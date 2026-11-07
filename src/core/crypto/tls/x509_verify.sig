// X.509 chain validation (RFC 5280 path validation, TLS-server profile).
// Layer 1: crypto (internal to the tls_client directory module).
//
// Given a server-sent chain [leaf, intermediate...] plus a set of trusted root
// certificates and the expected hostname + current time, this:
//   1. verifies each cert's signature with its issuer's public key,
//   2. links issuer→subject names down the chain,
//   3. checks every cert's validity window against `now`,
//   4. requires intermediates/roots to be CAs (basicConstraints) whose
//      keyUsage allows keyCertSign, and enforces pathLenConstraint,
//   5. anchors the chain at a trusted root (by signature, not just name); on
//      Windows, when no supplied root anchors the top of the chain, the OS
//      ROOT store (kept current by Windows Update) is tried under the same
//      anchor rules,
//   6. checks the leaf's SAN against the hostname,
//   7. requires the leaf to be an end-entity (not a CA) whose extendedKeyUsage,
//      if present, includes serverAuth (intermediates: serverAuth or any),
//   8. rejects any certificate on the path with an unknown critical extension,
//   9. applies dNSName nameConstraints (permitted/excluded subtrees) of every
//      CA on the path to the leaf's SAN dNSNames. Other name forms
//      (iPAddress, directoryName, ...) are not constrained here; the leaf is
//      only ever matched by dNSName.
//
// Supported signature algorithms: RSA PKCS#1 v1.5 (SHA-256/384/512) and ECDSA
// over P-256 or P-384 keys with SHA-256 or SHA-384 (e.g. GTS Root R4 → WE1,
// the chain behind api.anthropic.com). Anything else (e.g. RSA-PSS cert
// signatures, P-521) is REJECTED rather than silently accepted — fail closed.

const asn1 = @import("asn1.sig");
const x509 = @import("x509.sig");
const rsa = @import("rsa.sig");
const p256 = @import("p256");
const p384 = @import("p384");
const sha256 = @import("sha256");
const sha512 = @import("sha512.sig");

pub const MAX_CHAIN: usize = 8;

pub const Error = error{
    EmptyChain,
    ChainTooLong,
    SignatureInvalid,
    NameMismatch, // issuer/subject link broken
    Expired, // outside validity window
    NotYetValid,
    NotACa, // an issuer lacked the CA basic-constraint
    UntrustedRoot, // chain did not anchor to a trusted root
    HostnameMismatch,
    UnsupportedAlgorithm,
    ParseError,
    LeafIsCa, // the end-entity certificate has basicConstraints cA=TRUE
    BadKeyUsage, // an issuer lacks keyUsage keyCertSign
    BadExtKeyUsage, // EKU present but not valid for a TLS server
    PathLenExceeded, // a CA's pathLenConstraint is exceeded
    UnknownCriticalExtension,
    NameConstraintViolation,
};

/// Verify `sig` over `tbs` using `issuer`'s public key and `alg`.
fn verifySig(issuer: *const x509.Cert, alg: x509.SigAlg, tbs: []const u8, sig: []const u8) Error!void {
    switch (alg) {
        .rsa_pkcs1_sha256, .rsa_pkcs1_sha384, .rsa_pkcs1_sha512 => {
            if (issuer.key_alg != .rsa) return Error.UnsupportedAlgorithm;
            const pk = rsa.publicKey(issuer.rsa_modulus, issuer.rsa_exponent) catch
                return Error.UnsupportedAlgorithm;
            const h: rsa.Hash = switch (alg) {
                .rsa_pkcs1_sha256 => .sha256,
                .rsa_pkcs1_sha384 => .sha384,
                else => .sha512,
            };
            if (!rsa.verifyPkcs1(&pk, h, tbs, sig)) return Error.SignatureInvalid;
        },
        .ecdsa_sha256, .ecdsa_sha384 => {
            // SHA-256 digest (32 bytes) or SHA-384 digest (48 bytes).
            var digest_buf: [48]u8 = undefined;
            const digest: []const u8 = if (alg == .ecdsa_sha256) blk: {
                digest_buf[0..32].* = sha256.hash(tbs);
                break :blk digest_buf[0..32];
            } else blk: {
                digest_buf = sha512.sha384(tbs);
                break :blk digest_buf[0..48];
            };
            try verifyEcdsa(issuer, digest, sig);
        },
        .unsupported => return Error.UnsupportedAlgorithm,
    }
}

/// ECDSA-verify `sig` (DER) over a precomputed `digest` with `key`'s EC public
/// key (P-256 or P-384, uncompressed point). Public so the TLS layer can reuse
/// it for CertificateVerify.
pub fn verifyEcdsa(key: *const x509.Cert, digest: []const u8, sig: []const u8) Error!void {
    switch (key.key_alg) {
        .ecdsa_p256 => {
            // EC point is 0x04 || X(32) || Y(32).
            if (key.ec_point.len != 65 or key.ec_point[0] != 0x04) return Error.UnsupportedAlgorithm;
            var raw_sig: [64]u8 = undefined;
            try ecdsaDerToRaw(sig, &raw_sig);
            // ECDSA uses the leftmost 256 bits of a longer (SHA-384) digest.
            if (digest.len < 32) return Error.UnsupportedAlgorithm;
            if (!p256.verify(key.ec_point[1..65], digest[0..32], &raw_sig)) return Error.SignatureInvalid;
        },
        .ecdsa_p384 => {
            // EC point is 0x04 || X(48) || Y(48).
            if (key.ec_point.len != 97 or key.ec_point[0] != 0x04) return Error.UnsupportedAlgorithm;
            var raw_sig: [96]u8 = undefined;
            try ecdsaDerToRaw(sig, &raw_sig);
            if (!p384.verify(key.ec_point[1..97], digest, &raw_sig)) return Error.SignatureInvalid;
        },
        else => return Error.UnsupportedAlgorithm,
    }
}

/// Convert a DER ECDSA-Sig-Value (SEQUENCE { r INTEGER, s INTEGER }) to the
/// fixed r||s form the curve verifiers expect (each half left-zero-padded to
/// out.len / 2: 64 bytes for P-256, 96 for P-384).
/// Public so the TLS layer can reuse it for CertificateVerify ECDSA sigs.
pub fn ecdsaDerToRawPub(der: []const u8, out: *[64]u8) Error!void {
    return ecdsaDerToRaw(der, out);
}

/// The P-384 form: r(48) || s(48).
pub fn ecdsaDerToRaw384(der: []const u8, out: *[96]u8) Error!void {
    return ecdsaDerToRaw(der, out);
}

fn ecdsaDerToRaw(der: []const u8, out: anytype) Error!void {
    const half = out.len / 2;
    var c = asn1.Cursor.init(der);
    const seq = c.expect(asn1.TAG_SEQUENCE) catch return Error.ParseError;
    var s = asn1.intoSequence(seq);
    const r_el = s.expect(asn1.TAG_INTEGER) catch return Error.ParseError;
    const s_el = s.expect(asn1.TAG_INTEGER) catch return Error.ParseError;
    const r_bytes = asn1.integerBytes(r_el) catch return Error.ParseError;
    const s_bytes = asn1.integerBytes(s_el) catch return Error.ParseError;
    if (r_bytes.len > half or s_bytes.len > half) return Error.ParseError;
    for (out) |*o| o.* = 0;
    @memcpy(out[half - r_bytes.len .. half], r_bytes);
    @memcpy(out[out.len - s_bytes.len .. out.len], s_bytes);
}

/// Verify that `issuer`'s key signed `cert` (one chain link, no name, CA or
/// validity checks). For diagnostics and tools; verifyChain is the real gate.
pub fn verifyIssued(cert: *const x509.Cert, issuer: *const x509.Cert) Error!void {
    return verifySig(issuer, cert.sig_alg, cert.tbs_raw, cert.signature);
}

fn checkValidity(cert: *const x509.Cert, now: i64) Error!void {
    if (now < cert.not_before) return Error.NotYetValid;
    if (now > cert.not_after) return Error.Expired;
}

/// `root` anchors `cert`: a CA whose keyUsage (if present) allows certificate
/// signing, inside its validity window, whose subject is `cert`'s issuer AND
/// whose key verifies `cert`'s signature.
fn isAnchorFor(cert: *const x509.Cert, root: *const x509.Cert, now: i64) bool {
    if (!root.is_ca) return false;
    if (root.has_key_usage and root.key_usage & x509.KU_KEY_CERT_SIGN == 0) return false;
    if (!x509.namesEqual(cert.issuer_raw, root.subject_raw)) return false;
    checkValidity(root, now) catch return false;
    verifySig(root, cert.sig_alg, cert.tbs_raw, cert.signature) catch return false;
    return true;
}

/// A trusted root that issued `cert`: issuer name matches the root's subject
/// AND the root's key verifies the signature. Expired roots, and roots whose
/// keyUsage forbids certificate signing, are not anchors. A root with the
/// right name but a different key (e.g. a re-keyed root) is skipped.
fn issuedByRoot(cert: *const x509.Cert, roots: []const x509.Cert, now: i64) ?*const x509.Cert {
    for (roots) |*root| {
        if (isAnchorFor(cert, root, now)) return root;
    }
    return null;
}

/// Anchor `cert` (the top of the chain) in the Windows system ROOT store, under
/// the same rules as the supplied roots (isAnchorFor, then the root's own
/// constraints on the path below it). True if anchored. Only Windows has the
/// store; elsewhere this is false and win32 is never referenced.
fn trySystemRoots(cert: *const x509.Cert, below: usize, leaf: *const x509.Cert, now: i64) Error!bool {
    if (@import("builtin").os.tag != .windows) return false;
    const w32 = @import("win32");
    // "ROOT" as a null-terminated UTF-16 string.
    const store_name = [_:0]u16{ 'R', 'O', 'O', 'T' };
    const store = w32.CertOpenSystemStoreW(null, &store_name) orelse return false;
    defer _ = w32.CertCloseStore(store, 0);
    var ctx: ?*const w32.CERT_CONTEXT = null;
    while (true) {
        ctx = w32.CertEnumCertificatesInStore(store, ctx);
        const c = ctx orelse break;
        const der = c.pbCertEncoded[0..@as(usize, c.cbCertEncoded)];
        const root = x509.parse(der) catch continue;
        if (!isAnchorFor(cert, &root, now)) continue;
        try checkCaConstraints(&root, below, leaf);
        return true;
    }
    return false;
}

/// True if `cert` is itself one of the trusted roots (byte-identical content).
fn isTrustedRoot(cert: *const x509.Cert, roots: []const x509.Cert) bool {
    for (roots) |*root| {
        if (cert.tbs_raw.len == root.tbs_raw.len and
            @import("std").mem.eql(u8, cert.tbs_raw, root.tbs_raw)) return true;
    }
    return false;
}

/// Self-issued (subject == issuer): such intermediates (key rollover,
/// re-signed roots) do not count toward pathLenConstraint (RFC 5280 §4.2.1.9).
fn selfIssued(cert: *const x509.Cert) bool {
    return x509.namesEqual(cert.subject_raw, cert.issuer_raw);
}

/// The end-entity checks for a TLS server certificate.
fn checkLeaf(leaf: *const x509.Cert) Error!void {
    if (leaf.is_ca) return Error.LeafIsCa;
    if (leaf.has_eku and !leaf.eku_server_auth) return Error.BadExtKeyUsage;
}

/// Constraints a CA (intermediate or anchor root) places on the path below
/// it. `below` is the number of non-self-issued intermediates between it and
/// the leaf.
fn checkCaConstraints(ca: *const x509.Cert, below: usize, leaf: *const x509.Cert) Error!void {
    if (ca.path_len) |pl| {
        if (below > pl) return Error.PathLenExceeded;
    }
    if (ca.name_constraints.len != 0) try checkNameConstraints(ca.name_constraints, leaf);
}

/// Every SAN dNSName of `leaf` must lie in a permitted dNSName subtree (when
/// any are listed) and in no excluded one. Malformed constraints fail closed.
fn checkNameConstraints(nc_der: []const u8, leaf: *const x509.Cert) Error!void {
    if (leaf.san_raw.len == 0) return Error.NameConstraintViolation;
    var c = asn1.Cursor.init(leaf.san_raw);
    const seq = c.expect(asn1.TAG_SEQUENCE) catch return Error.NameConstraintViolation;
    var g = asn1.intoSequence(seq);
    while (!g.atEnd()) {
        const name = g.next() catch return Error.NameConstraintViolation;
        if (name.tag != asn1.contextPrimitive(2)) continue;
        try checkDnsNameConstraints(nc_der, name.data);
    }
}

fn checkDnsNameConstraints(nc_der: []const u8, name: []const u8) Error!void {
    // NameConstraints ::= SEQUENCE {
    //   permittedSubtrees [0] GeneralSubtrees OPTIONAL,
    //   excludedSubtrees  [1] GeneralSubtrees OPTIONAL }
    // GeneralSubtree ::= SEQUENCE { base GeneralName, minimum [0], maximum [1] }
    var c = asn1.Cursor.init(nc_der);
    const seq = c.expect(asn1.TAG_SEQUENCE) catch return Error.NameConstraintViolation;
    var nc = asn1.intoSequence(seq);
    var have_permitted_dns = false;
    var permitted = false;
    while (!nc.atEnd()) {
        const subtrees = nc.next() catch return Error.NameConstraintViolation;
        const is_permitted = subtrees.tag == asn1.contextConstructed(0);
        const is_excluded = subtrees.tag == asn1.contextConstructed(1);
        if (!is_permitted and !is_excluded) return Error.NameConstraintViolation;
        var st = asn1.intoSequence(subtrees);
        while (!st.atEnd()) {
            const gs = st.expect(asn1.TAG_SEQUENCE) catch return Error.NameConstraintViolation;
            var b = asn1.intoSequence(gs);
            const base = b.next() catch return Error.NameConstraintViolation;
            if (base.tag != asn1.contextPrimitive(2)) continue; // not a dNSName subtree
            if (is_excluded) {
                if (dnsInSubtree(base.data, name)) return Error.NameConstraintViolation;
            } else {
                have_permitted_dns = true;
                if (dnsInSubtree(base.data, name)) permitted = true;
            }
        }
    }
    if (have_permitted_dns and !permitted) return Error.NameConstraintViolation;
}

/// RFC 5280 §4.2.1.10 dNSName subtree test: "example.com" covers itself and
/// every name ending in ".example.com"; a leading-dot base ".example.com"
/// covers subdomains only; an empty base covers everything. A SAN wildcard
/// "*.example.com" is tested as written (it ends in the subtree's suffix).
fn dnsInSubtree(base: []const u8, name: []const u8) bool {
    if (base.len == 0) return true;
    if (base[0] == '.') return name.len > base.len and eqlIgnoreCase(name[name.len - base.len ..], base);
    if (eqlIgnoreCase(name, base)) return true;
    return name.len > base.len and name[name.len - base.len - 1] == '.' and
        eqlIgnoreCase(name[name.len - base.len ..], base);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lx = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const ly = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lx != ly) return false;
    }
    return true;
}

/// Full chain validation. `chain[0]` is the leaf; `chain[1..]` are intermediates
/// in order. `roots` are trusted, pre-parsed CA certificates. `now` is Unix secs.
///
/// Path building anchors at the FIRST cert (walking up from the leaf) that a
/// trusted root issued. Servers often append extra cross-signed certificates
/// (GTS Root R4 by GlobalSign, ISRG Root X2 by X1, ...) for old clients; with
/// the modern root in the store, the chain is complete before those, so their
/// algorithms, extensions and (earlier) expiry dates don't matter — as in
/// browsers.
pub fn verifyChain(
    chain: []const x509.Cert,
    roots: []const x509.Cert,
    hostname: []const u8,
    now: i64,
) Error!void {
    if (chain.len == 0) return Error.EmptyChain;
    if (chain.len > MAX_CHAIN) return Error.ChainTooLong;
    const leaf = &chain[0];

    // 1. Leaf hostname must match a SAN dNSName; the leaf must be an
    //    end-entity certificate usable for TLS server authentication.
    if (!x509.certMatchesHost(leaf, hostname)) return Error.HostnameMismatch;
    try checkLeaf(leaf);

    // 2. Walk leaf → up. At each cert: it must be in its validity window and
    //    carry no unknown critical extension; an intermediate must also honour
    //    its own constraints. If a trusted root issued it, the chain is
    //    anchored (subject to the root's constraints). Otherwise the NEXT cert
    //    must be its issuer (name link + CA + keyCertSign + signature).
    var below: usize = 0; // non-self-issued intermediates below chain[i]
    var i: usize = 0;
    while (i < chain.len) : (i += 1) {
        const cert = &chain[i];
        try checkValidity(cert, now);
        if (cert.unknown_critical) return Error.UnknownCriticalExtension;
        if (i > 0) {
            // cert was verified as the issuer of chain[i-1] (CA + keyCertSign).
            try checkCaConstraints(cert, below, leaf);
            if (cert.has_eku and !cert.eku_server_auth and !cert.eku_any) return Error.BadExtKeyUsage;
            if (!selfIssued(cert)) below += 1;
        }
        if (issuedByRoot(cert, roots, now)) |root| {
            try checkCaConstraints(root, below, leaf);
            return;
        }
        // A server may send the root itself (as its own "intermediate").
        if (i > 0 and isTrustedRoot(cert, roots)) return;
        if (i + 1 == chain.len) {
            // Last resort for the top of the chain: the OS trust store.
            if (try trySystemRoots(cert, below, leaf, now)) return;
            break;
        }
        const issuer = &chain[i + 1];
        if (!x509.namesEqual(cert.issuer_raw, issuer.subject_raw)) return Error.NameMismatch;
        if (!issuer.is_ca) return Error.NotACa;
        if (!issuer.has_key_usage or issuer.key_usage & x509.KU_KEY_CERT_SIGN == 0) return Error.BadKeyUsage;
        try verifySig(issuer, cert.sig_alg, cert.tbs_raw, cert.signature);
    }
    return Error.UntrustedRoot;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "x509_verify: ECDSA DER→raw conversion pads correctly" {
    // SEQUENCE { INTEGER 0x01, INTEGER 0x02 } → r=00..01, s=00..02.
    const der = [_]u8{ 0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02 };
    var raw: [64]u8 = undefined;
    try ecdsaDerToRaw(&der, &raw);
    try testing.expectEqual(@as(u8, 1), raw[31]);
    try testing.expectEqual(@as(u8, 2), raw[63]);
    try testing.expectEqual(@as(u8, 0), raw[0]);
    try testing.expectEqual(@as(u8, 0), raw[32]);
}

test "x509_verify: empty chain rejected" {
    const chain = [_]x509.Cert{};
    const roots = [_]x509.Cert{};
    try testing.expectError(Error.EmptyChain, verifyChain(&chain, &roots, "x.com", 0));
}

test "x509_verify: real leaf signature verifies against its issuer key" {
    // The Binance leaf's signature over its TBS must verify with the issuer's
    // (intermediate) RSA key. Both are captured in testvec.sig.
    const tv = @import("testvec.sig");
    const leaf = try x509.parse(&tv.binance_leaf_der);
    const issuer = try x509.parse(&tv.binance_intermediate_der);
    // Sanity: the leaf's issuer name equals the intermediate's subject name.
    try testing.expect(x509.namesEqual(leaf.issuer_raw, issuer.subject_raw));
    // The core cryptographic check: RSA PKCS#1 v1.5 signature verification of a
    // REAL certificate signature — this exercises modexp + EMSA end to end.
    try verifySig(&issuer, leaf.sig_alg, leaf.tbs_raw, leaf.signature);
}

test "x509_verify: full real Binance chain anchors to DigiCert root" {
    const tv = @import("testvec.sig");
    const leaf = try x509.parse(&tv.binance_leaf_der);
    const inter = try x509.parse(&tv.binance_intermediate_der);
    const root = try x509.parse(&tv.digicert_root_g2_der);

    const chain = [_]x509.Cert{ leaf, inter };
    const roots = [_]x509.Cert{root};

    // A time inside all three validity windows (2026-06-01T00:00:00Z).
    const now: i64 = 1780272000;
    try verifyChain(&chain, &roots, "stream.binance.com", now);
}

test "x509_verify: chain rejects wrong hostname" {
    const tv = @import("testvec.sig");
    const leaf = try x509.parse(&tv.binance_leaf_der);
    const inter = try x509.parse(&tv.binance_intermediate_der);
    const root = try x509.parse(&tv.digicert_root_g2_der);
    const chain = [_]x509.Cert{ leaf, inter };
    const roots = [_]x509.Cert{root};
    const now: i64 = 1780272000;
    try testing.expectError(Error.HostnameMismatch, verifyChain(&chain, &roots, "evil.com", now));
}

test "x509_verify: chain rejects when expired" {
    const tv = @import("testvec.sig");
    const leaf = try x509.parse(&tv.binance_leaf_der);
    const inter = try x509.parse(&tv.binance_intermediate_der);
    const root = try x509.parse(&tv.digicert_root_g2_der);
    const chain = [_]x509.Cert{ leaf, inter };
    const roots = [_]x509.Cert{root};
    // Far future (year ~2100) — leaf definitely expired.
    const now: i64 = 4102444800;
    try testing.expectError(Error.Expired, verifyChain(&chain, &roots, "stream.binance.com", now));
}

test "x509_verify: empty embedded store falls back to the OS root store" {
    // With NO supplied roots the chain is untrusted, except on Windows, where
    // the system ROOT store trusts DigiCert Global Root G2 and anchors it.
    const tv = @import("testvec.sig");
    const leaf = try x509.parse(&tv.binance_leaf_der);
    const inter = try x509.parse(&tv.binance_intermediate_der);
    const chain = [_]x509.Cert{ leaf, inter };
    const roots = [_]x509.Cert{}; // empty store
    const now: i64 = 1780272000;
    if (@import("builtin").os.tag == .windows) {
        try verifyChain(&chain, &roots, "stream.binance.com", now);
    } else {
        try testing.expectError(Error.UntrustedRoot, verifyChain(&chain, &roots, "stream.binance.com", now));
    }
}

test "x509_verify: the OS-store fallback still rejects a wrong hostname and a forged link" {
    const tv = @import("testvec.sig");
    const leaf = try x509.parse(&tv.binance_leaf_der);
    const inter = try x509.parse(&tv.binance_intermediate_der);
    const chain = [_]x509.Cert{ leaf, inter };
    const roots = [_]x509.Cert{};
    const now: i64 = 1780272000;
    try testing.expectError(Error.HostnameMismatch, verifyChain(&chain, &roots, "evil.com", now));
    var inter_der = tv.binance_intermediate_der;
    inter_der[inter_der.len - 5] ^= 0x01; // corrupt the intermediate's signature
    const forged = [_]x509.Cert{ leaf, try x509.parse(&inter_der) };
    try testing.expectError(Error.UntrustedRoot, verifyChain(&forged, &roots, "stream.binance.com", now));
}

test "x509_verify: real Binance chain anchors to the EMBEDDED CA bundle" {
    const tv = @import("testvec.sig");
    const ca_bundle = @import("ca_bundle.sig");
    const leaf = try x509.parse(&tv.binance_leaf_der);
    const inter = try x509.parse(&tv.binance_intermediate_der);
    const chain = [_]x509.Cert{ leaf, inter };

    var root_buf: [ca_bundle.MAX_ROOTS]x509.Cert = undefined;
    const nroots = ca_bundle.load(&root_buf);
    const now: i64 = 1780272000;
    // This is the true end-to-end test: server chain + shipped trust store.
    try verifyChain(&chain, root_buf[0..nroots], "stream.binance.com", now);
}

test "x509_verify: api.anthropic.com chain (P-384 WE1 link) anchors to the bundle" {
    const tv = @import("testvec.sig");
    const ca_bundle = @import("ca_bundle.sig");
    const leaf = try x509.parse(&tv.anthropic_leaf_der);
    const we1 = try x509.parse(&tv.anthropic_we1_der);
    const cross = try x509.parse(&tv.anthropic_gts_r4_cross_der);
    try testing.expect(we1.key_alg == .ecdsa_p256);
    try testing.expect(cross.key_alg == .ecdsa_p384);
    var root_buf: [ca_bundle.MAX_ROOTS]x509.Cert = undefined;
    const nroots = ca_bundle.load(&root_buf);
    const now: i64 = 1790812800; // 2026-10-01
    // As the server sends it: leaf, WE1, GTS R4 (cross-signed by GlobalSign).
    const full = [_]x509.Cert{ leaf, we1, cross };
    try verifyChain(&full, root_buf[0..nroots], "api.anthropic.com", now);
    // Short chain: WE1 anchors directly to the self-signed GTS Root R4 (P-384).
    const short = [_]x509.Cert{ leaf, we1 };
    try verifyChain(&short, root_buf[0..nroots], "api.anthropic.com", now);
    try testing.expectError(Error.HostnameMismatch, verifyChain(&short, root_buf[0..nroots], "api.anthropic.com.evil", now));
}

test "x509_verify: tampered P-384 signature is rejected" {
    const tv = @import("testvec.sig");
    const ca_bundle = @import("ca_bundle.sig");
    var we1_der = tv.anthropic_we1_der;
    we1_der[we1_der.len - 5] ^= 0x01;
    const leaf = try x509.parse(&tv.anthropic_leaf_der);
    const we1 = try x509.parse(&we1_der);
    var root_buf: [ca_bundle.MAX_ROOTS]x509.Cert = undefined;
    const nroots = ca_bundle.load(&root_buf);
    const short = [_]x509.Cert{ leaf, we1 };
    try testing.expectError(Error.UntrustedRoot, verifyChain(&short, root_buf[0..nroots], "api.anthropic.com", 1790812800));
}

test "x509_verify: ECDSA DER→raw pads to P-384 width" {
    const der = [_]u8{ 0x30, 0x06, 0x02, 0x01, 0x07, 0x02, 0x01, 0x09 };
    var raw: [96]u8 = undefined;
    try ecdsaDerToRaw(&der, &raw);
    try testing.expectEqual(@as(u8, 7), raw[47]);
    try testing.expectEqual(@as(u8, 9), raw[95]);
    try testing.expectEqual(@as(u8, 0), raw[48]);
}

test "x509_verify: RSA-4096 issuer (GTS Root R1 → WR2) verifies" {
    const tv = @import("testvec.sig");
    const ca_bundle = @import("ca_bundle.sig");
    const wr2 = try x509.parse(&tv.google_wr2_der);
    var root_buf: [ca_bundle.MAX_ROOTS]x509.Cert = undefined;
    const nroots = ca_bundle.load(&root_buf);
    var found = false;
    for (root_buf[0..nroots]) |*root| {
        if (!x509.namesEqual(wr2.issuer_raw, root.subject_raw)) continue;
        try testing.expectEqual(@as(usize, 512), root.rsa_modulus.len);
        try verifyIssued(&wr2, root);
        found = true;
    }
    try testing.expect(found);
}

test "x509_verify: letsencrypt.org chain anchors at ISRG Root X2 before the RSA cross-sign" {
    const tv = @import("testvec.sig");
    const ca_bundle = @import("ca_bundle.sig");
    const chain = [_]x509.Cert{
        try x509.parse(&tv.le_leaf_der),
        try x509.parse(&tv.le_ye2_der),
        try x509.parse(&tv.le_root_ye_der),
        try x509.parse(&tv.le_x2_cross_der),
    };
    var root_buf: [ca_bundle.MAX_ROOTS]x509.Cert = undefined;
    const nroots = ca_bundle.load(&root_buf);
    try verifyChain(&chain, root_buf[0..nroots], "letsencrypt.org", 1790812800);
    // The cross-signed X2 expires in 2032; the chain must not depend on it —
    // even with no X1 in the store, X2 itself anchors Root YE.
    try verifyChain(chain[0..3], root_buf[0..nroots], "letsencrypt.org", 1790812800);
}

// ── Synthetic PKI (testvec_pki.sig): leaf profile, keyUsage, pathLen, ──
// ── critical extensions and nameConstraints.                          ──

const PKI_NOW: i64 = 1790812800; // 2026-10-01, inside every test cert's window

fn pkiVerify(chain_ders: []const []const u8, host: []const u8) Error!void {
    const pki = @import("testvec_pki.sig");
    var chain: [MAX_CHAIN]x509.Cert = undefined;
    for (chain_ders, 0..) |der, i| chain[i] = x509.parse(der) catch return Error.ParseError;
    const roots = [_]x509.Cert{x509.parse(&pki.root_der) catch return Error.ParseError};
    return verifyChain(chain[0..chain_ders.len], &roots, host, PKI_NOW);
}

test "x509_verify: synthetic PKI parses the constraint extensions" {
    const pki = @import("testvec_pki.sig");
    const inter = try x509.parse(&pki.inter_der);
    try testing.expect(inter.is_ca);
    try testing.expectEqual(@as(?u8, 0), inter.path_len);
    try testing.expect(inter.has_key_usage and inter.key_usage & x509.KU_KEY_CERT_SIGN != 0);
    try testing.expect(inter.has_eku and inter.eku_server_auth);
    const leaf = try x509.parse(&pki.leaf_der);
    try testing.expect(!leaf.is_ca and leaf.path_len == null);
    try testing.expect(leaf.key_usage & x509.KU_DIGITAL_SIGNATURE != 0);
    try testing.expect(leaf.key_usage & x509.KU_KEY_CERT_SIGN == 0);
    try testing.expect(!leaf.unknown_critical);
    const crit = try x509.parse(&pki.leaf_crit_der);
    try testing.expect(crit.unknown_critical);
    const nc = try x509.parse(&pki.nc_der);
    try testing.expect(nc.name_constraints.len > 0 and !nc.unknown_critical);
}

test "x509_verify: synthetic leaf -> issuing CA -> root verifies" {
    const pki = @import("testvec_pki.sig");
    try pkiVerify(&.{ &pki.leaf_der, &pki.inter_der }, "tls.galaxy.test");
    try pkiVerify(&.{ &pki.leaf_der, &pki.inter_der }, "x.galaxy.test");
    // The root may be sent too.
    try pkiVerify(&.{ &pki.leaf_der, &pki.inter_der, &pki.root_der }, "tls.galaxy.test");
}

test "x509_verify: leaf with EKU clientAuth only is rejected" {
    const pki = @import("testvec_pki.sig");
    try testing.expectError(Error.BadExtKeyUsage, pkiVerify(&.{ &pki.leaf_client_der, &pki.inter_der }, "client.galaxy.test"));
}

test "x509_verify: a CA certificate is not accepted as the leaf" {
    const pki = @import("testvec_pki.sig");
    try testing.expectError(Error.LeafIsCa, pkiVerify(&.{ &pki.leaf_ca_der, &pki.inter_der }, "ca.galaxy.test"));
}

test "x509_verify: chain exceeding an intermediate's pathLen=0 is rejected" {
    const pki = @import("testvec_pki.sig");
    try testing.expectError(Error.PathLenExceeded, pkiVerify(&.{ &pki.leaf_deep_der, &pki.sub_der, &pki.inter_der }, "deep.galaxy.test"));
}

test "x509_verify: issuer without keyUsage keyCertSign is rejected" {
    const pki = @import("testvec_pki.sig");
    try testing.expectError(Error.BadKeyUsage, pkiVerify(&.{ &pki.leaf_noks_der, &pki.noks_der }, "noks.galaxy.test"));
}

test "x509_verify: unknown critical extension is rejected" {
    const pki = @import("testvec_pki.sig");
    try testing.expectError(Error.UnknownCriticalExtension, pkiVerify(&.{ &pki.leaf_crit_der, &pki.inter_der }, "crit.galaxy.test"));
}

test "x509_verify: name-constrained CA cannot issue outside its subtree" {
    const pki = @import("testvec_pki.sig");
    try pkiVerify(&.{ &pki.leaf_nc_good_der, &pki.nc_der }, "www.good.test");
    // www.evil.test is outside permitted DNS:good.test — rejected even when
    // the client asks for the other (permitted) SAN on the same certificate.
    try testing.expectError(Error.NameConstraintViolation, pkiVerify(&.{ &pki.leaf_nc_bad_der, &pki.nc_der }, "www.evil.test"));
    try testing.expectError(Error.NameConstraintViolation, pkiVerify(&.{ &pki.leaf_nc_bad_der, &pki.nc_der }, "www.good.test"));
}

test "x509_verify: dNSName subtree matching" {
    try testing.expect(dnsInSubtree("good.test", "good.test"));
    try testing.expect(dnsInSubtree("good.test", "a.b.GOOD.test"));
    try testing.expect(dnsInSubtree("good.test", "*.good.test"));
    try testing.expect(!dnsInSubtree("good.test", "notgood.test"));
    try testing.expect(!dnsInSubtree(".good.test", "good.test"));
    try testing.expect(dnsInSubtree(".good.test", "x.good.test"));
    try testing.expect(dnsInSubtree("", "anything"));
}
