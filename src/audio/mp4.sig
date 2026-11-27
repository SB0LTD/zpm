//! Strict, zero-allocation fragmented MP4 AAC packet reader.
//! Immutable input and packet slices borrow the caller's mapped file. A single
//! AAC-LC mono/stereo track is selected from structured sample descriptions;
//! payload strings are never searched to guess codecs or sample rates.
const std = @import("std");
pub const Error = error{ InvalidContainer, UnexpectedEof, UnsupportedContainer, UnsupportedCodec, UnsupportedProfile, UnsupportedChannels, InvalidConfiguration, InvalidTrack, InvalidFragment, InvalidSample, InvalidDuration, TooManyRuns, ArithmeticOverflow };

pub const Config = struct { sample_rate: u32, channels: u8, object_type: u8, frequency_index: u8 };
pub const Packet = struct { bytes: []const u8, dts: u64, duration: u32, index: u64 };

pub const Demux = struct {
    bytes: []const u8,
    config: Config = undefined,
    timescale: u32 = 0,
    /// Track decode duration in timescale units; zero means unspecified/live.
    duration: u64 = 0,
    track_id: u32 = 0,
    position: usize = 0,
    packet_index: u64 = 0,
    next_dts: u64 = 0,
    runs: [32]Run = undefined,
    run_count: usize = 0,
    run_index: usize = 0,
    default_duration: u32 = 0,
    default_size: u32 = 0,

    pub fn open(bytes: []const u8) Error!Demux {
        var result: Demux = .{ .bytes = bytes };
        var found_ftyp = false;
        var found_moov = false;
        var at: usize = 0;
        while (at < bytes.len) {
            const box = try Box.read(bytes, at, bytes.len);
            if (box.is("ftyp")) {
                if (found_ftyp or box.payload.len < 8) return error.InvalidContainer;
                found_ftyp = true;
            } else if (box.is("moov")) {
                if (found_moov) return error.InvalidContainer;
                try result.movie(box);
                found_moov = true;
                result.position = box.end;
            } else if (box.is("moof")) break;
            at = box.end;
        }
        if (!found_ftyp or !found_moov or result.track_id == 0) return error.InvalidContainer;
        return result;
    }

    pub fn next(self: *Demux) Error!?Packet {
        while (true) {
            if (self.run_index < self.run_count) {
                var run = &self.runs[self.run_index];
                if (run.index == run.count) {
                    self.run_index += 1;
                    continue;
                }
                var duration = run.default_duration;
                var size = run.default_size;
                if (run.flags & 0x100 != 0) duration = try run.word();
                if (run.flags & 0x200 != 0) size = try run.word();
                if (run.flags & 0x400 != 0) _ = try run.word();
                if (run.flags & 0x800 != 0) _ = try run.word();
                if (duration == 0 or size == 0 or size > 8192) return error.InvalidSample;
                if (run.offset < run.media_start or run.offset > run.media_end or size > run.media_end - run.offset)
                    return error.InvalidSample;
                const data = self.bytes[run.offset..][0..size];
                const packet: Packet = .{ .bytes = data, .dts = run.dts, .duration = duration, .index = self.packet_index };
                run.offset += size;
                run.dts = try add64(run.dts, duration);
                self.next_dts = run.dts;
                run.index += 1;
                self.packet_index += 1;
                return packet;
            }
            if (self.position == self.bytes.len) {
                if (self.duration != 0 and self.next_dts != self.duration) return error.InvalidDuration;
                return null;
            }
            const box = try Box.read(self.bytes, self.position, self.bytes.len);
            self.position = box.end;
            if (box.is("moof")) try self.fragment(box);
        }
    }

    fn movie(self: *Demux, parent: Box) Error!void {
        var children = parent.children();
        var fragmented = false;
        while (try children.next(self.bytes)) |box| {
            if (box.is("trak")) {
                var track: Track = .{};
                try track.parse(self.bytes, box, 0);
                if (track.audio) {
                    if (self.track_id != 0) return error.UnsupportedContainer;
                    if (track.id == 0 or track.timescale == 0 or track.config == null) return error.InvalidTrack;
                    self.track_id = track.id;
                    self.timescale = track.timescale;
                    self.config = track.config.?;
                    self.duration = track.duration;
                }
            } else if (box.is("mvex")) {
                fragmented = true;
            }
        }
        if (!fragmented) return error.UnsupportedContainer;
        if (self.track_id == 0) return error.InvalidTrack;
        if (self.timescale != self.config.sample_rate) return error.InvalidTrack;
        children = parent.children();
        while (try children.next(self.bytes)) |box| if (box.is("mvex")) {
            var entries = box.children();
            while (try entries.next(self.bytes)) |entry| if (entry.is("trex")) {
                if (entry.payload.len != 24 or be32(entry.payload[0..4]) != 0) return error.InvalidTrack;
                if (be32(entry.payload[4..8]) == self.track_id) {
                    if (be32(entry.payload[8..12]) != 1) return error.InvalidTrack;
                    self.default_duration = be32(entry.payload[12..16]);
                    self.default_size = be32(entry.payload[16..20]);
                }
            };
        };
    }

    fn fragment(self: *Demux, parent: Box) Error!void {
        self.run_count = 0;
        self.run_index = 0;
        var media_start: usize = 0;
        var media_end: usize = 0;
        var media_at = parent.end;
        while (media_at < self.bytes.len) {
            const box = try Box.read(self.bytes, media_at, self.bytes.len);
            if (box.is("moof")) break;
            if (box.is("mdat")) {
                media_start = box.start + box.header;
                media_end = box.end;
                break;
            }
            media_at = box.end;
        }
        if (media_end == 0) return error.InvalidFragment;
        var children = parent.children();
        while (try children.next(self.bytes)) |box| if (box.is("traf")) {
            var entries = box.children();
            var track: u32 = 0;
            var base = parent.start;
            var duration = self.default_duration;
            var size = self.default_size;
            var dts = self.next_dts;
            var found_tfhd = false;
            while (try entries.next(self.bytes)) |entry| {
                if (entry.is("tfhd")) {
                    if (found_tfhd or entry.payload.len < 8) return error.InvalidFragment;
                    found_tfhd = true;
                    var words: Words = .{ .data = entry.payload };
                    const version_flags = try words.next();
                    if (version_flags >> 24 != 0 or version_flags & ~@as(u32, 0x02003b) != 0) return error.InvalidFragment;
                    track = try words.next();
                    if (version_flags & 1 != 0) base = std.math.cast(usize, try words.long()) orelse return error.ArithmeticOverflow;
                    if (version_flags & 2 != 0 and try words.next() != 1) return error.InvalidFragment;
                    if (version_flags & 8 != 0) duration = try words.next();
                    if (version_flags & 16 != 0) size = try words.next();
                    if (version_flags & 32 != 0) _ = try words.next();
                    if (words.at != words.data.len) return error.InvalidFragment;
                } else if (entry.is("tfdt")) {
                    var words: Words = .{ .data = entry.payload };
                    const version_flags = try words.next();
                    dts = switch (version_flags) {
                        0 => try words.next(),
                        0x01000000 => try words.long(),
                        else => return error.InvalidFragment,
                    };
                    if (words.at != words.data.len) return error.InvalidFragment;
                }
            }
            if (!found_tfhd) return error.InvalidFragment;
            if (track != self.track_id) continue;
            if (dts != self.next_dts) return error.InvalidFragment;
            entries = box.children();
            var implicit_offset = media_start;
            while (try entries.next(self.bytes)) |entry| if (entry.is("trun")) {
                if (self.run_count == self.runs.len) return error.TooManyRuns;
                var words: Words = .{ .data = entry.payload };
                const flags = try words.next();
                if (flags & ~@as(u32, 0x01000f05) != 0 or flags >> 24 > 1) return error.InvalidFragment;
                const count = try words.next();
                if (count == 0 or count > 1048576) return error.InvalidFragment;
                var offset = implicit_offset;
                if (flags & 1 != 0) {
                    const delta: i32 = @bitCast(try words.next());
                    const signed: i128 = @as(i128, base) + delta;
                    if (signed < 0 or signed > std.math.maxInt(usize)) return error.InvalidSample;
                    offset = @intCast(signed);
                }
                if (flags & 4 != 0) _ = try words.next();
                const fields: usize = @popCount(flags & 0xf00);
                const required = @as(u64, count) * fields * 4;
                if (required != words.data.len - words.at) return error.InvalidFragment;
                self.runs[self.run_count] = .{ .table = entry.payload[words.at..], .count = count, .flags = flags, .offset = offset, .dts = dts, .default_duration = duration, .default_size = size, .media_start = media_start, .media_end = media_end };
                var scan = self.runs[self.run_count];
                for (0..count) |_| {
                    const frame_duration = if (flags & 0x100 != 0) try scan.word() else duration;
                    const frame_size = if (flags & 0x200 != 0) try scan.word() else size;
                    if (flags & 0x400 != 0) _ = try scan.word();
                    if (flags & 0x800 != 0) _ = try scan.word();
                    if (frame_duration == 0 or frame_size == 0 or frame_size > 8192 or offset < media_start or
                        offset > media_end or frame_size > media_end - offset) return error.InvalidSample;
                    offset += frame_size;
                    dts = try add64(dts, frame_duration);
                }
                implicit_offset = offset;
                self.run_count += 1;
            };
        };
        if (self.run_count == 0) return error.InvalidFragment;
    }
};

const Run = struct {
    table: []const u8,
    count: u32,
    flags: u32,
    offset: usize,
    dts: u64,
    default_duration: u32,
    default_size: u32,
    media_start: usize,
    media_end: usize,
    at: usize = 0,
    index: u32 = 0,
    fn word(self: *Run) Error!u32 {
        if (self.table.len - self.at < 4) return error.InvalidFragment;
        const value = be32(self.table[self.at..][0..4]);
        self.at += 4;
        return value;
    }
};
const Words = struct {
    data: []const u8,
    at: usize = 0,
    fn next(self: *Words) Error!u32 {
        if (self.data.len - self.at < 4) return error.UnexpectedEof;
        const value = be32(self.data[self.at..][0..4]);
        self.at += 4;
        return value;
    }
    fn long(self: *Words) Error!u64 {
        const high = try self.next();
        return (@as(u64, high) << 32) | try self.next();
    }
};
const Track = struct {
    id: u32 = 0,
    timescale: u32 = 0,
    duration: u64 = 0,
    audio: bool = false,
    config: ?Config = null,
    fn parse(self: *Track, bytes: []const u8, parent: Box, depth: usize) Error!void {
        if (depth > 6) return error.InvalidContainer;
        var children = parent.children();
        while (try children.next(bytes)) |box| {
            if (box.is("tkhd")) {
                if (box.payload.len < 20) return error.InvalidTrack;
                const at: usize = switch (box.payload[0]) {
                    0 => 12,
                    1 => 20,
                    else => return error.InvalidTrack,
                };
                if (box.payload.len < at + 4) return error.InvalidTrack;
                self.id = be32(box.payload[at..][0..4]);
            } else if (box.is("mdhd")) {
                if (box.payload.len < 20) return error.InvalidTrack;
                const at: usize = switch (box.payload[0]) {
                    0 => 12,
                    1 => 20,
                    else => return error.InvalidTrack,
                };
                if (box.payload.len < at + 4) return error.InvalidTrack;
                self.timescale = be32(box.payload[at..][0..4]);
                if (box.payload[0] == 0) {
                    if (box.payload.len < at + 8) return error.InvalidTrack;
                    const value = be32(box.payload[at + 4 ..][0..4]);
                    self.duration = if (value == std.math.maxInt(u32)) 0 else value;
                } else {
                    if (box.payload.len < at + 12) return error.InvalidTrack;
                    const value = (@as(u64, be32(box.payload[at + 4 ..][0..4])) << 32) | be32(box.payload[at + 8 ..][0..4]);
                    self.duration = if (value == std.math.maxInt(u64)) 0 else value;
                }
            } else if (box.is("hdlr")) {
                if (box.payload.len < 12) return error.InvalidTrack;
                self.audio = std.mem.eql(u8, box.payload[8..12], "soun");
            } else if (box.is("mdia") or box.is("minf") or box.is("stbl")) {
                try self.parse(bytes, box, depth + 1);
            } else if (box.is("stsd")) {
                if (box.payload.len < 8 or be32(box.payload[0..4]) != 0 or be32(box.payload[4..8]) != 1)
                    return error.InvalidTrack;
                const entry = try Box.read(bytes, box.start + box.header + 8, box.end);
                if (!entry.is("mp4a")) continue;
                if (entry.end != box.end or entry.payload.len < 28 or be16(entry.payload[8..10]) != 0)
                    return error.InvalidTrack;
                var descriptions: Children = .{ .at = entry.start + entry.header + 28, .end = entry.end };
                while (try descriptions.next(bytes)) |description| if (description.is("esds")) {
                    if (description.payload.len < 4 or be32(description.payload[0..4]) != 0 or self.config != null)
                        return error.InvalidConfiguration;
                    self.config = try descriptors(description.payload[4..], 0);
                };
            }
        }
    }
};

fn descriptors(bytes: []const u8, depth: usize) Error!?Config {
    if (depth > 4) return error.InvalidConfiguration;
    var at: usize = 0;
    var config: ?Config = null;
    while (at < bytes.len) {
        const kind = bytes[at];
        at += 1;
        var length: usize = 0;
        var n: usize = 0;
        while (true) {
            if (at == bytes.len or n == 4) return error.InvalidConfiguration;
            const byte = bytes[at];
            at += 1;
            n += 1;
            length = (length << 7) | (byte & 127);
            if (byte & 128 == 0) break;
        }
        if (length > bytes.len - at) return error.UnexpectedEof;
        const payload = bytes[at..][0..length];
        at += length;
        var found: ?Config = null;
        if (kind == 3) {
            if (payload.len < 3) return error.InvalidConfiguration;
            var skip: usize = 3;
            if (payload[2] & 128 != 0) skip += 2;
            if (skip > payload.len) return error.InvalidConfiguration;
            if (payload[2] & 64 != 0) {
                if (skip == payload.len) return error.InvalidConfiguration;
                skip += 1 + @as(usize, payload[skip]);
            }
            if (payload[2] & 32 != 0) skip += 2;
            if (skip > payload.len) return error.InvalidConfiguration;
            found = try descriptors(payload[skip..], depth + 1);
        } else if (kind == 4) {
            if (payload.len < 13 or payload[0] != 0x40 or payload[1] >> 2 != 5) return error.UnsupportedCodec;
            found = try descriptors(payload[13..], depth + 1);
        } else if (kind == 5) {
            found = try parseConfig(payload);
        }
        if (found) |value| {
            if (config != null) return error.InvalidConfiguration;
            config = value;
        }
    }
    return config;
}

pub fn parseConfig(bytes: []const u8) Error!Config {
    if (bytes.len < 2) return error.InvalidConfiguration;
    const object_type = bytes[0] >> 3;
    const frequency_index: u8 = ((bytes[0] & 7) << 1) | (bytes[1] >> 7);
    const channels: u8 = (bytes[1] >> 3) & 15;
    if (object_type != 2) return error.UnsupportedProfile;
    if (frequency_index >= SAMPLE_RATES.len) return error.InvalidConfiguration;
    if (channels == 0 or channels > 2) return error.UnsupportedChannels;
    if (bytes[1] & 7 != 0) return error.UnsupportedProfile; // 960-sample/dependent core/extension.
    for (bytes[2..]) |byte| if (byte != 0) return error.UnsupportedProfile;
    return .{ .sample_rate = SAMPLE_RATES[frequency_index], .channels = channels, .object_type = object_type, .frequency_index = frequency_index };
}
pub const SAMPLE_RATES = [_]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };

const Box = struct {
    start: usize,
    end: usize,
    header: usize,
    kind: []const u8,
    payload: []const u8,
    fn is(self: Box, comptime name: []const u8) bool {
        return std.mem.eql(u8, self.kind, name);
    }
    fn children(self: Box) Children {
        return .{ .at = self.start + self.header, .end = self.end };
    }
    fn read(bytes: []const u8, at: usize, end: usize) Error!Box {
        if (at > end or end > bytes.len or end - at < 8) return error.UnexpectedEof;
        var size: u64 = be32(bytes[at..][0..4]);
        var header: usize = 8;
        if (size == 1) {
            if (end - at < 16) return error.UnexpectedEof;
            size = (@as(u64, be32(bytes[at + 8 ..][0..4])) << 32) | be32(bytes[at + 12 ..][0..4]);
            header = 16;
        } else if (size == 0) size = end - at;
        if (size < header or size > end - at) return error.InvalidContainer;
        const box_end = at + @as(usize, @intCast(size));
        return .{ .start = at, .end = box_end, .header = header, .kind = bytes[at + 4 ..][0..4], .payload = bytes[at + header .. box_end] };
    }
};
const Children = struct {
    at: usize,
    end: usize,
    fn next(self: *Children, bytes: []const u8) Error!?Box {
        if (self.at == self.end) return null;
        const box = try Box.read(bytes, self.at, self.end);
        self.at = box.end;
        return box;
    }
};
fn be16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}
fn be32(bytes: []const u8) u32 {
    return (@as(u32, be16(bytes[0..2])) << 16) | be16(bytes[2..4]);
}
fn add64(a: u64, b: u64) Error!u64 {
    const value = @addWithOverflow(a, b);
    if (value[1] != 0) return error.ArithmeticOverflow;
    return value[0];
}

test "AAC AudioSpecificConfig matches YouTube LC stereo44100 and rejects extensions" {
    const config = try parseConfig(&.{ 0x12, 0x10 });
    try std.testing.expectEqual(@as(u32, 44100), config.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), config.channels);
    try std.testing.expectError(error.UnsupportedProfile, parseConfig(&.{ 0x2a, 0x10 }));
    try std.testing.expectError(error.UnsupportedChannels, parseConfig(&.{ 0x12, 0x00 }));
    try std.testing.expectError(error.UnsupportedProfile, parseConfig(&.{ 0x12, 0x14 }));
    try std.testing.expectError(error.UnsupportedProfile, parseConfig(&.{ 0x12, 0x10, 0x56, 0xe5 }));
}

test "fragmented MP4 without an audio track is rejected before reading undefined configuration" {
    const bytes = "\x00\x00\x00\x10ftypisom\x00\x00\x00\x00" ++
        "\x00\x00\x00\x10moov\x00\x00\x00\x08mvex";
    try std.testing.expectError(error.InvalidTrack, Demux.open(bytes));
}
