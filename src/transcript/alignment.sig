//! Bounded approximate source alignment for ASR spelling variants. Three exact
//! normalized words anchor a candidate; short character edits extend it. This
//! produces source evidence only and never assigns a discourse mode.
const std = @import("std");
const t = @import("root.sig");
pub const max_words = 64;
pub const seed_words = 3;
pub const max_candidates = 256;
pub const Error = t.Error || error{ InvalidOptions, CandidateCapacity };
pub const Options = struct { max_word_edits: u8 = 4, max_candidates: usize = 256 };
const Cell = struct { cost: u16 = 0xffff, aligned: u16 = 0, exact: u16 = 0, chars: u16 = 0, character_edits: u16 = 0, word_edits: u16 = 0 };
const Extension = struct { valid: bool = false, source_words: u16 = 0, cell: Cell = .{} };
pub const Scratch = struct {
    cells: [max_words + 1][max_words + 1]Cell = undefined,
    left: [max_words + 1]Extension = undefined,
    right: [max_words + 1]Extension = undefined,
    candidates: usize = 0,
    cells_evaluated: usize = 0,
};
pub const Range = struct { begin: usize, end: usize };
pub const WordOrigin = struct {
    part: enum { before, focus, after },
    /// UTF-8 byte offsets in the original corresponding input string.
    begin_byte: usize, end_byte: usize,
};
pub const ContextStorage = struct {
    text: [8192]u8 = undefined,
    words: [64]t.Word = undefined,
    origins: [64]WordOrigin = undefined,
    /// Input neighbors are bounded to 1024 words each; only 16 are retained.
    token_scratch: [1024]t.Word = undefined,
};
pub const Query = struct {
    text: []const u8, words: []const t.Word, origins: []const WordOrigin,
    /// Word and byte ranges in this combined evidence query, not ASR timestamps.
    focus: Range, before_bytes: Range, focus_bytes: Range, after_bytes: Range,
};
pub const ContextEvidence = struct { query: Query, matches: []t.Match };

/// Preserve the selected raw UTF-8 slices and map every evidence word back to
/// its original before/focus/after input. At most 16+32+16 words are retained.
/// Separating newlines are evidence-query framing, never edited ASR speech.
pub fn buildContext(before: []const u8, focus: []const u8, after: []const u8, storage: *ContextStorage) Error!Query {
    var pos: usize = 0;
    var count: usize = 0;
    var ranges: [3]Range = undefined;
    var focus_words = Range{ .begin = 0, .end = 0 };
    const parts = [_][]const u8{ before, focus, after };
    for (parts, 0..) |part, index| {
        const words = try t.tokenize(part, &storage.token_scratch);
        if (index == 1 and (words.len == 0 or words.len > 32)) return error.Capacity;
        const begin_word = if (index == 0 and words.len > 16) words.len - 16 else 0;
        const end_word = if (index == 2) @min(words.len, 16) else words.len;
        const begin_byte = if (begin_word == 0) 0 else words[begin_word].start;
        const end_byte = if (end_word == words.len) part.len else words[end_word].start;
        if (index != 0) try t.append(&storage.text, &pos, "\n");
        ranges[index] = .{ .begin = pos, .end = pos + end_byte - begin_byte };
        try t.append(&storage.text, &pos, part[begin_byte..end_byte]);
        if (index == 1) focus_words.begin = count;
        for (words[begin_word..end_word]) |word| {
            if (count == storage.words.len) return error.Capacity;
            storage.words[count] = .{ .start = ranges[index].begin + word.start - begin_byte,
                .end = ranges[index].begin + word.end - begin_byte, .hash = word.hash };
            storage.origins[count] = .{ .part = @enumFromInt(index), .begin_byte = word.start, .end_byte = word.end };
            count += 1;
        }
        if (index == 1) focus_words.end = count;
    }
    return .{ .text = storage.text[0..pos], .words = storage.words[0..count], .origins = storage.origins[0..count],
        .focus = focus_words, .before_bytes = ranges[0], .focus_bytes = ranges[1], .after_bytes = ranges[2] };
}
fn hash(words: []const t.Word) u64 {
    var value: u64 = 14695981039346656037;
    for (words[0..seed_words]) |word| value = (value ^ word.hash) *% 1099511628211;
    return value;
}
fn less(_: void, a: t.Seed, b: t.Seed) bool { return a.hash < b.hash or (a.hash == b.hash and a.word < b.word); }
fn matchLess(_: void, a: t.Match, b: t.Match) bool { return a.begin < b.begin or (a.begin == b.begin and a.end < b.end); }

fn canonical(text: []const u8, word: t.Word, out: *[64]u21) ?usize {
    var pos = word.start;
    var count: usize = 0;
    while (pos < word.end) {
        const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return null;
        var cp = std.unicode.utf8Decode(text[pos..][0..len]) catch return null;
        pos += len;
        if (cp >= 'A' and cp <= 'Z') cp += 32;
        if (!((cp >= 'a' and cp <= 'z') or (cp >= '0' and cp <= '9') or (cp >= 0x5d0 and cp <= 0x5ea))) continue;
        if (count == out.len) return null;
        out[count] = cp;
        count += 1;
    }
    return count;
}
const Pair = struct { exact: bool = false, chars: u16 = 0, edits: ?u16 = null };
fn pair(a: []const u8, aw: t.Word, b: []const u8, bw: t.Word) Pair {
    var ab: [64]u21 = undefined;
    var bb: [64]u21 = undefined;
    const an = canonical(a, aw, &ab) orelse return .{};
    const bn = canonical(b, bw, &bb) orelse return .{};
    if (std.mem.eql(u21, ab[0..an], bb[0..bn])) return .{ .exact = true, .chars = @intCast(an), .edits = 0 };
    const longest = @max(an, bn);
    if (@min(an, bn) < 3 or longest > 32) return .{};
    const limit: u16 = if (longest >= 6) 2 else 1;
    if (longest - @min(an, bn) > limit) return .{};
    var previous: [33]u16 = undefined;
    var current: [33]u16 = undefined;
    for (0..bn + 1) |i| previous[i] = @intCast(i);
    for (ab[0..an], 0..) |ac, i| {
        current[0] = @intCast(i + 1);
        var minimum = current[0];
        for (bb[0..bn], 0..) |bc, j| {
            current[j + 1] = @min(@min(previous[j + 1] + 1, current[j] + 1), previous[j] + @intFromBool(ac != bc));
            minimum = @min(minimum, current[j + 1]);
        }
        if (minimum > limit) return .{};
        @memcpy(previous[0..bn + 1], current[0..bn + 1]);
    }
    if (previous[bn] > limit) return .{};
    return .{ .chars = @intCast(longest), .edits = previous[bn] };
}
fn better(a: Cell, b: Cell) bool {
    return a.cost < b.cost or (a.cost == b.cost and (a.aligned > b.aligned or (a.aligned == b.aligned and a.exact > b.exact)));
}
fn gap(cell: Cell, options: Options) Cell {
    if (cell.cost == 0xffff or cell.word_edits == options.max_word_edits) return .{};
    var result = cell;
    result.cost += 6; result.word_edits += 1;
    return result;
}
fn joined(a: Cell, b: Cell) Cell {
    return .{ .cost = a.cost + b.cost, .aligned = a.aligned + b.aligned, .exact = a.exact + b.exact,
        .chars = a.chars + b.chars, .character_edits = a.character_edits + b.character_edits, .word_edits = a.word_edits + b.word_edits };
}
fn valid(cell: Cell, minimum_words: u16, options: Options) bool {
    return cell.cost != 0xffff and cell.aligned >= minimum_words and cell.exact >= seed_words and cell.chars != 0 and
        cell.word_edits <= options.max_word_edits and cell.word_edits <= cell.aligned / 8 and @as(u32, cell.cost) * 5 <= cell.chars;
}

pub const ApproxSource = struct {
    source: t.Source,
    seeds: []const t.Seed,

    /// Source text/word storage and seed storage must remain alive. Build once
    /// per source, not once per ASR clause. No source text or words are copied.
    pub fn init(source: t.Source, seeds: []t.Seed) Error!ApproxSource {
        const count = if (source.words.len < seed_words) 0 else source.words.len - seed_words + 1;
        if (count > seeds.len) return error.Capacity;
        for (seeds[0..count], 0..) |*seed, i| seed.* = .{ .hash = hash(source.words[i..]), .word = i };
        std.sort.heap(t.Seed, seeds[0..count], {}, less);
        return .{ .source = source, .seeds = seeds[0..count] };
    }

    pub fn alignContext(self: ApproxSource, before: []const u8, focus: []const u8, after: []const u8,
        storage: *ContextStorage, matches: []t.Match, scratch: *Scratch, options: Options) Error!ContextEvidence {
        const query = try buildContext(before, focus, after, storage);
        return .{ .query = query, .matches = try self.match(query.text, query.words, matches, scratch, options) };
    }

    fn extend(self: ApproxSource, text: []const u8, words: []const t.Word, ti: usize, si: usize,
        reverse: bool, base: Cell, scratch: *Scratch, out: *[max_words + 1]Extension, options: Options) void {
        const nt = if (reverse) ti else words.len - ti - seed_words;
        const ns = @min(max_words, if (reverse) si else self.source.words.len - si - seed_words);
        for (scratch.cells[0..nt + 1]) |*row| @memset(row[0..ns + 1], Cell{});
        @memset(out, Extension{});
        scratch.cells[0][0] = .{ .cost = 0 };
        for (0..nt + 1) |i| {
            for (0..ns + 1) |j| {
                if (i == 0 and j == 0) {} else {
                    if (@max(i, j) - @min(i, j) > options.max_word_edits) continue;
                    var selected = Cell{};
                    if (i > 0) {
                        const candidate = gap(scratch.cells[i - 1][j], options);
                        if (better(candidate, selected)) selected = candidate;
                    }
                    if (j > 0) {
                        const candidate = gap(scratch.cells[i][j - 1], options);
                        if (better(candidate, selected)) selected = candidate;
                    }
                    if (i > 0 and j > 0) {
                        const previous = scratch.cells[i - 1][j - 1];
                        if (previous.cost != 0xffff) {
                            const tw = words[if (reverse) ti - i else ti + seed_words + i - 1];
                            const sw = self.source.words[if (reverse) si - j else si + seed_words + j - 1];
                            const p = pair(text, tw, self.source.text, sw);
                            var candidate = previous;
                            if (p.edits) |edits| {
                                candidate.cost += edits; candidate.character_edits += edits;
                                candidate.aligned += 1; candidate.exact += @intFromBool(p.exact); candidate.chars += p.chars;
                            } else candidate = gap(previous, options);
                            if (better(candidate, selected)) selected = candidate;
                        }
                    }
                    scratch.cells[i][j] = selected;
                    scratch.cells_evaluated += 1;
                }
                const cell = scratch.cells[i][j];
                if (cell.cost != 0xffff and valid(joined(base, cell), seed_words, options) and
                    (!out[i].valid or better(cell, out[i].cell))) out[i] = .{ .valid = true, .source_words = @intCast(j), .cell = cell };
            }
        }
    }

    fn alignCandidate(self: ApproxSource, text: []const u8, words: []const t.Word, ti: usize, si: usize,
        scratch: *Scratch, options: Options) ?t.Match {
        var base = Cell{ .cost = 0, .aligned = seed_words, .exact = seed_words };
        for (0..seed_words) |i| {
            const p = pair(text, words[ti + i], self.source.text, self.source.words[si + i]);
            if (!p.exact) return null; // Hash collisions are not evidence.
            base.chars += p.chars;
        }
        self.extend(text, words, ti, si, true, base, scratch, &scratch.left, options);
        self.extend(text, words, ti, si, false, base, scratch, &scratch.right, options);
        var best: ?t.Match = null;
        for (scratch.left[0..ti + 1], 0..) |left, li| {
            if (!left.valid) continue;
            for (scratch.right[0..words.len - ti - seed_words + 1], 0..) |right, ri| {
                if (!right.valid) continue;
                const cell = joined(joined(base, left.cell), right.cell);
                if (!valid(cell, t.seed_words, options)) continue;
                const quality: u8 = @intCast(100 - (@as(u32, cell.cost) * 100 / cell.chars));
                const begin = ti - li;
                const end = ti + seed_words + ri;
                const source_begin = si - left.source_words;
                const source_end = si + seed_words + right.source_words;
                const found = t.Match{ .begin = begin, .end = end,
                    .source_begin = self.source.words[source_begin].start, .source_end = self.source.words[source_end - 1].end,
                    .source_word_begin = source_begin, .source_word_end = source_end, .ambiguous = false,
                    .kind = if (cell.cost == 0) .exact else .approximate,
                    .aligned_words = cell.aligned, .exact_words = cell.exact, .aligned_characters = cell.chars,
                    .character_edits = cell.character_edits, .word_edits = cell.word_edits, .quality = quality };
                if (best == null or found.aligned_words > best.?.aligned_words or
                    (found.aligned_words == best.?.aligned_words and found.quality > best.?.quality)) best = found;
            }
        }
        return best;
    }

    /// Bounded anchored word alignment, at most 64 ASR words and 256 candidate
    /// DPs. On capacity failure callers must retain uncertainty, not pretend a
    /// partial source search established uniqueness. Returned ranges partition
    /// no text; they are evidence for a separate semantic classifier.
    pub fn match(self: ApproxSource, text: []const u8, words: []const t.Word,
        out: []t.Match, scratch: *Scratch, options: Options) Error![]t.Match {
        if (words.len > max_words) return error.Capacity;
        if (options.max_word_edits > 4 or options.max_candidates == 0 or options.max_candidates > max_candidates) return error.InvalidOptions;
        scratch.candidates = 0; scratch.cells_evaluated = 0;
        var count: usize = 0;
        if (words.len < t.seed_words) return out[0..0];
        for (0..words.len - seed_words + 1) |ti| {
            const target = hash(words[ti..]);
            var lo: usize = 0; var hi = self.seeds.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.seeds[mid].hash < target) lo = mid + 1 else hi = mid;
            }
            while (lo < self.seeds.len and self.seeds[lo].hash == target) : (lo += 1) {
                const si = self.seeds[lo].word;
                var covered = false;
                for (out[0..count]) |prior| {
                    if (prior.word_edits == 0 and prior.begin <= ti and prior.end >= ti + seed_words and
                        prior.source_word_begin <= si and prior.source_word_end >= si + seed_words and
                        ti - prior.begin == si - prior.source_word_begin) covered = true;
                }
                if (covered) continue;
                if (scratch.candidates == options.max_candidates) return error.CandidateCapacity;
                scratch.candidates += 1;
                const found = self.alignCandidate(text, words, ti, si, scratch, options) orelse continue;
                var merged = false;
                for (out[0..count]) |*prior| {
                    if (found.begin >= prior.end or prior.begin >= found.end) continue;
                    const similar = @max(found.aligned_words, prior.aligned_words) - @min(found.aligned_words, prior.aligned_words) <= 1 and
                        @max(found.quality, prior.quality) - @min(found.quality, prior.quality) <= 2;
                    const different = @max(found.source_word_begin, prior.source_word_begin) - @min(found.source_word_begin, prior.source_word_begin) >= seed_words;
                    const ambiguous = similar and (different or prior.ambiguous);
                    if (found.aligned_words > prior.aligned_words or (found.aligned_words == prior.aligned_words and found.quality > prior.quality)) prior.* = found;
                    prior.ambiguous = prior.ambiguous or ambiguous;
                    merged = true; break;
                }
                if (!merged) {
                    if (count == out.len) return error.Capacity;
                    out[count] = found; count += 1;
                }
            }
        }
        std.sort.heap(t.Match, out[0..count], {}, matchLess);
        return out[0..count];
    }
};
