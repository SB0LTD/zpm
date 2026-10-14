// @zpm/youtube/botguard/challenge — WAA Challenge Fetcher
//
// Fetches BotGuard challenge data from Google's Web Anti-Abuse API.
// The challenge contains:
//   - The VM interpreter JavaScript (URL or inline)
//   - A bytecode program to run in the VM
//   - The global object name for accessing the VM
//
// Two methods:
//   1. WAA Create API (POST to jnn-pa.googleapis.com)
//   2. Extract from YouTube watch page HTML (embedded in ytInitialPlayerResponse)

// ── HTTP via @zpm/http (app-local adapter) + console ──
const http = @import("../net.sig");

extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

fn print(msg: []const u8) void {
    _ = WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg.ptr, @intCast(msg.len), null, null);
}

// ── Challenge data ──

pub const MAX_SCRIPT_SIZE: usize = 768 * 1024; // BG scripts are ~500KB
pub const MAX_PROGRAM_SIZE: usize = 64 * 1024; // att/get program is ~40KB base64
pub const MAX_VISITOR_DATA: usize = 2048;

pub const Challenge = struct {
    // VM script (JavaScript source, fetched from interpreterUrl)
    script: [MAX_SCRIPT_SIZE]u8,
    script_len: usize,
    // Bytecode program (base64-encoded, passed to the VM)
    program: [MAX_PROGRAM_SIZE]u8,
    program_len: usize,
    // Global name (how to access the VM after script execution)
    global_name: [32]u8,
    global_name_len: usize,
    // Interpreter hash (for caching)
    interpreter_hash: [64]u8,
    hash_len: usize,
    // Interpreter URL (protocol-relative, e.g. //www.google.com/js/th/<hash>.js)
    interpreter_url: [256]u8,
    interpreter_url_len: usize,
    // Request key (needed for integrity token step)
    request_key: [128]u8,
    request_key_len: usize,
    // Visitor data (needed for session-bound PO token minting)
    visitor_data: [MAX_VISITOR_DATA]u8,
    visitor_data_len: usize,

    pub fn init() Challenge {
        return .{
            .script = undefined,
            .script_len = 0,
            .program = undefined,
            .program_len = 0,
            .global_name = undefined,
            .global_name_len = 0,
            .interpreter_hash = undefined,
            .hash_len = 0,
            .interpreter_url = undefined,
            .interpreter_url_len = 0,
            .request_key = undefined,
            .request_key_len = 0,
            .visitor_data = undefined,
            .visitor_data_len = 0,
        };
    }
};

// Response buffer
// Large enough to hold a full WAA/Create response including an inline VM script
// (BG interpreter JS can be ~500KB) plus the base64 program and metadata.
const RESP_BUF_SIZE: usize = 1024 * 1024;
pub var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
pub var resp_buf_len: usize = 0;

/// Get the raw response buffer (for debugging).
pub fn getRawResponse() []const u8 {
    return resp_buf[0..resp_buf_len];
}

/// Fetch the BotGuard challenge via InnerTube's attestation endpoint.
///
/// POST https://www.youtube.com/youtubei/v1/att/get?key=<web key>
/// The JSON response contains a `bgChallenge` object with the interpreter URL,
/// interpreter hash, the base64 program, and the VM global name — the exact
/// data the reference client (youtubei.js getAttestationChallenge) consumes.
pub fn fetch(chal: *Challenge) bool {
    print("  [botguard] Fetching challenge from InnerTube att/get...\n");

    const resp_len = attGetPost();
    if (resp_len == 0) {
        print("  [botguard] att/get request failed\n");
        return false;
    }

    print("  [botguard] att/get response: ");
    printNum(resp_len);
    print(" bytes\n");

    // Parse the keyed JSON (bgChallenge.*) into the challenge struct.
    return parseAttGetResponse(resp_buf[0..resp_len], chal);
}

/// POST to the InnerTube att/get endpoint with the public web API key.
/// Response is left in resp_buf; returns its length.
fn attGetPost() usize {
    const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
    const body = "{\"engagementType\":\"ENGAGEMENT_TYPE_UNBOUND\",\"context\":{\"client\":{\"clientName\":\"WEB\",\"clientVersion\":\"2.20241126.01.00\",\"hl\":\"en\",\"gl\":\"US\"}}}";
    const r = http.postInto(
        "www.youtube.com",
        443,
        "/youtubei/v1/att/get?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false",
        "Content-Type: application/json\r\n",
        body,
        UA,
        &resp_buf,
    );
    resp_buf_len = r.len;
    return r.len;
}

/// POST a JSON body to the WAA (BotGuard) service at jnn-pa.googleapis.com.
/// Used for the GenerateIT integrity-token exchange. `path` is the request
/// path (e.g. "/$rpc/google.internal.waa.v1.Waa/GenerateIT"). The response is
/// read into resp_buf; returns the byte length (0 on failure).
pub fn waaPost(path: []const u8, body: []const u8) usize {
    const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
    // WAA requires JSON+protobuf content type and the web WAA API key.
    const headers = "Content-Type: application/json+protobuf\r\nx-goog-api-key: AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw\r\nx-user-agent: grpc-web-javascript/0.1\r\nOrigin: https://www.youtube.com\r\nReferer: https://www.youtube.com/\r\n";
    const r = http.postInto("jnn-pa.googleapis.com", 443, path, headers, body, UA, &resp_buf);
    resp_buf_len = r.len;
    return r.len;
}

/// Fetch a BotGuard challenge via the WAA **Create** RPC (the flow BgUtils uses
/// for WebPO minting). Unlike att/get (ENGAGEMENT_TYPE_UNBOUND, which never
/// populates the minter), the Create challenge's snapshot DOES populate
/// webPoSignalOutput[0] = getMinter, enabling content-bound PO token minting.
///
/// POST https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create
/// body: ["<requestKey>"]  (JSON+protobuf)
/// resp: [messageId, wrappedScript, wrappedUrl, interpreterHash, program, globalName, ...]
///   wrappedScript = [ ... , "<interpreter JS>" ] (find the string element)
///   wrappedUrl    = [ ... , "//..." ]           (protocol-relative script URL)
/// The response may also be scrambled (resp[1] is a base64 string); we handle
/// the common unscrambled array form and fall back to key-based extraction.
pub const YT_REQUEST_KEY: []const u8 = "O43z0dpjhgX20SCx4KAo";

pub fn fetchCreate(chal: *Challenge) bool {
    print("  [botguard] Fetching challenge via WAA Create...\n");

    // Body is a JSON array with the request key: ["<key>"].
    var body_buf: [160]u8 = undefined;
    var bl: usize = 0;
    body_buf[bl] = '['; bl += 1;
    body_buf[bl] = '"'; bl += 1;
    @memcpy(body_buf[bl .. bl + YT_REQUEST_KEY.len], YT_REQUEST_KEY);
    bl += YT_REQUEST_KEY.len;
    body_buf[bl] = '"'; bl += 1;
    body_buf[bl] = ']'; bl += 1;

    const resp_len = waaPost("/$rpc/google.internal.waa.v1.Waa/Create", body_buf[0..bl]);
    if (resp_len == 0) {
        print("  [botguard] Create request failed\n");
        return false;
    }
    print("  [botguard] Create response: ");
    printNum(resp_len);
    print(" bytes\n");

    return parseCreateResponse(resp_buf[0..resp_len], chal);
}

/// Parse the WAA Create response array:
///   [messageId, wrappedScript, wrappedUrl, interpreterHash, program, globalName, ...]
/// We extract: program (base64), globalName, interpreterHash, interpreterUrl
/// (from wrappedUrl), and the inline interpreter JS (from wrappedScript, if
/// present). The response is a raw JSON array (elements are strings/arrays), so
/// we walk top-level array elements by index.
// Scratch buffer for the DESCRAMBLED Create challenge JSON (element indices
// [messageId, wrappedScript, wrappedUrl, interpreterHash, program, globalName]).
var descramble_buf: [MAX_SCRIPT_SIZE + MAX_PROGRAM_SIZE + 4096]u8 = undefined;

fn parseCreateResponse(resp_in: []const u8, chal: *Challenge) bool {
    // The Create response is USUALLY the scrambled form `[null,"<base64>"]`:
    // descramble = base64-decode then add 97 (mod 256) to each byte, yielding the
    // real challenge JSON array. Detect it (2-element array, [1] a base64 string)
    // and descramble into `descramble_buf`; otherwise parse `resp_in` directly.
    var resp: []const u8 = resp_in;
    if (findScrambledPayload(resp_in)) |scrambled| {
        const dn = base64DecodeAdd97(scrambled, descramble_buf[0..]);
        if (dn > 0) resp = descramble_buf[0..dn];
    }

    // Locate the outer array and split its TOP-LEVEL elements (respecting nested
    // brackets and strings). Element indices per the WAA Create shape above.
    var elems: [16]([]const u8) = undefined;
    var n_elems: usize = 0;

    // Find first '['.
    var i: usize = 0;
    while (i < resp.len and resp[i] != '[') : (i += 1) {}
    if (i >= resp.len) return false;
    i += 1; // past outer '['

    var depth: i32 = 0;
    var in_str = false;
    var elem_start = i;
    while (i < resp.len) : (i += 1) {
        const ch = resp[i];
        if (in_str) {
            if (ch == '\\') { i += 1; continue; }
            if (ch == '"') in_str = false;
            continue;
        }
        switch (ch) {
            '"' => in_str = true,
            '[', '{' => depth += 1,
            ']', '}' => {
                if (depth == 0) {
                    // End of outer array — capture the final element.
                    if (n_elems < elems.len and i > elem_start) elems[n_elems] = trimWs(resp[elem_start..i]);
                    if (i > elem_start) n_elems += 1;
                    break;
                }
                depth -= 1;
            },
            ',' => {
                if (depth == 0) {
                    if (n_elems < elems.len) { elems[n_elems] = trimWs(resp[elem_start..i]); n_elems += 1; }
                    elem_start = i + 1;
                }
            },
            else => {},
        }
    }

    // Shape: [0]=messageId, [1]=wrappedScript, [2]=wrappedUrl, [3]=interpreterHash,
    //        [4]=program, [5]=globalName, ...
    if (n_elems >= 6) {
        // program (base64) — element 4, a JSON string (may contain \/ escapes).
        if (unquote(elems[4])) |prog| {
            chal.program_len = jsonUnescape(prog, chal.program[0..]);
        }
        // globalName — element 5.
        if (unquote(elems[5])) |gn| {
            const glen = @min(gn.len, 32);
            @memcpy(chal.global_name[0..glen], gn[0..glen]);
            chal.global_name_len = glen;
        }
        // interpreterHash — element 3.
        if (unquote(elems[3])) |ih| {
            const hlen = @min(ih.len, 64);
            @memcpy(chal.interpreter_hash[0..hlen], ih[0..hlen]);
            chal.hash_len = hlen;
        }
        // wrappedUrl — element 2: an array containing a protocol-relative URL
        // string. Pull the first "//..."-looking string out of it.
        if (findStrVal(elems[2], "//") == null) {
            // element 2 is like [null,null,"//www.google.com/js/th/<hash>.js"]
        }
        if (findProtocolRelativeUrl(elems[2])) |url_val| {
            const ulen = @min(url_val.len, 256);
            @memcpy(chal.interpreter_url[0..ulen], url_val[0..ulen]);
            chal.interpreter_url_len = ulen;
        }
        // wrappedScript — element 1: the inline interpreter JS as the long
        // string element (Create embeds the JS rather than a URL). It is a JSON
        // string literal, so UNESCAPE it (\n, \", \/, \\, \uXXXX) into the script
        // buffer. If absent, fall back to fetchScript(interpreterUrl).
        if (findLongStringElement(elems[1])) |js| {
            chal.script_len = jsonUnescape(js, chal.script[0..]);
        }
    } else {
        // Fallback: key-based extraction (some responses are keyed JSON).
        return parseAttGetResponse(resp, chal);
    }

    return chal.program_len > 0 and (chal.interpreter_url_len > 0 or chal.script_len > 0);
}

/// Detect the scrambled Create form `[null,"<base64>"]` (or `[<x>,"<base64>"]`)
/// and return the inner base64 string (the scrambled challenge). The payload is
/// the SECOND top-level string element. Returns null if not the scrambled form.
fn findScrambledPayload(resp: []const u8) ?[]const u8 {
    // Find the outer array, then the first quoted string of substantial length.
    // The scrambled challenge is a large base64 blob (>4KB); a normal unscrambled
    // array's first string is short (messageId). So: return the FIRST quoted
    // string whose length is > 4096 (the scrambled payload).
    var i: usize = 0;
    while (i < resp.len) : (i += 1) {
        if (resp[i] == '"') {
            const start = i + 1;
            var j = start;
            while (j < resp.len and resp[j] != '"') : (j += 1) {
                if (resp[j] == '\\' and j + 1 < resp.len) j += 1;
            }
            if (j - start > 4096) return resp[start..j];
            i = j;
        }
    }
    return null;
}

/// Base64-decode `input` and add 97 (mod 256) to each output byte — the WAA
/// Create descramble transform (BgUtils `descrambleChallenge`). Writes to `out`,
/// returns the number of bytes produced (0 on overflow/failure).
fn base64DecodeAdd97(input: []const u8, out: []u8) usize {
    var acc: u32 = 0;
    var nbits: u5 = 0;
    var oi: usize = 0;
    for (input) |c| {
        const v: i16 = b64Value(c);
        if (v < 0) continue; // skip '=', whitespace, non-b64
        acc = (acc << 6) | @as(u32, @intCast(v));
        if (nbits >= 2) {
            nbits -= 2;
            if (oi >= out.len) return 0;
            const byte: u8 = @intCast((acc >> nbits) & 0xFF);
            out[oi] = byte +% 97; // descramble: +97 mod 256
            oi += 1;
        } else {
            nbits += 6;
        }
    }
    return oi;
}

/// Map a base64 char (standard OR url-safe) to its 6-bit value, or -1.
fn b64Value(c: u8) i16 {
    if (c >= 'A' and c <= 'Z') return @as(i16, c - 'A');
    if (c >= 'a' and c <= 'z') return @as(i16, c - 'a') + 26;
    if (c >= '0' and c <= '9') return @as(i16, c - '0') + 52;
    if (c == '+' or c == '-') return 62;
    if (c == '/' or c == '_') return 63;
    return -1;
}

/// Trim leading/trailing ASCII whitespace from a slice.
fn trimWs(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\n' or s[a] == '\r' or s[a] == '\t')) : (a += 1) {}
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\n' or s[b - 1] == '\r' or s[b - 1] == '\t')) : (b -= 1) {}
    return s[a..b];
}

/// Unescape a JSON string body (the bytes BETWEEN the quotes) into `out`,
/// resolving \n \r \t \b \f \" \\ \/ and \uXXXX (BMP → UTF-8). Returns the
/// number of bytes written (clamped to out.len). Used for the Create challenge's
/// inline interpreter JS and base64 program, which arrive JSON-escaped.
fn jsonUnescape(s: []const u8, out: []u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len and o < out.len) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) {
            out[o] = c; o += 1; i += 1; continue;
        }
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
                // \uHHHH → UTF-8 (BMP only; surrogate pairs are rare here).
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

/// If `s` is a JSON string literal ("..."), return its inner (still-escaped)
/// bytes; otherwise null. Handles the plain string-element case.
fn unquote(s: []const u8) ?[]const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return null;
}

/// Find the first protocol-relative URL string ("//...") inside a JSON fragment
/// (e.g. the wrappedUrl array). Returns the inner bytes (without quotes).
fn findProtocolRelativeUrl(frag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 3 < frag.len) : (i += 1) {
        if (frag[i] == '"' and frag[i + 1] == '/' and frag[i + 2] == '/') {
            const start = i + 1;
            var j = start;
            while (j < frag.len and frag[j] != '"') : (j += 1) {
                if (frag[j] == '\\' and j + 1 < frag.len) j += 1;
            }
            if (j > start) return frag[start..j];
        }
    }
    return null;
}

/// Find the LONGEST quoted string element inside a JSON fragment (the inline
/// interpreter JS, if the Create response embeds it). Returns inner bytes.
fn findLongStringElement(frag: []const u8) ?[]const u8 {
    var best_start: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < frag.len) : (i += 1) {
        if (frag[i] == '"') {
            const start = i + 1;
            var j = start;
            while (j < frag.len and frag[j] != '"') : (j += 1) {
                if (frag[j] == '\\' and j + 1 < frag.len) j += 1;
            }
            if (j - start > best_len) { best_len = j - start; best_start = start; }
            i = j;
        }
    }
    // Only treat as the interpreter JS if it's plausibly large (>1KB).
    if (best_len > 1024) return frag[best_start .. best_start + best_len];
    return null;
}

/// Fetch the VM script from the challenge's interpreter URL.
/// The URL is protocol-relative: //<host>/<path> (typically
/// //www.google.com/js/th/<hash>.js). We split host and path and GET over TLS.
pub fn fetchScript(chal: *Challenge) bool {
    if (chal.interpreter_url_len == 0) return false;

    // Parse protocol-relative URL: strip leading "//", then split at first '/'.
    var u = chal.interpreter_url[0..chal.interpreter_url_len];
    if (u.len >= 2 and u[0] == '/' and u[1] == '/') {
        u = u[2..];
    } else if (u.len >= 8 and u[0] == 'h' and u[1] == 't' and u[2] == 't' and u[3] == 'p' and u[4] == 's' and u[5] == ':' and u[6] == '/' and u[7] == '/') {
        u = u[8..]; // strip https://
    }

    var slash: usize = 0;
    while (slash < u.len and u[slash] != '/') : (slash += 1) {}
    if (slash == 0 or slash >= u.len) return false;

    const host = u[0..slash];
    const path = u[slash..];

    print("  [botguard] Fetching VM script from ");
    print(host);
    print("...\n");

    const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

    // GET the interpreter JS straight into the challenge's script buffer.
    const r = http.getInto(host, 443, path, "", UA, chal.script[0..MAX_SCRIPT_SIZE]);
    chal.script_len = if (r.ok) r.len else 0;

    print("  [botguard] Script: ");
    printNum(chal.script_len);
    print(" bytes\n");

    return chal.script_len > 0;
}

// ── Debug: fetch raw att/get response for structure inspection ──

/// POST to InnerTube att/get with the public web API key and return the raw
/// response length (contents in resp_buf, retrievable via getRawResponse()).
pub fn debugFetchAttGet() usize {
    const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
    // engagementType UNBOUND — the shape youtubei.js sends for attestation.
    const body = "{\"engagementType\":\"ENGAGEMENT_TYPE_UNBOUND\",\"context\":{\"client\":{\"clientName\":\"WEB\",\"clientVersion\":\"2.20241126.01.00\",\"hl\":\"en\",\"gl\":\"US\"}}}";
    const r = http.postInto(
        "www.youtube.com",
        443,
        "/youtubei/v1/att/get?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false",
        "Content-Type: application/json\r\n",
        body,
        UA,
        &resp_buf,
    );
    resp_buf_len = r.len;
    return r.len;
}

// ── Internal: fetch request key from YouTube attestation endpoint ──

// ── Parse InnerTube att/get response ──

fn parseAttGetResponse(resp: []const u8, chal: *Challenge) bool {
    // Keyed JSON. Relevant fields (inside "bgChallenge"):
    //   "interpreterUrl": { "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": "//..." }
    //   "interpreterHash": "<hash>"
    //   "program": "<base64>"
    //   "globalName": "<name>"
    // Top-level responseContext contains "visitorData".

    // program (base64 bytecode program for the VM)
    if (findStrVal(resp, "\"program\"")) |prog| {
        const plen = @min(prog.len, MAX_PROGRAM_SIZE);
        @memcpy(chal.program[0..plen], prog[0..plen]);
        chal.program_len = plen;
    }

    // globalName
    if (findStrVal(resp, "\"globalName\"")) |gn| {
        const glen = @min(gn.len, 32);
        @memcpy(chal.global_name[0..glen], gn[0..glen]);
        chal.global_name_len = glen;
    }

    // interpreterHash (for caching)
    if (findStrVal(resp, "\"interpreterHash\"")) |ih| {
        const hlen = @min(ih.len, 64);
        @memcpy(chal.interpreter_hash[0..hlen], ih[0..hlen]);
        chal.hash_len = hlen;
    }

    // interpreterUrl — protocol-relative URL to the VM script.
    if (findStrVal(resp, "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue")) |url_val| {
        const ulen = @min(url_val.len, 256);
        @memcpy(chal.interpreter_url[0..ulen], url_val[0..ulen]);
        chal.interpreter_url_len = ulen;
    }

    // visitorData — keep the complete server-issued visitor context.
    if (findStrVal(resp, "\"visitorData\"")) |vd| {
        if (vd.len > chal.visitor_data.len) return false;
        const vlen = vd.len;
        @memcpy(chal.visitor_data[0..vlen], vd[0..vlen]);
        chal.visitor_data_len = vlen;
    }

    // A valid challenge requires at least a program and a way to get the script.
    return chal.program_len > 0 and (chal.interpreter_url_len > 0 or chal.script_len > 0);
}

// ── Helpers ──

/// Find a JSON string value for `key`: locates `key`, requires the next
/// non-space delimiter to be ':', then returns the following "..." string.
/// Returns the raw (still-escaped) inner bytes of that string.
fn findStrVal(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = findStr(data, key) orelse return null;
    var i = pos + key.len;

    // Allow an optional closing quote of the key (when the key was passed
    // without its surrounding quotes), then whitespace, then ':'.
    if (i < data.len and data[i] == '"') i += 1;
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len or data[i] != ':') return null;
    i += 1;

    // Skip whitespace to the value.
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len or data[i] != '"') return null;
    i += 1; // opening quote

    const start = i;
    while (i < data.len and data[i] != '"') : (i += 1) {
        if (data[i] == '\\' and i + 1 < data.len) i += 1; // skip escaped char
    }
    if (i > start) return data[start..i];
    // Empty string value.
    return data[start..start];
}

fn findStr(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    for (0..haystack.len - needle.len + 1) |i| {
        var ok = true;
        for (0..needle.len) |j| if (haystack[i + j] != needle[j]) { ok = false; break; };
        if (ok) return i;
    }
    return null;
}

fn printNum(val: usize) void {
    var buf: [20]u8 = undefined;
    var v = val;
    var len: usize = 0;
    if (v == 0) { print("0"); return; }
    while (v > 0) : (len += 1) { buf[len] = @intCast((v % 10) + '0'); v /= 10; }
    var rev: [20]u8 = undefined;
    for (0..len) |i| rev[i] = buf[len - 1 - i];
    print(rev[0..len]);
}
