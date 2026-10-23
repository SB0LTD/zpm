//! Bounded, allocation-free in-memory SQL (Layer 0).
//!
//! Database and result storage belong entirely to the caller. Identifiers and
//! text cells are copied inline; neither statements nor results borrow database
//! storage. Callers serialize access (one call at a time); concurrency comes
//! from interleaving transactions, never from threads.
//!
//! Supported: CREATE/DROP TABLE; single-row INSERT [column list] VALUES
//! (expressions); SELECT expressions [FROM one table [alias]] [WHERE]
//! [ORDER BY expressions/positions/output names] [LIMIT] [FOR UPDATE|SHARE
//! [NOWAIT|SKIP LOCKED]]; UPDATE with expression SET; DELETE. Types are
//! INTEGER (int4), BIGINT (int8), BOOLEAN, TEXT and NULL. Expressions (design
//! §4.1): AND/OR/NOT with three-valued logic, comparisons, IS [NOT]
//! NULL/TRUE/FALSE/UNKNOWN, [NOT] IN lists, [NOT] BETWEEN, [NOT] LIKE/ILIKE,
//! `||`, checked integer `+ - * / %`, CASE, COALESCE, NULLIF, `::`/CAST,
//! typed with PostgreSQL's implicit-cast rules. Constraints are NOT NULL and
//! a single-column PRIMARY KEY. Unquoted identifiers are ASCII and case
//! insensitive; quoted identifiers keep case; text comparison is bytewise.
//! Joins, aggregates, other functions, NUMERIC and secondary indices are
//! outside this SQL subset; this is not full SQL-standard or PostgreSQL
//! compatibility.
//!
//! Transactions (design §4.4-§4.5): READ COMMITTED only, over row versions.
//! Every statement takes a new snapshot and runs as a statement
//! subtransaction of its transaction (begin/statement/prepareCommit/
//! publishCommit/abort); savepoints are nested subtransactions. DDL is
//! transactional through the versioned catalog (catalog.sig). A statement
//! that meets a lock held by a live transaction returns WouldBlock with its
//! work kept; re-delivering it resumes with the same snapshot and command id
//! (EvalPlanQual re-checks on every remaining target). REPEATABLE READ and
//! SERIALIZABLE are not provided (callers reject them). execute(),
//! executeWithCommit() and executeChanges() are single-statement autocommit
//! conveniences over the same machinery.
//!
//! Dialect (per session, `Database.dialect`, set by the caller before each
//! statement): on `.postgres` INTEGER is always int4; on `.mysql`/`.tds` it
//! follows Config.integer_bits and integer 0/1 may be assigned to BOOLEAN.
//! Expression typing never depends on the dialect.
//!
//! Pipeline (sql/*.sig, relative imports only; nothing outside this module
//! imports them): lexer -> parser (statement-scoped node pool, bounded depth)
//! -> binder (names under the statement snapshot, types; never executes;
//! powers describe()) -> expr (evaluation) -> exec (scans, filters,
//! projections, ORDER BY, LockRows) / dml (row construction, assignment
//! casts, unique checks) over versioned storage (stable rowids, row versions,
//! PK multi-index, horizon-bounded reclamation), mvcc (transaction table,
//! write sets, subtransactions), locks (row/table locks, wait-for sets,
//! deadlock DFS), catalog (versioned base relations) -> kind-3 change records
//! (prepareCommit / applyChangeRecord). `legacy_alpha` replays kind 1/2
//! SQL-text WAL records with the frozen alpha grammar (alpha.sig) only.
//!
//! No allocator, platform or runtime dependency. The only std symbols this
//! module and sql/*.sig may ever use are std.fmt.parseFloat(T, s) and
//! std.fmt.float.render(buf, value, options); today they use none.
const types = @import("sql/types.sig");
const ast = @import("sql/ast.sig");
const lexer = @import("sql/lexer.sig");
const parser_module = @import("sql/parser.sig");
const binder_module = @import("sql/binder.sig");
const storage = @import("sql/storage.sig");
const change_log = @import("sql/change_log.sig");
const expr_module = @import("sql/expr.sig");
const exec_module = @import("sql/exec.sig");
const dml_module = @import("sql/dml.sig");
const mvcc_module = @import("sql/mvcc.sig");
const locks_module = @import("sql/locks.sig");
const catalog_module = @import("sql/catalog.sig");

pub const Config = types.Config;
pub const Error = types.Error;
pub const Dialect = types.Dialect;
pub const DataType = types.DataType;
pub const CommandTag = types.CommandTag;
pub const ParseMode = parser_module.Mode;
pub const Isolation = ast.Isolation;
pub const typeOid = types.typeOid;
/// Kind-3 change-record format constants and header validation.
pub const change_records = struct {
    pub const format_version = change_log.format_version;
    pub const header_size = change_log.header_size;
    pub const first_oid = change_log.first_oid;
    pub const opCount = change_log.opCount;
};

/// Inline text of a decoded control command (names, setting values).
pub const ControlText = struct {
    bytes: [128]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const ControlText) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const SettingValueKind = enum { default, word, string, number };

/// A decoded transaction-control or session command (store-executed).
pub const Control = union(enum) {
    /// An ordinary SQL statement.
    none: void,
    begin: Isolation,
    commit: void,
    rollback: void,
    savepoint: ControlText,
    release: ControlText,
    rollback_to: ControlText,
    /// `name` is lower case; TIME ZONE is "timezone".
    set: struct { local: bool, name: ControlText, kind: SettingValueKind, value: ControlText },
    set_transaction: Isolation,
    /// TRANSACTION ISOLATION LEVEL is "transaction_isolation".
    show: ControlText,
    /// null = RESET ALL.
    reset: ?ControlText,
};

pub const StatementOptions = struct {
    /// Re-delivery of a parked statement: same snapshot and command id.
    @"resume": bool = false,
    /// false: a statement that writes is rolled back with ReadOnlyTransaction.
    writes: bool = true,
    mode: ParseMode = .standard,
    /// Leave a mutation's affected count and tag out of `result` (see
    /// Database.lastOutcome); the caller writes them after commit.
    hold_result: bool = false,
};

pub fn Database(comptime config: Config) type {
    if (config.integer_bits != 32 and config.integer_bits != 64) @compileError("SQL INTEGER width must be 32 or 64");
    if (config.tables == 0 or config.columns == 0 or config.rows_per_table == 0 or
        config.name_bytes == 0 or config.text_bytes == 0 or config.predicates == 0 or
        config.expr_nodes == 0 or config.expr_depth == 0 or config.transactions == 0)
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
    const M = mvcc_module.Mvcc(config);
    const L = locks_module.Locks(config);
    const K = catalog_module.Catalog(config);

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
        pub const Snapshot = storage.Snapshot;
        pub const LockSet = L.Set;
        pub const versions_per_table = S.versions_capacity;
        pub const transaction_capacity = config.transactions;
        pub const savepoint_capacity = config.savepoints;
        pub const write_capacity = M.write_capacity;
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

        pub const Outcome = struct { affected: usize = 0, command: CommandTag = .none };

        /// Statement-scoped scratch inside caller-owned database storage.
        pub const Workspace = struct {
            nodes: A.Pool = .{},
        };

        tables: [config.tables]S.Table = @splat(.{}),
        catalog: K = .{},
        txs: [config.transactions]M.Tx = @splat(.{}),
        locks: L = .{},
        /// Table OIDs are first_oid + counter; never reused while committed.
        oid_counter: u32 = 0,
        /// Global commit sequence number, advanced only at publish.
        csn: u64 = 0,
        /// Command id used by change-record replay.
        cid: u32 = 0,
        /// Transaction epoch counter (unique per transaction and replay).
        epoch: u32 = 0,
        /// Bumped whenever locks are released or a transaction ends; parked
        /// callers re-deliver their statement when it changes.
        wake_epoch: u64 = 0,
        /// FIFO order of table-lock waiters.
        wait_counter: u64 = 0,
        /// Outcome of the last completed statement (written to the caller's
        /// result after the statement, or after commit for autocommit).
        outcome: Outcome = .{},
        /// Session dialect of the next statement (callers serialize access
        /// and set it per call; Store.Connection does). Not database state.
        dialect: Dialect = .postgres,
        workspace: Workspace = .{},

        /// Includes all caller-owned table, version, index, catalog,
        /// transaction, lock and statement storage.
        pub fn storageBytes() usize {
            return @sizeOf(Self);
        }

        /// Copy a complete committed logical state into distinct storage. The
        /// source must have no active transaction; the copy has none.
        pub fn copyFrom(self: *Self, source: *const Self) void {
            if (self == source) return;
            self.oid_counter = source.oid_counter;
            self.csn = source.csn;
            self.cid = source.cid;
            self.epoch = source.epoch;
            self.catalog = source.catalog;
            self.locks = .{};
            for (&self.txs) |*tx| tx.active = false;
            for (&self.tables, &source.tables) |*destination, *table| {
                destination.live = table.live;
                destination.pending_create = false;
                destination.pending_drop = false;
                destination.dead_csn = table.dead_csn;
                if (!table.live) continue;
                S.copyTable(destination, table);
            }
        }

        pub fn tableCount(self: *const Self) usize {
            var count: usize = 0;
            for (&self.tables) |*table| if (S.committedTable(table)) {
                count += 1;
            };
            return count;
        }

        // ---- autocommit conveniences ------------------------------------

        /// Result contains copied SELECT rows or a mutation's affected_rows.
        /// Any error preserves the previous result and the whole database.
        pub fn execute(self: *Self, source: []const u8, result: *Result) Error!void {
            return self.autocommit(source, result, .standard, NoCommit{});
        }

        /// Replays one alpha SQL-text statement (WAL kinds 1/2): alpha grammar,
        /// alpha boolean integers (assignment and comparison), the configured
        /// INTEGER width, whatever the dialect.
        /// Anything outside the alpha grammar fails with UnsupportedLogVersion.
        pub fn executeLegacy(self: *Self, source: []const u8, result: *Result) Error!void {
            return self.autocommit(source, result, .legacy_alpha, NoCommit{});
        }

        const NoCommit = struct {
            fn before(_: @This(), _: *Self, _: u16, _: bool) Error!void {}
        };

        const CommitBoundary = struct {
            context: ?*anyopaque,
            commit: *const fn (?*anyopaque) anyerror!void,

            fn before(self: @This(), _: *Self, _: u16, selected: bool) anyerror!void {
                if (!selected) try self.commit(self.context);
            }
        };

        const RecordSink = struct {
            record: []u8,
            used: *usize,
            context: ?*anyopaque,
            commit: ?RecordCommitFn,

            fn before(self: @This(), db: *Self, slot: u16, selected: bool) anyerror!void {
                if (selected) return;
                var writer = try change_log.Writer.init(self.record, self.used.*);
                try db.encodeWrites(&writer, slot);
                const length = try writer.finish();
                if (self.commit) |commit| try commit(self.context, self.record[0..length]);
                self.used.* = length;
            }
        };

        /// Validate the entire statement before calling commit, then publish
        /// its mutation without any further fallible operation. A statement
        /// without writes never calls commit. Failed validation or commit
        /// preserves the database and result. The callback must not mutate
        /// this database, source, or result, or reenter a write.
        pub fn executeWithCommit(self: *Self, source: []const u8, result: *Result, context: ?*anyopaque, commit: *const fn (?*anyopaque) anyerror!void) anyerror!void {
            return self.autocommit(source, result, .standard, CommitBoundary{ .context = context, .commit = commit });
        }

        /// Like executeWithCommit, but encodes the completed statement's row
        /// and DDL ops as a kind-3 change record appended to record[used..]; a
        /// header is written when used is 0. With `commit`, the complete
        /// record is passed to it before publication. `used` changes only when
        /// the statement succeeds; overflow is TransactionLogCapacity with no
        /// state change. SELECT encodes nothing and never commits.
        pub fn executeChanges(self: *Self, source: []const u8, result: *Result, record: []u8, used: *usize, context: ?*anyopaque, commit: ?RecordCommitFn) anyerror!void {
            return self.autocommit(source, result, .standard, RecordSink{ .record = record, .used = used, .context = context, .commit = commit });
        }

        fn autocommit(self: *Self, source: []const u8, result: *Result, mode: ParseMode, sink: anytype) !void {
            const slot = try self.begin();
            // A mutation's outcome reaches `result` only after the sink and
            // publication, so the hook observes the previous result.
            self.statement(slot, source, result, .{ .mode = mode, .hold_result = true }) catch |err| {
                self.abort(slot);
                return err;
            };
            // The hook may observe the database (read-only), which reuses
            // `outcome`; keep this statement's own.
            const outcome = self.outcome;
            sink.before(self, slot, outcome.command == .select) catch |err| {
                self.abort(slot);
                return err;
            };
            self.publishCommit(slot);
            self.outcome = outcome;
            self.writeOutcome(result);
        }

        fn writeOutcome(self: *const Self, result: *Result) void {
            if (self.outcome.command == .select) return;
            result.clear(self.outcome.affected);
            result.command = self.outcome.command;
        }

        // ---- transactions -------------------------------------------------

        /// Starts a transaction; returns its slot.
        pub fn begin(self: *Self) Error!u16 {
            for (&self.txs, 0..) |*tx, slot| if (!tx.active) {
                self.epoch +%= 1;
                if (self.epoch == 0) self.epoch = 1;
                tx.active = true;
                tx.epoch = self.epoch;
                tx.cid = 0;
                tx.write_len = 0;
                tx.sub_len = 0;
                tx.lock_len = 0;
                tx.pin = null;
                tx.fresh = false;
                tx.waiting_for = .{};
                tx.table_wait = null;
                return @intCast(slot);
            };
            return error.TransactionCapacity;
        }

        pub fn active(self: *const Self, slot: u16) bool {
            return slot < config.transactions and self.txs[slot].active;
        }

        /// A transaction with no write is read-only: commit needs no record.
        pub fn readOnly(self: *const Self, slot: u16) bool {
            return self.txs[slot].write_len == 0;
        }

        /// Encodes the transaction's change record into `buffer`. Fallible,
        /// changes nothing (overflow is TransactionLogCapacity).
        pub fn prepareCommit(self: *const Self, slot: u16, buffer: []u8) Error![]const u8 {
            var writer = try change_log.Writer.init(buffer, 0);
            try self.encodeWrites(&writer, slot);
            return buffer[0..try writer.finish()];
        }

        /// Infallible publication: stamps every write, advances csn, releases
        /// every lock and frees the slot.
        pub fn publishCommit(self: *Self, slot: u16) void {
            const tx = &self.txs[slot];
            const wrote = tx.write_len != 0;
            if (wrote) {
                const csn = self.csn + 1;
                M.stamp(self, slot, csn);
                self.csn = csn;
            }
            M.releaseLocks(self, slot, 0);
            self.free(slot);
            if (wrote) {
                const at = self.horizon();
                M.reclaim(self, slot, at);
                self.reclaimTables(at);
            }
            tx.write_len = 0;
        }

        /// Undoes every write and releases every lock of the transaction.
        pub fn abort(self: *Self, slot: u16) void {
            if (!self.active(slot)) return;
            M.abortSlice(self, slot, 0, 0);
            self.free(slot);
        }

        fn free(self: *Self, slot: u16) void {
            const tx = &self.txs[slot];
            tx.active = false;
            tx.sub_len = 0;
            tx.pin = null;
            tx.fresh = false;
            tx.waiting_for = .{};
            tx.table_wait = null;
            for (&self.txs) |*other| other.waiting_for.remove(slot);
            self.wake_epoch +%= 1;
        }

        /// Terminal error inside a transaction block: aborts everything since
        /// the innermost savepoint (or the whole transaction's work), as
        /// PostgreSQL's AbortSubTransaction/AbortTransaction do at error
        /// time. Savepoint entries stay so ROLLBACK TO can recover.
        pub fn failScope(self: *Self, slot: u16) void {
            if (!self.active(slot)) return;
            const tx = &self.txs[slot];
            self.dropStatement(slot);
            var start: usize = 0;
            var lock_start: usize = 0;
            if (tx.sub_len != 0) {
                start = tx.subs[tx.sub_len - 1].write_start;
                lock_start = tx.subs[tx.sub_len - 1].lock_start;
            }
            M.abortSlice(self, slot, start, lock_start);
            self.wake_epoch +%= 1;
        }

        /// Aborts a parked statement's subtransaction (cancel, timeout,
        /// deadlock victim, disconnect). The transaction keeps what it held
        /// before the statement.
        pub fn abortStatement(self: *Self, slot: u16) void {
            if (!self.active(slot)) return;
            self.dropStatement(slot);
            self.wake_epoch +%= 1;
        }

        fn dropStatement(self: *Self, slot: u16) void {
            const tx = &self.txs[slot];
            if (tx.sub_len != 0 and tx.subs[tx.sub_len - 1].statement) {
                const sub = tx.subs[tx.sub_len - 1];
                M.abortSlice(self, slot, sub.write_start, sub.lock_start);
                tx.sub_len -= 1;
            }
            tx.pin = null;
            tx.fresh = false;
            tx.waiting_for = .{};
            tx.table_wait = null;
        }

        pub fn parked(self: *const Self, slot: u16) bool {
            return self.active(slot) and self.txs[slot].pin != null;
        }

        /// The transactions a parked statement waits for.
        pub fn waitingFor(self: *const Self, slot: u16) L.Set {
            return self.txs[slot].waiting_for;
        }

        /// The bounded iterative DFS used by deadlocked(), over explicit
        /// wait-for sets (`waits[slot]` = transactions slot waits for).
        pub fn waitCycle(waits: *const [config.transactions]L.Set, start: usize) bool {
            return L.cycle(waits, start);
        }

        /// Deadlock check (one-time, at wait_start + deadlock_timeout): true
        /// when the parked transaction is in a cycle of the wait-for graph.
        pub fn deadlocked(self: *const Self, slot: u16) bool {
            var waits: [config.transactions]L.Set = @splat(.{});
            for (&self.txs, 0..) |*tx, index| {
                if (tx.active and tx.pin != null) waits[index] = tx.waiting_for;
            }
            return L.cycle(&waits, slot);
        }

        // ---- savepoints ---------------------------------------------------

        pub fn savepoint(self: *Self, slot: u16, name: []const u8) Error!void {
            const tx = &self.txs[slot];
            if (tx.sub_len >= config.savepoints) return error.SavepointCapacity;
            var sub: M.Sub = .{ .write_start = @intCast(tx.write_len), .lock_start = @intCast(tx.lock_len) };
            if (name.len > config.name_bytes) return error.NameCapacity;
            sub.name.len = name.len;
            @memcpy(sub.name.bytes[0..name.len], name);
            tx.subs[tx.sub_len] = sub;
            tx.sub_len += 1;
        }

        fn findSavepoint(self: *const Self, slot: u16, name: []const u8) Error!usize {
            const tx = &self.txs[slot];
            var index = tx.sub_len;
            while (index != 0) {
                index -= 1;
                const sub = &tx.subs[index];
                if (!sub.statement and types.same(sub.name.slice(), name)) return index;
            }
            return error.SavepointNotFound;
        }

        /// Merges the savepoint (and every newer one) into its parent.
        /// Returns the savepoint's depth (its index in the stack).
        pub fn release(self: *Self, slot: u16, name: []const u8) Error!usize {
            const index = try self.findSavepoint(slot, name);
            self.txs[slot].sub_len = index;
            return index;
        }

        /// Undoes everything after the savepoint, which stays established.
        pub fn rollbackTo(self: *Self, slot: u16, name: []const u8) Error!usize {
            const index = try self.findSavepoint(slot, name);
            const tx = &self.txs[slot];
            const sub = tx.subs[index];
            M.abortSlice(self, slot, sub.write_start, sub.lock_start);
            tx.sub_len = index + 1;
            self.wake_epoch +%= 1;
            return index;
        }

        pub fn savepointDepth(self: *const Self, slot: u16) usize {
            return self.txs[slot].userSavepoints();
        }

        // ---- statements ---------------------------------------------------

        /// Runs one statement in transaction `slot` as a statement
        /// subtransaction. Success merges it; a terminal error undoes it
        /// (atomicity) and leaves `result` untouched; WouldBlock keeps it
        /// open with its versions and locks (re-deliver with .resume).
        pub fn statement(self: *Self, slot: u16, source: []const u8, result: *Result, options: StatementOptions) Error!void {
            if (!self.active(slot)) return error.NoActiveTransaction;
            const tx = &self.txs[slot];
            const parsed = P.parse(source, &self.workspace.nodes, options.mode) catch |err| {
                if (options.@"resume") self.dropStatement(slot);
                return legacy(options.mode, err);
            };
            var snap: Snapshot = undefined;
            if (options.@"resume") {
                const pinned = tx.pin orelse return error.QueryCanceled;
                snap = pinned;
                // A wait before any data access (table lock, catalog) takes a
                // fresh snapshot, as PostgreSQL locks before snapshotting.
                if (tx.fresh) snap.csn = self.csn;
                tx.pin = null;
                tx.fresh = false;
            } else {
                if (tx.pin != null) return error.QueryCanceled;
                if (tx.sub_len >= M.sub_capacity) return error.SavepointCapacity;
                tx.cid +%= 1;
                snap = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid };
                tx.subs[tx.sub_len] = .{ .statement = true, .write_start = @intCast(tx.write_len), .lock_start = @intCast(tx.lock_len) };
                tx.sub_len += 1;
            }
            const start = tx.subs[tx.sub_len - 1].write_start;
            self.body(slot, source, &parsed, snap, result, options.mode) catch |err| {
                if (err == error.WouldBlock) {
                    tx.pin = snap;
                    return err;
                }
                self.dropStatement(slot);
                self.wake_epoch +%= 1;
                return legacy(options.mode, err);
            };
            if (!options.writes and tx.write_len > start) {
                self.dropStatement(slot);
                return error.ReadOnlyTransaction;
            }
            tx.sub_len -= 1;
            tx.waiting_for = .{};
            tx.table_wait = null;
            if (!options.hold_result) self.writeOutcome(result);
        }

        /// Affected rows and command tag of the last completed statement.
        pub fn lastOutcome(self: *const Self) Outcome {
            return self.outcome;
        }

        /// Writes a held mutation outcome (StatementOptions.hold_result)
        /// into `result` once the caller's commit succeeded.
        pub fn lastOutcomeInto(self: *const Self, result: *Result) void {
            self.writeOutcome(result);
        }

        fn legacy(mode: ParseMode, err: Error) Error {
            if (mode == .legacy_alpha and (err == error.Syntax or err == error.UnsupportedStatement)) return error.UnsupportedLogVersion;
            return err;
        }

        fn bindContext(self: *Self, source: []const u8, mode: ParseMode, snap: Snapshot) B.Context {
            return .{ .source = source, .tables = &self.tables, .catalog = &self.catalog, .snapshot = snap, .pool = &self.workspace.nodes, .legacy = mode == .legacy_alpha, .dialect = self.dialect };
        }

        fn evalContext(self: *const Self, source: []const u8) E.Context {
            return .{ .source = source, .pool = &self.workspace.nodes };
        }

        fn body(self: *Self, slot: u16, source: []const u8, parsed: *const A.Statement, snap: Snapshot, result: *Result, mode: ParseMode) Error!void {
            const context = self.bindContext(source, mode, snap);
            const bound = try B.bind(&context, parsed);
            switch (bound) {
                .control => return error.UnsupportedStatement,
                .select => |*select| {
                    self.outcome = .{ .affected = 0, .command = .select };
                    if (select.table) |table| try self.lockTable(slot, table, .access_share);
                    if (select.lock.strength == .none)
                        return X.select(&self.tables, source, &self.workspace.nodes, select, snap, result, X.NoLock{});
                    const locker: RowLocker = .{ .db = self, .slot = slot, .snap = snap, .mode = if (select.lock.strength == .update) .update else .share, .wait = select.lock.wait };
                    return X.select(&self.tables, source, &self.workspace.nodes, select, snap, result, locker);
                },
                else => {},
            }
            const affected: usize = switch (bound) {
                .create_table => |*create| try self.createTable(slot, create, snap),
                .drop_table => |index| try self.dropTable(slot, index, snap),
                .insert => |*insert| blk: {
                    try self.lockTable(slot, insert.table, .row_exclusive);
                    break :blk try self.insertRow(slot, source, insert, snap);
                },
                .update => |*update| blk: {
                    try self.lockTable(slot, update.table, .row_exclusive);
                    break :blk try self.updateRows(slot, source, update, snap);
                },
                .delete => |*delete| blk: {
                    try self.lockTable(slot, delete.table, .row_exclusive);
                    break :blk try self.deleteRows(slot, source, delete, snap);
                },
                .select, .control => unreachable,
            };
            self.outcome = .{ .affected = affected, .command = B.command(&bound) };
        }

        /// Reclamation horizon: no pinned snapshot can see a version whose
        /// xmax_csn is at or below it.
        fn horizon(self: *const Self) u64 {
            var out = self.csn;
            for (&self.txs) |*tx| if (tx.active and !tx.fresh) {
                if (tx.pin) |pin| out = @min(out, pin.csn);
            };
            return out;
        }

        fn reclaimTables(self: *Self, at: u64) void {
            var freed = false;
            for (&self.tables) |*table| if (table.live and table.dead_csn != 0 and table.dead_csn <= at) {
                table.live = false;
                table.dead_csn = 0;
                freed = true;
            };
            if (freed) _ = self.catalog.vacuum(at);
        }

        fn park(self: *Self, slot: u16, waits: L.Set) Error {
            self.txs[slot].waiting_for = waits;
            return error.WouldBlock;
        }

        fn tableConflict(a: locks_module.TableMode, b: locks_module.TableMode) bool {
            return a == .access_exclusive or b == .access_exclusive;
        }

        /// Table lock held to transaction end; conflicts and FIFO waiters
        /// ahead of us park the statement (fresh snapshot on resume).
        fn lockTable(self: *Self, slot: u16, table: usize, mode: locks_module.TableMode) Error!void {
            const tx = &self.txs[slot];
            if (self.locks.holdsTableMode(table, slot, mode)) return;
            var waits: L.Set = .{};
            self.locks.tableHolders(table, slot, mode, &waits);
            if (!self.locks.holdsTable(table, slot)) {
                const own_seq = if (tx.table_wait) |wait| wait.seq else 0xffffffffffffffff;
                for (&self.txs, 0..) |*other, index| {
                    if (index == slot or !other.active or other.pin == null) continue;
                    const wait = other.table_wait orelse continue;
                    if (wait.table == table and wait.seq < own_seq and tableConflict(mode, wait.mode)) waits.add(index);
                }
            }
            if (waits.any()) {
                if (tx.table_wait == null) {
                    self.wait_counter += 1;
                    tx.table_wait = .{ .table = @intCast(table), .mode = mode, .seq = self.wait_counter };
                }
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            if (self.locks.grantTable(table, slot, mode)) tx.pushLock(.{ .kind = .table, .table = @intCast(table), .mode = @intFromEnum(mode) });
            tx.table_wait = null;
        }

        const Target = union(enum) { skip, authored, wait, ready: u32 };

        /// EvalPlanQual: from the snapshot-visible version, follow committed
        /// successors to the newest version and report what blocks it.
        fn target(self: *Self, slot: u16, table_index: usize, version: u32, snap: Snapshot, mode: locks_module.RowMode, waits: *L.Set) Target {
            const table = &self.tables[table_index];
            var current = version;
            while (true) {
                const entry = &table.versions[current];
                if (entry.xmax.epoch != 0) {
                    if (entry.xmax_csn != 0) {
                        current = S.successor(table, current) orelse return .skip;
                        continue;
                    }
                    if (snap.own(entry.xmax)) return if (entry.xmax_cid == snap.cid) .authored else .skip;
                    waits.add(entry.xmax.slot);
                }
                self.locks.rowHolders(table_index, table.rows[entry.row - 1].rowid, slot, mode, waits);
                if (waits.any()) return .wait;
                return .{ .ready = current };
            }
        }

        const RowLocker = struct {
            db: *Self,
            slot: u16,
            snap: Snapshot,
            mode: locks_module.RowMode,
            wait: ast.LockWait,

            pub const active = true;

            pub fn lock(self: RowLocker, table_index: usize, version: u32) Error!?u32 {
                const db = self.db;
                var waits: L.Set = .{};
                switch (db.target(self.slot, table_index, version, self.snap, self.mode, &waits)) {
                    .skip, .authored => return null,
                    .wait => switch (self.wait) {
                        .nowait => return error.LockNotAvailable,
                        .skip_locked => return null,
                        .block => return db.park(self.slot, waits),
                    },
                    .ready => |newest| {
                        const table = &db.tables[table_index];
                        const rowid = table.rows[table.versions[newest].row - 1].rowid;
                        if (try db.locks.grantRow(table_index, rowid, self.slot, self.mode)) |index| {
                            db.txs[self.slot].pushLock(.{ .kind = .row, .table = @intCast(table_index), .mode = @intFromEnum(self.mode), .index = index });
                        }
                        return newest;
                    },
                }
            }
        };

        fn reserveWrites(self: *const Self, slot: u16, count: usize) Error!void {
            if (M.write_capacity - self.txs[slot].write_len < count) return error.WriteSetCapacity;
        }

        fn createTable(self: *Self, slot: u16, create: *const B.Create, snap: Snapshot) Error!usize {
            const tx = &self.txs[slot];
            if (self.catalog.creator(create.name.slice(), snap)) |owner| {
                var waits: L.Set = .{};
                waits.add(owner);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            try self.reserveWrites(slot, 2 + create.count);
            var destination: ?usize = null;
            for (0..2) |attempt| {
                for (&self.tables, 0..) |*table, index| if (!table.live) {
                    destination = index;
                    break;
                };
                if (destination != null or attempt == 1) break;
                self.reclaimTables(self.horizon());
            }
            const index = destination orelse return error.TableCapacity;
            if (self.oid_counter >= 0xffffffff - change_log.first_oid) return error.TableCapacity;
            const table = &self.tables[index];
            S.reset(table, change_log.first_oid + self.oid_counter, create.name, create.columns[0..create.count]);
            table.live = true;
            table.pending_create = true;
            self.oid_counter += 1;
            tx.push(.{ .kind = .create_table, .table = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const count = try self.catalog.create(index, table, tx.ref(slot), snap.cid, 0, self.horizon(), &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_insert, .table = @intFromEnum(change.relation), .new = change.version }) catch unreachable;
            return 0;
        }

        fn dropTable(self: *Self, slot: u16, index: usize, snap: Snapshot) Error!usize {
            try self.lockTable(slot, index, .access_exclusive);
            const tx = &self.txs[slot];
            const table = &self.tables[index];
            try self.reserveWrites(slot, 2 + table.column_count);
            table.pending_drop = true;
            tx.push(.{ .kind = .drop_table, .table = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const count = self.catalog.drop(index, table.column_count, snap, tx.ref(slot), snap.cid, 0, &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_delete, .table = @intFromEnum(change.relation), .old = change.version }) catch unreachable;
            return 0;
        }

        fn insertRow(self: *Self, slot: u16, source: []const u8, insert: *const B.Insert, snap: Snapshot) Error!usize {
            const tx = &self.txs[slot];
            const table = &self.tables[insert.table];
            var ctx = self.evalContext(source);
            const cells = try D.insertedRow(&ctx, table, &insert.values);
            if (table.primary_column) |column| switch (D.keyCheck(table, &cells[column], 0xffffffff, snap)) {
                .free => {},
                .taken => return error.PrimaryKeyViolation,
                .wait => |owner| {
                    var waits: L.Set = .{};
                    waits.add(owner);
                    return self.park(slot, waits);
                },
            };
            if (table.next_rowid == 0xffffffffffffffff) return error.RowCapacity;
            try self.reserveWrites(slot, 1);
            const at = self.horizon();
            try S.ensureVersions(table, 1, at);
            try S.ensureRowSlot(table, at);
            const row = S.allocRow(table, table.next_rowid);
            table.next_rowid += 1;
            const version = S.allocVersion(table);
            table.versions[version] = .{ .row = row + 1, .xmin = tx.ref(slot), .xmin_cid = snap.cid, .cells = cells };
            table.rows[row].newest = version + 1;
            S.indexKey(table, version);
            tx.push(.{ .kind = .insert, .table = @intCast(insert.table), .new = version }) catch unreachable;
            return 1;
        }

        /// Rows are visited in rowid order and updated one at a time, as a
        /// PostgreSQL heap scan does: WHERE, SET and key checks interleave.
        /// On resume, rows this statement already handled are skipped by
        /// authorship and still counted.
        fn updateRows(self: *Self, slot: u16, source: []const u8, update: *const B.Update, snap: Snapshot) Error!usize {
            const table = &self.tables[update.table];
            var ctx = self.evalContext(source);
            var affected: usize = 0;
            switch (try X.candidates(&ctx, table, update.key, snap)) {
                .empty => {},
                .slot => |row| affected += try self.updateSlot(slot, &ctx, update, row, snap),
                .scan => {
                    const high = table.row_high;
                    for (0..high) |row| affected += try self.updateSlot(slot, &ctx, update, @intCast(row), snap);
                },
            }
            return affected;
        }

        fn updateSlot(self: *Self, slot: u16, ctx: *E.Context, update: *const B.Update, row: u32, snap: Snapshot) Error!usize {
            const table = &self.tables[update.table];
            if (table.rows[row].newest == 0) return 0;
            const version = S.visibleAt(table, row, snap) orelse return 0;
            var waits: L.Set = .{};
            const plan = self.target(slot, update.table, version, snap, .write, &waits);
            if (plan == .authored) return 1;
            if (!try X.keep(ctx, update.where, &table.versions[version].cells)) return 0;
            const goal = switch (plan) {
                .skip, .authored => return 0,
                .wait => return self.park(slot, waits),
                .ready => |newest| newest,
            };
            if (goal != version and !try X.keep(ctx, update.where, &table.versions[goal].cells)) return 0;
            try self.updateOne(slot, ctx, update, row, goal, snap);
            return 1;
        }

        fn updateOne(self: *Self, slot: u16, ctx: *E.Context, update: *const B.Update, row: u32, old: u32, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const table = &self.tables[update.table];
            const cells = try D.updatedRow(ctx, table, &update.values, &table.versions[old].cells);
            if (table.primary_column) |column| {
                if (update.values[column] != ast.none) switch (D.keyCheck(table, &cells[column], row, snap)) {
                    .free => {},
                    .taken => return error.PrimaryKeyViolation,
                    .wait => |owner| {
                        var waits: L.Set = .{};
                        waits.add(owner);
                        return self.park(slot, waits);
                    },
                };
            }
            try self.reserveWrites(slot, 1);
            try S.ensureVersions(table, 1, self.horizon());
            const version = S.allocVersion(table);
            table.versions[version] = .{ .row = row + 1, .xmin = tx.ref(slot), .xmin_cid = snap.cid, .older = old + 1, .cells = cells };
            table.rows[row].newest = version + 1;
            table.versions[old].xmax = tx.ref(slot);
            table.versions[old].xmax_cid = snap.cid;
            S.indexKey(table, version);
            tx.push(.{ .kind = .update, .table = @intCast(update.table), .old = old, .new = version }) catch unreachable;
        }

        fn deleteRows(self: *Self, slot: u16, source: []const u8, delete: *const B.Delete, snap: Snapshot) Error!usize {
            const table = &self.tables[delete.table];
            var ctx = self.evalContext(source);
            var affected: usize = 0;
            switch (try X.candidates(&ctx, table, delete.key, snap)) {
                .empty => {},
                .slot => |row| affected += try self.deleteSlot(slot, &ctx, delete, row, snap),
                .scan => {
                    const high = table.row_high;
                    for (0..high) |row| affected += try self.deleteSlot(slot, &ctx, delete, @intCast(row), snap);
                },
            }
            return affected;
        }

        fn deleteSlot(self: *Self, slot: u16, ctx: *E.Context, delete: *const B.Delete, row: u32, snap: Snapshot) Error!usize {
            const tx = &self.txs[slot];
            const table = &self.tables[delete.table];
            if (table.rows[row].newest == 0) return 0;
            const version = S.visibleAt(table, row, snap) orelse return 0;
            var waits: L.Set = .{};
            const plan = self.target(slot, delete.table, version, snap, .write, &waits);
            if (plan == .authored) return 1;
            if (!try X.keep(ctx, delete.where, &table.versions[version].cells)) return 0;
            const goal = switch (plan) {
                .skip, .authored => return 0,
                .wait => return self.park(slot, waits),
                .ready => |newest| newest,
            };
            if (goal != version and !try X.keep(ctx, delete.where, &table.versions[goal].cells)) return 0;
            try self.reserveWrites(slot, 1);
            table.versions[goal].xmax = tx.ref(slot);
            table.versions[goal].xmax_cid = snap.cid;
            tx.push(.{ .kind = .delete, .table = @intCast(delete.table), .old = goal }) catch unreachable;
            return 1;
        }

        /// Every write in order (no coalescing: a later op may depend on an
        /// earlier one's key change); rolled-back slices were truncated.
        fn encodeWrites(self: *const Self, writer: *change_log.Writer, slot: u16) Error!void {
            const tx = &self.txs[slot];
            for (tx.writes[0..tx.write_len]) |entry| {
                switch (entry.kind) {
                    .insert, .update => {
                        const table = &self.tables[entry.table];
                        const version = &table.versions[entry.new];
                        const tag: change_log.Op = if (entry.kind == .insert) .insert else .update;
                        try C.encodeRow(writer, tag, table.oid, table.rows[version.row - 1].rowid, version.cells[0..table.column_count]);
                    },
                    .delete => {
                        const table = &self.tables[entry.table];
                        try C.encodeDelete(writer, table.oid, table.rows[table.versions[entry.old].row - 1].rowid);
                    },
                    .create_table => try C.encodeCreate(writer, &self.tables[entry.table]),
                    .drop_table => try C.encodeDrop(writer, self.tables[entry.table].oid),
                    .catalog_insert, .catalog_delete => {},
                }
            }
        }

        // ---- control commands and description ---------------------------

        fn decodeIdent(source: []const u8, ident: ast.Ident, out: *ControlText) Error!void {
            if (ident.len > out.bytes.len) return error.NameCapacity;
            const raw = ident.span.slice(source);
            out.len = ident.len;
            if (ident.quoted) {
                lexer.decodeQuotedWith(source, .{ .start = ident.span.start, .end = ident.span.start + ident.span.len, .len = ident.len }, '"', &out.bytes);
            } else for (raw, 0..) |byte, index| {
                out.bytes[index] = types.lower(byte);
            }
        }

        fn settingName(source: []const u8, name: ast.SettingName, out: *ControlText) Error!void {
            const special: []const u8 = switch (name.special) {
                .none => return decodeIdent(source, name.ident, out),
                .time_zone => "timezone",
                .transaction_isolation => "transaction_isolation",
            };
            out.len = special.len;
            @memcpy(out.bytes[0..special.len], special);
        }

        fn settingValue(source: []const u8, value: ast.SettingValue, out: *ControlText) Error!SettingValueKind {
            switch (value.kind) {
                .default => out.len = 0,
                .word, .number => {
                    const raw = value.span.slice(source);
                    if (raw.len > out.bytes.len) return error.InvalidSettingValue;
                    out.len = raw.len;
                    @memcpy(out.bytes[0..raw.len], raw);
                },
                .string => {
                    if (value.quoted.len > out.bytes.len) return error.InvalidSettingValue;
                    lexer.decodeQuotedWith(source, value.quoted, '\'', &out.bytes);
                    out.len = value.quoted.len;
                },
            }
            return switch (value.kind) {
                .default => .default,
                .word => .word,
                .string => .string,
                .number => .number,
            };
        }

        fn controlWord(source: []const u8) bool {
            var tokens: lexer.Tokenizer = .{ .source = source, .text_limit = config.text_bytes };
            const first = tokens.next() catch return false;
            if (first.kind != .word) return false;
            return switch (first.keyword) {
                .begin, .start, .commit, .end, .abort, .rollback, .savepoint, .release, .set, .show, .reset => true,
                else => false,
            };
        }

        /// Decodes a transaction-control or session command; `.none` for an
        /// ordinary statement. Syntax errors in a control command return.
        pub fn control(self: *Self, source: []const u8) Error!Control {
            if (!controlWord(source)) return .none;
            const parsed = try P.parse(source, &self.workspace.nodes, .standard);
            const command = switch (parsed) {
                .control => |command| command,
                else => return .none,
            };
            var out: Control = .none;
            switch (command) {
                .begin => |level| out = .{ .begin = level },
                .commit => out = .commit,
                .rollback => out = .rollback,
                .savepoint => |name| {
                    out = .{ .savepoint = .{} };
                    try decodeIdent(source, name, &out.savepoint);
                },
                .release => |name| {
                    out = .{ .release = .{} };
                    try decodeIdent(source, name, &out.release);
                },
                .rollback_to => |name| {
                    out = .{ .rollback_to = .{} };
                    try decodeIdent(source, name, &out.rollback_to);
                },
                .set => |set| {
                    out = .{ .set = .{ .local = set.local, .name = .{}, .kind = .default, .value = .{} } };
                    try settingName(source, set.name, &out.set.name);
                    out.set.kind = try settingValue(source, set.value, &out.set.value);
                },
                .set_transaction => |level| out = .{ .set_transaction = level },
                .show => |name| {
                    out = .{ .show = .{} };
                    try settingName(source, name, &out.show);
                },
                .reset => |name| {
                    out = .{ .reset = null };
                    if (name) |value| {
                        var text: ControlText = .{};
                        try settingName(source, value, &text);
                        out = .{ .reset = text };
                    }
                },
            }
            return out;
        }

        /// Parse and bind without executing, under the snapshot of the
        /// transaction `slot` (or the committed state). SELECT reports its
        /// output columns.
        pub fn describe(self: *Self, source: []const u8, result: *Result) Error!void {
            return self.describeIn(null, source, result);
        }

        pub fn describeIn(self: *Self, slot: ?u16, source: []const u8, result: *Result) Error!void {
            const parsed = try P.parse(source, &self.workspace.nodes, .standard);
            var snap: Snapshot = .{ .csn = self.csn };
            if (slot) |owner| if (self.active(owner)) {
                snap = .{ .csn = self.csn, .slot = owner, .epoch = self.txs[owner].epoch, .cid = self.txs[owner].cid +% 1 };
            };
            const context = self.bindContext(source, .standard, snap);
            const bound = try B.bind(&context, &parsed);
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

        // ---- replay and introspection -----------------------------------

        /// Applies a kind-3 change record atomically: the whole record is
        /// decoded and validated against `scratch` before anything changes.
        /// Replay runs before any transaction starts.
        pub fn applyChangeRecord(self: *Self, record: []const u8, scratch: *ReplayScratch) Error!void {
            try C.apply(self, record, scratch);
            self.reclaimTables(self.csn);
            self.wake_epoch +%= 1;
        }

        /// Replay hook: committed catalog rows for a table slot just reset.
        pub fn replayCreate(self: *Self, index: usize, csn: u64) Error!void {
            var changes: [K.max_changes]K.Change = undefined;
            const table = &self.tables[index];
            table.live = true;
            table.pending_create = false;
            _ = try self.catalog.create(index, table, .{ .epoch = self.epoch }, self.cid, csn, csn, &changes);
        }

        /// Replay hook: a committed DROP TABLE.
        pub fn replayDrop(self: *Self, index: usize, csn: u64) void {
            var changes: [K.max_changes]K.Change = undefined;
            const table = &self.tables[index];
            _ = self.catalog.drop(index, table.column_count, storage.committed_view, .{ .epoch = self.epoch }, self.cid, csn, &changes);
            table.dead_csn = csn;
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

        fn committedIndex(self: *const Self, table_name: []const u8) ?usize {
            return self.catalog.lookup(table_name, storage.committed_view);
        }

        pub fn storageStats(self: *const Self, table_name: []const u8) ?StorageStats {
            const index = self.committedIndex(table_name) orelse return null;
            return S.stats(&self.tables[index]);
        }

        pub fn rowRef(self: *const Self, table_name: []const u8, rowid: u64) ?RowRef {
            const index = self.committedIndex(table_name) orelse return null;
            const table = &self.tables[index];
            const slot = S.findRow(table, rowid) orelse return null;
            return .{ .slot = slot, .generation = table.rows[slot].generation };
        }

        /// Resolves a reference to its rowid; stale generations never resolve.
        pub fn resolveRowRef(self: *const Self, table_name: []const u8, ref: RowRef) ?u64 {
            const index = self.committedIndex(table_name) orelse return null;
            const table = &self.tables[index];
            if (ref.slot >= table.row_high) return null;
            const slot = &table.rows[ref.slot];
            if (slot.newest == 0 or slot.generation != ref.generation) return null;
            return slot.rowid;
        }

        /// Reclaims every dead version and empty row slot no pinned snapshot
        /// can still see.
        pub fn vacuum(self: *Self) usize {
            const at = self.horizon();
            var freed: usize = 0;
            for (&self.tables) |*table| if (table.live) {
                freed += S.vacuum(table, at);
            };
            self.reclaimTables(at);
            return freed + self.catalog.vacuum(at);
        }

        /// Leak accounting for contracts: active transactions, held row and
        /// table locks, and uncommitted versions or marks anywhere.
        pub const Usage = struct { transactions: usize, row_locks: usize, table_locks: usize, pending_versions: usize };

        pub fn usage(self: *const Self) Usage {
            var out: Usage = .{ .transactions = 0, .row_locks = self.locks.rowLocksUsed(), .table_locks = self.locks.tableLocksHeld(), .pending_versions = self.catalog.pending() };
            for (&self.txs) |*tx| if (tx.active) {
                out.transactions += 1;
            };
            for (&self.tables) |*table| if (table.live) {
                out.pending_versions += S.stats(table).pending;
            };
            return out;
        }
    };
}
