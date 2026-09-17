// X.509 v3 certificate parser (RFC 5280) — pure Sig, no allocator.
// Layer 1: crypto (internal to the tls_client directory module).
//
// Parses a DER Certificate into a `Cert` whose fields are slices INTO the
// source DER (nothing copied). Extracts exactly what chain validation needs:
//   • tbs_raw          — the exact TBSCertificate DER (what the signature covers)
//   • signature_alg    — algorithm OID of the outer signature
//   • signature        — the signature bits
//   • issuer_raw / subject_raw — the RDNSequence DER (compared for chain links)
//   • not_before / not_after   — validity as Unix seconds
//   • SPKI             — subject public key (RSA n/e or EC point) + its algorithm
//   • SAN dNSNames     — for hostname verification
//   • basicConstraints — is_ca + path_len (for intermediate/root checks)
//
//   Certificate ::= SEQUENCE {
//     tbsCertificate       TBSCertificate,
//     signatureAlgorithm   AlgorithmIdentifier,
//     signatureValue       BIT STRING }
//   TBSCertificate ::= SEQUENCE {
//     [0] version, serialNumber, signature (algid), issuer, validity,
//     subject, subjectPublicKeyInfo, ...optional..., [3] extensions }

const asn1 = @import("asn1.sig");

pub const Error = asn1.Error || error{
    Malformed,
    UnsupportedKey,
    UnsupportedSigAlg,
    TooManyNames,
};

pub const MAX_SAN_NAMES: usize = 24;
pub const MAX_NAME_LEN: usize = 256;

/// Public-key algorithm of the certificate's subject key.
pub const KeyAlg = enum { rsa, ecdsa_p256, ecdsa_p384, unsupported };

/// Signature algorithm of the outer certificate signature.
pub const SigAlg = enum {
    rsa_pkcs1_sha256,
    rsa_pkcs1_sha384,
    rsa_pkcs1_sha512,
    ecdsa_sha256,
    ecdsa_sha384,
    unsupported,
};

pub const Cert = struct {
    /// Exact DER of TBSCertificate (tag+len+value) — the bytes the signature signs.
    tbs_raw: []const u8 = &.{},
    sig_alg: SigAlg = .unsupported,
    signature: []const u8 = &.{},

    issuer_raw: []const u8 = &.{}, // RDNSequence DER
    subject_raw: []const u8 = &.{},

    not_before: i64 = 0, // Unix seconds
    not_after: i64 = 0,

    key_alg: KeyAlg = .unsupported,
    // For RSA:
    rsa_modulus: []const u8 = &.{}, // big-endian, sign pad stripped
    rsa_exponent: []const u8 = &.{},
    // For ECDSA: the uncompressed point (0x04 || X || Y) from the SPKI BIT STRING.
    ec_point: []const u8 = &.{},

    is_ca: bool = false,
    has_basic_constraints: bool = false,

    // SAN dNSNames (each a slice into the DER).
    san: [MAX_SAN_NAMES][]const u8 = [_][]const u8{&.{}} ** MAX_SAN_NAMES,
    san_count: usize = 0,
};

// ── OIDs (DER content bytes, i.e. the V of the OID TLV) ─────────────────
const OID_RSA_ENCRYPTION = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
const OID_EC_PUBLIC_KEY = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const OID_P256 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
const OID_P384 = [_]u8{ 0x2b, 0x81, 0x04, 0x00, 0x22 };
const OID_SHA256_RSA = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b };
const OID_SHA384_RSA = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0c };
const OID_SHA512_RSA = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0d };
const OID_ECDSA_SHA256 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };
const OID_ECDSA_SHA384 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03 };
const OID_BASIC_CONSTRAINTS = [_]u8{ 0x55, 0x1d, 0x13 };
const OID_SAN = [_]u8{ 0x55, 0x1d, 0x11 };

fn sigAlgFromOid(el: asn1.Element) SigAlg {
    if (asn1.oidEquals(el, &OID_SHA256_RSA)) return .rsa_pkcs1_sha256;
    if (asn1.oidEquals(el, &OID_SHA384_RSA)) return .rsa_pkcs1_sha384;
    if (asn1.oidEquals(el, &OID_SHA512_RSA)) return .rsa_pkcs1_sha512;
    if (asn1.oidEquals(el, &OID_ECDSA_SHA256)) return .ecdsa_sha256;
    if (asn1.oidEquals(el, &OID_ECDSA_SHA384)) return .ecdsa_sha384;
    return .unsupported;
}

/// Parse a DER-encoded certificate.
pub fn parse(der: []const u8) Error!Cert {
    var cert = Cert{};
    var top = asn1.Cursor.init(der);
    const cert_seq = try top.expect(asn1.TAG_SEQUENCE);
    var c = asn1.intoSequence(cert_seq);

    // tbsCertificate — keep its exact raw bytes for signature verification.
    const tbs = try c.expect(asn1.TAG_SEQUENCE);
    cert.tbs_raw = tbs.raw;

    // signatureAlgorithm
    const sig_alg_seq = try c.expect(asn1.TAG_SEQUENCE);
    var sa = asn1.intoSequence(sig_alg_seq);
    const sa_oid = try sa.expect(asn1.TAG_OID);
    cert.sig_alg = sigAlgFromOid(sa_oid);

    // signatureValue (BIT STRING)
    const sig_bits = try c.expect(asn1.TAG_BIT_STRING);
    cert.signature = try asn1.bitStringBytes(sig_bits);

    // ── Parse TBSCertificate ──
    try parseTbs(tbs, &cert);
    return cert;
}

fn parseTbs(tbs: asn1.Element, cert: *Cert) Error!void {
    var t = asn1.intoSequence(tbs);

    // Optional [0] EXPLICIT version. If present (tag 0xA0), skip it.
    if (t.peekTag()) |tag| {
        if (tag == asn1.contextConstructed(0)) {
            _ = try t.next();
        }
    }

    _ = try t.expect(asn1.TAG_INTEGER); // serialNumber

    _ = try t.expect(asn1.TAG_SEQUENCE); // signature (inner AlgorithmIdentifier)

    // issuer
    const issuer = try t.expect(asn1.TAG_SEQUENCE);
    cert.issuer_raw = issuer.raw;

    // validity: SEQUENCE { notBefore Time, notAfter Time }
    const validity = try t.expect(asn1.TAG_SEQUENCE);
    var v = asn1.intoSequence(validity);
    const nb = try v.next();
    const na = try v.next();
    cert.not_before = try parseTime(nb);
    cert.not_after = try parseTime(na);

    // subject
    const subject = try t.expect(asn1.TAG_SEQUENCE);
    cert.subject_raw = subject.raw;

    // subjectPublicKeyInfo
    const spki = try t.expect(asn1.TAG_SEQUENCE);
    try parseSpki(spki, cert);

    // Optional [1] issuerUniqueID, [2] subjectUniqueID, [3] extensions.
    while (!t.atEnd()) {
        const el = try t.next();
        if (el.tag == asn1.contextConstructed(3)) {
            try parseExtensions(el, cert);
        }
    }
}

fn parseSpki(spki: asn1.Element, cert: *Cert) Error!void {
    var s = asn1.intoSequence(spki);
    // algorithm ::= SEQUENCE { OID, params }
    const alg = try s.expect(asn1.TAG_SEQUENCE);
    var a = asn1.intoSequence(alg);
    const alg_oid = try a.expect(asn1.TAG_OID);
    // subjectPublicKey BIT STRING
    const key_bits_el = try s.expect(asn1.TAG_BIT_STRING);
    const key_bits = try asn1.bitStringBytes(key_bits_el);

    if (asn1.oidEquals(alg_oid, &OID_RSA_ENCRYPTION)) {
        cert.key_alg = .rsa;
        // RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
        var k = asn1.Cursor.init(key_bits);
        const rsa_seq = try k.expect(asn1.TAG_SEQUENCE);
        var rk = asn1.intoSequence(rsa_seq);
        const mod = try rk.expect(asn1.TAG_INTEGER);
        const exp = try rk.expect(asn1.TAG_INTEGER);
        cert.rsa_modulus = try asn1.integerBytes(mod);
        cert.rsa_exponent = try asn1.integerBytes(exp);
    } else if (asn1.oidEquals(alg_oid, &OID_EC_PUBLIC_KEY)) {
        // The named curve is the algorithm parameter (next element in `a`).
        const curve = a.next() catch return Error.UnsupportedKey;
        if (asn1.oidEquals(curve, &OID_P256)) {
            cert.key_alg = .ecdsa_p256;
        } else if (asn1.oidEquals(curve, &OID_P384)) {
            cert.key_alg = .ecdsa_p384;
        } else {
            cert.key_alg = .unsupported;
        }
        cert.ec_point = key_bits; // uncompressed 0x04 || X || Y
    } else {
        cert.key_alg = .unsupported;
    }
}

fn parseExtensions(ext_wrap: asn1.Element, cert: *Cert) Error!void {
    // [3] EXPLICIT SEQUENCE OF Extension
    var w = asn1.intoSequence(ext_wrap);
    const seq = try w.expect(asn1.TAG_SEQUENCE);
    var exts = asn1.intoSequence(seq);
    while (!exts.atEnd()) {
        const ext = try exts.expect(asn1.TAG_SEQUENCE);
        var e = asn1.intoSequence(ext);
        const oid = try e.expect(asn1.TAG_OID);
        // Optional critical BOOLEAN, then the OCTET STRING value.
        var val_el = try e.next();
        if (val_el.tag == asn1.TAG_BOOLEAN) {
            val_el = try e.next();
        }
        if (val_el.tag != asn1.TAG_OCTET_STRING) continue;

        if (asn1.oidEquals(oid, &OID_BASIC_CONSTRAINTS)) {
            parseBasicConstraints(val_el.data, cert);
        } else if (asn1.oidEquals(oid, &OID_SAN)) {
            try parseSan(val_el.data, cert);
        }
    }
}

fn parseBasicConstraints(inner: []const u8, cert: *Cert) void {
    cert.has_basic_constraints = true;
    // BasicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE, pathLen INTEGER OPTIONAL }
    var c = asn1.Cursor.init(inner);
    const seq = c.expect(asn1.TAG_SEQUENCE) catch return;
    var b = asn1.intoSequence(seq);
    if (b.peekTag()) |tag| {
        if (tag == asn1.TAG_BOOLEAN) {
            const boolean = b.next() catch return;
            if (boolean.data.len == 1 and boolean.data[0] != 0) cert.is_ca = true;
        }
    }
}

fn parseSan(inner: []const u8, cert: *Cert) Error!void {
    // GeneralNames ::= SEQUENCE OF GeneralName; dNSName is [2] IA5String (0x82).
    var c = asn1.Cursor.init(inner);
    const seq = try c.expect(asn1.TAG_SEQUENCE);
    var g = asn1.intoSequence(seq);
    while (!g.atEnd()) {
        const name = try g.next();
        if (name.tag == asn1.contextPrimitive(2)) { // dNSName
            if (cert.san_count >= MAX_SAN_NAMES) return Error.TooManyNames;
            cert.san[cert.san_count] = name.data;
            cert.san_count += 1;
        }
    }
}

/// Parse an X.509 Time (UTCTime "YYMMDDHHMMSSZ" or GeneralizedTime
/// "YYYYMMDDHHMMSSZ") into Unix seconds (UTC).
fn parseTime(el: asn1.Element) Error!i64 {
    const s = el.data;
    var year: i64 = 0;
    var rest: []const u8 = undefined;
    if (el.tag == asn1.TAG_UTC_TIME) {
        if (s.len < 13) return Error.Malformed;
        const yy = try dd(s[0..2]);
        // RFC 5280: YY >= 50 => 19YY, else 20YY.
        year = if (yy >= 50) 1900 + yy else 2000 + yy;
        rest = s[2..];
    } else if (el.tag == asn1.TAG_GENERALIZED_TIME) {
        if (s.len < 15) return Error.Malformed;
        year = (try dd(s[0..2])) * 100 + (try dd(s[2..4]));
        rest = s[4..];
    } else return Error.Malformed;

    const mon = try dd(rest[0..2]);
    const day = try dd(rest[2..4]);
    const hour = try dd(rest[4..6]);
    const min = try dd(rest[6..8]);
    const sec = try dd(rest[8..10]);
    return toUnix(year, mon, day, hour, min, sec);
}

fn dd(b: []const u8) Error!i64 {
    if (b.len < 2 or b[0] < '0' or b[0] > '9' or b[1] < '0' or b[1] > '9') return Error.Malformed;
    return @as(i64, b[0] - '0') * 10 + @as(i64, b[1] - '0');
}

/// Days-from-civil (Howard Hinnant) → Unix seconds. Valid for the Gregorian range.
fn toUnix(y: i64, m: i64, d: i64, hh: i64, mm: i64, ss: i64) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = @divTrunc(if (yy >= 0) yy else yy - 399, 400);
    const yoe = yy - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss;
}

/// Case-insensitive hostname match against a SAN entry, supporting a single
/// leftmost "*." wildcard (RFC 6125). `pattern` is a SAN dNSName.
pub fn hostnameMatches(pattern: []const u8, host: []const u8) bool {
    if (pattern.len >= 2 and pattern[0] == '*' and pattern[1] == '.') {
        // Wildcard matches exactly one leftmost label of host.
        const suffix = pattern[1..]; // ".example.com"
        // host must have a label before the suffix and end with the suffix.
        const dot = indexOfByte(host, '.') orelse return false;
        const host_rest = host[dot..];
        return eqlIgnoreCase(host_rest, suffix);
    }
    return eqlIgnoreCase(pattern, host);
}

/// Does any SAN dNSName match `host`?
pub fn certMatchesHost(cert: *const Cert, host: []const u8) bool {
    var i: usize = 0;
    while (i < cert.san_count) : (i += 1) {
        if (hostnameMatches(cert.san[i], host)) return true;
    }
    return false;
}

fn indexOfByte(s: []const u8, b: u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == b) return i;
    }
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Byte-compare two DER names (issuer/subject) for chain linking.
pub fn namesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "x509: hostname wildcard matching" {
    try testing.expect(hostnameMatches("stream.binance.com", "stream.binance.com"));
    try testing.expect(hostnameMatches("*.binance.com", "stream.binance.com"));
    try testing.expect(!hostnameMatches("*.binance.com", "binance.com")); // needs a label
    try testing.expect(!hostnameMatches("*.binance.com", "a.b.binance.com")); // one label only
    try testing.expect(hostnameMatches("STREAM.BINANCE.COM", "stream.binance.com"));
}

test "x509: UTCTime to unix seconds" {
    // "230101000000Z" = 2023-01-01T00:00:00Z = 1672531200.
    const der = [_]u8{ asn1.TAG_UTC_TIME, 13, '2', '3', '0', '1', '0', '1', '0', '0', '0', '0', '0', '0', 'Z' };
    var c = asn1.Cursor.init(&der);
    const el = try c.next();
    try testing.expectEqual(@as(i64, 1672531200), try parseTime(el));
}

test "x509: GeneralizedTime to unix seconds" {
    // "20230101000000Z"
    const der = [_]u8{ asn1.TAG_GENERALIZED_TIME, 15, '2', '0', '2', '3', '0', '1', '0', '1', '0', '0', '0', '0', '0', '0', 'Z' };
    var c = asn1.Cursor.init(&der);
    const el = try c.next();
    try testing.expectEqual(@as(i64, 1672531200), try parseTime(el));
}

test "x509: names equal" {
    const a = [_]u8{ 1, 2, 3 };
    const b = [_]u8{ 1, 2, 3 };
    const d = [_]u8{ 1, 2, 4 };
    try testing.expect(namesEqual(&a, &b));
    try testing.expect(!namesEqual(&a, &d));
}

test "x509: parse a real Binance leaf certificate" {
    const testvec = @import("testvec.sig");
    const cert = try parse(&testvec.binance_leaf_der);

    // RSA-2048 subject key → 256-byte modulus.
    try testing.expectEqual(KeyAlg.rsa, cert.key_alg);
    try testing.expectEqual(@as(usize, 256), cert.rsa_modulus.len);
    try testing.expect(cert.rsa_exponent.len >= 1);

    // SHA-256/RSA signature (Binance leaf).
    try testing.expectEqual(SigAlg.rsa_pkcs1_sha256, cert.sig_alg);

    // Validity parsed and ordered.
    try testing.expect(cert.not_after > cert.not_before);

    // SAN present and matches the wildcard host.
    try testing.expect(cert.san_count >= 1);
    try testing.expect(certMatchesHost(&cert, "stream.binance.com"));
    try testing.expect(certMatchesHost(&cert, "binance.com"));
    try testing.expect(!certMatchesHost(&cert, "evil.com"));

    // The signature bits and TBS were captured.
    try testing.expect(cert.signature.len >= 128);
    try testing.expect(cert.tbs_raw.len > 100);
}
