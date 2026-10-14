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
    url: [8192]u8, // decrypted stream URL
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
    // ── SABR selection fields ──
    // SABR keys formats by (itag, lastModified), not by URL, and the request
    // builder embeds initRange/indexRange + xtags. Populated from the same
    // adaptiveFormats JSON object (zero/empty when the fields are absent).
    last_modified: u64 = 0, // "lastModified" (microseconds, aka lmt)
    xtags: [96]u8 = undefined, // "xtags" (opaque format discriminator)
    xtags_len: u8 = 0,
    init_start: u32 = 0, // "initRange".start
    init_end: u32 = 0, // "initRange".end
    index_start: u32 = 0, // "indexRange".start
    index_end: u32 = 0, // "indexRange".end
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
        if (!formats[i].is_audio or formats[i].is_video) continue;
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

/// Select a specific directly downloadable itag.
pub fn selectByItag(formats: []const StreamFormat, n_formats: usize, itag: u16) ?*const StreamFormat {
    for (0..n_formats) |i| {
        if (formats[i].itag == itag and formats[i].url_len != 0) return &formats[i];
    }
    return null;
}

/// Select a format for SABR by itag (SABR does not need a direct URL — it
/// identifies the format by (itag, lastModified) inside the request protobuf,
/// so unlike `selectByItag` this does NOT require `url_len != 0`).
pub fn selectBySabr(formats: []const StreamFormat, n_formats: usize, itag: u16) ?*const StreamFormat {
    for (0..n_formats) |i| {
        if (formats[i].itag == itag) return &formats[i];
    }
    return null;
}

/// Select metadata for SABR when the player supplies no direct stream URLs.
/// A complete FormatId (itag + lastModified) is required by the POST protocol.
pub fn selectBestSabr(formats: []const StreamFormat, n_formats: usize, audio: bool) ?*const StreamFormat {
    return selectBestSabrWithCodec(formats, n_formats, audio, .any);
}

/// SABR selection honors the requested audio codec as strictly as direct
/// selection. This prevents an AAC request producing Opus under an M4A path.
pub fn selectBestSabrWithCodec(formats: []const StreamFormat, n_formats: usize, audio: bool, codec: AudioCodec) ?*const StreamFormat {
    var best: ?*const StreamFormat = null;
    for (formats[0..@min(n_formats, formats.len)]) |*fmt| {
        if (fmt.itag == 0 or fmt.last_modified == 0) continue;
        if (audio) {
            if (!fmt.is_audio or fmt.is_video) continue;
            const mime = fmt.mime_type[0..fmt.mime_len];
            if (codec == .aac and !containsStr(mime, "mp4a") and !containsStr(mime, "aac")) continue;
            if (codec == .opus and !containsStr(mime, "opus")) continue;
        } else if (!fmt.is_video) continue;
        if (best == null or fmt.bitrate > best.?.bitrate) best = fmt;
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

/// Select a complete video containing both video and audio tracks.
pub fn selectBestMuxed(formats: []const StreamFormat, n_formats: usize) ?*const StreamFormat {
    var best: ?*const StreamFormat = null;
    for (formats[0..@min(n_formats, formats.len)]) |*fmt| {
        if (!fmt.is_video or !fmt.is_audio or fmt.url_len == 0) continue;
        if (best == null or fmt.bitrate > best.?.bitrate) best = fmt;
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
        var in_string = false;
        while (pos < json.len) : (pos += 1) {
            if (in_string and json[pos] == '\\' and pos + 1 < json.len) { pos += 1; continue; }
            if (json[pos] == '"') { in_string = !in_string; continue; }
            if (in_string) continue;
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
        .last_modified = 0,
        .xtags = undefined,
        .xtags_len = 0,
        .init_start = 0,
        .init_end = 0,
        .index_start = 0,
        .index_end = 0,
    };

    // itag
    if (extractInt(obj, "\"itag\"")) |v| {
        if (v > 65535) return false;
        fmt.itag = @intCast(v);
    }
    if (fmt.itag == 0) return false;

    // mimeType
    if (extractString(obj, "\"mimeType\"")) |v| {
        const mlen = jsonUnescape(v, &fmt.mime_type);
        fmt.mime_len = @intCast(mlen);
        const mime = fmt.mime_type[0..mlen];
        fmt.is_video = containsStr(mime, "video/");
        fmt.is_audio = containsStr(mime, "audio/") or
            (fmt.is_video and (containsStr(mime, "mp4a") or containsStr(mime, "opus") or containsStr(mime, "vorbis")));
    }

    // bitrate
    if (extractInt(obj, "\"bitrate\"")) |v| fmt.bitrate = @intCast(@min(v, 0xFFFFFFFF));

    // contentLength
    if (extractString(obj, "\"contentLength\"")) |v| {
        fmt.content_length = parseU64(v);
    }

    // ── SABR selection fields ──
    // lastModified (lmt) — a bare integer or quoted string depending on client.
    if (extractInt(obj, "\"lastModified\"")) |v| {
        fmt.last_modified = v;
    } else if (extractString(obj, "\"lastModified\"")) |v| {
        fmt.last_modified = parseU64(v);
    }
    // xtags — opaque string discriminator used alongside (itag, lmt).
    if (extractString(obj, "\"xtags\"")) |v| {
        const xlen = @min(v.len, fmt.xtags.len);
        @memcpy(fmt.xtags[0..xlen], v[0..xlen]);
        fmt.xtags_len = @intCast(xlen);
    }
    // initRange / indexRange — {"start":"N","end":"M"} objects.
    if (extractObject(obj, "\"initRange\"")) |rng| {
        if (extractString(rng, "\"start\"")) |s| fmt.init_start = @intCast(@min(parseU64(s), 0xFFFFFFFF));
        if (extractString(rng, "\"end\"")) |e| fmt.init_end = @intCast(@min(parseU64(e), 0xFFFFFFFF));
    }
    if (extractObject(obj, "\"indexRange\"")) |rng| {
        if (extractString(rng, "\"start\"")) |s| fmt.index_start = @intCast(@min(parseU64(s), 0xFFFFFFFF));
        if (extractString(rng, "\"end\"")) |e| fmt.index_end = @intCast(@min(parseU64(e), 0xFFFFFFFF));
    }

    // audioSampleRate
    if (extractString(obj, "\"audioSampleRate\"")) |v| {
        fmt.sample_rate = @intCast(@min(parseU64(v), 0xFFFFFFFF));
    }

    // audioChannels
    if (extractInt(obj, "\"audioChannels\"")) |v| fmt.channels = @intCast(@min(v, 255));
    if (fmt.channels > 0 or fmt.sample_rate > 0) fmt.is_audio = true;

    // qualityLabel
    if (extractString(obj, "\"qualityLabel\"")) |v| {
        const qlen = jsonUnescape(v, &fmt.quality_label);
        fmt.quality_len = @intCast(qlen);
    }

    // URL: either direct "url" field or "signatureCipher" that needs decryption
    if (extractString(obj, "\"url\"")) |url_val| {
        const ulen = jsonUnescape(url_val, &fmt.url);
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
    // Split the encoded form before decoding its values: decoding the entire
    // form would turn URL query %26 bytes into form separators and truncate it.
    var decoded: [8192]u8 = undefined;
    const dec_len = jsonUnescape(cipher_str, &decoded);
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
    var url_dec: [8192]u8 = undefined;
    const url_dec_len = urlDecode(base_url, &url_dec);
    if (url_dec_len == 0) return;

    var sig_dec: [256]u8 = undefined;
    const sig_dec_len = urlDecode(sig, &sig_dec);
    var sp_dec: [32]u8 = undefined;
    const sp_dec_len = urlDecode(sp, &sp_dec);
    if (sp_dec_len == 0) return;
    if (sig.len == 0) {
        @memcpy(fmt.url[0..url_dec_len], url_dec[0..url_dec_len]);
        fmt.url_len = @intCast(url_dec_len);
        return;
    }

    // Decrypt the signature
    var decrypted_sig: [256]u8 = undefined;
    const sig_len = cipher_mod.decryptSignature(sig_dec[0..sig_dec_len], &decrypted_sig);
    if (sig_len == 0 or url_dec_len + sp_dec_len + sig_len + 2 > fmt.url.len) return;

    // Append &sp=decrypted_sig to URL
    var pos: usize = 0;
    @memcpy(fmt.url[0..url_dec_len], url_dec[0..url_dec_len]);
    pos = url_dec_len;
    fmt.url[pos] = '&';
    pos += 1;
    @memcpy(fmt.url[pos .. pos + sp_dec_len], sp_dec[0..sp_dec_len]);
    pos += sp_dec_len;
    fmt.url[pos] = '=';
    pos += 1;
    @memcpy(fmt.url[pos .. pos + sig_len], decrypted_sig[0..sig_len]);
    pos += sig_len;
    fmt.url_len = @intCast(pos);
    fmt.has_cipher = true;
}

/// Apply the same n transform to a SABR endpoint or another unescaped stream URL.
/// Returns zero when its required transform cannot be produced natively.
pub fn transformStreamUrl(url: []const u8, out: []u8) usize {
    var fmt: StreamFormat = undefined;
    if (url.len > fmt.url.len or url.len > out.len) return 0;
    @memcpy(fmt.url[0..url.len], url);
    fmt.url_len = @intCast(url.len);
    applyNsig(&fmt);
    if (fmt.url_len > out.len) return 0;
    @memcpy(out[0..fmt.url_len], fmt.url[0..fmt.url_len]);
    return fmt.url_len;
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
    if (new_len == 0 or url_slice.len - n_param.len + new_len > fmt.url.len) {
        fmt.url_len = 0;
        return;
    }

    // Replace the n parameter in the URL
    // This is complex to do in-place, so rebuild the URL
    var new_url: [8192]u8 = undefined;
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

    const final_len = @min(new_pos, 8192);
    @memcpy(fmt.url[0..final_len], new_url[0..final_len]);
    fmt.url_len = @intCast(final_len);
}

// ── Helpers ──

fn urlDecode(src: []const u8, dst: []u8) usize {
    var si: usize = 0;
    var di: usize = 0;
    while (si < src.len and di < dst.len) {
        if (src[si] == '%') {
            if (si + 2 >= src.len or !isHex(src[si + 1]) or !isHex(src[si + 2])) return 0;
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
    return if (si == src.len) di else 0;
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn jsonUnescape(src: []const u8, dst: []u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < src.len) {
        if (n >= dst.len) return 0;
        var c = src[i];
        i += 1;
        if (c == '\\') {
            if (i >= src.len) return 0;
            c = src[i];
            i += 1;
            switch (c) {
                '"', '\\', '/' => {},
                'n' => c = '\n', 'r' => c = '\r', 't' => c = '\t',
                'b' => c = 8, 'f' => c = 12,
                'u' => {
                    if (i + 4 > src.len) return 0;
                    for (src[i..i + 4]) |h| if (!isHex(h)) return 0;
                    const cp = (@as(u16, hexVal(src[i])) << 12) | (@as(u16, hexVal(src[i + 1])) << 8) |
                        (@as(u16, hexVal(src[i + 2])) << 4) | @as(u16, hexVal(src[i + 3]));
                    i += 4;
                    if (cp >= 0x80) {
                        if (cp < 0x800) {
                            if (n + 2 > dst.len) return 0;
                            dst[n] = @intCast(0xC0 | (cp >> 6)); n += 1;
                        } else {
                            if (n + 3 > dst.len or (cp >= 0xD800 and cp <= 0xDFFF)) return 0;
                            dst[n] = @intCast(0xE0 | (cp >> 12)); n += 1;
                            dst[n] = @intCast(0x80 | ((cp >> 6) & 63)); n += 1;
                        }
                        c = @intCast(0x80 | (cp & 63));
                    } else c = @intCast(cp);
                },
                else => return 0,
            }
        }
        dst[n] = c;
        n += 1;
    }
    return n;
}

fn hexVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

fn findParam(data: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    while (i + key.len <= data.len) : (i += 1) {
        if (key[0] != '&' and key[0] != '?' and i > 0 and data[i - 1] != '&') continue;
        var ok = true;
        for (key, 0..) |c, j| if (data[i + j] != c) { ok = false; break; };
        if (ok) return i + key.len;
    }
    return null;
}

fn extractString(data: []const u8, key: []const u8) ?[]const u8 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i >= data.len) return null;
    i += 1;
    const start = i;
    while (i < data.len and data[i] != '"') : (i += 1) {
        if (data[i] == '\\') {
            if (i + 1 >= data.len) return null;
            i += 1;
        }
    }
    if (i < data.len and i > start) return data[start..i];
    return null;
}

/// Extract a JSON object value ({...}) for `key`, returning the slice spanning
/// the braces (inclusive). Used for nested initRange/indexRange objects.
fn extractObject(data: []const u8, key: []const u8) ?[]const u8 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and data[i] != '{') : (i += 1) {
        if (data[i] == ',' or data[i] == '}' or data[i] == ']') return null;
    }
    if (i >= data.len) return null;
    const start = i;
    var depth: usize = 0;
    var in_string = false;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_string) {
            if (c == '\\') { i += 1; continue; }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') { in_string = true; continue; }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return data[start .. i + 1];
        }
    }
    return null;
}

fn extractInt(data: []const u8, key: []const u8) ?u64 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ' or data[i] == '\n' or data[i] == '\r' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len or data[i] < '0' or data[i] > '9') return null;
    var v: u64 = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        const digit: u64 = data[i] - '0';
        if (v > (0xFFFFFFFFFFFFFFFF - digit) / 10) return null;
        v = v * 10 + digit;
    }
    return v;
}

fn parseU64(s: []const u8) u64 {
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return 0;
        const digit: u64 = c - '0';
        if (v > (0xFFFFFFFFFFFFFFFF - digit) / 10) return 0;
        v = v * 10 + digit;
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

// ── Tests (inline, std.testing) — SABR field parsing + selection (offline) ──

const std = @import("std");
const testing = std.testing;

test "manifest: parseOneFormat captures SABR fields" {
    const obj =
        "{\"itag\":251,\"mimeType\":\"audio/webm; codecs=\\\"opus\\\"\"," ++
        "\"bitrate\":160000,\"contentLength\":\"5551234\"," ++
        "\"lastModified\":\"1700000000000000\",\"xtags\":\"acont=dubbed-auto:lang=en\"," ++
        "\"initRange\":{\"start\":\"0\",\"end\":\"266\"}," ++
        "\"indexRange\":{\"start\":\"267\",\"end\":\"1023\"}," ++
        "\"audioSampleRate\":\"48000\",\"url\":\"https://x/videoplayback?e=1\"}";
    var fmt: StreamFormat = undefined;
    try testing.expect(parseOneFormat(obj, &fmt));
    try testing.expectEqual(@as(u16, 251), fmt.itag);
    try testing.expectEqual(@as(u64, 1700000000000000), fmt.last_modified);
    try testing.expectEqualSlices(u8, "acont=dubbed-auto:lang=en", fmt.xtags[0..fmt.xtags_len]);
    try testing.expectEqual(@as(u32, 0), fmt.init_start);
    try testing.expectEqual(@as(u32, 266), fmt.init_end);
    try testing.expectEqual(@as(u32, 267), fmt.index_start);
    try testing.expectEqual(@as(u32, 1023), fmt.index_end);
    try testing.expectEqual(@as(u64, 5551234), fmt.content_length);
}

test "manifest: selectBySabr picks the matching itag without a URL" {
    var formats: [2]StreamFormat = undefined;
    const a =
        "{\"itag\":140,\"mimeType\":\"audio/mp4; codecs=\\\"mp4a.40.2\\\"\",\"bitrate\":128000," ++
        "\"contentLength\":\"100\",\"lastModified\":\"42\",\"url\":\"https://a/\"}";
    const v =
        "{\"itag\":137,\"mimeType\":\"video/mp4; codecs=\\\"avc1\\\"\",\"bitrate\":2000000," ++
        "\"contentLength\":\"999\",\"lastModified\":\"43\"}"; // no url (SABR-only)
    try testing.expect(parseOneFormat(a, &formats[0]));
    try testing.expect(parseOneFormat(v, &formats[1]));
    const sel = selectBySabr(&formats, 2, 137).?;
    try testing.expectEqual(@as(u16, 137), sel.itag);
    try testing.expectEqual(@as(u64, 43), sel.last_modified);
    try testing.expectEqual(@as(u16, 0), sel.url_len);
}
