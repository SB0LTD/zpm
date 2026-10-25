//! Query execution (Layer 0, design §4.9): candidate scans with the
//! primary-key probe, WHERE filters, projections, ORDER BY and LockRows over
//! typed expressions, all under the statement snapshot. A failing SELECT
//! leaves the caller's result untouched: every fallible evaluation (and every
//! lock wait) completes before the first result byte is written.
const types = @import("types.sig");
const ast = @import("ast.sig");
const storage = @import("storage.sig");
const expr = @import("expr.sig");
const binder = @import("binder.sig");
const value_module = @import("value.sig");
const sort_module = @import("sort.sig");
const catalog = @import("catalog.sig");
const Error = types.Error;
const none = ast.none;

pub fn Exec(comptime config: types.Config) type {
    const V = types.Values(config);
    const S = storage.Storage(config);
    const E = expr.Eval(config);
    const B = binder.Binder(config);
    const Ast = ast.Ast(config);
    const Io = value_module.Io(config);
    return struct {
        pub const work_rows = types.workRows(config);
        pub const work_cells = work_rows * 2 * config.columns;
        pub const work_refs = work_rows * 4 * (config.relations + 4);
        const absent: u32 = 0xffffffff;
        const group_relation = B.group_relation;

        /// Row handles in Work.refs: cell offsets of materialized rows, or
        /// version indices of a base table's visible rows.
        pub const List = struct { start: u32 = 0, count: u32 = 0 };

        const Tuples = struct { start: u32, count: u32, width: u32 };

        const CteRun = struct {
            state: enum { idle, iterating, done } = .idle,
            rows: List = .{},
            working: List = .{},
        };

        const Cache = struct { valid: bool = false, rows: List = .{} };

        const Mark = struct { cells: usize, refs: usize };

        /// Per-statement evidence for the single-source streaming path. Counts
        /// include nested eligible plans; scratch figures are per-plan peaks.
        pub const StreamStats = struct {
            rows: usize = 0,
            groups: usize = 0,
            probes: usize = 0,
            scratch_cells: usize = 0,
            scratch_refs: usize = 0,
        };

        /// The statement's query workspace (design §4.9): caller-owned,
        /// uninitialized until a statement writes it. Scratch grows from the
        /// bottom and is released per correlated subquery evaluation;
        /// materialized CTEs and uncorrelated subquery results are copied
        /// to the top and live for the statement.
        pub const Work = struct {
            cells: [work_cells]V.Cell = undefined,
            cell_low: usize = 0,
            cell_high: usize = work_cells,
            refs: if (config.external_storage) []u32 else [work_refs]u32 = if (config.external_storage) &.{} else undefined,
            ref_low: usize = 0,
            ref_high: usize = if (config.external_storage) 0 else work_refs,
            ctes: [config.ctes]CteRun = undefined,
            cache: [config.subqueries]Cache = undefined,
            stream_stats: StreamStats = .{},
            /// System-view rows (catalog.sig View) for this statement; set by
            /// the Database before it runs a query (kept across resets).
            views: ?ViewHook = null,

            fn reset(self: *Work) void {
                self.cell_low = 0;
                self.cell_high = work_cells;
                self.ref_low = 0;
                self.ref_high = self.refs.len;
                self.stream_stats = .{};
                for (&self.ctes) |*cte| cte.* = .{};
                for (&self.cache) |*entry| entry.* = .{};
            }
        };

        /// Produces a system view's rows into the workspace at scan time.
        pub const ViewHook = struct {
            ptr: *anyopaque,
            rows: *const fn (ptr: *anyopaque, view: catalog.View, sink: *RowSink) Error!void,
        };

        /// Appends rows of `width` cells to a workspace row list.
        pub const RowSink = struct {
            query: *Query,
            list: List,
            width: usize,

            pub fn add(self: *RowSink, cells: []const V.Cell) Error!void {
                try self.query.session.checkpoint();
                std_assert(cells.len == self.width);
                const at = try self.query.cells(self.width);
                for (cells, 0..) |cell, index| self.query.work.cells[at + index] = cell;
                try self.query.push(&self.list, at);
            }
        };

        /// Executes a bound general query (joins, grouping, DISTINCT,
        /// subqueries, CTEs, set operations). Every row is computed in the
        /// workspace first; `result` is written only after success.
        pub const Query = struct {
            tables: *const [config.tables]S.Table,
            source: []const u8,
            pool: *const Ast.Pool,
            plans: *const B.Plans,
            snap: storage.Snapshot,
            session: *const value_module.Session,
            work: *Work,
            hook: E.Hook = undefined,

            fn mark(self: *const Query) Mark {
                return .{ .cells = self.work.cell_low, .refs = self.work.ref_low };
            }

            fn release(self: *Query, at: Mark) void {
                self.work.cell_low = at.cells;
                self.work.ref_low = at.refs;
            }

            fn cells(self: *Query, count: usize) Error!u32 {
                try self.session.checkpoint();
                const work = self.work;
                if (work.cell_high - work.cell_low < count) return error.WorkspaceCapacity;
                const at = work.cell_low;
                work.cell_low += count;
                return @intCast(at);
            }

            fn refs(self: *Query, count: usize) Error!u32 {
                const work = self.work;
                if (work.ref_high - work.ref_low < count) return error.WorkspaceCapacity;
                const at = work.ref_low;
                work.ref_low += count;
                return @intCast(at);
            }

            fn push(self: *Query, list: *List, handle: u32) Error!void {
                try self.session.checkpoint();
                const at = try self.refs(1);
                if (list.count == 0) list.start = at;
                std_assert(list.start + list.count == at);
                self.work.refs[at] = handle;
                list.count += 1;
            }

            fn handles(self: *const Query, list: List) []u32 {
                return self.work.refs[list.start..][0..list.count];
            }

            fn row(self: *const Query, offset: u32) [*]const V.Cell {
                return self.work.cells[offset..].ptr;
            }

            /// Copies `width` cells of every row to the persistent top.
            fn persist(self: *Query, list: List, width: usize) Error!List {
                const work = self.work;
                const cell_count = @as(usize, list.count) * width;
                if (work.cell_high - work.cell_low < cell_count or work.ref_high - work.ref_low < list.count) return error.WorkspaceCapacity;
                work.cell_high -= cell_count;
                work.ref_high -= list.count;
                const out: List = .{ .start = @intCast(work.ref_high), .count = list.count };
                for (self.handles(list), 0..) |offset, index| {
                    const at = work.cell_high + index * width;
                    for (0..width) |column| work.cells[at + column] = work.cells[offset + column];
                    work.refs[out.start + index] = @intCast(at);
                }
                return out;
            }

            fn concatPersistent(self: *Query, a: List, b: List) Error!List {
                const work = self.work;
                const total = @as(usize, a.count) + b.count;
                if (work.ref_high - work.ref_low < total) return error.WorkspaceCapacity;
                work.ref_high -= total;
                const out: List = .{ .start = @intCast(work.ref_high), .count = @intCast(total) };
                @memcpy(work.refs[out.start..][0..a.count], self.handles(a));
                @memcpy(work.refs[out.start + a.count ..][0..b.count], self.handles(b));
                return out;
            }

            fn context(self: *Query, outer: ?*const E.Context) E.Context {
                return .{ .source = self.source, .pool = self.pool, .session = self.session, .outer = outer, .hook = &self.hook };
            }

            pub fn run(self: *Query, plan_id: u16, outer: ?*const E.Context) Error!List {
                const p = &self.plans.items[plan_id];
                if (p.set_op != .none) return self.setOperation(p, outer);
                return self.core(p, outer);
            }

            // ---- FROM items and joins ----------------------------------

            fn sourceRows(self: *Query, source: *const B.Source, outer: ?*const E.Context) Error!List {
                if (source.table) |index| {
                    const table = &self.tables[index];
                    var list: List = .{ .start = @intCast(self.work.ref_low) };
                    for (0..table.row_high) |slot| {
                        try self.session.checkpoint();
                        const version = S.visibleAt(table, slot, self.snap) orelse continue;
                        try self.push(&list, version);
                    }
                    return list;
                }
                if (source.cte != B.no_cte) return self.materializeCte(source.cte, outer);
                if (source.view) |view| {
                    const hook = self.work.views orelse return error.UnsupportedStatement;
                    var sink: RowSink = .{ .query = self, .list = .{ .start = @intCast(self.work.ref_low) }, .width = catalog.viewColumns(view).len };
                    try hook.rows(hook.ptr, view, &sink);
                    return sink.list;
                }
                return self.run(source.plan, outer);
            }

            fn rowOf(self: *const Query, source: *const B.Source, handle: u32) [*]const V.Cell {
                if (source.table) |index| return &self.tables[index].versions[handle].cells;
                return self.row(handle);
            }

            fn setTuple(self: *const Query, p: *const B.Plan, ctx: *E.Context, tuples: Tuples, index: usize) void {
                const base = tuples.start + index * tuples.width;
                for (0..tuples.width) |position| {
                    const handle = self.work.refs[base + position];
                    ctx.tuple[position] = if (handle == absent) null else self.rowOf(&p.sources[position], handle);
                }
            }

            fn emit(self: *Query, out: *Tuples, previous: Tuples, index: ?usize, handle: u32) Error!void {
                try self.session.checkpoint();
                const at = try self.refs(out.width);
                if (out.count == 0) out.start = at;
                std_assert(out.start + out.count * out.width == at);
                for (0..previous.width) |position| {
                    self.work.refs[at + position] = if (index) |i| self.work.refs[previous.start + i * previous.width + position] else absent;
                }
                self.work.refs[at + previous.width] = handle;
                out.count += 1;
            }

            /// Left-deep nested loops; the WHERE clause filters the last stage.
            fn join(self: *Query, p: *const B.Plan, outer: ?*const E.Context) Error!Tuples {
                var ctx = self.context(outer);
                if (p.source_count == 0) {
                    const kept = try keep(&ctx, p.where, null);
                    return .{ .start = @intCast(self.work.ref_low), .count = @intFromBool(kept), .width = 0 };
                }
                var current: Tuples = .{ .start = @intCast(self.work.ref_low), .count = 1, .width = 0 };
                for (p.sources[0..p.source_count], 0..) |*source, stage| {
                    const last = stage + 1 == p.source_count;
                    const probing = source.probe != none and stage != 0;
                    const rows: List = if (probing) .{} else try self.sourceRows(source, outer);
                    const outer_join = source.join == .left or source.join == .full;
                    const tracks = source.join == .right or source.join == .full;
                    var matched: u32 = 0;
                    if (tracks) {
                        matched = try self.refs(rows.count);
                        @memset(self.work.refs[matched..][0..rows.count], 0);
                    }
                    var next: Tuples = .{ .start = @intCast(self.work.ref_low), .count = 0, .width = @intCast(stage + 1) };
                    for (0..current.count) |index| {
                        self.setTuple(p, &ctx, current, index);
                        var any = false;
                        if (probing) {
                            ctx.row = null;
                            const key = try E.eval(&ctx, source.probe);
                            if (key != .null_value) {
                                const table = &self.tables[source.table.?];
                                if (S.lookupKeyAt(table, &key, self.snap)) |slot| if (S.visibleAt(table, slot, self.snap)) |version| {
                                    ctx.tuple[stage] = &table.versions[version].cells;
                                    if (source.on == none or (try E.truth(&ctx, source.on)) == true) {
                                        any = true;
                                        if (!last or try keep(&ctx, p.where, null)) try self.emit(&next, current, index, version);
                                    }
                                };
                            }
                        } else for (self.handles(rows), 0..) |handle, position| {
                            try self.session.checkpoint();
                            ctx.tuple[stage] = self.rowOf(source, handle);
                            if (stage != 0 and source.on != none and (try E.truth(&ctx, source.on)) != true) continue;
                            any = true;
                            if (tracks) self.work.refs[matched + position] = 1;
                            if (!last or try keep(&ctx, p.where, null)) try self.emit(&next, current, index, handle);
                        }
                        if (!any and outer_join) {
                            ctx.tuple[stage] = null;
                            if (!last or try keep(&ctx, p.where, null)) try self.emit(&next, current, index, absent);
                        }
                    }
                    if (tracks) {
                        for (self.handles(rows), 0..) |handle, position| {
                            if (self.work.refs[matched + position] != 0) continue;
                            for (0..stage) |slot| ctx.tuple[slot] = null;
                            ctx.tuple[stage] = self.rowOf(source, handle);
                            if (!last or try keep(&ctx, p.where, null)) try self.emit(&next, current, null, handle);
                        }
                    }
                    current = next;
                }
                return current;
            }

            // ---- projection and grouping -------------------------------

            fn projectRow(self: *Query, p: *const B.Plan, ctx: *E.Context, out: *List) Error!void {
                const at = try self.cells(p.width);
                for (p.targets[0..p.width], 0..) |id, column| {
                    const value = try E.eval(ctx, id);
                    self.work.cells[at + column] = value;
                }
                try self.push(out, at);
            }

            fn project(self: *Query, p: *const B.Plan, tuples: Tuples, outer: ?*const E.Context) Error!List {
                var ctx = self.context(outer);
                var out: List = .{ .start = @intCast(self.work.ref_low) };
                // Without sorting, stop once OFFSET + LIMIT rows exist.
                const lazy = p.order_count == 0 and p.distinct == .none;
                const wanted: u64 = if (p.limit > 0xffffffffffffffff - p.offset) 0xffffffffffffffff else p.offset + p.limit;
                for (0..tuples.count) |index| {
                    if (lazy and out.count >= wanted) break;
                    self.setTuple(p, &ctx, tuples, index);
                    try self.projectRow(p, &ctx, &out);
                }
                return out;
            }

            const KeySorter = struct {
                query: *const Query,
                base: u32,
                width: u32,
                count: u32,

                pub fn order(self: *const KeySorter, a: u32, b: u32) Error!i8 {
                    try self.query.session.checkpoint();
                    const work = self.query.work;
                    for (0..self.count) |column| {
                        const result = V.compare(&work.cells[self.base + a * self.width + column], &work.cells[self.base + b * self.width + column]);
                        if (result != 0) return result;
                    }
                    return 0;
                }
            };

            fn sameKeys(self: *const Query, base: u32, width: u32, a: u32, b: u32) bool {
                for (0..width) |column| {
                    if (V.compare(&self.work.cells[base + a * width + column], &self.work.cells[base + b * width + column]) != 0) return false;
                }
                return true;
            }

            /// Sort-based grouping: keys are evaluated once per input row,
            /// row indices are merge-sorted by key, and each run of equal keys
            /// (NULLs equal) is one group. Without GROUP BY there is exactly
            /// one group, even over no rows.
            fn group(self: *Query, p: *const B.Plan, tuples: Tuples, outer: ?*const E.Context) Error!List {
                var ctx = self.context(outer);
                const n = tuples.count;
                const key_width: u32 = @intCast(p.key_count);
                const keys = try self.cells(@as(usize, n) * key_width);
                for (0..n) |index| {
                    self.setTuple(p, &ctx, tuples, index);
                    for (p.keys[0..p.key_count], 0..) |key, column| self.work.cells[keys + index * key_width + column] = try E.eval(&ctx, key);
                }
                const order = try self.refs(n);
                for (0..n) |index| self.work.refs[order + index] = @intCast(index);
                if (key_width != 0) {
                    const scratch = try self.refs(n);
                    const sorter: KeySorter = .{ .query = self, .base = keys, .width = key_width, .count = key_width };
                    _ = try sort_module.mergeSort(self.work.refs[order..][0..n], self.work.refs[scratch..][0..n], &sorter);
                }
                const lazy = p.order_count == 0 and p.distinct == .none;
                const wanted: u64 = if (p.limit > 0xffffffffffffffff - p.offset) 0xffffffffffffffff else p.offset + p.limit;
                var out: List = .{ .start = @intCast(self.work.ref_low) };
                var first: usize = 0;
                while (first < n or (first == 0 and key_width == 0)) {
                    if (lazy and out.count >= wanted) break;
                    var end = first + 1;
                    if (key_width == 0) {
                        end = n;
                    } else while (end < n and self.sameKeys(keys, key_width, self.work.refs[order + first], self.work.refs[order + end])) end += 1;
                    const group_row = try self.cells(p.key_count + p.agg_count);
                    if (key_width != 0) {
                        const source_row = keys + self.work.refs[order + first] * key_width;
                        for (0..p.key_count) |column| self.work.cells[group_row + column] = self.work.cells[source_row + column];
                    }
                    for (p.aggs[0..p.agg_count], 0..) |*agg, index| {
                        self.work.cells[group_row + p.key_count + index] = try self.aggregate(p, agg, tuples, order, first, end, outer);
                    }
                    var group_ctx = self.context(outer);
                    group_ctx.tuple[group_relation] = self.row(group_row);
                    if (try keep(&group_ctx, p.having, null)) try self.projectRow(p, &group_ctx, &out);
                    first = end;
                    if (key_width == 0) break;
                }
                return out;
            }

            const Accumulator = struct {
                count: i64 = 0,
                integer: i64 = 0,
                // Workspace Cell slots need not have the native i128 alignment.
                // Declare the actual alignment instead of promising an aligned
                // pointer to borrowed bytes that may only be 8-byte aligned.
                wide: i128 align(@alignOf(V.Cell)) = 0,
                value: V.Cell = .null_value,
                flag: ?bool = null,
                /// AVG(float): PostgreSQL float8_accum's Sx and Sxx.
                sx: f64 = 0,
                sxx: f64 = 0,
            };

            /// Accumulators borrow whole Cell slots from the existing workspace.
            /// No second arena, heap, input-sized handle list or per-row Cell
            /// is needed. These reserved bytes are never read as tagged Cells.
            fn accumulatorCells(count: usize) usize {
                return (count * @sizeOf(Accumulator) + @sizeOf(V.Cell) - 1) / @sizeOf(V.Cell);
            }

            fn accumulators(self: *Query, at: u32, count: usize) []Accumulator {
                comptime {
                    if (@alignOf(Accumulator) > @alignOf(V.Cell)) @compileError("SQL workspace must align aggregate states");
                }
                const ptr: [*]Accumulator = @ptrCast(@alignCast(&self.work.cells[at]));
                return ptr[0..count];
            }

            fn streamEligible(p: *const B.Plan) bool {
                if (!p.grouped or p.source_count != 1 or p.sources[0].table == null) return false;
                // DISTINCT requires separate per-aggregate distinct-value state.
                for (p.aggs[0..p.agg_count]) |agg| if (agg.distinct) return false;
                // Keep the existing lazy evaluation contract for finite LIMITs.
                if (p.limit != 0xffffffffffffffff and p.order_count == 0 and p.distinct == .none) {
                    if (p.key_count != 0 or (p.limit == 0 and p.offset == 0)) return false;
                }
                return true;
            }

            /// A base-column input can be borrowed for this synchronous step;
            /// no whole tagged union copy is needed to read an integer or key.
            /// Computed/correlated expressions retain the ordinary evaluator.
            fn streamInput(self: *Query, ctx: *E.Context, id: u16, temporary: *V.Cell) Error!*const V.Cell {
                const node = &self.pool.nodes[id];
                if (node.kind == .column and node.level == 0 and node.relation == 0) return &ctx.tuple[0].?[node.column];
                temporary.* = try E.eval(ctx, id);
                return temporary;
            }

            fn addAggregates(self: *Query, p: *const B.Plan, ctx: *E.Context, states: []Accumulator) Error!void {
                for (p.aggs[0..p.agg_count], states) |*agg, *acc| {
                    if (agg.filter != none and (try E.truth(ctx, agg.filter)) != true) continue;
                    if (agg.kind == .count_star) {
                        acc.count += 1;
                    } else {
                        var temporary: V.Cell = undefined;
                        const input = try self.streamInput(ctx, agg.arg, &temporary);
                        if (input.* != .null_value) try self.accumulate(agg, acc, input);
                    }
                }
            }

            fn projectGroup(self: *Query, p: *const B.Plan, at: u32, states: []const Accumulator, outer: ?*const E.Context, out: *List) Error!void {
                for (p.aggs[0..p.agg_count], states, 0..) |*agg, *acc, index| {
                    self.work.cells[at + p.key_count + index] = try self.finishAggregate(agg, acc);
                }
                var ctx = self.context(outer);
                ctx.tuple[group_relation] = self.row(at);
                if (try keep(&ctx, p.having, null)) try self.projectRow(p, &ctx, out);
            }

            const GroupSorter = struct {
                query: *const Query,
                width: usize,
                pub fn order(self: *const GroupSorter, a: u32, b: u32) Error!i8 {
                    try self.query.session.checkpoint();
                    for (0..self.width) |column| {
                        const compared = V.compare(&self.query.work.cells[a + column], &self.query.work.cells[b + column]);
                        if (compared != 0) return compared;
                    }
                    return 0;
                }
            };

            /// Consume visible base-table versions directly. State grows with
            /// groups, not scanned rows. All output remains private until the
            /// ordinary query publication step succeeds.
            fn streamGroup(self: *Query, p: *const B.Plan, outer: ?*const E.Context) Error!List {
                const table = &self.tables[p.sources[0].table.?];
                var ctx = self.context(outer);
                var out: List = .{};
                if (p.key_count == 0) {
                    var states: [config.columns]Accumulator = undefined;
                    for (states[0..p.agg_count]) |*state| state.* = .{};
                    for (0..table.row_high) |slot| {
                        try self.session.checkpoint();
                        const version = S.visibleAt(table, slot, self.snap) orelse continue;
                        self.work.stream_stats.rows += 1;
                        ctx.tuple[0] = &table.versions[version].cells;
                        if (try keep(&ctx, p.where, null)) try self.addAggregates(p, &ctx, states[0..p.agg_count]);
                    }
                    const at = try self.cells(p.agg_count);
                    try self.projectGroup(p, at, states[0..p.agg_count], outer, &out);
                    self.work.stream_stats.groups += 1;
                    self.work.stream_stats.scratch_cells = @max(self.work.stream_stats.scratch_cells, p.agg_count);
                    return self.finish(p, out);
                }

                const state_cells = accumulatorCells(p.agg_count);
                const record_cells = p.key_count + p.agg_count + state_cells;
                // Leave room for projection as well as group state. Ref budget
                // covers rounded buckets, tickets, group sorting and final sort.
                const cell_budget = self.work.cell_high - self.work.cell_low;
                const ref_budget = self.work.ref_high - self.work.ref_low;
                const capacity = @min(cell_budget / (record_cells + p.width), ref_budget / 8);
                var slots: usize = 2;
                while (slots < capacity * 2) slots *= 2;
                var buckets: u32 = undefined;
                var tickets: u32 = undefined;
                var groups: usize = 0;
                var computed_keys: [config.columns]V.Cell = undefined;
                var keys: [config.columns]*const V.Cell = undefined;
                for (0..table.row_high) |slot| {
                    try self.session.checkpoint();
                    const version = S.visibleAt(table, slot, self.snap) orelse continue;
                    self.work.stream_stats.rows += 1;
                    ctx.tuple[0] = &table.versions[version].cells;
                    if (!try keep(&ctx, p.where, null)) continue;
                    if (groups == 0) {
                        if (capacity == 0) return error.WorkspaceCapacity;
                        buckets = try self.refs(slots);
                        @memset(self.work.refs[buckets..][0..slots], absent);
                        tickets = try self.refs(capacity);
                    }
                    var code: usize = 2166136261;
                    for (p.keys[0..p.key_count], 0..) |key, column| {
                        keys[column] = try self.streamInput(&ctx, key, &computed_keys[column]);
                        // V.hash deliberately rejects NULL (PK users exclude it).
                        const hash: usize = if (keys[column].* == .null_value) 0x9e3779b9 else V.hash(keys[column]);
                        code = (code ^ hash) *% 16777619;
                    }
                    var bucket = code & (slots - 1);
                    var at: u32 = undefined;
                    while (true) {
                        try self.session.checkpoint();
                        self.work.stream_stats.probes += 1;
                        const found = self.work.refs[buckets + bucket];
                        if (found == absent) {
                            if (groups == capacity) return error.WorkspaceCapacity;
                            at = try self.cells(record_cells);
                            for (keys[0..p.key_count], 0..) |key, column| self.work.cells[at + column] = key.*;
                            for (self.accumulators(at + @as(u32, @intCast(p.key_count + p.agg_count)), p.agg_count)) |*state| state.* = .{};
                            self.work.refs[tickets + groups] = at;
                            self.work.refs[buckets + bucket] = at;
                            groups += 1;
                            break;
                        }
                        var equal = true;
                        for (keys[0..p.key_count], 0..) |key, column| {
                            if (V.compare(key, &self.work.cells[found + column]) != 0) { equal = false; break; }
                        }
                        if (equal) { at = found; break; }
                        bucket = (bucket + 1) & (slots - 1);
                    }
                    try self.addAggregates(p, &ctx, self.accumulators(at + @as(u32, @intCast(p.key_count + p.agg_count)), p.agg_count));
                }
                if (groups == 0) return self.finish(p, out);
                // Preserve the previous key-sorted group order, including NULLs;
                // sorting touches G handles, never N input ordinals or Cells.
                const scratch = try self.refs(groups);
                const sorter: GroupSorter = .{ .query = self, .width = p.key_count };
                _ = try sort_module.mergeSort(self.work.refs[tickets..][0..groups], self.work.refs[scratch..][0..groups], &sorter);
                for (self.work.refs[tickets..][0..groups]) |at| {
                    try self.projectGroup(p, at, self.accumulators(at + @as(u32, @intCast(p.key_count + p.agg_count)), p.agg_count), outer, &out);
                }
                self.work.stream_stats.groups += groups;
                self.work.stream_stats.scratch_cells = @max(self.work.stream_stats.scratch_cells, groups * record_cells);
                self.work.stream_stats.scratch_refs = @max(self.work.stream_stats.scratch_refs, slots + capacity + groups);
                return self.finish(p, out);
            }

            fn infinite(x: f64) bool {
                return x == x and x - x != 0;
            }

            fn accumulate(self: *Query, agg: *const B.Agg, acc: *Accumulator, input: *const V.Cell) Error!void {
                acc.count += 1;
                switch (agg.kind) {
                    .count, .count_star => {},
                    .sum, .avg => {
                        if (value_module.integral(agg.arg_ty)) {
                            if (agg.kind == .sum and agg.ty == .int8) {
                                const sum = @addWithOverflow(acc.integer, input.integer);
                                if (sum[1] != 0) return error.IntegerOverflow;
                                acc.integer = sum[0];
                            } else acc.wide += input.integer;
                            return;
                        }
                        if (agg.kind == .avg and (agg.arg_ty == .float4 or agg.arg_ty == .float8)) {
                            // float8_accum (Youngs-Cramer): finite inputs whose
                            // Sx or Sxx overflows raise 22003, as PostgreSQL.
                            const x: f64 = if (input.* == .float4) input.float4 else input.float8;
                            const n: f64 = @floatFromInt(acc.count);
                            const previous = acc.sx;
                            acc.sx += x;
                            if (acc.count > 1) {
                                const tmp = x * n - acc.sx;
                                acc.sxx += tmp * tmp / (n * (n - 1));
                                if (infinite(acc.sx) or infinite(acc.sxx)) {
                                    if (!infinite(previous) and !infinite(x)) return error.NumericValueOutOfRange;
                                    acc.sxx = acc.sx - acc.sx;
                                }
                            }
                            return;
                        }
                        const item = input.*;
                        acc.value = if (acc.value == .null_value) item else try Io.arithmetic(.add, &acc.value, &item, if (agg.kind == .avg) agg.ty else agg.arg_ty, self.session);
                    },
                    .min, .max => {
                        if (acc.value == .null_value) {
                            acc.value = input.*;
                        } else {
                            const order = V.compare(input, &acc.value);
                            if ((agg.kind == .min and order < 0) or (agg.kind == .max and order > 0)) acc.value = input.*;
                        }
                    },
                    .bool_and => acc.flag = (acc.flag orelse true) and input.boolean,
                    .bool_or => acc.flag = (acc.flag orelse false) or input.boolean,
                    .none => unreachable,
                }
            }

            fn numericOf(self: *Query, value: i128) Error!V.Cell {
                var digits: [48]u8 = undefined;
                var index: usize = digits.len;
                var magnitude: u128 = if (value < 0) @intCast(-value) else @intCast(value);
                while (true) {
                    index -= 1;
                    digits[index] = @intCast('0' + magnitude % 10);
                    magnitude /= 10;
                    if (magnitude == 0) break;
                }
                if (value < 0) {
                    index -= 1;
                    digits[index] = '-';
                }
                return Io.parse(.numeric, -1, digits[index..], self.session);
            }

            fn finishAggregate(self: *Query, agg: *const B.Agg, acc: *const Accumulator) Error!V.Cell {
                switch (agg.kind) {
                    .count, .count_star => return .{ .integer = acc.count },
                    .bool_and, .bool_or => return if (acc.flag) |flag| .{ .boolean = flag } else .null_value,
                    .min, .max => return acc.value,
                    else => {},
                }
                if (acc.count == 0) return .null_value;
                if (value_module.integral(agg.arg_ty)) {
                    if (agg.kind == .sum and agg.ty == .int8) return .{ .integer = acc.integer };
                    const total = try self.numericOf(acc.wide);
                    if (agg.kind == .sum) return total;
                    const count = try self.numericOf(acc.count);
                    return Io.arithmetic(.div, &total, &count, .numeric, self.session);
                }
                if (agg.kind == .sum) return acc.value;
                if (agg.ty == .float8) return .{ .float8 = acc.sx / @as(f64, @floatFromInt(acc.count)) };
                const count = try self.numericOf(acc.count);
                return Io.arithmetic(.div, &acc.value, &count, agg.ty, self.session);
            }

            fn aggregate(self: *Query, p: *const B.Plan, agg: *const B.Agg, tuples: Tuples, order: u32, first: usize, end: usize, outer: ?*const E.Context) Error!V.Cell {
                var ctx = self.context(outer);
                var acc: Accumulator = .{};
                const at = self.mark();
                defer self.release(at);
                var values: List = .{ .start = @intCast(self.work.ref_low) };
                for (first..end) |position| {
                    self.setTuple(p, &ctx, tuples, self.work.refs[order + position]);
                    if (agg.filter != none and (try E.truth(&ctx, agg.filter)) != true) continue;
                    if (agg.kind == .count_star) {
                        acc.count += 1;
                        continue;
                    }
                    const input = try E.eval(&ctx, agg.arg);
                    if (input == .null_value) continue;
                    if (agg.distinct) {
                        const cell = try self.cells(1);
                        self.work.cells[cell] = input;
                        try self.push(&values, cell);
                    } else try self.accumulate(agg, &acc, &input);
                }
                if (agg.distinct and values.count != 0) {
                    // Sort-based DISTINCT: sort the values, skip repeats.
                    const scratch = try self.refs(values.count);
                    const sorter: RowSorter = .{ .query = self, .keys = &whole_row, .key_count = 1 };
                    _ = try sort_module.mergeSort(self.handles(values), self.work.refs[scratch..][0..values.count], &sorter);
                    const list = self.handles(values);
                    for (list, 0..) |offset, index| {
                        if (index != 0 and V.compare(&self.work.cells[offset], &self.work.cells[list[index - 1]]) == 0) continue;
                        try self.accumulate(agg, &acc, &self.work.cells[offset]);
                    }
                }
                return self.finishAggregate(agg, &acc);
            }

            const whole_row = [1]B.SortKey{.{ .column = 0, .descending = false, .nulls_first = false }};

            /// Orders materialized rows (cell offsets) by sort keys.
            const RowSorter = struct {
                query: *const Query,
                keys: [*]const B.SortKey,
                key_count: usize,

                pub fn order(self: *const RowSorter, a: u32, b: u32) Error!i8 {
                    try self.query.session.checkpoint();
                    const work = self.query.work;
                    for (self.keys[0..self.key_count]) |key| {
                        const x = &work.cells[a + key.column];
                        const y = &work.cells[b + key.column];
                        const x_null = x.* == .null_value;
                        const y_null = y.* == .null_value;
                        if (x_null or y_null) {
                            if (x_null and y_null) continue;
                            return if (x_null == key.nulls_first) -1 else 1;
                        }
                        const result = V.compare(x, y);
                        if (result != 0) return if (key.descending) -result else result;
                    }
                    return 0;
                }
            };

            fn equalColumns(self: *const Query, a: u32, b: u32, columns: []const u16) bool {
                for (columns) |column| if (V.compare(&self.work.cells[a + column], &self.work.cells[b + column]) != 0) return false;
                return true;
            }

            fn equalPrefix(self: *const Query, a: u32, b: u32, count: usize) bool {
                for (0..count) |column| if (V.compare(&self.work.cells[a + column], &self.work.cells[b + column]) != 0) return false;
                return true;
            }

            fn sortRows(self: *Query, list: List, keys: []const B.SortKey) Error!void {
                if (list.count < 2 or keys.len == 0) return;
                const at = self.mark();
                defer self.release(at);
                const scratch = try self.refs(list.count);
                const sorter: RowSorter = .{ .query = self, .keys = keys.ptr, .key_count = keys.len };
                _ = try sort_module.mergeSort(self.handles(list), self.work.refs[scratch..][0..list.count], &sorter);
            }

            /// ORDER BY, DISTINCT / DISTINCT ON (first row of each run of
            /// equal values, NULLs equal), OFFSET and LIMIT.
            fn finish(self: *Query, p: *const B.Plan, input: List) Error!List {
                var list = input;
                try self.sortRows(list, p.order[0..p.order_count]);
                if (p.distinct != .none and list.count > 1) {
                    const items = self.handles(list);
                    var kept: u32 = 1;
                    for (1..items.len) |index| {
                        const same = if (p.distinct == .all) self.equalPrefix(items[index], items[kept - 1], p.count) else self.equalColumns(items[index], items[kept - 1], p.distinct_on[0..p.distinct_on_count]);
                        if (same) continue;
                        items[kept] = items[index];
                        kept += 1;
                    }
                    list.count = kept;
                }
                const skip: u32 = if (p.offset >= list.count) list.count else @intCast(p.offset);
                list.start += skip;
                list.count -= skip;
                if (p.limit < list.count) list.count = @intCast(p.limit);
                return list;
            }

            fn core(self: *Query, p: *const B.Plan, outer: ?*const E.Context) Error!List {
                if (streamEligible(p) and self.repeatable()) {
                    const at = self.mark();
                    const stats = self.work.stream_stats;
                    if (self.streamGroup(p, outer)) |rows| return rows else |err| {
                        // Hash state can cost more than sorted runs at high
                        // cardinality. Preserve queries that fit the existing
                        // workspace by retrying that operator only when replay
                        // cannot repeat volatile functions or subquery effects.
                        if (err != error.WorkspaceCapacity or !self.repeatable()) return err;
                        self.release(at);
                        self.work.stream_stats = stats;
                        // ExecutionControl remains charged for the attempted
                        // hash work; retry must not bypass cancellation/budgets.
                    }
                }
                const tuples = try self.join(p, outer);
                const rows = if (p.grouped) try self.group(p, tuples, outer) else try self.project(p, tuples, outer);
                return self.finish(p, rows);
            }

            fn repeatable(self: *const Query) bool {
                for (self.pool.nodes[0..self.pool.len]) |node| switch (node.kind) {
                    .function, .scalar_subquery, .exists_subquery, .in_subquery => return false,
                    else => {},
                };
                return true;
            }

            // ---- set operations and CTEs -------------------------------

            fn concat(self: *Query, a: List, b: List) Error!List {
                const at = try self.refs(@as(usize, a.count) + b.count);
                @memcpy(self.work.refs[at..][0..a.count], self.handles(a));
                @memcpy(self.work.refs[at + a.count ..][0..b.count], self.handles(b));
                return .{ .start = at, .count = a.count + b.count };
            }

            /// Runs of equal rows over `left ++ right`, sorted stably so the
            /// left rows of a run come first. Emits per UNION / INTERSECT /
            /// EXCEPT [ALL] multiplicity rules.
            fn combine(self: *Query, op: ast.SetOp, all: bool, left: List, right: List, width: usize) Error!List {
                const merged = try self.concat(left, right);
                const n = merged.count;
                // Sort positions (to know each row's side), not offsets.
                const positions = try self.refs(n);
                for (0..n) |index| self.work.refs[positions + index] = @intCast(index);
                const scratch = try self.refs(n);
                const sorter: PositionSorter = .{ .query = self, .list = merged, .width = width };
                _ = try sort_module.mergeSort(self.work.refs[positions..][0..n], self.work.refs[scratch..][0..n], &sorter);
                var out: List = .{ .start = @intCast(self.work.ref_low) };
                var first: usize = 0;
                while (first < n) {
                    const head = self.work.refs[merged.start + self.work.refs[positions + first]];
                    var end = first + 1;
                    while (end < n and self.equalPrefix(head, self.work.refs[merged.start + self.work.refs[positions + end]], width)) end += 1;
                    var lefts: usize = 0;
                    for (first..end) |index| {
                        if (self.work.refs[positions + index] < left.count) lefts += 1;
                    }
                    const rights = (end - first) - lefts;
                    const emit_count: usize = switch (op) {
                        .@"union" => 1,
                        .intersect => if (all) @min(lefts, rights) else @intFromBool(lefts != 0 and rights != 0),
                        .except => if (all) (if (lefts > rights) lefts - rights else 0) else @intFromBool(lefts != 0 and rights == 0),
                        .none => unreachable,
                    };
                    for (0..emit_count) |index| {
                        const position = self.work.refs[positions + first + @min(index, end - first - 1)];
                        try self.push(&out, self.work.refs[merged.start + position]);
                    }
                    first = end;
                }
                return out;
            }

            const PositionSorter = struct {
                query: *const Query,
                list: List,
                width: usize,

                pub fn order(self: *const PositionSorter, a: u32, b: u32) Error!i8 {
                    const work = self.query.work;
                    const x = work.refs[self.list.start + a];
                    const y = work.refs[self.list.start + b];
                    for (0..self.width) |column| {
                        const result = V.compare(&work.cells[x + column], &work.cells[y + column]);
                        if (result != 0) return result;
                    }
                    return 0;
                }
            };

            fn setOperation(self: *Query, p: *const B.Plan, outer: ?*const E.Context) Error!List {
                const left = try self.run(p.left, outer);
                const right = try self.run(p.right, outer);
                const rows = if (p.set_op == .@"union" and p.set_all) try self.concat(left, right) else try self.combine(p.set_op, p.set_all, left, right, p.count);
                return self.finish(p, rows);
            }

            /// New rows of a recursive UNION step: not already in `known`,
            /// each once.
            fn fresh(self: *Query, known: List, rows: List, width: usize) Error!List {
                const merged = try self.concat(known, rows);
                const n = merged.count;
                const positions = try self.refs(n);
                for (0..n) |index| self.work.refs[positions + index] = @intCast(index);
                const scratch = try self.refs(n);
                const sorter: PositionSorter = .{ .query = self, .list = merged, .width = width };
                _ = try sort_module.mergeSort(self.work.refs[positions..][0..n], self.work.refs[scratch..][0..n], &sorter);
                var out: List = .{ .start = @intCast(self.work.ref_low) };
                var first: usize = 0;
                while (first < n) {
                    const head = self.work.refs[merged.start + self.work.refs[positions + first]];
                    var end = first + 1;
                    var seen = self.work.refs[positions + first] < known.count;
                    while (end < n and self.equalPrefix(head, self.work.refs[merged.start + self.work.refs[positions + end]], width)) : (end += 1) {
                        if (self.work.refs[positions + end] < known.count) seen = true;
                    }
                    if (!seen) try self.push(&out, head);
                    first = end;
                }
                return out;
            }

            /// Materializes a CTE once per statement. WITH RECURSIVE
            /// iterates the recursive term over the previous step's rows
            /// until a step adds nothing (UNION drops rows already present);
            /// a non-terminating recursion ends in WorkspaceCapacity.
            fn materializeCte(self: *Query, id: u8, outer: ?*const E.Context) Error!List {
                const state = &self.work.ctes[id];
                switch (state.state) {
                    .done => return state.rows,
                    .iterating => return state.working,
                    .idle => {},
                }
                const definition = &self.plans.ctes[id];
                const p = &self.plans.items[definition.plan];
                if (p.correlated) {
                    if (definition.recursive) return error.UnsupportedStatement;
                    return self.run(definition.plan, outer);
                }
                const width = p.count;
                if (!definition.recursive) {
                    const at = self.mark();
                    const list = try self.run(definition.plan, outer);
                    state.rows = try self.persist(list, width);
                    self.release(at);
                    state.state = .done;
                    return state.rows;
                }
                var at = self.mark();
                var seed = try self.run(p.left, outer);
                if (!p.set_all) seed = try self.fresh(.{}, seed, width);
                var result = try self.persist(seed, width);
                self.release(at);
                var working = result;
                while (true) {
                    state.state = .iterating;
                    try self.session.checkpoint();
                    state.working = working;
                    at = self.mark();
                    var step = try self.run(p.right, outer);
                    if (!p.set_all) step = try self.fresh(result, step, width);
                    if (step.count == 0) {
                        self.release(at);
                        break;
                    }
                    const added = try self.persist(step, width);
                    self.release(at);
                    result = try self.concatPersistent(result, added);
                    working = added;
                }
                state.rows = result;
                state.state = .done;
                return result;
            }

            // ---- subqueries --------------------------------------------

            fn subquery(ptr: *anyopaque, ctx: *const E.Context, id: u16) Error!V.Cell {
                const self: *Query = @ptrCast(@alignCast(ptr));
                const n = &self.pool.nodes[id];
                const plan_id: u16 = @intCast(n.integer);
                const p = &self.plans.items[plan_id];
                const at = self.mark();
                defer self.release(at);
                var list: List = undefined;
                if (p.correlated) {
                    list = try self.run(plan_id, ctx);
                } else {
                    const cache = &self.work.cache[plan_id];
                    if (!cache.valid) {
                        const rows = try self.run(plan_id, ctx);
                        cache.rows = try self.persist(rows, p.count);
                        cache.valid = true;
                    }
                    list = cache.rows;
                }
                switch (n.kind) {
                    .scalar_subquery => {
                        if (list.count > 1) return error.CardinalityViolation;
                        if (list.count == 0) return .null_value;
                        return self.row(self.handles(list)[0])[0];
                    },
                    .exists_subquery => return .{ .boolean = list.count != 0 },
                    .in_subquery => {
                        const value = try E.eval(ctx, n.a);
                        if (list.count == 0) return .{ .boolean = n.negated };
                        var found = false;
                        var unknown = value == .null_value;
                        if (!unknown) for (self.handles(list)) |offset| {
                            const candidate = &self.work.cells[offset];
                            if (candidate.* == .null_value) {
                                unknown = true;
                            } else if (V.compare(&value, candidate) == 0) {
                                found = true;
                                break;
                            }
                        };
                        if (found) return .{ .boolean = !n.negated };
                        if (unknown) return .null_value;
                        return .{ .boolean = n.negated };
                    },
                    else => unreachable,
                }
            }
        };

        fn std_assert(ok: bool) void {
            if (!ok) unreachable;
        }

        /// Runs the plan `root` and writes its rows into `result`.
        pub fn runQuery(tables: *const [config.tables]S.Table, source: []const u8, pool: *const Ast.Pool, plans: *const B.Plans, root: u16, snap: storage.Snapshot, result: anytype, session: *const value_module.Session, work: *Work) Error!void {
            work.reset();
            var runner: Query = .{ .tables = tables, .source = source, .pool = pool, .plans = plans, .snap = snap, .session = session, .work = work };
            runner.hook = .{ .ptr = &runner, .run = Query.subquery };
            const list = try runner.run(root, null);
            const p = &plans.items[root];
            if (list.count > result.rows.len) return error.RowCapacity;
            result.clear(0);
            result.command = .select;
            result.column_count = p.count;
            for (0..p.count) |column| {
                result.column_names[column] = p.names[column];
                result.column_types[column] = types.dataTypeOf(p.tys[column]);
                result.column_typmods[column] = p.typmods[column];
            }
            result.row_count = list.count;
            for (runner.handles(list), 0..) |offset, index| {
                @memcpy(result.rows[index].cells[0..p.count], work.cells[offset..][0..p.count]);
            }
        }
        /// Runs a bound general query and leaves its output rows in `work`
        /// (INSERT ... SELECT); read them with rowAt until the next reset.
        pub fn queryRows(tables: *const [config.tables]S.Table, source: []const u8, pool: *const Ast.Pool, plans: *const B.Plans, root: u16, snap: storage.Snapshot, session: *const value_module.Session, work: *Work) Error!List {
            work.reset();
            var runner: Query = .{ .tables = tables, .source = source, .pool = pool, .plans = plans, .snap = snap, .session = session, .work = work };
            runner.hook = .{ .ptr = &runner, .run = Query.subquery };
            return runner.run(root, null);
        }

        pub fn rowAt(work: *const Work, list: List, index: usize) [*]const V.Cell {
            return work.cells[work.refs[list.start + index]..].ptr;
        }

        pub fn resetWork(work: *Work) void {
            work.reset();
        }

        /// Reserves `count` statement-lifetime cells (RETURNING staging).
        pub fn stageCells(work: *Work, count: usize) Error!usize {
            if (work.cell_high - work.cell_low < count) return error.WorkspaceCapacity;
            const at = work.cell_low;
            work.cell_low += count;
            return at;
        }

        pub const Candidates = union(enum) { scan, empty, slot: u32 };

        /// WHERE keeps a row only when the predicate is TRUE.
        pub fn keep(ctx: *E.Context, where: u16, row: ?*const E.Row) Error!bool {
            if (where == none) return true;
            ctx.row = row;
            return (try E.truth(ctx, where)) == true;
        }

        /// Evaluates a top-level `pk = constant` once and probes the index
        /// under the statement snapshot.
        pub fn candidates(ctx: *E.Context, table: *const S.Table, key: u16, snap: storage.Snapshot) Error!Candidates {
            if (key == none) return .scan;
            ctx.row = null;
            const value = try E.eval(ctx, key);
            if (value == .null_value) return .empty;
            const slot = S.lookupKeyAt(table, &value, snap) orelse return .empty;
            return .{ .slot = slot };
        }

        /// Plain SELECT: candidates are emitted as read.
        pub const NoLock = struct {
            pub const active = false;
            pub fn lock(_: @This(), _: usize, version: u32) Error!?u32 {
                return version;
            }
        };

        fn simple(pool: *const Ast.Pool, id: u16) bool {
            return pool.nodes[id].kind == .column;
        }

        const Sorter = struct {
            ctx: *E.Context,
            table: *const S.Table,
            query: *const B.Select,

            pub fn order(self: *const Sorter, left: u32, right: u32) Error!i8 {
                try self.ctx.session.checkpoint();
                for (self.query.order[0..self.query.order_count]) |*key| {
                    const node = &self.ctx.pool.nodes[key.expr];
                    var av: V.Cell = undefined;
                    var bv: V.Cell = undefined;
                    const a: *const V.Cell = if (node.kind == .column) &self.table.versions[left].cells[node.column] else blk: {
                        self.ctx.row = &self.table.versions[left].cells;
                        av = try E.eval(self.ctx, key.expr);
                        break :blk &av;
                    };
                    const b: *const V.Cell = if (node.kind == .column) &self.table.versions[right].cells[node.column] else blk: {
                        self.ctx.row = &self.table.versions[right].cells;
                        bv = try E.eval(self.ctx, key.expr);
                        break :blk &bv;
                    };
                    const nulls_first = key.nulls_first orelse (config.nulls_first_ascending != key.descending);
                    const result: i8 = if (a.* == .null_value or b.* == .null_value) blk: {
                        if (a.* == .null_value and b.* == .null_value) break :blk 0;
                        break :blk if ((a.* == .null_value) == nulls_first) -1 else 1;
                    } else blk: {
                        const value = V.compare(a, b);
                        break :blk if (key.descending) -value else value;
                    };
                    if (result != 0) return result;
                }
                return 0;
            }

            /// Stable bottom-up merge sort over version indices.
            fn sort(self: *const Sorter, items: []u32) Error!void {
                var scratch: [types.workRows(config)]u32 = undefined;
                _ = try sort_module.mergeSort(items, scratch[0..items.len], self);
            }
        };

        const StableSorter = struct {
            base: *const Sorter,
            pub fn order(self: *const StableSorter, left: u32, right: u32) Error!i8 {
                const result = try self.base.order(left, right);
                if (result != 0) return result;
                const a = self.base.table.versions[left].row;
                const b = self.base.table.versions[right].row;
                return if (a < b) -1 else if (a > b) 1 else 0;
            }
        };

        /// `locker` (FOR UPDATE/SHARE) runs after ORDER BY and before LIMIT, as
        /// PostgreSQL's LockRows does: it returns the version to emit (the
        /// newest committed one, whose WHERE is re-checked here when it
        /// changed), null to skip the row, or WouldBlock to park.
        pub fn select(tables: *const [config.tables]S.Table, source: []const u8, pool: *const Ast.Pool, query: *const B.Select, snap: storage.Snapshot, result: anytype, locker: anytype, session: *const value_module.Session) Error!void {
            try session.checkpoint();
            var ctx: E.Context = .{ .source = source, .pool = pool, .session = session };
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
            const table_index = query.table.?;
            const table = &tables[table_index];
            const locking = @TypeOf(locker).active;
            var indices: [types.workRows(config)]u32 = undefined;
            var found: usize = 0;
            var column_order = true;
            for (query.order[0..query.order_count]) |key| column_order = column_order and simple(pool, key.expr);
            const top_k = !locking and column_order and query.order_count != 0 and query.limit <= indices.len and (query.limit < table.row_high / 2 or table.row_high > indices.len);
            const sorter: Sorter = .{ .ctx = &ctx, .table = table, .query = query };
            const stable: StableSorter = .{ .base = &sorter };
            if (query.limit != 0) switch (try candidates(&ctx, table, query.key, snap)) {
                .empty => {},
                .slot => |slot| {
                    const version = S.visibleAt(table, slot, snap).?;
                    if (try keep(&ctx, query.where, &table.versions[version].cells)) {
                        indices[0] = version;
                        found = 1;
                    }
                },
                .scan => for (0..table.row_high) |slot| {
                    try session.checkpoint();
                    const version = S.visibleAt(table, slot, snap) orelse continue;
                    if (!try keep(&ctx, query.where, &table.versions[version].cells)) continue;
                    if (top_k) {
                        try sort_module.offerTopK(indices[0..@intCast(query.limit)], &found, version, &stable);
                    } else {
                        if (found == indices.len) return error.WorkspaceCapacity;
                        indices[found] = version;
                        found += 1;
                    }
                    if (!locking and query.order_count == 0 and found >= query.limit) break;
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
                if (top_k) {
                    var scratch: [types.workRows(config)]u32 = undefined;
                    _ = try sort_module.mergeSort(indices[0..found], scratch[0..found], &stable);
                } else try sorter.sort(indices[0..found]);
            }
            if (locking) {
                // LockRows: lock in output order; LIMIT counts locked rows.
                var kept: usize = 0;
                for (0..found) |position| {
                    if (kept >= query.limit) break;
                    const version = indices[position];
                    const newest = (try locker.lock(table_index, version)) orelse continue;
                    if (newest != version and !try keep(&ctx, query.where, &table.versions[newest].cells)) continue;
                    indices[kept] = newest;
                    kept += 1;
                }
                found = kept;
            }
            const rows: usize = if (query.limit < found) @intCast(query.limit) else found;
            if (rows > result.rows.len) return error.WorkspaceCapacity;
            if (!plain) {
                // Validation pass: projections may fail; the result is untouched.
                for (indices[0..rows]) |version| {
                    ctx.row = &table.versions[version].cells;
                    for (query.targets[0..query.count]) |id| _ = try E.eval(&ctx, id);
                }
            }
            // Validation accounted for every expression and may fail/cancel.
            // Publishing the validated result must remain infallible.
            var publishing = session.*;
            publishing.control = null;
            ctx.session = &publishing;
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
                result.column_typmods[index] = query.typmods[index];
            }
        }
    };
}
