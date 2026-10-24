//! Row construction for INSERT values and expression SET (Layer 0, design
//! §4.9). Expressions are evaluated against the old row (UPDATE) or no row
//! (INSERT), converted with assignment casts (inserted by the binder; MySQL/TDS
//! integer 0/1 into boolean here), coerced to the column typmod (NUMERIC(p,s)
//! rounding and 22003, TIMESTAMP(p) rounding) and checked (NOT NULL, int2/int4
//! range). Primary-key
//! uniqueness is checked per row as PostgreSQL's immediate unique index
//! does: a key is taken by any committed row this statement has not already
//! replaced, or by a version this statement created.
const types = @import("types.sig");
const ast = @import("ast.sig");
const storage = @import("storage.sig");
const expr = @import("expr.sig");
const value = @import("value.sig");
const Error = types.Error;
const none = ast.none;

pub fn Dml(comptime config: types.Config) type {
    const V = types.Values(config);
    const S = storage.Storage(config);
    const E = expr.Eval(config);
    const Io = value.Io(config);
    return struct {
        /// Converts an evaluated value into the column's stored form.
        pub fn store(column: *const V.Column, evaluated: V.Cell, session: *const value.Session) Error!V.Cell {
            var cell = evaluated;
            switch (column.data_type) {
                .text, .name => if (cell != .null_value and cell != .text) {
                    cell = try E.toText(&evaluated, true, session);
                },
                .boolean => if (cell == .integer) {
                    // The binder admits integers here only for MySQL/TDS.
                    const integer = cell.integer;
                    if (integer != 0 and integer != 1) return error.TypeMismatch;
                    cell = .{ .boolean = integer == 1 };
                },
                else => {},
            }
            cell = try Io.applyTypmod(cell, types.typeOfData(column.data_type), column.typmod);
            try V.validate(column, &cell);
            return cell;
        }

        /// Bound column defaults and generation expressions (binder).
        pub const Derived = struct {
            defaults: *const [config.columns]u16,
            generated: *const [config.columns]u16,
        };

        /// The column default (DEFAULT expression, identity nextval) for an
        /// unlisted column or a DEFAULT item; NULL without one.
        fn defaultCell(ctx: *const E.Context, table: *const S.Table, derived: Derived, column: usize) Error!V.Cell {
            const id = derived.defaults[column];
            if (id == none) return .null_value;
            var sub = ctx.*;
            sub.source = table.columns[column].expression.slice();
            sub.row = null;
            return E.eval(&sub, id);
        }

        fn isDefault(ctx: *const E.Context, id: u16) bool {
            return id == none or ctx.pool.nodes[id].kind == .default_value;
        }

        /// Stored generated columns, computed from the new row after every
        /// other column (PostgreSQL ExecComputeStoredGenerated).
        fn computeGenerated(ctx: *const E.Context, table: *const S.Table, derived: Derived, cells: *E.Row) Error!void {
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                const id = derived.generated[index];
                if (id == none) continue;
                var sub = ctx.*;
                sub.source = column.expression.slice();
                sub.row = cells;
                const evaluated = try E.eval(&sub, id);
                cells[index] = try store(column, evaluated, ctx.session);
            }
        }

        /// `values[c]` none or a default_value node takes the column default.
        pub fn insertedRow(ctx: *E.Context, table: *const S.Table, values: *const [config.columns]u16, derived: Derived) Error!E.Row {
            var cells: E.Row = @splat(.null_value);
            ctx.row = null;
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                if (column.default_kind == .generated) continue;
                const evaluated: V.Cell = if (isDefault(ctx, values[index])) try defaultCell(ctx, table, derived, index) else try E.eval(ctx, values[index]);
                cells[index] = try store(column, evaluated, ctx.session);
            }
            try computeGenerated(ctx, table, derived, &cells);
            return cells;
        }

        /// Every SET expression sees the old row, never a partly updated one.
        pub fn updatedRow(ctx: *E.Context, table: *const S.Table, values: *const [config.columns]u16, derived: Derived, old: *const E.Row) Error!E.Row {
            var cells = old.*;
            ctx.row = old;
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                if (values[index] == none or column.default_kind == .generated) continue;
                const evaluated: V.Cell = if (isDefault(ctx, values[index])) try defaultCell(ctx, table, derived, index) else try E.eval(ctx, values[index]);
                cells[index] = try store(column, evaluated, ctx.session);
            }
            try computeGenerated(ctx, table, derived, &cells);
            ctx.row = old;
            return cells;
        }

        pub const KeyState = union(enum) { free, taken, wait: u16 };

        /// Unique-index check against the newest state, like PostgreSQL's
        /// dirty snapshot: a key is taken by a committed live row, or by a
        /// version the snapshot's own transaction created and still holds;
        /// a version created or deleted by another live transaction means
        /// the inserter must wait for that transaction (`wait`).
        pub fn keyCheck(table: *const S.Table, key: *const V.Cell, own_slot: u32, snap: storage.Snapshot) KeyState {
            const column = table.primary_column orelse return .free;
            if (key.* == .null_value) return .free;
            var waiting: ?u16 = null;
            var position = V.hash(key) & (S.key_index_capacity - 1);
            while (true) : (position = (position + 1) & (S.key_index_capacity - 1)) {
                const entry = table.key_index[position];
                if (entry == 0) break;
                const version = &table.versions[entry - 1];
                if (V.compare(&version.cells[column], key) != 0) continue;
                if (version.row - 1 == own_slot) continue;
                const marked = version.xmax.epoch != 0;
                if (version.xmin_csn == 0) {
                    if (snap.own(version.xmin)) {
                        if (marked and snap.own(version.xmax)) continue;
                        return .taken;
                    }
                    // Another live inserter; a version it replaced itself is
                    // superseded by a newer indexed version.
                    if (!marked and waiting == null) waiting = version.xmin.slot;
                    continue;
                }
                if (!marked) return .taken;
                if (version.xmax_csn != 0 or snap.own(version.xmax)) continue;
                if (waiting == null) waiting = version.xmax.slot;
            }
            return if (waiting) |slot| .{ .wait = slot } else .free;
        }
    };
}
