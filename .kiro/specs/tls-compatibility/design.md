# Design Document

## Overview

This design expands the pure-Sig TLS 1.3 client (`src/core/crypto/tls/`) from a
single hardcoded cipher/group (AES-128-GCM-SHA256 + X25519) to full agility over
the suites, groups, and handshake features common on the public web, while
preserving the existing path byte-for-byte and keeping certificate validation
fully enforced.

The central refactor is replacing hardcoded assumptions with a `Suite`
descriptor selected from the ServerHello, and making the transcript + key
schedule hash-length-aware (SHA-256 = 32 bytes, SHA-384 = 48 bytes). New crypto
primitives (AES-256-GCM, ChaCha20-Poly1305, P-256 ECDH, SHA-384 HKDF) are added
as Layer-0 modules with their own RFC test vectors; `tls.sig` wires them in
behind the `Suite` seam.

### Design principles
- **Preserve the proven path.** The X25519 + AES-128-GCM-SHA256 handshake must
  produce identical wire bytes and identical derived keys after the refactor;
  the existing live-tls/live-wss tests are the regression gate.
- **Server chooses; client offers everything.** The ClientHello advertises all
  suites and both groups; selection logic reads the ServerHello.
- **Fail closed.** Any unsupported or inconsistent server selection is a typed
  error, never a silent mis-derive or mis-decrypt.
- **Allocation-free, Layer-0 primitives.** New AEAD/hash/ECDH modules follow the
  existing zero-alloc, caller-buffer conventions and layer hierarchy.

## Architecture

```
ClientHello (offer: [AES128GCM, AES256GCM, CHACHA20] x [X25519 share, P256 share])
        |
        v
ServerHello --> select Suite{hash, aead} + group
        |              |
        |              +-- HelloRetryRequest? --> resend CH2 with requested group
        v
Transcript(hash)  <-- SHA-256 or SHA-384, bound to the suite
        |
        v
KeySchedule(hash) --> handshake + application traffic secrets (HKDF-hash)
        |
        v
RecordKeys(aead)  --> AES-128-GCM | AES-256-GCM | ChaCha20-Poly1305
```

### Module layout
```
src/core/crypto/
  aes.sig            (extend) AES-256 key schedule alongside AES-128
  gcm.sig            (reuse)  GCM is key-size agnostic over the AES block
  chacha20poly1305.sig (NEW)  RFC 8439 AEAD (ChaCha20 + Poly1305)
  p256.sig           (extend) ECDH: scalar*base and scalar*peer-point
  sha384 path                 via existing tls/sha512.sig (sha384)
  hkdf.sig / hmac.sig (extend or parallel) SHA-384 variants for the 384 schedule
  tls/tls.sig        (refactor) Suite seam, transcript(hash), negotiation, HRR, ALPN
  tls/keysched384             SHA-384 key schedule (parallel to tls13_keys)
```

## Components and Interfaces

### Suite descriptor (tls.sig)
A comptime-known table maps the three supported suites to their parameters:
```sig
const Aead = enum { aes128_gcm, aes256_gcm, chacha20_poly1305 };
const HashId = enum { sha256, sha384 };
const Suite = struct { id: u16, hash: HashId, aead: Aead, key_len: usize, hash_len: usize };
const SUPPORTED = [_]Suite{
    .{ .id = 0x1301, .hash = .sha256, .aead = .aes128_gcm,       .key_len = 16, .hash_len = 32 },
    .{ .id = 0x1302, .hash = .sha384, .aead = .aes256_gcm,       .key_len = 32, .hash_len = 48 },
    .{ .id = 0x1303, .hash = .sha256, .aead = .chacha20_poly1305, .key_len = 32, .hash_len = 32 },
};
```
The ServerHello handler looks up the selected `id`; an unknown id ->
UnsupportedParams. All downstream code reads `suite.hash_len`/`suite.aead`.

### Transcript (hash-length-aware)
The transcript currently returns `[32]u8`. It becomes hash-aware: it feeds bytes
to EITHER a SHA-256 OR a SHA-384 running state (chosen once the suite is known;
before that, both are fed in parallel since the suite is unknown until
ServerHello). `hash()` returns a `[48]u8` buffer plus a length (32 or 48).
Rationale: the ClientHello and ServerHello are hashed before the suite is known,
so the transcript buffers raw bytes OR runs both hashes until selection. Buffering
raw handshake bytes (bounded, already done for certs) is simplest and avoids
double-hashing; the design buffers the pre-ServerHello messages and finalizes the
chosen hash once the suite is selected.

### Key schedule (parameterized by hash)
The SHA-256 schedule (`tls13_keys.sig`) is preserved. A parallel SHA-384
schedule provides the same operations over 48-byte secrets using HKDF-SHA384.
`tls.sig` selects which schedule to drive from `suite.hash`. Both expose the
same logical steps (deriveHandshakeSecrets, deriveApplicationSecrets,
computeFinished) so the handshake driver branches only at the type boundary.

### RecordKeys (AEAD-agnostic)
`RecordKeys` currently wraps AES-128-GCM. It generalizes to hold the negotiated
AEAD: it stores the traffic secret, derives key+iv of the suite key_len via
HKDF-Expand-Label (hash-aware), and seal/open dispatch on `suite.aead`:
- aes128_gcm / aes256_gcm -> gcm.seal/open over an AES block of the right key size
- chacha20_poly1305 -> chacha20poly1305.seal/open
Nonce construction (iv XOR seq, 12 bytes) is identical across all three AEADs.

### New primitive: ChaCha20-Poly1305 (chacha20poly1305.sig, RFC 8439)
- ChaCha20 block function (20 rounds, 32-byte key, 12-byte nonce, 32-bit counter).
- Poly1305 one-time MAC (clamp r, accumulate mod 2^130-5).
- AEAD seal/open: keystream from counter 1, Poly1305 key from counter 0 block;
  MAC over AAD || pad || ciphertext || pad || len(AAD) || len(CT) (little-endian).
- Verified against the RFC 8439 Section 2.8.2 worked example + Poly1305 vectors.

### P-256 ECDH (p256.sig extension)
p256.sig already has the field + point arithmetic for ECDSA verify. Add:
- `ecdhKeypair(scalar) -> pub[65]` (uncompressed SEC1: 0x04 || X || Y) via scalar
  multiply of the base point.
- `ecdhShared(scalar, peer_pub[65]) -> secret[32]` (the X coordinate of
  scalar * peer_point), rejecting the point at infinity / invalid points.
Verified against RFC 5903 P-256 ECDH test vectors.

### AES-256 (aes.sig extension)
Add the AES-256 key expansion (14 rounds, 8-word key) alongside AES-128. GCM
(`gcm.sig`) already operates over an opaque block-cipher, so it works unchanged
with a 256-bit expanded key. Verified against FIPS-197 / NIST AES-256 vectors.

### Handshake flow changes (tls.sig)
1. ClientHello: offer all suites; send X25519 key_share always + P-256 key_share;
   advertise supported_groups {X25519, secp256r1}; add ALPN {http/1.1}.
2. ServerHello: select Suite from the chosen cipher id; detect HRR (special
   random); read the server key_share group + value.
3. HRR: if present, synthesize the message_hash transcript substitution, resend
   CH2 with a key_share for the requested group, then proceed. One HRR max.
4. Derive secrets via the hash-matched schedule; records via the suite AEAD.
5. EncryptedExtensions: parse ALPN selection -> store on Conn.

## Data Models

### Conn (extended)
```sig
pub const Conn = struct {
    transport: Transport,
    client_app: RecordKeys, // now AEAD-tagged
    server_app: RecordKeys,
    server_app_secret: [48]u8, // sized for the larger hash; len tracked
    alpn: [32]u8 = @splat(0),  // negotiated ALPN protocol (empty if none)
    alpn_len: u8 = 0,
    // ... existing fields unchanged ...
    pub fn negotiatedAlpn(self: *const Conn) []const u8;
};
```
Secret buffers widen to 48 bytes with a tracked length so SHA-256 (32) and
SHA-384 (48) share storage without allocation.

## Error Handling

Reuses the existing `tls.Error` set. Mapping:
- Unknown/unsupported suite or group selection -> `UnsupportedParams`.
- AEAD authentication failure (any of the three) -> `DecryptFailed`.
- Transcript / Finished-MAC mismatch -> `HandshakeFailed`.
- A second HRR, or server selecting an unoffered group -> `HandshakeFailed`.
- Certificate chain / hostname / validity failure -> `CertInvalid` (unchanged).
The HTTP client maps `CertInvalid` -> TlsFailKind.cert_invalid as it already does.

## Testing Strategy

### Hermetic (test vectors)
- **ChaCha20-Poly1305**: RFC 8439 Section 2.4.2 (ChaCha20 keystream), Section 2.5.2
  (Poly1305), Section 2.8.2 (AEAD) worked examples; a tamper test -> auth fail.
- **AES-256-GCM**: NIST GCM test vectors (256-bit key).
- **P-256 ECDH**: RFC 5903 Section 8.1 shared-secret vector.
- **SHA-384 key schedule**: an RFC 8448-derived or self-consistent vector; at
  minimum, cross-check HKDF-Expand-Label SHA-384 against a known output.
- **Suite selection**: given a synthetic ServerHello, the correct Suite is
  chosen; an unknown id -> UnsupportedParams.

### Live (flagged, real network)
- Extend/clone the `live-tls` harness to connect to servers that force each
  capability and assert a validated chain + decrypted response:
  - a host selecting AES-256-GCM-SHA384,
  - a host preferring ChaCha20-Poly1305,
  - a host that forces P-256 and/or sends an HRR,
  - example.com / www.google.com now succeed via `live-http`.
- The existing `live-tls`, `live-wss`, `live-http` steps MUST stay green.

### Regression protection
- The SHA-256 + X25519 + AES-128-GCM path is exercised by the existing
  `test-tls-client` unit tests and the binance live steps; these are the gate
  that the refactor preserved behavior.

## Risks and Mitigations
- **Transcript hash desync** is the top risk: feeding the wrong hash or at the
  wrong point silently breaks decryption. Mitigation: buffer pre-ServerHello
  messages, finalize the chosen hash once; add an intermediate assertion test
  that the SHA-256 path still derives the identical known keys.
- **ChaCha20/Poly1305 correctness** is security-critical: mitigate with the full
  RFC 8439 vector set before wiring into the suite.
- **Scope creep**: TLS 1.2 fallback, resumption/0-RTT, and client certs are
  explicitly OUT of scope for this feature.

## Correctness Properties

### Property 1: AEAD round-trip and tamper rejection
For any key/nonce/aad/plaintext, open(seal(x)) == x for all three AEADs; a
single flipped ciphertext or tag bit makes open fail. **Validates: Requirements 1.4, 2.4, 7.3**

### Property 2: P-256 ECDH agreement
ecdhShared(a, pub(b)) == ecdhShared(b, pub(a)), matching the RFC 5903 fixed
vector. **Validates: Requirements 3.1**

### Property 3: Hash binding
The transcript hash length always equals the negotiated suite hash_len, and the
Finished MAC uses the same hash as the key schedule. **Validates: Requirements 1.3, 6.2**

### Property 4: Negotiation soundness
The Suite driven for record protection is exactly the one the server selected in
ServerHello; no path uses a hardcoded suite after selection. **Validates: Requirements 6.2, 6.3**

### Property 5: Regression invariant
For the X25519 + AES-128-GCM-SHA256 path, derived handshake/application keys are
identical before and after the refactor. **Validates: Requirements 1.5, 6.4**

### Property 6: No-alloc invariant
No handshake or record path references an allocator. **Validates: Requirements 7.2**

