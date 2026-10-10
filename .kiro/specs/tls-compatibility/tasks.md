# Implementation Plan — TLS 1.3 Cipher/Group Compatibility

Build primitives bottom-up with RFC test vectors FIRST, then introduce the
Suite seam without changing wire behavior, then add each cipher/group/feature
and validate live. Keep the X25519 + AES-128-GCM-SHA256 path green at every step
(the binance live-tls/live-wss steps are the regression gate).

## Overview

Twelve tasks, bottom-up: four new/extended Layer-0 primitives (each gated by RFC
test vectors), then the Suite seam refactor (behavior-preserving), then wiring
each cipher/group/feature, then live validation and repo-wide verification.

## Task Dependency Graph

```
1 (AES-256) ----+
2 (ChaCha20) ---+
3 (P-256 ECDH) -+--> 5 (Suite seam) --> 6 (AES256 suite)  --> 11 (live) --> 12 (verify)
4 (SHA384 ks) --+                   --> 7 (ChaCha suite)
                                    --> 8 (P-256 share) --> 9 (HRR)
                                    --> 10 (ALPN)
```

```json
{
  "waves": [
    { "wave": 1, "tasks": ["1", "2", "3", "4"] },
    { "wave": 2, "tasks": ["5"] },
    { "wave": 3, "tasks": ["6", "7", "8", "10"] },
    { "wave": 4, "tasks": ["9"] },
    { "wave": 5, "tasks": ["11"] },
    { "wave": 6, "tasks": ["12"] }
  ]
}
```

Tasks 1-4 are independent and can be done in any order. Task 5 depends on 1-4
being available. Tasks 6-10 depend on 5. Task 11 depends on 6-10; task 12 last.

## Tasks

- [x] 1. AES-256 key expansion (`aes.sig`) + vectors
  - Add AES-256 (14-round, 8-word) key schedule alongside AES-128; keep AES-128
    byte-identical. Verify encrypt/decrypt against FIPS-197/NIST AES-256 vectors.
  - _Requirements: 1.4, 6.4_

- [x] 2. ChaCha20-Poly1305 AEAD (`chacha20poly1305.sig`, NEW) + RFC 8439 vectors
  - ChaCha20 block/keystream, Poly1305 one-time MAC, and the AEAD seal/open.
  - Tests: RFC 8439 Section 2.4.2 keystream, Section 2.5.2 Poly1305, Section 2.8.2 AEAD;
    tamper -> auth fail. Register `test-chacha20poly1305` in build.sig.
  - _Requirements: 2.1, 2.4, 7.3_

- [x] 3. P-256 ECDH (`p256.sig` extension) + RFC 5903 vector
  - `ecdhKeypair(scalar)->pub[65]` and `ecdhShared(scalar, peer[65])->secret[32]`
    over the existing field/point math; reject invalid/infinity points.
  - Test: RFC 5903 Section 8.1 shared-secret vector; agreement property.
  - _Requirements: 3.1_

- [x] 4. SHA-384 key schedule (`tls/keysched384.sig`) + HKDF-SHA384
  - HKDF-Expand-Label / Derive-Secret over SHA-384 (48-byte secrets); same
    operations as tls13_keys (handshake/application secrets, Finished).
  - Wire SHA-384 (tls/sha512.sig) + an HMAC-SHA384. Test against a known HKDF-
    SHA384 Expand-Label output.
  - _Requirements: 1.3_

- [x] 5. Suite seam + hash-aware transcript (`tls.sig` refactor, no behavior change)
  - Introduce the `Suite` table and `HashId`/`Aead` enums; make the transcript
    hash-length-aware (buffer pre-ServerHello messages, finalize chosen hash).
  - Generalize `RecordKeys` to carry the AEAD + key_len; dispatch seal/open.
  - CRITICAL: with only 0x1301 offered/selected, the derived keys and wire bytes
    MUST be identical to today. Add an assertion test pinning the known AES-128
    path keys. Keep `test-tls-client` + live-tls green.
  - _Requirements: 6.2, 6.3, 1.5, 6.4, 7.2_

- [x] 6. Wire AES-256-GCM-SHA384 suite (0x1302)
  - Advertise 0x1302; on selection drive the SHA-384 schedule + AES-256-GCM.
  - Hermetic: synthetic ServerHello(0x1302) selects the right Suite; a known
    TLS 1.3 AES-256 record test vector decrypts.
  - _Requirements: 1.1, 1.2, 1.3, 1.4_

- [x] 7. Wire ChaCha20-Poly1305 suite (0x1303)
  - Advertise 0x1303; on selection use ChaCha20-Poly1305 records with the
    SHA-256 schedule.
  - Hermetic: synthetic ServerHello(0x1303) selects the suite; AEAD round-trips.
  - _Requirements: 2.1, 2.2, 2.3_

- [x] 8. Advertise + handle P-256 key_share (0x0017)
  - supported_groups {X25519, secp256r1}; send both key_shares (X25519 first).
  - On server P-256 selection, compute ECDHE via p256.ecdhShared.
  - _Requirements: 3.2, 3.3, 3.4, 6.1_

- [x] 9. HelloRetryRequest handling
  - Detect HRR (special random); synthesize the message_hash transcript
    substitution; resend CH2 with the requested group's key_share; one HRR max;
    unoffered group / second HRR -> typed error.
  - Hermetic: scripted HRR exchange over a buffer transport drives CH2.
  - _Requirements: 4.1, 4.2, 4.3, 4.4_

- [x] 10. ALPN advertise + parse
  - Send ALPN {http/1.1}; parse the server selection from EncryptedExtensions;
    expose `Conn.negotiatedAlpn()`; absent ALPN is not an error.
  - _Requirements: 5.1, 5.2, 5.3, 5.4_

- [x] 11. Live validation against real servers (flagged)
  - Add live steps hitting servers that force each capability (AES-256-GCM,
    ChaCha20, P-256/HRR); assert validated chain + decrypted 2xx. Confirm
    example.com / www.google.com now succeed via live-http.
  - Regression: live-tls, live-wss, live-http (binance) still pass.
  - _Requirements: 8.1, 8.2, 8.3_

- [x] 12. Repo-wide verification
  - `sig build --summary all` green incl. all new primitive test steps.
  - wss / YouTube consumers build and pass unchanged (no API change).
  - _Requirements: 6.4, 7.1, 8.3_

## Notes

- Each primitive task MUST pass its RFC vectors before being wired into a suite.
- Task 5 is the riskiest (transcript/key-schedule generalization); it must keep
  the 0x1301 path byte-identical, pinned by an assertion test.
- Live tests are flagged (not in the `test` aggregate), like live-tls/live-wss.
- OUT of scope: TLS 1.2 fallback, resumption/0-RTT, client certificates.
