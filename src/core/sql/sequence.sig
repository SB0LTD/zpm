//! Sequences (Layer 0, design §4.11, §4.6): CREATE SEQUENCE option
//! resolution, PostgreSQL's nextval/setval arithmetic with SEQ_LOG_VALS
//! log-ahead, per-session currval/lastval state and a small slot bitset.
//!
//! Sequence values are non-transactional: nextval and setval change the slot
//! at once and are never rolled back. Durability follows PostgreSQL's WAL
//! ordering: a nextval that exhausts log_cnt logs last_value + 32 increments
//! (`logged`), which rides on the current transaction's change record; an
//! aborted transaction's logged value is carried into the next durable
//! append by the Database. CACHE values other than 1 are rejected (0A000).
const types = @import("types.sig");
const Error = types.Error;

/// PostgreSQL SEQ_LOG_VALS.
pub const log_values: i64 = 32;

/// Parsed CREATE SEQUENCE / identity options (null: not given).
pub const Options = struct {
    /// Parser-observed conflicting/redundant options; defer semantic failure
    /// until resolution so an existing conditional target can be skipped.
    duplicate_options: bool = false,
    increment: ?i64 = null,
    min: ?i64 = null,
    max: ?i64 = null,
    no_min: bool = false,
    no_max: bool = false,
    start: ?i64 = null,
    cache: ?i64 = null,
    cycle: bool = false,
    /// AS smallint|integer|bigint (type OID 21/23/20); 0 = bigint.
    type_oid: u32 = 0,
};

/// Resolved sequence parameters.
pub const Spec = struct {
    type_oid: u32 = 20,
    increment: i64 = 1,
    min: i64 = 1,
    max: i64 = 0x7fffffffffffffff,
    start: i64 = 1,
    cycle: bool = false,
};

fn typeBounds(oid: u32) Error![2]i64 {
    return switch (oid) {
        21 => .{ -32768, 32767 },
        23 => .{ -2147483648, 2147483647 },
        0, 20 => .{ -0x7fffffffffffffff - 1, 0x7fffffffffffffff },
        else => error.InvalidParameterValue,
    };
}

/// PostgreSQL init_params: defaults by direction and type, then checks
/// (22023 for a zero increment, MINVALUE >= MAXVALUE, START out of range or
/// a bound outside the type; 0A000 for CACHE other than 1).
pub fn resolve(options: Options) Error!Spec {
    if (options.duplicate_options) return error.Syntax;
    const oid: u32 = if (options.type_oid == 0) 20 else options.type_oid;
    const bounds = try typeBounds(oid);
    var out: Spec = .{ .type_oid = oid, .cycle = options.cycle };
    out.increment = options.increment orelse 1;
    if (out.increment == 0) return error.InvalidParameterValue;
    if (options.cache) |cache| {
        if (cache < 1) return error.InvalidParameterValue;
        if (cache != 1) return error.UnsupportedStatement;
    }
    const ascending = out.increment > 0;
    out.max = if (options.max) |value| value else if (ascending) bounds[1] else -1;
    out.min = if (options.min) |value| value else if (ascending) 1 else bounds[0];
    if (out.max < bounds[0] or out.max > bounds[1]) return error.InvalidParameterValue;
    if (out.min < bounds[0] or out.min > bounds[1]) return error.InvalidParameterValue;
    if (out.min >= out.max) return error.InvalidParameterValue;
    out.start = options.start orelse if (ascending) out.min else out.max;
    if (out.start < out.min or out.start > out.max) return error.InvalidParameterValue;
    return out;
}

pub fn Sequences(comptime config: types.Config) type {
    const V = types.Values(config);
    return struct {
        pub const capacity = config.sequences;

        pub const Seq = struct {
            live: bool = false,
            pending_create: bool = false,
            pending_drop: bool = false,
            /// Transaction slot that created it (while pending_create).
            creator: u16 = 0,
            dead_csn: u64 = 0,
            oid: u32 = 0,
            name: V.Name = .{},
            spec: Spec = .{},
            last_value: i64 = 1,
            is_called: bool = false,
            log_cnt: i64 = 0,
            /// Value and flag a change record carries (newest wins).
            logged_value: i64 = 1,
            logged_called: bool = false,
            /// Identity owner: table OID (0 none) and column index.
            owner: u32 = 0,
            owner_column: u8 = 0,
        };

        pub fn init(seq: *Seq, oid: u32, name: V.Name, spec: Spec, owner: u32, owner_column: u8) void {
            seq.* = .{ .live = true, .oid = oid, .name = name, .spec = spec, .last_value = spec.start, .logged_value = spec.start, .owner = owner, .owner_column = owner_column };
        }

        /// PostgreSQL nextval_internal with CACHE 1: returns the value and
        /// whether a new log-ahead value was recorded (seq.logged_*).
        pub fn next(seq: *Seq) Error!struct { value: i64, logged: bool } {
            var fetch: i64 = 1;
            var log = seq.log_cnt;
            var logit = false;
            if (log < fetch or !seq.is_called) {
                fetch = fetch + log_values;
                log = fetch;
                logit = true;
            }
            var current = seq.last_value;
            var result = current;
            var produced: i64 = 0;
            if (!seq.is_called) {
                produced += 1;
                fetch -= 1;
            }
            const spec = seq.spec;
            while (fetch != 0) {
                var candidate: i64 = undefined;
                if (spec.increment > 0) {
                    if ((spec.max >= 0 and current > spec.max - spec.increment) or (spec.max < 0 and current + spec.increment > spec.max)) {
                        if (produced > 0) break;
                        if (!spec.cycle) return error.SequenceLimit;
                        candidate = spec.min;
                    } else candidate = current + spec.increment;
                } else {
                    if ((spec.min < 0 and current < spec.min - spec.increment) or (spec.min >= 0 and current + spec.increment < spec.min)) {
                        if (produced > 0) break;
                        if (!spec.cycle) return error.SequenceLimit;
                        candidate = spec.max;
                    } else candidate = current + spec.increment;
                }
                current = candidate;
                fetch -= 1;
                if (produced < 1) {
                    produced += 1;
                    result = current;
                }
            }
            log -= produced;
            if (logit) {
                seq.logged_value = current;
                seq.logged_called = true;
            }
            seq.last_value = result;
            seq.is_called = true;
            seq.log_cnt = log;
            return .{ .value = result, .logged = logit };
        }

        /// setval: bounds are checked (22003); always logged.
        pub fn set(seq: *Seq, value: i64, called: bool) Error!void {
            if (value < seq.spec.min or value > seq.spec.max) return error.NumericValueOutOfRange;
            seq.last_value = value;
            seq.is_called = called;
            seq.log_cnt = 0;
            seq.logged_value = value;
            seq.logged_called = called;
        }

        /// Replay of a sequence op.
        pub fn restore(seq: *Seq, value: i64, called: bool) void {
            seq.last_value = value;
            seq.is_called = called;
            seq.log_cnt = 0;
            seq.logged_value = value;
            seq.logged_called = called;
        }

        /// Per-session currval/lastval state (design §4.11).
        pub const Session = struct {
            oids: [capacity]u32 = @splat(0),
            values: [capacity]i64 = @splat(0),
            last: u32 = 0,

            pub fn currval(self: *const Session, oid: u32) ?i64 {
                for (self.oids, self.values) |entry, value| if (entry == oid and oid != 0) return value;
                return null;
            }

            /// Records a nextval; `live` reports whether an OID still exists
            /// (entries of dropped sequences are reused when full).
            pub fn record(self: *Session, oid: u32, value: i64, live: anytype) void {
                self.last = oid;
                var free: ?usize = null;
                for (&self.oids, 0..) |entry, index| {
                    if (entry == oid) {
                        self.values[index] = value;
                        return;
                    }
                    if (free == null and (entry == 0 or !live.has(entry))) free = index;
                }
                const index = free orelse return;
                self.oids[index] = oid;
                self.values[index] = value;
            }
        };

        /// Bitset over sequence slots.
        pub const Set = struct {
            bits: [(capacity + 63) / 64]u64 = @splat(0),

            pub fn add(self: *Set, slot: usize) void {
                self.bits[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
            }
            pub fn remove(self: *Set, slot: usize) void {
                self.bits[slot / 64] &= ~(@as(u64, 1) << @intCast(slot % 64));
            }
            pub fn has(self: *const Set, slot: usize) bool {
                return self.bits[slot / 64] & (@as(u64, 1) << @intCast(slot % 64)) != 0;
            }
            pub fn any(self: *const Set) bool {
                for (self.bits) |word| if (word != 0) return true;
                return false;
            }
            pub fn merge(self: *Set, other: *const Set) void {
                for (&self.bits, other.bits) |*word, more| word.* |= more;
            }
        };
    };
}
