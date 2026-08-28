// @zpm/youtube — Comprehensive YouTube Integration Module
// Layer 1: Platform (HTTP + Subprocess)
//
// Full-featured YouTube operations:
//
//   channel    — Scan channels, list all videos with metadata
//   download   — Audio/video download via yt-dlp (WAV, MP3, MP4)
//   comments   — Post comments via YouTube Data API v3 (OAuth2)
//   captions   — Download subtitles (manual + auto-generated, any language)
//   playlist   — List playlist contents, enumerate channel playlists
//   search     — Search YouTube globally or within a channel
//   thumbnails — Download video thumbnails (direct HTTPS, no API key)
//   info       — Detailed video info (chapters, tags, views, likes)
//   auth       — OAuth2 token management (load, validate, save)
//   url        — URL parsing (video IDs, channels, playlists)
//   metadata   — Shared types (VideoMeta, VideoStatus)
//
// Dependencies:
//   - yt-dlp (in PATH) for scraping/download operations
//   - WinHTTP (winhttp.dll) for HTTPS API calls
//   - No API key needed for read-only operations (yt-dlp handles it)
//   - OAuth2 token needed only for write operations (comments)
//
// Architecture:
//   Zero heap. All buffers are module-level statics or stack.
//   yt-dlp subprocess for heavy lifting (metadata, download, captions).
//   Direct WinHTTP for lightweight API calls (comments, thumbnails, auth).
//
// Usage:
//   const yt = @import("youtube");
//
//   // Scan a channel
//   var videos: [4096]yt.metadata.VideoMeta = undefined;
//   const n = yt.channel.scan("https://www.youtube.com/@handle", &videos);
//
//   // Download audio
//   yt.download.audio(&video_id, "output.wav", .wav);
//
//   // Get subtitles
//   yt.captions.downloadAuto(&video_id, "he", .srt, "subs.srt");
//
//   // Search
//   var results: [50]yt.metadata.VideoMeta = undefined;
//   const found = yt.search.query("kabbalah", &results, .{});
//
//   // Thumbnails
//   yt.thumbnails.download(&video_id, .high, "thumb.jpg");
//
//   // Detailed info
//   var info: yt.info.VideoInfo = undefined;
//   yt.info.fetch(&video_id, &info);
//
//   // Auth + Comments
//   yt.auth.load("token.txt");
//   if (yt.auth.hasYoutubeScope()) {
//       yt.comments.post(&video_id, "Great video!");
//   }

pub const channel = @import("channel.sig");
pub const download = @import("download.sig");
pub const comments = @import("comments.sig");
pub const captions = @import("captions.sig");
pub const playlist = @import("playlist.sig");
pub const search = @import("search.sig");
pub const thumbnails = @import("thumbnails.sig");
pub const info = @import("info.sig");
pub const auth = @import("auth.sig");
pub const url = @import("url.sig");
pub const metadata = @import("metadata.sig");

// ── Pure Sig extraction engine (no yt-dlp) ──
pub const innertube = @import("innertube.sig");
pub const cipher = @import("cipher.sig");
pub const nsig = @import("nsig.sig");
pub const manifest = @import("manifest.sig");
pub const stream = @import("stream.sig");
pub const mux = @import("mux.sig");

// ── BotGuard PO Token Engine ──
pub const botguard = @import("botguard/root.sig");
