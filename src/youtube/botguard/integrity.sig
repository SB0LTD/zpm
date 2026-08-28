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

var resp_buf: [8192]u8 = undefined;

/// Exchange a BotGuard response token for an integrity token.
/// `bg_response`: the token returned by the BotGuard VM execution
/// `out_token`: buffer for the integrity token
/// `out_len`: receives the token length
/// Returns true on success.
pub fn getToken(bg_response: []const u8, out_token: *[512]u8, out_len: *usize) bool {
    print("  [botguard] Exchanging BG response for integrity token...\n");

    // Build request body: ["requestKey", "bgResponse"]
    var body: [2048]u8 = undefined;
    var blen: usize = 0;

    const p1 = "[\"O43z0dpjhgX20SCx4KAo\",\"";
    @memcpy(body[blen .. blen + p1.len], p1);
    blen += p1.len;

    // JSON-escape the BG response
    for (bg_response) |c| {
        if (blen >= 2000) break;
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
    if (resp_len == 0) {
        print("  [botguard] GenerateIT request failed\n");
        return false;
    }

    print("  [botguard] GenerateIT response: ");
    printNum(resp_len);
    print(" bytes\n");

    // Parse response: [integrityToken, ttlSecs, mintRefreshThreshold, fallbackToken]
    // The response is a JSON array
    const resp = challenge_mod.resp_buf[0..resp_len];

    // Find the first string value (integrity token)
    var i: usize = 0;
    while (i < resp.len and resp[i] != '"') : (i += 1) {}
    if (i >= resp.len) return false;
    i += 1; // skip opening quote
    const tok_start = i;
    while (i < resp.len and resp[i] != '"') : (i += 1) {}
    const tok_len = i - tok_start;

    if (tok_len == 0 or tok_len > 512) return false;

    @memcpy(out_token[0..tok_len], resp[tok_start .. tok_start + tok_len]);
    out_len.* = tok_len;

    print("  [botguard] Integrity token: ");
    printNum(tok_len);
    print(" bytes\n");

    return true;
}

/// Get a full integrity token response with TTL info.
pub fn getTokenFull(bg_response: []const u8) IntegrityTokenResponse {
    var result = IntegrityTokenResponse.init();
    var token_buf: [512]u8 = undefined;
    var token_len: usize = 0;

    if (getToken(bg_response, &token_buf, &token_len)) {
        @memcpy(result.token[0..token_len], token_buf[0..token_len]);
        result.token_len = token_len;
        result.ttl_secs = 43200; // default 12 hours
        result.valid = true;
    }
    return result;
}
