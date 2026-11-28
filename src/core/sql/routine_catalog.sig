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
//!       i32, body text, optional owner OID u32, and optional EXECUTE ACL
//!       (owner/PUBLIC flags u8, count u8, grantee OIDs u32). Extended ACLs
//!       set flag 0x80 and encode (grantee u32, grantor u32, option u8) per
//!       entry; flag 0x04 retains an explicit owner grant option. Legacy
//!       owner-issued records retain their original encoding.
//!   62: oid u32, name, table OID u32, function OID u32, tgtype u8
//!       (PostgreSQL's bits: 1 ROW, 2 BEFORE, 4 INSERT, 8 DELETE, 16 UPDATE,
//!       32 TRUNCATE, 64 INSTEAD), column_count u8 + column indexes u8
//!       (UPDATE OF), WHEN text, nargs u8, arguments text (NUL-terminated
//!       strings).
//!   64: oid u32, name, table OID u32, event u8 ('2' UPDATE, '3' INSERT,
//!       '4' DELETE), instead u8, WHERE text (empty: unconditional).
//!   61 / 63 / 65: oid u32.
//!   120 (B11 wave 5): a trigger with REFERENCING transition tables or a
//!       constraint trigger: flags u8 (1 OLD TABLE, 2 NEW TABLE, 4
//!       constraint, 8 DEFERRABLE, 16 INITIALLY DEFERRED), the OLD TABLE
//!       name and the NEW TABLE name (when flagged), for a constraint
//!       trigger its constraint OID u32 and FROM table OID u32 (0: none),
//!       then the op-62 payload. Other triggers keep op 62 byte for byte.
//!   80 (B11 wave 4): a routine with parameter modes, DEFAULT values,
//!       RETURNS SETOF / TABLE, SECURITY DEFINER or SET clauses:
//!       extension length u16, extension, then the op-60 payload. The
//!       extension: version u8 (1), flags u8 (1 retset, 2 security
//!       definer), parameter count u8 and every parameter's mode u8 in
//!       declaration order ('i', 'o', 'b', 'v', 't'), then per 'o' / 't'
//!       parameter: name (len u8, may be 0), type OID u32, typmod i32;
//!       default count u8, defaults text (NUL-terminated expressions of the
//!       last inputs); setting count u8, settings text (NUL-terminated
//!       `name=value`). Routines without these features keep op 60 and
//!       its bytes unchanged.
//! Decoders validate every byte (bounded lengths, known type OIDs, flags,
//! no trailing bytes) and never recurse.
const std = @import("std");
const types = @import("types.sig");
const value_module = @import("value.sig");
const privilege_graph = @import("privilege_graph.sig");
const execute_privilege = @import("catalog_objects.sig").priv_execute;
const storage = @import("storage.sig");
const Error = types.Error;

pub const void_oid: u32 = 2278;
pub const trigger_oid: u32 = 2279;
/// pg_proc.prorettype of a routine with several OUT parameters.
pub const record_oid: u32 = 2249;
/// The extended creation op (B11 wave 4, routines-sig lane: ops 80-84).
pub const create_routine_extended: u8 = 80;
/// Transition tables and constraint triggers (B11 wave 5, routines-trig
/// lane: ops 120-124).
pub const create_trigger_extended: u8 = 120;
pub const trigger_old_table: u8 = 1;
pub const trigger_new_table: u8 = 2;
pub const trigger_constraint: u8 = 4;
pub const trigger_deferrable: u8 = 8;
pub const trigger_initially_deferred: u8 = 16;

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

pub const Op = enum(u8) { create_routine = 60, drop_routine = 61, create_trigger = 62, drop_trigger = 63, create_rule = 64, drop_rule = 65, create_rule_action = 85, create_trigger_extended = 120 };

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
        pub const payload_bytes: usize = config.routine_bytes + arg_bytes + config.routine_args * (config.name_bytes + 10) + config.columns + 2 * config.name_bytes + 64 + 9 * @as(usize, config.routine_acl_entries) +
            // The op-80 extension (B11 wave 4).
            2 * arg_bytes + config.routine_args * (config.name_bytes + 10) + 16;

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

        pub const ExecuteAcl = struct {
            explicit: bool = false,
            owner: bool = true,
            owner_option: bool = false,
            public: bool = true,
            count: u8 = 0,
            grantees: [config.routine_acl_entries]u32 = @splat(0),
            /// Zero denotes the owner, preserving owner-issued ACL constructors.
            grantors: [config.routine_acl_entries]u32 = @splat(0),
            options: [config.routine_acl_entries]bool = @splat(false),

            pub fn roles(self: *const ExecuteAcl) []const u32 {
                return self.grantees[0..self.count];
            }

            pub fn grantor(self: *const ExecuteAcl, index: usize, owner: u32) u32 {
                return if (self.grantors[index] == 0) owner else self.grantors[index];
            }

            pub fn extended(self: *const ExecuteAcl, owner: u32) bool {
                if (self.owner_option) return true;
                for (0..self.count) |index| {
                    if (self.options[index] or self.grantor(index, owner) != owner) return true;
                }
                return false;
            }

            pub fn graph(self: *const ExecuteAcl, owner: u32, edges: []privilege_graph.Edge) privilege_graph.Graph {
                var result: privilege_graph.Graph = .{ .edges = edges, .owner = owner, .privileges = execute_privilege };
                result.add(.{ .grantor = owner, .grantee = 0, .flags = if (self.public) execute_privilege else 0, .options = 0 });
                result.add(.{ .grantor = owner, .grantee = owner, .flags = if (self.owner) execute_privilege else 0,
                    .options = if (self.owner_option) execute_privilege else 0 });
                for (self.roles(), 0..) |role, index| result.add(.{
                    .grantor = self.grantor(index, owner), .grantee = role, .flags = execute_privilege,
                    .options = if (self.options[index]) execute_privilege else 0,
                });
                return result;
            }

            pub fn assignGraph(self: *ExecuteAcl, grants: privilege_graph.Graph) Error!void {
                self.* = .{ .explicit = true, .owner = false, .public = false };
                for (grants.edges[0..grants.len]) |edge| {
                    if (edge.flags == 0) continue;
                    if (edge.grantor == grants.owner and edge.grantee == grants.owner) {
                        self.owner = true;
                        self.owner_option = edge.options != 0;
                    } else if (edge.grantor == grants.owner and edge.grantee == 0) {
                        self.public = true;
                    } else {
                        if (self.count == self.grantees.len) return error.ProgramLimitExceeded;
                        self.grantees[self.count] = edge.grantee;
                        self.grantors[self.count] = if (edge.grantor == grants.owner) 0 else edge.grantor;
                        self.options[self.count] = edge.options != 0;
                        self.count += 1;
                    }
                }
            }

            pub fn set(self: *ExecuteAcl, role: u32, owner: u32, allow: bool) Error!void {
                self.explicit = true;
                if (role == owner) {
                    self.owner = allow;
                    if (!allow) self.owner_option = false;
                    return;
                }
                if (role == 0) {
                    self.public = allow;
                    return;
                }
                for (self.roles(), 0..) |grantee, index| {
                    if (grantee != role or self.grantor(index, owner) != owner) continue;
                    if (!allow) {
                        const count = self.count - 1;
                        for (index..count) |i| {
                            self.grantees[i] = self.grantees[i + 1];
                            self.grantors[i] = self.grantors[i + 1];
                            self.options[i] = self.options[i + 1];
                        }
                        self.count = count;
                    }
                    return;
                }
                if (!allow) return;
                if (self.count == self.grantees.len) return error.ProgramLimitExceeded;
                self.grantees[self.count] = role;
                self.grantors[self.count] = 0;
                self.options[self.count] = false;
                self.count += 1;
            }
        };

        pub const Routine = struct {
            live: bool = false,
            stamp: Stamp = .{},
            oid: u32 = 0,
            namespace: u32 = 2200,
            owner: u32 = @import("catalog_objects.sig").bootstrap_role,
            acl: ExecuteAcl = .{},
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
            // B11 wave 4 (op 80): parameter modes, defaults, set results,
            // SECURITY DEFINER and SET clauses.
            /// Every declared parameter's mode in declaration order ('i'
            /// IN, 'o' OUT, 'b' INOUT, 'v' VARIADIC, 't' TABLE column);
            /// empty when every parameter is IN.
            param_count: usize = 0,
            param_modes: [config.routine_args]u8 = @splat('i'),
            /// Modes of the inputs (the `arg_*` list): 'i', 'b' or 'v'.
            arg_modes: [config.routine_args]u8 = @splat('i'),
            /// Result columns (OUT, INOUT and TABLE parameters) in
            /// declaration order; an INOUT column's input index in
            /// `out_inputs` (0xff for OUT / TABLE).
            out_count: usize = 0,
            out_names: [config.routine_args]Name = @splat(.{}),
            out_oids: [config.routine_args]u32 = @splat(0),
            out_typmods: [config.routine_args]i32 = @splat(-1),
            out_inputs: [config.routine_args]u8 = @splat(0xff),
            /// pronargdefaults: the last `default_count` inputs have DEFAULT
            /// expressions (their SQL text, NUL-terminated in `defaults`).
            default_count: usize = 0,
            defaults: [arg_bytes]u8 = @splat(0),
            defaults_len: usize = 0,
            /// RETURNS SETOF / TABLE (proretset).
            retset: bool = false,
            security_definer: bool = false,
            /// SET clauses (proconfig): NUL-terminated `name=value` entries.
            setting_count: usize = 0,
            settings: [arg_bytes]u8 = @splat(0),
            settings_len: usize = 0,

            pub fn args(self: *const Routine) []const u32 {
                return self.arg_oids[0..self.arg_count];
            }

            /// Whether the routine needs the extended record (op 80).
            pub fn extended(self: *const Routine) bool {
                return self.param_count != 0 or self.default_count != 0 or self.retset or self.security_definer or self.setting_count != 0 or self.return_oid == record_oid;
            }

            /// The last input is VARIADIC (an array of its element type).
            pub fn variadic(self: *const Routine) bool {
                return self.arg_count != 0 and self.arg_modes[self.arg_count - 1] == 'v';
            }

            /// DEFAULT expression of input `index` (it must have one).
            pub fn defaultText(self: *const Routine, index: usize) []const u8 {
                return nulEntry(self.defaults[0..self.defaults_len], index - (self.arg_count - self.default_count));
            }

            pub fn setting(self: *const Routine, index: usize) []const u8 {
                return nulEntry(self.settings[0..self.settings_len], index);
            }
        };

        /// Entry `index` of NUL-terminated strings.
        pub fn nulEntry(bytes: []const u8, index: usize) []const u8 {
            var start: usize = 0;
            var seen: usize = 0;
            for (bytes, 0..) |byte, at| {
                if (byte != 0) continue;
                if (seen == index) return bytes[start..at];
                seen += 1;
                start = at + 1;
            }
            return "";
        }

        fn nulCount(bytes: []const u8) ?usize {
            var count: usize = 0;
            var start: usize = 0;
            for (bytes, 0..) |byte, at| {
                if (byte != 0) continue;
                if (at == start) return null;
                count += 1;
                start = at + 1;
            }
            if (start != bytes.len) return null;
            return count;
        }

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
            /// B11 wave 5 (op 120): REFERENCING transition table names
            /// (empty: none), constraint trigger flags, its pg_constraint
            /// OID and FROM table (tgconstrrelid, 0: none).
            old_table: Name = .{},
            new_table: Name = .{},
            constraint: bool = false,
            deferrable: bool = false,
            initially_deferred: bool = false,
            constraint_oid: u32 = 0,
            constraint_relid: u32 = 0,

            /// Whether the trigger needs the extended record (op 120).
            pub fn extended(self: *const Trigger) bool {
                return self.old_table.len != 0 or self.new_table.len != 0 or self.constraint;
            }

            pub fn transitions(self: *const Trigger) bool {
                return self.old_table.len != 0 or self.new_table.len != 0;
            }

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
            /// WHERE qualification text (empty: unconditional).
            where: Text = .{},
            /// Action statements (B11 wave 4, op 85): empty for NOTHING;
            /// `multiple` when written in parentheses.
            action: Text = .{},
            multiple: bool = false,
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

        // ---- call matching (B11 wave 4) ------------------------------------

        /// One argument of a call: its name in named notation (else
        /// empty), its type and whether it is an untyped literal or NULL.
        pub const Supplied = struct { name: Name = .{}, ty: types.Type = .unknown, unknown: bool = false };

        pub const default_slot: u8 = 0xff;
        pub const expanded_slot: u8 = 0xfe;

        /// How a call fills a routine's parameters: per parameter of the
        /// call view (callParam) the supplied argument, `default_slot` or
        /// `expanded_slot` (supplied[expand_from..] are the elements of the
        /// VARIADIC parameter); `exact` scores the type match.
        pub const Match = struct {
            slots: [config.routine_args]u8 = @splat(default_slot),
            count: usize = 0,
            expand_from: usize = 0,
            expanded: bool = false,
            exact: usize = 0,
        };

        pub const Param = struct { name: Name = .{}, oid: u32 = 0, typmod: i32 = -1, mode: u8 = 'i', default: bool = false, input: u8 = default_slot };

        /// The parameters a call fills: the inputs, or for CALL every
        /// IN, INOUT, VARIADIC and OUT parameter in declaration order (an
        /// OUT one takes a placeholder argument, as in PostgreSQL 14+).
        pub fn callParams(item: *const Routine, with_outputs: bool, out: *[config.routine_args]Param) usize {
            const first_default = item.arg_count - item.default_count;
            if (!with_outputs or item.param_count == 0) {
                for (0..item.arg_count) |index| out[index] = .{ .name = item.arg_names[index], .oid = item.arg_oids[index], .typmod = item.arg_typmods[index], .mode = item.arg_modes[index], .default = index >= first_default, .input = @intCast(index) };
                return item.arg_count;
            }
            var count: usize = 0;
            var input: usize = 0;
            var output: usize = 0;
            for (item.param_modes[0..item.param_count]) |mode| {
                switch (mode) {
                    'i', 'b', 'v' => {
                        out[count] = .{ .name = item.arg_names[input], .oid = item.arg_oids[input], .typmod = item.arg_typmods[input], .mode = mode, .default = input >= first_default, .input = @intCast(input) };
                        input += 1;
                        count += 1;
                        if (mode == 'b') output += 1;
                    },
                    'o' => {
                        out[count] = .{ .name = item.out_names[output], .oid = item.out_oids[output], .typmod = item.out_typmods[output], .mode = mode };
                        output += 1;
                        count += 1;
                    },
                    else => output += 1,
                }
            }
            return count;
        }

        /// PostgreSQL's argument matching (func_get_detail, simplified like
        /// the wave-3 resolution): positional arguments first, then named
        /// ones; a VARIADIC parameter takes the trailing positional
        /// arguments as elements unless the call says VARIADIC (named
        /// notation reaches it only with VARIADIC); unfilled parameters need
        /// DEFAULTs. An exact type counts 2, an untyped literal 1 for text;
        /// anything else needs an implicit cast. Null: not a candidate.
        pub fn matchCall(params: []const Param, supplied: []const Supplied, variadic_call: bool, out: *Match) bool {
            out.* = .{ .count = params.len };
            var positional: usize = 0;
            while (positional < supplied.len and supplied[positional].name.len == 0) positional += 1;
            const last = params.len -% 1;
            const variadic = params.len != 0 and params[last].mode == 'v';
            if (variadic_call and !variadic) return false;
            // Named notation reaches a variadic routine only with VARIADIC.
            if (variadic and !variadic_call and positional != supplied.len) return false;
            // Variadic expansion: positional arguments from the VARIADIC
            // parameter's position on (at least one) are its elements.
            const expand = variadic and !variadic_call and positional > last;
            if (expand and positional != supplied.len) return false;
            const direct = if (expand) last else positional;
            if (direct > params.len) return false;
            for (0..direct) |index| out.slots[index] = @intCast(index);
            if (expand) {
                out.slots[last] = expanded_slot;
                out.expand_from = last;
                out.expanded = true;
            }
            for (supplied[positional..], positional..) |arg, index| {
                if (arg.name.len == 0) return false;
                var found: ?usize = null;
                for (params, 0..) |param, position| {
                    if (param.name.len != 0 and types.same(param.name.slice(), arg.name.slice())) found = position;
                }
                const position = found orelse return false;
                if (out.slots[position] != default_slot) return false;
                if (params[position].mode == 'v' and !variadic_call) return false;
                out.slots[position] = @intCast(index);
            }
            for (params, 0..) |param, position| {
                if (out.slots[position] == default_slot and !param.default) return false;
            }
            // Types.
            for (params, 0..) |param, position| {
                const slot = out.slots[position];
                if (slot == default_slot) continue;
                const data = types.typeFromOid(param.oid) orelse return false;
                const declared = types.typeOfData(data);
                if (slot == expanded_slot) {
                    const element = types.elementType(declared) orelse return false;
                    for (supplied[out.expand_from..]) |arg| if (!accepts(arg, element, &out.exact)) return false;
                } else if (!accepts(supplied[slot], declared, &out.exact)) return false;
            }
            return true;
        }

        /// More exact matches win; at a tie PostgreSQL prefers a candidate
        /// that needs no variadic expansion (else the call is ambiguous).
        pub fn betterMatch(a: *const Match, b: *const Match) bool {
            return a.exact > b.exact or (a.exact == b.exact and !a.expanded and b.expanded);
        }

        fn accepts(arg: Supplied, to: types.Type, exact: *usize) bool {
            if (arg.unknown or arg.ty == .unknown) {
                if (to == .text) exact.* += 1;
                return true;
            }
            if (arg.ty == to) {
                exact.* += 2;
                return true;
            }
            return value_module.castable(arg.ty, to, .implicit);
        }

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
            // Older routine records end after the body and imply the bootstrap owner.
            if (item.owner != @import("catalog_objects.sig").bootstrap_role or item.acl.explicit) try out.int(u32, item.owner);
            if (item.acl.explicit) {
                const extended = item.acl.extended(item.owner);
                const flags = @as(u8, @intFromBool(item.acl.owner)) | (@as(u8, @intFromBool(item.acl.public)) << 1) |
                    (@as(u8, @intFromBool(item.acl.owner_option)) << 2) | (if (extended) @as(u8, 0x80) else 0);
                try out.int(u8, flags);
                try out.int(u8, item.acl.count);
                for (item.acl.roles(), 0..) |role, index| {
                    try out.int(u32, role);
                    if (extended) {
                        try out.int(u32, item.acl.grantor(index, item.owner));
                        try out.int(u8, @intFromBool(item.acl.options[index]));
                    }
                }
            }
        }

        /// Op 80: the extension, then the op-60 payload.
        pub fn encodeRoutineExtended(out: *Payload, item: *const Routine) Error!void {
            const length_at = out.used;
            try out.int(u16, 0);
            const start = out.used;
            try out.int(u8, 1);
            try out.int(u8, @as(u8, @intFromBool(item.retset)) | (@as(u8, @intFromBool(item.security_definer)) << 1));
            try out.int(u8, @intCast(item.param_count));
            try out.bytes(item.param_modes[0..item.param_count]);
            for (0..item.out_count) |index| {
                if (item.out_inputs[index] != 0xff) continue;
                try out.name(item.out_names[index].slice());
                try out.int(u32, item.out_oids[index]);
                try out.int(i32, item.out_typmods[index]);
            }
            try out.int(u8, @intCast(item.default_count));
            try out.text(item.defaults[0..item.defaults_len]);
            try out.int(u8, @intCast(item.setting_count));
            try out.text(item.settings[0..item.settings_len]);
            const length = out.used - start;
            if (length > 0xffff) return error.TransactionLogCapacity;
            out.buffer[length_at] = @truncate(length);
            out.buffer[length_at + 1] = @truncate(length >> 8);
            try encodeRoutine(out, item);
        }

        /// Op 62 carries plain triggers only; catalog images refuse
        /// transition tables and constraint triggers (op 120).
        pub fn encodeTrigger(out: *Payload, item: *const Trigger) Error!void {
            if (item.extended()) return error.UnsupportedStatement;
            try encodeTriggerFields(out, item);
        }

        /// Op 120 (B11 wave 5): the extension, then the op-62 payload.
        pub fn encodeTriggerExtended(out: *Payload, item: *const Trigger) Error!void {
            if (!item.extended()) return error.UnsupportedStatement;
            var flags: u8 = 0;
            if (item.old_table.len != 0) flags |= trigger_old_table;
            if (item.new_table.len != 0) flags |= trigger_new_table;
            if (item.constraint) flags |= trigger_constraint;
            if (item.deferrable) flags |= trigger_deferrable;
            if (item.initially_deferred) flags |= trigger_initially_deferred;
            try out.int(u8, flags);
            if (item.old_table.len != 0) try out.name(item.old_table.slice());
            if (item.new_table.len != 0) try out.name(item.new_table.slice());
            if (item.constraint) {
                try out.int(u32, item.constraint_oid);
                try out.int(u32, item.constraint_relid);
            }
            try encodeTriggerFields(out, item);
        }

        fn encodeTriggerFields(out: *Payload, item: *const Trigger) Error!void {
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

        /// Op 64 carries DO NOTHING rules only; a rule with actions is op 85
        /// (catalog images do not carry rule actions: they refuse them).
        pub fn encodeRule(out: *Payload, item: *const Rule) Error!void {
            if (item.action.len != 0) return error.UnsupportedStatement;
            try encodeRuleFields(out, item);
        }

        /// Op 85 (B11 wave 4): the op 64 payload, flags u8 (1 multiple),
        /// then the action text (u16 + bytes, at least one byte).
        pub fn encodeRuleAction(out: *Payload, item: *const Rule) Error!void {
            if (item.action.len == 0) return error.UnsupportedStatement;
            try encodeRuleFields(out, item);
            try out.int(u8, @intFromBool(item.multiple));
            try out.text(item.action.slice());
        }

        fn encodeRuleFields(out: *Payload, item: *const Rule) Error!void {
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
            // record needs the extension (several OUT parameters).
            if (out.return_oid != void_oid and out.return_oid != trigger_oid and out.return_oid != record_oid and !knownType(out.return_oid)) return error.InvalidChangeRecord;
            if (out.kind == 'p' and out.return_oid != void_oid and out.return_oid != record_oid) return error.InvalidChangeRecord;
            out.body.len = try readText(&reader, &out.body.bytes);
            if (!reader.finished()) {
                out.owner = try reader.int(u32);
                if (out.owner == 0) return error.InvalidChangeRecord;
            }
            if (!reader.finished()) {
                const flags = try reader.int(u8);
                const count_acl = try reader.int(u8);
                const extended = flags & 0x80 != 0;
                if (flags & ~@as(u8, 0x87) != 0 or count_acl > config.routine_acl_entries or
                    (flags & 4 != 0 and (!extended or flags & 1 == 0))) return error.InvalidChangeRecord;
                out.acl = .{ .explicit = true, .owner = flags & 1 != 0, .owner_option = flags & 4 != 0, .public = flags & 2 != 0 };
                for (0..count_acl) |_| {
                    const role = try reader.int(u32);
                    const grantor = if (extended) try reader.int(u32) else out.owner;
                    const option = if (extended) try reader.int(u8) else 0;
                    if (grantor == 0 or option > 1 or
                        (grantor == out.owner and (role == 0 or role == out.owner)) or
                        (option != 0 and (role == 0 or role == grantor))) return error.InvalidChangeRecord;
                    for (out.acl.roles(), 0..) |existing, index| {
                        if (role == existing and grantor == out.acl.grantor(index, out.owner)) return error.InvalidChangeRecord;
                    }
                    out.acl.grantees[out.acl.count] = role;
                    out.acl.grantors[out.acl.count] = if (grantor == out.owner) 0 else grantor;
                    out.acl.options[out.acl.count] = option != 0;
                    out.acl.count += 1;
                }
            }
            if (!reader.finished()) return error.InvalidChangeRecord;
        }

        /// Op 80: validates the extension against the base routine.
        pub fn decodeRoutineExtended(payload: []const u8, out: *Routine) Error!void {
            var reader = Reader{ .bytes = payload };
            const length = try reader.int(u16);
            const extension = try reader.take(length);
            try decodeRoutine(payload[reader.position..], out);
            var ext = Reader{ .bytes = extension };
            if (try ext.int(u8) != 1) return error.InvalidChangeRecord;
            const flags = try ext.int(u8);
            if (flags & ~@as(u8, 3) != 0) return error.InvalidChangeRecord;
            out.retset = flags & 1 != 0;
            out.security_definer = flags & 2 != 0;
            const count = try ext.int(u8);
            if (count > config.routine_args or (count != 0 and count < out.arg_count)) return error.InvalidChangeRecord;
            out.param_count = count;
            // Every mode first, then the OUT / TABLE parameters' types.
            const modes = try ext.take(count);
            var input: usize = 0;
            for (modes, 0..) |mode, index| {
                out.param_modes[index] = mode;
                switch (mode) {
                    'i', 'b', 'v' => {
                        if (input == out.arg_count) return error.InvalidChangeRecord;
                        out.arg_modes[input] = mode;
                        if (mode == 'b') {
                            if (out.out_count == out.out_names.len) return error.InvalidChangeRecord;
                            out.out_names[out.out_count] = out.arg_names[input];
                            out.out_oids[out.out_count] = out.arg_oids[input];
                            out.out_typmods[out.out_count] = out.arg_typmods[input];
                            out.out_inputs[out.out_count] = @intCast(input);
                            out.out_count += 1;
                        }
                        input += 1;
                    },
                    'o', 't' => {
                        if (out.out_count == out.out_names.len) return error.InvalidChangeRecord;
                        const name_len = try ext.int(u8);
                        const name = try ext.take(name_len);
                        if (name.len > config.name_bytes) return error.InvalidChangeRecord;
                        for (name) |byte| if (byte == 0) return error.InvalidChangeRecord;
                        out.out_names[out.out_count] = .{ .len = name.len };
                        @memcpy(out.out_names[out.out_count].bytes[0..name.len], name);
                        out.out_oids[out.out_count] = try ext.int(u32);
                        out.out_typmods[out.out_count] = try ext.int(i32);
                        if (!knownType(out.out_oids[out.out_count])) return error.InvalidChangeRecord;
                        out.out_inputs[out.out_count] = 0xff;
                        out.out_count += 1;
                    },
                    else => return error.InvalidChangeRecord,
                }
            }
            if (count != 0 and input != out.arg_count) return error.InvalidChangeRecord;
            // VARIADIC: only the last input, an array.
            for (out.arg_modes[0..out.arg_count], 0..) |mode, index| {
                if (mode != 'v') continue;
                if (index + 1 != out.arg_count or types.typeFromOid(out.arg_oids[index]) == null or types.elementData(types.typeFromOid(out.arg_oids[index]).?) == null) return error.InvalidChangeRecord;
            }
            for (out.param_modes[0..count]) |mode| if (mode == 't' and !out.retset) return error.InvalidChangeRecord;
            out.default_count = try ext.int(u8);
            out.defaults_len = try readText(&ext, &out.defaults);
            if (out.default_count > out.arg_count or (nulCount(out.defaults[0..out.defaults_len]) orelse return error.InvalidChangeRecord) != out.default_count) return error.InvalidChangeRecord;
            out.setting_count = try ext.int(u8);
            out.settings_len = try readText(&ext, &out.settings);
            if ((nulCount(out.settings[0..out.settings_len]) orelse return error.InvalidChangeRecord) != out.setting_count) return error.InvalidChangeRecord;
            for (0..out.setting_count) |index| {
                const entry = nulEntry(out.settings[0..out.settings_len], index);
                const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidChangeRecord;
                if (eq == 0) return error.InvalidChangeRecord;
            }
            if (!ext.finished()) return error.InvalidChangeRecord;
            // The result type follows the outputs (one: its type; more: record).
            if (out.kind == 'f' and out.out_count == 1 and out.return_oid != out.out_oids[0]) return error.InvalidChangeRecord;
            if (out.out_count > 1 and out.return_oid != record_oid) return error.InvalidChangeRecord;
            if (out.return_oid == record_oid and out.out_count < (if (out.kind == 'p') @as(usize, 1) else 2)) return error.InvalidChangeRecord;
            if (out.kind == 'p' and out.out_count == 0 and out.return_oid != void_oid) return error.InvalidChangeRecord;
            if (out.kind == 'p' and out.retset) return error.InvalidChangeRecord;
            if (!out.extended()) return error.InvalidChangeRecord;
        }

        pub fn decodeTrigger(payload: []const u8, out: *Trigger) Error!void {
            var reader = Reader{ .bytes = payload };
            out.* = .{};
            try decodeTriggerFields(&reader, out);
        }

        /// Op 120: every extension byte is validated against PostgreSQL's
        /// rules (transition tables only on AFTER triggers of one event
        /// without columns, OLD for DELETE / UPDATE, NEW for INSERT /
        /// UPDATE, different names; constraint triggers AFTER ROW,
        /// INITIALLY DEFERRED only when DEFERRABLE).
        pub fn decodeTriggerExtended(payload: []const u8, out: *Trigger) Error!void {
            var reader = Reader{ .bytes = payload };
            const flags = try reader.int(u8);
            if (flags == 0 or flags & ~@as(u8, 31) != 0) return error.InvalidChangeRecord;
            var old_table: Name = .{};
            var new_table: Name = .{};
            if (flags & trigger_old_table != 0) try readName(&reader, &old_table);
            if (flags & trigger_new_table != 0) try readName(&reader, &new_table);
            var constraint_oid: u32 = 0;
            var constraint_relid: u32 = 0;
            const constraint = flags & trigger_constraint != 0;
            if (constraint) {
                constraint_oid = try reader.int(u32);
                constraint_relid = try reader.int(u32);
                if (constraint_oid == 0) return error.InvalidChangeRecord;
            } else if (flags & (trigger_deferrable | trigger_initially_deferred) != 0) return error.InvalidChangeRecord;
            if (flags & trigger_initially_deferred != 0 and flags & trigger_deferrable == 0) return error.InvalidChangeRecord;
            out.* = .{};
            try decodeTriggerFields(&reader, out);
            out.old_table = old_table;
            out.new_table = new_table;
            out.constraint = constraint;
            out.deferrable = flags & trigger_deferrable != 0;
            out.initially_deferred = flags & trigger_initially_deferred != 0;
            out.constraint_oid = constraint_oid;
            out.constraint_relid = constraint_relid;
            const kind = out.tgtype;
            const events = kind & (tg_insert | tg_delete | tg_update | tg_truncate);
            if (out.transitions()) {
                if (constraint or kind & (tg_before | tg_instead) != 0 or kind & tg_truncate != 0 or out.column_count != 0) return error.InvalidChangeRecord;
                if (events != tg_insert and events != tg_delete and events != tg_update) return error.InvalidChangeRecord;
                if (old_table.len != 0 and events == tg_insert) return error.InvalidChangeRecord;
                if (new_table.len != 0 and events == tg_delete) return error.InvalidChangeRecord;
                if (old_table.len != 0 and new_table.len != 0 and types.same(old_table.slice(), new_table.slice())) return error.InvalidChangeRecord;
            }
            if (constraint and (kind & (tg_before | tg_instead | tg_truncate) != 0 or kind & tg_row == 0)) return error.InvalidChangeRecord;
        }

        fn decodeTriggerFields(reader: *Reader, out: *Trigger) Error!void {
            out.oid = try reader.int(u32);
            try readName(reader, &out.name);
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
            out.when.len = try readText(reader, &out.when.bytes);
            out.nargs = try reader.int(u8);
            out.args_len = try readText(reader, &out.args);
            var terminators: usize = 0;
            for (out.args[0..out.args_len]) |byte| {
                if (byte == 0) terminators += 1;
            }
            if (terminators != out.nargs or (out.args_len != 0 and out.args[out.args_len - 1] != 0)) return error.InvalidChangeRecord;
            if (!reader.finished()) return error.InvalidChangeRecord;
        }

        pub fn decodeRule(payload: []const u8, out: *Rule) Error!void {
            var reader = Reader{ .bytes = payload };
            try decodeRuleFields(&reader, out);
            if (!reader.finished()) return error.InvalidChangeRecord;
        }

        pub fn decodeRuleAction(payload: []const u8, out: *Rule) Error!void {
            var reader = Reader{ .bytes = payload };
            try decodeRuleFields(&reader, out);
            const flags = try reader.int(u8);
            if (flags > 1) return error.InvalidChangeRecord;
            out.multiple = flags == 1;
            out.action.len = try readText(&reader, &out.action.bytes);
            if (out.action.len == 0) return error.InvalidChangeRecord;
            for (out.action.slice()) |byte| if (byte == 0) return error.InvalidChangeRecord;
            if (!reader.finished()) return error.InvalidChangeRecord;
        }

        fn decodeRuleFields(reader: *Reader, out: *Rule) Error!void {
            out.* = .{};
            out.oid = try reader.int(u32);
            try readName(reader, &out.name);
            out.table_oid = try reader.int(u32);
            out.event = try reader.int(u8);
            const instead = try reader.int(u8);
            if (out.event < '2' or out.event > '4' or instead > 1) return error.InvalidChangeRecord;
            out.instead = instead == 1;
            out.where.len = try readText(reader, &out.where.bytes);
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
            owner: u32 = 0,
            acl: ExecuteAcl = .{},
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
                overlay.objects[at] = .{ .live = true, .class = .routine, .oid = item.oid, .namespace = item.namespace, .owner = item.owner, .acl = item.acl, .kind = item.kind, .return_oid = item.return_oid, .name = item.name, .arg_count = item.arg_count, .arg_oids = item.arg_oids };
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

        /// A routine of the overlay lives in this namespace (DROP SCHEMA
        /// records follow the drops of its routines).
        pub fn overlayNamespaceUsed(overlay: *const Overlay, namespace: u32) bool {
            for (&overlay.objects) |*object| if (object.live and object.class == .routine and object.namespace == namespace) return true;
            return false;
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
                @intFromEnum(Op.create_routine), create_routine_extended => {
                    var item: Routine = undefined;
                    if (tag == create_routine_extended) try decodeRoutineExtended(payload, &item) else try decodeRoutine(payload, &item);
                    if (item.oid < 16384 or item.oid == 0xffffffff or overlayHas(overlay, item.oid) or context.oidTaken(item.oid)) return error.ChangeRecordConflict;
                    if (!context.namespaceKnown(item.namespace)) return error.ChangeRecordConflict;
                    for (&overlay.objects) |*object| {
                        if (object.live and object.class == .routine and object.namespace == item.namespace and types.same(object.name.slice(), item.name.slice()) and
                            sameArgs(object.arg_oids[0..object.arg_count], item.args())) return error.ChangeRecordConflict;
                    }
                    try overlayAdd(overlay, .{ .live = true, .class = .routine, .oid = item.oid, .namespace = item.namespace, .owner = item.owner, .acl = item.acl, .kind = item.kind, .return_oid = item.return_oid, .name = item.name, .arg_count = item.arg_count, .arg_oids = item.arg_oids });
                    return item.oid;
                },
                @intFromEnum(Op.create_trigger), create_trigger_extended => {
                    var item: Trigger = undefined;
                    if (tag == create_trigger_extended) try decodeTriggerExtended(payload, &item) else try decodeTrigger(payload, &item);
                    if (item.oid < 16384 or item.oid == 0xffffffff or overlayHas(overlay, item.oid) or context.oidTaken(item.oid)) return error.ChangeRecordConflict;
                    if (!context.tableLive(item.table_oid)) return error.ChangeRecordConflict;
                    if (item.constraint) {
                        if (item.constraint_oid < 16384 or item.constraint_oid == 0xffffffff or item.constraint_oid == item.oid or overlayHas(overlay, item.constraint_oid) or context.oidTaken(item.constraint_oid)) return error.ChangeRecordConflict;
                        if (item.constraint_relid != 0 and !context.tableLive(item.constraint_relid)) return error.ChangeRecordConflict;
                    }
                    const function = overlayFind(overlay, .routine, item.function_oid) orelse return error.ChangeRecordConflict;
                    if (function.return_oid != trigger_oid or function.arg_count != 0) return error.ChangeRecordConflict;
                    for (&overlay.objects) |*object| {
                        if (object.live and object.class == .trigger and object.table_oid == item.table_oid and types.same(object.name.slice(), item.name.slice())) return error.ChangeRecordConflict;
                    }
                    try overlayAdd(overlay, .{ .live = true, .class = .trigger, .oid = item.oid, .table_oid = item.table_oid, .function_oid = item.function_oid, .name = item.name });
                    return @max(item.oid, item.constraint_oid);
                },
                @intFromEnum(Op.create_rule), @intFromEnum(Op.create_rule_action) => {
                    var item: Rule = undefined;
                    if (tag == @intFromEnum(Op.create_rule)) try decodeRule(payload, &item) else try decodeRuleAction(payload, &item);
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
                    object.live = false;
                    overlay.counts[@intFromEnum(class)] -= 1;
                    return null;
                },
                else => return error.UnsupportedLogVersion,
            }
        }

        /// ACL changes and routine replacement retain the OID with a
        /// drop/create pair. Check dependencies on the final record state.
        pub fn finishOverlay(overlay: *Overlay, roles: anytype) Error!void {
            for (&overlay.objects) |*object| {
                if (!object.live) continue;
                switch (object.class) {
                    .routine => {
                        if (!roles.roleExists(object.owner)) return error.ChangeRecordConflict;
                        for (object.acl.roles(), 0..) |role, index| {
                            if ((role != 0 and !roles.roleExists(role)) or !roles.roleExists(object.acl.grantor(index, object.owner))) return error.ChangeRecordConflict;
                        }
                        var edges: [@as(usize, config.routine_acl_entries) + 2]privilege_graph.Edge = undefined;
                        var support: [edges.len]privilege_graph.Graph.State = undefined;
                        const graph = object.acl.graph(object.owner, &edges);
                        graph.support(&support, null);
                        for (graph.edges[0..graph.len], support[0..graph.len]) |edge, state| {
                            if (edge.flags & ~state.available != 0) return error.ChangeRecordConflict;
                        }
                    },
                    .trigger => {
                        const function = overlayFind(overlay, .routine, object.function_oid) orelse return error.ChangeRecordConflict;
                        if (function.return_oid != trigger_oid or function.arg_count != 0 or function.kind != 'f') return error.ChangeRecordConflict;
                    },
                    .rule => {},
                }
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
