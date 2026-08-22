// @zpm/crypto — Layer 0 freestanding cryptographic primitives.
//
// Pure computation. No allocator, no platform deps, no std import.
// Usable from both hosted (Windows/Linux) and freestanding (EL1 kernel) targets.
//
// Provides:
//   - AES-128: ECB block encrypt, key expansion
//   - AES-128-GCM: AEAD seal/open with GHASH authentication
//   - SHA-256: hash, HMAC, incremental context
//   - HKDF: Extract, Expand, Expand-Label (TLS 1.3 / QUIC format)
//   - X25519: Diffie-Hellman key exchange (RFC 7748)
//   - QUIC Initial key derivation (RFC 9001 §5.2)

pub const aes = @import("aes.sig");
pub const gcm = @import("gcm.sig");
pub const sha256 = @import("sha256.sig");
pub const hkdf = @import("hkdf.sig");
pub const x25519 = @import("x25519.sig");
pub const quic = @import("quic.sig");
pub const tls13_server = @import("tls13_server.sig");
