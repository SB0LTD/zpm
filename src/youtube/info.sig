// @zpm/youtube/info — Detailed Video Information (Pure Sig via InnerTube)
//
// Fetches comprehensive metadata for a single video via the InnerTube player endpoint.
// No yt-dlp, no subprocess. Direct HTTPS POST.
//
// Returns: chapters, view count, like count, channel info, description,
// tags, categories, live status, age restriction.

const meta = @import("metadata.sig");
const innertube = @import("innertube.sig");

/// Chapter marker within a video.
pub const Chapter = struct {
    start_time: u32, // seconds
    title: [128]u8,
    title_len: u8,
};

/// Extended video information.
pub const VideoInfo = struct {
    base: meta.VideoMeta,
    channel_name: [128]u8,
    channel_name_len: u8,
    channel_id: [24]u8,
    view_count: u64,
    like_count: u32,
    comment_count: u32,
    tags: [16][32]u8,
    tag_lengths: [16]u8,
    n_tags: u8,
    chapters: [64]Chapter,
    n_chapters: u8,
    is_live: bool,
    was_live: bool,
    age_restricted: bool,

    pub fn init() VideoInfo {
        return .{
            .base = meta.VideoMeta.init(),
            .channel_name = undefined,
            .channel_name_len = 0,
            .channel_id = undefined,
            .view_count = 0,
            .like_count = 0,
            .comment_count = 0,
            .tags = undefined,
            .tag_lengths = @splat(@as(u8, 0)),
            .n_tags = 0,
            .chapters = undefined,
            .n_chapters = 0,
            .is_live = false,
            .was_live = false,
            .age_restricted = false,
        };
    }
};

/// Fetch detailed info for a video.
pub fn fetch(video_id: *const [meta.VIDEO_ID_LEN]u8, result: *VideoInfo) bool {
    const resp = innertube.player(video_id);
    if (resp.len == 0) return false;

    result.* = VideoInfo.init();
    @memcpy(&result.base.id, video_id);

    // Title
    if (extractJsonStr(resp, "\"title\"")) |v| {
        const tlen = @min(v.len, meta.MAX_TITLE_LEN);
        @memcpy(result.base.title[0..tlen], v[0..tlen]);
        result.base.title_len = @intCast(tlen);
    }

    // Duration
    if (extractJsonStr(resp, "\"lengthSeconds\"")) |v| {
        result.base.duration = parseUint(v);
    }

    // Upload date
    if (extractJsonStr(resp, "\"publishDate\"")) |v| {
        if (v.len >= 10) {
            result.base.upload_date[0] = v[0]; result.base.upload_date[1] = v[1];
            result.base.upload_date[2] = v[2]; result.base.upload_date[3] = v[3];
            result.base.upload_date[4] = v[5]; result.base.upload_date[5] = v[6];
            result.base.upload_date[6] = v[8]; result.base.upload_date[7] = v[9];
        }
    }

    // Description
    if (extractJsonStr(resp, "\"shortDescription\"")) |v| {
        const dlen = @min(v.len, meta.MAX_DESC_LEN);
        @memcpy(result.base.description[0..dlen], v[0..dlen]);
        result.base.desc_len = @intCast(dlen);
    }

    // Channel
    if (extractJsonStr(resp, "\"author\"")) |v| {
        const clen = @min(v.len, 128);
        @memcpy(result.channel_name[0..clen], v[0..clen]);
        result.channel_name_len = @intCast(clen);
    }
    if (extractJsonStr(resp, "\"channelId\"")) |v| {
        if (v.len >= 24) @memcpy(&result.channel_id, v[0..24]);
    }

    // View count
    if (extractJsonStr(resp, "\"viewCount\"")) |v| {
        result.view_count = parseU64(v);
    }

    // Live status
    if (extractJsonBool(resp, "\"isLive\"")) |v| result.is_live = v;
    if (extractJsonBool(resp, "\"isLiveContent\"")) |v| result.was_live = v;

    // Keywords/tags
    result.n_tags = 0;
    var tag_search: usize = 0;
    const kw_marker = "\"keywords\"";
    if (findStr(resp, kw_marker)) |kw_pos| {
        tag_search = kw_pos;
        // Parse array of strings: ["tag1","tag2",...]
        while (result.n_tags < 16 and tag_search < resp.len) {
            const q_pos = findStrFrom(resp, "\"", tag_search + 1) orelse break;
            if (resp[q_pos] != '"') break;
            const t_start = q_pos + 1;
            var t_end = t_start;
            while (t_end < resp.len and resp[t_end] != '"') : (t_end += 1) {}
            if (t_end <= t_start) break;
            const tlen = @min(t_end - t_start, 32);
            @memcpy(result.tags[result.n_tags][0..tlen], resp[t_start .. t_start + tlen]);
            result.tag_lengths[result.n_tags] = @intCast(tlen);
            result.n_tags += 1;
            tag_search = t_end + 1;
            // Stop at array close
            if (tag_search < resp.len and resp[tag_search] == ']') break;
        }
    }

    // Chapters (from "chapters" in playerMicroformatRenderer)
    result.n_chapters = 0;
    if (findStr(resp, "\"chapters\"")) |ch_pos| {
        var ch_search = ch_pos;
        while (result.n_chapters < 64) {
            // Find "title":{"simpleText":"..."} and "startTimeMs"
            const title_pos = findStrFrom(resp, "\"title\"", ch_search) orelse break;
            const ms_pos = findStrFrom(resp, "\"startTimeMs\"", ch_search) orelse break;

            if (title_pos > ch_pos + 10000) break; // too far, left the chapters array

            // Extract chapter title
            var ch = Chapter{ .start_time = 0, .title = undefined, .title_len = 0 };
            const ctx = resp[title_pos..@min(title_pos + 200, resp.len)];
            if (extractJsonStr(ctx, "\"simpleText\"")) |t| {
                const tl = @min(t.len, 128);
                @memcpy(ch.title[0..tl], t[0..tl]);
                ch.title_len = @intCast(tl);
            }

            // Extract start time (milliseconds → seconds)
            const ms_ctx = resp[ms_pos..@min(ms_pos + 40, resp.len)];
            if (extractJsonStr(ms_ctx, "\"startTimeMs\"")) |ms| {
                ch.start_time = @intCast(parseU64(ms) / 1000);
            }

            if (ch.title_len > 0) {
                result.chapters[result.n_chapters] = ch;
                result.n_chapters += 1;
            }
            ch_search = @max(title_pos, ms_pos) + 1;
        }
    }

    result.base.valid = result.base.title_len > 0;
    return result.base.valid;
}

/// Get raw player JSON (for custom parsing).
pub fn fetchRaw(video_id: *const [meta.VIDEO_ID_LEN]u8) []const u8 {
    return innertube.player(video_id);
}

// ── Helpers ──

fn extractJsonStr(data: []const u8, key: []const u8) ?[]const u8 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i >= data.len) return null;
    i += 1;
    const start = i;
    while (i < data.len and !(data[i] == '"' and (i == start or data[i - 1] != '\\'))) : (i += 1) {}
    if (i > start) return data[start..i];
    return null;
}

fn extractJsonBool(data: []const u8, key: []const u8) ?bool {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ')) : (i += 1) {}
    if (i + 4 <= data.len and data[i] == 't') return true;
    if (i + 5 <= data.len and data[i] == 'f') return false;
    return null;
}

fn parseUint(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| { if (c >= '0' and c <= '9') v = v * 10 + @as(u32, c - '0'); }
    return v;
}

fn parseU64(s: []const u8) u64 {
    var v: u64 = 0;
    for (s) |c| { if (c >= '0' and c <= '9') v = v * 10 + @as(u64, c - '0'); }
    return v;
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
