//! Row construction for INSERT values and expression SET (Layer 0, design
//! §4.9). Expressions are evaluated against the old row (UPDATE) or no row
//! (INSERT), converted with assignment casts (int/boolean into text, MySQL/TDS
//! integer 0/1 into boolean) and checked (NOT NULL, int4 range). Primary-key
//! uniqueness is checked per row as PostgreSQL's immediate unique index
//! does: a key is taken by any committed row this statement has not already
//! replaced, or by a version this statement created.
const types = @import("types.sig");
const ast = @import("ast.sig");
const storage = @import("storage.sig");
const expr = @import("expr.sig");
const Error = types.Error;
const none = ast.none;

pub fn Dml(comptime config: types.Config) type {
    const V = types.Values(config);
    const S = storage.Storage(config);
    const E = expr.Eval(config);
    return struct {
        /// Converts an evaluated value into the column's stored form.
        pub fn store(column: *const V.Column, value: V.Cell) Error!V.Cell {
            var cell = value;
            switch (column.data_type) {
                .text => if (cell != .null_value and cell != .text) {
                    cell = try E.toText(&value, true);
                },
                .boolean => if (cell == .integer) {
                    // The binder admits integers here only for MySQL/TDS.
                    const integer = cell.integer;
                    if (integer != 0 and integer != 1) return error.TypeMismatch;
                    cell = .{ .boolean = integer == 1 };
                },
                .integer, .integer32 => {},
            }
            try V.validate(column, &cell);
            return cell;
        }

        pub fn insertedRow(ctx: *E.Context, table: *const S.Table, values: *const [config.columns]u16) Error!E.Row {
            var cells: E.Row = @splat(.null_value);
            ctx.row = null;
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                const value: V.Cell = if (values[index] == none) .null_value else try E.eval(ctx, values[index]);
                cells[index] = try store(column, value);
            }
            return cells;
        }

        /// Every SET expression sees the old row, never a partly updated one.
        pub fn updatedRow(ctx: *E.Context, table: *const S.Table, values: *const [config.columns]u16, old: *const E.Row) Error!E.Row {
            var cells = old.*;
            ctx.row = old;
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                if (values[index] == none) continue;
                cells[index] = try store(column, try E.eval(ctx, values[index]));
            }
            return cells;
        }

        pub fn keyTaken(table: *const S.Table, key: *const V.Cell, own_slot: u32) bool {
            const column = table.primary_column orelse return false;
            if (key.* == .null_value) return false;
            var position = V.hash(key) & (S.key_index_capacity - 1);
            while (true) : (position = (position + 1) & (S.key_index_capacity - 1)) {
                const entry = table.key_index[position];
                if (entry == 0) return false;
                const version = &table.versions[entry - 1];
                if (V.compare(&version.cells[column], key) != 0) continue;
                // A version this statement created holds the key.
                if (version.xmin_csn == 0) return true;
                const slot = version.row - 1;
                if (slot == own_slot or S.visible(table, slot) != entry - 1) continue;
                // A committed row this statement already replaced released it.
                if (version.xmax.epoch != 0 and version.xmax_csn == 0) continue;
                return true;
            }
        }
    };
}
