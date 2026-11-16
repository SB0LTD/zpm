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
//!       driver to call `after` once this decode is done and before the
//!       context's next picture is begun (VP9's backward adaptation reads
//!       the decoder's counts): the driver waits at that BeginPicture, so
//!       the decoder runs while the app makes the next picture.
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
    /// the buffer's bytes from `luma` (both planes; 0: not known)
    bytes: u32 = 0,

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
    /// another surface the decode writes besides the target (AV1 with film
    /// grain: the graded picture into current_display_picture), its VA id
    display: ?u32 = null,
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

/// Which SET_CONTROL_PARAMS word the HEVC, VP9 and AV1 modules send
/// (GALAXY_VA_CONTROL; H.264's is NVK's, always).
pub const Control = enum {
    /// NVK's (controlParams): proven on GB206 by H.264
    nvk,
    /// NVK's and TESTRUN_ENV PROD_RUN (19:18 = 1)
    prod,
    /// NVIDIA's driver's word as AROS nvgfx traced it on Ada and Blackwell
    /// (0x52050): NVK's, EVENT_TRACE_LOGGING_ON (16) and PROD_RUN
    nvidia,

    pub fn parse(s: []const u8) ?Control {
        return std.meta.stringToEnum(Control, s);
    }
};

pub fn controlFor(codec_type: u32, c: Control) u32 {
    const base = controlParams(codec_type, 0);
    return switch (c) {
        .nvk => base,
        .prod => base | (1 << 18),
        .nvidia => base | (1 << 16) | (1 << 18),
    };
}

// ── Blackwell (NVCFB0) ──────────────────────────────────────────────────────
//
// NVIDIA's public headers stop at Ada. AROS nvgfx (2026; workbench/hidds/
// nvgfx/nvgfx_decode{.h,_hevc.c,_vp9.c,_av1.c}, run on a GB207; facts only,
// none of its code) traced NVIDIA's driver on the class reported as CFB0:
// the HEVC, VP9 and AV1 paths (and the new H.264 application, id 8, which
// this driver does not use) bind one more buffer at method 0x4dc, of
// ceil(width / 128) + 1 blocks of 16 KiB, and write that count in the
// setup past Ada's struct, with a surface code and a depth code in fields
// Ada's header calls reserved. Without the buffer GB206's decoder faults at
// address 0 on the first HEVC, VP9 or AV1 picture (pc-1111c: MMU fault, VA
// 0, NVDEC0, every codec but H.264's old application).

/// The buffer's method (not in clc9b0.h).
pub const SET_BLK_BUF_OFFSET: u32 = 0x4dc;
pub const BLK_UNIT_BYTES: usize = 16 << 10;

/// The setup's count for pictures `width` samples wide.
pub fn blkUnits(width: u32) u32 {
    return (width + 127) / 128 + 1;
}

/// The buffer's bytes for pictures up to `width` wide.
pub fn blkBytes(width: u32) usize {
    return @as(usize, blkUnits(width)) * BLK_UNIT_BYTES;
}

/// The surface code NVIDIA's driver writes on Blackwell (HEVC reserved6,
/// VP9 reserved5, AV1 reserved_stat's low bits): 9 for 8-bit samples, 2
/// for 16-bit ones (P010).
pub fn surfaceCode(depth: u32) u8 {
    return if (depth > 8) 2 else 9;
}

/// The depth code beside it: 0, 3, 6 for 8, 10, 12 bits (4:2:0; HEVC adds
/// chroma_format_idc - 1).
pub fn depthCode(depth: u32) u8 {
    return @intCast(3 * ((@max(depth, 8) - 8) / 2));
}

/// What a module sends of Blackwell's additions (GALAXY_VA_BLACKWELL and
/// GALAXY_VA_{HEVC,VP9,AV1}_BLACKWELL).
pub const Blackwell = enum {
    /// the buffer at 0x4dc and the setup's fields (NVIDIA's, traced)
    full,
    /// the buffer only, Ada's setup
    buffer,
    /// the setup's fields only, no buffer (expected to fault: a check)
    fields,
    /// Ada's: neither (pc-1111c's)
    off,

    pub fn bindsBuffer(b: Blackwell) bool {
        return b == .full or b == .buffer;
    }

    pub fn writesFields(b: Blackwell) bool {
        return b == .full or b == .fields;
    }

    /// "1"/"on"/"full", "0"/"off", "buffer", "fields"; null: not one.
    pub fn parse(s: []const u8) ?Blackwell {
        if (std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "on")) return .full;
        if (std.mem.eql(u8, s, "0") or s.len == 0) return .off;
        return std.meta.stringToEnum(Blackwell, s);
    }
};

/// Zero bytes after a picture's bitstream (the decoder reads ahead; NVIDIA's
/// driver pads 256, as AROS traced).
pub const STREAM_PAD: usize = 256;

/// Pads the stream's `len` bytes in `stream` with zeros, as far as it fits.
pub fn padStream(stream: []u8, len: usize) void {
    if (len >= stream.len) return;
    const end = @min(stream.len, len + STREAM_PAD);
    @memset(stream[len..end], 0);
}

// ── A fake lookup for modules' tests ────────────────────────────────────────

/// Surfaces 1..n at made-up addresses, `w` x `h`, 64-byte pitches.
pub const FakeSurfaces = struct {
    w: u32,
    h: u32,
    n: u32,
    /// 2: P010 surfaces (10-bit)
    sample_bytes: u8 = 1,

    fn find(ctx: *anyopaque, id: u32) ?SurfaceRef {
        const f: *FakeSurfaces = @ptrCast(@alignCast(ctx));
        if (id == 0 or id > f.n) return null;
        const base = 0x40_0000_0000 + @as(u64, id) * 0x100_0000;
        const pitch = std.mem.alignForward(u32, f.w * f.sample_bytes, 64);
        return .{ .luma = base, .chroma = base + 0x80_0000, .width = f.w, .height = f.h, .pitch_luma = pitch, .pitch_chroma = pitch, .sample_bytes = f.sample_bytes, .bytes = 0x100_0000 };
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

test "codec: Blackwell's additions and the control words" {
    // (NVIDIA's HEVC word as AROS traced it: 7 | 0x52050)
    try std.testing.expectEqual(@as(u32, 0x52057), controlFor(7, .nvidia));
    try std.testing.expectEqual(controlParams(9, 0), controlFor(9, .nvk));
    try std.testing.expectEqual(controlParams(10, 0) | (1 << 18), controlFor(10, .prod));
    try std.testing.expectEqual(@as(?Control, .nvidia), Control.parse("nvidia"));
    try std.testing.expectEqual(@as(?Control, null), Control.parse("x"));
    // 640 wide: 5 + 1 blocks; 1920: 15 + 1; 1921: 16 + 1
    try std.testing.expectEqual(@as(u32, 6), blkUnits(640));
    try std.testing.expectEqual(@as(u32, 16), blkUnits(1920));
    try std.testing.expectEqual(@as(u32, 17), blkUnits(1921));
    try std.testing.expectEqual(@as(usize, 16 * 16384), blkBytes(1920));
    try std.testing.expectEqual(@as(u8, 9), surfaceCode(8));
    try std.testing.expectEqual(@as(u8, 2), surfaceCode(10));
    try std.testing.expectEqual(@as(u8, 0), depthCode(8));
    try std.testing.expectEqual(@as(u8, 3), depthCode(10));
    try std.testing.expectEqual(@as(?Blackwell, .full), Blackwell.parse("1"));
    try std.testing.expectEqual(@as(?Blackwell, .full), Blackwell.parse("full"));
    try std.testing.expectEqual(@as(?Blackwell, .off), Blackwell.parse("0"));
    try std.testing.expectEqual(@as(?Blackwell, .buffer), Blackwell.parse("buffer"));
    try std.testing.expectEqual(@as(?Blackwell, .fields), Blackwell.parse("fields"));
    try std.testing.expect(Blackwell.full.bindsBuffer() and Blackwell.full.writesFields());
    try std.testing.expect(Blackwell.buffer.bindsBuffer() and !Blackwell.buffer.writesFields());
    try std.testing.expect(!Blackwell.fields.bindsBuffer() and Blackwell.fields.writesFields());
    var s = [_]u8{0xaa} ** 300;
    padStream(&s, 10);
    try std.testing.expectEqual(@as(u8, 0xaa), s[9]);
    try std.testing.expectEqual(@as(u8, 0), s[10]);
    try std.testing.expectEqual(@as(u8, 0), s[265]);
    try std.testing.expectEqual(@as(u8, 0xaa), s[266]);
    padStream(&s, 299);
    try std.testing.expectEqual(@as(u8, 0), s[299]);
}
