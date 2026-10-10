// @zpm/openrouter — LLM-over-HTTP client (OpenRouter chat), with a folded-in
// STT request helper and a generic ambient transcript/analysis mechanism.
//
// Reusable extract of the BizInSpace demo's `src/kernel/openrouter.sig` and
// `src/kernel/ambient.sig`. The demo made its HTTPS calls over the in-kernel
// `dns`/`tcp_ip`/`tls` modules and hardcoded a BizInSpace system prompt plus an
// `@embedFile`'d API key. Both are removed here:
//
//   - The system prompt and API key are CALLER-SUPPLIED parameters. The string
//     "BizInSpace" never appears in this module (asserted by the tests).
//   - All I/O crosses a pluggable `Transport` byte seam. The module imports no
//     nexus kernel module and no platform transport; who backs the Transport
//     (pure-Sig TLS on a host, a not-supported stub in the SB0 app) is the
//     caller's concern.
//
// zpm-vs-app ambient split (FR-3): the generic WAV framing, base64, STT HTTP
// request, rolling transcript window, and proactive pattern-match mechanism
// live here in `Stt`/`Ambient`. The audio DEVICE CAPTURE does NOT — it is
// nexus/ABI-specific (the demo read a kernel `audio` module) and stays in the
// app, which feeds raw PCM bytes into `Stt.transcribe`. The product pattern
// copy (company blurbs, agenda) is app data; `Ambient.analyze` operates on
// caller-supplied `Pattern` tables only.
//
// Allocation-free: static module buffers + fixed stack scratch, no heap.

// ── Transport seam ──────────────────────────────────────────────────────────

/// A new, module-local error set. The `ConnectFailed` name mirrors
/// `src/net/websocket.sig` for familiarity, but this is a distinct, larger
/// contract (the websocket Transport has no `connect`/DNS). Do NOT try to
/// `@import("websocket").Error`.
pub const TransportError = error{ ResolveFailed, ConnectFailed, IoFailed, Closed };

/// A connected, TLS-capable byte stream the caller provides. This module writes
/// the HTTP request and reads the response through these pointers; it never
/// imports `dns`, `tcp_ip`, `tls`, or any nexus kernel module.
pub const Transport = struct {
    ctx: *anyopaque,
    /// Resolve + connect + TLS handshake to `host:port` with SNI = host.
    connect: *const fn (ctx: *anyopaque, host: []const u8, port: u16) TransportError!void,
    writeAll: *const fn (ctx: *anyopaque, data: []const u8) TransportError!void,
    /// Returns >0 bytes read, or 0 on clean peer close. May spin internally.
    readSome: *const fn (ctx: *anyopaque, buf: []u8) TransportError!usize,
    close: *const fn (ctx: *anyopaque) void,
};

// ── Bounded buffers (demo sizes; override at comptime) ──────────────────────

pub const REQ_BYTES: usize = 12288;
pub const RESP_BYTES: usize = 32768;
pub const JSON_BYTES: usize = 8192;

pub const HOST = "openrouter.ai";
pub const DEFAULT_MODEL = "openai/gpt-oss-120b:free";

var req: [REQ_BYTES]u8 = .{0} ** REQ_BYTES;
var resp: [RESP_BYTES]u8 = .{0} ** RESP_BYTES;
var jbuf: [JSON_BYTES]u8 = .{0} ** JSON_BYTES;

// ── Conversation memory ─────────────────────────────────────────────────────

pub const MAXT: usize = 6; // 3 exchanges
pub const TURN_CAP: usize = 720;

/// Rolling conversation window. The caller owns the instance (static) and
/// passes `&history` into `chat`. `pushTurn` ring-shifts, dropping the oldest.
pub const History = struct {
    role: [MAXT]u8 = .{0} ** MAXT, // 0 = user, 1 = assistant
    txt: [MAXT][TURN_CAP]u8 = .{.{0} ** TURN_CAP} ** MAXT,
    len: [MAXT]usize = .{0} ** MAXT,
    n: usize = 0,

    pub fn reset(self: *History) void {
        self.n = 0;
    }

    pub fn pushTurn(self: *History, role: u8, text: []const u8) void {
        if (self.n >= MAXT) {
            var i: usize = 1;
            while (i < MAXT) : (i += 1) {
                self.role[i - 1] = self.role[i];
                self.len[i - 1] = self.len[i];
                for (0..self.len[i]) |k| self.txt[i - 1][k] = self.txt[i][k];
            }
            self.n = MAXT - 1;
        }
        const k = @min(text.len, TURN_CAP);
        for (0..k) |i| self.txt[self.n][i] = text[i];
        self.role[self.n] = role;
        self.len[self.n] = k;
        self.n += 1;
    }
};

// ── Small bounded JSON/text writer (demo `W`) ───────────────────────────────

const W = struct {
    buf: []u8,
    len: usize = 0,
    fn s(self: *W, x: []const u8) void {
        for (x) |b| {
            if (self.len < self.buf.len) {
                self.buf[self.len] = b;
                self.len += 1;
            }
        }
    }
    fn esc(self: *W, x: []const u8) void {
        for (x) |b| {
            if (b == '"') self.s("\\\"") else if (b == '\\') self.s("\\\\") else if (b == '\n') self.s("\\n") else if (b == '\r') {} else if (self.len < self.buf.len) {
                self.buf[self.len] = b;
                self.len += 1;
            }
        }
    }
    fn num(self: *W, v: usize) void {
        if (v == 0) {
            self.s("0");
            return;
        }
        var t: [16]u8 = undefined;
        var i: usize = 0;
        var n = v;
        while (n > 0) {
            t[i] = @intCast('0' + n % 10);
            n /= 10;
            i += 1;
        }
        while (i > 0) {
            i -= 1;
            const c = [1]u8{t[i]};
            self.s(&c);
        }
    }
};

// ── Chat ────────────────────────────────────────────────────────────────────

pub const ChatOptions = struct {
    /// CALLER-SUPPLIED system prompt; never a module constant. MAY be empty.
    system: []const u8,
    model: []const u8 = DEFAULT_MODEL,
    /// CALLER-SUPPLIED; never `@embedFile`'d here. MUST be non-empty.
    api_key: []const u8,
    /// MUST be non-empty.
    prompt: []const u8,
    history: ?*History = null,
    max_tokens: u32 = 700,
};

/// Ask the model; write the assistant's reply into `out`, return its length.
/// Preserves the demo's patient read + single retry and, when `history` is
/// given, records the exchange for follow-ups.
///
/// Validation: if `api_key` or `prompt` is empty, returns 0 immediately WITHOUT
/// touching the transport (no malformed request is assembled or sent). `system`
/// may be empty. A failed `connect` also yields 0 (the app keeps its prior UI).
pub fn chat(t: *const Transport, opt: ChatOptions, out: []u8) usize {
    if (opt.api_key.len == 0 or opt.prompt.len == 0) return 0;
    if (out.len == 0) return 0;
    var attempt: u32 = 0;
    while (attempt < 2) : (attempt += 1) {
        const n = chatOnce(t, opt, out);
        if (n > 0) {
            if (opt.history) |h| {
                h.pushTurn(0, opt.prompt);
                h.pushTurn(1, out[0..n]);
            }
            return n;
        }
    }
    return 0;
}

fn chatOnce(t: *const Transport, opt: ChatOptions, out: []u8) usize {
    t.connect(t.ctx, HOST, 443) catch return 0;
    defer t.close(t.ctx);

    // Build the messages array: system, recent history, then the new prompt.
    var jw = W{ .buf = jbuf[0..] };
    jw.s("{\"model\":\"");
    jw.s(opt.model);
    jw.s("\",\"messages\":[{\"role\":\"system\",\"content\":\"");
    jw.esc(opt.system);
    jw.s("\"}");
    if (opt.history) |h| {
        var tt: usize = 0;
        while (tt < h.n) : (tt += 1) {
            jw.s(",{\"role\":\"");
            jw.s(if (h.role[tt] == 1) "assistant" else "user");
            jw.s("\",\"content\":\"");
            jw.esc(h.txt[tt][0..h.len[tt]]);
            jw.s("\"}");
        }
    }
    jw.s(",{\"role\":\"user\",\"content\":\"");
    jw.esc(opt.prompt);
    jw.s("\"}],\"max_tokens\":");
    jw.num(opt.max_tokens);
    jw.s("}");

    var rw = W{ .buf = req[0..] };
    rw.s("POST /api/v1/chat/completions HTTP/1.1\r\nHost: ");
    rw.s(HOST);
    rw.s("\r\nAuthorization: Bearer ");
    rw.s(opt.api_key);
    rw.s("\r\nContent-Type: application/json\r\nContent-Length: ");
    rw.num(jw.len);
    rw.s("\r\nX-Title: zpm-openrouter\r\nConnection: close\r\n\r\n");
    rw.s(jbuf[0..jw.len]);
    t.writeAll(t.ctx, req[0..rw.len]) catch return 0;

    // Patient read: keep reading until the reply is complete or the peer closes.
    var total: usize = 0;
    while (total < resp.len - 256) {
        const n = t.readSome(t.ctx, resp[total..]) catch break;
        if (n == 0) break; // clean close
        total += n;
        if (replyComplete(resp[0..total])) break;
    }
    return extractContent(resp[0..total], out);
}

/// True once the response contains a complete `"content":"..."` value.
pub fn replyComplete(data: []const u8) bool {
    const key = "\"content\":\"";
    if (data.len < key.len) return false;
    var i: usize = 0;
    while (i + key.len < data.len) : (i += 1) {
        var m = true;
        for (0..key.len) |k| {
            if (data[i + k] != key[k]) {
                m = false;
                break;
            }
        }
        if (!m) continue;
        var j = i + key.len;
        while (j < data.len) {
            if (data[j] == '\\') {
                j += 2;
                continue;
            }
            if (data[j] == '"') return true;
            j += 1;
        }
        return false;
    }
    return false;
}

/// Extract and unescape the assistant content into `out`; return its length.
pub fn extractContent(data: []const u8, out: []u8) usize {
    const key = "\"content\":\"";
    if (data.len < key.len) return 0;
    var i: usize = 0;
    while (i + key.len < data.len) : (i += 1) {
        var m = true;
        for (0..key.len) |k| {
            if (data[i + k] != key[k]) {
                m = false;
                break;
            }
        }
        if (!m) continue;
        var j = i + key.len;
        var o: usize = 0;
        while (j < data.len and o < out.len) {
            const c = data[j];
            if (c == '\\' and j + 1 < data.len) {
                const e = data[j + 1];
                out[o] = if (e == 'n') '\n' else if (e == '"') '"' else if (e == '\\') '\\' else e;
                o += 1;
                j += 2;
                continue;
            }
            if (c == '"') break;
            out[o] = c;
            o += 1;
            j += 1;
        }
        return o;
    }
    return 0;
}

// ── STT (folded) ─────────────────────────────────────────────────────────────
//
// The STT request is the same chat-style HTTPS POST over the same Transport
// seam, differing only in path (/api/v1/audio/transcriptions) and the "text"
// extraction. The DEVICE CAPTURE is NOT here — the caller passes raw PCM bytes.

pub const Stt = struct {
    pub const SAMPLE_RATE: u32 = 16000;
    pub const CHANNELS: u32 = 1;
    pub const BITS: u32 = 16;

    const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    fn writeU32LE(buf: []u8, val: u32) void {
        buf[0] = @intCast(val & 0xFF);
        buf[1] = @intCast((val >> 8) & 0xFF);
        buf[2] = @intCast((val >> 16) & 0xFF);
        buf[3] = @intCast((val >> 24) & 0xFF);
    }
    fn writeU16LE(buf: []u8, val: u16) void {
        buf[0] = @intCast(val & 0xFF);
        buf[1] = @intCast((val >> 8) & 0xFF);
    }

    /// Write a 44-byte RIFF/WAVE/fmt/data header for `data_len` PCM bytes.
    pub fn writeWavHeader(buf: []u8, data_len: u32) void {
        buf[0] = 'R';
        buf[1] = 'I';
        buf[2] = 'F';
        buf[3] = 'F';
        writeU32LE(buf[4..8], data_len + 36);
        buf[8] = 'W';
        buf[9] = 'A';
        buf[10] = 'V';
        buf[11] = 'E';
        buf[12] = 'f';
        buf[13] = 'm';
        buf[14] = 't';
        buf[15] = ' ';
        writeU32LE(buf[16..20], 16);
        writeU16LE(buf[20..22], 1);
        writeU16LE(buf[22..24], @intCast(CHANNELS));
        writeU32LE(buf[24..28], SAMPLE_RATE);
        writeU32LE(buf[28..32], SAMPLE_RATE * CHANNELS * (BITS / 8));
        writeU16LE(buf[32..34], @intCast(CHANNELS * (BITS / 8)));
        writeU16LE(buf[34..36], @intCast(BITS));
        buf[36] = 'd';
        buf[37] = 'a';
        buf[38] = 't';
        buf[39] = 'a';
        writeU32LE(buf[40..44], data_len);
    }

    /// RFC-4648 base64; returns bytes written. Truncates on a full `dst`.
    pub fn base64Encode(src: []const u8, dst: []u8) usize {
        var o: usize = 0;
        var i: usize = 0;
        while (i + 2 < src.len) {
            if (o + 3 >= dst.len) break;
            const a: u32 = src[i];
            const b: u32 = src[i + 1];
            const c: u32 = src[i + 2];
            const v = (a << 16) | (b << 8) | c;
            dst[o] = B64[(v >> 18) & 0x3F];
            dst[o + 1] = B64[(v >> 12) & 0x3F];
            dst[o + 2] = B64[(v >> 6) & 0x3F];
            dst[o + 3] = B64[v & 0x3F];
            o += 4;
            i += 3;
        }
        if (i < src.len and o + 3 < dst.len) {
            const rem = src.len - i;
            const a: u32 = src[i];
            const b: u32 = if (rem > 1) src[i + 1] else 0;
            const v = (a << 16) | (b << 8);
            dst[o] = B64[(v >> 18) & 0x3F];
            dst[o + 1] = B64[(v >> 12) & 0x3F];
            if (rem > 1) {
                dst[o + 2] = B64[(v >> 6) & 0x3F];
                dst[o + 3] = '=';
            } else {
                dst[o + 2] = '=';
                dst[o + 3] = '=';
            }
            o += 4;
        }
        return o;
    }

    /// Build + send the audio/transcriptions POST through `t`; extract "text"
    /// into `out`, returning its length. Same non-empty preconditions as chat:
    /// empty `api_key`/`model`/`pcm` returns 0 without touching the transport.
    /// Caller supplies scratch `wav` (>= pcm.len + 44), `b64`, and `request`.
    pub fn transcribe(
        t: *const Transport,
        api_key: []const u8,
        model: []const u8,
        pcm: []const u8,
        wav: []u8,
        b64: []u8,
        request: []u8,
        out: []u8,
    ) usize {
        if (api_key.len == 0 or model.len == 0 or pcm.len == 0) return 0;
        if (out.len == 0) return 0;
        if (wav.len < pcm.len + 44) return 0;

        writeWavHeader(wav[0..44], @intCast(pcm.len));
        for (0..pcm.len) |i| wav[44 + i] = pcm[i];
        const b64_len = base64Encode(wav[0 .. 44 + pcm.len], b64);

        // JSON body: {"model":"...","file":"data:audio/wav;base64,<data>"}
        var jw = W{ .buf = jbuf[0..] };
        jw.s("{\"model\":\"");
        jw.s(model);
        jw.s("\",\"file\":\"data:audio/wav;base64,");
        jw.s(b64[0..b64_len]);
        jw.s("\"}");

        var rw = W{ .buf = request };
        rw.s("POST /api/v1/audio/transcriptions HTTP/1.1\r\nHost: ");
        rw.s(HOST);
        rw.s("\r\nAuthorization: Bearer ");
        rw.s(api_key);
        rw.s("\r\nContent-Type: application/json\r\nContent-Length: ");
        rw.num(jw.len);
        rw.s("\r\nConnection: close\r\n\r\n");
        rw.s(jbuf[0..jw.len]);

        t.connect(t.ctx, HOST, 443) catch return 0;
        defer t.close(t.ctx);
        t.writeAll(t.ctx, request[0..rw.len]) catch return 0;

        var total: usize = 0;
        while (total < resp.len - 64) {
            const n = t.readSome(t.ctx, resp[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        return extractText(resp[0..total], out);
    }

    /// Extract and unescape the `"text":"..."` value into `out`.
    pub fn extractText(data: []const u8, out: []u8) usize {
        const key = "\"text\":\"";
        if (data.len < key.len) return 0;
        var i: usize = 0;
        while (i + key.len < data.len) : (i += 1) {
            var m = true;
            for (0..key.len) |k| {
                if (data[i + k] != key[k]) {
                    m = false;
                    break;
                }
            }
            if (!m) continue;
            var j = i + key.len;
            var o: usize = 0;
            while (j < data.len and o < out.len) {
                const c = data[j];
                if (c == '\\' and j + 1 < data.len) {
                    const e = data[j + 1];
                    out[o] = if (e == 'n') '\n' else if (e == '"') '"' else if (e == '\\') '\\' else e;
                    o += 1;
                    j += 2;
                    continue;
                }
                if (c == '"') break;
                out[o] = c;
                o += 1;
                j += 1;
            }
            return o;
        }
        return 0;
    }
};

// ── Ambient (folded) ─────────────────────────────────────────────────────────
//
// Rolling transcript window + proactive pattern analysis. OFF by default
// (`listening = false`); nothing analyzes until the app calls `setListening`.
// `analyze` operates on CALLER-SUPPLIED pattern tables — the product copy is
// app data, not a module constant.

/// A proactive rule: if any needle appears (case-insensitive) in the latest
/// transcript, surface `response`.
pub const Pattern = struct {
    needles: []const []const u8,
    response: []const u8,
};

pub const Ambient = struct {
    transcript: [2048]u8 = .{0} ** 2048,
    transcript_len: usize = 0,
    last: [256]u8 = .{0} ** 256,
    last_len: usize = 0,
    proactive: [512]u8 = .{0} ** 512,
    proactive_len: usize = 0,
    proactive_timer: u32 = 0,
    listening: bool = false, // OFF by default (AC-9 / NFR)

    pub fn setListening(self: *Ambient, active: bool) void {
        self.listening = active;
    }
    pub fn isListening(self: *const Ambient) bool {
        return self.listening;
    }

    /// Append `text` to the rolling 2KB window; on overflow keep the last 1024
    /// bytes (demo `appendTranscript`). Also records `text` as the latest.
    pub fn appendTranscript(self: *Ambient, text: []const u8) void {
        const tlen = @min(text.len, self.last.len);
        for (0..tlen) |i| self.last[i] = text[i];
        self.last_len = tlen;

        if (self.transcript_len + text.len + 2 > 2048) {
            const keep: usize = 1024;
            const start = self.transcript_len - keep;
            for (0..keep) |i| self.transcript[i] = self.transcript[start + i];
            self.transcript_len = keep;
        }
        if (self.transcript_len > 0 and self.transcript_len < 2048) {
            self.transcript[self.transcript_len] = ' ';
            self.transcript_len += 1;
        }
        const add = @min(text.len, 2048 - self.transcript_len);
        for (0..add) |i| self.transcript[self.transcript_len + i] = text[i];
        self.transcript_len += add;
    }

    pub fn poll(self: *const Ambient) []const u8 {
        return self.last[0..self.last_len];
    }
    pub fn getProactive(self: *const Ambient) []const u8 {
        return self.proactive[0..self.proactive_len];
    }
    pub fn tickTimer(self: *Ambient) void {
        if (self.proactive_timer > 0) self.proactive_timer -= 1;
    }

    fn setProactive(self: *Ambient, msg: []const u8) void {
        const n = @min(msg.len, self.proactive.len);
        for (0..n) |i| self.proactive[i] = msg[i];
        self.proactive_len = n;
        self.proactive_timer = 360; // ~12 seconds at 30fps
    }

    /// Run caller-supplied patterns against the latest transcript; the first
    /// matching pattern's `response` is surfaced. No-op while not listening.
    pub fn analyze(self: *Ambient, patterns: []const Pattern) void {
        if (!self.listening) return;
        const last = self.last[0..self.last_len];
        for (patterns) |p| {
            for (p.needles) |needle| {
                if (contains(last, needle)) {
                    self.setProactive(p.response);
                    return;
                }
            }
        }
    }
};

/// Case-insensitive substring search (demo `contains`).
pub fn contains(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (text.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        var m = true;
        for (0..needle.len) |j| {
            const tc = if (text[i + j] >= 'A' and text[i + j] <= 'Z') text[i + j] + 32 else text[i + j];
            const nc = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (tc != nc) {
                m = false;
                break;
            }
        }
        if (m) return true;
    }
    return false;
}

// ── Hermetic tests (MockTransport; records writes, replays canned bytes) ─────

const MockTransport = struct {
    written: [65536]u8 = undefined,
    written_len: usize = 0,
    connected: bool = false,
    canned: []const u8 = &[_]u8{},
    read_pos: usize = 0,
    fail_connect: bool = false,

    fn transport(self: *MockTransport) Transport {
        return .{
            .ctx = @ptrCast(self),
            .connect = mConnect,
            .writeAll = mWrite,
            .readSome = mRead,
            .close = mClose,
        };
    }

    fn mConnect(ctx: *anyopaque, host: []const u8, port: u16) TransportError!void {
        _ = host;
        _ = port;
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        if (self.fail_connect) return TransportError.ConnectFailed;
        self.connected = true;
    }
    fn mWrite(ctx: *anyopaque, data: []const u8) TransportError!void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        for (data) |b| {
            if (self.written_len < self.written.len) {
                self.written[self.written_len] = b;
                self.written_len += 1;
            }
        }
    }
    fn mRead(ctx: *anyopaque, buf: []u8) TransportError!usize {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        if (self.read_pos >= self.canned.len) return 0;
        const n = @min(buf.len, self.canned.len - self.read_pos);
        for (0..n) |i| buf[i] = self.canned[self.read_pos + i];
        self.read_pos += n;
        return n;
    }
    fn mClose(ctx: *anyopaque) void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.connected = false;
    }

    fn wrote(self: *const MockTransport) []const u8 {
        return self.written[0..self.written_len];
    }
};

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "openrouter chat request carries caller system/model + bearer, never BizInSpace" {
    var mock = MockTransport{};
    mock.canned = "HTTP/1.1 200 OK\r\n\r\n{\"choices\":[{\"message\":{\"content\":\"TITLE Hi\"}}]}";
    const t = mock.transport();
    var buf: [512]u8 = undefined;
    const n = chat(&t, .{
        .system = "You are a generic concierge.",
        .model = "test/model",
        .api_key = "sk-test-key",
        .prompt = "hello",
    }, &buf);
    try expect(n > 0);
    const body = mock.wrote();
    try expect(contains(body, "\"role\":\"system\",\"content\":\"You are a generic concierge.\""));
    try expect(contains(body, "test/model"));
    try expect(contains(body, "Authorization: Bearer sk-test-key"));
    try expect(!contains(body, "BizInSpace"));
    try expect(eqSlice(buf[0..n], "TITLE Hi"));
}

test "openrouter chat empty api_key or prompt returns 0 without touching transport" {
    var mock = MockTransport{};
    mock.canned = "irrelevant";
    const t = mock.transport();
    var buf: [64]u8 = undefined;
    try expectEqual(@as(usize, 0), chat(&t, .{ .system = "s", .api_key = "", .prompt = "p" }, &buf));
    try expectEqual(@as(usize, 0), chat(&t, .{ .system = "s", .api_key = "k", .prompt = "" }, &buf));
    try expect(!mock.connected);
    try expectEqual(@as(usize, 0), mock.written_len);
}

test "openrouter chat empty system is allowed" {
    var mock = MockTransport{};
    mock.canned = "{\"content\":\"ok\"}";
    const t = mock.transport();
    var buf: [64]u8 = undefined;
    const n = chat(&t, .{ .system = "", .api_key = "k", .prompt = "p" }, &buf);
    try expect(n > 0);
    try expect(contains(mock.wrote(), "\"role\":\"system\",\"content\":\"\""));
}

test "openrouter extractContent unescapes" {
    var out: [64]u8 = undefined;
    const data = "{\"content\":\"a\\nb\\\"c\\\\d\"}";
    const n = extractContent(data, &out);
    try expect(eqSlice(out[0..n], "a\nb\"c\\d"));
}

test "openrouter replyComplete false before closing quote, true after" {
    try expect(!replyComplete("{\"content\":\"partial"));
    try expect(replyComplete("{\"content\":\"done\"}"));
}

test "openrouter History ring-shift drops oldest after MAXT" {
    var h = History{};
    var i: usize = 0;
    while (i < MAXT + 2) : (i += 1) {
        const one = [_]u8{@intCast('a' + i)};
        h.pushTurn(0, &one);
    }
    try expectEqual(MAXT, h.n);
    // After pushing MAXT+2 turns 'a'..., the oldest kept is index 2 ('c').
    try expectEqual(@as(u8, 'c'), h.txt[0][0]);
    h.reset();
    try expectEqual(@as(usize, 0), h.n);
}

test "openrouter Stt writeWavHeader byte-exact fields" {
    var buf: [44]u8 = undefined;
    Stt.writeWavHeader(&buf, 32000);
    try expect(eqSlice(buf[0..4], "RIFF"));
    try expect(eqSlice(buf[8..12], "WAVE"));
    try expect(eqSlice(buf[12..16], "fmt "));
    try expect(eqSlice(buf[36..40], "data"));
    // RIFF size = data_len + 36 = 32036 (LE).
    try expectEqual(@as(u32, 32036), readU32LE(buf[4..8]));
    try expectEqual(@as(u16, 1), readU16LE(buf[20..22])); // PCM
    try expectEqual(@as(u16, 1), readU16LE(buf[22..24])); // mono
    try expectEqual(@as(u32, 16000), readU32LE(buf[24..28])); // sample rate
    try expectEqual(@as(u16, 16), readU16LE(buf[34..36])); // bits
    try expectEqual(@as(u32, 32000), readU32LE(buf[40..44])); // data_len
}

test "openrouter Stt base64Encode RFC-4648 vectors" {
    var out: [16]u8 = undefined;
    try expectEqual(@as(usize, 0), Stt.base64Encode("", &out));
    try expect(eqSlice(out[0..Stt.base64Encode("f", &out)], "Zg=="));
    try expect(eqSlice(out[0..Stt.base64Encode("fo", &out)], "Zm8="));
    try expect(eqSlice(out[0..Stt.base64Encode("foo", &out)], "Zm9v"));
    try expect(eqSlice(out[0..Stt.base64Encode("foob", &out)], "Zm9vYg=="));
}

test "openrouter Ambient off by default, no output while not listening" {
    var amb = Ambient{};
    try expect(!amb.isListening());
    amb.appendTranscript("someone said manufacturing numbers");
    const pats = [_]Pattern{.{ .needles = &[_][]const u8{"manufactur"}, .response = "PLAN" }};
    amb.analyze(&pats);
    try expectEqual(@as(usize, 0), amb.getProactive().len);
}

test "openrouter Ambient analyze fires matching pattern when listening" {
    var amb = Ambient{};
    amb.setListening(true);
    amb.appendTranscript("tell me about the Magic Leap team");
    const pats = [_]Pattern{
        .{ .needles = &[_][]const u8{"waveguide"}, .response = "OPTICS" },
        .{ .needles = &[_][]const u8{ "magic leap", "lumus" }, .response = "AR_CO" },
    };
    amb.analyze(&pats);
    try expect(eqSlice(amb.getProactive(), "AR_CO"));
    try expect(amb.proactive_timer > 0);
    amb.tickTimer();
    try expect(amb.proactive_timer == 359);
}

test "openrouter Ambient transcript window rolls over keeping last 1024" {
    var amb = Ambient{};
    amb.setListening(true);
    var big: [1500]u8 = .{'x'} ** 1500;
    amb.appendTranscript(&big);
    try expect(amb.transcript_len <= 2048);
    // Second large append forces the keep-last-1024 shift.
    big = .{'y'} ** 1500;
    amb.appendTranscript(&big);
    try expect(amb.transcript_len <= 2048);
}

fn eqSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
fn readU32LE(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}
fn readU16LE(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}
