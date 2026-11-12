//! @zpm/va enc_vp9 — a VP9 frame (profile 0, 8-bit 4:2:0): the kernels'
//! dispatches (vp9_kernels.sig), then the bitstream on the CPU.

const std = @import("std");

/// What the app (or the rate control) asks of a frame.
pub const Picture = struct {
    key: bool,
    q: u8,
    show: bool = true,
    error_resilient: bool = false,
    /// the reference slots this frame refreshes
    refresh: u8 = 0xff,
    /// the slot inter frames predict from (the app's LAST)
    ref_slot: u3 = 0,
    sharpness: u3 = 0,
    filter_level: ?u6 = null,
    search_range: u32 = 16,
};

pub const Error = error{ TooBig, NoSpace, Engine };

pub const Encoder = struct {
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32) Error!Encoder {
        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.TooBig;
        return .{ .width = width, .height = height };
    }
};

/// The CPU engine's memory (frames, records) for `e`.
pub fn cpuBytes(e: *const Encoder) usize {
    _ = e;
    return 4096;
}

/// A new frame store: the next frame is a key frame.
pub fn restart(e: *Encoder) void {
    _ = e;
}

/// One frame on the CPU engine (`mem`: cpuBytes of it, `surf`: the input
/// picture's buffer); the stream's bytes.
pub fn encodeCpu(e: *Encoder, mem: []u8, surf_mem: []u8, surf: anytype, pic: Picture, out: []u8, scratch: []u8) Error!usize {
    _ = .{ e, mem, surf_mem, surf, pic, out, scratch };
    return error.Engine;
}
