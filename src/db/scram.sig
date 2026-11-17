//! Bounded SCRAM-SHA-256 server authentication (RFC 5802 / RFC 7677).
//! Caller supplies a fresh, unpredictable server nonce for every connection.
//! This authenticates credentials; transport encryption and channel binding
//! belong to the caller. SCRAM-SHA-256-PLUS is deliberately not advertised.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.standard;
pub const mechanism = "SCRAM-SHA-256";
pub const max_message: usize = 1024;
pub const min_iterations: u32 = 4096;
pub const max_iterations: u32 = 10_000_000;
pub const Error = error{ InvalidVerifier, InvalidNonce, AuthenticationFailed, AuthenticationState, BufferTooSmall, PasswordNormalizationUnsupported };

pub const Verifier = struct {
    username: [64]u8 = @splat(0),
    username_len: usize = 0,
    salt: [64]u8 = @splat(0),
    salt_len: usize = 0,
    iterations: u32 = 0,
    stored_key: [32]u8 = @splat(0),
    server_key: [32]u8 = @splat(0),

    /// Provision printable ASCII passwords, for which SASLprep is identity.
    /// Non-ASCII provisioning requires an externally SASLprepped PostgreSQL
    /// verifier through parse(); silently deriving the wrong verifier is unsafe.
    pub fn fromPassword(username: []const u8, password: []const u8, salt: []const u8, iterations: u32) Error!Verifier {
        var result: Verifier = .{};
        try result.setIdentity(username, salt, iterations);
        if (password.len == 0 or password.len > 1024) return error.InvalidVerifier;
        for (password) |c| if (c < 0x20 or c > 0x7e) return error.PasswordNormalizationUnsupported;
        var salted_password: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &salted_password);
        std.crypto.pwhash.pbkdf2(&salted_password, password, salt, iterations, Hmac) catch return error.InvalidVerifier;
        var client_key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &client_key);
        Hmac.create(&client_key, "Client Key", &salted_password);
        Sha256.hash(&client_key, &result.stored_key, .{});
        Hmac.create(&result.server_key, "Server Key", &salted_password);
        return result;
    }

    /// Import PostgreSQL's SCRAM-SHA-256$iterations:salt$stored-key:server-key
    /// representation without retaining the credential file or its buffers.
    pub fn parse(username: []const u8, source: []const u8) Error!Verifier {
        const prefix = "SCRAM-SHA-256$";
        if (source.len > 512 or !std.mem.startsWith(u8, source, prefix)) return error.InvalidVerifier;
        const rounds_end = std.mem.indexOfScalarPos(u8, source, prefix.len, ':') orelse return error.InvalidVerifier;
        if (rounds_end == prefix.len or rounds_end - prefix.len > 8) return error.InvalidVerifier;
        var iterations: u32 = 0;
        for (source[prefix.len..rounds_end]) |c| {
            if (c < '0' or c > '9') return error.InvalidVerifier;
            iterations = iterations * 10 + c - '0';
        }
        const salt_end = std.mem.indexOfScalarPos(u8, source, rounds_end + 1, '$') orelse return error.InvalidVerifier;
        const key_end = std.mem.indexOfScalarPos(u8, source, salt_end + 1, ':') orelse return error.InvalidVerifier;
        var salt: [64]u8 = undefined;
        const salt_len = decode(source[rounds_end + 1 .. salt_end], &salt) catch return error.InvalidVerifier;
        var result: Verifier = .{};
        try result.setIdentity(username, salt[0..salt_len], iterations);
        const stored_len = decode(source[salt_end + 1 .. key_end], &result.stored_key) catch return error.InvalidVerifier;
        const server_len = decode(source[key_end + 1 ..], &result.server_key) catch return error.InvalidVerifier;
        if (stored_len != 32 or server_len != 32) return error.InvalidVerifier;
        return result;
    }

    pub fn format(self: *const Verifier, output: []u8) Error![]const u8 {
        try self.validate();
        var salt: [88]u8 = undefined;
        var stored: [44]u8 = undefined;
        var server: [44]u8 = undefined;
        return std.fmt.bufPrint(output, "SCRAM-SHA-256${d}:{s}${s}:{s}", .{
            self.iterations,                               b64.Encoder.encode(&salt, self.salt[0..self.salt_len]),
            b64.Encoder.encode(&stored, &self.stored_key), b64.Encoder.encode(&server, &self.server_key),
        }) catch error.BufferTooSmall;
    }

    pub fn validate(self: *const Verifier) Error!void {
        if (self.username_len == 0 or self.username_len > self.username.len or self.salt_len < 16 or self.salt_len > self.salt.len or self.iterations < min_iterations or self.iterations > max_iterations) return error.InvalidVerifier;
        for (self.identity()) |c| if (c == 0) return error.InvalidVerifier;
    }

    pub fn identity(self: *const Verifier) []const u8 {
        return self.username[0..self.username_len];
    }

    fn setIdentity(self: *Verifier, username: []const u8, salt: []const u8, iterations: u32) Error!void {
        if (username.len > self.username.len or salt.len > self.salt.len) return error.InvalidVerifier;
        self.username_len = username.len;
        self.salt_len = salt.len;
        self.iterations = iterations;
        @memcpy(self.username[0..username.len], username);
        @memcpy(self.salt[0..salt.len], salt);
        try self.validate();
    }
};

/// Parse UTF-8 username TAB verifier records into caller-owned storage.
/// LF and CRLF are accepted, with an optional final line ending. Each line
/// must contain a verifier. Callers own the input and scratch lifetime.
pub fn parseVerifierList(source: []const u8, storage: []Verifier) Error![]const Verifier {
    if (source.len == 0) return error.InvalidVerifier;
    var count: usize = 0;
    var start: usize = 0;
    while (start < source.len) {
        const newline = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const end = if (newline < source.len and newline > start and source[newline - 1] == '\r') newline - 1 else newline;
        const record = source[start..end];
        const separator = std.mem.indexOfScalar(u8, record, '\t') orelse return error.InvalidVerifier;
        const username = record[0..separator];
        if (!std.unicode.utf8ValidateSlice(username) or std.mem.indexOfScalar(u8, username, '\r') != null) return error.InvalidVerifier;
        if (count == storage.len) return error.BufferTooSmall;
        storage[count] = try Verifier.parse(username, record[separator + 1 ..]);
        count += 1;
        if (newline == source.len) break;
        start = newline + 1;
    }
    return storage[0..count];
}

/// Validated, immutable credentials borrowing the caller's verifier storage.
/// The mock secret is generated by the application and kept stable across
/// restarts. A single salt-length/iteration profile keeps trial challenges
/// for one username from being distinguishable by public SCRAM parameters.
pub const Credentials = struct {
    verifiers: []const Verifier,
    mock_secret: [32]u8,

    pub fn init(verifiers: []const Verifier, mock_secret: [32]u8) Error!Credentials {
        if (verifiers.len == 0 or std.crypto.timing_safe.eql([32]u8, mock_secret, @splat(0))) return error.InvalidVerifier;
        const profile = &verifiers[0];
        for (verifiers, 0..) |*verifier, index| {
            try verifier.validate();
            if (verifier.salt_len != profile.salt_len or verifier.iterations != profile.iterations) return error.InvalidVerifier;
            for (verifiers[0..index]) |*previous| {
                if (std.mem.eql(u8, verifier.identity(), previous.identity())) return error.InvalidVerifier;
            }
        }
        return .{ .verifiers = verifiers, .mock_secret = mock_secret };
    }

    fn select(self: *const Credentials, username: []const u8) struct { verifier: Verifier, found: bool } {
        var selected: ?usize = null;
        var target: [64]u8 = @splat(0);
        const length = @min(target.len, username.len);
        @memcpy(target[0..length], username[0..length]);
        for (self.verifiers, 0..) |*entry, index| {
            var candidate: [64]u8 = @splat(0);
            @memcpy(candidate[0..entry.username_len], entry.identity());
            const same_bytes = std.crypto.timing_safe.eql([64]u8, target, candidate);
            if (same_bytes and entry.username_len == username.len) selected = index;
        }

        const profile = &self.verifiers[0];
        var mock: Verifier = .{ .salt_len = profile.salt_len, .iterations = profile.iterations };
        const digest_bytes = Sha256.digest_length;
        for (0..(mock.salt_len + digest_bytes - 1) / digest_bytes) |block| {
            var hmac = Hmac.init(&self.mock_secret);
            defer std.crypto.secureZero(u8, std.mem.asBytes(&hmac));
            hmac.update("zpm.scram.mock.salt\x00");
            hmac.update(&.{@intCast(block)});
            hmac.update(username);
            hmac.final(mock.salt[block * digest_bytes ..][0..digest_bytes]);
        }
        if (selected) |index| return .{ .verifier = self.verifiers[index], .found = true };
        return .{ .verifier = mock, .found = false };
    }
};

const Field = struct { tag: u8, value: []const u8, begin: usize };
const Fields = struct {
    fields: [32]Field = undefined,
    count: usize = 0,
    fn parse(source: []const u8) Error!Fields {
        if (source.len == 0 or source.len > max_message) return error.AuthenticationFailed;
        var result: Fields = .{};
        var seen: u64 = 0;
        var begin: usize = 0;
        while (begin < source.len) {
            const end = std.mem.indexOfScalarPos(u8, source, begin, ',') orelse source.len;
            const field = source[begin..end];
            if (field.len < 2 or field[1] != '=' or result.count == result.fields.len) return error.AuthenticationFailed;
            const tag = field[0];
            const index: u6 = if (tag >= 'a' and tag <= 'z') @intCast(tag - 'a') else if (tag >= 'A' and tag <= 'Z') @intCast(tag - 'A' + 26) else return error.AuthenticationFailed;
            const bit = @as(u64, 1) << index;
            if (seen & bit != 0 or tag == 'm') return error.AuthenticationFailed;
            seen |= bit;
            for (field[2..]) |c| if (c == 0 or c < 0x20 or c == 0x7f) return error.AuthenticationFailed;
            result.fields[result.count] = .{ .tag = tag, .value = field[2..], .begin = begin };
            result.count += 1;
            if (end == source.len) break;
            begin = end + 1;
            if (begin == source.len) return error.AuthenticationFailed;
        }
        return result;
    }
};

pub const Server = struct {
    pub const State = enum { initial, challenge, complete, failed };
    state: State = .initial,
    verifier: Verifier = .{},
    identity_matches: bool = true,
    server_nonce: [128]u8 = @splat(0),
    server_nonce_len: usize = 0,
    client_first_bare: [512]u8 = @splat(0),
    client_first_len: usize = 0,
    combined_nonce: [384]u8 = @splat(0),
    combined_nonce_len: usize = 0,
    server_first: [512]u8 = @splat(0),
    server_first_len: usize = 0,
    gs2_flag: u8 = 'n',

    /// nonce must come from the application's CSPRNG and never be reused.
    /// The lower bound requires >=144 bits when using base64 random bytes.
    pub fn init(verifier: *const Verifier, nonce: []const u8) Error!Server {
        try verifier.validate();
        var result = try initUnselected(nonce);
        result.verifier = verifier.*;
        result.identity_matches = true;
        return result;
    }

    /// Reserve the connection nonce until StartupMessage supplies the user.
    pub fn initUnselected(nonce: []const u8) Error!Server {
        var result: Server = .{ .identity_matches = false };
        if (nonce.len < 24 or nonce.len > result.server_nonce.len or !validNonce(nonce)) return error.InvalidNonce;
        @memcpy(result.server_nonce[0..nonce.len], nonce);
        result.server_nonce_len = nonce.len;
        return result;
    }

    pub fn selectCredentials(self: *Server, credentials: *const Credentials, username: []const u8) Error!void {
        if (self.state != .initial or self.verifier.salt_len != 0) return error.AuthenticationState;
        if (credentials.verifiers.len == 0) return error.InvalidVerifier;
        const match = credentials.select(username);
        self.verifier = match.verifier;
        self.identity_matches = match.found;
    }

    /// PostgreSQL authenticates the StartupMessage user, ignoring the SASL name.
    /// Keep unknown-user failure until proof verification, with the same wire flow.
    pub fn setUsername(self: *Server, username: []const u8) void {
        self.identity_matches = self.verifier.username_len != 0 and std.mem.eql(u8, username, self.verifier.identity());
    }

    pub fn start(self: *Server, client_first: []const u8, output: []u8) Error![]const u8 {
        if (output.len < self.server_first.len) return error.BufferTooSmall;
        if (self.state != .initial) return error.AuthenticationState;
        errdefer self.state = .failed;
        if (self.verifier.salt_len == 0) return error.AuthenticationState;
        if (client_first.len < 7 or client_first.len > self.client_first_bare.len + 3 or (client_first[0] != 'n' and client_first[0] != 'y') or client_first[1] != ',' or client_first[2] != ',') return error.AuthenticationFailed;
        const bare = client_first[3..];
        const fields = try Fields.parse(bare);
        if (fields.count < 2 or fields.fields[0].tag != 'n' or fields.fields[1].tag != 'r') return error.AuthenticationFailed;
        // Validate SASL-name escapes even though PostgreSQL ignores this name.
        const name = fields.fields[0].value;
        var i: usize = 0;
        while (i < name.len) : (i += 1) {
            if (name[i] == '=') {
                if (name.len - i < 3 or (!std.mem.eql(u8, name[i..][0..3], "=2C") and !std.mem.eql(u8, name[i..][0..3], "=3D"))) return error.AuthenticationFailed;
                i += 2;
            }
        }
        const client_nonce = fields.fields[1].value;
        if (client_nonce.len == 0 or client_nonce.len > 256 or !validNonce(client_nonce)) return error.AuthenticationFailed;
        @memcpy(self.client_first_bare[0..bare.len], bare);
        self.client_first_len = bare.len;
        @memcpy(self.combined_nonce[0..client_nonce.len], client_nonce);
        @memcpy(self.combined_nonce[client_nonce.len..][0..self.server_nonce_len], self.server_nonce[0..self.server_nonce_len]);
        self.combined_nonce_len = client_nonce.len + self.server_nonce_len;
        var salt: [88]u8 = undefined;
        const message = std.fmt.bufPrint(&self.server_first, "r={s},s={s},i={d}", .{
            self.combined_nonce[0..self.combined_nonce_len], b64.Encoder.encode(&salt, self.verifier.salt[0..self.verifier.salt_len]), self.verifier.iterations,
        }) catch return error.AuthenticationFailed;
        self.server_first_len = message.len;
        @memcpy(output[0..message.len], message);
        self.gs2_flag = client_first[0];
        self.state = .challenge;
        return output[0..message.len];
    }

    pub fn finish(self: *Server, client_final: []const u8, output: []u8) Error![]const u8 {
        if (output.len < 46) return error.BufferTooSmall;
        if (self.state != .challenge) return error.AuthenticationState;
        errdefer self.state = .failed;
        const fields = try Fields.parse(client_final);
        if (fields.count < 3 or fields.fields[0].tag != 'c' or fields.fields[1].tag != 'r' or fields.fields[fields.count - 1].tag != 'p') return error.AuthenticationFailed;
        const channel = if (self.gs2_flag == 'n') "biws" else "eSws";
        if (!std.mem.eql(u8, fields.fields[0].value, channel) or !std.mem.eql(u8, fields.fields[1].value, self.combined_nonce[0..self.combined_nonce_len])) return error.AuthenticationFailed;
        const proof_field = fields.fields[fields.count - 1];
        var proof: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &proof);
        if ((try decode(proof_field.value, &proof)) != 32) return error.AuthenticationFailed;
        const without_proof = client_final[0 .. proof_field.begin - 1];
        var client_signature: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &client_signature);
        self.signature(&self.verifier.stored_key, without_proof, &client_signature);
        var client_key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &client_key);
        for (&client_key, proof, client_signature) |*key, p, s| key.* = p ^ s;
        var stored_key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &stored_key);
        Sha256.hash(&client_key, &stored_key, .{});
        const valid_proof = std.crypto.timing_safe.eql([32]u8, stored_key, self.verifier.stored_key);
        if (!valid_proof or !self.identity_matches) return error.AuthenticationFailed;
        var server_signature: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &server_signature);
        self.signature(&self.verifier.server_key, without_proof, &server_signature);
        output[0] = 'v';
        output[1] = '=';
        _ = b64.Encoder.encode(output[2..46], &server_signature);
        self.state = .complete;
        return output[0..46];
    }

    fn signature(self: *const Server, key: *const [32]u8, final: []const u8, output: *[32]u8) void {
        var hmac = Hmac.init(key);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&hmac));
        hmac.update(self.client_first_bare[0..self.client_first_len]);
        hmac.update(",");
        hmac.update(self.server_first[0..self.server_first_len]);
        hmac.update(",");
        hmac.update(final);
        hmac.final(output);
    }
};

fn validNonce(nonce: []const u8) bool {
    for (nonce) |c| if (c < 0x21 or c > 0x7e or c == ',') return false;
    return true;
}

fn decode(source: []const u8, output: []u8) Error!usize {
    if (source.len == 0 or source.len % 4 != 0) return error.AuthenticationFailed;
    const size = b64.Decoder.calcSizeForSlice(source) catch return error.AuthenticationFailed;
    if (size > output.len) return error.AuthenticationFailed;
    b64.Decoder.decode(output[0..size], source) catch return error.AuthenticationFailed;
    // Reject noncanonical padding bits, too, so signatures have one encoding.
    var canonical: [88]u8 = undefined;
    if (b64.Encoder.calcSize(size) > canonical.len) return error.AuthenticationFailed;
    if (!std.mem.eql(u8, b64.Encoder.encode(&canonical, output[0..size]), source)) return error.AuthenticationFailed;
    return size;
}
