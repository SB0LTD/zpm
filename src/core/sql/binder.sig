//! Name resolution and typing (Layer 0). Binds a parsed statement against the
//! committed catalog without executing it, so describe() never mutates data.
//! Bound statements own copies of every identifier and literal; they do not
//! borrow the source after binding.
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const ast = @import("ast.sig");
const storage = @import("storage.sig");
const Error = types.Error;

pub fn Binder(comptime config: types.Config) type {
    const V = types.Values(config);
    const Ast = ast.Ast(config);
    const S = storage.Storage(config);
    return struct {
        pub const integer_type: types.DataType = if (config.integer_bits == 32) .integer32 else .integer;

        pub const Predicate = struct {
            column: usize = 0,
            op: ast.Operator = .equal,
            value: V.Cell = .null_value,
        };

        pub const Filter = struct {
            items: [config.predicates]Predicate = undefined,
            len: usize = 0,
        };

        pub const Create = struct {
            name: V.Name,
            columns: [config.columns]V.Column,
            count: usize,
        };

        pub const Insert = struct { table: usize, row: V.Row };

        pub const Select = struct {
            table: usize,
            projection: [config.columns]usize,
            count: usize,
            where: Filter,
            order_column: ?usize,
            descending: bool,
            nulls_first: ?bool,
            limit: u64,
        };

        pub const Update = struct {
            table: usize,
            assignments: V.Row,
            assigned: [config.columns]bool,
            where: Filter,
        };

        pub const Delete = struct { table: usize, where: Filter };

        pub const Bound = union(enum) {
            create_table: Create,
            drop_table: usize,
            insert: Insert,
            select: Select,
            update: Update,
            delete: Delete,
            begin: void,
            commit: void,
            rollback: void,
        };

        pub const Context = struct {
            source: []const u8,
            tables: *const [config.tables]S.Table,
            pool: *const Ast.Pool,
            boolean_integers: bool,
        };

        pub fn command(bound: *const Bound) types.CommandTag {
            return switch (bound.*) {
                .create_table => .create_table,
                .drop_table => .drop_table,
                .insert => .insert,
                .select => .select,
                .update => .update,
                .delete => .delete,
                .begin => .begin,
                .commit => .commit,
                .rollback => .rollback,
            };
        }

        fn toName(context: *const Context, span: ast.Span) V.Name {
            var out: V.Name = .{ .len = span.len };
            for (span.slice(context.source), 0..) |byte, index| out.bytes[index] = types.lower(byte);
            return out;
        }

        /// Committed catalog lookup; a pending CREATE is not yet visible.
        pub fn tableIndex(tables: *const [config.tables]S.Table, wanted: []const u8) Error!usize {
            for (tables, 0..) |*table, index|
                if (table.live and types.same(table.name.slice(), wanted)) return index;
            return error.TableNotFound;
        }

        fn resolveTable(context: *const Context, span: ast.Span) Error!usize {
            const wanted = toName(context, span);
            return tableIndex(context.tables, wanted.slice());
        }

        fn columnIndex(context: *const Context, entry: *const S.Table, span: ast.Span) Error!usize {
            const wanted = toName(context, span);
            for (entry.columns[0..entry.column_count], 0..) |*column, index|
                if (types.same(column.name.slice(), wanted.slice())) return index;
            return error.ColumnNotFound;
        }

        fn toCell(context: *const Context, literal: ast.Literal) V.Cell {
            return switch (literal) {
                .null_value => .null_value,
                .integer => |value| .{ .integer = value },
                .boolean => |value| .{ .boolean = value },
                .text => |quoted| blk: {
                    var text: V.Text = .{ .len = quoted.len };
                    lexer.decodeQuoted(context.source, quoted, &text.bytes);
                    break :blk .{ .text = text };
                },
            };
        }

        fn bindFilter(context: *const Context, entry: *const S.Table, root: ?u16) Error!Filter {
            var out: Filter = .{};
            const top = root orelse return out;
            // Left-deep AND tree: walk the spine iteratively (no recursion),
            // then emit predicates in source order.
            var count: usize = 1;
            var node = top;
            while (context.pool.nodes[node].kind == .conjunction) : (node = context.pool.nodes[node].left) count += 1;
            if (count > config.predicates) return error.PredicateCapacity;
            var leaves: [config.predicates]u16 = undefined;
            var position = count;
            node = top;
            while (true) {
                const current = &context.pool.nodes[node];
                position -= 1;
                leaves[position] = if (current.kind == .conjunction) current.right else node;
                if (current.kind != .conjunction) break;
                node = current.left;
            }
            out.len = count;
            // Resolve and type in source order, matching historical errors.
            for (leaves[0..count], 0..) |leaf_index, index| {
                const leaf = &context.pool.nodes[leaf_index];
                const predicate = &out.items[index];
                predicate.* = .{ .op = leaf.op, .value = toCell(context, leaf.value) };
                predicate.column = try columnIndex(context, entry, leaf.column);
                if (predicate.op == .is_null or predicate.op == .is_not_null) continue;
                if (predicate.value != .null_value) {
                    var column = entry.columns[predicate.column];
                    column.not_null = false;
                    // PostgreSQL promotes out-of-range comparison constants;
                    // range enforcement belongs to assignment, not WHERE.
                    if (column.data_type == .integer32) column.data_type = .integer;
                    try V.validate(&column, &predicate.value, context.boolean_integers);
                }
            }
            return out;
        }

        pub fn bind(context: *const Context, statement: *const Ast.Statement) Error!Bound {
            switch (statement.*) {
                .create_table => |*create| {
                    const table_name = toName(context, create.name);
                    for (context.tables) |*entry|
                        if (entry.live and types.same(entry.name.slice(), table_name.slice())) return error.TableExists;
                    var out: Create = .{ .name = table_name, .columns = @splat(.{}), .count = create.count };
                    for (create.columns[0..create.count], 0..) |*definition, index| {
                        var column: V.Column = .{ .name = toName(context, definition.name), .not_null = definition.not_null, .primary_key = definition.primary_key };
                        for (out.columns[0..index]) |*previous|
                            if (types.same(previous.name.slice(), column.name.slice())) return error.DuplicateColumn;
                        column.data_type = switch (definition.type_name) {
                            .integer => integer_type,
                            .bigint => .integer,
                            .boolean => .boolean,
                            .text => .text,
                        };
                        out.columns[index] = column;
                    }
                    return .{ .create_table = out };
                },
                .drop_table => |span| return .{ .drop_table = try resolveTable(context, span) },
                .insert => |*insert| {
                    const index = try resolveTable(context, insert.table);
                    const entry = &context.tables[index];
                    var mapping: [config.columns]usize = @splat(0);
                    var mapped: [config.columns]bool = @splat(false);
                    var count: usize = 0;
                    if (insert.explicit_columns) {
                        for (insert.columns[0..insert.column_count]) |span| {
                            const column = try columnIndex(context, entry, span);
                            if (mapped[column]) return error.DuplicateColumn;
                            mapping[count] = column;
                            mapped[column] = true;
                            count += 1;
                        }
                    } else {
                        count = entry.column_count;
                        for (0..count) |column| mapping[column] = column;
                    }
                    if (insert.value_count != count) return error.Syntax;
                    var out: Insert = .{ .table = index, .row = .{} };
                    for (0..count) |position| out.row.cells[mapping[position]] = toCell(context, insert.values[position]);
                    for (entry.columns[0..entry.column_count], 0..) |*column, position|
                        try V.validate(column, &out.row.cells[position], context.boolean_integers);
                    return .{ .insert = out };
                },
                .select => |*select| {
                    const index = try resolveTable(context, select.table);
                    const entry = &context.tables[index];
                    var out: Select = .{ .table = index, .projection = @splat(0), .count = 0, .where = .{}, .order_column = null, .descending = false, .nulls_first = null, .limit = select.limit };
                    if (select.all) {
                        out.count = entry.column_count;
                        for (0..out.count) |column| out.projection[column] = column;
                    } else {
                        out.count = select.count;
                        for (select.targets[0..select.count], 0..) |span, position| out.projection[position] = try columnIndex(context, entry, span);
                    }
                    out.where = try bindFilter(context, entry, select.where);
                    if (select.order) |order| {
                        out.order_column = try columnIndex(context, entry, order.column);
                        out.descending = order.descending;
                        out.nulls_first = order.nulls_first;
                    }
                    return .{ .select = out };
                },
                .update => |*update| {
                    const index = try resolveTable(context, update.table);
                    const entry = &context.tables[index];
                    var out: Update = .{ .table = index, .assignments = .{}, .assigned = @splat(false), .where = .{} };
                    for (update.assignments[0..update.count]) |*assignment| {
                        const column = try columnIndex(context, entry, assignment.column);
                        if (out.assigned[column]) return error.DuplicateColumn;
                        out.assignments.cells[column] = toCell(context, assignment.value);
                        try V.validate(&entry.columns[column], &out.assignments.cells[column], context.boolean_integers);
                        out.assigned[column] = true;
                    }
                    out.where = try bindFilter(context, entry, update.where);
                    return .{ .update = out };
                },
                .delete => |*delete| {
                    const index = try resolveTable(context, delete.table);
                    return .{ .delete = .{ .table = index, .where = try bindFilter(context, &context.tables[index], delete.where) } };
                },
                .begin => return .begin,
                .commit => return .commit,
                .rollback => return .rollback,
            }
        }
    };
}
