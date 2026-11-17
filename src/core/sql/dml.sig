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

        /// Bound column defaults and generation expressions (binder), and the
        /// table's CHECK constraints by constraint index (null: none bound).
        pub const Derived = struct {
            defaults: *const [config.columns]u16,
            generated: *const [config.columns]u16,
            checks: ?*const [config.table_constraints]u16 = null,
        };

        /// The bound CHECK constraints over an existing row (ALTER TABLE).
        pub fn checkRow(ctx: *const E.Context, table: *const S.Table, checks: *const [config.table_constraints]u16, cells: *const E.Row) Error!void {
            const empty: [config.columns]u16 = @splat(none);
            return checkConstraints(ctx, table, .{ .defaults = &empty, .generated = &empty, .checks = checks }, cells);
        }

        /// PostgreSQL ExecConstraints after NOT NULL: a CHECK that yields
        /// FALSE rejects the row (23514); NULL satisfies it.
        fn checkConstraints(ctx: *const E.Context, table: *const S.Table, derived: Derived, cells: *const E.Row) Error!void {
            const checks = derived.checks orelse return;
            for (table.constraints[0..table.constraint_count], 0..) |*constraint, index| {
                if (constraint.kind != .check) continue;
                const id = checks[index];
                if (id == none) continue;
                var sub = ctx.*;
                sub.source = constraint.expression.slice();
                sub.row = cells;
                const verdict = try E.eval(&sub, id);
                if (verdict == .boolean and !verdict.boolean) return error.CheckViolation;
            }
        }

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
            try checkConstraints(ctx, table, derived, &cells);
            return cells;
        }

        /// COPY FROM: `provided[c]` holds column c's input-function value;
        /// null takes the column default. Stored like an INSERT value
        /// (typmod, NOT NULL, ranges), then generated columns are computed.
        pub fn copiedRow(ctx: *E.Context, table: *const S.Table, provided: *const [config.columns]?V.Cell, derived: Derived) Error!E.Row {
            var cells: E.Row = @splat(.null_value);
            ctx.row = null;
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                if (column.default_kind == .generated) continue;
                const evaluated: V.Cell = if (provided[index]) |cell| cell else try defaultCell(ctx, table, derived, index);
                cells[index] = try store(column, evaluated, ctx.session);
            }
            try computeGenerated(ctx, table, derived, &cells);
            try checkConstraints(ctx, table, derived, &cells);
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
            try checkConstraints(ctx, table, derived, &cells);
            ctx.row = old;
            return cells;
        }

        // ---- rows with BEFORE triggers or rules (B11 wave 3) -------------

        /// store() without the NOT NULL check, which PostgreSQL applies
        /// after BEFORE ROW triggers (ExecConstraints).
        pub fn storeRelaxed(column: *const V.Column, evaluated: V.Cell, session: *const value.Session) Error!V.Cell {
            var relaxed = column.*;
            relaxed.not_null = false;
            return store(&relaxed, evaluated, session);
        }

        /// insertedRow up to the BEFORE ROW triggers: values and defaults
        /// stored, NOT NULL, generated columns and CHECKs left to finishRow.
        pub fn insertedRowDeferred(ctx: *E.Context, table: *const S.Table, values: *const [config.columns]u16, derived: Derived) Error!E.Row {
            var cells: E.Row = @splat(.null_value);
            ctx.row = null;
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                if (column.default_kind == .generated) continue;
                const evaluated: V.Cell = if (isDefault(ctx, values[index])) try defaultCell(ctx, table, derived, index) else try E.eval(ctx, values[index]);
                cells[index] = try storeRelaxed(column, evaluated, ctx.session);
            }
            return cells;
        }

        /// updatedRow up to the BEFORE ROW triggers (see insertedRowDeferred).
        pub fn updatedRowDeferred(ctx: *E.Context, table: *const S.Table, values: *const [config.columns]u16, derived: Derived, old: *const E.Row) Error!E.Row {
            var cells = old.*;
            ctx.row = old;
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                if (values[index] == none or column.default_kind == .generated) continue;
                const evaluated: V.Cell = if (isDefault(ctx, values[index])) try defaultCell(ctx, table, derived, index) else try E.eval(ctx, values[index]);
                cells[index] = try storeRelaxed(column, evaluated, ctx.session);
            }
            ctx.row = old;
            return cells;
        }

        /// After the BEFORE ROW triggers: NOT NULL, stored generated
        /// columns, then CHECK constraints (PostgreSQL's order).
        pub fn finishRow(ctx: *const E.Context, table: *const S.Table, derived: Derived, cells: *E.Row) Error!void {
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                if (column.default_kind == .generated) continue;
                if (cells[index] == .null_value and column.not_null) return error.NotNullViolation;
            }
            try computeGenerated(ctx, table, derived, cells);
            try checkConstraints(ctx, table, derived, cells);
        }
    };
}
