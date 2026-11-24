//! @zpm/rtmp: an RTMP publisher. Opens a stream the way OBS and ffmpeg do
//! (the plain handshake, connect, releaseStream, FCPublish, createStream,
//! publish) and then sends audio, video and data messages (FLV bodies,
//! zpm's flv module). Over any byte transport: TCP for rtmp://, TLS for
//! rtmps:// (Twitch's ingest takes TLS 1.3).
//!
//! Layer 0: no platform deps, allocation-free; the Publisher holds its own
//! fixed buffers (about 70 KiB). Messages go out in 4096-byte chunks, the
//! first with a full (type 0) header carrying the absolute time, the rest
//! with type 3 headers. The server's messages are read back in whatever
//! chunk size it sets, and answered: acknowledgements once its window is
//! reached, pings with pongs. An onStatus error ends the stream.

const std = @import("std");
const flv = @import("flv");

pub const IoError = error{
    /// The connection closed.
    Closed,
    /// The transport failed (or timed out).
    Io,
};

pub const Error = IoError || error{
    /// The server broke the protocol (or sent more than this keeps).
    Protocol,
    /// The server refused: the status code is in `Publisher.status`.
    Refused,
    /// A message larger than the publisher's buffers.
    TooLarge,
};

/// A byte stream: TCP, or TLS over it.
pub const Transport = struct {
    ctx: *anyopaque,
    /// Reads 1 byte or more, waiting for them; 0 when closed.
    readFn: *const fn (ctx: *anyopaque, buf: []u8) IoError!usize,
    writeFn: *const fn (ctx: *anyopaque, data: []const u8) IoError!void,
    /// Bytes that can be read without waiting (0 if none). Null: `service`
    /// never reads.
    readyFn: ?*const fn (ctx: *anyopaque) usize = null,
};

/// Bytes a chunk carries, out (the server's size is whatever it sets).
pub const CHUNK: u32 = 4096;
/// The largest message read from the server.
const IN_MAX: usize = 16 * 1024;
const HANDSHAKE: usize = 1536;

// Message types.
pub const SET_CHUNK_SIZE: u8 = 1;
pub const ABORT: u8 = 2;
pub const ACK: u8 = 3;
pub const USER_CONTROL: u8 = 4;
pub const WINDOW_ACK_SIZE: u8 = 5;
pub const SET_PEER_BANDWIDTH: u8 = 6;
pub const AUDIO: u8 = 8;
pub const VIDEO: u8 = 9;
pub const DATA: u8 = 18;
pub const COMMAND: u8 = 20;

// Chunk streams this publisher uses.
const CS_CONTROL: u32 = 2;
const CS_COMMAND: u32 = 3;
const CS_AUDIO: u32 = 4;
const CS_DATA: u32 = 5;
const CS_VIDEO: u32 = 6;

/// One chunk stream's last header, as the server sent it.
const Track = struct {
    csid: u32 = 0,
    time: u32 = 0,
    length: u32 = 0,
    kind: u8 = 0,
    msid: u32 = 0,
    extended: bool = false,
};

pub const Publisher = struct {
    io: Transport,
    /// The stream id createStream gave.
    stream: u32 = 0,
    /// The server's last onStatus code (or the _error's), for the caller.
    status: [96]u8 = undefined,
    status_len: usize = 0,
    /// Bytes read so far, and at the last acknowledgement.
    received: u64 = 0,
    acked: u64 = 0,
    window: u32 = 2_500_000,
    chunk_in: u32 = 128,
    tracks: [8]Track = [_]Track{.{}} ** 8,
    /// Bytes read and not yet parsed.
    in: [IN_MAX + 64]u8 = undefined,
    in_len: usize = 0,
    /// The message being reassembled from the server's chunks.
    msg: [IN_MAX]u8 = undefined,
    msg_len: usize = 0,
    msg_track: ?usize = null,
    /// Replies the open sequence waits for.
    result_for: f64 = 0,
    result_value: ?f64 = null,
    got_result: bool = false,
    stage: [CHUNK + 18]u8 = undefined,

    pub fn init(io: Transport) Publisher {
        return .{ .io = io };
    }

    pub fn statusCode(p: *const Publisher) []const u8 {
        return p.status[0..p.status_len];
    }

    /// The handshake, then connect to `app` (tc_url: the rtmp:// URL up to
    /// the app), createStream, and publish `key` live. `random`: 1528
    /// bytes for the handshake's C1. Returns once the server says
    /// NetStream.Publish.Start.
    pub fn open(p: *Publisher, app: []const u8, tc_url: []const u8, key: []const u8, random: *const [HANDSHAKE - 8]u8) Error!void {
        var c1: [1 + HANDSHAKE]u8 = undefined;
        c1[0] = 3; // C0: RTMP 3
        @memset(c1[1..9], 0); // time, zero
        @memcpy(c1[9..], random);
        try p.io.writeFn(p.io.ctx, &c1);
        var s01: [1 + HANDSHAKE]u8 = undefined;
        try p.readExact(&s01);
        if (s01[0] != 3) return error.Protocol;
        try p.io.writeFn(p.io.ctx, s01[1..]); // C2: S1 back
        var s2: [HANDSHAKE]u8 = undefined;
        try p.readExact(&s2);

        var body: [512]u8 = undefined;
        // our chunk size first, so the rest goes in 4096-byte chunks
        std.mem.writeInt(u32, body[0..4], CHUNK, .big);
        try p.send(CS_CONTROL, SET_CHUNK_SIZE, 0, 0, body[0..4]);

        var a = flv.Amf{ .buf = &body };
        a.string("connect") catch return error.TooLarge;
        a.number(1) catch return error.TooLarge;
        a.object() catch return error.TooLarge;
        a.key("app") catch return error.TooLarge;
        a.string(app) catch return error.TooLarge;
        a.key("type") catch return error.TooLarge;
        a.string("nonprivate") catch return error.TooLarge;
        a.key("flashVer") catch return error.TooLarge;
        a.string("FMLE/3.0 (compatible; FMSc/1.0)") catch return error.TooLarge;
        a.key("swfUrl") catch return error.TooLarge;
        a.string(tc_url) catch return error.TooLarge;
        a.key("tcUrl") catch return error.TooLarge;
        a.string(tc_url) catch return error.TooLarge;
        a.end() catch return error.TooLarge;
        try p.command(body[0..a.at], 1);
        _ = try p.awaitResult(1);

        try p.call("releaseStream", 2, key);
        try p.call("FCPublish", 3, key);
        a = flv.Amf{ .buf = &body };
        a.string("createStream") catch return error.TooLarge;
        a.number(4) catch return error.TooLarge;
        a.nul() catch return error.TooLarge;
        try p.command(body[0..a.at], 4);
        const id = try p.awaitResult(4);
        if (id == null or id.? < 1 or id.? > 1e6) return error.Protocol;
        p.stream = @intFromFloat(id.?);

        a = flv.Amf{ .buf = &body };
        a.string("publish") catch return error.TooLarge;
        a.number(5) catch return error.TooLarge;
        a.nul() catch return error.TooLarge;
        a.string(key) catch return error.TooLarge;
        a.string("live") catch return error.TooLarge;
        p.status_len = 0;
        try p.send(CS_AUDIO, COMMAND, p.stream, 0, body[0..a.at]);
        while (p.status_len == 0) try p.pump(true);
        if (!std.mem.eql(u8, p.statusCode(), "NetStream.Publish.Start")) return error.Refused;
    }

    /// One FLV body as an audio, video or data message at `time_ms`.
    pub fn audio(p: *Publisher, time_ms: u32, body: []const u8) Error!void {
        try p.send(CS_AUDIO, AUDIO, p.stream, time_ms, body);
    }
    pub fn video(p: *Publisher, time_ms: u32, body: []const u8) Error!void {
        try p.send(CS_VIDEO, VIDEO, p.stream, time_ms, body);
    }
    pub fn data(p: *Publisher, body: []const u8) Error!void {
        try p.send(CS_DATA, DATA, p.stream, 0, body);
    }

    /// Reads what the server sent, if anything is waiting, and answers
    /// it: call between messages. Error.Refused if it ended the stream.
    pub fn service(p: *Publisher) Error!void {
        const ready = p.io.readyFn orelse return;
        while (ready(p.io.ctx) > 0) try p.pump(false);
        if (p.status_len > 0 and isError(p.statusCode())) return error.Refused;
    }

    /// FCUnpublish and deleteStream (the caller closes the transport).
    pub fn close(p: *Publisher, key: []const u8) void {
        p.call("FCUnpublish", 6, key) catch return;
        var body: [64]u8 = undefined;
        var a = flv.Amf{ .buf = &body };
        a.string("deleteStream") catch return;
        a.number(7) catch return;
        a.nul() catch return;
        a.number(@floatFromInt(p.stream)) catch return;
        p.command(body[0..a.at], 7) catch return;
    }

    fn call(p: *Publisher, name: []const u8, transaction: f64, arg: []const u8) Error!void {
        var body: [512]u8 = undefined;
        var a = flv.Amf{ .buf = &body };
        a.string(name) catch return error.TooLarge;
        a.number(transaction) catch return error.TooLarge;
        a.nul() catch return error.TooLarge;
        a.string(arg) catch return error.TooLarge;
        try p.command(body[0..a.at], transaction);
    }

    fn command(p: *Publisher, body: []const u8, transaction: f64) Error!void {
        _ = transaction;
        try p.send(CS_COMMAND, COMMAND, 0, 0, body);
    }

    /// Waits for the _result of `transaction`; returns its first number
    /// after the command object (createStream's stream id), if any.
    fn awaitResult(p: *Publisher, transaction: f64) Error!?f64 {
        p.result_for = transaction;
        p.got_result = false;
        p.result_value = null;
        while (!p.got_result) {
            try p.pump(true);
            if (p.status_len > 0 and isError(p.statusCode())) return error.Refused;
        }
        return p.result_value;
    }

    /// Sends one message in chunks.
    fn send(p: *Publisher, csid: u32, kind: u8, msid: u32, time: u32, body: []const u8) Error!void {
        var at: usize = 0;
        var first = true;
        while (first or at < body.len) {
            const n = @min(body.len - at, CHUNK);
            const head = chunkHeader(&p.stage, csid, if (first) 0 else 3, time, @intCast(body.len), kind, msid);
            @memcpy(p.stage[head..][0..n], body[at..][0..n]);
            try p.io.writeFn(p.io.ctx, p.stage[0 .. head + n]);
            at += n;
            first = false;
        }
    }

    fn readExact(p: *Publisher, out: []u8) Error!void {
        var got: usize = 0;
        while (got < out.len) {
            const n = try p.io.readFn(p.io.ctx, out[got..]);
            if (n == 0) return error.Closed;
            got += n;
        }
        p.received += out.len;
    }

    /// One read (waiting for it when `wait`), then every whole chunk in
    /// the buffer handled.
    fn pump(p: *Publisher, wait: bool) Error!void {
        _ = wait;
        if (p.in_len == p.in.len) return error.TooLarge;
        const n = try p.io.readFn(p.io.ctx, p.in[p.in_len..]);
        if (n == 0) return error.Closed;
        p.in_len += n;
        p.received += n;
        while (try p.chunk()) {}
        if (p.received - p.acked >= p.window) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @truncate(p.received), .big);
            try p.send(CS_CONTROL, ACK, 0, 0, &b);
            p.acked = p.received;
        }
    }

    /// Parses one chunk from the buffer if it is all there; false if not.
    fn chunk(p: *Publisher) Error!bool {
        const buf = p.in[0..p.in_len];
        if (buf.len < 1) return false;
        const fmt = buf[0] >> 6;
        var csid: u32 = buf[0] & 0x3f;
        var at: usize = 1;
        if (csid == 0) {
            if (buf.len < 2) return false;
            csid = @as(u32, buf[1]) + 64;
            at = 2;
        } else if (csid == 1) {
            if (buf.len < 3) return false;
            csid = @as(u32, buf[1]) + @as(u32, buf[2]) * 256 + 64;
            at = 3;
        }
        const ti = p.trackFor(csid) orelse return error.Protocol;
        var t = p.tracks[ti];
        const head_len: usize = switch (fmt) {
            0 => 11,
            1 => 7,
            2 => 3,
            else => 0,
        };
        if (buf.len < at + head_len) return false;
        var stamp: u32 = t.time;
        var extended = t.extended;
        if (fmt < 3) {
            const ts = readU24(buf[at..]);
            extended = ts == 0xffffff;
            if (fmt == 0) stamp = ts else stamp = t.time +% ts;
            if (fmt <= 1) {
                t.length = readU24(buf[at + 3 ..]);
                t.kind = buf[at + 6];
            }
            if (fmt == 0) t.msid = std.mem.readInt(u32, buf[at + 7 ..][0..4], .little);
        }
        at += head_len;
        if (extended) {
            if (buf.len < at + 4) return false;
            const ext = std.mem.readInt(u32, buf[at..][0..4], .big);
            if (fmt == 0) stamp = ext else if (fmt < 3) stamp = t.time +% ext;
            at += 4;
        }
        t.extended = extended;
        if (t.length > IN_MAX) return error.TooLarge;
        // a new message on this track, or the next piece of the open one
        const starting = p.msg_track == null;
        if (!starting and p.msg_track.? != ti) return error.Protocol;
        const have = if (starting) 0 else p.msg_len;
        const n = @min(t.length - have, p.chunk_in);
        if (buf.len < at + n) return false;
        if (fmt < 3 or starting) t.time = stamp;
        p.tracks[ti] = t;
        @memcpy(p.msg[have..][0..n], buf[at..][0..n]);
        p.msg_len = have + n;
        p.msg_track = ti;
        const used = at + n;
        std.mem.copyForwards(u8, p.in[0 .. p.in_len - used], p.in[used..p.in_len]);
        p.in_len -= used;
        if (p.msg_len == t.length) {
            p.msg_track = null;
            try p.handle(t.kind, p.msg[0..p.msg_len]);
        }
        return true;
    }

    fn trackFor(p: *Publisher, csid: u32) ?usize {
        for (&p.tracks, 0..) |*t, i| if (t.csid == csid) return i;
        for (&p.tracks, 0..) |*t, i| if (t.csid == 0) {
            t.csid = csid;
            return i;
        };
        return null;
    }

    fn handle(p: *Publisher, kind: u8, body: []const u8) Error!void {
        switch (kind) {
            SET_CHUNK_SIZE => {
                if (body.len < 4) return error.Protocol;
                const size = std.mem.readInt(u32, body[0..4], .big) & 0x7fffffff;
                if (size < 1 or size > IN_MAX) return error.Protocol;
                p.chunk_in = size;
            },
            WINDOW_ACK_SIZE => {
                if (body.len < 4) return error.Protocol;
                p.window = @max(std.mem.readInt(u32, body[0..4], .big), 1);
            },
            USER_CONTROL => {
                // a ping request (6): answer with its time (7)
                if (body.len >= 6 and std.mem.readInt(u16, body[0..2], .big) == 6) {
                    var pong: [6]u8 = undefined;
                    std.mem.writeInt(u16, pong[0..2], 7, .big);
                    @memcpy(pong[2..6], body[2..6]);
                    try p.send(CS_CONTROL, USER_CONTROL, 0, 0, &pong);
                }
            },
            COMMAND => p.onCommand(body),
            else => {},
        }
    }

    fn onCommand(p: *Publisher, body: []const u8) void {
        var r = flv.AmfReader{ .data = body };
        const name = (r.value() orelse return);
        if (name != .string) return;
        const tx = r.value() orelse return;
        const transaction: f64 = if (tx == .number) tx.number else -1;
        if (std.mem.eql(u8, name.string, "_result") or std.mem.eql(u8, name.string, "_error")) {
            // the command object, then the value (or the info object)
            const cmd = r.value() orelse return;
            if (!r.skip(cmd)) return;
            const info = r.value();
            if (std.mem.eql(u8, name.string, "_error")) {
                const code = if (info != null and info.? == .object) r.find("code") orelse "_error" else "_error";
                p.setStatus(code);
                p.got_result = true;
                return;
            }
            if (transaction == p.result_for) {
                if (info) |v| if (v == .number) {
                    p.result_value = v.number;
                };
                p.got_result = true;
            }
        } else if (std.mem.eql(u8, name.string, "onStatus")) {
            const cmd = r.value() orelse return;
            if (!r.skip(cmd)) return;
            const info = r.value() orelse return;
            if (info != .object) return;
            p.setStatus(r.find("code") orelse "onStatus");
        }
    }

    fn setStatus(p: *Publisher, code: []const u8) void {
        const n = @min(code.len, p.status.len);
        @memcpy(p.status[0..n], code[0..n]);
        p.status_len = n;
    }
};

fn isError(code: []const u8) bool {
    return std.mem.indexOf(u8, code, "Failed") != null or std.mem.indexOf(u8, code, "Bad") != null or
        std.mem.indexOf(u8, code, "Rejected") != null or std.mem.indexOf(u8, code, "error") != null or
        std.mem.eql(u8, code, "NetStream.Publish.Denied") or std.mem.eql(u8, code, "NetStream.Unpublish.Success") or
        std.mem.eql(u8, code, "_error");
}

fn readU24(b: []const u8) u32 {
    return @as(u32, b[0]) << 16 | @as(u32, b[1]) << 8 | b[2];
}

/// Writes a chunk's basic header and message header (type 0 or 3) into
/// `out`; returns its length. Times of 0xffffff and over go in the
/// extended field, which type 3 chunks repeat.
pub fn chunkHeader(out: []u8, csid: u32, fmt: u2, time: u32, length: u32, kind: u8, msid: u32) usize {
    var at: usize = 0;
    if (csid < 64) {
        out[0] = (@as(u8, fmt) << 6) | @as(u8, @intCast(csid));
        at = 1;
    } else if (csid < 320) {
        out[0] = @as(u8, fmt) << 6;
        out[1] = @intCast(csid - 64);
        at = 2;
    } else {
        out[0] = (@as(u8, fmt) << 6) | 1;
        out[1] = @intCast((csid - 64) & 0xff);
        out[2] = @intCast((csid - 64) >> 8);
        at = 3;
    }
    const extended = time >= 0xffffff;
    if (fmt == 0) {
        const ts: u32 = if (extended) 0xffffff else time;
        out[at..][0..3].* = .{ @intCast(ts >> 16), @intCast((ts >> 8) & 0xff), @intCast(ts & 0xff) };
        out[at + 3 ..][0..3].* = .{ @intCast(length >> 16), @intCast((length >> 8) & 0xff), @intCast(length & 0xff) };
        out[at + 6] = kind;
        std.mem.writeInt(u32, out[at + 7 ..][0..4], msid, .little);
        at += 11;
    }
    if (extended) {
        std.mem.writeInt(u32, out[at..][0..4], time, .big);
        at += 4;
    }
    return at;
}

/// Splits rtmp://host[:port]/app/key or rtmps://... into its parts.
pub const Url = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    app: []const u8,
    /// The URL up to the app (connect's tcUrl).
    tc_url: []const u8,
    key: []const u8,

    pub fn parse(url: []const u8) ?Url {
        var secure = false;
        var rest: []const u8 = undefined;
        if (std.mem.startsWith(u8, url, "rtmps://")) {
            secure = true;
            rest = url[8..];
        } else if (std.mem.startsWith(u8, url, "rtmp://")) {
            rest = url[7..];
        } else return null;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const authority = rest[0..slash];
        const path = rest[slash + 1 ..];
        var host = authority;
        var port: u16 = if (secure) 443 else 1935;
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
        }
        if (host.len == 0) return null;
        const app_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
        const app = path[0..app_end];
        if (app.len == 0) return null;
        const scheme_len: usize = if (secure) 8 else 7;
        return .{
            .secure = secure,
            .host = host,
            .port = port,
            .app = app,
            .tc_url = url[0 .. scheme_len + slash + 1 + app_end],
            .key = if (app_end < path.len) path[app_end + 1 ..] else "",
        };
    }
};

// ---- tests: the publisher against a scripted server ----

const testing = std.testing;

const Fake = struct {
    script: []const u8,
    at: usize = 0,
    sent: [64 * 1024]u8 = undefined,
    sent_len: usize = 0,

    fn read(ctx: *anyopaque, buf: []u8) IoError!usize {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        if (f.at == f.script.len) return error.Closed;
        // dribble the bytes in odd pieces: chunks must survive any split
        const n = @min(buf.len, f.script.len - f.at, 37);
        @memcpy(buf[0..n], f.script[f.at..][0..n]);
        f.at += n;
        return n;
    }
    fn write(ctx: *anyopaque, data_: []const u8) IoError!void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        @memcpy(f.sent[f.sent_len..][0..data_.len], data_);
        f.sent_len += data_.len;
    }
};

/// Appends a server message, in chunks of `size`, to `out`.
fn serverMessage(out: []u8, at: *usize, csid: u32, kind: u8, size: u32, body: []const u8) void {
    var done: usize = 0;
    var first = true;
    while (first or done < body.len) {
        const n = @min(body.len - done, size);
        at.* += chunkHeader(out[at.*..], csid, if (first) 0 else 3, 0, @intCast(body.len), kind, 0);
        @memcpy(out[at.*..][0..n], body[done..][0..n]);
        at.* += n;
        done += n;
        first = false;
    }
}

fn amfCommand(buf: []u8, name: []const u8, tx: f64, code_or_id: anytype) []u8 {
    var a = flv.Amf{ .buf = buf };
    a.string(name) catch unreachable;
    a.number(tx) catch unreachable;
    a.nul() catch unreachable;
    switch (@TypeOf(code_or_id)) {
        f64 => a.number(code_or_id) catch unreachable,
        else => {
            a.object() catch unreachable;
            a.key("level") catch unreachable;
            a.string("status") catch unreachable;
            a.key("code") catch unreachable;
            a.string(code_or_id) catch unreachable;
            a.key("description") catch unreachable;
            a.string("a description long enough to need a second 128-byte chunk from the server, which is its default chunk size before it sets another one") catch unreachable;
            a.end() catch unreachable;
        },
    }
    return buf[0..a.at];
}

test "the publisher opens a stream against a scripted server, then sends in 4096-byte chunks" {
    var script: [8192]u8 = undefined;
    var at: usize = 0;
    script[0] = 3;
    @memset(script[1 .. 1 + 2 * HANDSHAKE], 0x5a);
    at = 1 + 2 * HANDSHAKE;
    var b: [512]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], 5000, .big);
    serverMessage(&script, &at, 2, WINDOW_ACK_SIZE, 128, b[0..4]);
    // a ping, which the publisher must answer
    b[0..6].* = .{ 0, 6, 0, 0, 0x12, 0x34 };
    serverMessage(&script, &at, 2, USER_CONTROL, 128, b[0..6]);
    serverMessage(&script, &at, 3, COMMAND, 128, amfCommand(&b, "_result", 1, "NetConnection.Connect.Success"));
    std.mem.writeInt(u32, b[0..4], 4096, .big);
    serverMessage(&script, &at, 2, SET_CHUNK_SIZE, 128, b[0..4]);
    serverMessage(&script, &at, 3, COMMAND, 4096, amfCommand(&b, "_result", 4, @as(f64, 1)));
    serverMessage(&script, &at, 5, COMMAND, 4096, amfCommand(&b, "onStatus", 0, "NetStream.Publish.Start"));
    var fake = Fake{ .script = script[0..at] };
    var p = Publisher.init(.{ .ctx = &fake, .readFn = Fake.read, .writeFn = Fake.write });
    var random: [HANDSHAKE - 8]u8 = undefined;
    @memset(&random, 7);
    try p.open("app", "rtmp://127.0.0.1/app", "live_123", &random);
    try testing.expectEqual(@as(u32, 1), p.stream);
    try testing.expectEqualStrings("NetStream.Publish.Start", p.statusCode());
    try testing.expectEqual(@as(u32, 4096), p.chunk_in);
    // C0 C1, then C2 = S1
    try testing.expectEqual(@as(u8, 3), fake.sent[0]);
    try testing.expectEqualSlices(u8, script[1 .. 1 + HANDSHAKE], fake.sent[1 + HANDSHAKE .. 1 + 2 * HANDSHAKE]);
    // the pong carries the ping's time
    try testing.expect(std.mem.indexOf(u8, fake.sent[0..fake.sent_len], &.{ 0, 7, 0, 0, 0x12, 0x34 }) != null);
    const before = fake.sent_len;
    var big: [10000]u8 = undefined;
    for (&big, 0..) |*x, i| x.* = @truncate(i);
    try p.video(0x1000000, &big);
    // three chunks: a full header with an extended time, then two type 3
    // headers that repeat it
    const out = fake.sent[before..fake.sent_len];
    try testing.expectEqual(@as(usize, 10000 + (1 + 11 + 4) + 2 * (1 + 4)), out.len);
    try testing.expectEqual(@as(u8, 0x06), out[0]);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0, 0x27, 0x10, VIDEO, 1, 0, 0, 0, 1, 0, 0, 0 }, out[1..16]);
    try testing.expectEqual(@as(u8, 0xc6), out[16 + 4096]);
}

test "a refused publish is an error with the server's code" {
    var script: [8192]u8 = undefined;
    script[0] = 3;
    @memset(script[1 .. 1 + 2 * HANDSHAKE], 1);
    var at: usize = 1 + 2 * HANDSHAKE;
    var b: [512]u8 = undefined;
    serverMessage(&script, &at, 3, COMMAND, 128, amfCommand(&b, "_result", 1, "NetConnection.Connect.Success"));
    serverMessage(&script, &at, 3, COMMAND, 128, amfCommand(&b, "_result", 4, @as(f64, 1)));
    serverMessage(&script, &at, 5, COMMAND, 128, amfCommand(&b, "onStatus", 0, "NetStream.Publish.BadName"));
    var fake = Fake{ .script = script[0..at] };
    var p = Publisher.init(.{ .ctx = &fake, .readFn = Fake.read, .writeFn = Fake.write });
    var random: [HANDSHAKE - 8]u8 = undefined;
    @memset(&random, 0);
    try testing.expectError(error.Refused, p.open("app", "rtmp://h/app", "k", &random));
    try testing.expectEqualStrings("NetStream.Publish.BadName", p.statusCode());
}

test "stream URLs split into host, port, app and key" {
    const u = Url.parse("rtmps://live.twitch.tv:443/app/live_1_abc").?;
    try testing.expect(u.secure);
    try testing.expectEqualStrings("live.twitch.tv", u.host);
    try testing.expectEqual(@as(u16, 443), u.port);
    try testing.expectEqualStrings("app", u.app);
    try testing.expectEqualStrings("rtmps://live.twitch.tv:443/app", u.tc_url);
    try testing.expectEqualStrings("live_1_abc", u.key);
    const v = Url.parse("rtmp://172.17.176.1/live/test?bandwidthtest=true").?;
    try testing.expect(!v.secure);
    try testing.expectEqual(@as(u16, 1935), v.port);
    try testing.expectEqualStrings("live", v.app);
    try testing.expectEqualStrings("test?bandwidthtest=true", v.key);
    try testing.expect(Url.parse("http://x/app") == null);
    try testing.expect(Url.parse("rtmp://x/") == null);
}
