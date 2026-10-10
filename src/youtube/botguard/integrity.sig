// @zpm/youtube/botguard/integrity — WAA Integrity Token Exchange
//
// After executing the BotGuard VM and getting a response token,
// exchange it for an integrity token via the WAA GenerateIT endpoint.
// The integrity token is then used to mint PO tokens.

const challenge_mod = @import("challenge.sig");

extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

fn print(msg: []const u8) void {
    _ = WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg.ptr, @intCast(msg.len), null, null);
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

/// Response from the GenerateIT endpoint.
pub const IntegrityTokenResponse = struct {
    token: [512]u8,
    token_len: usize,
    ttl_secs: u32, // estimated time-to-live
    mint_refresh_threshold: u32,
    fallback_token: [256]u8,
    fallback_len: usize,
    valid: bool,

    pub fn init() IntegrityTokenResponse {
        return .{
            .token = undefined,
            .token_len = 0,
            .ttl_secs = 0,
            .mint_refresh_threshold = 0,
            .fallback_token = undefined,
            .fallback_len = 0,
            .valid = false,
        };
    }
};

/// Parse GenerateIT positionally. A fallback in element 3 is diagnostic data;
/// it cannot substitute for the primary integrity token in element 0.
pub fn parseResponse(resp: []const u8) IntegrityTokenResponse {
    var result = IntegrityTokenResponse.init();
    var i: usize = 0;
    skipSpace(resp, &i);
    if (i >= resp.len or resp[i] != '[') return result;
    i += 1;
    const primary = readToken(resp, &i, &result.token) orelse return result;
    if (!take(resp, &i, ',')) return result;
    result.ttl_secs = readNumber(resp, &i) orelse return result;
    skipSpace(resp, &i);
    if (i < resp.len and resp[i] == ',') {
        i += 1;
        result.mint_refresh_threshold = readNumber(resp, &i) orelse return result;
        skipSpace(resp, &i);
        if (i < resp.len and resp[i] == ',') {
            i += 1;
            result.fallback_len = readToken(resp, &i, &result.fallback_token) orelse return result;
        }
    }
    if (!take(resp, &i, ']')) return result;
    skipSpace(resp, &i);
    if (i != resp.len) return result;
    result.token_len = primary;
    result.valid = primary > 0 and result.ttl_secs > 0;
    return result;
}

fn skipSpace(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t' or s[i.*] == '\r' or s[i.*] == '\n')) : (i.* += 1) {}
}

fn take(s: []const u8, i: *usize, c: u8) bool {
    skipSpace(s, i);
    if (i.* >= s.len or s[i.*] != c) return false;
    i.* += 1;
    return true;
}

fn readToken(s: []const u8, i: *usize, out: []u8) ?usize {
    skipSpace(s, i);
    if (i.* + 4 <= s.len and s[i.*] == 'n' and s[i.* + 1] == 'u' and s[i.* + 2] == 'l' and s[i.* + 3] == 'l') {
        i.* += 4;
        return 0;
    }
    if (!take(s, i, '"')) return null;
    var n: usize = 0;
    while (i.* < s.len and s[i.*] != '"') : (i.* += 1) {
        // Tokens are base64 or base64url strings. Escapes/control characters
        // and oversized values cannot be passed to the VM as token bytes.
        const c = s[i.*];
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '+' or c == '/' or c == '-' or c == '_' or c == '=') or n >= out.len) return null;
        out[n] = c;
        n += 1;
    }
    if (!take(s, i, '"')) return null;
    return n;
}

fn readNumber(s: []const u8, i: *usize) ?u32 {
    skipSpace(s, i);
    if (i.* + 4 <= s.len and s[i.*] == 'n' and s[i.* + 1] == 'u' and s[i.* + 2] == 'l' and s[i.* + 3] == 'l') {
        i.* += 4;
        return 0;
    }
    const start = i.*;
    var n: u32 = 0;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') : (i.* += 1) {
        const digit: u32 = s[i.*] - '0';
        if (n > (0xFFFFFFFF - digit) / 10) return null;
        n = n * 10 + digit;
    }
    return if (i.* == start) null else n;
}

/// Exchange a BotGuard response token for an integrity token.
/// `bg_response`: the token returned by the BotGuard VM execution
/// `out_token`: buffer for the integrity token
/// `out_len`: receives the token length
/// Returns true on success.
pub fn getToken(bg_response: []const u8, out_token: *[512]u8, out_len: *usize) bool {
    out_len.* = 0;
    last_response_len = 0;
    print("  [botguard] Exchanging BG response for integrity token...\n");

    // Build request body: ["requestKey", "bgResponse"]. The BotGuard response
    // can be tens of KB, so the body buffer must be large enough to hold the
    // full JSON-escaped token plus the request-key wrapper.
    var body: [131072]u8 = undefined;
    var blen: usize = 0;

    const p1 = "[\"O43z0dpjhgX20SCx4KAo\",\"";
    @memcpy(body[blen .. blen + p1.len], p1);
    blen += p1.len;

    // JSON-escape the BG response
    for (bg_response) |c| {
        if (blen + 2 >= body.len - 4) return false;
        switch (c) {
            '"' => { body[blen] = '\\'; blen += 1; body[blen] = '"'; blen += 1; },
            '\\' => { body[blen] = '\\'; blen += 1; body[blen] = '\\'; blen += 1; },
            '\n' => { body[blen] = '\\'; blen += 1; body[blen] = 'n'; blen += 1; },
            else => { body[blen] = c; blen += 1; },
        }
    }

    const p2 = "\"]";
    @memcpy(body[blen .. blen + p2.len], p2);
    blen += p2.len;

    // POST to WAA/GenerateIT
    const resp_len = challenge_mod.waaPost("/$rpc/google.internal.waa.v1.Waa/GenerateIT", body[0..blen]);
    last_response_len = resp_len;
    if (resp_len == 0) {
        print("  [botguard] GenerateIT request failed\n");
        return false;
    }

    print("  [botguard] GenerateIT response: ");
    printNum(resp_len);
    print(" bytes\n");
    print("  [botguard] GenerateIT raw: ");
    print(challenge_mod.resp_buf[0..@min(resp_len, 400)]);
    print("\n");

    // Parse response: [integrityToken, ttlSecs, mintRefreshThreshold, fallbackToken]
    // The response is a JSON array
    const resp = challenge_mod.resp_buf[0..resp_len];

    const parsed = parseResponse(resp);
    if (!parsed.valid) return false;
    @memcpy(out_token[0..parsed.token_len], parsed.token[0..parsed.token_len]);
    out_len.* = parsed.token_len;

    print("  [botguard] Integrity token: ");
    printNum(parsed.token_len);
    print(" bytes\n");

    return true;
}

/// Get a full integrity token response with TTL info.
pub fn getTokenFull(bg_response: []const u8) IntegrityTokenResponse {
    var token_buf: [512]u8 = undefined;
    var token_len: usize = 0;
    _ = getToken(bg_response, &token_buf, &token_len);
    return parseResponse(challenge_mod.resp_buf[0..last_response_len]);
}

var last_response_len: usize = 0;
