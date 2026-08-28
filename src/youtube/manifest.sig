// @zpm/youtube/manifest — Adaptive Format / DASH Manifest Parser
//
// Parses the streaming data from InnerTube player response to extract
// available audio/video streams with their URLs, codecs, bitrates.
//
// YouTube returns streams in two categories:
//   formats[]         — muxed streams (audio+video together, lower quality)
//   adaptiveFormats[] — separate audio and video streams (higher quality)
//
// Each format entry contains:
//   - itag (format ID)
//   - url (direct stream URL, if not cipher-encrypted)
//   - signatureCipher (encrypted URL + signature, if cipher-protected)
//   - mimeType (e.g., "audio/webm; codecs=\"opus\"")
//   - bitrate
//   - contentLength
//   - audioQuality / qualityLabel
//
// For gotliv (audio-only ASR pipeline), we want:
//   itag 251 — opus 160kbps (highest quality audio)
//   itag 140 — m4a AAC 128kbps (widely compatible)
//   itag 250 — opus 70kbps (good balance)
//   itag 249 — opus 50kbps (smallest)

const cipher_mod = @import("cipher.sig");
const nsig_mod = @import("nsig.sig");

/// Audio codec preference.
pub const AudioCodec = enum {
    opus, // WebM/Opus (best quality per bitrate)
    aac, // M4A/AAC (most compatible)
    any, // best available
};

/// Parsed stream format.
pub const StreamFormat = struct {
    itag: u16,
    url: [2048]u8, // decrypted stream URL
    url_len: u16,
    mime_type: [64]u8,
    mime_len: u8,
    bitrate: u32,
    content_length: u64,
    sample_rate: u32,
    channels: u8,
    is_audio: bool,
    is_video: bool,
    quality_label: [16]u8, // "360p", "720p", etc.
    quality_len: u8,
    has_cipher: bool, // was cipher-encrypted (now decrypted)
};

pub const MAX_FORMATS: usize = 64;

/// Parse streaming data from a player response JSON.
/// Extracts all available formats with decrypted URLs.
/// Returns number of formats parsed.
pub fn parseFormats(player_json: []const u8, formats: []StreamFormat) usize {
    var count: usize = 0;

    // Find "adaptiveFormats" array (higher quality, separate audio/video)
    if (findStr(player_json, "\"adaptiveFormats\"")) |af_pos| {
        count += parseFormatArray(player_json[af_pos..], formats[count..]);
    }

    // Find "formats" array (muxed, lower quality)
    if (findStr(player_json, "\"formats\"")) |f_pos| {
        count += parseFormatArray(player_json[f_pos..], formats[count..]);
    }

    return count;
}

/// Select the best audio stream from parsed formats.
/// Preference: highest bitrate matching the requested codec.
pub fn selectBestAudio(formats: []const StreamFormat, n_formats: usize, codec_pref: AudioCodec) ?*const StreamFormat {
    var best: ?*const StreamFormat = null;
    var best_bitrate: u32 = 0;

    for (0..n_formats) |i| {
        if (!formats[i].is_audio) continue;
        if (formats[i].url_len == 0) continue;

        const mime = formats[i].mime_type[0..formats[i].mime_len];

        // Filter by codec preference
        switch (codec_pref) {
            .opus => {
                if (!containsStr(mime, "opus")) continue;
            },
            .aac => {
                if (!containsStr(mime, "mp4a") and !containsStr(mime, "aac")) continue;
            },
            .any => {},
        }

        if (formats[i].bitrate > best_bitrate) {
            best_bitrate = formats[i].bitrate;
            best = &formats[i];
        }
    }

    return best;
}

/// Select the best video stream.
pub fn selectBestVideo(formats: []const StreamFormat, n_formats: usize) ?*const StreamFormat {
    var best: ?*const StreamFormat = null;
    var best_bitrate: u32 = 0;

    for (0..n_formats) |i| {
        if (!formats[i].is_video) continue;
        if (formats[i].url_len == 0) continue;
        if (formats[i].bitrate > best_bitrate) {
            best_bitrate = formats[i].bitrate;
            best = &formats[i];
        }
    }
    return best;
}

// ── Format array parsing ──

fn parseFormatArray(json: []const u8, formats: []StreamFormat) usize {
    var count: usize = 0;

    // Find the opening [ of the array
    var pos: usize = 0;
    while (pos < json.len and json[pos] != '[') : (pos += 1) {}
    if (pos >= json.len) return 0;
    pos += 1;

    // Parse each format object {...}
    while (pos < json.len and count < formats.len) {
        // Find next {
        while (pos < json.len and json[pos] != '{') : (pos += 1) {
            if (json[pos] == ']') return count; // end of array
        }
        if (pos >= json.len) break;

        // Find matching }
        const obj_start = pos;
        var depth: usize = 0;
        while (pos < json.len) : (pos += 1) {
            if (json[pos] == '{') depth += 1;
            if (json[pos] == '}') {
                depth -= 1;
                if (depth == 0) { pos += 1; break; }
            }
        }
        const obj = json[obj_start..pos];

        if (parseOneFormat(obj, &formats[count])) {
            count += 1;
        }
    }
    return count;
}

fn parseOneFormat(obj: []const u8, fmt: *StreamFormat) bool {
    fmt.* = StreamFormat{
        .itag = 0,
        .url = undefined,
        .url_len = 0,
        .mime_type = undefined,
        .mime_len = 0,
        .bitrate = 0,
        .content_length = 0,
        .sample_rate = 0,
        .channels = 0,
        .is_audio = false,
        .is_video = false,
        .quality_label = undefined,
        .quality_len = 0,
        .has_cipher = false,
    };

    // itag
    if (extractInt(obj, "\"itag\"")) |v| fmt.itag = @intCast(v);
    if (fmt.itag == 0) return false;

    // mimeType
    if (extractString(obj, "\"mimeType\"")) |v| {
        const mlen = @min(v.len, 64);
        @memcpy(fmt.mime_type[0..mlen], v[0..mlen]);
        fmt.mime_len = @intCast(mlen);
        fmt.is_audio = containsStr(v, "audio/");
        fmt.is_video = containsStr(v, "video/");
    }

    // bitrate
    if (extractInt(obj, "\"bitrate\"")) |v| fmt.bitrate = @intCast(v);

    // contentLength
    if (extractString(obj, "\"contentLength\"")) |v| {
        fmt.content_length = parseU64(v);
    }

    // audioSampleRate
    if (extractString(obj, "\"audioSampleRate\"")) |v| {
        fmt.sample_rate = @intCast(parseU64(v));
    }

    // audioChannels
    if (extractInt(obj, "\"audioChannels\"")) |v| fmt.channels = @intCast(v);

    // qualityLabel
    if (extractString(obj, "\"qualityLabel\"")) |v| {
        const qlen = @min(v.len, 16);
        @memcpy(fmt.quality_label[0..qlen], v[0..qlen]);
        fmt.quality_len = @intCast(qlen);
    }

    // URL: either direct "url" field or "signatureCipher" that needs decryption
    if (extractString(obj, "\"url\"")) |url_val| {
        const ulen = @min(url_val.len, 2048);
        @memcpy(fmt.url[0..ulen], url_val[0..ulen]);
        fmt.url_len = @intCast(ulen);
    } else if (extractString(obj, "\"signatureCipher\"")) |sc| {
        // Parse signatureCipher: "s=XXX&sp=sig&url=XXX"
        decryptCipherUrl(sc, fmt);
    }

    // Apply nsig transform if URL has an "n" parameter
    if (fmt.url_len > 0) {
        applyNsig(fmt);
    }

    return fmt.url_len > 0 or fmt.itag > 0;
}

fn decryptCipherUrl(cipher_str: []const u8, fmt: *StreamFormat) void {
    // URL-decode the cipher string first
    var decoded: [2048]u8 = undefined;
    const dec_len = urlDecode(cipher_str, &decoded);
    const sc = decoded[0..dec_len];

    // Extract components: s=...&sp=...&url=...
    var sig: []const u8 = "";
    var sp: []const u8 = "sig";
    var base_url: []const u8 = "";

    // Find s= (signature)
    if (findParam(sc, "s=")) |s_start| {
        var s_end = s_start;
        while (s_end < sc.len and sc[s_end] != '&') : (s_end += 1) {}
        sig = sc[s_start..s_end];
    }

    // Find sp= (signature parameter name)
    if (findParam(sc, "sp=")) |sp_start| {
        var sp_end = sp_start;
        while (sp_end < sc.len and sc[sp_end] != '&') : (sp_end += 1) {}
        sp = sc[sp_start..sp_end];
    }

    // Find url=
    if (findParam(sc, "url=")) |url_start| {
        var url_end = url_start;
        while (url_end < sc.len and sc[url_end] != '&') : (url_end += 1) {}
        base_url = sc[url_start..url_end];
    }

    if (base_url.len == 0) return;

    // URL-decode the base URL
    var url_dec: [2048]u8 = undefined;
    const url_dec_len = urlDecode(base_url, &url_dec);

    // Decrypt the signature
    var decrypted_sig: [256]u8 = undefined;
    const sig_len = cipher_mod.decryptSignature(sig, &decrypted_sig);
    if (sig_len == 0) {
        // Cipher not loaded — store URL without sig (may not work)
        const ulen = @min(url_dec_len, 2048);
        @memcpy(fmt.url[0..ulen], url_dec[0..ulen]);
        fmt.url_len = @intCast(ulen);
        return;
    }

    // Append &sp=decrypted_sig to URL
    var pos: usize = 0;
    @memcpy(fmt.url[0..url_dec_len], url_dec[0..url_dec_len]);
    pos = url_dec_len;
    fmt.url[pos] = '&';
    pos += 1;
    @memcpy(fmt.url[pos .. pos + sp.len], sp);
    pos += sp.len;
    fmt.url[pos] = '=';
    pos += 1;
    @memcpy(fmt.url[pos .. pos + sig_len], decrypted_sig[0..sig_len]);
    pos += sig_len;
    fmt.url_len = @intCast(pos);
    fmt.has_cipher = true;
}

fn applyNsig(fmt: *StreamFormat) void {
    // Find &n= parameter in URL
    const url_slice = fmt.url[0..fmt.url_len];
    const n_pos = findParam(url_slice, "&n=") orelse findParam(url_slice, "?n=") orelse return;
    var n_end = n_pos;
    while (n_end < url_slice.len and url_slice[n_end] != '&') : (n_end += 1) {}
    const n_param = url_slice[n_pos..n_end];

    // Transform
    var transformed: [nsig_mod.MAX_NSIG_LEN]u8 = undefined;
    const new_len = nsig_mod.transform(n_param, &transformed);
    if (new_len == 0) return; // nsig transform failed, use original (throttled)

    // Replace the n parameter in the URL
    // This is complex to do in-place, so rebuild the URL
    var new_url: [2048]u8 = undefined;
    var new_pos: usize = 0;
    // Copy before n param
    const param_start = findStr(url_slice, "&n=") orelse findStr(url_slice, "?n=") orelse return;
    @memcpy(new_url[0..param_start], url_slice[0..param_start]);
    new_pos = param_start;
    // Write new n param
    const sep: u8 = url_slice[param_start]; // '&' or '?'
    new_url[new_pos] = sep;
    new_pos += 1;
    new_url[new_pos] = 'n';
    new_pos += 1;
    new_url[new_pos] = '=';
    new_pos += 1;
    @memcpy(new_url[new_pos .. new_pos + new_len], transformed[0..new_len]);
    new_pos += new_len;
    // Copy after n param
    if (n_end < url_slice.len) {
        const remaining = url_slice.len - n_end;
        @memcpy(new_url[new_pos .. new_pos + remaining], url_slice[n_end .. n_end + remaining]);
        new_pos += remaining;
    }

    const final_len = @min(new_pos, 2048);
    @memcpy(fmt.url[0..final_len], new_url[0..final_len]);
    fmt.url_len = @intCast(final_len);
}

// ── Helpers ──

fn urlDecode(src: []const u8, dst: *[2048]u8) usize {
    var si: usize = 0;
    var di: usize = 0;
    while (si < src.len and di < 2048) {
        if (src[si] == '%' and si + 2 < src.len) {
            dst[di] = (hexVal(src[si + 1]) << 4) | hexVal(src[si + 2]);
            si += 3;
        } else if (src[si] == '+') {
            dst[di] = ' ';
            si += 1;
        } else {
            dst[di] = src[si];
            si += 1;
        }
        di += 1;
    }
    return di;
}

fn hexVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

fn findParam(data: []const u8, key: []const u8) ?usize {
    const pos = findStr(data, key) orelse return null;
    return pos + key.len;
}

fn extractString(data: []const u8, key: []const u8) ?[]const u8 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i >= data.len) return null;
    i += 1;
    const start = i;
    while (i < data.len and !(data[i] == '"' and data[i - 1] != '\\')) : (i += 1) {}
    if (i > start) return data[start..i];
    return null;
}

fn extractInt(data: []const u8, key: []const u8) ?u64 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ')) : (i += 1) {}
    if (i >= data.len or data[i] < '0' or data[i] > '9') return null;
    var v: u64 = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        v = v * 10 + @as(u64, data[i] - '0');
    }
    return v;
}

fn parseU64(s: []const u8) u64 {
    var v: u64 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') v = v * 10 + @as(u64, c - '0');
    }
    return v;
}

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    return findStr(haystack, needle) != null;
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
