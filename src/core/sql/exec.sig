//! Query execution (Layer 0, design §4.9): candidate scans with the
//! primary-key probe, WHERE filters, projections and ORDER BY over typed
//! expressions. A failing SELECT leaves the caller's result untouched: every
//! fallible evaluation completes before the first result byte is written.
const types = @import("types.sig");
const ast = @import("ast.sig");
const storage = @import("storage.sig");
const expr = @import("expr.sig");
const binder = @import("binder.sig");
const Error = types.Error;
const none = ast.none;

pub fn Exec(comptime config: types.Config) type {
    const V = types.Values(config);
    const S = storage.Storage(config);
    const E = expr.Eval(config);
    const B = binder.Binder(config);
    const Ast = ast.Ast(config);
    return struct {
        pub const Candidates = union(enum) { scan, empty, slot: u32 };

        /// WHERE keeps a row only when the predicate is TRUE.
        pub fn keep(ctx: *E.Context, where: u16, row: ?*const E.Row) Error!bool {
            if (where == none) return true;
            ctx.row = row;
            return (try E.truth(ctx, where)) == true;
        }

        /// Evaluates a top-level `pk = constant` once and probes the index.
        pub fn candidates(ctx: *E.Context, table: *const S.Table, key: u16) Error!Candidates {
            if (key == none) return .scan;
            ctx.row = null;
            const value = try E.eval(ctx, key);
            if (value == .null_value) return .empty;
            const slot = S.lookupKey(table, &value) orelse return .empty;
            return .{ .slot = slot };
        }

        fn simple(pool: *const Ast.Pool, id: u16) bool {
            return pool.nodes[id].kind == .column;
        }

        const Sorter = struct {
            ctx: *E.Context,
            table: *const S.Table,
            query: *const B.Select,

            fn order(self: *const Sorter, left: u32, right: u32) Error!i8 {
                for (self.query.order[0..self.query.order_count]) |*key| {
                    self.ctx.row = &self.table.versions[left].cells;
                    const a = try E.eval(self.ctx, key.expr);
                    self.ctx.row = &self.table.versions[right].cells;
                    const b = try E.eval(self.ctx, key.expr);
                    const nulls_first = key.nulls_first orelse (config.nulls_first_ascending != key.descending);
                    const result: i8 = if (a == .null_value or b == .null_value) blk: {
                        if (a == .null_value and b == .null_value) break :blk 0;
                        break :blk if ((a == .null_value) == nulls_first) -1 else 1;
                    } else blk: {
                        const value = V.compare(&a, &b);
                        break :blk if (key.descending) -value else value;
                    };
                    if (result != 0) return result;
                }
                return 0;
            }

            /// Stable bottom-up merge sort over version indices.
            fn sort(self: *const Sorter, items: []u32) Error!void {
                var scratch: [config.rows_per_table]u32 = undefined;
                var width: usize = 1;
                var source = items;
                var target: []u32 = scratch[0..items.len];
                var in_scratch = false;
                while (width < items.len) : (width *= 2) {
                    var start: usize = 0;
                    while (start < items.len) : (start += 2 * width) {
                        const middle = @min(start + width, items.len);
                        const end = @min(start + 2 * width, items.len);
                        var i = start;
                        var j = middle;
                        var k = start;
                        while (i < middle and j < end) : (k += 1) {
                            if ((try self.order(source[j], source[i])) < 0) {
                                target[k] = source[j];
                                j += 1;
                            } else {
                                target[k] = source[i];
                                i += 1;
                            }
                        }
                        while (i < middle) : (k += 1) {
                            target[k] = source[i];
                            i += 1;
                        }
                        while (j < end) : (k += 1) {
                            target[k] = source[j];
                            j += 1;
                        }
                    }
                    const swap = source;
                    source = target;
                    target = swap;
                    in_scratch = !in_scratch;
                }
                if (in_scratch) @memcpy(items, source);
            }
        };

        pub fn select(tables: *const [config.tables]S.Table, source: []const u8, pool: *const Ast.Pool, query: *const B.Select, result: anytype) Error!void {
            var ctx: E.Context = .{ .source = source, .pool = pool };
            var plain = true;
            for (query.targets[0..query.count]) |id| plain = plain and simple(pool, id);
            if (query.table == null) {
                // No FROM: one row when WHERE holds and LIMIT allows it.
                var row: E.Row = undefined;
                var produced = false;
                if (query.limit != 0 and try keep(&ctx, query.where, null)) {
                    ctx.row = null;
                    for (query.targets[0..query.count], 0..) |id, column| row[column] = try E.eval(&ctx, id);
                    produced = true;
                }
                writeHeader(query, result);
                result.row_count = @intFromBool(produced);
                if (produced) @memcpy(result.rows[0].cells[0..query.count], row[0..query.count]);
                return;
            }
            const table = &tables[query.table.?];
            var indices: [config.rows_per_table]u32 = undefined;
            var found: usize = 0;
            if (query.limit != 0) switch (try candidates(&ctx, table, query.key)) {
                .empty => {},
                .slot => |slot| {
                    const version = S.visible(table, slot).?;
                    if (try keep(&ctx, query.where, &table.versions[version].cells)) {
                        indices[0] = version;
                        found = 1;
                    }
                },
                .scan => for (0..table.row_high) |slot| {
                    const version = S.visible(table, slot) orelse continue;
                    if (!try keep(&ctx, query.where, &table.versions[version].cells)) continue;
                    indices[found] = version;
                    found += 1;
                    if (query.order_count == 0 and found >= query.limit) break;
                },
            };
            if (query.order_count != 0 and found != 0) {
                // Sort keys are evaluated for every candidate row, so an
                // erroring key fails even when one row (or none) is compared.
                for (query.order[0..query.order_count]) |*key| if (!simple(pool, key.expr)) {
                    for (indices[0..found]) |version| {
                        ctx.row = &table.versions[version].cells;
                        _ = try E.eval(&ctx, key.expr);
                    }
                };
                const sorter: Sorter = .{ .ctx = &ctx, .table = table, .query = query };
                try sorter.sort(indices[0..found]);
            }
            const rows: usize = if (query.limit < found) @intCast(query.limit) else found;
            if (!plain) {
                // Validation pass: projections may fail; the result is untouched.
                for (indices[0..rows]) |version| {
                    ctx.row = &table.versions[version].cells;
                    for (query.targets[0..query.count]) |id| _ = try E.eval(&ctx, id);
                }
            }
            writeHeader(query, result);
            result.row_count = rows;
            for (0..rows) |row_index| {
                const cells = &table.versions[indices[row_index]].cells;
                ctx.row = cells;
                for (query.targets[0..query.count], 0..) |id, column| {
                    const n = &pool.nodes[id];
                    result.rows[row_index].cells[column] = if (n.kind == .column) cells[n.column] else E.eval(&ctx, id) catch unreachable;
                }
            }
        }

        fn writeHeader(query: *const B.Select, result: anytype) void {
            result.clear(0);
            result.command = .select;
            result.column_count = query.count;
            for (0..query.count) |index| {
                result.column_names[index] = query.names[index];
                result.column_types[index] = query.types[index];
            }
        }
    };
}
