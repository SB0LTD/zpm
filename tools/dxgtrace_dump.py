#!/usr/bin/env python3
"""Print a dxgtrace recording (tools/dxgtrace.sig) as text.

  python3 tools/dxgtrace_dump.py cuda.dxgt [--hex N] [--only NAME,...]

Each ioctl: its sequence number, dxgkrnl name, result, the argument after
the call (as dwords) and the memory it pointed at (first N bytes as hex,
default 64). Notes (kind 6) print as they come.
"""
import struct, sys

NAMES = {
    0x01: 'open_adapter_from_luid', 0x02: 'create_device', 0x04: 'create_context_virtual',
    0x05: 'destroy_context', 0x06: 'create_allocation', 0x07: 'create_paging_queue',
    0x08: 'reserve_gpu_va', 0x09: 'query_adapter_info', 0x0a: 'query_video_memory_info',
    0x0b: 'make_resident', 0x0c: 'map_gpu_va', 0x0d: 'escape', 0x0e: 'get_device_state',
    0x0f: 'submit_command', 0x10: 'create_sync_object2', 0x11: 'signal_sync_object2',
    0x12: 'wait_sync_object2', 0x13: 'destroy_allocation2', 0x14: 'enum_adapters2',
    0x15: 'close_adapter', 0x16: 'change_vidmem_reservation', 0x18: 'create_hw_queue',
    0x19: 'destroy_device', 0x1b: 'destroy_hw_queue', 0x1c: 'destroy_paging_queue',
    0x1d: 'destroy_sync_object', 0x1e: 'evict', 0x1f: 'flush_heap_transitions',
    0x20: 'free_gpu_va', 0x24: 'invalidate_cache', 0x25: 'lock2', 0x26: 'mark_device_as_error',
    0x27: 'offer_allocations', 0x2a: 'query_allocation_residency', 0x2c: 'reclaim_allocations2',
    0x2e: 'set_allocation_priority', 0x30: 'set_context_scheduling_priority',
    0x31: 'signal_sync_from_cpu', 0x32: 'signal_sync_from_gpu', 0x33: 'signal_sync_from_gpu2',
    0x34: 'submit_to_hw_queue', 0x35: 'submit_signal_to_hw_queue', 0x36: 'submit_wait_to_hw_queue',
    0x37: 'unlock2', 0x38: 'update_alloc_property', 0x39: 'update_gpu_va',
    0x3a: 'wait_sync_from_cpu', 0x3b: 'wait_sync_from_gpu', 0x3c: 'get_allocation_priority',
    0x3d: 'query_clock_calibration', 0x3e: 'enum_adapters3', 0x3f: 'share_objects',
    0x43: 'query_statistics', 0x44: 'share_object_with_host', 0x45: 'create_sync_file',
    0x46: 'wait_sync_file', 0x49: 'is_feature_enabled',
}
KINDS = {1: 'in', 2: 'out', 3: 'ptr-in', 4: 'ptr-out', 5: 'cmdbuf', 6: 'note'}


def records(path):
    b = open(path, 'rb').read()
    o = 0
    while o + 32 <= len(b):
        magic, kind, nr, seq, addr, n, rc = struct.unpack_from('<4sIIIQIi', b, o)
        assert magic == b'DXGT', o
        yield kind, nr, seq, addr, rc, b[o + 32:o + 32 + n]
        o += 32 + n


def dwords(d):
    return ' '.join('%08x' % w for w in struct.unpack_from('<%dI' % (len(d) // 4), d))


def main():
    path = sys.argv[1]
    nhex = 64
    only = None
    if '--hex' in sys.argv:
        nhex = int(sys.argv[sys.argv.index('--hex') + 1])
    if '--only' in sys.argv:
        only = set(sys.argv[sys.argv.index('--only') + 1].split(','))
    counts = {}
    for kind, nr, seq, addr, rc, d in records(path):
        name = NAMES.get(nr, 'ioctl_%02x' % nr)
        if kind == 6:
            print('---- %s' % d.decode('utf-8', 'replace'))
            continue
        if only and name not in only:
            continue
        if kind == 1:
            counts[name] = counts.get(name, 0) + 1
            continue
        if kind == 2:
            print('#%-5d %-26s rc=%d  %s' % (seq, name, rc, dwords(d)))
        else:
            print('       %-7s @%x %d bytes: %s%s' % (KINDS[kind], addr, len(d), d[:nhex].hex(),
                                                      '...' if len(d) > nhex else ''))
    print('---- totals:', ', '.join('%s %d' % kv for kv in sorted(counts.items(), key=lambda kv: -kv[1])))


main()
