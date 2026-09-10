//! Executed allocation-free text/phoneme contracts for native speech consumers.
const std = @import("std");
const mem = @import("sig_mem");
const text = @import("sig_text");
const english = @import("english_phonemes");

var assertions: usize = 0;
fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.SpeechTextContractFailed;
}

fn phonesMatch(input: []const u8, expected: []const english.Phone) !void {
    var phones = english.Phones{};
    try english.phonemize(input, &phones);
    try check(mem.eql(english.Phone, phones.values[0..phones.len], expected));
}

pub fn main(init: std.process.Init) !void {
    try check(mem.eql(u8, text.trim(" \r\nNative\t ", " \t\r\n"), "Native"));
    try check(text.trim(" \t", " \t").len == 0);
    var split = text.splitScalar("one\n\nthree\n", '\n');
    for ([_][]const u8{ "one", "", "three", "" }) |part|
        try check(mem.eql(u8, split.next().?, part));
    try check(split.next() == null);
    split.reset();
    try check(mem.eql(u8, split.next().?, "one"));

    for ([_][]const u8{ "", "plain", "שלום", "🧠", "\xc2\x80", "\xed\x9f\xbf", "\xf4\x8f\xbf\xbf" }) |valid|
        try check(text.utf8ValidateSlice(valid));
    for ([_][]const u8{
        "\x80",         "\xc0\x80",     "\xc1\xbf",         "\xc2",             "\xe0\x80\x80",
        "\xed\xa0\x80", "\xef\xbf",     "\xf0\x80\x80\x80", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80",
        "\xff",         "\xe2\x28\xa1",
    }) |invalid| try check(!text.utf8ValidateSlice(invalid));
    var value: u16 = 0;
    while (value <= 255) : (value += 1) {
        const byte: u8 = @intCast(value);
        try check(text.isAlphanumeric(byte) ==
            ((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9')));
        try check(text.toLower(byte) == if (byte >= 'A' and byte <= 'Z') byte + 32 else byte);
    }

    try phonesMatch("The display is ready.", &.{
        .dh, .ah, .short_pause, .d, .ih, .s, .p,  .l,          .ey, .short_pause,
        .ih, .z,  .short_pause, .r, .eh, .d, .iy, .long_pause,
    });
    try phonesMatch("happy", &.{ .hh, .ae, .p, .p, .iy, .long_pause });
    try phonesMatch("privacy", &.{ .p, .r, .ay, .v, .ah, .s, .iy, .long_pause });
    try phonesMatch("42", &.{ .f, .ao, .r, .short_pause, .t, .uw, .long_pause });

    var phones = english.Phones{};
    try english.phonemize("ready", &phones);
    try english.phonemize("is", &phones);
    try check(mem.eql(english.Phone, phones.values[0..phones.len], &.{ .ih, .z, .long_pause }));
    for ([_][]const u8{ "שלום", "bad\x00tail", "escape\x1b[2J" }) |unsupported| {
        if (english.phonemize(unsupported, &phones)) |_| return error.UnsupportedTextAccepted else |failure| try check(failure == error.UnsupportedText);
        try check(phones.len == 0);
        for (phones.values) |phone| try check(phone == .silence);
    }
    const word = [_]u8{'a'} ** 49;
    if (english.phonemize(&word, &phones)) |_| return error.OversizedWordAccepted else |failure| try check(failure == error.WordTooLong);
    try check(phones.len == 0);
    const oversized = [_]u8{'a'} ** (english.MAX_TEXT_BYTES + 1);
    if (english.phonemize(&oversized, &phones)) |_| return error.OversizedTextAccepted else |failure| try check(failure == error.TextTooLong);
    try check(phones.len == 0);
    var message: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&message, "PASS speech-text: {d} executed assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
