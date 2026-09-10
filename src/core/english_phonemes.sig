//! Bounded English grapheme-to-phoneme frontend for native speech engines.
//! Phones and lexical rules are independent of the acoustic model, host I/O,
//! driver, and kernel. Caller-owned fixed storage bounds every conversion.
const mem = @import("sig_mem");
const text_utils = @import("sig_text");

pub const MAX_TEXT_BYTES: usize = 384;
pub const MAX_PHONEMES: usize = 512;
pub const Error = error{ EmptyText, TextTooLong, WordTooLong, PhonemeCapacity, UnsupportedText };

pub const Phone = enum(u8) {
    silence,
    short_pause,
    long_pause,
    aa,
    ae,
    ah,
    ao,
    aw,
    ay,
    eh,
    er,
    ey,
    ih,
    iy,
    ow,
    oy,
    uh,
    uw,
    b,
    ch,
    d,
    dh,
    f,
    g,
    hh,
    jh,
    k,
    l,
    m,
    n,
    ng,
    p,
    r,
    s,
    sh,
    t,
    th,
    v,
    w,
    y,
    z,
    zh,
};

pub const Phones = struct {
    values: [MAX_PHONEMES]Phone = @splat(.silence),
    len: usize = 0,

    fn push(self: *Phones, phone: Phone) Error!void {
        if (self.len >= self.values.len) return error.PhonemeCapacity;
        self.values[self.len] = phone;
        self.len += 1;
    }

    fn append(self: *Phones, source: []const Phone) Error!void {
        if (source.len > self.values.len - self.len) return error.PhonemeCapacity;
        @memcpy(self.values[self.len..][0..source.len], source);
        self.len += source.len;
    }
};

const DictionaryEntry = struct { word: []const u8, phones: []const Phone };

const dictionary = [_]DictionaryEntry{
    .{ .word = "a", .phones = &.{.ah} },
    .{ .word = "an", .phones = &.{ .ae, .n } },
    .{ .word = "and", .phones = &.{ .ae, .n, .d } },
    .{ .word = "appears", .phones = &.{ .ah, .p, .iy, .r, .z } },
    .{ .word = "blue", .phones = &.{ .b, .l, .uw } },
    .{ .word = "from", .phones = &.{ .f, .r, .ah, .m } },
    .{ .word = "generated", .phones = &.{ .jh, .eh, .n, .er, .ey, .t, .ih, .d } },
    .{ .word = "google", .phones = &.{ .g, .uw, .g, .ah, .l } },
    .{ .word = "green", .phones = &.{ .g, .r, .iy, .n } },
    .{ .word = "hello", .phones = &.{ .hh, .eh, .l, .ow } },
    .{ .word = "heard", .phones = &.{ .hh, .er, .d } },
    .{ .word = "i", .phones = &.{.ay} },
    .{ .word = "image", .phones = &.{ .ih, .m, .ih, .jh } },
    .{ .word = "is", .phones = &.{ .ih, .z } },
    .{ .word = "it", .phones = &.{ .ih, .t } },
    .{ .word = "like", .phones = &.{ .l, .ay, .k } },
    .{ .word = "live", .phones = &.{ .l, .ih, .v } },
    .{ .word = "looks", .phones = &.{ .l, .uh, .k, .s } },
    .{ .word = "native", .phones = &.{ .n, .ey, .t, .ih, .v } },
    .{ .word = "nexus", .phones = &.{ .n, .eh, .k, .s, .ah, .s } },
    .{ .word = "now", .phones = &.{ .n, .aw } },
    .{ .word = "of", .phones = &.{ .ah, .v } },
    .{ .word = "phone", .phones = &.{ .f, .ow, .n } },
    .{ .word = "pure", .phones = &.{ .p, .y, .uh, .r } },
    .{ .word = "ready", .phones = &.{ .r, .eh, .d, .iy } },
    .{ .word = "red", .phones = &.{ .r, .eh, .d } },
    .{ .word = "response", .phones = &.{ .r, .ih, .s, .p, .aa, .n, .s } },
    .{ .word = "sbzero", .phones = &.{ .eh, .s, .b, .iy, .z, .iy, .r, .ow } },
    .{ .word = "screen", .phones = &.{ .s, .k, .r, .iy, .n } },
    .{ .word = "screenshot", .phones = &.{ .s, .k, .r, .iy, .n, .sh, .aa, .t } },
    .{ .word = "shows", .phones = &.{ .sh, .ow, .z } },
    .{ .word = "sig", .phones = &.{ .s, .ih, .g } },
    .{ .word = "speech", .phones = &.{ .s, .p, .iy, .ch } },
    .{ .word = "state", .phones = &.{ .s, .t, .ey, .t } },
    .{ .word = "stayed", .phones = &.{ .s, .t, .ey, .d } },
    .{ .word = "the", .phones = &.{ .dh, .ah } },
    .{ .word = "this", .phones = &.{ .dh, .ih, .s } },
    .{ .word = "voice", .phones = &.{ .v, .oy, .s } },
    .{ .word = "white", .phones = &.{ .w, .ay, .t } },
    .{ .word = "with", .phones = &.{ .w, .ih, .dh } },
    .{ .word = "you", .phones = &.{ .y, .uw } },
    .{ .word = "youtube", .phones = &.{ .y, .uw, .t, .uw, .b } },
    // Irregular vowels and stress-independent phones in device narration.
    .{ .word = "audio", .phones = &.{ .ao, .d, .iy, .ow } },
    .{ .word = "capture", .phones = &.{ .k, .ae, .p, .ch, .er } },
    .{ .word = "device", .phones = &.{ .d, .ih, .v, .ay, .s } },
    .{ .word = "display", .phones = &.{ .d, .ih, .s, .p, .l, .ey } },
    .{ .word = "driver", .phones = &.{ .d, .r, .ay, .v, .er } },
    .{ .word = "drivers", .phones = &.{ .d, .r, .ay, .v, .er, .z } },
    .{ .word = "input", .phones = &.{ .ih, .n, .p, .uh, .t } },
    .{ .word = "kernel", .phones = &.{ .k, .er, .n, .ah, .l } },
    .{ .word = "microphone", .phones = &.{ .m, .ay, .k, .r, .ow, .f, .ow, .n } },
    .{ .word = "mute", .phones = &.{ .m, .y, .uw, .t } },
    .{ .word = "network", .phones = &.{ .n, .eh, .t, .w, .er, .k } },
    .{ .word = "playback", .phones = &.{ .p, .l, .ey, .b, .ae, .k } },
    .{ .word = "privacy", .phones = &.{ .p, .r, .ay, .v, .ah, .s, .iy } },
    .{ .word = "refresh", .phones = &.{ .r, .ih, .f, .r, .eh, .sh } },
    .{ .word = "status", .phones = &.{ .s, .t, .ey, .t, .ah, .s } },
    .{ .word = "storage", .phones = &.{ .s, .t, .ao, .r, .ih, .jh } },
};

pub fn phonemize(text: []const u8, output: *Phones) Error!void {
    output.* = .{};
    errdefer output.* = .{};
    if (text.len > MAX_TEXT_BYTES) return error.TextTooLong;
    for (text) |byte| {
        if (byte > 0x7e or (byte < 0x20 and byte != '\t' and byte != '\r' and byte != '\n'))
            return error.UnsupportedText;
    }
    var word: [48]u8 = undefined;
    var word_len: usize = 0;
    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        const byte: u8 = if (index < text.len) text[index] else 0;
        if (text_utils.isLetter(byte)) {
            if (word_len >= word.len) return error.WordTooLong;
            word[word_len] = text_utils.toLower(byte);
            word_len += 1;
            continue;
        }
        if (word_len != 0) {
            try emitWord(word[0..word_len], output);
            word_len = 0;
        }
        if (byte == 0) break;
        if (byte >= '0' and byte <= '9') {
            // Spell digits rather than dropping port numbers, sizes, or IDs.
            // Reading a multi-digit quantity as a cardinal requires a richer
            // normalization contract; its exact digits remain audible here.
            if (output.len != 0 and output.values[output.len - 1] != .short_pause and
                output.values[output.len - 1] != .long_pause) try output.push(.short_pause);
            try emitDigit(byte, output);
            try output.push(.short_pause);
        } else if (byte == '.' or byte == '!' or byte == '?' or byte == ';' or byte == ':') {
            if (output.len != 0 and output.values[output.len - 1] != .long_pause)
                try output.push(.long_pause);
        } else if (byte == ',' or byte == '-' or byte == '\n') {
            if (output.len != 0 and output.values[output.len - 1] != .short_pause)
                try output.push(.short_pause);
        } else if (byte == ' ' or byte == '\t') {
            if (output.len != 0 and output.values[output.len - 1] != .short_pause and
                output.values[output.len - 1] != .long_pause)
                try output.push(.short_pause);
        }
    }
    while (output.len != 0 and (output.values[output.len - 1] == .short_pause or
        output.values[output.len - 1] == .long_pause)) output.len -= 1;
    if (output.len == 0) return error.EmptyText;
    try output.push(.long_pause);
}

fn emitDigit(byte: u8, output: *Phones) Error!void {
    try output.append(switch (byte) {
        '0' => &.{ .z, .ih, .r, .ow },
        '1' => &.{ .w, .ah, .n },
        '2' => &.{ .t, .uw },
        '3' => &.{ .th, .r, .iy },
        '4' => &.{ .f, .ao, .r },
        '5' => &.{ .f, .ay, .v },
        '6' => &.{ .s, .ih, .k, .s },
        '7' => &.{ .s, .eh, .v, .ah, .n },
        '8' => &.{ .ey, .t },
        '9' => &.{ .n, .ay, .n },
        else => unreachable,
    });
}

fn emitWord(word: []const u8, output: *Phones) Error!void {
    for (dictionary) |entry| if (mem.eql(u8, word, entry.word)) {
        try output.append(entry.phones);
        return;
    };
    var index: usize = 0;
    while (index < word.len) {
        const remaining = word[index..];
        if (starts(remaining, "tion")) {
            try output.append(&.{ .sh, .ah, .n });
            index += 4;
            continue;
        }
        if (starts(remaining, "sion")) {
            try output.append(&.{ .zh, .ah, .n });
            index += 4;
            continue;
        }
        if (starts(remaining, "tch")) {
            try output.push(.ch);
            index += 3;
            continue;
        }
        if (starts(remaining, "dge")) {
            try output.push(.jh);
            index += 3;
            continue;
        }
        if (starts(remaining, "sh")) {
            try output.push(.sh);
            index += 2;
            continue;
        }
        if (starts(remaining, "ch")) {
            try output.push(.ch);
            index += 2;
            continue;
        }
        if (starts(remaining, "th")) {
            try output.push(if (index > 0 and index + 2 < word.len and isVowel(word[index - 1]) and isVowel(word[index + 2])) .dh else .th);
            index += 2;
            continue;
        }
        if (starts(remaining, "ph")) {
            try output.push(.f);
            index += 2;
            continue;
        }
        if (starts(remaining, "ng")) {
            try output.push(.ng);
            index += 2;
            continue;
        }
        if (starts(remaining, "qu")) {
            try output.append(&.{ .k, .w });
            index += 2;
            continue;
        }
        if (starts(remaining, "ck")) {
            try output.push(.k);
            index += 2;
            continue;
        }
        if (starts(remaining, "ee") or starts(remaining, "ea")) {
            try output.push(.iy);
            index += 2;
            continue;
        }
        if (starts(remaining, "oo")) {
            try output.push(.uw);
            index += 2;
            continue;
        }
        if (starts(remaining, "ai") or starts(remaining, "ay")) {
            try output.push(.ey);
            index += 2;
            continue;
        }
        if (starts(remaining, "oa")) {
            try output.push(.ow);
            index += 2;
            continue;
        }
        if (starts(remaining, "oi") or starts(remaining, "oy")) {
            try output.push(.oy);
            index += 2;
            continue;
        }
        if (starts(remaining, "ou") or starts(remaining, "ow")) {
            try output.push(.aw);
            index += 2;
            continue;
        }
        if (starts(remaining, "er") or starts(remaining, "ir") or starts(remaining, "ur")) {
            try output.push(.er);
            index += 2;
            continue;
        }
        if (starts(remaining, "ar")) {
            try output.append(&.{ .aa, .r });
            index += 2;
            continue;
        }
        if (starts(remaining, "or")) {
            try output.append(&.{ .ao, .r });
            index += 2;
            continue;
        }
        // Common unstressed endings use vowel /i/, not consonant /j/.
        // Keep stressed endings (apply/reply/deny/occupy) out of this rule.
        if (word[index] == 'y' and index + 1 == word.len and word.len > 3 and
            (mem.endsWith(u8, word, "ity") or
                mem.endsWith(u8, word, "ary") or
                mem.endsWith(u8, word, "ory") or
                mem.endsWith(u8, word, "ery") or
                (mem.endsWith(u8, word, "ly") and
                    !mem.endsWith(u8, word, "ply") and
                    !mem.eql(u8, word, "rely")) or
                word[index - 1] == word[index - 2]))
        {
            try output.push(.iy);
            index += 1;
            continue;
        }
        const final_silent_e = word[index] == 'e' and index + 1 == word.len and word.len > 2;
        if (!final_silent_e) try output.push(letterPhone(
            word[index],
            if (index + 1 < word.len) word[index + 1] else 0,
        ));
        index += 1;
    }
}

fn letterPhone(letter: u8, next: u8) Phone {
    const soft = next == 'e' or next == 'i' or next == 'y';
    return switch (letter) {
        'a' => .ae,
        'b' => .b,
        'c' => if (soft) .s else .k,
        'd' => .d,
        'e' => .eh,
        'f' => .f,
        'g' => if (soft) .jh else .g,
        'h' => .hh,
        'i' => .ih,
        'j' => .jh,
        'k' => .k,
        'l' => .l,
        'm' => .m,
        'n' => .n,
        'o' => .aa,
        'p' => .p,
        'q' => .k,
        'r' => .r,
        's' => .s,
        't' => .t,
        'u' => .ah,
        'v' => .v,
        'w' => .w,
        'x' => .k,
        'y' => .y,
        'z' => .z,
        else => .short_pause,
    };
}

fn starts(source: []const u8, prefix: []const u8) bool {
    return source.len >= prefix.len and mem.eql(u8, source[0..prefix.len], prefix);
}
fn isVowel(byte: u8) bool {
    return byte == 'a' or byte == 'e' or byte == 'i' or byte == 'o' or byte == 'u' or byte == 'y';
}
