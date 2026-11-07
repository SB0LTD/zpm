const std = @import("std");
const t = @import("root.sig");
const classifier = @import("classifier.sig");
const alignment = @import("alignment.sig");

test "pointed Hebrew matches unchanged raw bytes and punctuation" {
    const source = "בְּרֵאשִׁית בָּרָא אֱלֹהִים אֵת הַשָּׁמַיִם וְאֵת הָאָרֶץ";
    const text = "הוא קורא: בראשית ברא אלהים את השמים ואת הארץ. עכשיו נסביר";
    var sw: [32]t.Word = undefined;
    var seeds: [32]t.Seed = undefined;
    const index = try t.Source.init(source, &sw, &seeds);
    var tw: [32]t.Word = undefined;
    const words = try t.tokenize(text, &tw);
    var matches: [8]t.Match = undefined;
    const ms = try index.match(text, words, &matches);
    try std.testing.expectEqual(@as(usize, 1), ms.len);
    try std.testing.expectEqual(@as(usize, 2), ms[0].begin);
    try std.testing.expectEqual(@as(usize, 9), ms[0].end);
    try std.testing.expectEqualStrings(source, source[ms[0].source_begin..ms[0].source_end]);
    try std.testing.expectEqualStrings("בראשית", text[words[2].start..words[2].end]);
    try std.testing.expect(!ms[0].ambiguous);
}
test "acronyms normalize quotes but preserve final letters" {
    var a: [8]t.Word = undefined;
    var b: [8]t.Word = undefined;
    const aw = try t.tokenize("תע״ס ABC מלך", &a);
    const bw = try t.tokenize("תע\"ס abc מלכ", &b);
    try std.testing.expectEqual(aw[0].hash, bw[0].hash);
    try std.testing.expectEqual(aw[1].hash, bw[1].hash);
    try std.testing.expect(aw[2].hash != bw[2].hash);
}
test "invalid UTF8 and word capacity fail explicitly" {
    var words: [1]t.Word = undefined;
    try std.testing.expectError(error.InvalidUtf8, t.tokenize("\xff", &words));
    try std.testing.expectError(error.Capacity, t.tokenize("one two", &words));
}
test "short common phrases are not source evidence" {
    var words: [16]t.Word = undefined;
    var seeds: [16]t.Seed = undefined;
    const source = try t.Source.init("one two three four", &words, &seeds);
    var tw: [16]t.Word = undefined;
    var matches: [4]t.Match = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try source.match("one two three four", try t.tokenize("one two three four", &tw), &matches)).len);
}
test "duplicate source occurrences retain ambiguity" {
    var words: [32]t.Word = undefined;
    var seeds: [32]t.Seed = undefined;
    const source = try t.Source.init("one two three four five x one two three four five", &words, &seeds);
    var tw: [8]t.Word = undefined;
    var matches: [4]t.Match = undefined;
    const ms = try source.match("one two three four five", try t.tokenize("one two three four five", &tw), &matches);
    try std.testing.expect(ms[0].ambiguous);
    const p = t.Proposal{ .begin = 0, .end = 5, .mode = .reading, .confidence = 99 };
    try std.testing.expectEqual(t.Reason.ungrounded_reading, t.adjudicate(p, ms, true).reason);
}
test "index capacity and result capacity cannot silently truncate" {
    var words: [16]t.Word = undefined;
    var seeds: [1]t.Seed = undefined;
    try std.testing.expectError(error.Capacity, t.Source.init("one two three four five six", &words, &seeds));
    var more: [16]t.Seed = undefined;
    const source = try t.Source.init("one two three four five six", &words, &more);
    var tw: [16]t.Word = undefined;
    var none: [0]t.Match = .{};
    try std.testing.expectError(error.Capacity, source.match("one two three four five", try t.tokenize("one two three four five", &tw), &none));
}
test "mixed mode proposal covers every word once" {
    var ps: [8]t.Proposal = undefined;
    const result = try t.parseProposals("0\t5\treading\t94\n5\t8\tcommentary\t87\n8\t10\ttechnical\t93\n", 10, &ps);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    const matches = [_]t.Match{.{ .begin = 0, .end = 5, .source_begin = 8, .source_end = 50, .ambiguous = false }};
    try std.testing.expectEqual(t.Mode.reading, t.adjudicate(ps[0], &matches, true).proposal.mode);
    try std.testing.expectEqual(t.Mode.commentary, t.adjudicate(ps[1], &matches, true).proposal.mode);
    try std.testing.expectEqual(t.Mode.technical, t.adjudicate(ps[2], &matches, true).proposal.mode);
}
test "gaps overlap missing tails overflow and invented modes reject entire response" {
    const invalid = [_][]const u8{
        "1\t5\treading\t90", "0\t6\treading\t90", "0\t4\treading\t90",
        "0\t0\treading\t90", "0\t5\treading\t101", "0\t5\trav\t90",
        "0\t3\tcommentary\t90\n2\t5\ttechnical\t90",
        "0\t2\tcommentary\t90\n3\t5\ttechnical\t90",
        "```\n0\t5\treading\t90\n```", "0\t5\treading\t90\textra", "",
    };
    for (invalid) |value| {
        var ps: [8]t.Proposal = undefined;
        try std.testing.expectError(error.InvalidProposal, t.parseProposals(value, 5, &ps));
    }
}
test "proposal capacity is explicit" {
    var out: [1]t.Proposal = undefined;
    try std.testing.expectError(error.Capacity, t.parseProposals("0\t2\tunknown\t0\n2\t5\tunknown\t0", 5, &out));
}
test "reading needs source support and confidence" {
    const p = t.Proposal{ .begin = 0, .end = 5, .mode = .reading, .confidence = 99 };
    try std.testing.expectEqual(t.Mode.unknown, t.adjudicate(p, &.{}, true).proposal.mode);
    var low = p;
    low.mode = .technical;
    low.confidence = 79;
    try std.testing.expectEqual(t.Reason.low_confidence, t.adjudicate(low, &.{}, true).reason);
    low.confidence = 95;
    low.mode = .digression;
    try std.testing.expectEqual(t.Reason.missing_topic, t.adjudicate(low, &.{}, false).reason);
}
test "segment times are validated without inventing speaker or word times" {
    const s = t.Segment{ .id = 1, .start_ms = 12, .end_ms = 11, .text = "hello" };
    try std.testing.expectError(error.InvalidTime, s.validate());
    try std.testing.expect(s.speaker == null);
}
test "JSON safely escapes controls quotes and backslashes" {
    var out: [128]u8 = undefined;
    var pos: usize = 0;
    try t.jsonString("a\n\"\\\t", &out, &pos);
    try std.testing.expectEqualStrings("\"a\\u000a\\\"\\\\\\u0009\"", out[0..pos]);
    var tiny: [1]u8 = undefined;
    pos = 0;
    try std.testing.expectError(error.Capacity, t.jsonString("hello", &tiny, &pos));
}
test "prompt identifies words and source evidence with bounded output" {
    var words: [8]t.Word = undefined;
    const ws = try t.tokenize("hello world", &words);
    var out: [4096]u8 = undefined;
    const prompt = try t.buildPrompt("topic", "before", "hello world", "after", ws, &.{}, &out);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "0\t\"hello\"\n1\t\"world\"") != null);
    var tiny: [12]u8 = undefined;
    try std.testing.expectError(error.Capacity, t.buildPrompt("", "", "hello world", "", ws, &.{}, &tiny));
}

test "finite classification scores have explicit abstention and stable softmax" {
    const span = classifier.Span{ .begin = 0, .end = 8 };
    const accepted = try classifier.decide(&.{ 10000, 10006, 10000, 10000, 10000 }, span, &.{}, true, .{});
    try std.testing.expectEqual(t.Mode.commentary, accepted.admitted);
    try std.testing.expect(accepted.conditional_share > 0.99);
    const ambiguous = try classifier.decide(&.{ 0, 2, 1.9, 0, 0 }, span, &.{}, true, .{});
    try std.testing.expectEqual(t.Mode.unknown, ambiguous.admitted);
    try std.testing.expectEqual(.low_margin, ambiguous.reason);
    const uncertain = try classifier.decide(&.{ 0, 0, 0, 0, 9 }, span, &.{}, true, .{});
    try std.testing.expectEqual(.uncertain, uncertain.reason);
    try std.testing.expectError(error.InvalidScores, classifier.decide(&.{ 0, 0, 0, std.math.nan(f32), 0 }, span, &.{}, true, .{}));
    try std.testing.expectError(error.InvalidPolicy, classifier.decide(&.{ 0, 0, 0, 0, 0 }, span, &.{}, true, .{ .minimum_share = 2 }));
    try std.testing.expectError(error.InvalidProposal, classifier.decide(&.{ 0, 0, 0, 0, 0 }, .{ .begin = 2, .end = 1 }, &.{}, true, .{}));
}
test "finite reading still requires unambiguous source and digression needs topic" {
    const span = classifier.Span{ .begin = 0, .end = 7 };
    const scores = [_]f32{ 10, 0, 0, 0, 0 };
    try std.testing.expectEqual(.ungrounded_reading, (try classifier.decide(&scores, span, &.{}, true, .{})).reason);
    const matches = [_]t.Match{.{ .begin = 0, .end = 7, .source_begin = 0, .source_end = 50, .ambiguous = false }};
    try std.testing.expectEqual(t.Mode.reading, (try classifier.decide(&scores, span, &matches, true, .{})).admitted);
    try std.testing.expectEqual(.missing_topic, (try classifier.decide(&.{ 0, 0, 10, 0, 0 }, span, &.{}, false, .{})).reason);
}
test "structural partition covers mixed source and punctuation without guessing modes" {
    const text = "one two three four five six seven. explain this? microphone works!";
    var wb: [32]t.Word = undefined;
    const words = try t.tokenize(text, &wb);
    const matches = [_]t.Match{.{ .begin = 0, .end = 7, .source_begin = 0, .source_end = 30, .ambiguous = false }};
    var out: [8]classifier.Span = undefined;
    const spans = try classifier.partition(text, words, &matches, 24, &out);
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqual(@as(usize, 7), spans[0].end);
    try std.testing.expectEqual(@as(usize, 9), spans[1].end);
    try std.testing.expectEqual(words.len, spans[2].end);
    try std.testing.expectError(error.Capacity, classifier.partition(text, words, &matches, 0, &out));
}

test "approximate Hebrew alignment accepts anchored ASR spellings with edit evidence" {
    const printed = "ורזא דמלה קול אומר קרא";
    const spoken = "ורזה דמילה קול אומר קרא";
    var sw: [32]t.Word = undefined; var s5: [32]t.Seed = undefined; var s3: [32]t.Seed = undefined;
    const source = try t.Source.init(printed, &sw, &s5);
    const index = try alignment.ApproxSource.init(source, &s3);
    var wb: [32]t.Word = undefined; var matches: [8]t.Match = undefined;
    var scratch: alignment.Scratch = undefined;
    const found = try index.match(spoken, try t.tokenize(spoken, &wb), &matches, &scratch, .{});
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(.approximate, found[0].kind);
    try std.testing.expectEqual(@as(u16, 2), found[0].character_edits);
    try std.testing.expectEqual(@as(u16, 0), found[0].word_edits);
    try std.testing.expectEqual(@as(u16, 5), found[0].aligned_words);
    try std.testing.expectEqual(@as(u16, 3), found[0].exact_words);
    try std.testing.expect(found[0].supports(0, 5));
    const proposal = t.Proposal{ .begin = 0, .end = 5, .mode = .reading, .confidence = 95 };
    try std.testing.expectEqual(t.Mode.reading, t.adjudicate(proposal, found, true).proposal.mode);
    try std.testing.expectEqualStrings(printed, printed[found[0].source_begin..found[0].source_end]);
}
test "short common anchor cannot promote unrelated or heavily corrupted speech" {
    var sw: [32]t.Word = undefined; var s5: [32]t.Seed = undefined; var s3: [32]t.Seed = undefined;
    const source = try t.Source.init("ורזא דמלה קול אומר קרא", &sw, &s5);
    const index = try alignment.ApproxSource.init(source, &s3);
    var wb: [32]t.Word = undefined; var matches: [8]t.Match = undefined;
    var scratch: alignment.Scratch = undefined;
    const spoken = "שלום מחר קול אומר קרא";
    try std.testing.expectEqual(@as(usize, 0), (try index.match(spoken, try t.tokenize(spoken, &wb), &matches, &scratch, .{})).len);
    const short = "קול אומר קרא";
    try std.testing.expectEqual(@as(usize, 0), (try index.match(short, try t.tokenize(short, &wb), &matches, &scratch, .{})).len);
}
test "repeated approximate source passage is ambiguous and cannot admit reading" {
    var sw: [64]t.Word = undefined; var s5: [64]t.Seed = undefined; var s3: [64]t.Seed = undefined;
    const source = try t.Source.init("ורזא דמלה קול אומר קרא סוף ורזא דמלה קול אומר קרא", &sw, &s5);
    const index = try alignment.ApproxSource.init(source, &s3);
    const spoken = "ורזה דמילה קול אומר קרא";
    var wb: [32]t.Word = undefined; var matches: [8]t.Match = undefined;
    var scratch: alignment.Scratch = undefined;
    const found = try index.match(spoken, try t.tokenize(spoken, &wb), &matches, &scratch, .{});
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(found[0].ambiguous);
    try std.testing.expect(!found[0].supports(0, 5));
    try std.testing.expectError(error.CandidateCapacity, index.match(spoken, wb[0..5], &matches, &scratch, .{ .max_candidates = 1 }));
}
test "bounded approximate alignment records an insertion rather than changing text" {
    const printed = "first second third fourth fifth sixth seventh eighth ninth tenth";
    const spoken = "first second third fourth please fifth sixth seventh eighth ninth tenth";
    var sw: [32]t.Word = undefined; var s5: [32]t.Seed = undefined; var s3: [32]t.Seed = undefined;
    const index = try alignment.ApproxSource.init(try t.Source.init(printed, &sw, &s5), &s3);
    var wb: [32]t.Word = undefined; var matches: [8]t.Match = undefined;
    var scratch: alignment.Scratch = undefined;
    const words = try t.tokenize(spoken, &wb);
    const found = try index.match(spoken, words, &matches, &scratch, .{});
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(u16, 1), found[0].word_edits);
    try std.testing.expectEqual(@as(u16, 10), found[0].aligned_words);
    try std.testing.expectEqual(@as(usize, 11), found[0].end);
    try std.testing.expect(found[0].supports(0, 11));
    try std.testing.expectEqualStrings("please", spoken[words[4].start..words[4].end]);
}
test "approximate search verifies hashes and reports source or result capacity" {
    var sw: [32]t.Word = undefined; var s5: [32]t.Seed = undefined; var s3: [32]t.Seed = undefined;
    const source = try t.Source.init("first second third fourth fifth", &sw, &s5);
    var small: [1]t.Seed = undefined;
    try std.testing.expectError(error.Capacity, alignment.ApproxSource.init(source, &small));
    const index = try alignment.ApproxSource.init(source, &s3);
    var wb: [32]t.Word = undefined; var matches: [8]t.Match = undefined;
    var scratch: alignment.Scratch = undefined;
    const spoken = "wrong unrelated token nothing same";
    const words = try t.tokenize(spoken, &wb);
    for (0..3) |i| words[i].hash = source.words[i].hash;
    try std.testing.expectEqual(@as(usize, 0), (try index.match(spoken, words, &matches, &scratch, .{})).len);
    var none: [0]t.Match = .{};
    const exact = "first second third fourth fifth";
    try std.testing.expectError(error.Capacity, index.match(exact, try t.tokenize(exact, &wb), &none, &scratch, .{}));
}
test "long exact source alignment reuses covered anchors instead of repeated DP" {
    var text: [1024]u8 = undefined;
    var pos: usize = 0;
    for (0..64) |i| {
        var number: [32]u8 = undefined;
        try t.append(&text, &pos, try std.fmt.bufPrint(&number, "word{d} ", .{i}));
    }
    const raw = text[0..pos];
    var sw: [80]t.Word = undefined; var s5: [80]t.Seed = undefined; var s3: [80]t.Seed = undefined;
    const index = try alignment.ApproxSource.init(try t.Source.init(raw, &sw, &s5), &s3);
    var wb: [80]t.Word = undefined; var matches: [8]t.Match = undefined;
    var scratch: alignment.Scratch = undefined;
    const found = try index.match(raw, try t.tokenize(raw, &wb), &matches, &scratch, .{});
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(.exact, found[0].kind);
    try std.testing.expectEqual(@as(usize, 64), found[0].end);
    try std.testing.expectEqual(@as(usize, 1), scratch.candidates);
    try std.testing.expect(scratch.cells_evaluated < 1024);
}
test "short focus uses longer source evidence and maps unedited neighbor bytes" {
    const before = "ורזה דמילה ";
    const focus = "קול אומר קרא,";
    const after = " כגון קרא נא היש עונך";
    const printed = "ורזא דמלה קול אומר קרא כגון קרא נא היש עונך";
    var sw: [64]t.Word = undefined; var s5: [64]t.Seed = undefined; var s3: [64]t.Seed = undefined;
    const index = try alignment.ApproxSource.init(try t.Source.init(printed, &sw, &s5), &s3);
    var storage: alignment.ContextStorage = undefined;
    var scratch: alignment.Scratch = undefined;
    var matches: [8]t.Match = undefined;
    const evidence = try index.alignContext(before, focus, after, &storage, &matches, &scratch, .{});
    try std.testing.expectEqualStrings(focus, evidence.query.text[evidence.query.focus_bytes.begin..evidence.query.focus_bytes.end]);
    try std.testing.expectEqual(@as(usize, 2), evidence.query.focus.begin);
    try std.testing.expectEqual(@as(usize, 5), evidence.query.focus.end);
    try std.testing.expect(evidence.matches[0].supports(evidence.query.focus.begin, evidence.query.focus.end));
    for (evidence.query.words, evidence.query.origins) |word, origin| {
        const original = switch (origin.part) { .before => before, .focus => focus, .after => after };
        try std.testing.expectEqualStrings(original[origin.begin_byte..origin.end_byte], evidence.query.text[word.start..word.end]);
    }
    const only_three = [_]t.Match{.{ .begin = 0, .end = 3, .source_begin = 0, .source_end = 20, .ambiguous = false }};
    try std.testing.expect(!only_three[0].supports(0, 3));
}
test "context clipping retains at most sixteen neighboring words and thirty-two focus words" {
    const neighbor = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty";
    var storage: alignment.ContextStorage = undefined;
    const query = try alignment.buildContext(neighbor, "focus", neighbor, &storage);
    try std.testing.expectEqual(@as(usize, 33), query.words.len);
    try std.testing.expectEqual(@as(usize, 16), query.focus.begin);
    try std.testing.expectEqualStrings("five", query.text[query.words[0].start..query.words[0].end]);
    try std.testing.expectEqualStrings("sixteen", query.text[query.words[32].start..query.words[32].end]);
    try std.testing.expectError(error.Capacity, alignment.buildContext("", neighbor ++ " " ++ neighbor, "", &storage));
}

test "specialist disagreement abstains without rewriting the primary proposal or scores" {
    const span = classifier.Span{ .begin = 0, .end = 7 };
    const matches = [_]t.Match{.{ .begin = 0, .end = 7, .source_begin = 0, .source_end = 30, .ambiguous = false }};
    const primary = try classifier.decide(&.{ 0, 12, 0, 0, 0 }, span, &matches, true, .{});
    try std.testing.expectEqual(.source_role, classifier.verificationKind(primary, span, &matches).?);
    try std.testing.expectEqual(@as(?classifier.VerificationKind, null), classifier.verificationKind(primary, span, &.{}));
    const waiting = classifier.awaitingVerification(primary);
    try std.testing.expectEqual(.verification_required, waiting.reason);
    try std.testing.expectEqual(t.Mode.unknown, waiting.admitted);
    const verified = try classifier.verify(primary, .source_role, &.{ 19, 0, 0 }, .{});
    try std.testing.expectEqual(.disagreement, verified.verification.result);
    try std.testing.expectEqual(.verification_conflict, verified.decision.reason);
    try std.testing.expectEqual(t.Mode.unknown, verified.decision.admitted);
    try std.testing.expectEqual(primary.proposed, verified.decision.proposed);
    try std.testing.expectEqual(primary.margin, verified.decision.margin);
    try std.testing.expectEqual(primary.conditional_share, verified.decision.conditional_share);
    const agreed = try classifier.verify(primary, .source_role, &.{ 0, 19, 0 }, .{});
    try std.testing.expectEqual(.agreement, agreed.verification.result);
    try std.testing.expectEqual(t.Mode.commentary, agreed.decision.admitted);
}

test "digression requires independent agreement and never changes into a technical label" {
    const primary = try classifier.decide(&.{ 0, 0, 15, 0, 0 }, .{ .begin = 0, .end = 6 }, &.{}, true, .{});
    try std.testing.expectEqual(.digression_role, classifier.verificationKind(primary, .{ .begin = 0, .end = 6 }, &.{}).?);
    const class_related = try classifier.verify(primary, .digression_role, &.{ 0, 15, 0 }, .{});
    try std.testing.expectEqual(t.Mode.unknown, class_related.decision.admitted);
    try std.testing.expectEqual(t.Mode.digression, class_related.decision.proposed);
    const personal = try classifier.verify(primary, .digression_role, &.{ 15, 0, 0 }, .{});
    try std.testing.expectEqual(t.Mode.digression, personal.decision.admitted);
    const uncertain = try classifier.verify(primary, .digression_role, &.{ 0, 0, 15 }, .{});
    try std.testing.expectEqual(.verification_uncertain, uncertain.decision.reason);
    const weak = try classifier.verify(primary, .digression_role, &.{ 1, 0, 0 }, .{});
    try std.testing.expectEqual(.low_margin, weak.verification.result);
    try std.testing.expectError(error.InvalidScores, classifier.verify(primary, .digression_role, &.{ 0, std.math.nan(f32), 1 }, .{}));
    try std.testing.expectError(error.InvalidScores, classifier.verify(primary, .digression_role, &.{ 1, 0 }, .{}));
    try std.testing.expectError(error.InvalidScores, classifier.verify(primary, .digression_role, &.{ 3.4e38, -3.4e38, -3.4e38 }, .{}));
    try std.testing.expectError(error.InvalidScores, classifier.decide(&.{ 3.4e38, -3.4e38, -3.4e38, -3.4e38, -3.4e38 }, .{ .begin = 0, .end = 6 }, &.{}, true, .{}));
    try std.testing.expectError(error.InvalidProposal, classifier.verify(primary, .source_role, &.{ 1, 0, 0 }, .{}));
    try std.testing.expectError(error.InvalidPolicy, classifier.verify(primary, .digression_role, &.{ 1, 0, 0 }, .{ .minimum_share = 1.1 }));
}
