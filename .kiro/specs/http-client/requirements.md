# Requirements — `@zpm/http` Pure-Sig HTTP Client

## Introduction

zpm has two HTTP code paths today and both are WinHTTP FFI wrappers, which
contradicts the toolchain policy ("Everything is Sig/ZPM native. No fallback to
system HTTP where we own a pure-Sig path"):

- `src/platform/http.sig` — one-shot WinHTTP GET helpers (SB0 Trade REST).
- `src/platform/http_session.sig` — WinHTTP request with a Sig cookie jar
  (YouTube/BotGuard session flow).

Meanwhile a complete **pure-Sig TLS 1.3 stack already exists** and is proven in
production by the market-data WebSocket client:

```
net/wss.sig  →  tls_client.Conn (TLS 1.3 records)  →  tls_client.Socket (Winsock TCP + getaddrinfo DNS)
                src/core/crypto/tls/{client,tls,winsock,x509,x509_verify,ca_bundle,rsa,asn1,sha512}.sig
                src/core/crypto/{sha256,hkdf,gcm,aes,p256,x25519,tls13_keys}.sig
```

There is **no pure-Sig HTTP-over-TLS client**. The bare-metal `net/http.sig` is
HTTP/1.1 over the kernel TCP/IP stack (needs a `NetInterface` NIC), has no TLS,
and caps bodies at 4 KiB — not usable for hosted app HTTPS.

This feature delivers `@zpm/http`: a comprehensive, allocation-free, pure-Sig
HTTP/1.1 (and forward-looking HTTP/2) client that composes on the existing
`tls_client` stack exactly as `wss.sig` does — the single HTTP path the whole
codebase uses, replacing both WinHTTP wrappers. It fixes the robustness problems
that currently force callers to retry blindly (no retries, no timeouts, opaque
failures, fresh connection per call, partial-read truncation) and the policy
inconsistency (two system-HTTP paths where we own a pure-Sig transport).

### Non-goals (this iteration)
- A server. (The QUIC/H3 server already lives in `src/transport/`.)
- Full HTTP/2 at GA — the design keeps a version-agnostic request/response core
  so H2 can be added later, but H1.1 is the shipping protocol.
- Non-Windows sockets at GA. The socket seam is abstracted (`tls.Transport`), and
  a POSIX `connectHost` can be added without touching the HTTP layer, but Windows
  (Winsock) is the GA target, matching the rest of zpm's platform layer.
- Replacing the bare-metal `net/` kernel stack. That stack stays for GVE/kernel
  use; `@zpm/http` is the hosted-app client.

## Glossary
- **Pinned owner** — a struct the caller allocates in place and never moves after
  `connect`, because inner layers hold pointers into it (the `wss.WssClient`
  pattern). Moving it dangles those pointers.
- **tls.Transport** — the `{ ctx, readFn, writeFn }` byte-stream vtable the TLS
  layer and plaintext layer both satisfy; the HTTP engine reads/writes through it.
- **Caller-provided buffer** — all response/scratch storage is a slice the caller
  owns; the client allocates nothing.

---

## Requirements

### Requirement 1 — Pure-Sig transport, no system HTTP
**User Story:** As a zpm maintainer, I want all app HTTP to run on our own Sig
transport so the toolchain policy holds and we control retries, timeouts, TLS,
and diagnostics end to end.

#### Acceptance Criteria
1. WHEN the client performs an HTTPS request THEN it SHALL use the pure-Sig
   `tls_client` stack (TLS 1.3 over Winsock TCP), NOT WinHTTP, WinINet, or any
   `winhttp.dll` / `wininet.dll` import.
2. WHEN the client performs a plaintext HTTP request (port 80 / `http://`) THEN it
   SHALL use a raw Winsock TCP transport that satisfies the same `tls.Transport`
   seam, so the HTTP engine is identical for both schemes.
3. The module SHALL NOT import `winhttp`, `wininet`, or any system HTTP API; its
   only platform surface SHALL be Winsock (`ws2_32`) via the existing
   `tls_client.winsock` / `win32` bindings and `BCryptGenRandom` for entropy.
4. The module SHALL compile and link into the existing `sig build --build-file
   build.sig` with no new system-library dependency beyond those `tls_client`
   already pulls in.

### Requirement 2 — Allocation-free, bounded, caller-owned buffers
**User Story:** As a maintainer, I want zero heap use so the client fits zpm's
"no allocators, every byte accounted for" rule and is safe in freestanding and
pinned-thread contexts.

#### Acceptance Criteria
1. The client SHALL NOT call any allocator (`std.mem.Allocator`, `malloc`, GPA,
   arena, etc.) in any code path.
2. All response bodies, headers, and handshake scratch SHALL be written into
   slices the CALLER provides via the request/options struct; the client SHALL
   NOT own a hidden growable buffer.
3. WHEN a response body exceeds the caller's buffer THEN the client SHALL report a
   `BodyTooLarge` outcome with the bytes received so far and SHALL NOT overflow or
   silently truncate without signalling.
4. Every internal fixed buffer SHALL have a named `MAX_*` constant, and the module
   SHALL pass a `comptime`-style no-allocator assertion test modeled on
   `src/transport/no_alloc_test.sig`.
5. The owning client struct SHALL be pinnable (fixed size, no self-moves after
   `connect`) following the `wss.WssClient` convention, and this SHALL be
   documented at the type.

### Requirement 3 — Full HTTP/1.1 request construction
**User Story:** As a caller, I want to issue any standard request so I can talk to
YouTube/WAA, REST APIs, and arbitrary hosts.

#### Acceptance Criteria
1. The client SHALL support methods GET, POST, PUT, DELETE, HEAD, PATCH, and
   OPTIONS.
2. The client SHALL send a correct request line (`METHOD path HTTP/1.1`), a `Host`
   header derived from the target host (with non-default port appended as
   `host:port`), and a caller-supplied `User-Agent` (default: the existing
   `CHROME_UA` string).
3. WHEN the caller supplies a raw extra-header block (`"Name: v\r\nName2: v2\r\n"`)
   THEN the client SHALL emit those headers verbatim, and SHALL support at least
   `MAX_EXTRA_HEADERS` bytes (≥ 4096) to cover api keys, visitor ids, client
   hints, Origin/Referer.
4. WHEN a request has a body THEN the client SHALL set `Content-Length`
   automatically unless the caller already provided one, and SHALL send the body
   bytes after the header terminator.
5. The client SHALL support a caller-set `Content-Type`; absent one on a body
   request it SHALL default to `application/octet-stream` and SHALL NOT invent a
   `Content-Type` for bodyless requests.
6. The client SHALL correctly handle a request path that already contains a query
   string and SHALL NOT re-encode it.
7. Header construction SHALL be injection-safe: a header name or value containing
   CR or LF SHALL be rejected (`InvalidHeader`), never emitted raw.

### Requirement 4 — Robust HTTP/1.1 response parsing
**User Story:** As a caller, I want responses parsed correctly and completely so I
never act on truncated data.

#### Acceptance Criteria
1. The parser SHALL parse the status line into a numeric status code and expose
   the reason phrase.
2. The parser SHALL parse response headers into a bounded, caller-inspectable set
   (at least `MAX_RESP_HEADERS` ≥ 32 entries) and provide case-insensitive lookup
   by name.
3. WHEN `Content-Length` is present THEN the client SHALL read exactly that many
   body bytes and SHALL treat the response as complete only when all are received.
4. WHEN `Transfer-Encoding: chunked` is present THEN the client SHALL decode the
   chunked body (hex sizes, CRLFs, trailing `0\r\n\r\n`), ignore chunk extensions,
   and read optional trailers, into the caller's body buffer.
5. WHEN neither `Content-Length` nor chunked is present AND the connection is
   `Connection: close` THEN the client SHALL treat EOF (clean TLS/socket close) as
   the body terminator.
6. The parser SHALL correctly handle a `HEAD` response (headers only, no body) and
   a `204`/`304` / `1xx` response (no body regardless of headers).
7. WHEN the status line or headers are malformed THEN the client SHALL return a
   `BadResponse` outcome rather than returning garbage or looping.
8. The parser SHALL tolerate the header block and body arriving across multiple
   socket reads (incremental feeding), buffering until a complete message is
   available or the buffer limit is hit.

### Requirement 5 — Timeouts and cancellation
**User Story:** As a caller, I want bounded operations so a stalled server can
never hang the thread (the current WinHTTP `waaPost` has no timeout control that
callers can see).

#### Acceptance Criteria
1. The request options SHALL expose connect, send, and receive timeouts in
   milliseconds with sane defaults (connect 15 000, send 20 000, receive 30 000).
2. WHEN a socket operation exceeds its timeout THEN the client SHALL abort the
   operation and return a `Timeout` outcome, releasing the socket.
3. Timeouts SHALL be enforced at the socket layer (Winsock `SO_RCVTIMEO` /
   `SO_SNDTIMEO` and a connect deadline), not by a busy-spin poll loop.
4. A total-deadline option SHALL bound the whole request (handshake + send +
   receive + any redirects/retries) so retries cannot extend latency unbounded.

### Requirement 6 — Retries with backoff
**User Story:** As the BotGuard/WAA caller, I want transient failures retried
automatically so I stop looping the whole program to get one successful
GenerateIT.

#### Acceptance Criteria
1. The request options SHALL expose a max-retries count (default 3) and a base
   backoff in milliseconds (default 250) with exponential growth.
2. The client SHALL retry only on transient failures: connect failure, TLS
   handshake failure, timeout, premature close before any status byte, and
   (optionally, caller-opt-in) HTTP 408/429/5xx.
3. The client SHALL NOT retry a non-idempotent request (POST/PATCH) by default
   unless the caller explicitly opts in (`retry_non_idempotent = true`), to avoid
   duplicate side effects.
4. WHEN retrying on HTTP 429/503 with a `Retry-After` header THEN the client
   SHALL honor that delay (capped by the total deadline) instead of the backoff.
5. Retries SHALL respect the total deadline from Requirement 5.4 and SHALL stop
   immediately once it is exceeded.
6. The result SHALL report how many attempts were made.

### Requirement 7 — Rich, diagnosable error reporting
**User Story:** As a debugger, I want to know *why* a request failed, not an
opaque "request failed" (the exact pain in `challenge.sig waaPost`).

#### Acceptance Criteria
1. Every failure SHALL carry a typed outcome from a single error enum covering at
   least: `DnsFailed`, `ConnectFailed`, `TlsFailed`, `Timeout`, `SendFailed`,
   `RecvFailed`, `PrematureClose`, `BadResponse`, `BodyTooLarge`, `TooManyRedirects`,
   `InvalidUrl`, `InvalidHeader`, `BufferTooSmall`.
2. WHEN a TLS handshake fails THEN the outcome SHALL distinguish cert-chain
   validation failure from a protocol/transport failure (propagating the
   `tls_client` error category).
3. WHEN a socket call fails THEN the result SHALL capture the Winsock
   `WSAGetLastError()` code for diagnostics.
4. The client SHALL provide an optional structured trace (timings per phase: DNS,
   connect, TLS, first-byte, complete; attempt count) that callers can log; it
   SHALL be off by default and allocation-free when on.
5. No failure path SHALL be a bare `return 0` / `return .{}` without an
   accompanying typed outcome.

### Requirement 8 — Cookie jar (migrated, not forked)
**User Story:** As the YouTube session caller, I want the same cookie-jar
semantics I have now, carried over the pure-Sig client.

#### Acceptance Criteria
1. The client SHALL support an optional `*CookieJar` on a request: serialize the
   jar into the `Cookie:` header and absorb `Set-Cookie:` response headers back
   into the jar.
2. The `CookieJar` type SHALL preserve the existing semantics of
   `http_session.CookieJar` (name/value store, `set`/`get`/`clear`/`count`/
   `serialize`/`absorbRawHeaders`, `MAX_COOKIES` ≥ 64, long `__Secure-*` values),
   so `youtube/session.sig` migrates with no behavioral change.
3. Cookie absorption SHALL parse `Set-Cookie` from the real parsed response
   headers (Requirement 4.2), not a separate raw-header re-query.

### Requirement 9 — Redirect following
**User Story:** As a caller, I want standard redirect handling so first-party
flows that bounce (consent, locale) work.

#### Acceptance Criteria
1. The client SHALL optionally follow 301/302/303/307/308 up to a caller-set
   `max_redirects` (default 5; 0 disables).
2. On 303 (and 301/302 for a non-GET per common practice, caller-configurable)
   THEN the client SHALL switch to GET and drop the body; on 307/308 it SHALL
   preserve method and body.
3. The client SHALL carry the cookie jar across redirects and SHALL re-resolve /
   reconnect when the redirect target host or scheme changes.
4. A redirect to a non-HTTPS target from an HTTPS origin SHALL be refused by
   default (opt-in to allow), consistent with zpm's existing WinHTTP redirect
   policy.
5. WHEN redirects exceed `max_redirects` THEN the client SHALL return
   `TooManyRedirects`.

### Requirement 10 — Connection reuse (keep-alive)
**User Story:** As a performance-sensitive caller (session flows do several
requests to the same host), I want to reuse one TLS connection.

#### Acceptance Criteria
1. The client SHALL support HTTP/1.1 keep-alive: when a response is `Connection:
   keep-alive` (default for 1.1) and fully delimited (Content-Length or chunked),
   the connection SHALL be reusable for a subsequent request to the same
   host:port:scheme.
2. A `Client` (pinned, connection-holding) type SHALL expose repeated requests
   over one connection; a one-shot `fetch` convenience SHALL open and close a
   connection per call.
3. WHEN the server sends `Connection: close` or closes the socket THEN the client
   SHALL transparently reconnect on the next request on the pinned `Client`.
4. Keep-alive reuse SHALL only occur when the prior body was fully consumed, so no
   stale bytes corrupt the next response.

### Requirement 11 — URL parsing
**User Story:** As a caller, I want to pass a URL and have scheme/host/port/path
parsed correctly.

#### Acceptance Criteria
1. The client SHALL parse `scheme://host[:port]/path?query` into components, with
   default port 443 for `https` and 80 for `http`.
2. The parser SHALL reject malformed URLs with `InvalidUrl` (missing scheme, empty
   host, host too long for the ≥ 256-byte buffer).
3. The parser SHALL support bracketed IPv6 hosts syntactically (even if GA only
   resolves IPv4 via getaddrinfo), and SHALL NOT crash on them.
4. A path-less URL SHALL default the request path to `/`.

### Requirement 12 — TLS correctness and server-name handling
**User Story:** As a security-conscious maintainer, I want real certificate
validation, matching what the WSS client already enforces.

#### Acceptance Criteria
1. The client SHALL perform the full `tls_client.handshake(transport, hostname,
   now)`, which validates the server certificate chain against the embedded CA
   bundle (`ca_bundle.sig`) and the SNI/hostname.
2. The caller SHALL supply the current time (Unix seconds) used for certificate
   validity, consistent with `wss.ConnectOptions.now`.
3. TLS entropy SHALL be seeded from the OS CSPRNG (`fillEntropy` /
   `BCryptGenRandom`) before the first handshake.
4. A certificate validation failure SHALL surface as a distinct `TlsFailed`
   (cert-category) outcome and SHALL NOT be silently ignored or downgraded.

### Requirement 13 — Single implementation; hard cutover (no shims, no legacy)
**User Story:** As a maintainer, I want exactly ONE HTTP client in the codebase —
`@zpm/http` — with the two WinHTTP modules deleted, not kept alive behind a
compatibility layer. One best implementation, versatile enough to absorb every
existing caller's needs directly.

#### Acceptance Criteria
1. `@zpm/http` SHALL be the SOLE HTTP client. There SHALL be NO compatibility
   shim, adapter module, or legacy API kept alongside it. The concepts the old
   modules exposed (`CookieJar`, `Response`, `CHROME_UA`, request/get/post) SHALL
   have their canonical and only home INSIDE `@zpm/http`.
2. `platform/http.sig` and `platform/http_session.sig` SHALL be DELETED once their
   callers are migrated; they SHALL NOT survive as thin wrappers.
3. Every current caller SHALL be rewritten to call the `@zpm/http` API directly
   (not a look-alike surface): `youtube/session.sig` (`generateITInSession`,
   `fetchChallengeInSession`, `establishIntegrityToken`), `botguard/challenge.sig`
   (`waaPost`, `Create`, `fetchScript`), and the SB0 Trade REST callers of
   `platform/http.sig`.
4. The `@zpm/http` API SHALL be versatile enough that NO caller needs a bespoke
   wrapper to express its request: arbitrary method, raw extra-header block,
   body + content-type, cookie jar, timeouts, retries, and status/header/body
   access SHALL all be first-class on the one API (satisfied by Reqs 3–12). If a
   real caller cannot be expressed, that is a gap in `@zpm/http` to be closed, not
   a reason to add a shim.
5. AFTER migration the create-test / session-test / dl-test harnesses and the SB0
   Trade build SHALL build and run with no behavioral regression, and NO non-test
   code anywhere SHALL import `winhttp`/`wininet` for HTTP (verified by a repo
   search returning zero matches outside `@zpm/http`'s own — nonexistent — and
   test code).
6. The GenerateIT call SHALL become reliable: with the built-in retries +
   timeouts, a transient network failure SHALL no longer require re-running the
   whole program.

### Requirement 14 — Build integration and module shape
**User Story:** As a maintainer, I want the client wired like the other zpm
modules so it builds with the rest.

#### Acceptance Criteria
1. The feature SHALL be a directory module (e.g. `src/net/http/` or
   `src/platform/http2/`) registered in `build.sig` via `ctx.addModule(...)` +
   `wire(...)`, mirroring the `tls_client` / `wss` registration.
2. It SHALL be importable as `@zpm/http` (module name `http` or `zpm_http`) by both
   zpm-internal consumers and downstream path-dependency projects (gotliv).
3. `sig build --build-file build.sig --summary all` SHALL report all targets
   succeeded with the new module and its tests included.
4. The feature SHALL add build test steps for its unit tests (parser, chunked,
   URL, cookie, no-alloc) consistent with the existing `test-net-*` steps.

### Requirement 15 — Test coverage
**User Story:** As a maintainer, I want the client proven correct offline before it
touches the live BotGuard flow.

#### Acceptance Criteria
1. There SHALL be in-module unit tests (over a buffer-backed `tls.Transport`) for:
   status/header parsing, Content-Length bodies, chunked decode (incl. split
   across reads, chunk extensions, trailers), HEAD/204/304 no-body, keep-alive
   reuse, redirect handling, cookie serialize/absorb, URL parse edge cases, and
   header-injection rejection.
2. There SHALL be a no-allocator assertion test modeled on
   `src/transport/no_alloc_test.sig`.
3. There SHALL be at least one live integration test (behind a flag, like the
   existing `live-wss` / `live-tls-handshake` steps) that performs a real HTTPS
   GET to a stable endpoint and asserts a 2xx and non-empty body.
4. The BotGuard GenerateIT path SHALL be verified end to end after migration: the
   pinned create-test reaches the `[5/5] Minting` block without the HTTP call being
   the flaky blocker.

### Requirement 16 — Forward-compatible version-agnostic core (HTTP/2 ready)
**User Story:** As a maintainer, I want to add HTTP/2 later without rewriting the
request/response API.

#### Acceptance Criteria
1. The public request/response model (method, url, headers, body, result,
   cookies, timeouts, retries) SHALL be independent of the wire protocol version.
2. The wire layer SHALL sit behind an internal protocol interface so an HTTP/2
   (and later H3 via the existing `transport/h3.sig`) backend can be added without
   changing caller code.
3. ALPN negotiation hooks SHALL be reserved in the TLS seam (advertise `http/1.1`
   now; `h2` later) so enabling H2 is additive.
4. This requirement SHALL NOT block GA: HTTP/1.1 is the only backend that must be
   complete and tested at GA.
