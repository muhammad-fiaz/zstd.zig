# Security Policy

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| 0.0.3   | :white_check_mark: |
| < 0.0.3 | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability in zstd.zig, please report it responsibly.

**Please do NOT open a public GitHub issue for security vulnerabilities.**

Instead:

1. Email **contact@muhammadfiaz.com** with details, or
2. Use [GitHub private vulnerability reporting](https://github.com/muhammad-fiaz/zstd.zig/security/advisories/new)

Include:
- A description of the vulnerability
- Steps to reproduce or a proof of concept
- The affected version(s)
- Any potential impact you have identified

You will receive an acknowledgement within **72 hours**. We aim to release a
fix within **30 days** depending on severity, and will publish a security
advisory once a patch is available.

## Scope

zstd.zig decompresses untrusted input by design. The following guarantees apply:

- Malformed, truncated, or hostile compressed data must never cause out-of-bounds
  reads/writes, undefined behavior, or hangs — only a returned `ZstdError`.
- Decompression validates the frame magic (`0xFD2FB528`), frame header fields,
  block headers, FSE/Huffman table constraints, sequence offsets against the
  declared window, content size, and the optional XXH64 checksum.
- Allocation failures propagate as `error.OutOfMemory`; no hidden global state.

Out of scope: misuse of the API (e.g., passing slices with the wrong lifetime),
and attacks on the Zig standard library itself.
