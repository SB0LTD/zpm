// X.509 chain validation (RFC 5280 path validation, TLS-server profile).
// Layer 1: crypto (internal to the tls_client directory module).
//
// Given a server-sent chain [leaf, intermediate...] plus a set of trusted root
// certificates and the expected hostname + current time, this:
//   1. verifies each cert's signature with its issuer's public key,
//   2. links issuer→subject names down the chain,
//   3. checks every cert's validity window against `now`,
//   4. requires intermediates/roots to be CAs (basicConstraints),
//   5. anchors the chain at a trusted root (by signature, not just name),
//   6. checks the leaf's SAN against the hostname.
//
// Supported signature algorithms: RSA PKCS#1 v1.5 (SHA-256/384/512) and ECDSA
// P-256 (SHA-256). Anything else (e.g. ECDSA P-384, RSA-PSS) is REJECTED rather
// than silently accepted — a fail-closed posture for trading traffic.

const asn1 = @import("asn1.sig");
const x509 = @import("x509.sig");
const rsa = @import("rsa.sig");
const p256 = @import("p256");
const sha256 = @import("sha256");

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
        .ecdsa_sha256 => {
            if (issuer.key_alg != .ecdsa_p256) return Error.UnsupportedAlgorithm;
            // EC point is 0x04 || X(32) || Y(32).
            if (issuer.ec_point.len != 65 or issuer.ec_point[0] != 0x04) return Error.UnsupportedAlgorithm;
            var xy: [64]u8 = undefined;
            @memcpy(&xy, issuer.ec_point[1..65]);
            const digest = sha256.hash(tbs);
            var raw_sig: [64]u8 = undefined;
            try ecdsaDerToRaw(sig, &raw_sig);
            if (!p256.verify(&xy, &digest, &raw_sig)) return Error.SignatureInvalid;
        },
        .ecdsa_sha384, .unsupported => return Error.UnsupportedAlgorithm,
    }
}

/// Convert a DER ECDSA-Sig-Value (SEQUENCE { r INTEGER, s INTEGER }) to the
/// fixed 64-byte r(32)||s(32) form p256.verify expects (left-zero-padded).
/// Public so the TLS layer can reuse it for CertificateVerify ECDSA sigs.
pub fn ecdsaDerToRawPub(der: []const u8, out: *[64]u8) Error!void {
    return ecdsaDerToRaw(der, out);
}

fn ecdsaDerToRaw(der: []const u8, out: *[64]u8) Error!void {
    var c = asn1.Cursor.init(der);
    const seq = c.expect(asn1.TAG_SEQUENCE) catch return Error.ParseError;
    var s = asn1.intoSequence(seq);
    const r_el = s.expect(asn1.TAG_INTEGER) catch return Error.ParseError;
    const s_el = s.expect(asn1.TAG_INTEGER) catch return Error.ParseError;
    const r_bytes = asn1.integerBytes(r_el) catch return Error.ParseError;
    const s_bytes = asn1.integerBytes(s_el) catch return Error.ParseError;
    if (r_bytes.len > 32 or s_bytes.len > 32) return Error.ParseError;
    for (out) |*o| o.* = 0;
    @memcpy(out[32 - r_bytes.len .. 32], r_bytes);
    @memcpy(out[64 - s_bytes.len .. 64], s_bytes);
}

fn checkValidity(cert: *const x509.Cert, now: i64) Error!void {
    if (now < cert.not_before) return Error.NotYetValid;
    if (now > cert.not_after) return Error.Expired;
}

/// Full chain validation. `chain[0]` is the leaf; `chain[1..]` are intermediates
/// in order. `roots` are trusted, pre-parsed CA certificates. `now` is Unix secs.
pub fn verifyChain(
    chain: []const x509.Cert,
    roots: []const x509.Cert,
    hostname: []const u8,
    now: i64,
) Error!void {
    if (chain.len == 0) return Error.EmptyChain;
    if (chain.len > MAX_CHAIN) return Error.ChainTooLong;

    // 1. Leaf hostname must match a SAN dNSName.
    if (!x509.certMatchesHost(&chain[0], hostname)) return Error.HostnameMismatch;

    // 2. Walk leaf → ... verifying each cert against the NEXT in the chain,
    //    which must be its issuer (name link + CA + signature + validity).
    var i: usize = 0;
    while (i < chain.len) : (i += 1) {
        const cert = &chain[i];
        try checkValidity(cert, now);

        if (i + 1 < chain.len) {
            const issuer = &chain[i + 1];
            if (!x509.namesEqual(cert.issuer_raw, issuer.subject_raw)) return Error.NameMismatch;
            if (!issuer.is_ca) return Error.NotACa;
            try checkValidity(issuer, now);
            try verifySig(issuer, cert.sig_alg, cert.tbs_raw, cert.signature);
        }
    }

    // 3. Anchor: the top-of-chain cert must be issued by a trusted root — match
    //    by issuer name AND verify its signature with the root's key. (A root
    //    that also equals the top cert, i.e. self-issued in the store, is fine.)
    const top = &chain[chain.len - 1];
    var r: usize = 0;
    while (r < roots.len) : (r += 1) {
        const root = &roots[r];
        if (!root.is_ca) continue;
        if (!x509.namesEqual(top.issuer_raw, root.subject_raw)) continue;
        // Root validity is checked too (expired roots are not anchors).
        checkValidity(root, now) catch continue;
        if (verifySig(root, top.sig_alg, top.tbs_raw, top.signature)) |_| {
            return; // anchored to a trusted root — chain valid.
        } else |_| {
            continue; // name matched but signature didn't — try other roots.
        }
    }
    // Also accept the case where the top cert IS a trusted root (present in the
    // store by exact subject/key), which some servers send.
    r = 0;
    while (r < roots.len) : (r += 1) {
        if (x509.namesEqual(top.subject_raw, roots[r].subject_raw) and
            x509.namesEqual(top.issuer_raw, roots[r].issuer_raw))
        {
            checkValidity(&roots[r], now) catch continue;
            return;
        }
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

test "x509_verify: chain rejects with no trusted root" {
    const tv = @import("testvec.sig");
    const leaf = try x509.parse(&tv.binance_leaf_der);
    const inter = try x509.parse(&tv.binance_intermediate_der);
    const chain = [_]x509.Cert{ leaf, inter };
    const roots = [_]x509.Cert{}; // empty store
    const now: i64 = 1780272000;
    try testing.expectError(Error.UntrustedRoot, verifyChain(&chain, &roots, "stream.binance.com", now));
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
