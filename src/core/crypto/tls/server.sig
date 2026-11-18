//! Private, caller-buffered TLS 1.3 server exchange for a configured P-256
//! identity. The transport owns I/O, timers, and alert transmission.
const std = @import("std");
const entropy = @import("entropy");
const sha256 = @import("sha256");
const x25519 = @import("x25519");
const key_schedule = @import("tls13_keys").KeySchedule;
const hello = @import("client_hello.sig");
const record = @import("record.sig");
const application = @import("application.sig");
const x509 = @import("x509.sig");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const suite = record.SUITE_AES128.id;
const max_session_id = 32;
const server_hello_extension_bytes = 46;
const server_hello_body_bytes = 2 + 32 + 1 + 2 + 1 + 2 + server_hello_extension_bytes;
const handshake_header_bytes = 4;
const verify_bytes = 32;
const finished_bytes = handshake_header_bytes + verify_bytes;
const certificate_list_limit = std.math.maxInt(u24) - 4;
const record_overhead = record.header_bytes + 1 + 16;
const compatibility_ccs = [_]u8{ 20, 3, 3, 0, 1, 1 };
const certificate_verify_prefix = ([_]u8{0x20} ** 64) ++ "TLS 1.3, server CertificateVerify\x00";

pub const Error = hello.Error || application.Error || error{
    InvalidCertificate,
    InvalidPrivateKey,
    EntropyUnavailable,
    InvalidPeerKey,
    SigningFailed,
    BadFinished,
    InvalidAlpnProtocol,
    NoApplicationProtocol,
    MissingAlpnExtension,
};

/// Borrow immutable DER leaf-first chain bytes for all referencing exchanges.
pub const Identity = struct {
    chain: []const []const u8,
    key_pair: Ecdsa.KeyPair,
    certificate_list_bytes: usize,

    pub fn init(chain: []const []const u8, private_key: *const [32]u8) Error!Identity {
        if (chain.len == 0) return error.InvalidCertificate;
        var certificate_list_bytes: usize = 0;
        for (chain, 0..) |der, index| {
            if (der.len == 0 or der.len > certificate_list_limit - certificate_list_bytes) return error.InvalidCertificate;
            if (certificate_list_limit - certificate_list_bytes - der.len < 5) return error.InvalidCertificate;
            if (index != 0) _ = x509.parse(der) catch return error.InvalidCertificate;
            certificate_list_bytes += der.len + 5;
        }
        const leaf = x509.parse(chain[0]) catch return error.InvalidCertificate;
        if (leaf.key_alg != .ecdsa_p256 or leaf.unknown_critical or leaf.is_ca) return error.InvalidCertificate;
        if (leaf.has_key_usage and leaf.key_usage & x509.KU_DIGITAL_SIGNATURE == 0) return error.InvalidCertificate;
        if (leaf.has_eku and !leaf.eku_server_auth and !leaf.eku_any) return error.InvalidCertificate;
        const secret = Ecdsa.SecretKey.fromBytes(private_key.*) catch return error.InvalidPrivateKey;
        const key_pair = Ecdsa.KeyPair.fromSecretKey(secret) catch return error.InvalidPrivateKey;
        if (!std.mem.eql(u8, leaf.ec_point, &key_pair.public_key.toUncompressedSec1())) return error.InvalidPrivateKey;
        return .{ .chain = chain, .key_pair = key_pair, .certificate_list_bytes = certificate_list_bytes };
    }

    pub fn flightScratchBytes(self: *const Identity) usize {
        const encrypted_extensions = handshake_header_bytes + 2;
        const certificate = handshake_header_bytes + 4 + self.certificate_list_bytes;
        const certificate_verify = handshake_header_bytes + 4 + Ecdsa.Signature.der_encoded_length_max;
        return encrypted_extensions + certificate + certificate_verify + finished_bytes;
    }

    pub fn flightOutputBytes(self: *const Identity) usize {
        return flightOutputCapacity(self.flightScratchBytes());
    }
};

fn flightOutputCapacity(protected: usize) usize {
    const server_hello = record.header_bytes + handshake_header_bytes + server_hello_body_bytes + max_session_id;
    const chunks = (protected + record.max_plaintext_bytes - 1) / record.max_plaintext_bytes;
    return server_hello + compatibility_ccs.len + protected + chunks * record_overhead;
}

/// One configured opaque protocol, borrowed immutably until the exchange ends.
pub const Alpn = struct { protocol: []const u8, required: bool = false };

/// A fatal alert sent before ServerHello and before record protection is active.
pub const no_application_protocol_alert = [_]u8{ 21, 3, 3, 0, 2, 2, 120 };
pub const missing_alpn_extension_alert = [_]u8{ 21, 3, 3, 0, 2, 2, 109 };

pub const Phase = enum { client_hello, server_flight, client_finished, established, transferred, failed };
pub const FrameRead = union(enum) {
    need: usize,
    consumed: usize,
};
pub const Application = application.Application;

pub const Server = struct {
    identity: *const Identity,
    hello_buffer: []u8,
    alpn: ?Alpn = null,
    alpn_matched: bool = false,
    hello_len: usize = 0,
    parsed: ?hello.Hello = null,
    phase: Phase = .client_hello,
    client_handshake: ?record.RecordKeys = null,
    expected_finished: [verify_bytes]u8 = @splat(0),
    finished: [finished_bytes]u8 = undefined,
    finished_len: usize = 0,
    application: ?Application = null,

    /// The caller retains both objects and uses distinct stream and flight buffers.
    pub fn init(identity: *const Identity, hello_buffer: []u8) Server {
        return .{ .identity = identity, .hello_buffer = hello_buffer };
    }

    pub fn initWithAlpn(identity: *const Identity, hello_buffer: []u8, alpn: ?Alpn) Error!Server {
        if (alpn) |policy| {
            if (policy.protocol.len == 0 or policy.protocol.len > 255) return error.InvalidAlpnProtocol;
            if (overlaps(policy.protocol, hello_buffer)) return error.BadRecord;
        }
        var server = init(identity, hello_buffer);
        server.alpn = alpn;
        return server;
    }

    pub fn flightScratchBytes(self: *const Server) usize {
        return self.identity.flightScratchBytes() + if (self.alpn) |policy| alpnBytes(policy.protocol) else 0;
    }

    pub fn flightOutputBytes(self: *const Server) usize {
        return flightOutputCapacity(self.flightScratchBytes());
    }

    fn alpnBytes(protocol: []const u8) usize {
        return 2 + 2 + 2 + 1 + protocol.len;
    }

    /// The successful selection is exposed after Finished authentication.
    pub fn selectedAlpn(self: *const Server) ?[]const u8 {
        if (self.phase != .established and self.phase != .transferred) return null;
        return if (self.alpn_matched) self.alpn.?.protocol else null;
    }

    /// Consume only the first complete record. On .need, keep the input prefix
    /// and append bytes until the required total is available.
    pub fn receive(self: *Server, input: []u8) Error!FrameRead {
        errdefer self.close();
        if (self.phase != .client_hello and self.phase != .client_finished) return error.UnexpectedMessage;
        if (overlaps(input, self.hello_buffer)) return error.BadRecord;
        if (self.alpn) |policy| if (overlaps(input, policy.protocol)) return error.BadRecord;
        const total = switch (try record.frame(input)) {
            .incomplete => |need| return .{ .need = need },
            .complete => |length| length,
        };
        const frame = input[0..total];
        switch (self.phase) {
            .client_hello => try self.receiveHello(frame),
            .client_finished => try self.receiveFinished(frame),
            else => unreachable,
        }
        return .{ .consumed = total };
    }

    fn receiveHello(self: *Server, frame: []const u8) Error!void {
        if (frame[0] != 22) return error.UnexpectedMessage;
        const bytes = frame[record.header_bytes..];
        if (bytes.len > record.max_plaintext_bytes) return error.RecordOverflow;
        if (bytes.len > self.hello_buffer.len - self.hello_len) return error.BufferTooSmall;
        @memcpy(self.hello_buffer[self.hello_len..][0..bytes.len], bytes);
        self.hello_len += bytes.len;
        if (self.hello_buffer[0] != 1) return error.UnexpectedMessage;
        if (self.hello_len < handshake_header_bytes) return;
        const length = handshake_header_bytes + @as(usize, std.mem.readInt(u24, self.hello_buffer[1..4], .big));
        if (length > self.hello_buffer.len) return error.BufferTooSmall;
        if (self.hello_len < length) return;
        if (self.hello_len != length) return error.UnexpectedMessage;
        const parsed = try hello.parseWithAlpn(self.hello_buffer[handshake_header_bytes..length],
            if (self.alpn) |policy| policy.protocol else null);
        if (self.alpn) |policy| {
            if (parsed.alpn_match) |matched| {
                if (!matched) return error.NoApplicationProtocol;
                self.alpn_matched = true;
            } else if (policy.required) return error.MissingAlpnExtension;
        }
        self.parsed = parsed;
        self.phase = .server_flight;
    }

    /// Generate a fresh ephemeral server flight into caller-owned buffers.
    /// The sender writes the returned bytes in order before consuming client Finished.
    pub fn emitFlight(self: *Server, scratch: []u8, output: []u8) Error![]const u8 {
        errdefer self.close();
        if (self.phase != .server_flight) return error.UnexpectedMessage;
        if (scratch.len < self.flightScratchBytes() or output.len < self.flightOutputBytes()) return error.BufferTooSmall;
        if (overlaps(scratch, output) or overlaps(scratch, self.hello_buffer) or overlaps(output, self.hello_buffer)) return error.BadRecord;
        if (self.alpn) |policy| {
            if (overlaps(scratch, policy.protocol) or overlaps(output, policy.protocol)) return error.BadRecord;
        }
        var random: [64 + Ecdsa.noise_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &random);
        entropy.fill(&random) catch return error.EntropyUnavailable;
        return self.emitWithEntropy(scratch, output, &random);
    }

    fn emitWithEntropy(self: *Server, scratch: []u8, output: []u8, random: *const [64 + Ecdsa.noise_length]u8) Error![]const u8 {
        const parsed = self.parsed.?;
        const public_key = x25519.publicKey(random[32..64]);
        var shared = x25519.sharedSecret(random[32..64], &parsed.key_share);
        defer std.crypto.secureZero(u8, &shared);
        if (std.crypto.timing_safe.eql([32]u8, shared, @splat(0))) return error.InvalidPeerKey;

        var outgoing: Writer = .{ .bytes = output };
        try writeServerHello(&outgoing, parsed.session_id, random[0..32], &public_key);
        var transcript = sha256.Sha256.init();
        transcript.update(self.hello_buffer[0..self.hello_len]);
        transcript.update(outgoing.written()[record.header_bytes..]);
        if (parsed.session_id.len != 0) try outgoing.put(&compatibility_ccs);

        var schedule = key_schedule.init(null);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&schedule));
        var client_secret: [32]u8 = undefined;
        var server_secret: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &client_secret);
        defer std.crypto.secureZero(u8, &server_secret);
        const first_hash = digest(transcript);
        schedule.deriveHandshakeSecrets(&shared, &first_hash, &client_secret, &server_secret);
        var sending = try record.keysForSuite(suite, &server_secret);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&sending));
        self.client_handshake = try record.keysForSuite(suite, &client_secret);

        var flight: Writer = .{ .bytes = scratch };
        try self.writeEncryptedExtensions(&flight);
        try self.writeCertificate(&flight);
        transcript.update(flight.written());
        try self.writeCertificateVerify(&flight, &transcript, random[64..][0..Ecdsa.noise_length].*);

        const server_hash = digest(transcript);
        const server_finished = key_schedule.computeFinished(&server_secret, &server_hash);
        const finished_start = flight.used;
        try flight.handshake(20, server_finished.len);
        try flight.put(&server_finished);
        transcript.update(flight.written()[finished_start..]);
        const application_hash = digest(transcript);
        self.expected_finished = key_schedule.computeFinished(&client_secret, &application_hash);
        schedule.deriveApplicationSecrets(&application_hash, &client_secret, &server_secret);
        self.application = try Application.init(suite, &server_secret, &client_secret);

        var body = flight.written();
        while (body.len != 0) {
            const take = @min(body.len, record.max_plaintext_bytes);
            const buffer = outgoing.bytes[outgoing.used..];
            if (buffer.len < take + record_overhead) return error.BufferTooSmall;
            @memcpy(buffer[record.header_bytes..][0..take], body[0..take]);
            const sealed = try sending.sealProtected(buffer, .handshake, take, 0);
            outgoing.used += sealed.len;
            body = body[take..];
        }
        self.parsed = null;
        self.phase = .client_finished;
        return outgoing.written();
    }

    fn writeEncryptedExtensions(self: *const Server, flight: *Writer) Error!void {
        const protocol = if (self.alpn_matched) self.alpn.?.protocol else "";
        const extensions = if (protocol.len != 0) alpnBytes(protocol) else 0;
        try flight.handshake(8, 2 + extensions);
        try flight.uint(u16, @intCast(extensions));
        if (protocol.len == 0) return;
        try flight.uint(u16, hello.alpn_extension);
        try flight.uint(u16, @intCast(3 + protocol.len));
        try flight.uint(u16, @intCast(1 + protocol.len));
        try flight.uint(u8, @intCast(protocol.len));
        try flight.put(protocol);
    }

    fn writeCertificate(self: *const Server, flight: *Writer) Error!void {
        const bytes = self.identity.certificate_list_bytes;
        try flight.handshake(11, 4 + bytes);
        try flight.uint(u8, 0);
        try flight.uint(u24, @intCast(bytes));
        for (self.identity.chain) |der| {
            try flight.uint(u24, @intCast(der.len));
            try flight.put(der);
            try flight.uint(u16, 0);
        }
    }

    fn writeCertificateVerify(self: *const Server, flight: *Writer, transcript: *sha256.Sha256, noise: [Ecdsa.noise_length]u8) Error!void {
        var signed: [certificate_verify_prefix.len + 32]u8 = undefined;
        @memcpy(signed[0..certificate_verify_prefix.len], certificate_verify_prefix[0..]);
        const hash = digest(transcript.*);
        @memcpy(signed[certificate_verify_prefix.len..], &hash);
        const signature = self.identity.key_pair.sign(&signed, noise) catch return error.SigningFailed;
        var der: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
        const encoded = signature.toDer(&der);
        const start = flight.used;
        try flight.handshake(15, 4 + encoded.len);
        try flight.uint(u16, 0x0403);
        try flight.uint(u16, @intCast(encoded.len));
        try flight.put(encoded);
        transcript.update(flight.written()[start..]);
    }

    fn receiveFinished(self: *Server, frame: []u8) Error!void {
        if (frame[0] == 20) {
            if (!std.mem.eql(u8, frame[record.header_bytes..], &.{1})) return error.UnexpectedMessage;
            return;
        }
        const decoded = try self.client_handshake.?.openProtected(frame);
        if (decoded.content_type != .handshake) return error.UnexpectedMessage;
        if (decoded.content.len > self.finished.len - self.finished_len) return error.UnexpectedMessage;
        @memcpy(self.finished[self.finished_len..][0..decoded.content.len], decoded.content);
        self.finished_len += decoded.content.len;
        if (self.finished[0] != 20) return error.UnexpectedMessage;
        if (self.finished_len < handshake_header_bytes) return;
        if (!std.mem.eql(u8, self.finished[0..4], &.{ 20, 0, 0, verify_bytes })) return error.DecodeError;
        if (self.finished_len < self.finished.len) return;
        if (!std.crypto.timing_safe.eql([verify_bytes]u8, self.finished[4..].*, self.expected_finished)) return error.BadFinished;
        self.clearHandshake();
        self.phase = .established;
    }

    pub fn takeApplication(self: *Server) Error!Application {
        if (self.phase != .established) return error.UnexpectedMessage;
        const keys = self.application.?;
        self.clearApplication();
        self.phase = .transferred;
        return keys;
    }

    fn clearHandshake(self: *Server) void {
        if (self.client_handshake) |*keys| std.crypto.secureZero(u8, std.mem.asBytes(keys));
        self.client_handshake = null;
        std.crypto.secureZero(u8, &self.expected_finished);
        std.crypto.secureZero(u8, &self.finished);
    }

    fn clearApplication(self: *Server) void {
        if (self.application) |*keys| keys.close();
        self.application = null;
    }

    pub fn close(self: *Server) void {
        self.clearHandshake();
        self.clearApplication();
        self.parsed = null;
        self.alpn_matched = false;
        self.phase = .failed;
    }
};

fn digest(transcript: sha256.Sha256) [32]u8 {
    var copy = transcript;
    return copy.final();
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const left = @intFromPtr(a.ptr);
    const right = @intFromPtr(b.ptr);
    return if (left <= right) right - left < a.len else left - right < b.len;
}

const Writer = struct {
    bytes: []u8,
    used: usize = 0,

    fn put(self: *Writer, bytes: []const u8) Error!void {
        if (bytes.len > self.bytes.len - self.used) return error.BufferTooSmall;
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }

    fn uint(self: *Writer, comptime T: type, value: T) Error!void {
        var bytes: [@bitSizeOf(T) / 8]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);
        return self.put(&bytes);
    }

    fn handshake(self: *Writer, message: u8, length: usize) Error!void {
        try self.uint(u8, message);
        try self.uint(u24, @intCast(length));
    }

    fn written(self: *const Writer) []const u8 {
        return self.bytes[0..self.used];
    }
};

fn writeServerHello(writer: *Writer, session_id: []const u8, random: *const [32]u8, public_key: *const [32]u8) Error!void {
    const body_bytes = server_hello_body_bytes + session_id.len;
    try writer.uint(u8, 22);
    try writer.uint(u16, 0x0303);
    try writer.uint(u16, @intCast(handshake_header_bytes + body_bytes));
    try writer.handshake(2, body_bytes);
    try writer.uint(u16, 0x0303);
    try writer.put(random);
    try writer.uint(u8, @intCast(session_id.len));
    try writer.put(session_id);
    try writer.uint(u16, suite);
    try writer.uint(u8, 0);
    try writer.uint(u16, server_hello_extension_bytes);
    try writer.uint(u16, 51);
    try writer.uint(u16, 36);
    try writer.uint(u16, 0x001d);
    try writer.uint(u16, 32);
    try writer.put(public_key);
    try writer.uint(u16, 43);
    try writer.uint(u16, 2);
    try writer.uint(u16, 0x0304);
}

test "ALPN accounts for an opaque selected protocol in its protected flight" {
    const testing = std.testing;
    var identity: Identity = undefined;
    identity.certificate_list_bytes = record.max_plaintext_bytes;
    var hello_buffer: [16]u8 = undefined;
    try testing.expectError(error.InvalidAlpnProtocol, Server.initWithAlpn(&identity, &hello_buffer, .{ .protocol = "" }));
    const oversized = [_]u8{1} ** 256;
    try testing.expectError(error.InvalidAlpnProtocol, Server.initWithAlpn(&identity, &hello_buffer, .{ .protocol = &oversized }));
    try testing.expectError(error.BadRecord, Server.initWithAlpn(&identity, &hello_buffer, .{ .protocol = hello_buffer[0..1] }));
    var server = try Server.initWithAlpn(&identity, &hello_buffer, .{ .protocol = "a\x00b" });
    try testing.expectEqual(identity.flightScratchBytes() + 10, server.flightScratchBytes());
    try testing.expect(server.flightOutputBytes() >= identity.flightOutputBytes() + 10);
    try testing.expect(server.selectedAlpn() == null);
    server.alpn_matched = true;
    var bytes: [16]u8 = undefined;
    var writer: Writer = .{ .bytes = &bytes };
    try server.writeEncryptedExtensions(&writer);
    try testing.expectEqualSlices(u8, &.{ 8, 0, 0, 12, 0, 10, 0, 16, 0, 6, 0, 4, 3, 'a', 0, 'b' }, writer.written());
    try testing.expect(server.selectedAlpn() == null);
    server.phase = .established;
    try testing.expectEqualSlices(u8, "a\x00b", server.selectedAlpn().?);
}

test "fragmented RFC 8448 ClientHello produces the published ServerHello and traffic secret" {
    const testing = std.testing;
    var client_message: [196]u8 = undefined;
    _ = try std.fmt.hexToBytes(&client_message,
        "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b" ++
            "0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d0020" ++
            "99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603" ++
            "020308040805080604010501060102010402050206020202002d00020101001c00024001");
    var server_message: [90]u8 = undefined;
    _ = try std.fmt.hexToBytes(&server_message,
        "020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020" ++
            "c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304");
    var private_key: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&private_key, "b1580eeadf6dd589b8ef4f2d5652578cc810e9980191ec8d058308cea216a21e");
    var expected_traffic: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_traffic, "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21");

    const identity: Identity = undefined;
    var assembled: [196]u8 = undefined;
    var server = Server.init(&identity, &assembled);
    var first: [record.header_bytes + 2]u8 = .{ 22, 3, 1, 0, 2, 0, 0 };
    @memcpy(first[record.header_bytes..], client_message[0..2]);
    try testing.expectEqual(FrameRead{ .need = record.header_bytes }, try server.receive(first[0..4]));
    try testing.expectEqual(FrameRead{ .need = first.len }, try server.receive(first[0..6]));
    try testing.expectEqual(FrameRead{ .consumed = first.len }, try server.receive(&first));
    try testing.expectEqual(Phase.client_hello, server.phase);
    var next: [record.header_bytes + client_message.len - 2]u8 = undefined;
    next[0..record.header_bytes].* = .{ 22, 3, 1, 0, client_message.len - 2 };
    @memcpy(next[record.header_bytes..], client_message[2..]);
    try testing.expectEqual(FrameRead{ .consumed = next.len }, try server.receive(&next));
    try testing.expectEqual(Phase.server_flight, server.phase);
    const parsed = server.parsed.?;

    var output: [record.header_bytes + server_message.len]u8 = undefined;
    var writer: Writer = .{ .bytes = &output };
    const public = x25519.publicKey(&private_key);
    try writeServerHello(&writer, parsed.session_id, server_message[6..38], &public);
    try testing.expectEqualSlices(u8, &server_message, writer.written()[record.header_bytes..]);
    var transcript = sha256.Sha256.init();
    transcript.update(server.hello_buffer[0..server.hello_len]);
    transcript.update(writer.written()[record.header_bytes..]);
    const hash = digest(transcript);
    const shared = x25519.sharedSecret(&private_key, &parsed.key_share);
    var schedule = key_schedule.init(null);
    var client: [32]u8 = undefined;
    var serving: [32]u8 = undefined;
    schedule.deriveHandshakeSecrets(&shared, &hash, &client, &serving);
    try testing.expectEqualSlices(u8, &expected_traffic, &client);
}

test "an authenticated record with wrong Finished closes the exchange" {
    const testing = std.testing;
    const identity: Identity = undefined;
    var hello_buffer: [256]u8 = undefined;
    var server = Server.init(&identity, &hello_buffer);
    const secret: [32]u8 = @splat(0x29);
    server.phase = .client_finished;
    server.client_handshake = try record.keysForSuite(suite, &secret);
    server.expected_finished = @splat(0x19);
    server.application = try Application.init(suite, &secret, &secret);
    try testing.expectError(error.UnexpectedMessage, server.takeApplication());
    var compat = compatibility_ccs;
    try testing.expectEqual(FrameRead{ .consumed = compatibility_ccs.len }, try server.receive(&compat));
    var wire: [finished_bytes + record_overhead]u8 = @splat(0);
    wire[record.header_bytes..][0..4].* = .{ 20, 0, 0, verify_bytes };
    var client = try record.keysForSuite(suite, &secret);
    const encrypted = try client.sealProtected(&wire, .handshake, finished_bytes, 0);
    try testing.expectError(error.BadFinished, server.receive(wire[0..encrypted.len]));
    try testing.expectEqual(Phase.failed, server.phase);
    try testing.expect(server.application == null);
    try testing.expect(server.client_handshake == null);
    try testing.expectError(error.UnexpectedMessage, server.takeApplication());
}
