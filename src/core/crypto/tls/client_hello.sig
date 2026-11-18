//! The ClientHello fields used by the private TLS 1.3 server handshake.
const std = @import("std");

const tls_1_3: u16 = 0x0304;
const aes_128_gcm_sha256: u16 = 0x1301;
const x25519_group: u16 = 0x001d;
const ecdsa_p256_sha256: u16 = 0x0403;

pub const Error = error{
    DecodeError,
    IllegalParameter,
    UnsupportedVersion,
    MissingExtension,
    NoCommonCipher,
    NoCommonSignature,
    NoUsableKeyShare,
    EarlyDataUnsupported,
};

pub const Hello = struct {
    session_id: []const u8,
    key_share: [32]u8,
};

const Cursor = struct {
    remaining: []const u8,

    fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (n > self.remaining.len) return error.DecodeError;
        const part = self.remaining[0..n];
        self.remaining = self.remaining[n..];
        return part;
    }

    fn read(self: *Cursor, comptime T: type) Error!T {
        const width = @bitSizeOf(T) / 8;
        return std.mem.readInt(T, (try self.take(width))[0..width], .big);
    }

    fn vector(self: *Cursor, comptime Width: type) Error![]const u8 {
        const len = try self.read(Width);
        return self.take(len);
    }

    fn end(self: Cursor) Error!void {
        if (self.remaining.len != 0) return error.DecodeError;
    }
};

const Seen = std.StaticBitSet(1 << 16);

fn mark(seen: *Seen, id: u16) Error!void {
    if (seen.isSet(id)) return error.IllegalParameter;
    seen.set(id);
}

fn offered(input: []const u8, id: u16) Error!bool {
    if (input.len == 0 or input.len % 2 != 0) return error.DecodeError;
    var list: Cursor = .{ .remaining = input };
    var found = false;
    while (list.remaining.len != 0) {
        if (try list.read(u16) == id) found = true;
    }
    return found;
}

fn keyShare(input: []const u8) Error!?[32]u8 {
    var list: Cursor = .{ .remaining = input };
    var seen = Seen.initEmpty();
    var share: ?[32]u8 = null;
    while (list.remaining.len != 0) {
        const group = try list.read(u16);
        try mark(&seen, group);
        const public_key = try list.vector(u16);
        if (public_key.len == 0) return error.DecodeError;
        if (group == x25519_group) {
            if (public_key.len != 32) return error.IllegalParameter;
            share = public_key[0..32].*;
        }
    }
    return share;
}

/// Parse one exact ClientHello body, excluding its handshake header.
/// Unselected extensions can be ignored after validating their framing.
pub fn parse(body: []const u8) Error!Hello {
    var hello: Cursor = .{ .remaining = body };
    if (try hello.read(u16) != 0x0303) return error.UnsupportedVersion;
    _ = try hello.take(32);
    const session_id = try hello.vector(u8);
    if (session_id.len > 32) return error.IllegalParameter;
    const ciphers = try hello.vector(u16);
    const null_compression = try hello.vector(u8);
    if (!std.mem.eql(u8, null_compression, &.{0})) return error.IllegalParameter;
    var extensions: Cursor = .{ .remaining = try hello.vector(u16) };
    try hello.end();

    var seen = Seen.initEmpty();
    var tls13 = false;
    var x25519 = false;
    var ecdsa = false;
    var share: ?[32]u8 = null;
    while (extensions.remaining.len != 0) {
        const id = try extensions.read(u16);
        try mark(&seen, id);
        var data: Cursor = .{ .remaining = try extensions.vector(u16) };
        switch (id) {
            10 => x25519 = try offered(try data.vector(u16), x25519_group),
            13 => ecdsa = try offered(try data.vector(u16), ecdsa_p256_sha256),
            41 => {
                if (extensions.remaining.len != 0) return error.IllegalParameter;
                continue;
            },
            42 => return error.EarlyDataUnsupported,
            43 => tls13 = try offered(try data.vector(u8), tls_1_3),
            51 => share = try keyShare(try data.vector(u16)),
            else => continue,
        }
        try data.end();
    }

    if (!tls13) return error.UnsupportedVersion;
    if (!try offered(ciphers, aes_128_gcm_sha256)) return error.NoCommonCipher;
    if (!seen.isSet(10) or !seen.isSet(13) or !seen.isSet(51)) return error.MissingExtension;
    if (!ecdsa) return error.NoCommonSignature;
    if (!x25519) return error.NoUsableKeyShare;
    return .{ .session_id = session_id, .key_share = share orelse return error.NoUsableKeyShare };
}
