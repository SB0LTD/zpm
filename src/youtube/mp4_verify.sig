// Bounded ISO BMFF inspection for downloaded MP4 tracks. Caller-owned random
// reads avoid buffering the movie or allocating its sample tables.
pub const Reader = struct {
    ctx: *anyopaque,
    size: u64,
    read_at: *const fn (*anyopaque, u64, []u8) bool,
};
pub const Info = struct {
    valid: bool = false,
    tracks: u32 = 0,
    video_tracks: u32 = 0,
    audio_tracks: u32 = 0,
    h264_tracks: u32 = 0,
    aac_tracks: u32 = 0,
    media_bytes: u64 = 0,
};
const Box = struct { kind: u32, payload: u64, end: u64 };
const Track = struct { handler: u32 = 0, h264: bool = false, aac: bool = false };

fn tag(comptime s: *const [4]u8) u32 { return be32(s); }
fn be32(s: []const u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | s[3];
}
fn be64(s: []const u8) u64 { return (@as(u64, be32(s[0..4])) << 32) | be32(s[4..8]); }
fn read(r: Reader, at: u64, out: []u8) bool {
    return at <= r.size and out.len <= r.size - at and r.read_at(r.ctx, at, out);
}
fn box(r: Reader, at: u64, limit: u64) ?Box {
    if (at > limit or limit - at < 8) return null;
    var h: [16]u8 = undefined;
    if (!read(r, at, h[0..8])) return null;
    var size: u64 = be32(h[0..4]);
    var header: u64 = 8;
    if (size == 1) {
        if (limit - at < 16 or !read(r, at + 8, h[8..16])) return null;
        size = be64(h[8..16]); header = 16;
    } else if (size == 0) size = limit - at;
    if (size < header or size > limit - at) return null;
    return .{ .kind = be32(h[4..8]), .payload = at + header, .end = at + size };
}

pub fn inspect(r: Reader) Info {
    var info = Info{};
    var at: u64 = 0;
    var ftyp = false;
    var moov = false;
    var count: usize = 0;
    while (at < r.size) {
        count += 1; if (count > 4096) return info;
        const b = box(r, at, r.size) orelse return info;
        if (b.kind == tag("ftyp")) {
            if (ftyp or b.end - b.payload < 8) return info;
            ftyp = true;
        } else if (b.kind == tag("moov")) {
            if (moov or !movie(r, b, &info)) return info;
            moov = true;
        } else if (b.kind == tag("mdat")) info.media_bytes += b.end - b.payload;
        at = b.end;
    }
    info.valid = ftyp and moov and info.tracks > 0 and info.media_bytes > 0;
    return info;
}

fn movie(r: Reader, parent: Box, info: *Info) bool {
    var at = parent.payload;
    var count: usize = 0;
    while (at < parent.end) {
        count += 1; if (count > 4096) return false;
        const b = box(r, at, parent.end) orelse return false;
        if (b.kind == tag("trak")) {
            if (info.tracks >= 32) return false;
            var track = Track{};
            if (!trackChildren(r, b.payload, b.end, 0, &track)) return false;
            info.tracks += 1;
            if (track.handler == tag("vide")) {
                info.video_tracks += 1;
                if (track.h264) info.h264_tracks += 1;
            } else if (track.handler == tag("soun")) {
                info.audio_tracks += 1;
                if (track.aac) info.aac_tracks += 1;
            }
        }
        at = b.end;
    }
    return true;
}
fn trackChildren(r: Reader, start: u64, end: u64, depth: usize, t: *Track) bool {
    if (depth > 4) return false;
    var at = start;
    var count: usize = 0;
    while (at < end) {
        count += 1; if (count > 4096) return false;
        const b = box(r, at, end) orelse return false;
        if (b.kind == tag("mdia") or b.kind == tag("minf") or b.kind == tag("stbl")) {
            if (!trackChildren(r, b.payload, b.end, depth + 1, t)) return false;
        } else if (b.kind == tag("hdlr")) {
            var h: [12]u8 = undefined;
            if (b.end - b.payload < 24 or !read(r, b.payload, &h)) return false;
            t.handler = be32(h[8..12]);
        } else if (b.kind == tag("stsd")) {
            if (!descriptions(r, b, t)) return false;
        }
        at = b.end;
    }
    return true;
}
fn descriptions(r: Reader, parent: Box, t: *Track) bool {
    var h: [8]u8 = undefined;
    if (parent.end - parent.payload < h.len or !read(r, parent.payload, &h)) return false;
    const entries = be32(h[4..8]);
    if (entries > 32) return false;
    var at = parent.payload + 8;
    var i: u32 = 0;
    while (i < entries) : (i += 1) {
        const b = box(r, at, parent.end) orelse return false;
        if (b.kind == tag("avc1") or b.kind == tag("avc3")) {
            if (b.end - b.payload < 78 or !sampleChildren(r, b.payload + 78, b.end, t, true)) return false;
        } else if (b.kind == tag("mp4a")) {
            if (b.end - b.payload < 28 or !sampleChildren(r, b.payload + 28, b.end, t, false)) return false;
        }
        at = b.end;
    }
    return at == parent.end;
}
fn sampleChildren(r: Reader, start: u64, end: u64, t: *Track, video: bool) bool {
    var at = start;
    var count: usize = 0;
    while (at < end) {
        count += 1; if (count > 128) return false;
        const b = box(r, at, end) orelse return false;
        if (video and b.kind == tag("avcC")) {
            if (!avcConfig(r, b)) return false;
            t.h264 = true;
        } else if (!video and b.kind == tag("esds")) {
            if (b.end - b.payload < 4) return false;
            if (!descriptors(r, b.payload + 4, b.end, 0, &t.aac)) return false;
        }
        at = b.end;
    }
    return true;
}
fn avcConfig(r: Reader, b: Box) bool {
    var h: [6]u8 = undefined;
    if (b.end - b.payload < 7 or !read(r, b.payload, &h) or h[0] != 1 or h[5] & 31 == 0) return false;
    var at = b.payload + 6;
    var n: usize = 0;
    while (n < h[5] & 31) : (n += 1) {
        if (!nal(r, &at, b.end, 7)) return false;
    }
    if (at >= b.end or !read(r, at, h[0..1]) or h[0] == 0) return false;
    at += 1; const pps = h[0]; n = 0;
    while (n < pps) : (n += 1) if (!nal(r, &at, b.end, 8)) return false;
    return true;
}
fn nal(r: Reader, at: *u64, end: u64, kind: u8) bool {
    var h: [2]u8 = undefined;
    if (end - at.* < 2 or !read(r, at.*, &h)) return false;
    const size = (@as(u16, h[0]) << 8) | h[1]; at.* += 2;
    if (size == 0 or size > end - at.* or !read(r, at.*, h[0..1]) or h[0] & 31 != kind) return false;
    at.* += size;
    return true;
}
fn descriptors(r: Reader, start: u64, end: u64, depth: usize, aac: *bool) bool {
    if (depth > 4) return false;
    var at = start;
    var count: usize = 0;
    while (at < end) {
        count += 1; if (count > 128) return false;
        var h: [13]u8 = undefined;
        if (!read(r, at, h[0..1])) return false;
        const kind = h[0]; at += 1;
        var size: u64 = 0;
        var n: usize = 0;
        while (true) {
            if (at >= end or n >= 4 or !read(r, at, h[0..1])) return false;
            at += 1; n += 1; size = (size << 7) | (h[0] & 127);
            if (h[0] & 128 == 0) break;
        }
        if (size > end - at) return false;
        const next = at + size;
        if (kind == 3) {
            if (size < 3 or !read(r, at, h[0..3])) return false;
            const flags = h[2]; at += 3;
            if (flags & 128 != 0) { if (next - at < 2) return false; at += 2; }
            if (flags & 64 != 0) {
                if (at >= next or !read(r, at, h[0..1])) return false;
                at += 1; if (h[0] > next - at) return false; at += h[0];
            }
            if (flags & 32 != 0) { if (next - at < 2) return false; at += 2; }
            if (!descriptors(r, at, next, depth + 1, aac)) return false;
        } else if (kind == 4) {
            if (size < 13 or !read(r, at, &h)) return false;
            const object_aac = h[0] == 0x40 or h[0] == 0x66 or h[0] == 0x67 or h[0] == 0x68;
            var specific_aac = false;
            if (!descriptors(r, at + 13, next, depth + 1, &specific_aac)) return false;
            if (object_aac and specific_aac) aac.* = true;
        } else if (kind == 5) {
            if (size < 2 or !read(r, at, h[0..2])) return false;
            const audio_type = h[0] >> 3;
            if ((audio_type >= 1 and audio_type <= 6) or audio_type == 17 or audio_type == 19 or audio_type == 20 or audio_type == 23 or audio_type == 29) aac.* = true;
        }
        at = next;
    }
    return true;
}
