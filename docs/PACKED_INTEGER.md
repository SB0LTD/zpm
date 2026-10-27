# Caller-owned packed integer columns

`src/core/packed_integer.sig` is a Layer 0 physical storage primitive. It has no
allocator, OS calls, SQL dependency or global mutable state. `encode(values,
null_mask, output)` writes one immutable frame into caller-owned output.
`parse(frame)` validates an existing frame. Both return a borrowed `View`; keep
the bytes alive and immutable for the entire lifetime of every view. Construct
views through these functions rather than manually initializing their fields.

The null mask uses one bit per row, least significant bit first; one means NULL.
A missing mask means all values are present. Slots marked NULL are ignored.
`value(row)` returns a nullable signed 64-bit integer and checks row bounds.
`summary()` returns the row count, non-NULL count and exact signed 128-bit sum;
the sum is NULL for zero non-NULL values. Parsing verifies the sum against the
payload. Summary verification is linear in the row count for nonconstant frames,
so validate once when admitting a frame, rather than once per query.

## Physical format, version 1

All integers are little endian. The 80-byte header contains:

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 8 | Magic `ZPMI0001` |
| 8 | 2 | Version, currently 1 |
| 10 | 1 | Flags: 0 no NULLs, 1 bitmap, 2 all NULLs |
| 11 | 1 | Delta width in bits, from 0 through 64 |
| 12 | 4 | Reserved, zero |
| 16 | 8 | Row count |
| 24 | 8 | Minimum/base, signed |
| 32 | 8 | Bitmap bytes |
| 40 | 8 | Packed data bytes |
| 48 | 8 | Non-NULL count |
| 56 | 16 | Exact signed sum |
| 72 | 8 | Wyhash checksum of bytes 0..72 followed by bytes 80..end |

The payload contains the optional NULL bitmap followed by unsigned deltas from
the base, packed least significant bit first. NULL deltas and unused trailing
bits are zero. A constant column needs no delta payload; an entirely NULL column
needs neither bitmap nor deltas. Otherwise the encoded size is
`80 + bitmap_bytes + ceil(rows * delta_bits / 8)`. Every size calculation is
checked before converting to the host address size. Checksum validation detects
accidental corruption; it is not cryptographic authentication.

For example, a column of 100M integers whose range fits in 27 bits requires
337,500,080 bytes without NULLs, or an extra 12,500,000 bytes with mixed NULLs.
This is format arithmetic, not evidence of a loaded RAMSQL table. Real tables
also need other columns, indexes, version ownership, execution buffers and
durability metadata. Full-width random integers can require all 64 delta bits.

Validation/capacity/alias errors leave the supplied output unchanged. The output
must not overlap either input, even if an overlapping input slot is marked NULL.
Encoding does not allocate a fallback buffer. A parsed frame must exactly match
its declared size; truncated frames, invalid flags, incorrect NULL counts,
nonzero padding/NULL deltas, corruption and inconsistent sums are rejected.

## Validation and integration status

Run `sig build test-packed-integer -Doptimize=ReleaseSafe`. The executable checks
every bit width, signed extrema, NULLs, random round trips, unaligned decoding,
error atomicity, alias rejection, corruption and checked format arithmetic.
It is included in the Windows/Linux/macOS database platform workflow.

This primitive does not implement SQL execution, MVCC, page publication,
reclamation, WAL, snapshots or automatic machine-resource discovery. RAMSQL must
integrate it behind storage accessors and preserve those contracts before a
compact-column result can be attributed to the database server.
