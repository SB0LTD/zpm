//! @zpm/va codec — what the driver (driver.sig) gives a codec module and
//! what it asks of one. H.264 is the driver's own (nvdec.sig, the first
//! codec); HEVC (hevc.sig), VP9 (vp9.sig) and AV1 (av1.sig) are modules
//! that meet here, so each is written and tested on its own.
//!
//! A module is a namespace with:
//!
//!   pub const State: per-context state kept across pictures (probability
//!       contexts, which picture slot holds which surface, ping-pong
//!       buffers); `State.init(width, height)` makes one.
//!   pub const MAX_PIC_BYTES: the most its setup struct takes (PIC_BYTES
//!       at most) and MAX_AUX_BYTES: its per-frame side buffers (scaling
//!       lists, tile sizes, probability tables; AUX_BYTES at most).
//!   pub fn scratchBytes(width, height) usize: its context-wide buffers
//!       (co-located motion, filter rows, segment maps, ...), in the work
//!       buffer after the frame slots; the driver zeroes them once.
//!   pub fn begin(st: *State) void: a new picture (BeginPicture).
//!   pub fn take(st: *State, b: Buffer, slot: Slot) va.Status: one VA
//!       buffer of the picture (RenderPicture), in VA's order: picture
//!       parameters, matrices or probabilities, then each slice parameter
//!       buffer and its slice data. The bitstream goes into `slot.stream`
//!       as the decoder wants it.
//!   pub fn end(st: *State, slot: Slot, scratch: Scratch, pic: Picture,
//!       lookup: Lookup, out: *End) va.Status: the setup into `slot.pic`,
//!       side buffers into `slot.aux`, the pushbuffer into `slot.push`
//!       (EndPicture); va.SUCCESS and `out` filled, or why not.
//!       `End.dwords` is the pushbuffer's length; `End.wait` asks the
//!       driver to wait for this decode before the next and then call
//!       `after` (VP9's backward adaptation reads the decoder's counts).
//!   pub fn after(st: *State, scratch: Scratch) void: that decode is done.
//!
//! Modules use nvdec.sig's `header`, `shifted`, `SLOTS`, `Status` and the
//! common methods; they never touch the node, surfaces or the CPU copy.

const std = @import("std");
const va = @import("vaapi.sig");
const nvdec = @import("nvdec.sig");

/// The setup struct's room in a frame slot.
pub const PIC_BYTES: usize = 0xc00;
/// Per-frame side buffers' room in a frame slot.
pub const AUX_BYTES: usize = 0xe000;

/// One VA buffer handed over by RenderPicture.
pub const Buffer = struct {
    /// VABufferType
    kind: u32,
    /// one element's size and how many (VA's slice parameter buffers hold
    /// several)
    size: u32,
    count: u32,
    /// all of it (size * count bytes)
    data: []const u8,

    /// Element `k` as `T` (the caller has checked `size >= @sizeOf(T)`).
    pub fn element(b: Buffer, comptime T: type, k: usize) T {
        return std.mem.bytesToValue(T, b.data[k * b.size ..][0..@sizeOf(T)]);
    }
};

/// One frame slot of the context's work buffer: CPU views and the
/// decoder's addresses (256-byte aligned) of each part.
pub const Slot = struct {
    push: []u32,
    pic: []u8,
    pic_va: u64,
    aux: []u8,
    aux_va: u64,
    status_va: u64,
    stream: []u8,
    stream_va: u64,
};

/// The context's codec-wide buffers (scratchBytes of them, zeroed when
/// the context was made).
pub const Scratch = struct {
    cpu: []u8,
    va: u64,
};

/// A surface as the decoder sees it: its block-linear planes.
pub const SurfaceRef = struct {
    luma: u64,
    chroma: u64,
    /// the picture's size, and the planes' pitches in bytes
    width: u32,
    height: u32,
    pitch_luma: u32,
    pitch_chroma: u32,
    /// bytes a sample: 1 for NV12, 2 for P010 (a 10-bit stream's target;
    /// the pitches are in bytes either way, so the decoder's framestride is
    /// the 2-byte layout's)
    sample_bytes: u8 = 1,

    /// The surface holds `bits`-bit samples (8 in NV12, 10 in P010).
    pub fn holds(s: SurfaceRef, bits: u32) bool {
        return if (bits == 8) s.sample_bytes == 1 else bits == 10 and s.sample_bytes == 2;
    }
};

/// VA surface ids to surfaces (null: not one of this driver's).
pub const Lookup = struct {
    ctx: *anyopaque,
    surface_fn: *const fn (ctx: *anyopaque, id: u32) ?SurfaceRef,

    pub fn surface(l: Lookup, id: u32) ?SurfaceRef {
        return l.surface_fn(l.ctx, id);
    }
};

/// What the driver knows of the picture being ended.
pub const Picture = struct {
    /// the decode target: its VA id and its planes
    target_id: u32,
    target: SurfaceRef,
    /// blocks of 2 << gob_height GOBs (tiling.sig)
    gob_height: u3,
    /// this context's decodes so far (SET_PICTURE_INDEX)
    picture_index: u32,
};

pub const End = struct {
    dwords: usize,
    wait: bool = false,
};

/// SET_OBJECT, the decoder's class bound on subchannel 0: every pushbuffer
/// starts with it (the probe's and H.264's do).
pub fn bind(out: []u32, n: *usize) void {
    put(out, n, nvdec.SET_OBJECT, nvdec.CLASS | nvdec.SET_OBJECT_ENGINE_SW);
}

/// One method, one value.
pub fn put(out: []u32, n: *usize, method: u32, value: u32) void {
    out[n.*] = nvdec.header(0, method, 1);
    out[n.* + 1] = value;
    n.* += 2;
}

/// The 17 picture slots' planes (SET_PICTURE_{LUMA,CHROMA}_OFFSET0..16).
pub fn pictures(out: []u32, n: *usize, luma: [nvdec.SLOTS]u64, chroma: [nvdec.SLOTS]u64) void {
    out[n.*] = nvdec.header(0, nvdec.SET_PICTURE_LUMA_OFFSET0, nvdec.SLOTS);
    n.* += 1;
    for (luma) |l| {
        out[n.*] = nvdec.shifted(l);
        n.* += 1;
    }
    out[n.*] = nvdec.header(0, nvdec.SET_PICTURE_CHROMA_OFFSET0, nvdec.SLOTS);
    n.* += 1;
    for (chroma) |c| {
        out[n.*] = nvdec.shifted(c);
        n.* += 1;
    }
}

/// EXECUTE: NOTIFY off, NOTIFY_ON end, AWAKEN off (the kernel's fence
/// after the pushbuffer says done).
pub fn execute(out: []u32, n: *usize) void {
    put(out, n, nvdec.EXECUTE, 0);
}

/// SET_CONTROL_PARAMS as NVK sets it: CODEC_TYPE, GPTIMER_ON (the setup's
/// timeout), ERR_CONCEAL_ON, MBTIMER_ON, ERROR_FRM_IDX (12:7).
pub fn controlParams(codec_type: u32, error_frm_idx: u32) u32 {
    return codec_type | (1 << 4) | (1 << 6) | ((error_frm_idx & 0x3f) << 7) | (1 << 13);
}

// ── A fake lookup for modules' tests ────────────────────────────────────────

/// Surfaces 1..n at made-up addresses, `w` x `h`, 64-byte pitches.
pub const FakeSurfaces = struct {
    w: u32,
    h: u32,
    n: u32,

    fn find(ctx: *anyopaque, id: u32) ?SurfaceRef {
        const f: *FakeSurfaces = @ptrCast(@alignCast(ctx));
        if (id == 0 or id > f.n) return null;
        const base = 0x40_0000_0000 + @as(u64, id) * 0x100_0000;
        const pitch = std.mem.alignForward(u32, f.w, 64);
        return .{ .luma = base, .chroma = base + 0x80_0000, .width = f.w, .height = f.h, .pitch_luma = pitch, .pitch_chroma = pitch };
    }

    pub fn lookup(f: *FakeSurfaces) Lookup {
        return .{ .ctx = f, .surface_fn = find };
    }
};

/// A frame slot in plain memory at made-up addresses, for modules' tests.
pub const FakeSlot = struct {
    push: [512]u32 = undefined,
    pic: [PIC_BYTES]u8 align(16) = undefined,
    aux: [AUX_BYTES]u8 align(16) = undefined,
    stream: [256 << 10]u8 = undefined,

    pub fn slot(f: *FakeSlot) Slot {
        @memset(&f.pic, 0);
        @memset(&f.aux, 0);
        return .{
            .push = &f.push,
            .pic = &f.pic,
            .pic_va = 0x10_0000_0400,
            .aux = &f.aux,
            .aux_va = 0x10_0000_2000,
            .status_va = 0x10_0000_1400,
            .stream = &f.stream,
            .stream_va = 0x10_0001_0000,
        };
    }
};

test "codec: a pushbuffer's common pieces" {
    var out: [64]u32 = undefined;
    var n: usize = 0;
    bind(&out, &n);
    put(&out, &n, nvdec.SET_APPLICATION_ID, 7);
    var l = [_]u64{0x100} ** nvdec.SLOTS;
    l[16] = 0x200;
    pictures(&out, &n, l, l);
    execute(&out, &n);
    try std.testing.expectEqual(@as(usize, 2 + 2 + 2 * (1 + nvdec.SLOTS) + 2), n);
    try std.testing.expectEqual(@as(u32, 0x2001_0080), out[2]);
    try std.testing.expectEqual(@as(u32, 7), out[3]);
    try std.testing.expectEqual(@as(u32, 2), out[4 + 17]);
    try std.testing.expectEqual(@as(u32, 0x2001_00c0), out[n - 2]);
    try std.testing.expectEqual(@as(u32, 7 | (1 << 4) | (1 << 6) | (3 << 7) | (1 << 13)), controlParams(7, 3));
}
