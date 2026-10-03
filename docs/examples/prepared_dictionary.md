---
title: Prepared Dictionary
description: Preparing dictionary state once and reusing it across many operations.
---

# Prepared Dictionary

`examples/prepared_dictionary.zig`

A *prepared* dictionary carries, after its magic and ID, the entropy tables that
describe its own content: a Huffman table for literals, FSE normalized counts for
the three sequence code sets, and the three repeat offsets in use when it was
built. A frame compressed against it inherits those tables instead of re-deriving
them from scratch, which is the point of preparing rather than loading raw
content.

Preparation produces no mutable state, so one prepared dictionary can be read by
many contexts at once.

## Output

```text
prepared dictionary id 0, 62 bytes of content
compressed  62 bytes into  16
compressed  78 bytes into  81
compressed  59 bytes into  31
compressed   0 bytes into   9
frame 0 round tripped, 62 bytes
frame 1 round tripped, 78 bytes
frame 2 round tripped, 59 bytes
frame 3 round tripped, 0 bytes
mismatched dictionary refused as InvalidOffset
missing dictionary refused as DictionaryWrong
```

## API used

| Call | Role |
|---|---|
| `zstd.prepareDictionary(allocator, bytes)` | Parse an existing dictionary into reusable state |
| `zstd.PreparedDictionary.fromContent(allocator, text, id)` | Wrap raw content with a magic and ID |
| `prepared.content()` | The dictionary content, without any header or tables |
| `zstd.loadDictionary(allocator, bytes)` | A `Dictionary` view for a context to hold |
| `zstd.createDictionaryFromData(allocator, text, id)` | Same, from raw content |
| `zstd.Compressor.setDictionary` / `zstd.Decompressor.setDictionary` | Attach it |

## Notes

- **Line 3 is the honest result.** 78 bytes of unrelated text does not fit the
  62-byte dictionary, so the frame is *larger* than the input - 81 bytes for 78.
  A dictionary helps when the payload shares phrasing with it and costs when it
  does not. Line 4 is the middle case, and line 5 is an empty payload, which still
  needs a 9-byte frame.
- **The last two lines are the safety property.** A frame compressed against one
  dictionary must not decode against another: its matches point at specific
  content, and decoding against the wrong dictionary produces plausible-looking
  rubbish rather than an obvious failure. A missing dictionary is refused too,
  for the same reason.
- One prepared dictionary is built and then used for all four compressions and
  all four decompressions. Nothing about the second use depends on the first,
  which is the property that makes preparation worth doing.

Run:

```bash
zig build run-prepared_dictionary
```
