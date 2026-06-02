// Layer 3 — Application Protocol Mapping.
//
// This is the ONLY module that knows about zpm semantics. Maps registry
// operations (resolve, publish, search, tarball fetch) to QUIC lanes using
// a compact binary envelope. All other transport modules are generic QUIC.
//
// Lane mapping:
//   Control lane → bidirectional stream 0 (reliable, ordered)
//   Bulk lane    → bidirectional streams 4, 8, 12, ... (reliable, parallel)
//   Hot lane     → DATAGRAM frames (unreliable, latest-wins)
//
// Wire format: 8-byte AppMsgHeader + variable payload.
// Zero allocator usage.

const streams = @import("streams");
const datagram = @import("datagram");
const packet = @import("packet");

// ── Message Types ──

pub const MsgType = enum(u8) {
    // Control lane messages
    hello = 0x01,
    hello_ack = 0x02,
    resolve_req = 0x10,
    resolve_resp = 0x11,
    publish_req = 0x20,
    publish_resp = 0x21,
    search_req = 0x30,
    search_resp = 0x31,
    close = 0xFF,

    // Hot lane messages (DATAGRAM)
    invalidation = 0x40,
    version_announce = 0x41,
    telemetry_ping = 0x42,
};

// ── Application Message Header ──
// Fixed 8-byte binary envelope for all application messages.
//
// Offset  Size  Field
// 0       1     msg_type (MsgType enum)
// 1       1     flags (reserved)
// 2       2     seq (little-endian u16, for Hot lane ordering)
// 4       4     payload_len (little-endian u32)

pub const AppMsgHeader = struct {
    msg_type: u8,
    flags: u8,
    seq: u16,
    payload_len: u32,
};

pub const header_size: u32 = 8;

// ── AppMap ──

pub const AppMap = struct {
    stream_mgr: *streams.StreamManager,
    dgrams: *datagram.DatagramHandler,
    last_hot_seq: u16,
    msg_buf: [65536]u8,

    pub fn init(sm: *streams.StreamManager, dg: *datagram.DatagramHandler) AppMap {
        return .{
            .stream_mgr = sm,
            .dgrams = dg,
            .last_hot_seq = 0,
            .msg_buf = [_]u8{0} ** 65536,
        };
    }

    // ── Serialization / Deserialization (25.2) ──

    /// Serialize an application message: 8-byte header + payload.
    /// Returns total bytes written to `out`.
    pub fn serializeMsg(msg_type: MsgType, seq: u16, payload: []const u8, out: []u8) u32 {
        const total: u32 = header_size + @as(u32, @intCast(payload.len));
        if (out.len < total) return 0;

        const plen: u32 = @intCast(payload.len);

        // msg_type
        out[0] = @intFromEnum(msg_type);
        // flags (reserved)
        out[1] = 0;
        // seq (little-endian u16)
        out[2] = @truncate(seq);
        out[3] = @truncate(seq >> 8);
        // payload_len (little-endian u32)
        out[4] = @truncate(plen);
        out[5] = @truncate(plen >> 8);
        out[6] = @truncate(plen >> 16);
        out[7] = @truncate(plen >> 24);

        // payload
        if (payload.len > 0) {
            @memcpy(out[header_size .. header_size + plen], payload);
        }

        return total;
    }

    pub const DeserializeResult = struct {
        header: AppMsgHeader,
        payload: []const u8,
        err: bool,
    };

    /// Deserialize an application message from a buffer.
    /// Returns the parsed header, a slice into `buf` for the payload, and error flag.
    pub fn deserializeMsg(buf: []const u8) DeserializeResult {
        if (buf.len < header_size) {
            return .{
                .header = .{ .msg_type = 0, .flags = 0, .seq = 0, .payload_len = 0 },
                .payload = &[_]u8{},
                .err = true,
            };
        }

        const msg_type = buf[0];
        const flags = buf[1];
        const seq: u16 = @as(u16, buf[2]) | (@as(u16, buf[3]) << 8);
        const payload_len: u32 = @as(u32, buf[4]) |
            (@as(u32, buf[5]) << 8) |
            (@as(u32, buf[6]) << 16) |
            (@as(u32, buf[7]) << 24);

        if (header_size + payload_len > buf.len) {
            return .{
                .header = .{ .msg_type = msg_type, .flags = flags, .seq = seq, .payload_len = payload_len },
                .payload = &[_]u8{},
                .err = true,
            };
        }

        return .{
            .header = .{
                .msg_type = msg_type,
                .flags = flags,
                .seq = seq,
                .payload_len = payload_len,
            },
            .payload = buf[header_size .. header_size + payload_len],
            .err = false,
        };
    }

    // ── Control Lane Operations (25.3) ──

    /// Send a resolve request on the Control lane (stream 0).
    /// Payload: scope_len:u8 + scope + name_len:u8 + name + version_len:u8 + version
    pub fn sendResolve(self: *AppMap, scope: []const u8, name: []const u8, version: ?[]const u8) bool {
        // Build payload in msg_buf
        var pos: u32 = 0;
        const scope_len: u8 = @intCast(@min(scope.len, 255));
        const name_len: u8 = @intCast(@min(name.len, 255));
        const ver = version orelse &[_]u8{};
        const ver_len: u8 = @intCast(@min(ver.len, 255));

        // scope_len + scope
        self.msg_buf[pos] = scope_len;
        pos += 1;
        if (scope_len > 0) {
            @memcpy(self.msg_buf[pos .. pos + scope_len], scope[0..scope_len]);
            pos += scope_len;
        }
        // name_len + name
        self.msg_buf[pos] = name_len;
        pos += 1;
        if (name_len > 0) {
            @memcpy(self.msg_buf[pos .. pos + name_len], name[0..name_len]);
            pos += name_len;
        }
        // version_len + version
        self.msg_buf[pos] = ver_len;
        pos += 1;
        if (ver_len > 0) {
            @memcpy(self.msg_buf[pos .. pos + ver_len], ver[0..ver_len]);
            pos += ver_len;
        }

        // Serialize full message (header + payload) into a temp area after pos
        const payload_slice = self.msg_buf[0..pos];
        var wire_buf: [65536]u8 = undefined;
        const total = serializeMsg(.resolve_req, 0, payload_slice, &wire_buf);
        if (total == 0) return false;

        const written = self.stream_mgr.writeToStream(0, wire_buf[0..total]);
        return written == total;
    }

    /// Send a publish request on the Control lane (stream 0).
    pub fn sendPublish(self: *AppMap, manifest_json: []const u8) bool {
        var wire_buf: [65536]u8 = undefined;
        const total = serializeMsg(.publish_req, 0, manifest_json, &wire_buf);
        if (total == 0) return false;

        const written = self.stream_mgr.writeToStream(0, wire_buf[0..total]);
        return written == total;
    }

    /// Send a search query on the Control lane (stream 0).
    /// Payload: query_len:u8 + query + layer_filter:u8 (0xFF = no filter)
    pub fn sendSearch(self: *AppMap, query: []const u8, layer_filter: ?u2) bool {
        var pos: u32 = 0;
        const query_len: u8 = @intCast(@min(query.len, 255));

        self.msg_buf[pos] = query_len;
        pos += 1;
        if (query_len > 0) {
            @memcpy(self.msg_buf[pos .. pos + query_len], query[0..query_len]);
            pos += query_len;
        }
        // layer_filter: 0xFF means no filter
        self.msg_buf[pos] = if (layer_filter) |lf| @as(u8, lf) else 0xFF;
        pos += 1;

        const payload_slice = self.msg_buf[0..pos];
        var wire_buf: [65536]u8 = undefined;
        const total = serializeMsg(.search_req, 0, payload_slice, &wire_buf);
        if (total == 0) return false;

        const written = self.stream_mgr.writeToStream(0, wire_buf[0..total]);
        return written == total;
    }

    pub const ControlResponse = struct {
        msg_type: MsgType,
        payload_len: u32,
    };

    /// Read a complete response from the Control lane (stream 0).
    /// Reads the 8-byte header first, then the payload into `out`.
    pub fn readControlResponse(self: *AppMap, out: []u8) ControlResponse {
        // Read header (8 bytes) from stream 0
        var hdr_buf: [8]u8 = undefined;
        const hdr_read = self.stream_mgr.readFromStream(0, &hdr_buf);
        if (hdr_read < header_size) {
            return .{ .msg_type = .hello, .payload_len = 0 };
        }

        // Parse header fields directly (don't use deserializeMsg which expects
        // the full message including payload in the buffer).
        const msg_type = hdr_buf[0];
        const plen: u32 = @as(u32, hdr_buf[4]) |
            (@as(u32, hdr_buf[5]) << 8) |
            (@as(u32, hdr_buf[6]) << 16) |
            (@as(u32, hdr_buf[7]) << 24);

        if (plen > 0 and out.len >= plen) {
            const payload_read = self.stream_mgr.readFromStream(0, out[0..plen]);
            _ = payload_read;
        }

        return .{
            .msg_type = @enumFromInt(msg_type),
            .payload_len = plen,
        };
    }

    // ── Bulk Lane Operations (25.4) ──

    /// Request a tarball download on a new Bulk lane stream.
    /// Opens a new bidirectional stream (4, 8, 12, ...) and writes the request.
    /// Returns the stream ID, or null if stream limit reached.
    pub fn requestTarball(self: *AppMap, url: []const u8) ?u62 {
        // Open a new bidi stream — IDs will be 0, 4, 8, 12, ...
        // Stream 0 is the control lane, so bulk starts at 4.
        const stream_id = self.stream_mgr.openStream(true) orelse return null;

        // Write a tarball request message on the new stream
        var wire_buf: [65536]u8 = undefined;
        const total = serializeMsg(.resolve_req, 0, url, &wire_buf);
        if (total == 0) return null;

        const written = self.stream_mgr.writeToStream(stream_id, wire_buf[0..total]);
        if (written == 0) return null;

        return @intCast(stream_id);
    }

    /// Read tarball data from a Bulk lane stream.
    pub fn readTarball(self: *AppMap, stream_id: u62, out: []u8) u32 {
        return self.stream_mgr.readFromStream(@intCast(stream_id), out);
    }

    // ── Hot Lane Operations (25.5) ──

    pub const HotResult = struct {
        msg_type: MsgType,
        payload: []const u8,
    };

    /// Process an incoming Hot lane datagram.
    /// Deserializes the AppMsgHeader, checks seq > last_hot_seq (latest-wins).
    /// Returns message type + payload if newer, null if older/equal.
    pub fn processHotDatagram(self: *AppMap, data: []const u8) ?HotResult {
        const result = deserializeMsg(data);
        if (result.err) return null;

        const seq = result.header.seq;

        // First datagram (last_hot_seq == 0 and seq == 0) is always accepted.
        // Otherwise, only accept if strictly newer.
        if (self.last_hot_seq == 0 and seq == 0) {
            // First datagram — accept
        } else if (seq <= self.last_hot_seq) {
            return null; // older or equal — discard
        }

        self.last_hot_seq = seq;
        return .{
            .msg_type = @enumFromInt(result.header.msg_type),
            .payload = result.payload,
        };
    }
};

// ── Tests ──

const testing = @import("std").testing;

// Module-level test state
var test_storage: streams.StreamArray = undefined;
var test_stream_mgr: streams.StreamManager = undefined;
var test_dgrams: datagram.DatagramHandler = undefined;
var test_appmap: AppMap = undefined;

fn initTestState() void {
    test_stream_mgr.init(&test_storage, false);
    test_dgrams = datagram.DatagramHandler.init();
    test_dgrams.enabled = true;
    test_dgrams.max_size = 1200;
    test_dgrams.peer_max_size = 1200;
    test_appmap = AppMap.init(&test_stream_mgr, &test_dgrams);
    // Open stream 0 (control lane)
    _ = test_stream_mgr.openStream(true);
}

// ── 25.7: Message round-trip tests ──

test "msg round-trip: resolve_req" {
    var buf: [256]u8 = undefined;
    const payload = "test-payload";
    const written = AppMap.serializeMsg(.resolve_req, 0, payload, &buf);
    try testing.expect(written > 0);

    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0x10), result.header.msg_type);
    try testing.expectEqual(@as(u32, payload.len), result.header.payload_len);
    try testing.expectEqualSlices(u8, payload, result.payload);
}

test "msg round-trip: publish_req with JSON" {
    var buf: [512]u8 = undefined;
    const json = "{\"name\":\"test\",\"version\":\"1.0.0\"}";
    const written = AppMap.serializeMsg(.publish_req, 0, json, &buf);
    try testing.expect(written > 0);

    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0x20), result.header.msg_type);
    try testing.expectEqualSlices(u8, json, result.payload);
}

test "msg round-trip: search_req" {
    var buf: [256]u8 = undefined;
    const payload = "search-query";
    const written = AppMap.serializeMsg(.search_req, 42, payload, &buf);
    try testing.expect(written > 0);

    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0x30), result.header.msg_type);
    try testing.expectEqual(@as(u16, 42), result.header.seq);
    try testing.expectEqualSlices(u8, payload, result.payload);
}

test "msg round-trip: hello (empty payload)" {
    var buf: [16]u8 = undefined;
    const written = AppMap.serializeMsg(.hello, 0, &[_]u8{}, &buf);
    try testing.expectEqual(@as(u32, 8), written);

    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0x01), result.header.msg_type);
    try testing.expectEqual(@as(u32, 0), result.header.payload_len);
    try testing.expectEqual(@as(usize, 0), result.payload.len);
}

test "msg round-trip: close (empty payload)" {
    var buf: [16]u8 = undefined;
    const written = AppMap.serializeMsg(.close, 0, &[_]u8{}, &buf);
    try testing.expectEqual(@as(u32, 8), written);

    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0xFF), result.header.msg_type);
}

test "msg round-trip: all message types" {
    const types = [_]MsgType{
        .hello, .hello_ack, .resolve_req, .resolve_resp,
        .publish_req, .publish_resp, .search_req, .search_resp,
        .close, .invalidation, .version_announce, .telemetry_ping,
    };
    for (types) |mt| {
        var buf: [64]u8 = undefined;
        const written = AppMap.serializeMsg(mt, 7, "data", &buf);
        try testing.expect(written > 0);
        const result = AppMap.deserializeMsg(buf[0..written]);
        try testing.expect(!result.err);
        try testing.expectEqual(@intFromEnum(mt), result.header.msg_type);
    }
}

test "deserializeMsg: truncated buffer returns error" {
    const buf = [_]u8{ 0x01, 0x00, 0x00 }; // only 3 bytes, need 8
    const result = AppMap.deserializeMsg(&buf);
    try testing.expect(result.err);
}

test "deserializeMsg: payload_len exceeds buffer returns error" {
    var buf: [16]u8 = undefined;
    // Write header claiming 100 bytes of payload but only provide 8 bytes total
    _ = AppMap.serializeMsg(.hello, 0, "x" ** 8, &buf);
    // Corrupt payload_len to claim more
    buf[4] = 100;
    const result = AppMap.deserializeMsg(buf[0..16]);
    try testing.expect(result.err);
}

test "msg round-trip: resolve_req structured payload encoding" {
    // Build the resolve_req payload manually: scope_len + scope + name_len + name + ver_len + ver
    const scope = "@myorg";
    const name = "my-package";
    const version = "2.3.1";
    var payload: [256]u8 = undefined;
    var pos: usize = 0;
    payload[pos] = @intCast(scope.len);
    pos += 1;
    @memcpy(payload[pos .. pos + scope.len], scope);
    pos += scope.len;
    payload[pos] = @intCast(name.len);
    pos += 1;
    @memcpy(payload[pos .. pos + name.len], name);
    pos += name.len;
    payload[pos] = @intCast(version.len);
    pos += 1;
    @memcpy(payload[pos .. pos + version.len], version);
    pos += version.len;

    // Serialize full message
    var buf: [512]u8 = undefined;
    const written = AppMap.serializeMsg(.resolve_req, 0, payload[0..pos], &buf);
    try testing.expect(written > 0);

    // Deserialize and verify header
    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0x10), result.header.msg_type);
    try testing.expectEqual(@as(u32, @intCast(pos)), result.header.payload_len);

    // Verify payload structure field by field
    const p = result.payload;
    var rpos: usize = 0;
    // scope_len + scope
    try testing.expectEqual(@as(u8, @intCast(scope.len)), p[rpos]);
    rpos += 1;
    try testing.expectEqualSlices(u8, scope, p[rpos .. rpos + scope.len]);
    rpos += scope.len;
    // name_len + name
    try testing.expectEqual(@as(u8, @intCast(name.len)), p[rpos]);
    rpos += 1;
    try testing.expectEqualSlices(u8, name, p[rpos .. rpos + name.len]);
    rpos += name.len;
    // version_len + version
    try testing.expectEqual(@as(u8, @intCast(version.len)), p[rpos]);
    rpos += 1;
    try testing.expectEqualSlices(u8, version, p[rpos .. rpos + version.len]);
    rpos += version.len;
    // Consumed entire payload
    try testing.expectEqual(pos, rpos);
}

test "msg round-trip: resolve_req with no version" {
    // scope_len + scope + name_len + name + ver_len(0)
    var payload: [128]u8 = undefined;
    var pos: usize = 0;
    payload[pos] = 3; // scope "abc"
    pos += 1;
    @memcpy(payload[pos .. pos + 3], "abc");
    pos += 3;
    payload[pos] = 4; // name "test"
    pos += 1;
    @memcpy(payload[pos .. pos + 4], "test");
    pos += 4;
    payload[pos] = 0; // no version
    pos += 1;

    var buf: [256]u8 = undefined;
    const written = AppMap.serializeMsg(.resolve_req, 0, payload[0..pos], &buf);
    try testing.expect(written > 0);

    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    const p = result.payload;
    // Verify version_len is 0
    try testing.expectEqual(@as(u8, 0), p[1 + 3 + 1 + 4]);
}

test "msg round-trip: search_req structured payload encoding" {
    // Build search_req payload: query_len + query + layer_filter
    const query = "crypto-utils";
    var payload: [256]u8 = undefined;
    var pos: usize = 0;
    payload[pos] = @intCast(query.len);
    pos += 1;
    @memcpy(payload[pos .. pos + query.len], query);
    pos += query.len;
    payload[pos] = 2; // layer_filter = 2
    pos += 1;

    var buf: [512]u8 = undefined;
    const written = AppMap.serializeMsg(.search_req, 0, payload[0..pos], &buf);
    try testing.expect(written > 0);

    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0x30), result.header.msg_type);

    // Verify payload structure
    const p = result.payload;
    var rpos: usize = 0;
    try testing.expectEqual(@as(u8, @intCast(query.len)), p[rpos]);
    rpos += 1;
    try testing.expectEqualSlices(u8, query, p[rpos .. rpos + query.len]);
    rpos += query.len;
    try testing.expectEqual(@as(u8, 2), p[rpos]); // layer_filter
    rpos += 1;
    try testing.expectEqual(pos, rpos);
}

test "msg round-trip: search_req with no layer filter" {
    var payload: [256]u8 = undefined;
    var pos: usize = 0;
    payload[pos] = 5; // query "hello"
    pos += 1;
    @memcpy(payload[pos .. pos + 5], "hello");
    pos += 5;
    payload[pos] = 0xFF; // no filter
    pos += 1;

    var buf: [256]u8 = undefined;
    const written = AppMap.serializeMsg(.search_req, 0, payload[0..pos], &buf);
    try testing.expect(written > 0);

    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    const p = result.payload;
    try testing.expectEqual(@as(u8, 0xFF), p[6]); // no filter marker
}

test "msg round-trip: seq field preserved" {
    var buf: [64]u8 = undefined;
    const written = AppMap.serializeMsg(.invalidation, 0xBEEF, "x", &buf);
    try testing.expect(written > 0);
    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u16, 0xBEEF), result.header.seq);
}

test "msg round-trip: flags field is zero" {
    var buf: [64]u8 = undefined;
    _ = AppMap.serializeMsg(.hello_ack, 0, "data", &buf);
    const result = AppMap.deserializeMsg(&buf);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0), result.header.flags);
}

test "msg round-trip: large payload" {
    var payload: [4096]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    var buf: [4200]u8 = undefined;
    const written = AppMap.serializeMsg(.publish_resp, 100, &payload, &buf);
    try testing.expect(written == 8 + 4096);

    const result = AppMap.deserializeMsg(buf[0..written]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u32, 4096), result.header.payload_len);
    try testing.expectEqualSlices(u8, &payload, result.payload);
}

// ── 25.8: Hot lane latest-wins tests ──

test "hot lane: seq=1 accepted, seq=2 accepted, seq=1 rejected" {
    initTestState();

    var buf1: [32]u8 = undefined;
    _ = AppMap.serializeMsg(.invalidation, 1, "a", &buf1);
    const r1 = test_appmap.processHotDatagram(buf1[0..9]);
    try testing.expect(r1 != null);

    var buf2: [32]u8 = undefined;
    _ = AppMap.serializeMsg(.invalidation, 2, "b", &buf2);
    const r2 = test_appmap.processHotDatagram(buf2[0..9]);
    try testing.expect(r2 != null);

    // seq=1 again — should be rejected (older)
    const r3 = test_appmap.processHotDatagram(buf1[0..9]);
    try testing.expect(r3 == null);
}

test "hot lane: seq=5 accepted, seq=3 rejected, seq=6 accepted" {
    initTestState();

    var buf5: [32]u8 = undefined;
    _ = AppMap.serializeMsg(.version_announce, 5, "v", &buf5);
    try testing.expect(test_appmap.processHotDatagram(buf5[0..9]) != null);

    var buf3: [32]u8 = undefined;
    _ = AppMap.serializeMsg(.version_announce, 3, "v", &buf3);
    try testing.expect(test_appmap.processHotDatagram(buf3[0..9]) == null);

    var buf6: [32]u8 = undefined;
    _ = AppMap.serializeMsg(.version_announce, 6, "v", &buf6);
    try testing.expect(test_appmap.processHotDatagram(buf6[0..9]) != null);
}

test "hot lane: first datagram seq=0 always accepted" {
    initTestState();

    var buf: [32]u8 = undefined;
    _ = AppMap.serializeMsg(.telemetry_ping, 0, "p", &buf);
    const r = test_appmap.processHotDatagram(buf[0..9]);
    try testing.expect(r != null);
}

// ── 25.9: Control lane tests ──

test "control lane: sendResolve writes to stream 0" {
    initTestState();

    const ok = test_appmap.sendResolve("@scope", "pkg-name", "1.0.0");
    try testing.expect(ok);

    // Read back from stream 0's send buffer (writeToStream writes to send_buf)
    const s0 = test_stream_mgr.getStream(0).?;
    var out: [256]u8 = undefined;
    const read_n = s0.send_buf.read(&out);
    try testing.expect(read_n > 8); // at least header

    // Verify header
    const result = AppMap.deserializeMsg(out[0..read_n]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0x10), result.header.msg_type); // resolve_req

    // Verify payload structure: scope_len + scope + name_len + name + ver_len + ver
    const p = result.payload;
    try testing.expect(p.len > 0);
    try testing.expectEqual(@as(u8, 6), p[0]); // scope_len "@scope"
    try testing.expectEqualSlices(u8, "@scope", p[1..7]);
    try testing.expectEqual(@as(u8, 8), p[7]); // name_len "pkg-name"
    try testing.expectEqualSlices(u8, "pkg-name", p[8..16]);
    try testing.expectEqual(@as(u8, 5), p[16]); // ver_len "1.0.0"
    try testing.expectEqualSlices(u8, "1.0.0", p[17..22]);
}

test "control lane: sendPublish writes JSON to stream 0" {
    initTestState();

    const json = "{\"name\":\"test\"}";
    const ok = test_appmap.sendPublish(json);
    try testing.expect(ok);

    const s0 = test_stream_mgr.getStream(0).?;
    var out: [256]u8 = undefined;
    const read_n = s0.send_buf.read(&out);
    try testing.expect(read_n > 8);

    const result = AppMap.deserializeMsg(out[0..read_n]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0x20), result.header.msg_type);
    try testing.expectEqualSlices(u8, json, result.payload);
}

test "control lane: sendSearch writes query to stream 0" {
    initTestState();

    const ok = test_appmap.sendSearch("test-query", null);
    try testing.expect(ok);

    const s0 = test_stream_mgr.getStream(0).?;
    var out: [256]u8 = undefined;
    const read_n = s0.send_buf.read(&out);
    try testing.expect(read_n > 8);

    const result = AppMap.deserializeMsg(out[0..read_n]);
    try testing.expect(!result.err);
    try testing.expectEqual(@as(u8, 0x30), result.header.msg_type);
    // Payload: query_len + query + layer_filter
    const p = result.payload;
    try testing.expectEqual(@as(u8, 10), p[0]); // "test-query" len
    try testing.expectEqualSlices(u8, "test-query", p[1..11]);
    try testing.expectEqual(@as(u8, 0xFF), p[11]); // no filter
}

test "control lane: sendSearch with layer filter" {
    initTestState();

    const ok = test_appmap.sendSearch("zig-lib", 2);
    try testing.expect(ok);

    const s0 = test_stream_mgr.getStream(0).?;
    var out: [256]u8 = undefined;
    const read_n = s0.send_buf.read(&out);
    try testing.expect(read_n > 8);

    const result = AppMap.deserializeMsg(out[0..read_n]);
    try testing.expect(!result.err);
    const p = result.payload;
    try testing.expectEqual(@as(u8, 7), p[0]); // "zig-lib" len
    try testing.expectEqual(@as(u8, 2), p[8]); // layer_filter = 2
}

test "control lane: multiple sequential requests on stream 0" {
    initTestState();

    // Send resolve, then publish — both should succeed on stream 0
    try testing.expect(test_appmap.sendResolve("@a", "b", null));
    try testing.expect(test_appmap.sendPublish("{\"v\":1}"));

    // Both messages should be in the send buffer sequentially
    const s0 = test_stream_mgr.getStream(0).?;
    var out: [512]u8 = undefined;
    const total_read = s0.send_buf.read(&out);
    try testing.expect(total_read > 16); // at least two 8-byte headers

    // First message: resolve_req
    const r1 = AppMap.deserializeMsg(out[0..total_read]);
    try testing.expect(!r1.err);
    try testing.expectEqual(@as(u8, 0x10), r1.header.msg_type);

    // Second message starts after first
    const first_len = header_size + r1.header.payload_len;
    const r2 = AppMap.deserializeMsg(out[first_len..total_read]);
    try testing.expect(!r2.err);
    try testing.expectEqual(@as(u8, 0x20), r2.header.msg_type);
}

// ── 25.10: Bulk lane tests ──

test "bulk lane: requestTarball opens streams 4, 8, 12" {
    initTestState();
    // Stream 0 already opened by initTestState

    const id1 = test_appmap.requestTarball("https://example.com/pkg.tar");
    try testing.expect(id1 != null);
    try testing.expectEqual(@as(u62, 4), id1.?);

    const id2 = test_appmap.requestTarball("https://example.com/pkg2.tar");
    try testing.expect(id2 != null);
    try testing.expectEqual(@as(u62, 8), id2.?);

    const id3 = test_appmap.requestTarball("https://example.com/pkg3.tar");
    try testing.expect(id3 != null);
    try testing.expectEqual(@as(u62, 12), id3.?);
}

test "bulk lane: readTarball reads from correct stream" {
    initTestState();

    // Open a bulk stream and write data to its recv buffer (simulating incoming data)
    const sid = test_stream_mgr.openStream(true) orelse unreachable; // stream 4
    const s = test_stream_mgr.getStream(sid).?;
    _ = s.recv_buf.write("tarball-data-here");

    var out: [64]u8 = undefined;
    const read_n = test_appmap.readTarball(@intCast(sid), &out);
    try testing.expect(read_n > 0);
    try testing.expectEqualSlices(u8, "tarball-data-here", out[0..read_n]);
}

test "bulk lane: requestTarball returns null when stream limit reached" {
    initTestState();
    // Open streams until limit is reached (stream 0 already open from initTestState)
    var i: u16 = 1;
    while (i < streams.max_concurrent_streams) : (i += 1) {
        _ = test_stream_mgr.openStream(true);
    }
    // Now requestTarball should fail
    const result = test_appmap.requestTarball("https://example.com/overflow.tar");
    try testing.expect(result == null);
}
