//! Allocator-free Solana wallet sign-in challenges.
//! Message construction follows the Sign In With Solana field order. Nonces
//! must come from a cryptographically secure platform random source.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const testing = @import("sig_testing");

pub const PUBLIC_KEY_SIZE: usize = Ed25519.PublicKey.encoded_length;
pub const SIGNATURE_SIZE: usize = Ed25519.Signature.encoded_length;
pub const NONCE_SIZE: usize = 32;
pub const MAX_CHALLENGES: usize = 64;
pub const MAX_DOMAIN: usize = 128;
pub const MAX_URI: usize = 192;
pub const MAX_TIME_TEXT: usize = 32;
pub const MAX_MESSAGE: usize = 1024;
const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

pub const Error = error{
    InvalidDomain,
    InvalidUri,
    InvalidTime,
    InvalidNonce,
    ChallengeCapacity,
    UnknownChallenge,
    ChallengeExpired,
    ChallengeConsumed,
    InvalidSignature,
    MessageTooLong,
};

pub const ChallengeInput = struct {
    public_key: [PUBLIC_KEY_SIZE]u8,
    /// Fresh, unpredictable bytes from a platform CSPRNG. Never use a counter.
    nonce: [NONCE_SIZE]u8,
    domain: []const u8,
    uri: []const u8,
    cluster: []const u8,
    issued_at_iso8601: []const u8,
    expiration_iso8601: []const u8,
    issued_at_unix: u64,
    expiration_unix: u64,
};

pub const IssuedChallenge = struct {
    id: [NONCE_SIZE]u8,
    message: [MAX_MESSAGE]u8,
    message_len: usize,
};

pub const AuthenticatedWallet = struct { public_key: [PUBLIC_KEY_SIZE]u8 };

/// Strict Ed25519 verification for consumers that persist the signed challenge
/// outside this module's fixed-capacity in-memory challenge store.
pub fn verifySignature(public_key_bytes: [PUBLIC_KEY_SIZE]u8, message: []const u8, signature_bytes: []const u8) bool {
    if (signature_bytes.len != SIGNATURE_SIZE) return false;
    const public_key = Ed25519.PublicKey.fromBytes(public_key_bytes) catch return false;
    const signature = Ed25519.Signature.fromBytes(signature_bytes[0..SIGNATURE_SIZE].*);
    signature.verifyStrict(message, public_key) catch return false;
    return true;
}

const StoredChallenge = struct {
    id: [NONCE_SIZE]u8 = @splat(0),
    public_key: [PUBLIC_KEY_SIZE]u8 = @splat(0),
    message: [MAX_MESSAGE]u8 = @splat(0),
    message_len: usize = 0,
    expires_at: u64 = 0,
    consumed: bool = false,
};

pub const ChallengeStore = struct {
    allowed_domain: [MAX_DOMAIN]u8 = @splat(0),
    allowed_domain_len: usize = 0,
    allowed_cluster: [16]u8 = @splat(0),
    allowed_cluster_len: usize = 0,
    entries: [MAX_CHALLENGES]StoredChallenge = @splat(.{}),

    pub fn init(domain: []const u8, cluster: []const u8) Error!ChallengeStore {
        if (!validField(domain, MAX_DOMAIN) or containsWhitespace(domain)) return error.InvalidDomain;
        if (!validField(cluster, 16)) return error.InvalidTime;
        var store = ChallengeStore{ .allowed_domain_len = domain.len, .allowed_cluster_len = cluster.len };
        @memcpy(store.allowed_domain[0..domain.len], domain);
        @memcpy(store.allowed_cluster[0..cluster.len], cluster);
        return store;
    }

    /// Caller supplies a CSPRNG nonce and times; expires_at must be in the
    /// future. Domain and URI are included verbatim in the signed SIWS message.
    pub fn issue(self: *ChallengeStore, input: ChallengeInput, now_unix: u64) Error!IssuedChallenge {
        if (!std.mem.eql(u8, input.domain, self.allowed_domain[0..self.allowed_domain_len])) return error.InvalidDomain;
        if (!validField(input.uri, MAX_URI) or !startsWith(input.uri, "https://") or
            !startsWith(input.uri[8..], input.domain) or
            (input.uri.len > 8 + input.domain.len and input.uri[8 + input.domain.len] != '/' and input.uri[8 + input.domain.len] != '?')) return error.InvalidUri;
        if (!std.mem.eql(u8, input.cluster, self.allowed_cluster[0..self.allowed_cluster_len]) or
            !validField(input.issued_at_iso8601, MAX_TIME_TEXT) or
            !validField(input.expiration_iso8601, MAX_TIME_TEXT) or input.expiration_unix <= now_unix or
            input.issued_at_unix > now_unix or input.expiration_unix <= input.issued_at_unix or
            input.expiration_unix - input.issued_at_unix > 600) return error.InvalidTime;

        var empty: ?usize = null;
        for (&self.entries, 0..) |*entry, i| {
            if (entry.expires_at != 0 and entry.expires_at <= now_unix) entry.* = .{};
            if (entry.expires_at != 0 and equalNonce(entry.id, input.nonce)) return error.InvalidNonce;
            if (entry.expires_at == 0 and empty == null) empty = i;
        }
        const slot_index = empty orelse return error.ChallengeCapacity;

        var result = IssuedChallenge{ .id = input.nonce, .message = @splat(0), .message_len = 0 };
        result.message_len = try buildMessage(input, &result.message);
        self.entries[slot_index] = .{
            .id = input.nonce,
            .public_key = input.public_key,
            .message = result.message,
            .message_len = result.message_len,
            .expires_at = input.expiration_unix,
        };
        return result;
    }

    /// Verifies the exact issued message against its wallet key and consumes
    /// the nonce once. Only this verified result may create/link an entity.
    pub fn verifyAndConsume(
        self: *ChallengeStore,
        id: [NONCE_SIZE]u8,
        signature_bytes: []const u8,
        now_unix: u64,
    ) Error!AuthenticatedWallet {
        for (&self.entries) |*entry| {
            if (!equalNonce(entry.id, id) or entry.expires_at == 0) continue;
            if (entry.consumed) return error.ChallengeConsumed;
            if (now_unix >= entry.expires_at) {
                entry.* = .{};
                return error.ChallengeExpired;
            }
            if (signature_bytes.len != SIGNATURE_SIZE) return error.InvalidSignature;
            const public_key = Ed25519.PublicKey.fromBytes(entry.public_key) catch return error.InvalidSignature;
            const signature = Ed25519.Signature.fromBytes(signature_bytes[0..SIGNATURE_SIZE].*);
            signature.verifyStrict(entry.message[0..entry.message_len], public_key) catch return error.InvalidSignature;
            entry.consumed = true;
            return .{ .public_key = entry.public_key };
        }
        return error.UnknownChallenge;
    }
};

/// Base58 encode a 32-byte Solana public key into caller storage.
pub fn encodePublicKey(public_key: *const [PUBLIC_KEY_SIZE]u8, output: *[44]u8) usize {
    var digits: [44]u8 = @splat(0);
    var used: usize = 0;
    for (public_key.*) |byte| {
        var carry: u32 = byte;
        for (0..used) |i| {
            carry += @as(u32, digits[i]) * 256;
            digits[i] = @intCast(carry % 58);
            carry /= 58;
        }
        while (carry > 0) : (carry /= 58) {
            digits[used] = @intCast(carry % 58);
            used += 1;
        }
    }
    var zeroes: usize = 0;
    while (zeroes < public_key.len and public_key[zeroes] == 0) : (zeroes += 1) {}
    @memset(output[0..zeroes], BASE58_ALPHABET[0]);
    var out_len = zeroes;
    var i = used;
    while (i > 0) {
        i -= 1;
        output[out_len] = BASE58_ALPHABET[digits[i]];
        out_len += 1;
    }
    return out_len;
}

/// Strictly decode the canonical base58 representation of a Solana key.
pub fn decodePublicKey(encoded: []const u8, output: *[PUBLIC_KEY_SIZE]u8) bool {
    if (encoded.len == 0 or encoded.len > 44) return false;
    var decoded: [PUBLIC_KEY_SIZE]u8 = @splat(0);
    for (encoded) |character| {
        const digit = std.mem.indexOfScalar(u8, BASE58_ALPHABET, character) orelse return false;
        var carry: u32 = @intCast(digit);
        var i = decoded.len;
        while (i > 0) {
            i -= 1;
            carry += @as(u32, decoded[i]) * 58;
            decoded[i] = @truncate(carry);
            carry >>= 8;
        }
        if (carry != 0) return false;
    }

    var zeroes: usize = 0;
    while (zeroes < encoded.len and encoded[zeroes] == BASE58_ALPHABET[0]) : (zeroes += 1) {}
    var decoded_zeroes: usize = 0;
    while (decoded_zeroes < decoded.len and decoded[decoded_zeroes] == 0) : (decoded_zeroes += 1) {}
    if (zeroes + decoded.len - decoded_zeroes > decoded.len) return false;
    if (zeroes > decoded_zeroes) return false;
    output.* = decoded;

    var check: [44]u8 = undefined;
    const check_len = encodePublicKey(output, &check);
    return std.mem.eql(u8, encoded, check[0..check_len]);
}

pub fn buildMessage(input: ChallengeInput, output: *[MAX_MESSAGE]u8) Error!usize {
    var writer = Writer{ .output = output };
    var address: [44]u8 = undefined;
    const address_len = encodePublicKey(&input.public_key, &address);
    try writer.append(input.domain);
    try writer.append(" wants you to sign in with your Solana account:\n");
    try writer.append(address[0..address_len]);
    try writer.append("\n\nSign in to your C³ login entity.\n\nURI: ");
    try writer.append(input.uri);
    try writer.append("\nVersion: 1\nChain ID: solana:");
    try writer.append(input.cluster);
    try writer.append("\nNonce: ");
    try appendHex(&writer, &input.nonce);
    try writer.append("\nIssued At: ");
    try writer.append(input.issued_at_iso8601);
    try writer.append("\nExpiration Time: ");
    try writer.append(input.expiration_iso8601);
    return writer.len;
}

const Writer = struct {
    output: *[MAX_MESSAGE]u8,
    len: usize = 0,
    fn append(self: *Writer, bytes: []const u8) Error!void {
        if (bytes.len > self.output.len - self.len) return error.MessageTooLong;
        @memcpy(self.output[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

fn appendHex(writer: *Writer, bytes: []const u8) Error!void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.append(&.{ alphabet[byte >> 4], alphabet[byte & 0x0f] });
    }
}

fn validField(value: []const u8, maximum: usize) bool {
    if (value.len == 0 or value.len > maximum) return false;
    for (value) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return true;
}

fn containsWhitespace(value: []const u8) bool {
    for (value) |byte| if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') return true;
    return false;
}

fn startsWith(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.mem.eql(u8, value[0..prefix.len], prefix);
}

fn equalNonce(a: [NONCE_SIZE]u8, b: [NONCE_SIZE]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

test "Solana public key base58 preserves leading zero bytes" {
    const key = [_]u8{0} ** PUBLIC_KEY_SIZE;
    var encoded: [44]u8 = undefined;
    const length = encodePublicKey(&key, &encoded);
    try testing.expectEqual(@as(usize, 32), length);
    try testing.expectEqualSlices(u8, "11111111111111111111111111111111", encoded[0..length]);
}

test "issued challenge is domain bound and invalid signatures do not consume it" {
    var store = try ChallengeStore.init("bizin.space", "devnet");
    const input = ChallengeInput{
        .public_key = @splat(0), .nonce = @splat(7), .domain = "bizin.space",
        .uri = "https://bizin.space/login", .cluster = "devnet",
        .issued_at_iso8601 = "2026-09-30T00:00:00Z", .expiration_iso8601 = "2026-09-30T00:05:00Z",
        .issued_at_unix = 100, .expiration_unix = 400,
    };
    const challenge = try store.issue(input, 100);
    try testing.expect(std.mem.indexOf(u8, challenge.message[0..challenge.message_len], "bizin.space") != null);
    try testing.expectError(error.InvalidSignature, store.verifyAndConsume(challenge.id, &([_]u8{0} ** SIGNATURE_SIZE), 101));
    try testing.expectError(error.InvalidNonce, store.issue(input, 100));
}
