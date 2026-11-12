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
        /// pictures decoded, failed
        decoded: u64 = 0,
        errors: u64 = 0,
        last_status: u32 = 0,

        pub fn init(self: *Self, drv: *D, codec: Codec) Status {
            self.* = .{ .drv = drv, .codec = codec };
            return switch (codec) {
                .h264 => .ok,
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

        /// Copies the next picture into `dst` (`pitch`: bytes between luma
        /// rows; its rows `height` of the visible rectangle; chroma as
        /// `layout` says) and lets it go. Returns false when the copy
        /// failed (the picture is let go either way).
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
            const vx = o.visible[0];
            const vy = o.visible[1];
            const w = o.visible[2];
            const h = o.visible[3];
            const sp = self.image_pitch;
            const ch = (h + 1) / 2;
            const cw = (w + 1) / 2;
            switch (layout) {
                .nv12, .p010 => {
                    if ((layout == .p010) != (sb == 2)) return false;
                    if (@as(u64, pitch) * (h + ch) > dst.len or pitch < w * sb) return false;
                    for (0..h) |r| @memcpy(dst[r * pitch ..][0 .. w * sb], src[(vy + r) * sp + vx * sb ..][0 .. w * sb]);
                    const uv = dst[@as(usize, pitch) * h ..];
                    for (0..ch) |r| @memcpy(uv[r * pitch ..][0 .. 2 * cw * sb], src[self.image_uv + (vy / 2 + r) * sp + (vx & ~@as(u32, 1)) * sb ..][0 .. 2 * cw * sb]);
                },
                .yv12 => {
                    if (sb != 1) return false;
                    const cp = pitch / 2;
                    if (@as(u64, pitch) * h + 2 * @as(u64, cp) * ch > dst.len or pitch < w) return false;
                    for (0..h) |r| @memcpy(dst[r * pitch ..][0..w], src[(vy + r) * sp + vx ..][0..w]);
                    const vplane = dst[@as(usize, pitch) * h ..];
                    const uplane = vplane[@as(usize, cp) * ch ..];
                    for (0..ch) |r| {
                        const row = src[self.image_uv + (vy / 2 + r) * sp + (vx & ~@as(u32, 1)) ..];
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
