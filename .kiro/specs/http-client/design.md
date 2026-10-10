# Design — `@zpm/http` Pure-Sig HTTP Client

## Overview

`@zpm/http` is an allocation-free, pure-Sig HTTP client that composes directly on
the existing pure-Sig TLS 1.3 stack (`tls_client`) and Winsock TCP, mirroring the
proven `net/wss.sig` layering. It replaces both WinHTTP wrappers
(`platform/http.sig`, `platform/http_session.sig`) with one path the whole
codebase shares.

The design reuses what exists and adds only the HTTP layer:

```
          ┌─────────────────────────── NEW (this feature) ──────────────────────────┐
caller →  │  http.Client / http.fetch   (request build, response parse, retries,     │
          │                               redirects, cookies, keep-alive, timeouts)   │
          │        │ reads/writes plaintext bytes through a tls.Transport             │
          └────────┼─────────────────────────────────────────────────────────────────┘
                   ▼
          tls_client.Conn  (TLS 1.3 records)      ← EXISTS, unchanged
                   │  OR  http.PlainTransport      ← NEW tiny transport adapter for port-80
                   ▼
          tls_client.Socket (Winsock TCP + getaddrinfo DNS + Nagle off)  ← EXISTS,
                   │                                 extended with timeout/deadline
                   ▼
          ws2_32 (Winsock)                          ← via existing win32 bindings
```

Everything above `tls.Transport` is version-agnostic (Req 16); the HTTP/1.1 wire
codec is one implementation behind an internal `Protocol` seam so HTTP/2 can be
added later without touching callers.

### Why compose on `tls_client`, not reinvent
- `tls_client` already does TLS 1.3 handshake, X.509 chain verification against an
  embedded CA bundle, GCM record protection, and server KeyUpdate — all pure Sig,
  allocation-free, and shipping in the market-data WSS client. Rebuilding any of it
  would duplicate ~140 KB of audited crypto. The HTTP layer only needs the
  `tls.Transport` byte seam and `tls_client.handshake`.
- The `net/` stack is bare-metal (needs a `NetInterface` NIC) and TLS-less, so it
  cannot serve hosted-app HTTPS. We leave it for the kernel.

---

## Module layout

New directory module `src/net/http/` (importable as `@zpm/http`, build-module name
`zpm_http`). Internal files import each other relatively, like the `tls` dir
module.

```
src/net/http/
  client.sig       — module root: re-exports; Client, fetch(), one-shot helpers
  url.sig          — URL parse (scheme/host/port/path/query), IPv4/IPv6-bracket
  request.sig      — request-line + header serialization, body framing, injection guard
  response.sig     — incremental status/header parser, header set, lookups
  body.sig         — Content-Length + chunked decode (extensions, trailers), EOF-delimited
  cookie.sig       — CookieJar (migrated from http_session, semantics-preserving)
  transport.sig    — Transport seam helpers: tls.Conn adapter + PlainTransport (port 80)
  socket_ext.sig   — timeout/deadline/last-error extensions over tls_client.winsock
  protocol.sig     — internal Protocol vtable (H1.1 now; H2 later) — version-agnostic core
  retry.sig        — retry policy + backoff + Retry-After
  errors.sig       — single Error enum + Outcome/Trace structs
  tests.sig        — unit tests over a buffer-backed Transport
  no_alloc_test.sig— no-allocator assertion (models transport/no_alloc_test.sig)
```

Rationale for `src/net/http/` (not `platform/`): it is transport-composed and
mostly platform-agnostic (only `socket_ext` touches Winsock, via `tls_client`),
and it belongs beside `net/wss.sig` which is the sibling composition.

---

## Core types (public API)

### Error (errors.sig)
```sig
pub const Error = error{
    InvalidUrl,
    InvalidHeader,
    DnsFailed,
    ConnectFailed,
    TlsFailed,            // see TlsFailKind for cert vs transport
    Timeout,
    SendFailed,
    RecvFailed,
    PrematureClose,       // socket/TLS closed before a full response
    BadResponse,          // malformed status line / headers / chunk framing
    BodyTooLarge,         // response exceeds caller buffer
    BufferTooSmall,       // scratch/header buffer too small
    TooManyRedirects,
    RetryExhausted,
};

pub const TlsFailKind = enum(u8) { none, cert_invalid, protocol, transport };

/// Optional structured trace (off unless caller passes a *Trace). Alloc-free.
pub const Trace = struct {
    dns_ms: u32 = 0, connect_ms: u32 = 0, tls_ms: u32 = 0,
    first_byte_ms: u32 = 0, total_ms: u32 = 0,
    attempts: u8 = 0, redirects: u8 = 0,
    wsa_last_error: i32 = 0, tls_kind: TlsFailKind = .none,
};
```

### Method, Scheme, Url
```sig
pub const Method = enum { GET, POST, PUT, DELETE, HEAD, PATCH, OPTIONS };
pub const Scheme = enum { http, https };

pub const Url = struct {
    scheme: Scheme,
    host: []const u8,     // slice into caller/opts storage
    port: u16,            // defaulted: https=443, http=80
    path_query: []const u8, // "/path?query", defaults to "/"
    pub fn parse(raw: []const u8, host_buf: []u8) Error!Url; // copies host into host_buf
};
```

### Request / Response (request.sig, response.sig)
```sig
pub const Request = struct {
    method: Method = .GET,
    url: []const u8,              // or pre-parsed Url via requestUrl()
    headers: []const u8 = "",     // raw "Name: v\r\n..." block, verbatim, injection-checked
    content_type: []const u8 = "",// optional; defaults applied by framing rules
    body: []const u8 = "",
    user_agent: []const u8 = CHROME_UA,
    jar: ?*CookieJar = null,
    // policy
    timeouts: Timeouts = .{},
    retry: RetryPolicy = .{},
    max_redirects: u8 = 5,
    allow_insecure_redirect: bool = false,
    retry_non_idempotent: bool = false,
    trace: ?*Trace = null,
};

pub const Timeouts = struct {
    connect_ms: u32 = 15_000,
    send_ms: u32 = 20_000,
    recv_ms: u32 = 30_000,
    total_ms: u32 = 60_000,       // whole request incl. retries/redirects
};

/// A parsed response. `body` and header name/value slices point into the
/// caller-provided buffers; valid until the next request on the same buffers.
pub const Response = struct {
    status: u16 = 0,
    reason: []const u8 = "",
    headers: HeaderSet,           // bounded, case-insensitive lookup
    body: []const u8 = "",
    complete: bool = false,
    keep_alive: bool = false,
    pub fn ok(self: *const Response) bool { return self.status >= 200 and self.status < 300; }
    pub fn header(self: *const Response, name: []const u8) ?[]const u8;
};

pub const HeaderSet = struct {
    // Fixed array of (name_slice, value_slice) into the header scratch buffer.
    const MAX_RESP_HEADERS = 48;
    // ...
    pub fn get(self: *const HeaderSet, name: []const u8) ?[]const u8; // case-insensitive
};
```

### Buffers (caller-owned, Req 2)
Request options carry the storage so the client allocates nothing:
```sig
pub const Buffers = struct {
    body: []u8,        // response body destination (bounds max body)
    header_scratch: []u8, // response header bytes + parsed slices live here (≥ 8 KiB)
    tls_scratch: []u8, // handshake scratch (≥ 4 KiB) — passed to tls_client
};
```

### fetch (one-shot) and Client (keep-alive)
```sig
/// One-shot: open → (TLS) handshake → request → response → close. Alloc-free.
pub fn fetch(req: Request, bufs: Buffers, now: i64) Error!Response;

/// Pinned, connection-holding client for keep-alive and repeated requests to one
/// host:port:scheme. PIN this (do not move after `connect`): inner layers hold
/// pointers into it, exactly like wss.WssClient.
pub const Client = struct {
    sock: tlsc.Socket = .{},
    conn: tlsc.Conn = undefined,     // used when scheme == https
    plain: PlainTransport = .{},     // used when scheme == http
    scheme: Scheme = .https,
    host_buf: [256]u8 = undefined, host_len: usize = 0,
    port: u16 = 443,
    connected: bool = false,

    pub fn connect(self: *Client, url: []const u8, bufs: Buffers, now: i64) Error!void;
    pub fn send(self: *Client, req: Request, bufs: Buffers, now: i64) Error!Response; // reuses conn
    pub fn close(self: *Client) void;
    pub fn shutdownSocket(self: *Client) void; // cross-thread unblock (wss parity)
};
```

### CookieJar (cookie.sig) — migrated verbatim semantics
Lift `http_session.CookieJar` (and `Cookie`, `MAX_COOKIES=64`,
`COOKIE_VALUE_MAX=768`) into `cookie.sig` unchanged: `init`, `clear`, `count`,
`set`, `get`, `serialize`, `absorbRawHeaders`. The only change: absorption is
driven from the parsed `HeaderSet` (Req 8.3) rather than a WinHTTP raw-header
re-query — a thin `absorbFromHeaders(hs: *const HeaderSet)` wrapper that iterates
`Set-Cookie` entries and calls the existing `set`.

### Public constants
`pub const CHROME_UA` (same string as `http_session.CHROME_UA`).

---

## The transport seam (transport.sig + socket_ext.sig)

The HTTP engine reads/writes plaintext bytes through one abstraction so HTTPS and
plaintext HTTP share identical code.

### HTTPS path
Reuse exactly as `wss.sig` does:
```sig
self.sock = tlsc.connectHost(host, port);     // Winsock TCP + getaddrinfo + Nagle off
self.conn = tlsc.handshake(self.sock.transport(), host, now); // TLS1.3 + cert verify
// http engine then uses conn.read()/conn.write() (decrypted/encrypted app bytes)
```
A `connTransport(*tlsc.Conn)` adapter exposes the Conn's read/write as the HTTP
engine's byte seam (identical to `wss.connTransport`).

### Plaintext path (port 80 / http://)
`PlainTransport` wraps a `tlsc.Socket` directly (no TLS Conn), presenting the same
read-some / write-all seam the HTTP engine consumes. This keeps the HTTP codec
transport-agnostic.

### socket_ext.sig — timeouts, connect deadline, last-error (Req 5, 7.3)
`tls_client.winsock.Socket` is a blocking socket with Nagle disabled but no
timeouts. Rather than fork it, add free functions that operate on a
`tlsc.Socket.fd`:
- `setRecvTimeout(fd, ms)` / `setSendTimeout(fd, ms)` via
  `setsockopt(SOL_SOCKET, SO_RCVTIMEO/SO_SNDTIMEO, &DWORD(ms))` — add the two
  `SO_*` constants (0x1006 / 0x1005) to `win32.sig`.
- `connectDeadline(host, port, connect_ms)` — a non-blocking connect using the
  existing `ioctlsocket(FIONBIO)` binding + `select`/`WSAPoll` with a deadline,
  returning a connected blocking `tlsc.Socket` or `Error.Timeout`/`ConnectFailed`.
  (`select` is added to the win32 ws2_32 externs.)
- `lastError()` → `WSAGetLastError()` for `Trace.wsa_last_error`.

These are thin additions; `connectHost` stays the simple blocking path and
`connectDeadline` is used when `timeouts.connect_ms` is set (default).

> Design note: `getaddrinfo` itself is synchronous and not deadline-bounded by
> Winsock. The connect deadline covers the TCP SYN wait (the common stall). DNS is
> recorded in `Trace.dns_ms`; a hard DNS timeout is out of scope at GA (documented).

---

## HTTP/1.1 wire codec

### Request serialization (request.sig)
Build directly into a stack buffer, then write through the transport in up to
three `writeAll`s (header block, body) — no per-byte socket calls (Nagle is off,
but we still batch):
1. Request line: `METHOD SP path_query SP HTTP/1.1 CRLF`.
2. `Host:` — `host` or `host:port` when port is non-default for the scheme.
3. `User-Agent:` (caller or `CHROME_UA`).
4. `Accept-Encoding: identity` (we do not decompress; avoid gzip surprises) unless
   the caller overrides via extra headers.
5. `Connection: keep-alive` for a `Client`, `Connection: close` for one-shot
   `fetch` (so EOF-delimited bodies terminate cleanly).
6. Caller extra-header block, verbatim — but every line is validated to contain no
   bare CR/LF beyond its own terminator and a `:`; a bad line → `InvalidHeader`.
7. Cookie header from the jar (`jar.serialize`) when present.
8. Body framing: if `body.len > 0` and the caller did not already supply a
   `Content-Length`/`Transfer-Encoding`, emit `Content-Length: <n>` and, if no
   `Content-Type` is present, `Content-Type: application/octet-stream`.
9. CRLF terminator, then the body bytes.

Header-injection guard (Req 3.7): a small scanner rejects `\r`/`\n`/NUL inside any
caller-provided name or value.

### Response parsing (response.sig + body.sig)
A resumable state machine fed from transport reads into `header_scratch`:
```
reading_status → reading_headers → reading_body(len|chunked|eof) → complete
```
- **Status line**: parse `HTTP/1.x` + 3-digit code + reason phrase (sliced).
- **Headers**: split on CRLF; store name/value slices into `HeaderSet` (cap 48,
  case-insensitive `get`). Pull out `Content-Length`, `Transfer-Encoding`,
  `Connection`, `Location`, `Retry-After`, `Set-Cookie` (multi).
- **Body selection** (Req 4.3–4.6):
  - `HEAD`, `204`, `304`, `1xx` → no body, complete immediately.
  - chunked → `body.sig` chunk decoder (hex size, skip `;ext`, CRLF, data, CRLF;
    `0\r\n` ends; read+discard trailer headers to the blank line).
  - Content-Length → read exactly N into `bufs.body`.
  - else + `Connection: close` → read until EOF (clean close).
- Writes body bytes into `bufs.body`; overflow → `BodyTooLarge` with partial length
  recorded (never overruns).
- Incremental: the parser is re-entrant; the engine loops `transport.read` →
  `feed` until `complete` or a buffer/timeout limit (Req 4.8).

Buffering model: a single `header_scratch` holds the raw header bytes (so slices
stay valid); the body goes to `bufs.body`. If headers exceed `header_scratch` →
`BufferTooSmall`.

### Protocol seam (protocol.sig, Req 16)
```sig
pub const Protocol = struct {
    ctx: *anyopaque,
    sendRequestFn: *const fn (ctx, *const Request, Transport) Error!void,
    readResponseFn: *const fn (ctx, Transport, Buffers, *Response) Error!void,
};
```
GA ships `Http1` implementing this. An `Http2` impl (HPACK + frames over the same
`tls.Transport`, ALPN `h2`) can be added later with no API change. ALPN: the TLS
ClientHello advertises `http/1.1` now; adding `h2` to the advertised list and an
`Http2` selected on the negotiated ALPN is additive (a small `tls_client` hook to
expose negotiated ALPN; until then H1.1 is forced).

---

## Request lifecycle (fetch / Client.send)

```
1. parse url → Url (scheme, host, port, path_query)              [url.sig]
2. (Client) reuse live conn if same host:port:scheme & prior body consumed,
   else connect:
     a. socket_ext.connectDeadline(host, port, connect_ms)       [Trace.connect_ms]
        → tlsc.Socket  (DNS via getaddrinfo → Trace.dns_ms)
     b. if https: tlsc.handshake(sock.transport(), host, now)    [Trace.tls_ms]
        cert-chain validated vs ca_bundle; TlsFailKind on failure
     c. setRecv/SendTimeout(fd, ...)
3. serialize request (+cookies) → transport.writeAll             [request.sig]
4. read + parse response (first byte → Trace.first_byte_ms)      [response/body.sig]
5. jar.absorbFromHeaders(&resp.headers)                          [cookie.sig]
6. redirect? (Location, status in {301,302,303,307,308},
   redirects < max, scheme policy) → rebuild + goto 2            [Req 9]
7. keep-alive bookkeeping: reusable iff fully delimited & keep-alive & body consumed
8. return Response  (Trace.total_ms, attempts, redirects filled)
```

### Retry wrapper (retry.sig, Req 6)
`fetch` and `Client.send` run the lifecycle inside a retry loop:
- Retriable: `ConnectFailed`, `TlsFailed(transport)`, `Timeout`,
  `PrematureClose` (before any status byte). Opt-in: HTTP 408/429/5xx.
- Idempotency: GET/HEAD/PUT/DELETE/OPTIONS retriable; POST/PATCH only if
  `retry_non_idempotent`.
- Backoff: `base_ms * 2^(attempt-1)`, capped; `Retry-After` (delta-seconds or
  HTTP-date) overrides for 429/503, capped by `total_ms`.
- Bounded by `timeouts.total_ms`; stops with `RetryExhausted` or the last typed
  error, `Trace.attempts` set.
- Never retries past a point where the request body was partially sent on a
  non-idempotent method.

---

## Single implementation; hard cutover (Req 13 — NO shims)

There is exactly ONE HTTP client: `@zpm/http`. The two WinHTTP modules are
**deleted**, not wrapped. `CookieJar`, `Response`, `CHROME_UA`, `Method` have
their canonical and only home inside `@zpm/http` (see Core types above); callers
import them from there. There is no compatibility surface, no adapter module, no
re-export of the old API shape. If a caller cannot express its request on the
`@zpm/http` API, that is a gap in `@zpm/http` to close (Reqs 3–12), never a reason
to add a shim.

### Delete
- `src/platform/http_session.sig` — DELETED.
- `src/platform/http.sig` — DELETED.
(After migration, a repo-wide search for `winhttp`/`wininet` in non-test HTTP code
returns zero matches.)

### Callers to rewrite directly (real inventory across sibling repos)
All affected projects are siblings under `C:\Just-Things\Projects\` and
`C:\Just-Things\Projects\sb0\`. Each is rewritten to call `@zpm/http` directly on
its own up-to-date mainline, then built and pushed:

| Repo (mainline) | What imports the WinHTTP modules | Migration |
|---|---|---|
| **zpm** (`main`) | `youtube/session.sig` (`generateITInSession`, `fetchChallengeInSession`, `establishIntegrityToken`) via `platform/http_session`; `youtube/botguard/challenge.sig` (`waaPost`, `Create`, `fetchScript`) via hand-rolled WinHTTP | rewrite to `@zpm/http` `Client`/`fetch`; delete both platform modules |
| **gotliv** (`master`) | session/create/dl harnesses import `zpm/platform/http_session`; `ai_edit.sig` hand-rolls WinHTTP for the LLM call | repoint harnesses to `@zpm/http`; replace `ai_edit.sig` WinHTTP with `@zpm/http` (or `@zpm/openrouter`) |
| **sb0/sbtrade** (`master`) | `build.sig` registers `http` → `platform/http.sig`; `funding.sig` hand-rolls `WinHttp*` | REST callers → `@zpm/http.Client`; drop the `winhttp` link |
| **sb0/nexus** (`main`) | `build.sig`/`init.sig`/`official_packages.sig` reference `platform/http.sig` (package-registry metadata + any kernel/userspace REST) | update registry metadata to the pure-Sig client; migrate real callers; (kernel `tcp_ip` TLS path is separate, leave it) |
| **sb0/galaxy** (`galaxy`) | `build.sig`/`init.sig` reference `platform/http.sig` (mostly vendored zpm snapshot + registry metadata) | re-sync vendored zpm snapshot after the zpm change; migrate any real galaxy caller |
| **sb0/sbcode**, **sb0/stools** | HTTP via other means / none confirmed | audit; migrate if a real caller exists |

> Several nexus/galaxy "hits" are a **vendored zpm snapshot** + package-registry
> metadata, not real call sites. For those, the canonical fix is in zpm; the
> downstream repo re-syncs its vendored copy / updates registry metadata rather
> than hand-editing a copy. Confirm vendored-vs-path-dependency per repo before
> treating a hit as a caller.

### `botguard/challenge.sig` (the reliability win)
Rewrite `waaPost`, `Create`, and `fetchScript` to `@zpm/http` (`fetch` / a shared
`Client` for the Create→GenerateIT pair) with the json+protobuf headers. Retries +
timeouts + typed errors replace the opaque `return 0` that forces whole-program
re-runs today.

### Git workflow for the cutover (per affected repo)
1. Ensure a clean tree (commit/stash real work first — never discard someone's
   uncommitted changes); sync mainline to origin (ff-only).
2. Review branches: branches already merged into mainline are left/deleted;
   genuinely-unmerged branches are integrated properly (rebase/cherry-pick that
   adds, never a merge that regresses mainline) on their own branch + PR.
3. Make the `@zpm/http` migration on a feature branch, build green, open a PR to
   mainline, merge, push. The zpm change lands FIRST (it is the dependency);
   downstream repos migrate/re-sync against the merged zpm.

### Verification after migration
- zpm: `sig build --build-file build.sig --summary all` green (incl. new tests).
- gotliv path-dependency build green; `youtube` self-test (`session-test
  --relay`) and the gotliv harnesses (`create-test --pinned`, `dl-test`) build and
  run; GenerateIT is no longer the flaky blocker.
- sbtrade / nexus / galaxy / sbcode / stools: each affected repo builds green on
  its mainline after migration.
- Repo-wide: no non-test code imports `winhttp`/`wininet` for HTTP.

---

## Build wiring (build.sig, Req 14)

Mirror the `tls_client` / `wss` block:
```sig
const zpm_http = try ctx.addModule("zpm_http", "src/net/http/client.sig");
try wire(ctx, zpm_http, "tls_client", "src/core/crypto/tls/client.sig");
try wire(ctx, zpm_http, "win32", "<win32 module path>");   // for socket_ext SO_* + select
// internal http/*.sig files import each other relatively (dir module)
```
Add test steps alongside `test-net-*`:
`test-http-parse`, `test-http-chunked`, `test-http-url`, `test-http-cookie`,
`test-http-noalloc`, and a flagged `live-http-get`.

win32 additions (small): `SO_RCVTIMEO=0x1006`, `SO_SNDTIMEO=0x1005`, and `select`
+ `timeval`/`fd_set` externs for the connect deadline.

---

## No-allocation strategy (Req 2)

- All request serialization uses a stack buffer (`MAX_REQUEST_HEADER` ≈ 8 KiB) or
  writes straight through the transport.
- Response headers land in caller `header_scratch`; body in caller `bufs.body`;
  TLS handshake uses caller `tls_scratch` + `tls_client`'s own fixed internal
  buffers (already alloc-free).
- `CookieJar`, `HeaderSet`, `Client` are fixed-size structs (pinned).
- `no_alloc_test.sig` asserts (comptime + a failing-allocator harness like
  `transport/no_alloc_test.sig`) that `fetch` and `Client.send` take no allocator
  and reference none.

### Buffer sizing defaults (named constants)
| Constant | Default | Purpose |
|---|---|---|
| `MAX_REQUEST_HEADER` | 8 KiB | serialized request head (line+headers+cookies) |
| `MAX_EXTRA_HEADERS` | 4 KiB | caller raw header block (Req 3.3) |
| `MAX_RESP_HEADERS` | 48 | parsed header entries (Req 4.2) |
| `MAX_HEADER_SCRATCH` | 16 KiB | raw response header bytes (recommended min 8 KiB) |
| `MAX_HOST` | 256 | host buffer (Req 11.2) |
| `MAX_COOKIES` | 64 | jar size (parity) |
| default body buffer | caller-set | callers that need a large body pass a ≥1 MiB slice (e.g. YouTube homepage HTML + BG script) |

---

## Security considerations
- Real TLS cert-chain validation via `tls_client` + `ca_bundle` (Req 12); no
  "accept any cert" mode at GA.
- Header-injection rejection on all caller-supplied header bytes (Req 3.7).
- Insecure-redirect (https→http) refused by default (Req 9.4).
- Cookie values are copied into fixed buffers; over-long values are bounded, not
  overflowed (parity with current jar).
- Entropy seeded from `BCryptGenRandom` before first handshake (Req 12.3).
- External response bytes are treated as untrusted data: the parser never
  executes or reflects them; sizes are bounds-checked before every copy.

## Testing strategy
- **Unit (buffer-backed Transport):** a `TestTransport` that serves scripted bytes
  (incl. split-across-reads) and captures writes — exercises every parser/codec
  path offline with no network (Req 15.1).
- **No-alloc:** `no_alloc_test.sig` (Req 15.2).
- **Live (flagged):** `live-http-get` → real HTTPS GET to a stable 2xx endpoint
  (Req 15.3), parallel to the existing `live-tls-handshake`/`live-wss` steps.
- **E2E:** migrated BotGuard GenerateIT reaches minting without HTTP flakiness
  (Req 15.4).

## Risks / open questions
- **getaddrinfo has no deadline.** Mitigation: connect-deadline covers the common
  stall; a cached-DNS or async-resolver pass is a future enhancement.
- **ALPN exposure.** `tls_client` may need a tiny accessor to surface the
  negotiated ALPN for the future H2 switch; H1.1 GA does not need it.
- **platform/http.sig UTF-16 call sites.** Migrating SB0 Trade REST means changing
  a handful of `L"..."` UTF-16 paths to the ASCII `@zpm/http` API; low-risk but it
  touches a second project's call sites directly (no shim) — migrate those call
  sites in the sbtrade repo and verify its build separately before deleting the
  old module.
- **Cross-repo ordering.** The zpm change (new client + deleted modules) must land
  and be consumable before downstream repos migrate; vendored-zpm consumers
  (nexus/galaxy) re-sync their snapshot rather than hand-editing a copy.
