//! Kind-3 change records (Layer 0, design §4.6).
//!
//! A record is architecture-independent little-endian bytes:
//!   header: version u16 (= 1), flags u16 (= 0), op_count u32
//!   ops, each: tag u8 then its fields
//!     1 create_table  oid u32, name, expr_format_version u16 (= 1),
//!                     column_count u8, columns: name, type_oid u32,
//!                     typmod i32 (-1, NUMERIC(p,s) or TIMESTAMP[TZ](p)),
//!                     flags u8 (1 not null, 2 primary key),
//!                     default_len u16 (= 0; defaults arrive with FEAT-007)
//!     2 drop_table    oid u32
//!     3 insert        oid u32, rowid u64, count u8, values
//!     4 update        oid u32, rowid u64, count u8, values (complete row)
//!     5 delete        oid u32, rowid u64
//!     6 catalog_counters next_oid u32, count u8, (oid u32, next_rowid u64)*
//!     7..9            reserved for sequence ops (FEAT-007); rejected today
//!   name: len u8 + bytes. value: 0 null | 1 i64 | 2 bool u8 | 3 len u32 + bytes
//!   | 4 f32 bits u32 | 5 f64 bits u64 | 6 numeric {special u8, negative u8,
//!   dscale u16, coefficient 4 x u64} | 7 date i32 | 8 timestamp i64
//!   | 9 timestamptz i64 | 10 interval {months i32, days i32, us i64}
//!   | 11 jsonb len u32 + canonical bytes. Every value is checked against the
//!   column's type OID (create_table) before anything applies.
//! Ops may repeat a (table, rowid) and apply in record order.
//!
//! apply() decodes and validates the WHOLE record against a bounded,
//! caller-owned overlay before changing anything, then applies it without any
//! further failure. Unknown versions or ops fail closed with
//! UnsupportedLogVersion, malformed bytes with InvalidChangeRecord, and
//! unknown OIDs, rowid or key conflicts and capacity overflow with
//! ChangeRecordConflict.
const types = @import("types.sig");
const storage = @import("storage.sig");
const numeric = @import("numeric.sig");
const temporal = @import("temporal.sig");
const jsonb = @import("jsonb.sig");
const Error = types.Error;

pub const format_version: u16 = 1;
pub const header_size: usize = 8;
pub const first_oid: u32 = 16384;
pub const expr_format_version: u16 = 1;

pub const Op = enum(u8) { create_table = 1, drop_table = 2, insert = 3, update = 4, delete = 5, catalog_counters = 6 };

fn Unsigned(comptime T: type) type {
    return switch (T) {
        u8 => u8,
        u16 => u16,
        u32, i32 => u32,
        u64, i64 => u64,
        else => @compileError("unsupported change-record integer"),
    };
}

fn put(comptime T: type, out: []u8, value: T) void {
    const Bits = Unsigned(T);
    const bits: Bits = @bitCast(value);
    for (0..@sizeOf(T)) |index| out[index] = @truncate(bits >> @intCast(index * 8));
}

fn get(comptime T: type, input: []const u8) T {
    const Bits = Unsigned(T);
    var bits: Bits = 0;
    for (0..@sizeOf(T)) |index| bits |= @as(Bits, input[index]) << @intCast(index * 8);
    return @bitCast(bits);
}

/// Validates the header and returns the op count.
pub fn opCount(record: []const u8) Error!u32 {
    if (record.len < header_size) return error.InvalidChangeRecord;
    if (get(u16, record[0..2]) != format_version or get(u16, record[2..4]) != 0) return error.UnsupportedLogVersion;
    return get(u32, record[4..8]);
}

/// Appends ops after `used` bytes of `buffer`, writing a header when the
/// record is empty. Nothing is published until finish() returns the new length.
pub const Writer = struct {
    buffer: []u8,
    base: usize,
    used: usize,
    ops: u32 = 0,

    pub fn init(buffer: []u8, used: usize) Error!Writer {
        if (used > buffer.len) return error.TransactionLogCapacity;
        var writer = Writer{ .buffer = buffer, .base = used, .used = used };
        if (used == 0) {
            const header = try writer.reserve(header_size);
            put(u16, header[0..2], format_version);
            put(u16, header[2..4], 0);
            put(u32, header[4..8], 0);
        } else if (used < header_size) return error.InvalidChangeRecord;
        return writer;
    }

    fn reserve(self: *Writer, count: usize) Error![]u8 {
        if (count > self.buffer.len - self.used) return error.TransactionLogCapacity;
        const out = self.buffer[self.used..][0..count];
        self.used += count;
        return out;
    }

    pub fn int(self: *Writer, comptime T: type, value: T) Error!void {
        put(T, try self.reserve(@sizeOf(T)), value);
    }

    pub fn bytes(self: *Writer, value: []const u8) Error!void {
        @memcpy(try self.reserve(value.len), value);
    }

    pub fn name(self: *Writer, value: []const u8) Error!void {
        try self.int(u8, @intCast(value.len));
        try self.bytes(value);
    }

    pub fn op(self: *Writer, tag: Op) Error!void {
        try self.int(u8, @intFromEnum(tag));
        self.ops += 1;
    }

    /// Updates the header count; returns the record's new length.
    pub fn finish(self: *Writer) Error!usize {
        const previous = get(u32, self.buffer[4..8]);
        if (self.ops > 0xffffffff - previous) return error.TransactionLogCapacity;
        put(u32, self.buffer[4..8], previous + self.ops);
        return self.used;
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = header_size,

    fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.bytes.len - self.position) return error.InvalidChangeRecord;
        const out = self.bytes[self.position..][0..count];
        self.position += count;
        return out;
    }

    fn int(self: *Reader, comptime T: type) Error!T {
        return get(T, try self.take(@sizeOf(T)));
    }

    fn name(self: *Reader) Error![]const u8 {
        const len = try self.int(u8);
        return self.take(len);
    }
};

pub fn ChangeLog(comptime config: types.Config) type {
    const V = types.Values(config);
    const S = storage.Storage(config);
    const overlay_capacity = blk: {
        var capacity: usize = 2;
        while (capacity < config.rows_per_table * config.tables * 4) capacity *= 2;
        break :blk capacity;
    };
    return struct {
        // ----- encoding -------------------------------------------------

        pub fn encodeValue(writer: *Writer, cell: *const V.Cell) Error!void {
            switch (cell.*) {
                .null_value => try writer.int(u8, 0),
                .integer => |value| {
                    try writer.int(u8, 1);
                    try writer.int(i64, value);
                },
                .boolean => |value| {
                    try writer.int(u8, 2);
                    try writer.int(u8, @intFromBool(value));
                },
                .text => |*text| {
                    try writer.int(u8, 3);
                    try writer.int(u32, @intCast(text.len));
                    try writer.bytes(text.slice());
                },
                .float4 => |value| {
                    try writer.int(u8, 4);
                    try writer.int(u32, @bitCast(value));
                },
                .float8 => |value| {
                    try writer.int(u8, 5);
                    try writer.int(u64, @bitCast(value));
                },
                .numeric => |*value| {
                    try writer.int(u8, 6);
                    try writer.int(u8, @intFromEnum(value.special));
                    try writer.int(u8, @intFromBool(value.negative));
                    try writer.int(u16, value.dscale);
                    for (value.limbs) |limb| try writer.int(u64, limb);
                },
                .date => |value| {
                    try writer.int(u8, 7);
                    try writer.int(i32, value);
                },
                .timestamp => |value| {
                    try writer.int(u8, 8);
                    try writer.int(i64, value);
                },
                .timestamptz => |value| {
                    try writer.int(u8, 9);
                    try writer.int(i64, value);
                },
                .interval => |value| {
                    try writer.int(u8, 10);
                    try writer.int(i32, value.months);
                    try writer.int(i32, value.days);
                    try writer.int(i64, value.us);
                },
                .jsonb => |*document| {
                    try writer.int(u8, 11);
                    try writer.int(u32, @intCast(document.len));
                    try writer.bytes(document.slice());
                },
            }
        }

        pub fn encodeCreate(writer: *Writer, table: *const S.Table) Error!void {
            try writer.op(.create_table);
            try writer.int(u32, table.oid);
            try writer.name(table.name.slice());
            try writer.int(u16, expr_format_version);
            try writer.int(u8, @intCast(table.column_count));
            for (table.columns[0..table.column_count]) |*column| {
                try writer.name(column.name.slice());
                try writer.int(u32, types.typeOid(column.data_type));
                try writer.int(i32, column.typmod);
                try writer.int(u8, @as(u8, @intFromBool(column.not_null)) | (@as(u8, @intFromBool(column.primary_key)) << 1));
                try writer.int(u16, 0);
            }
        }

        pub fn encodeDrop(writer: *Writer, oid: u32) Error!void {
            try writer.op(.drop_table);
            try writer.int(u32, oid);
        }

        pub fn encodeRow(writer: *Writer, tag: Op, oid: u32, rowid: u64, cells: []const V.Cell) Error!void {
            try writer.op(tag);
            try writer.int(u32, oid);
            try writer.int(u64, rowid);
            try writer.int(u8, @intCast(cells.len));
            for (cells) |*cell| try encodeValue(writer, cell);
        }

        pub fn encodeDelete(writer: *Writer, oid: u32, rowid: u64) Error!void {
            try writer.op(.delete);
            try writer.int(u32, oid);
            try writer.int(u64, rowid);
        }

        /// next_oid plus every live table's next rowid.
        pub fn encodeCounters(writer: *Writer, next_oid: u32, tables: *const [config.tables]S.Table) Error!void {
            try writer.op(.catalog_counters);
            try writer.int(u32, next_oid);
            var count: u8 = 0;
            for (tables) |*table| if (table.live) {
                count += 1;
            };
            try writer.int(u8, count);
            for (tables) |*table| if (table.live) {
                try writer.int(u32, table.oid);
                try writer.int(u64, table.next_rowid);
            };
        }

        // ----- validation overlay ---------------------------------------

        const RowEntry = struct {
            epoch: u32 = 0,
            table: u8 = 0,
            live: bool = false,
            has_key: bool = false,
            rowid: u64 = 0,
            key_offset: u32 = 0,
        };

        const KeyEntry = struct {
            epoch: u32 = 0,
            table: u8 = 0,
            hash: usize = 0,
            rowid: u64 = 0,
        };

        const VTable = struct {
            live: bool = false,
            /// Rows of this slot still come from the database (not recreated).
            base: bool = false,
            oid: u32 = 0,
            name: V.Name = .{},
            column_count: usize = 0,
            columns: [config.columns]V.Column = undefined,
            primary: ?usize = null,
            base_next_rowid: u64 = 0,
            next_rowid: u64 = 0,
            live_rows: usize = 0,
        };

        /// Caller-owned replay overlay. Bounded by 2 x rows x tables live
        /// entries (rows touched from the database plus rows created by the
        /// record that are still alive) at <= 50% load. Reset is O(1).
        pub const Scratch = struct {
            epoch: u32 = 0,
            rows: [overlay_capacity]RowEntry = @splat(.{}),
            keys: [overlay_capacity]KeyEntry = @splat(.{}),
            tables: [config.tables]VTable = undefined,
        };

        const mask = overlay_capacity - 1;

        fn rowHome(table: u8, rowid: u64) usize {
            return storage.mix(rowid ^ (@as(u64, table) << 56)) & mask;
        }

        fn keyHome(table: u8, hash: usize) usize {
            return storage.mix(@as(u64, hash) ^ (@as(u64, table) << 56)) & mask;
        }

        fn findRow(scratch: *Scratch, table: u8, rowid: u64) ?usize {
            var position = rowHome(table, rowid);
            while (true) {
                const entry = &scratch.rows[position];
                if (entry.epoch != scratch.epoch) return null;
                if (entry.table == table and entry.rowid == rowid) return position;
                position = (position + 1) & mask;
            }
        }

        fn putRow(scratch: *Scratch, value: RowEntry) Error!void {
            if (findRow(scratch, value.table, value.rowid)) |position| {
                scratch.rows[position] = value;
                return;
            }
            var position = rowHome(value.table, value.rowid);
            var probes: usize = 0;
            while (scratch.rows[position].epoch == scratch.epoch) : (position = (position + 1) & mask) {
                probes += 1;
                if (probes == overlay_capacity / 2) return error.ChangeRecordConflict;
            }
            scratch.rows[position] = value;
        }

        fn removeRowAt(scratch: *Scratch, start: usize) void {
            var hole = start;
            var probe = start;
            while (true) {
                probe = (probe + 1) & mask;
                const entry = scratch.rows[probe];
                if (entry.epoch != scratch.epoch) break;
                const distance_entry = (probe -% rowHome(entry.table, entry.rowid)) & mask;
                if (((probe -% hole) & mask) <= distance_entry) {
                    scratch.rows[hole] = entry;
                    hole = probe;
                }
            }
            scratch.rows[hole].epoch = scratch.epoch -% 1;
        }

        fn putKey(scratch: *Scratch, table: u8, hash: usize, rowid: u64) Error!void {
            var position = keyHome(table, hash);
            var probes: usize = 0;
            while (scratch.keys[position].epoch == scratch.epoch) : (position = (position + 1) & mask) {
                probes += 1;
                if (probes == overlay_capacity / 2) return error.ChangeRecordConflict;
            }
            scratch.keys[position] = .{ .epoch = scratch.epoch, .table = table, .hash = hash, .rowid = rowid };
        }

        fn removeKeyAt(scratch: *Scratch, start: usize) void {
            var hole = start;
            var probe = start;
            while (true) {
                probe = (probe + 1) & mask;
                const entry = scratch.keys[probe];
                if (entry.epoch != scratch.epoch) break;
                const distance_entry = (probe -% keyHome(entry.table, entry.hash)) & mask;
                if (((probe -% hole) & mask) <= distance_entry) {
                    scratch.keys[hole] = entry;
                    hole = probe;
                }
            }
            scratch.keys[hole].epoch = scratch.epoch -% 1;
        }

        fn removeKey(scratch: *Scratch, table: u8, hash: usize, rowid: u64) void {
            var position = keyHome(table, hash);
            while (scratch.keys[position].epoch == scratch.epoch) : (position = (position + 1) & mask) {
                const entry = &scratch.keys[position];
                if (entry.table == table and entry.hash == hash and entry.rowid == rowid) {
                    removeKeyAt(scratch, position);
                    return;
                }
            }
        }

        /// Removes every overlay entry of a dropped table slot. Backward
        /// shifts only move entries into the current or a later hole, so
        /// re-checking the same position visits every entry.
        fn purge(scratch: *Scratch, table: u8) void {
            var position: usize = 0;
            while (position < overlay_capacity) {
                const entry = &scratch.rows[position];
                if (entry.epoch == scratch.epoch and entry.table == table) {
                    removeRowAt(scratch, position);
                    continue;
                }
                position += 1;
            }
            position = 0;
            while (position < overlay_capacity) {
                const entry = &scratch.keys[position];
                if (entry.epoch == scratch.epoch and entry.table == table) {
                    removeKeyAt(scratch, position);
                    continue;
                }
                position += 1;
            }
        }

        // ----- decoding -------------------------------------------------

        const Value = struct { cell: V.Cell, offset: u32 };

        fn decodeValue(reader: *Reader) Error!Value {
            const offset: u32 = @intCast(reader.position);
            const tag = try reader.int(u8);
            const cell: V.Cell = switch (tag) {
                0 => .null_value,
                1 => .{ .integer = try reader.int(i64) },
                2 => blk: {
                    const value = try reader.int(u8);
                    if (value > 1) return error.InvalidChangeRecord;
                    break :blk .{ .boolean = value == 1 };
                },
                3, 11 => blk: {
                    const len = try reader.int(u32);
                    if (len > config.text_bytes) return error.ChangeRecordConflict;
                    var text: V.Text = .{ .len = len };
                    @memcpy(text.bytes[0..len], try reader.take(len));
                    if (tag == 3) break :blk .{ .text = text };
                    if (!jsonb.validBinary(text.slice(), config.json_depth, config.numeric_digits)) return error.InvalidChangeRecord;
                    break :blk .{ .jsonb = text };
                },
                4 => .{ .float4 = @bitCast(try reader.int(u32)) },
                5 => .{ .float8 = @bitCast(try reader.int(u64)) },
                6 => blk: {
                    const special = try reader.int(u8);
                    const negative = try reader.int(u8);
                    if (special > 3 or negative > 1) return error.InvalidChangeRecord;
                    var out: numeric.Numeric = .{ .special = @enumFromInt(special), .negative = negative == 1, .dscale = try reader.int(u16) };
                    for (&out.limbs) |*limb| limb.* = try reader.int(u64);
                    if (out.dscale > numeric.max_scale or numeric.digitCount(out.coef()) > config.numeric_digits) return error.InvalidChangeRecord;
                    if (out.special != .finite and (out.coef() != 0 or out.dscale != 0 or out.negative)) return error.InvalidChangeRecord;
                    if (out.negative and out.coef() == 0) return error.InvalidChangeRecord;
                    break :blk .{ .numeric = out };
                },
                7 => blk: {
                    const days = try reader.int(i32);
                    if (temporal.finiteDate(days) and !temporal.validDate(days)) return error.InvalidChangeRecord;
                    break :blk .{ .date = days };
                },
                8, 9 => blk: {
                    const us = try reader.int(i64);
                    if (temporal.finiteTimestamp(us) and !temporal.validTimestamp(us)) return error.InvalidChangeRecord;
                    break :blk if (tag == 8) V.Cell{ .timestamp = us } else V.Cell{ .timestamptz = us };
                },
                10 => .{ .interval = .{ .months = try reader.int(i32), .days = try reader.int(i32), .us = try reader.int(i64) } },
                else => return error.InvalidChangeRecord,
            };
            return .{ .cell = cell, .offset = offset };
        }

        fn valueAt(record: []const u8, offset: u32) Error!V.Cell {
            var reader = Reader{ .bytes = record, .position = offset };
            return (try decodeValue(&reader)).cell;
        }

        fn sameValue(left: *const V.Cell, right: *const V.Cell) bool {
            if (@as(V.CellTag, left.*) != @as(V.CellTag, right.*)) return false;
            return V.compare(left, right) == 0;
        }

        const Definition = struct {
            oid: u32,
            name: V.Name,
            columns: [config.columns]V.Column,
            count: usize,
        };

        fn validName(value: []const u8) bool {
            if (value.len == 0 or value.len > config.name_bytes or !types.letter(value[0])) return false;
            for (value) |byte| if (!(types.letter(byte) or types.digit(byte)) or (byte >= 'A' and byte <= 'Z')) return false;
            return true;
        }

        fn decodeCreate(reader: *Reader) Error!Definition {
            var out: Definition = .{ .oid = try reader.int(u32), .name = .{}, .columns = @splat(.{}), .count = 0 };
            const table_name = try reader.name();
            if (!validName(table_name)) return error.InvalidChangeRecord;
            out.name.len = table_name.len;
            @memcpy(out.name.bytes[0..table_name.len], table_name);
            if (try reader.int(u16) != expr_format_version) return error.UnsupportedLogVersion;
            out.count = try reader.int(u8);
            if (out.count == 0) return error.InvalidChangeRecord;
            if (out.count > config.columns) return error.ChangeRecordConflict;
            var has_primary = false;
            for (0..out.count) |index| {
                const column_name = try reader.name();
                if (!validName(column_name)) return error.InvalidChangeRecord;
                var column: V.Column = .{ .name = .{ .len = column_name.len } };
                @memcpy(column.name.bytes[0..column_name.len], column_name);
                for (out.columns[0..index]) |*previous|
                    if (types.same(previous.name.slice(), column.name.slice())) return error.InvalidChangeRecord;
                column.data_type = types.typeFromOid(try reader.int(u32)) orelse return error.UnsupportedLogVersion;
                column.typmod = try reader.int(i32);
                const typmod_ok = switch (column.data_type) {
                    .numeric => column.typmod == -1 or blk: {
                        const decoded = numeric.Ops(config.numeric_digits).decodeTypmod(column.typmod) orelse break :blk false;
                        break :blk decoded.precision >= 1 and decoded.precision <= config.numeric_digits and decoded.scale >= -1000 and decoded.scale <= 1000;
                    },
                    .timestamp, .timestamptz => column.typmod >= -1 and column.typmod <= 6,
                    else => column.typmod == -1,
                };
                if (!typmod_ok) return error.InvalidChangeRecord;
                const flags = try reader.int(u8);
                if (flags > 3) return error.InvalidChangeRecord;
                column.not_null = flags & 1 != 0;
                column.primary_key = flags & 2 != 0;
                if (column.primary_key) {
                    if (has_primary or !column.not_null) return error.InvalidChangeRecord;
                    has_primary = true;
                }
                if (try reader.int(u16) != 0) return error.UnsupportedLogVersion;
                out.columns[index] = column;
            }
            return out;
        }

        fn findVTable(scratch: *Scratch, oid: u32) Error!u8 {
            for (&scratch.tables, 0..) |*table, index| if (table.live and table.oid == oid) return @intCast(index);
            return error.ChangeRecordConflict;
        }

        /// Decodes `count` values for the table into row, checking types.
        fn decodeRow(reader: *Reader, table: *const VTable, row: *V.Row, key_offset: *u32) Error!void {
            const count = try reader.int(u8);
            if (count != table.column_count) return error.ChangeRecordConflict;
            for (0..count) |index| {
                const value = try decodeValue(reader);
                row.cells[index] = value.cell;
                // Stored values are already typed; integers must fit int4 columns.
                V.validate(&table.columns[index], &row.cells[index]) catch return error.ChangeRecordConflict;
                if (table.primary == index) key_offset.* = value.offset;
            }
        }

        fn rowExists(db: anytype, scratch: *Scratch, table: u8, rowid: u64) bool {
            if (findRow(scratch, table, rowid)) |position| return scratch.rows[position].live;
            const vt = &scratch.tables[table];
            if (!vt.base or rowid >= vt.base_next_rowid) return false;
            const entry = &db.tables[table];
            const slot = S.findRow(entry, rowid) orelse return false;
            return S.visible(entry, slot) != null;
        }

        fn keyTaken(db: anytype, scratch: *Scratch, record: []const u8, table: u8, key: *const V.Cell, exclude: u64) Error!bool {
            const vt = &scratch.tables[table];
            if (vt.base) {
                const entry = &db.tables[table];
                if (S.lookupKey(entry, key)) |slot| {
                    const rowid = entry.rows[slot].rowid;
                    if (rowid != exclude) {
                        const position = findRow(scratch, table, rowid) orelse return true;
                        const touched = &scratch.rows[position];
                        if (touched.live and touched.has_key) {
                            const current = try valueAt(record, touched.key_offset);
                            if (sameValue(&current, key)) return true;
                        }
                    }
                }
            }
            const hash = V.hash(key);
            var position = keyHome(table, hash);
            while (scratch.keys[position].epoch == scratch.epoch) : (position = (position + 1) & mask) {
                const entry = &scratch.keys[position];
                if (entry.table != table or entry.hash != hash or entry.rowid == exclude) continue;
                const row = findRow(scratch, table, entry.rowid) orelse continue;
                const current = try valueAt(record, scratch.rows[row].key_offset);
                if (sameValue(&current, key)) return true;
            }
            return false;
        }

        fn validate(db: anytype, record: []const u8, scratch: *Scratch) Error!void {
            const count = try opCount(record);
            scratch.epoch +%= 1;
            if (scratch.epoch == 0) {
                @memset(&scratch.rows, .{});
                @memset(&scratch.keys, .{});
                scratch.epoch = 1;
            }
            for (&scratch.tables, &db.tables) |*vt, *table| {
                const committed = S.committedTable(table);
                vt.* = .{ .live = committed, .base = committed };
                if (!committed) continue;
                vt.oid = table.oid;
                vt.name = table.name;
                vt.column_count = table.column_count;
                vt.columns = table.columns;
                vt.primary = table.primary_column;
                vt.base_next_rowid = table.next_rowid;
                vt.next_rowid = table.next_rowid;
                vt.live_rows = S.liveRows(table);
            }
            var next_oid: u32 = first_oid + db.oid_counter;
            var reader = Reader{ .bytes = record };
            var row: V.Row = .{};
            for (0..count) |_| {
                const tag = try reader.int(u8);
                switch (tag) {
                    @intFromEnum(Op.create_table) => {
                        const definition = try decodeCreate(&reader);
                        if (definition.oid < next_oid) return error.ChangeRecordConflict;
                        var free: ?usize = null;
                        for (&scratch.tables, 0..) |*vt, index| {
                            if (vt.live and types.same(vt.name.slice(), definition.name.slice())) return error.ChangeRecordConflict;
                            if (!vt.live and free == null) free = index;
                        }
                        const index = free orelse return error.ChangeRecordConflict;
                        purge(scratch, @intCast(index));
                        const vt = &scratch.tables[index];
                        vt.* = .{ .live = true, .oid = definition.oid, .name = definition.name, .column_count = definition.count, .columns = definition.columns, .next_rowid = 1 };
                        for (definition.columns[0..definition.count], 0..) |column, position| if (column.primary_key) {
                            vt.primary = position;
                        };
                        if (definition.oid == 0xffffffff) return error.ChangeRecordConflict;
                        next_oid = definition.oid + 1;
                    },
                    @intFromEnum(Op.drop_table) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        scratch.tables[index].live = false;
                        scratch.tables[index].base = false;
                        purge(scratch, index);
                    },
                    @intFromEnum(Op.insert) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        const vt = &scratch.tables[index];
                        const rowid = try reader.int(u64);
                        // Concurrent transactions commit in any order, so rowids
                        // need only be unused, not ascending.
                        if (rowid == 0 or rowid == 0xffffffffffffffff or rowExists(db, scratch, index, rowid)) return error.ChangeRecordConflict;
                        if (findRow(scratch, index, rowid) != null) return error.ChangeRecordConflict;
                        var key_offset: u32 = 0;
                        try decodeRow(&reader, vt, &row, &key_offset);
                        if (vt.live_rows == config.rows_per_table) return error.ChangeRecordConflict;
                        if (vt.primary) |column| {
                            if (try keyTaken(db, scratch, record, index, &row.cells[column], 0)) return error.ChangeRecordConflict;
                            try putKey(scratch, index, V.hash(&row.cells[column]), rowid);
                        }
                        try putRow(scratch, .{ .epoch = scratch.epoch, .table = index, .live = true, .has_key = vt.primary != null, .rowid = rowid, .key_offset = key_offset });
                        if (rowid + 1 > vt.next_rowid) vt.next_rowid = rowid + 1;
                        vt.live_rows += 1;
                    },
                    @intFromEnum(Op.update) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        const vt = &scratch.tables[index];
                        const rowid = try reader.int(u64);
                        if (!rowExists(db, scratch, index, rowid)) return error.ChangeRecordConflict;
                        var key_offset: u32 = 0;
                        try decodeRow(&reader, vt, &row, &key_offset);
                        if (vt.primary) |column| {
                            if (try keyTaken(db, scratch, record, index, &row.cells[column], rowid)) return error.ChangeRecordConflict;
                            if (findRow(scratch, index, rowid)) |position| {
                                if (scratch.rows[position].has_key) {
                                    const old = try valueAt(record, scratch.rows[position].key_offset);
                                    removeKey(scratch, index, V.hash(&old), rowid);
                                }
                            }
                            try putKey(scratch, index, V.hash(&row.cells[column]), rowid);
                        }
                        try putRow(scratch, .{ .epoch = scratch.epoch, .table = index, .live = true, .has_key = vt.primary != null, .rowid = rowid, .key_offset = key_offset });
                    },
                    @intFromEnum(Op.delete) => {
                        const index = try findVTable(scratch, try reader.int(u32));
                        const vt = &scratch.tables[index];
                        const rowid = try reader.int(u64);
                        if (!rowExists(db, scratch, index, rowid)) return error.ChangeRecordConflict;
                        const created = !vt.base or rowid >= vt.base_next_rowid;
                        if (findRow(scratch, index, rowid)) |position| {
                            if (scratch.rows[position].has_key) {
                                const old = try valueAt(record, scratch.rows[position].key_offset);
                                removeKey(scratch, index, V.hash(&old), rowid);
                            }
                            if (created) removeRowAt(scratch, position);
                        }
                        if (!created) try putRow(scratch, .{ .epoch = scratch.epoch, .table = index, .live = false, .rowid = rowid });
                        vt.live_rows -= 1;
                    },
                    @intFromEnum(Op.catalog_counters) => {
                        const counter = try reader.int(u32);
                        if (counter < next_oid) return error.ChangeRecordConflict;
                        next_oid = counter;
                        const tables = try reader.int(u8);
                        if (tables > config.tables) return error.ChangeRecordConflict;
                        for (0..tables) |_| {
                            const index = try findVTable(scratch, try reader.int(u32));
                            const next = try reader.int(u64);
                            if (next < scratch.tables[index].next_rowid) return error.ChangeRecordConflict;
                            scratch.tables[index].next_rowid = next;
                        }
                    },
                    else => return error.UnsupportedLogVersion,
                }
            }
            if (reader.position != record.len) return error.InvalidChangeRecord;
        }

        // ----- application (infallible after validation) ----------------

        fn tableByOid(db: anytype, oid: u32) Error!*S.Table {
            for (&db.tables) |*table| if (S.committedTable(table) and table.oid == oid) return table;
            return error.ChangeRecordConflict;
        }

        fn writeVersion(db: anytype, table: *S.Table, slot: u32, older: u32, row: *const V.Row, csn: u64) Error!u32 {
            try S.ensureVersions(table, 1, csn);
            const version = S.allocVersion(table);
            table.versions[version] = .{ .row = slot + 1, .xmin = .{ .epoch = db.epoch }, .xmin_cid = db.cid, .xmin_csn = csn, .older = older, .cells = row.cells };
            table.rows[slot].newest = version + 1;
            S.indexKey(table, version);
            return version;
        }

        fn retire(db: anytype, table: *S.Table, version: u32, csn: u64) void {
            const entry = &table.versions[version];
            entry.xmax = .{ .epoch = db.epoch };
            entry.xmax_cid = db.cid;
            entry.xmax_csn = csn;
            S.reclaimVersion(table, version);
        }

        /// `db` provides tables, oid_counter, csn, cid and epoch.
        pub fn apply(db: anytype, record: []const u8, scratch: *Scratch) Error!void {
            try validate(db, record, scratch);
            // Validated: the remaining errors are unreachable invariants.
            const csn = db.csn + 1;
            db.epoch +%= 1;
            if (db.epoch == 0) db.epoch = 1;
            db.cid +%= 1;
            const count = try opCount(record);
            var reader = Reader{ .bytes = record };
            var row: V.Row = .{};
            for (0..count) |_| {
                const tag = try reader.int(u8);
                switch (tag) {
                    @intFromEnum(Op.create_table) => {
                        const definition = try decodeCreate(&reader);
                        for (&db.tables, 0..) |*table, index| if (!table.live) {
                            S.reset(table, definition.oid, definition.name, definition.columns[0..definition.count]);
                            try db.replayCreate(index, csn);
                            break;
                        };
                        db.oid_counter = definition.oid + 1 - first_oid;
                    },
                    @intFromEnum(Op.drop_table) => {
                        const table = try tableByOid(db, try reader.int(u32));
                        db.replayDrop((@intFromPtr(table) - @intFromPtr(&db.tables[0])) / @sizeOf(S.Table), csn);
                        // Replay has no snapshot: the slot is free at once.
                        table.live = false;
                        table.dead_csn = 0;
                    },
                    @intFromEnum(Op.insert), @intFromEnum(Op.update) => {
                        const table = try tableByOid(db, try reader.int(u32));
                        const rowid = try reader.int(u64);
                        const columns = try reader.int(u8);
                        row = .{};
                        for (0..columns) |index| row.cells[index] = (try decodeValue(&reader)).cell;
                        if (tag == @intFromEnum(Op.insert)) {
                            try S.ensureVersions(table, 1, csn);
                            try S.ensureRowSlot(table, csn);
                            const slot = S.allocRow(table, rowid);
                            _ = try writeVersion(db, table, slot, 0, &row, csn);
                            if (rowid + 1 > table.next_rowid) table.next_rowid = rowid + 1;
                        } else {
                            const slot = S.findRow(table, rowid) orelse return error.ChangeRecordConflict;
                            const old = S.visible(table, slot) orelse return error.ChangeRecordConflict;
                            _ = try writeVersion(db, table, slot, old + 1, &row, csn);
                            retire(db, table, old, csn);
                        }
                    },
                    @intFromEnum(Op.delete) => {
                        const table = try tableByOid(db, try reader.int(u32));
                        const slot = S.findRow(table, try reader.int(u64)) orelse return error.ChangeRecordConflict;
                        const old = S.visible(table, slot) orelse return error.ChangeRecordConflict;
                        retire(db, table, old, csn);
                    },
                    @intFromEnum(Op.catalog_counters) => {
                        db.oid_counter = (try reader.int(u32)) - first_oid;
                        const tables = try reader.int(u8);
                        for (0..tables) |_| {
                            const table = try tableByOid(db, try reader.int(u32));
                            table.next_rowid = try reader.int(u64);
                        }
                    },
                    else => return error.UnsupportedLogVersion,
                }
            }
            db.csn = csn;
        }
    };
}
