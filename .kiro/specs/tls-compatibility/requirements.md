# Requirements Document

## Introduction

The pure-Sig TLS 1.3 client in `src/core/crypto/tls/` currently negotiates a
single cipher suite (`TLS_AES_128_GCM_SHA256`) over a single key-exchange group
(`X25519`), with no ALPN and no HelloRetryRequest handling. This is sufficient
for the exchange market-data endpoints it was built for, but real-world servers
(Google, Cloudflare, Fastly/example.com) frequently require a broader set: they
may select AES-256-GCM-SHA384 or ChaCha20-Poly1305, prefer the secp256r1 (P-256)
group, send a HelloRetryRequest, or require ALPN. Against such servers the
handshake fails at the protocol level today.

This feature expands the TLS client to interoperate with the cipher suites,
key-exchange groups, and handshake features common on the public web, WITHOUT
regressing the proven X25519 + AES-128-GCM path that `wss` market-data and the
YouTube flows depend on, and WITHOUT weakening certificate-chain validation.

This is a `tls_client` (Layer 1 crypto) enhancement. It benefits every TLS
consumer in the repo (wss, @zpm/http, YouTube) additively; no caller API change.

### Current state (baseline to preserve)
- Cipher: `TLS_AES_128_GCM_SHA256` (0x1301) only
- Group: `X25519` (0x001d) only
- SNI: sent; ALPN: not sent; HelloRetryRequest: not handled
- Transcript + key schedule hardcoded to SHA-256 (32-byte secrets)
- Cert-chain validation against the embedded CA bundle: MUST remain intact

## Requirements

### Requirement 1: AES-256-GCM-SHA384 cipher suite
**User Story:** As a caller connecting to a server that selects
`TLS_AES_256_GCM_SHA384`, I want the handshake to complete so the request works.

#### Acceptance Criteria
1. The ClientHello SHALL advertise `TLS_AES_256_GCM_SHA384` (0x1302) in addition
   to `TLS_AES_128_GCM_SHA256`.
2. WHEN the server selects 0x1302 THEN the client SHALL drive the handshake with
   a SHA-384 transcript and HKDF-SHA384 key schedule and AES-256-GCM record
   protection, and SHALL complete the handshake and decrypt application data.
3. The transcript hash, key-schedule secrets, and Finished MAC SHALL use the
   hash bound to the negotiated suite (SHA-256 for 0x1301, SHA-384 for 0x1302).
4. AES-256-GCM SHALL be driven by a 32-byte key / 12-byte nonce derived through
   the SHA-384 key schedule, verified against a known TLS 1.3 test vector.
5. The existing 0x1301 (AES-128-GCM-SHA256) path SHALL remain byte-for-byte
   unchanged in behavior (regression-protected by the existing live-tls test).

### Requirement 2: ChaCha20-Poly1305 cipher suite
**User Story:** As a caller connecting to a server that prefers
`TLS_CHACHA20_POLY1305_SHA256` (common on mobile-optimized CDNs), I want the
handshake to complete.

#### Acceptance Criteria
1. A pure-Sig ChaCha20-Poly1305 AEAD (RFC 8439) SHALL be implemented as a new
   Layer-0 crypto module, verified against the RFC 8439 test vectors (ChaCha20
   block function, Poly1305 MAC, and the AEAD construction).
2. The ClientHello SHALL advertise `TLS_CHACHA20_POLY1305_SHA256` (0x1303).
3. WHEN the server selects 0x1303 THEN the client SHALL use ChaCha20-Poly1305
   record protection with a SHA-256 transcript/key schedule and complete the
   handshake and decrypt application data.
4. The AEAD SHALL enforce the 16-byte Poly1305 tag and reject a tampered record
   (authentication failure -> DecryptFailed).

### Requirement 3: secp256r1 (P-256) key-exchange group
**User Story:** As a caller connecting to a server that only offers the P-256
group for key exchange, I want ECDHE to succeed.

#### Acceptance Criteria
1. P-256 ECDH (scalar * base point, and scalar * peer point) SHALL be available
   over the existing P-256 field arithmetic, verified against an ECDH test
   vector (e.g. RFC 5903 / NIST).
2. The ClientHello SHALL advertise `secp256r1` (0x0017) in supported_groups and
   SHALL be able to send a P-256 key_share.
3. WHEN the server selects P-256 THEN the client SHALL compute the ECDHE shared
   secret from the server key_share and complete the handshake.
4. X25519 SHALL remain the preferred group (advertised first) so no regression
   occurs for servers that accept it.

### Requirement 4: HelloRetryRequest (HRR)
**User Story:** As a caller, I want the handshake to recover when the server
asks for a different key-exchange group than the one I offered a share for.

#### Acceptance Criteria
1. WHEN the server responds with a HelloRetryRequest (ServerHello with the
   special random + a key_share group selection) THEN the client SHALL resend a
   second ClientHello with a key_share for the requested group.
2. The transcript SHALL be reconstructed per RFC 8446 (the synthetic
   message_hash of ClientHello1 replaces ClientHello1 in the transcript).
3. The client SHALL send at most one HRR response; a second HRR or a server
   selecting an unoffered group SHALL fail with a typed error, not loop.
4. A normal (non-HRR) handshake SHALL be unaffected.

### Requirement 5: ALPN negotiation
**User Story:** As a caller connecting to a server that requires ALPN (or to
enable the future HTTP/2 switch), I want to advertise and read the negotiated
application protocol.

#### Acceptance Criteria
1. The ClientHello SHALL send an ALPN extension advertising `http/1.1`.
2. WHEN the server returns a selected ALPN protocol in EncryptedExtensions THEN
   the client SHALL parse and expose it on the established `Conn` (accessor).
3. The advertised ALPN list SHALL be extensible (adding `h2` later is additive).
4. A server that does not send ALPN SHALL NOT cause a handshake failure; the
   exposed negotiated protocol is simply empty.

### Requirement 6: Negotiation agility and preservation
**User Story:** As a maintainer, I want the client to offer everything and let
the server choose, without breaking the paths that already work.

#### Acceptance Criteria
1. The ClientHello SHALL offer all supported suites (0x1301, 0x1302, 0x1303) and
   both groups (X25519 preferred, then P-256), with key_shares the server can
   use without an HRR in the common case (X25519 share always included).
2. The client SHALL select the negotiated cipher/hash/AEAD/group from the
   ServerHello, not from a hardcoded assumption.
3. An unknown/unsupported server selection SHALL fail with `UnsupportedParams`,
   never a silent mis-decrypt.
4. All existing TLS consumers (`wss`, `@zpm/http`, YouTube) SHALL continue to
   build and pass their tests with no API change.

### Requirement 7: Security and correctness preservation
**User Story:** As a security reviewer, I want the expansion to add algorithms
without weakening the trust model.

#### Acceptance Criteria
1. Certificate-chain validation against the embedded CA bundle, hostname/SNI
   matching, and validity-time checks SHALL remain fully enforced on every path.
2. The implementation SHALL remain allocation-free (no allocator in any path),
   consistent with the rest of the TLS stack.
3. AEAD authentication failures and transcript/Finished-MAC mismatches SHALL
   surface as typed errors (`DecryptFailed` / `HandshakeFailed`), never ignored.
4. Entropy for all ephemeral keys (X25519 and P-256 scalars, ClientHello.random)
   SHALL come from the OS CSPRNG via the existing `fillEntropy` seam.

### Requirement 8: Verification against real servers
**User Story:** As a maintainer, I want proof the expansion works against the
servers that fail today.

#### Acceptance Criteria
1. Each new primitive (AES-256-GCM, ChaCha20-Poly1305, SHA-384 schedule, P-256
   ECDH) SHALL have hermetic unit tests over published test vectors.
2. A live handshake test SHALL successfully complete against at least one server
   that requires each new capability (e.g. a host that selects AES-256-GCM-
   SHA384, one that prefers ChaCha20, one that forces P-256 / HRR), asserting a
   validated certificate chain and a decrypted 2xx response.
3. The existing `live-tls` and `live-wss` and `live-http` steps SHALL still pass
   (no regression on the X25519 + AES-128 path).

## Glossary

- **AEAD**: Authenticated Encryption with Associated Data (AES-GCM, ChaCha20-Poly1305).
- **ALPN**: Application-Layer Protocol Negotiation (TLS extension selecting e.g. http/1.1).
- **ECDHE**: Ephemeral Elliptic-Curve Diffie-Hellman key exchange.
- **HRR**: HelloRetryRequest, a ServerHello variant asking the client to retry with a different group.
- **Key schedule**: The HKDF-based derivation of handshake and application traffic secrets (RFC 8446 Section 7).
- **Transcript hash**: Running hash of all handshake messages, bound to the negotiated cipher suite hash.
- **SNI**: Server Name Indication (TLS extension carrying the target hostname).

