//! @zpm/va video — the RTX's video engines for apps that hold a bitstream,
//! not VA-API buffers: Galaxy's Media Foundation on its Windows layer
//! (galaxy-pe's NtGalaxyVideo: Windows Firefox's decoder MFTs), or any
//! native player. A Decoder takes access units in decode order (H.264
//! Annex B first; the other codecs' readers plug in the same way), parses
//! them as a VA-API client would (h264_parse.sig), has the driver
//! (driver.sig: NVDEC over Galaxy's render node) decode each picture into
//! one of its surfaces, and hands the pictures back in display order, each
//! copied into the caller's memory (NV12, YV12 or P010, cropped to the
//! stream's visible rectangle) from the surface's pitch-linear copy, which
//! the driver converts from NVDEC's block-linear picture on the GPU.
//!
//! The same work as libva's path, so a picture decoded here is the one
//! Linux Firefox gets from galaxy_drv_video.so for the same stream.
//!
//! Generic over the driver type (driver.DriverWith(Sys, Conv)), so tests
//! run it on the fake node's pretend decoder. Allocation-free: fixed
//! tables, the driver's pools; one picture's VA buffers live in the
//! Decoder (a few hundred KiB: keep it in mapped memory, not on a stack).

const std = @import("std");
const va = @import("vaapi.sig");
const h264 = @import("h264_parse.sig");
const vp9r = @import("vp9_read.sig");
const vav9 = @import("vaapi_vp9.sig");
const vp8r = @import("vp8_read.sig");
const vav8 = @import("vaapi_vp8.sig");

pub const Codec = enum(u32) { h264 = 1, hevc = 2, vp8 = 3, vp9 = 4, av1 = 5, _ };

/// How a picture is laid out in the caller's memory.
pub const Layout = enum(u32) {
    /// luma rows, then interleaved UV rows (half height), both `pitch` apart
    nv12 = 0,
    /// luma rows, then V rows, then U rows (half width and height, pitch/2)
    yv12 = 1,
    /// as NV12 with 16-bit samples (10 bits in the high bits)
    p010 = 2,
    _,
};

pub const Status = enum(u32) {
    ok = 0,
    /// the input was taken but made no picture (parameter sets, SEI)
    more = 1,
    /// output pictures first (none free, or a new sequence waits for the
    /// old pictures to leave), then the same input again
    full = 2,
    /// the stream is one the engine cannot decode (profile, depth, size)
    unsupported = 3,
    /// the driver or the engine failed
    failed = 4,
    /// a broken access unit (skipped)
    bad = 5,
};

/// A picture ready for output.
pub const Out = struct {
    surface: u32 = 0,
    pts: i64 = 0,
    duration: i64 = 0,
    /// the visible rectangle within the surface (left, top, width, height)
    visible: [4]u32 = .{ 0, 0, 0, 0 },
    depth: u8 = 8,
};

pub const MAX_SURFACES = 24;
pub const QUEUE = 8;

pub fn Decoder(comptime D: type) type {
    return struct {
        const Self = @This();

        drv: *D,
        codec: Codec = .h264,
        config: u32 = 0,
        context: u32 = 0,
        image: u32 = 0,
        image_buf: u32 = 0,
        image_pitch: u32 = 0,
        image_uv: u32 = 0,
        /// the surfaces' coded size and depth, and how many there are
        width: u32 = 0,
        height: u32 = 0,
        depth: u8 = 8,
        count: u32 = 0,
        surfaces: [MAX_SURFACES]u32 = [_]u32{0} ** MAX_SURFACES,
        /// held by the parser (a reference or a picture not yet output),
        /// or waiting in the queue
        held: [MAX_SURFACES]bool = [_]bool{false} ** MAX_SURFACES,
        queued: [MAX_SURFACES]bool = [_]bool{false} ** MAX_SURFACES,
        queue: [QUEUE]Out = undefined,
        q_head: u32 = 0,
        q_len: u32 = 0,
        /// a picture that arrived with the queue full (bumped out of the
        /// DPB at the wrong moment): kept for the next output
        overflow: [MAX_SURFACES]Out = undefined,
        o_len: u32 = 0,
        h: h264.State = .{},
        pic: h264.Picture = .{},
        /// VP9: the eight reference slots' surfaces (vp9r.INVALID: none)
        /// and frame sizes, the stream's depth
        vp9_slots: [8]u32 = [_]u32{vp9r.INVALID} ** 8,
        vp9_sizes: [8][2]u32 = [_][2]u32{.{ 0, 0 }} ** 8,
        vp9_depth: u8 = 8,
        /// VP8: what it keeps across frames (references, probabilities),
        /// and the frame being read
        vp8: vp8r.State = .{},
        vp8_frame: vp8r.Frame = .{},
        /// pictures decoded, failed
        decoded: u64 = 0,
        errors: u64 = 0,
        last_status: u32 = 0,

        pub fn init(self: *Self, drv: *D, codec: Codec) Status {
            self.* = .{ .drv = drv, .codec = codec };
            return switch (codec) {
                .h264, .vp8, .vp9 => .ok,
                else => .unsupported,
            };
        }

        // ── Surfaces ─────────────────────────────────────────────────────

        fn indexOf(self: *const Self, surface: u32) ?usize {
            for (self.surfaces[0..self.count], 0..) |s, i| if (s == surface) return i;
            return null;
        }

        fn takeSurface(ctx: *anyopaque) ?u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |i| {
                if (!self.held[i] and !self.queued[i]) {
                    self.held[i] = true;
                    return self.surfaces[i];
                }
            }
            return null;
        }

        fn released(ctx: *anyopaque, surface: u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const i = self.indexOf(surface) orelse return;
            self.held[i] = false;
        }

        fn output(ctx: *anyopaque, p: *const h264.Pic) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const i = self.indexOf(p.surface) orelse return;
            self.queued[i] = true;
            const o = Out{ .surface = p.surface, .pts = p.pts, .duration = p.duration, .visible = self.pic.visible, .depth = self.depth };
            if (self.q_len < QUEUE) {
                self.queue[(self.q_head + self.q_len) % QUEUE] = o;
                self.q_len += 1;
            } else if (self.o_len < MAX_SURFACES) {
                self.overflow[self.o_len] = o;
                self.o_len += 1;
            }
        }

        fn cb(self: *Self) h264.Callbacks {
            return .{ .ctx = self, .surface = takeSurface, .output = output, .released = released };
        }

        fn freeSurfaces(self: *const Self) u32 {
            var n: u32 = 0;
            for (0..self.count) |i| {
                if (!self.held[i] and !self.queued[i]) n += 1;
            }
            return n;
        }

        fn teardown(self: *Self) void {
            if (self.image != 0) _ = self.drv.destroyImage(self.image);
            if (self.context != 0) _ = self.drv.destroyContext(self.context);
            if (self.count > 0) _ = self.drv.destroySurfaces(self.surfaces[0..self.count]);
            if (self.config != 0) _ = self.drv.destroyConfig(self.config);
            self.image = 0;
            self.context = 0;
            self.config = 0;
            self.count = 0;
            self.held = [_]bool{false} ** MAX_SURFACES;
            self.queued = [_]bool{false} ** MAX_SURFACES;
        }

        /// Surfaces, a context and an image for a sequence of this size.
        fn setup(self: *Self, profile: va.Profile, width: u32, height: u32, depth: u8, dpb: u32) Status {
            self.teardown();
            var cfg: u32 = 0;
            if (self.drv.createConfig(profile, va.ENTRYPOINT_VLD, &.{}, &cfg) != va.SUCCESS) return .unsupported;
            self.config = cfg;
            const n = @min(dpb + 2 + QUEUE / 2, MAX_SURFACES);
            const fmt: u32 = if (depth > 8) va.RT_FORMAT_YUV420_10 else va.RT_FORMAT_YUV420;
            if (self.drv.createSurfaces(fmt, width, height, self.surfaces[0..n], &.{}) != va.SUCCESS) {
                self.teardown();
                return .failed;
            }
            self.count = n;
            var ctx: u32 = 0;
            if (self.drv.createContext(cfg, width, height, &ctx) != va.SUCCESS) {
                self.teardown();
                return .unsupported;
            }
            self.context = ctx;
            var im: va.Image = undefined;
            const f = if (depth > 8) va.P010_FORMAT else va.NV12_FORMAT;
            if (self.drv.createImage(&f, width, height, &im) != va.SUCCESS) {
                self.teardown();
                return .failed;
            }
            self.image = im.image_id;
            self.image_buf = im.buf;
            self.image_pitch = im.pitches[0];
            self.image_uv = im.offsets[1];
            self.width = width;
            self.height = height;
            self.depth = depth;
            return .ok;
        }

        // ── Input ────────────────────────────────────────────────────────

        /// One access unit (decode order). `.full`: call `next`/`read`
        /// until the queue is empty, then this again with the same bytes.
        pub fn push(self: *Self, au: []const u8, pts: i64, duration: i64) Status {
            return switch (self.codec) {
                .h264 => self.pushH264(au, pts, duration),
                .vp9 => self.pushVp9(au, pts, duration),
                .vp8 => self.pushVp8(au, pts, duration),
                else => .unsupported,
            };
        }

        fn pushH264(self: *Self, au: []const u8, pts: i64, duration: i64) Status {
            // (a picture needs a free surface; pictures that overflowed the
            // queue go first)
            if (self.o_len > 0) return .full;
            if (self.count > 0 and self.freeSurfaces() == 0) return .full;
            // The parameter sets first, so the surfaces fit the picture
            // (its size, depth and DPB) before the parser takes one.
            var it = h264.NalIter.init(au);
            var first: ?h264.SliceHeader = null;
            while (it.next()) |nal| {
                const t = nal[0] & 0x1f;
                if (t == h264.NAL_SPS) {
                    var sp: h264.Sps = .{};
                    h264.parseSps(nal, &sp) catch continue;
                    self.h.sps[sp.id] = sp;
                } else if (t == h264.NAL_PPS) {
                    var pp: h264.Pps = .{};
                    h264.parsePps(nal, &self.h.sps, &pp) catch continue;
                    self.h.pps[pp.id] = pp;
                } else if (t == h264.NAL_SLICE or t == h264.NAL_IDR) {
                    var hd: h264.SliceHeader = undefined;
                    h264.parseSlice(nal, &self.h.sps, &self.h.pps, &hd) catch |e| return switch (e) {
                        error.NoParameterSet => .more,
                        error.Unsupported => .unsupported,
                        else => .bad,
                    };
                    first = hd;
                    break;
                }
            }
            const hd = first orelse return .more;
            const sps = &self.h.sps[self.h.pps[hd.pps_id].sps_id];
            if (sps.chroma_format_idc != 1 or sps.bit_depth_luma != 8 or sps.bit_depth_chroma != 8) return .unsupported;
            const prof: va.Profile = switch (sps.profile_idc) {
                66 => va.PROFILE_H264_CONSTRAINED_BASELINE,
                77 => va.PROFILE_H264_MAIN,
                100 => va.PROFILE_H264_HIGH,
                else => return .unsupported,
            };
            const dpb = sps.dpbFrames();
            const want_n = @min(dpb + 2 + QUEUE / 2, MAX_SURFACES);
            if (self.count == 0 or sps.width() != self.width or sps.height() != self.height or want_n > self.count) {
                if (self.count > 0) {
                    // a new sequence: the old pictures out first
                    h264.drain(&self.h, self.cb());
                    if (self.q_len > 0 or self.o_len > 0) return .full;
                    h264.reset(&self.h, self.cb());
                }
                const st = self.setup(prof, sps.width(), sps.height(), 8, dpb);
                if (st != .ok) return st;
            }
            const got = h264.take(&self.h, au, pts, duration, self.cb(), &self.pic) catch |e| return switch (e) {
                error.Unsupported, error.Field => .unsupported,
                error.NoParameterSet => .more,
                else => .bad,
            };
            if (!got) return .more;
            if (self.decodeH264()) {
                h264.finish(&self.h, &self.pic, self.cb());
                self.decoded += 1;
                return .ok;
            }
            h264.abandon(&self.h, self.cb());
            self.errors += 1;
            return .failed;
        }

        // ── VP9 ──────────────────────────────────────────────────────────

        /// The surfaces the eight slots hold are held; the rest free.
        fn vp9Hold(self: *Self) void {
            for (0..self.count) |i| {
                self.held[i] = false;
                for (self.vp9_slots) |s| {
                    if (s == self.surfaces[i]) self.held[i] = true;
                }
            }
        }

        fn queueOut(self: *Self, surface: u32, pts: i64, duration: i64, w: u32, hgt: u32) void {
            const i = self.indexOf(surface) orelse return;
            self.queued[i] = true;
            const o = Out{ .surface = surface, .pts = pts, .duration = duration, .visible = .{ 0, 0, w, hgt }, .depth = self.depth };
            if (self.q_len < QUEUE) {
                self.queue[(self.q_head + self.q_len) % QUEUE] = o;
                self.q_len += 1;
            } else if (self.o_len < MAX_SURFACES) {
                self.overflow[self.o_len] = o;
                self.o_len += 1;
            }
        }

        fn pushVp9(self: *Self, au: []const u8, pts: i64, duration: i64) Status {
            if (self.o_len > 0) return .full;
            const frames = vp9r.Frames.of(au);
            if (frames.n == 0) return .more;
            // What the superframe needs: a surface for each frame decoded,
            // queue room for each shown; else output first.
            var decodes: u32 = 0;
            var shows: u32 = 0;
            {
                var at: usize = 0;
                for (frames.sizes[0..frames.n]) |sz| {
                    var hd: vp9r.Header = .{};
                    vp9r.parse(au[at..][0..sz], &self.vp9_sizes, self.vp9_depth, &hd) catch |e| return if (e == error.Unsupported) .unsupported else .bad;
                    at += sz;
                    if (hd.show_existing) {
                        shows += 1;
                        continue;
                    }
                    decodes += 1;
                    if (hd.show_frame) shows += 1;
                    // a key frame of a new size or depth: new surfaces
                    if (hd.key and (self.count == 0 or hd.width != self.width or hd.height != self.height or hd.bit_depth != self.depth)) {
                        if (hd.bit_depth != 8 and hd.bit_depth != 10) return .unsupported;
                        if (self.q_len > 0) return .full;
                        self.vp9_slots = [_]u32{vp9r.INVALID} ** 8;
                        const prof: va.Profile = if (hd.bit_depth == 10) va.PROFILE_VP9_PROFILE_2 else va.PROFILE_VP9_PROFILE_0;
                        const st = self.setup(prof, hd.width, hd.height, hd.bit_depth, 8);
                        if (st != .ok) return st;
                        self.vp9_depth = hd.bit_depth;
                    }
                }
            }
            if (self.count == 0) return .more; // (no key frame yet)
            if (self.q_len + shows > QUEUE or self.freeSurfaces() < decodes) return .full;
            var at: usize = 0;
            for (frames.sizes[0..frames.n]) |sz| {
                const frame = au[at..][0..sz];
                at += sz;
                var hd: vp9r.Header = .{};
                vp9r.parse(frame, &self.vp9_sizes, self.vp9_depth, &hd) catch return .bad;
                if (hd.show_existing) {
                    const s = self.vp9_slots[hd.existing_idx];
                    if (s == vp9r.INVALID) return .bad;
                    const sz2 = self.vp9_sizes[hd.existing_idx];
                    self.queueOut(s, pts, duration, sz2[0], sz2[1]);
                    continue;
                }
                if (hd.width != self.width or hd.height != self.height) return .unsupported; // (scaled references)
                // a free surface for it
                var target: u32 = 0;
                for (0..self.count) |i| {
                    if (!self.held[i] and !self.queued[i]) {
                        target = self.surfaces[i];
                        break;
                    }
                }
                if (target == 0) return .full;
                var pp = vp9r.pictureParams(&hd, &self.vp9_slots);
                var sp = vp9r.sliceParams(@intCast(frame.len));
                if (!self.decodeOne(target, std.mem.asBytes(&pp), @sizeOf(vav9.PictureParameterBufferVP9), std.mem.asBytes(&sp), @sizeOf(vav9.SliceParameterBufferVP9), frame)) {
                    self.errors += 1;
                    return .failed;
                }
                self.decoded += 1;
                for (0..8) |k| {
                    if (hd.refresh & (@as(u8, 1) << @intCast(k)) != 0) {
                        self.vp9_slots[k] = target;
                        self.vp9_sizes[k] = .{ hd.width, hd.height };
                    }
                }
                self.vp9Hold();
                if (hd.show_frame) self.queueOut(target, pts, duration, hd.width, hd.height);
            }
            return .ok;
        }

        /// One picture of a codec with one picture-parameter, one slice
        /// parameter and one slice data buffer (VP8, VP9).
        fn decodeOne(self: *Self, target: u32, pic: []const u8, pic_size: u32, slice: []const u8, slice_size: u32, data: []const u8) bool {
            const d = self.drv;
            if (d.beginPicture(self.context, target) != va.SUCCESS) return false;
            var ids: [3]u32 = undefined;
            var n: usize = 0;
            defer for (ids[0..n]) |id| {
                _ = d.destroyBuffer(id);
            };
            if (d.createBuffer(va.PICTURE_PARAMETER_BUFFER, pic_size, 1, pic.ptr, &ids[n]) != va.SUCCESS) return false;
            n += 1;
            if (d.createBuffer(va.SLICE_PARAMETER_BUFFER, slice_size, 1, slice.ptr, &ids[n]) != va.SUCCESS) return false;
            n += 1;
            if (d.createBuffer(va.SLICE_DATA_BUFFER, @intCast(data.len), 1, data.ptr, &ids[n]) != va.SUCCESS) return false;
            n += 1;
            if (d.renderPicture(self.context, ids[0..n]) != va.SUCCESS) return false;
            const st = d.endPicture(self.context);
            self.last_status = st;
            return st == va.SUCCESS;
        }

        // ── VP8 ──────────────────────────────────────────────────────────

        fn vp8Hold(self: *Self) void {
            const st = &self.vp8;
            for (0..self.count) |i| {
                const s = self.surfaces[i];
                self.held[i] = s == st.last or s == st.golden or s == st.altref;
            }
        }

        fn pushVp8(self: *Self, au: []const u8, pts: i64, duration: i64) Status {
            if (self.o_len > 0) return .full;
            const f = &self.vp8_frame;
            vp8r.read(&self.vp8, au, f) catch |e| return switch (e) {
                error.Unsupported => .unsupported,
                error.Corrupt => if (self.count == 0) .more else .bad,
                error.Truncated => .bad,
            };
            if (f.key and (self.count == 0 or f.width != self.width or f.height != self.height)) {
                if (self.q_len > 0) return .full;
                self.vp8 = .{};
                vp8r.read(&self.vp8, au, f) catch return .bad;
                const st = self.setup(vav8.PROFILE_VP8_VERSION0_3, f.width, f.height, 8, 3);
                if (st != .ok) return st;
            }
            if (self.count == 0) return .more;
            if (self.q_len >= QUEUE or self.freeSurfaces() == 0) return .full;
            var target: u32 = 0;
            for (0..self.count) |i| {
                if (!self.held[i] and !self.queued[i]) {
                    target = self.surfaces[i];
                    break;
                }
            }
            if (target == 0) return .full;
            const bufs = [_]Buf{
                .{ .kind = va.PICTURE_PARAMETER_BUFFER, .size = @sizeOf(vav8.PictureParameterBufferVP8), .data = std.mem.asBytes(&f.pic) },
                .{ .kind = vav8.PROBABILITY_BUFFER, .size = @sizeOf(vav8.ProbabilityDataBufferVP8), .data = std.mem.asBytes(&f.probs) },
                .{ .kind = va.IQ_MATRIX_BUFFER, .size = @sizeOf(vav8.IQMatrixBufferVP8), .data = std.mem.asBytes(&f.iq) },
                .{ .kind = va.SLICE_PARAMETER_BUFFER, .size = @sizeOf(vav8.SliceParameterBufferVP8), .data = std.mem.asBytes(&f.slice) },
                .{ .kind = va.SLICE_DATA_BUFFER, .size = @intCast(au.len - f.data_offset), .data = au[f.data_offset..] },
            };
            if (!self.decodeBufs(target, &bufs)) {
                self.errors += 1;
                return .failed;
            }
            self.decoded += 1;
            vp8r.commit(&self.vp8, f, target);
            self.vp8Hold();
            if (f.show) self.queueOut(target, pts, duration, f.width, f.height);
            return .ok;
        }

        const Buf = struct { kind: u32, size: u32, data: []const u8 };

        /// One picture from a list of VA buffers.
        fn decodeBufs(self: *Self, target: u32, bufs: []const Buf) bool {
            const d = self.drv;
            if (d.beginPicture(self.context, target) != va.SUCCESS) return false;
            var ids: [8]u32 = undefined;
            var n: usize = 0;
            defer for (ids[0..n]) |id| {
                _ = d.destroyBuffer(id);
            };
            for (bufs) |b| {
                if (d.createBuffer(b.kind, b.size, 1, b.data.ptr, &ids[n]) != va.SUCCESS) return false;
                n += 1;
            }
            if (d.renderPicture(self.context, ids[0..n]) != va.SUCCESS) return false;
            const st = d.endPicture(self.context);
            self.last_status = st;
            return st == va.SUCCESS;
        }

        fn decodeH264(self: *Self) bool {
            const d = self.drv;
            const p = &self.pic;
            if (d.beginPicture(self.context, p.surface) != va.SUCCESS) return false;
            var ids: [2 + 2 * h264.MAX_SLICES]u32 = undefined;
            var n: usize = 0;
            defer for (ids[0..n]) |id| {
                _ = d.destroyBuffer(id);
            };
            if (d.createBuffer(va.PICTURE_PARAMETER_BUFFER, @sizeOf(va.PictureParameterBufferH264), 1, &p.pic, &ids[n]) != va.SUCCESS) return false;
            n += 1;
            if (d.createBuffer(va.IQ_MATRIX_BUFFER, @sizeOf(va.IQMatrixBufferH264), 1, &p.iq, &ids[n]) != va.SUCCESS) return false;
            n += 1;
            for (0..p.count) |k| {
                if (d.createBuffer(va.SLICE_PARAMETER_BUFFER, @sizeOf(va.SliceParameterBufferH264), 1, &p.slices[k], &ids[n]) != va.SUCCESS) return false;
                n += 1;
                if (d.createBuffer(va.SLICE_DATA_BUFFER, @intCast(p.data[k].len), 1, p.data[k].ptr, &ids[n]) != va.SUCCESS) return false;
                n += 1;
            }
            if (d.renderPicture(self.context, ids[0..n]) != va.SUCCESS) return false;
            const st = d.endPicture(self.context);
            self.last_status = st;
            return st == va.SUCCESS;
        }

        /// End of stream: the pictures still waiting go to the queue (call
        /// `next` until it is empty; `.full` when the queue has no room
        /// yet: output, then drain again).
        pub fn drain(self: *Self) Status {
            if (self.o_len > 0) return .full;
            switch (self.codec) {
                .h264 => h264.drain(&self.h, self.cb()),
                else => {},
            }
            return if (self.o_len > 0) .full else .ok;
        }

        /// A seek: every picture dropped (decoding restarts at the next
        /// random access point).
        pub fn flush(self: *Self) void {
            self.q_len = 0;
            self.o_len = 0;
            self.queued = [_]bool{false} ** MAX_SURFACES;
            switch (self.codec) {
                .h264 => h264.reset(&self.h, self.cb()),
                .vp9 => {
                    // (decoding restarts at the next key frame)
                    self.vp9_slots = [_]u32{vp9r.INVALID} ** 8;
                    self.vp9Hold();
                },
                .vp8 => {
                    self.vp8.last = vp8r.INVALID;
                    self.vp8.golden = vp8r.INVALID;
                    self.vp8.altref = vp8r.INVALID;
                    self.vp8.have_key = false;
                    self.vp8Hold();
                },
                else => {},
            }
        }

        pub fn deinit(self: *Self) void {
            self.flush();
            self.teardown();
        }

        // ── Output ───────────────────────────────────────────────────────

        /// The next picture in display order, if one is ready.
        pub fn next(self: *const Self) ?Out {
            if (self.q_len == 0) return null;
            return self.queue[self.q_head];
        }

        /// Copies the next picture into `dst` and lets it go: the whole
        /// coded picture (`width` x `height`, the visible rectangle inside
        /// it as `Out.visible` says), luma rows `pitch` bytes apart, then
        /// chroma as `layout` says (NV12/P010: interleaved UV rows `pitch`
        /// apart; YV12: V then U, rows pitch / 2 apart), each plane right
        /// after the last one's `height` (or `height / 2`) rows, as Media
        /// Foundation lays out a frame. False when the copy failed (the
        /// picture is let go either way).
        pub fn read(self: *Self, dst: []u8, pitch: u32, layout: Layout) bool {
            const o = self.next() orelse return false;
            self.q_head = (self.q_head + 1) % QUEUE;
            self.q_len -= 1;
            defer self.release(o.surface);
            // (pictures that overflowed the queue move in)
            while (self.o_len > 0 and self.q_len < QUEUE) {
                self.queue[(self.q_head + self.q_len) % QUEUE] = self.overflow[0];
                self.q_len += 1;
                std.mem.copyForwards(Out, self.overflow[0 .. self.o_len - 1], self.overflow[1..self.o_len]);
                self.o_len -= 1;
            }
            return self.copyOut(o, dst, pitch, layout);
        }

        /// Lets the next picture go unread.
        pub fn skip(self: *Self) void {
            const o = self.next() orelse return;
            self.q_head = (self.q_head + 1) % QUEUE;
            self.q_len -= 1;
            self.release(o.surface);
        }

        fn release(self: *Self, surface: u32) void {
            const i = self.indexOf(surface) orelse return;
            self.queued[i] = false;
        }

        fn copyOut(self: *Self, o: Out, dst: []u8, pitch: u32, layout: Layout) bool {
            const d = self.drv;
            if (d.getImage(o.surface, 0, 0, self.width, self.height, self.image) != va.SUCCESS) return false;
            var mp: ?*anyopaque = null;
            if (d.mapBuffer(self.image_buf, &mp) != va.SUCCESS) return false;
            defer _ = d.unmapBuffer(self.image_buf);
            const src: [*]const u8 = @ptrCast(mp orelse return false);
            const sb: u32 = if (o.depth > 8) 2 else 1;
            const w = self.width;
            const h = self.height;
            const sp = self.image_pitch;
            const ch = h / 2;
            switch (layout) {
                .nv12, .p010 => {
                    if ((layout == .p010) != (sb == 2)) return false;
                    if (@as(u64, pitch) * (h + ch) > dst.len or pitch < w * sb) return false;
                    for (0..h) |r| @memcpy(dst[r * pitch ..][0 .. w * sb], src[r * sp ..][0 .. w * sb]);
                    const uv = dst[@as(usize, pitch) * h ..];
                    for (0..ch) |r| @memcpy(uv[r * pitch ..][0 .. w * sb], src[self.image_uv + r * sp ..][0 .. w * sb]);
                },
                .yv12 => {
                    if (sb != 1) return false;
                    const cp = pitch / 2;
                    const cw = w / 2;
                    if (@as(u64, pitch) * h + 2 * @as(u64, cp) * ch > dst.len or pitch < w) return false;
                    for (0..h) |r| @memcpy(dst[r * pitch ..][0..w], src[r * sp ..][0..w]);
                    const vplane = dst[@as(usize, pitch) * h ..];
                    const uplane = vplane[@as(usize, cp) * ch ..];
                    for (0..ch) |r| {
                        const row = src[self.image_uv + r * sp ..];
                        for (0..cw) |c| {
                            uplane[r * cp + c] = row[2 * c];
                            vplane[r * cp + c] = row[2 * c + 1];
                        }
                    }
                },
                _ => return false,
            }
            return true;
        }
    };
}
