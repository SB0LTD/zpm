# Implementation Plan — `@zpm/http` Pure-Sig HTTP Client

Build bottom-up and test offline at each step over a buffer-backed transport
before touching the network or migrating callers. Every task cites the
requirements it satisfies. Keep each step allocation-free and compiling green.

- [x] 1. Scaffold the module and build wiring
  - Create `src/net/http/` with `client.sig` (root re-exports) and empty sibling
    files; register `zpm_http` in `build.sig` via `addModule` + `wire(tls_client)`
    mirroring the `wss` block.
  - Add placeholder test steps (`test-http-parse`, etc.) so the harness picks them
    up; confirm `sig build --build-file build.sig --summary all` stays green.
  - _Requirements: 14.1, 14.2, 14.3_

- [x] 2. Error, Trace, and core enums (`errors.sig`)
  - Define `Error`, `TlsFailKind`, `Trace`, `Method`, `Scheme`.
  - _Requirements: 7.1, 7.2, 7.4, 16.1_

- [x] 3. URL parser (`url.sig`) + tests
  - `Url.parse(raw, host_buf)`: scheme/host/port/path_query, default ports,
    bracketed IPv6 syntactic support, default path `/`, reject malformed.
  - Unit tests for: https/http defaults, explicit port, query preserved, missing
    scheme, empty host, over-long host, IPv6 brackets, path-less URL.
  - _Requirements: 11.1, 11.2, 11.3, 11.4; 15.1_

- [x] 4. Transport seam (`transport.sig`) + buffer-backed `TestTransport`
  - `connTransport(*tlsc.Conn)` adapter (mirror `wss.connTransport`) and
    `PlainTransport` over a `tlsc.Socket` for port-80; both expose the HTTP
    engine's read-some / write-all seam.
  - `TestTransport`: scripted-read (incl. split-across-reads) + write-capture, for
    all offline tests.
  - _Requirements: 1.2, 2.2; 15.1_

- [x] 5. Request serialization (`request.sig`) + header-injection guard + tests
  - `Request` struct + `Buffers` struct; serialize request line, `Host`
    (host:port when non-default), `User-Agent`, `Accept-Encoding: identity`,
    `Connection` (close for one-shot / keep-alive for Client), verbatim extra
    headers, cookie header, auto `Content-Length`/`Content-Type`, body.
  - Reject CR/LF/NUL in caller header name/value → `InvalidHeader`.
  - Tests: method/path/host:port lines, body framing & auto headers, caller
    Content-Type/Content-Length respected, injection rejected, bodyless has no
    Content-Type.
  - _Requirements: 3.1–3.7; 2.1, 2.2; 15.1_

- [x] 6. Response parser (`response.sig`) + `HeaderSet` + tests
  - Resumable state machine: status line (code + reason), headers into
    `HeaderSet` (cap 48, case-insensitive `get`), extract Content-Length /
    Transfer-Encoding / Connection / Location / Retry-After / Set-Cookie.
  - Incremental feeding across multiple reads; malformed → `BadResponse`; headers
    over scratch → `BufferTooSmall`.
  - Tests: well-formed parse, header lookup case-insensitivity, split-across-reads,
    malformed status/headers.
  - _Requirements: 4.1, 4.2, 4.7, 4.8; 2.3; 15.1_

- [x] 7. Body decoding (`body.sig`) + tests
  - Content-Length exact read into `bufs.body`; chunked decode (hex size, skip
    `;ext`, CRLFs, `0\r\n` end, read+discard trailers); EOF-delimited on
    `Connection: close`; no-body for HEAD/204/304/1xx; `BodyTooLarge` on overflow
    with partial length (no overrun).
  - Tests: Content-Length, chunked (single, split, extensions, trailers), HEAD/204/
    304, EOF-delimited, overflow signalled.
  - _Requirements: 4.3, 4.4, 4.5, 4.6; 2.3; 15.1_

- [x] 8. CookieJar (`cookie.sig`) — migrate + tests
  - Lift `http_session.CookieJar`/`Cookie` verbatim (semantics-preserving);
    add `absorbFromHeaders(&HeaderSet)` driving the existing `set`.
  - Tests: set/get/replace, serialize ("a=1; b=2"), absorb multiple Set-Cookie,
    long `__Secure-*` value, overflow bounded.
  - _Requirements: 8.1, 8.2, 8.3; 2.1; 15.1_

- [x] 9. Socket extensions (`socket_ext.sig`) + win32 additions
  - Add to `win32.sig`: `SO_RCVTIMEO`/`SO_SNDTIMEO`, `select` + `timeval`/`fd_set`.
  - `setRecvTimeout`/`setSendTimeout` via setsockopt; `connectDeadline` (FIONBIO +
    select deadline) → connected `tlsc.Socket` or `Timeout`/`ConnectFailed`;
    `lastError()` → WSAGetLastError.
  - _Requirements: 5.1, 5.2, 5.3, 7.3; 1.3_

- [x] 10. Protocol seam + HTTP/1.1 impl (`protocol.sig`)
  - `Protocol` vtable; `Http1` wiring request.sig send + response/body read over a
    `Transport`. Keep the request/response model version-agnostic.
  - _Requirements: 16.1, 16.2; 3.*, 4.*_

- [x] 11. One-shot `fetch` (`client.sig`) over the real stack
  - Compose connectDeadline → (https: `tlsc.handshake` cert-verified; http:
    PlainTransport) → set timeouts → `Http1.send` → `Http1.read` → absorb cookies;
    fill `Trace`; typed `Error` + `TlsFailKind` on every failure path.
  - Seed entropy (`tlsc.fillEntropy`) once before first handshake.
  - _Requirements: 1.1, 1.2, 5.*, 7.*, 12.1, 12.3, 12.4; 2.1_

- [x] 12. Redirect following
  - 301/302/303/307/308 up to `max_redirects`; method/body rules (303/301/302 →
    GET+drop; 307/308 preserve); carry jar; reconnect on host/scheme change; refuse
    https→http unless opted in; `TooManyRedirects` on overflow.
  - Tests (TestTransport scripting a redirect chain + a loop).
  - _Requirements: 9.1–9.5; 15.1_

- [x] 13. Retry policy (`retry.sig`) + wrapper
  - `RetryPolicy` (max, base backoff, opt-in 408/429/5xx, `retry_non_idempotent`);
    retriable classification; exponential backoff; `Retry-After` honoring; bounded
    by `total_ms`; `attempts` recorded; `RetryExhausted`.
  - Tests: retries on transient, no-retry POST by default, Retry-After honored,
    total-deadline stop.
  - _Requirements: 6.1–6.6, 5.4; 15.1_

- [x] 14. Keep-alive `Client` (pinned)
  - Connection-holding `Client` (pinned-owner doc); reuse conn for same
    host:port:scheme when prior body fully consumed & keep-alive; reconnect on
    `Connection: close`/EOF; `shutdownSocket` cross-thread unblock (wss parity).
  - Tests: two sequential requests reuse one conn; forced-close reconnect.
  - _Requirements: 10.1–10.4; 2.5_

- [x] 15. No-allocator assertion test (`no_alloc_test.sig`)
  - Model on `src/transport/no_alloc_test.sig`; assert `fetch`/`Client.send` take
    and reference no allocator; verify `MAX_*` constants exist.
  - _Requirements: 2.1, 2.4; 15.2_

- [x] 16. Live integration test (flagged `live-http-get`)
  - Real HTTPS GET to a stable endpoint; assert 2xx + non-empty body + cert
    validated; parallel to `live-tls-handshake`.
  - _Requirements: 12.1, 15.3_

- [ ] 17. Migrate zpm's own callers to `@zpm/http`, then DELETE the WinHTTP modules
  - Rewrite `youtube/session.sig` (`generateITInSession`,
    `fetchChallengeInSession`, `establishIntegrityToken`) to call `@zpm/http`
    directly (import `CookieJar`/`Response`/`CHROME_UA` from `@zpm/http`).
  - Rewrite `botguard/challenge.sig` `waaPost`/`Create`/`fetchScript` to
    `@zpm/http` (`fetch` + a shared `Client` for Create→GenerateIT), gaining
    retries/timeouts/typed errors over the opaque `return 0`.
  - DELETE `src/platform/http_session.sig` and `src/platform/http.sig`.
  - Verify no non-test zpm code imports `winhttp`/`wininet`.
  - _Requirements: 13.1, 13.2, 13.3, 13.6_

- [ ] 18. Migrate the sibling-repo callers directly (no shims); land zpm first
  - zpm change (new client + deletions) merged to `main` FIRST — it is the
    dependency.
  - **gotliv** (`master`): repoint the session/create/dl harnesses off
    `zpm/platform/http_session` to `@zpm/http`; replace `ai_edit.sig`'s hand-rolled
    WinHTTP LLM call with `@zpm/http` (or `@zpm/openrouter`).
  - **sb0/sbtrade** (`master`): migrate REST callers (`funding.sig` + the
    `platform/http` registration in `build.sig`) to `@zpm/http.Client`; drop the
    `winhttp` link; update the few UTF-16 `L"..."` paths to the ASCII API.
  - **sb0/nexus** (`main`) + **sb0/galaxy** (`galaxy`): these mostly carry a
    VENDORED zpm snapshot + package-registry metadata — re-sync the vendored
    snapshot and update registry metadata rather than hand-editing copies; migrate
    any genuine first-party caller.
  - **sb0/sbcode**, **sb0/stools**: audit; migrate only if a real caller exists.
  - Per repo: clean tree → sync mainline → feature branch → build green → PR →
    merge → push. Stop on any conflict or red build (never force).
  - _Requirements: 13.3, 13.4, 13.5_

- [ ] 19. Verify end to end (repo-wide, no WinHTTP left)
  - zpm: `sig build --build-file build.sig --summary all` green incl. new tests.
  - gotliv path-dependency build green; `create-test --pinned` reaches the
    `[5/5] Minting` block with the HTTP call no longer the flaky blocker; `dl-test`
    and `session-test` build/run.
  - sbtrade / nexus / galaxy / sbcode / stools build green on mainline.
  - Repo-wide search: zero non-test `winhttp`/`wininet` imports for HTTP.
  - _Requirements: 13.5, 13.6, 15.4, 14.3_

- [ ] 20. (Optional, post-GA) HTTP/2 backend groundwork
  - Expose negotiated ALPN from `tls_client`; advertise `h2`; add an `Http2`
    `Protocol` impl (HPACK + frames) selectable on ALPN — additive, no caller
    changes.
  - _Requirements: 16.2, 16.3, 16.4_
