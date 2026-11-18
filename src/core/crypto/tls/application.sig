//! TLS 1.3 application record state over caller-owned stream buffers.
const std = @import("std");
const record = @import("record.sig");

pub const Error = record.Error || error{ InvalidKeyUpdate, KeyUpdateRequired, Closed, PeerAlert };
pub const Incoming = union(enum) {
    data: []const u8,
    handshake_fragment,
    key_update,
    close_notify,
    user_canceled,
};

const Direction = struct {
    secret: [48]u8 = @splat(0),
    keys: record.RecordKeys,

    fn init(suite: record.Suite, secret: []const u8) Direction {
        var direction: Direction = .{ .keys = record.RecordKeys.initSuite(suite, secret) };
        @memcpy(direction.secret[0..suite.hash_len], secret);
        return direction;
    }

    fn rotate(self: *Direction, suite: record.Suite) void {
        record.nextTrafficSecret(suite, &self.secret);
        std.crypto.secureZero(u8, std.mem.asBytes(&self.keys));
        self.keys = record.RecordKeys.initSuite(suite, self.secret[0..suite.hash_len]);
    }

    fn erase(self: *Direction) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

pub const Application = struct {
    suite: record.Suite,
    send: Direction,
    receive: Direction,
    incoming_update: [5]u8 = @splat(0),
    incoming_used: usize = 0,
    sent_updates: u64 = 0,
    update_owed: bool = false,
    update_requested: bool = false,
    send_closed: bool = false,
    receive_closed: bool = false,
    receive_failed: bool = false,

    pub fn init(id: u16, send_secret: []const u8, receive_secret: []const u8) Error!Application {
        const suite = record.suiteById(id) orelse return error.UnsupportedCipherSuite;
        if (send_secret.len != suite.hash_len or receive_secret.len != suite.hash_len)
            return error.InvalidSecret;
        return .{
            .suite = suite,
            .send = Direction.init(suite, send_secret),
            .receive = Direction.init(suite, receive_secret),
        };
    }

    /// Open exactly one complete protected record. Data borrows input.
    /// On error, the transport owns the fatal alert and must close the stream.
    pub fn open(self: *Application, input: []u8) Error!Incoming {
        if (self.receive_closed or self.receive_failed) return error.Closed;
        errdefer {
            self.receive_failed = true;
            self.receive.erase();
        }
        const decoded = try self.receive.keys.openProtected(input);
        if (self.incoming_used != 0 and decoded.content_type != .handshake)
            return error.UnexpectedMessage;
        switch (decoded.content_type) {
            .application_data => return .{ .data = decoded.content },
            .alert => switch (decoded.content[1]) {
                0 => {
                    self.receive_closed = true;
                    self.receive.erase();
                    return .close_notify;
                },
                90 => return .user_canceled,
                else => {
                    self.send_closed = true;
                    self.send.erase();
                    return error.PeerAlert;
                },
            },
            .handshake => return self.openUpdate(decoded.content),
        }
    }

    fn openUpdate(self: *Application, content: []const u8) Error!Incoming {
        if (content.len > self.incoming_update.len - self.incoming_used) return error.UnexpectedMessage;
        @memcpy(self.incoming_update[self.incoming_used..][0..content.len], content);
        self.incoming_used += content.len;
        const header = [_]u8{ 24, 0, 0, 1 };
        const observed = @min(self.incoming_used, header.len);
        if (!std.mem.eql(u8, self.incoming_update[0..observed], header[0..observed]))
            return error.UnexpectedMessage;
        if (self.incoming_used < self.incoming_update.len) return .handshake_fragment;
        const request = self.incoming_update[header.len];
        if (request > 1) return error.InvalidKeyUpdate;

        self.receive.rotate(self.suite);
        self.incoming_used = 0;
        self.update_requested = false;
        if (request == 1 and !self.send_closed and self.sent_updates < record.max_send_key_updates)
            self.update_owed = true;
        return .key_update;
    }

    pub fn needsUpdateBeforeData(self: *const Application) bool {
        return !self.send_closed and self.sent_updates < record.max_send_key_updates and
            (self.update_owed or self.send.keys.remainingSendRecords() == 1);
    }

    /// On success, send the retained record in full before another sealing call.
    /// Application content starts at record.header_bytes in output.
    pub fn sealData(self: *Application, output: []u8, content_len: usize) Error![]const u8 {
        if (self.send_closed or self.receive_failed) return error.Closed;
        if (self.needsUpdateBeforeData()) return error.KeyUpdateRequired;
        return self.send.keys.sealProtected(output, .application_data, content_len, 0);
    }

    /// Seal the update under the current keys, then switch only the send direction.
    pub fn sealUpdate(self: *Application, output: []u8, request_peer: bool) Error![]const u8 {
        if (self.send_closed or self.receive_failed) return error.Closed;
        if (self.sent_updates == record.max_send_key_updates) return error.KeyUseLimit;
        if (request_peer and (self.update_owed or self.update_requested)) return error.KeyUpdateRequired;
        if (output.len < record.header_bytes + self.incoming_update.len) return error.BufferTooSmall;
        output[record.header_bytes..][0..5].* = .{ 24, 0, 0, 1, @intFromBool(request_peer) };
        const sealed = try self.send.keys.sealProtected(output, .handshake, 5, 0);
        self.send.rotate(self.suite);
        self.sent_updates += 1;
        self.update_owed = false;
        if (request_peer) self.update_requested = true;
        return sealed;
    }

    pub fn sealAlert(self: *Application, output: []u8, description: u8) Error![]const u8 {
        if (self.send_closed or (self.receive_failed and (description == 0 or description == 90)))
            return error.Closed;
        if (output.len < record.header_bytes + 2) return error.BufferTooSmall;
        output[record.header_bytes..][0..2].* = .{ if (description == 0 or description == 90) 1 else 2, description };
        const sealed = try self.send.keys.sealProtected(output, .alert, 2, 0);
        if (description == 0) {
            self.send_closed = true;
            self.send.erase();
        } else if (description != 90) self.close();
        return sealed;
    }

    pub fn close(self: *Application) void {
        self.send.erase();
        self.receive.erase();
        self.send_closed = true;
        self.receive_closed = true;
    }
};

test "application rekeys only after the complete old-key message" {
    const testing = std.testing;
    const suite = record.SUITE_AES128;
    const a = @as([32]u8, @splat(0x28));
    const b = @as([32]u8, @splat(0x6a));
    const update = [_]u8{ 24, 0, 0, 1, 1 };
    var out: [128]u8 = undefined;
    for (1..update.len) |split| {
        var peer = Direction.init(suite, &a);
        defer peer.erase();
        var server = try Application.init(suite.id, &b, &a);
        defer server.close();
        @memcpy(out[record.header_bytes..][0..split], update[0..split]);
        var sealed = try peer.keys.sealProtected(&out, .handshake, split, 0);
        try testing.expect((try server.open(out[0..sealed.len])) == .handshake_fragment);
        try testing.expectEqual(@as(u64, 1), server.receive.keys.seq);
        @memcpy(out[record.header_bytes..][0..update.len - split], update[split..]);
        sealed = try peer.keys.sealProtected(&out, .handshake, update.len - split, 0);
        try testing.expect((try server.open(out[0..sealed.len])) == .key_update);
        try testing.expectEqual(@as(u64, 0), server.receive.keys.seq);
        try testing.expect(server.needsUpdateBeforeData());
        try testing.expectError(error.KeyUpdateRequired, server.sealData(&out, 0));
        try testing.expectError(error.BufferTooSmall, server.sealUpdate(out[0..10], false));
        try testing.expect(server.needsUpdateBeforeData());

        peer.rotate(suite);
        out[record.header_bytes] = 42;
        sealed = try peer.keys.sealProtected(&out, .application_data, 1, 0);
        try testing.expectEqualSlices(u8, &.{42}, (try server.open(out[0..sealed.len])).data);
        var other = try Application.init(suite.id, &a, &b);
        defer other.close();
        sealed = try server.sealUpdate(&out, false);
        try testing.expect((try other.open(out[0..sealed.len])) == .key_update);
        try testing.expect(!server.needsUpdateBeforeData() and !other.needsUpdateBeforeData());
        out[record.header_bytes] = 7;
        sealed = try server.sealData(&out, 1);
        try testing.expectEqualSlices(u8, &.{7}, (try other.open(out[0..sealed.len])).data);
        sealed = try server.sealAlert(&out, 0);
        try testing.expect((try other.open(out[0..sealed.len])) == .close_notify);
        try testing.expectError(error.Closed, server.sealData(&out, 0));
        try testing.expectError(error.Closed, other.open(out[0..sealed.len]));
    }
}

test "application rejects invalid key updates and never accepts the newer epoch first" {
    const testing = std.testing;
    const suite = record.SUITE_AES128;
    const secret = @as([32]u8, @splat(93));
    var input: [128]u8 = undefined;

    var peer = Direction.init(suite, &secret);
    defer peer.erase();
    var receiver = try Application.init(suite.id, &secret, &secret);
    defer receiver.close();
    input[record.header_bytes..][0..5].* = .{ 24, 0, 0, 1, 2 };
    const invalid = try peer.keys.sealProtected(&input, .handshake, 5, 0);
    try testing.expectError(error.InvalidKeyUpdate, receiver.open(input[0..invalid.len]));
    try testing.expectError(error.Closed, receiver.open(input[0..invalid.len]));
    try testing.expectError(error.Closed, receiver.sealData(&input, 0));
    const alert = try receiver.sealAlert(&input, 47);
    var alert_peer = Direction.init(suite, &secret);
    defer alert_peer.erase();
    try testing.expectEqualSlices(u8, &.{ 2, 47 }, (try alert_peer.keys.openProtected(input[0..alert.len])).content);

    var fresh = try Application.init(suite.id, &secret, &secret);
    defer fresh.close();
    peer.rotate(suite);
    const early = try peer.keys.sealProtected(&input, .application_data, 0, 0);
    try testing.expectError(error.DecryptFailed, fresh.open(input[0..early.len]));
}

test "application reserves the last send record for rekeying" {
    const testing = std.testing;
    const suite = record.SUITE_AES128;
    const secret = @as([32]u8, @splat(35));
    var application = try Application.init(suite.id, &secret, &secret);
    defer application.close();
    var output: [64]u8 = undefined;
    application.send.keys.seq = application.send.keys.remainingSendRecords() - 1;
    try testing.expect(application.needsUpdateBeforeData());
    try testing.expectError(error.KeyUpdateRequired, application.sealData(&output, 0));
    _ = try application.sealUpdate(&output, true);
    try testing.expectEqual(@as(u64, 0), application.send.keys.seq);
    try testing.expectError(error.KeyUpdateRequired, application.sealUpdate(&output, true));
    _ = try application.sealData(&output, 0);
    application.sent_updates = record.max_send_key_updates;
    try testing.expectError(error.KeyUseLimit, application.sealUpdate(&output, false));
}
