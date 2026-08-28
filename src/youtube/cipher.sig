// @zpm/youtube/cipher — JavaScript Signature Decryption (Pure Sig)
//
// YouTube encrypts stream URLs using a JavaScript cipher function embedded
// in the player.js file. This module extracts and executes that cipher natively.
//
// How YouTube's cipher works:
//   1. The player response contains "signatureCipher" fields with an encrypted "s" param
//   2. The player.js file contains a function that transforms the signature string
//   3. The transform is always a sequence of 3 basic operations:
//      - reverse(a): reverse the character array
//      - splice(a, n): remove first n characters
//      - swap(a, n): swap a[0] with a[n%a.len]
//   4. The specific sequence and parameters change with each player.js version
//
// Our approach:
//   1. Fetch player.js (URL extracted from watch page HTML)
//   2. Find the signature function using regex-like patterns
//   3. Parse the function body into a sequence of Operation structs
//   4. Apply those operations to decrypt any signature
//
// The cipher function in player.js looks like:
//   var Xy={wS:function(a){a.reverse()},
//           Xr:function(a,b){a.splice(0,b)},
//           lH:function(a,b){var c=a[0];a[0]=a[b%a.length];a[b%a.length]=c}};
//   var decrypt=function(a){a=a.split("");Xy.lH(a,2);Xy.wS(a,51);Xy.lH(a,61);...;return a.join("")};
//
// We only need to identify which helper does what (by function body pattern)
// and parse the call sequence with numeric args.

const innertube = @import("innertube.sig");

// ── Operation types ──

pub const Op = enum(u8) {
    reverse = 0, // reverse the array
    splice = 1, // remove first N chars (a.splice(0,n))
    swap = 2, // swap a[0] with a[n%len]
};

pub const CipherStep = struct {
    op: Op,
    arg: u16, // numeric argument (for splice and swap)
};

/// Maximum cipher steps (YouTube typically uses 3-5).
pub const MAX_STEPS: usize = 16;

/// Parsed cipher program.
pub const CipherProgram = struct {
    steps: [MAX_STEPS]CipherStep,
    n_steps: usize,
    valid: bool,

    pub fn init() CipherProgram {
        return .{ .steps = undefined, .n_steps = 0, .valid = false };
    }
};

// ── Module state ──

// Player.js buffer (player.js is typically 1-2 MB)
const PLAYER_JS_SIZE: usize = 2 * 1024 * 1024;
var player_js_buf: [PLAYER_JS_SIZE]u8 = undefined;
var player_js_len: usize = 0;

// Cached cipher program (reused for all videos using same player version)
var cached_program: CipherProgram = CipherProgram.init();
var cached_player_id: [32]u8 = undefined;
var cached_player_id_len: usize = 0;

/// Extract the player.js URL from a watch page HTML response.
/// Looks for: "/s/player/XXXXXX/player_ias.vflset/en_US/base.js"
/// Returns the path slice, or empty string if not found.
pub fn extractPlayerUrl(html: []const u8) []const u8 {
    // Pattern: /s/player/[a-f0-9]+/player_ias.vflset/
    const marker = "/s/player/";
    const pos = findStr(html, marker) orelse return "";
    // Find the end of the URL (terminated by " or ')
    var end = pos;
    while (end < html.len and html[end] != '"' and html[end] != '\'') : (end += 1) {}
    if (end <= pos) return "";
    return html[pos..end];
}

/// Load and parse the cipher program from a player.js file.
/// `player_url`: path like "/s/player/abc123/player_ias.vflset/en_US/base.js"
/// Returns true if cipher was successfully extracted.
pub fn loadCipher(player_url: []const u8) bool {
    // Check cache: same player = same cipher
    if (player_url.len == cached_player_id_len and cached_program.valid) {
        var same = true;
        for (0..player_url.len) |i| {
            if (player_url[i] != cached_player_id[i]) { same = false; break; }
        }
        if (same) return true;
    }

    // Fetch player.js
    player_js_len = innertube.fetchPlayerJs(player_url, &player_js_buf, PLAYER_JS_SIZE);
    if (player_js_len == 0) return false;

    // Parse cipher function
    cached_program = parseCipherFunction(player_js_buf[0..player_js_len]);
    if (!cached_program.valid) return false;

    // Cache the player ID
    const id_len = @min(player_url.len, 32);
    @memcpy(cached_player_id[0..id_len], player_url[0..id_len]);
    cached_player_id_len = id_len;

    return true;
}

/// Decrypt a signature string using the loaded cipher program.
/// `sig`: the encrypted signature (from signatureCipher "s" parameter)
/// `out`: buffer to write decrypted signature
/// Returns length of decrypted signature.
pub fn decryptSignature(sig: []const u8, out: *[256]u8) usize {
    if (!cached_program.valid) return 0;

    // Copy sig to working buffer (we modify in place)
    var work: [256]u8 = undefined;
    const slen = @min(sig.len, 256);
    @memcpy(work[0..slen], sig[0..slen]);
    var len = slen;

    // Apply each cipher step
    for (0..cached_program.n_steps) |i| {
        const step = &cached_program.steps[i];
        switch (step.op) {
            .reverse => {
                // Reverse the array
                var lo: usize = 0;
                var hi: usize = len - 1;
                while (lo < hi) {
                    const tmp = work[lo];
                    work[lo] = work[hi];
                    work[hi] = tmp;
                    lo += 1;
                    hi -= 1;
                }
            },
            .splice => {
                // Remove first N characters
                const n = @min(@as(usize, step.arg), len);
                var j: usize = 0;
                while (j < len - n) : (j += 1) {
                    work[j] = work[j + n];
                }
                len -= n;
            },
            .swap => {
                // Swap a[0] with a[n % len]
                if (len == 0) continue;
                const idx = @as(usize, step.arg) % len;
                const tmp = work[0];
                work[0] = work[idx];
                work[idx] = tmp;
            },
        }
    }

    @memcpy(out[0..len], work[0..len]);
    return len;
}

/// Check if the cipher is loaded and ready.
pub fn isReady() bool {
    return cached_program.valid;
}

/// Get the raw player.js content (for nsig extraction).
pub fn getPlayerJs() []const u8 {
    return player_js_buf[0..player_js_len];
}

// ── Cipher function parser ──
// Finds the cipher function in player.js and extracts the operation sequence.

fn parseCipherFunction(js: []const u8) CipherProgram {
    var prog = CipherProgram.init();

    // Step 1: Find the helper object that contains reverse/splice/swap methods.
    // Pattern: var XX={YY:function(a){a.reverse()},
    //                  ZZ:function(a,b){a.splice(0,b)},
    //                  WW:function(a,b){var c=a[0];a[0]=a[b%a.length];a[b%a.length]=c}};
    //
    // We identify each method by its body content:
    //   - contains "reverse" → reverse
    //   - contains "splice" → splice
    //   - contains "a[0]" or "var c=a[0]" → swap

    // Step 2: Find the main cipher function that calls the helper methods.
    // Pattern: function(a){a=a.split("");XX.YY(a,N);XX.ZZ(a,M);...;return a.join("")}
    //
    // We look for: a=a.split("") ... return a.join("")

    // Find "a=a.split(\"\")" — the signature function entry
    const split_marker = "a=a.split(\"\")";
    const fn_start = findStr(js, split_marker) orelse return prog;

    // Find the end of this function: "return a.join(\"\")"
    const join_marker = "return a.join(\"\")";
    const search_end = @min(fn_start + 2048, js.len);
    const fn_end = findStrRange(js, join_marker, fn_start, search_end) orelse return prog;

    // Extract function body between split and join
    const fn_body = js[fn_start + split_marker.len .. fn_end];

    // Step 3: Identify the helper object name (2-3 chars before first dot call)
    // The function body calls: ObjName.MethodName(a, N)
    // Find first ".X(" pattern to get object name
    var obj_name: [8]u8 = undefined;
    var obj_name_len: usize = 0;
    {
        var i: usize = 0;
        // Skip semicolons and whitespace to first call
        while (i < fn_body.len and (fn_body[i] == ';' or fn_body[i] == ' ' or fn_body[i] == '\n')) : (i += 1) {}
        // Read until '.'
        while (i < fn_body.len and fn_body[i] != '.' and obj_name_len < 8) : (i += 1) {
            obj_name[obj_name_len] = fn_body[i];
            obj_name_len += 1;
        }
    }

    if (obj_name_len == 0) return prog;

    // Step 4: Find the helper object definition and classify each method
    // Search for "var ObjName={" in the JS
    var obj_search: [16]u8 = undefined;
    var os_len: usize = 0;
    const os_prefix = "var ";
    @memcpy(obj_search[os_len .. os_len + os_prefix.len], os_prefix);
    os_len += os_prefix.len;
    @memcpy(obj_search[os_len .. os_len + obj_name_len], obj_name[0..obj_name_len]);
    os_len += obj_name_len;
    obj_search[os_len] = '=';
    os_len += 1;

    const obj_pos = findStr(js, obj_search[0..os_len]) orelse return prog;

    // Parse methods within the object (until closing "};")
    const obj_end_limit = @min(obj_pos + 1024, js.len);

    // Map method names to operations
    const MAX_METHODS: usize = 4;
    var methods: [MAX_METHODS]struct { name: [8]u8, name_len: u8, op: Op } = undefined;
    var n_methods: usize = 0;

    {
        var i = obj_pos + os_len;
        while (i < obj_end_limit and n_methods < MAX_METHODS) {
            // Skip to next method name (alphanumeric before ":")
            while (i < obj_end_limit and !isIdentChar(js[i])) : (i += 1) {}
            if (i >= obj_end_limit) break;

            // Read method name
            var mname: [8]u8 = undefined;
            var mlen: usize = 0;
            while (i < obj_end_limit and isIdentChar(js[i]) and mlen < 8) : (i += 1) {
                mname[mlen] = js[i];
                mlen += 1;
            }

            // Find function body (between { and })
            while (i < obj_end_limit and js[i] != '{') : (i += 1) {}
            const body_start = i + 1;
            var brace_depth: usize = 1;
            i += 1;
            while (i < obj_end_limit and brace_depth > 0) : (i += 1) {
                if (js[i] == '{') brace_depth += 1;
                if (js[i] == '}') brace_depth -= 1;
            }
            const body_end = i - 1;

            if (body_end <= body_start) continue;
            const method_body = js[body_start..body_end];

            // Classify by body content
            const op: Op = if (findStr(method_body, "reverse") != null)
                .reverse
            else if (findStr(method_body, "splice") != null)
                .splice
            else if (findStr(method_body, "a[0]") != null or findStr(method_body, "var c") != null)
                .swap
            else
                continue;

            methods[n_methods] = .{ .name = mname, .name_len = @intCast(mlen), .op = op };
            n_methods += 1;
        }
    }

    if (n_methods == 0) return prog;

    // Step 5: Parse the cipher function's call sequence
    // Each call is: ObjName.MethodName(a,N) or ObjName.MethodName(a)
    {
        var i: usize = 0;
        while (i < fn_body.len and prog.n_steps < MAX_STEPS) {
            // Look for "ObjName."
            if (i + obj_name_len + 1 < fn_body.len and fn_body[i + obj_name_len] == '.') {
                var match = true;
                for (0..obj_name_len) |k| {
                    if (fn_body[i + k] != obj_name[k]) { match = false; break; }
                }
                if (match) {
                    i += obj_name_len + 1; // skip "ObjName."
                    // Read method name
                    var call_name: [8]u8 = undefined;
                    var cn_len: usize = 0;
                    while (i < fn_body.len and isIdentChar(fn_body[i]) and cn_len < 8) : (i += 1) {
                        call_name[cn_len] = fn_body[i];
                        cn_len += 1;
                    }
                    // Find the numeric argument
                    var arg: u16 = 0;
                    while (i < fn_body.len and fn_body[i] != ')') : (i += 1) {
                        if (fn_body[i] >= '0' and fn_body[i] <= '9') {
                            arg = arg * 10 + @as(u16, fn_body[i] - '0');
                        }
                    }
                    // Match call to method
                    for (0..n_methods) |mi| {
                        if (methods[mi].name_len == cn_len) {
                            var m_match = true;
                            for (0..cn_len) |k| {
                                if (methods[mi].name[k] != call_name[k]) { m_match = false; break; }
                            }
                            if (m_match) {
                                prog.steps[prog.n_steps] = .{ .op = methods[mi].op, .arg = arg };
                                prog.n_steps += 1;
                                break;
                            }
                        }
                    }
                    continue;
                }
            }
            i += 1;
        }
    }

    prog.valid = prog.n_steps > 0;
    return prog;
}

// ── String search helpers ──

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

fn findStrRange(haystack: []const u8, needle: []const u8, start: usize, end: usize) ?usize {
    const s = @min(start, haystack.len);
    const e = @min(end, haystack.len);
    if (e < s + needle.len) return null;
    const sub_result = findStr(haystack[s..e], needle);
    if (sub_result) |r| return s + r;
    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$';
}
