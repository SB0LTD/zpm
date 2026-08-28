// @zpm/youtube/channel — Channel Scanning (Pure Sig via InnerTube)
//
// Lists all videos from a YouTube channel using the InnerTube browse API.
// No yt-dlp dependency. Direct HTTPS POST to YouTube's private API.
//
// Flow:
//   1. Resolve channel URL to channel ID (if needed)
//   2. Call /youtubei/v1/browse with browseId + videos tab param
//   3. Parse the JSON response for video renderers
//   4. Follow continuation tokens for pagination (channels with 1000+ videos)
//
// Usage:
//   var videos: [4096]yt.metadata.VideoMeta = undefined;
//   const n = yt.channel.scan("https://www.youtube.com/@avivsoul", &videos);

const meta = @import("metadata.sig");
const innertube = @import("innertube.sig");
const url_mod = @import("url.sig");

/// Scan a channel's videos tab. Returns number of videos found.
/// Handles pagination automatically (up to results.len videos).
pub fn scan(channel_url: []const u8, results: []meta.VideoMeta) usize {
    // Resolve to channel ID if we have a handle URL
    var channel_id: [24]u8 = undefined;
    var have_id = false;

    if (url_mod.extractChannelId(channel_url, &channel_id)) {
        have_id = true;
    } else {
        // Try fetching the channel page to find the ID
        have_id = resolveChannelId(channel_url, &channel_id);
    }

    if (!have_id) {
        // Fallback: use the URL directly as a browse target
        // For @handle URLs, InnerTube can resolve via the browse endpoint
        return scanByUrl(channel_url, results);
    }

    // Browse the channel's videos tab
    const resp = innertube.browseChannel(&channel_id);
    if (resp.len == 0) return 0;

    var count: usize = 0;

    // Parse video renderers from the response
    count += parseVideoRenderers(resp, results[count..]);

    // Follow continuation tokens for more pages
    var continuation_buf: [256]u8 = undefined;
    var cont_len = extractContinuation(resp, &continuation_buf);

    while (cont_len > 0 and count < results.len) {
        const next_resp = innertube.browseContinuation(continuation_buf[0..cont_len]);
        if (next_resp.len == 0) break;

        count += parseVideoRenderers(next_resp, results[count..]);
        cont_len = extractContinuation(next_resp, &continuation_buf);
    }

    return count;
}

/// Scan using extended metadata (fetches description too — slower, one request per video).
pub fn scanExtended(channel_url: []const u8, results: []meta.VideoMeta) usize {
    // First get basic scan
    const n = scan(channel_url, results);

    // For each video, fetch the description via player endpoint
    for (0..n) |i| {
        const player_resp = innertube.player(&results[i].id);
        if (player_resp.len > 0) {
            if (extractJsonString(player_resp, "\"shortDescription\"")) |desc| {
                const dlen = @min(desc.len, meta.MAX_DESC_LEN);
                @memcpy(results[i].description[0..dlen], desc[0..dlen]);
                results[i].desc_len = @intCast(dlen);
            }
        }
    }

    return n;
}

/// Get metadata for a single video by ID.
pub fn getVideoMeta(video_id: *const [meta.VIDEO_ID_LEN]u8, result: *meta.VideoMeta) bool {
    const resp = innertube.player(video_id);
    if (resp.len == 0) return false;

    result.* = meta.VideoMeta.init();
    @memcpy(&result.id, video_id);

    // Extract title
    if (extractJsonString(resp, "\"title\"")) |title| {
        const tlen = @min(title.len, meta.MAX_TITLE_LEN);
        @memcpy(result.title[0..tlen], title[0..tlen]);
        result.title_len = @intCast(tlen);
    }

    // Extract duration (in seconds, from "lengthSeconds")
    if (extractJsonString(resp, "\"lengthSeconds\"")) |dur_str| {
        result.duration = parseUint(dur_str);
    }

    // Extract upload date (from "publishDate" as "YYYY-MM-DD")
    if (extractJsonString(resp, "\"publishDate\"")) |date| {
        if (date.len >= 10) {
            // Convert YYYY-MM-DD to YYYYMMDD
            result.upload_date[0] = date[0];
            result.upload_date[1] = date[1];
            result.upload_date[2] = date[2];
            result.upload_date[3] = date[3];
            result.upload_date[4] = date[5];
            result.upload_date[5] = date[6];
            result.upload_date[6] = date[8];
            result.upload_date[7] = date[9];
        }
    }

    // Extract description
    if (extractJsonString(resp, "\"shortDescription\"")) |desc| {
        const dlen = @min(desc.len, meta.MAX_DESC_LEN);
        @memcpy(result.description[0..dlen], desc[0..dlen]);
        result.desc_len = @intCast(dlen);
    }

    result.valid = result.title_len > 0;
    return result.valid;
}

// ── Channel ID resolution ──

fn resolveChannelId(channel_url: []const u8, id_out: *[24]u8) bool {
    // Fetch the channel page and look for "channelId" or "externalId" in the HTML/JSON
    const page = innertube.fetchWatchPage(channel_url);
    if (page.len == 0) return false;

    // Look for "channelId":"UC..."
    if (extractJsonString(page, "\"channelId\"")) |cid| {
        if (cid.len >= 24) {
            @memcpy(id_out, cid[0..24]);
            return true;
        }
    }
    if (extractJsonString(page, "\"externalId\"")) |eid| {
        if (eid.len >= 24) {
            @memcpy(id_out, eid[0..24]);
            return true;
        }
    }
    return false;
}

fn scanByUrl(channel_url: []const u8, results: []meta.VideoMeta) usize {
    // Use InnerTube browse with the URL as a browseId proxy
    // Build a browse request with the full URL for resolution
    var extra: [512]u8 = undefined;
    var pos: usize = 0;
    const p1 = "\"browseId\":\"";
    @memcpy(extra[pos .. pos + p1.len], p1);
    pos += p1.len;
    // Try extracting handle and using "c/" prefix
    var handle_buf: [128]u8 = undefined;
    const hlen = url_mod.extractChannelHandle(channel_url, &handle_buf);
    if (hlen > 0) {
        // Format as @handle for InnerTube
        extra[pos] = '@';
        pos += 1;
        @memcpy(extra[pos .. pos + hlen], handle_buf[0..hlen]);
        pos += hlen;
    } else {
        const ulen = @min(channel_url.len, 400);
        @memcpy(extra[pos .. pos + ulen], channel_url[0..ulen]);
        pos += ulen;
    }
    const p2 = "\",\"params\":\"EgZ2aWRlb3PyBgQKAjoA\"";
    @memcpy(extra[pos .. pos + p2.len], p2);
    pos += p2.len;

    const resp = innertube.request(.browse, .web, extra[0..pos]);
    if (resp.len == 0) return 0;

    return parseVideoRenderers(resp, results);
}

// ── JSON response parsing ──

/// Parse videoRenderer objects from an InnerTube browse/search response.
/// Extracts video ID, title, upload date text, and duration from each renderer.
fn parseVideoRenderers(json: []const u8, results: []meta.VideoMeta) usize {
    var count: usize = 0;
    var search_pos: usize = 0;

    // Look for videoId patterns in the JSON response
    while (search_pos < json.len and count < results.len) {
        // Search for the literal bytes: videoId (without quotes for reliability)
        const vid_key = "videoId";
        const pos = findStrFrom(json, vid_key, search_pos) orelse break;
        // Move past "videoId" and find the value string
        var val_start = pos + vid_key.len;
        // Skip any of: ", :, space, newline, tab, carriage return
        while (val_start < json.len) : (val_start += 1) {
            const c = json[val_start];
            if (c != '"' and c != ':' and c != ' ' and c != '\n' and c != '\r' and c != '\t') break;
        }
        // val_start should now point to the first char of the video ID
        const id_start = val_start;

        if (id_start + meta.VIDEO_ID_LEN > json.len) break;

        var v = meta.VideoMeta.init();
        @memcpy(&v.id, json[id_start .. id_start + meta.VIDEO_ID_LEN]);

        // Look for title near this videoId (within next 500 chars)
        const ctx_end = @min(id_start + 1000, json.len);
        const ctx = json[id_start..ctx_end];

        // Title: "title":{"runs":[{"text":"..."}]} or "title":{"simpleText":"..."}
        if (extractJsonString(ctx, "\"text\":\"")) |title| {
            const tlen = @min(title.len, meta.MAX_TITLE_LEN);
            @memcpy(v.title[0..tlen], title[0..tlen]);
            v.title_len = @intCast(tlen);
        } else if (extractJsonString(ctx, "\"simpleText\":\"")) |title| {
            const tlen = @min(title.len, meta.MAX_TITLE_LEN);
            @memcpy(v.title[0..tlen], title[0..tlen]);
            v.title_len = @intCast(tlen);
        }

        // Duration: "lengthText":{"simpleText":"HH:MM:SS"} → convert to seconds
        if (extractJsonString(ctx, "\"lengthText\"")) |_| {
            if (extractJsonString(ctx, "\"simpleText\":\"")) |dur_text| {
                v.duration = parseDurationText(dur_text);
            }
        }

        // Published: "publishedTimeText":{"simpleText":"X days/months/years ago"}
        // This is relative, not absolute — we'll leave upload_date as 00000000
        // unless we can find an absolute date elsewhere

        v.valid = true; // Accept any valid video ID (title may not be in first 1000 chars)
        if (v.title_len == 0) {
            // Set a placeholder title with the video ID
            @memcpy(v.title[0..11], &v.id);
            v.title_len = 11;
        }
        if (v.valid) {
            // Dedup: skip if we already have this video ID
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

/// Extract continuation token for next page.
fn extractContinuation(json: []const u8, out: *[256]u8) usize {
    const marker = "\"continuation\":\"";
    // Find the LAST continuation token (pagination is at the end)
    var last_pos: ?usize = null;
    var search: usize = 0;
    while (findStrFrom(json, marker, search)) |pos| {
        last_pos = pos;
        search = pos + 1;
    }

    const pos = last_pos orelse return 0;
    const start = pos + marker.len;
    var end = start;
    while (end < json.len and json[end] != '"') : (end += 1) {}
    const len = @min(end - start, 256);
    if (len == 0) return 0;
    @memcpy(out[0..len], json[start .. start + len]);
    return len;
}

/// Parse duration text "HH:MM:SS" or "MM:SS" to seconds.
fn parseDurationText(text: []const u8) u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var part_idx: usize = 0;

    for (text) |c| {
        if (c >= '0' and c <= '9') {
            parts[part_idx] = parts[part_idx] * 10 + @as(u32, c - '0');
        } else if (c == ':') {
            part_idx += 1;
            if (part_idx >= 3) break;
        }
    }

    return switch (part_idx) {
        0 => parts[0], // just seconds
        1 => parts[0] * 60 + parts[1], // MM:SS
        2 => parts[0] * 3600 + parts[1] * 60 + parts[2], // HH:MM:SS
        else => 0,
    };
}

// ── Helpers ──

fn extractJsonString(data: []const u8, key: []const u8) ?[]const u8 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    // Skip to opening quote if not already there
    while (i < data.len and data[i] != '"') : (i += 1) {
        if (data[i] == ':' or data[i] == ' ') continue;
        break;
    }
    if (i < data.len and data[i] == '"') i += 1;
    if (i >= data.len) return null;
    // If key already ended with a quote, we're at the value start
    if (key[key.len - 1] == '"') {
        // Already past the opening quote
        const start = kpos + key.len;
        var end = start;
        while (end < data.len and !(data[end] == '"' and (end == start or data[end - 1] != '\\'))) : (end += 1) {}
        if (end > start) return data[start..end];
        return null;
    }
    // General case
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i >= data.len) return null;
    i += 1;
    const start = i;
    while (i < data.len and !(data[i] == '"' and data[i - 1] != '\\')) : (i += 1) {}
    if (i > start) return data[start..i];
    return null;
}

fn parseUint(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| { if (c >= '0' and c <= '9') v = v * 10 + @as(u32, c - '0'); }
    return v;
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
