//! Bounded, allocation-free in-memory SQL (Layer 0).
//!
//! Database and result storage belong entirely to the caller. Identifiers and
//! text cells are copied inline; neither statements nor results borrow database
//! storage. Each execute accepts exactly one statement and failing statements
//! leave both the database and result unchanged. Callers serialize access.
//!
//! Supported: CREATE/DROP TABLE; single-row INSERT [column list] VALUES
//! (expressions); SELECT expressions [FROM one table [alias]] [WHERE]
//! [ORDER BY expressions/positions/output names] [LIMIT]; UPDATE with
//! expression SET; DELETE. Types are INTEGER (int4), BIGINT (int8), BOOLEAN,
//! TEXT and NULL. Expressions (design §4.1): AND/OR/NOT with three-valued
//! logic, comparisons, IS [NOT] NULL/TRUE/FALSE/UNKNOWN, [NOT] IN lists,
//! [NOT] BETWEEN, [NOT] LIKE/ILIKE, `||`, checked integer `+ - * / %`, CASE,
//! COALESCE, NULLIF, `::`/CAST, typed with PostgreSQL's implicit-cast rules.
//! Constraints are NOT NULL and a single-column PRIMARY KEY. Unquoted
//! identifiers are ASCII and case insensitive; quoted identifiers keep case;
//! text comparison is bytewise. Transactions, joins, aggregates, other
//! functions, NUMERIC and secondary indices are outside this SQL subset; this
//! is not full SQL-standard or PostgreSQL compatibility.
//!
//! Dialect (per session, `Database.dialect`, set by the caller before each
//! statement): on `.postgres` INTEGER is always int4; on `.mysql`/`.tds` it
//! follows Config.integer_bits and integer 0/1 may be assigned to BOOLEAN.
//! Expression typing never depends on the dialect.
//!
//! Pipeline (sql/*.sig, relative imports only; nothing outside this module
//! imports them): lexer -> parser (statement-scoped node pool, bounded depth)
//! -> binder (names and types, never executes; powers describe()) -> expr
//! (evaluation) -> exec (scans, filters, projections, ORDER BY) / dml (row
//! construction, assignment casts, per-row key checks) over versioned
//! storage (stable rowids, row versions, PK multi-index, bounded
//! reclamation) -> kind-3 change records (executeChanges /
//! applyChangeRecord). `legacy_alpha` replays kind 1/2 SQL-text WAL records
//! with the frozen alpha grammar (alpha.sig) only.
//!
//! No allocator, platform or runtime dependency. The only std symbols this
//! module and sql/*.sig may ever use are std.fmt.parseFloat(T, s) and
//! std.fmt.float.render(buf, value, options); today they use none.
const types = @import("sql/types.sig");
const ast = @import("sql/ast.sig");
const parser_module = @import("sql/parser.sig");
const binder_module = @import("sql/binder.sig");
const storage = @import("sql/storage.sig");
const change_log = @import("sql/change_log.sig");
const expr_module = @import("sql/expr.sig");
const exec_module = @import("sql/exec.sig");
const dml_module = @import("sql/dml.sig");

pub const Config = types.Config;
pub const Error = types.Error;
pub const Dialect = types.Dialect;
pub const DataType = types.DataType;
pub const CommandTag = types.CommandTag;
pub const ParseMode = parser_module.Mode;
pub const typeOid = types.typeOid;
/// Kind-3 change-record format constants and header validation.
pub const change_records = struct {
    pub const format_version = change_log.format_version;
    pub const header_size = change_log.header_size;
    pub const first_oid = change_log.first_oid;
    pub const opCount = change_log.opCount;
};

pub fn Database(comptime config: Config) type {
    if (config.integer_bits != 32 and config.integer_bits != 64) @compileError("SQL INTEGER width must be 32 or 64");
    if (config.tables == 0 or config.columns == 0 or config.rows_per_table == 0 or
        config.name_bytes == 0 or config.text_bytes == 0 or config.predicates == 0 or
        config.expr_nodes == 0 or config.expr_depth == 0)
        @compileError("SQL capacities must be non-zero");
    if (config.tables > 255 or config.columns > 255 or config.name_bytes > 255) @compileError("SQL catalog capacities must fit change records");

    const V = types.Values(config);
    const S = storage.Storage(config);
    const A = ast.Ast(config);
    const P = parser_module.Parser(config);
    const B = binder_module.Binder(config);
    const C = change_log.ChangeLog(config);
    const E = expr_module.Eval(config);
    const X = exec_module.Exec(config);
    const D = dml_module.Dml(config);

    return struct {
        const Self = @This();
        pub const integer_type: DataType = B.integer_type;
        pub const Name = V.Name;
        pub const Text = V.Text;
        pub const Cell = V.Cell;
        pub const Row = V.Row;
        pub const Column = V.Column;
        pub const RowRef = S.RowRef;
        pub const StorageStats = S.Stats;
        pub const ReplayScratch = C.Scratch;
        pub const versions_per_table = S.versions_capacity;
        pub const undo_capacity = S.undo_capacity;
        /// Receives the complete change record before the statement publishes.
        pub const RecordCommitFn = *const fn (?*anyopaque, []const u8) anyerror!void;

        pub const Result = struct {
            column_count: usize = 0,
            row_count: usize = 0,
            affected_rows: usize = 0,
            command: CommandTag = .none,
            column_names: [config.columns]Name = @splat(.{}),
            column_types: [config.columns]DataType = @splat(.integer),
            rows: [config.rows_per_table]Row = @splat(.{}),

            /// Only active ranges are observable; avoid clearing unused row capacity.
            pub fn clear(self: *Result, affected: usize) void {
                self.column_count = 0;
                self.row_count = 0;
                self.affected_rows = affected;
                self.command = .none;
            }

            /// Copy the observable result, without touching unused capacity.
            /// Destination may be uninitialized; inactive ranges stay unreadable.
            pub fn copyFrom(self: *Result, source: *const Result) void {
                if (self == source) return;
                self.column_count = source.column_count;
                self.row_count = source.row_count;
                self.affected_rows = source.affected_rows;
                self.command = source.command;
                @memcpy(self.column_names[0..source.column_count], source.column_names[0..source.column_count]);
                @memcpy(self.column_types[0..source.column_count], source.column_types[0..source.column_count]);
                for (0..source.row_count) |row| {
                    @memcpy(self.rows[row].cells[0..source.column_count], source.rows[row].cells[0..source.column_count]);
                }
            }
        };

        /// Statement-scoped scratch inside caller-owned database storage:
        /// the expression node pool and the statement-local undo list.
        pub const Workspace = struct {
            nodes: A.Pool = .{},
            undo: [S.undo_capacity]S.Undo = undefined,
            undo_len: usize = 0,
            saved_oid_counter: u32 = 0,
            saved_table: ?usize = null,
            saved_next_rowid: u64 = 0,
        };

        tables: [config.tables]S.Table = @splat(.{}),
        /// Table OIDs are first_oid + counter; never reused.
        oid_counter: u32 = 0,
        /// Local commit sequence; every completed mutation stamps csn + 1.
        csn: u64 = 0,
        cid: u32 = 0,
        epoch: u32 = 0,
        /// Session dialect of the next statement (callers serialize access
        /// and set it per call; Store.Connection does). Not database state.
        dialect: Dialect = .postgres,
        workspace: Workspace = .{},

        /// Includes all caller-owned table, version, index and statement storage.
        pub fn storageBytes() usize {
            return @sizeOf(Self);
        }

        /// Copy a complete logical snapshot into distinct caller-owned storage.
        /// Only live tables, schemas, row slots, versions and indices are
        /// observable. Inactive table payloads and unused row/version capacity
        /// need neither copying nor zeroing; the statement workspace is scratch.
        pub fn copyFrom(self: *Self, source: *const Self) void {
            if (self == source) return;
            self.oid_counter = source.oid_counter;
            self.csn = source.csn;
            self.cid = source.cid;
            self.epoch = source.epoch;
            for (&self.tables, &source.tables) |*destination, *table| {
                destination.live = table.live;
                destination.pending_create = false;
                destination.pending_drop = false;
                if (!table.live) continue;
                S.copyTable(destination, table);
            }
        }

        pub fn tableCount(self: *const Self) usize {
            var count: usize = 0;
            for (&self.tables) |*table| if (table.live) {
                count += 1;
            };
            return count;
        }

        /// Result contains copied SELECT rows or a mutation's affected_rows.
        /// Any error preserves the previous result and the whole database.
        pub fn execute(self: *Self, source: []const u8, result: *Result) Error!void {
            return self.run(source, result, .standard, NoCommit{});
        }

        /// Replays one alpha SQL-text statement (WAL kinds 1/2): alpha grammar,
        /// alpha boolean integers (assignment and comparison), the configured
        /// INTEGER width, whatever the dialect.
        /// Anything outside the alpha grammar fails with UnsupportedLogVersion.
        pub fn executeLegacy(self: *Self, source: []const u8, result: *Result) Error!void {
            return self.run(source, result, .legacy_alpha, NoCommit{});
        }

        const NoCommit = struct {
            fn before(_: @This(), _: *Self) Error!void {}
        };

        const CommitBoundary = struct {
            context: ?*anyopaque,
            commit: *const fn (?*anyopaque) anyerror!void,

            fn before(self: @This(), _: *Self) anyerror!void {
                try self.commit(self.context);
            }
        };

        const RecordSink = struct {
            record: []u8,
            used: *usize,
            context: ?*anyopaque,
            commit: ?RecordCommitFn,

            fn before(self: @This(), db: *Self) anyerror!void {
                var writer = try change_log.Writer.init(self.record, self.used.*);
                try db.encodeStatement(&writer);
                const length = try writer.finish();
                if (self.commit) |commit| try commit(self.context, self.record[0..length]);
                self.used.* = length;
            }
        };

        /// Validate the entire statement before calling commit, then publish its
        /// mutation without any further fallible operation. SELECT never calls
        /// commit. Failed validation or commit preserves the database and result.
        /// The caller serializes access through the complete call. The callback
        /// must not mutate this database, source, or result, or reenter a write;
        /// read-only observation is permitted. The callback normally
        /// flushes a WAL record. No database snapshot or heap storage is needed.
        pub fn executeWithCommit(self: *Self, source: []const u8, result: *Result, context: ?*anyopaque, commit: *const fn (?*anyopaque) anyerror!void) anyerror!void {
            return self.run(source, result, .standard, CommitBoundary{ .context = context, .commit = commit });
        }

        /// Like executeWithCommit, but encodes the completed statement's row and
        /// DDL ops (from its undo list) as a kind-3 change record appended to
        /// record[used..]; a header is written when used is 0. With `commit`,
        /// the complete record is passed to it before publication; without it
        /// the bytes are only appended (explicit transactions). `used` changes
        /// only when the statement succeeds; overflow is TransactionLogCapacity
        /// with no state change. SELECT encodes nothing and never commits.
        pub fn executeChanges(self: *Self, source: []const u8, result: *Result, record: []u8, used: *usize, context: ?*anyopaque, commit: ?RecordCommitFn) anyerror!void {
            return self.run(source, result, .standard, RecordSink{ .record = record, .used = used, .context = context, .commit = commit });
        }

        /// Parse and bind without executing. SELECT reports its output columns.
        pub fn describe(self: *Self, source: []const u8, result: *Result) Error!void {
            const statement = try P.parse(source, &self.workspace.nodes, .standard);
            const context = self.bindContext(source, .standard);
            const bound = try B.bind(&context, &statement);
            result.clear(0);
            result.command = B.command(&bound);
            if (bound == .select) {
                result.column_count = bound.select.count;
                for (0..bound.select.count) |index| {
                    result.column_names[index] = bound.select.names[index];
                    result.column_types[index] = bound.select.types[index];
                }
            }
        }

        /// Applies a kind-3 change record atomically: the whole record is
        /// decoded and validated against `scratch` before anything changes.
        pub fn applyChangeRecord(self: *Self, record: []const u8, scratch: *ReplayScratch) Error!void {
            return C.apply(self, record, scratch);
        }

        /// Header validation; returns the record's op count.
        pub fn changeRecordOps(record: []const u8) Error!u32 {
            return change_log.opCount(record);
        }

        /// Appends a catalog_counters op (next OID and every live table's next rowid).
        pub fn encodeCatalogCounters(self: *const Self, record: []u8, used: *usize) Error!void {
            var writer = try change_log.Writer.init(record, used.*);
            try C.encodeCounters(&writer, change_log.first_oid + self.oid_counter, &self.tables);
            used.* = try writer.finish();
        }

        pub fn storageStats(self: *const Self, table_name: []const u8) ?StorageStats {
            const index = B.tableIndex(&self.tables, table_name) catch return null;
            return S.stats(&self.tables[index]);
        }

        pub fn rowRef(self: *const Self, table_name: []const u8, rowid: u64) ?RowRef {
            const index = B.tableIndex(&self.tables, table_name) catch return null;
            const table = &self.tables[index];
            const slot = S.findRow(table, rowid) orelse return null;
            return .{ .slot = slot, .generation = table.rows[slot].generation };
        }

        /// Resolves a reference to its rowid; stale generations never resolve.
        pub fn resolveRowRef(self: *const Self, table_name: []const u8, ref: RowRef) ?u64 {
            const index = B.tableIndex(&self.tables, table_name) catch return null;
            const table = &self.tables[index];
            if (ref.slot >= table.row_high) return null;
            const slot = &table.rows[ref.slot];
            if (slot.newest == 0 or slot.generation != ref.generation) return null;
            return slot.rowid;
        }

        /// Reclaims every dead version and empty row slot now.
        pub fn vacuum(self: *Self) usize {
            var freed: usize = 0;
            for (&self.tables) |*table| if (table.live) {
                freed += S.vacuum(table, self.csn);
            };
            return freed;
        }

        fn bindContext(self: *Self, source: []const u8, mode: ParseMode) B.Context {
            return .{ .source = source, .tables = &self.tables, .pool = &self.workspace.nodes, .legacy = mode == .legacy_alpha, .dialect = self.dialect };
        }

        fn evalContext(self: *const Self, source: []const u8) E.Context {
            return .{ .source = source, .pool = &self.workspace.nodes };
        }

        fn legacy(mode: ParseMode, err: Error) Error {
            if (mode == .legacy_alpha and (err == error.Syntax or err == error.UnsupportedStatement)) return error.UnsupportedLogVersion;
            return err;
        }

        fn run(self: *Self, source: []const u8, result: *Result, mode: ParseMode, sink: anytype) !void {
            const statement = P.parse(source, &self.workspace.nodes, mode) catch |err| return legacy(mode, err);
            const context = self.bindContext(source, mode);
            const bound = B.bind(&context, &statement) catch |err| return legacy(mode, err);
            switch (bound) {
                .select => |*select| return X.select(&self.tables, source, &self.workspace.nodes, select, result),
                // Transaction control belongs to the store, not a single Raw.
                .begin, .commit, .rollback => return legacy(mode, error.UnsupportedStatement),
                else => {},
            }
            try self.mutate(source, &bound, result, sink);
        }

        fn txRef(self: *const Self) S.TxRef {
            return .{ .slot = 0, .epoch = self.epoch, .sub = 0 };
        }

        fn push(self: *Self, entry: S.Undo) void {
            // Bounded: one statement touches at most rows_per_table rows of one table.
            self.workspace.undo[self.workspace.undo_len] = entry;
            self.workspace.undo_len += 1;
        }

        fn mutate(self: *Self, source: []const u8, bound: *const B.Bound, result: *Result, sink: anytype) !void {
            const workspace = &self.workspace;
            workspace.undo_len = 0;
            workspace.saved_oid_counter = self.oid_counter;
            workspace.saved_table = null;
            self.epoch +%= 1;
            if (self.epoch == 0) self.epoch = 1;
            self.cid +%= 1;
            errdefer self.undoStatement();
            const affected = switch (bound.*) {
                .create_table => |*create| try self.createTable(create),
                .drop_table => |index| blk: {
                    self.tables[index].pending_drop = true;
                    self.push(.{ .kind = .drop_table, .table = @intCast(index) });
                    break :blk 0;
                },
                .insert => |*insert| try self.insertRow(source, insert),
                .update => |*update| try self.updateRows(source, update),
                .delete => |*delete| try self.deleteRows(source, delete),
                .select, .begin, .commit, .rollback => unreachable,
            };
            try sink.before(self);
            self.stampStatement();
            result.clear(affected);
            result.command = B.command(bound);
        }

        /// A failing statement frees the versions it created and clears the
        /// xmax marks it set (reclamation case 1) before the error returns.
        fn undoStatement(self: *Self) void {
            const workspace = &self.workspace;
            var index = workspace.undo_len;
            while (index != 0) {
                index -= 1;
                const entry = workspace.undo[index];
                const table = &self.tables[entry.table];
                switch (entry.kind) {
                    .insert => S.reclaimVersion(table, entry.new),
                    .update => {
                        S.reclaimVersion(table, entry.new);
                        clearMark(table, entry.old);
                    },
                    .delete => clearMark(table, entry.old),
                    .create_table => table.pending_create = false,
                    .drop_table => table.pending_drop = false,
                }
            }
            workspace.undo_len = 0;
            self.oid_counter = workspace.saved_oid_counter;
            if (workspace.saved_table) |table| self.tables[table].next_rowid = workspace.saved_next_rowid;
        }

        fn clearMark(table: *S.Table, version: u32) void {
            table.versions[version].xmax = .{};
            table.versions[version].xmax_cid = 0;
        }

        /// Stamps the statement committed in this Raw, then reclaims up to
        /// reclaim_budget superseded versions (horizon = current csn).
        fn stampStatement(self: *Self) void {
            const csn = self.csn + 1;
            const workspace = &self.workspace;
            for (workspace.undo[0..workspace.undo_len]) |entry| {
                const table = &self.tables[entry.table];
                switch (entry.kind) {
                    .insert => table.versions[entry.new].xmin_csn = csn,
                    .update => {
                        table.versions[entry.new].xmin_csn = csn;
                        table.versions[entry.old].xmax_csn = csn;
                    },
                    .delete => table.versions[entry.old].xmax_csn = csn,
                    .create_table => {
                        table.pending_create = false;
                        table.live = true;
                    },
                    .drop_table => {
                        table.pending_drop = false;
                        table.live = false;
                    },
                }
            }
            self.csn = csn;
            var budget: usize = S.reclaim_budget;
            for (workspace.undo[0..workspace.undo_len]) |entry| {
                if (budget == 0) break;
                if (entry.kind != .update and entry.kind != .delete) continue;
                const table = &self.tables[entry.table];
                if (!table.live) continue;
                S.reclaimVersion(table, entry.old);
                budget -= 1;
            }
            workspace.undo_len = 0;
        }

        fn encodeStatement(self: *const Self, writer: *change_log.Writer) Error!void {
            const workspace = &self.workspace;
            for (workspace.undo[0..workspace.undo_len]) |entry| {
                const table = &self.tables[entry.table];
                switch (entry.kind) {
                    .insert, .update => {
                        const version = &table.versions[entry.new];
                        const tag: change_log.Op = if (entry.kind == .insert) .insert else .update;
                        try C.encodeRow(writer, tag, table.oid, table.rows[version.row - 1].rowid, version.cells[0..table.column_count]);
                    },
                    .delete => try C.encodeDelete(writer, table.oid, table.rows[table.versions[entry.old].row - 1].rowid),
                    .create_table => try C.encodeCreate(writer, table),
                    .drop_table => try C.encodeDrop(writer, table.oid),
                }
            }
        }

        fn createTable(self: *Self, create: *const B.Create) Error!usize {
            var destination: ?usize = null;
            for (&self.tables, 0..) |*table, index| if (!table.live and !table.pending_create) {
                destination = index;
                break;
            };
            const index = destination orelse return error.TableCapacity;
            if (self.oid_counter >= 0xffffffff - change_log.first_oid) return error.TableCapacity;
            const table = &self.tables[index];
            S.reset(table, change_log.first_oid + self.oid_counter, create.name, create.columns[0..create.count]);
            self.oid_counter += 1;
            table.pending_create = true;
            self.push(.{ .kind = .create_table, .table = @intCast(index) });
            return 0;
        }

        fn insertRow(self: *Self, source: []const u8, insert: *const B.Insert) Error!usize {
            const table = &self.tables[insert.table];
            var ctx = self.evalContext(source);
            const cells = try D.insertedRow(&ctx, table, &insert.values);
            if (table.primary_column) |column| {
                if (S.lookupKey(table, &cells[column]) != null) return error.PrimaryKeyViolation;
            }
            if (table.next_rowid == 0xffffffffffffffff) return error.RowCapacity;
            try S.ensureVersions(table, 1, self.csn);
            try S.ensureRowSlot(table, self.csn);
            self.workspace.saved_table = insert.table;
            self.workspace.saved_next_rowid = table.next_rowid;
            const slot = S.allocRow(table, table.next_rowid);
            table.next_rowid += 1;
            const version = S.allocVersion(table);
            table.versions[version] = .{ .row = slot + 1, .xmin = self.txRef(), .xmin_cid = self.cid, .cells = cells };
            table.rows[slot].newest = version + 1;
            S.indexKey(table, version);
            self.push(.{ .kind = .insert, .table = @intCast(insert.table), .new = version });
            return 1;
        }

        /// Rows are visited in rowid order and updated one at a time, as a
        /// PostgreSQL heap scan does: WHERE, SET and key checks interleave,
        /// and any error undoes every earlier row (undo list).
        fn updateRows(self: *Self, source: []const u8, update: *const B.Update) Error!usize {
            const table = &self.tables[update.table];
            var ctx = self.evalContext(source);
            var affected: usize = 0;
            switch (try X.candidates(&ctx, table, update.key)) {
                .empty => {},
                .slot => |slot| {
                    const version = S.visible(table, slot).?;
                    if (try X.keep(&ctx, update.where, &table.versions[version].cells)) {
                        try self.updateOne(&ctx, update, slot, version);
                        affected = 1;
                    }
                },
                .scan => for (0..table.row_high) |slot| {
                    const version = S.visible(table, slot) orelse continue;
                    if (!try X.keep(&ctx, update.where, &table.versions[version].cells)) continue;
                    try self.updateOne(&ctx, update, @intCast(slot), version);
                    affected += 1;
                },
            }
            return affected;
        }

        fn updateOne(self: *Self, ctx: *E.Context, update: *const B.Update, slot: u32, old: u32) Error!void {
            const table = &self.tables[update.table];
            const cells = try D.updatedRow(ctx, table, &update.values, &table.versions[old].cells);
            if (table.primary_column) |column| {
                if (update.values[column] != ast.none and D.keyTaken(table, &cells[column], slot)) return error.PrimaryKeyViolation;
            }
            // Statement-pending versions and marks are never reclaimed here.
            try S.ensureVersions(table, 1, self.csn);
            const version = S.allocVersion(table);
            table.versions[version] = .{ .row = slot + 1, .xmin = self.txRef(), .xmin_cid = self.cid, .older = old + 1, .cells = cells };
            table.rows[slot].newest = version + 1;
            table.versions[old].xmax = self.txRef();
            table.versions[old].xmax_cid = self.cid;
            S.indexKey(table, version);
            self.push(.{ .kind = .update, .table = @intCast(update.table), .old = old, .new = version });
        }

        fn deleteRows(self: *Self, source: []const u8, delete: *const B.Delete) Error!usize {
            const table = &self.tables[delete.table];
            var ctx = self.evalContext(source);
            var affected: usize = 0;
            switch (try X.candidates(&ctx, table, delete.key)) {
                .empty => {},
                .slot => |slot| {
                    const version = S.visible(table, slot).?;
                    if (try X.keep(&ctx, delete.where, &table.versions[version].cells)) {
                        self.deleteOne(delete.table, version);
                        affected = 1;
                    }
                },
                .scan => for (0..table.row_high) |slot| {
                    const version = S.visible(table, slot) orelse continue;
                    if (!try X.keep(&ctx, delete.where, &table.versions[version].cells)) continue;
                    self.deleteOne(delete.table, version);
                    affected += 1;
                },
            }
            return affected;
        }

        fn deleteOne(self: *Self, table_index: usize, old: u32) void {
            const table = &self.tables[table_index];
            table.versions[old].xmax = self.txRef();
            table.versions[old].xmax_cid = self.cid;
            self.push(.{ .kind = .delete, .table = @intCast(table_index), .old = old });
        }
    };
}