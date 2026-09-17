// cdp — a pure-Sig Chrome DevTools Protocol client.
// Layer 1: Platform.
//
// Drives a headless Chromium-family browser (Chrome / Edge / Chromium / Brave)
// over the DevTools Protocol so callers can navigate a page and run JavaScript
// in it — the reliable way to read a live page's *rendered* DOM (real text,
// computed styles, geometry, image URLs) that a flat screenshot cannot recover.
//
// The transport is fully portable: it launches the browser with
// `--remote-debugging-port` via the zpm `subprocess` primitive, discovers the
// page target with a one-line HTTP GET over `std.Io.net`, then speaks JSON-RPC
// over the pure-Sig `websocket` client. No OS `#if`s, no libc, no heap.
//
//   var browser = try cdp.Browser.launch(io, .{ .port = 9222 });
//   defer browser.shutdown(io);
//   var page = try browser.attach(io, &page_bufs);
//   try page.navigate(io, "https://example.com");
//   const json = try page.evaluate(io, extractor_js, result_buf);
//
// `evaluate` returns the JSON text the page script produced (via
// `Runtime.evaluate` with `returnByValue`), ready for a domain parser.

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const subprocess = @import("subprocess");
const websocket = @import("websocket");

pub const Error = error{
    NoBrowserFound,
    LaunchFailed,
    EndpointUnreachable,
    NoPageTarget,
    Protocol,
    EvalFailed,
    BufferTooSmall,
};

/// Known Chromium-family executables per platform, in preference order.
/// Mirrors web_capture's probe list so the two tools agree on the browser.
fn candidatePaths() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{
            "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
            "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
            "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
            "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
            "C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe",
        },
        .macos => &[_][]const u8{
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        },
        else => &[_][]const u8{
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/usr/bin/microsoft-edge",
            "/usr/bin/brave-browser",
            "google-chrome",
            "chromium",
        },
    };
}

fn hasPathSep(s: []const u8) bool {
    for (s) |c| {
        if (c == '/' or c == '\\') return true;
    }
    return false;
}

fn resolveBrowser(io: std.Io, explicit: ?[]const u8) ?[]const u8 {
    if (explicit) |p| {
        if (p.len > 0) return p;
    }
    const cwd: std.Io.Dir = .cwd();
    for (candidatePaths()) |cand| {
        if (!hasPathSep(cand)) return cand;
        if (cwd.access(io, cand, .{})) |_| return cand else |_| {}
    }
    return null;
}

pub const LaunchOptions = struct {
    /// Local debugging port. Pick one unlikely to collide.
    port: u16 = 9222,
    /// Explicit browser path; if null, probe known install locations.
    browser_path: ?[]const u8 = null,
    /// Viewport width/height in CSS pixels for the headless window.
    width: u32 = 1440,
    height: u32 = 2200,
    /// A writable directory for the throwaway browser profile. Chrome refuses
    /// to share a profile with a running instance, so a fresh dir avoids
    /// clobbering the user's browser. If empty, Chrome's default is used.
    user_data_dir: []const u8 = "",
    /// How long to wait (ms) for the debugging endpoint to come up.
    endpoint_timeout_ms: u32 = 8000,
    /// Grace period (ms) after page load before running the extractor, so
    /// client-rendered pages finish painting images/fonts/late content.
    settle_ms: u32 = 1200,
};

/// A launched headless browser process plus its debugging port.
pub const Browser = struct {
    handle: subprocess.ProcessHandle,
    port: u16,
    io: std.Io,
    /// Grace period (ms) after page load before extraction; propagated to Page.
    settle_ms: u32 = 1200,

    /// Launch a headless browser with the remote debugging port open.
    pub fn launch(io: std.Io, opts: LaunchOptions) Error!Browser {
        const browser = resolveBrowser(io, opts.browser_path) orelse return Error.NoBrowserFound;

        var arg_store: ArgStore = .{};
        const port_flag = arg_store.fmt("--remote-debugging-port={d}", .{opts.port});
        const window_flag = arg_store.fmt("--window-size={d},{d}", .{ opts.width, opts.height });
        // Chrome hands a launch off to an existing instance if it finds a
        // usable profile — which would silently ignore our --remote-debugging-port
        // and hang the client. Force a unique, throwaway profile per launch so
        // we always get our own instance and port.
        //
        // The path MUST be absolute: Chrome refuses a relative --user-data-dir
        // ("cannot read and write to its data directory") and pops a modal that
        // never opens the port. Resolve a relative name against the cwd.
        var abs_udd_buf: [1024]u8 = undefined;
        const udd_flag = if (opts.user_data_dir.len > 0) blk: {
            const abs = absProfileDir(io, opts.user_data_dir, uniqueSuffix(io), &abs_udd_buf);
            break :blk arg_store.fmt("--user-data-dir={s}", .{abs});
        } else "";

        // A blank first page so the browser opens exactly one page target we
        // can attach to and drive with Page.navigate.
        var argv_buf: [16][]const u8 = undefined;
        var argc: usize = 0;
        const base = [_][]const u8{
            browser,
            "--headless",
            "--disable-gpu",
            "--hide-scrollbars",
            "--no-sandbox",
            "--no-first-run",
            "--disable-extensions",
            "--remote-allow-origins=*",
            port_flag,
            window_flag,
        };
        for (base) |a| {
            argv_buf[argc] = a;
            argc += 1;
        }
        if (udd_flag.len > 0) {
            argv_buf[argc] = udd_flag;
            argc += 1;
        }
        argv_buf[argc] = "about:blank";
        argc += 1;

        const cfg = subprocess.SubprocessConfig{ .argv = argv_buf[0..argc] };
        // Detached: the browser streams diagnostics to stderr forever; piping
        // and not draining that would deadlock it. Discard its output.
        const handle = subprocess.spawnDetached(io, &cfg) orelse return Error.LaunchFailed;

        var self = Browser{ .handle = handle, .port = opts.port, .io = io, .settle_ms = opts.settle_ms };

        // Poll the HTTP endpoint until the DevTools server is ready.
        if (!self.waitForEndpoint(io, opts.endpoint_timeout_ms)) {
            self.shutdown(io);
            return Error.EndpointUnreachable;
        }
        return self;
    }

    /// Kill the browser process.
    pub fn shutdown(self: *Browser, io: std.Io) void {
        _ = subprocess.kill(io, &self.handle);
    }

    /// Poll `GET /json/version` until it answers or the deadline passes.
    fn waitForEndpoint(self: *Browser, io: std.Io, timeout_ms: u32) bool {
        var waited: u32 = 0;
        const step: u32 = 200;
        var scratch: [4096]u8 = undefined;
        while (waited < timeout_ms) {
            if (httpGet(io, self.port, "/json/version", &scratch)) |_| return true else |_| {}
            sleepMs(io, step);
            waited += step;
        }
        return false;
    }

    /// Buffers a Page borrows for the lifetime of a session. Caller-owned so
    /// the whole client stays heap-free.
    pub const PageBuffers = struct {
        /// Receive buffer for the websocket — bounds the largest CDP message,
        /// i.e. the largest DOM-extraction JSON we can read back. Size it big.
        recv: []u8,
        /// Handshake scratch for the websocket client.
        scratch: []u8,
        /// Scratch for the target-discovery HTTP GET.
        http: []u8,
        /// Scratch for building JSON-RPC request bodies.
        request: []u8,
        /// Stable storage for the plaintext WebSocket transport. The ws Client's
        /// vtable points here, so it must outlive the Page (hence caller-owned).
        transport: websocket.StreamTransport = undefined,
    };

    /// Discover the first page target and open a CDP session on it.
    pub fn attach(self: *Browser, io: std.Io, bufs: *PageBuffers) Error!Page {
        // GET /json → array of targets. Find a "page" target's ws debugger URL.
        const body = httpGet(io, self.port, "/json", bufs.http) catch return Error.EndpointUnreachable;
        var path_buf: [512]u8 = undefined;
        const ws_path = extractWsPath(body, &path_buf) orelse return Error.NoPageTarget;

        var host_buf: [16]u8 = undefined;
        const host = std.fmt.bufPrint(&host_buf, "127.0.0.1", .{}) catch return Error.BufferTooSmall;

        // Open the plaintext TCP transport into caller-owned stable storage,
        // then run the WebSocket upgrade over it.
        bufs.transport = websocket.StreamTransport.connect(io, host, self.port) catch
            return Error.Protocol;
        const client = websocket.Client.overTransport(bufs.transport.transport(), .{
            .host = host,
            .port = self.port,
            .path = ws_path,
            .recv_buf = bufs.recv,
            .scratch = bufs.scratch,
        }) catch return Error.Protocol;

        return Page{ .ws = client, .next_id = 1, .request = bufs.request, .settle_ms = self.settle_ms };
    }
};

/// An attached CDP page session. Sends JSON-RPC commands over the websocket.
pub const Page = struct {
    ws: websocket.Client,
    next_id: u32,
    request: []u8,
    /// Grace period (ms) after `load` before extraction, for SPA/late content.
    settle_ms: u32 = 1200,

    /// Enable the Page domain and navigate to `url`, then wait for the load
    /// event. CDP delivers events and command replies on the same channel, so
    /// we send the commands and then drain messages until navigation settles.
    pub fn navigate(self: *Page, io: std.Io, url: []const u8) Error!void {
        // Page.enable so we receive lifecycle/load events.
        _ = try self.call(io, "Page.enable", "{}");

        // Page.navigate {url:...}
        var params_buf: [2048]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"url\":\"{s}\"}}", .{url}) catch
            return Error.BufferTooSmall;
        _ = try self.call(io, "Page.navigate", params);

        // Drain events until we see a load/lifecycle signal, bounded by a max
        // number of frames so a chatty page can't spin us forever.
        var seen_load = false;
        var budget: u32 = 400;
        while (!seen_load and budget > 0) : (budget -= 1) {
            const msg = self.ws.receiveMessage() catch break;
            if (indexOf(msg.data, "\"Page.loadEventFired\"") != null) seen_load = true;
            if (indexOf(msg.data, "\"Page.frameStoppedLoading\"") != null) seen_load = true;
        }

        // Client-rendered (SPA) pages keep painting after `load`: images,
        // webfonts, and framework-inserted content settle a beat later. Give
        // the page a short grace period so the extractor sees the finished DOM
        // rather than a half-built one.
        std.Io.sleep(io, .fromMilliseconds(self.settle_ms), .awake) catch {};
    }

    /// Evaluate `expression` in the page and return the JSON of its value.
    /// The expression should evaluate to a JSON string (we request
    /// returnByValue); the returned slice points into `out`.
    pub fn evaluate(self: *Page, io: std.Io, expression: []const u8, out: []u8) Error![]const u8 {
        // Build Runtime.evaluate params with the expression JSON-escaped.
        // We stream the request directly to avoid a giant params copy.
        const id = self.next_id;
        self.next_id += 1;

        // Header + escaped expression + tail, written straight into request buf.
        var b = Builder{ .buf = self.request };
        b.raw("{\"id\":");
        b.num(id);
        b.raw(",\"method\":\"Runtime.evaluate\",\"params\":{\"returnByValue\":true,\"expression\":\"");
        b.escaped(expression);
        b.raw("\"}}");
        if (b.overflow) return Error.BufferTooSmall;

        self.ws.sendText(b.slice()) catch return Error.Protocol;

        // Read replies until we get the one matching our id.
        var id_needle_buf: [32]u8 = undefined;
        const id_needle = std.fmt.bufPrint(&id_needle_buf, "\"id\":{d}", .{id}) catch
            return Error.BufferTooSmall;

        var budget: u32 = 200;
        while (budget > 0) : (budget -= 1) {
            const msg = self.ws.receiveMessage() catch return Error.Protocol;
            if (indexOf(msg.data, id_needle) == null) continue; // an event or other reply

            if (indexOf(msg.data, "\"exceptionDetails\"") != null) return Error.EvalFailed;
            // result.result.value holds the returned value. For a string value
            // it appears as "value":"...."; extract it, unescaping JSON.
            return extractResultValue(msg.data, out) orelse Error.EvalFailed;
        }
        return Error.Protocol;
    }

    /// Send a command and wait for its matching reply. Returns nothing useful
    /// beyond success; the reply body is discarded.
    fn call(self: *Page, io: std.Io, method: []const u8, params: []const u8) Error!void {
        const id = self.next_id;
        self.next_id += 1;

        var b = Builder{ .buf = self.request };
        b.raw("{\"id\":");
        b.num(id);
        b.raw(",\"method\":\"");
        b.raw(method);
        b.raw("\",\"params\":");
        b.raw(params);
        b.raw("}");
        if (b.overflow) return Error.BufferTooSmall;

        self.ws.sendText(b.slice()) catch return Error.Protocol;

        var id_needle_buf: [32]u8 = undefined;
        const id_needle = std.fmt.bufPrint(&id_needle_buf, "\"id\":{d}", .{id}) catch
            return Error.BufferTooSmall;
        var budget: u32 = 200;
        while (budget > 0) : (budget -= 1) {
            const msg = self.ws.receiveMessage() catch return Error.Protocol;
            if (indexOf(msg.data, id_needle) != null) return;
        }
        return Error.Protocol;
    }

    pub fn close(self: *Page, io: std.Io) void {
        self.ws.close();
    }
};

// ── HTTP GET (minimal, plaintext, localhost) ──────────────────────────────

/// Perform `GET path` against 127.0.0.1:port and return the response *body*
/// (headers stripped). Body points into `buf`. Blocking, one-shot.
fn httpGet(io: std.Io, port: u16, path: []const u8, buf: []u8) Error![]const u8 {
    const addr = net.IpAddress.parse("127.0.0.1", port) catch return Error.EndpointUnreachable;
    const stream = net.IpAddress.connect(&addr, io, .{ .mode = .stream, .protocol = .tcp }) catch
        return Error.EndpointUnreachable;
    defer stream.close(io);

    var wbuf: [1024]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    const w = &writer.interface;
    w.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ path, port }) catch
        return Error.EndpointUnreachable;
    w.flush() catch return Error.EndpointUnreachable;

    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const r = &reader.interface;

    // Read in small chunks. `readSliceShort` fills its whole slice before
    // returning (only stopping early on EOF), so reading straight into a giant
    // buffer would block waiting for bytes that never come on a keep-alive
    // connection. Read a byte at a time via the buffered reader (cheap: the
    // reader refills its 4 KiB buffer under the hood) and stop as soon as the
    // HTTP message is structurally complete — headers seen, then either
    // Content-Length bytes of body or a balanced top-level JSON value.
    var total: usize = 0;
    var header_end: ?usize = null;
    var content_len: ?usize = null;
    var depth: i32 = 0;
    var started_body = false;
    var in_string = false;
    var escaped_ch = false;

    while (total < buf.len) {
        const c = r.takeByte() catch break; // EOF or error → return what we have
        buf[total] = c;
        total += 1;

        if (header_end == null) {
            if (total >= 4 and
                buf[total - 4] == '\r' and buf[total - 3] == '\n' and
                buf[total - 2] == '\r' and buf[total - 1] == '\n')
            {
                header_end = total;
                content_len = parseContentLength(buf[0..total]);
                // A 0-length or header-only response is already complete.
                if (content_len) |cl| {
                    if (cl == 0) break;
                }
            }
            continue;
        }

        // We are in the body now.
        const body_len = total - header_end.?;
        if (content_len) |cl| {
            if (body_len >= cl) break; // got the whole declared body
            continue;
        }

        // No Content-Length: track balanced JSON to know when the value ends.
        if (in_string) {
            if (escaped_ch) {
                escaped_ch = false;
            } else if (c == '\\') {
                escaped_ch = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                started_body = true;
            },
            ']', '}' => {
                depth -= 1;
                if (started_body and depth == 0) break; // top-level value closed
            },
            else => {},
        }
    }

    const resp = buf[0..total];
    if (indexOf(resp, "\r\n\r\n")) |i| return resp[i + 4 ..];
    return resp;
}

/// Parse the Content-Length header value from an HTTP header block, or null.
fn parseContentLength(head: []const u8) ?usize {
    const key = "content-length:";
    var i: usize = 0;
    while (i + key.len <= head.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < key.len) : (j += 1) {
            if (lowerc(head[i + j]) != key[j]) {
                match = false;
                break;
            }
        }
        if (!match) continue;
        var k = i + key.len;
        while (k < head.len and (head[k] == ' ' or head[k] == '\t')) : (k += 1) {}
        var v: usize = 0;
        var saw = false;
        while (k < head.len and head[k] >= '0' and head[k] <= '9') : (k += 1) {
            v = v * 10 + (head[k] - '0');
            saw = true;
        }
        if (saw) return v;
    }
    return null;
}

fn lowerc(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// From a `/json` targets array, extract the ws debugger path of a real
/// *page* target (`"type":"page"`), skipping background_page / browser_ui /
/// service_worker entries whose ws URLs also live under /devtools/page/.
/// e.g. ws://127.0.0.1:9222/devtools/page/ABC → /devtools/page/ABC
///
/// Tolerant of pretty-printed JSON: the DevTools endpoint emits
/// `"type": "page"` with spaces around the colon, so we match the *key* then
/// skip whitespace/colon before reading the quoted value.
fn extractWsPath(body: []const u8, out: []u8) ?[]const u8 {
    // Walk each `"type"` key; if its value is "page", take that object's
    // `"webSocketDebuggerUrl"` (the next one before the following "type" key).
    var i: usize = 0;
    while (findValueAfterKey(body, "\"type\"", i)) |tv| {
        if (std.mem.eql(u8, body[tv.start..tv.end], "page")) {
            const next_type = keyIndexFrom(body, "\"type\"", tv.end) orelse body.len;
            if (findValueAfterKey(body, "\"webSocketDebuggerUrl\"", tv.end)) |uv| {
                if (uv.start < next_type) {
                    return wsUrlPath(body[uv.start..uv.end], out);
                }
            }
        }
        i = tv.end;
    }
    return null;
}

const Span = struct { start: usize, end: usize };

/// Find `key` at or after `from` and return the byte span of the quoted string
/// value that follows it (skipping whitespace and the ':'). Null if not found.
fn findValueAfterKey(body: []const u8, key: []const u8, from: usize) ?Span {
    const k = keyIndexFrom(body, key, from) orelse return null;
    var j = k + key.len;
    // skip spaces, tabs, and the colon
    while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == ':' or body[j] == '\n' or body[j] == '\r')) : (j += 1) {}
    if (j >= body.len or body[j] != '"') return null;
    const start = j + 1;
    const end = indexOfFrom(body, "\"", start) orelse return null;
    return .{ .start = start, .end = end };
}

fn keyIndexFrom(body: []const u8, key: []const u8, from: usize) ?usize {
    return indexOfFrom(body, key, from);
}

/// Strip the scheme+authority from a ws:// URL, leaving the path.
fn wsUrlPath(url: []const u8, out: []u8) ?[]const u8 {
    var i: usize = 0;
    // skip "ws://" or "wss://"
    if (startsWith(url, "ws://")) i = 5 else if (startsWith(url, "wss://")) i = 6;
    // skip authority up to the first '/'
    while (i < url.len and url[i] != '/') : (i += 1) {}
    if (i >= url.len) return null;
    const path = url[i..];
    if (path.len > out.len) return null;
    @memcpy(out[0..path.len], path);
    return out[0..path.len];
}

/// Extract result.result.value (a JSON string) from a Runtime.evaluate reply,
/// unescaping JSON string escapes into `out`.
fn extractResultValue(reply: []const u8, out: []u8) ?[]const u8 {
    // Find the "value":" that lives inside "result":{...}. The reply shape is
    // {"id":N,"result":{"result":{"type":"string","value":"...."}}}.
    const rk = "\"value\":\"";
    const start = indexOf(reply, rk) orelse return null;
    var i = start + rk.len;
    var n: usize = 0;
    while (i < reply.len) {
        const c = reply[i];
        if (c == '\\') {
            i += 1;
            if (i >= reply.len) break;
            const e = reply[i];
            const decoded: u8 = switch (e) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 8,
                'f' => 12,
                'u' => {
                    // \uXXXX escape. Decode the 16-bit unit; if it is a UTF-16
                    // high surrogate followed by "\uXXXX" low surrogate, combine
                    // the pair into the real (astral) code point so we emit
                    // valid UTF-8 rather than two invalid surrogate byte runs
                    // (which would produce malformed UTF-8, e.g. for emoji).
                    if (i + 4 >= reply.len) break;
                    var cp: u32 = hex4(reply[i + 1 .. i + 5]) orelse break;
                    i += 4; // now at last hex digit
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        // Expect a following \uXXXX low surrogate.
                        if (i + 6 < reply.len and reply[i + 1] == '\\' and reply[i + 2] == 'u') {
                            if (hex4(reply[i + 3 .. i + 7])) |lo| {
                                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                    i += 6; // consume the \uXXXX low half
                                }
                            }
                        }
                    }
                    n += utf8EncodeCp(cp, out[n..]) orelse break;
                    i += 1;
                    continue;
                },
                else => e,
            };
            if (n >= out.len) return null;
            out[n] = decoded;
            n += 1;
            i += 1;
            continue;
        }
        if (c == '"') break; // end of the JSON string value
        if (n >= out.len) return null;
        out[n] = c;
        n += 1;
        i += 1;
    }
    return out[0..n];
}

fn hex4(s: []const u8) ?u32 {
    if (s.len < 4) return null;
    var v: u32 = 0;
    for (s[0..4]) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = v * 16 + d;
    }
    return v;
}

/// Encode a Unicode code point (U+0000..U+10FFFF) as UTF-8 into dest; returns
/// bytes written, or null on a too-small buffer. A lone surrogate (which is not
/// a valid scalar value) is emitted as U+FFFD so output stays valid UTF-8.
fn utf8EncodeCp(cp_in: u32, dest: []u8) ?usize {
    var cp = cp_in;
    if (cp >= 0xD800 and cp <= 0xDFFF) cp = 0xFFFD; // lone surrogate → replacement
    if (cp < 0x80) {
        if (dest.len < 1) return null;
        dest[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        if (dest.len < 2) return null;
        dest[0] = @intCast(0xC0 | (cp >> 6));
        dest[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        if (dest.len < 3) return null;
        dest[0] = @intCast(0xE0 | (cp >> 12));
        dest[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dest[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        if (dest.len < 4) return null;
        dest[0] = @intCast(0xF0 | (cp >> 18));
        dest[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        dest[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dest[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

// ── tiny JSON request builder (no alloc) ──

const Builder = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    fn raw(self: *Builder, s: []const u8) void {
        for (s) |c| self.byte(c);
    }
    fn num(self: *Builder, v: u32) void {
        self.num64(v);
    }
    fn num64(self: *Builder, v: u64) void {
        if (v == 0) {
            self.byte('0');
            return;
        }
        var digits: [20]u8 = undefined;
        var k: usize = 0;
        var x = v;
        while (x > 0) : (x /= 10) {
            digits[k] = @intCast('0' + (x % 10));
            k += 1;
        }
        while (k > 0) {
            k -= 1;
            self.byte(digits[k]);
        }
    }
    fn escaped(self: *Builder, s: []const u8) void {
        for (s) |c| switch (c) {
            '"' => self.raw("\\\""),
            '\\' => self.raw("\\\\"),
            '\n' => self.raw("\\n"),
            '\r' => self.raw("\\r"),
            '\t' => self.raw("\\t"),
            else => self.byte(c),
        };
    }
    fn byte(self: *Builder, c: u8) void {
        if (self.len >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.len] = c;
        self.len += 1;
    }
    fn slice(self: *const Builder) []const u8 {
        return self.buf[0..self.len];
    }
};

// ── misc helpers ──

fn sleepMs(io: std.Io, ms: u32) void {
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

/// A per-launch unique number (milliseconds since the monotonic epoch) used to
/// give each headless run its own throwaway profile directory.
fn uniqueSuffix(io: std.Io) u64 {
    const ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    return @intCast(@max(0, ms));
}

/// Build an ABSOLUTE, unique profile directory: "<name>-<suffix>" if `name` is
/// already absolute, else "<cwd><sep><name>-<suffix>". Chrome rejects a
/// relative --user-data-dir, so this must always yield an absolute path.
fn absProfileDir(io: std.Io, name: []const u8, suffix: u64, out: []u8) []const u8 {
    var b = Builder{ .buf = out };
    if (isAbsolute(name)) {
        b.raw(name);
    } else {
        var cwd_buf: [768]u8 = undefined;
        const n = std.process.currentPath(io, &cwd_buf) catch 0;
        if (n > 0) {
            const dir = cwd_buf[0..n];
            b.raw(dir);
            b.byte(if (isWindowsPath(dir)) '\\' else '/');
        }
        b.raw(name);
    }
    b.byte('-');
    b.num64(suffix);
    if (b.overflow) return name; // fall back; caller path still tries
    return b.slice();
}

fn isAbsolute(p: []const u8) bool {
    if (p.len >= 1 and (p[0] == '/' or p[0] == '\\')) return true; // POSIX / UNC
    if (p.len >= 2 and p[1] == ':') return true; // Windows drive letter
    return false;
}

fn isWindowsPath(p: []const u8) bool {
    if (p.len >= 2 and p[1] == ':') return true;
    for (p) |c| {
        if (c == '\\') return true;
    }
    return false;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.mem.eql(u8, s[0..prefix.len], prefix);
}

fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return indexOfFrom(haystack, needle, 0);
}

fn indexOfFrom(haystack: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or from >= haystack.len or needle.len > haystack.len) return null;
    var i: usize = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Small fixed arena for formatted argv strings, like web_capture's.
const ArgStore = struct {
    buf: [1024]u8 = undefined,
    used: usize = 0,

    fn fmt(self: *ArgStore, comptime spec: []const u8, args: anytype) []const u8 {
        const remaining = self.buf[self.used..];
        const out = std.fmt.bufPrint(remaining, spec, args) catch return "";
        self.used += out.len;
        return out;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "wsUrlPath strips scheme and authority" {
    var out: [128]u8 = undefined;
    const p = wsUrlPath("ws://127.0.0.1:9222/devtools/page/ABC123", &out).?;
    try testing.expectEqualStrings("/devtools/page/ABC123", p);
}

test "extractWsPath finds a page target" {
    const body =
        \\[{"type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/XYZ"}]
    ;
    var out: [128]u8 = undefined;
    const p = extractWsPath(body, &out).?;
    try testing.expectEqualStrings("/devtools/page/XYZ", p);
}

test "extractWsPath skips non-page targets" {
    const body =
        \\[{"type":"service_worker","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/B"},{"type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/P"}]
    ;
    var out: [128]u8 = undefined;
    const p = extractWsPath(body, &out).?;
    try testing.expectEqualStrings("/devtools/page/P", p);
}

test "extractWsPath handles pretty-printed JSON with spaces" {
    // Chrome's real /json is pretty-printed: `"type": "page"` with a space
    // after the colon, and the page target comes after background_page ones.
    const body =
        \\[ {
        \\   "type": "background_page",
        \\   "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/BG"
        \\}, {
        \\   "type": "page",
        \\   "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/REAL"
        \\} ]
    ;
    var out: [128]u8 = undefined;
    const p = extractWsPath(body, &out).?;
    try testing.expectEqualStrings("/devtools/page/REAL", p);
}

test "extractResultValue unescapes a JSON string value" {
    const reply =
        \\{"id":3,"result":{"result":{"type":"string","value":"a\"b\nc"}}}
    ;
    var out: [64]u8 = undefined;
    const v = extractResultValue(reply, &out).?;
    try testing.expectEqualStrings("a\"b\nc", v);
}

test "extractResultValue combines a UTF-16 surrogate pair into valid UTF-8" {
    // 📐 U+1F4D0 arrives as the surrogate pair \uD83D\uDCD0; it must become the
    // 4-byte UTF-8 encoding F0 9F 93 90, not two invalid 3-byte runs.
    const reply =
        \\{"id":9,"result":{"result":{"type":"string","value":"x\uD83D\uDCD0y"}}}
    ;
    var out: [32]u8 = undefined;
    const v = extractResultValue(reply, &out).?;
    const expect = "x\u{1F4D0}y";
    try testing.expectEqualStrings(expect, v);
}

test "extractResultValue decodes a BMP \\u escape (Hebrew)" {
    // א U+05D0 → UTF-8 D7 90.
    const reply =
        \\{"id":1,"result":{"result":{"type":"string","value":"\u05D0"}}}
    ;
    var out: [16]u8 = undefined;
    const v = extractResultValue(reply, &out).?;
    try testing.expectEqualStrings("\u{05D0}", v);
}

test "Builder escapes and bounds" {
    var buf: [64]u8 = undefined;
    var b = Builder{ .buf = &buf };
    b.raw("{\"x\":\"");
    b.escaped("a\"b");
    b.raw("\"}");
    try testing.expect(!b.overflow);
    try testing.expectEqualStrings("{\"x\":\"a\\\"b\"}", b.slice());
}
