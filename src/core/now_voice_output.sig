//! Bounded text ownership and cancellation for committed NOW speech output.
//! A new user turn or newer assistant answer invalidates every old chunk.
const text_utils = @import("sig_text");
const testing = @import("sig_testing");

pub const MAX_TEXT_BYTES: usize = 2048;
pub const MAX_CHUNK_BYTES: usize = 96;
pub const Error = error{ EmptyText, TextCapacity, UnsupportedText, WordCapacity, InvalidEvent };

pub const Text = struct {
    event_id: u64 = 0,
    digest: [16]u8 = @splat(0),
    len: usize = 0,
    offset: usize = 0,
    bytes: [MAX_TEXT_BYTES]u8 = @splat(0),

    pub fn init(event_id: u64, digest: [16]u8, text: []const u8) Error!Text {
        if (event_id == 0) return error.InvalidEvent;
        if (text.len == 0) return error.EmptyText;
        if (text.len > MAX_TEXT_BYTES) return error.TextCapacity;
        var meaningful = false;
        var word: usize = 0;
        for (text) |byte| {
            // The admitted Kitten frontend is English/ASCII. Reject unsupported
            // text rather than silently replacing the user's language.
            if (byte < 0x20 or byte > 0x7e) {
                if (byte != '\n' and byte != '\r' and byte != '\t')
                    return error.UnsupportedText;
            }
            if (isSpace(byte)) word = 0 else {
                word += 1;
                if (word > MAX_CHUNK_BYTES) return error.WordCapacity;
                meaningful = meaningful or text_utils.isAlphanumeric(byte);
            }
        }
        if (!meaningful) return error.EmptyText;
        var result = Text{ .event_id = event_id, .digest = digest, .len = text.len };
        @memcpy(result.bytes[0..text.len], text);
        return result;
    }

    /// Consume a complete phrase or word-bounded chunk, retaining every byte
    /// except inter-chunk whitespace. No partial word is silently spoken.
    pub fn nextChunk(self: *Text) ?[]const u8 {
        while (self.offset < self.len and isSpace(self.bytes[self.offset])) self.offset += 1;
        if (self.offset == self.len) return null;
        const start = self.offset;
        const limit = @min(start + MAX_CHUNK_BYTES, self.len);
        var end = limit;
        var index = start;
        while (index < limit) : (index += 1) {
            const byte = self.bytes[index];
            if ((byte == '.' or byte == '!' or byte == '?' or byte == ';') and
                (index + 1 == self.len or isSpace(self.bytes[index + 1])))
            {
                end = index + 1;
                break;
            }
        }
        if (end == limit and end < self.len and !isSpace(self.bytes[end])) {
            while (end > start and !isSpace(self.bytes[end - 1])) end -= 1;
            // init proves each word fits, so failure to find a boundary means
            // exactly MAX_CHUNK_BYTES bytes form one complete word.
            if (end == start) end = limit;
        }
        self.offset = end;
        while (end > start and isSpace(self.bytes[end - 1])) end -= 1;
        return self.bytes[start..end];
    }

    pub fn erase(self: *Text) void {
        self.* = .{};
    }
};

pub const Mailbox = struct {
    generation: u64 = 1,
    active_generation: u64 = 0,
    latest_user_event: u64 = 0,
    latest_output_event: u64 = 0,
    active: Text = .{},
    pending: Text = .{},

    pub fn cancel(self: *Mailbox) void {
        self.generation +|= 1;
        self.active_generation = 0;
        self.pending.erase();
    }

    /// Explicit user cancellation also fences committed output not yet read
    /// from NOW. Only events committed after this boundary may speak again.
    pub fn cancelThrough(self: *Mailbox, event_id: u64) void {
        self.latest_user_event = @max(self.latest_user_event, event_id);
        self.cancel();
    }

    pub fn userEvent(self: *Mailbox, event_id: u64) void {
        if (event_id <= self.latest_user_event) return;
        self.cancelThrough(event_id);
    }

    pub fn offer(self: *Mailbox, text: Text) bool {
        if (text.event_id <= self.latest_user_event or text.event_id <= self.latest_output_event)
            return false;
        self.latest_output_event = text.event_id;
        self.generation +|= 1;
        self.active_generation = 0;
        self.pending = text;
        return true;
    }

    pub fn begin(self: *Mailbox) bool {
        if (self.pending.event_id == 0) return false;
        self.active = self.pending;
        self.pending.erase();
        self.active_generation = self.generation;
        return true;
    }

    pub fn valid(self: *const Mailbox) bool {
        return self.active.event_id != 0 and self.active_generation != 0 and
            self.active_generation == self.generation;
    }
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

test "a newer turn cancels old audio without losing the new response" {
    var mailbox = Mailbox{};
    try testing.expect(mailbox.offer(try Text.init(2, @splat(1), "First answer.")));
    try testing.expect(mailbox.begin());
    try testing.expect(mailbox.valid());
    mailbox.userEvent(3);
    try testing.expect(!mailbox.valid());
    try testing.expect(!mailbox.offer(try Text.init(2, @splat(1), "Stale answer.")));
    try testing.expect(mailbox.offer(try Text.init(4, @splat(2), "Fresh answer.")));
    try testing.expect(!mailbox.valid());
    try testing.expect(mailbox.begin());
    try testing.expect(mailbox.valid());
    try testing.expectEqual(@as(u64, 4), mailbox.active.event_id);
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(2)), &mailbox.active.digest);
}

test "newer output supersedes active and pending output and is never replayed" {
    var mailbox = Mailbox{};
    _ = mailbox.offer(try Text.init(10, @splat(0), "First."));
    _ = mailbox.begin();
    _ = mailbox.offer(try Text.init(11, @splat(0), "Second."));
    try testing.expect(!mailbox.valid());
    _ = mailbox.offer(try Text.init(12, @splat(0), "Third."));
    try testing.expect(mailbox.begin());
    try testing.expectEqual(@as(u64, 12), mailbox.active.event_id);
    try testing.expect(!mailbox.begin());
    try testing.expect(!mailbox.offer(try Text.init(12, @splat(0), "Third.")));
    mailbox.cancel();
    try testing.expect(!mailbox.valid());
}

test "phrases stay bounded and preserve the complete committed text" {
    const input = "The display is ready. " ++ "The second sentence uses enough words to require several bounded chunks while keeping every complete word in its original order. " ++ "Done.";
    var text = try Text.init(1, @splat(0), input);
    var rebuilt: [input.len]u8 = undefined;
    var written: usize = 0;
    var chunks: usize = 0;
    while (text.nextChunk()) |chunk| {
        try testing.expect(chunk.len != 0 and chunk.len <= MAX_CHUNK_BYTES);
        if (written != 0) {
            rebuilt[written] = ' ';
            written += 1;
        }
        @memcpy(rebuilt[written..][0..chunk.len], chunk);
        written += chunk.len;
        chunks += 1;
    }
    try testing.expect(chunks >= 4);
    try testing.expectEqualSlices(u8, input, rebuilt[0..written]);
    try testing.expect(text.nextChunk() == null);
}

test "unsupported language and oversized words fail explicitly" {
    try testing.expectError(error.UnsupportedText, Text.init(1, @splat(0), "שלום"));
    try testing.expectError(error.EmptyText, Text.init(1, @splat(0), " \t..."));
    try testing.expectError(error.WordCapacity, Text.init(1, @splat(0), &(@as([MAX_CHUNK_BYTES + 1]u8, @splat('a')))));
    try testing.expectError(error.TextCapacity, Text.init(1, @splat(0), &(@as([MAX_TEXT_BYTES + 1]u8, @splat(' ')))));
}
