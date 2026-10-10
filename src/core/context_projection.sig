//! Model-independent context projection. Owners retain payloads and persistence.
//! This module selects typed views and emits loss receipts; it never invents text.
const mem = @import("sig_mem");
const t = @import("sig_testing");
pub const Error = error{ Capacity, InvalidIdentity, InvalidDependency, InvalidBudget, RequiredUnavailable, RequiredConflict, RequiredBudget, InvalidEvidence, UnrecoverableLoss };
pub const Origin = enum(u8) { policy, state, owner, validated_learning, derived, retrieved, interaction, observation, hypothesis };
pub const Lifetime = enum(u8) { operation, session, durable };
pub const Privacy = enum(u8) { public, session, owner };
pub const Form = enum(u8) { full, exact, descriptor, omitted };
pub const Reason = enum(u8) { selected, compacted, disclosed, budget, irrelevant, expired, invalidated, superseded, conflict, duplicate, untrusted, unavailable };
pub const Reference = struct {
    source: u64 = 0,
    revision: u64 = 0,
    pub fn eql(a: Reference, b: Reference) bool {
        return a.source == b.source and a.revision == b.revision;
    }
};
pub const Stamp = struct { reference: Reference, available: bool = true, origin: Origin = .hypothesis, privacy: Privacy = .owner };
pub const Candidate = struct {
    id: u64,
    reference: Reference,
    origin: Origin,
    lifetime: Lifetime = .operation,
    privacy: Privacy = .public,
    /// Explicit single-valued claim identity. Zero means no contradiction inference.
    claim: u64 = 0,
    value: u64 = 0,
    observed: u64 = 0,
    expires: u64 = 0,
    deps: [4]Reference = @splat(.{}),
    dep_count: u3 = 0,
    required: bool = false,
    task: u64 = 0,
    confidence: u16 = 65535,
    relevance: u16 = 0,
    usage: u16 = 0,
    /// All variants are owner-produced. Exact is a lossless extraction with
    /// explicit identifiers/constraints, not a generated summary.
    full: []const u8,
    exact: []const u8 = "",
    descriptor: []const u8 = "",
    prefer_descriptor: bool = false,
    recoverable: bool = true,
    pub fn body(c: Candidate, f: Form) []const u8 {
        return switch (f) {
            .full => c.full,
            .exact => c.exact,
            .descriptor => c.descriptor,
            .omitted => "",
        };
    }
};
pub const Budget = struct {
    bytes: usize,
    units: usize,
    reserve_bytes: usize = 0,
    reserve_units: usize = 0,
    item_overhead: usize = 0,
};
pub const Cost = struct { bytes: usize, units: usize };
/// A provider supplies a tokenizer at the boundary. Conservative byte units
/// work without one, but must not be reported as measured model tokens.
pub const Measure = struct {
    context: ?*anyopaque = null,
    count: *const fn (?*anyopaque, []const u8) usize = byteUnits,
};
pub fn byteUnits(_: ?*anyopaque, text: []const u8) usize {
    return text.len;
}
pub const Policy = struct {
    task: u64 = 0,
    now: u64,
    min_relevance: u16 = 1,
    allow_hypotheses: bool = false,
    allow_external: bool = true,
    descriptor_first: bool = false,
    clearance: Privacy = .public,
};
pub const Decision = struct { id: u64, reference: Reference, form: Form = .omitted, reason: Reason = .irrelevant, cost: Cost = .{ .bytes = 0, .units = 0 }, invalidated_by: Reference = .{}, effective_authority: u8 = 0, effective_privacy: Privacy = .public, external: bool = false, hypothetical: bool = false, eligible: bool = false, resolved: bool = false };
pub const Totals = struct { cost: Cost = .{ .bytes = 0, .units = 0 }, candidates: usize = 0, selected: usize = 0, deferred: usize = 0, conflicts: usize = 0, comparisons: usize = 0 };
pub fn authority(origin: Origin) u8 {
    return switch (origin) {
        .policy => 6,
        .state => 5,
        .owner => 4,
        .validated_learning => 3,
        .derived => 2,
        .interaction, .observation => 1,
        .retrieved, .hypothesis => 0,
    };
}
fn fresh(reference: Reference, stamps: []const Stamp) bool {
    for (stamps) |s| if (s.reference.source == reference.source) return s.available and s.reference.revision == reference.revision;
    return false;
}
fn invalid(c: Candidate, stamps: []const Stamp, p: Policy) ?Decision {
    var d: Decision = .{ .id = c.id, .reference = c.reference };
    if (!fresh(c.reference, stamps)) {
        d.reason = .unavailable;
        d.invalidated_by = c.reference;
        return d;
    }
    for (c.deps[0..c.dep_count]) |dep| if (!fresh(dep, stamps)) {
        d.reason = .invalidated;
        d.invalidated_by = dep;
        return d;
    };
    if (c.expires != 0 and p.now >= c.expires) {
        d.reason = .expired;
        return d;
    }
    if (@intFromEnum(c.privacy) > @intFromEnum(p.clearance) or (c.origin == .hypothesis and !p.allow_hypotheses) or (c.origin == .retrieved and !p.allow_external)) {
        d.reason = .untrusted;
        return d;
    }
    return null;
}
fn stronger(a: Candidate, b: Candidate, ad: Decision, bd: Decision) bool {
    if (ad.effective_authority != bd.effective_authority) return ad.effective_authority > bd.effective_authority;
    // Revisions order only versions of the SAME source; wall time cannot
    // resolve independent, equally authoritative conflicting sources.
    return a.reference.source == b.reference.source and a.reference.revision > b.reference.revision;
}
fn before(a: Candidate, b: Candidate, ad: Decision, bd: Decision, p: Policy) bool {
    if (a.required != b.required) return a.required;
    const at = p.task != 0 and a.task == p.task;
    const bt = p.task != 0 and b.task == p.task;
    if (at != bt) return at;
    if (a.relevance != b.relevance) return a.relevance > b.relevance;
    if (ad.effective_authority != bd.effective_authority) return ad.effective_authority > bd.effective_authority;
    if (a.confidence != b.confidence) return a.confidence > b.confidence;
    if (a.observed != b.observed) return a.observed > b.observed;
    if (a.usage != b.usage) return a.usage > b.usage;
    return a.id < b.id;
}
/// decisions and scratch must each fit candidates. No I/O, storage or models.
/// Errors leave receipts but callers MUST NOT consume a failed projection.
pub fn compile(candidates: []const Candidate, stamps: []const Stamp, policy: Policy, budget: Budget, measure: Measure, decisions: []Decision, order: []usize) Error!Totals {
    if (candidates.len > decisions.len or candidates.len > order.len) return error.Capacity;
    if (budget.reserve_bytes > budget.bytes or budget.reserve_units > budget.units) return error.InvalidBudget;
    for (stamps, 0..) |stamp, i| {
        if (stamp.reference.source == 0 or stamp.reference.revision == 0) return error.InvalidIdentity;
        for (stamps[0..i]) |old| if (old.reference.source == stamp.reference.source) return error.InvalidIdentity;
    }
    var total: Totals = .{ .candidates = candidates.len, .cost = .{ .bytes = budget.reserve_bytes, .units = budget.reserve_units } };
    for (candidates, 0..) |c, i| {
        if (c.id == 0 or c.reference.source == 0 or c.reference.revision == 0) return error.InvalidIdentity;
        if (c.dep_count > c.deps.len) return error.InvalidDependency;
        for (c.deps[0..c.dep_count]) |dep| if (dep.source == 0 or dep.revision == 0) return error.InvalidDependency;
        for (candidates[0..i]) |previous| if (previous.id == c.id) return error.InvalidIdentity;
        decisions[i] = invalid(c, stamps, policy) orelse .{ .id = c.id, .reference = c.reference, .reason = .selected };
        order[i] = i;
    }
    // Topological dependency validation uses caller-owned receipts as scratch.
    // Omitting a valid source from this projection does not invalidate its data.
    var remaining = candidates.len;
    while (remaining != 0) {
        var progress = false;
        for (candidates, 0..) |c, i| {
            const d = &decisions[i];
            if (d.resolved) continue;
            var ready = true;
            for (c.deps[0..c.dep_count]) |dep| {
                for (candidates, 0..) |parent, j| {
                    if (parent.reference.eql(dep) and !decisions[j].resolved) ready = false;
                }
            }
            if (!ready) continue;
            d.effective_authority = authority(c.origin);
            d.effective_privacy = c.privacy;
            d.external = c.origin == .retrieved;
            d.hypothetical = c.origin == .hypothesis;
            for (c.deps[0..c.dep_count]) |dep| {
                var found = false;
                for (candidates, 0..) |parent, j| {
                    if (!parent.reference.eql(dep)) continue;
                    found = true;
                    const pd = decisions[j];
                    d.effective_authority = @min(d.effective_authority, pd.effective_authority);
                    d.effective_privacy = @enumFromInt(@max(@intFromEnum(d.effective_privacy), @intFromEnum(pd.effective_privacy)));
                    d.external = d.external or pd.external;
                    d.hypothetical = d.hypothetical or pd.hypothetical;
                    if (d.reason == .selected and !pd.eligible) {
                        d.reason = .invalidated;
                        d.invalidated_by = if (pd.invalidated_by.source != 0) pd.invalidated_by else dep;
                    }
                }
                if (!found) for (stamps) |stamp| {
                    if (!stamp.reference.eql(dep)) continue;
                    d.effective_authority = @min(d.effective_authority, authority(stamp.origin));
                    d.effective_privacy = @enumFromInt(@max(@intFromEnum(d.effective_privacy), @intFromEnum(stamp.privacy)));
                    d.external = d.external or stamp.origin == .retrieved;
                    d.hypothetical = d.hypothetical or stamp.origin == .hypothesis;
                };
            }
            if (d.reason == .selected and (@intFromEnum(d.effective_privacy) > @intFromEnum(policy.clearance) or (d.external and !policy.allow_external) or (d.hypothetical and !policy.allow_hypotheses))) d.reason = .untrusted;
            d.eligible = d.reason == .selected;
            d.resolved = true;
            remaining -= 1;
            progress = true;
        }
        if (!progress) return error.InvalidDependency;
    }
    // Resolve against the original eligibility set: exclusion order cannot
    // allow a lower-trust fact to reappear after its opponent is excluded.
    for (candidates, 0..) |c, i| {
        if (!decisions[i].eligible or c.claim == 0) continue;
        var reason: Reason = .selected;
        for (candidates, 0..) |other, j| {
            total.comparisons += 1;
            if (i == j or other.claim != c.claim or !decisions[j].eligible) continue;
            if (other.value == c.value) {
                if (reason == .selected and (stronger(other, c, decisions[j], decisions[i]) or (!stronger(c, other, decisions[i], decisions[j]) and other.id < c.id))) reason = .duplicate;
            } else if (stronger(other, c, decisions[j], decisions[i])) {
                reason = .superseded;
                break;
            } else if (!stronger(c, other, decisions[i], decisions[j])) reason = .conflict;
        }
        decisions[i].reason = reason;
    }
    // Claim supersession/conflict also invalidates dependent syntheses.
    for (0..candidates.len) |_| {
        var changed = false;
        for (candidates, 0..) |c, i| {
            if (decisions[i].reason != .selected) continue;
            for (c.deps[0..c.dep_count]) |dep| {
                for (candidates, 0..) |parent, j| {
                    if (!parent.reference.eql(dep)) continue;
                    const reason = decisions[j].reason;
                    if (reason == .selected or reason == .duplicate) continue;
                    decisions[i].reason = .invalidated;
                    decisions[i].invalidated_by = if (decisions[j].invalidated_by.source != 0) decisions[j].invalidated_by else dep;
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }
    // Stable insertion sort; bounded caller capacity, deterministic ties.
    for (1..if (candidates.len == 0) @as(usize, 1) else candidates.len) |i| {
        const index = order[i];
        var j = i;
        while (j > 0 and before(candidates[index], candidates[order[j - 1]], decisions[index], decisions[order[j - 1]], policy)) : (j -= 1) {
            total.comparisons += 1;
            order[j] = order[j - 1];
        }
        order[j] = index;
    }
    for (order[0..candidates.len]) |i| {
        const c = candidates[i];
        const d = &decisions[i];
        if (d.reason != .selected) {
            if (d.reason == .conflict) total.conflicts += 1;
            if (c.required and d.reason != .duplicate) return if (d.reason == .conflict) error.RequiredConflict else error.RequiredUnavailable;
            if (!c.recoverable) return error.UnrecoverableLoss;
            continue;
        }
        if (!c.required and c.relevance < policy.min_relevance and !(policy.task != 0 and c.task == policy.task)) {
            d.reason = .irrelevant;
            total.deferred += 1;
            if (!c.recoverable) return error.UnrecoverableLoss;
            continue;
        }
        const variants: [3]Form = if ((policy.descriptor_first or c.prefer_descriptor) and !c.required) .{ .descriptor, .exact, .full } else .{ .full, .exact, .descriptor };
        for (variants) |form| {
            // A required item may use exact protected fields, never only an index.
            if ((c.required or !c.recoverable) and form == .descriptor) continue;
            const text = c.body(form);
            if (text.len == 0) continue;
            const bytes = text.len +| budget.item_overhead;
            const units = measure.count(measure.context, text) +| budget.item_overhead;
            if (bytes > budget.bytes - total.cost.bytes or units > budget.units - total.cost.units) continue;
            d.form = form;
            d.cost = .{ .bytes = bytes, .units = units };
            d.reason = switch (form) {
                .full => .selected,
                .exact => .compacted,
                .descriptor => .disclosed,
                .omitted => unreachable,
            };
            total.cost.bytes += bytes;
            total.cost.units += units;
            total.selected += 1;
            break;
        }
        if (d.form == .omitted) {
            d.reason = .budget;
            total.deferred += 1;
            if (c.required) return error.RequiredBudget;
            if (!c.recoverable) return error.UnrecoverableLoss;
        }
    }
    return total;
}
/// Deterministic whole-word overlap for routing, not semantic truth. Owners
/// may supply richer relevance; this cheap baseline never calls a model.
pub fn relevance(query: []const u8, body: []const u8) u16 {
    var score: u16 = 0;
    var begin: usize = 0;
    while (begin < query.len) {
        while (begin < query.len and !word(query[begin])) : (begin += 1) {}
        var end = begin;
        while (end < query.len and word(query[end])) : (end += 1) {}
        if (end - begin >= 3) {
            var at: usize = 0;
            while (at + end - begin <= body.len) : (at += 1) {
                if (at != 0 and word(body[at - 1])) continue;
                const stop = at + end - begin;
                if (stop < body.len and word(body[stop])) continue;
                var equal = true;
                for (query[begin..end], body[at..stop]) |a, b| if (lower(a) != lower(b)) { equal = false; break; };
                if (equal) { score +|= 1; break; }
            }
        }
        begin = if (end == begin) end + 1 else end;
    }
    return score;
}
fn word(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c >= 128; }
fn lower(c: u8) u8 { return if (c >= 'A' and c <= 'Z') c + 32 else c; }
/// Exact evidence promotion: caller authenticates source classification.
/// Independent owner statements or verified system outcomes corroborate;
/// model/external repetition never does. Evidence from one operation counts once.
pub const Evidence = struct { id: u64, operation: u64, origin: Origin, statement: []const u8, valid: bool = true };
pub const Validation = struct { accepted: bool, corroborations: usize, first: u64 = 0, last: u64 = 0 };
pub fn validateLearning(body: []const u8, evidence: []const Evidence, explicit_owner: bool) Validation {
    var result: Validation = .{ .accepted = false, .corroborations = 0 };
    if (body.len == 0) return result;
    for (evidence, 0..) |e, i| {
        if (!e.valid or e.id == 0 or e.operation == 0 or (e.origin != .owner and e.origin != .state) or !mem.eql(u8, body, e.statement)) continue;
        var duplicate = false;
        for (evidence[0..i]) |old| if (old.valid and old.id != 0 and old.operation == e.operation and (old.origin == .owner or old.origin == .state) and mem.eql(u8, body, old.statement)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        result.corroborations += 1;
        if (result.first == 0) result.first = e.id;
        result.last = e.id;
        if (explicit_owner and e.origin == .owner) result.accepted = true;
    }
    result.accepted = result.accepted or result.corroborations >= 2;
    return result;
}
/// Confidence decay for learned/observed evidence, never for policy or state.
/// An integer half-life measured in owner's monotonic epochs, not wall clock.
pub fn decay(confidence: u16, elapsed: u64, half_life: u64) u16 {
    if (half_life == 0) return confidence;
    const periods = @min(elapsed / half_life, 16);
    return confidence >> @as(u4, @intCast(@min(periods, 15))) >> @as(u4, @intCast(if (periods == 16) @as(u4, 1) else 0));
}
test "source revision invalidates derived context even at high similarity" {
    const cs = [_]Candidate{.{ .id = 1, .reference = .{ .source = 2, .revision = 1 }, .origin = .derived, .relevance = 65535, .full = "old", .deps = .{ .{ .source = 1, .revision = 1 }, .{}, .{}, .{} }, .dep_count = 1 }};
    var ds: [1]Decision = undefined;
    var order: [1]usize = undefined;
    const r = try compile(&cs, &.{ .{ .reference = .{ .source = 2, .revision = 1 } }, .{ .reference = .{ .source = 1, .revision = 2 } } }, .{ .now = 5 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(r.selected == 0 and ds[0].reason == .invalidated and ds[0].invalidated_by.source == 1);
}
test "conflicts use authority rather than prompt order or wall time" {
    const cs = [_]Candidate{
        .{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .retrieved, .claim = 9, .value = 1, .relevance = 500, .full = "poison" },
        .{ .id = 2, .reference = .{ .source = 2, .revision = 1 }, .origin = .state, .claim = 9, .value = 2, .relevance = 1, .full = "correct" },
    };
    var ds: [2]Decision = undefined;
    var order: [2]usize = undefined;
    _ = try compile(&cs, &.{ .{ .reference = cs[0].reference }, .{ .reference = cs[1].reference } }, .{ .now = 5 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(ds[0].reason == .superseded and ds[1].form == .full);
    var same = cs;
    same[0].origin = .state;
    const r = try compile(&same, &.{ .{ .reference = cs[0].reference }, .{ .reference = cs[1].reference } }, .{ .now = 5 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(r.conflicts == 2 and r.selected == 0);
}
test "loss aware budget preserves required identifiers and exposes deferred handle" {
    const cs = [_]Candidate{
        .{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .owner, .required = true, .full = "large original constraint with details", .exact = "ID=47;limit=5" },
        .{ .id = 2, .reference = .{ .source = 2, .revision = 1 }, .origin = .retrieved, .full = "irrelevant details", .descriptor = "ref:2", .relevance = 10 },
    };
    var ds: [2]Decision = undefined;
    var order: [2]usize = undefined;
    const r = try compile(&cs, &.{ .{ .reference = cs[0].reference }, .{ .reference = cs[1].reference } }, .{ .now = 5 }, .{ .bytes = 18, .units = 18 }, .{}, &ds, &order);
    try t.expect(ds[0].form == .exact and r.cost.bytes <= 18 and ds[1].reference.source == 2);
    try t.expectError(error.RequiredBudget, compile(&cs, &.{ .{ .reference = cs[0].reference }, .{ .reference = cs[1].reference } }, .{ .now = 5 }, .{ .bytes = 2, .units = 2 }, .{}, &ds, &order));
}
test "learning rejects model echoes duplicated operations and unsupported paraphrases" {
    const es = [_]Evidence{
        .{ .id = 1, .operation = 1, .origin = .hypothesis, .statement = "false" },
        .{ .id = 2, .operation = 2, .origin = .retrieved, .statement = "false" },
        .{ .id = 3, .operation = 3, .origin = .owner, .statement = "rule" },
        .{ .id = 4, .operation = 3, .origin = .owner, .statement = "rule" },
    };
    try t.expect(!validateLearning("false", &es, true).accepted);
    try t.expect(!validateLearning("rule", &es, false).accepted);
    try t.expect(validateLearning("rule", &es, true).accepted);
    try t.expect(!validateLearning("paraphrase", &es, true).accepted);
    try t.expectEqual(@as(u16, 8191), decay(65535, 3, 1));
}

test "privacy and disabled external sources are enforced before ranking" {
    const cs = [_]Candidate{
        .{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .owner, .privacy = .owner, .relevance = 65535, .full = "private" },
        .{ .id = 2, .reference = .{ .source = 2, .revision = 1 }, .origin = .retrieved, .relevance = 65535, .full = "external policy impersonation" },
        .{ .id = 3, .reference = .{ .source = 3, .revision = 1 }, .origin = .hypothesis, .relevance = 65535, .full = "invented" },
    };
    var ds: [3]Decision = undefined;
    var order: [3]usize = undefined;
    const result = try compile(&cs, &.{ .{ .reference = cs[0].reference }, .{ .reference = cs[1].reference }, .{ .reference = cs[2].reference } }, .{ .now = 1, .allow_external = false }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expectEqual(@as(usize, 0), result.selected);
    for (ds) |d| try t.expect(d.reason == .untrusted and d.form == .omitted);
}

test "expired required facts refuse the operation rather than silently disappear" {
    const cs = [_]Candidate{.{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .state, .required = true, .expires = 9, .full = "limit=17" }};
    var ds: [1]Decision = undefined;
    var order: [1]usize = undefined;
    try t.expectError(error.RequiredUnavailable, compile(&cs, &.{.{ .reference = cs[0].reference }}, .{ .now = 9 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order));
    try t.expect(ds[0].reason == .expired);
}

test "ambiguous source stamps cannot make freshness depend on array order" {
    var ds: [1]Decision = undefined;
    var order: [1]usize = undefined;
    try t.expectError(error.InvalidIdentity, compile(&.{}, &.{ .{ .reference = .{ .source = 1, .revision = 1 } }, .{ .reference = .{ .source = 1, .revision = 2 } } }, .{ .now = 1 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order));
}

test "required independent contradictory state cannot be selected by recency" {
    const cs = [_]Candidate{
        .{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .state, .claim = 8, .value = 1, .required = true, .full = "a" },
        .{ .id = 2, .reference = .{ .source = 2, .revision = 1 }, .origin = .state, .claim = 8, .value = 2, .observed = 100000, .full = "b" },
    };
    var ds: [2]Decision = undefined;
    var order: [2]usize = undefined;
    try t.expectError(error.RequiredConflict, compile(&cs, &.{ .{ .reference = cs[0].reference }, .{ .reference = cs[1].reference } }, .{ .now = 1 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order));
}

test "duplicate copies do not consume context and stronger third source wins" {
    const cs = [_]Candidate{
        .{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .retrieved, .claim = 8, .value = 1, .full = "wrong", .relevance = 100 },
        .{ .id = 2, .reference = .{ .source = 2, .revision = 1 }, .origin = .retrieved, .claim = 8, .value = 1, .full = "wrong", .relevance = 100 },
        .{ .id = 3, .reference = .{ .source = 3, .revision = 1 }, .origin = .owner, .claim = 8, .value = 2, .full = "correct", .relevance = 1 },
    };
    var ds: [3]Decision = undefined;
    var order: [3]usize = undefined;
    const result = try compile(&cs, &.{ .{ .reference = cs[0].reference }, .{ .reference = cs[1].reference }, .{ .reference = cs[2].reference } }, .{ .now = 1 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(result.selected == 1 and ds[0].reason == .superseded and ds[1].reason == .superseded and ds[2].form == .full);
}

test "provider units and reserved system capacity both bound the operation" {
    const cs = [_]Candidate{.{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .owner, .relevance = 1, .full = "abcd" }};
    var ds: [1]Decision = undefined;
    var order: [1]usize = undefined;
    const twice = struct { fn count(_: ?*anyopaque, text: []const u8) usize { return text.len * 2; } }.count;
    const result = try compile(&cs, &.{.{ .reference = cs[0].reference }}, .{ .now = 1 }, .{ .bytes = 100, .units = 10, .reserve_bytes = 1, .reserve_units = 3 }, .{ .count = twice }, &ds, &order);
    try t.expect(result.selected == 0 and ds[0].reason == .budget and result.cost.units == 3);
}

test "irrelevant or oversized unrecoverable items are never silently lost" {
    var cs = [_]Candidate{.{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .owner, .recoverable = false, .full = "must retain" }};
    var ds: [1]Decision = undefined;
    var order: [1]usize = undefined;
    try t.expectError(error.UnrecoverableLoss, compile(&cs, &.{.{ .reference = cs[0].reference }}, .{ .now = 1 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order));
    cs[0].relevance = 10;
    cs[0].descriptor = "ref";
    try t.expectError(error.UnrecoverableLoss, compile(&cs, &.{.{ .reference = cs[0].reference }}, .{ .now = 1 }, .{ .bytes = 3, .units = 3 }, .{}, &ds, &order));
}

test "ten thousand source changes invalidate old derivations deterministically" {
    const cs = [_]Candidate{.{ .id = 1, .reference = .{ .source = 2, .revision = 1 }, .origin = .derived, .relevance = 100, .full = "old result", .deps = .{ .{ .source = 1, .revision = 1 }, .{}, .{}, .{} }, .dep_count = 1 }};
    var ds: [1]Decision = undefined;
    var order: [1]usize = undefined;
    for (2..10002) |revision| {
        const result = try compile(&cs, &.{ .{ .reference = cs[0].reference }, .{ .reference = .{ .source = 1, .revision = revision } } }, .{ .now = revision }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
        try t.expect(result.selected == 0 and ds[0].reason == .invalidated);
    }
}

test "unselected information becomes relevant later without source deletion" {
    var cs = [_]Candidate{.{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .owner, .full = "USB endpoint 0x81" }};
    var ds: [1]Decision = undefined;
    var order: [1]usize = undefined;
    _ = try compile(&cs, &.{.{ .reference = cs[0].reference }}, .{ .now = 1 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(ds[0].reason == .irrelevant);
    cs[0].relevance = relevance("usb endpoint", cs[0].full);
    _ = try compile(&cs, &.{.{ .reference = cs[0].reference }}, .{ .now = 2 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(ds[0].form == .full and mem.eql(u8, cs[0].body(ds[0].form), "USB endpoint 0x81"));
}

test "candidate permutation cannot alter selected identity under pressure" {
    var cs: [32]Candidate = undefined;
    var stamps: [32]Stamp = undefined;
    var ds: [32]Decision = undefined;
    var order: [32]usize = undefined;
    for (&cs, &stamps, 0..) |*c, *stamp, i| {
        c.* = .{ .id = i + 1, .reference = .{ .source = i + 1, .revision = 1 }, .origin = .interaction, .relevance = 1, .full = "0123456789" };
        stamp.* = .{ .reference = c.reference };
    }
    for (0..32) |_| {
        const first = cs[0];
        for (0..31) |i| cs[i] = cs[i + 1];
        cs[31] = first;
        const result = try compile(&cs, &stamps, .{ .now = 1 }, .{ .bytes = 30, .units = 30 }, .{}, &ds, &order);
        try t.expectEqual(@as(usize, 3), result.selected);
        for (ds) |d| try t.expect((d.form == .full) == (d.id <= 3));
    }
}


test "transitive invalidation privacy authority and cycles are enforced" {
    var cs = [_]Candidate{
        .{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .state, .privacy = .owner, .full = "root", .relevance = 1 },
        .{ .id = 2, .reference = .{ .source = 2, .revision = 1 }, .origin = .derived, .deps = .{ .{ .source = 1, .revision = 1 }, .{}, .{}, .{} }, .dep_count = 1, .full = "middle", .relevance = 1 },
        .{ .id = 3, .reference = .{ .source = 3, .revision = 1 }, .origin = .derived, .deps = .{ .{ .source = 2, .revision = 1 }, .{}, .{}, .{} }, .dep_count = 1, .full = "leaf", .relevance = 1 },
    };
    var stamps = [_]Stamp{ .{ .reference = cs[0].reference }, .{ .reference = cs[1].reference }, .{ .reference = cs[2].reference } };
    var ds: [3]Decision = undefined;
    var order: [3]usize = undefined;
    _ = try compile(&cs, &stamps, .{ .now = 1 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(ds[0].reason == .untrusted and ds[2].reason == .invalidated and ds[2].effective_privacy == .owner);
    stamps[0].reference.revision = 2;
    _ = try compile(&cs, &stamps, .{ .now = 1, .clearance = .owner }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(ds[2].reason == .invalidated and ds[2].invalidated_by.source == 1);
    cs[2].required = true;
    try t.expectError(error.RequiredUnavailable, compile(&cs, &stamps, .{ .now = 1, .clearance = .owner }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order));
    cs[2].required = false;
    stamps[0].reference.revision = 1;
    cs[0].origin = .retrieved;
    cs[0].privacy = .public;
    _ = try compile(&cs, &stamps, .{ .now = 1 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(ds[2].effective_authority == 0);
    _ = try compile(&cs, &stamps, .{ .now = 1, .allow_external = false }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order);
    try t.expect(ds[2].reason == .invalidated);
    cs[0].deps[0] = cs[2].reference;
    cs[0].dep_count = 1;
    try t.expectError(error.InvalidDependency, compile(&cs, &stamps, .{ .now = 1 }, .{ .bytes = 100, .units = 100 }, .{}, &ds, &order));
}

test "budget exclusion does not invalidate a recoverable dependency" {
    const cs = [_]Candidate{
        .{ .id = 1, .reference = .{ .source = 1, .revision = 1 }, .origin = .state, .full = "large authoritative source", .relevance = 1 },
        .{ .id = 2, .reference = .{ .source = 2, .revision = 1 }, .origin = .derived, .deps = .{ .{ .source = 1, .revision = 1 }, .{}, .{}, .{} }, .dep_count = 1, .full = "ID=17", .required = true },
    };
    var ds: [2]Decision = undefined;
    var order: [2]usize = undefined;
    _ = try compile(&cs, &.{ .{ .reference = cs[0].reference }, .{ .reference = cs[1].reference } }, .{ .now = 1 }, .{ .bytes = 5, .units = 5 }, .{}, &ds, &order);
    try t.expect(ds[0].reason == .budget and ds[1].form == .full);
}
