// HKDF — RFC 5869 HMAC-based Extract-and-Expand Key Derivation Function
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Uses HMAC-SHA-256 as the underlying PRF. Provides:
// - extract(): Condense input keying material into a fixed-length PRK
// - expand(): Derive output keying material of arbitrary length from PRK
// - expandLabel(): TLS 1.3 HKDF-Expand-Label (RFC 8446 §7.1)

const hmac = @import("hmac");

/// PRK length (same as HMAC-SHA-256 output).
pub const PRK_LEN = 32;

/// Maximum output length for expand: 255 * 32 = 8160 bytes.
pub const MAX_OUTPUT = 255 * 32;

/// HKDF-Extract (RFC 5869 §2.2):
/// PRK = HMAC-Hash(salt, IKM)
///
/// If salt is empty, uses a zero-filled key of HashLen bytes (per RFC).
pub fn extract(salt: []const u8, ikm: []const u8) [PRK_LEN]u8 {
    if (salt.len == 0) {
        const zero_salt: [PRK_LEN]u8 = @splat(0);
        return hmac.mac(&zero_salt, ikm);
    }
    return hmac.mac(salt, ikm);
}

/// HKDF-Expand (RFC 5869 §2.3):
/// OKM = T(1) || T(2) || ... || T(N)  where N = ceil(L/HashLen)
/// T(0) = empty string
/// T(i) = HMAC-Hash(PRK, T(i-1) || info || i)
///
/// Writes exactly `out_len` bytes into `out`. Returns the slice written.
pub fn expand(prk: *const [PRK_LEN]u8, info: []const u8, out: []u8, out_len: usize) []u8 {
    const len = @min(out_len, @min(out.len, MAX_OUTPUT));
    const n: usize = (len + 31) / 32; // ceil(len / 32)

    var prev: [32]u8 = undefined;
    var prev_len: usize = 0;

    var offset: usize = 0;
    for (0..n) |i| {
        var h = hmac.Hmac.init(prk);
        if (prev_len > 0) {
            h.update(prev[0..prev_len]);
        }
        h.update(info);
        const counter: [1]u8 = .{@intCast(i + 1)};
        h.update(&counter);
        prev = h.final();
        prev_len = 32;

        const copy_len = @min(32, len - offset);
        @memcpy(out[offset..][0..copy_len], prev[0..copy_len]);
        offset += copy_len;
    }

    return out[0..len];
}

/// TLS 1.3 HKDF-Expand-Label (RFC 8446 §7.1):
/// HKDF-Expand-Label(Secret, Label, Context, Length) =
///     HKDF-Expand(Secret, HkdfLabel, Length)
///
/// where HkdfLabel = length(2) || "tls13 " || Label || context_len(1) || Context
///
/// Returns the derived key material in `out[0..out_len]`.
pub fn expandLabel(
    secret: *const [PRK_LEN]u8,
    label: []const u8,
    context: []const u8,
    out: []u8,
    out_len: usize,
) []u8 {
    // Build HkdfLabel structure
    // Max: 2 + 1 + 6 + 255 + 1 + 255 = 520, but labels are short in practice
    var hkdf_label: [512]u8 = undefined;
    var pos: usize = 0;

    // Length (2 bytes, big-endian)
    const length: u16 = @intCast(out_len);
    hkdf_label[pos] = @intCast(length >> 8);
    hkdf_label[pos + 1] = @intCast(length & 0xFF);
    pos += 2;

    // Label: length-prefixed "tls13 " + label
    const prefix = "tls13 ";
    const label_len: u8 = @intCast(prefix.len + label.len);
    hkdf_label[pos] = label_len;
    pos += 1;
    @memcpy(hkdf_label[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(hkdf_label[pos..][0..label.len], label);
    pos += label.len;

    // Context: length-prefixed
    hkdf_label[pos] = @intCast(context.len);
    pos += 1;
    if (context.len > 0) {
        @memcpy(hkdf_label[pos..][0..context.len], context);
        pos += context.len;
    }

    return expand(secret, hkdf_label[0..pos], out, out_len);
}

/// Derive-Secret (RFC 8446 §7.1):
/// Derive-Secret(Secret, Label, Messages) =
///     HKDF-Expand-Label(Secret, Label, Transcript-Hash(Messages), Hash.length)
///
/// `transcript_hash` is the pre-computed hash of the handshake transcript.
pub fn deriveSecret(
    secret: *const [PRK_LEN]u8,
    label: []const u8,
    transcript_hash: *const [32]u8,
    out: *[32]u8,
) void {
    _ = expandLabel(secret, label, transcript_hash, out, 32);
}

// ── Tests ──

test "hkdf: RFC 5869 Test Case 1" {
    // IKM  = 0x0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b (22 bytes)
    // salt = 0x000102030405060708090a0b0c (13 bytes)
    // info = 0xf0f1f2f3f4f5f6f7f8f9 (10 bytes)
    // L    = 42
    const ikm = [_]u8{0x0b} ** 22;
    const salt = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };
    const info = [_]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9 };

    const prk = extract(&salt, &ikm);

    // Expected PRK
    const expected_prk = [_]u8{
        0x07, 0x77, 0x09, 0x36, 0x2c, 0x2e, 0x32, 0xdf,
        0x0d, 0xdc, 0x3f, 0x0d, 0xc4, 0x7b, 0xba, 0x63,
        0x90, 0xb6, 0xc7, 0x3b, 0xb5, 0x0f, 0x9c, 0x31,
        0x22, 0xec, 0x84, 0x4a, 0xd7, 0xc2, 0xb3, 0xe5,
    };
    for (0..32) |i| {
        if (prk[i] != expected_prk[i]) return error.TestUnexpectedResult;
    }

    // Expected OKM (42 bytes)
    const expected_okm = [_]u8{
        0x3c, 0xb2, 0x5f, 0x25, 0xfa, 0xac, 0xd5, 0x7a,
        0x90, 0x43, 0x4f, 0x64, 0xd0, 0x36, 0x2f, 0x2a,
        0x2d, 0x2d, 0x0a, 0x90, 0xcf, 0x1a, 0x5a, 0x4c,
        0x5d, 0xb0, 0x2d, 0x56, 0xec, 0xc4, 0xc5, 0xbf,
        0x34, 0x00, 0x72, 0x08, 0xd5, 0xb8, 0x87, 0x18,
        0x58, 0x65,
    };
    var okm: [42]u8 = undefined;
    _ = expand(&prk, &info, &okm, 42);
    for (0..42) |i| {
        if (okm[i] != expected_okm[i]) return error.TestUnexpectedResult;
    }
}

test "hkdf: RFC 5869 Test Case 2" {
    // IKM  = 0x000102...4f (80 bytes)
    // salt = 0x606162...af (80 bytes)
    // info = 0xb0b1b2...ff (80 bytes)
    // L    = 82
    var ikm: [80]u8 = undefined;
    for (0..80) |i| ikm[i] = @intCast(i);
    var salt: [80]u8 = undefined;
    for (0..80) |i| salt[i] = @intCast(0x60 + i);
    var info: [80]u8 = undefined;
    for (0..80) |i| info[i] = @intCast(0xb0 + i);

    const prk = extract(&salt, &ikm);

    const expected_prk = [_]u8{
        0x06, 0xa6, 0xb8, 0x8c, 0x58, 0x53, 0x36, 0x1a,
        0x06, 0x10, 0x4c, 0x9c, 0xeb, 0x35, 0xb4, 0x5c,
        0xef, 0x76, 0x00, 0x14, 0x90, 0x46, 0x71, 0x01,
        0x4a, 0x19, 0x3f, 0x40, 0xc1, 0x5f, 0xc2, 0x44,
    };
    for (0..32) |i| {
        if (prk[i] != expected_prk[i]) return error.TestUnexpectedResult;
    }

    var okm: [82]u8 = undefined;
    _ = expand(&prk, &info, &okm, 82);

    const expected_okm = [_]u8{
        0xb1, 0x1e, 0x39, 0x8d, 0xc8, 0x03, 0x27, 0xa1,
        0xc8, 0xe7, 0xf7, 0x8c, 0x59, 0x6a, 0x49, 0x34,
        0x4f, 0x01, 0x2e, 0xda, 0x2d, 0x4e, 0xfa, 0xd8,
        0xa0, 0x50, 0xcc, 0x4c, 0x19, 0xaf, 0xa9, 0x7c,
        0x59, 0x04, 0x5a, 0x99, 0xca, 0xc7, 0x82, 0x72,
        0x71, 0xcb, 0x41, 0xc6, 0x5e, 0x59, 0x0e, 0x09,
        0xda, 0x32, 0x75, 0x60, 0x0c, 0x2f, 0x09, 0xb8,
        0x36, 0x77, 0x93, 0xa9, 0xac, 0xa3, 0xdb, 0x71,
        0xcc, 0x30, 0xc5, 0x81, 0x79, 0xec, 0x3e, 0x87,
        0xc1, 0x4c, 0x01, 0xd5, 0xc1, 0xf3, 0x43, 0x4f,
        0x1d, 0x87,
    };
    for (0..82) |i| {
        if (okm[i] != expected_okm[i]) return error.TestUnexpectedResult;
    }
}

test "hkdf: empty salt uses zero key" {
    const ikm = [_]u8{0x0b} ** 22;
    const empty_salt: []const u8 = "";
    const prk = extract(empty_salt, &ikm);
    // Just verify it produces a non-zero result
    var all_zero = true;
    for (prk) |b| {
        if (b != 0) { all_zero = false; break; }
    }
    if (all_zero) return error.TestUnexpectedResult;
}

test "hkdf: expandLabel produces correct length" {
    const secret = [_]u8{0x01} ** 32;
    var out: [48]u8 = undefined;
    const result = expandLabel(&secret, "key", "", &out, 16);
    if (result.len != 16) return error.TestUnexpectedResult;
}

test "hkdf: expandLabel with context" {
    const secret = [_]u8{0xAB} ** 32;
    const context = [_]u8{0xCD} ** 32;
    var out1: [32]u8 = undefined;
    var out2: [32]u8 = undefined;
    _ = expandLabel(&secret, "derived", &context, &out1, 32);
    _ = expandLabel(&secret, "derived", "", &out2, 32);
    // Different context must produce different output
    var same = true;
    for (0..32) |i| {
        if (out1[i] != out2[i]) { same = false; break; }
    }
    if (same) return error.TestUnexpectedResult;
}
