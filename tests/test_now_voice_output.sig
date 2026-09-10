//! Executable contracts: success requires the assertions to run.
const std = @import("std");
const voice = @import("now_voice_output");

pub fn main(init: std.process.Init) !void {
    try cancellation();
    try completeText();
    try rejectedText();
    try generationSaturation();
    try std.Io.File.stdout().writeStreamingAll(init.io, "PASS now-voice-output: 4 executed cases (cancellation/provenance, complete text, rejection, saturation)\n");
}

fn require(value: bool) !void {
    if (!value) return error.AssertionFailed;
}

fn cancellation() !void {
    var mailbox = voice.Mailbox{};
    try require(mailbox.offer(try voice.Text.init(2, @splat(1), "First answer.")));
    try require(mailbox.begin() and mailbox.valid());
    const first_chunk = mailbox.active.nextChunk().?;
    try require(std.mem.eql(u8, first_chunk, "First answer."));
    mailbox.userEvent(3);
    try require(!mailbox.valid());
    try require(!mailbox.offer(try voice.Text.init(2, @splat(1), "Stale answer.")));
    try require(mailbox.offer(try voice.Text.init(4, @splat(2), "Fresh answer.")));
    try require(!mailbox.valid());
    try require(mailbox.begin() and mailbox.valid());
    try require(mailbox.active.event_id == 4);
    for (mailbox.active.digest) |byte| try require(byte == 2);
    try require(!mailbox.begin());
    try require(!mailbox.offer(try voice.Text.init(4, @splat(2), "Fresh answer.")));
    _ = mailbox.offer(try voice.Text.init(5, @splat(3), "Newer answer."));
    try require(!mailbox.valid());
    _ = mailbox.offer(try voice.Text.init(6, @splat(4), "Newest answer."));
    try require(mailbox.begin() and mailbox.active.event_id == 6);
    mailbox.cancel();
    try require(!mailbox.valid() and !mailbox.begin());
    mailbox.cancelThrough(100);
    try require(!mailbox.offer(try voice.Text.init(99, @splat(0), "Unread before stop.")));
    try require(!mailbox.offer(try voice.Text.init(100, @splat(0), "At stop boundary.")));
    try require(mailbox.offer(try voice.Text.init(101, @splat(0), "After stop boundary.")));
    try require(mailbox.begin() and mailbox.valid());
}

fn completeText() !void {
    const input = "The display is ready. " ++
        "The second sentence uses enough words to require several bounded chunks while keeping every complete word in its original order. " ++
        "This third sentence makes the committed reply longer than the original two hundred and fifty six byte retention limit without dropping its final words. " ++
        "Done.";
    try require(input.len > 256);
    var text = try voice.Text.init(10, @splat(7), input);
    var rebuilt: [input.len]u8 = undefined;
    var written: usize = 0;
    var chunks: usize = 0;
    while (text.nextChunk()) |chunk| {
        try require(chunk.len > 0 and chunk.len <= voice.MAX_CHUNK_BYTES);
        if (written != 0) {
            rebuilt[written] = ' ';
            written += 1;
        }
        @memcpy(rebuilt[written..][0..chunk.len], chunk);
        written += chunk.len;
        chunks += 1;
    }
    try require(chunks >= 5);
    try require(std.mem.eql(u8, input, rebuilt[0..written]));
    try require(text.nextChunk() == null);
    text.erase();
    try require(text.event_id == 0 and text.len == 0);
    for (text.bytes) |byte| try require(byte == 0);

    const exact_word = [_]u8{'a'} ** voice.MAX_CHUNK_BYTES;
    var exact = try voice.Text.init(11, @splat(0), &exact_word);
    try require(exact.nextChunk().?.len == voice.MAX_CHUNK_BYTES);
    try require(exact.nextChunk() == null);
}

fn rejectedText() !void {
    if (voice.Text.init(1, @splat(0), "שלום")) |_| return error.AcceptedUnsupportedLanguage else |failure| try require(failure == error.UnsupportedText);
    if (voice.Text.init(1, @splat(0), " \t...")) |_| return error.AcceptedEmptyText else |failure| try require(failure == error.EmptyText);
    const word = [_]u8{'a'} ** (voice.MAX_CHUNK_BYTES + 1);
    if (voice.Text.init(1, @splat(0), &word)) |_| return error.AcceptedOversizedWord else |failure| try require(failure == error.WordCapacity);
    const oversized = [_]u8{' '} ** (voice.MAX_TEXT_BYTES + 1);
    if (voice.Text.init(1, @splat(0), &oversized)) |_| return error.AcceptedOversizedText else |failure| try require(failure == error.TextCapacity);
    if (voice.Text.init(0, @splat(0), "Uncommitted.")) |_| return error.AcceptedUncommittedText else |failure| try require(failure == error.InvalidEvent);
}

fn generationSaturation() !void {
    var mailbox = voice.Mailbox{ .generation = std.math.maxInt(u64) };
    _ = mailbox.offer(try voice.Text.init(1, @splat(0), "First."));
    try require(mailbox.begin() and mailbox.valid());
    _ = mailbox.offer(try voice.Text.init(2, @splat(0), "Second."));
    try require(!mailbox.valid());
    try require(mailbox.begin() and mailbox.valid());
    mailbox.cancel();
    try require(!mailbox.valid());
}
