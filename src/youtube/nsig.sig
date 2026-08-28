// @zpm/youtube/nsig — N-Parameter Throttle Transform (Pure Sig)
//
// YouTube applies throttling to stream URLs unless the "n" parameter is
// transformed using a function embedded in player.js. Without this transform,
// downloads are rate-limited to ~50KB/s.
//
// The nsig function is more complex than the signature cipher:
//   - It's a single function that takes the n-param string and returns a transformed string
//   - It uses array operations: push, splice, reverse, forEach, map, indexOf
//   - It accesses characters by index and performs string concatenation
//   - The function changes with each player.js version
//
// Strategy:
//   Unlike the simple cipher (which is always reverse/splice/swap),
//   the nsig function is a full mini-program. We implement a targeted
//   interpreter that handles the specific patterns YouTube uses:
//
//   1. Extract the nsig function body from player.js
//   2. Parse it into a sequence of array/string operations
//   3. Execute those operations on the input n-parameter
//
// The nsig function typically:
//   - Splits the input into characters
//   - Rearranges them using index-based swaps and lookups into a hardcoded charset
//   - Joins and returns the result
//
// Since the nsig function changes frequently, we use a pattern-based approach:
//   Find the function by signature, extract its character manipulation table,
//   and apply the transformations.

const innertube = @import("innertube.sig");
const cipher_mod = @import("cipher.sig");

// ── Nsig transform state ──

pub const MAX_NSIG_LEN: usize = 64;

/// Extract and apply the nsig transform to an n-parameter value.
/// `n_param`: the original n parameter from the stream URL
/// `out`: buffer for the transformed n parameter
/// Returns length of transformed value, or 0 on failure.
pub fn transform(n_param: []const u8, out: *[MAX_NSIG_LEN]u8) usize {
    // Get player.js (should be cached from cipher loading)
    const js = cipher_mod.getPlayerJs();
    if (js.len == 0) return 0;

    // Find the nsig function
    const func = findNsigFunction(js);
    if (func.len == 0) return 0;

    // Execute the nsig transform
    return executeNsig(func, n_param, out);
}

/// Find the nsig function body in player.js.
/// The nsig function is identified by patterns like:
///   - "enhanced_except_" followed by function definition
///   - Function that takes a single param and returns transformed string
///   - Contains specific markers like ".split(\"\")" and ".join(\"\")"
fn findNsigFunction(js: []const u8) []const u8 {
    // Pattern 1: Look for the nsig function assignment
    // Common patterns (YouTube changes these):
    //   var b=a.split(""),c=[function signatures...];
    //   ...array manipulations...
    //   return b.join("")
    //
    // The function is typically found near: "enhanced_except_"
    // Or identified by: function(a){var b=a.split("")...return b.join("")}
    // where the body contains specific array manipulation patterns

    // Strategy: find "b=a.split(\"\")" which is unique to nsig (cipher uses a=a.split)
    const nsig_marker = "b=a.split(\"\")";
    var search_pos: usize = 0;

    while (search_pos < js.len) {
        const pos = findStrFrom(js, nsig_marker, search_pos) orelse break;

        // Walk backwards to find function start
        var fn_start = pos;
        var paren_count: usize = 0;
        while (fn_start > 0) : (fn_start -= 1) {
            if (js[fn_start] == '{' and paren_count == 0) break;
            if (js[fn_start] == '}') paren_count += 1;
            if (js[fn_start] == '{') paren_count -= 1;
        }

        // Walk forward to find function end (matching closing brace)
        var fn_end = pos;
        var brace_depth: usize = 1;
        // Skip to first { after fn_start
        while (fn_end < js.len and js[fn_end] != '{') : (fn_end += 1) {}
        fn_end += 1;
        while (fn_end < js.len and brace_depth > 0) : (fn_end += 1) {
            if (js[fn_end] == '{') brace_depth += 1;
            if (js[fn_end] == '}') brace_depth -= 1;
        }

        // Validate: must also contain "join" (the return statement)
        const candidate = js[fn_start..fn_end];
        if (findStr(candidate, "join") != null and candidate.len > 50 and candidate.len < 16384) {
            return candidate;
        }

        search_pos = pos + 1;
    }
    return "";
}

/// Execute the nsig transform by interpreting the function.
///
/// YouTube's nsig functions follow a template:
///   1. b = a.split("")   — split input into char array
///   2. c = [array of strings/numbers/functions used as lookup table]
///   3. Series of operations that rearrange b using indices from c
///   4. return b.join("")  — rejoin and return
///
/// The operations are typically:
///   - b.push(b[N])        — duplicate element
///   - b.splice(N, 1)      — remove element at N
///   - b.reverse()         — reverse array
///   - b[N] = b[M]         — direct assignment
///   - b.unshift(b.pop())  — rotate right
///   - various indexOf + charAt combinations
///
/// For robustness, we implement a simplified interpreter that handles
/// the common operation set. If the function uses patterns we don't
/// recognize, we return 0 (caller falls back to throttled download).
fn executeNsig(func_body: []const u8, input: []const u8, out: *[MAX_NSIG_LEN]u8) usize {
    // Working array: the input characters
    var b: [MAX_NSIG_LEN]u8 = undefined;
    var blen: usize = @min(input.len, MAX_NSIG_LEN);
    @memcpy(b[0..blen], input[0..blen]);

    // Extract the hardcoded lookup array if present
    // Look for c=[...] pattern (array of strings used for index calculations)
    var lookup_table: [256]u8 = undefined;
    var lookup_len: usize = 0;
    extractLookupTable(func_body, &lookup_table, &lookup_len);

    // Parse and execute operations sequentially
    // We look for known patterns in the function body:
    var i: usize = 0;
    var ops_executed: usize = 0;

    while (i < func_body.len and ops_executed < 200) {
        // Pattern: b.reverse()
        if (matchAt(func_body, i, "b.reverse()")) {
            reverseArr(&b, blen);
            i += 11;
            ops_executed += 1;
            continue;
        }

        // Pattern: b.splice(N,1) — remove element at position N
        if (matchAt(func_body, i, "b.splice(")) {
            i += 9;
            const n = parseNumAt(func_body, &i);
            // Remove element at position n
            if (n < blen) {
                var j = n;
                while (j + 1 < blen) : (j += 1) b[j] = b[j + 1];
                blen -= 1;
            }
            ops_executed += 1;
            continue;
        }

        // Pattern: b.unshift(b.pop()) — rotate right
        if (matchAt(func_body, i, "b.unshift(b.pop())")) {
            if (blen > 1) {
                const last = b[blen - 1];
                var j = blen - 1;
                while (j > 0) : (j -= 1) b[j] = b[j - 1];
                b[0] = last;
            }
            i += 18;
            ops_executed += 1;
            continue;
        }

        // Pattern: b.push(b[N]) — duplicate element
        if (matchAt(func_body, i, "b.push(b[")) {
            i += 9;
            const n = parseNumAt(func_body, &i);
            if (n < blen and blen < MAX_NSIG_LEN) {
                b[blen] = b[n];
                blen += 1;
            }
            ops_executed += 1;
            continue;
        }

        i += 1;
    }

    // If we didn't execute any operations, the function format is unrecognized
    if (ops_executed == 0) return 0;

    // Output result
    @memcpy(out[0..blen], b[0..blen]);
    return blen;
}

fn extractLookupTable(func_body: []const u8, table: *[256]u8, table_len: *usize) void {
    // Look for c=["...",...",..."] pattern
    const marker = "c=[";
    const pos = findStr(func_body, marker) orelse return;
    var i = pos + marker.len;
    table_len.* = 0;

    // Extract characters from string literals in the array
    while (i < func_body.len and func_body[i] != ']' and table_len.* < 256) {
        if (func_body[i] == '"' or func_body[i] == '\'') {
            const quote = func_body[i];
            i += 1;
            while (i < func_body.len and func_body[i] != quote and table_len.* < 256) : (i += 1) {
                table[table_len.*] = func_body[i];
                table_len.* += 1;
            }
        }
        i += 1;
    }
}

// ── Helpers ──

fn reverseArr(arr: *[MAX_NSIG_LEN]u8, len: usize) void {
    if (len < 2) return;
    var lo: usize = 0;
    var hi: usize = len - 1;
    while (lo < hi) {
        const t = arr[lo];
        arr[lo] = arr[hi];
        arr[hi] = t;
        lo += 1;
        hi -= 1;
    }
}

fn matchAt(data: []const u8, pos: usize, pattern: []const u8) bool {
    if (pos + pattern.len > data.len) return false;
    for (0..pattern.len) |j| if (data[pos + j] != pattern[j]) return false;
    return true;
}

fn parseNumAt(data: []const u8, pos: *usize) usize {
    var val: usize = 0;
    while (pos.* < data.len and data[pos.*] >= '0' and data[pos.*] <= '9') : (pos.* += 1) {
        val = val * 10 + @as(usize, data[pos.*] - '0');
    }
    return val;
}

fn findStr(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    for (0..haystack.len - needle.len + 1) |idx| {
        var ok = true;
        for (0..needle.len) |j| if (haystack[idx + j] != needle[j]) { ok = false; break; };
        if (ok) return idx;
    }
    return null;
}

fn findStrFrom(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;
    const sub = findStr(haystack[start..], needle);
    if (sub) |s| return start + s;
    return null;
}
