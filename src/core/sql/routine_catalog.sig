//! Routine, trigger and rule catalog objects (Layer 0, conformance lane B11
//! wave 3, docs/SQL_ROUTINES.md).
//!
//! Functions and procedures (pg_proc), triggers (pg_trigger) and rewrite
//! rules (pg_rewrite) are their own fixed-capacity slot arrays
//! (Config.routines, Config.triggers, Config.rules). Every slot is one
//! version of an object with the MVCC stamps of a row version (storage.sig):
//! its creation is visible when it committed at or before the snapshot, or
//! when the snapshot's own transaction created it in an earlier statement;
//! deletion follows the same rule on xmax. CREATE OR REPLACE marks the
//! visible version deleted and writes a new version with the same OID, as
//! ALTER TABLE does with table slots. A slot is reused once its deleting
//! version passed the reclamation horizon (or at once after an abort).
//!
//! Change records (kind 3, change_log.sig) carry each effect as its own op
//! with a length-prefixed payload: 60 create_routine, 61 drop_routine,
//! 62 create_trigger, 63 drop_trigger, 64 create_rule, 65 drop_rule (66-69
//! stay reserved). Payloads (little endian, `name` = len u8 + bytes, `text` =
//! len u16 + bytes):
//!   60: oid u32, namespace u32, name, kind u8 ('f' function, 'p' procedure),
//!       language u8 (0 sql, 1 plpgsql), volatility u8 ('i', 's', 'v'),
//!       strict u8, arg_count u8, per argument: name, type OID u32, typmod
//!       i32; return type OID u32 (2278 void, 2279 trigger), return typmod
//!       i32, body text.
//!   62: oid u32, name, table OID u32, function OID u32, tgtype u8
//!       (PostgreSQL's bits: 1 ROW, 2 BEFORE, 4 INSERT, 8 DELETE, 16 UPDATE,
//!       32 TRUNCATE, 64 INSTEAD), column_count u8 + column indexes u8
//!       (UPDATE OF), WHEN text, nargs u8, arguments text (NUL-terminated
//!       strings).
//!   64: oid u32, name, table OID u32, event u8 ('2' UPDATE, '3' INSERT,
//!       '4' DELETE), instead u8, WHERE text (empty: unconditional).
//!   61 / 63 / 65: oid u32.
//! Decoders validate every byte (bounded lengths, known type OIDs, flags,
//! no trailing bytes) and never recurse.
const types = @import("types.sig");
const storage = @import("storage.sig");
const Error = types.Error;

pub const void_oid: u32 = 2278;
pub const trigger_oid: u32 = 2279;

/// PostgreSQL pg_trigger.tgtype bits.
pub const tg_row: u8 = 1;
pub const tg_before: u8 = 2;
pub const tg_insert: u8 = 4;
pub const tg_delete: u8 = 8;
pub const tg_update: u8 = 16;
pub const tg_truncate: u8 = 32;
pub const tg_instead: u8 = 64;

/// Object class of a write-set entry (Mvcc.Write.new) and of an overlay slot.
pub const Class = enum(u8) { routine = 0, trigger = 1, rule = 2 };

pub const Op = enum(u8) { create_routine = 60, drop_routine = 61, create_trigger = 62, drop_trigger = 63, create_rule = 64, drop_rule = 65 };

/// The MVCC stamps of one object version (the storage.Version rules).
pub const Stamp = struct {
    xmin: storage.TxRef = .{},
    xmin_cid: u32 = 0,
    xmin_csn: u64 = 0,
    xmax: storage.TxRef = .{},
    xmax_cid: u32 = 0,
    xmax_csn: u64 = 0,

    pub fn created(self: *const Stamp, snap: storage.Snapshot) bool {
        if (self.xmin_csn != 0) return self.xmin_csn <= snap.csn;
        return snap.own(self.xmin) and self.xmin_cid < snap.cid;
    }

    pub fn deleted(self: *const Stamp, snap: storage.Snapshot) bool {
        if (self.xmax.epoch == 0) return false;
        if (self.xmax_csn != 0) return self.xmax_csn <= snap.csn;
        return snap.own(self.xmax) and self.xmax_cid < snap.cid;
    }

    pub fn visible(self: *const Stamp, snap: storage.Snapshot) bool {
        return self.created(snap) and !self.deleted(snap);
    }

    /// Committed and not deleted by a committed transaction.
    pub fn committedLive(self: *const Stamp) bool {
        return self.xmin_csn != 0 and !(self.xmax.epoch != 0 and self.xmax_csn != 0);
    }

    /// Another live transaction's uncommitted creation of this version.
    pub fn creatorOther(self: *const Stamp, snap: storage.Snapshot) ?u16 {
        if (self.xmin_csn != 0 or snap.own(self.xmin)) return null;
        return self.xmin.slot;
    }

    /// Another live transaction's uncommitted deletion of this version.
    pub fn deleterOther(self: *const Stamp, snap: storage.Snapshot) ?u16 {
        if (self.xmax.epoch == 0 or self.xmax_csn != 0 or snap.own(self.xmax)) return null;
        return self.xmax.slot;
    }
};

/// Little-endian payload reader: every read is bounded (InvalidChangeRecord).
pub const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.bytes.len - self.position) return error.InvalidChangeRecord;
        const out = self.bytes[self.position..][0..count];
        self.position += count;
        return out;
    }

    pub fn int(self: *Reader, comptime T: type) Error!T {
        const raw = try self.take(@sizeOf(T));
        var bits: u64 = 0;
        for (raw, 0..) |byte, index| bits |= @as(u64, byte) << @intCast(index * 8);
        return switch (T) {
            u8 => @truncate(bits),
            u16 => @truncate(bits),
            u32 => @truncate(bits),
            i32 => @bitCast(@as(u32, @truncate(bits))),
            else => @compileError("unsupported routine payload integer"),
        };
    }

    pub fn finished(self: *const Reader) bool {
        return self.position == self.bytes.len;
    }
};

pub fn Catalog(comptime config: types.Config) type {
    if (config.routines > 255 or config.triggers > 255 or config.rules > 255) @compileError("routine capacities must fit write-set slots");
    if (config.routine_args > 255 or config.routine_bytes > 0xffff) @compileError("routine capacities must fit change records");
    const V = types.Values(config);
    return struct {
        pub const Name = V.Name;
        pub const arg_bytes: usize = @max(config.routine_bytes / 4, 16);
        /// Largest object payload (a routine with every argument named).
        pub const payload_bytes: usize = config.routine_bytes + arg_bytes + config.routine_args * (config.name_bytes + 10) + config.columns + 2 * config.name_bytes + 64;

        /// Inline object text (bodies, WHEN conditions, rule qualifications).
        pub const Text = struct {
            bytes: [config.routine_bytes]u8 = @splat(0),
            len: usize = 0,

            pub fn slice(self: *const Text) []const u8 {
                return self.bytes[0..self.len];
            }

            pub fn set(self: *Text, value: []const u8) Error!void {
                if (value.len > config.routine_bytes) return error.TextCapacity;
                @memcpy(self.bytes[0..value.len], value);
                self.len = value.len;
            }
        };

        pub const Routine = struct {
            live: bool = false,
            stamp: Stamp = .{},
            oid: u32 = 0,
            namespace: u32 = 2200,
            name: Name = .{},
            /// 'f' function, 'p' procedure (pg_proc.prokind).
            kind: u8 = 'f',
            /// 0 SQL, 1 PL/pgSQL.
            language: u8 = 0,
            /// pg_proc.provolatile: 'i', 's' or 'v'.
            volatility: u8 = 'v',
            strict: bool = false,
            arg_count: usize = 0,
            arg_names: [config.routine_args]Name = @splat(.{}),
            arg_oids: [config.routine_args]u32 = @splat(0),
            arg_typmods: [config.routine_args]i32 = @splat(-1),
            /// 2278 void, 2279 trigger, else a type OID.
            return_oid: u32 = void_oid,
            return_typmod: i32 = -1,
            body: Text = .{},

            pub fn args(self: *const Routine) []const u32 {
                return self.arg_oids[0..self.arg_count];
            }
        };

        pub const Trigger = struct {
            live: bool = false,
            stamp: Stamp = .{},
            oid: u32 = 0,
            name: Name = .{},
            table_oid: u32 = 0,
            function_oid: u32 = 0,
            tgtype: u8 = 0,
            /// UPDATE OF column indexes (empty: every UPDATE).
            column_count: usize = 0,
            columns: [config.columns]u8 = @splat(0),
            when: Text = .{},
            nargs: usize = 0,
            /// NUL-terminated argument strings.
            args: [arg_bytes]u8 = @splat(0),
            args_len: usize = 0,

            pub fn argument(self: *const Trigger, index: usize) []const u8 {
                var start: usize = 0;
                var seen: usize = 0;
                for (self.args[0..self.args_len], 0..) |byte, at| {
                    if (byte != 0) continue;
                    if (seen == index) return self.args[start..at];
                    seen += 1;
                    start = at + 1;
                }
                return "";
            }
        };

        pub const Rule = struct {
            live: bool = false,
            stamp: Stamp = .{},
            oid: u32 = 0,
            name: Name = .{},
            table_oid: u32 = 0,
            /// pg_rewrite.ev_type: '2' UPDATE, '3' INSERT, '4' DELETE.
            event: u8 = '4',
            instead: bool = true,
            /// WHERE qualification text (empty: unconditional). The action
            /// is always NOTHING in this subset.
            where: Text = .{},
        };

        /// Every object slot of a database.
        pub const Set = struct {
            routines: [config.routines]Routine = @splat(.{}),
            triggers: [config.triggers]Trigger = @splat(.{}),
            rules: [config.rules]Rule = @splat(.{}),

            pub fn visibleRoutine(self: *const Set, index: usize, snap: storage.Snapshot) bool {
                const item = &self.routines[index];
                return item.live and item.stamp.visible(snap);
            }

            /// The visible routine with this name and exact argument types.
            pub fn findRoutine(self: *const Set, namespace: u32, name: []const u8, args: []const u32, snap: storage.Snapshot) ?usize {
                for (&self.routines, 0..) |*item, index| {
                    if (!item.live or item.namespace != namespace or !item.stamp.visible(snap)) continue;
                    if (!types.same(item.name.slice(), name) or !sameArgs(item.args(), args)) continue;
                    return index;
                }
                return null;
            }

            /// Another live transaction creating or dropping a routine with
            /// this signature (CREATE waits for it, as for a unique key).
            pub fn routineWriter(self: *const Set, namespace: u32, name: []const u8, args: []const u32, snap: storage.Snapshot) ?u16 {
                for (&self.routines) |*item| {
                    if (!item.live or item.namespace != namespace or !types.same(item.name.slice(), name) or !sameArgs(item.args(), args)) continue;
                    if (item.stamp.creatorOther(snap)) |other| if (item.stamp.xmax.epoch == 0) return other;
                    if (item.stamp.created(snap)) if (item.stamp.deleterOther(snap)) |other| return other;
                }
                return null;
            }

            pub fn routineByOid(self: *const Set, oid: u32, snap: storage.Snapshot) ?usize {
                for (&self.routines, 0..) |*item, index| {
                    if (item.live and item.oid == oid and item.stamp.visible(snap)) return index;
                }
                return null;
            }

            /// Visible triggers of a table, in name order (PostgreSQL fires
            /// triggers of the same kind alphabetically).
            pub fn tableTriggers(self: *const Set, table_oid: u32, snap: storage.Snapshot, out: *[config.triggers]u8) usize {
                var count: usize = 0;
                for (&self.triggers, 0..) |*item, index| {
                    if (!item.live or item.table_oid != table_oid or !item.stamp.visible(snap)) continue;
                    var at = count;
                    while (at > 0 and types.bytesOrder(self.triggers[out[at - 1]].name.slice(), item.name.slice()) > 0) : (at -= 1) out[at] = out[at - 1];
                    out[at] = @intCast(index);
                    count += 1;
                }
                return count;
            }

            pub fn findTrigger(self: *const Set, table_oid: u32, name: []const u8, snap: storage.Snapshot) ?usize {
                for (&self.triggers, 0..) |*item, index| {
                    if (item.live and item.table_oid == table_oid and item.stamp.visible(snap) and types.same(item.name.slice(), name)) return index;
                }
                return null;
            }

            pub fn triggerWriter(self: *const Set, table_oid: u32, name: []const u8, snap: storage.Snapshot) ?u16 {
                for (&self.triggers) |*item| {
                    if (!item.live or item.table_oid != table_oid or !types.same(item.name.slice(), name)) continue;
                    if (item.stamp.creatorOther(snap)) |other| if (item.stamp.xmax.epoch == 0) return other;
                    if (item.stamp.created(snap)) if (item.stamp.deleterOther(snap)) |other| return other;
                }
                return null;
            }

            pub fn findRule(self: *const Set, table_oid: u32, name: []const u8, snap: storage.Snapshot) ?usize {
                for (&self.rules, 0..) |*item, index| {
                    if (item.live and item.table_oid == table_oid and item.stamp.visible(snap) and types.same(item.name.slice(), name)) return index;
                }
                return null;
            }

            pub fn ruleWriter(self: *const Set, table_oid: u32, name: []const u8, snap: storage.Snapshot) ?u16 {
                for (&self.rules) |*item| {
                    if (!item.live or item.table_oid != table_oid or !types.same(item.name.slice(), name)) continue;
                    if (item.stamp.creatorOther(snap)) |other| if (item.stamp.xmax.epoch == 0) return other;
                    if (item.stamp.created(snap)) if (item.stamp.deleterOther(snap)) |other| return other;
                }
                return null;
            }

            /// Visible rules of a table for one event, in name order.
            pub fn tableRules(self: *const Set, table_oid: u32, event: u8, snap: storage.Snapshot, out: *[config.rules]u8) usize {
                var count: usize = 0;
                for (&self.rules, 0..) |*item, index| {
                    if (!item.live or item.table_oid != table_oid or item.event != event or !item.stamp.visible(snap)) continue;
                    var at = count;
                    while (at > 0 and types.bytesOrder(self.rules[out[at - 1]].name.slice(), item.name.slice()) > 0) : (at -= 1) out[at] = out[at - 1];
                    out[at] = @intCast(index);
                    count += 1;
                }
                return count;
            }

            /// Any visible or pending object version that names `oid` as
            /// its table or function (dependency checks).
            pub fn stampOf(self: *Set, class: Class, index: usize) *Stamp {
                return switch (class) {
                    .routine => &self.routines[index].stamp,
                    .trigger => &self.triggers[index].stamp,
                    .rule => &self.rules[index].stamp,
                };
            }

            pub fn liveOf(self: *Set, class: Class, index: usize) *bool {
                return switch (class) {
                    .routine => &self.routines[index].live,
                    .trigger => &self.triggers[index].live,
                    .rule => &self.rules[index].live,
                };
            }

            pub fn oidOf(self: *const Set, class: Class, index: usize) u32 {
                return switch (class) {
                    .routine => self.routines[index].oid,
                    .trigger => self.triggers[index].oid,
                    .rule => self.rules[index].oid,
                };
            }

            /// Frees every slot whose deletion passed the horizon.
            pub fn reclaim(self: *Set, horizon: u64) bool {
                var freed = false;
                inline for (.{ "routines", "triggers", "rules" }) |field| {
                    for (&@field(self, field)) |*item| {
                        if (item.live and item.stamp.xmax.epoch != 0 and item.stamp.xmax_csn != 0 and item.stamp.xmax_csn <= horizon) {
                            item.live = false;
                            freed = true;
                        }
                    }
                }
                return freed;
            }

            /// Uncommitted object versions or marks (leak accounting).
            pub fn pending(self: *const Set) usize {
                var count: usize = 0;
                inline for (.{ "routines", "triggers", "rules" }) |field| {
                    for (&@field(self, field)) |*item| {
                        if (!item.live) continue;
                        if (item.stamp.xmin_csn == 0) count += 1;
                        if (item.stamp.xmax.epoch != 0 and item.stamp.xmax_csn == 0) count += 1;
                    }
                }
                return count;
            }
        };

        pub fn sameArgs(a: []const u32, b: []const u32) bool {
            if (a.len != b.len) return false;
            for (a, b) |left, right| if (left != right) return false;
            return true;
        }

        // ---- change records ---------------------------------------------

        /// Bounded little-endian payload writer over a caller buffer.
        pub const Payload = struct {
            buffer: []u8,
            used: usize = 0,

            fn reserve(self: *Payload, count: usize) Error![]u8 {
                if (count > self.buffer.len - self.used) return error.TransactionLogCapacity;
                const out = self.buffer[self.used..][0..count];
                self.used += count;
                return out;
            }

            pub fn int(self: *Payload, comptime T: type, value: T) Error!void {
                const Bits = switch (T) {
                    u8 => u8,
                    u16 => u16,
                    u32, i32 => u32,
                    else => @compileError("unsupported routine payload integer"),
                };
                const bits: Bits = @bitCast(value);
                const out = try self.reserve(@sizeOf(T));
                for (0..@sizeOf(T)) |index| out[index] = @truncate(bits >> @intCast(index * 8));
            }

            pub fn bytes(self: *Payload, value: []const u8) Error!void {
                @memcpy(try self.reserve(value.len), value);
            }

            pub fn name(self: *Payload, value: []const u8) Error!void {
                try self.int(u8, @intCast(value.len));
                try self.bytes(value);
            }

            pub fn text(self: *Payload, value: []const u8) Error!void {
                try self.int(u16, @intCast(value.len));
                try self.bytes(value);
            }
        };

        pub fn encodeRoutine(out: *Payload, item: *const Routine) Error!void {
            try out.int(u32, item.oid);
            try out.int(u32, item.namespace);
            try out.name(item.name.slice());
            try out.int(u8, item.kind);
            try out.int(u8, item.language);
            try out.int(u8, item.volatility);
            try out.int(u8, @intFromBool(item.strict));
            try out.int(u8, @intCast(item.arg_count));
            for (0..item.arg_count) |index| {
                try out.name(item.arg_names[index].slice());
                try out.int(u32, item.arg_oids[index]);
                try out.int(i32, item.arg_typmods[index]);
            }
            try out.int(u32, item.return_oid);
            try out.int(i32, item.return_typmod);
            try out.text(item.body.slice());
        }

        pub fn encodeTrigger(out: *Payload, item: *const Trigger) Error!void {
            try out.int(u32, item.oid);
            try out.name(item.name.slice());
            try out.int(u32, item.table_oid);
            try out.int(u32, item.function_oid);
            try out.int(u8, item.tgtype);
            try out.int(u8, @intCast(item.column_count));
            try out.bytes(item.columns[0..item.column_count]);
            try out.text(item.when.slice());
            try out.int(u8, @intCast(item.nargs));
            try out.text(item.args[0..item.args_len]);
        }

        pub fn encodeRule(out: *Payload, item: *const Rule) Error!void {
            try out.int(u32, item.oid);
            try out.name(item.name.slice());
            try out.int(u32, item.table_oid);
            try out.int(u8, item.event);
            try out.int(u8, @intFromBool(item.instead));
            try out.text(item.where.slice());
        }

        fn readName(reader: *Reader, out: *Name) Error!void {
            const len = try reader.int(u8);
            const raw = try reader.take(len);
            if (raw.len == 0 or raw.len > config.name_bytes) return error.InvalidChangeRecord;
            for (raw) |byte| if (byte == 0) return error.InvalidChangeRecord;
            out.* = .{ .len = raw.len };
            @memcpy(out.bytes[0..raw.len], raw);
        }

        fn readText(reader: *Reader, out: []u8) Error!usize {
            const len = try reader.int(u16);
            if (len > out.len) return error.InvalidChangeRecord;
            @memcpy(out[0..len], try reader.take(len));
            return len;
        }

        fn knownType(oid: u32) bool {
            return types.typeFromOid(oid) != null;
        }

        pub fn decodeRoutine(payload: []const u8, out: *Routine) Error!void {
            var reader = Reader{ .bytes = payload };
            out.* = .{};
            out.oid = try reader.int(u32);
            out.namespace = try reader.int(u32);
            try readName(&reader, &out.name);
            out.kind = try reader.int(u8);
            out.language = try reader.int(u8);
            out.volatility = try reader.int(u8);
            const strict = try reader.int(u8);
            const count = try reader.int(u8);
            if ((out.kind != 'f' and out.kind != 'p') or out.language > 1 or strict > 1 or count > config.routine_args) return error.InvalidChangeRecord;
            if (out.volatility != 'i' and out.volatility != 's' and out.volatility != 'v') return error.InvalidChangeRecord;
            out.strict = strict == 1;
            out.arg_count = count;
            for (0..count) |index| {
                // Unnamed arguments (`f(INT)`) have an empty name.
                if (reader.position < payload.len and payload[reader.position] == 0) {
                    reader.position += 1;
                    out.arg_names[index] = .{};
                } else try readName(&reader, &out.arg_names[index]);
                out.arg_oids[index] = try reader.int(u32);
                out.arg_typmods[index] = try reader.int(i32);
                if (!knownType(out.arg_oids[index])) return error.InvalidChangeRecord;
            }
            out.return_oid = try reader.int(u32);
            out.return_typmod = try reader.int(i32);
            if (out.return_oid != void_oid and out.return_oid != trigger_oid and !knownType(out.return_oid)) return error.InvalidChangeRecord;
            if (out.kind == 'p' and out.return_oid != void_oid) return error.InvalidChangeRecord;
            out.body.len = try readText(&reader, &out.body.bytes);
            if (!reader.finished()) return error.InvalidChangeRecord;
        }

        pub fn decodeTrigger(payload: []const u8, out: *Trigger) Error!void {
            var reader = Reader{ .bytes = payload };
            out.* = .{};
            out.oid = try reader.int(u32);
            try readName(&reader, &out.name);
            out.table_oid = try reader.int(u32);
            out.function_oid = try reader.int(u32);
            out.tgtype = try reader.int(u8);
            if (out.tgtype & 0x80 != 0 or out.tgtype & (tg_insert | tg_delete | tg_update | tg_truncate) == 0) return error.InvalidChangeRecord;
            const count = try reader.int(u8);
            if (count > config.columns) return error.InvalidChangeRecord;
            out.column_count = count;
            for (0..count) |index| {
                out.columns[index] = try reader.int(u8);
                if (out.columns[index] >= config.columns) return error.InvalidChangeRecord;
            }
            out.when.len = try readText(&reader, &out.when.bytes);
            out.nargs = try reader.int(u8);
            out.args_len = try readText(&reader, &out.args);
            var terminators: usize = 0;
            for (out.args[0..out.args_len]) |byte| {
                if (byte == 0) terminators += 1;
            }
            if (terminators != out.nargs or (out.args_len != 0 and out.args[out.args_len - 1] != 0)) return error.InvalidChangeRecord;
            if (!reader.finished()) return error.InvalidChangeRecord;
        }

        pub fn decodeRule(payload: []const u8, out: *Rule) Error!void {
            var reader = Reader{ .bytes = payload };
            out.* = .{};
            out.oid = try reader.int(u32);
            try readName(&reader, &out.name);
            out.table_oid = try reader.int(u32);
            out.event = try reader.int(u8);
            const instead = try reader.int(u8);
            if (out.event < '2' or out.event > '4' or instead > 1) return error.InvalidChangeRecord;
            out.instead = instead == 1;
            out.where.len = try readText(&reader, &out.where.bytes);
            if (!reader.finished()) return error.InvalidChangeRecord;
        }

        pub fn decodeOid(payload: []const u8) Error!u32 {
            var reader = Reader{ .bytes = payload };
            const oid = try reader.int(u32);
            if (!reader.finished()) return error.InvalidChangeRecord;
            return oid;
        }

        // ---- replay validation overlay ------------------------------------

        pub const object_capacity = config.routines + config.triggers + config.rules;

        const VObject = struct {
            live: bool = false,
            class: Class = .routine,
            oid: u32 = 0,
            namespace: u32 = 0,
            /// Trigger / rule table OID.
            table_oid: u32 = 0,
            /// Trigger function OID.
            function_oid: u32 = 0,
            kind: u8 = 'f',
            return_oid: u32 = 0,
            name: Name = .{},
            arg_count: usize = 0,
            arg_oids: [config.routine_args]u32 = @splat(0),
        };

        /// Caller-owned overlay of the committed objects while a record is
        /// validated (part of ChangeLog.Scratch).
        pub const Overlay = struct {
            objects: [object_capacity]VObject = @splat(.{}),
            counts: [3]usize = @splat(0),
        };

        fn capacityOf(class: Class) usize {
            return switch (class) {
                .routine => config.routines,
                .trigger => config.triggers,
                .rule => config.rules,
            };
        }

        /// Loads the committed objects of `set` into the overlay.
        pub fn beginOverlay(overlay: *Overlay, set: *const Set) void {
            overlay.* = .{};
            var at: usize = 0;
            for (&set.routines) |*item| {
                if (!item.live or !item.stamp.committedLive()) continue;
                overlay.objects[at] = .{ .live = true, .class = .routine, .oid = item.oid, .namespace = item.namespace, .kind = item.kind, .return_oid = item.return_oid, .name = item.name, .arg_count = item.arg_count, .arg_oids = item.arg_oids };
                overlay.counts[0] += 1;
                at += 1;
            }
            for (&set.triggers) |*item| {
                if (!item.live or !item.stamp.committedLive()) continue;
                overlay.objects[at] = .{ .live = true, .class = .trigger, .oid = item.oid, .table_oid = item.table_oid, .function_oid = item.function_oid, .name = item.name };
                overlay.counts[1] += 1;
                at += 1;
            }
            for (&set.rules) |*item| {
                if (!item.live or !item.stamp.committedLive()) continue;
                overlay.objects[at] = .{ .live = true, .class = .rule, .oid = item.oid, .table_oid = item.table_oid, .name = item.name };
                overlay.counts[2] += 1;
                at += 1;
            }
        }

        pub fn overlayHas(overlay: *const Overlay, oid: u32) bool {
            for (&overlay.objects) |*object| if (object.live and object.oid == oid) return true;
            return false;
        }

        fn overlayFind(overlay: *Overlay, class: Class, oid: u32) ?*VObject {
            for (&overlay.objects) |*object| if (object.live and object.class == class and object.oid == oid) return object;
            return null;
        }

        fn overlayAdd(overlay: *Overlay, object: VObject) Error!void {
            const class_index = @intFromEnum(object.class);
            if (overlay.counts[class_index] >= capacityOf(object.class)) return error.ChangeRecordConflict;
            for (&overlay.objects) |*slot| if (!slot.live) {
                slot.* = object;
                overlay.counts[class_index] += 1;
                return;
            };
            return error.ChangeRecordConflict;
        }

        /// Validates one object op against the overlay. `oidTaken(oid)`
        /// reports OIDs that tables, indexes, sequences or schemas hold and
        /// `tableLive(oid)` whether a relation exists at this point of the
        /// record. Returns the created OID (the caller keeps the maximum).
        pub fn validateOp(overlay: *Overlay, tag: u8, payload: []const u8, context: anytype) Error!?u32 {
            switch (tag) {
                @intFromEnum(Op.create_routine) => {
                    var item: Routine = undefined;
                    try decodeRoutine(payload, &item);
                    if (item.oid < 16384 or item.oid == 0xffffffff or overlayHas(overlay, item.oid) or context.oidTaken(item.oid)) return error.ChangeRecordConflict;
                    if (!context.namespaceKnown(item.namespace)) return error.ChangeRecordConflict;
                    for (&overlay.objects) |*object| {
                        if (object.live and object.class == .routine and object.namespace == item.namespace and types.same(object.name.slice(), item.name.slice()) and
                            sameArgs(object.arg_oids[0..object.arg_count], item.args())) return error.ChangeRecordConflict;
                    }
                    try overlayAdd(overlay, .{ .live = true, .class = .routine, .oid = item.oid, .namespace = item.namespace, .kind = item.kind, .return_oid = item.return_oid, .name = item.name, .arg_count = item.arg_count, .arg_oids = item.arg_oids });
                    return item.oid;
                },
                @intFromEnum(Op.create_trigger) => {
                    var item: Trigger = undefined;
                    try decodeTrigger(payload, &item);
                    if (item.oid < 16384 or item.oid == 0xffffffff or overlayHas(overlay, item.oid) or context.oidTaken(item.oid)) return error.ChangeRecordConflict;
                    if (!context.tableLive(item.table_oid)) return error.ChangeRecordConflict;
                    const function = overlayFind(overlay, .routine, item.function_oid) orelse return error.ChangeRecordConflict;
                    if (function.return_oid != trigger_oid or function.arg_count != 0) return error.ChangeRecordConflict;
                    for (&overlay.objects) |*object| {
                        if (object.live and object.class == .trigger and object.table_oid == item.table_oid and types.same(object.name.slice(), item.name.slice())) return error.ChangeRecordConflict;
                    }
                    try overlayAdd(overlay, .{ .live = true, .class = .trigger, .oid = item.oid, .table_oid = item.table_oid, .function_oid = item.function_oid, .name = item.name });
                    return item.oid;
                },
                @intFromEnum(Op.create_rule) => {
                    var item: Rule = undefined;
                    try decodeRule(payload, &item);
                    if (item.oid < 16384 or item.oid == 0xffffffff or overlayHas(overlay, item.oid) or context.oidTaken(item.oid)) return error.ChangeRecordConflict;
                    if (!context.tableLive(item.table_oid)) return error.ChangeRecordConflict;
                    for (&overlay.objects) |*object| {
                        if (object.live and object.class == .rule and object.table_oid == item.table_oid and types.same(object.name.slice(), item.name.slice())) return error.ChangeRecordConflict;
                    }
                    try overlayAdd(overlay, .{ .live = true, .class = .rule, .oid = item.oid, .table_oid = item.table_oid, .name = item.name });
                    return item.oid;
                },
                @intFromEnum(Op.drop_routine), @intFromEnum(Op.drop_trigger), @intFromEnum(Op.drop_rule) => {
                    const class: Class = switch (tag) {
                        @intFromEnum(Op.drop_routine) => .routine,
                        @intFromEnum(Op.drop_trigger) => .trigger,
                        else => .rule,
                    };
                    const object = overlayFind(overlay, class, try decodeOid(payload)) orelse return error.ChangeRecordConflict;
                    if (class == .routine) {
                        // A trigger still using the function must be dropped first.
                        for (&overlay.objects) |*other| if (other.live and other.class == .trigger and other.function_oid == object.oid) return error.ChangeRecordConflict;
                    }
                    object.live = false;
                    overlay.counts[@intFromEnum(class)] -= 1;
                    return null;
                },
                else => return error.UnsupportedLogVersion,
            }
        }

        /// A table dropped by the record takes its triggers and rules along
        /// (replay mirrors the primary's cascade).
        pub fn overlayDropTable(overlay: *Overlay, table_oid: u32) void {
            for (&overlay.objects) |*object| {
                if (!object.live or object.class == .routine or object.table_oid != table_oid) continue;
                object.live = false;
                overlay.counts[@intFromEnum(object.class)] -= 1;
            }
        }
    };
}
