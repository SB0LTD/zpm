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
const builtin = @import("builtin");
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
        const integer_topk_capacity = if (config.external_workspace) 256 else types.workRows(config);
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

        /// Per-statement evidence for streaming read paths. Counts
        /// include nested eligible plans; scratch figures are per-plan peaks.
        pub const StreamStats = struct {
            rows: usize = 0,
            summary_rows: usize = 0,
            summary_plans: usize = 0,
            dense_plans: usize = 0,
            compact_plans: usize = 0,
            compact_rows: usize = 0,
            wide_dense_plans: usize = 0,
            narrow_dense_plans: usize = 0,
            factor_plans: usize = 0,
            factor_keys: usize = 0,
            factor_selected_rows: usize = 0,
            typed_group_plans: usize = 0,
            typed_group_channels: usize = 0,
            nested_factor_plans: usize = 0,
            nested_factor_keys: usize = 0,
            presence_rejected_blocks:usize=0,
            gathered_rows: usize = 0,
            distinct_bitmap_bytes: usize = 0,
            groups: usize = 0,
            probes: usize = 0,
            dimension_probes: usize = 0,
            prefix_rejected: usize = 0,
            cascade_rejected: usize = 0,
            scratch_cells: usize = 0,
            scratch_refs: usize = 0,
        };
        pub const ReadStats = struct {
            projected_filter_scans: usize = 0,
            projected_filter_rows: usize = 0,
            key_probes: usize = 0,
            key_walks: usize = 0,
            key_fallbacks: usize = 0,
            key_successes: usize = 0,
            nonnull_sort_keys: usize = 0,
        };

        /// The statement's query workspace (design §4.9): caller-owned,
        /// uninitialized until a statement writes it. Scratch grows from the
        /// bottom and is released per correlated subquery evaluation;
        /// materialized CTEs and uncorrelated subquery results are copied
        /// to the top and live for the statement.
        pub const Work = struct {
            cells: if (config.external_workspace) []V.Cell else [work_cells]V.Cell = if (config.external_workspace) &.{} else undefined,
            cell_low: usize = 0,
            cell_high: usize = if (config.external_workspace) 0 else work_cells,
            refs: if (config.external_storage) []u32 else [work_refs]u32 = if (config.external_storage) &.{} else undefined,
            ref_low: usize = 0,
            ref_high: usize = if (config.external_storage) 0 else work_refs,
            ctes: [config.ctes]CteRun = undefined,
            cache: [config.subqueries]Cache = undefined,
            stream_stats: StreamStats = .{},
            read_stats: ReadStats = .{},
            /// System-view rows (catalog.sig View) for this statement; set by
            /// the Database before it runs a query (kept across resets).
            views: ?ViewHook = null,

            fn reset(self: *Work) void {
                self.cell_low = 0;
                self.cell_high = self.cells.len;
                self.ref_low = 0;
                self.ref_high = self.refs.len;
                self.stream_stats = .{};
                self.read_stats = .{};
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
            committed_only: bool = false,
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

            /// Only pure, non-throwing comparisons may move across inner joins.
            /// Outer joins and volatile/computed/subquery predicates retain the
            /// original path. An OR moves only when all its inputs are present.
            fn earlyAvailable(self: *const Query, id: u16, stage: usize) bool {
                if (id == none) return true;
                const n = self.pool.nodes[id];
                return switch (n.kind) {
                    .row_compare => blk: {
                        if (n.a != none) break :blk self.earlyAvailable(n.a, stage);
                        var item = n.b;
                        while (item != none) : (item = self.pool.nodes[item].next) {
                            const pair = self.pool.nodes[item];
                            if (!self.earlyAvailable(pair.a, stage) or !self.earlyAvailable(pair.b, stage)) break :blk false;
                        }
                        break :blk true;
                    },
                    .row_constructor, .row_in => blk: {
                        var item = n.b;
                        while (item != none) : (item = self.pool.nodes[item].next) if (!self.earlyAvailable(item, stage)) break :blk false;
                        break :blk true;
                    },
                    .column => n.level == 0 and n.relation <= stage,
                    .null_literal, .bool_literal, .int_literal, .text_literal, .decimal_literal => true,
                    .binary => switch (n.op) {
                        .eq, .ne, .lt, .le, .gt, .ge => self.earlyAvailable(n.a, stage) and self.earlyAvailable(n.b, stage),
                        else => false,
                    },
                    .and_op, .or_op => self.earlyAvailable(n.a, stage) and self.earlyAvailable(n.b, stage),
                    .not_op, .test_op => self.earlyAvailable(n.a, stage),
                    else => false,
                };
            }

            fn earlyKeep(self: *const Query, ctx: *E.Context, id: u16, stage: usize) Error!bool {
                if (id == none) return true;
                const n = self.pool.nodes[id];
                if (n.kind == .and_op) return try self.earlyKeep(ctx, n.a, stage) and try self.earlyKeep(ctx, n.b, stage);
                return !self.earlyAvailable(id, stage) or (try E.truth(ctx, id)) == true;
            }

            fn joinKeep(self: *const Query, ctx: *E.Context, id: u16, stage: usize, last: bool, early: bool) Error!bool {
                if (last) return keep(ctx, id, null);
                return !early or try self.earlyKeep(ctx, id, stage);
            }

            /// Left-deep joins prune eligible WHERE conjuncts at their first
            /// complete tuple, before allocating the next intermediate stage.
            fn join(self: *Query, p: *const B.Plan, outer: ?*const E.Context) Error!Tuples {
                var ctx = self.context(outer);
                if (p.source_count == 0) {
                    const kept = try keep(&ctx, p.where, null);
                    return .{ .start = @intCast(self.work.ref_low), .count = @intFromBool(kept), .width = 0 };
                }
                var current: Tuples = .{ .start = @intCast(self.work.ref_low), .count = 1, .width = 0 };
                var early = self.earlyAvailable(p.where, p.source_count - 1) and self.prefixJoinsSafe(p);
                for (p.sources[0..p.source_count]) |source| if (source.join == .left or source.join == .right or source.join == .full) { early = false; break; };
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
                                        if (try self.joinKeep(&ctx, p.where, stage, last, early)) try self.emit(&next, current, index, version);
                                    }
                                };
                            }
                        } else for (self.handles(rows), 0..) |handle, position| {
                            try self.session.checkpoint();
                            ctx.tuple[stage] = self.rowOf(source, handle);
                            if (stage != 0 and source.on != none and (try E.truth(&ctx, source.on)) != true) continue;
                            any = true;
                            if (tracks) self.work.refs[matched + position] = 1;
                            if (try self.joinKeep(&ctx, p.where, stage, last, early)) try self.emit(&next, current, index, handle);
                        }
                        if (!any and outer_join) {
                            ctx.tuple[stage] = null;
                            if (try self.joinKeep(&ctx, p.where, stage, last, early)) try self.emit(&next, current, index, absent);
                        }
                    }
                    if (tracks) {
                        for (self.handles(rows), 0..) |handle, position| {
                            if (self.work.refs[matched + position] != 0) continue;
                            for (0..stage) |slot| ctx.tuple[slot] = null;
                            ctx.tuple[stage] = self.rowOf(source, handle);
                            if (try self.joinKeep(&ctx, p.where, stage, last, early)) try self.emit(&next, current, null, handle);
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
                if (!p.grouped or p.source_count == 0 or p.sources[0].table == null) return false;
                // Each later input contributes at most one visible row through
                // its unique primary key. Other join shapes retain the general
                // operator; no fanout-sized state is hidden in this path.
                for(p.sources[1..p.source_count]) |source| {
                    if(source.join!=.inner or source.table==null or source.probe==none) return false;
                }
                // Integral COUNT(DISTINCT) may use exact caller-backed bitmap
                // states. Other types/aggregates keep the general operator.
                for (p.aggs[0..p.agg_count]) |agg| if (agg.distinct and
                    (agg.kind!=.count or !value_module.integral(agg.arg_ty))) return false;
                // Keep the existing lazy evaluation contract for finite LIMITs.
                if (p.limit != 0xffffffffffffffff and p.order_count == 0 and p.distinct == .none) {
                    if (p.key_count != 0 or (p.limit == 0 and p.offset == 0)) return false;
                }
                return true;
            }

            /// A bound column input can be borrowed for this synchronous step;
            /// no whole tagged union copy is needed to read an integer or key.
            /// Computed/correlated expressions retain the ordinary evaluator.
            fn streamInput(self: *Query, ctx: *E.Context, id: u16, temporary: *V.Cell) Error!*const V.Cell {
                const node = &self.pool.nodes[id];
                if (node.kind == .column and node.level==0 and node.relation==0) return E.columnRef(ctx,node);
                return E.evalRef(ctx,id,temporary);
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

            const DistinctDomain=struct {base:i64=0,span:usize=0,offset:usize=0,words:usize=0};
            const DistinctLayout=struct {
                domains:[config.columns]DistinctDomain=@splat(.{}),words:usize=0,cells:usize=0,active:bool=false,
            };
            fn distinctLayout(self:*const Query,p:*const B.Plan) ?DistinctLayout {
                var layout:DistinctLayout=.{};
                const available=self.work.cell_high-self.work.cell_low;
                for(p.aggs[0..p.agg_count],0..) |agg,i| {
                    if(!agg.distinct) continue;
                    layout.active=true;
                    const node=&self.pool.nodes[agg.arg];
                    if(agg.kind!=.count or node.kind!=.column or node.level!=0 or node.relation>=p.source_count or
                        !value_module.integral(node.ty)) return null;
                    const source=p.sources[node.relation].table orelse return null;
                    const table=&self.tables[source];
                    const bounds=table.integer_bounds[node.column];
                    // Bounds include every inserted version, including aborted
                    // and pending writes, and are never narrowed by reclamation.
                    // They safely enclose old snapshots and own-write values.
                    const span:u128=if(bounds.known) @intCast(@as(i128,bounds.high)-bounds.low+1) else 0;
                    const words=(span+63)/64;
                    const total=@as(u128,layout.words)+words;
                    if(span>@as(u128,~@as(usize,0)) or total*8>@as(u128,available)*@sizeOf(V.Cell)) return null;
                    layout.domains[i]=.{.base=bounds.low,.span=@intCast(span),.offset=layout.words,.words=@intCast(words)};
                    layout.words=@intCast(total);
                }
                layout.cells=@intCast((@as(u128,layout.words)*8+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell));
                return layout;
            }
            fn distinctWords(self:*Query,at:u32,words:usize) []align(@alignOf(V.Cell)) u64 {
                if(words==0) return &.{};
                const data:[*]align(@alignOf(V.Cell)) u64=@ptrCast(&self.work.cells[at]);
                return data[0..words];
            }
            fn addDistinctAggregates(self:*Query,p:*const B.Plan,ctx:*E.Context,states:[]Accumulator,
                layout:*const DistinctLayout,seen:[]align(@alignOf(V.Cell)) u64) Error!void {
                for(p.aggs[0..p.agg_count],states,0..) |*agg,*acc,i| {
                    if(agg.filter!=none and (try E.truth(ctx,agg.filter))!=true) continue;
                    if(agg.kind==.count_star) {acc.count+=1;continue;}
                    var temporary:V.Cell=undefined;
                    const input=try self.streamInput(ctx,agg.arg,&temporary);
                    if(input.*==.null_value) continue;
                    if(agg.distinct) {
                        try self.session.checkpoint();
                        const domain=layout.domains[i];
                        const relative=@as(i128,input.integer)-domain.base;
                        if(relative<0 or relative>=domain.span) return error.WorkspaceCapacity;
                        const bit:usize=@intCast(relative);const mask=@as(u64,1)<<@as(u6,@intCast(bit%64));
                        const word=&seen[domain.offset+bit/64];
                        if(word.*&mask!=0) continue;
                        word.*|=mask;
                    }
                    try self.accumulate(agg,acc,input);
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

            /// Every eligible aggregate can use exact published metadata.
            /// No computed/filter/distinct input is skipped. The caller proves
            /// this transaction has no writes; CSN protects pinned snapshots.
            fn summaryEligible(self: *const Query, p: *const B.Plan, table: *const S.Table) bool {
                if(p.source_count!=1) return false;
                if (!self.committed_only or !table.summary.valid or table.summary.csn > self.snap.csn or p.where != none) return false;
                for (p.aggs[0..p.agg_count]) |agg| {
                    if (agg.distinct or agg.filter != none) return false;
                    if (agg.kind == .count_star) continue;
                    if (agg.kind != .count and !((agg.kind == .sum or agg.kind == .avg) and value_module.integral(agg.arg_ty))) return false;
                    // A legacy int8 -> int8 SUM must preserve prefix-overflow
                    // errors, even if cancellation makes the final total fit.
                    if (agg.kind == .sum and agg.ty == .int8 and agg.arg_ty == .int8) return false;
                    const node = &self.pool.nodes[agg.arg];
                    if (node.kind != .column or node.level != 0 or node.relation != 0) return false;
                }
                return true;
            }

            fn summaryStates(self: *Query, p: *const B.Plan, columns: *const [config.columns]S.ColumnSummary, rows: i64, states: []Accumulator) Error!void {
                for (p.aggs[0..p.agg_count], states) |agg, *state| {
                    try self.session.checkpoint();
                    state.* = .{};
                    if (agg.kind == .count_star) { state.count = rows; continue; }
                    const column = &columns[self.pool.nodes[agg.arg].column];
                    state.count = column.nonnull;
                    state.wide = column.total;
                    if (agg.kind == .sum and agg.ty == .int8) state.integer = @intCast(column.total);
                }
            }

            const RollupSorter = struct {
                rollup: *const S.Rollup,
                session: *const value_module.Session,
                pub fn order(self: *const RollupSorter, a: u32, b: u32) Error!i8 {
                    try self.session.checkpoint();
                    const left = &self.rollup.groups[a];
                    const right = &self.rollup.groups[b];
                    return V.compare(&left.key, &right.key);
                }
            };

            fn rollupGroup(self: *Query, p: *const B.Plan, outer: ?*const E.Context, table: *const S.Table, rollup: *const S.Rollup) Error!List {
                var out: List = .{};
                var groups: usize = 0;
                for (rollup.groups[0..rollup.used]) |*entry| if (entry.rows != 0) { groups += 1; };
                self.work.stream_stats.summary_plans += 1;
                self.work.stream_stats.summary_rows += @intCast(table.summary.rows);
                if (groups == 0) return self.finish(p, out);
                const order = try self.refs(groups);
                const scratch = try self.refs(groups);
                var used: usize = 0;
                for (rollup.groups[0..rollup.used], 0..) |*entry, i| if (entry.rows != 0) {
                    self.work.refs[order + used] = @intCast(i);
                    used += 1;
                };
                const sorter: RollupSorter = .{ .rollup = rollup, .session = self.session };
                _ = try sort_module.mergeSort(self.work.refs[order..][0..groups], self.work.refs[scratch..][0..groups], &sorter);
                var states: [config.columns]Accumulator = undefined;
                for (self.work.refs[order..][0..groups]) |index| {
                    const entry = &rollup.groups[index];
                    const at = try self.cells(1 + p.agg_count);
                    self.work.cells[at] = entry.key;
                    try self.summaryStates(p, &entry.columns, entry.rows, states[0..p.agg_count]);
                    try self.projectGroup(p, at, states[0..p.agg_count], outer, &out);
                }
                self.work.stream_stats.groups += groups;
                self.work.stream_stats.scratch_cells = @max(self.work.stream_stats.scratch_cells, groups * (1 + p.agg_count));
                self.work.stream_stats.scratch_refs = @max(self.work.stream_stats.scratch_refs, groups * 2);
                return self.finish(p, out);
            }

            const Transition = struct {
                kind: enum { count_star, count, sum_integer, sum_wide },
                column: u16 = 0,
            };

            fn prepareTransitions(self: *const Query, p: *const B.Plan, output: []Transition) bool {
                for (p.aggs[0..p.agg_count], output) |agg, *item| {
                    if (agg.distinct or agg.filter != none) return false;
                    if (agg.kind == .count_star) { item.* = .{ .kind = .count_star }; continue; }
                    if (agg.kind != .count and !((agg.kind == .sum or agg.kind == .avg) and value_module.integral(agg.arg_ty))) return false;
                    const node = &self.pool.nodes[agg.arg];
                    if (node.kind != .column or node.level != 0 or node.relation != 0) return false;
                    item.* = .{ .column = node.column, .kind = if (agg.kind == .count) .count else if (agg.kind == .sum and agg.ty == .int8) .sum_integer else .sum_wide };
                }
                return true;
            }

            inline fn addTransitions(transitions: []const Transition, states: []Accumulator, source_cells: *const [config.columns]V.Cell) Error!void {
                for (transitions, states) |item, *state| {
                    if (item.kind == .count_star) { state.count += 1; continue; }
                    const value = &source_cells[item.column];
                    if (value.* == .null_value) continue;
                    state.count += 1;
                    switch (item.kind) {
                        .count => {},
                        .sum_integer => {
                            const sum = @addWithOverflow(state.integer, value.integer);
                            if (sum[1] != 0) return error.IntegerOverflow;
                            state.integer = sum[0];
                        },
                        .sum_wide => state.wide += value.integer,
                        .count_star => unreachable,
                    }
                }
            }

            const DenseDomain = struct { column: u16, base: i64, span: usize };
            fn denseDomain(self: *const Query, p: *const B.Plan, table: *const S.Table, bucket_budget: usize) ?DenseDomain {
                if (p.key_count != 1) return null;
                const key = &self.pool.nodes[p.keys[0]];
                if (key.kind != .column or key.level != 0 or key.relation != 0 or !value_module.integral(key.ty)) return null;
                const bounds = table.integer_bounds[key.column];
                if (!bounds.known) return null;
                const span = @as(i128, bounds.high) - bounds.low + 1;
                // This is an optimization budget, not a SQL cardinality limit.
                // Wider domains keep the collision-safe hash/sort paths.
                if (span > 4096 or span + 1 > bucket_budget) return null;
                return .{ .column = key.column, .base = bounds.low, .span = @intCast(span) };
            }

            noinline fn denseGroup(self: *Query, p: *const B.Plan, outer: ?*const E.Context, table: *const S.Table, domain: DenseDomain, capacity: usize, record_cells: usize) Error!List {
                var ctx = self.context(outer);
                var out: List = .{};
                var groups: usize = 0;
                var buckets: u32 = undefined;
                var tickets: u32 = undefined;
                var transitions: [config.columns]Transition = undefined;
                const prepared = self.prepareTransitions(p, transitions[0..p.agg_count]);
                for (0..table.row_high) |slot| {
                    try self.session.checkpoint();
                    const version = S.visibleAt(table, slot, self.snap) orelse continue;
                    self.work.stream_stats.rows += 1;
                    const source_cells = &table.versions[version].cells;
                    ctx.tuple[0] = source_cells;
                    if (!try keep(&ctx, p.where, null)) continue;
                    if (groups == 0) {
                        if (capacity == 0) return error.WorkspaceCapacity;
                        buckets = try self.refs(domain.span + 1);
                        @memset(self.work.refs[buckets..][0..domain.span + 1], absent);
                        tickets = try self.refs(capacity);
                    }
                    const key = &source_cells[domain.column];
                    const bucket: usize = if (key.* == .null_value) domain.span else @intCast(@as(i128, key.integer) - domain.base);
                    self.work.stream_stats.probes += 1;
                    var at = self.work.refs[buckets + bucket];
                    if (at == absent) {
                        if (groups == capacity) return error.WorkspaceCapacity;
                        at = try self.cells(record_cells);
                        self.work.cells[at] = key.*;
                        for (self.accumulators(at + @as(u32, @intCast(1 + p.agg_count)), p.agg_count)) |*state| state.* = .{};
                        self.work.refs[tickets + groups] = at;
                        self.work.refs[buckets + bucket] = at;
                        groups += 1;
                    }
                    const states = self.accumulators(at + @as(u32, @intCast(1 + p.agg_count)), p.agg_count);
                    if (prepared) try addTransitions(transitions[0..p.agg_count], states, source_cells) else try self.addAggregates(p, &ctx, states);
                }
                self.work.stream_stats.dense_plans += 1;
                if (groups == 0) return self.finish(p, out);
                const scratch = try self.refs(groups);
                const sorter: GroupSorter = .{ .query = self, .width = 1 };
                _ = try sort_module.mergeSort(self.work.refs[tickets..][0..groups], self.work.refs[scratch..][0..groups], &sorter);
                for (self.work.refs[tickets..][0..groups]) |at|
                    try self.projectGroup(p, at, self.accumulators(at + @as(u32, @intCast(1 + p.agg_count)), p.agg_count), outer, &out);
                self.work.stream_stats.groups += groups;
                self.work.stream_stats.scratch_cells = @max(self.work.stream_stats.scratch_cells, groups * record_cells);
                self.work.stream_stats.scratch_refs = @max(self.work.stream_stats.scratch_refs, domain.span + 1 + capacity + groups);
                return self.finish(p, out);
            }

            const CompactPredicate = struct { column: u16, op: ast.Op, value: i64, nonnull: bool };
            fn compactPredicates(pool: *const Ast.Pool, id: u16, table: *const S.Table, out: []CompactPredicate, used: *usize) bool {
                if (id == none) return true;
                const node = &pool.nodes[id];
                if (node.kind == .and_op) return compactPredicates(pool, node.a, table, out, used) and compactPredicates(pool, node.b, table, out, used);
                if (node.kind != .binary or used.* == out.len) return false;
                switch (node.op) { .eq, .ne, .lt, .le, .gt, .ge => {}, else => return false }
                var a = &pool.nodes[node.a];
                var b = &pool.nodes[node.b];
                var op = node.op;
                if (b.kind == .column and a.kind == .int_literal) {
                    const temp = a; a = b; b = temp;
                    op = switch (op) { .lt => .gt, .le => .ge, .gt => .lt, .ge => .le, else => op };
                }
                // Computed, volatile, nullable literal and correlated inputs
                // retain expression evaluation and its normal error behavior.
                if (a.kind != .column or a.level != 0 or a.relation != 0 or !value_module.integral(a.ty) or b.kind != .int_literal) return false;
                out[used.*] = .{ .column = a.column, .op = op, .value = b.integer,
                    .nonnull = table.summary.columns[a.column].nonnull == table.summary.rows };
                used.* += 1;
                return true;
            }

            inline fn compactKeep(table: *const S.Table, slot: usize, predicates: []const CompactPredicate) bool {
                for (predicates) |predicate| {
                    if (!predicate.nonnull and table.scan_nonnull[slot] & (@as(u64, 1) << @intCast(predicate.column)) == 0) return false;
                    const value = table.scan_values[@as(usize, predicate.column) * table.rows.len + slot];
                    const keep_row = switch (predicate.op) {
                        .eq => value == predicate.value, .ne => value != predicate.value,
                        .lt => value < predicate.value, .le => value <= predicate.value,
                        .gt => value > predicate.value, .ge => value >= predicate.value,
                        else => unreachable,
                    };
                    if (!keep_row) return false;
                }
                return true;
            }

            fn liveMask(table:*const S.Table,start:usize,count:usize,dense:bool) u64 {
                if(dense) return if(count==64) ~@as(u64,0) else (@as(u64,1)<<@intCast(count))-1;
                var mask:u64=0;var i:usize=0;
                if(comptime builtin.zig_backend==.stage2_llvm) {
                    const zero:@Vector(8,u8)=@splat(0);
                    while(i+8<=count):(i+=8) {
                        const flags:@Vector(8,u8)=table.scan_live[start+i..][0..8].*;
                        var bits:u8=@bitCast(flags!=zero);
                        if(comptime builtin.cpu.arch.endian()==.big) bits=@bitReverse(bits);
                        mask|=@as(u64,bits)<<@intCast(i);
                    }
                }
                while(i<count):(i+=1) mask|=@as(u64,@intFromBool(table.scan_live[start+i]!=0))<<@intCast(i);
                return mask;
            }

            fn comparisonMask(comptime op: ast.Op, table: *const S.Table, start: usize, count: usize, predicate: CompactPredicate, stats:?*StreamStats) u64 {
                if(comptime S.presence_enabled and op==.eq) if(!S.blockMayContain(table,predicate.column,start,count,predicate.value)) {
                    if(stats) |value| value.presence_rejected_blocks+=1;
                    return 0;
                };
                const base = @as(usize,predicate.column) * table.rows.len + start;
                var mask: u64 = 0;
                var i: usize = 0;
                // Preserve a scalar implementation for native/codegen backends
                // that do not lower packed vector comparisons yet.
                if (comptime builtin.zig_backend == .stage2_llvm) {
                  const rhs: @Vector(8,i64) = @splat(predicate.value);
                  while (i + 8 <= count) : (i += 8) {
                    const values: @Vector(8,i64) = table.scan_values[base+i..][0..8].*;
                    const matched = switch(op) {
                        .eq => values == rhs, .ne => values != rhs,
                        .lt => values < rhs, .le => values <= rhs,
                        .gt => values > rhs, .ge => values >= rhs,
                        else => unreachable,
                    };
                    var bits: u8 = @bitCast(matched);
                    if (!predicate.nonnull) {
                        const flags: @Vector(8,u64) = table.scan_nonnull[start+i..][0..8].*;
                        const bit: @Vector(8,u64) = @splat(@as(u64,1) << @intCast(predicate.column));
                        const zero: @Vector(8,u64) = @splat(0);
                        bits &= @as(u8,@bitCast((flags & bit) != zero));
                    }
                    if (comptime builtin.cpu.arch.endian() == .big) bits = @bitReverse(bits);
                    mask |= @as(u64,bits) << @intCast(i);
                  }
                }
                while (i < count) : (i += 1) {
                    const value = table.scan_values[base+i];
                    const matched = switch(op) {
                        .eq => value == predicate.value, .ne => value != predicate.value,
                        .lt => value < predicate.value, .le => value <= predicate.value,
                        .gt => value > predicate.value, .ge => value >= predicate.value,
                        else => unreachable,
                    };
                    const valid = predicate.nonnull or table.scan_nonnull[start+i] & (@as(u64,1) << @intCast(predicate.column)) != 0;
                    mask |= @as(u64,@intFromBool(matched and valid)) << @intCast(i);
                }
                return mask;
            }

            const CompactFold = struct {
                table: *const S.Table, domain: DenseDomain, grouped: bool, key_nonnull: bool,
                transitions: []const Transition, nonnull: []const bool,
                present: *[4097]bool, counts: *[4][4097]i64, totals: *[4][4097]i64,
                fused: bool, count_index: usize, sum_index: usize,
                presence_count: ?usize,
                inline fn add(self: *const CompactFold, slot: usize) void {
                    const table = self.table;
                    const bucket: usize = if (!self.grouped) 0 else if (!self.key_nonnull and table.scan_nonnull[slot] & (@as(u64,1) << @intCast(self.domain.column)) == 0) self.domain.span
                        else @intCast(@as(i128,table.scan_values[@as(usize,self.domain.column)*table.rows.len+slot])-self.domain.base);
                    if (self.presence_count == null) self.present[bucket] = true;
                    if (self.fused) {
                        self.counts[self.count_index][bucket] += 1;
                        self.totals[self.sum_index][bucket] += table.scan_values[@as(usize,self.transitions[self.sum_index].column)*table.rows.len+slot];
                    } else for (self.transitions,0..) |item,i| {
                        if (item.kind != .count_star and !self.nonnull[i] and table.scan_nonnull[slot] & (@as(u64,1) << @intCast(item.column)) == 0) continue;
                        self.counts[i][bucket] += 1;
                        if (item.kind == .sum_integer or item.kind == .sum_wide) self.totals[i][bucket] += table.scan_values[@as(usize,item.column)*table.rows.len+slot];
                    }
                }
            };

            inline fn countSumDense(keys: []const i64, values: []const i64, noalias counts: *[4097]i64, noalias sums: *[4097]i64, base: i64) void {
                for (keys,values) |key,value| {
                    // The validated domain is <=4096 wide. Modular subtraction
                    // is exact even when that signed interval crosses zero.
                    const bucket:usize=@intCast(@as(u64,@bitCast(key)) -% @as(u64,@bitCast(base)));
                    counts[bucket]+=1;sums[bucket]+=value;
                }
            }

            inline fn countSumMasked(keys: []const i64, values: []const i64, noalias counts: *[4097]i64, noalias sums: *[4097]i64, base: i64, selected: u64) void {
                var mask=selected;
                while(mask!=0) {
                    const i=@ctz(mask);mask&=mask-1;
                    const bucket:usize=@intCast(@as(u64,@bitCast(keys[i])) -% @as(u64,@bitCast(base)));
                    counts[bucket]+=1;sums[bucket]+=values[i];
                }
            }

            /// Integral committed scans use caller-backed column-major data
            /// and compact per-group arithmetic, not padded Cell unions.
            /// The shared publication/replay path maintains this projection;
            /// it is never a cached SQL result or a speculative row snapshot.
            noinline fn compactGroup(self: *Query, p: *const B.Plan, outer: ?*const E.Context, table: *const S.Table) Error!?List {
                if (!self.committed_only or !table.summary.valid or table.summary.csn > self.snap.csn or p.key_count > 1 or p.agg_count > 4) return null;
                var transitions: [4]Transition = undefined;
                if (!self.prepareTransitions(p, transitions[0..p.agg_count])) return null;
                var nonnull: [4]bool = undefined;
                for (p.aggs[0..p.agg_count], 0..) |agg, i| {
                    // At most 2^31-1 values of these types fit exactly in i64.
                    // int8 inputs retain prefix-overflow/wide numeric handling.
                    if (agg.kind != .count and agg.kind != .count_star and agg.arg_ty != .int2 and agg.arg_ty != .int4 and agg.arg_ty != .oid) return null;
                    nonnull[i] = agg.kind == .count_star or table.summary.columns[transitions[i].column].nonnull == table.summary.rows;
                }
                const domain: DenseDomain = if (p.key_count == 0) .{ .column = 0, .base = 0, .span = 0 } else self.denseDomain(p, table, 4097) orelse return null;
                var predicates: [config.predicates]CompactPredicate = undefined;
                var predicate_count: usize = 0;
                if (!compactPredicates(self.pool, p.where, table, &predicates, &predicate_count)) return null;
                const size = domain.span + 1;
                var present: [4097]bool = undefined;
                var counts: [4][4097]i64 = undefined;
                var totals: [4][4097]i64 = undefined;
                @memset(present[0..size], false);
                for (0..p.agg_count) |i| { @memset(counts[i][0..size], 0); @memset(totals[i][0..size], 0); }
                if (p.key_count == 0) present[0] = true;
                const dense = table.summary.rows == @as(i64, @intCast(table.scan_high));
                const key_nonnull = p.key_count == 0 or table.summary.columns[domain.column].nonnull == table.summary.rows;
                var count_index:usize=0;var sum_index:usize=1;var fused=false;
                var presence_count:?usize=null;
                for(transitions[0..p.agg_count],0..) |item,i| if(item.kind==.count_star) {presence_count=i;break;};
                if (p.agg_count == 2) {
                    if (transitions[1].kind == .count_star) { count_index=1;sum_index=0; }
                    fused=transitions[count_index].kind==.count_star and transitions[sum_index].kind==.sum_integer and nonnull[sum_index];
                }
                const fold:CompactFold=.{.table=table,.domain=domain,.grouped=p.key_count!=0,.key_nonnull=key_nonnull,
                    .transitions=transitions[0..p.agg_count],.nonnull=nonnull[0..p.agg_count],.present=&present,.counts=&counts,.totals=&totals,
                    .fused=fused,.count_index=count_index,.sum_index=sum_index,.presence_count=presence_count};
                var visited:usize=0;
                defer { self.work.stream_stats.rows+=visited;self.work.stream_stats.compact_rows+=visited; }
                var start:usize=0;
                while (start < table.scan_high) : (start += 64) {
                    const count=@min(@as(usize,64),table.scan_high-start);
                    // Reserve/check every input step before reading this bounded
                    // block. A work/cancel failure still leaves results private.
                    try self.session.checkpoints(count);
                    var mask=liveMask(table,start,count,dense);
                    visited+=@popCount(mask);
                    for (predicates[0..predicate_count]) |predicate| mask &= switch(predicate.op) {
                        .eq=>comparisonMask(.eq,table,start,count,predicate,&self.work.stream_stats),.ne=>comparisonMask(.ne,table,start,count,predicate,&self.work.stream_stats),
                        .lt=>comparisonMask(.lt,table,start,count,predicate,&self.work.stream_stats),.le=>comparisonMask(.le,table,start,count,predicate,&self.work.stream_stats),
                        .gt=>comparisonMask(.gt,table,start,count,predicate,&self.work.stream_stats),.ge=>comparisonMask(.ge,table,start,count,predicate,&self.work.stream_stats),
                        else=>unreachable,
                    };
                    if (fused and p.key_count!=0 and key_nonnull) {
                        const keys=table.scan_values[@as(usize,domain.column)*table.rows.len+start..][0..count];
                        const values=table.scan_values[@as(usize,transitions[sum_index].column)*table.rows.len+start..][0..count];
                        const full:u64=if(count==64) ~@as(u64,0) else (@as(u64,1)<<@intCast(count))-1;
                        if(mask==full) countSumDense(keys,values,&counts[count_index],&totals[sum_index],domain.base)
                        else countSumMasked(keys,values,&counts[count_index],&totals[sum_index],domain.base,mask);
                    } else if (predicate_count==0 and dense) {
                        for (0..count) |i| fold.add(start+i);
                    } else while (mask!=0) {
                        const i=@ctz(mask);mask&=mask-1;fold.add(start+i);
                    }
                }
                if(p.key_count!=0) if(presence_count) |index| for(present[0..size],0..) |*exists,bucket| {exists.*=counts[index][bucket]!=0;};
                var groups: usize = 0;
                for (present[0..size]) |used| groups += @intFromBool(used);
                var out: List = .{};
                self.work.stream_stats.compact_plans += 1;
                if (groups == 0) return try self.finish(p, out);
                const tickets = try self.refs(groups);
                var used: usize = 0;
                var states: [config.columns]Accumulator = undefined;
                // Retain the ordinary key sort/projection, HAVING and output
                // validation. No result bytes are published by this scan.
                for (present[0..size], 0..) |exists, bucket| {
                    if (!exists) continue;
                    try self.session.checkpoint();
                    const at = try self.cells(p.key_count + p.agg_count);
                    if (p.key_count != 0) self.work.cells[at] = if (bucket == domain.span) .null_value else .{ .integer = domain.base + @as(i64, @intCast(bucket)) };
                    // Store the bucket ID after the keys/aggregate output.
                    const bucket_cell = try self.cells(1);
                    self.work.cells[bucket_cell] = .{ .integer = @intCast(bucket) };
                    self.work.refs[tickets + used] = at;
                    used += 1;
                }
                if (p.key_count != 0) {
                    const scratch = try self.refs(groups);
                    const sorter: GroupSorter = .{ .query = self, .width = 1 };
                    _ = try sort_module.mergeSort(self.work.refs[tickets..][0..groups], self.work.refs[scratch..][0..groups], &sorter);
                }
                for (self.work.refs[tickets..][0..groups]) |at| {
                    const bucket: usize = @intCast(self.work.cells[at + p.key_count + p.agg_count].integer);
                    for (states[0..p.agg_count], 0..) |*state, i| state.* = .{ .count = counts[if(fused and i==sum_index) count_index else i][bucket], .integer = totals[i][bucket], .wide = totals[i][bucket] };
                    try self.projectGroup(p, at, states[0..p.agg_count], outer, &out);
                }
                self.work.stream_stats.groups += groups;
                self.work.stream_stats.scratch_cells = @max(self.work.stream_stats.scratch_cells, groups * (p.key_count + p.agg_count + 1));
                self.work.stream_stats.scratch_refs = @max(self.work.stream_stats.scratch_refs, groups * 2);
                return try self.finish(p, out);
            }

            /// Consume visible base-table versions directly. State grows with
            /// groups, not scanned rows. All output remains private until the
            const StreamCursor=struct {
                next:usize=0,
                high:usize=0,
                columns:?u64=null,
                prefix:?CompactPredicate=null,
                prefix_mask:u64=0,
                prefix_start:usize=0,
                cascade:[config.predicates]CompactPredicate=undefined,
                cascade_count:usize=0,
                all_live:bool=false,
                all_nonnull:bool=false,
                row:if(S.compact_enabled) [config.columns]V.Cell else [0]V.Cell=undefined,
            };

            fn prefixOperandSafe(self:*const Query,id:u16) bool {
                const node=self.pool.nodes[id];
                return node.kind==.int_literal or (node.kind==.column and node.level==0 and value_module.integral(node.ty));
            }
            fn prefixOnSafe(self:*const Query,id:u16) bool {
                if(id==none) return true;
                const node=self.pool.nodes[id];
                if(node.kind==.and_op or node.kind==.or_op) return self.prefixOnSafe(node.a) and self.prefixOnSafe(node.b);
                if(node.kind!=.binary) return false;
                return switch(node.op) {
                    .eq,.ne,.lt,.le,.gt,.ge=>self.prefixOperandSafe(node.a) and self.prefixOperandSafe(node.b),
                    else=>false,
                };
            }
            fn prefixJoinsSafe(self:*const Query,p:*const B.Plan) bool {
                for(p.sources[1..p.source_count]) |source| {
                    if(source.probe!=none and !self.prefixOperandSafe(source.probe)) return false;
                    if(!self.prefixOnSafe(source.on)) return false;
                }
                return true;
            }
            fn prefixCanReject(table:*const S.Table,predicate:CompactPredicate) bool {
                const bounds=table.integer_bounds[predicate.column];
                if(!bounds.known) return true;
                // Bounds include pending/aborted inserts too. Proving that
                // even this conservative domain always passes safely avoids
                // an extra pass for an unselective leading conjunct.
                return switch(predicate.op) {
                    .eq=>bounds.low!=predicate.value or bounds.high!=predicate.value,
                    .ne=>predicate.value>=bounds.low and predicate.value<=bounds.high,
                    .lt=>bounds.high>=predicate.value,
                    .le=>bounds.high>predicate.value,
                    .gt=>bounds.low<=predicate.value,
                    .ge=>bounds.low<predicate.value,
                    else=>false,
                };
            }

            fn projectionList(self:*const Query,table:*const S.Table,first:u16,columns:*u64,depth:usize,budget:*usize) bool {
                var id=first;
                while(id!=none) {
                    if(!self.projectionNode(table,id,columns,depth,budget)) return false;
                    id=self.pool.nodes[id].next;
                }
                return true;
            }
            fn projectionNode(self:*const Query,table:*const S.Table,id:u16,columns:*u64,depth:usize,budget:*usize) bool {
                if(id==none) return true;
                if(depth>=config.expr_depth or budget.*==0) return false;
                budget.*-=1;
                const node=self.pool.nodes[id];
                switch(node.kind) {
                    .column=>{
                        if(node.level!=0 or node.relation!=0) return true;
                        if(node.column>=table.column_count) return false;
                        switch(table.columns[node.column].data_type) {
                            .smallint,.integer32,.integer,.oid=>if(!value_module.integral(node.ty)) return false,
                            .date=>if(node.ty!=.date) return false,
                            else=>return false,
                        }
                        columns.*|=@as(u64,1)<<@intCast(node.column);return true;
                    },
                    .null_literal,.bool_literal,.int_literal,.text_literal,.decimal_literal=>return true,
                    .unary,.not_op,.test_op,.cast=>return self.projectionNode(table,node.a,columns,depth+1,budget),
                    .binary,.and_op,.or_op,.nullif,.when_arm,.at_zone=>return self.projectionNode(table,node.a,columns,depth+1,budget) and self.projectionNode(table,node.b,columns,depth+1,budget),
                    .between,.like=>return self.projectionNode(table,node.a,columns,depth+1,budget) and self.projectionNode(table,node.b,columns,depth+1,budget) and self.projectionNode(table,node.c,columns,depth+1,budget),
                    .in_list=>return self.projectionNode(table,node.a,columns,depth+1,budget) and self.projectionList(table,node.b,columns,depth+1,budget),
                    .row_in=>return self.projectionList(table,node.b,columns,depth+1,budget),
                    .coalesce,.function=>return self.projectionList(table,node.b,columns,depth+1,budget),
                    .case_expr=>return self.projectionNode(table,node.a,columns,depth+1,budget) and self.projectionList(table,node.b,columns,depth+1,budget) and self.projectionNode(table,node.c,columns,depth+1,budget),
                    .aggregate=>return self.projectionNode(table,node.a,columns,depth+1,budget) and self.projectionNode(table,node.c,columns,depth+1,budget),
                    else=>return false,
                }
            }
            fn projectionColumns(self:*const Query,p:*const B.Plan,table:*const S.Table,columns:*u64) bool {
                // Relation numbers are local to a query block. Walking the
                // whole shared pool confuses unrelated CTE/outer columns with
                // this fact table and can disable (or over-gather) projection.
                var budget:usize=config.expr_nodes*4;
                if(!self.projectionNode(table,p.where,columns,0,&budget) or !self.projectionNode(table,p.having,columns,0,&budget)) return false;
                for(p.keys[0..p.key_count]) |id| if(!self.projectionNode(table,id,columns,0,&budget)) return false;
                for(p.aggs[0..p.agg_count]) |agg| if(!self.projectionNode(table,agg.arg,columns,0,&budget) or !self.projectionNode(table,agg.filter,columns,0,&budget)) return false;
                for(p.targets[0..p.width]) |id| if(!self.projectionNode(table,id,columns,0,&budget)) return false;
                for(p.distinct_on[0..p.distinct_on_count]) |id| if(!self.projectionNode(table,id,columns,0,&budget)) return false;
                for(p.sources[0..p.source_count]) |source| if(!self.projectionNode(table,source.on,columns,0,&budget) or !self.projectionNode(table,source.probe,columns,0,&budget)) return false;
                return true;
            }

            fn boundDate(node:*const ast.Node) ?i64 {
                if(node.ty!=.date or !node.date_bound or (node.kind!=.text_literal and node.kind!=.cast)) return null;
                return node.integer;
            }
            fn dateColumn(table:*const S.Table,node:*const ast.Node) bool {
                return node.kind==.column and node.level==0 and node.relation==0 and node.ty==.date and
                    node.column<table.column_count and table.columns[node.column].data_type==.date;
            }
            fn datePredicates(self:*const Query,id:u16,table:*const S.Table,out:*[2]CompactPredicate,used:*usize) bool {
                const node=&self.pool.nodes[id];
                if(node.kind==.between and !node.negated) {
                    const column=&self.pool.nodes[node.a];if(!dateColumn(table,column)) return false;
                    const low=boundDate(&self.pool.nodes[node.b]) orelse return false;
                    const high=boundDate(&self.pool.nodes[node.c]) orelse return false;
                    const nonnull=table.summary.columns[column.column].nonnull==table.summary.rows;
                    out[0]=.{.column=column.column,.op=.ge,.value=low,.nonnull=nonnull};
                    out[1]=.{.column=column.column,.op=.le,.value=high,.nonnull=nonnull};used.*=2;return true;
                }
                if(node.kind!=.binary) return false;
                var op=node.op;switch(op){.eq,.ne,.lt,.le,.gt,.ge=>{},else=>return false}
                var column=&self.pool.nodes[node.a];var literal=&self.pool.nodes[node.b];
                if(dateColumn(table,literal)) {
                    const swap=column;column=literal;literal=swap;
                    op=switch(op){.lt=>.gt,.le=>.ge,.gt=>.lt,.ge=>.le,else=>op};
                }
                if(!dateColumn(table,column)) return false;
                const value=boundDate(literal) orelse return false;
                out[0]=.{.column=column.column,.op=op,.value=value,.nonnull=table.summary.columns[column.column].nonnull==table.summary.rows};used.*=1;return true;
            }
            fn collectCascade(self:*const Query,id:u16,first:u16,table:*const S.Table,cursor:*StreamCursor) bool {
                if(id==first) return true;
                const node=&self.pool.nodes[id];
                if(node.kind==.and_op) return self.collectCascade(node.a,first,table,cursor) and self.collectCascade(node.b,first,table,cursor);
                var predicates:[2]CompactPredicate=undefined;var used:usize=0;
                if(!compactPredicates(self.pool,id,table,&predicates,&used)) {
                    used=0;if(!self.datePredicates(id,table,&predicates,&used)) return false;
                }
                if(used>cursor.cascade.len-cursor.cascade_count) return false;
                for(predicates[0..used]) |predicate| if(!predicate.nonnull) return false;
                for(predicates[0..used]) |predicate| if(prefixCanReject(table,predicate)) {
                    cursor.cascade[cursor.cascade_count]=predicate;cursor.cascade_count+=1;
                };
                return true;
            }
            fn prepareStreamCursor(self:*const Query,p:*const B.Plan,cursor:*StreamCursor,early:bool) void {
                const table=&self.tables[p.sources[0].table.?];
                cursor.high=table.row_high;
                if(comptime S.compact_enabled) {
                    // Exactly the committed projection guard used by compact
                    // aggregates: old snapshots and own writes retain MVCC.
                    if(!self.committed_only or !table.summary.valid or table.summary.csn>self.snap.csn) return;
                    cursor.all_live=table.summary.rows>=0 and @as(u64,@intCast(table.summary.rows))==table.scan_high and table.scan_high==table.row_high;
                    // A typed/computed residual need not prevent a safe first
                    // conjunct from rejecting fact rows before inner probes.
                    // Keep SQL's left-to-right error ordering: only the first
                    // non-null integral/literal comparison may move here.
                    if(!early and p.source_count>1 and p.where!=none and table.scan_high==table.row_high) {
                        var first=p.where;
                        while(self.pool.nodes[first].kind==.and_op) first=self.pool.nodes[first].a;
                        var predicate:[1]CompactPredicate=undefined;var used:usize=0;
                        if(self.prefixJoinsSafe(p) and compactPredicates(self.pool,first,table,&predicate,&used) and used==1 and predicate[0].nonnull and prefixCanReject(table,predicate[0])) {
                            cursor.prefix=predicate[0];
                            _=self.collectCascade(p.where,first,table,cursor);
                        }
                    }
                    var columns:u64=0;
                    if(!self.projectionColumns(p,table,&columns)) return;
                    cursor.all_nonnull=true;
                    var required=columns;
                    while(required!=0) {
                        const column=@ctz(required);required&=required-1;
                        if(table.summary.columns[column].nonnull!=table.summary.rows) {cursor.all_nonnull=false;break;}
                    }
                    cursor.columns=columns;cursor.high=table.scan_high;
                }
            }

            fn streamFactRow(self:*Query,table:*const S.Table,cursor:*StreamCursor,slot:usize) ?[*]const V.Cell {
                if(comptime S.compact_enabled) if(cursor.columns) |mask| {
                    if(!cursor.all_live and table.scan_live[slot]==0) return null;
                    const nonnull=if(cursor.all_nonnull) ~@as(u64,0) else table.scan_nonnull[slot];
                    var columns=mask;
                    while(columns!=0) {
                        const column=@ctz(columns);
                        const bit=@as(u64,1)<<@intCast(column);
                        if(nonnull&bit!=0) {
                            const value=table.scan_values[@as(usize,column)*table.rows.len+slot];
                            cursor.row[column]=if(table.columns[column].data_type==.date) .{.date=@intCast(value)} else .{.integer=value};
                        } else cursor.row[column]=.null_value;
                        columns&=columns-1;
                    }
                    self.work.stream_stats.gathered_rows+=1;
                    return &cursor.row;
                };
                const version=S.visibleAt(table,slot,self.snap) orelse return null;
                return &table.versions[version].cells;
            }

            /// Scan one fact row and resolve unique-key inner dimensions using
            /// borrowed version cells. Scratch depends on group cardinality,
            /// not on fact cardinality or left-deep intermediate tuple counts.
            fn nextStreamTuple(self:*Query,p:*const B.Plan,ctx:*E.Context,cursor:*StreamCursor,early:bool) Error!bool {
                const table=&self.tables[p.sources[0].table.?];
                scan: while(cursor.next<cursor.high or cursor.prefix_mask!=0) {
                    var current:usize=undefined;
                    if(comptime S.compact_enabled) {
                      if(cursor.prefix) |predicate| {
                        while(cursor.prefix_mask==0 and cursor.next<cursor.high) {
                            const start=cursor.next;const count=@min(@as(usize,64),cursor.high-start);
                            try self.session.checkpoints(count);
                            var mask=liveMask(table,start,count,cursor.all_live);
                            const visible=@popCount(mask);
                            self.work.stream_stats.rows+=visible;
                            try self.session.checkpoints(visible);
                            mask &= switch(predicate.op) {
                                .eq=>comparisonMask(.eq,table,start,count,predicate,&self.work.stream_stats),
                                .ne=>comparisonMask(.ne,table,start,count,predicate,&self.work.stream_stats),
                                .lt=>comparisonMask(.lt,table,start,count,predicate,&self.work.stream_stats),
                                .le=>comparisonMask(.le,table,start,count,predicate,&self.work.stream_stats),
                                .gt=>comparisonMask(.gt,table,start,count,predicate,&self.work.stream_stats),
                                .ge=>comparisonMask(.ge,table,start,count,predicate,&self.work.stream_stats),
                                else=>unreachable,
                            };
                            self.work.stream_stats.prefix_rejected+=visible-@popCount(mask);
                            for(cursor.cascade[0..cursor.cascade_count]) |extra| {
                                if(mask==0) break;
                                const before=@popCount(mask);try self.session.checkpoints(before);
                                const single=[_]CompactPredicate{extra};var selected=mask;
                                while(selected!=0) {
                                    const i=@ctz(selected);selected&=selected-1;
                                    if(!compactKeep(table,start+i,&single)) mask&=~(@as(u64,1)<<@intCast(i));
                                }
                                self.work.stream_stats.cascade_rejected+=before-@popCount(mask);
                            }
                            cursor.prefix_start=start;cursor.prefix_mask=mask;cursor.next+=count;
                        }
                        if(cursor.prefix_mask==0) return false;
                        current=cursor.prefix_start+@ctz(cursor.prefix_mask);
                        cursor.prefix_mask&=cursor.prefix_mask-1;
                      } else {
                        try self.session.checkpoint();current=cursor.next;cursor.next+=1;
                      }
                    } else {
                        try self.session.checkpoint();current=cursor.next;cursor.next+=1;
                    }
                    const fact_cells=self.streamFactRow(table,cursor,current) orelse continue;
                    if(cursor.prefix==null) self.work.stream_stats.rows+=1;
                    ctx.row=null;ctx.tuple[0]=fact_cells;
                    if(p.source_count>1 and early and !try self.earlyKeep(ctx,p.where,0)) continue;
                    for(p.sources[1..p.source_count],1..) |*source,stage| {
                        try self.session.checkpoint();
                        var key_value:V.Cell=undefined;
                        const key=try E.evalRef(ctx,source.probe,&key_value);
                        if(key.*==.null_value) continue :scan;
                        const dimension=&self.tables[source.table.?];
                        self.work.stream_stats.dimension_probes+=1;
                        const visible=S.lookupVersionAt(dimension,key,self.snap) orelse continue :scan;
                        ctx.tuple[stage]=&dimension.versions[visible].cells;
                        if(source.on!=none and (try E.truth(ctx,source.on))!=true) continue :scan;
                        if(stage+1<p.source_count and early and !try self.earlyKeep(ctx,p.where,stage)) continue :scan;
                    }
                    if(try keep(ctx,p.where,null)) return true;
                }
                return false;
            }

            const FactorAggregate=struct {total:i128 align(@alignOf(V.Cell))=0,count:i64=0};
            const factor_header=(@sizeOf(i64)+@alignOf(FactorAggregate)-1)/@alignOf(FactorAggregate)*@alignOf(FactorAggregate);
            fn factorRows(bytes:[*]u8) *i64 {return @ptrCast(@alignCast(bytes));}
            fn factorStates(bytes:[*]u8,count:usize) []FactorAggregate {
                const pointer:[*]FactorAggregate=@ptrCast(@alignCast(bytes+factor_header));return pointer[0..count];
            }
            fn factorOperand(self:*const Query,id:u16,key_column:u16) bool {
                const node=self.pool.nodes[id];
                return node.kind==.int_literal or (node.kind==.column and node.level==0 and value_module.integral(node.ty) and (node.relation!=0 or node.column==key_column));
            }
            fn factorOn(self:*const Query,id:u16,key_column:u16) bool {
                if(id==none) return true;
                const node=self.pool.nodes[id];
                if(node.kind==.and_op or node.kind==.or_op) return self.factorOn(node.a,key_column) and self.factorOn(node.b,key_column);
                if(node.kind!=.binary) return false;
                return switch(node.op) {
                    .eq,.ne,.lt,.le,.gt,.ge=>self.factorOperand(node.a,key_column) and self.factorOperand(node.b,key_column),
                    else=>false,
                };
            }
            fn factorPredicates(self:*const Query,id:u16,table:*const S.Table,out:[]CompactPredicate,used:*usize) bool {
                if(id==none) return true;
                const node=self.pool.nodes[id];
                if(node.kind==.and_op) return self.factorPredicates(node.a,table,out,used) and self.factorPredicates(node.b,table,out,used);
                var leaf:[2]CompactPredicate=undefined;var count:usize=0;
                if(!compactPredicates(self.pool,id,table,&leaf,&count)) {
                    count=0;if(!self.datePredicates(id,table,&leaf,&count)) return false;
                }
                if(count>out.len-used.*) return false;
                @memcpy(out[used.*..][0..count],leaf[0..count]);used.*+=count;return true;
            }

            /// Distribute direct fact aggregates over non-throwing unique-key
            /// inner joins. All admission/proof failures retain ordinary SQL.
            /// Scratch scales with the admitted join-key domain, never fact rows.
            noinline fn factorGroup(self:*Query,p:*const B.Plan,outer:?*const E.Context,table:*const S.Table) Error!?List {
                if(p.source_count<2 or p.key_count==0 or p.agg_count==0 or !self.committed_only or !table.summary.valid or
                    table.summary.rows<0 or table.summary.csn>self.snap.csn or table.scan_high!=table.row_high) return null;
                // Every wide integer sum of at most 2^31-1 i64 inputs fits i128.
                // Small configured NUMERIC capacities need their canonical path.
                if(comptime config.numeric_digits<39) return null;
                const join_key=self.pool.nodes[p.sources[1].probe];
                if(join_key.kind!=.column or join_key.level!=0 or join_key.relation!=0 or !value_module.integral(join_key.ty)) return null;
                for(p.sources[1..p.source_count]) |source| {
                    if(!self.factorOperand(source.probe,join_key.column) or !self.factorOn(source.on,join_key.column)) return null;
                }
                for(p.keys[0..p.key_count]) |id| {
                    const key=self.pool.nodes[id];
                    if(key.kind!=.column or key.level!=0 or key.relation==0) return null;
                    const dimension=&self.tables[p.sources[key.relation].table.?];
                    if(!S.summaryKeyType(dimension.columns[key.column].data_type)) return null;
                }
                var transitions:[config.columns]Transition=undefined;
                if(!self.prepareTransitions(p,transitions[0..p.agg_count])) return null;
                for(transitions[0..p.agg_count]) |transition| if(transition.kind==.sum_integer and table.summary.columns[transition.column].nonnull!=0) {
                    const amounts=table.integer_bounds[transition.column];if(!amounts.known) return null;
                    const n=@as(i128,table.summary.rows);
                    if(n*@as(i128,@min(amounts.low,0)) < -9223372036854775808 or n*@as(i128,@max(amounts.high,0))>9223372036854775807) return null;
                };
                var predicates:[config.predicates*2]CompactPredicate=undefined;var predicate_count:usize=0;
                if(!self.factorPredicates(p.where,table,&predicates,&predicate_count)) return null;
                const bounds=table.integer_bounds[join_key.column];if(!bounds.known) return null;
                const span128=@as(i128,bounds.high)-bounds.low+1;
                const stride=factor_header+p.agg_count*@sizeOf(FactorAggregate);
                const state_cells=(stride+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell);
                const cells_per_key=(stride+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell)+p.key_count+p.agg_count+state_cells+p.width+1;
                const domain_budget=@min((self.work.cell_high-self.work.cell_low)/cells_per_key,(self.work.ref_high-self.work.ref_low)/16);
                if(span128<=0 or span128>domain_budget) return null;
                const span:usize=@intCast(span128);
                const bytes=span*stride;
                const cell_start=self.work.cell_low;const ref_start=self.work.ref_low;
                const partial_at=try self.cells((bytes+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell));
                const partial:[*]u8=@ptrCast(&self.work.cells[partial_at]);@memset(partial[0..bytes],0);
                var slots:usize=2;while(slots<span*2) slots*=2;
                const buckets=try self.refs(slots);@memset(self.work.refs[buckets..][0..slots],absent);
                const tickets=try self.refs(span);var groups:usize=0;
                const key_nonnull=table.summary.columns[join_key.column].nonnull==table.summary.rows;
                const dense=table.summary.rows==@as(i64,@intCast(table.scan_high));
                var start:usize=0;
                while(start<table.scan_high):(start+=64) {
                    const count=@min(@as(usize,64),table.scan_high-start);try self.session.checkpoints(count);
                    var mask=liveMask(table,start,count,dense);self.work.stream_stats.rows+=@popCount(mask);
                    for(predicates[0..predicate_count]) |predicate| {
                        if(mask==0) break;
                        mask&=switch(predicate.op) {
                            .eq=>comparisonMask(.eq,table,start,count,predicate,&self.work.stream_stats),.ne=>comparisonMask(.ne,table,start,count,predicate,&self.work.stream_stats),
                            .lt=>comparisonMask(.lt,table,start,count,predicate,&self.work.stream_stats),.le=>comparisonMask(.le,table,start,count,predicate,&self.work.stream_stats),
                            .gt=>comparisonMask(.gt,table,start,count,predicate,&self.work.stream_stats),.ge=>comparisonMask(.ge,table,start,count,predicate,&self.work.stream_stats),else=>unreachable,
                        };
                    }
                    while(mask!=0) {
                        const i=@ctz(mask);mask&=mask-1;const slot=start+i;const flags=table.scan_nonnull[slot];
                        if(!key_nonnull and flags&(@as(u64,1)<<@intCast(join_key.column))==0) continue;
                        const key=table.scan_values[@as(usize,join_key.column)*table.rows.len+slot];
                        const at=partial+@as(usize,@intCast(@as(i128,key)-bounds.low))*stride;
                        factorRows(at).*+=1;self.work.stream_stats.factor_selected_rows+=1;
                        for(transitions[0..p.agg_count],factorStates(at,p.agg_count)) |transition,*state| {
                            if(transition.kind==.count_star) {state.count+=1;continue;}
                            if(flags&(@as(u64,1)<<@intCast(transition.column))==0) continue;
                            state.count+=1;
                            if(transition.kind==.sum_integer or transition.kind==.sum_wide) state.total+=table.scan_values[@as(usize,transition.column)*table.rows.len+slot];
                        }
                    }
                }
                var ctx=self.context(outer);var fact:[config.columns]V.Cell=undefined;
                var key_cells:[config.columns]*const V.Cell=undefined;
                for(0..span) |key_index| {
                    const input=partial+key_index*stride;if(factorRows(input).*==0) continue;
                    self.work.stream_stats.factor_keys+=1;
                    fact[join_key.column]=.{.integer=@intCast(@as(i128,bounds.low)+key_index)};ctx.row=null;ctx.tuple[0]=&fact;
                    var matched=true;
                    for(p.sources[1..p.source_count],1..) |source,stage| {
                        try self.session.checkpoint();var temporary:V.Cell=undefined;
                        const key=try E.evalRef(&ctx,source.probe,&temporary);
                        if(key.*==.null_value) {matched=false;break;}
                        self.work.stream_stats.dimension_probes+=1;
                        const dimension=&self.tables[source.table.?];
                        const visible=S.lookupVersionAt(dimension,key,self.snap) orelse {matched=false;break;};
                        ctx.tuple[stage]=&dimension.versions[visible].cells;
                        if(source.on!=none and (try E.truth(&ctx,source.on))!=true) {matched=false;break;}
                    }
                    if(!matched) continue;
                    var hash:usize=2166136261;
                    for(p.keys[0..p.key_count],0..) |id,column| {
                        key_cells[column]=E.columnRef(&ctx,&self.pool.nodes[id]);
                        hash=(hash^(if(key_cells[column].*==.null_value) @as(usize,0x9e3779b9) else V.hash(key_cells[column])))*%16777619;
                    }
                    var bucket=hash&(slots-1);var group_at:u32=undefined;
                    while(true) {
                        try self.session.checkpoint();self.work.stream_stats.probes+=1;
                        const found=self.work.refs[buckets+bucket];
                        if(found==absent) {
                            group_at=try self.cells(p.key_count+p.agg_count+state_cells);
                            for(key_cells[0..p.key_count],0..) |key,column| self.work.cells[group_at+column]=key.*;
                            const state_bytes:[*]u8=@ptrCast(&self.work.cells[group_at+p.key_count+p.agg_count]);@memset(state_bytes[0..stride],0);
                            self.work.refs[buckets+bucket]=group_at;self.work.refs[tickets+groups]=group_at;groups+=1;break;
                        }
                        var equal=true;for(key_cells[0..p.key_count],0..) |key,column| if(V.compare(key,&self.work.cells[found+column])!=0) {equal=false;break;};
                        if(equal) {group_at=found;break;}bucket=(bucket+1)&(slots-1);
                    }
                    const output:[*]u8=@ptrCast(&self.work.cells[group_at+p.key_count+p.agg_count]);
                    factorRows(output).*+=factorRows(input).*;
                    for(factorStates(input,p.agg_count),factorStates(output,p.agg_count)) |value,*state| {state.count+=value.count;state.total+=value.total;}
                }
                if(groups!=0) {
                    const scratch=try self.refs(groups);const sorter:GroupSorter=.{.query=self,.width=p.key_count};
                    _=try sort_module.mergeSort(self.work.refs[tickets..][0..groups],self.work.refs[scratch..][0..groups],&sorter);
                }
                var out:List=.{};
                for(self.work.refs[tickets..][0..groups]) |at| {
                    const bytes_at:[*]u8=@ptrCast(&self.work.cells[at+p.key_count+p.agg_count]);var states:[config.columns]Accumulator=undefined;
                    for(factorStates(bytes_at,p.agg_count),transitions[0..p.agg_count],states[0..p.agg_count]) |value,transition,*state| {
                        state.*=.{.count=value.count,.wide=value.total,.integer=if(transition.kind==.sum_integer) @intCast(value.total) else 0};
                    }
                    try self.projectGroup(p,at,states[0..p.agg_count],outer,&out);
                }
                const result=try self.finish(p,out);
                self.work.stream_stats.factor_plans+=1;self.work.stream_stats.groups+=groups;
                self.work.stream_stats.scratch_cells=@max(self.work.stream_stats.scratch_cells,self.work.cell_low-cell_start);
                self.work.stream_stats.scratch_refs=@max(self.work.stream_stats.scratch_refs,self.work.ref_low-ref_start);
                return result;
            }

            const NestedInput=enum {none,key,rows,total};
            const NestedPredicate=struct {input:NestedInput,op:ast.Op,value:i64};
            const NestedAggregate=struct {total:i128 align(@alignOf(V.Cell))=0,extreme:i128 align(@alignOf(V.Cell))=0,count:i64=0};
            fn nestedStates(bytes:[*]u8,count:usize) []NestedAggregate {
                const pointer:[*]NestedAggregate=@ptrCast(@alignCast(bytes+factor_header));return pointer[0..count];
            }
            fn nestedInput(self:*const Query,first:u16,outputs:[]const NestedInput) NestedInput {
                var id=first;
                for(0..config.expr_depth) |_| {
                    const node=self.pool.nodes[id];
                    if(node.kind==.cast and node.ty==.numeric and node.typmod<0) {id=node.a;continue;}
                    if(node.kind==.column and node.level==0 and node.relation==0 and node.column<outputs.len) return outputs[node.column];
                    return .none;
                }
                return .none;
            }
            fn nestedLiteral(self:*const Query,first:u16) ?i64 {
                var id=first;
                for(0..config.expr_depth) |_| {
                    const node=self.pool.nodes[id];
                    if(node.kind==.cast and node.ty==.numeric and node.typmod<0) {id=node.a;continue;}
                    return if(node.kind==.int_literal) node.integer else null;
                }
                return null;
            }
            fn nestedPredicates(self:*const Query,id:u16,outputs:[]const NestedInput,out:[]NestedPredicate,used:*usize) bool {
                if(id==none) return true;
                const node=self.pool.nodes[id];
                if(node.kind==.and_op) return self.nestedPredicates(node.a,outputs,out,used) and self.nestedPredicates(node.b,outputs,out,used);
                if(node.kind!=.binary or used.*==out.len) return false;
                var op=node.op;switch(op){.eq,.ne,.lt,.le,.gt,.ge=>{},else=>return false}
                var input=self.nestedInput(node.a,outputs);var literal=self.nestedLiteral(node.b);
                if(input==.none or literal==null) {
                    input=self.nestedInput(node.b,outputs);literal=self.nestedLiteral(node.a);
                    op=switch(op){.lt=>.gt,.le=>.ge,.gt=>.lt,.ge=>.le,else=>op};
                }
                if(input==.none or literal==null) return false;
                out[used.*]=.{.input=input,.op=op,.value=literal.?};used.*+=1;return true;
            }
            fn nestedValue(input:NestedInput,key:i64,bucket:*const NarrowBucket) i128 {
                return switch(input){.key=>key,.rows=>bucket.rows,.total=>bucket.total,.none=>unreachable};
            }

            /// Carry a non-null COUNT/SUM producer directly into a grouped
            /// unique-key consumer. No producer Cell table or NUMERIC per key.
            noinline fn nestedFactorGroup(self:*Query,p:*const B.Plan,outer:?*const E.Context) Error!?List {
                if(outer!=null or p.set_op!=.none or p.correlated or !p.grouped or p.source_count!=2 or p.key_count==0 or p.agg_count==0 or !self.committed_only) return null;
                if(comptime config.numeric_digits<39) return null;
                const source=p.sources[0];var producer_id=source.plan;
                if(source.table!=null or source.view!=null or p.sources[1].table==null or p.sources[1].join!=.inner or p.sources[1].probe==none) return null;
                if(source.cte!=B.no_cte) {
                    // A shared/recursive producer owns a materialization lifetime.
                    // Fuse only a single consumer, leaving that lifetime untouched.
                    for(self.plans.ctes[0..self.plans.cte_len]) |definition| if(definition.recursive) {return null;};
                    if(self.work.ctes[source.cte].state!=.idle) return null;
                    var references:usize=0;for(self.plans.items[0..self.plans.len]) |plan| for(plan.sources[0..plan.source_count]) |item| {references+=@intFromBool(item.cte==source.cte);};
                    if(references!=1) return null;
                    producer_id=self.plans.ctes[source.cte].plan;
                }
                if(producer_id==none) return null;
                const producer=&self.plans.items[producer_id];
                if(producer.set_op!=.none or producer.correlated or !producer.grouped or producer.source_count!=1 or producer.sources[0].table==null or
                    producer.where!=none or producer.having!=none or producer.key_count!=1 or producer.agg_count!=2 or producer.order_count!=0 or
                    producer.distinct!=.none or producer.limit!=0xffffffffffffffff or producer.offset!=0) return null;
                const table=&self.tables[producer.sources[0].table.?];
                if(!table.summary.valid or table.summary.rows<0 or table.summary.csn>self.snap.csn or table.scan_high!=table.row_high) return null;
                const key=self.pool.nodes[producer.keys[0]];
                if(key.kind!=.column or key.level!=0 or key.relation!=0 or !value_module.integral(key.ty)) return null;
                var transitions:[2]Transition=undefined;if(!self.prepareTransitions(producer,&transitions)) return null;
                const count_index:usize=if(transitions[0].kind==.count_star) 0 else 1;const sum_index=1-count_index;
                if(transitions[count_index].kind!=.count_star or (transitions[sum_index].kind!=.sum_integer and transitions[sum_index].kind!=.sum_wide)) return null;
                const sum_column=transitions[sum_index].column;
                // The narrow producer state represents every prefix exactly.
                // Nullable measures need a separate non-null count; defer those
                // to the canonical executor rather than treating NULL as zero.
                if(table.summary.columns[sum_column].nonnull!=table.summary.rows) return null;
                const amounts=table.integer_bounds[sum_column];const bounds=table.integer_bounds[key.column];if(!amounts.known or !bounds.known) return null;
                const n=@as(i128,table.summary.rows);const low=n*@as(i128,@min(amounts.low,0));const high=n*@as(i128,@max(amounts.high,0));
                if(low < -9223372036854775808 or high>9223372036854775807) return null;
                var outputs:[config.columns]NestedInput=undefined;
                for(producer.targets[0..producer.count],0..) |id,column| {
                    const target=self.pool.nodes[id];
                    if(target.kind!=.column or target.level!=0 or target.relation!=group_relation) return null;
                    outputs[column]=if(target.column==0) .key else if(target.column==1+count_index) .rows else if(target.column==1+sum_index) .total else return null;
                }
                const probe=self.pool.nodes[p.sources[1].probe];
                if(probe.kind!=.column or probe.level!=0 or probe.relation!=0 or probe.column>=producer.count or outputs[probe.column]!=.key or !self.factorOn(p.sources[1].on,probe.column)) return null;
                const dimension=&self.tables[p.sources[1].table.?];
                for(p.keys[0..p.key_count]) |id| {
                    const group_key=self.pool.nodes[id];
                    if(group_key.kind!=.column or group_key.level!=0 or group_key.relation!=1 or !S.summaryKeyType(dimension.columns[group_key.column].data_type)) return null;
                }
                var inputs:[config.columns]NestedInput=undefined;
                for(p.aggs[0..p.agg_count],0..) |agg,index| {
                    if(agg.distinct or agg.filter!=none) return null;
                    if(agg.kind==.count_star) {inputs[index]=.none;continue;}
                    if(agg.kind!=.count and agg.kind!=.sum and agg.kind!=.avg and agg.kind!=.min and agg.kind!=.max) return null;
                    const input=self.pool.nodes[agg.arg];
                    if(input.kind!=.column or input.level!=0 or input.relation!=0 or input.column>=producer.count) return null;
                    inputs[index]=outputs[input.column];
                    if(agg.kind==.sum and agg.ty==.int8) {
                        const lower:i128=switch(inputs[index]){.key=>@min(bounds.low,0),.rows=>0,.total=>low,.none=>unreachable};
                        const upper:i128=switch(inputs[index]){.key=>@max(bounds.high,0),.rows=>n,.total=>high,.none=>unreachable};
                        if(n*lower < -9223372036854775808 or n*upper>9223372036854775807) return null;
                    }
                }
                var predicates:[config.predicates]NestedPredicate=undefined;var predicate_count:usize=0;
                if(!self.nestedPredicates(p.where,outputs[0..producer.count],&predicates,&predicate_count)) return null;
                const stride=factor_header+p.agg_count*@sizeOf(NestedAggregate);const state_cells=(stride+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell);
                const per_key=1+p.key_count+p.agg_count+state_cells+p.width+1;
                const domain_budget=@min((self.work.cell_high-self.work.cell_low)/per_key,(self.work.ref_high-self.work.ref_low)/16);
                // Admission is in caller-owned bytes and handles, never a new
                // compile-time SQL row ceiling. Conservative extrema can decline.
                const span128=@as(i128,bounds.high)-bounds.low+1;if(span128<=0 or span128>domain_budget) return null;
                const span:usize=@intCast(span128);const cell_start=self.work.cell_low;const ref_start=self.work.ref_low;
                const partial_at=try self.cells((span*@sizeOf(NarrowBucket)+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell));
                const partial_ptr:[*]NarrowBucket=@ptrCast(@alignCast(&self.work.cells[partial_at]));const partial=partial_ptr[0..span];for(partial) |*bucket| bucket.*=.{};
                var slots:usize=2;while(slots<span*2) slots*=2;
                const buckets=try self.refs(slots);@memset(self.work.refs[buckets..][0..slots],absent);const tickets=try self.refs(span);var groups:usize=0;
                const dense=table.summary.rows==@as(i64,@intCast(table.scan_high));const key_nonnull=table.summary.columns[key.column].nonnull==table.summary.rows;
                var start:usize=0;
                while(start<table.scan_high):(start+=64) {
                    const count=@min(@as(usize,64),table.scan_high-start);try self.session.checkpoints(count);
                    const keys=table.scan_values[@as(usize,key.column)*table.rows.len+start..][0..count];
                    const values=table.scan_values[@as(usize,sum_column)*table.rows.len+start..][0..count];
                    if(dense and key_nonnull) {
                        self.work.stream_stats.rows+=count;
                        for(keys,values) |key_value,value| {const bucket=&partial[@intCast(@as(i128,key_value)-bounds.low)];bucket.rows+=1;bucket.total+=value;}
                    } else {
                        var mask=liveMask(table,start,count,dense);self.work.stream_stats.rows+=@popCount(mask);
                        while(mask!=0) {
                            const i=@ctz(mask);mask&=mask-1;
                            // A NULL producer key cannot pass this integral PK
                            // equality join. Its SUM is proven non-throwing above.
                            if(!key_nonnull and table.scan_nonnull[start+i]&(@as(u64,1)<<@intCast(key.column))==0) continue;
                            const bucket=&partial[@intCast(@as(i128,keys[i])-bounds.low)];bucket.rows+=1;bucket.total+=values[i];
                        }
                    }
                }
                var ctx=self.context(outer);var producer_cells:[config.columns]V.Cell=undefined;var key_cells:[config.columns]*const V.Cell=undefined;
                for(partial,0..) |*value,index| {
                    if(value.rows==0) continue;try self.session.checkpoint();self.work.stream_stats.nested_factor_keys+=1;
                    const key_value:i64=@intCast(@as(i128,bounds.low)+index);var keep_key=true;
                    for(predicates[0..predicate_count]) |predicate| {
                        const input=nestedValue(predicate.input,key_value,value);
                        const passes=switch(predicate.op){.eq=>input==predicate.value,.ne=>input!=predicate.value,.lt=>input<predicate.value,.le=>input<=predicate.value,.gt=>input>predicate.value,.ge=>input>=predicate.value,else=>unreachable};
                        if(!passes) {keep_key=false;break;}
                    }
                    if(!keep_key) continue;
                    producer_cells[probe.column]=.{.integer=key_value};ctx.row=null;ctx.tuple[0]=&producer_cells;
                    self.work.stream_stats.dimension_probes+=1;
                    const visible=S.lookupVersionAt(dimension,&producer_cells[probe.column],self.snap) orelse continue;
                    ctx.tuple[1]=&dimension.versions[visible].cells;
                    if(p.sources[1].on!=none and (try E.truth(&ctx,p.sources[1].on))!=true) continue;
                    var hash:usize=2166136261;
                    for(p.keys[0..p.key_count],0..) |id,column| {key_cells[column]=E.columnRef(&ctx,&self.pool.nodes[id]);hash=(hash^(if(key_cells[column].*==.null_value) @as(usize,0x9e3779b9) else V.hash(key_cells[column])))*%16777619;}
                    var bucket=hash&(slots-1);var group_at:u32=undefined;
                    while(true) {
                        try self.session.checkpoint();self.work.stream_stats.probes+=1;const found=self.work.refs[buckets+bucket];
                        if(found==absent) {
                            group_at=try self.cells(p.key_count+p.agg_count+state_cells);
                            for(key_cells[0..p.key_count],0..) |group_key,column| self.work.cells[group_at+column]=group_key.*;
                            const bytes:[*]u8=@ptrCast(&self.work.cells[group_at+p.key_count+p.agg_count]);@memset(bytes[0..stride],0);
                            self.work.refs[buckets+bucket]=group_at;self.work.refs[tickets+groups]=group_at;groups+=1;break;
                        }
                        var equal=true;for(key_cells[0..p.key_count],0..) |group_key,column| if(V.compare(group_key,&self.work.cells[found+column])!=0) {equal=false;break;};
                        if(equal) {group_at=found;break;}bucket=(bucket+1)&(slots-1);
                    }
                    const bytes:[*]u8=@ptrCast(&self.work.cells[group_at+p.key_count+p.agg_count]);factorRows(bytes).*+=1;
                    for(p.aggs[0..p.agg_count],inputs[0..p.agg_count],nestedStates(bytes,p.agg_count)) |agg,input,*state| {
                        if(agg.kind==.count_star or agg.kind==.count) {state.count+=1;continue;}
                        const scalar=nestedValue(input,key_value,value);
                        if(agg.kind==.min or agg.kind==.max) state.extreme=if(state.count==0) scalar else if(agg.kind==.min) @min(state.extreme,scalar) else @max(state.extreme,scalar)
                        else state.total+=scalar;
                        state.count+=1;
                    }
                }
                if(groups!=0) {const scratch=try self.refs(groups);const sorter:GroupSorter=.{.query=self,.width=p.key_count};_=try sort_module.mergeSort(self.work.refs[tickets..][0..groups],self.work.refs[scratch..][0..groups],&sorter);}
                var out:List=.{};
                for(self.work.refs[tickets..][0..groups]) |at| {
                    const bytes:[*]u8=@ptrCast(&self.work.cells[at+p.key_count+p.agg_count]);var states:[config.columns]Accumulator=undefined;
                    for(p.aggs[0..p.agg_count],nestedStates(bytes,p.agg_count),states[0..p.agg_count]) |agg,value,*state| {
                        state.*=.{.count=value.count,.wide=value.total};
                        if(value.count!=0) {
                            if(agg.kind==.min or agg.kind==.max) state.value=if(value_module.integral(agg.arg_ty)) .{.integer=@intCast(value.extreme)} else try self.numericOf(value.extreme)
                            else if(agg.kind==.sum or agg.kind==.avg) {
                                if(!value_module.integral(agg.arg_ty)) state.value=try self.numericOf(value.total)
                                else if(agg.kind==.sum and agg.ty==.int8) state.integer=@intCast(value.total);
                            }
                        }
                    }
                    try self.projectGroup(p,at,states[0..p.agg_count],outer,&out);
                }
                const result=try self.finish(p,out);self.work.stream_stats.nested_factor_plans+=1;self.work.stream_stats.groups+=groups;
                self.work.stream_stats.scratch_cells=@max(self.work.stream_stats.scratch_cells,self.work.cell_low-cell_start);self.work.stream_stats.scratch_refs=@max(self.work.stream_stats.scratch_refs,self.work.ref_low-ref_start);
                return result;
            }

            const WideBucket=struct {
                // Storage references admit at most 2^31-1 rows; even i64 input
                // extremes therefore fit exactly in this signed i128 total.
                total:i128 align(@alignOf(V.Cell))=0,
                rows:i64=0,
                nonnull:i64=0,
            };
            const NarrowBucket=struct {total:i64=0,rows:i64=0};

            /// Exact wide arithmetic over bounded integral grouping domains.
            /// The state is borrowed from the query arena, never a comptime
            /// cardinality-sized array or an input-sized handle list.
            noinline fn wideDenseGroup(self:*Query,p:*const B.Plan,outer:?*const E.Context,table:*const S.Table) Error!?List {
                if(!self.committed_only or !table.summary.valid or table.summary.csn>self.snap.csn or p.where!=none or p.key_count!=1 or p.agg_count!=2) return null;
                const key=self.pool.nodes[p.keys[0]];
                if(key.kind!=.column or key.level!=0 or key.relation!=0 or !value_module.integral(key.ty)) return null;
                var transitions:[2]Transition=undefined;
                if(!self.prepareTransitions(p,&transitions)) return null;
                const count_index:usize=if(transitions[0].kind==.count_star) 0 else 1;
                const sum_index=1-count_index;
                if(transitions[count_index].kind!=.count_star or transitions[sum_index].kind!=.sum_wide) return null;
                const bounds=table.integer_bounds[key.column];
                if(!bounds.known) return null;
                const sum_column=transitions[sum_index].column;
                const amounts=table.integer_bounds[sum_column];
                if(amounts.known and table.summary.rows>=0 and table.summary.columns[sum_column].nonnull==table.summary.rows) {
                    const rows=@as(i128,table.summary.rows);
                    const low=rows*@as(i128,@min(amounts.low,0));
                    const high=rows*@as(i128,@max(amounts.high,0));
                    // This bounds every group AND every accumulation prefix,
                    // including mixed signs, not just the final table total.
                    if(low>=-9223372036854775808 and high<=9223372036854775807)
                        return self.typedDenseGroup(p,outer,table,key.column,bounds,sum_column,count_index,sum_index,true);
                }
                return self.typedDenseGroup(p,outer,table,key.column,bounds,sum_column,count_index,sum_index,false);
            }

            noinline fn typedDenseGroup(self:*Query,p:*const B.Plan,outer:?*const E.Context,table:*const S.Table,key_column:u16,bounds:S.IntegerBounds,sum_column:u16,count_index:usize,sum_index:usize,comptime narrow:bool) Error!?List {
                const Bucket=if(narrow) NarrowBucket else WideBucket;
                const span128=@as(i128,bounds.high)-bounds.low+1;
                const cell_budget=self.work.cell_high-self.work.cell_low;
                const ref_budget=self.work.ref_high-self.work.ref_low;
                const output_cells=1+p.agg_count+p.width;
                // Round state cost upward per domain entry and leave room for
                // all output groups and finish/sort handles before reserving.
                const state_per_bucket=(@sizeOf(Bucket)+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell);
                const bucket_budget=@min(cell_budget/(state_per_bucket+output_cells),ref_budget/4);
                if(span128+1>bucket_budget) return null;
                const span:usize=@intCast(span128);const size=span+1;
                const state_cells=(size*@sizeOf(Bucket)+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell);
                const state_at=try self.cells(state_cells);
                const ptr:[*]Bucket=@ptrCast(@alignCast(&self.work.cells[state_at]));
                const buckets=ptr[0..size];for(buckets) |*bucket| bucket.*=.{};
                const key_nonnull=table.summary.columns[key_column].nonnull==table.summary.rows;
                const sum_nonnull=if(narrow) true else table.summary.columns[sum_column].nonnull==table.summary.rows;
                const dense=table.summary.rows==@as(i64,@intCast(table.scan_high));
                var visited:usize=0;defer {self.work.stream_stats.rows+=visited;self.work.stream_stats.compact_rows+=visited;}
                var start:usize=0;
                while(start<table.scan_high):(start+=64) {
                    const count=@min(@as(usize,64),table.scan_high-start);
                    try self.session.checkpoints(count);
                    const keys=table.scan_values[@as(usize,key_column)*table.rows.len+start..][0..count];
                    const values=table.scan_values[@as(usize,sum_column)*table.rows.len+start..][0..count];
                    if(dense and key_nonnull and sum_nonnull) {
                        visited+=count;
                        for(keys,values) |key_value,value| {
                            const bucket=&buckets[@intCast(@as(i128,key_value)-bounds.low)];
                            bucket.rows+=1;
                            if(comptime !narrow) bucket.nonnull+=1;
                            bucket.total+=value;
                        }
                    } else {
                        var mask=liveMask(table,start,count,dense);visited+=@popCount(mask);
                        while(mask!=0) {
                            const i=@ctz(mask);mask&=mask-1;
                            const nonnull=table.scan_nonnull[start+i];
                            const slot:usize=if(!key_nonnull and nonnull&(@as(u64,1)<<@intCast(key_column))==0) span else @intCast(@as(i128,keys[i])-bounds.low);
                            const bucket=&buckets[slot];bucket.rows+=1;
                            if(sum_nonnull or nonnull&(@as(u64,1)<<@intCast(sum_column))!=0) {
                                if(comptime !narrow) bucket.nonnull+=1;
                                bucket.total+=values[i];
                            }
                        }
                    }
                }
                var out:List=.{};var groups:usize=0;
                // Canonical grouping order uses NULL first, then integral keys.
                // Final SQL ORDER BY/HAVING/projection still run normally.
                for(0..size) |index| {
                    const bucket_index=if(index==0) span else index-1;
                    const bucket=&buckets[bucket_index];if(bucket.rows==0) continue;
                    const at=try self.cells(1+p.agg_count);
                    self.work.cells[at]=if(bucket_index==span) .null_value else .{.integer=@intCast(@as(i128,bounds.low)+bucket_index)};
                    var states:[2]Accumulator=.{.{},.{}};
                    states[count_index].count=bucket.rows;
                    states[sum_index].count=if(narrow) bucket.rows else bucket.nonnull;states[sum_index].wide=bucket.total;
                    try self.projectGroup(p,at,&states,outer,&out);groups+=1;
                }
                self.work.stream_stats.wide_dense_plans+=1;
                self.work.stream_stats.narrow_dense_plans+=@intFromBool(narrow);
                self.work.stream_stats.groups+=groups;
                self.work.stream_stats.scratch_cells=@max(self.work.stream_stats.scratch_cells,state_cells+groups*(1+p.agg_count));
                return try self.finish(p,out);
            }

            /// A general typed state vector per admitted integral key. Multiple
            /// SUM/AVG channels stay on committed columns through aggregation;
            /// Cells are constructed only for final groups. No input-sized rows.
            noinline fn typedMultiGroup(self:*Query,p:*const B.Plan,outer:?*const E.Context,table:*const S.Table) Error!?List {
                if(!self.committed_only or !table.summary.valid or table.summary.rows<0 or table.summary.csn>self.snap.csn or
                    table.scan_high!=table.row_high or p.where!=none or p.key_count!=1 or p.agg_count==0) return null;
                if(comptime config.numeric_digits<39) return null;
                const key=self.pool.nodes[p.keys[0]];
                if(key.kind!=.column or key.level!=0 or key.relation!=0 or !value_module.integral(key.ty)) return null;
                var transitions:[config.columns]Transition=undefined;
                if(!self.prepareTransitions(p,transitions[0..p.agg_count])) return null;
                // Preserve canonical checked-i64 SUM semantics: every possible
                // accumulation prefix must fit, not merely the final total.
                for(transitions[0..p.agg_count]) |item| if(item.kind==.sum_integer and table.summary.columns[item.column].nonnull!=0) {
                    const amounts=table.integer_bounds[item.column];if(!amounts.known) return null;
                    const rows=@as(i128,table.summary.rows);
                    if(rows*@as(i128,@min(amounts.low,0)) < -9223372036854775808 or rows*@as(i128,@max(amounts.high,0))>9223372036854775807) return null;
                };
                const bounds=table.integer_bounds[key.column];if(!bounds.known) return null;
                const span128=@as(i128,bounds.high)-bounds.low+1;
                const stride=factor_header+p.agg_count*@sizeOf(FactorAggregate);
                const per_bucket=(stride+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell)+1+p.agg_count+p.width;
                const budget=@min((self.work.cell_high-self.work.cell_low)/per_bucket,(self.work.ref_high-self.work.ref_low)/2);
                if(span128<=0 or span128>=budget) return null;
                const span:usize=@intCast(span128);const size=span+1; // independent NULL-key state
                const bytes=size*stride;
                const state_cells=(bytes+@sizeOf(V.Cell)-1)/@sizeOf(V.Cell);
                const at=try self.cells(state_cells);
                const partial:[*]u8=@ptrCast(&self.work.cells[at]);@memset(partial[0..bytes],0);
                const key_nonnull=table.summary.columns[key.column].nonnull==table.summary.rows;
                const dense=table.summary.rows==@as(i64,@intCast(table.scan_high));
                var nonnull:[config.columns]bool=undefined;
                for(transitions[0..p.agg_count],0..) |item,index| nonnull[index]=item.kind==.count_star or table.summary.columns[item.column].nonnull==table.summary.rows;
                var start:usize=0;
                while(start<table.scan_high):(start+=64) {
                    const count=@min(@as(usize,64),table.scan_high-start);try self.session.checkpoints(count);
                    var selected=liveMask(table,start,count,dense);self.work.stream_stats.rows+=@popCount(selected);
                    while(selected!=0) {
                        const bit=@ctz(selected);selected&=selected-1;const slot=start+bit;
                        const flags=table.scan_nonnull[slot];
                        const bucket:usize=if(!key_nonnull and flags&(@as(u64,1)<<@intCast(key.column))==0) span
                            else @intCast(@as(i128,table.scan_values[@as(usize,key.column)*table.rows.len+slot])-bounds.low);
                        const state=partial+bucket*stride;factorRows(state).*+=1;
                        for(transitions[0..p.agg_count],factorStates(state,p.agg_count),0..) |item,*channel,index| {
                            if(item.kind!=.count_star and !nonnull[index] and flags&(@as(u64,1)<<@intCast(item.column))==0) continue;
                            channel.count+=1;
                            if(item.kind==.sum_integer or item.kind==.sum_wide) channel.total+=table.scan_values[@as(usize,item.column)*table.rows.len+slot];
                        }
                    }
                }
                var out:List=.{};var groups:usize=0;
                // Canonical group order is NULL, then increasing integral keys.
                // HAVING, arithmetic/projection errors and final sort/limit
                // retain their existing implementation and private publication.
                for(0..size) |index| {
                    const bucket=if(index==0) span else index-1;const state=partial+bucket*stride;
                    if(factorRows(state).*==0) continue;
                    try self.session.checkpoint();const group_at=try self.cells(1+p.agg_count);
                    self.work.cells[group_at]=if(bucket==span) .null_value else .{.integer=@intCast(@as(i128,bounds.low)+bucket)};
                    var values:[config.columns]Accumulator=undefined;
                    for(transitions[0..p.agg_count],factorStates(state,p.agg_count),values[0..p.agg_count]) |item,channel,*value| {
                        value.*=.{.count=channel.count,.wide=channel.total};
                        if(item.kind==.sum_integer) value.integer=@intCast(channel.total);
                    }
                    try self.projectGroup(p,group_at,values[0..p.agg_count],outer,&out);groups+=1;
                }
                self.work.stream_stats.typed_group_plans+=1;self.work.stream_stats.typed_group_channels+=p.agg_count;
                self.work.stream_stats.groups+=groups;
                self.work.stream_stats.scratch_cells=@max(self.work.stream_stats.scratch_cells,state_cells+groups*(1+p.agg_count+p.width));
                self.work.stream_stats.scratch_refs=@max(self.work.stream_stats.scratch_refs,groups*2);
                return try self.finish(p,out);
            }

            /// Aggregate states and projections remain private until the
            /// ordinary query publication step succeeds.
            fn streamGroup(self: *Query, p: *const B.Plan, outer: ?*const E.Context) Error!List {
                const table = &self.tables[p.sources[0].table.?];
                if(comptime config.factorized_aggregates and S.compact_enabled and config.relations>=2) if(try self.factorGroup(p,outer,table)) |rows| return rows;
                const distinct=self.distinctLayout(p) orelse return error.WorkspaceCapacity;
                var ctx = self.context(outer);
                var out: List = .{};
                if (comptime config.summary_groups != 0) {
                    if (p.key_count == 1 and self.summaryEligible(p, table)) {
                        const key = &self.pool.nodes[p.keys[0]];
                        if (key.kind == .column and key.level == 0 and key.relation == 0 and S.summaryKeyType(table.columns[key.column].data_type)) {
                            const rollup = &table.rollups[key.column];
                            if (rollup.valid) return self.rollupGroup(p, outer, table, rollup);
                        }
                    }
                }
                if (comptime S.compact_enabled) {
                    if(p.source_count==1) if(try self.wideDenseGroup(p,outer,table)) |rows| return rows;
                    if (p.source_count==1 and (p.key_count != 0 or !self.summaryEligible(p, table))) {
                        if (try self.compactGroup(p, outer, table)) |rows| return rows;
                    }
                    if(comptime config.typed_grouped_aggregates) if(p.source_count==1) if(try self.typedMultiGroup(p,outer,table)) |rows| return rows;
                }
                const early=p.source_count>1 and self.earlyAvailable(p.where,p.source_count-1) and self.prefixJoinsSafe(p);
                var cursor:StreamCursor=.{};
                self.prepareStreamCursor(p,&cursor,early);
                if (p.key_count == 0) {
                    var states: [config.columns]Accumulator = undefined;
                    for (states[0..p.agg_count]) |*state| state.* = .{};
                    var bitmap_at:u32=0;
                    if(distinct.active) {
                        bitmap_at=try self.cells(distinct.cells);
                        @memset(self.distinctWords(bitmap_at,distinct.words),0);
                        self.work.stream_stats.distinct_bitmap_bytes+=distinct.words*8;
                    }
                    if (self.summaryEligible(p, table)) {
                        try self.summaryStates(p, &table.summary.columns, table.summary.rows, states[0..p.agg_count]);
                        self.work.stream_stats.summary_rows += @intCast(table.summary.rows);
                        self.work.stream_stats.summary_plans += 1;
                    } else {
                        while(try self.nextStreamTuple(p,&ctx,&cursor,early)) {
                            if(distinct.active) try self.addDistinctAggregates(p,&ctx,states[0..p.agg_count],&distinct,self.distinctWords(bitmap_at,distinct.words))
                            else try self.addAggregates(p,&ctx,states[0..p.agg_count]);
                        }
                    }
                    const at = try self.cells(p.agg_count);
                    try self.projectGroup(p, at, states[0..p.agg_count], outer, &out);
                    self.work.stream_stats.groups += 1;
                    self.work.stream_stats.scratch_cells = @max(self.work.stream_stats.scratch_cells, p.agg_count+distinct.cells);
                    return self.finish(p, out);
                }

                const state_cells = accumulatorCells(p.agg_count);
                const ordinary_cells=p.key_count+p.agg_count+state_cells;
                if(distinct.cells>self.work.cell_high-self.work.cell_low or ordinary_cells>self.work.cell_high-self.work.cell_low-distinct.cells) return error.WorkspaceCapacity;
                const record_cells = ordinary_cells+distinct.cells;
                // Leave room for projection as well as group state. Ref budget
                // covers rounded buckets, tickets, group sorting and final sort.
                const cell_budget = self.work.cell_high - self.work.cell_low;
                const ref_budget = self.work.ref_high - self.work.ref_low;
                const capacity = @min(cell_budget / (record_cells + p.width), ref_budget / 8);
                var slots: usize = 2;
                while (slots < capacity * 2) slots *= 2;
                if(!distinct.active and p.source_count==1) if (self.denseDomain(p, table, slots)) |domain| return self.denseGroup(p, outer, table, domain, capacity, record_cells);
                var buckets: u32 = undefined;
                var tickets: u32 = undefined;
                var groups: usize = 0;
                var computed_keys: [config.columns]V.Cell = undefined;
                var keys: [config.columns]*const V.Cell = undefined;
                while(try self.nextStreamTuple(p,&ctx,&cursor,early)) {
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
                            if(distinct.active) {
                                @memset(self.distinctWords(at+@as(u32,@intCast(ordinary_cells)),distinct.words),0);
                                self.work.stream_stats.distinct_bitmap_bytes+=distinct.words*8;
                            }
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
                    const states=self.accumulators(at+@as(u32,@intCast(p.key_count+p.agg_count)),p.agg_count);
                    if(distinct.active) try self.addDistinctAggregates(p,&ctx,states,&distinct,self.distinctWords(at+@as(u32,@intCast(ordinary_cells)),distinct.words))
                    else try self.addAggregates(p,&ctx,states);
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
                if(comptime config.factorized_aggregates and S.compact_enabled and config.relations>=2) if(self.repeatable()) {
                    const at=self.mark();const stats=self.work.stream_stats;
                    if(self.nestedFactorGroup(p,outer)) |result| {if(result) |rows| return rows;} else |err| {
                        if(err!=error.WorkspaceCapacity) return err;
                        self.release(at);self.work.stream_stats=stats;
                    }
                };
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
                return repeatablePool(self.pool);
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
                        // All currently admitted comparison operators are
                        // strict. A NULL left operand cannot be decisive.
                        if (value == .null_value) return .null_value;
                        var unknown = false;
                        for (self.handles(list)) |offset| {
                            try ctx.session.checkpoint();
                            const candidate = &self.work.cells[offset];
                            if (E.compareOp(n.op, &value, candidate)) |matched| {
                                if (matched) return .{ .boolean = !n.negated };
                            } else {
                                unknown = true;
                            }
                        }
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
        pub fn runQuery(tables: *const [config.tables]S.Table, source: []const u8, pool: *const Ast.Pool, plans: *const B.Plans, root: u16, snap: storage.Snapshot, result: anytype, session: *const value_module.Session, work: *Work, committed_only: bool) Error!void {
            work.reset();
            var runner: Query = .{ .tables = tables, .source = source, .pool = pool, .plans = plans, .snap = snap, .session = session, .work = work, .committed_only = committed_only };
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

        pub const Candidates = union(enum) { scan, empty, slot: struct { row: u32, version: u32 } };

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
            const version = S.lookupVersionAt(table, &value, snap) orelse return .empty;
            return .{ .slot = .{ .row = table.versions[version].row - 1, .version = version } };
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

        fn repeatablePool(pool: *const Ast.Pool) bool {
            for (pool.nodes[0..pool.len]) |node| switch (node.kind) {
                .function => if (!ast.canRepeatFunction(node.func)) return false,
                .scalar_subquery, .exists_subquery, .in_subquery => return false,
                else => {},
            };
            return true;
        }

        /// A strict leading column makes later column sort keys irrelevant.
        /// A visible subset of this physical order remains ordered at every
        /// snapshot. NULLs/ties/key updates invalidate the stored proof.
        fn layoutOrder(table: *const S.Table, pool: *const Ast.Pool, query: *const B.Select) ?bool {
            const node = &pool.nodes[query.order[0].expr];
            const reverse = switch (table.column_order[node.column].state) {
                .increasing => query.order[0].descending,
                .decreasing => !query.order[0].descending,
                .one => if (table.row_high <= 1) false else return null,
                .empty => if (table.row_high == 0) false else return null,
                .unordered => return null,
            };
            if (!repeatablePool(pool)) return null;
            return reverse;
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

        const IntegerKey = struct { rank: u64, null_rank: bool };
        const IntegerEntry = struct {
            keys: [config.columns]IntegerKey = undefined,
            version: u32,
            ordinal: u32,
        };
        const IntegerOrder = struct { column: u16, descending: bool, nulls_first: bool, nonnull: bool };
        const IntegerSorter = struct {
            entries: []const IntegerEntry,
            count: usize,
            session: *const value_module.Session,
            pub fn order(self: *const IntegerSorter, left: u32, right: u32) Error!i8 {
                try self.session.checkpoint();
                const a = &self.entries[left];
                const b = &self.entries[right];
                for (0..self.count) |column| {
                    const x = a.keys[column];
                    const y = b.keys[column];
                    if (x.null_rank != y.null_rank) return if (x.null_rank) 1 else -1;
                    if (x.rank != y.rank) return if (x.rank < y.rank) -1 else 1;
                }
                return if (a.ordinal < b.ordinal) -1 else if (a.ordinal > b.ordinal) 1 else 0;
            }
        };

        fn integerOrder(pool: *const Ast.Pool, query: *const B.Select) bool {
            for (query.order[0..query.order_count]) |key| {
                const node = &pool.nodes[key.expr];
                if (node.kind != .column or !value_module.integral(node.ty)) return false;
            }
            return query.order_count != 0;
        }

        /// Evaluate column keys once per qualifying row, then compare compact
        /// cached ranks. The heap moves only slot IDs; one spare key slot is
        /// recycled on rejection/replacement. NULL placement and stable row-slot
        /// order match Sorter/StableSorter. Keep this stack frame off point reads.
        noinline fn integerTopK(ctx: *E.Context, table: *const S.Table, query: *const B.Select, snap: storage.Snapshot, indices: []u32, committed_only: bool, stats: *ReadStats) Error!usize {
            var entries: [integer_topk_capacity + 1]IntegerEntry = undefined;
            var keys: [config.columns]IntegerOrder = undefined;
            const current = committed_only and table.summary.valid and table.summary.csn <= snap.csn;
            for (query.order[0..query.order_count], 0..) |key, column| {
                const index = ctx.pool.nodes[key.expr].column;
                const nonnull = table.columns[index].not_null or (current and table.summary.columns[index].nonnull == table.summary.rows);
                keys[column] = .{ .column = index, .descending = key.descending,
                    .nulls_first = key.nulls_first orelse (config.nulls_first_ascending != key.descending), .nonnull = nonnull };
                stats.nonnull_sort_keys += @intFromBool(nonnull);
            }
            const count: usize = @intCast(query.limit);
            if (count == 0) return 0;
            var used: usize = 0;
            var spare: u32 = @intCast(count);
            const sorter: IntegerSorter = .{ .entries = &entries, .count = query.order_count, .session = ctx.session };
            rows: for (0..table.row_high) |slot| {
                try ctx.session.checkpoint();
                const version = S.visibleAt(table, slot, snap) orelse continue;
                if (!try keep(ctx, query.where, &table.versions[version].cells)) continue;
                const candidate: u32 = if (used < count) @intCast(used) else spare;
                const entry = &entries[candidate];
                entry.version = version;
                entry.ordinal = table.versions[version].row;
                const full = used == count;
                var relation: i8 = 0;
                for (keys[0..query.order_count], 0..) |key, column| {
                    const value = &table.versions[version].cells[key.column];
                    const is_null = !key.nonnull and value.* == .null_value;
                    var rank: u64 = if (is_null) 0 else @as(u64, @bitCast(value.integer)) ^ 0x8000000000000000;
                    if (!is_null and key.descending) rank = ~rank;
                    const normalized: IntegerKey = .{ .rank = rank, .null_rank = if (is_null) !key.nulls_first else key.nulls_first };
                    // The cached heap root is the worst retained row. Reject
                    // at its first decisive column before reading later keys
                    // or writing a spare entry for a losing candidate.
                    if (full and relation == 0) {
                        const worst = entries[indices[0]].keys[column];
                        relation = if (normalized.null_rank != worst.null_rank)
                            (if (normalized.null_rank) @as(i8, 1) else -1)
                        else if (normalized.rank < worst.rank) -1 else if (normalized.rank > worst.rank) 1 else 0;
                        if (relation > 0) continue :rows;
                    }
                    entry.keys[column] = normalized;
                }
                if (full and relation == 0 and entry.ordinal >= entries[indices[0]].ordinal) continue;
                const removed = try sort_module.offerTopKSlot(indices[0..count], &used, candidate, &sorter);
                if (full) spare = removed;
            }
            for (indices[0..used]) |*id| id.* = entries[id.*].version;
            return used;
        }

        const KeyInterval = struct { low: i128, high: i128, exact: bool = true };
        fn restrictKeys(ctx: *E.Context, id: u16, column: usize, interval: *KeyInterval) Error!void {
            if (id == none) return;
            const node = &ctx.pool.nodes[id];
            if (node.kind == .and_op) {
                try restrictKeys(ctx, node.a, column, interval);
                try restrictKeys(ctx, node.b, column, interval);
                return;
            }
            if (node.kind != .binary) { interval.exact = false; return; }
            switch (node.op) { .eq, .lt, .le, .gt, .ge => {}, else => { interval.exact = false; return; } }
            const a = &ctx.pool.nodes[node.a];
            const b = &ctx.pool.nodes[node.b];
            var expression: u16 = undefined;
            var op = node.op;
            if (a.kind == .column and a.level == 0 and a.relation == 0 and a.column == column and b.constant) expression = node.b
            else if (b.kind == .column and b.level == 0 and b.relation == 0 and b.column == column and a.constant) {
                expression = node.a;
                op = switch (op) { .lt => .gt, .le => .ge, .gt => .lt, .ge => .le, else => op };
            } else { interval.exact = false; return; }
            const value = try E.eval(ctx, expression);
            if (value != .integer) { interval.exact = false; return; }
            const key: i128 = value.integer;
            switch (op) {
                // Explicit comparisons also lower on the native AArch64
                // backend, whose min/max intrinsic currently stops at 64 bits.
                .eq => { if (interval.low < key) interval.low = key; if (interval.high > key) interval.high = key; },
                .lt => { if (interval.high > key - 1) interval.high = key - 1; },
                .le => { if (interval.high > key) interval.high = key; },
                .gt => { if (interval.low < key + 1) interval.low = key + 1; },
                .ge => { if (interval.low < key) interval.low = key; },
                else => unreachable,
            }
        }

        /// Uniqueness + N keys inside an N-wide integral interval proves
        /// density, regardless of physical layout. Probe in ORDER BY direction.
        /// A bounded failed speculation retries the ordinary scan, charging all
        /// work already done. Only repeatable plans may take this path.
        noinline fn densePrimaryScan(ctx: *E.Context, table: *const S.Table, query: *const B.Select, snap: storage.Snapshot, indices: []u32, committed_only: bool, stats: *ReadStats) Error!?usize {
            if (config.ordered_probe_rows == 0 or !committed_only or !table.summary.valid or table.summary.csn > snap.csn) return null;
            const column = table.primary_column orelse return null;
            const key = &ctx.pool.nodes[query.order[0].expr];
            if (key.column != column or !value_module.integral(key.ty) or !repeatablePool(ctx.pool)) return null;
            const bounds = table.summary.primary_bounds;
            if (!bounds.known or @as(i128, bounds.high) - bounds.low + 1 != table.summary.rows) return null;
            var interval: KeyInterval = .{ .low = bounds.low, .high = bounds.high };
            try restrictKeys(ctx, query.where, column, &interval);
            const reverse = query.order[0].descending;
            var current = if (reverse) interval.high else interval.low;
            const budget = @min(config.ordered_probe_rows, @max(@as(usize, 256), @as(usize, @intCast(query.limit)) * 128));
            // Do not replace a small broad sequential scan with random probes
            // when a residual predicate may require the entire key interval.
            if (!interval.exact and @as(i128, table.summary.rows) <= budget and interval.high - interval.low + 1 > @divTrunc(@as(i128, table.summary.rows), 4)) return null;
            stats.key_walks += 1;
            var probes: usize = 0;
            var found: usize = 0;
            while (current >= interval.low and current <= interval.high) : (current += if (reverse) @as(i128, -1) else 1) {
                if (probes == budget) { stats.key_fallbacks += 1; return null; }
                try ctx.session.checkpoint();
                probes += 1;stats.key_probes += 1;
                const value: V.Cell = .{ .integer = @intCast(current) };
                const version = S.lookupVersionAt(table, &value, snap) orelse { stats.key_fallbacks += 1; return null; };
                if (!try keep(ctx, query.where, &table.versions[version].cells)) continue;
                indices[found] = version;found += 1;
                if (found >= query.limit) break;
            }
            stats.key_successes += 1;
            return found;
        }

        /// Filter narrow committed integer columns first; resolve full MVCC
        /// versions only for survivors. Non-null proofs preserve AND's exact
        /// left-to-right short-circuit checkpoint count. Nullable/computed
        /// predicates and old/own-write snapshots keep the canonical path.
        noinline fn projectedFilterScan(ctx:*E.Context,table:*const S.Table,query:*const B.Select,snap:storage.Snapshot,
            indices:[]u32,committed_only:bool,stats:*ReadStats) Error!?usize {
            if(comptime !S.compact_enabled) return null;
            if(!committed_only or !table.summary.valid or table.summary.csn>snap.csn or table.scan_high!=table.row_high or
                query.where==none or query.order_count!=0 or query.limit!=0xffffffffffffffff) return null;
            var predicates:[config.predicates]Query.CompactPredicate=undefined;
            var used:usize=0;
            if(!Query.compactPredicates(ctx.pool,query.where,table,&predicates,&used) or used==0) return null;
            for(predicates[0..used]) |predicate| if(!predicate.nonnull) return null;
            stats.projected_filter_scans+=1;
            const dense=table.summary.rows>=0 and @as(u64,@intCast(table.summary.rows))==table.scan_high;
            var found:usize=0;var start:usize=0;
            while(start<table.scan_high):(start+=64) {
                const count=@min(@as(usize,64),table.scan_high-start);
                // Charge dead slots too, exactly as the canonical scan does.
                try ctx.session.checkpoints(count);
                var mask=Query.liveMask(table,start,count,dense);
                stats.projected_filter_rows+=@popCount(mask);
                for(predicates[0..used]) |predicate| {
                    // Comparisons borrow their column and evaluate one literal;
                    // subsequent AND terms run only for preceding TRUE rows.
                    try ctx.session.checkpoints(@popCount(mask));
                    mask &= switch(predicate.op) {
                        .eq=>Query.comparisonMask(.eq,table,start,count,predicate,null),
                        .ne=>Query.comparisonMask(.ne,table,start,count,predicate,null),
                        .lt=>Query.comparisonMask(.lt,table,start,count,predicate,null),
                        .le=>Query.comparisonMask(.le,table,start,count,predicate,null),
                        .gt=>Query.comparisonMask(.gt,table,start,count,predicate,null),
                        .ge=>Query.comparisonMask(.ge,table,start,count,predicate,null),
                        else=>unreachable,
                    };
                    if(mask==0) break;
                }
                while(mask!=0) {
                    const slot=start+@ctz(mask);mask&=mask-1;
                    const version=S.visibleAt(table,slot,snap) orelse continue;
                    if(found==indices.len) return error.WorkspaceCapacity;
                    indices[found]=version;found+=1;
                }
            }
            return found;
        }

        /// `locker` (FOR UPDATE/SHARE) runs after ORDER BY and before LIMIT, as
        /// PostgreSQL's LockRows does: it returns the version to emit (the
        /// newest committed one, whose WHERE is re-checked here when it
        /// changed), null to skip the row, or WouldBlock to park.
        pub fn select(tables: *const [config.tables]S.Table, source: []const u8, pool: *const Ast.Pool, query: *const B.Select, snap: storage.Snapshot, result: anytype, locker: anytype, session: *const value_module.Session, committed_only: bool, stats: *ReadStats, work: *Work) Error!void {
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
            var inline_indices: [if (config.external_workspace) 0 else types.workRows(config)]u32 = undefined;
            const index_capacity = if (config.external_workspace) @min(work.refs.len / 2, work.cells.len / (2 * config.columns)) else inline_indices.len;
            if (index_capacity == 0) return error.WorkspaceCapacity;
            const indices = if (config.external_workspace) work.refs[0..index_capacity] else inline_indices[0..];
            var found: usize = 0;
            var column_order = true;
            for (query.order[0..query.order_count]) |key| column_order = column_order and simple(pool, key.expr);
            const layout_reverse: ?bool = if (!locking and column_order and query.order_count != 0 and query.limit <= indices.len) layoutOrder(table, pool, query) else null;
            var ordered = layout_reverse != null;
            const top_k = !locking and column_order and query.order_count != 0 and query.limit <= indices.len and (query.limit < table.row_high / 2 or table.row_high > indices.len);
            const sorter: Sorter = .{ .ctx = &ctx, .table = table, .query = query };
            const stable: StableSorter = .{ .base = &sorter };
            if (query.limit != 0) switch (try candidates(&ctx, table, query.key, snap)) {
                .empty => {},
                .slot => |hit| {
                    const version = hit.version;
                    if (try keep(&ctx, query.where, &table.versions[version].cells)) {
                        indices[0] = version;
                        found = 1;
                    }
                },
                .scan => scan: {
                  if (layout_reverse) |reverse| {
                    var offset: usize = 0;
                    while (offset < table.row_high) : (offset += 1) {
                        try session.checkpoint();
                        const slot = if (reverse) table.row_high - 1 - offset else offset;
                        const version = S.visibleAt(table, slot, snap) orelse continue;
                        if (!try keep(&ctx, query.where, &table.versions[version].cells)) continue;
                        if (found == indices.len) return error.WorkspaceCapacity;
                        indices[found] = version;
                        found += 1;
                        if (found >= query.limit) break;
                    }
                    break :scan;
                  }
                  if (!locking and column_order and query.order_count != 0 and query.limit <= indices.len) {
                    if (try densePrimaryScan(&ctx, table, query, snap, indices, committed_only, stats)) |count| {
                        found = count;ordered = true;break :scan;
                    }
                  }
                  if(!locking and !top_k) if(try projectedFilterScan(&ctx,table,query,snap,indices,committed_only,stats)) |count| {
                    found=count;break :scan;
                  };
                  if (top_k and query.limit <= integer_topk_capacity and integerOrder(pool, query)) {
                    found = try integerTopK(&ctx, table, query, snap, indices, committed_only, stats);
                  } else for (0..table.row_high) |slot| {
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
                  }
                },
            };
            if (query.order_count != 0 and found != 0 and !ordered) {
                // Sort keys are evaluated for every candidate row, so an
                // erroring key fails even when one row (or none) is compared.
                for (query.order[0..query.order_count]) |*key| if (!simple(pool, key.expr)) {
                    for (indices[0..found]) |version| {
                        ctx.row = &table.versions[version].cells;
                        _ = try E.eval(&ctx, key.expr);
                    }
                };
                if (top_k) {
                    var inline_scratch: [if (config.external_workspace) 0 else types.workRows(config)]u32 = undefined;
                    const scratch = if (config.external_workspace) work.refs[index_capacity..][0..index_capacity] else inline_scratch[0..];
                    _ = try sort_module.mergeSort(indices[0..found], scratch[0..found], &stable);
                } else if (comptime config.external_workspace) {
                    _ = try sort_module.mergeSort(indices[0..found], work.refs[index_capacity..][0..found], &sorter);
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
