//! @zpm/flv: FLV tags for H.264 video and AAC audio, the bodies RTMP
//! carries (video messages are type 9, audio 8, data 18) and the tags of an
//! .flv file around them. Also AMF0, the values RTMP's commands and FLV's
//! onMetaData are written in.
//!
//! Layer 0: pure computation, allocation-free. The caller owns every buffer.
//!
//!   video body: 0x17 (key) or 0x27, AVCPacketType (0 config, 1 pictures),
//!               composition time (s24, 0: no B pictures), then the
//!               AVCDecoderConfigurationRecord or the picture's NAL units,
//!               each behind its 4-byte length (AVCC)
//!   audio body: 0xAF (AAC), AACPacketType (0 config, 1 frame), then the
//!               AudioSpecificConfig or one raw AAC frame
//!   file tag:   type, size (u24), time (u24 + u8 high), stream 0 (u24),
//!               the body, then the tag's whole size (u32)

const std = @import("std");

pub const Error = error{
    /// The output slice cannot hold what is asked.
    OutputTooSmall,
    /// The stream has not shown an SPS and a PPS yet.
    NoParameterSets,
    /// A parameter set is longer than this module keeps.
    ParameterSetTooLong,
};

pub const AUDIO: u8 = 8;
pub const VIDEO: u8 = 9;
pub const SCRIPT: u8 = 18;
pub const FILE_HEADER_BYTES: usize = 13;
pub const TAG_HEADER_BYTES: usize = 11;

/// NAL unit types this module looks at.
const NAL_IDR: u8 = 5;
const NAL_SPS: u8 = 7;
const NAL_PPS: u8 = 8;
const NAL_AUD: u8 = 9;

/// The NAL units of an Annex B stream (start codes 00 00 01 and
/// 00 00 00 01), without their start codes.
pub const Units = struct {
    data: []const u8,
    at: usize = 0,

    pub fn next(u: *Units) ?[]const u8 {
        const begin = startAfter(u.data, u.at) orelse return null;
        const end_code = startCode(u.data, begin);
        var end = if (end_code) |c| c else u.data.len;
        // (a 4-byte start code's leading zero is not the unit's)
        while (end > begin and end_code != null and u.data[end - 1] == 0) end -= 1;
        u.at = end_code orelse u.data.len;
        return u.data[begin..end];
    }
};

/// The first byte after the next start code at or after `from`.
fn startAfter(data: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 3 <= data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) return i + 3;
    }
    return null;
}

/// Where the next start code (00 00 01) begins after `from`, if any.
fn startCode(data: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 3 <= data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) return i;
    }
    return null;
}

/// What an H.264 stream's decoder needs first: its SPS and PPS.
pub const Avc = struct {
    sps: [256]u8 = undefined,
    sps_len: usize = 0,
    pps: [128]u8 = undefined,
    pps_len: usize = 0,

    /// Keeps the parameter sets in `annexb`; true when they are new or
    /// changed (a new sequence header is due).
    pub fn learn(a: *Avc, annexb: []const u8) Error!bool {
        var changed = false;
        var units = Units{ .data = annexb };
        while (units.next()) |nal| {
            if (nal.len == 0) continue;
            const kind = nal[0] & 0x1f;
            if (kind == NAL_SPS) {
                if (nal.len > a.sps.len) return error.ParameterSetTooLong;
                if (a.sps_len != nal.len or !std.mem.eql(u8, a.sps[0..nal.len], nal)) changed = true;
                @memcpy(a.sps[0..nal.len], nal);
                a.sps_len = nal.len;
            } else if (kind == NAL_PPS) {
                if (nal.len > a.pps.len) return error.ParameterSetTooLong;
                if (a.pps_len != nal.len or !std.mem.eql(u8, a.pps[0..nal.len], nal)) changed = true;
                @memcpy(a.pps[0..nal.len], nal);
                a.pps_len = nal.len;
            }
        }
        return changed;
    }

    /// The video body of the sequence header: the
    /// AVCDecoderConfigurationRecord (ISO/IEC 14496-15), 4-byte lengths.
    pub fn sequenceHeader(a: *const Avc, out: []u8) Error![]u8 {
        if (a.sps_len < 4 or a.pps_len == 0) return error.NoParameterSets;
        const total = 5 + 6 + 2 + a.sps_len + 1 + 2 + a.pps_len;
        if (out.len < total) return error.OutputTooSmall;
        var w = Put{ .buf = out };
        w.bytes(&.{ 0x17, 0, 0, 0, 0 });
        w.byte(1); // configurationVersion
        w.bytes(a.sps[1..4]); // profile, compatibility, level
        w.byte(0xff); // lengthSizeMinusOne 3
        w.byte(0xe1); // one SPS
        w.u16be(@intCast(a.sps_len));
        w.bytes(a.sps[0..a.sps_len]);
        w.byte(1); // one PPS
        w.u16be(@intCast(a.pps_len));
        w.bytes(a.pps[0..a.pps_len]);
        return out[0..w.at];
    }
};

/// The video body of one picture from its Annex B bytes: its NAL units
/// with 4-byte lengths, without parameter sets or delimiters (those go in
/// the sequence header). `key`: an IDR picture.
pub fn videoPicture(annexb: []const u8, key: bool, out: []u8) Error![]u8 {
    if (out.len < 5) return error.OutputTooSmall;
    var w = Put{ .buf = out };
    w.bytes(&.{ if (key) 0x17 else 0x27, 1, 0, 0, 0 });
    var units = Units{ .data = annexb };
    while (units.next()) |nal| {
        if (nal.len == 0) continue;
        const kind = nal[0] & 0x1f;
        if (kind == NAL_SPS or kind == NAL_PPS or kind == NAL_AUD) continue;
        if (w.at + 4 + nal.len > out.len) return error.OutputTooSmall;
        w.u32be(@intCast(nal.len));
        w.bytes(nal);
    }
    return out[0..w.at];
}

/// True when the Annex B picture holds an IDR slice.
pub fn isKey(annexb: []const u8) bool {
    var units = Units{ .data = annexb };
    while (units.next()) |nal| if (nal.len > 0 and nal[0] & 0x1f == NAL_IDR) return true;
    return false;
}

/// The audio body of AAC's sequence header (its AudioSpecificConfig).
pub fn aacSequenceHeader(config: []const u8, out: []u8) Error![]u8 {
    if (out.len < 2 + config.len) return error.OutputTooSmall;
    out[0] = 0xaf;
    out[1] = 0;
    @memcpy(out[2..][0..config.len], config);
    return out[0 .. 2 + config.len];
}

/// The audio body of one raw AAC frame.
pub fn aacFrame(frame: []const u8, out: []u8) Error![]u8 {
    if (out.len < 2 + frame.len) return error.OutputTooSmall;
    out[0] = 0xaf;
    out[1] = 1;
    @memcpy(out[2..][0..frame.len], frame);
    return out[0 .. 2 + frame.len];
}

/// An .flv file's 9-byte header (audio and video) and the first
/// PreviousTagSize (0).
pub fn fileHeader(out: *[FILE_HEADER_BYTES]u8) void {
    out.* = .{ 'F', 'L', 'V', 1, 5, 0, 0, 0, 9, 0, 0, 0, 0 };
}

/// One file tag around `body`.
pub fn tag(kind: u8, time_ms: u32, body: []const u8, out: []u8) Error![]u8 {
    const total = TAG_HEADER_BYTES + body.len + 4;
    if (out.len < total) return error.OutputTooSmall;
    var w = Put{ .buf = out };
    w.byte(kind);
    w.u24be(@intCast(body.len));
    w.u24be(@truncate(time_ms));
    w.byte(@intCast(time_ms >> 24));
    w.u24be(0);
    w.bytes(body);
    w.u32be(@intCast(TAG_HEADER_BYTES + body.len));
    return out[0..total];
}

/// What onMetaData tells a player about the stream.
pub const Meta = struct {
    width: u32,
    height: u32,
    frame_rate: f64,
    video_kbps: f64,
    audio_kbps: f64,
    sample_rate: u32 = 48_000,
    stereo: bool = true,
    encoder: []const u8 = "Galaxy",
};

/// The data body of onMetaData. RTMP publishers put "@setDataFrame" first
/// (`for_rtmp`); an .flv file's script tag does not.
pub fn metaData(m: Meta, for_rtmp: bool, out: []u8) Error![]u8 {
    var a = Amf{ .buf = out };
    if (for_rtmp) try a.string("@setDataFrame");
    try a.string("onMetaData");
    try a.ecmaArray(11);
    try a.key("duration");
    try a.number(0);
    try a.key("width");
    try a.number(@floatFromInt(m.width));
    try a.key("height");
    try a.number(@floatFromInt(m.height));
    try a.key("framerate");
    try a.number(m.frame_rate);
    try a.key("videocodecid");
    try a.number(7);
    try a.key("videodatarate");
    try a.number(m.video_kbps);
    try a.key("audiocodecid");
    try a.number(10);
    try a.key("audiodatarate");
    try a.number(m.audio_kbps);
    try a.key("audiosamplerate");
    try a.number(@floatFromInt(m.sample_rate));
    try a.key("stereo");
    try a.boolean(m.stereo);
    try a.key("encoder");
    try a.string(m.encoder);
    try a.end();
    return out[0..a.at];
}

/// AMF0 values, written big-endian into a caller's buffer.
pub const Amf = struct {
    buf: []u8,
    at: usize = 0,

    fn room(a: *Amf, n: usize) Error!void {
        if (a.at + n > a.buf.len) return error.OutputTooSmall;
    }

    pub fn number(a: *Amf, v: f64) Error!void {
        try a.room(9);
        a.buf[a.at] = 0;
        std.mem.writeInt(u64, a.buf[a.at + 1 ..][0..8], @bitCast(v), .big);
        a.at += 9;
    }

    pub fn boolean(a: *Amf, v: bool) Error!void {
        try a.room(2);
        a.buf[a.at] = 1;
        a.buf[a.at + 1] = @intFromBool(v);
        a.at += 2;
    }

    pub fn string(a: *Amf, s: []const u8) Error!void {
        try a.room(1);
        a.buf[a.at] = 2;
        a.at += 1;
        try a.key(s);
    }

    pub fn nul(a: *Amf) Error!void {
        try a.room(1);
        a.buf[a.at] = 5;
        a.at += 1;
    }

    pub fn object(a: *Amf) Error!void {
        try a.room(1);
        a.buf[a.at] = 3;
        a.at += 1;
    }

    pub fn ecmaArray(a: *Amf, count: u32) Error!void {
        try a.room(5);
        a.buf[a.at] = 8;
        std.mem.writeInt(u32, a.buf[a.at + 1 ..][0..4], count, .big);
        a.at += 5;
    }

    /// A property name (an object's or array's key: no type marker).
    pub fn key(a: *Amf, s: []const u8) Error!void {
        try a.room(2 + s.len);
        std.mem.writeInt(u16, a.buf[a.at..][0..2], @intCast(s.len), .big);
        @memcpy(a.buf[a.at + 2 ..][0..s.len], s);
        a.at += 2 + s.len;
    }

    /// Closes an object or ECMA array.
    pub fn end(a: *Amf) Error!void {
        try a.room(3);
        a.buf[a.at..][0..3].* = .{ 0, 0, 9 };
        a.at += 3;
    }
};

/// AMF0 values read back: what an RTMP client needs from a server's
/// _result and onStatus (strings, numbers, and objects' string values).
pub const AmfReader = struct {
    data: []const u8,
    at: usize = 0,

    pub const Value = union(enum) {
        number: f64,
        boolean: bool,
        string: []const u8,
        /// An object or ECMA array: its properties follow (`property`).
        object,
        nul,
        undefined_,
    };

    pub fn value(r: *AmfReader) ?Value {
        if (r.at >= r.data.len) return null;
        const marker = r.data[r.at];
        r.at += 1;
        switch (marker) {
            0 => {
                if (r.at + 8 > r.data.len) return null;
                const v: f64 = @bitCast(std.mem.readInt(u64, r.data[r.at..][0..8], .big));
                r.at += 8;
                return .{ .number = v };
            },
            1 => {
                if (r.at >= r.data.len) return null;
                r.at += 1;
                return .{ .boolean = r.data[r.at - 1] != 0 };
            },
            2 => return .{ .string = r.name() orelse return null },
            3 => return .object,
            5 => return .nul,
            6 => return .undefined_,
            8 => {
                if (r.at + 4 > r.data.len) return null;
                r.at += 4;
                return .object;
            },
            else => return null,
        }
    }

    /// The next property name of an open object; null at its end marker.
    pub fn property(r: *AmfReader) ?[]const u8 {
        if (r.at + 3 <= r.data.len and r.data[r.at] == 0 and r.data[r.at + 1] == 0 and r.data[r.at + 2] == 9) {
            r.at += 3;
            return null;
        }
        return r.name();
    }

    /// Skips a value just read (an object: all its properties).
    pub fn skip(r: *AmfReader, v: Value) bool {
        if (v != .object) return true;
        while (r.property()) |_| {
            const inner = r.value() orelse return false;
            if (!r.skip(inner)) return false;
        }
        return true;
    }

    /// The string property `want` of the object just opened (the rest of
    /// the object is read past).
    pub fn find(r: *AmfReader, want: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        while (r.property()) |p| {
            const v = r.value() orelse return found;
            if (v == .string and std.mem.eql(u8, p, want)) found = v.string;
            if (!r.skip(v)) return found;
        }
        return found;
    }

    fn name(r: *AmfReader) ?[]const u8 {
        if (r.at + 2 > r.data.len) return null;
        const n = std.mem.readInt(u16, r.data[r.at..][0..2], .big);
        if (r.at + 2 + n > r.data.len) return null;
        const s = r.data[r.at + 2 ..][0..n];
        r.at += 2 + n;
        return s;
    }
};

/// Big-endian writes; callers check the room first.
const Put = struct {
    buf: []u8,
    at: usize = 0,

    fn byte(p: *Put, v: u8) void {
        p.buf[p.at] = v;
        p.at += 1;
    }
    fn bytes(p: *Put, v: []const u8) void {
        @memcpy(p.buf[p.at..][0..v.len], v);
        p.at += v.len;
    }
    fn u16be(p: *Put, v: u16) void {
        std.mem.writeInt(u16, p.buf[p.at..][0..2], v, .big);
        p.at += 2;
    }
    fn u24be(p: *Put, v: u24) void {
        std.mem.writeInt(u24, p.buf[p.at..][0..3], v, .big);
        p.at += 3;
    }
    fn u32be(p: *Put, v: u32) void {
        std.mem.writeInt(u32, p.buf[p.at..][0..4], v, .big);
        p.at += 4;
    }
};

const testing = std.testing;

test "Annex B splits into NAL units with either start code" {
    const s = [_]u8{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 0 };
    var u = Units{ .data = &s };
    try testing.expectEqualSlices(u8, &.{ 0x67, 1, 2 }, u.next().?);
    try testing.expectEqualSlices(u8, &.{ 0x68, 3 }, u.next().?);
    try testing.expectEqualSlices(u8, &.{ 0x65, 4, 5, 0 }, u.next().?);
    try testing.expect(u.next() == null);
    try testing.expect(isKey(&s));
}

test "the sequence header is an AVCDecoderConfigurationRecord; pictures are AVCC" {
    const s = [_]u8{ 0, 0, 0, 1, 0x09, 0xf0, 0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1f, 0xac, 0, 0, 0, 1, 0x68, 0xee, 0x3c, 0x80, 0, 0, 1, 0x65, 0x88, 0x84 };
    var a = Avc{};
    try testing.expect(try a.learn(&s));
    try testing.expect(!try a.learn(&s));
    var out: [64]u8 = undefined;
    const h = try a.sequenceHeader(&out);
    try testing.expectEqualSlices(u8, &.{ 0x17, 0, 0, 0, 0, 1, 0x64, 0x00, 0x1f, 0xff, 0xe1, 0, 5, 0x67, 0x64, 0x00, 0x1f, 0xac, 1, 0, 4, 0x68, 0xee, 0x3c, 0x80 }, h);
    var pic: [64]u8 = undefined;
    const p = try videoPicture(&s, true, &pic);
    try testing.expectEqualSlices(u8, &.{ 0x17, 1, 0, 0, 0, 0, 0, 0, 3, 0x65, 0x88, 0x84 }, p);
}

test "a file tag: header, body, previous tag size" {
    var out: [32]u8 = undefined;
    const t = try tag(AUDIO, 0x01020304, &.{ 0xaf, 1, 0x21 }, &out);
    try testing.expectEqualSlices(u8, &.{ 8, 0, 0, 3, 0x02, 0x03, 0x04, 0x01, 0, 0, 0, 0xaf, 1, 0x21, 0, 0, 0, 14 }, t);
}

test "AMF0 written and read back" {
    var buf: [256]u8 = undefined;
    var a = Amf{ .buf = &buf };
    try a.string("_result");
    try a.number(4);
    try a.nul();
    try a.object();
    try a.key("level");
    try a.string("status");
    try a.key("code");
    try a.string("NetStream.Publish.Start");
    try a.key("n");
    try a.number(1.5);
    try a.end();
    var r = AmfReader{ .data = buf[0..a.at] };
    try testing.expectEqualStrings("_result", r.value().?.string);
    try testing.expectEqual(@as(f64, 4), r.value().?.number);
    try testing.expect(r.value().? == .nul);
    try testing.expect(r.value().? == .object);
    try testing.expectEqualStrings("NetStream.Publish.Start", r.find("code").?);
    try testing.expect(r.value() == null);
    var mbuf: [512]u8 = undefined;
    const meta = try metaData(.{ .width = 1280, .height = 720, .frame_rate = 30, .video_kbps = 4500, .audio_kbps = 160 }, true, &mbuf);
    var m = AmfReader{ .data = meta };
    try testing.expectEqualStrings("@setDataFrame", m.value().?.string);
    try testing.expectEqualStrings("onMetaData", m.value().?.string);
    try testing.expect(m.value().? == .object);
    try testing.expectEqualStrings("Galaxy", m.find("encoder").?);
}
