//! @zpm/dxg fwd — forwarding an NVIDIA GPU to a virtual machine: the
//! requests a guest's driver makes over a virtio device, and what the host
//! answers (tools/gpud.sig serves them with fwd_server over /dev/dxg).
//!
//! The device is virtio ID 21 (PCI 1af4:1055): the specification's
//! "signal distribution module", which no system implements, taken because
//! QEMU 8.2's vhost-user-device accepts only IDs it has a name for. One
//! virtqueue, no config space. Each
//! request is a chain of two buffers: a Request the device reads, a
//! Response it writes.
//!
//! The guest's memory is the GPU's: the guest chooses GPU addresses in its
//! window (WINDOW_START..WINDOW_END, as Galaxy's render node lays them out)
//! and maps its own RAM there (`map`: guest-physical, contiguous, 64 KiB
//! units); the host maps the very same pages for the GPU, so pushbuffers,
//! code and data are never copied. Each channel's finished work shows in
//! the guest's status page (`status_page`): the GPU writes a channel's
//! fence (u32) at status + 8 * channel when its work is done, so the guest
//! waits by reading its own memory.
//!
//! Plain data: usable by a freestanding guest kernel and by the host.

const std = @import("std");

pub const VIRTIO_ID: u16 = 21;
pub const PCI_VENDOR: u16 = 0x1af4;
pub const PCI_DEVICE: u16 = 0x1040 + VIRTIO_ID;
pub const VERSION: u32 = 1;

/// The guest's GPU address window (Galaxy's render node's, nv_dev's).
pub const WINDOW_START: u64 = 0x40_0000_0000;
pub const WINDOW_END: u64 = 0x80_0000_0000;
/// Mappings are whole units of this (the host GPU's allocation unit).
pub const UNIT: u64 = 64 << 10;
/// Channels 1..MAX_CHANNELS-1 (0: none).
pub const MAX_CHANNELS = 17;

pub const Op = enum(u32) {
    /// a: VERSION. Answer: a = PCI vendor << 16 | device of the GPU, b =
    /// the window's start, c = its end.
    hello = 1,
    /// a: guest-physical address, b: GPU address, c: bytes. The page the
    /// GPU writes channel fences to.
    status_page = 2,
    /// a: guest-physical address, b: GPU address, c: bytes. Answer: a = a
    /// handle.
    map = 3,
    /// a: the GPU address a `map` gave.
    unmap = 4,
    /// Answer: chan = a new channel (the 3D engine and compute).
    open = 5,
    /// chan: a channel `open` gave.
    close = 6,
    /// chan, a: a pushbuffer's GPU address, b: its dwords. Answer: a = its
    /// fence (the status page's word reaches it when the work is done).
    submit = 7,
    /// chan. Answer: a = the channel's last finished fence, b = 1 when the
    /// channel faulted (lost: open another).
    state = 8,
    /// b: GPU address, c: bytes. The GPU's own memory (VRAM) there: the
    /// guest has no view of it, the GPU reads and writes it at full speed
    /// (a frame drawn there and copied out, gfx_pipe's). Answer: a = a
    /// handle; `unmap` gives it back.
    map_video = 9,
    _,
};

pub const Status = enum(i32) {
    ok = 0,
    /// Not a request this host knows, or arguments out of range.
    invalid = -22,
    /// The host's GPU refused (dxgkrnl, NVIDIA's host driver).
    refused = -5,
    /// No channel or table room left.
    busy = -16,
    /// No GPU behind the device.
    no_device = -19,
    /// The channel faulted.
    lost = -32,
    _,
};

pub const Request = extern struct {
    op: u32,
    chan: u32 = 0,
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
};

pub const Response = extern struct {
    status: i32 = 0,
    chan: u32 = 0,
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
};

comptime {
    if (@sizeOf(Request) != 32 or @sizeOf(Response) != 32) @compileError("fwd: 32-byte requests and responses");
}

/// Where channel `chan`'s fence word is in the status page.
pub fn fenceOffset(chan: u32) u64 {
    return 8 * @as(u64, chan);
}

/// Whether [va, va + bytes) is a mapping the guest may ask for.
pub fn inWindow(va: u64, bytes: u64) bool {
    return va % UNIT == 0 and bytes != 0 and bytes % UNIT == 0 and va >= WINDOW_START and bytes <= WINDOW_END - va;
}

test "fwd: the window" {
    try std.testing.expect(inWindow(WINDOW_START, UNIT));
    try std.testing.expect(!inWindow(WINDOW_START + 4096, UNIT));
    try std.testing.expect(!inWindow(WINDOW_END - UNIT, 2 * UNIT));
    try std.testing.expectEqual(@as(u16, 0x1055), PCI_DEVICE);
}
