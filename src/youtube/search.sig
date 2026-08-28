// @zpm/youtube/search — Video Search (Pure Sig via InnerTube)
//
// Search YouTube using the InnerTube /search endpoint.
// No yt-dlp, no API key. Direct HTTPS POST.
//
// Usage:
//   var results: [50]yt.metadata.VideoMeta = undefined;
//   const n = yt.search.query("kabbalah zohar", &results, .{});
//   const n = yt.search.inChannel("@avivsoul", "שמעתי", &results);

const meta = @import("metadata.sig");
const innertube = @import("innertube.sig");
const channel_mod = @import("channel.sig");

/// Search options (filters applied client-side after fetching).
pub const SearchOpts = struct {
    max_results: u16 = 50,
};

/// Search YouTube globally.
/// Returns number of results found (up to results.len).
pub fn query(search_query: []const u8, results: []meta.VideoMeta, opts: SearchOpts) usize {
    _ = opts;

    const resp = innertube.search(search_query);
    if (resp.len == 0) return 0;

    // Parse video renderers from search response
    return parseSearchResults(resp, results);
}

/// Search within a specific channel by scanning and filtering.
pub fn inChannel(channel_url: []const u8, search_term: []const u8, results: []meta.VideoMeta) usize {
    // Scan the full channel
    var all_videos: [8192]meta.VideoMeta = undefined;
    const total = channel_mod.scan(channel_url, &all_videos);

    // Filter by title match
    var count: usize = 0;
    for (0..total) |i| {
        if (!all_videos[i].valid) continue;
        if (count >= results.len) break;
        if (containsStr(all_videos[i].title[0..all_videos[i].title_len], search_term)) {
            results[count] = all_videos[i];
            count += 1;
        }
    }
    return count;
}

// ── Response parsing ──

fn parseSearchResults(json: []const u8, results: []meta.VideoMeta) usize {
    var count: usize = 0;
    var search_pos: usize = 0;

    // InnerTube search response has videoRenderer objects with "videoId" fields
    const marker = "\"videoId\":\"";

    while (search_pos < json.len and count < results.len) {
        const pos = findStrFrom(json, marker, search_pos) orelse break;
        const id_start = pos + marker.len;

        if (id_start + meta.VIDEO_ID_LEN > json.len) break;

        var v = meta.VideoMeta.init();
        @memcpy(&v.id, json[id_start .. id_start + meta.VIDEO_ID_LEN]);

        // Extract context around this videoId for title/duration
        const ctx_end = @min(id_start + 1000, json.len);
        const ctx = json[id_start..ctx_end];

        if (extractText(ctx)) |title| {
            const tlen = @min(title.len, meta.MAX_TITLE_LEN);
            @memcpy(v.title[0..tlen], title[0..tlen]);
            v.title_len = @intCast(tlen);
        }

        if (extractSimpleText(ctx, "\"lengthText\"")) |dur| {
            v.duration = parseDuration(dur);
        }

        v.valid = v.title_len > 0;
        if (v.valid) {
            // Dedup
            var dup = false;
            for (0..count) |i| {
                if (eqlSlice(&results[i].id, &v.id)) { dup = true; break; }
            }
            if (!dup) {
                results[count] = v;
                count += 1;
            }
        }

        search_pos = id_start + meta.VIDEO_ID_LEN;
    }

    return count;
}

fn extractText(ctx: []const u8) ?[]const u8 {
    // Look for "text":"..." (first occurrence = title in most renderers)
    const marker = "\"text\":\"";
    const pos = findStr(ctx, marker) orelse return null;
    const start = pos + marker.len;
    var end = start;
    while (end < ctx.len and !(ctx[end] == '"' and (end == start or ctx[end - 1] != '\\'))) : (end += 1) {}
    if (end > start) return ctx[start..end];
    return null;
}

fn extractSimpleText(ctx: []const u8, section: []const u8) ?[]const u8 {
    const sec_pos = findStr(ctx, section) orelse return null;
    const after = ctx[sec_pos..];
    const st_marker = "\"simpleText\":\"";
    const st_pos = findStr(after, st_marker) orelse return null;
    const start = st_pos + st_marker.len;
    var end = start;
    while (end < after.len and after[end] != '"') : (end += 1) {}
    if (end > start) return after[start..end];
    return null;
}

fn parseDuration(text: []const u8) u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var pi: usize = 0;
    for (text) |c| {
        if (c >= '0' and c <= '9') parts[pi] = parts[pi] * 10 + @as(u32, c - '0');
        if (c == ':') { pi += 1; if (pi >= 3) break; }
    }
    return switch (pi) {
        0 => parts[0],
        1 => parts[0] * 60 + parts[1],
        2 => parts[0] * 3600 + parts[1] * 60 + parts[2],
        else => 0,
    };
}

// ── Helpers ──

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    return findStr(haystack, needle) != null;
}

fn eqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
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

fn findStrFrom(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;
    const sub = findStr(haystack[start..], needle);
    if (sub) |s| return start + s;
    return null;
}
