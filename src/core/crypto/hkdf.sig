// @zpm/crypto/hkdf — Freestanding HKDF (RFC 5869) + TLS 1.3 Expand-Label.
// Zero allocator. Pure computation. No std dependency.

const sha256 = @import("sha256.sig");

/// HKDF-Extract: PRK = HMAC-SHA-256(salt, IKM).
pub fn extract(salt: []const u8, ikm: []const u8, out: *[32]u8) void {
    sha256.hmac(salt, ikm, out);
}

/// HKDF-Expand-Label (RFC 8446 §7.1 / RFC 9001).
/// Label format: length(2) || "tls13 " || label || context_len(1) || context
/// Used for both TLS 1.3 key schedule and QUIC key derivation.
pub fn expandLabel(secret: *const [32]u8, label: []const u8, ctx: []const u8, out: []u8) void {
    var info: [320]u8 = undefined;
    var p: usize = 0;

    // Output length (2 bytes, big-endian)
    info[0] = @intCast(out.len >> 8);
    info[1] = @intCast(out.len & 0xFF);
    p = 2;

    // Label: length_byte + "tls13 " + label
    const prefix = "tls13 ";
    info[p] = @intCast(prefix.len + label.len);
    p += 1;
    @memcpy(info[p..][0..prefix.len], prefix);
    p += prefix.len;
    @memcpy(info[p..][0..label.len], label);
    p += label.len;

    // Context: length_byte + ctx
    info[p] = @intCast(ctx.len);
    p += 1;
    if (ctx.len > 0) {
        @memcpy(info[p..][0..ctx.len], ctx);
        p += ctx.len;
    }

    // HKDF-Expand with counter
    expand(secret, info[0..p], out);
}

/// HKDF-Expand (generic, without label formatting).
pub fn expand(prk: *const [32]u8, info: []const u8, out: []u8) void {
    var t: [32]u8 = undefined;
    var done: usize = 0;
    var counter: u8 = 1;
    while (done < out.len) : (counter += 1) {
        var input: [360]u8 = undefined;
        var il: usize = 0;
        if (counter > 1) {
            @memcpy(input[0..32], &t);
            il = 32;
        }
        @memcpy(input[il..][0..info.len], info);
        il += info.len;
        input[il] = counter;
        il += 1;
        sha256.hmac(prk, input[0..il], &t);
        const cp = @min(32, out.len - done);
        @memcpy(out[done..][0..cp], t[0..cp]);
        done += cp;
    }
}

/// Derive a traffic secret: SHA-256(messages) → expandLabel(secret, label, hash, out).
pub fn deriveSecret(secret: *const [32]u8, label: []const u8, messages: []const u8, out: *[32]u8) void {
    var transcript_hash: [32]u8 = undefined;
    sha256.hash(messages, &transcript_hash);
    expandLabel(secret, label, &transcript_hash, out);
}
