// @zpm/youtube/metadata — Video Metadata Types
//
// Shared data structures for video information used across the youtube module.

pub const VIDEO_ID_LEN: usize = 11;
pub const MAX_TITLE_LEN: usize = 256;
pub const MAX_DESC_LEN: usize = 1024;

/// Metadata for a single YouTube video.
pub const VideoMeta = struct {
    id: [VIDEO_ID_LEN]u8,
    title: [MAX_TITLE_LEN]u8,
    title_len: u16,
    upload_date: [8]u8, // YYYYMMDD
    duration: u32, // seconds
    description: [MAX_DESC_LEN]u8,
    desc_len: u16,
    valid: bool,

    pub fn init() VideoMeta {
        return .{
            .id = undefined,
            .title = undefined,
            .title_len = 0,
            .upload_date = "00000000".*,
            .duration = 0,
            .description = undefined,
            .desc_len = 0,
            .valid = false,
        };
    }

    pub fn titleSlice(self: *const VideoMeta) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn descSlice(self: *const VideoMeta) []const u8 {
        return self.description[0..self.desc_len];
    }

    /// Duration in minutes (rounded).
    pub fn durationMin(self: *const VideoMeta) u32 {
        return (self.duration + 30) / 60;
    }
};

/// Processing status for batch workflows.
pub const VideoStatus = enum(u8) {
    pending = 0,
    downloading = 1,
    transcribed = 2,
    edited = 3,
    published = 4,
    err = 5,

    pub fn toChar(self: VideoStatus) u8 {
        return switch (self) {
            .pending => 'P',
            .downloading => 'D',
            .transcribed => 'T',
            .edited => 'E',
            .published => 'X',
            .err => 'R',
        };
    }

    pub fn fromChar(c: u8) VideoStatus {
        return switch (c) {
            'P' => .pending,
            'D' => .downloading,
            'T' => .transcribed,
            'E' => .edited,
            'X' => .published,
            'R' => .err,
            else => .pending,
        };
    }
};
