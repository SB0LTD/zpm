#!/usr/bin/env python3
# Every named field of the setups in an nvcap file, by zpm's tables
# (src/va/nvenc.sig: `pub const X = struct { pub const f: F = .{ .bit = N,
# .width = W }; ...}`), and the bytes no field covers that are not zero.
#   fields.py NVENC_SIG FILE STRUCT [SUBSTRUCT@OFFSET ...] [--setup K]
# e.g. fields.py nvenc.sig hevc1.nvcap H265 H265Slice@0x600 H265Md@0x400
import re, struct, sys

src = open(sys.argv[1]).read()
cap = open(sys.argv[2], 'rb').read()
top = sys.argv[3]
subs = [a for a in sys.argv[4:] if '@' in a]
k_want = int(sys.argv[sys.argv.index('--setup') + 1]) if '--setup' in sys.argv else 0


def table(name):
    m = re.search(r'pub const %s = struct \{(.*?)\n\};' % name, src, re.S)
    if not m:
        sys.exit('no struct ' + name)
    fs = re.findall(r'pub const (\w+): F = \.\{ \.bit = (\d+), \.width = (\d+) \}', m[1])
    size = re.search(r'pub const SIZE = (\d+);', m[1])
    return [(n, int(b), int(w)) for n, b, w in fs], int(size[1]) if size else None


setups = []
off = 0
while off + 24 <= len(cap):
    kind, addr, seq, n = struct.unpack_from('<IQII', cap, off + 4)
    if kind == 1:
        setups.append((seq, cap[off + 24:off + 24 + n]))
    off += 24 + n
seq, buf = setups[k_want]
val = int.from_bytes(buf, 'little')
print('setup', k_want, 'of', len(setups), 'seq', seq)
covered = set()
for spec in [top + '@0'] + subs:
    name, at = spec.split('@')
    at = int(at, 0)
    fs, size = table(name)
    print('== %s at 0x%x (%s bytes)' % (name, at, size))
    for n, b, w in fs:
        bit = at * 8 + b
        v = (val >> bit) & ((1 << w) - 1)
        for x in range(bit, bit + w):
            covered.add(x)
        print('  %-40s %d' % (n, v))
# bytes with bits set that no field covers
loose = []
for i, byte in enumerate(buf):
    if byte and any(((byte >> j) & 1) and (i * 8 + j) not in covered for j in range(8)):
        loose.append(i)
print('nonzero bytes no field covers: %d' % len(loose))
for i in loose[:200]:
    print('  0x%03x = %02x' % (i, buf[i]))
