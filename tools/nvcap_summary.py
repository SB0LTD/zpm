#!/usr/bin/env python3
# Summary of an nvcap file: the region notes, then each setup (magic,
# width/height) and each push window (the NVENC methods in it).
#   summary.py FILE [--methods]
import struct, sys

data = open(sys.argv[1], 'rb').read()
recs = []
off = 0
while off + 24 <= len(data):
    assert data[off:off + 4] == b'NVCP', off
    kind, addr, seq, n = struct.unpack_from('<IQII', data, off + 4)
    recs.append((kind, addr, seq, data[off + 24:off + 24 + n]))
    off += 24 + n
notes = [r for r in recs if r[0] == 3]
setups = [r for r in recs if r[0] == 1]
pushes = [r for r in recs if r[0] == 2]
print('records', len(recs), 'notes', len(notes), 'setups', len(setups), 'push windows', len(pushes))
for k, a, s, b in notes[:40]:
    print('  ', b.decode(errors='replace'))
for k, a, s, b in setups[:40]:
    w0, w1 = struct.unpack_from('<II', b, 0)
    print('setup seq %5d at %x: magic %08x  w %d h %d  len %d' % (s, a, w0, (w1 & 0xffff) + 1, (w1 >> 16) + 1, len(b)))


def methods(b):
    """The method headers and values in a push window (incrementing, non-
    incrementing, one-increment, immediate), as (method, value) pairs."""
    out = []
    i = 0
    n = len(b) // 4
    words = struct.unpack_from('<%dI' % n, b, 0)
    while i < n:
        h = words[i]
        op = h >> 29
        cnt = (h >> 16) & 0x1fff
        sub = (h >> 13) & 7
        m = (h & 0xfff) << 2
        if op == 4:  # immediate
            out.append((sub, m, cnt))
            i += 1
            continue
        if op in (1, 3, 5) and 0 < cnt <= 64 and i + cnt < n:
            for j in range(cnt):
                mm = m + 4 * j if op == 1 else (m if op == 3 else (m if j == 0 else m + 4))
                out.append((sub, mm, words[i + 1 + j]))
            i += 1 + cnt
            continue
        i += 1
    return out


if '--methods' in sys.argv:
    for k, a, s, b in pushes[:20]:
        ms = methods(b)
        enc = [(sub, m, v) for sub, m, v in ms if 0x700 <= m <= 0x7fc or 0x480 <= m <= 0x4fc or m in (0x0, 0x200, 0x300)]
        print('push seq %5d at %x: %s' % (s, a, ' '.join('%d:%x=%x' % e for e in enc)))
