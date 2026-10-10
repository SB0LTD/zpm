//! Atomic interaction-episode retention over the context projection contract.
//! The caller identifies episode boundaries and keeps original bytes/references.
const projection = @import("context_projection");
const t = @import("sig_testing");
pub const Entry = struct {
    id: u64,
    reference: projection.Reference,
    episode: u64,
    body: []const u8,
    required: bool = false,
    recoverable: bool,
    available: bool = true,
    relevance: u16 = 1,
};
pub const Episode = struct {
    first: usize,
    end: usize,
    candidate: projection.Candidate,
};
pub const Error = projection.Error || error{ InvalidEpisode, NoncontiguousBytes };

/// A complete episode is the retention unit. Inputs share contiguous owner
/// storage; kept opaque provider call signatures are never rewritten.
pub fn select(entries: []const Entry, budget: projection.Budget, episodes: []Episode, candidates: []projection.Candidate, stamps: []projection.Stamp, decisions: []projection.Decision, order: []usize) Error!usize {
    if (entries.len == 0) return 0;
    var count: usize = 0;
    var at: usize = 0;
    while (at < entries.len) {
        if (count == episodes.len or count == candidates.len or count == stamps.len) return error.Capacity;
        const first = at;
        const episode = entries[at].episode;
        if (episode == 0) return error.InvalidEpisode;
        for (episodes[0..count]) |old| if (old.candidate.id == episode) return error.InvalidEpisode;
        var required = false;
        var recoverable = true;
        var available = true;
        var relevance: u16 = 0;
        var bytes: usize = 0;
        while (at < entries.len and entries[at].episode == episode) : (at += 1) {
            const entry = entries[at];
            if (entry.id == 0 or !entry.reference.eql(entries[first].reference)) return error.InvalidIdentity;
            if (@intFromPtr(entry.body.ptr) != @intFromPtr(entries[first].body.ptr) + bytes) return error.NoncontiguousBytes;
            bytes += entry.body.len;
            required = required or entry.required;
            recoverable = recoverable and entry.recoverable;
            available = available and entry.available;
            relevance = @max(relevance, entry.relevance);
        }
        // Slice construction stays within the validated contiguous owner buffer.
        const body = entries[first].body.ptr[0..bytes];
        candidates[count] = .{ .id = episode, .reference = entries[first].reference, .origin = .interaction, .lifetime = .session, .full = body, .required = required or !recoverable, .recoverable = recoverable, .relevance = relevance };
        stamps[count] = .{ .reference = entries[first].reference, .available = available };
        episodes[count] = .{ .first = first, .end = at, .candidate = candidates[count] };
        count += 1;
    }
    // This transport has TWO independent limits: encoded bytes and number
    // of messages. Units here are messages, explicitly not model tokens.
    var groups = episodes[0..count];
    const message_count = struct {
        fn measure(ctx: ?*anyopaque, body: []const u8) usize {
            const all: *[]Episode = @ptrCast(@alignCast(ctx.?));
            for (all.*) |group| if (group.candidate.full.ptr == body.ptr) return group.end - group.first;
            return ~@as(usize, 0);
        }
    }.measure;
    _ = try projection.compile(candidates[0..count], stamps[0..count], .{ .now = 0 }, budget, .{ .context = @ptrCast(&groups), .count = message_count }, decisions, order);
    return count;
}

test "calls results and opaque signatures remain one verbatim retention unit" {
    const original = "goalcall:opaque-signatureresult:ID47irrelevantlater";
    const entries = [_]Entry{
        .{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .episode = 1, .body = original[0..4], .required = true, .recoverable = true },
        .{ .id = 2, .reference = .{ .source = 2, .revision = 1 }, .episode = 2, .body = original[4..25], .recoverable = true },
        .{ .id = 3, .reference = .{ .source = 2, .revision = 1 }, .episode = 2, .body = original[25..36], .recoverable = true },
        .{ .id = 4, .reference = .{ .source = 3, .revision = 1 }, .episode = 3, .body = original[36..46], .recoverable = true, .relevance = 0 },
        .{ .id = 5, .reference = .{ .source = 4, .revision = 1 }, .episode = 4, .body = original[46..], .recoverable = true, .required = true },
    };
    var es: [5]Episode = undefined;
    var cs: [5]projection.Candidate = undefined;
    var stamps: [5]projection.Stamp = undefined;
    var ds: [5]projection.Decision = undefined;
    var order: [5]usize = undefined;
    const n = try select(&entries, .{ .bytes = 45, .units = 45 }, &es, &cs, &stamps, &ds, &order);
    try t.expect(n == 4 and ds[0].form == .full and ds[1].form == .full and ds[2].form == .omitted and ds[3].form == .full);
    try t.expect(es[1].first == 1 and es[1].end == 3 and es[1].candidate.body(.full).len == 32);
}

test "unarchived episodes cannot be compacted away under capacity pressure" {
    const entries = [_]Entry{.{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .episode = 1, .body = "unarchived", .recoverable = false }};
    var es: [1]Episode = undefined;
    var cs: [1]projection.Candidate = undefined;
    var stamps: [1]projection.Stamp = undefined;
    var ds: [1]projection.Decision = undefined;
    var order: [1]usize = undefined;
    try t.expectError(error.RequiredBudget, select(&entries, .{ .bytes = 2, .units = 2 }, &es, &cs, &stamps, &ds, &order));
}

test "a stale result invalidates its complete call episode" {
    const original = "goalcallresultlater";
    const entries = [_]Entry{
        .{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .episode = 1, .body = original[0..4], .required = true, .recoverable = true },
        .{ .id = 2, .reference = .{ .source = 2, .revision = 1 }, .episode = 2, .body = original[4..8], .recoverable = true },
        .{ .id = 3, .reference = .{ .source = 2, .revision = 1 }, .episode = 2, .body = original[8..14], .recoverable = true, .available = false },
        .{ .id = 4, .reference = .{ .source = 3, .revision = 1 }, .episode = 3, .body = original[14..], .required = true, .recoverable = true },
    };
    var es: [4]Episode = undefined; var cs: [4]projection.Candidate = undefined;
    var ss: [4]projection.Stamp = undefined; var ds: [4]projection.Decision = undefined; var order: [4]usize = undefined;
    _ = try select(&entries, .{ .bytes = 100, .units = 100 }, &es, &cs, &ss, &ds, &order);
    try t.expect(ds[1].form == .omitted and ds[1].reason == .unavailable);
    var required_entries = entries; required_entries[1].required = true;
    try t.expectError(error.RequiredUnavailable, select(&required_entries, .{ .bytes = 100, .units = 100 }, &es, &cs, &ss, &ds, &order));
}
