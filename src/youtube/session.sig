// @zpm/youtube/session — Browser-like YouTube Session (Layer 1)
//
// Establishes a genuine, cookied YouTube visitor session in pure Sig — the
// missing piece that lets BotGuard's GenerateIT issue a NON-null integrity
// token (a headless Create->GenerateIT replay, even in real Chrome, returns
// [null,ttl,null,fallback]; the token is gated on a real visitor session).
//
// Flow (mirrors what a browser does on first load of youtube.com):
//   1. GET https://www.youtube.com/  with a Chrome UA and a fresh cookie jar.
//      -> Set-Cookie: VISITOR_INFO1_LIVE, YSC, __Secure-* , (maybe CONSENT).
//   2. Handle the EU consent interstitial if present (set CONSENT + retry).
//   3. Extract from the HTML:
//        - ytcfg VISITOR_DATA (the visitorData string)
//        - INNERTUBE_CONTEXT_CLIENT_VERSION (client version to echo)
//        - the homepage BotGuard challenge (window.ytAtN {...}.R.bgChallenge):
//            interpreterUrl, interpreterHash, program, globalName
//   4. Expose the jar + visitorData + challenge to the BotGuard flow so the VM
//      snapshot and GenerateIT run WITHIN this session (cookies + X-Goog-Visitor-Id).
//
// All HTTP goes through platform/http_session (persistent cookie jar).

const http = @import("../platform/http_session.sig");
const challenge = @import("botguard/challenge.sig");

extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
fn print(msg: []const u8) void {
    _ = WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg.ptr, @intCast(msg.len), null, null);
}
fn printNum(val: usize) void {
    var buf: [20]u8 = undefined;
    var v = val; var len: usize = 0;
    if (v == 0) { print("0"); return; }
    while (v > 0) : (len += 1) { buf[len] = @intCast((v % 10) + '0'); v /= 10; }
    var rev: [20]u8 = undefined;
    for (0..len) |i| rev[i] = buf[len - 1 - i];
    print(rev[0..len]);
}

// ── Session state ──

pub const Session = struct {
    jar: http.CookieJar = http.CookieJar.init(),
    visitor_data: [challenge.MAX_VISITOR_DATA]u8 = undefined,
    visitor_data_len: usize = 0,
    client_version: [32]u8 = undefined,
    client_version_len: usize = 0,
    bootstrapped: bool = false,

    pub fn init() Session {
        return .{ .jar = http.CookieJar.init() };
    }

    pub fn visitorData(self: *const Session) []const u8 {
        return self.visitor_data[0..self.visitor_data_len];
    }
    pub fn clientVersion(self: *const Session) []const u8 {
        return self.client_version[0..self.client_version_len];
    }
};

// ── Bootstrap ──

/// GET youtube.com, harvest cookies + visitorData + client version, and parse
/// the embedded BotGuard homepage challenge into `chal`. Returns true if we
/// obtained cookies and a usable visitorData (challenge is best-effort — some
/// homepage variants omit ytAtN, in which case the caller falls back to att/get
/// / Create using this session's cookies + visitorData).
pub fn bootstrap(sess: *Session, chal: *challenge.Challenge) bool {
    print("  [session] GET https://www.youtube.com/ ...\n");
    // A browser sends Accept/Accept-Language; include them so YouTube serves the
    // full desktop homepage (with ytcfg + ytAtN) rather than a minimal variant.
    const hdrs =
        "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n" ++
        "Accept-Language: en-US,en;q=0.9\r\n" ++
        "Sec-Fetch-Dest: document\r\nSec-Fetch-Mode: navigate\r\nSec-Fetch-Site: none\r\nSec-Fetch-User: ?1\r\nUpgrade-Insecure-Requests: 1\r\n";

    var resp = http.get("www.youtube.com", "/", &sess.jar, hdrs);
    print("  [session] status="); printNum(resp.status);
    print(" bytes="); printNum(resp.body.len);
    print(" cookies="); printNum(sess.jar.count()); print("\n");

    // EU consent interstitial: consent.youtube.com or a "CONSENT" bounce. If the
    // body looks like a consent page (or we got redirected there), set a
    // pre-consent cookie and retry — this is what "reject all"/"accept" does.
    if (isConsentPage(resp.body) or sess.jar.get("CONSENT") != null and startsWithPending(sess.jar.get("CONSENT").?)) {
        print("  [session] consent interstitial -> setting CONSENT and retrying\n");
        // A commonly-accepted consent cookie value form (YES+ with a random-ish
        // suffix). YouTube accepts a "YES+" prefix to bypass the interstitial.
        sess.jar.set("CONSENT", "YES+cb.20210328-17-p0.en+FX+000");
        sess.jar.set("SOCS", "CAI"); // "accept" state
        resp = http.get("www.youtube.com", "/", &sess.jar, hdrs);
        print("  [session] retry status="); printNum(resp.status);
        print(" bytes="); printNum(resp.body.len);
        print(" cookies="); printNum(sess.jar.count()); print("\n");
    }

    if (resp.body.len == 0) return false;

    // Extract visitorData + client version from ytcfg.
    extractVisitorData(resp.body, sess);
    extractClientVersion(resp.body, sess);
    print("  [session] visitorData="); printNum(sess.visitor_data_len);
    print(" clientVersion='"); print(sess.clientVersion()); print("'\n");

    // Parse the embedded homepage BotGuard challenge (window.ytAtN {...}).
    const got_challenge = parseHomepageChallenge(resp.body, chal);
    print("  [session] homepage challenge="); print(if (got_challenge) "YES" else "no");
    if (got_challenge) {
        print(" program="); printNum(chal.program_len);
        print(" global='"); print(chal.global_name[0..chal.global_name_len]); print("'");
        print(" script="); printNum(chal.script_len);
        print(" url="); printNum(chal.interpreter_url_len);
    }
    print("\n");

    // Copy visitorData into the challenge too (used for session-bound minting).
    if (sess.visitor_data_len > 0 and chal.visitor_data_len == 0) {
        @memcpy(chal.visitor_data[0..sess.visitor_data_len], sess.visitor_data[0..sess.visitor_data_len]);
        chal.visitor_data_len = sess.visitor_data_len;
    }

    sess.bootstrapped = sess.jar.count() > 0 or sess.visitor_data_len > 0;
    return sess.bootstrapped;
}

// ── HTML/JSON extraction ──

fn isConsentPage(body: []const u8) bool {
    return findStr(body, "consent.youtube.com") != null or
        findStr(body, "consent.google.com") != null or
        (findStr(body, "Before you continue") != null and findStr(body, "cookies") != null);
}

fn startsWithPending(v: []const u8) bool {
    return v.len >= 7 and eqb(v[0..7], "PENDING");
}

/// visitorData lives in ytcfg as "VISITOR_DATA":"<b64url>" (and also inside
/// responseContext). Pull the ytcfg one.
fn extractVisitorData(body: []const u8, sess: *Session) void {
    if (findStrVal(body, "\"VISITOR_DATA\"")) |vd| {
        if (vd.len > sess.visitor_data.len) { sess.visitor_data_len = 0; return; }
        const n = vd.len;
        @memcpy(sess.visitor_data[0..n], vd[0..n]);
        sess.visitor_data_len = n;
        return;
    }
    // Fallback: some pages only carry "visitorData" (camelCase).
    if (findStrVal(body, "\"visitorData\"")) |vd| {
        if (vd.len > sess.visitor_data.len) { sess.visitor_data_len = 0; return; }
        const n = vd.len;
        @memcpy(sess.visitor_data[0..n], vd[0..n]);
        sess.visitor_data_len = n;
    }
}

fn extractClientVersion(body: []const u8, sess: *Session) void {
    if (findStrVal(body, "\"INNERTUBE_CONTEXT_CLIENT_VERSION\"")) |cv| {
        const n = @min(cv.len, 32);
        @memcpy(sess.client_version[0..n], cv[0..n]);
        sess.client_version_len = n;
    }
}

/// Parse the homepage BotGuard challenge from `window.ytAtN({...})` (or the
/// modern `botguardData` blob). The argument object has an `R` field that is a
/// hex/JSON-escaped JSON string whose `.bgChallenge` holds:
///   interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue
///   interpreterHash, program, globalName
/// We locate `bgChallenge` anywhere in the HTML (it may appear unescaped in the
/// ytInitialData/ytcfg region) and extract the fields with the same helpers
/// challenge.sig uses for att/get.
fn parseHomepageChallenge(body: []const u8, chal: *challenge.Challenge) bool {
    // Find a "bgChallenge" region. Search from there so keys resolve to the
    // challenge's own values.
    const bg_pos = findStr(body, "bgChallenge") orelse return false;
    const region = body[bg_pos..@min(bg_pos + 200000, body.len)];

    // program (base64) — may be escaped (\u0026 etc are rare in base64).
    if (findStrVal(region, "\"program\"")) |prog| {
        // Homepage program is sometimes JSON-escaped; unescape into buffer.
        chal.program_len = jsonUnescape(prog, chal.program[0..]);
    }
    if (findStrVal(region, "\"globalName\"")) |gn| {
        const glen = @min(gn.len, 32);
        @memcpy(chal.global_name[0..glen], gn[0..glen]);
        chal.global_name_len = glen;
    }
    if (findStrVal(region, "\"interpreterHash\"")) |ih| {
        const hlen = @min(ih.len, 64);
        @memcpy(chal.interpreter_hash[0..hlen], ih[0..hlen]);
        chal.hash_len = hlen;
    }
    if (findStrVal(region, "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue")) |url_val| {
        // The URL may be escaped ("\/\/www.google.com\/...") — unescape.
        var tmp: [256]u8 = undefined;
        const un = jsonUnescape(url_val, tmp[0..]);
        const ulen = @min(un, 256);
        @memcpy(chal.interpreter_url[0..ulen], tmp[0..ulen]);
        chal.interpreter_url_len = ulen;
    }
    return chal.program_len > 0 and (chal.interpreter_url_len > 0 or chal.script_len > 0);
}

// ── Local copies of challenge.sig helpers (kept private to avoid a cyclic
//    dependency; identical semantics). ──

fn eqb(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}

fn findStr(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    for (0..hay.len - needle.len + 1) |i| {
        var ok = true;
        for (0..needle.len) |j| if (hay[i + j] != needle[j]) { ok = false; break; };
        if (ok) return i;
    }
    return null;
}

fn findStrVal(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = findStr(data, key) orelse return null;
    var i = pos + key.len;
    if (i < data.len and data[i] == '"') i += 1;
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len or data[i] != ':') return null;
    i += 1;
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len or data[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < data.len and data[i] != '"') : (i += 1) {
        if (data[i] == '\\' and i + 1 < data.len) i += 1;
    }
    if (i > start) return data[start..i];
    return data[start..start];
}

fn jsonUnescape(s: []const u8, out: []u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len and o < out.len) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) { out[o] = c; o += 1; i += 1; continue; }
        const e = s[i + 1];
        i += 2;
        switch (e) {
            'n' => { out[o] = '\n'; o += 1; },
            'r' => { out[o] = '\r'; o += 1; },
            't' => { out[o] = '\t'; o += 1; },
            'b' => { out[o] = 8; o += 1; },
            'f' => { out[o] = 12; o += 1; },
            '"' => { out[o] = '"'; o += 1; },
            '\\' => { out[o] = '\\'; o += 1; },
            '/' => { out[o] = '/'; o += 1; },
            'u' => {
                if (i + 4 <= s.len) {
                    const cp: u32 = (@as(u32, hexNib(s[i])) << 12) | (@as(u32, hexNib(s[i + 1])) << 8) |
                        (@as(u32, hexNib(s[i + 2])) << 4) | @as(u32, hexNib(s[i + 3]));
                    i += 4;
                    if (cp < 0x80) { out[o] = @intCast(cp); o += 1; }
                    else if (cp < 0x800) {
                        if (o + 1 < out.len) { out[o] = @intCast(0xC0 | (cp >> 6)); out[o + 1] = @intCast(0x80 | (cp & 0x3F)); o += 2; }
                    } else {
                        if (o + 2 < out.len) { out[o] = @intCast(0xE0 | (cp >> 12)); out[o + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F)); out[o + 2] = @intCast(0x80 | (cp & 0x3F)); o += 3; }
                    }
                }
            },
            else => { out[o] = e; o += 1; },
        }
    }
    return o;
}

fn hexNib(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

// ── Session-bound BotGuard challenge + GenerateIT ──
//
// The critical difference from the headless flow: the att/get challenge and the
// GenerateIT exchange are performed THROUGH the cookied session (Cookie header +
// X-Goog-Visitor-Id), so Google issues the challenge against, and binds the
// integrity token to, our genuine visitor session — yielding a NON-null token.

const jsvm = @import("botguard/jsvm/root.sig");

const WEB_API_KEY: []const u8 = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";
const YT_REQUEST_KEY: []const u8 = "O43z0dpjhgX20SCx4KAo";
const WAA_API_KEY: []const u8 = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw";

// Result of establishing a session-bound integrity token.
pub const IntegrityResult = struct {
    integrity_token: [512]u8 = undefined,
    integrity_token_len: usize = 0,
    // The raw GenerateIT response (for diagnostics: [tok,ttl,thr,fallback]).
    minter_ready: bool = false, // webPoSignalOutput[0] populated
    valid: bool = false,
};

// Scratch for building request bodies + capturing the BG response.
var att_body_buf: [4096]u8 = undefined;
var git_body_buf: [131072]u8 = undefined;
var bg_response_buf: [65536]u8 = undefined;
var visitor_header_buf: [challenge.MAX_VISITOR_DATA + 32]u8 = undefined;

/// Build the `X-Goog-Visitor-Id: <visitorData>\r\n` header line into the module
/// buffer and return it (empty if no visitorData).
fn visitorHeader(sess: *const Session) []const u8 {
    if (sess.visitor_data_len == 0) return "";
    var p: usize = 0;
    const pre = "X-Goog-Visitor-Id: ";
    @memcpy(visitor_header_buf[p .. p + pre.len], pre); p += pre.len;
    @memcpy(visitor_header_buf[p .. p + sess.visitor_data_len], sess.visitor_data[0..sess.visitor_data_len]);
    p += sess.visitor_data_len;
    visitor_header_buf[p] = '\r'; p += 1; visitor_header_buf[p] = '\n'; p += 1;
    return visitor_header_buf[0..p];
}

/// Fetch the BotGuard challenge via InnerTube att/get, THROUGH the session
/// (cookies + visitor id). Populates `chal` (program, globalName, interpreterUrl,
/// visitorData). Returns true on success.
pub fn fetchChallengeInSession(sess: *Session, chal: *challenge.Challenge) bool {
    print("  [session] att/get (cookied) ...\n");

    // Body: engagementType UNBOUND + WEB client context, echoing our session's
    // client version so the challenge matches the visitor session.
    var bp: usize = 0;
    bp = appendS(&att_body_buf, bp, "{\"engagementType\":\"ENGAGEMENT_TYPE_UNBOUND\",\"context\":{\"client\":{\"clientName\":\"WEB\",\"clientVersion\":\"");
    if (sess.client_version_len > 0) {
        bp = appendS(&att_body_buf, bp, sess.clientVersion());
    } else {
        bp = appendS(&att_body_buf, bp, "2.20250312.04.00");
    }
    bp = appendS(&att_body_buf, bp, "\",\"hl\":\"en\",\"gl\":\"US\",\"visitorData\":\"");
    bp = appendS(&att_body_buf, bp, sess.visitorData());
    bp = appendS(&att_body_buf, bp, "\"}}}");

    var path_buf: [128]u8 = undefined;
    var pp: usize = 0;
    pp = appendS(&path_buf, pp, "/youtubei/v1/att/get?key=");
    pp = appendS(&path_buf, pp, WEB_API_KEY);
    pp = appendS(&path_buf, pp, "&prettyPrint=false");

    // Headers: Content-Type + Origin + visitor id (Cookie is added by the jar).
    var hdr_buf: [4096]u8 = undefined;
    var hp: usize = 0;
    hp = appendS(&hdr_buf, hp, "Content-Type: application/json\r\nOrigin: https://www.youtube.com\r\nReferer: https://www.youtube.com/\r\n");
    hp = appendS(&hdr_buf, hp, visitorHeader(sess));

    const resp = http.post("www.youtube.com", path_buf[0..pp], hdr_buf[0..hp], att_body_buf[0..bp], &sess.jar);
    print("  [session] att/get status="); printNum(resp.status);
    print(" bytes="); printNum(resp.body.len); print("\n");
    if (resp.body.len == 0) return false;

    return parseAttGetInto(resp.body, chal);
}

/// Parse an att/get JSON response into the challenge struct (program, globalName,
/// interpreterHash, interpreterUrl, visitorData).
fn parseAttGetInto(resp: []const u8, chal: *challenge.Challenge) bool {
    if (findStrVal(resp, "\"program\"")) |prog| {
        const plen = @min(prog.len, chal.program.len);
        @memcpy(chal.program[0..plen], prog[0..plen]);
        chal.program_len = plen;
    }
    if (findStrVal(resp, "\"globalName\"")) |gn| {
        const glen = @min(gn.len, 32);
        @memcpy(chal.global_name[0..glen], gn[0..glen]);
        chal.global_name_len = glen;
    }
    if (findStrVal(resp, "\"interpreterHash\"")) |ih| {
        const hlen = @min(ih.len, 64);
        @memcpy(chal.interpreter_hash[0..hlen], ih[0..hlen]);
        chal.hash_len = hlen;
    }
    if (findStrVal(resp, "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue")) |url_val| {
        var tmp: [256]u8 = undefined;
        const un = jsonUnescape(url_val, tmp[0..]);
        const ulen = @min(un, 256);
        @memcpy(chal.interpreter_url[0..ulen], tmp[0..ulen]);
        chal.interpreter_url_len = ulen;
    }
    if (findStrVal(resp, "\"visitorData\"")) |vd| {
        const vlen = @min(vd.len, chal.visitor_data.len);
        @memcpy(chal.visitor_data[0..vlen], vd[0..vlen]);
        chal.visitor_data_len = vlen;
    }
    return chal.program_len > 0 and (chal.interpreter_url_len > 0 or chal.script_len > 0);
}

/// Exchange a BotGuard response for an integrity token via GenerateIT, THROUGH
/// the session (cookies + visitor id). Parses [token, ttl, thr, fallback].
/// Public so callers (and validation harnesses) can relay a botguardResponse
/// produced elsewhere through the exact session plumbing.
pub fn generateITInSession(sess: *Session, bg_response: []const u8, out: *IntegrityResult) bool {
    print("  [session] GenerateIT (cookied) ...\n");

    var blen: usize = 0;
    const p1 = "[\"";
    @memcpy(git_body_buf[blen .. blen + p1.len], p1); blen += p1.len;
    @memcpy(git_body_buf[blen .. blen + YT_REQUEST_KEY.len], YT_REQUEST_KEY); blen += YT_REQUEST_KEY.len;
    const mid = "\",\"";
    @memcpy(git_body_buf[blen .. blen + mid.len], mid); blen += mid.len;
    // JSON-escape the BG response.
    for (bg_response) |c| {
        if (blen + 2 >= git_body_buf.len - 4) break;
        switch (c) {
            '"' => { git_body_buf[blen] = '\\'; blen += 1; git_body_buf[blen] = '"'; blen += 1; },
            '\\' => { git_body_buf[blen] = '\\'; blen += 1; git_body_buf[blen] = '\\'; blen += 1; },
            '\n' => { git_body_buf[blen] = '\\'; blen += 1; git_body_buf[blen] = 'n'; blen += 1; },
            else => { git_body_buf[blen] = c; blen += 1; },
        }
    }
    const p2 = "\"]";
    @memcpy(git_body_buf[blen .. blen + p2.len], p2); blen += p2.len;

    // Headers mirror what YouTube's OWN web player sends to the first-party
    // GenerateIT endpoint (captured via CDP): the WAA api key as X-Goog-Api-Key,
    // json+protobuf content type, sec-ch-ua client hints, Origin/Referer, and the
    // visitor id. Cookies are carried by the jar. This first-party endpoint
    // (www.youtube.com/api/jnn/v1/GenerateIT) returns a NON-null token for a
    // genuine session, unlike the jnn-pa.googleapis.com RPC used headless.
    var hdr_buf: [4096]u8 = undefined;
    var hp: usize = 0;
    hp = appendS(&hdr_buf, hp, "Content-Type: application/json+protobuf\r\nX-Goog-Api-Key: ");
    hp = appendS(&hdr_buf, hp, WAA_API_KEY);
    hp = appendS(&hdr_buf, hp, "\r\nOrigin: https://www.youtube.com\r\nReferer: https://www.youtube.com/\r\n");
    hp = appendS(&hdr_buf, hp, "sec-ch-ua: \"Google Chrome\";v=\"131\", \"Not_A Brand\";v=\"8\", \"Chromium\";v=\"131\"\r\nsec-ch-ua-mobile: ?0\r\nsec-ch-ua-platform: \"Windows\"\r\n");
    hp = appendS(&hdr_buf, hp, visitorHeader(sess));

    const resp = http.post("www.youtube.com", "/api/jnn/v1/GenerateIT", hdr_buf[0..hp], git_body_buf[0..blen], &sess.jar);
    print("  [session] GenerateIT status="); printNum(resp.status);
    print(" bytes="); printNum(resp.body.len); print("\n");
    if (resp.body.len > 0) {
        print("  [session] GenerateIT raw: ");
        print(resp.body[0..@min(resp.body.len, 400)]);
        print("\n");
    }
    if (resp.body.len == 0) return false;

    // Response is a JSON array: [integrityToken, ttl, mintRefreshThreshold,
    // websafeFallbackToken]. Element 0 is the REAL integrity token, or `null`
    // when the session isn't trusted enough (in which case only the fallback
    // string is present). We MUST read element 0 positionally, not just "the
    // first quoted string" (that would wrongly pick up the fallback).
    const r = resp.body;
    // Find outer '['.
    var i: usize = 0;
    while (i < r.len and r[i] != '[') : (i += 1) {}
    if (i >= r.len) return false;
    i += 1;
    // Skip whitespace.
    while (i < r.len and (r[i] == ' ' or r[i] == '\t' or r[i] == '\n' or r[i] == '\r')) : (i += 1) {}
    // Element 0: either `null` or a "quoted string".
    if (i + 4 <= r.len and r[i] == 'n' and r[i + 1] == 'u' and r[i + 2] == 'l' and r[i + 3] == 'l') {
        // integrityToken is null — capture the fallback (element 3) separately.
        out.integrity_token_len = 0;
        out.valid = false;
        // Capture fallback token for diagnostics / cold-start use.
        captureFallback(r, out);
        return false;
    }
    if (r[i] != '"') return false;
    i += 1;
    const start = i;
    while (i < r.len and r[i] != '"') : (i += 1) {
        if (r[i] == '\\' and i + 1 < r.len) i += 1;
    }
    const tlen = i - start;
    if (tlen == 0 or tlen > 512) return false;
    @memcpy(out.integrity_token[0..tlen], r[start .. start + tlen]);
    out.integrity_token_len = tlen;
    out.valid = true;
    return true;
}

/// Capture the websafe fallback token (last string element) for diagnostics.
var fallback_buf: [256]u8 = undefined;
pub var fallback_len: usize = 0;
fn captureFallback(r: []const u8, out: *IntegrityResult) void {
    _ = out;
    // Last quoted string in the array.
    var best_start: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < r.len) : (i += 1) {
        if (r[i] == '"') {
            const s = i + 1;
            var j = s;
            while (j < r.len and r[j] != '"') : (j += 1) { if (r[j] == '\\' and j + 1 < r.len) j += 1; }
            best_start = s; best_len = j - s;
            i = j;
        }
    }
    const n = @min(best_len, fallback_buf.len);
    if (n > 0) @memcpy(fallback_buf[0..n], r[best_start .. best_start + n]);
    fallback_len = n;
}

/// End-to-end: bootstrap the session (if not already), fetch a session-bound
/// challenge, run the BotGuard VM, and exchange for a session-bound integrity
/// token. On success, the VM's webPoSignalOutput[0] minter is populated so the
/// caller can mint a content-bound PO token via jsvm.mintPoToken.
///
/// Returns an IntegrityResult; .valid && integrity_token_len>0 means a REAL
/// (non-null) token was issued.
pub fn establishIntegrityToken(sess: *Session, chal: *challenge.Challenge, out: *IntegrityResult) bool {
    if (!sess.bootstrapped) {
        _ = bootstrap(sess, chal);
    }

    // If the homepage didn't embed a challenge, fetch one within the session.
    if (chal.program_len == 0) {
        if (!fetchChallengeInSession(sess, chal)) {
            print("  [session] challenge fetch failed\n");
            return false;
        }
    }

    // Fetch the VM script if only a URL was provided.
    if (chal.script_len == 0 and chal.interpreter_url_len > 0) {
        print("  [session] fetching interpreter script ...\n");
        if (!challenge.fetchScript(chal)) {
            print("  [session] script fetch failed\n");
            return false;
        }
    }
    print("  [session] script="); printNum(chal.script_len); print(" bytes\n");

    // Run the BotGuard VM to produce the botguardResponse (this also populates
    // the minter chain in webPoSignalOutput[0]).
    var bg_len: usize = 0;
    const ok = jsvm.execute(
        chal.script[0..chal.script_len],
        chal.program[0..chal.program_len],
        chal.global_name[0..chal.global_name_len],
        &bg_response_buf,
        &bg_len,
    );
    print("  [session] VM response="); printNum(bg_len);
    print(" ok="); print(if (ok) "1" else "0"); print("\n");
    if (!ok or bg_len == 0) return false;

    out.minter_ready = jsvm.bg_webpo_signal.tag == .object or jsvm.bg_webpo_signal.tag == .array;

    // Exchange for a session-bound integrity token.
    return generateITInSession(sess, bg_response_buf[0..bg_len], out);
}

fn appendS(buf: anytype, pos: usize, s: []const u8) usize {
    const len = @min(s.len, buf.len - pos);
    @memcpy(buf[pos .. pos + len], s[0..len]);
    return pos + len;
}
