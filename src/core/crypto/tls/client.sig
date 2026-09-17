// TLS 1.3 client (pure Sig) — public entry point for the TLS-over-TCP stack.
// Layer 1: Net/crypto.
//
// This directory module bundles everything a `wss://` client needs:
//   asn1.sig        — DER decoder
//   rsa.sig         — RSA PKCS#1 signature verification (bignum modexp)
//   x509.sig        — X.509 certificate parsing
//   x509_verify.sig — chain building + validation against the CA bundle
//   ca_bundle.sig   — embedded trusted roots
//   sha512.sig      — SHA-384/512 (for SHA-384 cert signatures)
//   (this file)     — TLS 1.3 record layer + handshake over std.Io.net.Stream
//
// Kept as one build module (relative sibling imports) so the whole stack
// registers once, mirroring how platform/mcp and platform/png are structured.

pub const asn1 = @import("asn1.sig");
pub const rsa = @import("rsa.sig");
pub const x509 = @import("x509.sig");
pub const x509_verify = @import("x509_verify.sig");
pub const ca_bundle = @import("ca_bundle.sig");
pub const sha512 = @import("sha512.sig");

// Re-exports for the rest of the stack are added here as each piece lands.

// ── Tests ───────────────────────────────────────────────────────────────
// Re-run the internal modules' tests through the module entry so a single
// test step covers the whole directory module.

test {
    @import("std").testing.refAllDecls(asn1);
    @import("std").testing.refAllDecls(rsa);
    @import("std").testing.refAllDecls(x509);
    @import("std").testing.refAllDecls(x509_verify);
    @import("std").testing.refAllDecls(ca_bundle);
    @import("std").testing.refAllDecls(sha512);
}
