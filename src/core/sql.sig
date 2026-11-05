//! Bounded, allocation-free in-memory SQL (Layer 0).
//!
//! Database and result storage belong entirely to the caller. Identifiers and
//! text cells are copied inline; neither statements nor results borrow database
//! storage. Callers serialize the default database methods. Independent
//! ReadContext instances may execute on threads while the caller holds shared
//! immutable ownership and excludes all database/schema mutations.
//!
//! Supported: CREATE/DROP TABLE (DEFAULT, GENERATED {ALWAYS|BY DEFAULT} AS
//! IDENTITY, GENERATED ALWAYS AS (expr) STORED); CREATE/DROP SEQUENCE and
//! nextval/currval/setval/lastval (sequence.sig); INSERT [AS alias] [column
//! list] VALUES rows | SELECT | DEFAULT VALUES [OVERRIDING ...] [ON CONFLICT
//! ... DO NOTHING | DO UPDATE] [RETURNING]; UPDATE/DELETE ... RETURNING; the
//! system views of catalog.sig with current_database, to_regtype,
//! to_regclass, format_type and ::regclass/::regtype;
//! SELECT [DISTINCT [ON (...)]] expressions [FROM tables,
//! derived tables and CTEs joined INNER/LEFT/RIGHT/FULL/CROSS ON|USING]
//! [WHERE] [GROUP BY] [HAVING] with aggregates (COUNT/SUM/AVG/MIN/MAX/
//! BOOL_AND/BOOL_OR, DISTINCT, FILTER), scalar/IN/EXISTS and ANY/SOME/ALL subqueries, WITH
//! [RECURSIVE], UNION/INTERSECT/EXCEPT [ALL], [ORDER BY expressions/positions/
//! output names] [LIMIT|OFFSET|FETCH FIRST] [FOR UPDATE|SHARE [NOWAIT|SKIP
//! LOCKED]] (single table only); UPDATE with expression SET; DELETE; COPY
//! FROM STDIN / TO STDOUT through copyInfo/copyBegin/copyBuild/copyInsert/
//! copyEnd (row formats belong to the caller's codec). General
//! queries run in the bounded statement workspace (Config.work_rows;
//! WorkspaceCapacity, 54000, when exhausted). Types are
//! SMALLINT, INTEGER (int4), BIGINT (int8), NUMERIC[(p,s)] (at most
//! Config.numeric_digits significant digits), REAL, DOUBLE PRECISION,
//! BOOLEAN, TEXT, NAME, OID, DATE, TIMESTAMP[(p)], TIMESTAMPTZ[(p)], INTERVAL,
//! JSON and JSONB (encoded size at most Config.text_bytes) and NULL; see
//! value.sig, numeric.sig, float_text.sig, temporal.sig, tzif.sig and
//! jsonb.sig for their exact input/output rules. Expressions (design
//! §4.1): AND/OR/NOT with three-valued logic, comparisons, IS [NOT]
//! NULL/TRUE/FALSE/UNKNOWN and DISTINCT FROM, [NOT] IN lists, [NOT] BETWEEN, [NOT] LIKE/ILIKE,
//! Flat ROW constructor comparisons and NULL tests, GREATEST/LEAST, `||`, checked arithmetic over the numeric and datetime types, AT TIME
//! ZONE, JSON/JSONB extraction `-> ->> #> #>>`, JSONB `@> <@ ? ||`, CASE, COALESCE, NULLIF,
//! `::`/CAST, now() / CURRENT_TIMESTAMP / statement_timestamp() /
//! clock_timestamp() / CURRENT_DATE, jsonb_typeof and jsonb_array_length,
//! typed with PostgreSQL's implicit-cast rules. Constraints are NOT NULL and
//! a single-column PRIMARY KEY. Unquoted identifiers are ASCII and case
//! insensitive; quoted identifiers keep case; text comparison is bytewise.
//! Window support includes ROW_NUMBER/RANK/DENSE_RANK/PERCENT_RANK/CUME_DIST,
//! NTILE, LAG/LEAD, FIRST_VALUE/LAST_VALUE/NTH_VALUE and bounded aggregate frames/exclusions (see the SQL_WINDOW_*
//! module docs for demand and frame restrictions). Named WINDOW definitions
//! support scoped inheritance. General arrays/records and secondary indices remain outside this
//! SQL subset; this is not full SQL-standard or PostgreSQL compatibility.
//!
//! Session values (per statement, `Database.session`, set by the caller like
//! the dialect): TimeZone, a zone-name resolver, transaction/statement start
//! times and the wall clock (value.Session).
//!
//! Transactions (design §4.4-§4.5): READ COMMITTED only, over row versions.
//! Every statement takes a new snapshot and runs as a statement
//! subtransaction of its transaction (begin/statement/prepareCommit/
//! publishCommit/abort); savepoints are nested subtransactions. DDL is
//! transactional through the versioned catalog (catalog.sig). A statement
//! that meets a lock held by a live transaction returns WouldBlock with its
//! work kept; re-delivering it resumes with the same snapshot and command id
//! (EvalPlanQual re-checks on every remaining target). REPEATABLE READ keeps
//! the snapshot of the transaction's first query for every statement and
//! raises 40001 where READ COMMITTED would re-check a row a concurrent
//! transaction changed; SERIALIZABLE adds relation-granularity SSI
//! (ssi.sig); READ ONLY (25006), DEFERRABLE and the session state of the
//! tx-session lane (settings, cursors, SQL prepared statements, LOCK
//! TABLE, advisory locks, LISTEN/NOTIFY) are in session.sig. execute(),
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
//! -> binder (names under the statement snapshot, types, query plans; never
//! executes; powers describe()) -> expr (evaluation) -> exec (scans, filters,
//! projections, ORDER BY, LockRows; joins, grouping, DISTINCT, subqueries,
//! CTEs and set operations over the workspace; sort.sig merge sort) / dml
//! (row construction, assignment
//! casts, unique checks) over versioned storage (stable rowids, row versions,
//! PK multi-index, horizon-bounded reclamation), mvcc (transaction table,
//! write sets, subtransactions), locks (row/table locks, wait-for sets,
//! deadlock DFS), catalog (versioned base relations) -> kind-3 change records
//! (prepareCommit / applyChangeRecord). `legacy_alpha` replays kind 1/2
//! SQL-text WAL records with the frozen alpha grammar (alpha.sig) only.
//!
//! No allocator, platform or runtime dependency. The only std symbols this
//! module and sql/*.sig may ever use are std.fmt.parseFloat(T, s) and
//! std.fmt.float.render(buf, value, options); float_text.sig uses exactly
//! those two (REAL/DOUBLE input and shortest round-trip output).
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
const value_module = @import("sql/value.sig");
const numeric_module = @import("sql/numeric.sig");
const temporal_module = @import("sql/temporal.sig");
const tzif_module = @import("sql/tzif.sig");
const float_module = @import("sql/float_text.sig");
const sort_module = @import("sql/sort.sig");
const sequence_module = @import("sql/sequence.sig");
const deparse_module = @import("sql/deparse.sig");
const range_eval_module = @import("sql/range_eval.sig");
const session_module = @import("sql/session.sig");
const ssi_module = @import("sql/ssi.sig");
const routine_catalog = @import("sql/routine_catalog.sig");
const routine_module = @import("sql/routine.sig");
const CO = @import("sql/catalog_objects.sig");
const array_module = @import("sql/array.sig");

/// The canonical SQL tokenizer, also used by wire parameter binding.
/// Source and token spans remain caller-owned; tokenization allocates nothing.
pub const Tokenizer = lexer.Tokenizer;
pub const Config = types.Config;
/// Per-statement session values (TimeZone, zone resolver, clocks).
pub const Session = value_module.Session;
pub const Zone = temporal_module.Zone;
pub const ZoneResolver = temporal_module.Resolver;
pub const Interval = temporal_module.Interval;
pub const Numeric = numeric_module.Numeric;
pub const Type = types.Type;
pub const typeInfo = types.typeInfo;
pub const typeFromOid = types.typeFromOid;
/// Datetime helpers for codecs and callers (PostgreSQL epoch, zones).
pub const temporal = temporal_module;
/// TZif validation and POSIX TZ strings for zone providers.
pub const tzif = tzif_module;
/// REAL/DOUBLE text I/O.
pub const float_text = float_module;
/// The executor's stable merge sort over caller-owned index arrays
/// (returns the number of comparisons; contract tests count them).
pub const mergeSort = sort_module.mergeSort;
pub const offerTopK = sort_module.offerTopK;
pub const Error = types.Error;
pub const ExecutionControl = types.ExecutionControl;
pub const Dialect = types.Dialect;
pub const DataType = types.DataType;
pub const CommandTag = types.CommandTag;
pub const ParseMode = parser_module.Mode;
pub const Isolation = ast.Isolation;
pub const Characteristics = ast.Characteristics;
pub const typeOid = types.typeOid;
pub const CopyFormat = ast.CopyFormat;
pub const CopyHeader = ast.CopyHeader;
pub const CopyDirection = ast.CopyDirection;
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
    begin: Characteristics,
    commit: void,
    rollback: void,
    savepoint: ControlText,
    release: ControlText,
    rollback_to: ControlText,
    /// `name` is lower case; TIME ZONE is "timezone".
    set: struct { local: bool, name: ControlText, kind: SettingValueKind, value: ControlText },
    set_transaction: Characteristics,
    /// TRANSACTION ISOLATION LEVEL is "transaction_isolation".
    show: ControlText,
    /// null = RESET ALL.
    reset: ?ControlText,
    /// SET SESSION CHARACTERISTICS AS TRANSACTION (default_transaction_*).
    set_session_characteristics: Characteristics,
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
    /// The statement runs in an implicit (autocommit) transaction: LOCK
    /// TABLE and DECLARE without WITH HOLD are 25P01 there.
    implicit: bool = false,
};

pub fn Database(comptime config: Config) type {
    if (config.external_workspace and !config.external_storage) @compileError("external_workspace requires external_storage");
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
    const Q = sequence_module.Sequences(config);
    const G = deparse_module.Deparse(config);
    const Sess = session_module.Sessions(config);
    const SSI = ssi_module.Ssi(config);
    const RC = routine_catalog.Catalog(config);
    const R = routine_module.Routines(config);
    const O = CO.Objects(config);

    return struct {
        const Self = @This();
        pub const integer_type: DataType = B.integer_type;
        pub const Name = V.Name;
        pub const Text = V.Text;
        pub const Cell = V.Cell;
        pub const CellTag = V.CellTag;
        pub const SqlError = types.Error;
        pub const Zone = temporal_module.Zone;
        pub const SessionValues = value_module.Session;
        pub const ExecutionControl = types.ExecutionControl;
        pub const tzif = tzif_module;
        /// btree comparison of two non-NULL cells of the same type.
        pub const compareCells = V.compare;
        pub const Row = V.Row;
        pub const Column = V.Column;
        pub const RowRef = S.RowRef;
        pub const StorageStats = S.Stats;
        pub const StorageBacking = S.Backing;
        pub const StorageRowSlot = S.RowSlot;
        pub const StorageVersion = S.Version;
        pub const ReplayScratch = C.Scratch;
        pub const Snapshot = storage.Snapshot;
        pub const LockSet = L.Set;
        pub const versions_per_table = S.versions_capacity;
        pub const transaction_capacity = config.transactions;
        pub const savepoint_capacity = config.savepoints;
        pub const write_capacity = M.write_capacity;
        /// Per-session currval/lastval state; callers that own sessions set
        /// `sequence_session` before each statement (Store.Connection does).
        pub const SequenceSession = Q.Session;
        pub const sequence_capacity = config.sequences;
        /// Receives the complete change record before the statement publishes.
        pub const RecordCommitFn = *const fn (?*anyopaque, []const u8) anyerror!void;
        /// A connection's engine session state (session.sig): install it as
        /// `session_state` before every call, like `sequence_session`.
        pub const SessionState = Sess.State;
        /// A committed notification (takeNotification).
        pub const Notification = Sess.Note;
        pub const cursor_capacity = config.cursors;

        /// Text I/O, casts and JSONB/NUMERIC helpers for this configuration.
        pub const Io = value_module.Io(config);

        pub const Result = struct {
            /// Value I/O for codecs that only see the result type.
            pub const ValueIo = value_module.Io(config);

            column_count: usize = 0,
            row_count: usize = 0,
            affected_rows: usize = 0,
            command: CommandTag = .none,
            column_names: [config.columns]Name = @splat(.{}),
            column_types: [config.columns]DataType = @splat(.integer),
            /// PostgreSQL atttypmod of each column (-1 when none).
            column_typmods: [config.columns]i32 = @splat(-1),
            rows: if (config.external_results) []Row else [types.resultRows(config)]Row = if (config.external_results) &.{} else @splat(.{}),
            pub const default_row_capacity = types.resultRows(config);
            pub const external_rows = config.external_results;

            pub fn storageBytesFor(rows: usize) Error!usize {
                if (rows == 0 or rows > 0x7fffffff) return error.InvalidParameterValue;
                const amount = @mulWithOverflow(rows, @sizeOf(Row));
                const header = @sizeOf(Result) - (if (config.external_results) 0 else @sizeOf([types.resultRows(config)]Row));
                const total = @addWithOverflow(header, amount[0]);
                if (amount[1] != 0 or total[1] != 0) return error.InvalidParameterValue;
                return total[0];
            }

            pub fn rowBytes(rows: usize) Error!usize {
                _ = try storageBytesFor(rows);
                return rows * @sizeOf(Row);
            }

            pub fn bindMemory(self: *Result, bytes: []u8, rows: usize) Error!void {
                if (comptime !config.external_results) @compileError("result binding requires external_results");
                if (bytes.len < try rowBytes(rows)) return error.WorkspaceCapacity;
                const values = try storageView(Row, bytes, 0, rows);
                const start = @intFromPtr(values.ptr);
                const own = @intFromPtr(self);
                if (start < own + @sizeOf(Result) and own < start + rows * @sizeOf(Row)) return error.InvalidParameterValue;
                self.rows = values;
                self.clear(0);
            }

            pub const default_session: *const value_module.Session = &value_module.default_session;

            /// Renders every column that is not BIGINT/INTEGER/BOOLEAN/TEXT
            /// as TEXT (output function, `session` TimeZone), for codecs
            /// without native metadata for the other types (MySQL/TDS, flag
            /// F-M). A value longer than Config.text_bytes is TextCapacity.
            pub fn textify(self: *Result, session: *const value_module.Session) Error!void {
                for (0..self.column_count) |column| {
                    switch (self.column_types[column]) {
                        .integer, .integer32, .boolean, .text => continue,
                        .smallint, .oid => {
                            self.column_types[column] = .integer;
                            continue;
                        },
                        else => {},
                    }
                    for (self.rows[0..self.row_count]) |*row| {
                        row.cells[column] = try ValueIo.toText(&row.cells[column], false, session);
                    }
                    self.column_types[column] = .text;
                    self.column_typmods[column] = -1;
                }
            }

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
                if (comptime config.external_results) @compileError("use copyFromChecked for runtime-sized results");
                self.copyFromChecked(source) catch unreachable;
            }

            pub fn copyFromChecked(self: *Result, source: *const Result) Error!void {
                if (self == source) return;
                if (source.row_count > self.rows.len) return error.RowCapacity;
                self.column_count = source.column_count;
                self.row_count = source.row_count;
                self.affected_rows = source.affected_rows;
                self.command = source.command;
                @memcpy(self.column_names[0..source.column_count], source.column_names[0..source.column_count]);
                @memcpy(self.column_types[0..source.column_count], source.column_types[0..source.column_count]);
                @memcpy(self.column_typmods[0..source.column_count], source.column_typmods[0..source.column_count]);
                for (0..source.row_count) |row| {
                    @memcpy(self.rows[row].cells[0..source.column_count], source.rows[row].cells[0..source.column_count]);
                }
            }
        };

        /// RETURNING rows of a completed mutation, staged in the statement
        /// workspace (`rows` x `count` cells at `base`) until written.
        pub const Returned = struct {
            count: usize = 0,
            rows: usize = 0,
            base: usize = 0,
            names: [config.columns]Name = @splat(.{}),
            types: [config.columns]DataType = @splat(.integer),
            typmods: [config.columns]i32 = @splat(-1),
        };

        pub const Outcome = struct { affected: usize = 0, command: CommandTag = .none, returning: Returned = .{}, noop: bool = false };

        /// A user schema slot: like a sequence slot, `creator` owns a pending
        /// CREATE or DROP; `dead_csn` marks a committed DROP until reclaimed.
        pub const Schema = struct {
            live: bool = false,
            pending_create: bool = false,
            pending_drop: bool = false,
            creator: u16 = 0,
            dead_csn: u64 = 0,
            oid: u32 = 0,
            name: Name = .{},
        };

        pub const AlterRecord = struct {
            sources: [config.columns]u8 = @splat(0),
            fills: [config.columns]V.Cell = @splat(.null_value),
        };

        /// Statement-scoped scratch inside caller-owned database storage.
        pub const Workspace = struct {
            nodes: A.Pool = .{},
            plans: B.Plans = .{},
            query: X.Work = .{},
            /// Statement text followed by the view texts it expands.
            expansion: [config.expansion_bytes]u8 = undefined,
            /// OIDs of the views a statement expanded (CREATE VIEW records
            /// them as dependencies).
            expanded: [config.tables]u32 = undefined,
            expanded_count: usize = 0,
            /// Row-security WITH CHECK of the statement's INSERT / UPDATE
            /// target (B11 wave 3): bound over expansion[start..][0..len].
            security_check: u16 = ast.none,
            security_start: usize = 0,
            security_len: usize = 0,
            security_table: usize = 0,
        };

        /// A decoded identifier (quoted names keep case, others fold).
        fn identName(source: []const u8, ident: ast.Ident) Name {
            var out: Name = .{};
            var text: ControlText = .{};
            decodeIdent(source, ident, &text) catch return out;
            const length = @min(text.len, config.name_bytes);
            @memcpy(out.bytes[0..length], text.bytes[0..length]);
            out.len = length;
            return out;
        }

        /// The namespace OID of a schema name (public when null).
        fn namespaceFor(catalog: *const K, schema: ?[]const u8, snap: Snapshot) ?u32 {
            const wanted = schema orelse return catalog_module.public_namespace;
            for (catalog_module.namespaces) |known| if (types.same(known.name, wanted)) return known.oid;
            return if (catalog.findSchema(wanted, snap)) |found| found.oid else null;
        }

        /// Appends a stored query text to the workspace copy of the statement
        /// (copying the statement first) and parses it with absolute spans.
        fn appendQuery(workspace: *Workspace, length: *usize, source: []const u8, text: []const u8) Error!u16 {
            if (length.* == 0) {
                if (source.len > workspace.expansion.len) return error.TextCapacity;
                @memcpy(workspace.expansion[0..source.len], source);
                length.* = source.len;
            }
            if (text.len + 1 > workspace.expansion.len - length.*) return error.TextCapacity;
            workspace.expansion[length.*] = ' ';
            const start = length.* + 1;
            @memcpy(workspace.expansion[start..][0..text.len], text);
            length.* = start + text.len;
            return P.parseQueryAt(workspace.expansion[0..length.*], start, length.*, &workspace.nodes);
        }

        /// Views are stored definitions expanded at bind time: every FROM
        /// item naming a view (not a CTE or system view) becomes a derived
        /// table over the view's text, appended to the statement text in
        /// the workspace (Config.expansion_bytes, TextCapacity beyond) and
        /// parsed with absolute spans, recursively for views over views.
        /// Returns the source to bind and execute with.
        /// Inheritance parents and partitioned tables read as the UNION ALL
        /// of `ONLY` each member (the parent and every descendant; a
        /// partitioned table's leaf partitions), over the parent's columns.
        fn appendFamily(db: *const Self, workspace: *Workspace, length: *usize, source: []const u8, root: usize, snap: Snapshot) Error!u16 {
            if (length.* == 0) {
                if (source.len > workspace.expansion.len) return error.TextCapacity;
                @memcpy(workspace.expansion[0..source.len], source);
                length.* = source.len;
            }
            var members: [config.tables]usize = undefined;
            members[0] = root;
            var count: usize = 1;
            var relations: [K.relation_rows]K.Found = undefined;
            const relation_count = db.catalog.visibleRelations(snap, &relations);
            var next: usize = 0;
            while (next < count) : (next += 1) {
                const oid = db.tables[members[next]].oid;
                for (relations[0..relation_count]) |found| {
                    if (found.kind == 'S' or db.tables[found.slot].parent != oid or count == members.len) continue;
                    members[count] = found.slot;
                    count += 1;
                }
            }
            var text: Expansion = .{ .buffer = &workspace.expansion, .len = length.* };
            try text.add(" ");
            const start = text.len;
            const parent = &db.tables[root];
            var first = true;
            for (members[0..count]) |slot| {
                const member = &db.tables[slot];
                if (member.relkind == 'p' and count > 1) continue;
                if (!first) try text.add(" UNION ALL ");
                first = false;
                try text.add("SELECT ");
                for (parent.columns[0..parent.column_count], 0..) |*column, position| {
                    if (position != 0) try text.add(", ");
                    try text.quoted(column.name.slice());
                }
                try text.add(" FROM ONLY ");
                try text.quoted(db.namespaceName(member.namespace));
                try text.add(".");
                try text.quoted(member.name.slice());
            }
            length.* = text.len;
            return P.parseQueryAt(workspace.expansion[0..length.*], start, length.*, &workspace.nodes);
        }

        /// Bounded writer into the workspace expansion buffer (TextCapacity).
        const Expansion = struct {
            buffer: *[config.expansion_bytes]u8,
            len: usize,
            fn add(self: *Expansion, bytes: []const u8) Error!void {
                if (bytes.len > self.buffer.len - self.len) return error.TextCapacity;
                @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
                self.len += bytes.len;
            }
            fn quoted(self: *Expansion, name: []const u8) Error!void {
                try self.add("\"");
                for (name) |byte| {
                    try self.add(&[1]u8{byte});
                    if (byte == '"') try self.add("\"");
                }
                try self.add("\"");
            }
        };

        /// A visible table inheriting from (or partitioning) `oid`.
        fn hasChildren(self: *const Self, oid: u32, snap: Snapshot) bool {
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind != 'S' and self.tables[found.slot].parent == oid) return true;
            }
            return false;
        }

        fn expandRelations(db: *const Self, workspace: *Workspace, source: []const u8, snap: Snapshot, bound_statement: *A.Statement, role: u32) Error![]const u8 {
            // Privileges and row security apply to roles other than superusers (B11 wave 3).
            const privileged = role == CO.bootstrap_role or db.catalog_objects.superuser(role, snap);
            const tables = &db.tables;
            const catalog = &db.catalog;
            workspace.expanded_count = 0;
            const pool = &workspace.nodes;
            var length: usize = 0;
            // REFRESH MATERIALIZED VIEW reads the stored query the same way.
            if (bound_statement.* == .refresh_view) {
                const refresh = &bound_statement.refresh_view;
                const schema_name = if (refresh.name.schema) |qualifier| identName(source, qualifier) else Name{};
                if (namespaceFor(catalog, if (refresh.name.schema != null) schema_name.slice() else null, snap)) |namespace| {
                    if (catalog.findIn(namespace, identName(source, refresh.name.name).slice(), snap)) |found| {
                        if (found.kind == 'm') refresh.query = try appendQuery(workspace, &length, source, tables[found.slot].query.slice());
                    }
                }
            }
            var block: usize = 0;
            while (block < pool.query_len) : (block += 1) {
                const q = &pool.queries[block];
                for (q.items[0..q.item_count]) |*item| {
                    if (item.query != ast.none) continue;
                    const text = if (length == 0) source else workspace.expansion[0..length];
                    const name = identName(text, item.name);
                    if (item.schema == null) {
                        var cte = false;
                        for (pool.queries[0..pool.query_len]) |*other| for (other.ctes[0..other.cte_count]) |*definition| {
                            if (types.same(identName(text, definition.name).slice(), name.slice())) cte = true;
                        };
                        if (cte) continue;
                    }
                    const schema_name = if (item.schema) |qualifier| identName(text, qualifier) else Name{};
                    if (catalog_module.findView(if (item.schema != null) schema_name.slice() else null, name.slice())) |view| {
                        if (view == .pg_authid and !privileged) return error.InsufficientPrivilege;
                        continue;
                    }
                    const namespace = namespaceFor(catalog, if (item.schema != null) schema_name.slice() else null, snap) orelse continue;
                    const found = catalog.findIn(namespace, name.slice(), snap) orelse continue;
                    // Items the statement names (not view or expansion texts).
                    if (!privileged and item.name.span.start < source.len) {
                        const secured = try secureItem(db, workspace, &length, source, role, found, snap);
                        if (secured != ast.none) {
                            item.query = secured;
                            item.view = true;
                            if (item.alias == null) item.alias = item.name;
                            q.from = null;
                            pool.complex = true;
                            continue;
                        }
                    }
                    if (found.kind != 'v') {
                        if (item.only or found.kind == 'S') continue;
                        const table = &tables[found.slot];
                        if (table.relkind != 'p' and !db.hasChildren(table.oid, snap)) continue;
                        item.query = try appendFamily(db, workspace, &length, source, found.slot, snap);
                        item.view = true;
                        if (item.alias == null) item.alias = item.name;
                        q.from = null;
                        pool.complex = true;
                        continue;
                    }
                    const view = &tables[found.slot];
                    const parsed = try appendQuery(workspace, &length, source, view.query.slice());
                    // View columns keep the names CREATE VIEW gave them.
                    const top = &pool.queries[parsed];
                    if (top.set_op == .none) {
                        var star = false;
                        for (top.targets[0..top.count]) |*output| star = star or output.star;
                        if (!star and top.count == view.column_count) {
                            for (top.targets[0..top.count], view.columns[0..top.count]) |*output, *column| {
                                const label = column.name.slice();
                                if (label.len + 3 > workspace.expansion.len - length) return error.TextCapacity;
                                workspace.expansion[length] = ' ';
                                workspace.expansion[length + 1] = '"';
                                @memcpy(workspace.expansion[length + 2 ..][0..label.len], label);
                                workspace.expansion[length + 2 + label.len] = '"';
                                output.alias = .{ .span = .{ .start = length + 2, .len = label.len }, .quoted = true, .len = label.len };
                                length += label.len + 3;
                            }
                        }
                    }
                    item.query = parsed;
                    item.view = true;
                    if (item.alias == null) item.alias = item.name;
                    q.from = null;
                    pool.complex = true;
                    if (workspace.expanded_count < workspace.expanded.len) {
                        workspace.expanded[workspace.expanded_count] = view.oid;
                        workspace.expanded_count += 1;
                    }
                }
            }
            if (length == 0) return source;
            if (bound_statement.* == .select) {
                const top = bound_statement.select;
                bound_statement.* = .{ .query = top };
            }
            return workspace.expansion[0..length];
        }
        /// Independent parser/binder/executor state over shared immutable table
        /// storage. The caller excludes ALL database/schema mutations until the
        /// call returns (or between prepare/run), and owns every scratch/result
        /// buffer. No row/database snapshots are copied into this context.
        pub const ReadContext = struct {
            const Context=@This();
            const Plan=union(enum){simple:B.Select,general:u16};
            workspace:Workspace=.{},
            session:value_module.Session=.{},
            dialect:Dialect=.postgres,
            prepared:?Plan=null,
            preparation_error:?Error=null,
            database:?*const Self=null,
            source:[]const u8=&.{},
            /// `source` plus expanded view texts (inside the workspace).
            effective:[]const u8=&.{},
            snapshot:Snapshot=.{.csn=0},

            pub fn backingBytes(rows:usize) Error!usize {
                return Context.backingBytesFor(rows,try Self.queryReferenceCount(rows));
            }
            pub fn backingBytesFor(rows:usize,refs:usize) Error!usize {
                const cells=try Self.queryWorkspaceBytes(rows);
                if(refs==0 or refs>0x7fffffff) return error.InvalidParameterValue;
                const reference_bytes=@mulWithOverflow(refs,@sizeOf(u32));
                const total=@addWithOverflow(cells,reference_bytes[0]);
                if(reference_bytes[1]!=0 or total[1]!=0) return error.InvalidParameterValue;
                return total[0];
            }
            pub fn bindMemory(self:*Context,bytes:[]u8,rows:usize) Error!void {
                return self.bindMemoryFor(bytes,rows,try Self.queryReferenceCount(rows));
            }
            pub fn bindMemoryFor(self:*Context,bytes:[]u8,rows:usize,reference_count:usize) Error!void {
                if(comptime !config.external_workspace or !config.external_storage) @compileError("ReadContext.bindMemory requires external workspace/storage");
                const required=try Context.backingBytesFor(rows,reference_count);
                if(bytes.len<required) return error.WorkspaceCapacity;
                const own=try objectSpan(self);
                if(overlaps(own,try span(bytes))) return error.InvalidParameterValue;
                const cells=try Self.storageView(Cell,bytes,0,rows*2*config.columns);
                const refs=try Self.storageView(u32,bytes,try Self.queryWorkspaceBytes(rows),reference_count);
                self.workspace.query.cells=cells;self.workspace.query.refs=refs;
                self.workspace.query.cell_high=cells.len;self.workspace.query.ref_high=refs.len;
                self.prepared=null;
            }
            fn objectSpan(pointer:anytype) Error!StorageSpan {
                const first=@intFromPtr(pointer);const last=@addWithOverflow(first,@sizeOf(@TypeOf(pointer.*)));
                if(last[1]!=0) return error.InvalidParameterValue;
                return .{.start=first,.end=last[0]};
            }
            fn span(values:anytype) Error!StorageSpan {
                const bytes=@mulWithOverflow(values.len,@sizeOf(@TypeOf(values[0])));
                const last=@addWithOverflow(@intFromPtr(values.ptr),bytes[0]);
                if(bytes[1]!=0 or last[1]!=0) return error.InvalidParameterValue;
                return .{.start=@intFromPtr(values.ptr),.end=last[0]};
            }
            fn overlaps(a:StorageSpan,b:StorageSpan) bool {
                return a.start<a.end and b.start<b.end and a.start<b.end and b.start<a.end;
            }
            fn validate(self:*Context,db:*const Self,source:[]const u8,result:?*Result) Error!void {
                const cells=self.workspace.query.cells[0..];const refs=self.workspace.query.refs[0..];
                if(cells.len<2*config.columns or refs.len==0) return error.WorkspaceCapacity;
                const empty:StorageSpan=.{.start=0,.end=0};
                const mutable=[_]StorageSpan{try objectSpan(self),
                    if(config.external_workspace) try span(cells) else empty,
                    if(config.external_storage) try span(refs) else empty,
                    if(result) |out| try objectSpan(out) else empty,
                    if(config.external_results and result!=null) try span(result.?.rows) else empty};
                const db_span=try objectSpan(db);const source_span=try span(source);
                for(mutable,0..) |part,index| {
                    if(overlaps(part,db_span) or overlaps(part,source_span)) return error.InvalidParameterValue;
                    for(mutable[0..index]) |earlier| if(overlaps(part,earlier)) return error.InvalidParameterValue;
                    for(&db.tables) |*table| inline for(.{"rows","versions","row_index","key_index","scan_values","scan_nonnull","scan_live","scan_presence","index_slots"}) |name| {
                        if(overlaps(part,try span(@field(table,name)[0..]))) return error.InvalidParameterValue;
                    };
                }
            }
            /// Callbacks in session (clock/zone resolver/control) must themselves
            /// be safe for concurrent reads. Sequence hooks are always disabled.
            pub fn prepare(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot) Error!void {
                return self.prepareMode(db,source,snapshot,false);
            }
            /// Metadata binding is separate from executable preparation. It
            /// never leaves a metadata-only plan available to run().
            pub fn describe(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot,result:*Result) Error!void {
                defer self.prepared=null;
                try self.prepareMode(db,source,snapshot,true);
                try self.describeResult(result);
            }
            fn prepareMode(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot,describe_only:bool) Error!void {
                try self.validate(db,source,null);
                self.prepared=null;
                self.preparation_error=null;self.database=db;self.source=source;self.snapshot=snapshot;
                self.prepareBody(db,source,snapshot,describe_only) catch |err| {self.preparation_error=err;return err;};
            }
            fn prepareBody(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot,describe_only:bool) Error!void {
                self.session.sequences=null;
                var parsed=try P.parse(source,&self.workspace.nodes,.standard);
                switch(parsed){.select,.query=>{},else=>return error.UnsupportedStatement}
                const expanded=try Self.expandRelations(db,&self.workspace,source,snapshot,&parsed,self.session.role);
                try self.session.checkpoint();
                for(self.workspace.nodes.queries[0..self.workspace.nodes.query_len]) |query| {
                    if(query.lock.strength!=.none) return error.UnsupportedStatement;
                }
                const context:B.Context=.{.source=expanded,.tables=&db.tables,.catalog=&db.catalog,.snapshot=snapshot,
                    .pool=&self.workspace.nodes,.legacy=false,.dialect=self.dialect,.session=&self.session,.plans=&self.workspace.plans,.describe_only=describe_only,.routines=&db.objects};
                const bound=try B.bind(&context,&parsed);
                // Detached reads never mutate: no data-modifying WITH (B11).
                if(self.workspace.plans.dml_len!=0) return error.UnsupportedStatement;
                for(self.workspace.nodes.nodes[0..self.workspace.nodes.len]) |node| switch(node.func) {
                    .nextval,.currval,.setval,.lastval,.identity_next=>return error.UnsupportedStatement,
                    // Catalog-object text needs the serialized database hook.
                    .obj_description,.col_description,.shobj_description,.current_user,.session_user=>return error.UnsupportedStatement,
                    else=>{},
                };
                self.prepared=switch(bound){.select=>|select| .{.simple=select},.query=>|root| .{.general=root},else=>return error.UnsupportedStatement};
                self.database=db;self.source=source;self.effective=expanded;self.snapshot=snapshot;
            }
            pub fn run(self:*Context,result:*Result) Error!void {
                const db=self.database orelse return error.InvalidParameterValue;
                try self.validate(db,self.source,result);
                if(self.preparation_error) |err| return err;
                const plan=self.prepared orelse return error.InvalidParameterValue;
                if(config.external_results and result.rows.len==0) return error.InvalidParameterValue;
                self.workspace.query.views=.{.ptr=self,.rows=readViewRows};
                self.workspace.query.read_stats=.{};
                switch(plan) {
                    .simple=>|*select| try X.select(&db.tables,self.effective,&self.workspace.nodes,select,self.snapshot,result,X.NoLock{},
                        &self.session,self.snapshot.epoch==0,&self.workspace.query.read_stats,&self.workspace.query),
                    .general=>|root| try X.runQuery(&db.tables,self.effective,&self.workspace.nodes,&self.workspace.plans,root,self.snapshot,result,
                        &self.session,&self.workspace.query,self.snapshot.epoch==0),
                }
            }
            /// Describe an already bound read without running expressions,
            /// acquiring row locks or touching the database's shared workspace.
            pub fn describeResult(self:*Context,result:*Result) Error!void {
                const db=self.database orelse return error.InvalidParameterValue;
                try self.validate(db,self.source,result);
                if(self.preparation_error) |err| return err;
                const plan=self.prepared orelse return error.InvalidParameterValue;
                result.clear(0);result.command=.select;
                switch(plan) {
                    .simple=>|select| {
                        result.column_count=select.count;
                        @memcpy(result.column_names[0..select.count],select.names[0..select.count]);
                        @memcpy(result.column_types[0..select.count],select.types[0..select.count]);
                        @memcpy(result.column_typmods[0..select.count],select.typmods[0..select.count]);
                    },
                    .general=>|root| {
                        const query=&self.workspace.plans.items[root];
                        result.column_count=query.count;
                        for(0..query.count) |i| {
                            result.column_names[i]=query.names[i];result.column_types[i]=types.dataTypeOf(query.tys[i]);
                            result.column_typmods[i]=query.typmods[i];
                        }
                    },
                }
            }
            fn readViewRows(pointer:*anyopaque,view:catalog_module.View,sink:*X.RowSink) Error!void {
                const context:*Context=@ptrCast(@alignCast(pointer));
                const db=context.database orelse return error.InvalidParameterValue;
                return db.fillViewRows(&context.session,context.snapshot,&context.workspace.nodes,view,sink);
            }
            /// Conservative routing hint for callers with a mutable named-zone
            /// cache. Typed temporal values use the immutable session zone;
            /// dynamic zone names/text timestamp input may require a resolver.
            pub fn needsZoneResolver(self:*const Context) bool {
                for(self.workspace.nodes.nodes[0..self.workspace.nodes.len]) |node| {
                    if(node.kind==.at_zone) return true;
                    if(node.kind==.cast and (node.ty==.timestamp or node.ty==.timestamptz)) {
                        if(node.a==ast.none) return true;
                        switch(self.workspace.nodes.nodes[node.a].ty){.unknown,.text,.name=>return true,else=>{}}
                    }
                }
                return false;
            }
            pub fn execute(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot,result:*Result) Error!void {
                try self.validate(db,source,result);
                try self.prepare(db,source,snapshot);try self.run(result);
            }
        };
        /// Query workspace capacity: rows (each up to 2 x columns cells).
        pub const work_rows = X.work_rows;

        tables: [config.tables]S.Table = @splat(.{}),
        /// ALTER TABLE column mapping of the table slot it filled (indexed by
        /// that slot), read when the transaction encodes its record.
        alters: [config.tables]AlterRecord = @splat(.{}),
        /// User schemas (Config.schemas); visibility is the catalog's.
        schemas: [config.schemas]Schema = @splat(.{}),
        catalog: K = .{},
        /// Roles, grants, policies, comments, wrappers, servers and
        /// publications (catalog_objects.sig, B11 wave 3).
        catalog_objects: O = .{},
        /// Sequence slots (Config.sequences); values are non-transactional.
        seqs: [config.sequences]Q.Seq = @splat(.{}),
        /// Globally pending log-ahead values, including live owners. Any
        /// acknowledged consumer must persist them before publication; later
        /// cache hits need no record once that watermark has been published.
        seq_carried: Q.Set = .{},
        /// currval/lastval of callers without their own session state.
        default_sequences: Q.Session = .{},
        sequence_session: ?*Q.Session = null,
        seq_hook: value_module.SequenceHook = undefined,
        seq_slot: u16 = 0,
        seq_snap: Snapshot = .{ .csn = 0 },
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
        /// Per transaction: the running statement's data-modifying WITH
        /// entries (B11), kept across a park so a resume continues them.
        modifying: [config.transactions]Modifying = @splat(.{}),
        /// Session values of the next statement (TimeZone, clocks); set per
        /// call like `dialect`. Not database state.
        session: value_module.Session = .{},
        workspace: Workspace = .{},
        /// Tx-session lane: the caller's session state for the next call
        /// (null: default_session_state), cursors and notifications of every
        /// session, SERIALIZABLE records and EXECUTE parameter values.
        session_state: ?*Sess.State = null,
        default_session_state: Sess.State = .{},
        session_counter: u64 = 0,
        cursors: Sess.Cursors = .{},
        notify: Sess.Notify = .{},
        ssi: SSI = .{},
        session_hook: value_module.SessionHook = undefined,
        param_values: [config.statement_parameters]Cell = undefined,
        active_params: ?*const B.Parameters = null,
        statement_implicit: bool = false,
        /// Settings before the running statement's first set_config (a
        /// failed statement restores them).
        statement_settings: Sess.Values = .{},
        statement_base: Sess.Values = .{},
        statement_settings_cid: ?u32 = null,
        /// Settings provider for parameters the caller implements (the
        /// store's TimeZone, timeouts ...): current_setting / set_config.
        settings_provider: ?SettingsProvider = null,
        // Routines, triggers and rules (B11 wave 3, routine_catalog.sig).
        /// Function / procedure, trigger and rule versions.
        objects: RC.Set = .{},
        /// The running statement's routine context: its transaction slot,
        /// snapshot and result, the frame its statements' variables read,
        /// routine nesting depth (54001 beyond Config.routine_depth) and
        /// expression / trigger nesting (no statement may run inside one).
        routine_hook: value_module.RoutineHook = undefined,
        routine_slot: u16 = 0,
        routine_snap: Snapshot = .{ .csn = 0 },
        routine_result: ?*Result = null,
        routine_frame: ?*R.Frame = null,
        routine_depth: usize = 0,
        routine_nested: usize = 0,
        /// Write-set index where the running statement's writes begin (its
        /// AFTER ROW triggers read them); kept across a park.
        statement_start: usize = 0,

        /// current_setting / set_config of caller-owned parameters: `show`
        /// writes the value (null: unknown name); `set` applies it (false:
        /// unknown name).
        pub const SettingsProvider = struct {
            context: ?*anyopaque = null,
            show: *const fn (?*anyopaque, []const u8, []u8) ?usize,
            set: *const fn (?*anyopaque, []const u8, []const u8, bool, bool) Error!bool,
        };

        const BackingLayout = struct {
            offsets: [config.tables][9]usize,
            refs: usize,
            bytes: usize,
            row_index: [config.tables]usize,
            key_index: [config.tables]usize,
        };

        pub const TableBudget = struct { rows: usize, versions: usize };

        fn appendLayout(cursor: *usize, comptime T: type, count: usize) Error!usize {
            const aligned = @addWithOverflow(cursor.*, @alignOf(T) - 1);
            if (aligned[1] != 0) return error.InvalidParameterValue;
            const offset = aligned[0] & ~(@as(usize, @alignOf(T)) - 1);
            const size = @mulWithOverflow(count, @sizeOf(T));
            const end = @addWithOverflow(offset, size[0]);
            if (size[1] != 0 or end[1] != 0) return error.InvalidParameterValue;
            cursor.* = end[0];
            return offset;
        }

        fn backingLayout(rows: usize, versions: usize, refs: usize) Error!BackingLayout {
            return backingLayoutFor(@splat(.{ .rows=rows, .versions=versions }),refs);
        }

        fn backingLayoutFor(budgets: [config.tables]TableBudget, refs: usize) Error!BackingLayout {
            if (refs == 0 or refs > 0x7fffffff) return error.InvalidParameterValue;
            var layout: BackingLayout = undefined;
            var cursor: usize = 0;
            for (&layout.offsets, &layout.row_index, &layout.key_index, budgets) |*offsets,*row_index,*key_index,budget| {
                const rows=budget.rows; const versions=budget.versions;
                if (rows == 0 or rows > 0x7fffffff or versions <= rows or versions > 0x7fffffff or versions > ~@as(usize,0)/4) return error.InvalidParameterValue;
                var ri:usize=2; while(ri<rows*2) ri*=2;
                var ki:usize=2; while(ki<versions*2) ki*=2;
                row_index.*=ri; key_index.*=ki;
                offsets[0] = try appendLayout(&cursor, S.RowSlot, rows);
                offsets[1] = try appendLayout(&cursor, S.Version, versions);
                offsets[2] = try appendLayout(&cursor, u32, ri);
                offsets[3] = try appendLayout(&cursor, u32, ki);
                const scan_rows = if (S.compact_enabled) rows else 0;
                const scan_cells = @mulWithOverflow(scan_rows, config.columns);
                if (scan_cells[1] != 0) return error.InvalidParameterValue;
                offsets[4] = try appendLayout(&cursor, i64, scan_cells[0]);
                offsets[5] = try appendLayout(&cursor, u64, scan_rows);
                offsets[6] = try appendLayout(&cursor, u8, scan_rows);
                offsets[7] = if(S.presence_enabled) try appendLayout(&cursor,u64,try S.presenceWords(rows)) else cursor;
                const index_slots = @mulWithOverflow(ki, S.bound_indexes);
                if (index_slots[1] != 0) return error.InvalidParameterValue;
                offsets[8] = if (S.bound_indexes != 0) try appendLayout(&cursor, u32, index_slots[0]) else cursor;
            }
            layout.refs = try appendLayout(&cursor, u32, refs);
            layout.bytes = cursor;
            return layout;
        }

        /// Exact byte budget for runtime-sized external row/version/index buffers.
        pub fn backingBytes(rows: usize, versions: usize, refs: usize) Error!usize {
            return (try backingLayout(rows, versions, refs)).bytes;
        }

        pub fn backingBytesFor(budgets: [config.tables]TableBudget, refs: usize) Error!usize {
            return (try backingLayoutFor(budgets,refs)).bytes;
        }

        pub fn queryWorkspaceBytes(rows: usize) Error!usize {
            if (rows == 0 or rows > 0xffffffff / (2 * config.columns)) return error.InvalidParameterValue;
            var cursor: usize = 0;
            _ = try appendLayout(&cursor, Cell, rows * 2 * config.columns);
            return cursor;
        }

        pub fn queryReferenceCount(rows: usize) Error!usize {
            const factor = 4 * (config.relations + 4);
            if (rows == 0 or rows > 0x7fffffff / factor) return error.InvalidParameterValue;
            return rows * factor;
        }

        /// Bind scratch only to fresh state; validate ownership before mutation.
        /// This region never becomes part of the database's inline object/image.
        pub fn bindWorkspace(self: *Self, cells: []Cell) Error!void {
            if (comptime !config.external_workspace) @compileError("bindWorkspace requires external_workspace");
            if (self.csn != 0 or cells.len < 2 * config.columns or cells.len > 0xffffffff) return error.InvalidParameterValue;
            for (&self.txs) |*tx| if (tx.active) return error.InvalidParameterValue;
            const region = StorageSpan.of(cells);
            const own: StorageSpan = .{ .start = @intFromPtr(self), .end = @intFromPtr(self) + @sizeOf(Self) };
            if (region.start < own.end and own.start < region.end) return error.InvalidParameterValue;
            if (comptime config.external_storage) {
                const refs = StorageSpan.of(self.workspace.query.refs);
                if (refs.start < refs.end and region.start < refs.end and refs.start < region.end) return error.InvalidParameterValue;
                for (&self.tables) |*table| inline for (.{ "rows", "versions", "row_index", "key_index", "scan_values", "scan_nonnull", "scan_live", "scan_presence", "index_slots" }) |field| {
                    const part = StorageSpan.of(@field(table, field));
                    if (part.start < part.end and region.start < part.end and part.start < region.end) return error.InvalidParameterValue;
                };
            }
            self.workspace.query.cells = cells;
            self.workspace.query.cell_high = cells.len;
        }

        pub fn bindWorkspaceMemory(self: *Self, bytes: []u8, rows: usize) Error!void {
            const required = try queryWorkspaceBytes(rows);
            if (bytes.len < required) return error.WorkspaceCapacity;
            try self.bindWorkspace(try storageView(Cell, bytes, 0, rows * 2 * config.columns));
        }

        fn storageView(comptime T: type, bytes: []u8, offset: usize, count: usize) Error![]T {
            const ptr = bytes.ptr + offset;
            if (@intFromPtr(ptr) % @alignOf(T) != 0) return error.InvalidParameterValue;
            return @as([*]T, @ptrCast(@alignCast(ptr)))[0..count];
        }

        /// Carve only the declared typed buffers from one caller-owned region.
        /// No allocator interface, hidden growth, or platform imports.
        pub fn bindMemory(self: *Self, bytes: []u8, rows: usize, versions: usize, refs: usize) Error!void {
            return self.bindMemoryFor(bytes,@splat(.{.rows=rows,.versions=versions}),refs);
        }

        pub fn bindMemoryFor(self: *Self, bytes: []u8, budgets: [config.tables]TableBudget, refs: usize) Error!void {
            if (comptime !config.external_storage) @compileError("bindMemory requires external_storage");
            const layout = try backingLayoutFor(budgets, refs);
            if (bytes.len < layout.bytes) return error.WorkspaceCapacity;
            var backings: [config.tables]StorageBacking = undefined;
            for (&backings, layout.offsets, layout.row_index, layout.key_index, budgets) |*backing, offsets, ri, ki, budget| backing.* = .{
                .rows = try storageView(S.RowSlot, bytes, offsets[0], budget.rows),
                .versions = try storageView(S.Version, bytes, offsets[1], budget.versions),
                .row_index = try storageView(u32, bytes, offsets[2], ri),
                .key_index = try storageView(u32, bytes, offsets[3], ki),
                .scan_values = try storageView(i64, bytes, offsets[4], if (S.compact_enabled) budget.rows * config.columns else 0),
                .scan_nonnull = try storageView(u64, bytes, offsets[5], if (S.compact_enabled) budget.rows else 0),
                .scan_live = try storageView(u8, bytes, offsets[6], if (S.compact_enabled) budget.rows else 0),
                .scan_presence = if(S.presence_enabled) try storageView(u64,bytes,offsets[7],try S.presenceWords(budget.rows)) else &.{},
                .index_slots = if (S.bound_indexes != 0) try storageView(u32, bytes, offsets[8], ki * S.bound_indexes) else &.{},
            };
            try self.bindStorage(backings, try storageView(u32, bytes, layout.refs, refs));
        }

        const StorageSpan = struct {
            start: usize,
            end: usize,

            fn of(values: anytype) StorageSpan {
                const start = @intFromPtr(values.ptr);
                return .{ .start = start, .end = start + values.len * @sizeOf(@TypeOf(values[0])) };
            }
        };

        /// Bind distinct caller-owned storage to a fresh external-storage DB.
        /// Buffers must outlive the DB and must not be moved during a statement
        /// or transaction. No initialization reads unused row/version storage.
        /// Validation completes before any binding is changed.
        pub fn bindStorage(self: *Self, backings: [config.tables]StorageBacking, refs: []u32) Error!void {
            if (comptime !config.external_storage) @compileError("bindStorage requires external_storage");
            if (self.csn != 0 or refs.len == 0 or refs.len > 0x7fffffff) return error.InvalidParameterValue;
            for (&self.tables) |*table| if (table.live) return error.InvalidParameterValue;
            for (&self.txs) |*tx| if (tx.active) return error.InvalidParameterValue;
            var spans: [config.tables * 9 + 3]StorageSpan = undefined;
            spans[0] = .{ .start = @intFromPtr(self), .end = @intFromPtr(self) + @sizeOf(Self) };
            spans[1] = StorageSpan.of(refs);
            spans[spans.len - 1] = if (comptime config.external_workspace) StorageSpan.of(self.workspace.query.cells) else .{ .start = 0, .end = 0 };
            for (backings, 0..) |backing, i| {
                if (!backing.valid()) return error.InvalidParameterValue;
                spans[2 + i * 9] = StorageSpan.of(backing.rows);
                spans[3 + i * 9] = StorageSpan.of(backing.versions);
                spans[4 + i * 9] = StorageSpan.of(backing.row_index);
                spans[5 + i * 9] = StorageSpan.of(backing.key_index);
                spans[6 + i * 9] = StorageSpan.of(backing.scan_values);
                spans[7 + i * 9] = StorageSpan.of(backing.scan_nonnull);
                spans[8 + i * 9] = StorageSpan.of(backing.scan_live);
                spans[9 + i * 9] = StorageSpan.of(backing.scan_presence);
                spans[10 + i * 9] = StorageSpan.of(backing.index_slots);
            }
            for (spans, 0..) |a, i| for (spans[i + 1 ..]) |b| {
                if (a.start == a.end or b.start == b.end) continue;
                if (a.start < b.end and b.start < a.end) return error.InvalidParameterValue;
            };
            for (&self.tables, backings) |*table, backing| {
                table.rows = backing.rows;
                table.versions = backing.versions;
                table.row_index = backing.row_index;
                table.key_index = backing.key_index;
                table.scan_values = backing.scan_values;
                table.scan_nonnull = backing.scan_nonnull;
                table.scan_live = backing.scan_live;
                table.scan_presence = backing.scan_presence;
                table.index_slots = backing.index_slots;
            }
            self.workspace.query.refs = refs;
            self.workspace.query.ref_high = refs.len;
        }

        /// Inline object bytes. With external_storage this excludes the bound
        /// row/version/index/reference buffers; backingBytes reports their
        /// separate capacity budget. It is not total resident memory.
        pub fn storageBytes() usize {
            return @sizeOf(Self);
        }

        /// Copy a complete committed logical state into distinct storage. The
        /// source must have no active transaction; the copy has none.
        pub fn copyFrom(self: *Self, source: *const Self) void {
            if (comptime config.external_storage) @compileError("use checked copyFromInto with external storage");
            self.copyState(source);
        }

        /// Copies into independently bound external buffers, rejecting a small
        /// destination before modifying it. Indices are rebuilt for its masks.
        pub fn copyFromInto(self: *Self, source: *const Self) Error!void {
            if (self == source) return;
            for (&self.txs) |*tx| if (tx.active) return error.InvalidParameterValue;
            for (&source.txs) |*tx| if (tx.active) return error.InvalidParameterValue;
            for (&self.tables, &source.tables) |*dst, *src| if (src.live) {
                if (dst.rows.len < src.row_high or dst.versions.len < src.version_high or dst.row_index.len == 0 or dst.key_index.len == 0) return error.WorkspaceCapacity;
                if (!S.indexFits(dst, src.index_count, src.version_used)) return error.WorkspaceCapacity;
            };
            self.copyState(source);
        }

        fn copyState(self: *Self, source: *const Self) void {
            if (self == source) return;
            self.oid_counter = source.oid_counter;
            self.csn = source.csn;
            self.cid = source.cid;
            self.epoch = source.epoch;
            self.catalog = source.catalog;
            self.catalog_objects = source.catalog_objects;
            self.seqs = source.seqs;
            self.schemas = source.schemas;
            for (&self.schemas) |*schema| {
                schema.pending_create = false;
                schema.pending_drop = false;
            }
            self.seq_carried = source.seq_carried;
            self.objects = source.objects;
            self.routine_slot = 0;
            self.routine_snap = .{ .csn = 0 };
            self.routine_result = null;
            self.routine_frame = null;
            self.routine_depth = 0;
            self.routine_nested = 0;
            // A logical copy has fresh session/execution state. In particular,
            // never copy caller-owned interrupt or sequence-hook pointers.
            self.sequence_session = null;
            self.default_sequences = .{};
            self.seq_hook = undefined; // installed before a sequence expression
            self.seq_slot = 0;
            self.seq_snap = .{ .csn = 0 };
            self.wake_epoch = 0;
            self.wait_counter = 0;
            self.outcome = .{};
            self.dialect = .postgres;
            self.session = .{};
            self.session_state = null;
            self.default_session_state = .{};
            self.session_counter = 0;
            self.cursors.slots = @splat(.{});
            self.cursors.used_rows = 0;
            self.notify = .{};
            self.ssi = .{};
            self.active_params = null;
            self.settings_provider = null;
            if (comptime config.external_storage) {
                const refs = self.workspace.query.refs;
                const cells = if (comptime config.external_workspace) self.workspace.query.cells else {};
                self.workspace = .{};
                self.workspace.query.refs = refs;
                self.workspace.query.ref_high = refs.len;
                if (comptime config.external_workspace) {
                    self.workspace.query.cells = cells;
                    self.workspace.query.cell_high = cells.len;
                }
            } else self.workspace = .{};
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
            self.statement(slot, source, result, .{ .mode = mode, .hold_result = true, .implicit = true }) catch |err| {
                self.abort(slot);
                return err;
            };
            // Deferred constraints are checked as the transaction commits.
            self.deferredViolation(slot) catch |err| {
                self.abort(slot);
                return err;
            };
            // The hook may observe the database (read-only), which reuses
            // `outcome`; keep this statement's own.
            const outcome = self.outcome;

            sink.before(self, slot, (outcome.command == .select or outcome.noop) and self.readOnly(slot)) catch |err| {
                self.abort(slot);
                return err;
            };
            self.publishCommit(slot);
            self.outcome = outcome;
            self.writeOutcome(result);
        }

        fn writeOutcome(self: *const Self, result: *Result) void {
            if (self.outcome.command == .select or self.outcome.command == .fetch or self.outcome.command == .show) return;
            result.clear(self.outcome.affected);
            result.command = self.outcome.command;
            const returned = &self.outcome.returning;
            if (returned.count == 0) return;
            result.column_count = returned.count;
            @memcpy(result.column_names[0..returned.count], returned.names[0..returned.count]);
            @memcpy(result.column_types[0..returned.count], returned.types[0..returned.count]);
            @memcpy(result.column_typmods[0..returned.count], returned.typmods[0..returned.count]);
            result.row_count = returned.rows;
            for (0..returned.rows) |row| {
                @memcpy(result.rows[row].cells[0..returned.count], self.workspace.query.cells[returned.base + row * returned.count ..][0..returned.count]);
            }
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
                tx.running_snap = null;
                tx.fresh = false;
                tx.waiting_for = .{};
                tx.table_wait = null;
                tx.seq_dirty = .{};
                tx.copy_table = null;
                tx.copy_rows = 0;
                tx.deferred_checks = false;
                tx.constraints_all = null;
                tx.constraint_mode_count = 0;
                const state = self.sessionState();
                tx.isolation = state.values.isolation;
                tx.read_only = state.values.read_only;
                tx.deferrable = state.values.deferrable;
                tx.snapshot_csn = null;
                tx.snapshot_cid = 0;
                tx.session = state.id;
                tx.ssi = null;
                state.beginTransaction(tx.epoch);
                return @intCast(slot);
            };
            return error.TransactionCapacity;
        }

        pub fn active(self: *const Self, slot: u16) bool {
            return slot < config.transactions and self.txs[slot].active;
        }

        /// Read-only (commit needs no record): no write, no sequence
        /// log-ahead value of its own and none carried (design §4.6).
        pub fn readOnly(self: *const Self, slot: u16) bool {
            const tx = &self.txs[slot];
            return tx.write_len == 0 and !tx.seq_dirty.any() and !self.seq_carried.any();
        }

        /// Encodes the transaction's change record into `buffer`. Fallible,
        /// changes nothing (overflow is TransactionLogCapacity).
        pub fn prepareCommit(self: *const Self, slot: u16, buffer: []u8) Error![]const u8 {
            try self.deferredViolation(slot);
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
            self.endSessionTransaction(slot, true);
            M.releaseLocks(self, slot, 0);
            self.free(slot);
            if (wrote) {
                const at = self.horizon();
                M.reclaim(self, slot, at);
                self.reclaimTables(at);
            }
            tx.write_len = 0;
            // The record (if any) carried every pending log-ahead value.
            tx.seq_dirty = .{};
            self.seq_carried = .{};
        }

        /// Undoes every write and releases every lock of the transaction.
        /// Sequence log-ahead values are not rolled back: they are carried.
        pub fn abort(self: *Self, slot: u16) void {
            if (!self.active(slot)) return;
            const tx = &self.txs[slot];
            M.abortSlice(self, slot, 0, 0);
            self.seq_carried.merge(&tx.seq_dirty);
            tx.seq_dirty = .{};
            self.endSessionTransaction(slot, false);
            self.free(slot);
        }

        fn free(self: *Self, slot: u16) void {
            const tx = &self.txs[slot];
            tx.active = false;
            tx.running_snap = null;
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
            self.sessionRollback(slot, tx.userSavepoints(), true);
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
                // The failed statement's NOTIFY entries and set_config calls.
                self.notify.discard(slot, tx.epoch, 0, tx.cid);
                if (self.statement_settings_cid) |cid| if (cid == tx.cid) {
                    const state = self.sessionState();
                    if (state.tx_epoch == tx.epoch) {
                        state.values = self.statement_settings;
                        state.base = self.statement_base;
                    }
                };
            }
            self.statement_settings_cid = null;
            tx.copy_table = null;
            tx.copy_rows = 0;
            tx.running_snap = null;
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
            if (self.ownSession(slot)) |state| state.savepoint();
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
            if (self.ownSession(slot)) |state| state.release(index);
            return index;
        }

        /// Undoes everything after the savepoint, which stays established.
        pub fn rollbackTo(self: *Self, slot: u16, name: []const u8) Error!usize {
            const index = try self.findSavepoint(slot, name);
            const tx = &self.txs[slot];
            const sub = tx.subs[index];
            M.abortSlice(self, slot, sub.write_start, sub.lock_start);
            tx.sub_len = index + 1;
            self.sessionRollback(slot, index + 1, false);
            if (self.ownSession(slot)) |state| state.rollbackTo(index);
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
            if (comptime config.external_results) if (result.rows.len == 0) return error.InvalidParameterValue;
            if (comptime config.external_workspace) if (self.workspace.query.cells.len == 0) return error.InvalidParameterValue;
            if (comptime config.external_storage) if (self.workspace.query.refs.len == 0) return error.InvalidParameterValue;
            if (!self.active(slot)) return error.NoActiveTransaction;
            const tx = &self.txs[slot];
            // Routine statements (B11 wave 3) have their own grammar.
            const routine = options.mode == .standard and R.classify(source) != null;
            const parsed: A.Statement = if (routine) .{ .control = .commit } else P.parse(source, &self.workspace.nodes, options.mode) catch |err| {
                if (options.@"resume") self.dropStatement(slot);
                return legacy(options.mode, err);
            };
            var snap: Snapshot = undefined;
            if (options.@"resume") {
                const pinned = tx.pin orelse return error.QueryCanceled;
                snap = pinned;
                // A wait before any data access (table lock, catalog) takes a
                // fresh snapshot, as PostgreSQL locks before snapshotting
                // (the transaction snapshot too, when this statement took it).
                if (tx.fresh) {
                    if (tx.snapshot_csn != null and tx.snapshot_cid == tx.cid) {
                        tx.snapshot_csn = self.csn;
                        if (tx.ssi) |index| self.ssi.records[index].snapshot = self.csn;
                    }
                    snap.csn = if (transactionSnapshot(tx.isolation) and tx.snapshot_csn != null) tx.snapshot_csn.? else self.csn;
                }
                tx.pin = null;
                tx.fresh = false;
            } else {
                if (tx.pin != null) return error.QueryCanceled;
                if (tx.sub_len >= M.sub_capacity) return error.SavepointCapacity;
                tx.cid +%= 1;
                tx.progress = 0;
                tx.progress_affected = 0;
                self.modifying[slot] = .{};                snap = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid };
                // The first statement that needs a snapshot fixes the
                // transaction snapshot (REPEATABLE READ / SERIALIZABLE use it).
                if (needsSnapshot(&parsed)) {
                    if (tx.snapshot_csn == null) {
                        tx.snapshot_csn = self.csn;
                        tx.snapshot_cid = tx.cid;
                    }
                    if (transactionSnapshot(tx.isolation)) snap.csn = tx.snapshot_csn.?;
                }
                tx.subs[tx.sub_len] = .{ .statement = true, .write_start = @intCast(tx.write_len), .lock_start = @intCast(tx.lock_len) };
                tx.sub_len += 1;
            }
            self.statement_implicit = options.implicit;
            tx.running_snap = snap;
            defer tx.running_snap = null;
            const start = tx.subs[tx.sub_len - 1].write_start;
            self.statementHooks(slot, snap);
            self.routine_result = result;
            self.statement_start = start;
            const ran = if (routine) self.routineBody(slot, source, snap, result) else self.body(slot, source, &parsed, snap, result, options.mode);
            ran catch |err| {
                if (err == error.WouldBlock) {
                    tx.pin = snap;
                    return err;
                }
                self.dropStatement(slot);
                self.wake_epoch +%= 1;
                return legacy(options.mode, err);
            };
            // DEFERRABLE constraints in IMMEDIATE mode: end of statement.
            self.deferredCheck(slot, start, true) catch |err| {
                self.dropStatement(slot);
                self.wake_epoch +%= 1;
                return err;
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
            return .{ .source = source, .tables = &self.tables, .catalog = &self.catalog, .snapshot = snap, .pool = &self.workspace.nodes, .legacy = mode == .legacy_alpha, .dialect = self.dialect, .session = &self.session, .plans = &self.workspace.plans, .params = self.active_params,
                .routines = &self.objects, .variables = if (self.routine_frame) |frame| &frame.variables else null };
        }

        fn evalContext(self: *const Self, source: []const u8) E.Context {
            return .{ .source = source, .pool = &self.workspace.nodes, .session = &self.session };
        }

        fn body(self: *Self, slot: u16, original: []const u8, parsed: *const A.Statement, snap: Snapshot, result: *Result, mode: ParseMode) Error!void {
            self.workspace.query.read_stats = .{};
            try self.session.checkpoint();
            switch (parsed.*) {
                .control => |command| return self.runControl(slot, original, command, result),
                .session => |*command| return self.runSession(slot, original, command, snap, result, mode),
                else => {},
            }
            try self.serializableSnapshot(slot);
            self.workspace.security_check = ast.none;
            // Catalog objects (B11 wave 3); a READ ONLY transaction writes none (25006).
            if (parsed.* == .catalog_object) {
                if (self.txs[slot].read_only) return error.ReadOnlyTransaction;
                return self.catalogObject(slot, original, &parsed.catalog_object, snap);
            }
            var statement_copy = parsed.*;
            const expanded = try expandRelations(self, &self.workspace, original, snap, &statement_copy, self.session.role);
            const source = try self.secureTarget(&statement_copy, expanded, original, snap);
            const context = self.bindContext(source, mode, snap);
            const bound = try B.bind(&context, &statement_copy);
            if (self.txs[slot].read_only) try readOnlyCheck(&bound, &self.workspace.plans);
            try self.checkPrivileges(&bound, snap);
            try self.secureNewRows(&bound, source, snap);
            switch (bound) {
                .control => return error.UnsupportedStatement,
                .select => |*select| {
                    self.outcome = .{ .affected = 0, .command = .select };
                    if (select.table) |table| try self.lockTable(slot, table, if (select.lock.strength == .none) .access_share else .row_share);
                    if (select.lock.strength == .none)
                        return X.select(&self.tables, source, &self.workspace.nodes, select, snap, result, X.NoLock{}, &self.session, self.txs[slot].write_len == 0, &self.workspace.query.read_stats, &self.workspace.query);
                    const row_mode: locks_module.RowMode = switch (select.lock.strength) {
                        .update, .none => .update,
                        .no_key_update => .no_key_update,
                        .share => .share,
                        .key_share => .key_share,
                    };
                    const locker: RowLocker = .{ .db = self, .slot = slot, .snap = snap, .mode = row_mode, .wait = select.lock.wait };
                    return X.select(&self.tables, source, &self.workspace.nodes, select, snap, result, locker, &self.session, self.txs[slot].write_len == 0, &self.workspace.query.read_stats, &self.workspace.query);
                },
                .query => |root| {
                    self.outcome = .{ .affected = 0, .command = .select };
                    const plans = &self.workspace.plans;
                    for (plans.items[0..plans.len]) |*plan| {
                        for (plan.sources[0..plan.source_count]) |*item| if (item.table) |table| try self.lockTable(slot, table, .access_share);
                    }
                    defer {
                        self.workspace.query.pinned_cells = 0;
                        self.workspace.query.pinned_refs = 0;
                    }
                    if (plans.dml_len != 0) {
                        try self.modifyingCtes(slot, source, snap);
                        try self.afterTriggers(slot, self.statement_start, null, snap);
                    }
                    return X.runQuery(&self.tables, source, &self.workspace.nodes, plans, root, snap, result, &self.session, &self.workspace.query, self.txs[slot].write_len == 0);
                },
                else => {},
            }
            const affected: usize = switch (bound) {
                .noop => 0,
                .create_table => |*create| blk: {
                    var definition = create.*;
                    // Views depend on the views they expanded, too.
                    if (definition.extras.relkind == 'v' or definition.extras.relkind == 'm') {
                        for (self.workspace.expanded[0..self.workspace.expanded_count]) |oid| {
                            var known = false;
                            for (definition.extras.depends[0..definition.extras.depend_count]) |existing| known = known or existing == oid;
                            if (known or definition.extras.depend_count == config.tables) continue;
                            definition.extras.depends[definition.extras.depend_count] = oid;
                            definition.extras.depend_count += 1;
                        }
                    }
                    break :blk try self.createTable(slot, &definition, snap, source);
                },
                .drop_table => |index| try self.dropTable(slot, index, false, snap),
                .create_sequence => |*create| blk: {
                    try self.createSequence(slot, create.name, create.spec, 0, 0, snap);
                    break :blk 0;
                },
                .drop_sequence => |index| blk: {
                    if (self.seqs[index].owner != 0) return error.DependentObjects;
                    try self.dropSequence(slot, index, snap);
                    break :blk 0;
                },
                .insert => |*insert| blk: {
                    try self.lockTable(slot, insert.table, .row_exclusive);
                    if (insert.conflict.action != .none) try self.ssiRead(slot, insert.table);
                    try self.lockSources(slot);
                    // Rules and triggers (B11 wave 3).
                    const upsert = insert.conflict.action == .update;
                    if (insert.conflict.action != .none and (self.ruleKind(insert.table, '3', snap) != .none or self.ruleKind(insert.table, '2', snap) != .none)) return error.UnsupportedStatement;
                    if (try self.insteadNothing(insert.table, '3', insert.returning.count != 0, snap)) break :blk 0;
                    const events: []const u8 = if (upsert) &.{ routine_catalog.tg_insert, routine_catalog.tg_update } else &.{routine_catalog.tg_insert};
                    try self.statementTriggers(insert.table, routine_catalog.tg_before, events, snap);
                    const affected = try self.insertRows(slot, source, insert, snap);
                    try self.afterTriggers(slot, self.statement_start, if (upsert) &insert.conflict.update.values else null, snap);
                    try self.statementTriggers(insert.table, 0, events, snap);
                    break :blk affected;
                },
                .update => |*update| blk: {
                    try self.lockTable(slot, update.table, .row_exclusive);
                    try self.ssiRead(slot, update.table);
                    try self.lockSources(slot);
                    if (try self.insteadNothing(update.table, '2', update.returning.count != 0, snap)) break :blk 0;
                    try self.statementTriggers(update.table, routine_catalog.tg_before, &.{routine_catalog.tg_update}, snap);
                    const affected = try self.updateRows(slot, source, update, snap);
                    try self.afterTriggers(slot, self.statement_start, &update.values, snap);
                    try self.statementTriggers(update.table, 0, &.{routine_catalog.tg_update}, snap);
                    break :blk affected;
                },
                .delete => |*delete| blk: {
                    try self.lockTable(slot, delete.table, .row_exclusive);
                    try self.ssiRead(slot, delete.table);
                    try self.lockSources(slot);
                    if (try self.insteadNothing(delete.table, '4', delete.returning.count != 0, snap)) break :blk 0;
                    try self.statementTriggers(delete.table, routine_catalog.tg_before, &.{routine_catalog.tg_delete}, snap);
                    const affected = try self.deleteRows(slot, source, delete, snap);
                    try self.afterTriggers(slot, self.statement_start, null, snap);
                    try self.statementTriggers(delete.table, 0, &.{routine_catalog.tg_delete}, snap);
                    break :blk affected;
                },
                .truncate => |*truncate| blk: {
                    for (truncate.tables[0..truncate.count]) |index| try self.statementTriggers(index, routine_catalog.tg_before, &.{routine_catalog.tg_truncate}, snap);
                    try self.truncateTables(slot, truncate, snap);
                    for (truncate.tables[0..truncate.count]) |index| try self.statementTriggers(index, 0, &.{routine_catalog.tg_truncate}, snap);
                    break :blk 0;
                },
                .alter_table => |*alter| blk: {
                    try self.alterTable(slot, alter, snap);
                    break :blk 0;
                },
                .alter_sequence => |*alter| blk: {
                    try self.alterSequence(slot, alter.slot, alter.options, snap);
                    break :blk 0;
                },
                .create_schema => |name| blk: {
                    try self.createSchema(slot, name, snap);
                    break :blk 0;
                },
                .drop_schema => |*drop| blk: {
                    try self.dropSchema(slot, drop, snap);
                    break :blk 0;
                },
                .drop_relation => |*drop| try self.dropTable(slot, drop.slot, drop.cascade, snap),
                .set_constraints => |*set| blk: {
                    try self.setConstraints(slot, set);
                    break :blk 0;
                },
                .refresh_view => |*refresh| try self.refreshView(slot, refresh, source, snap),
                .merge => |*merge| blk: {
                    try self.lockTable(slot, merge.table, .row_exclusive);
                    try self.ssiRead(slot, merge.table);
                    try self.lockSources(slot);
                    // MERGE is not supported for relations with rules (0A000).
                    if (self.anyRule(merge.table, snap)) return error.UnsupportedStatement;
                    const affected = try self.mergeRows(slot, source, merge, snap);
                    try self.afterTriggers(slot, self.statement_start, null, snap);
                    break :blk affected;
                },
                .select, .query, .control => unreachable,
            };
            self.outcome = .{ .affected = affected, .command = B.command(&bound), .noop = bound == .noop };
            switch (bound) {
                .insert => |*insert| if (insert.returning.count != 0) try self.returnRows(slot, source, &insert.returning, insert.table, insert.plan == ast.none, result.rows.len),
                .update => |*update| if (update.returning.count != 0) try self.returnRows(slot, source, &update.returning, update.table, true, result.rows.len),
                .delete => |*delete| if (delete.returning.count != 0) try self.returnRows(slot, source, &delete.returning, delete.table, true, result.rows.len),
                else => {},
            }
        }

        /// Data-modifying WITH entries (B11): each runs exactly once, in
        /// statement order, under the statement snapshot (so neither the
        /// other entries nor the main query see its writes), with its
        /// table's row-exclusive lock and the usual row locks / waits. Its
        /// RETURNING rows are captured from its own slice of the write set
        /// into the pinned top of the workspace for the main query. A park
        /// keeps each entry's write-slice start and INSERT progress, so a
        /// resumed statement neither repeats nor loses writes. Every write is
        /// part of the statement subtransaction: any later failure undoes all.
        const Modifying = struct {
            started: [config.ctes]bool = @splat(false),
            start: [config.ctes]usize = @splat(0),
            progress: [config.ctes]usize = @splat(0),
            affected: [config.ctes]usize = @splat(0),
        };

        fn modifyingCtes(self: *Self, slot: u16, source: []const u8, snap: Snapshot) Error!void {
            const plans = &self.workspace.plans;
            const work = &self.workspace.query;
            work.pinned_cells = 0;
            work.pinned_refs = 0;
            const state = &self.modifying[slot];
            const tx = &self.txs[slot];
            for (plans.dml[0..plans.dml_len], 0..) |*dml, k| {
                if (!state.started[k]) {
                    state.started[k] = true;
                    state.start[k] = tx.write_len;
                }
                tx.progress = state.progress[k];
                tx.progress_affected = state.affected[k];
                const table_index: usize, const returning: *const B.Returning = switch (dml.*) {
                    .insert => |*insert| .{ insert.table, &insert.returning },
                    .update => |*update| .{ update.table, &update.returning },
                    .delete => |*delete| .{ delete.table, &delete.returning },
                };
                // Rules are not supported for data-modifying WITH (0A000).
                if (self.anyRule(table_index, snap)) return error.UnsupportedStatement;
                self.runModifying(slot, source, dml, snap) catch |err| {
                    state.progress[k] = tx.progress;
                    state.affected[k] = tx.progress_affected;
                    return err;
                };
                state.progress[k] = tx.progress;
                state.affected[k] = tx.progress_affected;
                const last = if (k + 1 < plans.dml_len and state.started[k + 1]) state.start[k + 1] else tx.write_len;
                work.dml_rows[k] = try self.captureReturning(source, returning, table_index, state.start[k], last, slot);
            }
            tx.progress = 0;
            tx.progress_affected = 0;
        }

        fn runModifying(self: *Self, slot: u16, source: []const u8, dml: *const B.DmlBound, snap: Snapshot) Error!void {
            switch (dml.*) {
                .insert => |*insert| {
                    try self.lockTable(slot, insert.table, .row_exclusive);
                    _ = try self.insertRows(slot, source, insert, snap);
                },
                .update => |*update| {
                    try self.lockTable(slot, update.table, .row_exclusive);
                    _ = try self.updateRows(slot, source, update, snap);
                },
                .delete => |*delete| {
                    try self.lockTable(slot, delete.table, .row_exclusive);
                    _ = try self.deleteRows(slot, source, delete, snap);
                },
            }
        }

        /// RETURNING of the rows `table_index` got from writes first..last,
        /// in write order, into the pinned top of the query workspace.
        fn captureReturning(self: *Self, source: []const u8, list: *const B.Returning, table_index: usize, first: usize, last: usize, slot: u16) Error!X.List {
            const tx = &self.txs[slot];
            const writes = tx.writes[first..last];
            var count: usize = 0;
            for (writes) |entry| if (rowWrite(entry.kind) and entry.table == table_index) {
                count += 1;
            };
            const work = &self.workspace.query;
            const width = list.count;
            if ((work.cell_high - work.cell_low) / @max(width, 1) < count or work.ref_high - work.ref_low < count) return error.WorkspaceCapacity;
            work.cell_high -= count * width;
            work.ref_high -= count;
            const out: X.List = .{ .start = @intCast(work.ref_high), .count = @intCast(count) };
            var ctx = self.evalContext(source);
            const table = &self.tables[table_index];
            var row: usize = 0;
            for (writes) |entry| {
                if (!rowWrite(entry.kind) or entry.table != table_index) continue;
                try self.session.checkpoint();
                ctx.row = &table.versions[if (entry.kind == .delete) entry.old else entry.new].cells;
                const at = work.cell_high + row * width;
                for (list.targets[0..width], 0..) |id, column| work.cells[at + column] = try E.eval(&ctx, id);
                work.refs[out.start + row] = @intCast(at);
                row += 1;
            }
            work.pinned_cells = work.cells.len - work.cell_high;
            work.pinned_refs = work.refs.len - work.ref_high;
            return out;
        }

        /// RETURNING: one row per row this statement wrote, in write order
        /// (new versions for INSERT/UPDATE, the deleted version for DELETE).
        /// The statement's write slice survives a park, so a resumed
        /// statement emits every row exactly once. Every value is computed
        /// into the workspace first; a failure leaves the result untouched.
        fn returnRows(self: *Self, slot: u16, source: []const u8, list: *const B.Returning, table_index: usize, fresh: bool, result_capacity: usize) Error!void {
            const tx = &self.txs[slot];
            // The statement's own writes (a routine's statement starts
            // inside the CALL / DO statement's subtransaction).
            const start = self.statement_start;
            const writes = tx.writes[start..tx.write_len];
            var count: usize = 0;
            for (writes) |entry| if (rowWrite(entry.kind) and (entry.table == table_index or self.descends(entry.table, table_index))) {
                count += 1;
            };
            if (count > result_capacity) return error.RowCapacity;
            const work = &self.workspace.query;
            if (fresh) X.resetWork(work);
            const width = list.count;
            const base = try X.stageCells(work, count * width);
            var ctx = self.evalContext(source);
            var row: usize = 0;
            for (writes) |entry| {
                if (!rowWrite(entry.kind) or (entry.table != table_index and !self.descends(entry.table, table_index))) continue;
                const table = &self.tables[entry.table];
                ctx.row = &table.versions[if (entry.kind == .delete) entry.old else entry.new].cells;
                for (list.targets[0..width], 0..) |id, column| work.cells[base + row * width + column] = try E.eval(&ctx, id);
                row += 1;
            }
            var returned: Returned = .{ .count = width, .rows = count, .base = base };
            @memcpy(returned.names[0..width], list.names[0..width]);
            @memcpy(returned.types[0..width], list.types[0..width]);
            @memcpy(returned.typmods[0..width], list.typmods[0..width]);
            self.outcome.returning = returned;
        }

        fn rowWrite(kind: anytype) bool {
            return kind == .insert or kind == .update or kind == .delete;
        }

        /// Reclamation horizon covers running bodies, parked statements and
        /// COPY between messages. A pre-data lock wait may re-snapshot.
        fn horizon(self: *const Self) u64 {
            var out = self.csn;
            for (&self.txs) |*tx| if (tx.active) {
                if (tx.running_snap) |snap| out = @min(out, snap.csn);
                if (tx.copy_table != null) out = @min(out, tx.copy_snap.csn);
                if (transactionSnapshot(tx.isolation)) if (tx.snapshot_csn) |csn| {
                    out = @min(out, csn);
                };
                if (!tx.fresh) if (tx.pin) |pin| { out = @min(out, pin.csn); };
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
            for (&self.seqs) |*seq| if (seq.live and seq.dead_csn != 0 and seq.dead_csn <= at) {
                seq.live = false;
                seq.dead_csn = 0;
                freed = true;
            };
            for (&self.schemas) |*schema| if (schema.live and schema.dead_csn != 0 and schema.dead_csn <= at) {
                schema.live = false;
                schema.dead_csn = 0;
                freed = true;
            };
            if (self.objects.reclaim(at)) freed = true;
            if (freed) _ = self.catalog.vacuum(at);
        }

        // ---- schemas ---------------------------------------------------------

        /// CREATE SCHEMA: a schema slot, an OID and a cat_relations row
        /// (relkind 'n'), all transactional. A concurrent creator of the same
        /// name is waited for; the binder already rejected a visible name.
        fn createSchema(self: *Self, slot: u16, name: Name, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            if (self.catalog.creator(name.slice(), snap)) |other| {
                var waits: L.Set = .{};
                waits.add(other);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            try self.reserveWrites(slot, 2);
            var destination: ?usize = null;
            for (0..2) |attempt| {
                for (&self.schemas, 0..) |*schema, index| if (!schema.live) {
                    destination = index;
                    break;
                };
                if (destination != null or attempt == 1) break;
                self.reclaimTables(self.horizon());
            }
            const index = destination orelse return error.TableCapacity;
            if (self.oid_counter >= 0xffffffff - change_log.first_oid) return error.TableCapacity;
            const schema = &self.schemas[index];
            schema.* = .{ .live = true, .pending_create = true, .creator = slot, .oid = change_log.first_oid + self.oid_counter, .name = name };
            self.oid_counter += 1;
            tx.push(.{ .kind = .create_schema, .table = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const count = try self.catalog.createSchema(index, schema.oid, name.slice(), tx.ref(slot), snap.cid, 0, self.horizon(), &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_insert, .table = @intFromEnum(change.relation), .new = change.version }) catch unreachable;
        }

        /// DROP SCHEMA: RESTRICT refuses a schema that holds tables (2BP01);
        /// CASCADE drops them first. A table another transaction is creating
        /// in it, or its pending DROP, is waited for.
        fn dropSchema(self: *Self, slot: u16, drop: *const B.DropSchema, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const schema = &self.schemas[drop.slot];
            var waits: L.Set = .{};
            if (schema.pending_drop and schema.creator != slot) waits.add(schema.creator);
            if (self.catalog.namespaceCreator(drop.oid, snap)) |other| waits.add(other);
            if (self.catalog_objects.pendingReference(drop.oid, snap)) |other| waits.add(other);
            if (waits.any()) {
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind != 'r' or self.tables[found.slot].namespace != drop.oid) continue;
                if (!drop.cascade) return error.DependentObjects;
                _ = try self.dropTable(slot, found.slot, true, snap);
            }
            try self.reserveWrites(slot, 2);
            schema.pending_drop = true;
            schema.creator = slot;
            tx.push(.{ .kind = .drop_schema, .table = @intCast(drop.slot) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const changed = self.catalog.dropSchema(drop.slot, snap, tx.ref(slot), snap.cid, 0, &changes);
            for (changes[0..changed]) |change| tx.push(.{ .kind = .catalog_delete, .table = @intFromEnum(change.relation), .old = change.version }) catch unreachable;
            try self.dropObjectsOf(slot, drop.oid, snap);
        }

        /// Schema name of a namespace OID for the system views.
        fn namespaceName(self: *const Self, oid: u32) []const u8 {
            for (catalog_module.namespaces) |namespace| if (namespace.oid == oid) return namespace.name;
            for (&self.schemas) |*schema| if (schema.live and schema.oid == oid) return schema.name.slice();
            return "";
        }

        // ---- catalog objects (B11 wave 3, catalog_objects.sig) --------------

        fn objectIdent(ident: CO.Ident) ast.Ident {
            return .{ .span = .{ .start = ident.span.start, .len = ident.span.len }, .quoted = ident.quoted, .len = ident.len };
        }

        fn objectName(source: []const u8, ident: CO.Ident) Name {
            return identName(source, objectIdent(ident));
        }

        /// The current role holds every privilege (bootstrap or superuser).
        fn privilegedRole(self: *const Self, snap: Snapshot) bool {
            return self.session.role == CO.bootstrap_role or self.catalog_objects.superuser(self.session.role, snap);
        }

        fn actorFlags(self: *const Self, snap: Snapshot) u32 {
            return self.catalog_objects.roleFlags(self.session.role, snap) orelse 0;
        }

        /// A role named in GRANT / policies / OWNER TO (PUBLIC is 0; 42704
        /// for an unknown name).
        fn objectRole(self: *const Self, source: []const u8, grantee: CO.Grantee, snap: Snapshot) Error!u32 {
            return switch (grantee.kind) {
                .public => CO.public_role,
                .current_user, .current_role => self.session.role,
                .session_user => self.session.session_role,
                .name => self.catalog_objects.roleByName(objectName(source, grantee.name).slice(), snap) orelse error.UndefinedObject,
            };
        }

        /// `role` holds ADMIN OPTION on `group` (or is a superuser).
        fn roleAdmin(self: *const Self, role: u32, group: u32, snap: Snapshot) bool {
            if (self.catalog_objects.superuser(role, snap)) return true;
            const key: O.Object = .{ .kind = .member, .target = group, .grantee = role };
            const index = self.catalog_objects.findKey(&key, snap) orelse return false;
            return self.catalog_objects.items[index].grant_flags & 1 != 0;
        }

        fn objectPark(self: *Self, slot: u16, other: u16) Error {
            const tx = &self.txs[slot];
            var waits: L.Set = .{};
            waits.add(other);
            tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
            return self.park(slot, waits);
        }

        /// Writes a new object version for the statement (writes reserved
        /// by the caller); `fresh_oid` takes the next OID.
        fn objectInsert(self: *Self, slot: u16, value: *O.Object, fresh_oid: bool, snap: Snapshot) Error!usize {
            const index = try self.catalog_objects.allocate(self.horizon());
            if (fresh_oid) {
                if (self.oid_counter >= 0xffffffff - change_log.first_oid) return error.TableCapacity;
                value.oid = change_log.first_oid + self.oid_counter;
                self.oid_counter += 1;
            }
            const tx = &self.txs[slot];
            self.catalog_objects.insert(index, value, tx.ref(slot), snap.cid, 0);
            tx.push(.{ .kind = .object_insert, .table = @intFromBool(fresh_oid), .new = @intCast(index) }) catch unreachable;
            return index;
        }

        fn objectDelete(self: *Self, slot: u16, index: usize, snap: Snapshot) void {
            const tx = &self.txs[slot];
            self.catalog_objects.mark(index, tx.ref(slot), snap.cid);
            tx.push(.{ .kind = .object_delete, .table = 0, .old = @intCast(index) }) catch unreachable;
        }

        /// Objects that die with `oid` (a table: its grants, owner/RLS
        /// entry, policies and comments; a sequence, schema, policy,
        /// wrapper, server, publication or role: its comment). Another
        /// transaction's uncommitted object naming it is waited for.
        fn objectDependent(o: *const O.Object, oid: u32) bool {
            return switch (o.kind) {
                .acl, .relation, .policy => o.target == oid,
                .comment => o.target == oid,
                else => false,
            };
        }

        fn dropObjectsOf(self: *Self, slot: u16, oid: u32, snap: Snapshot) Error!void {
            if (self.catalog_objects.pendingReference(oid, snap)) |other| return self.objectPark(slot, other);
            var count: usize = 0;
            for (&self.catalog_objects.items) |*o| {
                if (!O.visible(o, snap) or o.xmax.epoch != 0) continue;
                if (objectDependent(o, oid)) count += 1;
                // Comments on the table's policies go with them.
                if (o.kind == .policy and o.target == oid) {
                    for (&self.catalog_objects.items) |*c| if (c.kind == .comment and c.grantee == CO.class_policy and c.target == o.oid and O.visible(c, snap) and c.xmax.epoch == 0) {
                        count += 1;
                    };
                }
            }
            if (count == 0) return;
            try self.reserveWrites(slot, count);
            for (&self.catalog_objects.items, 0..) |*o, index| {
                if (!O.visible(o, snap) or o.xmax.epoch != 0) continue;
                if (o.kind == .policy and o.target == oid) {
                    for (&self.catalog_objects.items, 0..) |*c, position| if (c.kind == .comment and c.grantee == CO.class_policy and c.target == o.oid and O.visible(c, snap) and c.xmax.epoch == 0) {
                        self.objectDelete(slot, position, snap);
                    };
                }
                if (objectDependent(o, oid)) self.objectDelete(slot, index, snap);
            }
        }

        /// ALTER TABLE moved or dropped columns: column comments follow
        /// their column (`sources[new] = old`), or go with it.
        fn remapColumnComments(self: *Self, slot: u16, oid: u32, sources: []const u8, snap: Snapshot) Error!void {
            var count: usize = 0;
            for (&self.catalog_objects.items) |*o| {
                if (o.kind != .comment or o.grantee != CO.class_relation or o.target != oid or o.sub == 0 or !O.visible(o, snap) or o.xmax.epoch != 0) continue;
                count += 1;
            }
            if (count == 0) return;
            try self.reserveWrites(slot, 2 * count);
            for (0..self.catalog_objects.items.len) |index| {
                const o = &self.catalog_objects.items[index];
                if (o.kind != .comment or o.grantee != CO.class_relation or o.target != oid or o.sub == 0 or !O.visible(o, snap) or o.xmax.epoch != 0) continue;
                // Only versions that existed before this statement move.
                if (o.xmin_csn == 0 and o.xmin_cid == snap.cid) continue;
                var moved: ?usize = null;
                for (sources, 0..) |origin, position| if (origin != 0xff and @as(i32, origin) + 1 == o.sub) {
                    moved = position;
                };
                if (moved) |position| if (@as(i32, @intCast(position)) + 1 == o.sub) continue;
                var next = o.*;
                self.objectDelete(slot, index, snap);
                if (moved) |position| {
                    next.sub = @intCast(position + 1);
                    _ = try self.objectInsert(slot, &next, false, snap);
                }
            }
        }

        /// A table, view or materialized view named by a catalog-object
        /// statement (42P01), locked in `mode`; null with IF EXISTS.
        fn objectTable(self: *Self, slot: u16, source: []const u8, name: CO.Qualified, mode: locks_module.TableMode, snap: Snapshot) Error!usize {
            const schema_name = if (name.has_schema) objectName(source, name.schema) else Name{};
            const namespace = namespaceFor(&self.catalog, if (name.has_schema) schema_name.slice() else null, snap) orelse return error.UndefinedSchema;
            const found = self.catalog.findIn(namespace, objectName(source, name.name).slice(), snap) orelse return error.TableNotFound;
            if (found.kind == 'S') return error.WrongObjectType;
            try self.lockTable(slot, found.slot, mode);
            return found.slot;
        }

        fn catalogObject(self: *Self, slot: u16, source: []const u8, object_statement: *const CO.Statement, snap: Snapshot) Error!void {
            const command: CommandTag = switch (object_statement.*) {
                .create_role => |*spec| blk: {
                    try self.createRole(slot, source, spec, snap);
                    break :blk .create_role;
                },
                .alter_role => |*spec| blk: {
                    try self.alterRole(slot, source, spec, snap);
                    break :blk .alter_role;
                },
                .drop_role => |*drop| blk: {
                    try self.dropRoles(slot, source, drop, snap);
                    break :blk .drop_role;
                },
                .grant => |*grant| blk: {
                    if (grant.membership) try self.grantMembership(slot, source, grant, false, snap) else try self.grantTables(slot, source, grant, false, snap);
                    break :blk if (grant.membership) .grant_role else .grant;
                },
                .revoke => |*grant| blk: {
                    if (grant.membership) try self.grantMembership(slot, source, grant, true, snap) else try self.grantTables(slot, source, grant, true, snap);
                    break :blk if (grant.membership) .revoke_role else .revoke;
                },
                .create_policy => |*policy| blk: {
                    try self.createPolicy(slot, source, policy, snap);
                    break :blk .create_policy;
                },
                .alter_policy => |*policy| blk: {
                    try self.alterPolicy(slot, source, policy, snap);
                    break :blk .alter_policy;
                },
                .drop_policy => |*policy| blk: {
                    try self.dropPolicy(slot, source, policy, snap);
                    break :blk .drop_policy;
                },
                .table_security => |*security| blk: {
                    try self.tableSecurity(slot, source, security, snap);
                    break :blk .alter_table;
                },
                .comment => |*comment| blk: {
                    try self.commentOn(slot, source, comment, snap);
                    break :blk .comment;
                },
                .create_fdw => |*named| blk: {
                    try self.createNamed(slot, source, .fdw, named.name, named.if_not_exists, null, snap);
                    break :blk .create_foreign_data_wrapper;
                },
                .create_server => |*server| blk: {
                    try self.createNamed(slot, source, .server, server.name, server.if_not_exists, server, snap);
                    break :blk .create_server;
                },
                .create_publication => |*publication| blk: {
                    try self.createPublication(slot, source, publication, snap);
                    break :blk .create_publication;
                },
                .drop_fdw => |*drop| blk: {
                    try self.dropNamed(slot, source, .fdw, drop, snap);
                    break :blk .drop_foreign_data_wrapper;
                },
                .drop_server => |*drop| blk: {
                    try self.dropNamed(slot, source, .server, drop, snap);
                    break :blk .drop_server;
                },
                .drop_publication => |*drop| blk: {
                    try self.dropNamed(slot, source, .publication, drop, snap);
                    break :blk .drop_publication;
                },
                .create_extension => |*named| blk: {
                    // plpgsql is the only extension, installed in every database.
                    if (!types.same(objectName(source, named.name).slice(), "plpgsql")) return error.UnsupportedStatement;
                    if (!named.if_not_exists) return error.DuplicateObject;
                    break :blk .create_extension;
                },
            };
            self.outcome = .{ .affected = 0, .command = command };
        }

        // -- roles ---------------------------------------------------------

        /// CREATE ROLE: superusers, or CREATEROLE roles for roles without
        /// SUPERUSER (and REPLICATION / BYPASSRLS only when they hold them).
        fn createRole(self: *Self, slot: u16, source: []const u8, spec: *const CO.RoleSpec, snap: Snapshot) Error!void {
            const name = objectName(source, spec.name);
            if (CO.reservedRoleName(name.slice())) return error.ReservedName;
            const actor = self.actorFlags(snap);
            const superuser = actor & CO.role_superuser != 0;
            if (!superuser and actor & CO.role_createrole == 0) return error.InsufficientPrivilege;
            const flags = (CO.role_inherit | spec.set) & ~spec.clear;
            if (!superuser and (flags & CO.role_superuser != 0 or flags & ~actor & (CO.role_replication | CO.role_bypassrls) != 0)) return error.InsufficientPrivilege;
            var role: O.Object = .{ .kind = .role, .flags = flags, .grant_flags = @bitCast(spec.connlimit) };
            try role.setName(name.slice());
            if (self.catalog_objects.pendingConflict(&role, snap)) |other| return self.objectPark(slot, other);
            if (self.catalog_objects.roleByName(name.slice(), snap) != null) return error.DuplicateObject;
            var groups: [CO.list_capacity]u32 = undefined;
            for (spec.in_roles[0..spec.in_count], 0..) |group, index| {
                groups[index] = self.catalog_objects.roleByName(objectName(source, group).slice(), snap) orelse return error.UndefinedObject;
                if (!self.roleAdmin(self.session.role, groups[index], snap)) return error.InsufficientPrivilege;
                if (self.catalog_objects.superuser(groups[index], snap) and !superuser) return error.InsufficientPrivilege;
            }
            try self.reserveWrites(slot, 1 + spec.in_count);
            const index = try self.objectInsert(slot, &role, true, snap);
            const oid = self.catalog_objects.items[index].oid;
            for (groups[0..spec.in_count]) |group| {
                var member: O.Object = .{ .kind = .member, .target = group, .grantee = oid, .owner = if (superuser) CO.bootstrap_role else self.session.role };
                _ = try self.objectInsert(slot, &member, true, snap);
            }
        }

        fn alterRole(self: *Self, slot: u16, source: []const u8, spec: *const CO.RoleSpec, snap: Snapshot) Error!void {
            const oid = self.catalog_objects.roleByName(objectName(source, spec.name).slice(), snap) orelse return error.UndefinedObject;
            // The bootstrap superuser is built in.
            if (oid == CO.bootstrap_role) return error.UnsupportedStatement;
            const index = self.catalog_objects.byOid(.role, oid, snap) orelse return error.UndefinedObject;
            const current = &self.catalog_objects.items[index];
            const actor = self.actorFlags(snap);
            const superuser = actor & CO.role_superuser != 0;
            if (!superuser) {
                if (current.flags & CO.role_superuser != 0 or actor & CO.role_createrole == 0 or !self.roleAdmin(self.session.role, oid, snap)) return error.InsufficientPrivilege;
                if (spec.set & CO.role_superuser != 0 or spec.set & ~actor & (CO.role_replication | CO.role_bypassrls) != 0) return error.InsufficientPrivilege;
            }
            var next = current.*;
            if (spec.rename) {
                const new_name = objectName(source, spec.new_name);
                // Renaming the session or current user is 0A000.
                if (oid == self.session.session_role or oid == self.session.role) return error.UnsupportedStatement;
                if (CO.reservedRoleName(new_name.slice())) return error.ReservedName;
                if (self.catalog_objects.roleByName(new_name.slice(), snap) != null) return error.DuplicateObject;
                try next.setName(new_name.slice());
            } else {
                next.flags = (next.flags | spec.set) & ~spec.clear;
                if (spec.connlimit_set) next.grant_flags = @bitCast(spec.connlimit);
            }
            if (self.catalog_objects.pendingConflict(current, snap)) |other| return self.objectPark(slot, other);
            if (self.catalog_objects.pendingConflict(&next, snap)) |other| return self.objectPark(slot, other);
            try self.reserveWrites(slot, 2);
            self.objectDelete(slot, index, snap);
            _ = try self.objectInsert(slot, &next, false, snap);
        }

        /// DROP ROLE: never the current, session or bootstrap user (55006 /
        /// 2BP01); 2BP01 while it owns objects, holds grants or is named by
        /// a policy. Its memberships and comment go with it.
        fn dropRoles(self: *Self, slot: u16, source: []const u8, drop: *const CO.Drop, snap: Snapshot) Error!void {
            var roles: [CO.list_capacity]u32 = undefined;
            var count: usize = 0;
            var writes: usize = 0;
            const actor = self.actorFlags(snap);
            const superuser = actor & CO.role_superuser != 0;
            for (drop.names[0..drop.count]) |ident| {
                const oid = self.catalog_objects.roleByName(objectName(source, ident).slice(), snap) orelse {
                    if (drop.if_exists) continue;
                    return error.UndefinedObject;
                };
                if (oid == self.session.role or oid == self.session.session_role) return error.ObjectInUse;
                if (oid == CO.bootstrap_role) return error.DependentObjects;
                if (!superuser and (actor & CO.role_createrole == 0 or self.catalog_objects.superuser(oid, snap) or !self.roleAdmin(self.session.role, oid, snap))) return error.InsufficientPrivilege;
                var known = false;
                for (roles[0..count]) |seen| known = known or seen == oid;
                if (known) continue;
                if (self.catalog_objects.pendingReference(oid, snap)) |other| return self.objectPark(slot, other);
                for (&self.catalog_objects.items) |*o| {
                    if (!O.visible(o, snap)) continue;
                    switch (o.kind) {
                        .member => {
                            if (o.target == oid or o.grantee == oid) {
                                writes += 1;
                            } else if (o.owner == oid) return error.DependentObjects;
                        },
                        .comment => if (o.grantee == CO.class_authid and o.target == oid) {
                            writes += 1;
                        },
                        .acl => if (o.grantee == oid or o.owner == oid) return error.DependentObjects,
                        .policy => {
                            for (o.roleList()) |listed| {
                                if (listed == oid) return error.DependentObjects;
                            }
                        },
                        .relation, .fdw, .server, .publication => if (o.owner == oid) return error.DependentObjects,
                        else => {},
                    }
                }
                roles[count] = oid;
                count += 1;
                writes += 1;
            }
            try self.reserveWrites(slot, writes);
            for (roles[0..count]) |oid| {
                for (&self.catalog_objects.items, 0..) |*o, index| {
                    if (!O.visible(o, snap) or o.xmax.epoch != 0) continue;
                    const dies = switch (o.kind) {
                        .role => o.oid == oid,
                        .member => o.target == oid or o.grantee == oid,
                        .comment => o.grantee == CO.class_authid and o.target == oid,
                        else => false,
                    };
                    if (dies) self.objectDelete(slot, index, snap);
                }
            }
        }

        /// GRANT / REVOKE role membership. Granting needs ADMIN OPTION on
        /// the role (superusers have it); a grant that would make a role a
        /// member of itself is 0LP01.
        fn grantMembership(self: *Self, slot: u16, source: []const u8, grant: *const CO.Grant, revoke: bool, snap: Snapshot) Error!void {
            const actor = self.session.role;
            const superuser = self.privilegedRole(snap);
            var groups: [CO.list_capacity]u32 = undefined;
            var members: [CO.list_capacity]u32 = undefined;
            for (grant.granted[0..grant.granted_count], 0..) |ident, index| {
                groups[index] = self.catalog_objects.roleByName(objectName(source, ident).slice(), snap) orelse return error.UndefinedObject;
                if (!self.roleAdmin(actor, groups[index], snap)) return error.InsufficientPrivilege;
                if (!superuser and self.catalog_objects.superuser(groups[index], snap)) return error.InsufficientPrivilege;
            }
            for (grant.grantees[0..grant.grantee_count], 0..) |grantee, index| {
                if (grantee.kind == .public) return error.UndefinedObject;
                members[index] = try self.objectRole(source, grantee, snap);
            }
            var writes: usize = 0;
            for (groups[0..grant.granted_count]) |group| {
                for (members[0..grant.grantee_count]) |member| {
                    if (!revoke and (group == member or self.catalog_objects.memberOf(group, member, false, snap))) return error.InvalidGrantOperation;
                    const key: O.Object = .{ .kind = .member, .target = group, .grantee = member };
                    if (self.catalog_objects.pendingConflict(&key, snap)) |other| return self.objectPark(slot, other);
                    writes += 2;
                }
            }
            try self.reserveWrites(slot, writes);
            for (0..grant.granted_count * grant.grantee_count) |pair| {
                const group = groups[pair / grant.grantee_count];
                const member = members[pair % grant.grantee_count];
                const key: O.Object = .{ .kind = .member, .target = group, .grantee = member };
                const existing = self.catalog_objects.findKey(&key, snap);
                if (existing) |index| if (self.catalog_objects.items[index].xmax.epoch != 0) continue;
                if (revoke) {
                    const index = existing orelse continue;
                    var next = self.catalog_objects.items[index];
                    self.objectDelete(slot, index, snap);
                    // REVOKE ADMIN OPTION FOR keeps the membership.
                    if (grant.option) {
                        next.grant_flags = 0;
                        _ = try self.objectInsert(slot, &next, false, snap);
                    }
                    continue;
                }
                if (existing) |index| {
                    if (!grant.option or self.catalog_objects.items[index].grant_flags & 1 != 0) continue;
                    var next = self.catalog_objects.items[index];
                    next.grant_flags = 1;
                    self.objectDelete(slot, index, snap);
                    _ = try self.objectInsert(slot, &next, false, snap);
                    continue;
                }
                var member_object: O.Object = .{ .kind = .member, .target = group, .grantee = member, .grant_flags = @intFromBool(grant.option), .owner = if (superuser) CO.bootstrap_role else actor };
                _ = try self.objectInsert(slot, &member_object, true, snap);
            }
        }

        /// GRANT / REVOKE table privileges: the owner (or a superuser) or a
        /// holder of the grant options (42501 otherwise). One aclitem per
        /// table and grantee; its grantor is the table owner.
        fn grantTables(self: *Self, slot: u16, source: []const u8, grant: *const CO.Grant, revoke: bool, snap: Snapshot) Error!void {
            const actor = self.session.role;
            var slots: [CO.list_capacity]usize = undefined;
            var grantees: [CO.list_capacity]u32 = undefined;
            for (grant.tables[0..grant.table_count], 0..) |name, index| {
                slots[index] = try self.objectTable(slot, source, name, .access_share, snap);
                const oid = self.tables[slots[index]].oid;
                if (!self.catalog_objects.grantOptions(actor, oid, grant.privileges, snap)) return error.InsufficientPrivilege;
            }
            for (grant.grantees[0..grant.grantee_count], 0..) |grantee, index| grantees[index] = try self.objectRole(source, grantee, snap);
            var writes: usize = 0;
            for (0..grant.table_count * grant.grantee_count) |pair| {
                const key: O.Object = .{ .kind = .acl, .target = self.tables[slots[pair / grant.grantee_count]].oid, .grantee = grantees[pair % grant.grantee_count] };
                if (self.catalog_objects.pendingConflict(&key, snap)) |other| return self.objectPark(slot, other);
                writes += 2;
            }
            try self.reserveWrites(slot, writes);
            for (0..grant.table_count * grant.grantee_count) |pair| {
                const grantee = grantees[pair % grant.grantee_count];
                const oid = self.tables[slots[pair / grant.grantee_count]].oid;
                const key: O.Object = .{ .kind = .acl, .target = oid, .grantee = grantee };
                var next: O.Object = .{ .kind = .acl, .target = oid, .grantee = grantee, .owner = self.catalog_objects.owner(oid, snap) };
                const existing = self.catalog_objects.findKey(&key, snap);
                if (existing) |index| {
                    if (self.catalog_objects.items[index].xmax.epoch != 0) continue;
                    next.flags = self.catalog_objects.items[index].flags;
                    next.grant_flags = self.catalog_objects.items[index].grant_flags;
                }
                if (revoke) {
                    next.grant_flags &= ~grant.privileges;
                    if (!grant.option) next.flags &= ~grant.privileges;
                } else {
                    next.flags |= grant.privileges;
                    if (grant.option) next.grant_flags |= grant.privileges;
                }
                if (existing) |index| {
                    const old = &self.catalog_objects.items[index];
                    if (old.flags == next.flags and old.grant_flags == next.grant_flags) continue;
                    self.objectDelete(slot, index, snap);
                } else if (next.flags == 0) continue;
                if (next.flags != 0) _ = try self.objectInsert(slot, &next, false, snap);
            }
        }

        // -- row-level security ------------------------------------------------

        /// Canonical text of a policy expression over table `table_slot`
        /// (bound like a CHECK constraint: boolean, no subqueries).
        fn policyText(self: *Self, table_slot: usize, text: []const u8, snap: Snapshot, out: *Text) Error!void {
            const context = self.bindContext(text, .standard, snap);
            const id = try B.bindPolicyText(&context, text, table_slot);
            try G.column(&self.workspace.nodes, text, id, .boolean, out);
        }

        /// The policy expressions a policy command allows (42601 otherwise).
        fn policyShape(command: CO.Command, has_using: bool, has_check: bool) Error!void {
            if (command == .insert and has_using) return error.Syntax;
            if ((command == .select or command == .delete) and has_check) return error.Syntax;
        }

        fn policyRoles(self: *const Self, source: []const u8, policy: *const CO.Policy, out: *O.Object, snap: Snapshot) Error!void {
            if (policy.role_count > O.role_capacity) return error.ProgramLimitExceeded;
            out.role_count = 0;
            for (policy.roles[0..policy.role_count]) |grantee| {
                out.roles[out.role_count] = try self.objectRole(source, grantee, snap);
                out.role_count += 1;
            }
            if (out.role_count == 0) {
                out.roles[0] = CO.public_role;
                out.role_count = 1;
            }
        }

        fn policyExpressions(self: *Self, source: []const u8, table_slot: usize, policy: *const CO.Policy, out: *O.Object, snap: Snapshot) Error!void {
            var using: Text = .{};
            var check: Text = .{};
            if (policy.has_using) try self.policyText(table_slot, source[policy.using.start..][0..policy.using.len], snap, &using);
            if (policy.has_check) try self.policyText(table_slot, source[policy.check.start..][0..policy.check.len], snap, &check);
            // Unchanged expressions keep their stored text (ALTER POLICY).
            var buffer: [O.text_capacity]u8 = undefined;
            const using_bytes = if (policy.has_using) using.slice() else out.usingText();
            if (using_bytes.len > buffer.len) return error.TextCapacity;
            @memcpy(buffer[0..using_bytes.len], using_bytes);
            const check_bytes = if (policy.has_check) check.slice() else out.checkText();
            if (check_bytes.len > buffer.len - using_bytes.len) return error.TextCapacity;
            @memcpy(buffer[using_bytes.len..][0..check_bytes.len], check_bytes);
            if (policy.has_using) out.flags |= CO.policy_using;
            if (policy.has_check) out.flags |= CO.policy_check;
            try out.setText(buffer[0..using_bytes.len], buffer[using_bytes.len..][0..check_bytes.len]);
        }

        /// CREATE POLICY: the table owner (42501), a new name on the table
        /// (42710); USING / WITH CHECK bound over the table's row.
        fn createPolicy(self: *Self, slot: u16, source: []const u8, policy: *const CO.Policy, snap: Snapshot) Error!void {
            const table_slot = try self.objectTable(slot, source, policy.table, .access_exclusive, snap);
            const table = &self.tables[table_slot];
            if (table.relkind != 'r' and table.relkind != 'p') return error.WrongObjectType;
            if (!self.catalog_objects.ownsTable(self.session.role, table.oid, snap)) return error.InsufficientPrivilege;
            try policyShape(policy.command, policy.has_using, policy.has_check);
            var object: O.Object = .{ .kind = .policy, .target = table.oid, .flags = @intFromEnum(policy.command) | (if (policy.permissive) CO.policy_permissive else 0) };
            try object.setName(objectName(source, policy.name).slice());
            if (self.catalog_objects.byName(.policy, table.oid, object.name.slice(), snap) != null) return error.DuplicateObject;
            if (self.catalog_objects.pendingConflict(&object, snap)) |other| return self.objectPark(slot, other);
            try self.policyRoles(source, policy, &object, snap);
            try self.policyExpressions(source, table_slot, policy, &object, snap);
            try self.reserveWrites(slot, 1);
            _ = try self.objectInsert(slot, &object, true, snap);
        }

        fn findPolicy(self: *Self, slot: u16, source: []const u8, policy: *const CO.Policy, snap: Snapshot) Error!?struct { table: usize, index: usize } {
            const table_slot = try self.objectTable(slot, source, policy.table, .access_exclusive, snap);
            const table = &self.tables[table_slot];
            const index = self.catalog_objects.byName(.policy, table.oid, objectName(source, policy.name).slice(), snap) orelse {
                if (policy.if_exists) return null;
                return error.UndefinedObject;
            };
            if (!self.catalog_objects.ownsTable(self.session.role, table.oid, snap)) return error.InsufficientPrivilege;
            if (self.catalog_objects.pendingConflict(&self.catalog_objects.items[index], snap)) |other| return self.objectPark(slot, other);
            return .{ .table = table_slot, .index = index };
        }

        fn alterPolicy(self: *Self, slot: u16, source: []const u8, policy: *const CO.Policy, snap: Snapshot) Error!void {
            const found = (try self.findPolicy(slot, source, policy, snap)).?;
            var next = self.catalog_objects.items[found.index];
            if (policy.rename) {
                const new_name = objectName(source, policy.new_name);
                if (self.catalog_objects.byName(.policy, next.target, new_name.slice(), snap) != null) return error.DuplicateObject;
                try next.setName(new_name.slice());
                if (self.catalog_objects.pendingConflict(&next, snap)) |other| return self.objectPark(slot, other);
            } else {
                const command: CO.Command = @enumFromInt(@as(u8, @truncate(next.flags)));
                try policyShape(command, policy.has_using, policy.has_check);
                if (policy.role_count != 0) try self.policyRoles(source, policy, &next, snap);
                try self.policyExpressions(source, found.table, policy, &next, snap);
            }
            try self.reserveWrites(slot, 2);
            self.objectDelete(slot, found.index, snap);
            _ = try self.objectInsert(slot, &next, false, snap);
        }

        fn dropPolicy(self: *Self, slot: u16, source: []const u8, policy: *const CO.Policy, snap: Snapshot) Error!void {
            const found = (try self.findPolicy(slot, source, policy, snap)) orelse return;
            const oid = self.catalog_objects.items[found.index].oid;
            if (self.catalog_objects.pendingReference(oid, snap)) |other| return self.objectPark(slot, other);
            try self.reserveWrites(slot, 2);
            self.objectDelete(slot, found.index, snap);
            const comment: O.Object = .{ .kind = .comment, .grantee = CO.class_policy, .target = oid };
            if (self.catalog_objects.findKey(&comment, snap)) |index| self.objectDelete(slot, index, snap);
        }

        /// ALTER TABLE ... ENABLE / DISABLE / [NO] FORCE ROW LEVEL SECURITY
        /// (the owner) and OWNER TO (superusers): the table's relation entry.
        fn tableSecurity(self: *Self, slot: u16, source: []const u8, security: *const CO.TableSecurity, snap: Snapshot) Error!void {
            const table_slot = self.objectTable(slot, source, security.table, .access_exclusive, snap) catch |err| {
                if (err == error.TableNotFound and security.if_exists) return;
                return err;
            };
            const table = &self.tables[table_slot];
            const oid = table.oid;
            if (security.action != .owner and table.relkind != 'r' and table.relkind != 'p') return error.WrongObjectType;
            if (!self.catalog_objects.ownsTable(self.session.role, oid, snap)) return error.InsufficientPrivilege;
            const key: O.Object = .{ .kind = .relation, .target = oid };
            if (self.catalog_objects.pendingConflict(&key, snap)) |other| return self.objectPark(slot, other);
            const existing = self.catalog_objects.relation(oid, snap);
            const old_owner = self.catalog_objects.owner(oid, snap);
            var owner = old_owner;
            var flags = self.catalog_objects.securityFlags(oid, snap);
            switch (security.action) {
                .enable => flags |= CO.rls_enabled,
                .disable => flags &= ~CO.rls_enabled,
                .force => flags |= CO.rls_forced,
                .no_force => flags &= ~CO.rls_forced,
                .owner => {
                    if (!self.privilegedRole(snap)) return error.InsufficientPrivilege;
                    owner = try self.objectRole(source, security.owner, snap);
                },
            }
            if (owner == old_owner and flags == self.catalog_objects.securityFlags(oid, snap)) return;
            // Grants recorded by the old owner move to the new one (aclnewowner).
            var grants: usize = 0;
            if (owner != old_owner) {
                for (&self.catalog_objects.items) |*o| {
                    if (o.kind == .acl and o.target == oid and o.owner == old_owner and O.visible(o, snap)) grants += 1;
                }
            }
            try self.reserveWrites(slot, 2 + 2 * grants);
            if (existing) |index| self.objectDelete(slot, index, snap);
            if (owner != CO.bootstrap_role or flags != 0) {
                var next: O.Object = .{ .kind = .relation, .target = oid, .owner = owner, .flags = flags };
                _ = try self.objectInsert(slot, &next, false, snap);
            }
            if (grants != 0) {
                for (0..self.catalog_objects.items.len) |index| {
                    const o = &self.catalog_objects.items[index];
                    if (o.kind != .acl or o.target != oid or o.owner != old_owner or !O.visible(o, snap) or o.xmax.epoch != 0) continue;
                    if (o.xmin_csn == 0 and o.xmin_cid == snap.cid) continue;
                    var next = o.*;
                    next.owner = owner;
                    self.objectDelete(slot, index, snap);
                    _ = try self.objectInsert(slot, &next, false, snap);
                }
            }
        }

        // -- comments ----------------------------------------------------------

        /// COMMENT ON ... IS 'text' | NULL (an empty text removes it too).
        fn commentOn(self: *Self, slot: u16, source: []const u8, comment: *const CO.Comment, snap: Snapshot) Error!void {
            var key: O.Object = .{ .kind = .comment };
            const role = self.session.role;
            const privileged = self.privilegedRole(snap);
            switch (comment.target) {
                .table, .view, .materialized_view, .column => {
                    const table_slot = try self.objectTable(slot, source, comment.object, .access_share, snap);
                    const table = &self.tables[table_slot];
                    const kind_ok = switch (comment.target) {
                        .table => table.relkind == 'r' or table.relkind == 'p',
                        .view => table.relkind == 'v',
                        .materialized_view => table.relkind == 'm',
                        else => true,
                    };
                    if (!kind_ok) return error.WrongObjectType;
                    if (!self.catalog_objects.ownsTable(role, table.oid, snap)) return error.InsufficientPrivilege;
                    key.grantee = CO.class_relation;
                    key.target = table.oid;
                    if (comment.target == .column) {
                        const column_name = objectName(source, comment.column);
                        var position: ?usize = null;
                        for (table.columns[0..table.column_count], 0..) |*column, index| {
                            if (types.same(column.name.slice(), column_name.slice())) position = index;
                        }
                        key.sub = @intCast((position orelse return error.ColumnNotFound) + 1);
                    }
                },
                .sequence => {
                    const schema_name = if (comment.object.has_schema) objectName(source, comment.object.schema) else Name{};
                    const namespace = namespaceFor(&self.catalog, if (comment.object.has_schema) schema_name.slice() else null, snap) orelse return error.UndefinedSchema;
                    const found = self.catalog.findIn(namespace, objectName(source, comment.object.name).slice(), snap) orelse return error.TableNotFound;
                    if (found.kind != 'S') return error.WrongObjectType;
                    if (!privileged) return error.InsufficientPrivilege;
                    key.grantee = CO.class_relation;
                    key.target = self.seqs[found.slot].oid;
                },
                .index, .extension => return error.UnsupportedStatement,
                .foreign_table => return error.TableNotFound,
                .schema => {
                    key.grantee = CO.class_namespace;
                    key.target = namespaceFor(&self.catalog, objectName(source, comment.object.name).slice(), snap) orelse return error.UndefinedSchema;
                    if (!privileged) return error.InsufficientPrivilege;
                },
                .role => {
                    key.grantee = CO.class_authid;
                    key.target = self.catalog_objects.roleByName(objectName(source, comment.object.name).slice(), snap) orelse return error.UndefinedObject;
                    if (!privileged and (self.actorFlags(snap) & CO.role_createrole == 0 or !self.roleAdmin(role, key.target, snap))) return error.InsufficientPrivilege;
                },
                .policy => {
                    const table_slot = try self.objectTable(slot, source, comment.on, .access_share, snap);
                    const table = &self.tables[table_slot];
                    const index = self.catalog_objects.byName(.policy, table.oid, objectName(source, comment.object.name).slice(), snap) orelse return error.UndefinedObject;
                    if (!self.catalog_objects.ownsTable(role, table.oid, snap)) return error.InsufficientPrivilege;
                    key.grantee = CO.class_policy;
                    key.target = self.catalog_objects.items[index].oid;
                },
                .fdw, .server, .publication => {
                    const kind: CO.Kind = switch (comment.target) {
                        .fdw => .fdw,
                        .server => .server,
                        else => .publication,
                    };
                    const index = self.catalog_objects.byName(kind, 0, objectName(source, comment.object.name).slice(), snap) orelse return error.UndefinedObject;
                    if (!privileged and !self.catalog_objects.memberOf(role, self.catalog_objects.items[index].owner, true, snap)) return error.InsufficientPrivilege;
                    key.grantee = switch (kind) {
                        .fdw => CO.class_fdw,
                        .server => CO.class_server,
                        else => CO.class_publication,
                    };
                    key.target = self.catalog_objects.items[index].oid;
                },
            }
            if (comment.has_text) {
                if (comment.text.len > O.text_capacity) return error.TextCapacity;
                lexer.decodeQuoted(source, comment.text, key.text[0..comment.text.len]);
                key.text_len = @intCast(comment.text.len);
            }
            if (self.catalog_objects.pendingConflict(&key, snap)) |other| return self.objectPark(slot, other);
            if (key.grantee != CO.class_relation and key.grantee != CO.class_namespace) {
                if (self.catalog_objects.pendingReference(key.target, snap)) |other| return self.objectPark(slot, other);
            }
            try self.reserveWrites(slot, 2);
            if (self.catalog_objects.findKey(&key, snap)) |index| {
                if (self.catalog_objects.items[index].xmax.epoch == 0) self.objectDelete(slot, index, snap);
            }
            if (key.text_len != 0) _ = try self.objectInsert(slot, &key, false, snap);
        }

        // -- foreign-data wrappers, servers, publications ------------------------

        /// CREATE FOREIGN DATA WRAPPER (superusers) / CREATE SERVER (USAGE on
        /// the wrapper: its owner or a superuser). Catalog entries only:
        /// there are no handlers, user mappings or foreign tables.
        fn createNamed(self: *Self, slot: u16, source: []const u8, kind: CO.Kind, ident: CO.Ident, if_not_exists: bool, server: ?*const CO.Server, snap: Snapshot) Error!void {
            var object: O.Object = .{ .kind = kind, .owner = self.session.role };
            try object.setName(objectName(source, ident).slice());
            if (self.catalog_objects.byName(kind, 0, object.name.slice(), snap) != null) {
                if (if_not_exists) return;
                return error.DuplicateObject;
            }
            if (kind == .fdw and !self.privilegedRole(snap)) return error.InsufficientPrivilege;
            if (server) |spec| {
                const fdw = self.catalog_objects.byName(.fdw, 0, objectName(source, spec.fdw).slice(), snap) orelse return error.UndefinedObject;
                object.target = self.catalog_objects.items[fdw].oid;
                if (!self.privilegedRole(snap) and !self.catalog_objects.memberOf(self.session.role, self.catalog_objects.items[fdw].owner, true, snap)) return error.InsufficientPrivilege;
                var first: Text = .{};
                var second: Text = .{};
                if (spec.has_type) {
                    if (spec.server_type.len > config.text_bytes) return error.TextCapacity;
                    lexer.decodeQuoted(source, spec.server_type, first.bytes[0..spec.server_type.len]);
                    first.len = spec.server_type.len;
                    object.flags |= CO.server_type;
                }
                if (spec.has_version) {
                    if (spec.version.len > config.text_bytes) return error.TextCapacity;
                    lexer.decodeQuoted(source, spec.version, second.bytes[0..spec.version.len]);
                    second.len = spec.version.len;
                    object.flags |= CO.server_version;
                }
                // srvtype / srvversion may be empty strings: never ambiguous
                // with NULL because the flags say which are present.
                try object.setText(first.slice(), second.slice());
                if (self.catalog_objects.pendingReference(object.target, snap)) |other| return self.objectPark(slot, other);
            }
            if (self.catalog_objects.pendingConflict(&object, snap)) |other| return self.objectPark(slot, other);
            try self.reserveWrites(slot, 1);
            _ = try self.objectInsert(slot, &object, true, snap);
        }

        /// CREATE PUBLICATION (superusers: the database's CREATE privilege
        /// belongs to its owner). Catalog entry only: no logical decoding.
        fn createPublication(self: *Self, slot: u16, source: []const u8, publication: *const CO.Publication, snap: Snapshot) Error!void {
            if (!self.privilegedRole(snap)) return error.InsufficientPrivilege;
            var object: O.Object = .{ .kind = .publication, .owner = self.session.role, .flags = publication.flags };
            try object.setName(objectName(source, publication.name).slice());
            if (self.catalog_objects.byName(.publication, 0, object.name.slice(), snap) != null) return error.DuplicateObject;
            if (self.catalog_objects.pendingConflict(&object, snap)) |other| return self.objectPark(slot, other);
            try self.reserveWrites(slot, 1);
            _ = try self.objectInsert(slot, &object, true, snap);
        }

        /// DROP FOREIGN DATA WRAPPER / SERVER / PUBLICATION: the owner or a
        /// superuser; a wrapper with servers is 2BP01 unless CASCADE.
        fn dropNamed(self: *Self, slot: u16, source: []const u8, kind: CO.Kind, drop: *const CO.Drop, snap: Snapshot) Error!void {
            var victims: [CO.list_capacity]usize = undefined;
            var count: usize = 0;
            var writes: usize = 0;
            for (drop.names[0..drop.count]) |ident| {
                const index = self.catalog_objects.byName(kind, 0, objectName(source, ident).slice(), snap) orelse {
                    if (drop.if_exists) continue;
                    return error.UndefinedObject;
                };
                const o = &self.catalog_objects.items[index];
                if (!self.privilegedRole(snap) and !self.catalog_objects.memberOf(self.session.role, o.owner, true, snap)) return error.InsufficientPrivilege;
                var known = false;
                for (victims[0..count]) |seen| known = known or seen == index;
                if (known) continue;
                if (self.catalog_objects.pendingConflict(o, snap)) |other| return self.objectPark(slot, other);
                if (self.catalog_objects.pendingReference(o.oid, snap)) |other| return self.objectPark(slot, other);
                for (&self.catalog_objects.items) |*other| {
                    if (!O.visible(other, snap)) continue;
                    if (other.kind == .comment and other.target == o.oid) writes += 1;
                    if (kind == .fdw and other.kind == .server and other.target == o.oid) {
                        if (!drop.cascade) return error.DependentObjects;
                        if (self.catalog_objects.pendingReference(other.oid, snap)) |waiter| return self.objectPark(slot, waiter);
                        writes += 2;
                    }
                }
                victims[count] = index;
                count += 1;
                writes += 1;
            }
            try self.reserveWrites(slot, writes);
            for (victims[0..count]) |index| {
                const oid = self.catalog_objects.items[index].oid;
                for (&self.catalog_objects.items, 0..) |*other, position| {
                    if (!O.visible(other, snap) or other.xmax.epoch != 0) continue;
                    if (kind == .fdw and other.kind == .server and other.target == oid) {
                        const server_oid = other.oid;
                        self.objectDelete(slot, position, snap);
                        for (&self.catalog_objects.items, 0..) |*c, at| if (c.kind == .comment and c.target == server_oid and O.visible(c, snap) and c.xmax.epoch == 0) {
                            self.objectDelete(slot, at, snap);
                        };
                    }
                }
                for (&self.catalog_objects.items, 0..) |*c, at| if (c.kind == .comment and c.target == oid and O.visible(c, snap) and c.xmax.epoch == 0) {
                    self.objectDelete(slot, at, snap);
                };
                self.objectDelete(slot, index, snap);
            }
        }

        // -- privileges and row security of ordinary statements ---------------

        fn needTable(self: *const Self, table_slot: usize, wanted: u32, snap: Snapshot) Error!void {
            if (!self.catalog_objects.tablePrivileges(self.session.role, self.tables[table_slot].oid, wanted, snap)) return error.InsufficientPrivilege;
        }

        fn needOwner(self: *const Self, table_slot: usize, snap: Snapshot) Error!void {
            if (!self.catalog_objects.ownsTable(self.session.role, self.tables[table_slot].oid, snap)) return error.InsufficientPrivilege;
        }

        fn insertPrivileges(self: *const Self, insert: *const B.Insert, snap: Snapshot) Error!void {
            var wanted: u32 = CO.priv_insert;
            if (insert.returning.count != 0) wanted |= CO.priv_select;
            if (insert.conflict.action == .update) wanted |= CO.priv_update;
            try self.needTable(insert.table, wanted, snap);
        }

        /// UPDATE / DELETE read the rows they change when they filter or
        /// return them (SELECT privilege, as column reads in PostgreSQL).
        fn changePrivileges(self: *const Self, table_slot: usize, privilege: u32, where: u16, returning: usize, snap: Snapshot) Error!void {
            var wanted = privilege;
            if (where != ast.none or returning != 0) wanted |= CO.priv_select;
            try self.needTable(table_slot, wanted, snap);
        }

        /// Table privileges of a bound statement for a role that is not a
        /// superuser (FROM items were checked while expanding relations).
        /// Creating objects needs CREATE on a schema, which only superusers
        /// hold here (PostgreSQL 15+ public schema); altering or dropping a
        /// relation needs its ownership.
        fn checkPrivileges(self: *const Self, bound: *const B.Bound, snap: Snapshot) Error!void {
            if (self.privilegedRole(snap)) return;
            switch (bound.*) {
                .insert => |*insert| try self.insertPrivileges(insert, snap),
                .update => |*update| try self.changePrivileges(update.table, CO.priv_update, update.where, update.returning.count, snap),
                .delete => |*delete| try self.changePrivileges(delete.table, CO.priv_delete, delete.where, delete.returning.count, snap),
                .query => {
                    const plans = &self.workspace.plans;
                    for (plans.dml[0..plans.dml_len]) |*dml| switch (dml.*) {
                        .insert => |*insert| try self.insertPrivileges(insert, snap),
                        .update => |*update| try self.changePrivileges(update.table, CO.priv_update, update.where, update.returning.count, snap),
                        .delete => |*delete| try self.changePrivileges(delete.table, CO.priv_delete, delete.where, delete.returning.count, snap),
                    };
                },
                .truncate => |*truncate| {
                    for (truncate.tables[0..truncate.count]) |table_slot| try self.needTable(table_slot, CO.priv_truncate, snap);
                },
                .merge => |*merge| {
                    var wanted: u32 = CO.priv_select;
                    for (merge.whens[0..merge.when_count]) |*when| wanted |= switch (when.action) {
                        .update => CO.priv_update,
                        .delete => CO.priv_delete,
                        .insert => CO.priv_insert,
                        .nothing => 0,
                    };
                    try self.needTable(merge.table, wanted, snap);
                },
                .drop_table => |table_slot| try self.needOwner(table_slot, snap),
                .drop_relation => |*drop| try self.needOwner(drop.slot, snap),
                .alter_table => |*alter| try self.needOwner(alter.table, snap),
                .refresh_view => |*refresh| try self.needOwner(refresh.slot, snap),
                .create_table, .create_sequence, .drop_sequence, .alter_sequence, .create_schema, .drop_schema => return error.InsufficientPrivilege,
                else => {},
            }
        }

        /// The workspace copy of the statement (after its expansions),
        /// with room to append row-security text.
        fn securedSource(self: *Self, source: []const u8, original: []const u8, length: *usize) Error!void {
            if (source.ptr == &self.workspace.expansion) {
                length.* = source.len;
                return;
            }
            if (original.len > self.workspace.expansion.len) return error.TextCapacity;
            @memcpy(self.workspace.expansion[0..original.len], original);
            length.* = original.len;
        }

        /// UPDATE / DELETE targets under row security: the command's USING
        /// expressions (and SELECT's when the statement reads the rows) are
        /// AND-ed into WHERE before binding.
        fn secureTarget(self: *Self, statement_copy: *A.Statement, source: []const u8, original: []const u8, snap: Snapshot) Error![]const u8 {
            const role = self.session.role;
            if (self.privilegedRole(snap)) return source;
            const goal: struct { schema: ?ast.Ident, table: ast.Ident, where: *u16, command: CO.Command, reads: bool } = switch (statement_copy.*) {
                .update => |*update| .{ .schema = update.schema, .table = update.table, .where = &update.where, .command = .update, .reads = update.where != ast.none or update.returning.count != 0 },
                .delete => |*delete| .{ .schema = delete.schema, .table = delete.table, .where = &delete.where, .command = .delete, .reads = delete.where != ast.none or delete.returning.count != 0 },
                else => return source,
            };
            const schema_name = if (goal.schema) |qualifier| identName(source, qualifier) else Name{};
            const namespace = namespaceFor(&self.catalog, if (goal.schema != null) schema_name.slice() else null, snap) orelse return source;
            const found = self.catalog.findIn(namespace, identName(source, goal.table).slice(), snap) orelse return source;
            if (found.kind != 'r' and found.kind != 'p') return source;
            const table = &self.tables[found.slot];
            if (!self.catalog_objects.rowSecurity(role, table.oid, snap)) return source;
            if (table.relkind == 'p' or self.hasChildren(table.oid, snap)) return error.UnsupportedStatement;
            var length: usize = 0;
            try self.securedSource(source, original, &length);
            var text: CO.Appender = .{ .out = &self.workspace.expansion, .len = &length };
            try text.add(" ");
            const start = length;
            try self.catalog_objects.securityText(role, table.oid, goal.command, false, snap, &self.workspace.expansion, &length);
            if (goal.reads) {
                try text.add(" AND ");
                try self.catalog_objects.securityText(role, table.oid, .select, false, snap, &self.workspace.expansion, &length);
            }
            const id = try P.parseExpressionAt(self.workspace.expansion[0..length], start, length, &self.workspace.nodes);
            goal.where.* = if (goal.where.* == ast.none) id else try self.workspace.nodes.add(.{ .kind = .and_op, .a = id, .b = goal.where.* });
            return self.workspace.expansion[0..length];
        }

        /// INSERT / UPDATE new rows under row security: the WITH CHECK
        /// expressions (USING where a policy has none) bound over the
        /// table's row, checked for every new row (42501 unless true).
        fn secureNewRows(self: *Self, bound: *const B.Bound, source: []const u8, snap: Snapshot) Error!void {
            self.workspace.security_check = ast.none;
            const role = self.session.role;
            if (self.privilegedRole(snap)) return;
            const goal: struct { table: usize, command: CO.Command } = switch (bound.*) {
                .insert => |*insert| .{ .table = insert.table, .command = .insert },
                .update => |*update| .{ .table = update.table, .command = .update },
                .merge => |*merge| {
                    if (self.catalog_objects.rowSecurity(role, self.tables[merge.table].oid, snap)) return error.UnsupportedStatement;
                    return;
                },
                .query => {
                    const plans = &self.workspace.plans;
                    for (plans.dml[0..plans.dml_len]) |*dml| {
                        const table_slot = switch (dml.*) {
                            .insert => |*insert| insert.table,
                            .update => |*update| update.table,
                            .delete => |*delete| delete.table,
                        };
                        if (self.catalog_objects.rowSecurity(role, self.tables[table_slot].oid, snap)) return error.UnsupportedStatement;
                    }
                    return;
                },
                else => return,
            };
            const oid = self.tables[goal.table].oid;
            if (!self.catalog_objects.rowSecurity(role, oid, snap)) return;
            if (bound.* == .insert and bound.insert.conflict.action != .none) return error.UnsupportedStatement;
            var length: usize = 0;
            try self.securedSource(source, source, &length);
            const start = length;
            try self.catalog_objects.securityText(role, oid, goal.command, true, snap, &self.workspace.expansion, &length);
            const text = self.workspace.expansion[start..length];
            const context = self.bindContext(text, .standard, snap);
            self.workspace.security_check = try B.bindPolicyText(&context, text, goal.table);
            self.workspace.security_start = start;
            self.workspace.security_len = length - start;
            self.workspace.security_table = goal.table;
        }

        /// The new row of the statement's INSERT / UPDATE target passes its
        /// row-security WITH CHECK expression.
        fn securityCheck(self: *Self, ctx: *const E.Context, table_slot: usize, cells: *const E.Row) Error!void {
            const id = self.workspace.security_check;
            if (id == ast.none or table_slot != self.workspace.security_table) return;
            var sub = ctx.*;
            sub.source = self.workspace.expansion[self.workspace.security_start..][0..self.workspace.security_len];
            sub.row = cells;
            const verdict = try E.eval(&sub, id);
            if (verdict != .boolean or !verdict.boolean) return error.InsufficientPrivilege;
        }

        /// SELECT privilege and row security of one FROM item the statement
        /// names (not one a view or an expansion introduced: those run with
        /// the view owner's rights, the bootstrap superuser). Returns the
        /// derived query replacing it under row security, or none.
        fn secureItem(db: *const Self, workspace: *Workspace, length: *usize, source: []const u8, role: u32, found: K.Found, snap: Snapshot) Error!u16 {
            if (found.kind == 'S') return error.InsufficientPrivilege;
            const table = &db.tables[found.slot];
            if (!db.catalog_objects.tablePrivileges(role, table.oid, CO.priv_select, snap)) return error.InsufficientPrivilege;
            if (table.relkind != 'r' and table.relkind != 'p') return ast.none;
            if (!db.catalog_objects.rowSecurity(role, table.oid, snap)) return ast.none;
            if (table.relkind == 'p' or db.hasChildren(table.oid, snap)) return error.UnsupportedStatement;
            if (length.* == 0) {
                if (source.len > workspace.expansion.len) return error.TextCapacity;
                @memcpy(workspace.expansion[0..source.len], source);
                length.* = source.len;
            }
            var text: CO.Appender = .{ .out = &workspace.expansion, .len = length };
            try text.add(" ");
            const start = length.*;
            try text.add("SELECT * FROM ONLY ");
            try text.quoted(db.namespaceName(table.namespace));
            try text.add(".");
            try text.quoted(table.name.slice());
            try text.add(" WHERE ");
            try db.catalog_objects.securityText(role, table.oid, .select, false, snap, &workspace.expansion, length);
            return P.parseQueryAt(workspace.expansion[0..length.*], start, length.*, &workspace.nodes);
        }

        /// catalog_text hook: comments and role names under the statement
        /// snapshot.
        fn catalogText(ptr: *anyopaque, kind: value_module.CatalogText, object: u32, classoid: u32, sub: i32, out: []u8) Error!?usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const snap = self.seq_snap;
            const text: []const u8 = switch (kind) {
                .role_name => self.catalog_objects.roleName(object, snap) orelse return null,
                .description => self.catalog_objects.description(object, classoid, sub, snap) orelse return null,
                .shared_description => if (classoid == CO.class_authid) self.catalog_objects.description(object, classoid, 0, snap) orelse return null else return null,
            };
            if (text.len > out.len) return error.TextCapacity;
            @memcpy(out[0..text.len], text);
            return text.len;
        }

        /// Rows of the catalog-object system views.
        fn catalogObjectRows(self: *const Self, session_values: *const value_module.Session, snapshot: Snapshot, view: catalog_module.View, sink: *X.RowSink) Error!void {
            const database = session_values.database;
            switch (view) {
                .pg_roles, .pg_authid => {
                    // The bootstrap superuser first, then roles in catalog order.
                    var bootstrap: O.Object = .{ .kind = .role, .oid = CO.bootstrap_role, .flags = CO.role_attributes, .grant_flags = @bitCast(@as(i32, -1)) };
                    bootstrap.setName(CO.bootstrap_name) catch {};
                    try self.roleRow(view, &bootstrap, sink);
                    for (&self.catalog_objects.items) |*o| if (o.kind == .role and O.visible(o, snapshot)) try self.roleRow(view, o, sink);
                },
                .pg_auth_members => for (&self.catalog_objects.items) |*o| if (o.kind == .member and O.visible(o, snapshot)) {
                    try sink.add(&.{ intCell(o.oid), intCell(o.target), intCell(o.grantee), intCell(o.owner), boolCell(o.grant_flags & 1 != 0), boolCell(true), boolCell(true) });
                },
                .pg_policy, .pg_policies => for (&self.catalog_objects.items) |*o| if (o.kind == .policy and O.visible(o, snapshot)) {
                    const command: CO.Command = @enumFromInt(@as(u8, @truncate(o.flags)));
                    const qual: Cell = if (o.flags & CO.policy_using != 0) try objectTextCell(o.usingText()) else .null_value;
                    const check: Cell = if (o.flags & CO.policy_check != 0) try objectTextCell(o.checkText()) else .null_value;
                    if (view == .pg_policy) {
                        const code: []const u8 = switch (command) {
                            .all => "*",
                            .select => "r",
                            .insert => "a",
                            .update => "w",
                            .delete => "d",
                        };
                        try sink.add(&.{ intCell(o.oid), nameCell(o.name.slice()), intCell(o.target), nameCell(code), boolCell(o.flags & CO.policy_permissive != 0), try self.roleArray(o, false, snapshot), qual, check });
                        continue;
                    }
                    const table_slot = self.visibleTableSlot(o.target, snapshot) orelse continue;
                    const table = &self.tables[table_slot];
                    const cmd: []const u8 = switch (command) {
                        .all => "ALL",
                        .select => "SELECT",
                        .insert => "INSERT",
                        .update => "UPDATE",
                        .delete => "DELETE",
                    };
                    try sink.add(&.{ nameCell(self.namespaceName(table.namespace)), nameCell(table.name.slice()), nameCell(o.name.slice()), nameCell(if (o.flags & CO.policy_permissive != 0) "PERMISSIVE" else "RESTRICTIVE"), try self.roleArray(o, true, snapshot), nameCell(cmd), qual, check });
                },
                .pg_description, .pg_shdescription => for (&self.catalog_objects.items) |*o| if (o.kind == .comment and O.visible(o, snapshot)) {
                    const shared = o.grantee == CO.class_authid;
                    if (shared != (view == .pg_shdescription)) continue;
                    const text = try objectTextCell(o.textSlice());
                    if (shared) try sink.add(&.{ intCell(o.target), intCell(o.grantee), text }) else try sink.add(&.{ intCell(o.target), intCell(o.grantee), intCell(o.sub), text });
                },
                .pg_foreign_data_wrapper => for (&self.catalog_objects.items) |*o| if (o.kind == .fdw and O.visible(o, snapshot)) {
                    try sink.add(&.{ intCell(o.oid), nameCell(o.name.slice()), intCell(o.owner), intCell(0), intCell(0), .null_value, .null_value });
                },
                .pg_foreign_server => for (&self.catalog_objects.items) |*o| if (o.kind == .server and O.visible(o, snapshot)) {
                    const server_type: Cell = if (o.flags & CO.server_type != 0) nameCell(o.usingText()) else .null_value;
                    const version: Cell = if (o.flags & CO.server_version != 0) nameCell(o.checkText()) else .null_value;
                    try sink.add(&.{ intCell(o.oid), nameCell(o.name.slice()), intCell(o.owner), intCell(o.target), server_type, version, .null_value, .null_value });
                },
                .pg_publication => for (&self.catalog_objects.items) |*o| if (o.kind == .publication and O.visible(o, snapshot)) {
                    const flags = o.flags;
                    try sink.add(&.{ intCell(o.oid), nameCell(o.name.slice()), intCell(o.owner), boolCell(flags & CO.pub_all_tables != 0), boolCell(flags & CO.pub_insert != 0), boolCell(flags & CO.pub_update != 0), boolCell(flags & CO.pub_delete != 0), boolCell(flags & CO.pub_truncate != 0), boolCell(flags & CO.pub_via_root != 0), nameCell("n") });
                },
                .pg_extension => try sink.add(&.{ intCell(CO.plpgsql_extension_oid), nameCell("plpgsql"), intCell(CO.bootstrap_role), intCell(catalog_module.catalog_namespace), boolCell(false), nameCell("1.0"), .null_value, .null_value }),
                .pg_tables, .table_privileges => {
                    var relations: [K.relation_rows]K.Found = undefined;
                    const count = self.catalog.visibleRelations(snapshot, &relations);
                    for (relations[0..count]) |found| {
                        if (found.kind == 'S') continue;
                        const table = &self.tables[found.slot];
                        if (table.relkind != 'r' and table.relkind != 'p' and view == .pg_tables) continue;
                        const owner = self.catalog_objects.owner(table.oid, snapshot);
                        const owner_name = self.catalog_objects.roleName(owner, snapshot) orelse "";
                        const schema_name = self.namespaceName(table.namespace);
                        if (view == .pg_tables) {
                            try sink.add(&.{ nameCell(schema_name), nameCell(table.name.slice()), nameCell(owner_name), .null_value, boolCell(S.keyed(table) or table.index_count != 0), boolCell(false), boolCell(false), boolCell(self.catalog_objects.securityFlags(table.oid, snapshot) & CO.rls_enabled != 0) });
                            continue;
                        }
                        // aclexplode(coalesce(relacl, acldefault)): the owner's
                        // privileges, then each grant, in privilege-bit order.
                        try self.privilegeRows(database, schema_name, table, owner_name, owner_name, CO.table_privileges, CO.table_privileges, sink);
                        for (&self.catalog_objects.items) |*o| if (o.kind == .acl and o.target == table.oid and O.visible(o, snapshot)) {
                            const grantor = self.catalog_objects.roleName(o.owner, snapshot) orelse "";
                            const grantee = if (o.grantee == CO.public_role) "PUBLIC" else self.catalog_objects.roleName(o.grantee, snapshot) orelse "";
                            try self.privilegeRows(database, schema_name, table, grantor, grantee, o.flags, o.grant_flags, sink);
                        };
                    }
                },
                else => {},
            }
        }

        /// Object text as a cell (54000 TextCapacity past Config.text_bytes).
        fn objectTextCell(bytes: []const u8) Error!Cell {
            if (bytes.len > config.text_bytes) return error.TextCapacity;
            return nameCell(bytes);
        }

        fn privilegeRows(self: *const Self, database: []const u8, schema_name: []const u8, table: *const S.Table, grantor: []const u8, grantee: []const u8, flags: u32, grant_flags: u32, sink: *X.RowSink) Error!void {
            _ = self;
            for (CO.privilege_bits, CO.privilege_sql) |bit, spelling| {
                if (flags & bit == 0) continue;
                try sink.add(&.{ nameCell(grantor), nameCell(grantee), nameCell(database), nameCell(schema_name), nameCell(table.name.slice()), nameCell(spelling), nameCell(if (grant_flags & bit != 0) "YES" else "NO"), nameCell(if (bit == CO.priv_select) "YES" else "NO") });
            }
        }

        fn roleRow(self: *const Self, view: catalog_module.View, o: *const O.Object, sink: *X.RowSink) Error!void {
            _ = self;
            const flags = o.flags;
            const connlimit: i32 = @bitCast(o.grant_flags);
            if (view == .pg_roles) {
                try sink.add(&.{ nameCell(o.name.slice()), boolCell(flags & CO.role_superuser != 0), boolCell(flags & CO.role_inherit != 0), boolCell(flags & CO.role_createrole != 0), boolCell(flags & CO.role_createdb != 0), boolCell(flags & CO.role_login != 0), boolCell(flags & CO.role_replication != 0), intCell(connlimit), .null_value, .null_value, boolCell(flags & CO.role_bypassrls != 0), .null_value, intCell(o.oid) });
            } else {
                try sink.add(&.{ intCell(o.oid), nameCell(o.name.slice()), boolCell(flags & CO.role_superuser != 0), boolCell(flags & CO.role_inherit != 0), boolCell(flags & CO.role_createrole != 0), boolCell(flags & CO.role_createdb != 0), boolCell(flags & CO.role_login != 0), boolCell(flags & CO.role_replication != 0), boolCell(flags & CO.role_bypassrls != 0), intCell(connlimit), .null_value, .null_value });
            }
        }

        /// polroles (oid[], 0 for PUBLIC) or pg_policies.roles (name[]).
        fn roleArray(self: *const Self, o: *const O.Object, names: bool, snap: Snapshot) Error!Cell {
            var out: Text = .{};
            var layout: array_module.Shape = .{ .element = if (names) .name else .oid, .ndim = 1 };
            layout.dims[0] = o.role_count;
            var writer = try V.Arrays.Writer.begin(&out, &layout);
            for (o.roleList()) |role| {
                const cell: Cell = if (!names) intCell(role) else if (role == CO.public_role) nameCell("public") else nameCell(self.catalog_objects.roleName(role, snap) orelse "");
                try writer.append(&cell);
            }
            return .{ .array = out };
        }

        // ---- sequences (design §4.11) ---------------------------------------

        /// CREATE SEQUENCE, or an identity column's owned sequence.
        fn createSequence(self: *Self, slot: u16, name: Name, spec: sequence_module.Spec, owner: u32, owner_column: u8, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            if (self.catalog.creator(name.slice(), snap)) |other| {
                var waits: L.Set = .{};
                waits.add(other);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            if (self.catalog.find(name.slice(), snap) != null) return error.TableExists;
            try self.reserveWrites(slot, 3);
            var destination: ?usize = null;
            for (0..2) |attempt| {
                for (&self.seqs, 0..) |*seq, index| if (!seq.live) {
                    destination = index;
                    break;
                };
                if (destination != null or attempt == 1) break;
                self.reclaimTables(self.horizon());
            }
            const index = destination orelse return error.TableCapacity;
            if (self.oid_counter >= 0xffffffff - change_log.first_oid) return error.TableCapacity;
            const seq = &self.seqs[index];
            Q.init(seq, change_log.first_oid + self.oid_counter, name, spec, owner, owner_column);
            seq.pending_create = true;
            seq.creator = slot;
            self.oid_counter += 1;
            tx.push(.{ .kind = .create_sequence, .table = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const count = try self.catalog.createSequence(index, seq, tx.ref(slot), snap.cid, 0, self.horizon(), &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_insert, .table = @intFromEnum(change.relation), .new = change.version }) catch unreachable;
        }

        fn dropSequence(self: *Self, slot: u16, index: usize, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const seq = &self.seqs[index];
            if (seq.pending_drop and seq.creator != slot) {
                // Another transaction's uncommitted DROP: wait for it.
                var waits: L.Set = .{};
                waits.add(seq.creator);
                // No schema mutation has happened yet. Rebind against the
                // committed catalog after the competing DROP finishes.
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            if (self.catalog_objects.pendingReference(seq.oid, snap)) |other| return self.objectPark(slot, other);
            try self.reserveWrites(slot, 3);
            seq.pending_drop = true;
            seq.creator = slot;
            tx.push(.{ .kind = .drop_sequence, .table = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const count = self.catalog.dropSequence(index, snap, tx.ref(slot), snap.cid, 0, &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_delete, .table = @intFromEnum(change.relation), .old = change.version }) catch unreachable;
            try self.dropObjectsOf(slot, seq.oid, snap);
        }

        /// The identity sequence of a table column visible to the statement.
        fn identitySequence(self: *const Self, table_index: usize, column: usize) Error!usize {
            const oid = self.tables[table_index].oid;
            for (&self.seqs, 0..) |*seq, index| {
                if (!seq.live or seq.owner != oid or seq.owner_column != column or seq.dead_csn != 0) continue;
                if (seq.pending_create and seq.creator != self.seq_slot) continue;
                // This transaction replaced it (ALTER SEQUENCE) or dropped it.
                if (seq.pending_drop and seq.creator == self.seq_slot) continue;
                return index;
            }
            return error.TableNotFound;
        }

        /// ALTER SEQUENCE (PostgreSQL 10+ makes it transactional): the
        /// sequence is copied into a free sequence slot with the new options
        /// and, for RESTART, the new state; the catalog swaps the relation in
        /// this transaction, as ALTER TABLE does. Other sessions' nextval
        /// waits for it (PostgreSQL's lock); abort discards the copy. The
        /// own session forgets its cached values.
        fn alterSequence(self: *Self, slot: u16, index: usize, options: sequence_module.Options, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const seq = &self.seqs[index];
            if (seq.pending_drop and seq.creator != slot) {
                var waits: L.Set = .{};
                waits.add(seq.creator);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            const altered = try sequence_module.alter(seq.spec, seq.last_value, options);
            try self.reserveWrites(slot, 5);
            var destination: ?usize = null;
            for (0..2) |attempt| {
                for (&self.seqs, 0..) |*candidate, position| if (!candidate.live) {
                    destination = position;
                    break;
                };
                if (destination != null or attempt == 1) break;
                self.reclaimTables(self.horizon());
            }
            const fresh_slot = destination orelse return error.TableCapacity;
            const copy = &self.seqs[fresh_slot];
            copy.* = seq.*;
            copy.spec = altered.spec;
            // The copy logs again before handing out a value.
            copy.log_cnt = 0;
            if (altered.restart) |value| {
                copy.last_value = value;
                copy.is_called = false;
                copy.logged_value = value;
                copy.logged_called = false;
            }
            copy.live = true;
            copy.pending_create = true;
            copy.pending_drop = false;
            copy.dead_csn = 0;
            copy.creator = slot;
            seq.pending_drop = true;
            seq.creator = slot;
            tx.push(.{ .kind = .alter_sequence, .table = @intCast(fresh_slot), .old = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            var count = self.catalog.dropSequence(index, snap, tx.ref(slot), snap.cid, 0, &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_delete, .table = @intFromEnum(change.relation), .old = change.version }) catch unreachable;
            count = try self.catalog.createSequence(fresh_slot, copy, tx.ref(slot), snap.cid, 0, self.horizon(), &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_insert, .table = @intFromEnum(change.relation), .new = change.version }) catch unreachable;
            const session = self.sequence_session orelse &self.default_sequences;
            session.forget(copy.oid);
        }

        /// regclass text input: optional `public.` qualifier, quoted names
        /// keep case, unquoted names fold to lower case.
        fn sequenceByName(self: *const Self, text: []const u8) Error!usize {
            const name = regclassName(text) orelse return error.TableNotFound;
            const found = self.catalog.find(name.slice(), self.seq_snap) orelse return error.TableNotFound;
            if (found.kind != 'S') return error.WrongObjectType;
            return found.slot;
        }

        fn sequenceByOid(self: *const Self, oid: u32) Error!usize {
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(self.seq_snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S' and self.seqs[found.slot].oid == oid) return found.slot;
                if (found.kind == 'r' and self.tables[found.slot].oid == oid) return error.WrongObjectType;
            }
            return error.TableNotFound;
        }

        /// The dot separating `schema.name` in regclass text outside double
        /// quotes, unless the schema is public (regclassName strips that).
        fn std_dot(text: []const u8) ?usize {
            var quoted = false;
            for (text, 0..) |byte, index| {
                if (byte == '"') quoted = !quoted;
                if (byte == '.' and !quoted) {
                    const head = text[0..index];
                    var trimmed = head;
                    while (trimmed.len != 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) trimmed = trimmed[1..];
                    if (types.keyword(trimmed, "public")) return null;
                    return index;
                }
            }
            return null;
        }

        fn regclassName(text: []const u8) ?Name {
            var raw = text;
            while (raw.len != 0 and (raw[0] == ' ' or raw[0] == '\t')) raw = raw[1..];
            while (raw.len != 0 and (raw[raw.len - 1] == ' ' or raw[raw.len - 1] == '\t')) raw = raw[0 .. raw.len - 1];
            if (raw.len > 7 and types.keyword(raw[0..7], "public.")) raw = raw[7..];
            var name: Name = .{};
            if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
                raw = raw[1 .. raw.len - 1];
                if (raw.len > config.name_bytes) return null;
                @memcpy(name.bytes[0..raw.len], raw);
            } else {
                if (raw.len > config.name_bytes) return null;
                for (raw, 0..) |byte, position| name.bytes[position] = types.lower(byte);
            }
            name.len = raw.len;
            return name;
        }

        /// regclass input: a visible table, its primary-key index
        /// (`<table>_pkey`) or a sequence; -1 (or 42P01) when missing.
        fn regclassOid(self: *const Self, text: []const u8, strict: bool) Error!i64 {
            const missing: Error!i64 = if (strict) error.TableNotFound else -1;
            // `schema.name` of a user schema (unquoted parts fold to lower case).
            if (std_dot(text)) |dot| {
                const schema = regclassName(text[0..dot]) orelse return missing;
                const relation = regclassName(text[dot + 1 ..]) orelse return missing;
                var schemas: [K.relation_rows]K.SchemaFound = undefined;
                const count = self.catalog.visibleSchemas(self.seq_snap, &schemas);
                for (schemas[0..count]) |found| {
                    if (!types.same(self.schemas[found.slot].name.slice(), schema.slice())) continue;
                    const hit = self.catalog.findIn(found.oid, relation.slice(), self.seq_snap) orelse return missing;
                    return if (hit.kind == 'S') self.seqs[hit.slot].oid else self.tables[hit.slot].oid;
                }
            }
            const name = regclassName(text) orelse return missing;
            if (self.catalog.find(name.slice(), self.seq_snap)) |found| {
                return if (found.kind == 'S') self.seqs[found.slot].oid else self.tables[found.slot].oid;
            }
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(self.seq_snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind != 'r') continue;
                const table = &self.tables[found.slot];
                if (!S.keyed(table)) continue;
                const index_name = indexName(table) catch continue;
                if (types.same(index_name.slice(), name.slice())) return table.oid + 1;
            }
            return missing;
        }

        /// The primary-key index (and constraint) name: CONSTRAINT name, else
        /// `<table>_pkey`.
        fn indexName(table: *const S.Table) Error!Name {
            if (S.primaryConstraint(table)) |index| return table.constraints[index].name;
            var out: Name = .{};
            for ([_][]const u8{ table.name.slice(), "_pkey" }) |part| {
                if (part.len > config.name_bytes - out.len) return error.NameCapacity;
                @memcpy(out.bytes[out.len..][0..part.len], part);
                out.len += part.len;
            }
            return out;
        }

        fn relationName(ptr: *anyopaque, oid: u32, out: *[64]u8) ?usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(self.seq_snap, &relations);
            for (relations[0..count]) |found| {
                var name: Name = undefined;
                if (found.kind == 'S') {
                    if (self.seqs[found.slot].oid != oid) continue;
                    name = self.seqs[found.slot].name;
                } else {
                    const table = &self.tables[found.slot];
                    if (table.oid == oid) {
                        name = table.name;
                    } else if (S.keyed(table) and table.oid + 1 == oid) {
                        name = indexName(table) catch return null;
                    } else continue;
                }
                if (name.len > out.len) return null;
                @memcpy(out[0..name.len], name.slice());
                return name.len;
            }
            return null;
        }

        const LiveOids = struct {
            db: *const Self,
            pub fn has(self: LiveOids, oid: u32) bool {
                for (&self.db.seqs) |*seq| if (seq.live and seq.oid == oid) return true;
                return false;
            }
        };

        fn sequenceCall(ptr: *anyopaque, kind: value_module.SequenceCall, name: []const u8, oid: u32, amount: i64, called: bool) Error!i64 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const session = self.sequence_session orelse &self.default_sequences;
            if (kind == .lastval) {
                if (session.last == 0 or !(LiveOids{ .db = self }).has(session.last)) return error.SequenceNotReady;
                return session.currval(session.last) orelse error.SequenceNotReady;
            }
            if (kind == .regclass) return self.regclassOid(name, called);
            const index = if (kind == .identity) try self.identitySequence(oid, @intCast(amount)) else if (oid != 0) try self.sequenceByOid(oid) else try self.sequenceByName(name);
            const seq = &self.seqs[index];
            const tx = &self.txs[self.seq_slot];
            // nextval/setval write the sequence: 25006 in a READ ONLY transaction.
            if (kind != .currval and tx.active and tx.read_only) return error.ReadOnlyTransaction;
            if (kind != .currval and seq.pending_drop and seq.creator != self.seq_slot and self.active(seq.creator)) {
                // Another transaction is replacing or dropping it: wait, as
                // nextval/setval wait for PostgreSQL's sequence lock.
                if (tx.running_snap == null) return error.LockNotAvailable;
                var waits: L.Set = .{};
                waits.add(seq.creator);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(self.seq_slot, waits);
            }
            switch (kind) {
                .nextval, .identity => {
                    if (seq.spec.cache > 1) {
                        if (session.cachedNext(seq.oid)) |value| return value;
                        const batch = try Q.nextCached(seq);
                        if (batch.logged) {
                            tx.seq_dirty.add(index);
                            self.seq_carried.add(index);
                        }
                        session.recordBatch(seq.oid, batch.value, batch.last, seq.spec.increment, LiveOids{ .db = self });
                        return batch.value;
                    }
                    const out = try Q.next(seq);
                    if (out.logged) {
                        tx.seq_dirty.add(index);
                        self.seq_carried.add(index);
                    }
                    session.record(seq.oid, out.value, LiveOids{ .db = self });
                    return out.value;
                },
                .currval => return session.currval(seq.oid) orelse error.SequenceNotReady,
                .setval => {
                    try Q.set(seq, amount, called);
                    session.forget(seq.oid);
                    tx.seq_dirty.add(index);
                    self.seq_carried.add(index);
                    if (called) {
                        // setval sets currval but not lastval's sequence.
                        const last = session.last;
                        session.record(seq.oid, amount, LiveOids{ .db = self });
                        session.last = last;
                    }
                    return amount;
                },
                .lastval, .regclass => unreachable,
            }
        }

        // ---- system views (design §4.10) ---------------------------------

        fn nameCell(bytes: []const u8) V.Cell {
            var text: V.Text = .{ .len = @min(bytes.len, config.text_bytes) };
            @memcpy(text.bytes[0..text.len], bytes[0..text.len]);
            return .{ .text = text };
        }

        fn intCell(value: i64) V.Cell {
            return .{ .integer = value };
        }

        fn boolCell(value: bool) V.Cell {
            return .{ .boolean = value };
        }

        fn optionalInt(value: ?i64) V.Cell {
            return if (value) |number| .{ .integer = number } else .null_value;
        }

        /// Canonical text of a column's DEFAULT / generation expression,
        /// re-parsed from its stored source into scratch pool nodes.
        fn expressionTextWithPool(pool:*A.Pool,column:*const V.Column) V.Cell {
            const saved = pool.len;
            defer pool.len = saved;
            var text: V.Text = .{};
            const source = column.expression.slice();
            const id = P.parseExpression(source, pool) catch return nameCell(source);
            G.column(pool, source, id, column.data_type, &text) catch return nameCell(source);
            return .{ .text = text };
        }

        fn numericPrecision(column: *const V.Column) [3]?i64 {
            return switch (column.data_type) {
                .smallint => .{ 16, 2, 0 },
                .integer32 => .{ 32, 2, 0 },
                .integer => .{ 64, 2, 0 },
                .real => .{ 24, 2, null },
                .double => .{ 53, 2, null },
                .numeric => if (column.typmod >= 4) .{ (column.typmod - 4) >> 16, 10, (column.typmod - 4) & 0xffff } else .{ null, 10, null },
                else => .{ null, null, null },
            };
        }

        /// information_schema character_maximum_length (_pg_char_max_length).
        fn characterMaximumLength(column: *const V.Column) ?i64 {
            return switch (column.data_type) {
                .varchar, .bpchar => if (column.typmod > 4) column.typmod - 4 else null,
                .bit, .varbit => if (column.typmod > 0) column.typmod else null,
                else => null,
            };
        }

        fn datetimePrecision(column: *const V.Column) ?i64 {
            return switch (column.data_type) {
                .date => 0,
                .timestamp, .timestamptz, .time, .timetz => if (column.typmod >= 0) column.typmod else 6,
                .interval => 6,
                else => null,
            };
        }

        fn viewRows(ptr: *anyopaque, view: catalog_module.View, sink: *X.RowSink) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.fillViewRows(&self.session,self.seq_snap,&self.workspace.nodes,view,sink);
        }
        fn fillViewRows(self:*const Self,session_values:*const value_module.Session,snapshot:Snapshot,pool:*A.Pool,view:catalog_module.View,sink:*X.RowSink) Error!void {
            const database = session_values.database;
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snapshot, &relations);
            const public: i64 = catalog_module.public_namespace;
            switch (view) {
                .pg_proc, .pg_trigger, .pg_rewrite, .pg_rules => return self.objectViewRows(snapshot, view, sink),
                .pg_type => inline for (@typeInfo(DataType).@"enum".field_names) |field| {
                    const data_type = @field(DataType, field);
                    const info = types.typeInfo(data_type);
                    var category: [1]u8 = .{info.category};
                    try sink.add(&.{ intCell(info.oid), nameCell(info.name), intCell(catalog_module.catalog_namespace), intCell(info.len), nameCell("b"), nameCell(&category), intCell(info.array), nameCell(","), nameCell(types.typeInputName(data_type)) });
                    // The type's array type (`_name`, category A).
                    if (types.arrayData(data_type)) |array_type| {
                        const array_info = types.typeInfo(array_type);
                        try sink.add(&.{ intCell(array_info.oid), nameCell(array_info.name), intCell(catalog_module.catalog_namespace), intCell(array_info.len), nameCell("b"), nameCell("A"), intCell(0), nameCell(","), nameCell(types.typeInputName(array_type)) });
                    }
                },
                .pg_roles, .pg_authid, .pg_auth_members, .pg_policy, .pg_policies, .pg_description, .pg_shdescription, .pg_foreign_data_wrapper, .pg_foreign_server, .pg_publication, .pg_extension, .pg_tables, .table_privileges => return self.catalogObjectRows(session_values, snapshot, view, sink),
                .pg_namespace, .schemata => {
                    for (catalog_module.namespaces) |namespace| {
                        if (view == .pg_namespace) try sink.add(&.{ intCell(namespace.oid), nameCell(namespace.name) }) else try sink.add(&.{ nameCell(database), nameCell(namespace.name) });
                    }
                    var schemas: [K.relation_rows]K.SchemaFound = undefined;
                    const schema_count = self.catalog.visibleSchemas(snapshot, &schemas);
                    for (schemas[0..schema_count]) |found| {
                        const schema_name = self.schemas[found.slot].name.slice();
                        if (view == .pg_namespace) try sink.add(&.{ intCell(found.oid), nameCell(schema_name) }) else try sink.add(&.{ nameCell(database), nameCell(schema_name) });
                    }
                },
                else => for (relations[0..count]) |found| {
                    if (found.kind == 'S') {
                        const seq = &self.seqs[found.slot];
                        switch (view) {
                            .pg_class => try sink.add(&.{ intCell(seq.oid), nameCell(seq.name.slice()), intCell(public), nameCell("S"), intCell(3) }),
                            .pg_sequence => try sink.add(&.{ intCell(seq.oid), intCell(seq.spec.type_oid), intCell(seq.spec.start), intCell(seq.spec.increment), intCell(seq.spec.max), intCell(seq.spec.min), intCell(seq.spec.cache), boolCell(seq.spec.cycle) }),
                            else => {},
                        }
                        continue;
                    }
                    const table = &self.tables[found.slot];
                    const schema_name = self.namespaceName(table.namespace);
                    const name = table.name.slice();
                    const oid: i64 = table.oid;
                    const pkey = indexName(table) catch Name{};
                    var key_columns: [config.columns]u8 = undefined;
                    const primary_columns = primaryColumns(table, &key_columns);
                    const relkind = [1]u8{table.relkind};
                    switch (view) {
                        .pg_class => {
                            try sink.add(&.{ intCell(oid), nameCell(name), intCell(table.namespace), nameCell(&relkind), intCell(@intCast(table.column_count)) });
                            if (S.keyed(table)) try sink.add(&.{ intCell(oid + 1), nameCell(pkey.slice()), intCell(table.namespace), nameCell("i"), intCell(@intCast(primary_columns.len)) });
                            for (table.indexes[0..table.index_count]) |*index| {
                                if (index.oid == 0) continue;
                                try sink.add(&.{ intCell(index.oid), nameCell(index.name.slice()), intCell(table.namespace), nameCell("i"), intCell(@intCast(index.key_count + index.include_count)) });
                            }
                        },
                        .tables => if (table.relkind != 'm') {
                            try sink.add(&.{ nameCell(database), nameCell(schema_name), nameCell(name), nameCell(if (table.relkind == 'v') "VIEW" else "BASE TABLE") });
                        },
                        .pg_index => {
                            var key: [4 * config.columns]u8 = undefined;
                            if (S.keyed(table)) try sink.add(&.{ intCell(oid + 1), intCell(oid), boolCell(true), boolCell(true), nameCell(indexKey(primary_columns, &key)) });
                            for (table.indexes[0..table.index_count]) |*index| {
                                if (index.oid == 0) continue;
                                try sink.add(&.{ intCell(index.oid), intCell(oid), boolCell(false), boolCell(index.unique), nameCell(indexKey(index.keyColumns(), &key)) });
                            }
                        },
                        .pg_indexes => {
                            var text: [512]u8 = undefined;
                            if (S.keyed(table)) try sink.add(&.{ nameCell(schema_name), nameCell(name), nameCell(pkey.slice()), .null_value, nameCell(indexDefinition(table, schema_name, pkey.slice(), true, primary_columns, &text)) });
                            for (table.constraints[0..table.constraint_count]) |*constraint| {
                                if (constraint.kind != .unique) continue;
                                try sink.add(&.{ nameCell(schema_name), nameCell(name), nameCell(constraint.name.slice()), .null_value, nameCell(indexDefinition(table, schema_name, constraint.name.slice(), true, constraint.keyColumns(), &text)) });
                            }
                            for (table.indexes[0..table.index_count]) |*index| {
                                try sink.add(&.{ nameCell(schema_name), nameCell(name), nameCell(index.name.slice()), .null_value, nameCell(secondaryDefinition(table, schema_name, index, &text)) });
                            }
                            for (table.constraints[0..table.constraint_count]) |*constraint| {
                                if (constraint.kind != .exclusion) continue;
                                var definition: Writer512 = .{ .out = &text };
                                definition.add("CREATE INDEX ");
                                definition.add(constraint.name.slice());
                                definition.add(" ON ");
                                definition.add(schema_name);
                                definition.add(".");
                                definition.add(name);
                                definition.add(" USING gist (");
                                for (constraint.keyColumns(), 0..) |column, position| {
                                    if (position != 0) definition.add(", ");
                                    definition.add(table.columns[column].name.slice());
                                }
                                definition.add(")");
                                try sink.add(&.{ nameCell(schema_name), nameCell(name), nameCell(constraint.name.slice()), .null_value, nameCell(definition.slice()) });
                            }
                        },
                        .pg_views => if (table.relkind == 'v') {
                            try sink.add(&.{ nameCell(schema_name), nameCell(name), nameCell("ramsql"), nameCell(table.query.slice()) });
                        },
                        .pg_matviews => if (table.relkind == 'm') {
                            try sink.add(&.{ nameCell(schema_name), nameCell(name), nameCell("ramsql"), .null_value, boolCell(table.index_count != 0), boolCell(table.populated), nameCell(table.query.slice()) });
                        },
                        .pg_inherits => if (table.parent != 0) {
                            try sink.add(&.{ intCell(oid), intCell(table.parent), intCell(1), boolCell(false) });
                        },
                        .table_constraints => {
                            if (S.keyed(table)) try sink.add(&.{ nameCell(database), nameCell(schema_name), nameCell(pkey.slice()), nameCell(database), nameCell(schema_name), nameCell(name), nameCell("PRIMARY KEY") });
                            for (table.constraints[0..table.constraint_count]) |*constraint| {
                                const kind: []const u8 = switch (constraint.kind) {
                                    .primary, .exclusion => continue,
                                    .check => "CHECK",
                                    .unique => "UNIQUE",
                                    .foreign => "FOREIGN KEY",
                                };
                                try sink.add(&.{ nameCell(database), nameCell(schema_name), nameCell(constraint.name.slice()), nameCell(database), nameCell(schema_name), nameCell(name), nameCell(kind) });
                            }
                        },
                        .key_column_usage => {
                            for (primary_columns, 0..) |column, position| {
                                try sink.add(&.{ nameCell(database), nameCell(schema_name), nameCell(pkey.slice()), nameCell(database), nameCell(schema_name), nameCell(name), nameCell(table.columns[column].name.slice()), intCell(@intCast(position + 1)) });
                            }
                            for (table.constraints[0..table.constraint_count]) |*constraint| {
                                if (constraint.kind != .unique and constraint.kind != .foreign) continue;
                                for (constraint.keyColumns(), 0..) |column, position| {
                                    try sink.add(&.{ nameCell(database), nameCell(schema_name), nameCell(constraint.name.slice()), nameCell(database), nameCell(schema_name), nameCell(name), nameCell(table.columns[column].name.slice()), intCell(@intCast(position + 1)) });
                                }
                            }
                        },
                        .pg_attribute, .pg_attrdef, .columns => for (table.columns[0..table.column_count], 0..) |*column, index| {
                            const attnum: i64 = @intCast(index + 1);
                            const kind = column.default_kind;
                            const identity: []const u8 = switch (kind) {
                                .identity_always => "a",
                                .identity_by_default => "d",
                                else => "",
                            };
                            const has_expression = kind == .default or kind == .generated;
                            switch (view) {
                                .pg_attribute => try sink.add(&.{ intCell(oid), nameCell(column.name.slice()), intCell(types.typeOid(column.data_type)), intCell(column.typmod), intCell(attnum), boolCell(column.not_null), boolCell(false), nameCell(identity), nameCell(if (kind != .generated) "" else if (column.virtual) "v" else "s"), boolCell(has_expression) }),
                                .pg_attrdef => if (has_expression) {
                                    try sink.add(&.{ intCell(oid), intCell(attnum), expressionTextWithPool(pool,column) });
                                },
                                .columns => {
                                    const numeric = numericPrecision(column);
                                    try sink.add(&.{
                                        nameCell(database),                                       nameCell(schema_name),                          nameCell(name),            nameCell(column.name.slice()),
                                        intCell(attnum),                                          if (kind == .default) expressionTextWithPool(pool,column) else .null_value, nameCell(if (column.not_null) "NO" else "YES"), nameCell(if (types.elementData(column.data_type) != null) "ARRAY" else types.sqlTypeName(column.data_type)),
                                        optionalInt(characterMaximumLength(column)),              optionalInt(numeric[0]),                     optionalInt(numeric[1]),   optionalInt(numeric[2]),
                                        optionalInt(datetimePrecision(column)),                   nameCell(if (identity.len != 0) "YES" else "NO"), if (identity.len == 0) .null_value else nameCell(if (kind == .identity_always) "ALWAYS" else "BY DEFAULT"), nameCell(if (kind == .generated) "ALWAYS" else "NEVER"),
                                        if (kind == .generated) expressionTextWithPool(pool,column) else .null_value,
                                    });
                                },
                                else => unreachable,
                            }
                        },
                        else => {},
                    }
                },
            }
        }

        /// pg_indexes.indexdef of a primary key or UNIQUE constraint index.
        fn indexDefinition(table: *const S.Table, schema_name: []const u8, index_name: []const u8, unique: bool, columns: []const u8, out: *[512]u8) []const u8 {
            var text: Writer512 = .{ .out = out };
            text.add(if (unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
            text.add(index_name);
            text.add(" ON ");
            text.add(schema_name);
            text.add(".");
            text.add(table.name.slice());
            text.add(" USING btree (");
            for (columns, 0..) |column, position| {
                if (position != 0) text.add(", ");
                text.add(table.columns[column].name.slice());
            }
            text.add(")");
            return text.slice();
        }

        /// pg_indexes.indexdef of a secondary index (expression elements and
        /// the predicate are their stored source texts).
        fn secondaryDefinition(table: *const S.Table, schema_name: []const u8, index: *const S.Index, out: *[512]u8) []const u8 {
            var text: Writer512 = .{ .out = out };
            text.add(if (index.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
            text.add(index.name.slice());
            text.add(" ON ");
            text.add(schema_name);
            text.add(".");
            text.add(table.name.slice());
            text.add(" USING btree (");
            var at: usize = 0;
            const expressions = index.expressions.slice();
            for (index.keyColumns(), 0..) |column, position| {
                if (position != 0) text.add(", ");
                if (column == S.expression_key) {
                    var end = at;
                    while (end < expressions.len and expressions[end] != 0) end += 1;
                    text.add("(");
                    text.add(expressions[at..end]);
                    text.add(")");
                    at = end + 1;
                } else text.add(table.columns[column].name.slice());
                const descending = index.options[position] & 1 != 0;
                const nulls_first = index.options[position] & 2 != 0;
                if (descending) text.add(" DESC");
                if (nulls_first and !descending) text.add(" NULLS FIRST");
                if (!nulls_first and descending) text.add(" NULLS LAST");
            }
            text.add(")");
            if (index.include_count != 0) {
                text.add(" INCLUDE (");
                for (index.includes[0..index.include_count], 0..) |column, position| {
                    if (position != 0) text.add(", ");
                    text.add(table.columns[column].name.slice());
                }
                text.add(")");
            }
            if (index.nulls_not_distinct) text.add(" NULLS NOT DISTINCT");
            if (index.predicate.len != 0) {
                text.add(" WHERE (");
                text.add(index.predicate.slice());
                text.add(")");
            }
            return text.slice();
        }

        /// Bounded text assembly (truncates at 512 bytes).
        const Writer512 = struct {
            out: *[512]u8,
            len: usize = 0,
            fn add(self: *Writer512, bytes: []const u8) void {
                const take = @min(bytes.len, self.out.len - self.len);
                @memcpy(self.out[self.len..][0..take], bytes[0..take]);
                self.len += take;
            }
            fn slice(self: *const Writer512) []const u8 {
                return self.out[0..self.len];
            }
        };

        /// Primary-key columns in key order (empty without a primary key).
        fn primaryColumns(table: *const S.Table, out: *[config.columns]u8) []const u8 {
            if (table.primary_column) |column| {
                out[0] = @intCast(column);
                return out[0..1];
            }
            const index = S.primaryConstraint(table) orelse return out[0..0];
            const keys = table.constraints[index].keyColumns();
            @memcpy(out[0..keys.len], keys);
            return out[0..keys.len];
        }

        /// pg_index.indkey text: 1-based column numbers separated by spaces.
        fn indexKey(columns: []const u8, out: *[4 * config.columns]u8) []const u8 {
            var at: usize = 0;
            for (columns, 0..) |column, position| {
                if (position != 0) {
                    out[at] = ' ';
                    at += 1;
                }
                var digits: [4]u8 = undefined;
                const text = formatSmall(if (column == S.expression_key) 0 else @as(usize, column) + 1, &digits);
                @memcpy(out[at..][0..text.len], text);
                at += text.len;
            }
            return out[0..at];
        }

        fn formatSmall(value: usize, out: *[4]u8) []const u8 {
            var index: usize = out.len;
            var rest = value;
            while (true) {
                index -= 1;
                out[index] = @intCast('0' + rest % 10);
                rest /= 10;
                if (rest == 0) break;
            }
            return out[index..];
        }

        fn park(self: *Self, slot: u16, waits: L.Set) Error {
            self.txs[slot].waiting_for = waits;
            return error.WouldBlock;
        }

        fn tableConflict(a: locks_module.TableMode, b: locks_module.TableMode) bool {
            return locks_module.tableConflicts(a) & @intFromEnum(b) != 0;
        }

        /// Table lock held to transaction end; conflicts and FIFO waiters
        /// ahead of us park the statement (fresh snapshot on resume).
        /// SERIALIZABLE records the read (AccessShare, RowShare) or write.
        fn lockTable(self: *Self, slot: u16, table: usize, mode: locks_module.TableMode) Error!void {
            if (self.txs[slot].ssi != null) switch (mode) {
                .access_share, .row_share => try self.ssiRead(slot, table),
                .row_exclusive, .access_exclusive => try self.ssiWrite(slot, table),
                else => {},
            };
            return self.lockTableMode(slot, table, mode, false);
        }

        /// The table lock alone (LOCK TABLE); `nowait` is 55P03 on conflict.
        fn lockTableMode(self: *Self, slot: u16, table: usize, mode: locks_module.TableMode, nowait: bool) Error!void {
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
                if (nowait) return error.LockNotAvailable;
                if (tx.table_wait == null) {
                    self.wait_counter += 1;
                    tx.table_wait = .{ .table = @intCast(table), .mode = mode, .seq = self.wait_counter };
                }
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            if (self.locks.grantTable(table, slot, mode)) try M.recordLock(self, slot, .{ .kind = .table, .table = @intCast(table), .mode = @intFromEnum(mode) });
            tx.table_wait = null;
        }

        const Target = union(enum) { skip, authored, wait, ready: u32 };

        /// EvalPlanQual: from the snapshot-visible version, follow committed
        /// successors to the newest version and report what blocks it.
        /// REPEATABLE READ / SERIALIZABLE: a version changed by a
        /// transaction that committed after the snapshot is 40001
        /// ("could not serialize access due to concurrent update").
        fn target(self: *Self, slot: u16, table_index: usize, version: u32, snap: Snapshot, mode: locks_module.RowMode, waits: *L.Set) Error!Target {
            const table = &self.tables[table_index];
            var current = version;
            const strict = transactionSnapshot(self.txs[slot].isolation);
            while (true) {
                const entry = &table.versions[current];
                if (entry.xmax.epoch != 0) {
                    if (entry.xmax_csn != 0) {
                        if (strict and entry.xmax_csn > snap.csn) return error.SerializationFailure;
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
                switch (try db.target(self.slot, table_index, version, self.snap, self.mode, &waits)) {
                    .skip, .authored => return null,
                    .wait => switch (self.wait) {
                        .nowait => return error.LockNotAvailable,
                        .skip_locked => return null,
                        .block => return db.park(self.slot, waits),
                    },
                    .ready => |newest| {
                        const table = &db.tables[table_index];
                        const rowid = table.rows[table.versions[newest].row - 1].rowid;
                        if (try db.locks.grantRow(table_index, rowid, self.slot, self.mode)) |granted| try M.recordLock(db, self.slot, granted);
                        return newest;
                    },
                }
            }
        };

        fn reserveWrites(self: *const Self, slot: u16, count: usize) Error!void {
            if (M.write_capacity - self.txs[slot].write_len < count) return error.WriteSetCapacity;
        }

        fn createTable(self: *Self, slot: u16, create: *const B.Create, snap: Snapshot, source: []const u8) Error!usize {
            const tx = &self.txs[slot];
            // CREATE TABLE AS / MATERIALIZED VIEW read their sources first,
            // so a lock wait parks before anything is written.
            if (create.plan != ast.none) try self.lockSources(slot);
            if (self.catalog.creator(create.name.slice(), snap)) |owner| {
                var waits: L.Set = .{};
                waits.add(owner);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            // A schema another transaction is dropping: wait for it.
            for (&self.schemas) |*schema| if (schema.live and schema.oid == create.namespace and schema.pending_drop and schema.creator != slot) {
                var waits: L.Set = .{};
                waits.add(schema.creator);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            };
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
            if (!S.indexFits(table, create.extras.index_count, 0)) return error.IndexCapacity;
            S.reset(table, change_log.first_oid + self.oid_counter, create.name, create.columns[0..create.count]);
            table.namespace = create.namespace;
            S.setConstraints(table, create.constraints[0..create.constraint_count]);
            S.setExtras(table, &create.extras);
            // A foreign key to the table itself takes its OID now.
            for (table.constraints[0..table.constraint_count]) |*constraint| {
                if (constraint.kind == .foreign and constraint.ref_oid == 0) constraint.ref_oid = table.oid;
            }
            table.live = true;
            table.pending_create = true;
            // A primary key's index owns the next OID (pg_class relkind i).
            self.oid_counter += S.oidWidth(table);
            tx.push(.{ .kind = .create_table, .table = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const count = try self.catalog.create(index, table, tx.ref(slot), snap.cid, 0, self.horizon(), &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_insert, .table = @intFromEnum(change.relation), .new = change.version }) catch unreachable;
            if (create.identity) |identity| try self.createSequence(slot, identity.name, identity.spec, table.oid, identity.column, snap);
            for (create.serials[0..create.serial_count]) |serial| try self.createSequence(slot, serial.name, serial.spec, table.oid, serial.column, snap);
            const generated_context = self.bindContext("", .standard, snap);
            try B.validateGenerated(&generated_context, index);
            try B.validateConstraints(&generated_context, index);
            // Referenced tables cannot be dropped while this one is created.
            for (table.constraints[0..table.constraint_count]) |*constraint| {
                if (constraint.kind != .foreign or constraint.ref_oid == table.oid) continue;
                try self.lockTable(slot, self.visibleTableSlot(constraint.ref_oid, snap) orelse return error.TableNotFound, .access_share);
            }
            for (table.depends[0..table.depend_count]) |oid| {
                if (self.visibleTableSlot(oid, snap)) |read| try self.lockTable(slot, read, .access_share);
            }
            // Indexes copied by LIKE ... INCLUDING INDEXES take their OIDs.
            for (table.indexes[0..table.index_count]) |*created| if (created.oid == 0) {
                if (self.oid_counter >= 0xffffffff - change_log.first_oid) return error.TableCapacity;
                created.oid = change_log.first_oid + self.oid_counter;
                self.oid_counter += 1;
            };
            if (create.plan != ast.none) return self.fillFromPlan(slot, index, source, create.plan, snap);
            return 0;
        }

        /// Inserts the rows of a bound query into table `index` (CREATE
        /// TABLE AS, CREATE / REFRESH MATERIALIZED VIEW); returns the count.
        fn fillFromPlan(self: *Self, slot: u16, index: usize, source: []const u8, root: u16, snap: Snapshot) Error!usize {
            const work = &self.workspace.query;
            const list = try X.queryRows(&self.tables, source, &self.workspace.nodes, &self.workspace.plans, root, snap, &self.session, work);
            const table = &self.tables[index];
            for (0..list.count) |position| {
                try self.session.checkpoint();
                const row = X.rowAt(work, list, position);
                var cells: E.Row = @splat(.null_value);
                for (table.columns[0..table.column_count], 0..) |*column, column_index| cells[column_index] = try D.store(column, row[column_index], &self.session);
                try self.appendRow(slot, index, &cells, snap);
            }
            return list.count;
        }

        /// REFRESH MATERIALIZED VIEW: AccessExclusive, every row marked
        /// deleted in place (one truncate entry), then the query's rows under
        /// the statement snapshot. A change of populated state rewrites the
        /// definition first (ALTER TABLE copy, durable op 12).
        fn refreshView(self: *Self, slot: u16, refresh: *const B.Refresh, source: []const u8, snap: Snapshot) Error!usize {
            try self.lockTable(slot, refresh.slot, .access_exclusive);
            if (refresh.with_data) try self.lockSources(slot);
            var index = refresh.slot;
            if (self.tables[index].populated != refresh.with_data) {
                const context = self.bindContext("", .standard, snap);
                var alter = B.identityAlter(&context, index);
                alter.extras.populated = refresh.with_data;
                alter.command = .refresh_materialized_view;
                try self.alterTable(slot, &alter, snap);
                index = self.visibleTableSlot(self.tables[index].oid, .{ .csn = snap.csn, .slot = snap.slot, .epoch = snap.epoch, .cid = snap.cid +% 1 }) orelse return error.TableNotFound;
            }
            try self.truncateSlot(slot, index, snap);
            if (!refresh.with_data) return 0;
            return self.fillFromPlan(slot, index, source, refresh.plan, snap);
        }

        /// Marks every row version of `index` visible to `snap` deleted in
        /// place with one truncate write entry (the caller locked it).
        fn truncateSlot(self: *Self, slot: u16, index: usize, snap: Snapshot) Error!void {
            try self.reserveWrites(slot, 1);
            const tx = &self.txs[slot];
            const table = &self.tables[index];
            for (0..table.row_high) |row| {
                if (table.rows[row].newest == 0) continue;
                const version = S.visibleAt(table, row, snap) orelse continue;
                const entry = &table.versions[version];
                entry.xmax = tx.ref(slot);
                entry.xmax_cid = snap.cid;
            }
            tx.push(.{ .kind = .truncate, .table = @intCast(index), .old = snap.cid }) catch unreachable;
        }

        fn dropTable(self: *Self, slot: u16, index: usize, cascade: bool, snap: Snapshot) Error!usize {
            try self.lockTable(slot, index, .access_exclusive);
            const tx = &self.txs[slot];
            const table = &self.tables[index];
            if (table.pending_drop) return 0;
            // Grants, policies or comments another transaction is writing.
            if (self.catalog_objects.pendingReference(table.oid, snap)) |other| return self.objectPark(slot, other);
            // Its triggers and rules go with it (B11 wave 3).
            try self.dropTableObjects(slot, table.oid, snap);
            // Dependents (pg_depend): other tables' foreign keys, views that
            // read it and inheritance children / partitions. RESTRICT is
            // 2BP01; CASCADE drops the views and children and removes the
            // foreign keys from the referencing tables.
            var relations: [K.relation_rows]K.Found = undefined;
            const relation_count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..relation_count]) |found| {
                if (found.kind == 'S' or found.slot == index) continue;
                const other = &self.tables[found.slot];
                if (other.pending_drop) continue;
                // Partitions are part of their table: dropped with it.
                if (other.parent == table.oid and other.partition.bound != .none) {
                    _ = try self.dropTable(slot, found.slot, true, snap);
                    continue;
                }
                var depends = other.parent == table.oid;
                for (other.depends[0..other.depend_count]) |oid| depends = depends or oid == table.oid;
                var references = false;
                for (other.constraints[0..other.constraint_count]) |*constraint| references = references or (constraint.kind == .foreign and constraint.ref_oid == table.oid);
                if ((depends or references) and !cascade) return error.DependentObjects;
                if (depends) {
                    _ = try self.dropTable(slot, found.slot, true, snap);
                } else if (references) {
                    const context = self.bindContext("", .standard, snap);
                    var alter = B.identityAlter(&context, found.slot);
                    var kept: usize = 0;
                    for (alter.constraints[0..alter.constraint_count]) |constraint| {
                        if (constraint.kind == .foreign and constraint.ref_oid == table.oid) continue;
                        alter.constraints[kept] = constraint;
                        kept += 1;
                    }
                    alter.constraint_count = kept;
                    try self.alterTable(slot, &alter, snap);
                }
            }
            // Owned identity sequences go with the table (DROP ... CASCADE of
            // the dependency), encoded before the table.
            for (&self.seqs, 0..) |*seq, seq_index| {
                if (!seq.live or seq.owner != table.oid or seq.dead_csn != 0 or seq.pending_drop) continue;
                try self.dropSequence(slot, seq_index, snap);
            }
            try self.reserveWrites(slot, 2 + table.column_count);
            table.pending_drop = true;
            tx.push(.{ .kind = .drop_table, .table = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const count = self.catalog.drop(index, table.column_count, snap, tx.ref(slot), snap.cid, 0, &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_delete, .table = @intFromEnum(change.relation), .old = change.version }) catch unreachable;
            try self.dropObjectsOf(slot, table.oid, snap);
            return 0;
        }

        /// TRUNCATE (PostgreSQL ExecuteTruncate): AccessExclusive on every
        /// target first, so a lock wait parks before any write; then every
        /// row version visible to the statement is marked deleted in place.
        /// One write entry per table covers all of its rows (no write-set or
        /// version cost per row); commit publishes the marks and frees the
        /// dead versions, abort or ROLLBACK TO clears exactly these marks.
        /// RESTART IDENTITY is not provided (0A000).
        fn truncateTables(self: *Self, slot: u16, truncate: *const B.Truncate, snap: Snapshot) Error!void {
            for (truncate.tables[0..truncate.count]) |index| try self.lockTable(slot, index, .access_exclusive);
            // A table referenced by a foreign key of a table outside the
            // list cannot be truncated (0A000; CASCADE is outside the subset).
            var relations: [K.relation_rows]K.Found = undefined;
            const relation_count = self.catalog.visibleRelations(snap, &relations);
            for (truncate.tables[0..truncate.count]) |index| {
                for (relations[0..relation_count]) |found| {
                    if (found.kind == 'S') continue;
                    var listed = false;
                    for (truncate.tables[0..truncate.count]) |other| listed = listed or other == found.slot;
                    if (listed) continue;
                    const other = &self.tables[found.slot];
                    for (other.constraints[0..other.constraint_count]) |*constraint| {
                        if (constraint.kind == .foreign and constraint.ref_oid == self.tables[index].oid) return error.UnsupportedStatement;
                    }
                }
            }
            try self.reserveWrites(slot, truncate.count);
            // RESTART IDENTITY: every sequence a column of the table owns
            // (identity, SERIAL) restarts, transactionally (ALTER SEQUENCE).
            if (truncate.restart_identity) {
                // Collect first: each restart fills another sequence slot.
                var owned: [config.sequences]bool = @splat(false);
                for (truncate.tables[0..truncate.count]) |index| {
                    const oid = self.tables[index].oid;
                    for (&self.seqs, 0..) |*seq, position| {
                        if (!seq.live or seq.owner != oid or seq.dead_csn != 0) continue;
                        if (seq.pending_create and seq.creator != slot) continue;
                        if (seq.pending_drop and seq.creator == slot) continue;
                        owned[position] = true;
                    }
                }
                for (owned, 0..) |restart, position| if (restart) try self.alterSequence(slot, position, .{ .restart = true }, snap);
            }
            const tx = &self.txs[slot];
            for (truncate.tables[0..truncate.count]) |index| {
                const table = &self.tables[index];
                for (0..table.row_high) |row| {
                    if (table.rows[row].newest == 0) continue;
                    const version = S.visibleAt(table, row, snap) orelse continue;
                    const entry = &table.versions[version];
                    entry.xmax = tx.ref(slot);
                    entry.xmax_cid = snap.cid;
                }
                tx.push(.{ .kind = .truncate, .table = index, .old = snap.cid }) catch unreachable;
            }
        }

        /// ALTER TABLE (copy on write): AccessExclusive on the table, then
        /// every row slot and version is copied into a free table slot with
        /// the new definition and the same OID. The catalog swaps the
        /// relation in this transaction only: other snapshots, including
        /// detached reads, keep the old slot and definition until commit;
        /// abort or ROLLBACK TO discards the copy. Added columns take their
        /// DEFAULT evaluated once (non-volatile only). Existing rows are then
        /// re-checked for new NOT NULL, CHECK and UNIQUE constraints. Needs a
        /// free table slot (TableCapacity, 54000) until the old one is
        /// reclaimed after commit.
        fn alterTable(self: *Self, slot: u16, alter: *const B.AlterTable, snap: Snapshot) Error!void {
            try self.lockTable(slot, alter.table, .access_exclusive);
            const tx = &self.txs[slot];
            try self.reserveWrites(slot, 3 + 2 * config.columns);
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
            const source = &self.tables[alter.table];
            // Owned sequences (identity, SERIAL) record their column: it must
            // keep its position (dropping or shifting it is 0A000).
            for (&self.seqs) |*seq| {
                if (!seq.live or seq.owner != source.oid or seq.dead_csn != 0) continue;
                if (seq.owner_column >= alter.count or alter.sources[seq.owner_column] != seq.owner_column) return error.UnsupportedStatement;
            }
            const copy = &self.tables[index];
            if (copy.rows.len < source.row_high or copy.versions.len < source.version_high) return error.TableCapacity;
            var fills: [config.columns]Cell = @splat(.null_value);
            for (alter.columns[0..alter.count], 0..) |*column, position| {
                if (alter.sources[position] != 0xff or alter.fills[position] == ast.none) continue;
                var ctx = self.evalContext(column.expression.slice());
                const value = try E.eval(&ctx, alter.fills[position]);
                if (value != .null_value) fills[position] = try D.store(column, value, &self.session);
            }
            if (!S.indexFits(copy, alter.extras.index_count, source.version_used)) return error.IndexCapacity;
            S.reset(copy, source.oid, alter.name, alter.columns[0..alter.count]);
            copy.namespace = source.namespace;
            S.setConstraints(copy, alter.constraints[0..alter.constraint_count]);
            S.setExtras(copy, &alter.extras);
            S.copyRelayout(copy, source, alter.sources[0..alter.count], fills[0..alter.count]);
            copy.live = true;
            copy.pending_create = true;
            source.pending_drop = true;
            self.alters[index] = .{ .sources = alter.sources, .fills = fills };
            tx.push(.{ .kind = .alter_table, .table = @intCast(index), .old = @intCast(alter.table), .new = snap.cid }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            var count = self.catalog.drop(alter.table, source.column_count, snap, tx.ref(slot), snap.cid, 0, &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_delete, .table = @intFromEnum(change.relation), .old = change.version }) catch unreachable;
            count = try self.catalog.create(index, copy, tx.ref(slot), snap.cid, 0, self.horizon(), &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_insert, .table = @intFromEnum(change.relation), .new = change.version }) catch unreachable;
            try self.validateAltered(slot, index, alter, snap);
            // CREATE INDEX: OIDs are taken last, so a failed statement
            // leaves the counter as it was (abort restores a tail OID).
            for (copy.indexes[0..copy.index_count]) |*created| if (created.oid == 0) {
                if (self.oid_counter >= 0xffffffff - change_log.first_oid) return error.TableCapacity;
                created.oid = change_log.first_oid + self.oid_counter;
                self.oid_counter += 1;
            };
            try self.remapColumnComments(slot, source.oid, alter.sources[0..alter.count], snap);
        }

        /// Existing rows against the constraints ALTER TABLE added or
        /// tightened (23502, 23514, 23505), and generation/CHECK texts that
        /// must still bind over the new definition.
        fn validateAltered(self: *Self, slot: u16, index: usize, alter: *const B.AlterTable, snap: Snapshot) Error!void {
            const context = self.bindContext("", .standard, snap);
            try B.validateGenerated(&context, index);
            try B.validateConstraints(&context, index);
            var checks: [config.table_constraints]u16 = @splat(ast.none);
            try B.bindFlaggedChecks(&context, index, &alter.check_constraint, &checks);
            const table = &self.tables[index];
            var ctx = self.evalContext("");
            for (0..table.row_high) |row| {
                if (table.rows[row].newest == 0) continue;
                const version = S.visibleAt(table, row, snap) orelse continue;
                try self.session.checkpoint();
                const cells = &table.versions[version].cells;
                for (0..table.column_count) |column| {
                    if (alter.check_not_null[column] and cells[column] == .null_value) return error.NotNullViolation;
                }
                try D.checkRow(&ctx, table, &checks, cells);
                // An added EXCLUDE constraint over the existing rows.
                for (table.constraints[0..table.constraint_count], 0..) |*constraint, position| {
                    if (constraint.kind != .exclusion or !alter.check_constraint[position]) continue;
                    switch (try exclusionCheck(table, constraint, cells, @intCast(row), snap)) {
                        .free, .wait => {},
                        .taken => return error.ExclusionViolation,
                    }
                }
                // An added FOREIGN KEY: every existing row must reference a row.
                for (table.constraints[0..table.constraint_count], 0..) |*constraint, position| {
                    if (constraint.kind != .foreign or !alter.check_constraint[position]) continue;
                    var has_null = false;
                    for (constraint.keyColumns()) |column| has_null = has_null or cells[column] == .null_value;
                    if (!has_null) try self.referencedRow(slot, index, constraint, cells, snap);
                }
                for (table.constraints[0..table.constraint_count], 0..) |*constraint, position| {
                    if (!alter.check_constraint[position] or !S.scannedUnique(table, constraint)) continue;
                    switch (S.uniqueCheck(table, constraint, cells, @intCast(row), snap)) {
                        .free => {},
                        .taken => return error.PrimaryKeyViolation,
                        .wait => |owner| {
                            var waits: L.Set = .{};
                            waits.add(owner);
                            return self.park(slot, waits);
                        },
                    }
                }
                if (alter.check_index) |which| switch (S.indexUniqueCheck(table, which, cells, @intCast(row), snap)) {
                    .free => {},
                    .taken => return error.PrimaryKeyViolation,
                    .wait => |owner| {
                        var waits: L.Set = .{};
                        waits.add(owner);
                        return self.park(slot, waits);
                    },
                };
            }
        }

        /// Inserts every VALUES row, SELECT row or the DEFAULT VALUES row in
        /// order. A resumed statement continues after the rows it already
        /// handled (Tx.progress); their writes are in its write slice.
        fn insertRows(self: *Self, slot: u16, source: []const u8, insert: *const B.Insert, snap: Snapshot) Error!usize {
            const tx = &self.txs[slot];
            const done = tx.progress;
            var ctx = self.evalContext(source);
            const derived: D.Derived = .{ .defaults = &insert.defaults, .generated = &insert.generated, .checks = &insert.checks };
            var position: usize = 0;
            if (insert.plan != ast.none) {
                const work = &self.workspace.query;
                const rows = try X.queryRows(&self.tables, source, &self.workspace.nodes, &self.workspace.plans, insert.plan, snap, &self.session, work);
                for (0..rows.count) |index| {
                    if (position >= done) {
                        ctx.tuple[1] = X.rowAt(work, rows, index);
                        try self.insertProgress(slot, &ctx, insert, &insert.values, derived, snap, position);
                    }
                    position += 1;
                }
            } else if (insert.rows == ast.none) {
                if (done == 0) try self.insertProgress(slot, &ctx, insert, &insert.values, derived, snap, 0);
            } else {
                const nodes = &self.workspace.nodes.nodes;
                var row = insert.rows;
                while (row != ast.none) : (row = nodes[row].next) {
                    if (position >= done) {
                        var values: [config.columns]u16 = @splat(ast.none);
                        var item = nodes[row].b;
                        var item_index: usize = 0;
                        while (item != ast.none) : (item = nodes[item].next) {
                            values[insert.mapping[item_index]] = item;
                            item_index += 1;
                        }
                        try self.insertProgress(slot, &ctx, insert, &values, derived, snap, position);
                    }
                    position += 1;
                }
            }
            return tx.progress_affected;
        }

        fn insertProgress(self: *Self, slot: u16, ctx: *E.Context, insert: *const B.Insert, values: *const [config.columns]u16, derived: D.Derived, snap: Snapshot, position: usize) Error!void {
            try self.session.checkpoint();
            const affected = try self.insertOne(slot, ctx, insert, values, derived, snap);
            const tx = &self.txs[slot];
            tx.progress = position + 1;
            tx.progress_affected += affected;
        }

        /// ON CONFLICT DO UPDATE on the conflicting row (the newest committed
        /// or own version, not the statement snapshot's): wait for a live
        /// writer or locker (the whole row is retried on resume), 21000 when
        /// this statement already wrote the row, WHERE false locks the row
        /// and skips it. Returns rows affected (0 or 1).
        fn conflictUpdate(self: *Self, slot: u16, ctx: *E.Context, table_index: usize, update: *const B.Update, version: u32, proposed: *const E.Row, snap: Snapshot) Error!usize {
            const table = &self.tables[table_index];
            const entry = &table.versions[version];
            if (entry.xmin_csn == 0 and snap.own(entry.xmin) and entry.xmin_cid == snap.cid) return error.CardinalityViolation;
            var waits: L.Set = .{};
            const goal = switch (try self.target(slot, table_index, version, snap, .write, &waits)) {
                .wait => return self.park(slot, waits),
                .ready => |newest| newest,
                .skip, .authored => return error.CardinalityViolation,
            };
            // REPEATABLE READ: the conflicting row must be visible to the
            // snapshot (ExecCheckTupleVisible).
            if (transactionSnapshot(self.txs[slot].isolation) and !snap.own(table.versions[goal].xmin) and table.versions[goal].xmin_csn > snap.csn) return error.SerializationFailure;
            const row = table.versions[goal].row - 1;
            ctx.tuple[1] = proposed;
            if (!try X.keep(ctx, update.where, &table.versions[goal].cells)) {
                if (try self.locks.grantRow(table_index, table.rows[row].rowid, slot, .update)) |granted| try M.recordLock(self, slot, granted);
                return 0;
            }
            return @intFromBool(try self.updateOne(slot, ctx, update, row, goal, snap));
        }

        fn insertOne(self: *Self, slot: u16, ctx: *E.Context, insert: *const B.Insert, values: *const [config.columns]u16, derived: D.Derived, snap: Snapshot) Error!usize {
            // BEFORE ROW triggers and conditional rules see the row before
            // NOT NULL, generated columns and CHECKs (B11 wave 3).
            const hooked = self.insertHooks(insert.table, snap);
            var cells = if (hooked) try D.insertedRowDeferred(ctx, &self.tables[insert.table], values, derived) else try D.insertedRow(ctx, &self.tables[insert.table], values, derived);
            if (hooked and try self.ruleSkips(insert.table, '3', &cells, null, snap)) return 0;
            // A partitioned table routes the row to its partition.
            const table_index = try self.routeRow(slot, insert.table, &cells, snap);
            if (hooked) {
                if (!try self.beforeRow(table_index, routine_catalog.tg_insert, &cells, null, null, snap)) return 0;
                try D.finishRow(ctx, &self.tables[insert.table], derived, &cells);
                if (table_index != insert.table) try self.partitionBound(table_index, &cells, snap);
            }
            // Row security checks the row the triggers produced (B11 wave 3).
            try self.securityCheck(ctx, insert.table, &cells);
            const table = &self.tables[table_index];
            // ON CONFLICT: the arbiter is checked first (PostgreSQL's
            // speculative pre-check); other unique indexes still raise 23505.
            const conflict = &insert.conflict;
            if (conflict.action != .none) if (try self.arbiterTaken(slot, table_index, conflict.arbiter, &cells, snap)) |version| switch (conflict.action) {
                .nothing, .none => return 0,
                .update => return self.conflictUpdate(slot, ctx, table_index, &conflict.update, version, &cells, snap),
            };
            if (table.primary_column) |column| switch (D.keyCheck(table, &cells[column], 0xffffffff, snap)) {
                .free => {},
                .taken => return error.PrimaryKeyViolation,
                .wait => |owner| {
                    var waits: L.Set = .{};
                    waits.add(owner);
                    return self.park(slot, waits);
                },
            };
            if (try self.uniqueTaken(slot, table_index, &cells, 0xffffffff, null, snap)) |_| return error.PrimaryKeyViolation;
            try self.exclusionTaken(slot, table_index, &cells, 0xffffffff, null, snap);
            try self.checkReferences(slot, table_index, &cells, null, snap);
            try self.appendRow(slot, table_index, &cells, snap);
            return 1;
        }

        // ---- exclusion constraints -----------------------------------------

        /// EXCLUDE constraints of a new or updated row (23P01) with the
        /// dirty-snapshot rules of UNIQUE: a committed or own row matching
        /// every element conflicts; another live writer's is waited for.
        /// NULL elements never conflict; deferrable ones are checked later.
        fn exclusionTaken(self: *Self, slot: u16, table_index: usize, cells: *const E.Row, own_slot: u32, old: ?*const E.Row, snap: Snapshot) Error!void {
            const table = &self.tables[table_index];
            for (table.constraints[0..table.constraint_count]) |*constraint| {
                if (constraint.kind != .exclusion) continue;
                if (old) |previous| if (!S.keyChanged(constraint, previous, cells)) continue;
                if (constraint.deferrable) {
                    self.txs[slot].deferred_checks = true;
                    continue;
                }
                switch (try exclusionCheck(table, constraint, cells, own_slot, snap)) {
                    .free => {},
                    .taken => return error.ExclusionViolation,
                    .wait => |owner| {
                        var waits: L.Set = .{};
                        waits.add(owner);
                        return self.park(slot, waits);
                    },
                }
            }
        }

        fn exclusionCheck(table: *const S.Table, constraint: *const S.Constraint, cells: *const E.Row, own_slot: u32, snap: Snapshot) Error!S.KeyState {
            for (constraint.keyColumns()) |column| if (cells[column] == .null_value) return .free;
            var waiting: ?u16 = null;
            for (table.versions[0..table.version_high], 0..) |*version, index| {
                if (version.row == 0 or version.row - 1 == own_slot) continue;
                var all = true;
                for (constraint.keyColumns(), constraint.operators[0..constraint.column_count]) |column, operator| {
                    if (!all) break;
                    all = try exclusionMatch(operator, &version.cells[column], &cells[column]);
                }
                if (!all) continue;
                if (S.classify(version, index, snap, &waiting)) |state| return state;
            }
            return if (waiting) |owner| .{ .wait = owner } else .free;
        }

        fn exclusionMatch(operator: S.ExclusionOperator, left: *const V.Cell, right: *const V.Cell) Error!bool {
            if (left.* == .null_value or right.* == .null_value) return false;
            return switch (operator) {
                .equal => V.compare(left, right) == 0,
                .overlap => range_eval_module.RangeEval(config, E).predicate(.overlap, left, right),
            };
        }

        // ---- foreign keys -------------------------------------------------

        /// The table slot with `oid` visible to `snap` (ALTER keeps the OID
        /// across slots), if any.
        fn visibleTableSlot(self: *const Self, oid: u32, snap: Snapshot) ?usize {
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind != 'S' and self.tables[found.slot].oid == oid) return found.slot;
            }
            return null;
        }

        const KeyLookup = union(enum) { found: u32, missing, wait: u16 };

        /// The newest live version of `table` whose `columns` equal
        /// `key[key_columns]` (PostgreSQL's RI check under the latest state):
        /// a committed live row or one this transaction wrote; another
        /// transaction's uncommitted insert is invisible, a row it is
        /// deleting or updating means waiting for it.
        fn liveKey(table: *const S.Table, columns: []const u8, key: *const E.Row, key_columns: []const u8, snap: Snapshot) KeyLookup {
            var waiting: ?u16 = null;
            for (table.versions[0..table.version_high], 0..) |*version, index| {
                if (version.row == 0) continue;
                var equal = true;
                for (columns, key_columns) |column, source| {
                    if (version.cells[column] == .null_value or V.compare(&version.cells[column], &key[source]) != 0) equal = false;
                }
                if (!equal) continue;
                if (version.xmin_csn == 0) {
                    if (!snap.own(version.xmin)) continue;
                    if (version.xmax.epoch != 0 and snap.own(version.xmax)) continue;
                    return .{ .found = @intCast(index) };
                }
                if (version.xmax.epoch == 0) return .{ .found = @intCast(index) };
                if (version.xmax_csn != 0 or snap.own(version.xmax)) continue;
                if (waiting == null) waiting = version.xmax.slot;
            }
            return if (waiting) |slot| .{ .wait = slot } else .missing;
        }

        /// FOREIGN KEY checks of a new or updated referencing row (MATCH
        /// SIMPLE: a NULL member skips the check): the referenced row must be
        /// live (23503); it is share-locked so its DELETE or key UPDATE waits
        /// for this transaction. A row may reference itself. Deferred
        /// constraints are checked at COMMIT instead.
        fn checkReferences(self: *Self, slot: u16, table_index: usize, cells: *const E.Row, old: ?*const E.Row, snap: Snapshot) Error!void {
            const table = &self.tables[table_index];
            for (table.constraints[0..table.constraint_count]) |*constraint| {
                if (constraint.kind != .foreign) continue;
                if (old) |previous| if (!S.keyChanged(constraint, previous, cells)) continue;
                var has_null = false;
                for (constraint.keyColumns()) |column| has_null = has_null or cells[column] == .null_value;
                if (has_null) continue;
                if (constraint.deferrable) {
                    self.txs[slot].deferred_checks = true;
                    continue;
                }
                try self.referencedRow(slot, table_index, constraint, cells, snap);
            }
        }

        fn referencedRow(self: *Self, slot: u16, table_index: usize, constraint: *const S.Constraint, cells: *const E.Row, snap: Snapshot) Error!void {
            const table = &self.tables[table_index];
            if (constraint.ref_oid == table.oid) {
                // A row referencing its own key.
                var own = true;
                for (constraint.keyColumns(), constraint.refColumns()) |child, key| {
                    if (V.compare(&cells[child], &cells[key]) != 0) own = false;
                }
                if (own) return;
            }
            const parent_index = if (constraint.ref_oid == table.oid) table_index else (self.visibleTableSlot(constraint.ref_oid, snap) orelse return error.ForeignKeyViolation);
            if (parent_index != table_index) try self.lockTable(slot, parent_index, .access_share);
            const parent = &self.tables[parent_index];
            switch (liveKey(parent, constraint.refColumns(), cells, constraint.keyColumns(), snap)) {
                .missing => return error.ForeignKeyViolation,
                .wait => |owner| {
                    var waits: L.Set = .{};
                    waits.add(owner);
                    return self.park(slot, waits);
                },
                .found => |version| {
                    if (parent.versions[version].xmin_csn == 0) return;
                    const rowid = parent.rows[parent.versions[version].row - 1].rowid;
                    var waits: L.Set = .{};
                    self.locks.rowHolders(parent_index, rowid, slot, .share, &waits);
                    if (waits.any()) return self.park(slot, waits);
                    if (try self.locks.grantRow(parent_index, rowid, slot, .share)) |granted| try M.recordLock(self, slot, granted);
                },
            }
        }

        /// ON DELETE (`new` null) or ON UPDATE of referenced key `old` in
        /// table `table_index`: every live referencing row is handled by its
        /// constraint's action. NO ACTION / RESTRICT: 23503. CASCADE deletes
        /// it (or copies the new key), SET NULL / SET DEFAULT update its
        /// columns; cascaded rows are checked and cascade further. Rows of
        /// live writers are waited for; nothing is written before every wait
        /// of this row has passed (a resumed statement re-runs it).
        fn referencedChange(self: *Self, slot: u16, table_index: usize, old: *const E.Row, new: ?*const E.Row, snap: Snapshot) Error!void {
            const parent = &self.tables[table_index];
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') continue;
                const child_index = found.slot;
                const child = &self.tables[child_index];
                for (child.constraints[0..child.constraint_count]) |*constraint| {
                    if (constraint.kind != .foreign or constraint.ref_oid != parent.oid) continue;
                    var has_null = false;
                    for (constraint.refColumns()) |column| has_null = has_null or old[column] == .null_value;
                    if (has_null) continue;
                    if (new) |cells| {
                        var changed = false;
                        for (constraint.refColumns()) |column| {
                            if (@as(V.CellTag, old[column]) != @as(V.CellTag, cells[column]) or V.compare(&old[column], &cells[column]) != 0) changed = true;
                        }
                        if (!changed) continue;
                    }
                    const action = if (new == null) constraint.on_delete else constraint.on_update;
                    if (action == .no_action and constraint.deferrable) {
                        self.txs[slot].deferred_checks = true;
                        continue;
                    }
                    try self.referencingRows(slot, child_index, constraint, action, old, new, snap);
                }
            }
        }

        fn referencingRows(self: *Self, slot: u16, child_index: usize, constraint: *const S.Constraint, action: S.ForeignAction, old: *const E.Row, new: ?*const E.Row, snap: Snapshot) Error!void {
            const child = &self.tables[child_index];
            const tx = &self.txs[slot];
            if (action == .no_action or action == .restrict) try self.lockTable(slot, child_index, .access_share) else try self.lockTable(slot, child_index, .row_exclusive);
            var version: u32 = 0;
            while (version < child.version_high) : (version += 1) {
                const entry = &child.versions[version];
                if (entry.row == 0) continue;
                var equal = true;
                for (constraint.keyColumns(), constraint.refColumns()) |column, key| {
                    if (entry.cells[column] == .null_value or V.compare(&entry.cells[column], &old[key]) != 0) equal = false;
                }
                if (!equal) continue;
                var goal = version;
                if (entry.xmin_csn == 0) {
                    if (!snap.own(entry.xmin)) {
                        var waits: L.Set = .{};
                        waits.add(entry.xmin.slot);
                        return self.park(slot, waits);
                    }
                    if (entry.xmax.epoch != 0 and snap.own(entry.xmax)) continue;
                } else {
                    if (entry.xmax.epoch != 0 and (entry.xmax_csn != 0 or snap.own(entry.xmax))) continue;
                    var waits: L.Set = .{};
                    switch (try self.target(slot, child_index, version, snap, .write, &waits)) {
                        .wait => return self.park(slot, waits),
                        .skip, .authored => continue,
                        .ready => |newest| goal = newest,
                    }
                }
                switch (action) {
                    .no_action, .restrict => return error.ForeignKeyViolation,
                    .cascade => if (new) |cells| {
                        var updated = child.versions[goal].cells;
                        for (constraint.keyColumns(), constraint.refColumns()) |column, key| updated[column] = try D.store(&child.columns[column], cells[key], &self.session);
                        try self.cascadeUpdate(slot, child_index, goal, &updated, .none, snap);
                    } else {
                        try self.referencedChange(slot, child_index, &child.versions[goal].cells, null, snap);
                        if (child.versions[goal].xmax.epoch != 0) continue;
                        try self.reserveWrites(slot, 1);
                        child.versions[goal].xmax = tx.ref(slot);
                        child.versions[goal].xmax_cid = snap.cid;
                        tx.push(.{ .kind = .delete, .table = @intCast(child_index), .old = goal }) catch unreachable;
                    },
                    .set_null, .set_default => {
                        var updated = child.versions[goal].cells;
                        for (constraint.keyColumns()) |column| {
                            updated[column] = .null_value;
                            if (action == .set_default) {
                                const context = self.bindContext("", .standard, snap);
                                const id = try B.columnDefault(&context, child_index, column);
                                if (id != ast.none) {
                                    var ctx = self.evalContext(child.columns[column].expression.slice());
                                    updated[column] = try D.store(&child.columns[column], try E.eval(&ctx, id), &self.session);
                                }
                            }
                            try V.validate(&child.columns[column], &updated[column]);
                        }
                        // A default equal to the removed key references nothing.
                        var still = true;
                        for (constraint.keyColumns(), constraint.refColumns()) |column, key| {
                            if (updated[column] == .null_value or V.compare(&updated[column], &old[key]) != 0) still = false;
                        }
                        if (still) return error.ForeignKeyViolation;
                        try self.cascadeUpdate(slot, child_index, goal, &updated, if (action == .set_default) .all else .changed, snap);
                    },
                }
            }
        }

        /// A referencing row rewritten by a referential action: CHECK and
        /// unique constraints of its table, its own foreign keys and the
        /// rows that reference it, then the new version.
        const ReferenceCheck = enum { none, changed, all };

        /// `check`: none for ON UPDATE CASCADE (the new key is the parent's
        /// own new key, written by this statement), the changed foreign keys,
        /// or all of them (SET DEFAULT).
        fn cascadeUpdate(self: *Self, slot: u16, table_index: usize, old: u32, cells: *const E.Row, check: ReferenceCheck, snap: Snapshot) Error!void {
            const table = &self.tables[table_index];
            const context = self.bindContext("", .standard, snap);
            var flags: [config.table_constraints]bool = @splat(true);
            var checks: [config.table_constraints]u16 = @splat(ast.none);
            try B.bindFlaggedChecks(&context, table_index, &flags, &checks);
            var ctx = self.evalContext("");
            try D.checkRow(&ctx, table, &checks, cells);
            const row = table.versions[old].row - 1;
            if (table.primary_column) |column| if (V.compare(&cells[column], &table.versions[old].cells[column]) != 0) switch (D.keyCheck(table, &cells[column], row, snap)) {
                .free => {},
                .taken => return error.PrimaryKeyViolation,
                .wait => |owner| {
                    var waits: L.Set = .{};
                    waits.add(owner);
                    return self.park(slot, waits);
                },
            };
            if ((try self.uniqueTaken(slot, table_index, cells, row, &table.versions[old].cells, snap)) != null) return error.PrimaryKeyViolation;
            try self.exclusionTaken(slot, table_index, cells, row, &table.versions[old].cells, snap);
            if (check != .none) try self.checkReferences(slot, table_index, cells, if (check == .all) null else &table.versions[old].cells, snap);
            try self.referencedChange(slot, table_index, &table.versions[old].cells, cells, snap);
            if (table.versions[old].xmax.epoch != 0) return;
            try self.placeUpdate(slot, table_index, row, old, cells, snap);
        }

        /// Writes the new version of `row` over `old` (checks done).
        fn placeUpdate(self: *Self, slot: u16, table_index: usize, row: u32, old: u32, cells: *const E.Row, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const table = &self.tables[table_index];
            try self.reserveWrites(slot, 1);
            try S.ensureVersions(table, 1, self.horizon());
            const version = S.allocVersion(table);
            table.versions[version] = .{ .row = row + 1, .xmin = tx.ref(slot), .xmin_cid = snap.cid, .older = old + 1, .cells = cells.* };
            table.rows[row].newest = version + 1;
            table.versions[old].xmax = tx.ref(slot);
            table.versions[old].xmax_cid = snap.cid;
            S.indexKey(table, version);
            tx.push(.{ .kind = .update, .table = @intCast(table_index), .old = old, .new = version }) catch unreachable;
        }

        /// SET CONSTRAINTS: the transaction's ALL or per-name modes. Setting
        /// IMMEDIATE checks every outstanding deferred row first; a
        /// violation keeps the previous modes and fails the statement.
        fn setConstraints(self: *Self, slot: u16, set: *const B.SetConstraints) Error!void {
            const tx = &self.txs[slot];
            const saved_all = tx.constraints_all;
            const saved_count = tx.constraint_mode_count;
            const saved = tx.constraint_modes;
            errdefer {
                tx.constraints_all = saved_all;
                tx.constraint_mode_count = saved_count;
                tx.constraint_modes = saved;
            }
            if (set.all) {
                tx.constraints_all = set.deferred;
                tx.constraint_mode_count = 0;
            } else for (set.names[0..set.count]) |reference| {
                const mode: M.ConstraintMode = .{ .oid = reference.oid, .name = reference.name, .deferred = set.deferred };
                for (tx.constraint_modes[0..tx.constraint_mode_count]) |*existing| {
                    if (existing.oid == mode.oid and types.same(existing.name.slice(), mode.name.slice())) {
                        existing.deferred = mode.deferred;
                        break;
                    }
                } else {
                    if (tx.constraint_mode_count == config.constraint_modes) return error.TableCapacity;
                    tx.constraint_modes[tx.constraint_mode_count] = mode;
                    tx.constraint_mode_count += 1;
                }
            }
            if (!set.deferred) try self.deferredCheck(slot, 0, true);
        }

        /// The deferred checks of a transaction (COMMIT, SET CONSTRAINTS
        /// IMMEDIATE) over the newest state, without waiting: every live
        /// row it wrote satisfies its deferrable UNIQUE (23505) and FOREIGN
        /// KEY (23503) constraints, and no live row references a key it
        /// removed under a deferrable NO ACTION foreign key (23503). A
        /// conflicting version of another live transaction is left to that
        /// transaction's own check, which then sees this commit.
        pub fn deferredViolation(self: *const Self, slot: u16) Error!void {
            // SERIALIZABLE: a doomed transaction or pivot cannot commit.
            if (self.active(slot)) if (self.txs[slot].ssi) |index| try self.ssi.check(index);
            return self.deferredCheck(slot, 0, false);
        }

        /// Writes from `start`; `immediate_only` skips constraints whose
        /// mode is DEFERRED now (statement end, SET CONSTRAINTS IMMEDIATE).
        fn deferredCheck(self: *const Self, slot: u16, start: usize, immediate_only: bool) Error!void {
            const tx = &self.txs[slot];
            if (!tx.active or !tx.deferred_checks) return;
            const snap: Snapshot = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid +% 1 };
            for (tx.writes[start..tx.write_len]) |entry| {
                if (entry.kind != .insert and entry.kind != .update and entry.kind != .delete) continue;
                const table = &self.tables[entry.table];
                if (!table.live or table.pending_drop) continue;
                if (entry.kind != .delete) {
                    const version = &table.versions[entry.new];
                    if (version.row != 0 and version.xmax.epoch == 0) try self.deferredRow(slot, table, &version.cells, version.row - 1, immediate_only, snap);
                }
                if (entry.kind != .insert) try self.deferredParent(slot, table, &table.versions[entry.old].cells, immediate_only, snap);
            }
        }

        fn deferredRow(self: *const Self, slot: u16, table: *const S.Table, cells: *const E.Row, row: u32, immediate_only: bool, snap: Snapshot) Error!void {
            for (table.constraints[0..table.constraint_count], 0..) |*constraint, position| {
                if (!constraint.deferrable or (immediate_only and self.deferredNow(slot, table, position))) continue;
                switch (constraint.kind) {
                    .unique, .primary => switch (S.uniqueCheck(table, constraint, cells, row, snap)) {
                        .taken => return error.PrimaryKeyViolation,
                        .free, .wait => {},
                    },
                    .exclusion => switch (try exclusionCheck(table, constraint, cells, row, snap)) {
                        .taken => return error.ExclusionViolation,
                        .free, .wait => {},
                    },
                    .foreign => {
                        var has_null = false;
                        for (constraint.keyColumns()) |column| has_null = has_null or cells[column] == .null_value;
                        if (has_null) continue;
                        const parent_index = self.visibleTableSlot(constraint.ref_oid, snap) orelse return error.ForeignKeyViolation;
                        if (liveKey(&self.tables[parent_index], constraint.refColumns(), cells, constraint.keyColumns(), snap) == .missing) return error.ForeignKeyViolation;
                    },
                    else => {},
                }
            }
        }

        /// A key this transaction removed or changed in `table`: unless the
        /// key is live again, no live row may reference it through a
        /// deferrable foreign key.
        fn deferredParent(self: *const Self, slot: u16, table: *const S.Table, old: *const E.Row, immediate_only: bool, snap: Snapshot) Error!void {
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') continue;
                const child = &self.tables[found.slot];
                for (child.constraints[0..child.constraint_count], 0..) |*constraint, position| {
                    if (constraint.kind != .foreign or !constraint.deferrable or constraint.ref_oid != table.oid) continue;
                    if (immediate_only and self.deferredNow(slot, child, position)) continue;
                    var has_null = false;
                    for (constraint.refColumns()) |column| has_null = has_null or old[column] == .null_value;
                    if (has_null) continue;
                    if (liveKey(table, constraint.refColumns(), old, constraint.refColumns(), snap) != .missing) continue;
                    if (liveKey(child, constraint.keyColumns(), old, constraint.refColumns(), snap) != .missing) return error.ForeignKeyViolation;
                }
            }
        }

        /// Whether constraint `position` of `table` is deferred now in the
        /// transaction (SET CONSTRAINTS, else INITIALLY DEFERRED).
        fn deferredNow(self: *const Self, slot: u16, table: *const S.Table, position: usize) bool {
            const constraint = &table.constraints[position];
            if (!constraint.deferrable) return false;
            const tx = &self.txs[slot];
            for (tx.constraint_modes[0..tx.constraint_mode_count]) |mode| {
                if (mode.oid == table.oid and types.same(mode.name.slice(), constraint.name.slice())) return mode.deferred;
            }
            if (tx.constraints_all) |deferred| return deferred;
            return constraint.initially_deferred;
        }

        /// The partition (leaf) of a partitioned table that admits the row
        /// (else its DEFAULT partition, else 23514), row-exclusive locked;
        /// any partition's own bound is checked (23514).
        fn routeRow(self: *Self, slot: u16, table_index: usize, cells: *const E.Row, snap: Snapshot) Error!usize {
            var current = table_index;
            var depth: usize = 0;
            while (self.tables[current].relkind == 'p') : (depth += 1) {
                if (depth == config.tables) return error.CheckViolation;
                const parent = &self.tables[current];
                const key = &cells[parent.partition.key];
                var chosen: ?usize = null;
                var fallback: ?usize = null;
                var relations: [K.relation_rows]K.Found = undefined;
                const count = self.catalog.visibleRelations(snap, &relations);
                for (relations[0..count]) |found| {
                    if (found.kind == 'S') continue;
                    const child = &self.tables[found.slot];
                    if (child.parent != parent.oid) continue;
                    if (child.partition.bound == .default) fallback = found.slot else if (S.partitionContains(&child.partition, key)) chosen = found.slot;
                }
                current = chosen orelse fallback orelse return error.CheckViolation;
                try self.lockTable(slot, current, .row_exclusive);
            }
            try self.partitionBound(current, cells, snap);
            return current;
        }

        /// A row of partition `index` must satisfy its bound (a DEFAULT
        /// partition: no sibling's bound) - 23514.
        fn partitionBound(self: *const Self, index: usize, cells: *const E.Row, snap: Snapshot) Error!void {
            const table = &self.tables[index];
            if (table.parent == 0 or table.partition.bound == .none) return;
            const parent_slot = self.visibleTableSlot(table.parent, snap) orelse return;
            const key = &cells[self.tables[parent_slot].partition.key];
            if (table.partition.bound != .default) {
                if (!S.partitionContains(&table.partition, key)) return error.CheckViolation;
                return;
            }
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S' or found.slot == index) continue;
                const sibling = &self.tables[found.slot];
                if (sibling.parent == table.parent and S.partitionContains(&sibling.partition, key)) return error.CheckViolation;
            }
        }

        /// Whether table `slot` is a partition (at any depth) of `ancestor`.
        fn descends(self: *const Self, slot: usize, ancestor: usize) bool {
            var current = slot;
            for (0..config.tables) |_| {
                const parent = self.tables[current].parent;
                if (parent == 0) return false;
                if (parent == self.tables[ancestor].oid) return true;
                current = for (&self.tables, 0..) |*table, position| {
                    if (table.live and !table.pending_drop and table.oid == parent) break position;
                } else return false;
            }
            return false;
        }

        /// The conflicting version of an ON CONFLICT arbiter, null when the
        /// key is free; a live writer of the key parks the statement.
        fn arbiterTaken(self: *Self, slot: u16, table_index: usize, arbiter: B.Arbiter, cells: *const E.Row, snap: Snapshot) Error!?u32 {
            const table = &self.tables[table_index];
            const state: S.KeyState = switch (arbiter) {
                .primary, .any => blk: {
                    const column = table.primary_column orelse break :blk .free;
                    break :blk switch (D.keyCheck(table, &cells[column], 0xffffffff, snap)) {
                        .free => .free,
                        .taken => |version| .{ .taken = version },
                        .wait => |owner| .{ .wait = owner },
                    };
                },
                .constraint => |index| S.uniqueCheck(table, &table.constraints[index], cells, 0xffffffff, snap),
                .index => |which| S.indexUniqueCheck(table, which, cells, 0xffffffff, snap),
            };
            switch (state) {
                .free => {},
                .taken => |version| return version,
                .wait => |owner| {
                    var waits: L.Set = .{};
                    waits.add(owner);
                    return self.park(slot, waits);
                },
            }
            if (arbiter == .any) return self.uniqueTaken(slot, table_index, cells, 0xffffffff, null, snap);
            return null;
        }

        /// UNIQUE and composite PRIMARY KEY checks after the key index
        /// (23505 for the caller): the conflicting version, null when free;
        /// a live writer of the same key parks the statement like a primary
        /// key does. An UPDATE (`old`) skips constraints whose key it keeps.
        fn uniqueTaken(self: *Self, slot: u16, table_index: usize, cells: *const E.Row, own_slot: u32, old: ?*const E.Row, snap: Snapshot) Error!?u32 {
            const table = &self.tables[table_index];
            for (table.constraints[0..table.constraint_count], 0..) |*constraint, position| {
                if (!S.scannedUnique(table, constraint)) continue;
                if (old) |previous| if (!S.keyChanged(constraint, previous, cells)) continue;
                // A DEFERRABLE constraint is checked at the end of the
                // statement (IMMEDIATE) or at COMMIT (DEFERRED).
                _ = position;
                if (constraint.deferrable) {
                    self.txs[slot].deferred_checks = true;
                    continue;
                }
                switch (S.uniqueCheck(table, constraint, cells, own_slot, snap)) {
                    .free => {},
                    .taken => |version| return version,
                    .wait => |owner| {
                        var waits: L.Set = .{};
                        waits.add(owner);
                        return self.park(slot, waits);
                    },
                }
            }
            // UNIQUE indexes (CREATE UNIQUE INDEX) probe their own entries.
            for (table.indexes[0..table.index_count], 0..) |*index, which| {
                if (!index.unique) continue;
                if (old) |previous| {
                    var changed = false;
                    for (index.keyColumns()) |column| {
                        if (@as(V.CellTag, previous[column]) != @as(V.CellTag, cells[column]) or V.compare(&previous[column], &cells[column]) != 0) changed = true;
                    }
                    if (!changed) continue;
                }
                switch (S.indexUniqueCheck(table, which, cells, own_slot, snap)) {
                    .free => {},
                    .taken => |version| return version,
                    .wait => |owner| {
                        var waits: L.Set = .{};
                        waits.add(owner);
                        return self.park(slot, waits);
                    },
                }
            }
            return null;
        }

        /// Secondary index probe of a committed table by index name, for
        /// contracts that compare the index path with a scan: the number of
        /// rows visible to the committed view whose plain key columns equal
        /// `key` (in index key order), from the index (`probe`) or a scan.
        pub fn indexMatches(self: *const Self, table_name: []const u8, index_name: []const u8, key: []const Cell, probe: bool) ?usize {
            const index = self.committedIndex(table_name) orelse return null;
            const table = &self.tables[index];
            for (table.indexes[0..table.index_count], 0..) |*definition, which| {
                if (!types.same(definition.name.slice(), index_name)) continue;
                var cells: E.Row = @splat(.null_value);
                var position: usize = 0;
                for (definition.keyColumns()) |column| {
                    if (column == S.expression_key) continue;
                    if (position == key.len) return null;
                    cells[column] = key[position];
                    position += 1;
                }
                var found: [64]u32 = undefined;
                return if (probe) S.indexLookup(table, which, &cells, storage.committed_view, &found) else S.scanLookup(table, which, &cells, storage.committed_view, &found);
            }
            return null;
        }

        /// Index entries of every secondary index of a table, and whether
        /// each equals the table's allocated versions (no stale entry).
        pub fn indexConsistent(self: *const Self, table_name: []const u8) ?bool {
            const index = self.committedIndex(table_name) orelse return null;
            const table = &self.tables[index];
            for (0..table.index_count) |which| {
                if (S.indexEntries(table, which) != table.version_used) return false;
            }
            return true;
        }

        /// Places a new row version (key already checked). Capacity errors
        /// leave the table and write set unchanged.
        fn appendRow(self: *Self, slot: u16, table_index: usize, cells: *const E.Row, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const table = &self.tables[table_index];
            if (table.next_rowid == 0xffffffffffffffff) return error.RowCapacity;
            try self.reserveWrites(slot, 1);
            const at = self.horizon();
            try S.ensureVersions(table, 1, at);
            try S.ensureRowSlot(table, at);
            const row = S.allocRow(table, table.next_rowid);
            table.next_rowid += 1;
            const version = S.allocVersion(table);
            table.versions[version] = .{ .row = row + 1, .xmin = tx.ref(slot), .xmin_cid = snap.cid, .cells = cells.* };
            table.rows[row].newest = version + 1;
            S.indexKey(table, version);
            tx.push(.{ .kind = .insert, .table = @intCast(table_index), .new = version }) catch unreachable;
        }

        // ---- COPY (design §4.7, §5.17) ----------------------------------

        /// Validated COPY options with PostgreSQL's defaults filled in.
        pub const CopyOptions = struct {
            format: ast.CopyFormat = .text,
            delimiter: u8 = '\t',
            null_bytes: [64]u8 = @splat(0),
            null_len: usize = 0,
            quote: u8 = '"',
            escape: u8 = '"',
            header: ast.CopyHeader = .off,

            pub fn nullString(self: *const CopyOptions) []const u8 {
                return self.null_bytes[0..self.null_len];
            }
        };

        /// What a codec needs to run a COPY. FROM: the target columns of
        /// each data field, in field order. TO: the length of the SELECT
        /// written into the caller's buffer (the codec runs it as a query).
        pub const CopyInfo = struct {
            direction: ast.CopyDirection = .from,
            options: CopyOptions = .{},
            count: usize = 0,
            names: [config.columns]Name = @splat(.{}),
            types: [config.columns]DataType = @splat(.integer),
            typmods: [config.columns]i32 = @splat(-1),
            select_len: usize = 0,
        };

        pub const copy_line_bytes = config.copy_line_bytes;

        /// PostgreSQL ProcessCopyOptions (PostgreSQL 16 SQLSTATEs): binary
        /// with DELIMITER/NULL 42601; non-single-byte DELIMITER/QUOTE/ESCAPE,
        /// QUOTE/ESCAPE outside CSV, HEADER in binary and HEADER MATCH in
        /// COPY TO 0A000; newline delimiters/NULL, a text delimiter from
        /// `\.a-z0-9`, delimiter = quote and delimiter or quote inside NULL
        /// 22023. NULL longer than 64 bytes is TextCapacity (54000).
        fn copyOptions(given: *const ast.CopyOptions, direction: ast.CopyDirection) Error!CopyOptions {
            const binary = given.format == .binary;
            const csv = given.format == .csv;
            if (binary and given.delimiter.set) return error.Syntax;
            if (binary and given.null_string.set) return error.Syntax;
            var out: CopyOptions = .{ .format = given.format, .header = given.header };
            if (given.delimiter.set) {
                if (given.delimiter.len != 1) return error.UnsupportedStatement;
                out.delimiter = given.delimiter.bytes[0];
            } else out.delimiter = if (csv) ',' else '\t';
            if (given.null_string.set) {
                if (given.null_string.len > out.null_bytes.len) return error.TextCapacity;
                out.null_len = given.null_string.len;
                @memcpy(out.null_bytes[0..out.null_len], given.null_string.bytes[0..out.null_len]);
            } else if (!csv) {
                out.null_len = 2;
                @memcpy(out.null_bytes[0..2], "\\N");
            }
            const null_text = out.nullString();
            if (out.delimiter == '\r' or out.delimiter == '\n') return error.InvalidParameterValue;
            for (null_text) |byte| if (byte == '\r' or byte == '\n') return error.InvalidParameterValue;
            if (!csv) {
                for ("\\.abcdefghijklmnopqrstuvwxyz0123456789") |byte| if (out.delimiter == byte) return error.InvalidParameterValue;
            }
            if (binary and given.header != .off) return error.UnsupportedStatement;
            if (given.header == .match and direction == .to) return error.UnsupportedStatement;
            if (!csv and given.quote.set) return error.UnsupportedStatement;
            if (csv) {
                if (given.quote.set) {
                    if (given.quote.len != 1) return error.UnsupportedStatement;
                    out.quote = given.quote.bytes[0];
                }
                if (out.delimiter == out.quote) return error.InvalidParameterValue;
            }
            if (!csv and given.escape.set) return error.UnsupportedStatement;
            if (csv) {
                out.escape = out.quote;
                if (given.escape.set) {
                    if (given.escape.len != 1) return error.UnsupportedStatement;
                    out.escape = given.escape.bytes[0];
                }
            }
            for (null_text) |byte| if (byte == out.delimiter) return error.InvalidParameterValue;
            if (csv) for (null_text) |byte| if (byte == out.quote) return error.InvalidParameterValue;
            return out;
        }

        fn parseCopy(self: *Self, source: []const u8) Error!A.Copy {
            const parsed = try P.parse(source, &self.workspace.nodes, .standard);
            return switch (parsed) {
                .copy => |copy| copy,
                else => error.UnsupportedStatement,
            };
        }

        fn appendText(out: []u8, used: *usize, bytes: []const u8) Error!void {
            if (bytes.len > out.len - used.*) return error.TextCapacity;
            @memcpy(out[used.*..][0..bytes.len], bytes);
            used.* += bytes.len;
        }

        fn appendQuoted(out: []u8, used: *usize, name: []const u8) Error!void {
            try appendText(out, used, "\"");
            for (name) |byte| {
                if (byte == '"') try appendText(out, used, "\"\"") else try appendText(out, used, &[_]u8{byte});
            }
            try appendText(out, used, "\"");
        }

        /// Parses and validates a COPY statement and binds its target under
        /// the snapshot of `slot` (or the committed state). Never executes,
        /// locks or writes. COPY TO writes the equivalent SELECT into
        /// `select` (`(query)` verbatim; a table lists its non-generated
        /// columns or the given ones).
        pub fn copyInfo(self: *Self, slot: ?u16, source: []const u8, select: []u8) Error!CopyInfo {
            const copy = try self.parseCopy(source);
            var info: CopyInfo = .{ .direction = copy.direction, .options = try copyOptions(&copy.options, copy.direction) };
            var snap: Snapshot = .{ .csn = self.csn };
            if (slot) |owner| if (self.active(owner)) {
                snap = .{ .csn = self.csn, .slot = owner, .epoch = self.txs[owner].epoch, .cid = self.txs[owner].cid +% 1 };
            };
            if (copy.query) |span| {
                var used: usize = 0;
                try appendText(select, &used, span.slice(source));
                info.select_len = used;
                return info;
            }
            const context = self.bindContext(source, .standard, snap);
            const bound = try B.bindCopy(&context, &copy, false);
            const table = &self.tables[bound.table];
            info.count = bound.count;
            for (bound.mapping[0..bound.count], 0..) |column, field| {
                info.names[field] = table.columns[column].name;
                info.types[field] = table.columns[column].data_type;
                info.typmods[field] = table.columns[column].typmod;
            }
            if (copy.direction == .to) {
                var used: usize = 0;
                try appendText(select, &used, "SELECT ");
                for (bound.mapping[0..bound.count], 0..) |column, field| {
                    if (field != 0) try appendText(select, &used, ", ");
                    try appendQuoted(select, &used, table.columns[column].name.slice());
                }
                try appendText(select, &used, " FROM ");
                try appendQuoted(select, &used, table.name.slice());
                info.select_len = used;
            }
            return info;
        }

        /// Opens a COPY FROM in transaction `slot`: a statement
        /// subtransaction that stays open until copyEnd (rows) or a terminal
        /// error (abort/failScope/abortStatement roll the whole COPY back).
        /// A table-lock wait returns WouldBlock; re-deliver with `resuming`.
        pub fn copyBegin(self: *Self, slot: u16, source: []const u8, resuming: bool) Error!CopyInfo {
            if (!self.active(slot)) return error.NoActiveTransaction;
            const tx = &self.txs[slot];
            var snap: Snapshot = undefined;
            if (resuming) {
                const pinned = tx.pin orelse return error.QueryCanceled;
                snap = pinned;
                if (tx.fresh) snap.csn = self.csn;
                tx.pin = null;
                tx.fresh = false;
            } else {
                if (tx.pin != null or tx.copy_table != null) return error.QueryCanceled;
                const copy = try self.parseCopy(source);
                if (copy.direction != .from) return error.UnsupportedStatement;
                _ = try copyOptions(&copy.options, copy.direction);
                if (tx.sub_len >= M.sub_capacity) return error.SavepointCapacity;
                tx.cid +%= 1;
                snap = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid };
                if (tx.read_only) return error.ReadOnlyTransaction;
                if (tx.snapshot_csn == null) {
                    tx.snapshot_csn = self.csn;
                    tx.snapshot_cid = tx.cid;
                }
                if (transactionSnapshot(tx.isolation)) snap.csn = tx.snapshot_csn.?;
                tx.subs[tx.sub_len] = .{ .statement = true, .write_start = @intCast(tx.write_len), .lock_start = @intCast(tx.lock_len) };
                tx.sub_len += 1;
            }
            tx.running_snap = snap;
            defer tx.running_snap = null;
            const info = self.openCopy(slot, source, snap) catch |err| {
                if (err == error.WouldBlock) {
                    tx.pin = snap;
                    return err;
                }
                self.dropStatement(slot);
                self.wake_epoch +%= 1;
                return err;
            };
            return info;
        }

        fn openCopy(self: *Self, slot: u16, source: []const u8, snap: Snapshot) Error!CopyInfo {
            self.installRole();
            const tx = &self.txs[slot];
            const copy = try self.parseCopy(source);
            const context = self.bindContext(source, .standard, snap);
            const bound = try B.bindCopy(&context, &copy, false);
            try self.lockTable(slot, bound.table, .row_exclusive);
            if (!self.privilegedRole(snap)) {
                try self.needTable(bound.table, CO.priv_insert, snap);
                // COPY FROM is not supported with row-level security (0A000).
                if (self.catalog_objects.rowSecurity(self.session.role, self.tables[bound.table].oid, snap)) return error.UnsupportedStatement;
            }
            var info: CopyInfo = .{ .direction = .from, .options = try copyOptions(&copy.options, .from), .count = bound.count };
            const table = &self.tables[bound.table];
            for (bound.mapping[0..bound.count], 0..) |column, field| {
                info.names[field] = table.columns[column].name;
                info.types[field] = table.columns[column].data_type;
                info.typmods[field] = table.columns[column].typmod;
            }
            tx.waiting_for = .{};
            tx.table_wait = null;
            tx.copy_table = @intCast(bound.table);
            tx.copy_snap = snap;
            tx.copy_rows = 0;
            return info;
        }

        fn statementHooks(self: *Self, slot: u16, snap: Snapshot) void {
            self.seq_hook = .{ .ptr = self, .call = &sequenceCall, .relation_name = &relationName, .catalog_text = &catalogText };
            self.session.sequences = &self.seq_hook;
            self.seq_slot = slot;
            self.seq_snap = snap;
            self.workspace.query.views = .{ .ptr = self, .rows = &viewRows };
            self.session_hook = .{ .ptr = self, .call = &sessionCall };
            self.session.engine = &self.session_hook;
            self.routine_hook = .{ .ptr = self, .call = &routineHookCall };
            self.session.routines = &self.routine_hook;
            self.session.routine_frame = null;
            self.routine_slot = slot;
            self.routine_snap = snap;
            self.routine_frame = null;
            self.routine_depth = 0;
            self.routine_nested = 0;
            self.installRole();
        }

        /// One COPY FROM data row: `fields[p]` is field p's text (null =
        /// NULL) for the column copyBegin reported at p. Applies the input
        /// functions, then defaults (identity nextval, DEFAULT) for the other
        /// columns and generated columns, and validates like INSERT. Writes
        /// nothing; a sequence value drawn by a default is consumed as in
        /// PostgreSQL. Errors are terminal for the COPY.
        pub fn copyBuild(self: *Self, slot: u16, source: []const u8, fields: []const ?[]const u8, out: *Row) Error!void {
            if (!self.active(slot)) return error.NoActiveTransaction;
            const tx = &self.txs[slot];
            const table_index = tx.copy_table orelse return error.NoActiveTransaction;
            const copy = try self.parseCopy(source);
            const snap = tx.copy_snap;
            const context = self.bindContext(source, .standard, snap);
            const bound = try B.bindCopy(&context, &copy, true);
            if (bound.table != table_index) return error.TableNotFound;
            if (fields.len != bound.count) return error.BadCopyFormat;
            const table = &self.tables[table_index];
            self.statementHooks(slot, snap);
            var provided: [config.columns]?Cell = @splat(null);
            for (fields, 0..) |field, position| {
                const column = &table.columns[bound.mapping[position]];
                provided[bound.mapping[position]] = if (field) |text| try Io.parse(types.typeOfData(column.data_type), column.typmod, text, &self.session) else .null_value;
            }
            var ctx = self.evalContext(source);
            out.cells = try D.copiedRow(&ctx, table, &provided, .{ .defaults = &bound.defaults, .generated = &bound.generated, .checks = &bound.checks });
        }

        /// Inserts a built row under the open COPY. A key held by a live
        /// inserter or deleter parks the COPY (WouldBlock, row kept by the
        /// caller); calling again with the same row re-checks it (inserted,
        /// or 23505 once the other inserter committed).
        pub fn copyInsert(self: *Self, slot: u16, row: *const Row) Error!void {
            if (!self.active(slot)) return error.NoActiveTransaction;
            const tx = &self.txs[slot];
            const table_index = tx.copy_table orelse return error.NoActiveTransaction;
            tx.pin = null;
            tx.waiting_for = .{};
            const snap = tx.copy_snap;
            const table = &self.tables[table_index];
            if (table.primary_column) |column| switch (D.keyCheck(table, &row.cells[column], 0xffffffff, snap)) {
                .free => {},
                .taken => return error.PrimaryKeyViolation,
                .wait => |owner| {
                    var waits: L.Set = .{};
                    waits.add(owner);
                    tx.pin = snap;
                    return self.park(slot, waits);
                },
            };
            if (self.uniqueTaken(slot, table_index, &row.cells, 0xffffffff, null, snap)) |taken| {
                if (taken != null) return error.PrimaryKeyViolation;
            } else |err| {
                if (err == error.WouldBlock) tx.pin = snap;
                return err;
            }
            self.exclusionTaken(slot, table_index, &row.cells, 0xffffffff, null, snap) catch |err| {
                if (err == error.WouldBlock) tx.pin = snap;
                return err;
            };
            self.checkReferences(slot, table_index, &row.cells, null, snap) catch |err| {
                if (err == error.WouldBlock) tx.pin = snap;
                return err;
            };
            try self.partitionBound(table_index, &row.cells, snap);
            try self.appendRow(slot, table_index, &row.cells, snap);
            tx.copy_rows += 1;
        }

        /// Completes the open COPY FROM: merges its subtransaction into the
        /// transaction and records the outcome (COPY n). Returns n.
        pub fn copyEnd(self: *Self, slot: u16) Error!usize {
            if (!self.active(slot)) return error.NoActiveTransaction;
            const tx = &self.txs[slot];
            if (tx.copy_table == null) return error.NoActiveTransaction;
            const rows = tx.copy_rows;
            tx.copy_table = null;
            tx.copy_rows = 0;
            tx.pin = null;
            tx.sub_len -= 1;
            tx.waiting_for = .{};
            tx.table_wait = null;
            self.outcome = .{ .affected = rows, .command = .copy };
            return rows;
        }

        /// True while `slot` has an open COPY FROM.
        pub fn copyActive(self: *const Self, slot: u16) bool {
            return self.active(slot) and self.txs[slot].copy_table != null;
        }

        /// AccessShare on every table a statement's plans read (INSERT ...
        /// SELECT, UPDATE FROM, DELETE USING, subqueries), after the target's
        /// RowExclusive and before any row is touched (STO-11): concurrent
        /// TRUNCATE, ALTER and DROP wait for the statement's transaction.
        fn lockSources(self: *Self, slot: u16) Error!void {
            const plans = &self.workspace.plans;
            for (plans.items[0..plans.len]) |*plan| {
                for (plan.sources[0..plan.source_count]) |*item| if (item.table) |table| try self.lockTable(slot, table, .access_share);
            }
        }

        /// MERGE (PostgreSQL ExecMerge under READ COMMITTED): the source rows
        /// are materialized once under the statement snapshot; for each, every
        /// target row the ON condition matches takes the first WHEN MATCHED
        /// clause whose condition holds (UPDATE, DELETE or DO NOTHING), and a
        /// source row with no match the first WHEN NOT MATCHED clause (INSERT
        /// or DO NOTHING); then target rows no source row matched take the
        /// first WHEN NOT MATCHED BY SOURCE clause. A target row changed twice
        /// is 21000. Live writers are waited for (EvalPlanQual re-checks ON on
        /// the newest version; a row that no longer matches is left alone).
        /// A resumed statement continues after the source rows it handled.
        fn mergeRows(self: *Self, slot: u16, source: []const u8, merge: *const B.Merge, snap: Snapshot) Error!usize {
            const tx = &self.txs[slot];
            const done = tx.progress;
            const table = &self.tables[merge.table];
            var ctx = self.evalContext(source);
            const joined = (try self.joinedRows(source, merge.source, &merge.offsets, snap)) orelse return 0;
            const work = &self.workspace.query;
            var position: usize = 0;
            for (0..joined.list.count) |index| {
                defer position += 1;
                if (position < done) continue;
                try self.session.checkpoint();
                const row = X.rowAt(work, joined.list, index);
                for (1..config.relations) |relation| ctx.tuple[relation] = row + joined.offsets[relation];
                var matched = false;
                for (0..table.row_high) |target_row| {
                    if (table.rows[target_row].newest == 0) continue;
                    const version = S.visibleAt(table, target_row, snap) orelse continue;
                    if (!try X.keep(&ctx, merge.on, &table.versions[version].cells)) continue;
                    matched = true;
                    try self.mergeMatched(slot, &ctx, merge, @intCast(target_row), version, false, snap);
                }
                if (!matched) try self.mergeInsert(slot, &ctx, merge, snap);
                tx.progress = position + 1;
            }
            var by_source = false;
            for (merge.whens[0..merge.when_count]) |*when| by_source = by_source or when.by_source;
            if (by_source) for (0..table.row_high) |target_row| {
                defer position += 1;
                if (position < done) continue;
                try self.session.checkpoint();
                if (table.rows[target_row].newest == 0) continue;
                const version = S.visibleAt(table, target_row, snap) orelse continue;
                var matched = false;
                for (0..joined.list.count) |index| {
                    const row = X.rowAt(work, joined.list, index);
                    for (1..config.relations) |relation| ctx.tuple[relation] = row + joined.offsets[relation];
                    if (try X.keep(&ctx, merge.on, &table.versions[version].cells)) matched = true;
                }
                if (!matched) {
                    for (1..config.relations) |relation| ctx.tuple[relation] = null;
                    try self.mergeMatched(slot, &ctx, merge, @intCast(target_row), version, true, snap);
                }
                tx.progress = position + 1;
            };
            return tx.progress_affected;
        }

        fn mergeMatched(self: *Self, slot: u16, ctx: *E.Context, merge: *const B.Merge, row: u32, version: u32, by_source: bool, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const table = &self.tables[merge.table];
            var chosen: ?*const B.MergeWhen = null;
            var waits: L.Set = .{};
            const plan = try self.target(slot, merge.table, version, snap, .write, &waits);
            const goal = switch (plan) {
                .wait => return self.park(slot, waits),
                .authored => return error.CardinalityViolation,
                .skip => return,
                .ready => |newest| newest,
            };
            const cells = &table.versions[goal].cells;
            if (!by_source and goal != version and !try X.keep(ctx, merge.on, cells)) return;
            for (merge.whens[0..merge.when_count]) |*when| {
                if (!when.matched or when.by_source != by_source) continue;
                if (when.condition != ast.none and !try X.keep(ctx, when.condition, cells)) continue;
                chosen = when;
                break;
            }
            const when = chosen orelse return;
            switch (when.action) {
                .update => {
                    const update: B.Update = .{ .table = merge.table, .values = when.values, .where = ast.none, .key = ast.none, .defaults = when.defaults, .generated = when.generated, .checks = merge.checks };
                    if (!try self.updateOne(slot, ctx, &update, row, goal, snap)) return;
                },
                .delete => {
                    if (self.rowHooks(merge.table, routine_catalog.tg_delete, '4', snap) and !try self.beforeRow(merge.table, routine_catalog.tg_delete, null, cells, null, snap)) return;
                    try self.referencedChange(slot, merge.table, cells, null, snap);
                    if (table.versions[goal].xmax.epoch == 0) {
                        try self.reserveWrites(slot, 1);
                        table.versions[goal].xmax = tx.ref(slot);
                        table.versions[goal].xmax_cid = snap.cid;
                        tx.push(.{ .kind = .delete, .table = @intCast(merge.table), .old = goal }) catch unreachable;
                    }
                },
                .nothing, .insert => return,
            }
            tx.progress_affected += 1;
        }

        fn mergeInsert(self: *Self, slot: u16, ctx: *E.Context, merge: *const B.Merge, snap: Snapshot) Error!void {
            const nulls: E.Row = @splat(.null_value);
            for (merge.whens[0..merge.when_count]) |*when| {
                if (when.matched) continue;
                if (when.condition != ast.none and !try X.keep(ctx, when.condition, &nulls)) continue;
                if (when.action != .insert) return;
                const insert: B.Insert = .{ .table = merge.table, .defaults = when.defaults, .generated = when.generated, .checks = merge.checks };
                const derived: D.Derived = .{ .defaults = &when.defaults, .generated = &when.generated, .checks = &merge.checks };
                const affected = try self.insertOne(slot, ctx, &insert, &when.values, derived, snap);
                self.txs[slot].progress_affected += affected;
                return;
            }
        }

        /// UPDATE FROM / DELETE USING source rows, materialized once per
        /// statement execution under the statement snapshot.
        const Joined = struct { list: X.List, offsets: *const [config.relations]u16 };

        fn joinedRows(self: *Self, source: []const u8, root: u16, offsets: *const [config.relations]u16, snap: Snapshot) Error!?Joined {
            if (root == ast.none) return null;
            const list = try X.queryRows(&self.tables, source, &self.workspace.nodes, &self.workspace.plans, root, snap, &self.session, &self.workspace.query);
            return .{ .list = list, .offsets = offsets };
        }

        /// WHERE over the target row and, with FROM/USING, the first joined
        /// source row that satisfies it (PostgreSQL updates or deletes a
        /// target row once, with one arbitrary matching source row). The
        /// matching row stays installed in `ctx` for SET.
        fn keepJoined(self: *Self, ctx: *E.Context, where: u16, joined: ?Joined, cells: *const E.Row) Error!bool {
            const join = joined orelse return X.keep(ctx, where, cells);
            for (0..join.list.count) |index| {
                const row = X.rowAt(&self.workspace.query, join.list, index);
                for (1..config.relations) |relation| ctx.tuple[relation] = row + join.offsets[relation];
                if (try X.keep(ctx, where, cells)) return true;
            }
            return false;
        }

        /// Rows are visited in rowid order and updated one at a time, as a
        /// PostgreSQL heap scan does: WHERE, SET and key checks interleave.
        /// On resume, rows this statement already handled are skipped by
        /// authorship and still counted.
        fn updateRows(self: *Self, slot: u16, source: []const u8, update: *const B.Update, snap: Snapshot) Error!usize {
            const table = &self.tables[update.table];
            var ctx = self.evalContext(source);
            var affected: usize = 0;
            const joined = try self.joinedRows(source, update.from, &update.offsets, snap);
            switch (try X.candidates(&ctx, table, update.key, snap)) {
                .empty => {},
                .slot => |hit| affected += try self.updateSlot(slot, &ctx, update, hit.row, snap, joined),
                .scan => {
                    const high = table.row_high;
                    for (0..high) |row| affected += try self.updateSlot(slot, &ctx, update, @intCast(row), snap, joined);
                },
            }
            return affected;
        }

        fn updateSlot(self: *Self, slot: u16, ctx: *E.Context, update: *const B.Update, row: u32, snap: Snapshot, joined: ?Joined) Error!usize {
            try self.session.checkpoint();
            const table = &self.tables[update.table];
            if (table.rows[row].newest == 0) return 0;
            const version = S.visibleAt(table, row, snap) orelse return 0;
            var waits: L.Set = .{};
            const plan = try self.target(slot, update.table, version, snap, .write, &waits);
            if (plan == .authored) return 1;
            if (!try self.keepJoined(ctx, update.where, joined, &table.versions[version].cells)) return 0;
            const goal = switch (plan) {
                .skip, .authored => return 0,
                .wait => return self.park(slot, waits),
                .ready => |newest| newest,
            };
            if (goal != version and !try self.keepJoined(ctx, update.where, joined, &table.versions[goal].cells)) return 0;
            return @intFromBool(try self.updateOne(slot, ctx, update, row, goal, snap));
        }

        /// Returns false when a BEFORE ROW trigger or a rule skipped the row.
        fn updateOne(self: *Self, slot: u16, ctx: *E.Context, update: *const B.Update, row: u32, old: u32, snap: Snapshot) Error!bool {
            const tx = &self.txs[slot];
            const table = &self.tables[update.table];
            const derived: D.Derived = .{ .defaults = &update.defaults, .generated = &update.generated, .checks = &update.checks };
            const hooked = self.rowHooks(update.table, routine_catalog.tg_update, '2', snap);
            var cells = if (hooked) try D.updatedRowDeferred(ctx, table, &update.values, derived, &table.versions[old].cells) else try D.updatedRow(ctx, table, &update.values, derived, &table.versions[old].cells);
            if (hooked) {
                if (try self.ruleSkips(update.table, '2', &cells, &table.versions[old].cells, snap)) return false;
                if (!try self.beforeRow(update.table, routine_catalog.tg_update, &cells, &table.versions[old].cells, &update.values, snap)) return false;
                try D.finishRow(ctx, table, derived, &cells);
            }
            try self.securityCheck(ctx, update.table, &cells);
            try self.partitionBound(update.table, &cells, snap);
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
            if ((try self.uniqueTaken(slot, update.table, &cells, row, &table.versions[old].cells, snap)) != null) return error.PrimaryKeyViolation;
            try self.exclusionTaken(slot, update.table, &cells, row, &table.versions[old].cells, snap);
            try self.checkReferences(slot, update.table, &cells, &table.versions[old].cells, snap);
            try self.referencedChange(slot, update.table, &table.versions[old].cells, &cells, snap);
            // A referential action of this statement may have replaced it.
            if (table.versions[old].xmax.epoch != 0) return true;
            _ = tx;
            try self.placeUpdate(slot, update.table, row, old, &cells, snap);
            return true;
        }

        fn deleteRows(self: *Self, slot: u16, source: []const u8, delete: *const B.Delete, snap: Snapshot) Error!usize {
            const table = &self.tables[delete.table];
            var ctx = self.evalContext(source);
            var affected: usize = 0;
            const joined = try self.joinedRows(source, delete.using, &delete.offsets, snap);
            switch (try X.candidates(&ctx, table, delete.key, snap)) {
                .empty => {},
                .slot => |hit| affected += try self.deleteSlot(slot, &ctx, delete, hit.row, snap, joined),
                .scan => {
                    const high = table.row_high;
                    for (0..high) |row| affected += try self.deleteSlot(slot, &ctx, delete, @intCast(row), snap, joined);
                },
            }
            return affected;
        }

        fn deleteSlot(self: *Self, slot: u16, ctx: *E.Context, delete: *const B.Delete, row: u32, snap: Snapshot, joined: ?Joined) Error!usize {
            try self.session.checkpoint();
            const tx = &self.txs[slot];
            const table = &self.tables[delete.table];
            if (table.rows[row].newest == 0) return 0;
            const version = S.visibleAt(table, row, snap) orelse return 0;
            var waits: L.Set = .{};
            const plan = try self.target(slot, delete.table, version, snap, .write, &waits);
            if (plan == .authored) return 1;
            if (!try self.keepJoined(ctx, delete.where, joined, &table.versions[version].cells)) return 0;
            const goal = switch (plan) {
                .skip, .authored => return 0,
                .wait => return self.park(slot, waits),
                .ready => |newest| newest,
            };
            if (goal != version and !try self.keepJoined(ctx, delete.where, joined, &table.versions[goal].cells)) return 0;
            if (self.rowHooks(delete.table, routine_catalog.tg_delete, '4', snap)) {
                if (try self.ruleSkips(delete.table, '4', null, &table.versions[goal].cells, snap)) return 0;
                if (!try self.beforeRow(delete.table, routine_catalog.tg_delete, null, &table.versions[goal].cells, null, snap)) return 0;
            }
            try self.referencedChange(slot, delete.table, &table.versions[goal].cells, null, snap);
            // A self-referencing CASCADE of this statement already deleted it.
            if (table.versions[goal].xmax.epoch != 0) return 1;
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
                    .create_sequence => try C.encodeCreateSequence(writer, &self.seqs[entry.table]),
                    .drop_sequence => try C.encodeDropSequence(writer, self.seqs[entry.table].oid),
                    .truncate => try C.encodeTruncate(writer, self.tables[entry.table].oid),
                    .alter_sequence => try C.encodeAlterSequence(writer, &self.seqs[entry.table]),
                    .create_schema => try C.encodeCreateSchema(writer, self.schemas[entry.table].oid, self.schemas[entry.table].name.slice()),
                    .drop_schema => try C.encodeDropSchema(writer, self.schemas[entry.table].oid),
                    .alter_table => {
                        const table = &self.tables[entry.table];
                        try C.encodeAlter(writer, table, self.alters[entry.table].sources[0..table.column_count], self.alters[entry.table].fills[0..table.column_count]);
                    },
                    .catalog_insert, .catalog_delete => {},
                    .create_object, .drop_object => try self.encodeObject(writer, entry.kind == .create_object, @enumFromInt(entry.new), entry.table),
                    .object_insert => {
                        try writer.op(.object_create);
                        try O.encodeCreate(writer, &self.catalog_objects.items[entry.new]);
                    },
                    .object_delete => {
                        try writer.op(.object_drop);
                        try O.encodeDrop(writer, &self.catalog_objects.items[entry.old]);
                    },
                }
            }
            // At most one log-ahead value per sequence: this transaction's
            // and every carried one (newest value wins).
            var pending = tx.seq_dirty;
            pending.merge(&self.seq_carried);
            for (&self.seqs, 0..) |*seq, index| {
                if (!pending.has(index) or !seq.live or seq.dead_csn != 0) continue;
                if (seq.pending_create and seq.creator != slot) continue;
                if (seq.pending_drop and seq.creator == slot) continue;
                try C.encodeSequenceValue(writer, seq.oid, seq.logged_value, seq.logged_called);
            }
        }

        // ---- tx-session lane (session.sig, ssi.sig) ----------------------
        //
        // Transaction modes, engine settings, cursors, SQL prepared
        // statements, LOCK TABLE, advisory locks and LISTEN/NOTIFY. Session
        // state belongs to the caller's connection (session_state).

        fn transactionSnapshot(level: M.Level) bool {
            return level == .repeatable_read or level == .serializable;
        }

        /// PostgreSQL's PlannedStmtRequiresSnapshot: transaction control,
        /// SET/SHOW/RESET, LOCK TABLE, SET CONSTRAINTS, FETCH/MOVE and
        /// LISTEN/NOTIFY/UNLISTEN run without taking the first snapshot.
        fn needsSnapshot(parsed: *const A.Statement) bool {
            return switch (parsed.*) {
                .control, .set_constraints => false,
                .session => |*command| switch (command.*) {
                    .lock_table, .fetch, .listen, .unlisten, .notify => false,
                    else => true,
                },
                else => true,
            };
        }

        fn levelOf(isolation: ast.Isolation, current: M.Level) M.Level {
            return switch (isolation) {
                .default => current,
                .read_uncommitted => .read_uncommitted,
                .read_committed => .read_committed,
                .repeatable_read => .repeatable_read,
                .serializable => .serializable,
            };
        }

        fn levelName(level: M.Level) []const u8 {
            return switch (level) {
                .read_committed => "read committed",
                .read_uncommitted => "read uncommitted",
                .repeatable_read => "repeatable read",
                .serializable => "serializable",
            };
        }

        fn parseLevel(text: []const u8) ?M.Level {
            if (Sess.sameInsensitive(text, "read committed")) return .read_committed;
            if (Sess.sameInsensitive(text, "read uncommitted")) return .read_uncommitted;
            if (Sess.sameInsensitive(text, "repeatable read")) return .repeatable_read;
            if (Sess.sameInsensitive(text, "serializable")) return .serializable;
            return null;
        }

        /// PostgreSQL parse_bool: on/off, true/false, yes/no, 1/0 and unique
        /// prefixes of true/false/yes/no.
        fn parseBool(text: []const u8) ?bool {
            if (text.len == 0) return null;
            if (Sess.sameInsensitive(text, "on") or Sess.sameInsensitive(text, "1")) return true;
            if (Sess.sameInsensitive(text, "0")) return false;
            if (text.len >= 2 and text.len <= 3 and Sess.sameInsensitive(text, "off"[0..text.len])) return false;
            for ([_][]const u8{ "true", "yes" }) |word| if (text.len <= word.len and Sess.sameInsensitive(text, word[0..text.len])) return true;
            for ([_][]const u8{ "false", "no" }) |word| if (text.len <= word.len and Sess.sameInsensitive(text, word[0..text.len])) return false;
            return null;
        }

        fn onOff(value: bool) []const u8 {
            return if (value) "on" else "off";
        }

        fn sessionState(self: *Self) *Sess.State {
            const state = self.session_state orelse &self.default_session_state;
            if (state.id == 0) {
                self.session_counter += 1;
                state.id = self.session_counter;
            }
            return state;
        }

        /// The installed session state when it follows transaction `slot`.
        fn ownSession(self: *Self, slot: u16) ?*Sess.State {
            const state = self.sessionState();
            const tx = &self.txs[slot];
            if (state.id != tx.session or state.tx_epoch != tx.epoch) return null;
            return state;
        }

        /// Transaction end for the lane: SERIALIZABLE record, committed
        /// LISTEN/UNLISTEN and NOTIFY (in that order, so a session sees its
        /// own notifications), cursors and the settings stack.
        fn endSessionTransaction(self: *Self, slot: u16, committed: bool) void {
            const tx = &self.txs[slot];
            if (tx.ssi) |index| {
                if (committed) self.ssi.commit(index, self.csn) else self.ssi.abort(index);
                tx.ssi = null;
            }
            const state = self.ownSession(slot);
            if (committed) {
                if (state) |owner| self.notify.applyListen(owner);
                self.notify.publish(slot, tx.epoch);
            } else self.notify.discard(slot, tx.epoch, 0, null);
            self.cursors.endTransaction(slot, tx.epoch, committed);
            if (state) |owner| owner.endTransaction(committed);
            self.statement_settings_cid = null;
        }

        /// ROLLBACK TO (min_depth = savepoint index + 1) or a failed scope
        /// (min_depth = savepoint count, `fail`): cursors, NOTIFY entries and
        /// LISTEN actions taken inside it are dropped.
        fn sessionRollback(self: *Self, slot: u16, min_depth: usize, fail: bool) void {
            const tx = &self.txs[slot];
            self.cursors.rollbackTo(slot, tx.epoch, min_depth);
            self.notify.discard(slot, tx.epoch, min_depth, null);
            if (self.ownSession(slot)) |state| {
                state.discardListen(min_depth);
                if (fail) state.failScope();
            }
        }

        /// SERIALIZABLE: the statement that took the transaction snapshot
        /// registers the SSI record; READ ONLY DEFERRABLE instead waits for a
        /// safe snapshot (no active SERIALIZABLE read-write transaction
        /// holds a snapshot) and then runs untracked.
        fn serializableSnapshot(self: *Self, slot: u16) Error!void {
            const tx = &self.txs[slot];
            if (tx.isolation != .serializable or tx.ssi != null) return;
            const csn = tx.snapshot_csn orelse return;
            if (tx.snapshot_cid != tx.cid) return;
            if (tx.read_only and tx.deferrable) {
                var waits: L.Set = .{};
                for (&self.txs, 0..) |*other, index| {
                    if (index != slot and other.active and other.isolation == .serializable and !other.read_only and other.snapshot_csn != null) waits.add(index);
                }
                if (waits.any()) {
                    tx.fresh = true;
                    return self.park(slot, waits);
                }
                return;
            }
            tx.ssi = self.ssi.register(slot, tx.epoch, csn) catch |err| {
                tx.snapshot_csn = null;
                return err;
            };
        }

        fn ssiRead(self: *Self, slot: u16, table: usize) Error!void {
            if (self.txs[slot].ssi) |index| try self.ssi.read(index, table);
        }

        fn ssiWrite(self: *Self, slot: u16, table: usize) Error!void {
            if (self.txs[slot].ssi) |index| try self.ssi.write(index, table);
        }

        /// READ ONLY transactions (25006 before anything runs): only plain
        /// queries and SET CONSTRAINTS.
        fn readOnlyCheck(bound: *const B.Bound, plans: *const B.Plans) Error!void {
            switch (bound.*) {
                .select => |*select| if (select.lock.strength != .none) return error.ReadOnlyTransaction,
                .query => if (plans.dml_len != 0) return error.ReadOnlyTransaction,
                .set_constraints, .control => {},
                else => return error.ReadOnlyTransaction,
            }
        }

        /// BEGIN / SET TRANSACTION modes with PostgreSQL's check hooks
        /// (25001 after the first query or inside a subtransaction).
        fn applyModes(self: *Self, slot: u16, modes: ast.Characteristics, from_begin: bool) Error!void {
            const tx = &self.txs[slot];
            const in_sub = tx.userSavepoints() != 0;
            const started = tx.snapshot_csn != null;
            const level = levelOf(modes.isolation, tx.isolation);
            if (!from_begin and level != tx.isolation and (started or in_sub)) return error.ActiveSqlTransaction;
            var read_only = tx.read_only;
            if (modes.read_only) |value| {
                if (!from_begin and !value and tx.read_only and (started or in_sub)) return error.ActiveSqlTransaction;
                read_only = value;
            }
            var deferrable = tx.deferrable;
            if (modes.deferrable) |value| {
                if (!from_begin and (started or in_sub)) return error.ActiveSqlTransaction;
                deferrable = value;
            }
            tx.isolation = level;
            tx.read_only = read_only;
            tx.deferrable = deferrable;
        }

        const SettingKind = enum { search_path, default_transaction_isolation, default_transaction_read_only, default_transaction_deferrable, transaction_isolation, transaction_read_only, transaction_deferrable, custom, role };

        fn settingKind(name: []const u8) ?SettingKind {
            inline for (@typeInfo(SettingKind).@"enum".field_names) |field| {
                if (!types.same(field, "custom") and Sess.sameInsensitive(name, field)) return @field(SettingKind, field);
            }
            // Placeholder variables: prefix.name of identifier characters.
            var dot = false;
            if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') return null;
            for (name) |byte| {
                if (byte == '.') {
                    dot = true;
                } else if (!(types.letter(byte) or types.digit(byte) or byte == '$' or byte >= 0x80)) return null;
            }
            return if (dot) .custom else null;
        }

        /// Settings PostgreSQL has that the caller (Store) implements.
        fn callerSetting(name: []const u8) bool {
            for ([_][]const u8{ "timezone", "datestyle", "intervalstyle", "application_name", "client_encoding", "statement_timeout", "lock_timeout", "deadlock_timeout", "standard_conforming_strings", "server_version", "server_encoding", "integer_datetimes" }) |known| {
                if (Sess.sameInsensitive(name, known)) return true;
            }
            return false;
        }

        /// True when the engine owns setting `name` (callers route SET,
        /// SHOW and RESET of it here).
        pub fn engineSetting(name: []const u8) bool {
            return settingKind(name) != null;
        }

        fn lowerInto(out: *Sess.SettingText, text: []const u8) Error!void {
            try out.set(text);
            for (out.bytes[0..out.len]) |*byte| byte.* = types.lower(byte.*);
        }

        /// quote_identifier: plain lower-case identifiers stay bare.
        fn appendIdentifier(out: []u8, used: *usize, name: []const u8) Error!void {
            var plain = name.len != 0 and (types.lower(name[0]) == name[0]) and (types.letter(name[0]));
            for (name) |byte| plain = plain and (byte == '_' or types.digit(byte) or (byte >= 'a' and byte <= 'z'));
            if (plain) {
                var tokens: lexer.Tokenizer = .{ .source = name, .text_limit = config.text_bytes };
                const token = tokens.next() catch return error.InvalidSettingValue;
                plain = token.kind == .word and !lexer.reserved(token.keyword);
            }
            const extra: usize = if (plain) 0 else 2;
            var quotes: usize = 0;
            for (name) |byte| if (byte == '"') {
                quotes += 1;
            };
            if (name.len + quotes + extra > out.len - used.*) return error.SessionCapacity;
            if (!plain) {
                out[used.*] = '"';
                used.* += 1;
            }
            for (name) |byte| {
                out[used.*] = byte;
                used.* += 1;
                if (byte == '"') {
                    out[used.*] = '"';
                    used.* += 1;
                }
            }
            if (!plain) {
                out[used.*] = '"';
                used.* += 1;
            }
        }

        /// search_path as PostgreSQL flattens it (GUC_LIST_QUOTE). Name
        /// resolution here is fixed (pg_catalog, then public), so only lists
        /// that resolve the same way are accepted: `public` plus any of
        /// "$user", pg_catalog and pg_temp (0A000 otherwise).
        fn searchPath(raw: []const u8, kind: SettingValueKind, out: *Sess.SettingText) Error!void {
            var buffer: [config.setting_bytes]u8 = undefined;
            var used: usize = 0;
            var public = false;
            var elements: usize = 0;
            var element: [128]u8 = undefined;
            if (kind == .string) {
                if (raw.len > element.len) return error.SessionCapacity;
                @memcpy(element[0..raw.len], raw);
                try pathElement(element[0..raw.len], &buffer, &used, &elements, &public);
            } else {
                var tokens: lexer.Tokenizer = .{ .source = raw, .text_limit = config.text_bytes };
                var expect = true;
                while (true) {
                    const token = tokens.next() catch return error.InvalidSettingValue;
                    if (token.kind == .end) break;
                    if (!expect) {
                        if (token.kind != .symbol or token.symbol != .comma) return error.InvalidSettingValue;
                        expect = true;
                        continue;
                    }
                    if (token.len > element.len) return error.SessionCapacity;
                    switch (token.kind) {
                        .word => for (token.raw(raw), 0..) |byte, index| {
                            element[index] = types.lower(byte);
                        },
                        .quoted_word => lexer.decodeQuotedWith(raw, .{ .start = token.start, .end = token.end, .len = token.len }, '"', &element),
                        .string => lexer.decodeQuoted(raw, token.quoted(), &element),
                        else => return error.InvalidSettingValue,
                    }
                    try pathElement(element[0..token.len], &buffer, &used, &elements, &public);
                    expect = false;
                }
                if (expect and elements != 0) return error.InvalidSettingValue;
            }
            if (!public) return error.UnsupportedStatement;
            try out.set(buffer[0..used]);
        }

        fn pathElement(name: []const u8, buffer: []u8, used: *usize, elements: *usize, public: *bool) Error!void {
            if (types.same(name, "public")) {
                public.* = true;
            } else if (!(types.same(name, "$user") or types.same(name, "pg_catalog") or types.same(name, "pg_temp"))) return error.UnsupportedStatement;
            if (elements.* != 0) {
                if (buffer.len - used.* < 2) return error.SessionCapacity;
                buffer[used.*] = ',';
                buffer[used.* + 1] = ' ';
                used.* += 2;
            }
            try appendIdentifier(buffer, used, name);
            elements.* += 1;
        }

        fn assignSetting(into: *Sess.Values, which: SettingKind, name: []const u8, kind: SettingValueKind, value: []const u8) Error!void {
            switch (which) {
                .search_path => try searchPath(value, kind, &into.search_path),
                .default_transaction_isolation => into.isolation = parseLevel(value) orelse return error.InvalidSettingValue,
                .default_transaction_read_only => into.read_only = parseBool(value) orelse return error.InvalidSettingValue,
                .default_transaction_deferrable => into.deferrable = parseBool(value) orelse return error.InvalidSettingValue,
                .custom => {
                    const index = into.findCustom(name) orelse blk: {
                        for (&into.custom, 0..) |*entry, candidate| if (!entry.used) {
                            entry.* = .{ .used = true };
                            try lowerInto(&entry.name, name);
                            break :blk candidate;
                        };
                        return error.SessionCapacity;
                    };
                    if (kind == .word) try lowerInto(&into.custom[index].value, value) else try into.custom[index].value.set(value);
                },
                .transaction_isolation, .transaction_read_only, .transaction_deferrable => return error.UnsupportedStatement,
                // SET ROLE resolves against the catalog (setSetting).
                .role => return error.UnsupportedStatement,
            }
        }

        /// Copies one setting from `source` into `target`.
        fn copySetting(into: *Sess.Values, source: *const Sess.Values, which: SettingKind, name: []const u8) Error!void {
            switch (which) {
                .search_path => into.search_path = source.search_path,
                .default_transaction_isolation => into.isolation = source.isolation,
                .default_transaction_read_only => into.read_only = source.read_only,
                .default_transaction_deferrable => into.deferrable = source.deferrable,
                .custom => {
                    if (source.findCustom(name)) |index| {
                        try assignSetting(into, .custom, name, .string, source.custom[index].value.slice());
                    } else if (into.findCustom(name)) |index| {
                        // A reset placeholder stays defined, empty.
                        into.custom[index].value.len = 0;
                    }
                },
                .transaction_isolation, .transaction_read_only, .transaction_deferrable => {},
                .role => into.role = source.role,
            }
        }

        /// SET [LOCAL] name {TO|=} value | DEFAULT, and set_config. `slot`
        /// is null outside a transaction block (SET LOCAL then has no
        /// effect, as PostgreSQL warns).
        fn setSetting(self: *Self, slot: ?u16, local: bool, name: []const u8, kind: SettingValueKind, value: []const u8) Error!void {
            const which = settingKind(name) orelse {
                if (self.settings_provider) |provider| {
                    if (try provider.set(provider.context, name, value, local, kind == .default)) return;
                }
                return if (callerSetting(name)) error.UnsupportedStatement else error.UndefinedSetting;
            };
            const state = self.sessionState();
            switch (which) {
                .transaction_isolation, .transaction_read_only, .transaction_deferrable => {
                    const owner = slot orelse return;
                    var modes: ast.Characteristics = .{};
                    switch (which) {
                        .transaction_isolation => {
                            const level = if (kind == .default) state.values.isolation else parseLevel(value) orelse return error.InvalidSettingValue;
                            modes.isolation = switch (level) {
                                .read_committed => .read_committed,
                                .read_uncommitted => .read_uncommitted,
                                .repeatable_read => .repeatable_read,
                                .serializable => .serializable,
                            };
                        },
                        .transaction_read_only => modes.read_only = if (kind == .default) state.values.read_only else parseBool(value) orelse return error.InvalidSettingValue,
                        else => modes.deferrable = if (kind == .default) state.values.deferrable else parseBool(value) orelse return error.InvalidSettingValue,
                    }
                    return self.applyModes(owner, modes, false);
                },
                else => {},
            }
            var next = state.values;
            if (kind == .default) {
                try copySetting(&next, &state.startup, which, name);
            } else if (which == .role) {
                next.role = try self.roleSetting(slot, kind, value);
            } else try assignSetting(&next, which, name, kind, value);
            if (slot != null) try state.preserve();
            if (local) {
                if (slot != null) state.values = next;
                return;
            }
            if (slot == null) {
                state.values = next;
                state.base = next;
                return;
            }
            var base = state.base;
            try copySetting(&base, &next, which, name);
            state.values = next;
            state.base = base;
        }

        /// The snapshot a setting reads the catalog under: the running
        /// statement's, else the committed state.
        fn settingSnapshot(self: *const Self, slot: ?u16) Snapshot {
            if (slot) |owner| if (self.active(owner)) {
                if (self.txs[owner].running_snap) |snap| return snap;
            };
            return .{ .csn = self.csn };
        }

        /// SET ROLE name (variable.c check_role): NONE, or a role the
        /// session user is a member of (any membership; superusers may
        /// become any role). An unknown role is 22023, a role the session
        /// user may not become 42501.
        fn roleSetting(self: *Self, slot: ?u16, kind: SettingValueKind, value: []const u8) Error!u32 {
            var folded: [64]u8 = undefined;
            if (value.len > folded.len) return error.InvalidSettingValue;
            var length: usize = 0;
            if (kind == .word and value.len >= 2 and value[0] == '"') {
                // A quoted identifier keeps its case; "" is one quote.
                var index: usize = 1;
                while (index + 1 < value.len) : (index += 1) {
                    folded[length] = value[index];
                    length += 1;
                    if (value[index] == '"') index += 1;
                }
                if (length == 0) return error.InvalidSettingValue;
            } else {
                for (value, 0..) |byte, index| folded[index] = if (kind == .word) types.lower(byte) else byte;
                length = value.len;
                if (kind == .word and types.same(folded[0..length], "none")) return 0;
            }
            const name = folded[0..length];
            const snap = self.settingSnapshot(slot);
            const oid = self.catalog_objects.roleByName(name, snap) orelse return error.InvalidSettingValue;
            const session_role = self.sessionState().session_role;
            if (!self.catalog_objects.superuser(session_role, snap) and !self.catalog_objects.memberOf(session_role, oid, false, snap)) return error.InsufficientPrivilege;
            return oid;
        }

        /// current_user / session_user of the next statement, from the
        /// session state (SET ROLE).
        fn installRole(self: *Self) void {
            const state = self.session_state orelse &self.default_session_state;
            self.session.session_role = state.session_role;
            self.session.role = if (state.values.role != 0) state.values.role else state.session_role;
        }

        /// RESET ALL of the engine settings (transaction modes excepted).
        fn resetSettings(self: *Self, slot: ?u16) Error!void {
            const state = self.sessionState();
            if (slot != null) try state.preserve();
            state.values = state.startup;
            state.base = state.startup;
        }

        /// The current text of setting `name` (engine, else the provider).
        fn settingText(self: *Self, slot: ?u16, name: []const u8, out: []u8) Error!usize {
            const which = settingKind(name) orelse {
                if (self.settings_provider) |provider| {
                    if (provider.show(provider.context, name, out)) |length| return length;
                }
                return if (callerSetting(name)) error.UnsupportedStatement else error.UndefinedSetting;
            };
            const state = self.sessionState();
            const tx: ?*const M.Tx = if (slot) |owner| (if (self.active(owner)) &self.txs[owner] else null) else null;
            const text: []const u8 = switch (which) {
                .search_path => state.values.search_path.slice(),
                .default_transaction_isolation => levelName(state.values.isolation),
                .default_transaction_read_only => onOff(state.values.read_only),
                .default_transaction_deferrable => onOff(state.values.deferrable),
                .transaction_isolation => levelName(if (tx) |t| t.isolation else state.values.isolation),
                .transaction_read_only => onOff(if (tx) |t| t.read_only else state.values.read_only),
                .transaction_deferrable => onOff(if (tx) |t| t.deferrable else state.values.deferrable),
                .custom => blk: {
                    const index = state.values.findCustom(name) orelse return error.UndefinedSetting;
                    break :blk state.values.custom[index].value.slice();
                },
                .role => if (state.values.role == 0) "none" else self.catalog_objects.roleName(state.values.role, self.settingSnapshot(slot)) orelse "none",
            };
            if (text.len > out.len) return error.TextCapacity;
            @memcpy(out[0..text.len], text);
            return text.len;
        }

        /// SHOW name: one text column named after the setting.
        fn showSetting(self: *Self, slot: ?u16, name: []const u8, result: *Result) Error!void {
            var text: Text = .{};
            text.len = try self.settingText(slot, name, &text.bytes);
            if (comptime config.external_results) if (result.rows.len == 0) return error.RowCapacity;
            const length = @min(name.len, config.name_bytes);
            result.clear(0);
            result.command = .show;
            result.column_count = 1;
            result.column_names[0] = .{ .len = length };
            @memcpy(result.column_names[0].bytes[0..length], name[0..length]);
            for (result.column_names[0].bytes[0..length]) |*byte| byte.* = types.lower(byte.*);
            result.column_types[0] = .text;
            result.column_typmods[0] = -1;
            result.row_count = 1;
            result.rows[0].cells[0] = .{ .text = text };
        }

        fn setCharacteristics(self: *Self, slot: ?u16, modes: ast.Characteristics) Error!void {
            if (modes.isolation != .default) try self.setSetting(slot, false, "default_transaction_isolation", .string, levelName(levelOf(modes.isolation, .read_committed)));
            if (modes.read_only) |value| try self.setSetting(slot, false, "default_transaction_read_only", .word, onOff(value));
            if (modes.deferrable) |value| try self.setSetting(slot, false, "default_transaction_deferrable", .word, onOff(value));
        }

        /// Settings before the running statement's first set_config.
        fn saveStatementSettings(self: *Self, slot: u16) void {
            const tx = &self.txs[slot];
            if (self.statement_settings_cid) |cid| if (cid == tx.cid) return;
            const state = self.sessionState();
            self.statement_settings = state.values;
            self.statement_base = state.base;
            self.statement_settings_cid = tx.cid;
        }

        // ---- public session API (Store.Connection) -----------------------

        /// SET of an engine setting; `slot` is the open transaction block.
        pub fn sessionSet(self: *Self, slot: ?u16, local: bool, name: []const u8, kind: SettingValueKind, value: []const u8) Error!void {
            return self.setSetting(slot, local, name, kind, value);
        }

        pub fn sessionShow(self: *Self, slot: ?u16, name: []const u8, result: *Result) Error!void {
            return self.showSetting(slot, name, result);
        }

        /// Writes the current text of an engine setting into `out`.
        pub fn sessionSettingText(self: *Self, slot: ?u16, name: []const u8, out: []u8) Error!usize {
            return self.settingText(slot, name, out);
        }

        /// RESET name, or RESET ALL (null).
        pub fn sessionReset(self: *Self, slot: ?u16, name: ?[]const u8) Error!void {
            if (name) |text| return self.setSetting(slot, false, text, .default, "");
            try self.resetSettings(slot);
        }

        /// BEGIN / START TRANSACTION modes of a block just begun.
        pub fn beginModes(self: *Self, slot: u16, modes: ast.Characteristics) Error!void {
            return self.applyModes(slot, modes, true);
        }

        /// SET TRANSACTION in a block.
        pub fn setTransaction(self: *Self, slot: u16, modes: ast.Characteristics) Error!void {
            return self.applyModes(slot, modes, false);
        }

        /// SET SESSION CHARACTERISTICS AS TRANSACTION (default_transaction_*).
        pub fn sessionCharacteristics(self: *Self, slot: ?u16, modes: ast.Characteristics) Error!void {
            return self.setCharacteristics(slot, modes);
        }

        /// The next notification for the installed session (call between
        /// transactions, as PostgreSQL delivers them).
        /// Count of notifications ever committed (monotonic). A server reads
        /// it after each statement under its store lock and compares it with
        /// the value it last saw, so idle LISTEN sessions only take the lock
        /// to drain their queue when something new was published.
        pub fn notificationSequence(self: *const Self) u64 {
            return self.notify.head;
        }

        pub fn takeNotification(self: *Self, out: *Notification) bool {
            const state = self.sessionState();
            return self.notify.take(state.id, out);
        }

        /// Session end: its cursors, LISTEN registration, session-level
        /// advisory locks and prepared statements go.
        pub fn endSession(self: *Self) void {
            const state = self.sessionState();
            self.cursors.closeSession(state.id);
            self.notify.removeListener(state.id);
            self.locks.releaseAdvisoryAll(state.id);
            self.wake_epoch +%= 1;
            const id = state.id;
            state.* = .{};
            state.id = id;
        }

        pub const SessionUsage = struct { cursors: usize, cursor_rows: usize, listeners: usize, pending_notifications: usize, queued_notifications: u64, advisory_locks: usize, serializable_records: usize };

        pub fn sessionUsage(self: *const Self) SessionUsage {
            var listeners: usize = 0;
            for (&self.notify.listeners) |*listener| if (listener.used) {
                listeners += 1;
            };
            return .{ .cursors = self.cursors.openCount(), .cursor_rows = self.cursors.used_rows, .listeners = listeners, .pending_notifications = self.notify.pendingCount(), .queued_notifications = self.notify.head - self.notify.tail(), .advisory_locks = self.locks.advisoryUsed(), .serializable_records = self.ssi.used() };
        }

        // ---- statements --------------------------------------------------

        fn runControl(self: *Self, slot: u16, source: []const u8, command: ast.Control, result: *Result) Error!void {
            switch (command) {
                // Already in a transaction block: PostgreSQL warns and ignores it.
                // An implicit (autocommit) statement cannot open a block: it
                // would commit at once while the caller believes it is open.
                .begin => {
                    if (self.statement_implicit) return error.UnsupportedStatement;
                    self.outcome = .{ .command = .begin };
                },
                .commit, .rollback, .savepoint, .release, .rollback_to => return error.UnsupportedStatement,
                .set => |set| {
                    var name: ControlText = .{};
                    try settingName(source, set.name, &name);
                    var value: ControlText = .{};
                    const kind = try settingValue(source, set.value, &value);
                    try self.setSetting(slot, set.local, name.slice(), kind, value.slice());
                    self.outcome = .{ .command = .set };
                },
                .set_transaction => |modes| {
                    try self.applyModes(slot, modes, false);
                    self.outcome = .{ .command = .set };
                },
                .set_session_characteristics => |modes| {
                    try self.setCharacteristics(slot, modes);
                    self.outcome = .{ .command = .set };
                },
                .show => |setting| {
                    var name: ControlText = .{};
                    try settingName(source, setting, &name);
                    try self.showSetting(slot, name.slice(), result);
                    self.outcome = .{ .command = .show };
                },
                .reset => |setting| {
                    if (setting) |which| {
                        var name: ControlText = .{};
                        try settingName(source, which, &name);
                        try self.setSetting(slot, false, name.slice(), .default, "");
                    } else try self.resetSettings(slot);
                    self.outcome = .{ .command = .reset };
                },
            }
        }

        fn runSession(self: *Self, slot: u16, source: []const u8, command: *const A.SessionCommand, snap: Snapshot, result: *Result, mode: ParseMode) Error!void {
            const tx = &self.txs[slot];
            const state = self.sessionState();
            const depth = tx.userSavepoints();
            switch (command.*) {
                .lock_table => |*lock| {
                    try self.lockTables(slot, source, lock, snap);
                    self.outcome = .{ .command = .lock_table };
                },
                .declare => |*declare| try self.declareCursor(slot, source, declare, snap, result, mode),
                .fetch => |*fetch| try self.fetchCursor(source, fetch, result),
                .close => |close| {
                    if (close.all) {
                        self.cursors.closeSession(state.id);
                    } else {
                        var name: ControlText = .{};
                        try decodeIdent(source, close.name, &name);
                        const index = self.cursors.find(state.id, name.slice()) orelse return error.PortalNotFound;
                        self.cursors.close(index);
                    }
                    self.outcome = .{ .command = .close_cursor };
                },
                .prepare => |*prepare| try self.prepareStatement(source, prepare, snap, mode),
                .execute => |*run| try self.executePrepared(slot, source, run, snap, result, mode),
                .deallocate => |deallocate| {
                    if (deallocate.all) {
                        for (&state.prepared) |*entry| entry.used = false;
                    } else {
                        var name: ControlText = .{};
                        try decodeIdent(source, deallocate.name, &name);
                        const index = state.findPrepared(name.slice()) orelse return error.StatementNotFound;
                        state.prepared[index].used = false;
                    }
                    self.outcome = .{ .command = .deallocate };
                },
                .listen => |ident| {
                    var name: ControlText = .{};
                    try decodeIdent(source, ident, &name);
                    if (!self.notify.listenRoom(state, name.slice())) return error.SessionCapacity;
                    try state.pushListen(.listen, name.slice(), depth);
                    self.outcome = .{ .command = .listen };
                },
                .unlisten => |unlisten| {
                    if (unlisten.all) {
                        try state.pushListen(.unlisten_all, "", depth);
                    } else {
                        var name: ControlText = .{};
                        try decodeIdent(source, unlisten.name, &name);
                        try state.pushListen(.unlisten, name.slice(), depth);
                    }
                    self.outcome = .{ .command = .unlisten };
                },
                .notify => |notify| {
                    var channel: ControlText = .{};
                    try decodeIdent(source, notify.channel, &channel);
                    var payload: Text = .{};
                    if (notify.payload) |quoted| {
                        if (quoted.len > payload.bytes.len) return error.TextCapacity;
                        lexer.decodeQuoted(source, quoted, &payload.bytes);
                        payload.len = quoted.len;
                    }
                    try self.notify.enqueue(slot, tx.epoch, depth, tx.cid, channel.slice(), payload.slice(), state.pid);
                    self.outcome = .{ .command = .notify };
                },
            }
        }

        /// LOCK TABLE: each listed table (and, without ONLY, its
        /// inheritance children and partitions) in `mode`, waiting in FIFO
        /// order like any table lock (NOWAIT: 55P03). Only in a transaction
        /// block (25P01); modes above ROW EXCLUSIVE are 25006 in a READ ONLY
        /// transaction. Views are 0A000, sequences 42809.
        fn lockTables(self: *Self, slot: u16, source: []const u8, lock: anytype, snap: Snapshot) Error!void {
            if (self.statement_implicit) return error.NoActiveTransaction;
            if (self.txs[slot].read_only and @intFromEnum(lock.mode) > @intFromEnum(ast.TableLockMode.row_exclusive)) return error.ReadOnlyTransaction;
            const mode: locks_module.TableMode = switch (lock.mode) {
                .access_share => .access_share,
                .row_share => .row_share,
                .row_exclusive => .row_exclusive,
                .share_update_exclusive => .share_update_exclusive,
                .share => .share,
                .share_row_exclusive => .share_row_exclusive,
                .exclusive => .exclusive,
                .access_exclusive => .access_exclusive,
            };
            for (lock.tables[0..lock.count], lock.only[0..lock.count]) |reference, only| {
                const schema_name = if (reference.schema) |qualifier| identName(source, qualifier) else Name{};
                const namespace = namespaceFor(&self.catalog, if (reference.schema != null) schema_name.slice() else null, snap) orelse return error.UndefinedSchema;
                const found = self.catalog.findIn(namespace, identName(source, reference.name).slice(), snap) orelse return error.TableNotFound;
                switch (found.kind) {
                    'r', 'p' => {},
                    'v', 'm' => return error.UnsupportedStatement,
                    else => return error.WrongObjectType,
                }
                var members: [config.tables]usize = undefined;
                members[0] = found.slot;
                var count: usize = 1;
                if (!only) {
                    var relations: [K.relation_rows]K.Found = undefined;
                    const relation_count = self.catalog.visibleRelations(snap, &relations);
                    var next: usize = 0;
                    while (next < count) : (next += 1) {
                        const oid = self.tables[members[next]].oid;
                        for (relations[0..relation_count]) |relation| {
                            if (relation.kind == 'S' or self.tables[relation.slot].parent != oid or count == members.len) continue;
                            members[count] = relation.slot;
                            count += 1;
                        }
                    }
                }
                for (members[0..count]) |member| try self.lockTableMode(slot, member, mode, lock.nowait);
            }
        }

        /// DECLARE: runs the query under the statement snapshot and keeps its
        /// rows in the shared cursor pool.
        fn declareCursor(self: *Self, slot: u16, source: []const u8, declare: anytype, snap: Snapshot, result: *Result, mode: ParseMode) Error!void {
            const tx = &self.txs[slot];
            if (!declare.hold and self.statement_implicit) return error.NoActiveTransaction;
            if (declare.binary) return error.UnsupportedStatement;
            const state = self.sessionState();
            var name: ControlText = .{};
            try decodeIdent(source, declare.name, &name);
            if (name.len > config.name_bytes) return error.NameCapacity;
            if (self.cursors.find(state.id, name.slice()) != null) return error.DuplicatePortal;
            const index = self.cursors.free() orelse return error.SessionCapacity;
            const inner_source = source[declare.body..];
            const inner = try P.parse(inner_source, &self.workspace.nodes, mode);
            const locking = switch (inner) {
                .select, .query => |query| self.workspace.nodes.queries[query].lock.strength != .none,
                else => return error.Syntax,
            };
            // PostgreSQL: FOR UPDATE/SHARE cursors cannot be SCROLL or WITH HOLD.
            if (locking and ((declare.scroll orelse false) or declare.hold)) return error.UnsupportedStatement;
            try self.body(slot, inner_source, &inner, snap, result, mode);
            const rows = result.row_count;
            if (rows > Sess.cursor_row_capacity - self.cursors.used_rows) return error.SessionCapacity;
            const columns = result.column_count;
            const cursor = &self.cursors.slots[index];
            cursor.* = .{ .used = true, .session = state.id, .hold = declare.hold, .scroll = declare.scroll orelse true, .epoch = tx.epoch, .slot = slot, .depth = tx.userSavepoints(), .column_count = columns, .base = self.cursors.used_rows, .count = rows };
            @memcpy(cursor.name.bytes[0..name.len], name.slice());
            cursor.name.len = name.len;
            @memcpy(cursor.names[0..columns], result.column_names[0..columns]);
            @memcpy(cursor.column_types[0..columns], result.column_types[0..columns]);
            @memcpy(cursor.typmods[0..columns], result.column_typmods[0..columns]);
            for (0..rows) |row| @memcpy(self.cursors.rows[cursor.base + row].cells[0..columns], result.rows[row].cells[0..columns]);
            self.cursors.used_rows += rows;
            result.clear(0);
            self.outcome = .{ .command = .declare_cursor };
        }

        /// FETCH / MOVE (PostgreSQL's cursor positions: 0 before the first
        /// row, count + 1 after the last). A NO SCROLL cursor never moves
        /// backward (55000, "cursor can only scan forward").
        fn fetchCursor(self: *Self, source: []const u8, fetch: anytype, result: *Result) Error!void {
            const state = self.sessionState();
            var name: ControlText = .{};
            try decodeIdent(source, fetch.name, &name);
            const index = self.cursors.find(state.id, name.slice()) orelse return error.PortalNotFound;
            const cursor = &self.cursors.slots[index];
            const total = cursor.count;
            const position = cursor.position;
            const step: Sess.Move = switch (fetch.direction) {
                .absolute => Sess.absoluteMove(total, fetch.count),
                .relative => Sess.relativePosition(position, total, fetch.count),
                .forward, .backward => blk: {
                    var forward = fetch.direction == .forward;
                    if (fetch.all) break :blk Sess.relativeMove(position, total, forward, 0xffffffffffffffff);
                    if (fetch.count == 0) break :blk Sess.relativePosition(position, total, 0);
                    if (fetch.count < 0) forward = !forward;
                    break :blk Sess.relativeMove(position, total, forward, @abs(fetch.count));
                },
            };
            if (!cursor.scroll and ((step.rows != 0 and step.first <= position) or step.position < position)) return error.ObjectNotInPrerequisiteState;
            if (fetch.move) {
                cursor.position = step.position;
                self.outcome = .{ .affected = step.rows, .command = .move };
                return;
            }
            if (step.rows > result.rows.len) return error.RowCapacity;
            const columns = cursor.column_count;
            result.clear(0);
            result.command = .fetch;
            result.column_count = columns;
            @memcpy(result.column_names[0..columns], cursor.names[0..columns]);
            @memcpy(result.column_types[0..columns], cursor.column_types[0..columns]);
            @memcpy(result.column_typmods[0..columns], cursor.typmods[0..columns]);
            for (0..step.rows) |row| {
                const at = if (step.backward) step.first - row else step.first + row;
                @memcpy(result.rows[row].cells[0..columns], self.cursors.rows[cursor.base + at - 1].cells[0..columns]);
            }
            result.row_count = step.rows;
            cursor.position = step.position;
            self.outcome = .{ .command = .fetch };
        }

        fn prepareStatement(self: *Self, source: []const u8, prepare: anytype, snap: Snapshot, mode: ParseMode) Error!void {
            const state = self.sessionState();
            var name: ControlText = .{};
            try decodeIdent(source, prepare.name, &name);
            if (name.len > config.name_bytes) return error.NameCapacity;
            if (state.findPrepared(name.slice()) != null) return error.DuplicateStatement;
            var text = source[prepare.body..];
            while (text.len != 0 and (text[text.len - 1] == ';' or text[text.len - 1] == ' ' or text[text.len - 1] == '\n' or text[text.len - 1] == '\r' or text[text.len - 1] == '\t')) text = text[0 .. text.len - 1];
            if (text.len > config.prepared_bytes) return error.SessionCapacity;
            var slot_index: ?usize = null;
            for (&state.prepared, 0..) |*entry, index| if (!entry.used) {
                slot_index = index;
                break;
            };
            const index = slot_index orelse return error.SessionCapacity;
            var params: B.Parameters = .{ .count = prepare.count };
            for (0..prepare.count) |position| params.types[position] = prepare.types[position];
            // Parse analysis now, as PostgreSQL's PREPARE (42P01, 42703 ...).
            const inner = try P.parse(text, &self.workspace.nodes, mode);
            self.active_params = &params;
            defer self.active_params = null;
            var copy = inner;
            // Parse analysis checks no privileges (EXECUTE does).
            const expanded = try expandRelations(self, &self.workspace, text, snap, &copy, CO.bootstrap_role);
            var context = self.bindContext(expanded, mode, snap);
            context.describe_only = true;
            _ = try B.bind(&context, &copy);
            const entry = &state.prepared[index];
            entry.* = .{ .used = true, .count = prepare.count };
            @memcpy(entry.name.bytes[0..name.len], name.slice());
            entry.name.len = name.len;
            @memcpy(entry.text[0..text.len], text);
            entry.len = text.len;
            for (0..prepare.count) |position| {
                entry.types[position] = prepare.types[position];
                entry.typmods[position] = prepare.typmods[position];
            }
            self.outcome = .{ .command = .prepare };
        }

        /// EXECUTE: the arguments are bound without FROM, coerced to the
        /// declared types (assignment) and evaluated; the stored statement
        /// then runs as this statement with them as $1..$n.
        fn executePrepared(self: *Self, slot: u16, source: []const u8, command: anytype, snap: Snapshot, result: *Result, mode: ParseMode) Error!void {
            const state = self.sessionState();
            var name: ControlText = .{};
            try decodeIdent(source, command.name, &name);
            const index = state.findPrepared(name.slice()) orelse return error.StatementNotFound;
            const prepared = &state.prepared[index];
            // "wrong number of parameters for prepared statement" (42601).
            if (command.count != prepared.count) return error.Syntax;
            var params: B.Parameters = .{ .count = prepared.count };
            for (0..prepared.count) |position| params.types[position] = prepared.types[position];
            if (prepared.count != 0) {
                var context = self.bindContext(source, mode, snap);
                context.plans = null;
                var ids: [config.statement_parameters]u16 = undefined;
                try B.bindArguments(&context, command.args, &params, &ids);
                const eval_context = self.evalContext(source);
                for (0..prepared.count) |position| {
                    var cell = try E.eval(&eval_context, ids[position]);
                    const ty = self.workspace.nodes.nodes[ids[position]].ty;
                    if (cell != .null_value and ty != params.types[position]) cell = try Io.cast(cell, ty, params.types[position], -1, &self.session);
                    self.param_values[position] = cell;
                }
            }
            const text = prepared.source();
            const inner = try P.parse(text, &self.workspace.nodes, mode);
            self.active_params = &params;
            self.session.params = @ptrCast(&self.param_values);
            defer {
                self.active_params = null;
                self.session.params = null;
            }
            try self.body(slot, text, &inner, snap, result, mode);
        }

        /// current_setting / set_config / advisory locks / pg_backend_pid
        /// for the running statement (Session.engine).
        fn sessionCall(ptr: *anyopaque, kind: value_module.SessionCall, a: []const u8, b: []const u8, x: i64, y: i64, flags: u8, out: []u8) Error!value_module.SessionReply {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const slot = self.seq_slot;
            switch (kind) {
                .backend_pid => return .{ .integer = self.sessionState().pid },
                .current_setting => {
                    const length = self.settingText(slot, a, out) catch |err| {
                        if (err == error.UndefinedSetting and flags & 1 != 0) return .{ .null_value = true };
                        return err;
                    };
                    return .{ .len = length };
                },
                .set_config => {
                    if (a.len == 0) return error.InvalidParameterValue;
                    self.saveStatementSettings(slot);
                    try self.setSetting(slot, flags & 1 != 0, a, if (flags & 2 != 0) .default else .string, b);
                    return .{ .len = try self.settingText(slot, a, out) };
                },
                .advisory_try_lock, .advisory_unlock => {
                    const raw: u64 = if (flags & 4 != 0) (@as(u64, @bitCast(x)) << 32) | (@as(u64, @bitCast(y)) & 0xffffffff) else @bitCast(x);
                    const key: locks_module.AdvisoryKey = .{ .key = @bitCast(raw), .pair = flags & 4 != 0 };
                    const state = self.sessionState();
                    const exclusive = flags & 1 == 0;
                    if (kind == .advisory_unlock) {
                        const released = self.locks.releaseAdvisorySession(key, state.id, exclusive);
                        if (released) self.wake_epoch +%= 1;
                        return .{ .integer = if (released) 1 else 0 };
                    }
                    const xact = flags & 2 != 0;
                    var waits: L.Set = .{};
                    var conflict = false;
                    self.locks.advisoryHolders(key, state.id, exclusive, &.{}, &.{}, &waits, &conflict);
                    if (conflict) return .{ .integer = 0 };
                    const index = try self.locks.grantAdvisory(key, state.id, slot, xact, exclusive);
                    if (xact) try M.recordLock(self, slot, .{ .kind = .advisory, .table = 0, .mode = if (exclusive) 1 else 0, .index = @intCast(index) });
                    return .{ .integer = 1 };
                },
                else => return error.UnsupportedStatement,
            }
        }

        // ---- routines, triggers and rules (B11 wave 3) ------------------

        const Interp = R.Interpreter(Self);
        const tg = routine_catalog;

        /// Statement-pool state a routine expression restores.
        const PoolMark = struct { len: usize, query_len: usize, window_len: usize, complex: bool, discarded: bool, planned: bool };

        fn poolMark(pool: *const A.Pool) PoolMark {
            return .{ .len = pool.len, .query_len = pool.query_len, .window_len = pool.window_len, .complex = pool.complex, .discarded = pool.discarded_row_constants, .planned = pool.planned_nulls };
        }

        fn poolRestore(pool: *A.Pool, mark: PoolMark) void {
            pool.len = mark.len;
            pool.query_len = mark.query_len;
            pool.window_len = mark.window_len;
            pool.complex = mark.complex;
            pool.discarded_row_constants = mark.discarded;
            pool.planned_nulls = mark.planned;
        }

        /// Write-set and lock-list watermark of an EXCEPTION block.
        pub const RoutineMark = struct { writes: usize, locks: usize };

        pub fn routineCheckpoint(self: *Self) Error!void {
            return self.session.checkpoint();
        }

        pub fn routineSession(self: *const Self) *const value_module.Session {
            return &self.session;
        }

        pub fn routineType(self: *Self, source: []const u8, start: usize) Error!P.TypeAt {
            return P.parseTypeAt(source, start, &self.workspace.nodes);
        }

        /// Syntax of a routine expression (CREATE FUNCTION / DO validation).
        pub fn routineCheck(self: *Self, source: []const u8, start: usize, end: usize) Error!void {
            const pool = &self.workspace.nodes;
            const mark = poolMark(pool);
            defer poolRestore(pool, mark);
            _ = try P.parseExpressionAt(source, start, end, pool);
        }

        /// Syntax of a statement inside a routine body.
        pub fn routineCheckStatement(self: *Self, text: []const u8) Error!void {
            if (R.classify(text) != null) {
                var routine: R.Statement = undefined;
                return R.parse(text, &self.workspace.nodes, &routine);
            }
            if (self.routine_nested != 0) return error.UnsupportedStatement;
            _ = try P.parse(text, &self.workspace.nodes, .standard);
        }

        /// Parses, binds (names read `frame`'s variables) and evaluates an
        /// expression at the top of the statement pool, then restores it.
        pub fn routineEvaluate(self: *Self, frame: *R.Frame, source: []const u8, start: usize, end: usize, goal: ?*const V.Column) Error!V.Cell {
            const pool = &self.workspace.nodes;
            const mark = poolMark(pool);
            defer poolRestore(pool, mark);
            const id = try P.parseExpressionAt(source, start, end, pool);
            return self.routineValue(frame, source, id, mark.len, goal);
        }

        fn routineValue(self: *Self, frame: *R.Frame, source: []const u8, id: u16, low: usize, goal: ?*const V.Column) Error!V.Cell {
            frame.variables.node_low = low;
            frame.variables.node_high = self.workspace.nodes.len;
            var context = self.bindContext(source, .standard, self.routine_snap);
            context.plans = null;
            context.variables = &frame.variables;
            const bound = try B.bindRoutineExpression(&context, id, goal);
            var ctx = self.evalContext(source);
            ctx.frame = frame.evalFrame();
            return E.eval(&ctx, bound);
        }

        /// `(left) = (right)` (simple CASE statement arms).
        pub fn routineCompare(self: *Self, frame: *R.Frame, source: []const u8, left: R.Span, right: R.Span) Error!bool {
            const pool = &self.workspace.nodes;
            const mark = poolMark(pool);
            defer poolRestore(pool, mark);
            const a = try P.parseExpressionAt(source, left.start, left.end, pool);
            const b = try P.parseExpressionAt(source, right.start, right.end, pool);
            const id = try pool.add(.{ .kind = .binary, .op = .eq, .a = a, .b = b });
            const column: V.Column = .{ .data_type = .boolean };
            const cell = try self.routineValue(frame, source, id, mark.len, &column);
            return cell == .boolean and cell.boolean;
        }

        pub fn routineMark(self: *Self) RoutineMark {
            const tx = &self.txs[self.routine_slot];
            return .{ .writes = tx.write_len, .locks = tx.lock_len };
        }

        /// An EXCEPTION handler caught an error: undo the block's writes.
        pub fn routineRollback(self: *Self, mark: RoutineMark) void {
            M.abortSlice(self, self.routine_slot, mark.writes, mark.locks);
            self.wake_epoch +%= 1;
        }

        fn enterRoutine(self: *Self) Error!void {
            if (self.routine_depth >= config.routine_depth) return error.StackDepthExceeded;
            self.routine_depth += 1;
        }

        /// A statement of a procedure or DO block: a new command id and
        /// snapshot (READ COMMITTED), its variables bound through `frame`.
        /// Only routines started by CALL / DO run statements: inside an
        /// expression or a trigger they are 0A000. Returns the rows it
        /// processed; `capture` takes its first row (INTO).
        pub fn routineStatement(self: *Self, frame: *R.Frame, text: []const u8, capture: ?*R.Capture) Error!usize {
            if (self.routine_nested != 0) return error.UnsupportedStatement;
            const slot = self.routine_slot;
            const tx = &self.txs[slot];
            tx.cid +%= 1;
            tx.progress = 0;
            tx.progress_affected = 0;
            self.modifying[slot] = .{};
            const snap: Snapshot = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid };
            const start = tx.write_len;
            const saved_snap = self.routine_snap;
            const saved_frame = self.routine_frame;
            const saved_shared = self.session.routine_frame;
            const saved_start = self.statement_start;
            const saved_sequences = self.seq_snap;
            defer {
                self.routine_snap = saved_snap;
                self.routine_frame = saved_frame;
                self.session.routine_frame = saved_shared;
                self.statement_start = saved_start;
                self.seq_snap = saved_sequences;
            }
            self.routine_snap = snap;
            self.seq_snap = snap;
            self.routine_frame = frame;
            self.session.routine_frame = frame.evalFrame();
            self.statement_start = start;
            if (R.classify(text) != null) {
                try self.routineBody(slot, text, snap, self.routine_result orelse return error.UnsupportedStatement);
                return 0;
            }
            var parsed = try P.parse(text, &self.workspace.nodes, .standard);
            frame.variables.node_low = 0;
            frame.variables.node_high = self.workspace.nodes.len;
            const rows = try self.subStatement(slot, text, &parsed, snap, capture);
            try self.deferredCheck(slot, start, true);
            return rows;
        }

        fn subStatement(self: *Self, slot: u16, text: []const u8, parsed: *A.Statement, snap: Snapshot, capture: ?*R.Capture) Error!usize {
            if (parsed.* == .select) {
                const top = parsed.select;
                parsed.* = .{ .query = top };
                self.workspace.nodes.complex = true;
            }
            if (parsed.* != .query) {
                const result = self.routine_result orelse return error.UnsupportedStatement;
                try self.body(slot, text, parsed, snap, result, .standard);
                const outcome = self.outcome;
                if (capture) |out| {
                    const returned = &outcome.returning;
                    out.rows = if (returned.count != 0) returned.rows else 0;
                    out.count = returned.count;
                    if (returned.count != 0 and returned.rows != 0) {
                        for (0..returned.count) |column| {
                            out.cells[column] = self.workspace.query.cells[returned.base + column];
                            out.tys[column] = types.typeOfData(returned.types[column]);
                        }
                    }
                }
                return outcome.affected;
            }
            self.workspace.query.read_stats = .{};
            try self.session.checkpoint();
            // Routine statements run with the invoker's privileges (SECURITY INVOKER).
            const source = try expandRelations(self, &self.workspace, text, snap, parsed, self.session.role);
            const context = self.bindContext(source, .standard, snap);
            const bound = try B.bind(&context, parsed);
            const root = switch (bound) {
                .query => |root| root,
                else => return error.UnsupportedStatement,
            };
            const plans = &self.workspace.plans;
            for (plans.items[0..plans.len]) |*plan| {
                for (plan.sources[0..plan.source_count]) |*item| if (item.table) |table| try self.lockTable(slot, table, .access_share);
            }
            defer {
                self.workspace.query.pinned_cells = 0;
                self.workspace.query.pinned_refs = 0;
            }
            if (plans.dml_len != 0) {
                try self.modifyingCtes(slot, source, snap);
                try self.afterTriggers(slot, self.statement_start, null, snap);
            }
            const work = &self.workspace.query;
            const list = try X.queryRows(&self.tables, source, &self.workspace.nodes, plans, root, snap, &self.session, work);
            if (capture) |out| {
                const plan = &plans.items[root];
                out.rows = list.count;
                out.count = plan.count;
                if (list.count != 0) {
                    const row = X.rowAt(work, list, 0);
                    for (0..plan.count) |column| {
                        out.cells[column] = row[column];
                        out.tys[column] = plan.tys[column];
                    }
                }
            }
            self.outcome = .{ .affected = 0, .command = .select };
            return list.count;
        }

        /// CREATE / DROP FUNCTION, PROCEDURE, TRIGGER, RULE, CALL and DO.
        fn routineBody(self: *Self, slot: u16, source: []const u8, snap: Snapshot, result: *Result) Error!void {
            self.workspace.query.read_stats = .{};
            try self.session.checkpoint();
            var statement_value: R.Statement = undefined;
            try R.parse(source, &self.workspace.nodes, &statement_value);
            const kind: R.Kind = statement_value;
            const saved_result = self.routine_result;
            defer self.routine_result = saved_result;
            self.routine_result = result;
            switch (statement_value) {
                .create_function, .create_procedure => |*definition| try self.createRoutine(slot, definition, snap),
                .drop_function, .drop_procedure => |*drop| try self.dropRoutine(slot, drop, snap),
                .call => |*call| try self.restartable(slot, snap, call, source),
                .do_block => |*block| try self.restartable(slot, snap, block, source),
                .create_trigger => |*definition| try self.createTrigger(slot, source, definition, snap),
                .drop_trigger => |*drop| try self.dropTrigger(slot, drop, snap),
                .create_rule => |*definition| try self.createRule(slot, source, definition, snap),
                .drop_rule => |*drop| try self.dropRule(slot, drop, snap),
            }
            self.outcome = .{ .affected = 0, .command = R.command(kind), .noop = kind == .call or kind == .do_block };
        }

        /// CALL and DO. A statement inside that must wait for a lock undoes
        /// the routine's writes and parks it; the re-delivered statement runs
        /// the routine again from its start (docs/SQL_ROUTINES.md).
        fn restartable(self: *Self, slot: u16, snap: Snapshot, routine: anytype, source: []const u8) Error!void {
            const tx = &self.txs[slot];
            const top = self.routine_nested == 0 and tx.sub_len != 0 and tx.subs[tx.sub_len - 1].statement;
            const write_start = tx.write_len;
            const lock_start = tx.lock_len;
            const run = if (@TypeOf(routine.*) == R.Call) self.callProcedure(slot, source, routine, snap) else self.doBlock(routine);
            run catch |err| {
                if (err == error.WouldBlock and top and self.routine_depth == 0) {
                    M.abortSlice(self, slot, write_start, lock_start);
                    tx.fresh = true;
                }
                return err;
            };
        }

        fn takeOid(self: *Self) Error!u32 {
            if (self.oid_counter >= 0xffffffff - change_log.first_oid) return error.TableCapacity;
            const oid = change_log.first_oid + self.oid_counter;
            self.oid_counter += 1;
            return oid;
        }

        fn objectSlot(self: *Self, class: tg.Class) Error!usize {
            for (0..2) |attempt| {
                switch (class) {
                    .routine => for (&self.objects.routines, 0..) |*item, index| {
                        if (!item.live) return index;
                    },
                    .trigger => for (&self.objects.triggers, 0..) |*item, index| {
                        if (!item.live) return index;
                    },
                    .rule => for (&self.objects.rules, 0..) |*item, index| {
                        if (!item.live) return index;
                    },
                }
                if (attempt == 0) self.reclaimTables(self.horizon());
            }
            return error.TableCapacity;
        }

        /// Waits for another transaction's uncommitted CREATE / DROP.
        fn waitObject(self: *Self, slot: u16, other: u16) Error {
            const tx = &self.txs[slot];
            var waits: L.Set = .{};
            waits.add(other);
            tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
            return self.park(slot, waits);
        }

        /// Marks object version `index` deleted by this statement.
        fn dropObject(self: *Self, slot: u16, class: tg.Class, index: usize, snap: Snapshot) Error!void {
            try self.reserveWrites(slot, 1);
            const tx = &self.txs[slot];
            const stamp = self.objects.stampOf(class, index);
            stamp.xmax = tx.ref(slot);
            stamp.xmax_cid = snap.cid;
            stamp.xmax_csn = 0;
            tx.push(.{ .kind = .drop_object, .table = @intCast(index), .new = @intFromEnum(class) }) catch unreachable;
        }

        fn createdObject(self: *Self, slot: u16, class: tg.Class, index: usize, snap: Snapshot) void {
            const tx = &self.txs[slot];
            self.objects.stampOf(class, index).* = .{ .xmin = tx.ref(slot), .xmin_cid = snap.cid };
            self.objects.liveOf(class, index).* = true;
            tx.push(.{ .kind = .create_object, .table = @intCast(index), .new = @intFromEnum(class) }) catch unreachable;
        }

        fn columnOfOid(oid: u32, typmod: i32) V.Column {
            const data = types.typeFromOid(oid) orelse .text;
            return .{ .data_type = data, .typmod = typmod };
        }

        fn typeOfOid(oid: u32) types.Type {
            return types.typeOfData(types.typeFromOid(oid) orelse .text);
        }

        /// Parameters (and FOUND for PL/pgSQL) of a routine frame.
        fn routineParameters(frame: *R.Frame, names: []const V.Name, oids: []const u32, typmods: []const i32, routine_name: V.Name, plpgsql: bool) Error!void {
            for (names, oids, typmods) |*name, oid, typmod| _ = try frame.declare(name.slice(), typeOfOid(oid), typmod);
            frame.variables.parameters = names.len;
            frame.variables.routine_name = routine_name;
            frame.variables.conflict_error = plpgsql;
            if (plpgsql) {
                frame.found = try frame.declare("found", .boolean, -1);
                frame.cells[frame.found] = .{ .boolean = false };
            }
        }

        /// CREATE [OR REPLACE] FUNCTION / PROCEDURE: validates the body
        /// (SQL: every statement parsed, analyzable ones bound and the final
        /// result checked; PL/pgSQL: syntax of every statement), then writes
        /// a new version (the replaced one is marked deleted, same OID).
        fn createRoutine(self: *Self, slot: u16, definition: *const R.CreateRoutine, snap: Snapshot) Error!void {
            var oid_buffer: [config.routine_args]u32 = undefined;
            const args = definition.argOids(&oid_buffer);
            const namespace = catalog_module.public_namespace;
            const name = definition.name.slice();
            if (self.objects.routineWriter(namespace, name, args, snap)) |other| return self.waitObject(slot, other);
            const existing = self.objects.findRoutine(namespace, name, args, snap);
            const kind: u8 = if (definition.procedure) 'p' else 'f';
            if (existing) |index| {
                if (!definition.replace) return error.DuplicateFunction;
                const old = &self.objects.routines[index];
                if (old.kind != kind) return error.WrongObjectType;
                if (old.return_oid != definition.return_oid or old.return_typmod != definition.return_typmod) return error.InvalidFunctionDefinition;
                for (0..old.arg_count) |position| {
                    if (!types.same(old.arg_names[position].slice(), definition.args[position].name.slice())) return error.InvalidFunctionDefinition;
                }
            }
            if (definition.return_oid == tg.trigger_oid and (definition.language == 0 or definition.arg_count != 0)) return error.InvalidFunctionDefinition;
            try self.validateRoutine(definition, snap);
            try self.reserveWrites(slot, 2);
            const index = try self.objectSlot(.routine);
            const oid = if (existing) |old| self.objects.routines[old].oid else try self.takeOid();
            if (existing) |old| try self.dropObject(slot, .routine, old, snap);
            const item = &self.objects.routines[index];
            item.* = .{ .oid = oid, .namespace = namespace, .name = definition.name, .kind = kind, .language = definition.language, .volatility = definition.volatility, .strict = definition.strict, .arg_count = definition.arg_count, .return_oid = definition.return_oid, .return_typmod = definition.return_typmod, .body = definition.body };
            for (definition.args[0..definition.arg_count], 0..) |arg, position| {
                item.arg_names[position] = arg.name;
                item.arg_oids[position] = arg.oid;
                item.arg_typmods[position] = arg.typmod;
            }
            self.createdObject(slot, .routine, index, snap);
        }

        fn validateRoutine(self: *Self, definition: *const R.CreateRoutine, snap: Snapshot) Error!void {
            var frame: R.Frame = .{};
            var names: [config.routine_args]V.Name = undefined;
            var oids: [config.routine_args]u32 = undefined;
            var typmods: [config.routine_args]i32 = undefined;
            for (definition.args[0..definition.arg_count], 0..) |arg, position| {
                names[position] = arg.name;
                oids[position] = arg.oid;
                typmods[position] = arg.typmod;
            }
            const count = definition.arg_count;
            const plpgsql = definition.language == 1;
            try routineParameters(&frame, names[0..count], oids[0..count], typmods[0..count], definition.name, plpgsql);
            if (plpgsql) {
                const purpose: R.Purpose = if (definition.procedure) .procedure else if (definition.return_oid == tg.trigger_oid) .trigger else .function;
                if (purpose == .trigger) try triggerVariableNames(&frame);
                var interpreter: Interp = .{ .host = self, .source = definition.body.slice(), .frame = &frame, .purpose = purpose, .void_result = definition.return_oid == tg.void_oid };
                return interpreter.execute(.check);
            }
            return self.validateSql(definition, &frame, snap);
        }

        /// The statements of a SQL routine body (PostgreSQL's
        /// check_function_bodies): analyzed until a utility statement.
        fn validateSql(self: *Self, definition: *const R.CreateRoutine, frame: *R.Frame, snap: Snapshot) Error!void {
            const text_body = definition.body.slice();
            var statements: R.Statements = .{ .source = text_body };
            var analyzable = true;
            var final_type: ?types.Type = null;
            var final_count: usize = 0;
            var final_seen = false;
            const saved_frame = self.routine_frame;
            defer self.routine_frame = saved_frame;
            while (try statements.next()) |span| {
                const text = text_body[span.start..span.end];
                final_seen = true;
                final_type = null;
                final_count = 0;
                if (R.classify(text) != null) {
                    var routine: R.Statement = undefined;
                    try R.parse(text, &self.workspace.nodes, &routine);
                    analyzable = false;
                    continue;
                }
                var parsed = try P.parse(text, &self.workspace.nodes, .standard);
                switch (parsed) {
                    .control, .copy => return error.UnsupportedStatement,
                    .select, .query, .insert, .update, .delete, .merge => {},
                    else => {
                        analyzable = false;
                        continue;
                    },
                }
                if (!analyzable) continue;
                if (parsed == .select) {
                    const top = parsed.select;
                    parsed = .{ .query = top };
                    self.workspace.nodes.complex = true;
                }
                frame.variables.node_low = 0;
                frame.variables.node_high = self.workspace.nodes.len;
                self.routine_frame = frame;
                // Body analysis checks no privileges (calls do).
                const source = try expandRelations(self, &self.workspace, text, snap, &parsed, CO.bootstrap_role);
                const context = self.bindContext(source, .standard, snap);
                const bound = try B.bind(&context, &parsed);
                self.routine_frame = saved_frame;
                switch (bound) {
                    .query => |root| {
                        const plan = &self.workspace.plans.items[root];
                        final_count = plan.count;
                        if (plan.count != 0) final_type = plan.tys[0];
                    },
                    .insert => |*insert| if (insert.returning.count != 0) {
                        final_count = insert.returning.count;
                        final_type = types.typeOfData(insert.returning.types[0]);
                    },
                    .update => |*update| if (update.returning.count != 0) {
                        final_count = update.returning.count;
                        final_type = types.typeOfData(update.returning.types[0]);
                    },
                    .delete => |*delete| if (delete.returning.count != 0) {
                        final_count = delete.returning.count;
                        final_type = types.typeOfData(delete.returning.types[0]);
                    },
                    else => {},
                }
            }
            if (definition.procedure or definition.return_oid == tg.void_oid) return;
            if (!final_seen) return error.InvalidFunctionDefinition;
            if (!analyzable) return;
            // The final statement returns one column of the result type
            // (an assignment-coercible one).
            const result = final_type orelse return error.InvalidFunctionDefinition;
            if (final_count != 1) return error.InvalidFunctionDefinition;
            const wanted = typeOfOid(definition.return_oid);
            if (result != wanted and result != .unknown and !value_module.castable(result, wanted, .assignment) and !(value_module.integral(result) and value_module.integral(wanted)))
                return error.InvalidFunctionDefinition;
        }

        /// DROP FUNCTION / PROCEDURE: the routine with the given argument
        /// types (or the only one of that name); triggers using a function
        /// are 2BP01 unless CASCADE drops them.
        fn dropRoutine(self: *Self, slot: u16, drop: *const R.DropRoutine, snap: Snapshot) Error!void {
            const namespace = catalog_module.public_namespace;
            const name = drop.name.slice();
            var found: ?usize = null;
            if (drop.has_args) {
                if (self.objects.routineWriter(namespace, name, drop.args[0..drop.arg_count], snap)) |other| return self.waitObject(slot, other);
                found = self.objects.findRoutine(namespace, name, drop.args[0..drop.arg_count], snap);
            } else {
                for (&self.objects.routines, 0..) |*item, index| {
                    if (!item.live or item.namespace != namespace or !item.stamp.visible(snap) or !types.same(item.name.slice(), name)) continue;
                    if (found != null) return error.AmbiguousFunction;
                    found = index;
                }
                if (found) |index| if (self.objects.routines[index].stamp.deleterOther(snap)) |other| return self.waitObject(slot, other);
            }
            const index = found orelse {
                if (drop.if_exists) return;
                return error.UndefinedFunction;
            };
            const routine = &self.objects.routines[index];
            if ((routine.kind == 'p') != drop.procedure) return error.WrongObjectType;
            for (&self.objects.triggers, 0..) |*trigger, position| {
                if (!trigger.live or trigger.function_oid != routine.oid or !trigger.stamp.visible(snap)) continue;
                if (!drop.cascade) return error.DependentObjects;
                try self.dropObject(slot, .trigger, position, snap);
            }
            try self.dropObject(slot, .routine, index, snap);
        }

        /// A routine argument value and its type (an untyped literal stays
        /// unknown for the resolution and is read as text).
        const Argument = struct { cell: V.Cell, ty: types.Type, unknown: bool };

        fn evaluateArgument(self: *Self, source: []const u8, span: R.Span) Error!Argument {
            const pool = &self.workspace.nodes;
            const mark = poolMark(pool);
            defer poolRestore(pool, mark);
            const id = try P.parseExpressionAt(source, span.start, span.end, pool);
            const kind = pool.nodes[id].kind;
            const unknown = kind == .text_literal or kind == .null_literal;
            var empty: R.Frame = .{};
            const frame = self.routine_frame orelse &empty;
            frame.variables.node_low = mark.len;
            frame.variables.node_high = pool.len;
            var context = self.bindContext(source, .standard, self.routine_snap);
            context.plans = null;
            context.variables = &frame.variables;
            const bound = try B.bindRoutineExpression(&context, id, null);
            var ctx = self.evalContext(source);
            ctx.frame = frame.evalFrame();
            const cell = try E.eval(&ctx, bound);
            return .{ .cell = cell, .ty = pool.nodes[bound].ty, .unknown = unknown };
        }

        /// CALL: the visible procedure whose parameters accept the
        /// arguments (42809 when only a function matches), then its body.
        fn callProcedure(self: *Self, slot: u16, source: []const u8, call: *const R.Call, snap: Snapshot) Error!void {
            _ = slot;
            var args: [config.routine_args]Argument = undefined;
            for (call.args[0..call.arg_count], 0..) |span, position| args[position] = try self.evaluateArgument(source, span);
            const name = call.name.slice();
            var best: ?usize = null;
            var best_exact: usize = 0;
            var ambiguous = false;
            var function = false;
            for (&self.objects.routines, 0..) |*routine, index| {
                if (!routine.live or routine.namespace != catalog_module.public_namespace or !routine.stamp.visible(snap)) continue;
                if (!types.same(routine.name.slice(), name) or routine.arg_count != call.arg_count) continue;
                if (routine.kind != 'p') {
                    function = true;
                    continue;
                }
                var exact: usize = 0;
                var accepted = true;
                for (args[0..call.arg_count], routine.arg_oids[0..call.arg_count]) |arg, oid| {
                    const to = typeOfOid(oid);
                    // An unknown literal prefers the string category (text).
                    if (arg.unknown) {
                        if (to == .text) exact += 1;
                        continue;
                    }
                    if (arg.ty == to) {
                        exact += 2;
                    } else if (!value_module.castable(arg.ty, to, .implicit)) accepted = false;
                }
                if (!accepted) continue;
                if (best == null or exact > best_exact) {
                    best = index;
                    best_exact = exact;
                    ambiguous = false;
                } else if (exact == best_exact) ambiguous = true;
            }
            const chosen = best orelse return if (function) error.WrongObjectType else error.UndefinedFunction;
            if (ambiguous) return error.AmbiguousFunction;
            const routine = &self.objects.routines[chosen];
            var cells: [config.routine_args]V.Cell = undefined;
            for (args[0..call.arg_count], 0..) |arg, position| {
                const to = typeOfOid(routine.arg_oids[position]);
                cells[position] = arg.cell;
                if (arg.cell == .null_value) continue;
                const from: types.Type = if (arg.unknown) .text else arg.ty;
                if (from != to) cells[position] = try E.cast(arg.cell, from, to, routine.arg_typmods[position], &self.session);
            }
            try self.enterRoutine();
            defer self.routine_depth -= 1;
            var frame: R.Frame = .{};
            try routineParameters(&frame, routine.arg_names[0..routine.arg_count], routine.arg_oids[0..routine.arg_count], routine.arg_typmods[0..routine.arg_count], routine.name, routine.language == 1);
            for (cells[0..call.arg_count], 0..) |cell, position| frame.cells[position] = cell;
            const text_body = routine.body.slice();
            if (routine.language == 1) {
                var interpreter: Interp = .{ .host = self, .source = text_body, .frame = &frame, .purpose = .procedure, .void_result = true };
                return interpreter.execute(.run);
            }
            var statements: R.Statements = .{ .source = text_body };
            while (try statements.next()) |span| {
                try self.session.checkpoint();
                _ = try self.routineStatement(&frame, text_body[span.start..span.end], null);
            }
        }

        /// DO: the whole block is checked first, then run.
        fn doBlock(self: *Self, block: *const R.DoBlock) Error!void {
            try self.enterRoutine();
            defer self.routine_depth -= 1;
            var frame: R.Frame = .{};
            try routineParameters(&frame, &.{}, &.{}, &.{}, .{}, true);
            var checker: Interp = .{ .host = self, .source = block.body.slice(), .frame = &frame, .purpose = .do_block, .void_result = true };
            try checker.execute(.check);
            var interpreter: Interp = .{ .host = self, .source = block.body.slice(), .frame = &frame, .purpose = .do_block, .void_result = true };
            return interpreter.execute(.run);
        }

        /// A user function called from an expression (Session.routines):
        /// STRICT gives NULL for a NULL argument; a SQL body is one SELECT
        /// of one expression without FROM (others are 0A000); PL/pgSQL runs
        /// without statements of its own.
        fn routineHookCall(ptr: *anyopaque, index: usize, args_ptr: *const anyopaque, count: usize, out_ptr: *anyopaque) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const args: [*]const V.Cell = @ptrCast(@alignCast(args_ptr));
            const out: *V.Cell = @ptrCast(@alignCast(out_ptr));
            if (index >= config.routines) return error.UndefinedFunction;
            const routine = &self.objects.routines[index];
            if (routine.strict) for (args[0..count]) |*cell| {
                if (cell.* == .null_value) {
                    out.* = .null_value;
                    return;
                }
            };
            try self.enterRoutine();
            defer self.routine_depth -= 1;
            self.routine_nested += 1;
            defer self.routine_nested -= 1;
            var frame: R.Frame = .{};
            try routineParameters(&frame, routine.arg_names[0..routine.arg_count], routine.arg_oids[0..routine.arg_count], routine.arg_typmods[0..routine.arg_count], routine.name, routine.language == 1);
            for (args[0..count], 0..) |cell, position| frame.cells[position] = cell;
            const result_column = columnOfOid(routine.return_oid, routine.return_typmod);
            const text_body = routine.body.slice();
            if (routine.language == 1) {
                var interpreter: Interp = .{ .host = self, .source = text_body, .frame = &frame, .purpose = .function, .return_column = result_column };
                try interpreter.execute(.run);
                out.* = interpreter.result;
                return;
            }
            var statements: R.Statements = .{ .source = text_body };
            const span = (try statements.next()) orelse return error.UnsupportedStatement;
            if ((try statements.next()) != null) return error.UnsupportedStatement;
            const pool = &self.workspace.nodes;
            const mark = poolMark(pool);
            defer poolRestore(pool, mark);
            const query_index = P.parseQueryAt(text_body, span.start, span.end, pool) catch return error.UnsupportedStatement;
            const q = &pool.queries[query_index];
            if (q.count != 1 or q.targets[0].star or q.item_count != 0 or q.from != null or q.where != ast.none or q.group_count != 0 or
                q.having != ast.none or q.order_count != 0 or q.limit_present or q.offset_present or q.set_op != .none or q.cte_count != 0 or
                q.distinct or q.values != ast.none or q.window_defs != ast.none or q.grouping_sets != ast.none) return error.UnsupportedStatement;
            const value = try self.routineValue(&frame, text_body, q.targets[0].expr, mark.len, &result_column);
            out.* = try D.store(&result_column, value, &self.session);
        }

        // ---- triggers -------------------------------------------------------

        const tg_names = [_][]const u8{ "tg_name", "tg_when", "tg_level", "tg_op", "tg_relid", "tg_relname", "tg_table_name", "tg_table_schema", "tg_nargs" };
        const tg_types = [_]types.Type{ .name, .text, .text, .text, .oid, .name, .name, .name, .int4 };

        /// FOUND is declared already; the TG_* variables follow it.
        fn triggerVariableNames(frame: *R.Frame) Error!void {
            for (tg_names, tg_types) |name, ty| _ = try frame.declare(name, ty, -1);
        }

        fn textValue(bytes: []const u8) V.Cell {
            var text: V.Text = .{};
            const length = @min(bytes.len, config.text_bytes);
            @memcpy(text.bytes[0..length], bytes[0..length]);
            text.len = length;
            return .{ .text = text };
        }

        /// Triggers of table `index` and of the partitioned tables above it
        /// (their triggers are cloned onto partitions), in name order.
        fn rowTriggerList(self: *const Self, index: usize, snap: Snapshot, out: *[config.triggers]u8) usize {
            var count = self.objects.tableTriggers(self.tables[index].oid, snap, out);
            var current = index;
            var guard: usize = 0;
            while (guard < config.tables) : (guard += 1) {
                const table = &self.tables[current];
                if (table.parent == 0 or table.partition.bound == .none) break;
                const parent = self.visibleTableSlot(table.parent, snap) orelse break;
                var more: [config.triggers]u8 = undefined;
                const extra = self.objects.tableTriggers(self.tables[parent].oid, snap, &more);
                for (more[0..extra]) |trigger| {
                    if (count == out.len) break;
                    var at = count;
                    while (at > 0 and types.bytesOrder(self.objects.triggers[out[at - 1]].name.slice(), self.objects.triggers[trigger].name.slice()) > 0) : (at -= 1) out[at] = out[at - 1];
                    out[at] = trigger;
                    count += 1;
                }
                current = parent;
            }
            return count;
        }

        fn triggerMatches(trigger: *const RC.Trigger, timing: u8, row: bool, event: u8) bool {
            const kind = trigger.tgtype;
            if ((kind & tg.tg_row != 0) != row) return false;
            if (kind & event == 0) return false;
            return kind & (tg.tg_before | tg.tg_instead) == timing;
        }

        fn sameCell(a: *const V.Cell, b: *const V.Cell) bool {
            if (a.* == .null_value or b.* == .null_value) return a.* == .null_value and b.* == .null_value;
            if (@as(V.CellTag, a.*) != @as(V.CellTag, b.*)) return false;
            return V.compare(a, b) == 0;
        }

        /// UPDATE OF columns: one of them is a SET target (or, without the
        /// statement's SET list, changed its value).
        fn updateOfFires(trigger: *const RC.Trigger, event: u8, assigned: ?*const [config.columns]u16, new: ?*const E.Row, old: ?*const E.Row) bool {
            if (event != tg.tg_update or trigger.column_count == 0) return true;
            for (trigger.columns[0..trigger.column_count]) |column| {
                if (assigned) |set| {
                    if (set[column] != ast.none) return true;
                } else if (new != null and old != null and !sameCell(&new.?[column], &old.?[column])) return true;
            }
            return false;
        }

        fn triggerWhen(self: *Self, trigger: *const RC.Trigger, table_index: usize, new: ?*E.Row, old: ?*E.Row) Error!bool {
            if (trigger.when.len == 0) return true;
            var frame: R.Frame = .{};
            frame.variables.record_table = &self.tables[table_index];
            frame.new = new;
            frame.old = old;
            const column: V.Column = .{ .data_type = .boolean };
            const text = trigger.when.slice();
            const cell = try self.routineEvaluate(&frame, text, 0, text.len, &column);
            return cell == .boolean and cell.boolean;
        }

        /// Runs a trigger's function (PL/pgSQL, no statements of its own)
        /// with NEW / OLD and the TG_* variables; returns what it RETURNed.
        fn callTrigger(self: *Self, trigger: *const RC.Trigger, table_index: usize, timing: u8, row: bool, event: u8, new: ?*E.Row, old: ?*E.Row, snap: Snapshot) Error!R.Record {
            const function = self.objects.routineByOid(trigger.function_oid, snap) orelse return error.UndefinedFunction;
            const routine = &self.objects.routines[function];
            if (routine.language != 1 or routine.return_oid != tg.trigger_oid) return error.UnsupportedStatement;
            try self.enterRoutine();
            defer self.routine_depth -= 1;
            self.routine_nested += 1;
            defer self.routine_nested -= 1;
            var frame: R.Frame = .{};
            try routineParameters(&frame, &.{}, &.{}, &.{}, routine.name, true);
            try triggerVariableNames(&frame);
            const table = &self.tables[table_index];
            frame.variables.record_table = table;
            frame.new = new;
            frame.old = old;
            const first = frame.found + 1;
            frame.cells[first] = textValue(trigger.name.slice());
            frame.cells[first + 1] = textValue(if (timing == tg.tg_before) "BEFORE" else if (timing == tg.tg_instead) "INSTEAD OF" else "AFTER");
            frame.cells[first + 2] = textValue(if (row) "ROW" else "STATEMENT");
            frame.cells[first + 3] = textValue(switch (event) {
                tg.tg_insert => "INSERT",
                tg.tg_update => "UPDATE",
                tg.tg_delete => "DELETE",
                else => "TRUNCATE",
            });
            frame.cells[first + 4] = .{ .integer = table.oid };
            frame.cells[first + 5] = textValue(table.name.slice());
            frame.cells[first + 6] = textValue(table.name.slice());
            frame.cells[first + 7] = textValue(self.namespaceName(table.namespace));
            frame.cells[first + 8] = .{ .integer = @intCast(trigger.nargs) };
            var interpreter: Interp = .{ .host = self, .source = routine.body.slice(), .frame = &frame, .purpose = .trigger };
            try interpreter.execute(.run);
            return interpreter.record;
        }

        fn anyTrigger(self: *const Self, timing: u8, row: bool, event: u8, snap: Snapshot) bool {
            for (&self.objects.triggers) |*trigger| {
                if (trigger.live and trigger.stamp.visible(snap) and triggerMatches(trigger, timing, row, event)) return true;
            }
            return false;
        }

        /// BEFORE ROW triggers of a row: NEW changes in place; false when a
        /// trigger returned NULL (the row is skipped).
        fn beforeRow(self: *Self, table_index: usize, event: u8, new: ?*E.Row, old: ?*const E.Row, assigned: ?*const [config.columns]u16, snap: Snapshot) Error!bool {
            var list: [config.triggers]u8 = undefined;
            const count = self.rowTriggerList(table_index, snap, &list);
            for (list[0..count]) |position| {
                const trigger = &self.objects.triggers[position];
                if (!triggerMatches(trigger, tg.tg_before, true, event)) continue;
                if (!updateOfFires(trigger, event, assigned, new, old)) continue;
                var old_copy: E.Row = undefined;
                if (old) |row| old_copy = row.*;
                const old_row: ?*E.Row = if (old != null) &old_copy else null;
                if (!try self.triggerWhen(trigger, table_index, new, old_row)) continue;
                switch (try self.callTrigger(trigger, table_index, tg.tg_before, true, event, new, old_row, snap)) {
                    .new => if (new == null) return false,
                    .old => {
                        const row = old_row orelse return false;
                        if (new) |target_row| target_row.* = row.*;
                    },
                    .null_row, .none => return false,
                }
            }
            return true;
        }

        /// Statement-level triggers of the named table for each event.
        fn statementTriggers(self: *Self, table_index: usize, timing: u8, events: []const u8, snap: Snapshot) Error!void {
            var list: [config.triggers]u8 = undefined;
            const count = self.objects.tableTriggers(self.tables[table_index].oid, snap, &list);
            if (count == 0) return;
            for (events) |event| for (list[0..count]) |position| {
                const trigger = &self.objects.triggers[position];
                if (!triggerMatches(trigger, timing, false, event)) continue;
                if (!try self.triggerWhen(trigger, table_index, null, null)) continue;
                _ = try self.callTrigger(trigger, table_index, timing, false, event, null, null, snap);
            };
        }

        /// AFTER ROW triggers of every row the statement wrote since
        /// `start`, in write order (PostgreSQL's after-trigger queue fires
        /// at statement end). `assigned`: the statement's SET list for
        /// UPDATE OF on its own target.
        fn afterTriggers(self: *Self, slot: u16, start: usize, assigned: ?*const [config.columns]u16, snap: Snapshot) Error!void {
            if (!self.anyTrigger(0, true, tg.tg_insert, snap) and !self.anyTrigger(0, true, tg.tg_update, snap) and !self.anyTrigger(0, true, tg.tg_delete, snap)) return;
            const tx = &self.txs[slot];
            var index = start;
            while (index < tx.write_len) : (index += 1) {
                const entry = tx.writes[index];
                const event: u8 = switch (entry.kind) {
                    .insert => tg.tg_insert,
                    .update => tg.tg_update,
                    .delete => tg.tg_delete,
                    else => continue,
                };
                var list: [config.triggers]u8 = undefined;
                const count = self.rowTriggerList(entry.table, snap, &list);
                if (count == 0) continue;
                const table = &self.tables[entry.table];
                var new_row: E.Row = undefined;
                var old_row: E.Row = undefined;
                if (entry.kind != .delete) new_row = table.versions[entry.new].cells;
                if (entry.kind != .insert) old_row = table.versions[entry.old].cells;
                const new: ?*E.Row = if (entry.kind != .delete) &new_row else null;
                const old: ?*E.Row = if (entry.kind != .insert) &old_row else null;
                for (list[0..count]) |position| {
                    try self.session.checkpoint();
                    const trigger = &self.objects.triggers[position];
                    if (!triggerMatches(trigger, 0, true, event)) continue;
                    if (!updateOfFires(trigger, event, assigned, new, old)) continue;
                    if (!try self.triggerWhen(trigger, entry.table, new, old)) continue;
                    _ = try self.callTrigger(trigger, entry.table, 0, true, event, new, old, snap);
                }
            }
        }

        fn insertHooks(self: *const Self, table_index: usize, snap: Snapshot) bool {
            return self.anyTrigger(tg.tg_before, true, tg.tg_insert, snap) or self.ruleKind(table_index, '3', snap) == .conditional;
        }

        fn rowHooks(self: *const Self, table_index: usize, event: u8, rule_event: u8, snap: Snapshot) bool {
            var list: [config.triggers]u8 = undefined;
            const count = self.rowTriggerList(table_index, snap, &list);
            for (list[0..count]) |position| {
                if (triggerMatches(&self.objects.triggers[position], tg.tg_before, true, event)) return true;
            }
            return self.ruleKind(table_index, rule_event, snap) == .conditional;
        }

        /// CREATE [OR REPLACE] TRIGGER (AccessExclusive on the table; the
        /// function must exist, take no arguments and return trigger).
        fn createTrigger(self: *Self, slot: u16, source: []const u8, definition: *const R.CreateTrigger, snap: Snapshot) Error!void {
            const table_index = try self.namedTable(&definition.table, snap);
            try self.lockTable(slot, table_index, .access_exclusive);
            const table = &self.tables[table_index];
            const kind = definition.tgtype;
            const row = kind & tg.tg_row != 0;
            // INSTEAD OF triggers (views) are outside the subset.
            if (kind & tg.tg_instead != 0) return error.UnsupportedStatement;
            if (table.relkind == 'm' or table.relkind == 'S') return error.WrongObjectType;
            if (table.relkind == 'v' and row) return error.WrongObjectType;
            if (kind & tg.tg_truncate != 0 and row) return error.UnsupportedStatement;
            var columns: [config.columns]u8 = undefined;
            for (definition.columns[0..definition.column_count], 0..) |*column_name, position| {
                var found: ?usize = null;
                for (table.columns[0..table.column_count], 0..) |*column, index| {
                    if (types.same(column.name.slice(), column_name.slice())) found = index;
                }
                columns[position] = @intCast(found orelse return error.ColumnNotFound);
            }
            var function: ?usize = null;
            for (&self.objects.routines, 0..) |*routine, index| {
                if (!routine.live or !routine.stamp.visible(snap) or routine.arg_count != 0 or routine.namespace != catalog_module.public_namespace) continue;
                if (types.same(routine.name.slice(), definition.function.slice())) function = index;
            }
            const routine_index = function orelse return error.UndefinedFunction;
            const routine = &self.objects.routines[routine_index];
            if (routine.return_oid != tg.trigger_oid or routine.kind != 'f') return error.InvalidObjectDefinition;
            const when = source[definition.when.start..definition.when.end];
            if (when.len > config.routine_bytes) return error.TextCapacity;
            if (when.len != 0) try self.validateRecordCondition(table_index, when, kind, row, true);
            if (self.objects.triggerWriter(table.oid, definition.name.slice(), snap)) |other| return self.waitObject(slot, other);
            const existing = self.objects.findTrigger(table.oid, definition.name.slice(), snap);
            if (existing != null and !definition.replace) return error.DuplicateObject;
            try self.reserveWrites(slot, 2);
            const index = try self.objectSlot(.trigger);
            const oid = try self.takeOid();
            if (existing) |old| try self.dropObject(slot, .trigger, old, snap);
            const item = &self.objects.triggers[index];
            item.* = .{ .oid = oid, .name = definition.name, .table_oid = table.oid, .function_oid = routine.oid, .tgtype = kind, .column_count = definition.column_count, .nargs = definition.nargs, .args_len = definition.args_len };
            @memcpy(item.columns[0..definition.column_count], columns[0..definition.column_count]);
            @memcpy(item.args[0..definition.args_len], definition.args[0..definition.args_len]);
            try item.when.set(when);
            self.createdObject(slot, .trigger, index, snap);
        }

        /// A trigger WHEN or rule WHERE condition: binds over NEW / OLD;
        /// statement-level conditions cannot read them, INSERT not OLD and
        /// DELETE not NEW (42P17); subqueries are 0A000.
        fn validateRecordCondition(self: *Self, table_index: usize, text: []const u8, events: u8, row: bool, trigger: bool) Error!void {
            const pool = &self.workspace.nodes;
            const mark = poolMark(pool);
            defer poolRestore(pool, mark);
            const id = try P.parseExpressionAt(text, 0, text.len, pool);
            var frame: R.Frame = .{};
            frame.variables.record_table = &self.tables[table_index];
            frame.variables.node_low = mark.len;
            frame.variables.node_high = pool.len;
            var context = self.bindContext(text, .standard, self.routine_snap);
            context.plans = null;
            context.variables = &frame.variables;
            const column: V.Column = .{ .data_type = .boolean };
            _ = try B.bindRoutineExpression(&context, id, &column);
            var uses_new = false;
            var uses_old = false;
            for (pool.nodes[mark.len..pool.len]) |*n| {
                if (n.kind != .function or n.func != .routine_param) continue;
                if (n.relation == 1) uses_new = true;
                if (n.relation == 2) uses_old = true;
            }
            if (!row and (uses_new or uses_old)) return error.InvalidObjectDefinition;
            const inserts = if (trigger) events & tg.tg_insert != 0 else events == '3';
            const deletes = if (trigger) events & tg.tg_delete != 0 else events == '4';
            if (inserts and uses_old) return error.InvalidObjectDefinition;
            if (deletes and uses_new) return error.InvalidObjectDefinition;
        }

        /// A table or view named by a trigger / rule statement.
        fn namedTable(self: *Self, name: *const R.TableName, snap: Snapshot) Error!usize {
            const namespace = namespaceFor(&self.catalog, if (name.schema.len != 0) name.schema.slice() else null, snap) orelse return error.UndefinedSchema;
            const found = self.catalog.findIn(namespace, name.name.slice(), snap) orelse return error.TableNotFound;
            if (found.kind == 'S') return error.WrongObjectType;
            return found.slot;
        }

        fn dropTrigger(self: *Self, slot: u16, drop: *const R.DropObject, snap: Snapshot) Error!void {
            const table_index = self.namedTable(&drop.table, snap) catch |err| {
                if (drop.if_exists and err == error.TableNotFound) return;
                return err;
            };
            try self.lockTable(slot, table_index, .access_exclusive);
            const oid = self.tables[table_index].oid;
            if (self.objects.triggerWriter(oid, drop.name.slice(), snap)) |other| return self.waitObject(slot, other);
            const index = self.objects.findTrigger(oid, drop.name.slice(), snap) orelse {
                if (drop.if_exists) return;
                return error.UndefinedObject;
            };
            try self.dropObject(slot, .trigger, index, snap);
        }

        // ---- rules ------------------------------------------------------------

        const RuleKind = enum { none, conditional, everything };

        /// The INSTEAD NOTHING rules of a table for one event: none, some
        /// with a qualification (rows matching it are skipped), or an
        /// unconditional one (the statement does nothing).
        fn ruleKind(self: *const Self, table_index: usize, event: u8, snap: Snapshot) RuleKind {
            var list: [config.rules]u8 = undefined;
            const count = self.objects.tableRules(self.tables[table_index].oid, event, snap, &list);
            var out: RuleKind = .none;
            for (list[0..count]) |position| {
                const rule = &self.objects.rules[position];
                if (!rule.instead) continue;
                if (rule.where.len == 0) return .everything;
                out = .conditional;
            }
            return out;
        }

        fn anyRule(self: *const Self, table_index: usize, snap: Snapshot) bool {
            for ([_]u8{ '2', '3', '4' }) |event| {
                var list: [config.rules]u8 = undefined;
                if (self.objects.tableRules(self.tables[table_index].oid, event, snap, &list) != 0) return true;
            }
            return false;
        }

        /// A conditional INSTEAD NOTHING rule whose qualification is TRUE
        /// for this row (PostgreSQL adds `qual IS NOT TRUE` to the query).
        fn ruleSkips(self: *Self, table_index: usize, event: u8, new: ?*E.Row, old: ?*const E.Row, snap: Snapshot) Error!bool {
            var list: [config.rules]u8 = undefined;
            const count = self.objects.tableRules(self.tables[table_index].oid, event, snap, &list);
            for (list[0..count]) |position| {
                const rule = &self.objects.rules[position];
                if (!rule.instead or rule.where.len == 0) continue;
                var frame: R.Frame = .{};
                var old_copy: E.Row = undefined;
                if (old) |row| old_copy = row.*;
                frame.variables.record_table = &self.tables[table_index];
                frame.new = new;
                frame.old = if (old != null) &old_copy else null;
                const column: V.Column = .{ .data_type = .boolean };
                const text = rule.where.slice();
                const cell = try self.routineEvaluate(&frame, text, 0, text.len, &column);
                if (cell == .boolean and cell.boolean) return true;
            }
            return false;
        }

        /// A data-modifying statement's rules before it runs: true when an
        /// unconditional INSTEAD NOTHING rule replaces it with nothing.
        fn insteadNothing(self: *const Self, table_index: usize, event: u8, returning: bool, snap: Snapshot) Error!bool {
            const kind = self.ruleKind(table_index, event, snap);
            if (kind == .none) return false;
            // INSTEAD rules need their own RETURNING (0A000 in PostgreSQL).
            if (returning) return error.UnsupportedStatement;
            return kind == .everything;
        }

        /// CREATE [OR REPLACE] RULE ... DO [ALSO | INSTEAD] NOTHING
        /// (AccessExclusive on the table, as PostgreSQL).
        fn createRule(self: *Self, slot: u16, source: []const u8, definition: *const R.CreateRule, snap: Snapshot) Error!void {
            const table_index = try self.namedTable(&definition.table, snap);
            try self.lockTable(slot, table_index, .access_exclusive);
            const table = &self.tables[table_index];
            // Rules on views and materialized views are outside the subset.
            if (table.relkind != 'r' and table.relkind != 'p') return error.UnsupportedStatement;
            const where = source[definition.where.start..definition.where.end];
            if (where.len > config.routine_bytes) return error.TextCapacity;
            if (where.len != 0) try self.validateRecordCondition(table_index, where, definition.event, true, false);
            if (self.objects.ruleWriter(table.oid, definition.name.slice(), snap)) |other| return self.waitObject(slot, other);
            const existing = self.objects.findRule(table.oid, definition.name.slice(), snap);
            if (existing != null and !definition.replace) return error.DuplicateObject;
            try self.reserveWrites(slot, 2);
            const index = try self.objectSlot(.rule);
            const oid = if (existing) |old| self.objects.rules[old].oid else try self.takeOid();
            if (existing) |old| try self.dropObject(slot, .rule, old, snap);
            const item = &self.objects.rules[index];
            item.* = .{ .oid = oid, .name = definition.name, .table_oid = table.oid, .event = definition.event, .instead = definition.instead };
            try item.where.set(where);
            self.createdObject(slot, .rule, index, snap);
        }

        fn dropRule(self: *Self, slot: u16, drop: *const R.DropObject, snap: Snapshot) Error!void {
            const table_index = self.namedTable(&drop.table, snap) catch |err| {
                if (drop.if_exists and err == error.TableNotFound) return;
                return err;
            };
            try self.lockTable(slot, table_index, .access_exclusive);
            const oid = self.tables[table_index].oid;
            if (self.objects.ruleWriter(oid, drop.name.slice(), snap)) |other| return self.waitObject(slot, other);
            const index = self.objects.findRule(oid, drop.name.slice(), snap) orelse {
                if (drop.if_exists) return;
                return error.UndefinedObject;
            };
            try self.dropObject(slot, .rule, index, snap);
        }

        /// DROP TABLE takes the table's triggers and rules along (their
        /// drops are encoded before the table's).
        fn dropTableObjects(self: *Self, slot: u16, oid: u32, snap: Snapshot) Error!void {
            for (&self.objects.triggers, 0..) |*trigger, index| {
                if (!trigger.live or trigger.table_oid != oid or !trigger.stamp.visible(snap)) continue;
                if (trigger.stamp.deleterOther(snap)) |other| return self.waitObject(slot, other);
                try self.dropObject(slot, .trigger, index, snap);
            }
            for (&self.objects.rules, 0..) |*rule, index| {
                if (!rule.live or rule.table_oid != oid or !rule.stamp.visible(snap)) continue;
                if (rule.stamp.deleterOther(snap)) |other| return self.waitObject(slot, other);
                try self.dropObject(slot, .rule, index, snap);
            }
        }

        // ---- durability -------------------------------------------------------

        fn encodeObject(self: *const Self, writer: *change_log.Writer, creation: bool, class: tg.Class, index: usize) Error!void {
            var buffer: [RC.payload_bytes]u8 = undefined;
            var payload: RC.Payload = .{ .buffer = &buffer };
            if (!creation) {
                try payload.int(u32, self.objects.oidOf(class, index));
                const tag: change_log.Op = switch (class) {
                    .routine => .drop_routine,
                    .trigger => .drop_trigger,
                    .rule => .drop_rule,
                };
                return C.encodeObject(writer, tag, buffer[0..payload.used]);
            }
            const tag: change_log.Op = switch (class) {
                .routine => .create_routine,
                .trigger => .create_trigger,
                .rule => .create_rule,
            };
            switch (class) {
                .routine => try RC.encodeRoutine(&payload, &self.objects.routines[index]),
                .trigger => try RC.encodeTrigger(&payload, &self.objects.triggers[index]),
                .rule => try RC.encodeRule(&payload, &self.objects.rules[index]),
            }
            return C.encodeObject(writer, tag, buffer[0..payload.used]);
        }

        fn oidInUse(self: *const Self, oid: u32) bool {
            for (&self.objects.routines) |*item| if (item.live and item.oid == oid) return true;
            for (&self.objects.triggers) |*item| if (item.live and item.oid == oid) return true;
            for (&self.objects.rules) |*item| if (item.live and item.oid == oid) return true;
            return false;
        }

        /// Mvcc.abortSlice: undo an object creation or deletion mark.
        pub fn undoObject(self: *Self, creation: bool, class_value: u32, index: u8) void {
            const class: tg.Class = @enumFromInt(class_value);
            const stamp = self.objects.stampOf(class, index);
            if (creation) {
                self.objects.liveOf(class, index).* = false;
                const oid = self.objects.oidOf(class, index);
                if (!self.oidInUse(oid) and self.oid_counter + change_log.first_oid == oid + 1) self.oid_counter -= 1;
            } else {
                stamp.xmax = .{};
                stamp.xmax_cid = 0;
                stamp.xmax_csn = 0;
            }
        }

        /// Mvcc.stamp: publish an object creation or deletion.
        pub fn stampObject(self: *Self, creation: bool, class_value: u32, index: u8, csn: u64) void {
            const stamp = self.objects.stampOf(@enumFromInt(class_value), index);
            if (creation) stamp.xmin_csn = csn else stamp.xmax_csn = csn;
        }

        /// Replay hook (change_log.apply) of a validated object op.
        pub fn replayObject(self: *Self, tag: u8, payload: []const u8, csn: u64) Error!void {
            const stamp: tg.Stamp = .{ .xmin = .{ .epoch = self.epoch }, .xmin_cid = self.cid, .xmin_csn = csn };
            var oid: u32 = 0;
            switch (tag) {
                @intFromEnum(change_log.Op.create_routine) => {
                    const index = try self.replaySlot(.routine);
                    const item = &self.objects.routines[index];
                    try RC.decodeRoutine(payload, item);
                    item.live = true;
                    item.stamp = stamp;
                    oid = item.oid;
                },
                @intFromEnum(change_log.Op.create_trigger) => {
                    const index = try self.replaySlot(.trigger);
                    const item = &self.objects.triggers[index];
                    try RC.decodeTrigger(payload, item);
                    item.live = true;
                    item.stamp = stamp;
                    oid = item.oid;
                },
                @intFromEnum(change_log.Op.create_rule) => {
                    const index = try self.replaySlot(.rule);
                    const item = &self.objects.rules[index];
                    try RC.decodeRule(payload, item);
                    item.live = true;
                    item.stamp = stamp;
                    oid = item.oid;
                },
                else => {
                    const target_oid = try RC.decodeOid(payload);
                    const class: tg.Class = switch (tag) {
                        @intFromEnum(change_log.Op.drop_routine) => .routine,
                        @intFromEnum(change_log.Op.drop_trigger) => .trigger,
                        else => .rule,
                    };
                    const count: usize = switch (class) {
                        .routine => config.routines,
                        .trigger => config.triggers,
                        .rule => config.rules,
                    };
                    for (0..count) |index| {
                        if (!self.objects.liveOf(class, index).* or self.objects.oidOf(class, index) != target_oid) continue;
                        // Replay has no snapshot: the slot is free at once.
                        self.objects.liveOf(class, index).* = false;
                        return;
                    }
                    return error.ChangeRecordConflict;
                },
            }
            self.oid_counter = @max(self.oid_counter, oid + 1 - change_log.first_oid);
        }

        fn replaySlot(self: *Self, class: tg.Class) Error!usize {
            switch (class) {
                .routine => for (&self.objects.routines, 0..) |*item, index| {
                    if (!item.live) return index;
                },
                .trigger => for (&self.objects.triggers, 0..) |*item, index| {
                    if (!item.live) return index;
                },
                .rule => for (&self.objects.rules, 0..) |*item, index| {
                    if (!item.live) return index;
                },
            }
            return error.ChangeRecordConflict;
        }

        // ---- catalogs ---------------------------------------------------------

        /// pg_proc, pg_trigger, pg_rewrite and pg_rules rows.
        fn objectViewRows(self: *const Self, snapshot: Snapshot, view: catalog_module.View, sink: *X.RowSink) Error!void {
            switch (view) {
                .pg_proc => for (&self.objects.routines) |*routine| {
                    if (!routine.live or !routine.stamp.visible(snapshot)) continue;
                    var argtypes: [12 * config.routine_args]u8 = undefined;
                    var at: usize = 0;
                    for (routine.args(), 0..) |oid, position| {
                        if (position != 0) {
                            argtypes[at] = ' ';
                            at += 1;
                        }
                        var digits: [10]u8 = undefined;
                        var length: usize = 0;
                        var rest = oid;
                        while (true) {
                            digits[digits.len - 1 - length] = @intCast('0' + rest % 10);
                            length += 1;
                            rest /= 10;
                            if (rest == 0) break;
                        }
                        @memcpy(argtypes[at..][0..length], digits[digits.len - length ..]);
                        at += length;
                    }
                    const kind = [1]u8{routine.kind};
                    const volatility = [1]u8{routine.volatility};
                    try sink.add(&.{ intCell(routine.oid), nameCell(routine.name.slice()), intCell(routine.namespace), nameCell(&kind), nameCell(if (routine.language == 0) "sql" else "plpgsql"), nameCell(&volatility), boolCell(routine.strict), intCell(@intCast(routine.arg_count)), intCell(routine.return_oid), nameCell(argtypes[0..at]), nameCell(routine.body.slice()) });
                },
                .pg_trigger => for (&self.objects.triggers) |*trigger| {
                    if (!trigger.live or !trigger.stamp.visible(snapshot)) continue;
                    try sink.add(&.{ intCell(trigger.oid), intCell(trigger.table_oid), nameCell(trigger.name.slice()), intCell(trigger.function_oid), intCell(trigger.tgtype), nameCell("O"), boolCell(false), intCell(@intCast(trigger.nargs)) });
                },
                .pg_rewrite => for (&self.objects.rules) |*rule| {
                    if (!rule.live or !rule.stamp.visible(snapshot)) continue;
                    const event = [1]u8{rule.event};
                    try sink.add(&.{ intCell(rule.oid), nameCell(rule.name.slice()), intCell(rule.table_oid), nameCell(&event), nameCell("O"), boolCell(rule.instead) });
                },
                .pg_rules => for (&self.objects.rules) |*rule| {
                    if (!rule.live or !rule.stamp.visible(snapshot)) continue;
                    const table_index = self.visibleTableSlot(rule.table_oid, snapshot) orelse continue;
                    const table = &self.tables[table_index];
                    const schema_name = self.namespaceName(table.namespace);
                    var text: [512]u8 = undefined;
                    var definition: Writer512 = .{ .out = &text };
                    definition.add("CREATE RULE ");
                    definition.add(rule.name.slice());
                    definition.add(" AS\n    ON ");
                    definition.add(switch (rule.event) {
                        '2' => "UPDATE",
                        '3' => "INSERT",
                        else => "DELETE",
                    });
                    definition.add(" TO ");
                    definition.add(schema_name);
                    definition.add(".");
                    definition.add(table.name.slice());
                    if (rule.where.len != 0) {
                        definition.add("\n   WHERE (");
                        definition.add(rule.where.slice());
                        definition.add(")");
                    }
                    definition.add(if (rule.instead) " DO INSTEAD NOTHING;" else " DO NOTHING;");
                    try sink.add(&.{ nameCell(schema_name), nameCell(table.name.slice()), nameCell(rule.name.slice()), nameCell(definition.slice()) });
                },
                else => {},
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
            if (value.list_end != 0) {
                // A list (search_path TO a, b): the raw text, normalized by the setting.
                const raw = source[value.list_start..value.list_end];
                if (raw.len > out.bytes.len) return error.InvalidSettingValue;
                out.len = raw.len;
                @memcpy(out.bytes[0..raw.len], raw);
                return .word;
            }
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
                    lexer.decodeQuoted(source, value.quoted, &out.bytes);
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

        /// Lexer-based scheduling hint, including nested comments/whitespace.
        /// Never authorizes execution: callers must still bind a read-only plan.
        pub fn queryCandidate(source:[]const u8) bool {
            var tokens:lexer.Tokenizer=.{.source=source,.text_limit=config.text_bytes};
            const first=tokens.next() catch return false;
            return first.isWord("select") or first.isWord("with");
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
                .begin => |modes| out = .{ .begin = modes },
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
                .set_transaction => |modes| out = .{ .set_transaction = modes },
                .set_session_characteristics => |modes| out = .{ .set_session_characteristics = modes },
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
            if (R.classify(source)) |kind| {
                var routine: R.Statement = undefined;
                try R.parse(source, &self.workspace.nodes, &routine);
                result.clear(0);
                result.command = R.command(kind);
                return;
            }
            const parsed = try P.parse(source, &self.workspace.nodes, .standard);
            var snap: Snapshot = .{ .csn = self.csn };
            if (slot) |owner| if (self.active(owner)) {
                snap = .{ .csn = self.csn, .slot = owner, .epoch = self.txs[owner].epoch, .cid = self.txs[owner].cid +% 1 };
            };
            // Catalog-object statements return no rows (B11 wave 3).
            if (parsed == .catalog_object) {
                result.clear(0);
                return;
            }
            var statement_copy = parsed;
            // Describing checks no privileges (execution does), as parse analysis.
            const expanded = try expandRelations(self, &self.workspace, source, snap, &statement_copy, CO.bootstrap_role);
            var context = self.bindContext(expanded, .standard, snap);
            context.describe_only=true;
            const bound = try B.bind(&context, &statement_copy);
            result.clear(0);
            result.command = B.command(&bound);
            const returning: ?*const B.Returning = switch (bound) {
                .insert => |*insert| &insert.returning,
                .update => |*update| &update.returning,
                .delete => |*delete| &delete.returning,
                else => null,
            };
            if (returning) |list| {
                result.column_count = list.count;
                @memcpy(result.column_names[0..list.count], list.names[0..list.count]);
                @memcpy(result.column_types[0..list.count], list.types[0..list.count]);
                @memcpy(result.column_typmods[0..list.count], list.typmods[0..list.count]);
            }
            if (bound == .select) {
                result.column_count = bound.select.count;
                for (0..bound.select.count) |index| {
                    result.column_names[index] = bound.select.names[index];
                    result.column_types[index] = bound.select.types[index];
                }
            }
            if (bound == .query) {
                const plan = &self.workspace.plans.items[bound.query];
                result.column_count = plan.count;
                for (0..plan.count) |index| {
                    result.column_names[index] = plan.names[index];
                    result.column_types[index] = types.dataTypeOf(plan.tys[index]);
                    result.column_typmods[index] = plan.typmods[index];
                }
            }
        }

        // ---- replay and introspection -----------------------------------

        /// Applies a kind-3 change record atomically: the whole record is
        /// decoded and validated against `scratch` before anything changes.
        /// Replay runs before any transaction starts.
        pub fn applyChangeRecord(self: *Self, record: []const u8, scratch: *ReplayScratch) Error!void {
            if (comptime config.external_workspace) if (self.workspace.query.cells.len == 0) return error.InvalidParameterValue;
            if (comptime config.external_storage) if (self.workspace.query.refs.len == 0) return error.InvalidParameterValue;
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

        /// Replay hook: committed catalog rows for a sequence slot.
        pub fn replayCreateSequence(self: *Self, index: usize, csn: u64) Error!void {
            var changes: [K.max_changes]K.Change = undefined;
            _ = try self.catalog.createSequence(index, &self.seqs[index], .{ .epoch = self.epoch }, self.cid, csn, csn, &changes);
        }

        /// Replay hook: a committed DROP SEQUENCE.
        pub fn replayDropSequence(self: *Self, index: usize, csn: u64) void {
            var changes: [K.max_changes]K.Change = undefined;
            _ = self.catalog.dropSequence(index, storage.committed_view, .{ .epoch = self.epoch }, self.cid, csn, &changes);
        }

        /// Replay hook: ALTER TABLE redefined a table slot in place; its
        /// catalog rows are replaced at the record's csn.
        pub fn replayAlter(self: *Self, index: usize, old_count: usize, csn: u64) Error!void {
            var changes: [K.max_changes]K.Change = undefined;
            _ = self.catalog.drop(index, old_count, storage.committed_view, .{ .epoch = self.epoch }, self.cid, csn, &changes);
            _ = try self.catalog.create(index, &self.tables[index], .{ .epoch = self.epoch }, self.cid, csn, csn, &changes);
        }

        /// Replay hook: a committed CREATE SCHEMA in schema slot `index`.
        pub fn replayCreateSchema(self: *Self, index: usize, csn: u64) Error!void {
            var changes: [K.max_changes]K.Change = undefined;
            const schema = &self.schemas[index];
            _ = try self.catalog.createSchema(index, schema.oid, schema.name.slice(), .{ .epoch = self.epoch }, self.cid, csn, csn, &changes);
        }

        /// Replay hook: a committed DROP SCHEMA.
        pub fn replayDropSchema(self: *Self, index: usize, csn: u64) void {
            var changes: [K.max_changes]K.Change = undefined;
            _ = self.catalog.dropSchema(index, storage.committed_view, .{ .epoch = self.epoch }, self.cid, csn, &changes);
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
            freed += self.catalog_objects.vacuum(at);
            return freed + self.catalog.vacuum(at);
        }

        /// Leak accounting for contracts: active transactions, held row and
        /// table locks, and uncommitted versions or marks anywhere.
        pub const Usage = struct { transactions: usize, row_locks: usize, table_locks: usize, pending_versions: usize };

        pub fn usage(self: *const Self) Usage {
            var out: Usage = .{ .transactions = 0, .row_locks = self.locks.rowLocksUsed(), .table_locks = self.locks.tableLocksHeld(), .pending_versions = self.catalog.pending() + self.objects.pending() + self.catalog_objects.pending() };
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
