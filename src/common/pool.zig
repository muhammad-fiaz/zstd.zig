//! Worker pool: a fixed set of threads pulling jobs from a bounded queue.
//!
//! A native Zig worker pool built on Zig 0.17 `std` primitives
//! (`std.Io.Mutex`, `std.Io.Condition`, `std.Thread`). The pool owns its
//! threads and its queue; the caller owns the job payloads, which must
//! outlive the job's execution.
//!
//! Ownership and synchronization rules:
//! - `init` spawns `num_threads` workers and allocates the queue. `deinit`
//!   shuts down, wakes every worker, and joins all of them. `deinit` must be
//!   called exactly once and no `add`/`tryAdd`/`joinJobs` may race it.
//! - The queue is a circular buffer of `queue_size + 1` slots (one wasted to
//!   tell empty from full). `add` blocks when the queue is full; `tryAdd`
//!   returns `false` instead. `queue_size == 0` means no queueing: `add`
//!   blocks whenever every worker is busy.
//! - A job is a plain function pointer plus an opaque argument. The pool never
//!   touches the payload; the caller guarantees it lives until the job runs.
//! - `joinJobs` blocks until the queue is empty and no worker is busy. It does
//!   not shut the pool down, so more jobs may be added afterwards.
//! - `resize` grows or shrinks the worker count. Shrinking only lowers the
//!   limit; excess workers exit once the queue drains and the limit lets them.

const std = @import("std");

threadlocal var current_pool: ?*Pool = null;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    threads: []std.Thread,
    threadCapacity: usize,
    threadLimit: usize,

    queue: []Job,
    queueHead: usize,
    queueTail: usize,
    queueSize: usize,

    numThreadsBusy: usize,
    numWorkersWaitingInJoin: usize,
    queueEmpty: bool,

    mutex: std.Io.Mutex,
    pushCond: std.Io.Condition,
    popCond: std.Io.Condition,
    shutdown: bool,

    /// A job is a function and its opaque argument. The function runs on a
    /// worker thread; the argument is borrowed, never owned.
    pub const Job = struct {
        function: *const fn (?*anyopaque) void,
        arg: ?*anyopaque,
    };

    /// Creates a pool with `num_threads` workers and a queue that holds
    /// `queue_size` pending jobs before `add` blocks. `queue_size == 0` means
    /// no queueing. The pool is heap-allocated because workers hold a pointer
    /// to it that must stay valid for the pool's whole lifetime. Returns an
    /// error on allocation failure or if a worker cannot be started; any
    /// workers already started are cleaned up.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, num_threads: usize, queue_size: usize) !*Pool {
        if (num_threads == 0) return error.InvalidArgument;
        const buf_len = queue_size + 1;
        const queue = try allocator.alloc(Job, buf_len);
        errdefer allocator.free(queue);
        const threads = try allocator.alloc(std.Thread, num_threads);
        errdefer allocator.free(threads);

        const self = try allocator.create(Pool);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .threads = threads,
            .threadCapacity = 0,
            .threadLimit = num_threads,
            .queue = queue,
            .queueHead = 0,
            .queueTail = 0,
            .queueSize = buf_len,
            .numThreadsBusy = 0,
            .numWorkersWaitingInJoin = 0,
            .queueEmpty = true,
            .mutex = .init,
            .pushCond = .init,
            .popCond = .init,
            .shutdown = false,
        };

        while (self.threadCapacity < num_threads) {
            const t = std.Thread.spawn(.{}, worker, .{self}) catch {
                self.mutex.lock(io) catch unreachable;
                self.shutdown = true;
                self.pushCond.broadcast(io);
                self.popCond.broadcast(io);
                self.mutex.unlock(io);
                for (threads[0..self.threadCapacity]) |th| th.join();
                return error.ThreadSpawnFailed;
            };
            threads[self.threadCapacity] = t;
            self.threadCapacity += 1;
        }
        return self;
    }

    /// Shuts the pool down and joins every worker, then frees the pool. After
    /// `deinit` the pointer is invalid. Safe to call exactly once; concurrent
    /// `add`/`tryAdd`/`joinJobs` are not safe and are the caller's
    /// responsibility to avoid.
    pub fn deinit(self: *Pool) void {
        const io = self.io;
        const allocator = self.allocator;
        const threads = self.threads;
        const queue = self.queue;
        self.mutex.lock(io) catch unreachable;
        self.shutdown = true;
        self.pushCond.broadcast(io);
        self.popCond.broadcast(io);
        self.mutex.unlock(io);
        for (threads[0..self.threadCapacity]) |t| t.join();
        allocator.free(threads);
        allocator.free(queue);
        allocator.destroy(self);
    }

    /// Adds a job, blocking until the queue has room. If the pool is shutting
    /// down the job is dropped (the pool is being torn down; the caller must
    /// not be adding jobs during shutdown).
    pub fn add(self: *Pool, function: *const fn (?*anyopaque) void, arg: ?*anyopaque) void {
        const io = self.io;
        self.mutex.lock(io) catch unreachable;
        while (self.isQueueFull() and !self.shutdown) {
            self.pushCond.wait(io, &self.mutex) catch {};
        }
        if (self.shutdown) {
            self.mutex.unlock(io);
            return;
        }
        self.queue[self.queueTail] = .{ .function = function, .arg = arg };
        self.queueTail = (self.queueTail + 1) % self.queueSize;
        self.queueEmpty = false;
        self.popCond.signal(io);
        self.mutex.unlock(io);
    }

    /// Adds a job if the queue has room; returns `false` without blocking
    /// otherwise. A job added during shutdown is dropped and reported as
    /// `false`.
    pub fn tryAdd(self: *Pool, function: *const fn (?*anyopaque) void, arg: ?*anyopaque) bool {
        const io = self.io;
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);
        if (self.isQueueFull() or self.shutdown) return false;
        self.queue[self.queueTail] = .{ .function = function, .arg = arg };
        self.queueTail = (self.queueTail + 1) % self.queueSize;
        self.queueEmpty = false;
        self.popCond.signal(io);
        return true;
    }

    /// Blocks until the queue is empty and no worker is busy. Does not shut
    /// the pool down; jobs may be added again afterwards.
    pub fn joinJobs(self: *Pool) void {
        const io = self.io;
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);
        const is_worker = (current_pool == self);

        while (!self.queueEmpty or self.numThreadsBusy > self.numWorkersWaitingInJoin) {
            if (!self.queueEmpty) {
                const job = self.queue[self.queueHead];
                self.queueHead = (self.queueHead + 1) % self.queueSize;
                self.queueEmpty = self.queueHead == self.queueTail;
                self.pushCond.signal(io);
                self.mutex.unlock(io);

                job.function(job.arg);

                self.mutex.lock(io) catch unreachable;
                self.pushCond.broadcast(io);
            } else {
                if (is_worker) {
                    self.numWorkersWaitingInJoin += 1;
                    if (self.queueEmpty and self.numThreadsBusy <= self.numWorkersWaitingInJoin) {
                        self.pushCond.broadcast(io);
                        self.numWorkersWaitingInJoin -= 1;
                        break;
                    }
                }
                self.pushCond.wait(io, &self.mutex) catch {};
                if (is_worker) self.numWorkersWaitingInJoin -= 1;
            }
        }
    }

    /// Changes the number of workers. Growing spawns new threads; shrinking
    /// lowers the limit so excess workers exit once they find no work and the
    /// limit lets them. Returns an error on failure to grow (the pool keeps
    /// its old size).
    pub fn resize(self: *Pool, num_threads: usize) !void {
        if (num_threads == 0) return error.InvalidArgument;
        const io = self.io;
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);
        if (num_threads <= self.threadCapacity) {
            self.threadLimit = num_threads;
            self.popCond.broadcast(io);
            return;
        }
        const grown = try self.allocator.realloc(self.threads, num_threads);
        self.threads = grown;
        while (self.threadCapacity < num_threads) {
            const t = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
                self.threadLimit = self.threadCapacity;
                return err;
            };
            self.threads[self.threadCapacity] = t;
            self.threadCapacity += 1;
        }
        self.threadLimit = num_threads;
        self.popCond.broadcast(io);
    }

    /// Number of workers currently running.
    pub fn count(self: *Pool) usize {
        return self.threadCapacity;
    }

    fn isQueueFull(self: *Pool) bool {
        if (self.queueSize > 1) {
            return self.queueHead == (self.queueTail + 1) % self.queueSize;
        }
        // queue_size == 0: full when every worker is busy or a job is queued.
        return self.numThreadsBusy == self.threadLimit or !self.queueEmpty;
    }

    /// Worker loop: wait for a job, run it, repeat. Exits when the pool is
    /// shutting down and it is not needed to drain the queue.
    fn worker(self: *Pool) void {
        current_pool = self;
        defer current_pool = null;
        const io = self.io;
        while (true) {
            self.mutex.lock(io) catch unreachable;
            while (self.queueEmpty or self.numThreadsBusy >= self.threadLimit) {
                if (self.shutdown) {
                    self.mutex.unlock(io);
                    return;
                }
                self.popCond.wait(io, &self.mutex) catch {};
            }
            const job = self.queue[self.queueHead];
            self.queueHead = (self.queueHead + 1) % self.queueSize;
            self.numThreadsBusy += 1;
            self.queueEmpty = self.queueHead == self.queueTail;
            self.pushCond.signal(io);
            self.mutex.unlock(io);

            job.function(job.arg);

            self.mutex.lock(io) catch unreachable;
            self.numThreadsBusy -= 1;
            self.pushCond.broadcast(io);
            self.mutex.unlock(io);
        }
    }
};

const testing = std.testing;

test "pool runs jobs on worker threads" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Ctx = struct {
        io: std.Io,
        mu: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        done: usize = 0,

        fn job(arg: ?*anyopaque) void {
            const c: *(@This()) = @ptrCast(@alignCast(arg.?));
            c.mu.lock(c.io) catch unreachable;
            c.done += 1;
            c.cond.signal(c.io);
            c.mu.unlock(c.io);
        }
    };

    var ctx = Ctx{ .io = io };
    const pool = try Pool.init(testing.allocator, io, 4, 8);
    defer pool.deinit();

    for (0..16) |_| pool.add(Ctx.job, &ctx);
    pool.joinJobs();

    ctx.mu.lock(io) catch unreachable;
    defer ctx.mu.unlock(io);
    try testing.expectEqual(@as(usize, 16), ctx.done);
}

test "pool tryAdd never blocks and reports a full queue" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Ctx = struct {
        io: std.Io,
        mu: std.Io.Mutex = .init,
        running: usize = 0,
        max_running: usize = 0,

        fn job(arg: ?*anyopaque) void {
            const c: *(@This()) = @ptrCast(@alignCast(arg.?));
            c.mu.lock(c.io) catch unreachable;
            c.running += 1;
            if (c.running > c.max_running) c.max_running = c.running;
            c.mu.unlock(c.io);
            std.Thread.yield() catch {};
            c.mu.lock(c.io) catch unreachable;
            c.running -= 1;
            c.mu.unlock(c.io);
        }
    };

    var ctx = Ctx{ .io = io };
    // One worker, no queue: tryAdd succeeds only when the worker is free.
    const pool = try Pool.init(testing.allocator, io, 1, 0);
    defer pool.deinit();

    var added: usize = 0;
    for (0..32) |_| {
        if (pool.tryAdd(Ctx.job, &ctx)) added += 1;
    }
    pool.joinJobs();
    // With one worker and no queue, at most a few jobs are accepted before the
    // worker is busy; the rest are refused. The point is it never blocks.
    try testing.expect(added < 32);
}

test "pool deinit joins every worker" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Ctx = struct {
        fn job(_: ?*anyopaque) void {}
    };
    _ = Ctx;
    const pool = try Pool.init(testing.allocator, io, 3, 4);
    try testing.expectEqual(@as(usize, 3), pool.count());
    pool.deinit();
}

test "pool resize grows and shrinks" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Ctx = struct {
        fn job(_: ?*anyopaque) void {}
    };
    _ = Ctx;
    const pool = try Pool.init(testing.allocator, io, 2, 4);
    defer pool.deinit();
    try pool.resize(5);
    try testing.expectEqual(@as(usize, 5), pool.count());
    try pool.resize(1);
    try testing.expectEqual(@as(usize, 5), pool.count());
    pool.joinJobs();
}

test "pool jobs run concurrently" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Ctx = struct {
        io: std.Io,
        mu: std.Io.Mutex = .init,
        active: usize = 0,
        peak: usize = 0,

        fn job(arg: ?*anyopaque) void {
            const c: *(@This()) = @ptrCast(@alignCast(arg.?));
            c.mu.lock(c.io) catch unreachable;
            c.active += 1;
            if (c.active > c.peak) c.peak = c.active;
            c.mu.unlock(c.io);
            // Hold the "CPU" long enough that a second worker must overlap.
            c.io.sleep(std.Io.Duration.fromNanoseconds(2_000_000), .awake) catch {};
            c.mu.lock(c.io) catch unreachable;
            c.active -= 1;
            c.mu.unlock(c.io);
        }
    };

    var ctx = Ctx{ .io = io };
    const pool = try Pool.init(testing.allocator, io, 2, 8);
    defer pool.deinit();

    pool.add(Ctx.job, &ctx);
    pool.add(Ctx.job, &ctx);
    pool.joinJobs();

    ctx.mu.lock(io) catch unreachable;
    defer ctx.mu.unlock(io);
    try testing.expectEqual(@as(usize, 2), ctx.peak);
}

test "pool waves survive add, tryAdd, join and a resize mid-flight" {
    // The pattern an application actually uses: fill the pool, drain it, and
    // change how many workers there are between waves. Every job must run exactly
    // once, whichever submission path took it.
    const io = testing.io;
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const Counter = struct {
        mu: std.Io.Mutex = .init,
        io: std.Io,
        next: usize = 0,
        runs: [16]usize = @splat(0),

        fn job(arg: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(arg.?));
            self.mu.lock(self.io) catch unreachable;
            const index = self.next;
            self.next += 1;
            if (index < self.runs.len) self.runs[index] += 1;
            self.mu.unlock(self.io);
        }
    };

    const rounds = 3;
    const per_round = 4;
    const total = rounds * per_round;
    var counter = Counter{ .io = io };
    var pool = try Pool.init(testing.allocator, io, 3, total);
    defer pool.deinit();

    for (0..rounds) |_| {
        for (0..per_round) |i| {
            // Half the jobs block until a worker takes them, half are offered and
            // retried, so both submission paths run in one wave.
            if (i % 2 == 0) {
                pool.add(Counter.job, &counter);
            } else {
                while (!pool.tryAdd(Counter.job, &counter)) {
                    io.sleep(std.Io.Duration.fromNanoseconds(50_000), .awake) catch {};
                }
            }
        }
        pool.joinJobs();
        // Shrink the pool between waves and put it back, the way a server reacts
        // to load changing. A resize must not disturb jobs already queued.
        try pool.resize(2);
        try pool.resize(3);
    }

    counter.mu.lock(io) catch unreachable;
    defer counter.mu.unlock(io);
    try testing.expectEqual(total, counter.next);
    for (counter.runs[0..total]) |count| try testing.expectEqual(@as(usize, 1), count);
}

test "pool jobs may themselves submit jobs" {
    // Fan-out inside a job: a worker that submits and waits for its own children is
    // the shape a parallel algorithm takes. The pool has to let a worker wait
    // without holding the queue, or this deadlocks as soon as the nesting needs
    // more workers than the pool has.
    const io = testing.io;
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const Nest = struct {
        io: std.Io,
        pool: *Pool,
        mu: std.Io.Mutex = .init,
        done: usize = 0,
        leaves_wanted: usize = 0,

        fn leaf(arg: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(arg.?));
            self.mu.lock(self.io) catch unreachable;
            self.done += 1;
            self.mu.unlock(self.io);
        }

        fn parent(arg: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(arg.?));
            self.leaves_wanted = 4;
            for (0..self.leaves_wanted) |_| self.pool.add(@This().leaf, self);
            self.pool.joinJobs();
        }
    };

    var nest = Nest{ .io = io, .pool = undefined };
    nest.pool = try Pool.init(testing.allocator, io, 4, 8);
    defer nest.pool.deinit();

    // Two parents, each queueing four leaves and then joining, which needs more
    // concurrent jobs than the pool has workers.
    nest.pool.add(Nest.parent, &nest);
    nest.pool.add(Nest.parent, &nest);
    nest.pool.joinJobs();

    nest.mu.lock(io) catch unreachable;
    defer nest.mu.unlock(io);
    try testing.expectEqual(@as(usize, 8), nest.done);
}
