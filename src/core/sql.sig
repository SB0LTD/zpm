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
const std = @import("std");
const types = @import("sql/types.sig");
const ast = @import("sql/ast.sig");
const lexer = @import("sql/lexer.sig");
const parser_module = @import("sql/parser.sig");
const binder_module = @import("sql/binder.sig");
const storage = @import("sql/storage.sig");
const change_log = @import("sql/change_log.sig");
const base_snapshot = @import("sql/base_snapshot.sig");
const two_phase = @import("sql/two_phase.sig");
const expr_module = @import("sql/expr.sig");
const exec_module = @import("sql/exec.sig");
const dml_module = @import("sql/dml.sig");
const mvcc_module = @import("sql/mvcc.sig");
const locks_module = @import("sql/locks.sig");
const catalog_module = @import("sql/catalog.sig");
const collation = @import("sql/collation.sig");
const value_module = @import("sql/value.sig");
const flat_record = @import("sql/flat_record.sig");
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
const operator_catalog = @import("sql/operator_catalog.sig");
const index_operator_catalog = @import("sql/index_operator_catalog.sig");
const array_module = @import("sql/array.sig");

/// The canonical SQL tokenizer, also used by wire parameter binding.
/// Source and token spans remain caller-owned; tokenization allocates nothing.
pub const Tokenizer = lexer.Tokenizer;
pub const PostgresStatements = lexer.PostgresStatements;
pub const Config = types.Config;
pub const HashLoad = storage.HashLoad;
/// Caller-backed MVCC storage for PostgreSQL large-object payload pages.
pub const large_object_pages = @import("sql/large_object_pages.sig");
pub const large_object_command = @import("sql/large_object_command.sig");
/// Per-statement session values (TimeZone, zone resolver, clocks).
pub const Session = value_module.Session;
pub const bootstrap_role_name = CO.bootstrap_name;
pub const DatabaseCatalogRow = catalog_module.DatabaseCatalogRow;
pub const DatabaseCatalogProvider = catalog_module.DatabaseCatalogProvider;
pub const Zone = temporal_module.Zone;
pub const ZoneResolver = temporal_module.Resolver;
pub const Interval = temporal_module.Interval;
pub const Numeric = numeric_module.Numeric;
pub const Type = types.Type;
pub const typeInfo = types.typeInfo;
pub const typeByName = types.typeByName;
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
pub const ParseOptions = parser_module.Options;
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

pub const SettingValueKind = enum { default, word, string, number, configuration_text };

/// A decoded transaction-control or session command (store-executed).
pub const Control = union(enum) {
    /// An ordinary SQL statement.
    none: void,
    begin: Characteristics,
    commit: void,
    rollback: void,
    prepared_transaction: struct { action: ast.PreparedTransactionAction, gid: ?two_phase.Gid },
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
    if (config.integral_external_versions and !S.integral_enabled)
        @compileError("integral_external_versions requires split external storage");
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
        pub const DatabaseCommand = P.DatabaseCommand;
        pub const parseDatabaseCommand = P.parseDatabaseCommand;
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
        pub const LargeObjectRequest = large_object_command.Request;
        pub const LargeObjectResponse = large_object_command.Response;
        pub const StorageRowSlot = S.RowSlot;
        pub const StorageVersion = S.Version;
        pub const StorageVersionRow = S.VersionRow;
        pub const integralRowWords = S.integralRowWords;
        pub const ReplayScratch = C.Scratch;
        pub const BaseSnapshot = base_snapshot.Image(config, Self);
        pub const PreparedWal = two_phase;
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
            pub const ResultRow = if (types.projectionColumns(config) == config.columns) Row else struct {
                cells: [types.projectionColumns(config)]Cell = @splat(.null_value),
            };
            /// Value I/O for codecs that only see the result type.
            pub const ValueIo = value_module.Io(config);

            column_count: usize = 0,
            row_count: usize = 0,
            affected_rows: usize = 0,
            mysql_insert_id: u64 = 0,
            mysql_generated_id: u64 = 0,
            command: CommandTag = .none,
            /// CREATE AS ran its source query, even if it produced zero rows.
            create_query_data: bool = false,
            column_names: [types.projectionColumns(config)]Name = @splat(.{}),
            column_types: [types.projectionColumns(config)]DataType = @splat(.integer),
            /// Nullability proven by the binder for this result shape.
            non_null_columns: std.StaticBitSet(types.projectionColumns(config)) = .empty,
            /// PostgreSQL atttypmod of each column (-1 when none).
            column_typmods: [types.projectionColumns(config)]i32 = @splat(-1),
            /// Advanced catalog types can share the built-in value storage
            /// of a built-in type while keeping their nominal wire identity.
            has_nominal_types: bool = false,
            nominal_types: [types.projectionColumns(config)]types.NominalColumnType = undefined,
            values: types.ValueBytes = .{},
            rows: if (config.external_results) []ResultRow else [types.resultRows(config)]ResultRow = if (config.external_results) &.{} else @splat(.{}),
            pub const default_row_capacity = types.resultRows(config);
            pub const external_rows = config.external_results;
            pub const value_bytes = types.catalogValueBytes(config) / 2;

            pub fn storageBytesFor(rows: usize) Error!usize {
                if (rows == 0 or rows > 0x7fffffff) return error.InvalidParameterValue;
                const amount = @mulWithOverflow(rows, @sizeOf(ResultRow));
                const header = @sizeOf(Result) - (if (config.external_results) 0 else @sizeOf([types.resultRows(config)]ResultRow));
                const backing = @addWithOverflow(amount[0], if (config.external_results) value_bytes else 0);
                const total = @addWithOverflow(header, backing[0]);
                if (amount[1] != 0 or backing[1] != 0 or total[1] != 0) return error.InvalidParameterValue;
                return total[0];
            }

            pub fn rowBytes(rows: usize) Error!usize {
                _ = try storageBytesFor(rows);
                return rows * @sizeOf(ResultRow) + if (config.external_results) value_bytes else 0;
            }

            pub fn bindMemory(self: *Result, bytes: []u8, rows: usize) Error!void {
                if (comptime !config.external_results) @compileError("result binding requires external_results");
                const capacity = try rowBytes(rows);
                if (bytes.len < capacity) return error.WorkspaceCapacity;
                const values = try storageView(ResultRow, bytes, 0, rows);
                const start = @intFromPtr(values.ptr);
                const own = @intFromPtr(self);
                if (start < own + @sizeOf(Result) and own < start + capacity) return error.InvalidParameterValue;
                self.rows = values;
                self.values = .{ .bytes = bytes[rows * @sizeOf(ResultRow)..capacity] };
                self.clear(0);
            }

            /// Optional storage for wide values on inline-result builds.
            /// The caller keeps it disjoint from the result and its rows
            /// and retains it until clear or until it no longer uses them.
            pub fn bindValueMemory(self: *Result, bytes: []u8) void {
                self.values = .{ .bytes = bytes };
                self.clear(0);
            }

            pub fn copyCells(self: *Result, output: []Cell, input: []const Cell) Error!void {
                for (output, input) |*destination, *value| {
                    destination.* = if (V.largeBytes(value)) |bytes| V.largeCell(value, try self.values.copy(bytes)) else value.*;
                }
            }

            pub const default_session: *const value_module.Session = &value_module.default_session;

            /// Renders every column that is not BIGINT/INTEGER/BOOLEAN/TEXT
            /// as TEXT (output function, `session` TimeZone), for codecs
            /// without native metadata for the other types (MySQL/TDS, flag
            /// F-M). A value longer than Config.text_bytes is TextCapacity.
            pub fn textify(self: *Result, session: *const value_module.Session) Error!void {
                return self.textifyForWire(session, .generic);
            }

            /// TDS 7.3 and later can encode DATE without formatting the cells.
            pub fn textifyWithDate(self: *Result, session: *const value_module.Session) Error!void {
                return self.textifyForWire(session, .tds);
            }

            pub fn textifyMysql(self: *Result, session: *const value_module.Session) Error!void {
                return self.textifyForWire(session, .mysql);
            }

            fn textifyForWire(self: *Result, session: *const value_module.Session, mode: enum { generic, tds, mysql }) Error!void {
                for (0..self.column_count) |column| {
                    switch (self.column_types[column]) {
                        .integer, .integer32, .boolean, .text => continue,
                        .mysql_bigint_unsigned => if (mode == .mysql) continue,
                        .numeric => if (mode == .mysql and self.column_typmods[column] == ast.mysql_unsigned_sum_typmod) {
                            for (self.rows[0..self.row_count]) |*row| {
                                const cell = &row.cells[column];
                                if (cell.* == .null_value) continue;
                                if (cell.* != .numeric or cell.numeric.special != .finite or cell.numeric.dscale != 0 or
                                    cell.numeric.coef() > std.math.maxInt(u128)) return error.TypeMismatch;
                            }
                            continue;
                        },
                        .date => if (mode == .tds) continue,
                        .smallint, .oid => {
                            self.column_types[column] = .integer;
                            continue;
                        },
                        else => {},
                    }
                    const identity = self.nominalColumnType(column);
                    if (identity != null and identity.?.representation == .flat_record) {
                        for (self.rows[0..self.row_count]) |*row| {
                            if (row.cells[column] == .null_value) continue;
                            var text: Text = .{};
                            text.len = (try self.formatNominalText(column, &row.cells[column], &text.bytes)).?;
                            row.cells[column] = .{ .text = text };
                        }
                    } else {
                        for (self.rows[0..self.row_count]) |*row| {
                            row.cells[column] = try ValueIo.toText(&row.cells[column], false, session);
                        }
                    }
                    const mysql_date = mode == .mysql and (self.column_types[column] == .date or
                        (self.column_types[column] == .bpchar and self.column_typmods[column] == ast.mysql_date_text_typmod));
                    if (!mysql_date) {
                        self.column_types[column] = .text;
                        self.column_typmods[column] = -1;
                    }
                }
                self.has_nominal_types = false;
            }

            /// Only active ranges are observable; avoid clearing unused row capacity.
            pub fn clear(self: *Result, affected: usize) void {
                self.values.used = 0;
                self.column_count = 0;
                self.row_count = 0;
                self.affected_rows = affected;
                self.mysql_insert_id = 0;
                self.mysql_generated_id = 0;
                self.command = .none;
                self.create_query_data = false;
                self.has_nominal_types = false;
                self.non_null_columns = .empty;
            }

            pub fn setNominalTypes(self: *Result, columns: []const types.NominalColumnType) void {
                if (columns.len != self.column_count) unreachable;
                @memcpy(self.nominal_types[0..columns.len], columns);
                self.has_nominal_types = true;
            }

            pub fn nominalColumnType(self: *const Result, column: usize) ?types.NominalColumnType {
                if (!self.has_nominal_types or column >= self.column_count) return null;
                const identity = self.nominal_types[column];
                return if (identity.oid != 0) identity else null;
            }

            /// A flat record carries typed field bytes in the existing Cell
            /// bytea storage. Its nominal descriptor selects record output.
            pub fn formatNominalText(self: *const Result, column: usize, cell: *const Cell, out: []u8) Error!?usize {
                const identity = self.nominalColumnType(column) orelse return null;
                if (identity.representation != .flat_record) return null;
                if (cell.* != .bytea) return error.TypeMismatch;
                return try flat_record.format(cell.bytea.slice(), out);
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
                if (source.values.used != 0 and source.values.used > self.values.bytes.len) return error.WorkspaceCapacity;
                self.values.used = 0;
                self.column_count = source.column_count;
                self.row_count = source.row_count;
                self.affected_rows = source.affected_rows;
                self.mysql_insert_id = source.mysql_insert_id;
                self.mysql_generated_id = source.mysql_generated_id;
                self.command = source.command;
                self.create_query_data = source.create_query_data;
                self.non_null_columns = source.non_null_columns;
                self.has_nominal_types = false;
                if (source.has_nominal_types) self.setNominalTypes(source.nominal_types[0..source.column_count]);
                @memcpy(self.column_names[0..source.column_count], source.column_names[0..source.column_count]);
                @memcpy(self.column_types[0..source.column_count], source.column_types[0..source.column_count]);
                @memcpy(self.column_typmods[0..source.column_count], source.column_typmods[0..source.column_count]);
                for (0..source.row_count) |row| {
                    const output = self.rows[row].cells[0..source.column_count];
                    const input = source.rows[row].cells[0..source.column_count];
                    if (source.values.used != 0) try self.copyCells(output, input) else @memcpy(output, input);
                }
            }
        };

        /// Optional caller-owned cache for complete typed read results. Bind
        /// after storage recovery. The database object and backing storage
        /// must outlive it. Replacing or restoring the database requires a
        /// new cache, even if the committed sequence number is unchanged.
        pub const ReadResultCache = struct {
            const Cache = @This();
            const ways = 4;

            pub const Entry = struct {
                valid: bool = false,
                csn: u64 = 0,
                hash: u64 = 0,
                key_length: usize = 0,
                database_name: [64]u8 = undefined,
                database_name_length: usize = 0,
                workspace_cells: usize = 0,
                workspace_refs: usize = 0,
                output_rows: usize = 0,
                result: Result = .{},
            };

            pub const Layout = struct {
                entries: usize,
                bytes: usize,
                entry_offset: usize,
                key_offset: usize,
                key_bytes: usize,
                row_offset: usize,
                row_count: usize,
            };

            pub const Stats = struct {
                hits: u64 = 0,
                misses: u64 = 0,
                publications: u64 = 0,
                contention: u64 = 0,
            };

            database: *const Self,
            entries: []Entry,
            keys: []u8,
            storage_spans: [4]StorageSpan,
            key_capacity: usize,
            rows_per_entry: usize,
            busy: u8 = 0,
            victim: usize = 0,
            counters: Stats = .{},
            projected: ?Projected = null,

            // Medium results hold only their integral values. Each stripe
            // has independent ownership while hashing or copying a result.
            const Projected = struct {
                const key_bytes = 1024;
                const stripe_width = 4;
                const Slot = struct {
                    state: enum { empty, observed, published } = .empty,
                    busy: u8 = 0,
                    csn: u64 = 0,
                    hash: u64 = 0,
                    key: [key_bytes]u8 = undefined,
                    key_length: usize = 0,
                    database: [64]u8 = undefined,
                    database_length: usize = 0,
                    workspace_cells: usize = 0,
                    workspace_refs: usize = 0,
                    output_rows: usize = 0,
                    row_count: usize = 0,
                };

                slots: []Slot,
                values: []i64,
                spans: [2]StorageSpan,
                rows_per_entry: usize,
                min_scan_rows: usize,
                counters: Stats = .{},

                fn stripe(self: *const Projected, hash: u64) usize {
                    return @as(usize, @intCast(hash % ((self.slots.len - 1) / stripe_width + 1))) * stripe_width;
                }

                fn lock(self: *Projected, first: usize) bool {
                    if (@cmpxchgStrong(u8, &self.slots[first].busy, 0, 1, .acquire, .monotonic) == null) return true;
                    _ = @atomicRmw(u64, &self.counters.contention, .Add, 1, .monotonic);
                    return false;
                }

                fn unlock(self: *Projected, first: usize) void {
                    @atomicStore(u8, &self.slots[first].busy, 0, .release);
                }

                fn matches(slot: *const Slot, context: *const ReadContext, hash: u64, result: *const Result) bool {
                    return slot.state != .empty and slot.csn == context.snapshot.csn and slot.hash == hash and
                        slot.workspace_cells == context.workspace.query.cells.len and slot.workspace_refs == context.workspace.query.refs.len and
                        slot.output_rows == result.rows.len and types.same(slot.key[0..slot.key_length], context.source) and
                        types.same(slot.database[0..slot.database_length], context.session.database);
                }

                fn cells(self: *const Projected, index: usize) []i64 {
                    const span = self.rows_per_entry * X.projected_cache_columns;
                    return self.values[index * span ..][0..span];
                }

                fn get(self: *Projected, context: *const ReadContext, hash: u64, select: *const B.Select, result: *Result) Error!bool {
                    const first = self.stripe(hash);
                    if (!self.lock(first)) return false;
                    defer self.unlock(first);
                    for (first..@min(first + stripe_width, self.slots.len)) |index| {
                        const slot = &self.slots[index];
                        if (slot.state != .published or !matches(slot, context, hash, result)) continue;
                        if (context.session.control) |execution_control| if (execution_control.poll) |poll| try poll(execution_control.context);
                        const packed_values = self.cells(index);
                        X.writeHeader(select, result);
                        for (result.rows[0..slot.row_count], 0..) |*row, row_index| {
                            const packed_row = packed_values[row_index * select.count ..][0..select.count];
                            for (row.cells[0..select.count], packed_row) |*cell, value| cell.* = .{ .integer = value };
                        }
                        result.row_count = slot.row_count;
                        _ = @atomicRmw(u64, &self.counters.hits, .Add, 1, .monotonic);
                        return true;
                    }
                    _ = @atomicRmw(u64, &self.counters.misses, .Add, 1, .monotonic);
                    return false;
                }

                fn put(self: *Projected, context: *const ReadContext, hash: u64, result: *const Result) void {
                    if (result.command != .select or result.row_count <= 128 or result.row_count > self.rows_per_entry or
                        context.workspace.query.read_stats.projected_filter_scans != 1) return;
                    const first = self.stripe(hash);
                    if (!self.lock(first)) return;
                    defer self.unlock(first);
                    var empty: ?usize = null;
                    for (first..@min(first + stripe_width, self.slots.len)) |index| {
                        const slot = &self.slots[index];
                        if (matches(slot, context, hash, result)) {
                            if (slot.state == .published) return;
                            const packed_values = self.cells(index);
                            for (result.rows[0..result.row_count], 0..) |*row, row_index| {
                                const packed_row = packed_values[row_index * result.column_count ..][0..result.column_count];
                                for (row.cells[0..result.column_count], packed_row) |*cell, *value| {
                                    if (cell.* != .integer) return;
                                    value.* = cell.integer;
                                }
                            }
                            slot.row_count = result.row_count;
                            slot.state = .published;
                            _ = @atomicRmw(u64, &self.counters.publications, .Add, 1, .monotonic);
                            return;
                        }
                        if (slot.state == .empty or slot.csn != context.snapshot.csn) empty = index;
                    }
                    // Churn may consume observations but never evicts a
                    // repeated result within the same committed snapshot.
                    const slot = &self.slots[empty orelse return];
                    slot.csn = context.snapshot.csn;
                    slot.hash = hash;
                    slot.key_length = context.source.len;
                    @memcpy(slot.key[0..slot.key_length], context.source);
                    slot.database_length = context.session.database.len;
                    @memcpy(slot.database[0..slot.database_length], context.session.database);
                    slot.workspace_cells = context.workspace.query.cells.len;
                    slot.workspace_refs = context.workspace.query.refs.len;
                    slot.output_rows = result.rows.len;
                    slot.state = .observed;
                }
            };

            pub const ProjectedLayout = struct {
                bytes: usize,
                entries: usize,
                slots_offset: usize,
                values_offset: usize,
                value_count: usize,
            };

            pub fn projectedLayoutForBytes(byte_budget: usize, rows_per_entry: usize) Error!ProjectedLayout {
                if (rows_per_entry <= 128) return error.InvalidParameterValue;
                const per_entry = @mulWithOverflow(rows_per_entry, X.projected_cache_columns * @sizeOf(i64));
                if (per_entry[1] != 0) return error.InvalidParameterValue;
                const footprint = @addWithOverflow(per_entry[0], @sizeOf(Projected.Slot));
                if (footprint[1] != 0) return error.InvalidParameterValue;
                const stripes = byte_budget / footprint[0] / Projected.stripe_width;
                if (stripes == 0) return error.WorkspaceCapacity;
                const entries = stripes * Projected.stripe_width;
                const value_count = entries * (per_entry[0] / @sizeOf(i64));
                var bytes: usize = 0;
                const slots_offset = try appendLayout(&bytes, Projected.Slot, entries);
                const values_offset = try appendLayout(&bytes, i64, value_count);
                if (bytes > byte_budget) return error.WorkspaceCapacity;
                return .{.bytes=bytes,.entries=entries,.slots_offset=slots_offset,.values_offset=values_offset,.value_count=value_count};
            }

            pub const TieredLayout = struct {
                small: Layout,
                small_offset: usize,
                projected: ?ProjectedLayout,
                bytes: usize,
            };

            /// Partition one caller budget. Keep at least seven eighths for
            /// small entries and decline the optional tier below two stripes.
            pub fn tieredLayoutForBytes(byte_budget: usize, key_bytes_per_entry: usize,
                small_rows: usize, projected_rows: usize) Error!TieredLayout {
                if (projected_rows > 128 and S.compact_enabled) {
                    const projected_budget = @min(byte_budget / 8, 16 * 1024 * 1024);
                    if (projectedLayoutForBytes(projected_budget, projected_rows)) |medium| {
                        if (medium.entries >= 2 * Projected.stripe_width) {
                            var aligned = medium.bytes;
                            const small_offset = try appendLayout(&aligned, Entry, 0);
                            const small = try layoutForBytes(byte_budget - small_offset, key_bytes_per_entry, small_rows);
                            return .{ .small=small, .small_offset=small_offset, .projected=medium, .bytes=small_offset+small.bytes };
                        }
                    } else |_| {}
                }
                const small = try layoutForBytes(byte_budget, key_bytes_per_entry, small_rows);
                return .{.small=small,.small_offset=0,.projected=null,.bytes=small.bytes};
            }

            /// Bind the optional integral tier after the small result cache.
            /// Keep both regions stable and disjoint for the cache lifetime.
            pub fn bindProjectedMemory(cache: *Cache, bytes: []u8, rows_per_entry: usize, min_scan_rows: usize) Error!void {
                if (cache.projected != null or min_scan_rows == 0) return error.InvalidParameterValue;
                const layout_value = try projectedLayoutForBytes(bytes.len, rows_per_entry);
                const slots = try storageView(Projected.Slot, bytes, layout_value.slots_offset, layout_value.entries);
                const values = try storageView(i64, bytes, layout_value.values_offset, layout_value.value_count);
                const spans = [_]StorageSpan{ try StorageSpan.of(slots), try StorageSpan.of(values) };
                try ReadContext.disjointDatabase(cache.database, &spans);
                for (spans) |span| for (cache.storage_spans) |other| {
                    if (ReadContext.overlaps(span, other)) return error.InvalidParameterValue;
                };
                for (slots) |*slot| {
                    slot.state = .empty;
                    slot.busy = 0;
                }
                cache.projected = .{.slots=slots,.values=values,.spans=spans,.rows_per_entry=rows_per_entry,.min_scan_rows=min_scan_rows};
            }

            pub fn projectedStats(cache: *const Cache) Stats {
                const projected = if (cache.projected) |*tier| tier else return .{};
                return readStats(&projected.counters);
            }

            /// Byte layout for one aligned caller-owned cache region.
            pub fn layout(entries: usize, key_bytes_per_entry: usize, rows_per_entry: usize) Error!Layout {
                if (entries == 0 or key_bytes_per_entry == 0 or rows_per_entry == 0 or
                    (!config.external_results and rows_per_entry > Result.default_row_capacity)) return error.InvalidParameterValue;
                const key_bytes = @mulWithOverflow(entries, key_bytes_per_entry);
                const row_count = @mulWithOverflow(entries, if (config.external_results) rows_per_entry else 0);
                if (key_bytes[1] != 0 or row_count[1] != 0) return error.InvalidParameterValue;
                var bytes: usize = 0;
                const entry_offset = try appendLayout(&bytes, Entry, entries);
                const key_offset = try appendLayout(&bytes, u8, key_bytes[0]);
                const row_offset = if (config.external_results) try appendLayout(&bytes, Result.ResultRow, row_count[0]) else bytes;
                return .{ .entries = entries, .bytes = bytes, .entry_offset = entry_offset, .key_offset = key_offset,
                    .key_bytes = key_bytes[0], .row_offset = row_offset, .row_count = row_count[0] };
            }

            /// Largest complete cache within the caller's byte budget.
            pub fn layoutForBytes(byte_budget: usize, key_bytes_per_entry: usize, rows_per_entry: usize) Error!Layout {
                const one = try layout(1, key_bytes_per_entry, rows_per_entry);
                if (one.bytes > byte_budget) return error.WorkspaceCapacity;
                var low: usize = 1;
                var high = byte_budget / @sizeOf(Entry);
                while (low < high) {
                    const middle = low + (high - low + 1) / 2;
                    const candidate = layout(middle, key_bytes_per_entry, rows_per_entry) catch {
                        high = middle - 1;
                        continue;
                    };
                    if (candidate.bytes <= byte_budget) low = middle else high = middle - 1;
                }
                return layout(low, key_bytes_per_entry, rows_per_entry);
            }

            pub fn bindMemory(cache: *Cache, db: *const Self, bytes: []u8, entries: usize, key_bytes_per_entry: usize, rows_per_entry: usize) Error!void {
                const memory = try layout(entries, key_bytes_per_entry, rows_per_entry);
                if (bytes.len < memory.bytes) return error.WorkspaceCapacity;
                const entry_storage = try storageView(Entry, bytes, memory.entry_offset, memory.entries);
                const key_storage = bytes[memory.key_offset..][0..memory.key_bytes];
                const row_storage: []Result.ResultRow = if (comptime config.external_results) try storageView(Result.ResultRow, bytes, memory.row_offset, memory.row_count) else &.{};
                try cache.init(db, entry_storage, key_storage, row_storage, rows_per_entry);
            }

            /// Snapshot of completed cache activity. Ineligible reads bypass
            /// the cache, and a contended access is counted separately.
            pub fn stats(cache: *const Cache) Stats {
                return readStats(&cache.counters);
            }

            fn readStats(counters: *const Stats) Stats {
                return .{
                    .hits = @atomicLoad(u64, &counters.hits, .monotonic),
                    .misses = @atomicLoad(u64, &counters.misses, .monotonic),
                    .publications = @atomicLoad(u64, &counters.publications, .monotonic),
                    .contention = @atomicLoad(u64, &counters.contention, .monotonic),
                };
            }

            /// Use a stable cache pointer for its lifetime. Each slot reserves
            /// an equal part of keys and, for external results, row_storage.
            /// For inline results pass empty row_storage.
            pub fn init(cache: *Cache, db: *const Self, entries: []Entry, keys: []u8, row_storage: []Result.ResultRow, rows_per_entry: usize) Error!void {
                if (entries.len == 0 or keys.len < entries.len or rows_per_entry == 0) return error.InvalidParameterValue;
                if (comptime config.external_results) {
                    if (rows_per_entry > row_storage.len / entries.len) return error.InvalidParameterValue;
                } else if (row_storage.len != 0 or rows_per_entry > Result.default_row_capacity) return error.InvalidParameterValue;
                const spans = [_]StorageSpan{ try ReadContext.objectSpan(cache), try StorageSpan.of(entries), try StorageSpan.of(keys), try StorageSpan.of(row_storage) };
                for (spans, 0..) |part, index| {
                    for (spans[0..index]) |earlier| if (ReadContext.overlaps(part, earlier)) return error.InvalidParameterValue;
                }
                try ReadContext.disjointDatabase(db, &spans);
                cache.* = .{ .database = db, .entries = entries, .keys = keys, .storage_spans = spans,
                    .key_capacity = keys.len / entries.len, .rows_per_entry = rows_per_entry };
                for (entries, 0..) |*entry, index| {
                    entry.valid = false;
                    if (comptime config.external_results) entry.result.rows = row_storage[index * rows_per_entry ..][0..rows_per_entry];
                }
            }

            fn validateContext(storage_spans: []const StorageSpan, context: *const ReadContext, result: *const Result) Error!void {
                const spans = [_]StorageSpan{ try ReadContext.objectSpan(context), try ReadContext.objectSpan(result),
                    try StorageSpan.of(context.source), try StorageSpan.of(context.session.database), try StorageSpan.of(context.workspace.query.cells[0..]),
                    try StorageSpan.of(context.workspace.query.refs[0..]), try StorageSpan.of(result.rows[0..]) };
                for (storage_spans) |part| {
                    for (spans) |other| if (ReadContext.overlaps(part, other)) return error.InvalidParameterValue;
                }
            }

            fn hashSource(source: []const u8) u64 {
                var hash: u64 = 14695981039346656037;
                for (source) |byte| hash = (hash ^ byte) *% 1099511628211;
                return hash;
            }

            fn bucket(cache: *const Cache, hash: u64) usize {
                const groups = (cache.entries.len - 1) / ways + 1;
                return @as(usize, @intCast(hash % groups)) * ways;
            }

            fn lock(cache: *Cache) bool {
                if (@cmpxchgStrong(u8, &cache.busy, 0, 1, .acquire, .monotonic) == null) return true;
                _ = @atomicRmw(u64, &cache.counters.contention, .Add, 1, .monotonic);
                return false;
            }

            fn unlock(cache: *Cache) void {
                @atomicStore(u8, &cache.busy, 0, .release);
            }

            fn key(cache: *const Cache, index: usize) []u8 {
                return cache.keys[index * cache.key_capacity ..][0..cache.key_capacity];
            }

            fn sameKey(cache: *const Cache, index: usize, context: *const ReadContext, hash: u64, result: *const Result) bool {
                const entry = &cache.entries[index];
                return entry.valid and entry.csn == context.snapshot.csn and entry.hash == hash and
                    entry.workspace_cells == context.workspace.query.cells.len and
                    entry.workspace_refs == context.workspace.query.refs.len and entry.output_rows == result.rows.len and
                    types.same(entry.database_name[0..entry.database_name_length], context.session.database) and
                    types.same(cache.key(index)[0..entry.key_length], context.source);
            }

            fn get(cache: *Cache, context: *const ReadContext, hash: u64, result: *Result) Error!bool {
                if (!cache.lock()) return false;
                defer cache.unlock();
                const first = cache.bucket(hash);
                for (first..@min(first + ways, cache.entries.len)) |index| {
                    if (!cache.sameKey(index, context, hash, result)) continue;
                    const entry = &cache.entries[index];
                    if (entry.result.row_count > result.rows.len) return false;
                    // A hit still honors a pending cancel before exposing rows.
                    if (context.session.control) |execution_control| {
                        if (execution_control.poll) |poll| try poll(execution_control.context);
                    }
                    try result.copyFromChecked(&entry.result);
                    _ = @atomicRmw(u64, &cache.counters.hits, .Add, 1, .monotonic);
                    return true;
                }
                _ = @atomicRmw(u64, &cache.counters.misses, .Add, 1, .monotonic);
                return false;
            }

            fn put(cache: *Cache, context: *const ReadContext, hash: u64, result: *const Result) Error!void {
                if (result.command != .select or result.values.used != 0 or result.row_count > cache.rows_per_entry or !cache.lock()) return;
                defer cache.unlock();
                const first = cache.bucket(hash);
                const end = @min(first + ways, cache.entries.len);
                const csn = context.snapshot.csn;
                var reusable: ?usize = null;
                for (first..end) |index| {
                    if (cache.sameKey(index, context, hash, result)) return;
                    if (!cache.entries[index].valid or cache.entries[index].csn != csn) reusable = index;
                }
                const index = reusable orelse first + cache.victim % (end - first);
                cache.victim +%= 1;
                const entry = &cache.entries[index];
                entry.valid = false;
                try entry.result.copyFromChecked(result);
                @memcpy(cache.key(index)[0..context.source.len], context.source);
                @memcpy(entry.database_name[0..context.session.database.len], context.session.database);
                entry.key_length = context.source.len;
                entry.database_name_length = context.session.database.len;
                entry.workspace_cells = context.workspace.query.cells.len;
                entry.workspace_refs = context.workspace.query.refs.len;
                entry.output_rows = result.rows.len;
                entry.csn = csn;
                entry.hash = hash;
                entry.valid = true;
                _ = @atomicRmw(u64, &cache.counters.publications, .Add, 1, .monotonic);
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
            non_null_columns: std.StaticBitSet(types.projectionColumns(config)) = .empty,
        };

        pub const Outcome = struct {
            affected: usize = 0,
            command: CommandTag = .none,
            mysql_insert_id: u64 = 0,
            mysql_generated_id: u64 = 0,
            create_query_data: bool = false,
            returning: Returned = .{},
            noop: bool = false,
        };

        /// A user schema slot: like a sequence slot, `creator` owns a pending
        /// CREATE or DROP; `dead_csn` marks a committed DROP until reclaimed.
        pub const Schema = struct {
            live: bool = false,
            pending_create: bool = false,
            pending_drop: bool = false,
            creator: u16 = 0,
            dead_csn: u64 = 0,
            oid: u32 = 0,
            owner: u32 = CO.bootstrap_role,
            private_usage: bool = false,
            name: Name = .{},
        };

        pub const AlterRecord = struct {
            fold_created_primary: bool = false,
            foldable_defaults: bool = false,
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

        /// Resolve direct access separately from catalog discovery and
        /// previously analyzed references inside a stored view.
        fn namespaceForUsage(self: *const Self, role: u32, schema: ?[]const u8, snap: Snapshot) Error!?u32 {
            const namespace = namespaceFor(&self.catalog, schema, snap) orelse return null;
            try self.checkNamespaceUsage(role, namespace, snap);
            return namespace;
        }

        fn checkNamespaceUsage(self: *const Self, role: u32, namespace: u32, snap: Snapshot) Error!void {
            if (namespace < change_log.first_oid or role == CO.bootstrap_role) return;
            for (&self.schemas) |*schema| {
                if (!schema.live or schema.oid != namespace) continue;
                if (!schema.private_usage) return;
                // Privilege changes follow the current catalog, even if the
                // query still reads user rows at an older transaction CSN.
                var authority = snap;
                authority.csn = self.csn;
                if (self.catalog_objects.schemaUsage(role, namespace, self.schemaOwner(schema, authority), authority)) return;
                return error.InsufficientPrivilege;
            }
        }

        fn bindNamespaceCreate(pointer: *const anyopaque, role: u32, namespace: u32, snap: Snapshot, plain: bool) Error!void {
            const self: *const Self = @ptrCast(@alignCast(pointer));
            var authority = snap;
            authority.csn = self.csn;
            if (self.catalog_objects.superuser(role, authority)) return;
            if (!plain or namespace < change_log.first_oid) return error.InsufficientPrivilege;
            for (&self.schemas) |*schema| {
                if (!schema.live or schema.oid != namespace) continue;
                if (schema.dead_csn != 0) return error.UndefinedSchema;
                if (schema.private_usage and self.catalog_objects.memberOf(role, self.schemaOwner(schema, authority), true, authority)) return;
                break;
            }
            return error.InsufficientPrivilege;
        }

        fn bindNamespaceUsage(pointer: *const anyopaque, role: u32, namespace: u32, snap: Snapshot) Error!void {
            const self: *const Self = @ptrCast(@alignCast(pointer));
            return self.checkNamespaceUsage(role, namespace, snap);
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

        fn expandRelations(db: *const Self, workspace: *Workspace, source: []const u8, snap: Snapshot, bound_statement: *A.Statement, role: u32, session: *const value_module.Session) Error![]const u8 {
            // Privileges and row security apply to roles other than superusers (B11 wave 3).
            const privileged = role == CO.bootstrap_role or db.catalog_objects.superuser(role, snap);
            // Analyzing a view definition or an unpopulated materialized
            // view does not execute the stored query.
            const executes_query = switch (bound_statement.*) {
                .create_view => |view| view.materialized and view.with_data,
                .refresh_view => |view| view.with_data,
                .create_table => |table| table.with_data,
                else => true,
            };
            const tables = &db.tables;
            const catalog = &db.catalog;
            const public_schema_on_path = session.public_schema_on_path;
            workspace.expanded_count = 0;
            const pool = &workspace.nodes;
            var length: usize = 0;
            // REFRESH MATERIALIZED VIEW reads the stored query the same way.
            if (bound_statement.* == .refresh_view) {
                const refresh = &bound_statement.refresh_view;
                const schema_name = if (refresh.name.schema) |qualifier| identName(source, qualifier) else Name{};
                const namespace_oid = if (refresh.name.schema != null or public_schema_on_path) try db.namespaceForUsage(session.role, if (refresh.name.schema != null) schema_name.slice() else null, snap) else null;
                if (namespace_oid) |namespace| {
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
                    if (catalog.findSystemView(if (item.schema != null) schema_name.slice() else null, name.slice())) |view| {
                        if (view == .pg_authid and !privileged) return error.InsufficientPrivilege;
                        continue;
                    }
                    if (item.schema == null and !public_schema_on_path and item.name.span.start < source.len) continue;
                    const qualified = if (item.schema != null) schema_name.slice() else null;
                    const namespace = if (item.name.span.start < source.len)
                        try db.namespaceForUsage(session.role, qualified, snap)
                    else
                        namespaceFor(catalog, qualified, snap);
                    const found = catalog.findIn(namespace orelse continue, name.slice(), snap) orelse continue;
                    if (executes_query) try session.restricted_relation_kinds.check(found.kind);
                    // Items the statement names (not view or expansion texts).
                    if (!privileged and item.name.span.start < source.len) {
                        const secured = try secureItem(db, workspace, &length, source, role, session.row_security, found, snap);
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
                    item.query = try appendQuery(workspace, &length, source, view.query.slice());
                    item.view = true;
                    item.view_table = @intCast(found.slot);
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
            const PrimaryKeyPlan = struct {
                select: B.Select,
                projection: [config.columns]u16,
                column: usize,
                data_type: DataType,
                oid: u32,
                role: u32,
                public_schema_on_path: bool,
                row_security: bool,
                restricted_relation_kinds: value_module.RestrictedRelationKinds,
                prepared_csn: u64,
                snapshot: Snapshot,
            };
            const Plan=union(enum){simple:B.Select,general:u16,primary_key:PrimaryKeyPlan};
            pub const primary_key_source_capacity = 256;
            /// The retained plan's projected columns and result metadata are
            /// independent of the AST workspace and own their template bytes.
            const CachedPrimaryKey = struct {
                source: [primary_key_source_capacity]u8 = undefined,
                len: usize,
                database: *const Self,
                plan: PrimaryKeyPlan,
            };
            cached_primary_key: ?CachedPrimaryKey = null,
            primary_key_cache_hits: usize = 0,
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
            last_result_reused: bool = false,

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
                if(overlaps(own,try StorageSpan.of(bytes))) return error.InvalidParameterValue;
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
            fn overlaps(a:StorageSpan,b:StorageSpan) bool {
                return a.start<a.end and b.start<b.end and a.start<b.end and b.start<a.end;
            }
            fn disjointParts(parts: []const StorageSpan, bounds: StorageSpan, backing_span: StorageSpan) Error!void {
                if (!overlaps(bounds, backing_span)) return;
                for (parts) |part| if (overlaps(part, backing_span)) return error.InvalidParameterValue;
            }
            fn disjointDatabase(db: *const Self, parts: []const StorageSpan) Error!void {
                // A backing range outside the bounds misses every caller range.
                // An intersection with the bounds still needs the exact check.
                var bounds: StorageSpan = .{ .start = ~@as(usize, 0), .end = 0 };
                for (parts) |part| {
                    if (part.start == part.end) continue;
                    bounds.start = @min(bounds.start, part.start);
                    bounds.end = @max(bounds.end, part.end);
                }
                try disjointParts(parts, bounds, try objectSpan(db));
                if (comptime config.external_workspace) {
                    try disjointParts(parts, bounds, try StorageSpan.of(db.workspace.query.cells[0..]));
                }
                if (comptime config.external_storage) {
                    if (db.contiguous_backing) |backing| {
                        if (!overlaps(bounds, backing)) return;
                        // Worker scratch and results can straddle the backing
                        // in address space without either touching it.
                        for (parts) |part| {
                            if (overlaps(part, backing)) break;
                        } else return;
                    }
                    try disjointParts(parts, bounds, try StorageSpan.of(db.workspace.query.refs[0..]));
                }
                for (&db.tables) |*table| inline for (storage_fields) |name| {
                    try disjointParts(parts, bounds, try StorageSpan.of(@field(table, name)[0..]));
                };
            }
            fn validate(self:*Context,db:*const Self,source:[]const u8,result:?*Result) Error!void {
                const cells=self.workspace.query.cells[0..];const refs=self.workspace.query.refs[0..];
                if(cells.len<2*config.columns or refs.len==0) return error.WorkspaceCapacity;
                const empty:StorageSpan=.{.start=0,.end=0};
                const mutable=[_]StorageSpan{try objectSpan(self),
                    if(config.external_workspace) try StorageSpan.of(cells) else empty,
                    if(config.external_storage) try StorageSpan.of(refs) else empty,
                    if(result) |out| try objectSpan(out) else empty,
                    if(config.external_results and result!=null) try StorageSpan.of(result.?.rows) else empty};
                const source_span=try StorageSpan.of(source);
                for(mutable,0..) |part,index| {
                    if(overlaps(part,source_span)) return error.InvalidParameterValue;
                    for(mutable[0..index]) |earlier| if(overlaps(part,earlier)) return error.InvalidParameterValue;
                }
                try disjointDatabase(db, &mutable);
            }
            /// Callbacks in session (clock/zone resolver/control) must themselves
            /// be safe for concurrent reads. Sequence hooks are always disabled.
            pub fn prepare(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot) Error!void {
                return self.prepareMode(db,source,snapshot,false,null);
            }
            /// Metadata binding is separate from executable preparation. It
            /// never leaves a metadata-only plan available to run().
            pub fn describe(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot,result:*Result) Error!void {
                defer self.prepared=null;
                try self.prepareMode(db,source,snapshot,true,null);
                try self.describeResult(result);
            }
            fn prepareMode(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot,describe_only:bool,params:?*const B.Parameters) Error!void {
                self.last_result_reused = false;
                try self.validate(db,source,null);
                self.prepared=null;
                self.preparation_error=null;self.database=db;self.source=source;self.snapshot=snapshot;
                self.prepareBody(db,source,snapshot,describe_only,params) catch |err| {self.preparation_error=err;return err;};
            }
            fn prepareBody(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot,describe_only:bool,params:?*const B.Parameters) Error!void {
                if (db.detachedReadsBlocked()) return error.UnsupportedStatement;
                self.session.sequences=null;
                var parsed=try P.parseWithOptions(source,&self.workspace.nodes,.{.dialect=self.dialect});
                switch(parsed){.select,.query=>{},else=>return error.UnsupportedStatement}
                const expanded=try Self.expandRelations(db,&self.workspace,source,snapshot,&parsed,self.session.role,&self.session);
                try self.session.checkpoint();
                for(self.workspace.nodes.queries[0..self.workspace.nodes.query_len]) |query| {
                    if(query.lock.strength!=.none) return error.UnsupportedStatement;
                }
                const context:B.Context=.{.source=expanded,.tables=&db.tables,.catalog=&db.catalog,.snapshot=snapshot,
                    .pool=&self.workspace.nodes,.legacy=false,.dialect=self.dialect,.session=&self.session,.plans=&self.workspace.plans,.describe_only=describe_only,.routines=&db.objects,.params=params,
                    .user_type_catalog=&db.catalog_objects,.stored_source_start=source.len,.namespace_usage=.{.ptr=db,.check=&Self.bindNamespaceUsage}};
                const bound=try B.bind(&context,&parsed);
                // Detached reads never mutate: no data-modifying WITH (B11).
                if(self.workspace.plans.dml_len!=0) return error.UnsupportedStatement;
                // A settings scan observes the installed connection state.
                // Describe only needs the static relation schema.
                if (!describe_only) for (self.workspace.plans.items[0..self.workspace.plans.len]) |*block| {
                    for (block.sources[0..block.source_count]) |*item| {
                        if (item.view == .pg_settings or item.sequence != null) return error.UnsupportedStatement;
                    }
                };
                // Metadata-only Describe does not call evaluation hooks.
                if(!describe_only) for(self.workspace.nodes.nodes[0..self.workspace.nodes.len]) |node| {
                    if (node.ty == .regproc or types.elementType(node.ty) == .regproc) return error.UnsupportedStatement;
                    switch(node.func) {
                        .nextval,.currval,.setval,.lastval,.identity_next,.lo_create,.lo_creat,.lo_unlink,.lo_from_bytea,.lo_get,.lo_truncate,.lo_truncate64=>return error.UnsupportedStatement,
                        // These catalog lookups use the serialized database hook.
                        .to_regclass,.regclass_in,.regclass_out,.pg_get_serial_sequence,.pg_table_is_visible,.pg_get_indexdef,.pg_get_constraintdef,.pg_get_triggerdef,.pg_get_viewdef,.pg_partition_ancestors,
                        .to_regnamespace,.regnamespace_in,.regnamespace_out,.to_regproc=>return error.UnsupportedStatement,
                        .pg_get_statisticsobjdef_columns,.pg_relation_is_publishable,.pg_get_partkeydef,.acldefault,.current_schemas=>return error.UnsupportedStatement,
                        .obj_description,.col_description,.shobj_description,.current_user,.session_user=>return error.UnsupportedStatement,
                        .current_setting,.set_config,.pg_backend_pid,.pg_is_in_recovery,
                        .pg_try_advisory_lock,.pg_try_advisory_lock_shared,
                        .pg_try_advisory_xact_lock,.pg_try_advisory_xact_lock_shared,
                        .pg_advisory_unlock,.pg_advisory_unlock_shared,
                        .routine,.routine_param=>return error.UnsupportedStatement,
                        else=>{},
                    }
                };
                self.prepared=switch(bound){.select=>|select| .{.simple=select},.query=>|root| .{.general=root},else=>return error.UnsupportedStatement};
                self.database=db;self.source=source;self.effective=expanded;self.snapshot=snapshot;
            }

            fn directColumn(node: *const ast.Node, count: usize) bool {
                return node.kind == .column and node.level == 0 and node.relation == 0 and node.column < count;
            }

            /// Binds a PostgreSQL integral PK lookup using a declared parameter
            /// type and this context's role. False means use ordinary execution.
            /// Keep the SQL buffer unchanged and the committed snapshot alive.
            /// Replacing database contents ends the binding, even at equal CSN.
            pub fn preparePrimaryKey(self: *Context, db: *const Self, source: []const u8, snapshot: Snapshot, parameter: DataType) Error!bool {
                self.last_result_reused = false;
                self.prepared = null;
                self.preparation_error = null;
                if (comptime config.statement_parameters == 0) return false;
                if (self.dialect != .postgres or snapshot.epoch != 0 or snapshot.csn > db.csn or db.detachedReadsBlocked()) return false;
                switch (parameter) {
                    .smallint, .integer32, .integer => {},
                    else => return false,
                }
                if (self.cached_primary_key) |*cached| {
                    if (cached.database == db and snapshotMatches(cached.plan.snapshot, snapshot) and
                        self.primaryKeyTableCurrent(db, &cached.plan) and cached.plan.data_type == parameter and
                        types.same(cached.source[0..cached.len], source))
                    {
                        try self.validate(db, source, null);
                        try self.session.checkpoint();
                        self.database = db;
                        self.source = source;
                        self.effective = source;
                        self.snapshot = snapshot;
                        self.prepared = .{ .primary_key = cached.plan };
                        self.primary_key_cache_hits +%= 1;
                        return true;
                    }
                }
                var params: B.Parameters = .{ .count = 1 };
                params.types[0] = types.typeOfData(parameter);
                // As with SQL PREPARE, bind types before runtime values exist.
                self.prepareMode(db, source, snapshot, true, &params) catch |err| {
                    if (err != error.UnsupportedStatement) return err;
                    self.preparation_error = null;
                    return false;
                };
                const bound = self.prepared.?;
                self.prepared = null;
                if (bound != .simple or self.effective.ptr != source.ptr) return false;
                const select = bound.simple;
                if (select.where == ast.none or select.order_count != 0 or select.limit != ~@as(u64, 0) or select.lock.strength != .none) return false;
                const table = &db.tables[select.table orelse return false];
                const primary = table.primary_column orelse return false;
                if (table.relkind != 'r' or table.parent != 0 or db.hasChildren(table.oid, snapshot) or
                    db.catalog_objects.rowSecurity(self.session.role, table.oid, snapshot) or table.columns[primary].data_type != parameter) return false;
                const nodes = &self.workspace.nodes.nodes;
                const predicate = &nodes[select.where];
                if (predicate.kind != .binary or predicate.op != .eq) return false;
                const left = &nodes[predicate.a];
                const right = &nodes[predicate.b];
                const column = if (left.kind == .param) right else left;
                const argument = if (left.kind == .param) left else right;
                if (!directColumn(column, table.column_count) or column.column != primary or argument.kind != .param or argument.integer != 1 or argument.ty != params.types[0]) return false;
                var projection: [config.columns]u16 = undefined;
                for (select.targets[0..select.count], 0..) |id, position| {
                    const item = &nodes[id];
                    if (!directColumn(item, table.column_count)) return false;
                    projection[position] = item.column;
                }
                const plan: PrimaryKeyPlan = .{
                    .select = select,
                    .projection = projection,
                    .column = primary,
                    .data_type = parameter,
                    .oid = table.oid,
                    .role = self.session.role,
                    .public_schema_on_path = self.session.public_schema_on_path,
                    .row_security = self.session.row_security,
                    .restricted_relation_kinds = self.session.restricted_relation_kinds,
                    .prepared_csn = db.csn,
                    .snapshot = snapshot,
                };
                self.prepared = .{ .primary_key = plan };
                if (source.len <= primary_key_source_capacity) {
                    self.cached_primary_key = .{ .len=source.len, .database=db, .plan=plan };
                    @memcpy(self.cached_primary_key.?.source[0..source.len], source);
                }
                return true;
            }

            /// An installed plan must match the owned template and parameter
            /// supplied by the current portal, before checking the snapshot.
            pub fn primaryKeyMatches(self: *const Context, source: []const u8, parameter: DataType) bool {
                const plan = if (self.prepared) |*prepared| prepared else return false;
                return plan.* == .primary_key and plan.primary_key.data_type == parameter and types.same(self.source, source);
            }

            fn snapshotMatches(cached: Snapshot, current: Snapshot) bool {
                return current.epoch == 0 and cached.epoch == 0 and cached.csn == current.csn and
                    cached.slot == current.slot and cached.cid == current.cid;
            }

            fn primaryKeyCurrent(self: *const Context, db: *const Self, snapshot: Snapshot, plan: *const PrimaryKeyPlan) bool {
                return self.database == db and snapshotMatches(plan.snapshot, snapshot) and self.primaryKeyTableCurrent(db, plan);
            }

            fn primaryKeyTableCurrent(self: *const Context, db: *const Self, plan: *const PrimaryKeyPlan) bool {
                if (plan.prepared_csn != db.csn or self.session.role != plan.role or self.dialect != .postgres) return false;
                if (self.session.public_schema_on_path != plan.public_schema_on_path or
                    self.session.row_security != plan.row_security or
                    !std.meta.eql(self.session.restricted_relation_kinds, plan.restricted_relation_kinds)) return false;
                const table = &db.tables[plan.select.table.?];
                return table.live and table.oid == plan.oid and table.primary_column == plan.column and
                    table.columns[plan.column].data_type == plan.data_type;
            }

            /// Runs a prepared PK probe without parsing or binding again.
            /// A stale binding returns false and leaves the result untouched.
            /// The caller still excludes mutation for the duration of the read.
            pub fn runPrimaryKey(self: *Context, db: *const Self, snapshot: Snapshot, key: *const Cell, result: *Result) Error!bool {
                const prepared = if (self.prepared) |*plan| plan else return false;
                if (prepared.* != .primary_key) return false;
                const plan = &prepared.primary_key;
                if (!self.primaryKeyCurrent(db, snapshot, plan)) return false;
                try self.probePrimaryKey(db, self.source, snapshot, plan, key, result);
                return true;
            }

            /// Reuse the retained read plan without installing it into the
            /// working plan union. On a miss the caller still owns the request.
            pub fn runCachedPrimaryKey(self: *Context, db: *const Self, source: []const u8, snapshot: Snapshot, parameter: DataType, key: *const Cell, result: *Result) Error!bool {
                const plan = self.cachedKeyPlan(db, source, snapshot, parameter) orelse return false;
                try self.probePrimaryKey(db, source, snapshot, plan, key, result);
                self.last_result_reused = false;
                self.primary_key_cache_hits +%= 1;
                return true;
            }

            fn cachedKeyPlan(self: *const Context, db: *const Self, source: []const u8, snapshot: Snapshot, parameter: DataType) ?*const PrimaryKeyPlan {
                const cached = if (self.cached_primary_key) |*entry| entry else return null;
                const plan = &cached.plan;
                if (cached.database != db or plan.data_type != parameter or db.detachedReadsBlocked() or
                    !snapshotMatches(plan.snapshot, snapshot) or !self.primaryKeyTableCurrent(db, plan) or
                    !types.same(cached.source[0..cached.len], source)) return null;
                return plan;
            }

            /// Valid only while the caller retains the read gate and leaves
            /// this context unchanged. A null version is a valid empty result.
            pub const PrimaryKeyView = struct {
                table: *const S.Table,
                version: ?u32,
                columns: []const u16,
                types: []const DataType,

                pub fn cell(self: PrimaryKeyView, index: usize, scratch: *Cell) *const Cell {
                    return S.borrowVersionCell(self.table, self.version.?, self.columns[index], scratch);
                }
            };

            pub fn cachedPrimaryKeyView(self: *Context, db: *const Self, source: []const u8, snapshot: Snapshot, parameter: DataType, key: *const Cell, output: []u8) Error!?PrimaryKeyView {
                const plan = self.cachedKeyPlan(db, source, snapshot, parameter) orelse return null;
                if (plan.select.has_nominal_types) return null;
                const span = try StorageSpan.of(output);
                if (overlaps(span, try StorageSpan.of(source)) or overlaps(span, try objectSpan(self))) return error.InvalidParameterValue;
                try disjointDatabase(db, &.{span});
                const table = &db.tables[plan.select.table.?];
                if (key.* != .null_value) try V.validate(&table.columns[plan.column], key);
                try self.session.checkpoint();
                const version = if (key.* == .null_value) null else S.lookupVersionAt(table, key, snapshot);
                self.workspace.query.read_stats = .{};
                self.last_result_reused = false;
                self.primary_key_cache_hits +%= 1;
                return .{ .table = table, .version = version, .columns = plan.projection[0..plan.select.count], .types = plan.select.types[0..plan.select.count] };
            }

            fn probePrimaryKey(self: *Context, db: *const Self, source: []const u8, snapshot: Snapshot, plan: *const PrimaryKeyPlan, key: *const Cell, result: *Result) Error!void {
                try self.validate(db, source, result);
                if (config.external_results and result.rows.len == 0) return error.InvalidParameterValue;
                const table = &db.tables[plan.select.table.?];
                if (key.* != .null_value) try V.validate(&table.columns[plan.column], key);
                self.workspace.query.read_stats = .{};
                try X.selectPrimaryKey(table, &plan.select, plan.projection[0..plan.select.count], key, snapshot, result, &self.session);
            }

            pub fn run(self:*Context,result:*Result) Error!void {
                return self.runWithCache(result, null);
            }

            /// Reuse a previously completed result when the caller already
            /// holds the same database read ownership required by run().
            pub fn runCached(self: *Context, result: *Result, cache: *ReadResultCache) Error!void {
                return self.runWithCache(result, cache);
            }

            fn runWithCache(self: *Context, result: *Result, cache: ?*ReadResultCache) Error!void {
                self.last_result_reused = false;
                const db=self.database orelse return error.InvalidParameterValue;
                try self.validate(db,self.source,result);
                if(self.preparation_error) |err| return err;
                const plan=self.prepared orelse return error.InvalidParameterValue;
                if(config.external_results and result.rows.len==0) return error.InvalidParameterValue;
                var projected_cache: ?*ReadResultCache.Projected = null;
                var cache_hash: ?u64 = null;
                const hit = if (cache) |candidate| cache_key: {
                    // A bound tier must stay disjoint even when this plan
                    // bypasses caching and writes its own Result.
                    const tier: ?*ReadResultCache.Projected = if (candidate.projected) |*tier| tier else null;
                    if (tier) |medium| try ReadResultCache.validateContext(&medium.spans, self, result);
                    if (candidate.database != db or self.session.database.len > 64 or
                        !self.cacheableProfile(db)) break :cache_key false;
                    switch (plan) {
                        .general => {
                            if (self.source.len > candidate.key_capacity or !self.cacheable(db, plan)) break :cache_key false;
                            try ReadResultCache.validateContext(&candidate.storage_spans, self, result);
                            const hash = ReadResultCache.hashSource(self.source);
                            cache_hash = hash;
                            break :cache_key try candidate.get(self, hash, result);
                        },
                        .simple => |*select| {
                            const medium = tier orelse break :cache_key false;
                            if (self.source.len > ReadResultCache.Projected.key_bytes or
                                !self.cacheableProjected(db, select, medium.min_scan_rows)) break :cache_key false;
                            try ReadResultCache.validateContext(&candidate.storage_spans, self, result);
                            const hash = ReadResultCache.hashSource(self.source);
                            cache_hash = hash;
                            projected_cache = medium;
                            break :cache_key try medium.get(self, hash, select, result);
                        },
                        .primary_key => break :cache_key false,
                    }
                } else false;
                if (hit) {
                    self.last_result_reused = true;
                    self.workspace.query.read_stats = .{};
                    self.workspace.query.stream_stats = .{};
                    return;
                }
                self.workspace.query.views=.{.ptr=self,.rows=readViewRows};
                self.workspace.query.read_stats=.{};
                switch(plan) {
                    .simple=>|*select| try X.select(&db.tables,self.effective,&self.workspace.nodes,select,self.snapshot,result,X.NoLock{},
                        &self.session,self.snapshot.epoch==0,&self.workspace.query.read_stats,&self.workspace.query),
                    .general=>|root| try X.runQuery(&db.tables,self.effective,&self.workspace.nodes,&self.workspace.plans,root,self.snapshot,result,
                        &self.session,&self.workspace.query,self.snapshot.epoch==0),
                    .primary_key => return error.UndefinedParameter,
                }
                if (cache_hash) |hash| {
                    if (projected_cache) |tier| tier.put(self, hash, result)
                    else try cache.?.put(self, hash, result);
                }
            }

            fn cacheableType(ty: ast.Type) bool {
                return switch (ty) {
                    .unknown, .int2, .int4, .int8, .numeric, .boolean, .text,
                    .name, .varchar, .bpchar, .date, .timestamp, .timestamptz => true,
                    else => false,
                };
            }

            fn cacheableAggregate(kind: ast.Agg) bool {
                return switch (kind) {
                    .count, .count_star, .sum, .avg, .min, .max => true,
                    else => false,
                };
            }

            fn cacheableProfile(self: *const Context, db: *const Self) bool {
                const session = &self.session;
                return self.dialect == .postgres and self.snapshot.epoch == 0 and
                    self.snapshot.csn == db.csn and self.effective.ptr == self.source.ptr and
                    session.role == CO.bootstrap_role and session.session_role == CO.bootstrap_role and
                    session.zone.kind == .utc and !session.xml_document and session.resolver.lookup == null and session.params == null and
                    session.engine == null and session.routines == null and session.routine_frame == null and
                    (session.control == null or session.control.?.max_work == 0);
            }

            fn cacheableProjected(self: *const Context, db: *const Self, select: *const B.Select, min_scan_rows: usize) bool {
                if (!self.session.synchronize_seqscans) return false;
                const table = &db.tables[select.table orelse return false];
                if (table.relkind != 'r' or table.namespace != catalog_module.public_namespace or table.parent != 0 or
                    db.hasChildren(table.oid, self.snapshot) or db.detachedReadsBlocked()) return false;
                return X.cacheableProjectedFilter(&self.workspace.nodes, table, select, self.snapshot, min_scan_rows);
            }

            fn cacheable(self: *const Context, db: *const Self, plan: Plan) bool {
                if (plan != .general) return false;

                // Positive allowlist: unknown functions, user routines,
                // clocks, session/sequence state, sampling and catalog scans
                // execute normally. Inspect nested blocks and window inputs.
                const pool = &self.workspace.nodes;
                for (pool.nodes[0..pool.len]) |*node| {
                    if (!cacheableType(node.ty)) return false;
                    switch (node.kind) {
                        .null_literal, .bool_literal, .int_literal, .text_literal, .decimal_literal,
                        .column, .unary, .binary, .and_op, .or_op, .not_op, .test_op,
                        .between, .in_list, .like, .case_expr, .when_arm, .coalesce, .nullif => {},
                        .cast => switch (node.ty) {
                            .date, .timestamp, .timestamptz => {
                                if (!node.date_bound) {
                                    if (node.a == ast.none) return false;
                                    switch (pool.nodes[node.a].ty) {
                                        .date, .timestamp, .timestamptz => {},
                                        else => return false,
                                    }
                                }
                            },
                            else => {},
                        },
                        .aggregate => if (!cacheableAggregate(node.agg)) return false,
                        .function => switch (node.func) {
                            .to_char, .round, .grouping, .window_call => {},
                            else => return false,
                        },
                        else => return false,
                    }
                }

                const plans = &self.workspace.plans;
                for (plans.ctes[0..plans.cte_len]) |*cte| if (cte.recursive) return false;
                var analytical = false;
                for (plans.items[0..plans.len]) |*block| {
                    analytical = analytical or block.grouped or block.window_count != 0;
                    if (block.function != ast.none or block.dml != B.no_dml or block.correlated or
                        block.set_op != .none or block.values != ast.none) return false;
                    if ((block.limit != 0xffffffffffffffff or block.offset != 0 or
                        block.limit_expr != ast.none or block.offset_expr != ast.none) and block.order_count == 0) return false;
                    for (block.sources[0..block.source_count]) |*source| {
                        if (source.view != null or source.sample_method != 0 or source.lateral) return false;
                        if (source.table) |index| {
                            const table = &db.tables[index];
                            if (table.relkind != 'r' or table.namespace != catalog_module.public_namespace) return false;
                            if (self.session.synchronize_seqscans and X.synchronizedProjection(block) and S.supportsSynchronizedScan(table)) return false;
                        }
                    }
                    for (block.aggs[0..block.agg_count]) |aggregate| if (!cacheableAggregate(aggregate.kind)) return false;
                    for (block.windows[0..block.window_count]) |*window| switch (window.kind) {
                        .rank, .dense_rank => {},
                        .aggregate => if (!cacheableAggregate(window.aggregate.kind)) return false,
                        else => return false,
                    };
                }
                return analytical;
            }
            /// Describe an already bound read without running expressions,
            /// acquiring row locks or touching the database's shared workspace.
            pub fn describeResult(self:*Context,result:*Result) Error!void {
                const db=self.database orelse return error.InvalidParameterValue;
                try self.validate(db,self.source,result);
                if(self.preparation_error) |err| return err;
                const plan=self.prepared orelse return error.InvalidParameterValue;
                switch(plan) {
                    .simple=>|*select| X.writeHeader(select,result),
                    .primary_key=>|*key| {
                        if (!self.primaryKeyCurrent(db, self.snapshot, key)) return error.InvalidParameterValue;
                        X.writeHeader(&key.select,result);
                    },
                    .general=>|root| {
                        result.clear(0);result.command=.select;
                        const query=&self.workspace.plans.items[root];
                        result.column_count=query.count;
                        result.non_null_columns=query.non_null_columns;
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
            fn inputNeedsZoneResolver(ty: types.Type) bool {
                const element = types.elementType(ty) orelse ty;
                return switch (types.rangeSubtype(element) orelse element) {
                    .timestamp, .timestamptz, .time, .timetz => true,
                    else => false,
                };
            }

            fn castNeedsZoneResolver(from: types.Type, to: types.Type) bool {
                if (types.elementType(from)) |element| {
                    const target_element = types.elementType(to) orelse return false;
                    return value_module.characterType(element) and inputNeedsZoneResolver(target_element);
                }
                return (from == .unknown or value_module.characterType(from)) and inputNeedsZoneResolver(to);
            }

            /// Typed datetime conversions use the frozen zone. Named-zone
            /// input parsing can call the embedding's mutable resolver.
            pub fn needsZoneResolver(self:*const Context) bool {
                const nodes = self.workspace.nodes.nodes[0..self.workspace.nodes.len];
                for (nodes) |node| switch (node.kind) {
                    .at_zone => return true,
                    .text_literal => if (inputNeedsZoneResolver(node.ty)) return true,
                    .function => if (node.func == .json_table_column and inputNeedsZoneResolver(node.cast_type)) return true,
                    .cast => {
                        if (node.a == ast.none) {
                            if (inputNeedsZoneResolver(node.cast_type)) return true;
                        } else if (castNeedsZoneResolver(nodes[node.a].ty, node.cast_type)) return true;
                    },
                    else => {},
                };
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
        large_pages: ?large_object_pages.Pages = null,
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
        /// Constraint OIDs have their own catalog namespace.
        next_constraint_oid: u32 = change_log.first_oid,
        next_default_oid: u32 = change_log.first_oid,
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
        exclusive_table_waiters: L.Set = .{},
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
        startup_recovery_active: bool = false,
        // All external table slices and query refs lie in this extent after
        // bindMemoryFor. Individual backing bindings have no such proof.
        contiguous_backing: if (config.external_storage) ?StorageSpan else void = if (config.external_storage) null else {},
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

        /// Borrow the embedding's cluster catalogue while serving statements.
        /// The embedding keeps the provider and its rows consistent for the
        /// duration of each SQL call, including detached execution.
        pub fn setDatabaseCatalog(self: *Self, provider: ?DatabaseCatalogProvider) void {
            self.catalog.databases = provider;
        }

        /// current_setting / set_config of caller-owned parameters: `show`
        /// writes the value (null: unknown name); `set` applies it (false:
        /// unknown name).
        pub const SettingsProvider = struct {
            context: ?*anyopaque = null,
            show: *const fn (?*anyopaque, []const u8, []u8) ?usize,
            set: *const fn (?*anyopaque, []const u8, []const u8, bool, bool) Error!bool,
            warn: ?*const fn (?*anyopaque, []const u8, []const u8) void = null,
        };

        const storage_fields = .{ "rows", "versions", "row_index", "key_index", "scan_values", "scan_nonnull", "scan_live", "scan_presence", "index_slots" } ++
            (if (S.split_versions) .{"version_rows"} else .{}) ++
            (if (S.integral_enabled) .{"integral_rows"} else .{});

        const BackingLayout = struct {
            offsets: [config.tables][storage_fields.len]usize,
            refs: usize,
            bytes: usize,
            row_index: [config.tables]usize,
            key_index: [config.tables]usize,
        };

        pub const TableBudget = struct {
            rows: usize,
            versions: usize,
            /// Opt in to a higher maximum load for the row and version indexes.
            hash_load: HashLoad = .half,
            /// Zero selects dense rows. A nonzero integral bank reserves
            /// this many u64 words per version, including the null bitmap.
            /// CREATE uses the first compatible free bank in caller order.
            integral_row_words: usize = 0,
            /// Hashes provisioned for this table. Null uses the configured
            /// default. An explicit smaller count keeps the same logical
            /// index capacity and scans MVCC versions for the other indexes,
            /// including when enforcing uniqueness.
            secondary_hashes: ?usize = null,
            /// Omit this slot's duplicate committed column projection.
            /// Queries scan MVCC versions and can still use summaries.
            omit_compact_scan: bool = false,
        };

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
                const ri = try budget.hash_load.slotsFor(rows);
                const ki = try budget.hash_load.slotsFor(versions);
                row_index.*=ri; key_index.*=ki;
                offsets[0] = try appendLayout(&cursor, S.RowSlot, rows);
                offsets[1] = try appendLayout(&cursor, S.Version, versions);
                offsets[2] = try appendLayout(&cursor, u32, ri);
                offsets[3] = try appendLayout(&cursor, u32, ki);
                const scan_rows = if (S.compact_enabled and !budget.omit_compact_scan) rows else 0;
                const scan_cells = @mulWithOverflow(scan_rows, config.columns);
                if (scan_cells[1] != 0) return error.InvalidParameterValue;
                offsets[4] = try appendLayout(&cursor, i64, scan_cells[0]);
                offsets[5] = try appendLayout(&cursor, u64, scan_rows);
                offsets[6] = try appendLayout(&cursor, u8, scan_rows);
                offsets[7] = if (S.presence_enabled) try appendLayout(&cursor, u64, try S.presenceWords(scan_rows)) else cursor;
                const hashes = budget.secondary_hashes orelse S.bound_indexes;
                if (hashes > S.bound_indexes) return error.InvalidParameterValue;
                const index_slots = @mulWithOverflow(ki, hashes);
                if (index_slots[1] != 0) return error.InvalidParameterValue;
                offsets[8] = if (hashes != 0) try appendLayout(&cursor, u32, index_slots[0]) else cursor;
                if (!S.integral_enabled and budget.integral_row_words != 0) return error.InvalidParameterValue;
                if (comptime S.split_versions) offsets[9] = try appendLayout(&cursor, S.VersionRow, if (budget.integral_row_words == 0) versions else 0);
                if (comptime S.integral_enabled) {
                    const words = @mulWithOverflow(versions, budget.integral_row_words);
                    if (words[1] != 0) return error.InvalidParameterValue;
                    offsets[10] = try appendLayout(&cursor, u64, words[0]);
                }
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
            const region = try StorageSpan.of(cells);
            const own: StorageSpan = .{ .start = @intFromPtr(self), .end = @intFromPtr(self) + @sizeOf(Self) };
            if (region.start < own.end and own.start < region.end) return error.InvalidParameterValue;
            if (comptime config.external_storage) {
                const refs = try StorageSpan.of(self.workspace.query.refs);
                if (refs.start < refs.end and region.start < refs.end and refs.start < region.end) return error.InvalidParameterValue;
                for (&self.tables) |*table| inline for (storage_fields) |field| {
                    const part = try StorageSpan.of(@field(table, field));
                    if (part.start < part.end and region.start < part.end and part.start < region.end) return error.InvalidParameterValue;
                };
            }
            if (self.large_pages) |*pages| {
                for (try largePageSpans(pages.backing())) |part| if (region.overlaps(part)) return error.InvalidParameterValue;
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
            const span = try StorageSpan.of(bytes[0..layout.bytes]);
            var backings: [config.tables]StorageBacking = undefined;
            for (&backings, layout.offsets, layout.row_index, layout.key_index, budgets) |*backing, offsets, ri, ki, budget| {
                const hashes = budget.secondary_hashes orelse S.bound_indexes;
                const scan_rows = if (S.compact_enabled and !budget.omit_compact_scan) budget.rows else 0;
                backing.* = .{
                    .rows = try storageView(S.RowSlot, bytes, offsets[0], budget.rows),
                    .versions = try storageView(S.Version, bytes, offsets[1], budget.versions),
                    .version_rows = if (comptime S.split_versions) try storageView(S.VersionRow, bytes, offsets[9], if (budget.integral_row_words == 0) budget.versions else 0) else {},
                    .integral_rows = if (comptime S.integral_enabled) try storageView(u64, bytes, offsets[10], budget.versions * budget.integral_row_words) else {},
                    .integral_row_words = if (S.integral_enabled) budget.integral_row_words else {},
                    .row_index = try storageView(u32, bytes, offsets[2], ri),
                    .key_index = try storageView(u32, bytes, offsets[3], ki),
                    .hash_load = budget.hash_load,
                    .scan_values = try storageView(i64, bytes, offsets[4], scan_rows * config.columns),
                    .scan_nonnull = try storageView(u64, bytes, offsets[5], scan_rows),
                    .scan_live = try storageView(u8, bytes, offsets[6], scan_rows),
                    .scan_presence = if (S.presence_enabled) try storageView(u64, bytes, offsets[7], try S.presenceWords(scan_rows)) else &.{},
                    .omit_compact_scan = budget.omit_compact_scan,
                    .index_slots = if (hashes != 0) try storageView(u32, bytes, offsets[8], ki * hashes) else &.{},
                    .scan_index_limit = if (hashes < S.bound_indexes) S.bound_indexes else 0,
                };
            }
            try self.bindStorage(backings, try storageView(u32, bytes, layout.refs, refs));
            self.contiguous_backing = span;
        }

        const StorageSpan = struct {
            start: usize,
            end: usize,

            fn of(values: anytype) Error!StorageSpan {
                const start = @intFromPtr(values.ptr);
                const size = @mulWithOverflow(values.len, @sizeOf(@TypeOf(values[0])));
                const end = @addWithOverflow(start, size[0]);
                if (size[1] != 0 or end[1] != 0) return error.InvalidParameterValue;
                return .{ .start = start, .end = end[0] };
            }

            fn overlaps(left: StorageSpan, right: StorageSpan) bool {
                return left.start < left.end and right.start < right.end and left.start < right.end and right.start < left.end;
            }
        };

        /// Bind distinct caller-owned storage to a fresh external-storage DB.
        /// Buffers must outlive the DB and must not be moved during a statement
        /// or transaction. No initialization reads unused row/version storage.
        /// Validation completes before any binding is changed.
        pub fn bindStorage(self: *Self, backings: [config.tables]StorageBacking, refs: []u32) Error!void {
            if (comptime !config.external_storage) @compileError("bindStorage requires external_storage");
            if (self.csn != 0 or self.large_pages != null or refs.len == 0 or refs.len > 0x7fffffff) return error.InvalidParameterValue;
            for (&self.tables) |*table| if (table.live) return error.InvalidParameterValue;
            for (&self.txs) |*tx| if (tx.active) return error.InvalidParameterValue;
            var spans: [config.tables * storage_fields.len + 3]StorageSpan = undefined;
            spans[0] = .{ .start = @intFromPtr(self), .end = @intFromPtr(self) + @sizeOf(Self) };
            spans[1] = try StorageSpan.of(refs);
            spans[spans.len - 1] = if (comptime config.external_workspace) try StorageSpan.of(self.workspace.query.cells) else .{ .start = 0, .end = 0 };
            for (backings, 0..) |backing, i| {
                if (!backing.valid()) return error.InvalidParameterValue;
                inline for (storage_fields, 0..) |field, index| {
                    spans[2 + i * storage_fields.len + index] = try StorageSpan.of(@field(backing, field));
                }
            }
            for (spans, 0..) |a, i| for (spans[i + 1 ..]) |b| {
                if (a.overlaps(b)) return error.InvalidParameterValue;
            };
            for (&self.tables, backings) |*table, backing| S.bindBacking(table, backing);
            self.workspace.query.refs = refs;
            self.workspace.query.ref_high = refs.len;
            self.contiguous_backing = null;
        }

        fn largePageSpans(backing: large_object_pages.Pages.Backing) Error![5]StorageSpan {
            return .{
                try StorageSpan.of(backing.rows), try StorageSpan.of(backing.versions),
                try StorageSpan.of(backing.version_rows), try StorageSpan.of(backing.row_index), try StorageSpan.of(backing.key_index),
            };
        }

        /// Attach caller-owned sparse page storage after the ordinary banks
        /// and workspace have been bound. The buffers must stay disjoint.
        pub fn bindLargeObjectPages(self: *Self, backing: large_object_pages.Pages.Backing) Error!void {
            if (comptime !config.external_storage) @compileError("large objects require caller-owned external storage");
            if (self.csn != 0 or !self.replayQuiescent() or self.large_pages != null) return error.InvalidParameterValue;
            const spans = try largePageSpans(backing);
            const instance = StorageSpan{ .start = @intFromPtr(self), .end = @intFromPtr(self) + @sizeOf(Self) };
            const refs = try StorageSpan.of(self.workspace.query.refs);
            const workspace = if (comptime config.external_workspace) try StorageSpan.of(self.workspace.query.cells) else StorageSpan{ .start = 0, .end = 0 };
            for (spans, 0..) |span, i| {
                if (span.overlaps(instance) or span.overlaps(refs) or span.overlaps(workspace)) return error.InvalidParameterValue;
                for (spans[i + 1 ..]) |other| if (span.overlaps(other)) return error.InvalidParameterValue;
                for (&self.tables) |*table| {
                    const bank = S.backingOf(table);
                    inline for (storage_fields) |field| {
                        if (span.overlaps(try StorageSpan.of(@field(bank, field)))) return error.InvalidParameterValue;
                    }
                }
            }
            self.large_pages = try large_object_pages.Pages.init(backing);
        }

        /// The startup owner holds exclusive access across replay, including
        /// validation and durable-log repair. A failed replay remains active
        /// until startup is abandoned or a subsequent attempt completes.
        pub fn setStartupRecovery(self: *Self, recovering: bool) void {
            self.startup_recovery_active = recovering;
        }

        pub fn startupRecoveryActive(self: *const Self) bool {
            return self.startup_recovery_active;
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

        fn copyBankFits(dst: *const S.Table, src: *const S.Table) bool {
            return dst.rows.len >= src.row_high and dst.versions.len >= src.version_high and dst.row_index.len != 0 and dst.key_index.len != 0 and
                S.indexFits(dst, src.index_count, src.version_used) and S.schemaFits(dst, src.columns[0..src.column_count]);
        }

        const CopyBankPlan = struct {
            owner: [config.tables]?usize = @splat(null),
            selected: [config.tables]?usize = @splat(null),

            /// Find an augmenting path through already matched banks.
            fn add(plan: *CopyBankPlan, destination: *const Self, source: *const Self, logical: usize) bool {
                var parent: [config.tables]?usize = @splat(null);
                var queue: [config.tables]usize = undefined;
                queue[0] = logical;
                var count: usize = 1;
                var head: usize = 0;
                while (head < count) : (head += 1) {
                    const request = queue[head];
                    // Prefer the same slot when it fits, then search all banks.
                    for (0..config.tables) |offset| {
                        const bank = (request + offset) % config.tables;
                        if (parent[bank] != null or !copyBankFits(&destination.tables[bank], &source.tables[request])) continue;
                        parent[bank] = request;
                        if (plan.owner[bank]) |previous| {
                            queue[count] = previous;
                            count += 1;
                            continue;
                        }
                        var available = bank;
                        while (true) {
                            const next = parent[available].?;
                            const before = plan.selected[next];
                            plan.owner[available] = next;
                            plan.selected[next] = available;
                            available = before orelse return true;
                        }
                    }
                }
                return false;
            }
        };

        const CopySpans = [config.tables * storage_fields.len + 3]StorageSpan;

        fn boundCopySpans(self: *const Self) Error!CopySpans {
            var spans: CopySpans = undefined;
            spans[0] = .{ .start = @intFromPtr(self), .end = @intFromPtr(self) + @sizeOf(Self) };
            spans[1] = try StorageSpan.of(self.workspace.query.refs);
            spans[spans.len - 1] = if (comptime config.external_workspace) try StorageSpan.of(self.workspace.query.cells) else .{ .start = 0, .end = 0 };
            for (&self.tables, 0..) |*table, bank| {
                inline for (storage_fields, 0..) |field, index| {
                    spans[2 + bank * storage_fields.len + index] = try StorageSpan.of(@field(table, field));
                }
            }
            return spans;
        }

        fn rebindCopyBanks(self: *Self, source: *const Self) Error!void {
            const targets = try self.boundCopySpans();
            const sources = try source.boundCopySpans();
            for (targets) |destination| for (sources) |origin| {
                if (destination.overlaps(origin)) return error.InvalidParameterValue;
            };
            var plan: CopyBankPlan = .{};
            for (&source.tables, 0..) |*table, slot| {
                if (table.live and !plan.add(self, source, slot)) return error.WorkspaceCapacity;
            }
            var banks: [config.tables]StorageBacking = undefined;
            for (&banks, &self.tables) |*backing, *table| backing.* = S.backingOf(table);
            var unused: usize = 0;
            for (&self.tables, plan.selected) |*table, selected| {
                const bank = selected orelse blk: {
                    while (plan.owner[unused] != null) : (unused += 1) {}
                    defer unused += 1;
                    break :blk unused;
                };
                S.bindBacking(table, banks[bank]);
            }
        }

        /// Copies into independently bound external buffers. Experimental
        /// heterogeneous banks may be permuted before the logical copy.
        /// Capacity and ownership checks complete before any bank changes.
        pub fn copyFromInto(self: *Self, source: *const Self) Error!void {
            if (self == source) return;
            for (&self.txs) |*tx| if (tx.active) return error.InvalidParameterValue;
            for (&source.txs) |*tx| if (tx.active) return error.InvalidParameterValue;
            if (source.large_pages) |*pages| {
                if (pages.committed_count != 0 and (self.large_pages == null or self.large_pages.?.capacity() < pages.committed_count))
                    return error.WorkspaceCapacity;
                const destination = try self.boundCopySpans();
                const source_parts = try largePageSpans(pages.backing());
                for (source_parts) |part| for (destination) |other| {
                    if (part.overlaps(other)) return error.InvalidParameterValue;
                };
                if (self.large_pages) |*target_pages| {
                    for (source_parts) |part| for (try largePageSpans(target_pages.backing())) |other| {
                        if (part.overlaps(other)) return error.InvalidParameterValue;
                    };
                }
            }
            if (self.large_pages) |*pages| {
                const origin = try source.boundCopySpans();
                for (try largePageSpans(pages.backing())) |part| for (origin) |other| {
                    if (part.overlaps(other)) return error.InvalidParameterValue;
                };
            }
            if (comptime S.integral_enabled) {
                try self.rebindCopyBanks(source);
            } else for (&self.tables, &source.tables) |*dst, *src| {
                if (src.live and !copyBankFits(dst, src)) return error.WorkspaceCapacity;
            }
            if (self.large_pages) |*pages| {
                if (source.large_pages) |*origin| {
                    pages.copyCommitted(origin, source.csn);
                } else pages.clear();
            }
            self.copyState(source);
        }

        fn copyState(self: *Self, source: *const Self) void {
            if (self == source) return;
            self.oid_counter = source.oid_counter;
            self.next_constraint_oid = source.next_constraint_oid;
            self.next_default_oid = source.next_default_oid;
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
            self.exclusive_table_waiters = .{};
            self.outcome = .{};
            self.dialect = .postgres;
            self.session = .{};
            self.session_state = null;
            self.default_session_state = .{};
            self.session_counter = 0;
            self.cursors.slots = @splat(.{});
            self.cursors.used_rows = 0;
            self.cursors.value_used = 0;
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
            if (self.outcome.command == .select or self.outcome.command == .fetch or self.outcome.command == .show or self.outcome.command == .explain) return;
            result.clear(self.outcome.affected);
            result.mysql_insert_id = self.outcome.mysql_insert_id;
            result.mysql_generated_id = self.outcome.mysql_generated_id;
            result.command = self.outcome.command;
            result.create_query_data = self.outcome.create_query_data;
            const returned = &self.outcome.returning;
            if (returned.count == 0) return;
            result.column_count = returned.count;
            result.non_null_columns = returned.non_null_columns;
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
            const slot = try self.reserveTransaction();
            const tx = &self.txs[slot];
            const state = self.sessionState();
            tx.isolation = state.values.isolation;
            tx.read_only = state.values.read_only;
            tx.deferrable = state.values.deferrable;
            tx.session = state.id;
            state.beginTransaction(tx.epoch);
            return slot;
        }

        fn reserveTransaction(self: *Self) Error!u16 {
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
                self.setTableWait(slot, null);
                tx.seq_dirty = .{};
                tx.copy_table = null;
                tx.copy_rows = 0;
                tx.deferred_checks = false;
                tx.constraints_all = null;
                tx.constraint_mode_count = 0;
                tx.isolation = .read_committed;
                tx.read_only = false;
                tx.deferrable = false;
                tx.snapshot_csn = null;
                tx.snapshot_cid = 0;
                tx.session = 0;
                tx.ssi = null;
                tx.prepared = false;
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

        pub fn prepareTransactionPayload(self: *Self, slot: u16, gid: two_phase.Gid, database: u32, at: i64, buffer: []u8) Error![]const u8 {
            if (!self.active(slot)) return error.NoActiveTransaction;
            const tx = &self.txs[slot];
            const state = self.ownSession(slot) orelse return error.NoActiveTransaction;
            if (tx.prepared or tx.copy_table != null or tx.pin != null or tx.running_snap != null) return error.ObjectNotInPrerequisiteState;
            if (tx.ssi != null or tx.seq_dirty.any() or tx.deferred_checks or state.listen_action_count != 0) return error.UnsupportedStatement;
            for (self.notify.pending) |entry| if (entry.used and entry.slot == slot and entry.epoch == tx.epoch) return error.UnsupportedStatement;
            for (self.cursors.slots) |cursor| if (cursor.used and cursor.hold and cursor.slot == slot and cursor.epoch == tx.epoch) return error.UnsupportedStatement;
            for (tx.lock_list[0..tx.lock_len]) |entry| if (entry.kind == .advisory) return error.UnsupportedStatement;
            try self.deferredViolation(slot);

            const metadata: two_phase.Metadata = .{
                .gid = gid,
                .owner = effectiveRole(state),
                .database = database,
                .prepared_at = at,
            };
            var envelope = try two_phase.PrepareWriter.init(buffer, &metadata);
            for (&self.tables, 0..) |*table, index| {
                const mode = self.locks.modes[index][slot];
                if (mode == 0) continue;
                if (!S.committedTable(table)) return error.UnsupportedStatement;
                try envelope.addLock(.{ .table_oid = table.oid, .rowid = 0, .mode = mode });
            }
            for (&self.locks.rows) |*lock| {
                if (!lock.used) continue;
                for (lock.holders[0..lock.count]) |holder| if (holder.slot == slot) {
                    try envelope.addLock(.{ .table_oid = self.tables[lock.table].oid, .rowid = lock.rowid, .mode = @intFromEnum(holder.mode) });
                    break;
                };
            }
            var writer = try change_log.Writer.init(envelope.changes(), 0);
            for (tx.writes[0..tx.write_len]) |entry| {
                const tag: change_log.Op = switch (entry.kind) {
                    .insert => .insert,
                    .update => .update,
                    .delete => .delete,
                    else => return error.UnsupportedStatement,
                };
                const table = &self.tables[entry.table];
                if (!S.committedTable(table) or table.relkind != 'r') return error.UnsupportedStatement;
                const version = &table.versions[if (tag == .delete) entry.old else entry.new];
                var old_scratch: S.VersionRowScratch = undefined;
                const old = if (tag == .insert) &.{} else S.versionValues(table, entry.old, &old_scratch);
                var new_scratch: S.VersionRowScratch = undefined;
                const new = if (tag == .delete) &.{} else S.versionValues(table, entry.new, &new_scratch);
                try C.encodePreparedRow(&writer, tag, table.oid, table.rows[version.rowSlot()].rowid, old, new);
            }
            return envelope.finish(try writer.finish());
        }

        fn effectiveRole(state: *const Sess.State) u32 {
            return if (state.values.role == 0) state.sessionUser() else state.values.role;
        }

        pub fn canResolvePrepared(self: *Self, owner: u32) bool {
            const role = effectiveRole(self.sessionState());
            return role == owner or self.catalog_objects.superuser(role, .{ .csn = self.csn });
        }

        /// After stable storage, detach the SQL session while retaining the
        /// active transaction slot, pending row versions and all grants.
        pub fn detachPrepared(self: *Self, slot: u16) void {
            self.endSessionTransaction(slot, true);
            const tx = &self.txs[slot];
            tx.prepared = true;
            tx.session = 0;
            tx.sub_len = 0;
            tx.snapshot_csn = null;
        }

        pub fn publishPrepared(self: *Self, slot: u16) void {
            // This payload contains only prepared row changes. Sequence
            // log-ahead values still belong to the ordinary commit stream.
            const carried = self.seq_carried;
            self.publishCommit(slot);
            self.seq_carried = carried;
        }

        fn preparedTable(self: *const Self, oid: u32) Error!usize {
            for (&self.tables, 0..) |*table, index| if (table.oid == oid and S.committedTable(table)) return index;
            return error.ChangeRecordConflict;
        }

        /// Validate the prepared record at its place in the WAL, even if a
        /// later decision aborts it. Before-images are matched when staged.
        pub fn validatePrepared(self: *const Self, prepared: two_phase.Prepared) Error!void {
            if (self.catalog_objects.roleFlags(prepared.metadata.owner, .{ .csn = self.csn }) == null) return error.ChangeRecordConflict;
            var locks = prepared.locks;
            while (locks.next()) |lock| _ = try self.preparedTable(lock.table_oid);
            var reader = try C.PreparedReader.init(prepared.changes);
            if (reader.remaining > M.write_capacity) return error.WriteSetCapacity;
            var old: V.Row = .{};
            var new: V.Row = .{};
            while (try reader.next(&old, &new)) |change| {
                const table = &self.tables[try self.preparedTable(change.oid)];
                if (table.relkind != 'r') return error.InvalidChangeRecord;
                if (change.tag != .insert) try validatePreparedImage(table, old.cells[0..change.old_count]);
                if (change.tag != .delete) try validatePreparedImage(table, new.cells[0..change.new_count]);
            }
        }

        fn validatePreparedImage(table: *const S.Table, values: []const V.Cell) Error!void {
            if (values.len != table.column_count) return error.InvalidChangeRecord;
            for (table.columns[0..values.len], values) |*column, *cell| {
                V.validate(column, cell) catch return error.ChangeRecordConflict;
            }
        }

        /// Installs a recovered PREPARE without committing it. Only recovery
        /// calls this, under exclusive access before starting client sessions.
        pub fn restorePrepared(self: *Self, prepared: two_phase.Prepared) Error!u16 {
            const slot = try self.reserveTransaction();
            var old_next: [config.tables]u64 = undefined;
            for (&self.tables, &old_next) |*table, *next| next.* = table.next_rowid;
            errdefer {
                self.abort(slot);
                for (&self.tables, old_next) |*table, next| table.next_rowid = next;
            }
            var table_locks = prepared.locks;
            while (table_locks.next()) |lock| {
                if (lock.rowid != 0) continue;
                const index = try self.preparedTable(lock.table_oid);
                if (self.locks.holdsTable(index, slot)) return error.InvalidChangeRecord;
                var modes = lock.mode;
                while (modes != 0) {
                    const bit = @as(u8, 1) << @intCast(@ctz(modes));
                    modes &= modes - 1;
                    const mode: locks_module.TableMode = @enumFromInt(bit);
                    var waits: L.Set = .{};
                    self.locks.tableHolders(index, slot, mode, &waits);
                    if (waits.any()) return error.ChangeRecordConflict;
                    if (self.locks.grantTable(index, slot, mode)) try M.recordLock(self, slot, .{ .kind = .table, .table = @intCast(index), .mode = bit });
                }
            }
            var reader = try C.PreparedReader.init(prepared.changes);
            var old: V.Row = .{};
            var new: V.Row = .{};
            const tx = &self.txs[slot];
            while (try reader.next(&old, &new)) |change| {
                if (tx.cid == 0xffffffff) return error.InvalidChangeRecord;
                tx.cid += 1;
                try self.restorePreparedRow(slot, change, &old.cells, &new.cells);
            }
            var row_locks = prepared.locks;
            while (row_locks.next()) |lock| {
                if (lock.rowid == 0) continue;
                const index = try self.preparedTable(lock.table_oid);
                const table = &self.tables[index];
                const row = S.findRow(table, lock.rowid) orelse return error.ChangeRecordConflict;
                if (table.rows[row].newest == 0) return error.ChangeRecordConflict;
                const newest = &table.versions[table.rows[row].newest - 1];
                if (!self.locks.holdsTable(index, slot)) return error.InvalidChangeRecord;
                if (newest.pendingCreation()) |creation| if (creation.tx.slot != slot) return error.ChangeRecordConflict;
                if (newest.pendingDeletion()) |deletion| if (deletion.tx.slot != slot) return error.ChangeRecordConflict;
                const mode: locks_module.RowMode = @enumFromInt(lock.mode);
                if (self.locks.holdsRow(index, lock.rowid, slot, .key_share)) return error.InvalidChangeRecord;
                var waits: L.Set = .{};
                self.locks.rowHolders(index, lock.rowid, slot, mode, &waits);
                if (waits.any()) return error.ChangeRecordConflict;
                if (try self.locks.grantRow(index, lock.rowid, slot, mode)) |granted| try M.recordLock(self, slot, granted);
            }
            tx.prepared = true;
            return slot;
        }

        fn restorePreparedRow(self: *Self, slot: u16, change: C.PreparedRow, old_image: *const E.Row, new_image: *const E.Row) Error!void {
            const index = try self.preparedTable(change.oid);
            const table = &self.tables[index];
            if (table.relkind != 'r' or !self.locks.holdsTableMode(index, slot, .row_exclusive)) return error.InvalidChangeRecord;
            const tx = &self.txs[slot];
            const snap: Snapshot = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid };
            const row = S.findRow(table, change.rowid);
            if (change.tag == .insert and row != null) return error.ChangeRecordConflict;
            var previous: ?u32 = null;
            var prior_scratch: S.VersionRowScratch = undefined;
            if (change.tag != .insert) {
                if (change.old_count != table.column_count) return error.InvalidChangeRecord;
                const current = S.visibleAt(table, row orelse return error.ChangeRecordConflict, snap) orelse return error.ChangeRecordConflict;
                var waits: L.Set = .{};
                const target_row = try self.target(slot, index, current, snap, .write, &waits);
                if (target_row != .ready or target_row.ready != current) return error.ChangeRecordConflict;
                const prior = S.versionValues(table, current, &prior_scratch);
                for (0..table.column_count) |column| {
                    const actual = &prior[column];
                    const before = &old_image[column];
                    if (@as(V.CellTag, actual.*) != @as(V.CellTag, before.*) or V.compare(actual, before) != 0) return error.ChangeRecordConflict;
                }
                previous = current;
            }
            if (change.tag != .delete) {
                try validatePreparedImage(table, new_image[0..change.new_count]);
                if (table.primary_column) |column| switch (S.primaryKeyCheck(table, &new_image[column], row orelse 0xffffffff, snap)) {
                    .free => {},
                    else => return error.ChangeRecordConflict,
                };
                const before = if (previous) |version| S.borrowVersionRow(table, version, &prior_scratch) else null;
                if ((self.uniqueTaken(slot, index, new_image, row orelse 0xffffffff, before, snap) catch return error.ChangeRecordConflict) != null) return error.ChangeRecordConflict;
                self.exclusionTaken(slot, index, new_image, row orelse 0xffffffff, before, snap) catch return error.ChangeRecordConflict;
            }
            switch (change.tag) {
                .insert => try self.placeInsert(slot, index, change.rowid, new_image, snap),
                .update => try self.placeUpdate(slot, index, row.?, previous.?, new_image, snap),
                .delete => try self.placeDelete(slot, index, previous.?, snap),
                else => unreachable,
            }
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
            if (tx.large_objects.used) tx.large_objects = .{};
            tx.running_snap = null;
            tx.sub_len = 0;
            tx.pin = null;
            tx.fresh = false;
            tx.waiting_for = .{};
            self.setTableWait(slot, null);
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
            if (tx.large_objects.used) tx.large_objects.discard(tx.userSavepoints(), null);
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
                if (tx.large_objects.used) tx.large_objects.discard(0, tx.cid);
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
            self.setTableWait(slot, null);
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
            if (self.txs[slot].large_objects.used) self.txs[slot].large_objects.release(index);
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
            if (tx.large_objects.used) tx.large_objects.discard(index + 1, null);
            self.sessionRollback(slot, index + 1, false);
            if (self.ownSession(slot)) |state| state.rollbackTo(index);
            self.wake_epoch +%= 1;
            return index;
        }

        pub fn savepointDepth(self: *const Self, slot: u16) usize {
            return self.txs[slot].userSavepoints();
        }

        // ---- statements ---------------------------------------------------

        /// Raw grammar pass for an entire PostgreSQL Query message. Reuses the
        /// statement parser's scratch without binding, starting a transaction
        /// or executing commands. A statement outside the supported grammar
        /// fails the batch after checking later statements for syntax errors.
        pub fn preflightPostgresBatch(self: *Self, source: []const u8) Error!usize {
            for (source) |byte| if (byte == 0) return error.Syntax;
            var statements: PostgresStatements = .{ .source = source };
            var count: usize = 0;
            var unsupported = false;
            while (try statements.next()) |part| {
                count += 1;
                self.parsePostgresEnvelope(part.slice(source)) catch |err| {
                    if (err != error.UnsupportedStatement) return err;
                    unsupported = true;
                };
            }
            if (unsupported) return error.UnsupportedStatement;
            return count;
        }

        fn parsePostgresEnvelope(self: *Self, source: []const u8) Error!void {
            if (try large_object_command.parseSql(source) != null) return;
            const options: parser_module.Options = .{ .dialect = .postgres };
            if (try P.parseDatabaseCommand(source, options)) |_| return;
            if (R.classify(source) != null) {
                self.workspace.nodes.reset();
                var routine: R.Statement = undefined;
                return R.parse(source, &self.workspace.nodes, &routine);
            }
            _ = try P.parseTopWithOptions(source, &self.workspace.nodes, options);
        }

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
            if (tx.prepared) return error.ObjectNotInPrerequisiteState;
            // Routine statements (B11 wave 3) have their own grammar.
            const routine = options.mode == .standard and R.classify(source) != null;
            const top: P.Parsed = if (routine) .{ .command = .{ .control = .commit } } else P.parseTopWithOptions(source, &self.workspace.nodes, .{ .mode = options.mode, .dialect = self.dialect }) catch |err| {
                if (options.@"resume") self.dropStatement(slot);
                return legacy(options.mode, err);
            };
            const parsed = &top.command;
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
                tx.mysql_insert_value = null;
                tx.mysql_first_generated = 0;
                tx.mysql_explicit_insert_id = 0;
                self.modifying[slot] = .{};                snap = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid };
                // The first statement that needs a snapshot fixes the
                // transaction snapshot (REPEATABLE READ / SERIALIZABLE use it).
                if (needsSnapshot(parsed)) {
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
            const ran = if (routine) self.routineBody(slot, source, snap, result) else self.body(slot, source, parsed, snap, result, .{ .mode = options.mode, .explain = top.explain });
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
            self.setTableWait(slot, null);
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
                .routines = &self.objects, .variables = if (self.routine_frame) |frame| &frame.variables else null,
                .namespace_usage = .{ .ptr = self, .check = &bindNamespaceUsage },
                .namespace_create = .{ .ptr = self, .check = &bindNamespaceCreate } };
        }

        fn evalContext(self: *const Self, source: []const u8) E.Context {
            return .{ .source = source, .pool = &self.workspace.nodes, .session = &self.session };
        }

        const BodyOptions = struct { mode: ParseMode, explain: ?P.Explain = null };

        fn body(self: *Self, slot: u16, original: []const u8, parsed: *const A.Statement, snap: Snapshot, result: *Result, execution_options: BodyOptions) Error!void {
            const mode = execution_options.mode;
            const explain = execution_options.explain;
            self.workspace.query.read_stats = .{};
            try self.session.checkpoint();
            if (explain != null and self.dialect != .postgres) return error.UnsupportedStatement;
            switch (parsed.*) {
                .control => |command| return self.runControl(slot, original, command, snap, result),
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
            const expanded = try expandRelations(self, &self.workspace, original, snap, &statement_copy, self.session.role, &self.session);
            const source = try self.secureTarget(&statement_copy, expanded, original, snap);
            var context = self.bindContext(source, mode, snap);
            context.stored_source_start = original.len;
            if (explain) |options| context.describe_only = !options.analyze;
            if (parsed.* == .select and self.routine_frame == null and self.active_params == null) context.user_type_catalog = &self.catalog_objects;
            const bound = try B.bind(&context, &statement_copy);
            if (self.txs[slot].read_only and (explain == null or explain.?.analyze)) try readOnlyCheck(&bound, &self.workspace.plans);
            try self.checkPrivileges(&bound, snap);
            try self.secureNewRows(&bound, source, snap);
            if (explain) |options| return self.runExplain(slot, source, &bound, snap, result, options);
            switch (bound) {
                .control => return error.UnsupportedStatement,
                .select => |*select| {
                    self.outcome = .{ .affected = 0, .command = .select };
                    try self.lockSelect(slot, select);
                    return self.runBoundSelect(slot, source, select, snap, result);
                },
                .query => |root| {
                    self.outcome = .{ .affected = 0, .command = .select };
                    const plans = &self.workspace.plans;
                    try self.lockSources(slot);
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
                    try self.createSequence(slot, create.namespace, create.name, create.spec, 0, 0, false, snap);
                    break :blk 0;
                },
                .drop_sequence => |index| blk: {
                    if (self.seqs[index].owner != 0) return error.DependentObjects;
                    try self.dropSequence(slot, index, snap);
                    break :blk 0;
                },
                .insert => |*insert| blk: {
                    try self.lockTable(slot, insert.table, .row_exclusive);
                    if (mysqlAutoColumn(&self.tables[insert.table]) != null) {
                        if (self.dialect != .mysql or insert.plan != ast.none or insert.rows == ast.none or
                            insert.conflict.action != .none or insert.returning.count != 0 or self.insertHooks(insert.table, snap))
                            return error.UnsupportedStatement;
                    }
                    if (insert.returning.output) try self.validateTsqlOutput(insert.table, .insert, snap);
                    if (insert.replace) try self.validateMysqlReplace(slot, insert.table, snap);
                    if (insert.replace or insert.conflict.action != .none) try self.ssiRead(slot, insert.table);
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
                    if (mysqlAutoColumn(&self.tables[update.table]) != null and self.dialect != .mysql)
                        return error.UnsupportedStatement;
                    if (update.returning.output) try self.validateTsqlOutput(update.table, .update, snap);
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
                    if (delete.returning.output) try self.validateTsqlOutput(delete.table, .delete, snap);
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
                .legacy_attribute_options => |options| blk: {
                    try self.lockTable(slot, options.table, .share_update_exclusive);
                    if (options.validation) |err| return err;
                    break :blk 0;
                },
                .alter_sequence => |*alter| blk: {
                    try self.alterSequence(slot, alter.slot, alter.options, alter.ownership, snap);
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
            const create_query_data = switch (bound) {
                .create_table => |*create| create.plan != ast.none,
                else => false,
            };
            self.outcome = .{ .affected = affected, .command = B.command(&bound), .create_query_data = create_query_data,
                .noop = bound == .noop or bound == .legacy_attribute_options };
            if (bound == .insert) {
                const tx = &self.txs[slot];
                self.outcome.mysql_generated_id = tx.mysql_first_generated;
                self.outcome.mysql_insert_id = if (tx.mysql_first_generated != 0) tx.mysql_first_generated else tx.mysql_explicit_insert_id;
            }
            switch (bound) {
                .insert => |*insert| if (insert.returning.count != 0) try self.returnRows(slot, source, &insert.returning, insert.table, insert.plan == ast.none, result.rows.len),
                .update => |*update| if (update.returning.count != 0) try self.returnRows(slot, source, &update.returning, update.table, true, result.rows.len),
                .delete => |*delete| if (delete.returning.count != 0) try self.returnRows(slot, source, &delete.returning, delete.table, true, result.rows.len),
                else => {},
            }
        }

        fn lockSelect(self: *Self, slot: u16, select: *const B.Select) Error!void {
            if (select.table) |table| try self.lockTable(slot, table, if (select.lock.strength == .none) .access_share else .row_share);
        }

        fn runBoundSelect(self: *Self, slot: u16, source: []const u8, select: *const B.Select, snap: Snapshot, output: anytype) Error!void {
            if (select.lock.strength == .none) return self.executeBoundSelect(slot, source, select, snap, X.NoLock{}, output);
            const row_mode: locks_module.RowMode = switch (select.lock.strength) {
                .update, .none => .update,
                .no_key_update => .no_key_update,
                .share => .share,
                .key_share => .key_share,
            };
            const locker: RowLocker = .{ .db = self, .slot = slot, .snap = snap, .mode = row_mode, .wait = select.lock.wait };
            return self.executeBoundSelect(slot, source, select, snap, locker, output);
        }

        fn executeBoundSelect(self: *Self, slot: u16, source: []const u8, select: *const B.Select, snap: Snapshot, locker: anytype, output: anytype) Error!void {
            const work = &self.workspace.query;
            const committed_only = self.txs[slot].write_len == 0;
            if (comptime @TypeOf(output) == *Result) {
                try X.select(&self.tables, source, &self.workspace.nodes, select, snap, output, locker, &self.session, committed_only, &work.read_stats, work);
            } else {
                output.* = try X.observeSelect(&self.tables, source, &self.workspace.nodes, select, snap, locker, &self.session, committed_only, &work.read_stats, work);
            }
        }

        const explain_column = "QUERY PLAN";

        fn validateExplain(self: *const Self, bound: *const B.Bound) Error!void {
            if (self.dialect != .postgres) return error.UnsupportedStatement;
            if (config.name_bytes < explain_column.len) return error.NameCapacity;
            switch (bound.*) {
                .select => {},
                .query => |root| {
                    const plans = &self.workspace.plans;
                    const plan = &plans.items[root];
                    if (plans.dml_len != 0 or plan.grouped or plan.window_count != 0) return error.UnsupportedStatement;
                },
                else => return error.UnsupportedStatement,
            }
        }

        fn explainHeader(result: *Result) void {
            result.clear(0);
            result.command = .explain;
            result.column_count = 1;
            var name: Name = .{ .len = @min(config.name_bytes, explain_column.len) };
            @memcpy(name.bytes[0..name.len], explain_column[0..name.len]);
            result.column_names[0] = name;
            result.column_types[0] = .json;
            result.column_typmods[0] = -1;
        }

        fn runExplain(self: *Self, slot: u16, source: []const u8, bound: *const B.Bound, snap: Snapshot, result: *Result, options: P.Explain) Error!void {
            try self.validateExplain(bound);
            const prefix = "[{\"Plan\":{\"Node Type\":\"";
            const actual_rows = ",\"Actual Rows\":";
            const actual_loops = ",\"Actual Loops\":1";
            const suffix = "}}]";
            const max_digits = (@bitSizeOf(usize) + 2) / 3;
            const max_label = comptime blk: {
                var longest: usize = 0;
                for (@typeInfo(X.SelectOperation).@"enum".field_names) |field| {
                    const operation = @field(X.SelectOperation, field);
                    longest = @max(longest, operation.name().len);
                }
                break :blk longest;
            };
            const minimum_capacity = prefix.len + max_label + 1 + suffix.len +
                if (options.analyze) actual_rows.len + max_digits + actual_loops.len else 0;
            if (config.text_bytes < minimum_capacity) return error.TextCapacity;
            if (result.rows.len == 0) return error.RowCapacity;

            var observation: X.SelectObservation = .{ .operation = .select_plan };
            switch (bound.*) {
                .select => |*select| {
                    try self.lockSelect(slot, select);
                    if (options.analyze) try self.runBoundSelect(slot, source, select, snap, &observation);
                },
                .query => |root| {
                    try self.lockSources(slot);
                    observation.operation = .query_plan;
                    if (options.analyze) observation = try X.observeQuery(&self.tables, source, &self.workspace.nodes,
                        &self.workspace.plans, root, snap, &self.session, &self.workspace.query, self.txs[slot].write_len == 0);
                },
                else => unreachable,
            }
            var buffer: [512]u8 = undefined;
            var text: CatalogTextWriter = .{ .out = &buffer };
            text.add(prefix);
            text.add(observation.operation.name());
            text.add("\"");
            if (options.analyze) {
                var digits: [max_digits]u8 = undefined;
                text.add(actual_rows);
                text.add(formatUnsigned(observation.rows, &digits));
                text.add(actual_loops);
            }
            text.add(suffix);
            explainHeader(result);
            result.rows[0].cells[0] = nameCell(text.slice());
            result.row_count = 1;
            self.outcome = .{ .command = .explain, .noop = true };
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
            var row_scratch: S.VersionRowScratch = undefined;
            const table = &self.tables[table_index];
            var row: usize = 0;
            for (writes) |entry| {
                if (!rowWrite(entry.kind) or entry.table != table_index) continue;
                try self.session.checkpoint();
                ctx.row = S.borrowVersionRow(table, if (entry.kind == .delete) entry.old else entry.new, &row_scratch);
                const at = work.cell_high + row * width;
                for (list.targets[0..width], 0..) |id, column| work.cells[at + column] = try E.eval(&ctx, id);
                work.refs[out.start + row] = @intCast(at);
                row += 1;
            }
            work.pinned_cells = work.cells.len - work.cell_high;
            work.pinned_refs = work.refs.len - work.ref_high;
            return out;
        }

        /// RETURNING: one row per write (new for INSERT/UPDATE, old for
        /// DELETE). T-SQL OUTPUT carries an image selector per result column.
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
            if (list.output and count != self.outcome.affected) return error.UnsupportedStatement;
            if (count > result_capacity) return error.RowCapacity;
            const work = &self.workspace.query;
            if (fresh) X.resetWork(work);
            const width = list.count;
            const base = try X.stageCells(work, count * width);
            var ctx = self.evalContext(source);
            var row_scratch: S.VersionRowScratch = undefined;
            var cell_scratch: Cell = undefined;
            var row: usize = 0;
            for (writes) |entry| {
                if (!rowWrite(entry.kind) or (entry.table != table_index and !self.descends(entry.table, table_index))) continue;
                const table = &self.tables[entry.table];
                if (list.output) {
                    try self.session.checkpoint();
                    for (list.targets[0..width], 0..) |id, column| {
                        const version = if (list.deleted_columns.isSet(column)) entry.old else entry.new;
                        const source_column = self.workspace.nodes.nodes[id].column;
                        work.cells[base + row * width + column] = S.borrowVersionCell(table, version, source_column, &cell_scratch).*;
                    }
                } else {
                    ctx.row = S.borrowVersionRow(table, if (entry.kind == .delete) entry.old else entry.new, &row_scratch);
                    for (list.targets[0..width], 0..) |id, column| work.cells[base + row * width + column] = try E.eval(&ctx, id);
                }
                row += 1;
            }
            var returned: Returned = .{ .count = width, .rows = count, .base = base, .non_null_columns = list.non_null_columns };
            @memcpy(returned.names[0..width], list.names[0..width]);
            @memcpy(returned.types[0..width], list.types[0..width]);
            @memcpy(returned.typmods[0..width], list.typmods[0..width]);
            self.outcome.returning = returned;
        }

        fn rowWrite(kind: anytype) bool {
            return kind == .insert or kind == .update or kind == .delete;
        }

        fn validateTsqlOutput(self: *const Self, index: usize, command: CommandTag, snap: Snapshot) Error!void {
            const rule: u8, const event: u8 = switch (command) {
                .insert => .{ '3', routine_catalog.tg_insert },
                .update => .{ '2', routine_catalog.tg_update },
                .delete => .{ '4', routine_catalog.tg_delete },
                else => unreachable,
            };
            const oid = self.tables[index].oid;
            // OUTPUT without INTO must reject a trigger for this event. Rules
            // and cascades can change which writes correspond to the DML.
            for (&self.objects.triggers) |*trigger| {
                if (trigger.live and trigger.table_oid == oid and trigger.tgtype & event != 0 and
                    trigger.stamp.visible(snap)) return error.UnsupportedStatement;
            }
            if (self.ruleKind(index, rule, snap) != .none) return error.UnsupportedStatement;
            if (command == .insert) return;
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') continue;
                const other = &self.tables[found.slot];
                for (other.constraints[0..other.constraint_count]) |constraint| {
                    if (constraint.kind != .foreign or constraint.ref_oid != oid) continue;
                    const action = if (command == .update) constraint.on_update else constraint.on_delete;
                    switch (action) {
                        .no_action, .restrict => {},
                        .cascade, .set_null, .set_default => return error.UnsupportedStatement,
                    }
                }
            }
        }

        /// Reclamation horizon covers running bodies, parked statements and
        /// COPY between messages. A pre-data lock wait may re-snapshot.
        fn horizon(self: *const Self) u64 {
            var out = self.csn;
            for (&self.txs) |*tx| if (tx.active) {
                if (tx.running_snap) |snap| out = @min(out, snap.csn);
                if (tx.large_objects.min_csn) |csn| out = @min(out, csn);
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
            const owner = self.session.role;
            if (owner != CO.bootstrap_role) {
                if (self.catalog_objects.pendingReference(owner, snap)) |other| return self.objectPark(slot, other);
                var latest = snap;
                latest.csn = self.csn;
                if (self.catalog_objects.byOid(.role, owner, latest) == null) return error.SerializationFailure;
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
            schema.* = .{ .live = true, .pending_create = true, .creator = slot, .oid = change_log.first_oid + self.oid_counter, .owner = owner, .private_usage = self.dialect == .postgres, .name = name };
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
            // DDL must account for dependencies that are committed now,
            // including catalog rows newer than the user's data snapshot.
            var current = snap;
            current.csn = self.csn;
            const namespace = self.catalog.findSchema(schema.name.slice(), current) orelse return error.UndefinedSchema;
            if (namespace.oid != drop.oid or namespace.slot != drop.slot) return error.SerializationFailure;
            if (!self.ownsNamespace(drop.oid, current)) return error.InsufficientPrivilege;
            var waits: L.Set = .{};
            if (schema.pending_drop and schema.creator != slot) waits.add(schema.creator);
            if (self.catalog.namespaceCreator(drop.oid, snap)) |other| waits.add(other);
            if (self.catalog_objects.pendingReference(drop.oid, snap)) |other| waits.add(other);
            if (waits.any()) {
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            var type_count: usize = 0;
            for (&self.catalog_objects.items) |*o| {
                if ((!CO.userType(o.kind) and o.kind != .statistics) or o.target != drop.oid or !O.visible(o, current)) continue;
                if (!drop.cascade) return error.DependentObjects;
                type_count += 1;
            }
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(current, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') {
                    const seq = &self.seqs[found.slot];
                    if (seq.namespace != drop.oid or seq.owner != 0) continue;
                    if (!drop.cascade) return error.DependentObjects;
                    try self.dropSequence(slot, found.slot, current);
                    continue;
                }
                if (self.tables[found.slot].namespace != drop.oid) continue;
                if (!drop.cascade) return error.DependentObjects;
                _ = try self.dropTable(slot, found.slot, true, current);
            }
            if (drop.cascade) {
                // A CASCADE can copy a relation to a different slot while
                // removing a foreign key. Prove this statement left neither
                // a schema member nor a surviving reference to a table it
                // dropped before it can publish the namespace removal.
                var after = current;
                after.cid +%= 1;
                var remaining: [K.relation_rows]K.Found = undefined;
                const remaining_count = self.catalog.visibleRelations(after, &remaining);
                for (remaining[0..remaining_count]) |found| {
                    if (found.kind == 'S') {
                        if (self.seqs[found.slot].namespace == drop.oid) return error.DependentObjects;
                        continue;
                    }
                    const survivor = &self.tables[found.slot];
                    if (survivor.namespace == drop.oid) return error.UnsupportedStatement;
                    for (survivor.constraints[0..survivor.constraint_count]) |*constraint| {
                        if (constraint.kind != .foreign or constraint.ref_oid == survivor.oid) continue;
                        if (self.visibleTableSlot(constraint.ref_oid, current) != null and
                            self.visibleTableSlot(constraint.ref_oid, after) == null) return error.UnsupportedStatement;
                    }
                }
            }
            try self.reserveWrites(slot, 2 + type_count);
            for (&self.catalog_objects.items, 0..) |*o, index| {
                if (CO.userType(o.kind) and o.target == drop.oid and O.visible(o, current)) self.objectDelete(slot, index, current);
            }
            schema.pending_drop = true;
            schema.creator = slot;
            tx.push(.{ .kind = .drop_schema, .table = @intCast(drop.slot) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const changed = self.catalog.dropSchema(drop.slot, current, tx.ref(slot), current.cid, 0, &changes);
            for (changes[0..changed]) |change| tx.push(.{ .kind = .catalog_delete, .table = @intFromEnum(change.relation), .old = change.version }) catch unreachable;
            try self.dropObjectsOf(slot, drop.oid, current);
        }

        /// Schema name of a namespace OID for the system views.
        fn namespaceName(self: *const Self, oid: u32) []const u8 {
            for (catalog_module.namespaces) |namespace| if (namespace.oid == oid) return namespace.name;
            for (&self.schemas) |*schema| if (schema.live and schema.oid == oid) return schema.name.slice();
            return "";
        }

        fn ownsNamespace(self: *const Self, oid: u32, snap: Snapshot) bool {
            if (self.privilegedRole(snap)) return true;
            for (&self.schemas) |*schema| {
                if (schema.live and schema.oid == oid) return self.catalog_objects.memberOf(self.session.role, self.schemaOwner(schema, snap), true, snap);
            }
            return false;
        }

        fn schemaOwner(self: *const Self, schema: *const Schema, snap: Snapshot) u32 {
            const key: O.Object = .{ .kind = .schema_owner, .target = schema.oid };
            const index = self.catalog_objects.findKey(&key, snap) orelse return schema.owner;
            return self.catalog_objects.items[index].owner;
        }

        // ---- catalog objects (B11 wave 3, catalog_objects.sig) --------------

        fn objectIdent(ident: CO.Ident) ast.Ident {
            return .{ .span = .{ .start = ident.span.start, .len = ident.span.len }, .quoted = ident.quoted, .len = ident.len };
        }

        fn objectName(source: []const u8, ident: CO.Ident) Name {
            return identName(source, objectIdent(ident));
        }

        /// Resolve an authenticated username against the committed role catalog.
        /// Roles with a finite connection limit require admission accounting
        /// that this API does not provide, so they cannot log in here.
        pub fn authenticatedRole(self: *const Self, username: []const u8) ?u32 {
            const snapshot: Snapshot = .{ .csn = self.csn };
            const role = self.catalog_objects.roleByName(username, snapshot) orelse return null;
            if (role == CO.bootstrap_role) return role;
            const index = self.catalog_objects.byOid(.role, role, snapshot) orelse return null;
            const entry = &self.catalog_objects.items[index];
            if (entry.flags & CO.role_login == 0 or @as(i32, @bitCast(entry.grant_flags)) >= 0) return null;
            return role;
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
            return self.catalog_objects.items[index].grant_flags & CO.member_admin != 0;
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
                .acl, .schema_acl, .schema_acl_state, .schema_owner, .relation, .policy => o.target == oid,
                .statistics => o.target == oid or o.grantee == oid,
                .publication_table, .publication_schema => o.grantee == oid,
                .comment => o.grantee != CO.class_large_object and o.target == oid,
                else => false,
            };
        }

        fn dropObjectsOf(self: *Self, slot: u16, oid: u32, snap: Snapshot) Error!void {
            if (self.catalog_objects.pendingReference(oid, snap)) |other| return self.objectPark(slot, other);
            var latest = snap;
            latest.csn = self.csn;
            var count: usize = 0;
            for (&self.catalog_objects.items) |*o| {
                if ((o.kind == .statistics or o.kind == .schema_acl or o.kind == .schema_acl_state or o.kind == .schema_owner or CO.publicationMembership(o.kind)) and objectDependent(o, oid) and O.visible(o, latest) != O.visible(o, snap)) return error.SerializationFailure;
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

        fn remapStatistics(self: *Self, slot: u16, oid: u32, sources: []const u8, snap: Snapshot) Error!void {
            var latest = snap;
            latest.csn = self.csn;
            for (0..self.catalog_objects.items.len) |index| {
                const o = &self.catalog_objects.items[index];
                if (o.kind != .statistics or o.grantee != oid) continue;
                if (O.visible(o, latest) != O.visible(o, snap)) return error.SerializationFailure;
                if (!O.visible(o, snap) or o.xmax.epoch != 0 or (o.xmin_csn == 0 and o.xmin_cid == snap.cid)) continue;
                if (self.catalog_objects.pendingConflict(o, snap)) |other| return self.objectPark(slot, other);
                var cols: [CO.statistics_columns]u8 = undefined;
                var count: usize = 0;
                for (sources, 0..) |old, position| {
                    if (std.mem.indexOfScalar(u8, o.textSlice(), old) == null) continue;
                    cols[count] = @intCast(position);
                    count += 1;
                }
                const retained = count == o.text_len;
                if (retained and types.same(o.textSlice(), cols[0..count])) continue;
                try self.reserveWrites(slot, if (retained) 2 else 1);
                var next = o.*;
                self.objectDelete(slot, index, snap);
                if (retained) {
                    try next.setText(cols[0..count], "");
                    _ = try self.objectInsert(slot, &next, false, snap);
                }
            }
        }

        /// A table, view or materialized view named by a catalog-object
        /// statement (42P01), locked in `mode`; null with IF EXISTS.
        fn objectTable(self: *Self, slot: u16, source: []const u8, name: CO.Qualified, mode: locks_module.TableMode, snap: Snapshot) Error!usize {
            if (!name.has_schema and !self.session.public_schema_on_path) return error.TableNotFound;
            const schema_name = if (name.has_schema) objectName(source, name.schema) else Name{};
            const namespace = (try self.namespaceForUsage(self.session.role, if (name.has_schema) schema_name.slice() else null, snap)) orelse return error.UndefinedSchema;
            const found = self.catalog.findIn(namespace, objectName(source, name.name).slice(), snap) orelse return error.TableNotFound;
            if (found.kind == 'S') return error.WrongObjectType;
            try self.lockTable(slot, found.slot, mode);
            return found.slot;
        }

        fn isLargeObjectChild(o: *const O.Object, oid: u32) bool {
            return o.target == oid and (o.kind == .large_object_acl or
                (o.kind == .comment and o.grantee == CO.class_large_object));
        }

        /// Serialize metadata, ACL and comment changes in the same OID namespace.
        fn lockLargeObject(self: *Self, slot: u16, oid: u32, snap: Snapshot) Error!?usize {
            const key: O.Object = .{ .kind = .large_object, .target = oid };
            if (self.catalog_objects.pendingConflict(&key, snap)) |other| return self.objectPark(slot, other);
            var latest = snap;
            latest.csn = self.csn;
            const index = self.catalog_objects.findKey(&key, snap);
            if (self.catalog_objects.findKey(&key, latest) != index) return error.SerializationFailure;
            if (index == null) return null;
            for (&self.catalog_objects.items) |*entry| {
                if (!entry.used or !isLargeObjectChild(entry, oid)) continue;
                if (O.pendingOf(entry, snap)) |other| return self.objectPark(slot, other);
                if (O.visible(entry, latest) != O.visible(entry, snap)) return error.SerializationFailure;
            }
            return index;
        }

        fn ownsLargeObject(self: *const Self, owner: u32, snap: Snapshot) bool {
            return self.privilegedRole(snap) or self.catalog_objects.memberOf(self.session.role, owner, true, snap);
        }

        /// Common statement boundary for PostgreSQL function calls carrying
        /// bytes outside an inline SQL cell. The protocol retains its input
        /// until the call returns and provides the response buffer.
        pub fn largeObjectStatement(self: *Self, slot: u16, request: large_object_command.Request, output: []u8, writes_allowed: bool) Error!large_object_command.Response {
            if (!self.active(slot)) return error.NoActiveTransaction;
            if (self.dialect != .postgres) return error.UnsupportedStatement;
            const tx = &self.txs[slot];
            if (tx.prepared or tx.pin != null or tx.copy_table != null) return error.ObjectNotInPrerequisiteState;
            if (request.writes() and (tx.read_only or !writes_allowed)) return error.ReadOnlyTransaction;
            if (tx.sub_len >= M.sub_capacity) return error.SavepointCapacity;
            tx.cid = std.math.add(u32, tx.cid, 1) catch return error.ProgramLimitExceeded;
            var snap: Snapshot = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid };
            if (tx.snapshot_csn == null) {
                tx.snapshot_csn = self.csn;
                tx.snapshot_cid = tx.cid;
            }
            if (transactionSnapshot(tx.isolation)) snap.csn = tx.snapshot_csn.?;
            tx.subs[tx.sub_len] = .{ .statement = true, .write_start = @intCast(tx.write_len), .lock_start = @intCast(tx.lock_len) };
            tx.sub_len += 1;
            tx.running_snap = snap;
            defer tx.running_snap = null;
            errdefer {
                self.dropStatement(slot);
                self.wake_epoch +%= 1;
            }
            self.statementHooks(slot, snap);
            try self.session.checkpoint();
            try self.serializableSnapshot(slot);
            const result = self.largeObjectRequest(slot, request, output, snap) catch |err| {
                if (err == error.WouldBlock) return error.LockNotAvailable;
                return err;
            };
            tx.sub_len -= 1;
            return result;
        }

        fn largeObjectAt(self: *const Self, oid: u32, snap: Snapshot) Error!*const O.Object {
            const key: O.Object = .{ .kind = .large_object, .target = oid };
            return &self.catalog_objects.items[self.catalog_objects.findKey(&key, snap) orelse return error.UndefinedObject];
        }

        fn readLargeObject(self: *const Self, oid: u32, length: u64, offset: u64, requested: ?usize, output: []u8, snap: Snapshot) Error!usize {
            const remaining = length -| offset;
            const count = if (requested) |limit| @min(remaining, limit) else remaining;
            if (count > output.len) return error.TextCapacity;
            if (count == 0) return 0;
            const pages = if (self.large_pages) |*value| value else return error.UnsupportedStatement;
            return pages.read(oid, length, offset, output[0..@intCast(count)], snap);
        }

        fn largeObjectRequest(self: *Self, slot: u16, request: large_object_command.Request, output: []u8, original_snap: Snapshot) Error!large_object_command.Response {
            const tx = &self.txs[slot];
            const visible = try largeObjectView(original_snap);
            var current = visible;
            current.csn = self.csn;
            switch (request) {
                .create => |oid| return .{ .oid = try largeObjectCall(self, true, oid) },
                .unlink => |oid| return .{ .int4 = @intCast(try largeObjectCall(self, false, oid)) },
                .open => |args| {
                    const write = args.mode & large_object_command.inv_write != 0;
                    if (args.mode & (large_object_command.inv_read | large_object_command.inv_write) == 0) return error.InvalidParameterValue;
                    if (write and tx.read_only) return error.ReadOnlyTransaction;
                    const snap = if (write) current else visible;
                    const object = try self.largeObjectAt(args.oid, snap);
                    const wanted = CO.priv_select | if (write) CO.priv_update else 0;
                    if (self.largeObjectPrivileges(object, self.session.role, snap) & wanted != wanted) return error.InsufficientPrivilege;
                    return .{ .int4 = try tx.large_objects.open(.{
                        .oid = args.oid, .depth = tx.userSavepoints(),
                        .opened_cid = original_snap.cid, .snapshot = if (write) null else snap,
                    }) };
                },
                .close => |fd| {
                    try tx.large_objects.close(fd);
                    return .{ .int4 = 0 };
                },
                .read => |args| {
                    const desc = try tx.large_objects.find(args.fd);
                    if (args.count <= 0) return .{ .bytes = 0 };
                    const snap = desc.snapshot orelse current;
                    const object = try self.largeObjectAt(desc.oid, snap);
                    const count = try self.readLargeObject(desc.oid, object.largeObjectLength(), desc.offset, @intCast(args.count), output, snap);
                    desc.offset += count;
                    return .{ .bytes = count };
                },
                .write => |args| {
                    const desc = try tx.large_objects.find(args.fd);
                    if (desc.snapshot != null) return error.ObjectNotInPrerequisiteState;
                    const count = try args.bytes.length();
                    if (count > 0x7fff_ffff) return error.ProgramLimitExceeded;
                    var mutation_snap = original_snap;
                    mutation_snap.csn = current.csn;
                    try self.stageLargeObjectWrite(slot, desc.oid, desc.offset, args.bytes, count, mutation_snap, false);
                    desc.offset += count;
                    return .{ .int4 = @intCast(count) };
                },
                .seek => |args| {
                    const desc = try tx.large_objects.find(args.fd);
                    const origin: i64 = switch (args.whence) {
                        0 => 0,
                        1 => @intCast(desc.offset),
                        2 => @intCast((try self.largeObjectAt(desc.oid, desc.snapshot orelse current)).largeObjectLength()),
                        else => return error.InvalidParameterValue,
                    };
                    const next = std.math.add(i64, origin, args.offset) catch return error.InvalidParameterValue;
                    if (next < 0 or next > large_object_pages.max_size) return error.InvalidParameterValue;
                    if (!args.wide and next > 0x7fff_ffff) return error.NumericValueOutOfRange;
                    desc.offset = @intCast(next);
                    return if (args.wide) .{ .int8 = next } else .{ .int4 = @intCast(next) };
                },
                .tell => |args| {
                    const offset = (try tx.large_objects.find(args.fd)).offset;
                    if (!args.wide and offset > 0x7fff_ffff) return error.NumericValueOutOfRange;
                    return if (args.wide) .{ .int8 = @intCast(offset) } else .{ .int4 = @intCast(offset) };
                },
                .truncate => |args| return .{ .int4 = try truncateLargeObject(self, args.fd, args.length) },
                .from_bytes => |args| {
                    const count = try args.bytes.length();
                    const oid = try largeObjectCall(self, true, args.oid);
                    try self.stageLargeObjectWrite(slot, oid, 0, args.bytes, count, original_snap, true);
                    return .{ .oid = oid };
                },
                .get => |args| {
                    if (args.offset < 0 or args.offset > large_object_pages.max_size) return error.InvalidParameterValue;
                    if (args.count) |count| if (count < 0) return error.InvalidParameterValue;
                    const object = try self.largeObjectAt(args.oid, visible);
                    if (self.largeObjectPrivileges(object, self.session.role, visible) & CO.priv_select == 0) return error.InsufficientPrivilege;
                    return .{ .bytes = try self.readLargeObject(args.oid, object.largeObjectLength(), @intCast(args.offset),
                        if (args.count) |count| @intCast(count) else null, output, visible) };
                },
                .put => |args| {
                    if (args.offset < 0) return error.InvalidParameterValue;
                    const count = try args.bytes.length();
                    try self.stageLargeObjectWrite(slot, args.oid, @intCast(args.offset), args.bytes, count, original_snap, true);
                    return .empty;
                },
            }
        }

        fn largeObjectView(original_snap: Snapshot) Error!Snapshot {
            var visible = original_snap;
            visible.cid = std.math.add(u32, visible.cid, 1) catch return error.ProgramLimitExceeded;
            return visible;
        }

        fn addLargePageChange(self: *Self, slot: u16, page_change: large_object_pages.Pages.Change) void {
            const missing = large_object_pages.Pages.no_version;
            self.txs[slot].push(.{
                .kind = .large_object_page, .table = 0,
                .old = page_change.previous orelse missing, .new = page_change.replacement orelse missing,
            }) catch unreachable;
        }

        fn largePageMutation(self: *const Self, slot: u16, original_snap: Snapshot, snap: Snapshot) large_object_pages.Mutation {
            return .{
                .snapshot = snap, .command = original_snap.cid,
                .owner = self.txs[slot].ref(slot), .horizon = self.horizon(),
            };
        }

        fn stageLargeObjectWrite(self: *Self, slot: u16, oid: u32, offset: u64, input: large_object_command.Input, input_len: usize, original_snap: Snapshot, check_privileges: bool) Error!void {
            if (self.txs[slot].read_only) return error.ReadOnlyTransaction;
            if (offset > large_object_pages.max_size or input_len > large_object_pages.max_size - offset) return error.InvalidParameterValue;
            const snap = try largeObjectView(original_snap);
            const index = (try self.lockLargeObject(slot, oid, snap)) orelse return error.UndefinedObject;
            var object = self.catalog_objects.items[index];
            if (check_privileges and self.largeObjectPrivileges(&object, self.session.role, snap) != CO.large_object_privileges)
                return error.InsufficientPrivilege;
            if (input_len == 0) return;
            const pages = if (self.large_pages) |*value| value else return error.UnsupportedStatement;
            const size = large_object_pages.page_bytes;
            const end = offset + input_len;
            const previous = object.largeObjectLength();
            const already_locked = object.xmin_csn == 0 and snap.own(object.xmin);
            const replace_metadata = end > previous or !already_locked;
            const touched: usize = @intCast((end - 1) / size - offset / size + 1);
            try self.reserveWrites(slot, touched + if (replace_metadata) @as(usize, 2) else 0);
            if (replace_metadata) {
                try object.setLargeObjectLength(@max(previous, end));
                self.objectDelete(slot, index, original_snap);
                _ = try self.objectInsert(slot, &object, false, original_snap);
            }

            const mutation = self.largePageMutation(slot, original_snap, snap);
            var used: usize = 0;
            var decoded: [size]u8 = undefined;
            while (used < input_len) {
                const position = offset + used;
                const chunk = @min(size - @as(usize, @intCast(position % size)), input_len - used);
                var change: [1]large_object_pages.Pages.Change = undefined;
                _ = try pages.stageWrite(oid, position, input.chunk(used, decoded[0..chunk]), mutation, &change);
                self.addLargePageChange(slot, change[0]);
                used += chunk;
            }
        }

        fn largeObjectDataCall(ptr: *anyopaque, operation: value_module.LargeObjectData, oid: u32, offset: i64, input: []const u8, output: []u8, requested: ?usize) Error!usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const slot = self.seq_slot;
            const original_snap = self.seq_snap;
            if (operation == .create) {
                const object = try largeObjectCall(ptr, true, oid);
                try self.stageLargeObjectWrite(slot, object, 0, .{ .raw = input }, input.len, original_snap, true);
                return object;
            }
            if (offset < 0 or offset > large_object_pages.max_size) return error.InvalidParameterValue;
            const snap = try largeObjectView(original_snap);
            const key: O.Object = .{ .kind = .large_object, .target = oid };
            const index = self.catalog_objects.findKey(&key, snap) orelse return error.UndefinedObject;
            const object = &self.catalog_objects.items[index];
            if (self.largeObjectPrivileges(object, self.session.role, snap) & CO.priv_select == 0) return error.InsufficientPrivilege;
            const at: u64 = @intCast(offset);
            const length = object.largeObjectLength();
            const count = if (requested) |limit| @min(length -| at, limit) else length -| at;
            if (count > output.len) return error.TextCapacity;
            if (count == 0) return 0;
            const pages = if (self.large_pages) |*value| value else return error.UnsupportedStatement;
            return try pages.read(oid, length, at, output[0..@intCast(count)], snap);
        }

        fn truncateLargeObject(ptr: *anyopaque, fd: i32, length: i64) Error!i32 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const slot = self.seq_slot;
            const tx = &self.txs[slot];
            if (tx.read_only) return error.ReadOnlyTransaction;
            const descriptor = tx.large_objects.find(fd) catch return error.UndefinedObject;
            if (descriptor.snapshot != null) return error.ObjectNotInPrerequisiteState;
            if (length < 0 or length > large_object_pages.max_size) return error.InvalidParameterValue;

            var original_snap = self.seq_snap;
            original_snap.csn = self.csn;
            const snap = try largeObjectView(original_snap);
            const oid = descriptor.oid;
            const index = (try self.lockLargeObject(slot, oid, snap)) orelse return error.UndefinedObject;
            const pages = if (self.large_pages) |*value| value else return error.UnsupportedStatement;
            var object = self.catalog_objects.items[index];
            const previous = object.largeObjectLength();
            const end: u64 = @intCast(length);
            const size = large_object_pages.page_bytes;
            const key: large_object_pages.Key = .{ .oid = oid, .page = @intCast(end / size) };
            const tail: usize = @intCast(end % size);
            const before = pages.page(key, snap);
            if (previous == end and before != null and before.?.len == tail) return 0;

            // Authoritative EOF lives in the catalog. Match pg_largeobject's
            // physical end marker as well, including at exact page boundaries.
            try self.reserveWrites(slot, 3);
            try object.setLargeObjectLength(end);
            self.objectDelete(slot, index, original_snap);
            _ = try self.objectInsert(slot, &object, false, original_snap);

            var page: [size]u8 = undefined;
            const prefix = if (before) |bytes| @min(bytes.len, tail) else 0;
            if (prefix != 0) @memcpy(page[0..prefix], before.?[0..prefix]);
            @memset(page[prefix..tail], 0);
            const mutation = self.largePageMutation(slot, original_snap, snap);
            self.addLargePageChange(slot, (try pages.stagePage(key, page[0..tail], mutation)).?);
            if (end < previous) try self.removeLargeObjectPages(slot, oid, key.page, original_snap, snap);
            return 0;
        }

        fn removeLargeObjectPages(self: *Self, slot: u16, oid: u32, keep_through: ?u32, original_snap: Snapshot, snap: Snapshot) Error!void {
            const pages = if (self.large_pages) |*value| value else return;
            const mutation = self.largePageMutation(slot, original_snap, snap);
            var cursor: large_object_pages.Pages.Cursor = .{};
            while (cursor.next(pages, snap)) |page| {
                if (page.key.oid != oid or (keep_through != null and page.key.page <= keep_through.?)) continue;
                try self.reserveWrites(slot, 1);
                if (try pages.stagePage(page.key, null, mutation)) |change| self.addLargePageChange(slot, change);
            }
        }

        fn largeObjectCall(ptr: *anyopaque, create: bool, oid: u32) Error!u32 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const slot = self.seq_slot;
            const original_snap = self.seq_snap;
            if (self.txs[slot].read_only) return error.ReadOnlyTransaction;
            // VOLATILE calls see writes from earlier calls in the same statement.
            const snap = try largeObjectView(original_snap);
            if (create) {
                const role = self.session.role;
                const owner_key: O.Object = .{ .kind = .role, .oid = role };
                if (self.catalog_objects.pendingConflict(&owner_key, snap)) |other| return self.objectPark(slot, other);
                var latest = snap;
                latest.csn = self.csn;
                if (self.catalog_objects.roleFlags(role, latest) == null) return error.UndefinedObject;
                var object_oid = oid;
                if (object_oid == 0) {
                    while (true) {
                        object_oid = try self.takeOid();
                        const key: O.Object = .{ .kind = .large_object, .target = object_oid };
                        if (self.catalog_objects.findKey(&key, latest) == null and
                            self.catalog_objects.pendingConflict(&key, snap) == null) break;
                    }
                } else if (try self.lockLargeObject(slot, oid, snap) != null) return error.PrimaryKeyViolation;
                try self.reserveWrites(slot, 1);
                var item: O.Object = .{
                    .kind = .large_object,
                    .target = object_oid,
                    .owner = role,
                    .grant_flags = if (oid == 0) CO.large_object_generated_oid else 0,
                };
                _ = try self.objectInsert(slot, &item, false, original_snap);
                return object_oid;
            }

            const index = (try self.lockLargeObject(slot, oid, snap)) orelse return error.UndefinedObject;
            if (!self.ownsLargeObject(self.catalog_objects.items[index].owner, snap)) return error.InsufficientPrivilege;
            var writes: usize = 1;
            for (&self.catalog_objects.items) |*entry| {
                if (O.visible(entry, snap) and isLargeObjectChild(entry, oid)) writes += 1;
            }
            if (self.large_pages) |*pages| {
                if (self.catalog_objects.items[index].largeObjectLength() != 0 or pages.page(.{ .oid = oid, .page = 0 }, snap) != null)
                    try self.removeLargeObjectPages(slot, oid, null, original_snap, snap);
            }
            try self.reserveWrites(slot, writes);
            for (&self.catalog_objects.items, 0..) |*entry, child| {
                if (O.visible(entry, snap) and isLargeObjectChild(entry, oid)) self.objectDelete(slot, child, original_snap);
            }
            self.objectDelete(slot, index, original_snap);
            if (self.txs[slot].large_objects.used) self.txs[slot].large_objects.unlink(oid);
            return 1;
        }

        /// The first explicit GRANT or REVOKE starts with the native owner ACL.
        fn largeObjectOwnerPrivileges(object: *const O.Object) u32 {
            return if (object.flags & CO.large_object_explicit_acl == 0) CO.large_object_privileges
                else object.flags & CO.large_object_privileges;
        }

        fn largeObjectPrivileges(self: *const Self, object: *const O.Object, role: u32, snap: Snapshot) u32 {
            if (self.catalog_objects.superuser(role, snap)) return CO.large_object_privileges;
            var privileges: u32 = 0;
            if (self.catalog_objects.memberOf(role, object.owner, true, snap)) privileges = largeObjectOwnerPrivileges(object);
            for (&self.catalog_objects.items) |*entry| {
                if (entry.kind != .large_object_acl or entry.target != object.target or !O.visible(entry, snap)) continue;
                if (entry.grantee == CO.public_role or self.catalog_objects.memberOf(role, entry.grantee, true, snap))
                    privileges |= entry.flags;
            }
            return privileges;
        }

        const LoAcl = @import("sql/large_object_acl.sig");

        fn largeObjectGrantGraph(self: *const Self, object: *const O.Object, snap: Snapshot, edges: []LoAcl.Edge) LoAcl.Graph {
            var graph: LoAcl.Graph = .{ .edges = edges, .owner = object.owner, .privileges = CO.large_object_privileges };
            for (&self.catalog_objects.items, 0..) |*entry, index| {
                if (entry.kind != .large_object_acl or entry.target != object.target or !O.visible(entry, snap)) continue;
                graph.add(.{
                    .grantor = entry.owner, .grantee = entry.grantee, .flags = entry.flags,
                    .options = entry.grant_flags, .original = index,
                });
            }
            return graph;
        }

        /// PostgreSQL selects one grantor for all privileges in a command.
        /// Prefer the owner, then the closest eligible role with the most options.
        fn largeObjectGrantor(self: *const Self, graph: LoAcl.Graph, wanted: u32, snap: Snapshot) struct { role: u32, options: u32 } {
            if (self.ownsLargeObject(graph.owner, snap)) return .{ .role = graph.owner, .options = wanted };
            var roles: [O.capacity + 1]u32 = undefined;
            roles[0] = self.session.role;
            var length: usize = 1;
            var next: usize = 0;
            var best_role = roles[0];
            var best_options: u32 = 0;
            while (next < length) : (next += 1) {
                const role = roles[next];
                var options: u32 = 0;
                for (graph.edges[0..graph.len]) |edge| {
                    if (edge.grantee == role) options |= edge.options & wanted;
                }
                if (options == wanted) return .{ .role = role, .options = options };
                if (@popCount(options) > @popCount(best_options)) {
                    best_options = options;
                    best_role = role;
                }
                for (&self.catalog_objects.items) |*entry| {
                    if (entry.kind != .member or entry.grantee != role or !O.visible(entry, snap) or
                        !self.catalog_objects.membershipInherits(entry, snap)) continue;
                    if (std.mem.indexOfScalar(u32, roles[0..length], entry.target) == null) {
                        roles[length] = entry.target;
                        length += 1;
                    }
                }
            }
            return .{ .role = best_role, .options = best_options };
        }

        fn largeObjectGrantorKey(object_owner: u32, grantor: u32) i32 {
            return if (object_owner == grantor) 0 else @bitCast(grantor);
        }

        fn largeObjectGrantChanged(self: *const Self, graph: LoAcl.Graph, edge: LoAcl.Edge) bool {
            const original = &self.catalog_objects.items[edge.original orelse return edge.flags != 0];
            return original.flags != edge.flags or original.grant_flags != edge.options or
                original.grantee != edge.grantee or original.owner != edge.grantor or
                original.sub != largeObjectGrantorKey(graph.owner, edge.grantor);
        }

        fn storeLargeObjectGrants(self: *Self, slot: u16, index: usize, object: *O.Object, graph: LoAcl.Graph, snap: Snapshot) Error!void {
            const original = &self.catalog_objects.items[index];
            const metadata_changed = object.owner != original.owner or object.flags != original.flags or object.grant_flags != original.grant_flags;
            var writes: usize = if (metadata_changed) 2 else 0;
            for (graph.edges[0..graph.len]) |edge| {
                if (self.largeObjectGrantChanged(graph, edge)) writes += @as(usize, @intFromBool(edge.original != null)) + @intFromBool(edge.flags != 0);
            }
            try self.reserveWrites(slot, writes);
            // Remove all replaced keys before inserting new ones. Ownership
            // transfer can merge two grants or move a grant to a former key.
            for (graph.edges[0..graph.len]) |edge| {
                if (self.largeObjectGrantChanged(graph, edge)) {
                    if (edge.original) |old| self.objectDelete(slot, old, snap);
                }
            }
            if (metadata_changed) {
                self.objectDelete(slot, index, snap);
                _ = try self.objectInsert(slot, object, false, snap);
            }
            for (graph.edges[0..graph.len]) |edge| {
                if (edge.flags == 0 or !self.largeObjectGrantChanged(graph, edge)) continue;
                var row: O.Object = .{
                    .kind = .large_object_acl, .target = object.target, .grantee = edge.grantee, .owner = edge.grantor,
                    .sub = largeObjectGrantorKey(graph.owner, edge.grantor), .flags = edge.flags, .grant_flags = edge.options,
                };
                _ = try self.objectInsert(slot, &row, false, snap);
            }
        }

        fn largeObjectGrantWarning(self: *Self, revoke: bool, partial: bool) void {
            const provider = self.settings_provider orelse return;
            const warn = provider.warn orelse return;
            warn(provider.context, if (revoke) "01006" else "01007",
                if (revoke)
                    (if (partial) "not all privileges could be revoked" else "no privileges could be revoked")
                else
                    (if (partial) "not all privileges were granted" else "no privileges were granted"));
        }

        fn grantLargeObjects(self: *Self, slot: u16, source: []const u8, grant: *const CO.Grant, revoke: bool, snap: Snapshot) Error!void {
            if (grant.grantor) |specified| {
                if (try self.objectRole(source, specified, snap) != self.session.role) return error.UnsupportedStatement;
            }
            var grantees: [CO.list_capacity]u32 = undefined;
            var count: usize = 0;
            var latest = snap;
            latest.csn = self.csn;
            for (grant.grantees[0..grant.grantee_count]) |grantee| {
                const role = try self.objectRole(source, grantee, snap);
                if (std.mem.indexOfScalar(u32, grantees[0..count], role) != null) continue;
                if (role == CO.public_role and !revoke and grant.option) return error.InvalidGrantOperation;
                if (role != CO.public_role) {
                    const key: O.Object = .{ .kind = .role, .oid = role };
                    if (self.catalog_objects.pendingConflict(&key, snap)) |other| return self.objectPark(slot, other);
                    if (self.catalog_objects.roleFlags(role, latest) == null) return error.SerializationFailure;
                }
                grantees[count] = role;
                count += 1;
            }
            for (grant.large_objects[0..grant.large_object_count], 0..) |oid, position| {
                if (std.mem.indexOfScalar(u32, grant.large_objects[0..position], oid) != null) continue;
                const index = (try self.lockLargeObject(slot, oid, snap)) orelse return error.UndefinedObject;
                var object = self.catalog_objects.items[index];
                var edges: [O.capacity + CO.list_capacity]LoAcl.Edge = undefined;
                var support: [edges.len]LoAcl.Graph.State = undefined;
                var graph = self.largeObjectGrantGraph(&object, snap, &edges);
                const issuer = self.largeObjectGrantor(graph, grant.privileges, snap);
                if (issuer.options == 0) {
                    if (self.largeObjectPrivileges(&object, self.session.role, snap) == 0) return error.InsufficientPrivilege;
                    self.largeObjectGrantWarning(revoke, false);
                    continue;
                }
                if (issuer.options != grant.privileges and !grant.all_privileges) self.largeObjectGrantWarning(revoke, true);
                var owner_flags = largeObjectOwnerPrivileges(&object);
                for (grantees[0..count]) |role| {
                    if (role == object.owner and issuer.role == role) {
                        if (!revoke) owner_flags |= issuer.options else if (!grant.option) owner_flags &= ~issuer.options;
                        if (revoke) object.grant_flags &= ~issuer.options else if (grant.option) object.grant_flags |= issuer.options;
                        continue;
                    }
                    const existing = graph.find(issuer.role, role);
                    if (!revoke and grant.option and issuer.role != object.owner and role != object.owner) {
                        const new_options = issuer.options & ~(if (existing) |old| graph.edges[old].options else @as(u32, 0));
                        if (new_options != 0) {
                            graph.support(&support, role);
                            if (graph.supportedOptions(issuer.role, &support) & new_options != new_options) return error.InvalidGrantOperation;
                        }
                    }
                    const item = existing orelse blk: {
                        if (revoke) continue;
                        graph.add(.{ .grantor = issuer.role, .grantee = role, .flags = 0, .options = 0 });
                        break :blk graph.len - 1;
                    };
                    const edge = &graph.edges[item];
                    if (revoke) {
                        edge.options &= ~issuer.options;
                        if (!grant.option) edge.flags &= ~issuer.options;
                    } else {
                        edge.flags |= issuer.options;
                        if (grant.option) edge.options |= issuer.options;
                    }
                }
                if (revoke) {
                    graph.support(&support, null);
                    for (graph.edges[0..graph.len], support[0..graph.len]) |*edge, state| {
                        if (edge.flags & ~state.available == 0) continue;
                        if (!grant.cascade) return error.DependentObjects;
                        edge.flags &= state.available;
                        edge.options &= state.available;
                    }
                }
                object.flags = CO.large_object_explicit_acl | owner_flags;
                try self.storeLargeObjectGrants(slot, index, &object, graph, snap);
            }
        }

        fn alterLargeObjectOwner(self: *Self, slot: u16, source: []const u8, oid: u32, grantee: CO.Grantee, snap: Snapshot) Error!void {
            const index = (try self.lockLargeObject(slot, oid, snap)) orelse return error.UndefinedObject;
            var object = self.catalog_objects.items[index];
            const old_owner = object.owner;
            if (!self.ownsLargeObject(old_owner, snap)) return error.InsufficientPrivilege;
            const owner = try self.objectRole(source, grantee, snap);
            if (owner == old_owner) return;
            if (!self.privilegedRole(snap) and !self.catalog_objects.membershipPath(self.session.role, owner, .set, snap)) return error.InsufficientPrivilege;
            const role_key: O.Object = .{ .kind = .role, .oid = owner };
            if (self.catalog_objects.pendingConflict(&role_key, snap)) |other| return self.objectPark(slot, other);
            var latest = snap;
            latest.csn = self.csn;
            if (self.catalog_objects.roleFlags(owner, latest) == null) return error.SerializationFailure;

            var edges: [O.capacity]LoAcl.Edge = undefined;
            var graph = self.largeObjectGrantGraph(&object, snap, &edges);
            const merged_acl = graph.changeOwner(owner);
            object.flags |= merged_acl.flags;
            object.grant_flags |= merged_acl.options;
            object.owner = owner;
            try self.storeLargeObjectGrants(slot, index, &object, graph, snap);
        }

        fn catalogObject(self: *Self, slot: u16, source: []const u8, object_statement: *const CO.Statement, snap: Snapshot) Error!void {
            const command: CommandTag = switch (object_statement.*) {
                .create_domain => |*domain| blk: {
                    var object: O.Object = .{ .kind = .domain, .domain = domain.spec };
                    try self.createUserType(slot, source, domain.name, &object, .none, snap);
                    break :blk .create_domain;
                },
                .drop_domain => |*drop| blk: {
                    try self.dropTypes(slot, source, drop, true, snap);
                    break :blk .drop_domain;
                },
                .create_enum => |*enumeration| blk: {
                    var object: O.Object = .{ .kind = .enum_type };
                    try self.createUserType(slot, source, enumeration.name, &object, .{ .enum_labels = enumeration.labels }, snap);
                    break :blk .create_type;
                },
                .create_composite => |*definition| blk: {
                    var object: O.Object = .{ .kind = .composite_type };
                    try self.createUserType(slot, source, definition.name, &object, .{ .composite_fields = definition.fields }, snap);
                    break :blk .create_type;
                },
                .drop_type => |*drop| blk: {
                    try self.dropTypes(slot, source, drop, false, snap);
                    break :blk .drop_type;
                },
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
                    if (grant.membership) {
                        try self.grantMembership(slot, source, grant, false, snap);
                    } else if (grant.schema) {
                        try self.grantSchemaUsage(slot, source, grant, false, snap);
                    } else if (grant.large_object_count != 0) {
                        try self.grantLargeObjects(slot, source, grant, false, snap);
                    } else try self.grantTables(slot, source, grant, false, snap);
                    break :blk if (grant.membership) .grant_role else .grant;
                },
                .revoke => |*grant| blk: {
                    if (grant.membership) {
                        try self.grantMembership(slot, source, grant, true, snap);
                    } else if (grant.schema) {
                        try self.grantSchemaUsage(slot, source, grant, true, snap);
                    } else if (grant.large_object_count != 0) {
                        try self.grantLargeObjects(slot, source, grant, true, snap);
                    } else try self.grantTables(slot, source, grant, true, snap);
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
                .alter_schema_owner => |change| blk: {
                    try self.alterSchemaOwner(slot, source, change.name, change.owner, snap);
                    break :blk .alter_schema;
                },
                .alter_large_object_owner => |change| blk: {
                    try self.alterLargeObjectOwner(slot, source, change.oid, change.owner, snap);
                    break :blk .alter_large_object;
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
                .create_statistics => |*spec| blk: {
                    try self.createStatistics(slot, source, spec, snap);
                    break :blk .create_statistics;
                },
                .alter_statistics => |*spec| blk: {
                    if (try self.findStatistics(slot, source, spec.name, spec.if_exists, snap)) |index| {
                        var next = self.catalog_objects.items[index];
                        next.sub = spec.target;
                        try self.reserveWrites(slot, 2);
                        self.objectDelete(slot, index, snap);
                        _ = try self.objectInsert(slot, &next, false, snap);
                    }
                    break :blk .alter_statistics;
                },
                .drop_statistics => |*spec| blk: {
                    for (spec.names[0..spec.count]) |name| {
                        const index = (try self.findStatistics(slot, source, name, spec.if_exists, snap)) orelse continue;
                        if (self.catalog_objects.items[index].xmax.epoch != 0) continue;
                        try self.reserveWrites(slot, 1);
                        self.objectDelete(slot, index, snap);
                    }
                    break :blk .drop_statistics;
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

        fn typeNamespace(self: *const Self, source: []const u8, name: CO.Qualified, snap: Snapshot) Error!u32 {
            if (!name.has_schema and !self.session.public_schema_on_path) return error.UndefinedSchema;
            const schema = if (name.has_schema) objectName(source, name.schema) else Name{};
            return (try self.namespaceForUsage(self.session.role, if (name.has_schema) schema.slice() else null, snap)) orelse error.UndefinedSchema;
        }

        fn typeNameOccupied(self: *const Self, namespace: u32, name: []const u8, snap: Snapshot) bool {
            if (self.catalog_objects.userTypeNameTaken(namespace, name, snap)) return true;
            const relation = self.catalog.findIn(namespace, name, snap) orelse return false;
            return relation.kind != 'S';
        }

        fn pendingTypeName(self: *const Self, namespace: u32, name: []const u8, snap: Snapshot) ?u16 {
            return self.catalog.creator(name, snap) orelse self.catalog_objects.pendingUserTypeName(namespace, name, snap);
        }

        fn checkRelationTypeName(self: *Self, slot: u16, namespace: u32, name: []const u8, snap: Snapshot) Error!void {
            if (self.catalog_objects.pendingUserTypeName(namespace, name, snap)) |other| return self.objectPark(slot, other);
            var latest = snap;
            latest.csn = self.csn;
            if (self.catalog_objects.userTypeNameTaken(namespace, name, latest)) return error.DuplicateObject;
        }

        const UserTypePayload = union(enum) { none, enum_labels: CO.Span, composite_fields: CO.Span };

        fn createUserType(self: *Self, slot: u16, source: []const u8, qualified: CO.Qualified, object: *O.Object, payload: UserTypePayload, snap: Snapshot) Error!void {
            if (self.dialect != .postgres or self.routine_frame != null) return error.UnsupportedStatement;
            if (!self.privilegedRole(snap)) return error.InsufficientPrivilege;
            const namespace = try self.typeNamespace(source, qualified, snap);
            if (namespace != catalog_module.public_namespace and namespace < change_log.first_oid) return error.InsufficientPrivilege;
            for (&self.schemas) |*schema| {
                if (schema.live and schema.oid == namespace and schema.pending_drop and schema.creator != slot) return self.objectPark(slot, schema.creator);
            }
            const owner = self.session.role;
            if (self.catalog_objects.pendingReference(owner, snap)) |other| return self.objectPark(slot, other);
            var latest = snap;
            latest.csn = self.csn;
            if (try self.typeNamespace(source, qualified, latest) != namespace) return error.SerializationFailure;
            if (owner != CO.bootstrap_role and self.catalog_objects.byOid(.role, owner, latest) == null) return error.SerializationFailure;
            const name = objectName(source, qualified.name);
            if (name.len == 0) return error.Syntax;
            if (name.len > config.text_bytes) return error.NameCapacity;
            if (self.pendingTypeName(namespace, name.slice(), snap)) |other| return self.objectPark(slot, other);
            if (self.typeNameOccupied(namespace, name.slice(), latest)) return error.DuplicateObject;
            if (object.kind == .composite_type and self.catalog.findIn(namespace, name.slice(), latest) != null) return error.TableExists;
            object.target = namespace;
            object.owner = owner;
            object.name = name;
            const limit: usize = @min(config.name_bytes, config.text_bytes, O.text_capacity);
            var found = false;
            var prefix: usize = 1;
            while (prefix <= limit) : (prefix += 1) {
                var length = @min(@as(usize, name.len), limit - prefix);
                // A generated array identifier must not split a UTF-8
                // sequence when making room for an underscore prefix.
                while (length > 0 and length < name.len and name.bytes[length] & 0xc0 == 0x80) length -= 1;
                @memset(object.text[0..prefix], '_');
                @memcpy(object.text[prefix..][0..length], name.slice()[0..length]);
                object.text_len = @intCast(prefix + length);
                const candidate = object.textSlice();
                if (types.same(name.slice(), candidate)) continue;
                if (self.pendingTypeName(namespace, candidate, snap)) |other| return self.objectPark(slot, other);
                if (self.typeNameOccupied(namespace, candidate, latest)) continue;
                found = true;
                break;
            }
            if (!found) return error.NameCapacity;
            switch (payload) {
                .none => {},
                .enum_labels => |label_span| {
                    object.split = object.text_len;
                    const labels_source = source[label_span.start..][0..label_span.len];
                    const encoded = try CO.encodeEnumLabels(labels_source, object.text[object.split..], @min(config.name_bytes, config.text_bytes));
                    object.enum_label_count = encoded.count;
                    object.text_len = @intCast(@as(usize, object.split) + encoded.bytes);
                },
                .composite_fields => |field_span| {
                    object.split = object.text_len;
                    try self.encodeCompositeFields(source[field_span.start..][0..field_span.len], object);
                },
            }
            try self.reserveWrites(slot, 1);
            const width = object.oidWidth();
            if (self.oid_counter > 0xffffffff - change_log.first_oid - width) return error.TableCapacity;
            object.oid = change_log.first_oid + self.oid_counter;
            _ = try self.objectInsert(slot, object, false, snap);
            self.oid_counter += width;
        }

        fn encodeCompositeFields(self: *Self, source: []const u8, object: *O.Object) Error!void {
            var next: ?usize = 0;
            var used: usize = 0;
            while (next) |position| {
                const field = (try P.parseCompositeFieldAt(source, position, &self.workspace.nodes)) orelse break;
                if (object.composite_field_count == config.columns) return error.ColumnCapacity;
                const name = identName(source, field.name);
                if (name.len > config.text_bytes) return error.NameCapacity;
                const data_type = types.dataTypeOf(field.spec.ty);
                if (!types.validTypeTypmod(config, data_type, field.spec.typmod)) return error.UnsupportedStatement;
                try CO.appendCompositeField(object.text[object.split..], &used, .{ .name = name.slice(), .oid = types.typeOid(data_type), .typmod = field.spec.typmod });
                object.composite_field_count += 1;
                next = field.next;
            }
            object.text_len = @intCast(@as(usize, object.split) + used);
        }

        fn dropTypes(self: *Self, slot: u16, source: []const u8, drop: *const CO.DropTypes, domain_only: bool, snap: Snapshot) Error!void {
            if (self.dialect != .postgres or self.routine_frame != null) return error.UnsupportedStatement;
            var found: [CO.list_capacity]usize = undefined;
            var count: usize = 0;
            for (drop.names[0..drop.count]) |name| {
                const namespace = self.typeNamespace(source, name, snap) catch |err| {
                    if (err == error.UndefinedSchema and drop.if_exists) continue;
                    return err;
                };
                const wanted = objectName(source, name.name);
                if (self.catalog_objects.pendingUserTypeName(namespace, wanted.slice(), snap)) |other| return self.objectPark(slot, other);
                const index = self.catalog_objects.byName(.domain, namespace, wanted.slice(), snap) orelse
                    self.catalog_objects.byName(.enum_type, namespace, wanted.slice(), snap) orelse
                    self.catalog_objects.byName(.composite_type, namespace, wanted.slice(), snap) orelse {
                    if (self.catalog_objects.userTypeNameTaken(namespace, wanted.slice(), snap)) return error.UnsupportedStatement;
                    if (drop.if_exists) continue;
                    return error.UndefinedObject;
                };
                const object = &self.catalog_objects.items[index];
                if (domain_only and object.kind != .domain) return error.WrongObjectType;
                if (object.xmax_csn > snap.csn) return error.SerializationFailure;
                if (!self.privilegedRole(snap) and !self.catalog_objects.memberOf(self.session.role, object.owner, true, snap)) return error.InsufficientPrivilege;
                for (found[0..count]) |previous| {
                    if (previous == index) break;
                } else {
                    found[count] = index;
                    count += 1;
                }
            }
            try self.reserveWrites(slot, count);
            for (found[0..count]) |index| self.objectDelete(slot, index, snap);
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
                var member: O.Object = .{ .kind = .member, .target = group, .grantee = oid, .flags = CO.membershipFlags(flags & CO.role_inherit != 0, true), .owner = if (superuser) CO.bootstrap_role else self.session.role };
                _ = try self.objectInsert(slot, &member, true, snap);
            }
        }

        fn alterRole(self: *Self, slot: u16, source: []const u8, spec: *const CO.RoleSpec, snap: Snapshot) Error!void {
            const oid = self.catalog_objects.roleByName(objectName(source, spec.name).slice(), snap) orelse return error.UndefinedObject;
            if (spec.defaults) |defaults| return self.alterRoleDefaults(slot, source, oid, defaults, snap);
            if (oid == CO.bootstrap_role) {
                // A stock archive restates the built-in role's attributes.
                if (!self.privilegedRole(snap)) return error.InsufficientPrivilege;
                if (spec.rename or spec.clear != 0 or (spec.connlimit_set and spec.connlimit != -1)) return error.UnsupportedStatement;
                return;
            }
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

        fn alterRoleDefaults(self: *Self, slot: u16, source: []const u8, role: u32, change: CO.RoleDefaults, snap: Snapshot) Error!void {
            if (!self.privilegedRole(snap) and role != self.session.role and
                (self.catalog_objects.superuser(role, snap) or self.actorFlags(snap) & CO.role_createrole == 0 or
                    !self.roleAdmin(self.session.role, role, snap))) return error.InsufficientPrivilege;
            var latest = snap;
            latest.csn = self.csn;
            if (role != CO.bootstrap_role) {
                const role_key: O.Object = .{ .kind = .role, .oid = role };
                if (self.catalog_objects.pendingConflict(&role_key, snap)) |other| return self.objectPark(slot, other);
                if (self.catalog_objects.byOid(.role, role, latest) == null) return error.SerializationFailure;
            }
            var next: O.Object = .{ .kind = .role_settings, .target = role };
            if (self.catalog_objects.pendingConflict(&next, snap)) |other| return self.objectPark(slot, other);
            const existing = self.catalog_objects.findKey(&next, snap);
            if (self.catalog_objects.findKey(&next, latest) != existing) return error.SerializationFailure;
            if (existing) |index| {
                next.flags = self.catalog_objects.items[index].flags;
                next.grant_flags = self.catalog_objects.items[index].grant_flags;
            }
            switch (change) {
                .reset_all => next.flags = 0,
                .reset => |setting| next.flags &= ~setting.bit(),
                .from_current => |setting| storeRoleBoolean(&next, setting, roleBoolean(&self.sessionState().values, setting).*),
                .set => |entry| {
                    var buffer: [16]u8 = undefined;
                    const spelling = if (entry.quoted) |quoted| blk: {
                        if (quoted.len > buffer.len) return error.InvalidSettingValue;
                        lexer.decodeQuoted(source, quoted, buffer[0..quoted.len]);
                        break :blk buffer[0..quoted.len];
                    } else source[entry.spelling.start..][0..entry.spelling.len];
                    storeRoleBoolean(&next, entry.setting, parseBool(spelling) orelse return error.InvalidSettingValue);
                },
            }
            next.grant_flags &= next.flags;
            if (existing) |index| {
                const current = &self.catalog_objects.items[index];
                if (current.flags == next.flags and current.grant_flags == next.grant_flags) return;
            }
            const writes = @as(usize, @intFromBool(existing != null)) + @as(usize, @intFromBool(next.flags != 0));
            if (writes == 0) return;
            try self.reserveWrites(slot, writes);
            if (existing) |index| self.objectDelete(slot, index, snap);
            if (next.flags != 0) _ = try self.objectInsert(slot, &next, false, snap);
        }

        fn storeRoleBoolean(entry: *O.Object, setting: CO.RoleBoolean, enabled: bool) void {
            const bit = setting.bit();
            entry.flags |= bit;
            if (enabled) entry.grant_flags |= bit else entry.grant_flags &= ~bit;
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
                var latest = snap;
                latest.csn = self.csn;
                for (&self.objects.routines) |*routine| {
                    if (!routine.live) continue;
                    if (routine.owner != oid and std.mem.indexOfScalar(u32, routine.acl.roles(), oid) == null) continue;
                    if (routine.stamp.creatorOther(snap) orelse routine.stamp.deleterOther(snap)) |other| return self.objectPark(slot, other);
                    if (routine.stamp.visible(snap) != routine.stamp.visible(latest)) return error.SerializationFailure;
                    if (routine.stamp.visible(snap)) return error.DependentObjects;
                }
                for (&self.schemas) |*schema| {
                    if (!schema.live) continue;
                    const owned_then = self.schemaOwner(schema, snap) == oid;
                    const owned_latest = self.schemaOwner(schema, latest) == oid;
                    if (!owned_then and !owned_latest) continue;
                    if ((schema.pending_create or schema.pending_drop) and schema.creator != slot) return self.objectPark(slot, schema.creator);
                    const old = self.catalog.findSchema(schema.name.slice(), snap);
                    const now = self.catalog.findSchema(schema.name.slice(), latest);
                    const owned_before = owned_then and old != null and old.?.oid == schema.oid;
                    const owned_now = owned_latest and now != null and now.?.oid == schema.oid;
                    if (owned_before != owned_now) return error.SerializationFailure;
                    if (owned_before) return error.DependentObjects;
                }
                for (&self.catalog_objects.items) |*o| {
                    const affected = (CO.userType(o.kind) or o.kind == .statistics or o.kind == .relation or o.kind == .large_object) and o.owner == oid or
                        (o.kind == .schema_acl or o.kind == .large_object_acl) and (o.owner == oid or o.grantee == oid) or
                        o.kind == .role_settings and o.target == oid;
                    if (affected and O.visible(o, latest) != O.visible(o, snap)) return error.SerializationFailure;
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
                        .role_settings => if (o.target == oid) { writes += 1; },
                        .acl, .schema_acl, .large_object_acl => if (o.grantee == oid or o.owner == oid) return error.DependentObjects,
                        .policy => {
                            for (o.roleList()) |listed| {
                                if (listed == oid) return error.DependentObjects;
                            }
                        },
                        .relation, .fdw, .server, .publication, .domain, .enum_type, .composite_type, .statistics, .large_object => if (o.owner == oid) return error.DependentObjects,
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
                        .role_settings => o.target == oid,
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
            const owner = if (superuser) CO.bootstrap_role else actor;
            if (grant.grantor) |grantor| {
                if (try self.objectRole(source, grantor, snap) != owner) return error.UnsupportedStatement;
            }
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
                    if (grant.grantor != null) {
                        if (self.catalog_objects.findKey(&key, snap)) |index| {
                            if (self.catalog_objects.items[index].owner != owner) return error.UnsupportedStatement;
                        }
                    }
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
                    var next = self.catalog_objects.items[index];
                    if (grant.admin) |admin| next.grant_flags = if (admin) CO.member_admin else 0;
                    if (grant.inherit != null or grant.set != null) {
                        next.flags = CO.membershipFlags(grant.inherit orelse self.catalog_objects.membershipInherits(&next, snap),
                            grant.set orelse O.membershipCanSet(&next));
                    }
                    const current = &self.catalog_objects.items[index];
                    if (next.grant_flags == current.grant_flags and next.flags == current.flags) continue;
                    self.objectDelete(slot, index, snap);
                    _ = try self.objectInsert(slot, &next, false, snap);
                    continue;
                }
                const inherits = (self.catalog_objects.roleFlags(member, snap) orelse 0) & CO.role_inherit != 0;
                var member_object: O.Object = .{ .kind = .member, .target = group, .grantee = member,
                    .flags = CO.membershipFlags(grant.inherit orelse inherits, grant.set orelse true),
                    .grant_flags = if (grant.admin orelse false) CO.member_admin else 0, .owner = owner };
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

        /// Schema grants use the owning role as grantor. This scope has no
        /// delegated grant chain, CREATE privilege, or built-in schema ACL.
        fn grantSchemaUsage(self: *Self, slot: u16, source: []const u8, grant: *const CO.Grant, revoke: bool, snap: Snapshot) Error!void {
            if (self.dialect != .postgres or grant.option or grant.cascade or grant.table_count != 1) return error.UnsupportedStatement;
            const schema_target = grant.tables[0];
            if (schema_target.has_schema) return error.Syntax;
            const name = objectName(source, schema_target.name);
            if (namespaceFor(&self.catalog, name.slice(), snap)) |oid| {
                if (oid < change_log.first_oid) return error.UnsupportedStatement;
            }
            const visible = self.catalog.findSchema(name.slice(), snap) orelse return error.UndefinedSchema;
            const schema = &self.schemas[visible.slot];
            if (!schema.private_usage) return error.UnsupportedStatement;
            if (schema.pending_drop and schema.creator != slot) return self.objectPark(slot, schema.creator);
            if (self.catalog_objects.pendingReference(schema.oid, snap)) |other| return self.objectPark(slot, other);

            var latest = snap;
            latest.csn = self.csn;
            const current_schema = self.catalog.findSchema(name.slice(), latest) orelse return error.SerializationFailure;
            if (visible.oid != current_schema.oid) return error.SerializationFailure;
            if (!self.ownsNamespace(schema.oid, latest)) return error.InsufficientPrivilege;

            var grantees: [CO.list_capacity]u32 = undefined;
            var count: usize = 0;
            for (grant.grantees[0..grant.grantee_count]) |grantee| {
                const role = try self.objectRole(source, grantee, latest);
                if (role != CO.public_role) {
                    if (self.catalog_objects.pendingReference(role, snap)) |other| return self.objectPark(slot, other);
                    if (self.catalog_objects.roleName(role, latest) == null) return error.UndefinedObject;
                }
                var duplicate = false;
                for (grantees[0..count]) |prior| duplicate = duplicate or prior == role;
                if (duplicate) continue;
                grantees[count] = role;
                count += 1;
            }
            // The first authorized GRANT or REVOKE materializes the ACL,
            // even if its effective privileges are exactly the default.
            const owner = self.schemaOwner(schema, latest);
            var state: O.Object = .{ .kind = .schema_acl_state, .target = schema.oid, .owner = owner };
            const first_acl = self.catalog_objects.findKey(&state, latest) == null;
            try self.reserveWrites(slot, 2 * count + @intFromBool(first_acl));
            if (first_acl) _ = try self.objectInsert(slot, &state, false, snap);
            for (grantees[0..count]) |role| {
                var acl: O.Object = .{ .kind = .schema_acl, .target = schema.oid, .grantee = role, .owner = owner };
                const before = self.catalog_objects.findKey(&acl, latest);
                const old: ?u32 = if (before) |index| self.catalog_objects.items[index].flags else null;
                const next: ?u32 = if (role == owner)
                    (if (revoke) 0 else null)
                else
                    (if (revoke) null else CO.priv_schema_usage);
                if (old == next) continue;
                if (before) |index| self.objectDelete(slot, index, snap);
                if (next) |flags| {
                    acl.flags = flags;
                    _ = try self.objectInsert(slot, &acl, false, snap);
                }
            }
        }

        fn alterSchemaOwner(self: *Self, slot: u16, source: []const u8, ident: CO.Ident, grantee: CO.Grantee, snap: Snapshot) Error!void {
            const name = objectName(source, ident);
            const visible = self.catalog.findSchema(name.slice(), snap) orelse return error.UndefinedSchema;
            const schema = &self.schemas[visible.slot];
            if (!schema.private_usage) return error.UnsupportedStatement;
            if (schema.pending_drop and schema.creator != slot) return self.objectPark(slot, schema.creator);
            if (self.catalog_objects.pendingReference(schema.oid, snap)) |other| return self.objectPark(slot, other);
            var latest = snap;
            latest.csn = self.csn;
            const current = self.catalog.findSchema(name.slice(), latest) orelse return error.SerializationFailure;
            if (current.oid != visible.oid) return error.SerializationFailure;
            const old_owner = self.schemaOwner(schema, latest);
            if (self.schemaOwner(schema, snap) != old_owner) return error.SerializationFailure;
            if (!self.ownsNamespace(schema.oid, latest)) return error.InsufficientPrivilege;
            const new_owner = try self.objectRole(source, grantee, latest);
            if (self.catalog_objects.pendingReference(new_owner, snap)) |other| return self.objectPark(slot, other);
            if (new_owner == old_owner) return;
            // The database layer exposes no database-level CREATE grants yet.
            if (!self.privilegedRole(latest)) return error.InsufficientPrivilege;

            var owner_entry: O.Object = .{ .kind = .schema_owner, .target = schema.oid, .owner = new_owner };
            const previous = self.catalog_objects.findKey(&owner_entry, latest);
            var acl_count: usize = 0;
            var owner_revoked = false;
            var new_owner_usage = false;
            for (&self.catalog_objects.items) |*item| {
                if (item.target != schema.oid or !O.visible(item, latest)) continue;
                if (item.kind == .schema_acl_state) acl_count += 1;
                if (item.kind != .schema_acl) continue;
                acl_count += 1;
                owner_revoked = owner_revoked or (item.grantee == old_owner and item.flags == 0);
                new_owner_usage = new_owner_usage or (item.grantee == new_owner and item.flags != 0);
            }
            try self.reserveWrites(slot, 1 + @as(usize, @intFromBool(previous != null)) + 2 * acl_count);
            if (previous) |index| self.objectDelete(slot, index, latest);
            _ = try self.objectInsert(slot, &owner_entry, false, latest);
            for (&self.catalog_objects.items, 0..) |*item, index| {
                if (item.target != schema.oid or !O.visible(item, latest)) continue;
                if (item.kind != .schema_acl and item.kind != .schema_acl_state) continue;
                var updated = item.*;
                self.objectDelete(slot, index, latest);
                if (updated.kind == .schema_acl) {
                    if (updated.grantee == new_owner) continue;
                    if (updated.grantee == old_owner) {
                        if (!owner_revoked or new_owner_usage) continue;
                        updated.grantee = new_owner;
                    }
                }
                updated.owner = new_owner;
                _ = try self.objectInsert(slot, &updated, false, latest);
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
                    if (!comment.object.has_schema and !self.session.public_schema_on_path) return error.TableNotFound;
                    const schema_name = if (comment.object.has_schema) objectName(source, comment.object.schema) else Name{};
                    const namespace = (try self.namespaceForUsage(self.session.role, if (comment.object.has_schema) schema_name.slice() else null, snap)) orelse return error.UndefinedSchema;
                    const found = self.catalog.findIn(namespace, objectName(source, comment.object.name).slice(), snap) orelse return error.TableNotFound;
                    if (found.kind != 'S') return error.WrongObjectType;
                    if (!privileged) return error.InsufficientPrivilege;
                    key.grantee = CO.class_relation;
                    key.target = self.seqs[found.slot].oid;
                },
                .index, .extension => return error.UnsupportedStatement,
                .foreign_table => return error.TableNotFound,
                .large_object => {
                    key.grantee = CO.class_large_object;
                    key.target = comment.large_object;
                    const index = (try self.lockLargeObject(slot, key.target, snap)) orelse return error.UndefinedObject;
                    if (!self.ownsLargeObject(self.catalog_objects.items[index].owner, snap)) return error.InsufficientPrivilege;
                },
                .schema => {
                    key.grantee = CO.class_namespace;
                    key.target = namespaceFor(&self.catalog, objectName(source, comment.object.name).slice(), snap) orelse return error.UndefinedSchema;
                    if (!self.ownsNamespace(key.target, snap)) return error.InsufficientPrivilege;
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
            if (key.grantee != CO.class_relation and key.grantee != CO.class_namespace and key.grantee != CO.class_large_object) {
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
            if (self.catalog_objects.pendingConflict(&object, snap)) |other| return self.objectPark(slot, other);
            var latest = snap;
            latest.csn = self.csn;
            if (self.catalog_objects.byName(.publication, 0, object.name.slice(), latest) != null) return error.DuplicateObject;
            if (self.catalog_objects.pendingReference(object.owner, snap)) |other| return self.objectPark(slot, other);
            var members: PublicationMembers = .{};
            for (publication.members[0..publication.count]) |member| {
                switch (member) {
                    .schema => |ident| {
                        const name = objectName(source, ident);
                        const namespace = namespaceFor(&self.catalog, name.slice(), snap) orelse return error.UndefinedSchema;
                        if (namespace != catalog_module.public_namespace and namespace < change_log.first_oid) return error.InvalidParameterValue;
                        for (&self.schemas) |*schema| {
                            if (schema.live and schema.oid == namespace and schema.pending_drop and schema.creator != slot) return self.objectPark(slot, schema.creator);
                        }
                        if (namespaceFor(&self.catalog, name.slice(), latest) != namespace) return error.SerializationFailure;
                        members.add(.publication_schema, namespace);
                    },
                    .table => |table| {
                        const index = self.objectTable(slot, source, table.name, .access_share, snap) catch |err| {
                            if (err == error.WrongObjectType) return error.InvalidParameterValue;
                            return err;
                        };
                        const relation = &self.tables[index];
                        if (!CO.publicationRelationKind(relation.relkind)) return error.InvalidParameterValue;
                        if (self.visibleTableSlot(relation.oid, latest) != index) return error.SerializationFailure;
                        members.add(.publication_table, relation.oid);
                        if (!table.only and relation.relkind != 'p') try self.addPublicationDescendants(slot, relation.oid, snap, &members);
                    },
                }
            }
            try self.reserveWrites(slot, 1 + members.count);
            const index = try self.objectInsert(slot, &object, true, snap);
            const oid = self.catalog_objects.items[index].oid;
            for (members.items[0..members.count]) |member| {
                var entry: O.Object = .{ .kind = member.kind, .target = oid, .grantee = member.oid };
                _ = try self.objectInsert(slot, &entry, true, snap);
            }
        }

        const PublicationMembers = struct {
            const Member = struct { kind: CO.Kind, oid: u32 };
            items: [config.tables + config.schemas + 1]Member = undefined,
            count: usize = 0,

            fn add(self: *PublicationMembers, kind: CO.Kind, oid: u32) void {
                for (self.items[0..self.count]) |member| {
                    if (member.kind == kind and member.oid == oid) return;
                }
                self.items[self.count] = .{ .kind = kind, .oid = oid };
                self.count += 1;
            }
        };

        fn addPublicationDescendants(self: *Self, slot: u16, root: u32, snap: Snapshot, members: *PublicationMembers) Error!void {
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') continue;
                const table = &self.tables[found.slot];
                if (!CO.publicationRelationKind(table.relkind) or table.partition.bound != .none) continue;
                var parent = table.parent;
                while (parent != 0) {
                    if (parent == root) {
                        try self.lockTable(slot, found.slot, .access_share);
                        var latest = snap;
                        latest.csn = self.csn;
                        if (self.visibleTableSlot(table.oid, latest) != found.slot) return error.SerializationFailure;
                        members.add(.publication_table, table.oid);
                        break;
                    }
                    const index = self.visibleTableSlot(parent, snap) orelse return error.SerializationFailure;
                    parent = self.tables[index].parent;
                }
            }
        }

        fn createStatistics(self: *Self, slot: u16, source: []const u8, spec: *const CO.Statistics, snap: Snapshot) Error!void {
            const table_slot = try self.objectTable(slot, source, spec.table, .share_update_exclusive, snap);
            const table = &self.tables[table_slot];
            if (table.relkind != 'r' and table.relkind != 'p' and table.relkind != 'm') return error.WrongObjectType;
            if (!self.catalog_objects.ownsTable(self.session.role, table.oid, snap)) return error.InsufficientPrivilege;
            const namespace = try self.typeNamespace(source, spec.name, snap);
            if (namespace != catalog_module.public_namespace and namespace < change_log.first_oid) return error.InsufficientPrivilege;
            for (&self.schemas) |*schema| {
                if (schema.live and schema.oid == namespace and schema.pending_drop and schema.creator != slot) return self.objectPark(slot, schema.creator);
            }
            var latest = snap;
            latest.csn = self.csn;
            if (!self.catalog_objects.ownsTable(self.session.role, table.oid, latest)) return error.SerializationFailure;
            if (try self.typeNamespace(source, spec.name, latest) != namespace) return error.SerializationFailure;
            var object: O.Object = .{ .kind = .statistics, .target = namespace, .grantee = table.oid, .sub = -1, .owner = self.session.role, .flags = spec.flags };
            try object.setName(objectName(source, spec.name.name).slice());
            if (self.catalog_objects.pendingConflict(&object, snap)) |other| return self.objectPark(slot, other);
            if (self.catalog_objects.byName(.statistics, namespace, object.name.slice(), latest) != null) {
                if (spec.if_not_exists) return;
                return error.DuplicateObject;
            }
            if (spec.count < 2) return error.InvalidObjectDefinition;
            var chosen: [config.columns]bool = @splat(false);
            for (spec.columns[0..spec.count]) |column| {
                const name = objectName(source, column);
                for (table.columns[0..table.column_count], 0..) |*definition, position| {
                    if (!types.same(definition.name.slice(), name.slice())) continue;
                    if (chosen[position]) return error.DuplicateColumn;
                    chosen[position] = true;
                    break;
                } else return error.ColumnNotFound;
            }
            var columns: [CO.statistics_columns]u8 = undefined;
            var count: usize = 0;
            for (chosen, 0..) |include, position| {
                if (!include) continue;
                columns[count] = @intCast(position);
                count += 1;
            }
            try object.setText(columns[0..count], "");
            if (self.catalog_objects.pendingReference(object.owner, snap)) |other| return self.objectPark(slot, other);
            try self.reserveWrites(slot, 1);
            _ = try self.objectInsert(slot, &object, true, snap);
        }

        fn findStatistics(self: *Self, slot: u16, source: []const u8, name: CO.Qualified, conditional: bool, snap: Snapshot) Error!?usize {
            const namespace = self.typeNamespace(source, name, snap) catch |err| {
                if (conditional and err == error.UndefinedSchema) return null;
                return err;
            };
            const parsed = objectName(source, name.name);
            const key: O.Object = .{ .kind = .statistics, .target = namespace, .name = parsed };
            if (self.catalog_objects.pendingConflict(&key, snap)) |other| return self.objectPark(slot, other);
            const index = self.catalog_objects.byName(.statistics, namespace, parsed.slice(), snap) orelse {
                if (conditional) return null;
                return error.UndefinedObject;
            };
            const object = &self.catalog_objects.items[index];
            const table_slot = self.visibleTableSlot(object.grantee, snap) orelse return error.TableNotFound;
            try self.lockTable(slot, table_slot, .share_update_exclusive);
            var latest = snap;
            latest.csn = self.csn;
            if (!O.visible(object, latest)) return error.SerializationFailure;
            if (!self.privilegedRole(snap) and !self.catalog_objects.memberOf(self.session.role, object.owner, true, snap)) return error.InsufficientPrivilege;
            return index;
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
                    if (other.kind == .comment and other.grantee != CO.class_large_object and other.target == o.oid) writes += 1;
                    if (kind == .publication and CO.publicationMembership(other.kind) and other.target == o.oid) writes += 1;
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
                    if (kind == .publication and CO.publicationMembership(other.kind) and other.target == oid) self.objectDelete(slot, position, snap);
                    if (kind == .fdw and other.kind == .server and other.target == oid) {
                        const server_oid = other.oid;
                        self.objectDelete(slot, position, snap);
                        for (&self.catalog_objects.items, 0..) |*c, at| if (c.kind == .comment and c.grantee == CO.class_server and c.target == server_oid and O.visible(c, snap) and c.xmax.epoch == 0) {
                            self.objectDelete(slot, at, snap);
                        };
                    }
                }
                for (&self.catalog_objects.items, 0..) |*c, at| if (c.kind == .comment and c.grantee != CO.class_large_object and c.target == oid and O.visible(c, snap) and c.xmax.epoch == 0) {
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
            if (insert.replace) wanted |= CO.priv_delete;
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
        /// Creation of a plain table was authorized against its destination
        /// namespace at bind time. Other creation paths still require a
        /// superuser. Altering or dropping a relation needs its ownership.
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
                .legacy_attribute_options => |options| try self.needOwner(options.table, snap),
                .refresh_view => |*refresh| try self.needOwner(refresh.slot, snap),
                .create_table => |*create| if (self.dialect != .postgres or !create.plain_definition) return error.InsufficientPrivilege,
                .create_sequence, .drop_sequence, .alter_sequence, .create_schema => return error.InsufficientPrivilege,
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
            if (goal.schema == null and !self.session.public_schema_on_path) return source;
            const schema_name = if (goal.schema) |qualifier| identName(source, qualifier) else Name{};
            const namespace = (try self.namespaceForUsage(role, if (goal.schema != null) schema_name.slice() else null, snap)) orelse return source;
            const found = self.catalog.findIn(namespace, identName(source, goal.table).slice(), snap) orelse return source;
            if (found.kind != 'r' and found.kind != 'p') return source;
            const table = &self.tables[found.slot];
            if (!try self.checkRowSecurity(role, table.oid, self.session.row_security, snap)) return source;
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
                    if (try self.checkRowSecurity(role, self.tables[merge.table].oid, self.session.row_security, snap)) return error.UnsupportedStatement;
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
                        if (try self.checkRowSecurity(role, self.tables[table_slot].oid, self.session.row_security, snap)) return error.UnsupportedStatement;
                    }
                    return;
                },
                else => return,
            };
            const oid = self.tables[goal.table].oid;
            if (!try self.checkRowSecurity(role, oid, self.session.row_security, snap)) return;
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

        /// With row_security disabled, access requiring any policy errors,
        /// including the default-deny case. Owners and bypass roles still
        /// use the ordinary catalog eligibility check.
        fn checkRowSecurity(self: *const Self, role: u32, table: u32, enabled: bool, snap: Snapshot) Error!bool {
            const applies = self.catalog_objects.rowSecurity(role, table, snap);
            if (applies and !enabled) return error.InsufficientPrivilege;
            return applies;
        }

        /// SELECT privilege and row security of one FROM item the statement
        /// names (not one a view or an expansion introduced: those run with
        /// the view owner's rights, the bootstrap superuser). Returns the
        /// derived query replacing it under row security, or none.
        fn secureItem(db: *const Self, workspace: *Workspace, length: *usize, source: []const u8, role: u32, row_security: bool, found: K.Found, snap: Snapshot) Error!u16 {
            if (found.kind == 'S') {
                const seq = &db.seqs[found.slot];
                const owner = if (seq.owner == 0) CO.bootstrap_role else db.catalog_objects.owner(seq.owner, snap);
                if (!db.catalog_objects.memberOf(role, owner, true, snap)) return error.InsufficientPrivilege;
                return ast.none;
            }
            const table = &db.tables[found.slot];
            if (!db.catalog_objects.tablePrivileges(role, table.oid, CO.priv_select, snap)) return error.InsufficientPrivilege;
            if (table.relkind != 'r' and table.relkind != 'p') return ast.none;
            if (!try db.checkRowSecurity(role, table.oid, row_security, snap)) return ast.none;
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

        fn relationAcl(self: *const Self, oid: u32, snapshot: Snapshot) Error!Cell {
            const owner = self.catalog_objects.owner(oid, snapshot);
            var count: u32 = 0;
            for (&self.catalog_objects.items) |*item| {
                if (item.kind == .acl and item.target == oid and item.grantee != owner and O.visible(item, snapshot)) count += 1;
            }
            if (count == 0) return .null_value;
            const Acl = @import("sql/catalog_acl.sig").Acl(V);
            const owner_name = self.catalog_objects.roleName(owner, snapshot) orelse return error.UndefinedObject;
            var output: Text = .{};
            var writer = try Acl.begin(&output, count + 1);
            try Acl.append(&writer, owner_name, "arwdDxt", owner_name);
            for (&self.catalog_objects.items) |*item| {
                if (item.kind != .acl or item.target != oid or item.grantee == owner or !O.visible(item, snapshot)) continue;
                const grantee = if (item.grantee == CO.public_role) "" else
                    self.catalog_objects.roleName(item.grantee, snapshot) orelse return error.UndefinedObject;
                const grantor = self.catalog_objects.roleName(item.owner, snapshot) orelse return error.UndefinedObject;
                var permissions: [16]u8 = undefined;
                var used: usize = 0;
                for ("arwdDxtm", CO.privilege_bits) |letter, flag| {
                    if (item.flags & flag == 0) continue;
                    permissions[used] = letter;
                    used += 1;
                    if (item.grant_flags & flag != 0) {
                        permissions[used] = '*';
                        used += 1;
                    }
                }
                try Acl.append(&writer, grantee, permissions[0..used], grantor);
            }
            return .{ .array = output };
        }

        fn largeObjectAcl(self: *const Self, object: *const O.Object, snapshot: Snapshot, values: ?*types.ValueBytes) Error!Cell {
            if (object.flags & CO.large_object_explicit_acl == 0) return .null_value;
            const owner = self.catalog_objects.roleName(object.owner, snapshot) orelse return error.UndefinedObject;
            const owner_flags = largeObjectOwnerPrivileges(object);
            var edges: [O.capacity]LoAcl.Edge = undefined;
            const graph = self.largeObjectGrantGraph(object, snapshot, &edges);
            var emitted: [O.capacity]LoAcl.Graph.State = undefined;
            graph.start(&emitted);
            var steps: [2 * O.capacity]LoAcl.Graph.Step = undefined;
            var count: usize = 0;
            while (graph.next(&emitted)) |step| {
                steps[count] = step;
                count += 1;
            }
            const Acl = @import("sql/catalog_acl.sig").Acl(V);
            var inline_buffer: [config.text_bytes]u8 = undefined;
            var writer = try Acl.CatalogWriter.start(&inline_buffer, values, @intCast(count + @intFromBool(owner_flags != 0)));
            var letters: [4]u8 = undefined;
            if (owner_flags != 0) try writer.add(owner, largeObjectPermissionLetters(owner_flags, object.grant_flags, &letters), owner);
            for (steps[0..count]) |step| {
                const entry = &edges[step.index];
                const grantee = if (entry.grantee == CO.public_role) "" else
                    self.catalog_objects.roleName(entry.grantee, snapshot) orelse return error.UndefinedObject;
                const grantor = self.catalog_objects.roleName(entry.grantor, snapshot) orelse return error.UndefinedObject;
                try writer.add(grantee, largeObjectPermissionLetters(step.flags, entry.options, &letters), grantor);
            }
            return writer.finish();
        }

        fn largeObjectPermissionLetters(flags: u32, options: u32, letters: *[4]u8) []const u8 {
            var used: usize = 0;
            for ([_]u32{ CO.priv_select, CO.priv_update }, "rw") |flag, letter| {
                if (flags & flag == 0) continue;
                letters[used] = letter;
                used += 1;
                if (options & flag != 0) {
                    letters[used] = '*';
                    used += 1;
                }
            }
            return letters[0..used];
        }

        fn namespaceAcl(self: *const Self, oid: u32, owner: u32, snapshot: Snapshot) Error!Cell {
            const key: O.Object = .{ .kind = .schema_acl_state, .target = oid, .owner = owner };
            if (self.catalog_objects.findKey(&key, snapshot) == null) return .null_value;
            const owner_name = self.catalog_objects.roleName(owner, snapshot) orelse return error.UndefinedObject;
            const Acl = @import("sql/catalog_acl.sig").Acl(V);
            var count: u32 = 1;
            var owner_privileges: []const u8 = "UC";
            for (&self.catalog_objects.items) |*item| {
                if (item.kind != .schema_acl or item.target != oid or !O.visible(item, snapshot)) continue;
                if (item.grantee == owner) {
                    owner_privileges = "C";
                } else count += 1;
            }
            var output: Text = .{};
            var writer = try Acl.begin(&output, count);
            try Acl.append(&writer, owner_name, owner_privileges, owner_name);
            for (&self.catalog_objects.items) |*item| {
                if (item.kind != .schema_acl or item.target != oid or item.grantee == owner or !O.visible(item, snapshot)) continue;
                const grantee = if (item.grantee == CO.public_role) "" else
                    self.catalog_objects.roleName(item.grantee, snapshot) orelse return error.UndefinedObject;
                try Acl.append(&writer, grantee, "U", owner_name);
            }
            return .{ .array = output };
        }

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

        fn catalogSchemaPath(ptr: *anyopaque, implicit: bool, names: *[2][]const u8) usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const path = self.sessionState().values.search_path.slice();
            var items = std.mem.splitSequence(u8, path, ", ");
            var count: usize = 0;
            var catalog_seen = false;
            var public_seen = false;
            while (items.next()) |item| {
                if (types.same(item, "pg_catalog") and !catalog_seen) {
                    names[count] = "pg_catalog";
                    count += 1;
                    catalog_seen = true;
                } else if (types.same(item, "public") and !public_seen) {
                    names[count] = "public";
                    count += 1;
                    public_seen = true;
                }
            }
            if (implicit and !catalog_seen) {
                if (count != 0) names[1] = names[0];
                names[0] = "pg_catalog";
                count += 1;
            }
            return count;
        }

        /// Rows of the catalog-object system views.
        fn catalogObjectRows(self: *const Self, session_values: *const value_module.Session, snapshot: Snapshot, view: catalog_module.View, sink: *X.RowSink) Error!void {
            const database = session_values.database;
            switch (view) {
                .pg_largeobject_metadata => {
                    const include_acl = sink.referencesColumn(2);
                    for (&self.catalog_objects.items) |*entry| {
                        if (entry.kind != .large_object or !O.visible(entry, snapshot)) continue;
                        const acl = if (include_acl) try self.largeObjectAcl(entry, snapshot, sink.valueBytes()) else .null_value;
                        try sink.add(&.{ intCell(entry.target), intCell(entry.owner), acl });
                    }
                },
                .pg_roles, .pg_authid => {
                    // The bootstrap superuser first, then roles in catalog order.
                    var bootstrap: O.Object = .{ .kind = .role, .oid = CO.bootstrap_role, .flags = CO.role_attributes, .grant_flags = @bitCast(@as(i32, -1)) };
                    bootstrap.setName(CO.bootstrap_name) catch {};
                    try self.roleRow(view, &bootstrap, sink);
                    for (&self.catalog_objects.items) |*o| if (o.kind == .role and O.visible(o, snapshot)) try self.roleRow(view, o, sink);
                },
                .pg_auth_members => for (&self.catalog_objects.items) |*o| if (o.kind == .member and O.visible(o, snapshot)) {
                    try sink.add(&.{ intCell(o.oid), intCell(o.target), intCell(o.grantee), intCell(o.owner),
                        boolCell(o.grant_flags & CO.member_admin != 0), boolCell(self.catalog_objects.membershipInherits(o, snapshot)), boolCell(O.membershipCanSet(o)) });
                },
                .pg_db_role_setting => for (&self.catalog_objects.items) |*o| if (o.kind == .role_settings and O.visible(o, snapshot)) {
                    var array: Text = .{};
                    var shape: array_module.Shape = .{ .element = .text, .ndim = 1 };
                    shape.dims[0] = @popCount(o.flags);
                    var writer = try V.Arrays.Writer.begin(&array, &shape);
                    inline for (@typeInfo(CO.RoleBoolean).@"enum".field_names) |name| {
                        const bit = @field(CO.RoleBoolean, name).bit();
                        if (o.flags & bit != 0) {
                            const cell = nameCell(if (o.grant_flags & bit != 0) name ++ "=on" else name ++ "=off");
                            try writer.append(&cell);
                        }
                    }
                    try sink.add(&.{ intCell(0), intCell(o.target), .{ .array = array } });
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
                .pg_publication_rel => for (&self.catalog_objects.items) |*o| if (o.kind == .publication_table and O.visible(o, snapshot)) {
                    try sink.add(&.{ intCell(o.oid), intCell(o.target), intCell(o.grantee), .null_value, .null_value });
                },
                .pg_publication_namespace => for (&self.catalog_objects.items) |*o| if (o.kind == .publication_schema and O.visible(o, snapshot)) {
                    try sink.add(&.{ intCell(o.oid), intCell(o.target), intCell(o.grantee) });
                },
                .pg_statistic_ext => for (&self.catalog_objects.items) |*o| if (o.kind == .statistics and O.visible(o, snapshot)) {
                    var buffer: [4 * CO.statistics_columns]u8 = undefined;
                    var keys: CatalogTextWriter = .{ .out = &buffer };
                    for (o.textSlice(), 0..) |column, index| {
                        if (index != 0) keys.add(" ");
                        var digits: [3]u8 = undefined;
                        keys.add(std.fmt.bufPrint(&digits, "{d}", .{@as(usize, column) + 1}) catch unreachable);
                    }
                    var kinds: Text = .{};
                    var shape: array_module.Shape = .{ .element = .text, .ndim = 1 };
                    shape.dims[0] = @popCount(o.flags);
                    var writer = try V.Arrays.Writer.begin(&kinds, &shape);
                    for (CO.statistics_kinds, 0..) |kind, index| {
                        if (o.flags & (@as(u32, 1) << @as(u5, @intCast(index))) != 0) try writer.append(&nameCell(kind));
                    }
                    try sink.add(&.{ intCell(o.oid), intCell(o.grantee), nameCell(o.name.slice()), intCell(o.target), intCell(o.owner),
                        if (o.sub == -1) .null_value else intCell(o.sub), try objectTextCell(keys.slice()), .{ .array = kinds }, .null_value });
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
        fn checkNamespaceForCreate(self: *Self, slot: u16, namespace: u32) Error!void {
            if (namespace == catalog_module.public_namespace) return;
            const tx = &self.txs[slot];
            for (&self.schemas) |*schema| {
                if (!schema.live or schema.oid != namespace) continue;
                if (schema.pending_drop and schema.creator != slot) {
                    var waits: L.Set = .{};
                    waits.add(schema.creator);
                    tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                    return self.park(slot, waits);
                }
                if (schema.dead_csn != 0 or schema.pending_drop) return error.UndefinedSchema;
                return;
            }
            return error.UndefinedSchema;
        }

        fn createSequence(self: *Self, slot: u16, namespace: u32, name: Name, spec: sequence_module.Spec, owner: u32, owner_column: u8, serial: bool, snap: Snapshot) Error!void {
            try self.checkNamespaceForCreate(slot, namespace);
            const tx = &self.txs[slot];
            if (self.catalog.creatorIn(namespace, name.slice(), snap)) |other| {
                var waits: L.Set = .{};
                waits.add(other);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            var latest = snap;
            latest.csn = self.csn;
            latest.cid +%= 1;
            if (self.catalog.findIn(namespace, name.slice(), latest) != null) return error.TableExists;
            if (self.catalog_objects.pendingCompositeRelationName(namespace, name.slice(), snap)) |other| return self.objectPark(slot, other);
            if (self.catalog_objects.byName(.composite_type, namespace, name.slice(), latest) != null) return error.TableExists;
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
            seq.namespace = namespace;
            seq.pending_create = true;
            seq.creator = slot;
            self.oid_counter += 1;
            tx.push(.{ .kind = .create_sequence, .table = @intCast(index), .new = @intFromBool(serial) }) catch unreachable;
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
        fn alterSequence(self: *Self, slot: u16, index: usize, options: sequence_module.Options, ownership: ?sequence_module.Ownership, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const seq = &self.seqs[index];
            if (seq.pending_drop and seq.creator != slot) {
                var waits: L.Set = .{};
                waits.add(seq.creator);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            const altered = try sequence_module.alter(seq.spec, seq.last_value, options);
            if (ownership) |dependency| {
                var latest = snap;
                latest.csn = self.csn;
                if (seq.dead_csn != 0) return error.SerializationFailure;
                var role: u32 = CO.bootstrap_role;
                if (seq.owner != 0) {
                    const origin = self.visibleTableSlot(seq.owner, snap) orelse return error.TableNotFound;
                    try self.lockTable(slot, origin, .access_share);
                    if (self.visibleTableSlot(seq.owner, latest) != origin) return error.SerializationFailure;
                    switch (self.tables[origin].columns[seq.owner_column].default_kind) {
                        .identity_always, .identity_by_default, .mysql_auto_increment => return error.UnsupportedStatement,
                        else => {},
                    }
                    role = self.catalog_objects.owner(seq.owner, latest);
                }
                if (dependency.table != 0) {
                    const destination = self.visibleTableSlot(dependency.table, snap) orelse return error.TableNotFound;
                    try self.lockTable(slot, destination, .access_share);
                    if (self.visibleTableSlot(dependency.table, latest) != destination) return error.SerializationFailure;
                    if (self.tables[destination].namespace != seq.namespace or
                        self.catalog_objects.owner(dependency.table, latest) != role)
                        return error.InvalidParameterValue;
                    switch (self.tables[destination].columns[dependency.column].default_kind) {
                        .identity_always, .identity_by_default, .mysql_auto_increment => return error.UnsupportedStatement,
                        else => {},
                    }
                }
            }
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
            if (ownership) |dependency| {
                copy.owner = dependency.table;
                copy.owner_column = dependency.column;
            }
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

        fn sequenceByName(self: *const Self, text: []const u8) Error!usize {
            return self.sequenceByOid(@intCast(try self.regclassOid(text, true)));
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

        /// The first qualifier separator outside double quotes.
        fn regclassSeparator(text: []const u8) ?usize {
            var quoted = false;
            for (text, 0..) |byte, index| {
                if (byte == '"') quoted = !quoted;
                if (byte == '.' and !quoted) return index;
            }
            return null;
        }

        fn numericRegOid(text: []const u8) Error!?u32 {
            if (text.len == 1 and text[0] == '-') return 0;
            if (text.len == 0) return null;
            for (text) |byte| {
                if (byte < '0' or byte > '9') return null;
            }
            return std.fmt.parseInt(u32, text, 10) catch error.NumericValueOutOfRange;
        }

        /// Resolve real catalog, table, sequence, index and composite OIDs.
        fn regclassOid(self: *const Self, text: []const u8, strict: bool) Error!i64 {
            const missing: Error!i64 = if (strict) error.TableNotFound else -1;
            if (try numericRegOid(text)) |oid| return oid;
            const whitespace = " \t\r\n";
            if (regclassSeparator(text)) |dot| {
                const tail = text[dot + 1 ..];
                if (regclassSeparator(tail) != null) return error.UnsupportedStatement;
                const schema = namespaceIdentifier(std.mem.trim(u8, text[0..dot], whitespace)) catch return missing;
                const name = namespaceIdentifier(std.mem.trim(u8, tail, whitespace)) catch return missing;
                const namespace = (try self.namespaceForUsage(self.session.role, schema.slice(), self.seq_snap)) orelse return missing;
                return if (self.regclassIn(namespace, name.slice())) |oid| oid else missing;
            }
            const name = namespaceIdentifier(std.mem.trim(u8, text, whitespace)) catch return missing;
            if (self.regclassIn(catalog_module.catalog_namespace, name.slice())) |oid| return oid;
            if (!self.session.public_schema_on_path) return missing;
            return if (self.regclassIn(catalog_module.public_namespace, name.slice())) |oid| oid else missing;
        }

        fn regclassIn(self: *const Self, namespace: u32, name: []const u8) ?u32 {
            if (namespace == catalog_module.catalog_namespace) {
                const view = self.catalog.findSystemView("pg_catalog", name) orelse return null;
                for (catalog_module.bootstrap_relations) |relation| {
                    if (relation.view == view) return relation.oid;
                }
                return null;
            }
            if (self.catalog.findIn(namespace, name, self.seq_snap)) |found| {
                return if (found.kind == 'S') self.seqs[found.slot].oid else self.tables[found.slot].oid;
            }
            if (self.catalog_objects.byName(.composite_type, namespace, name, self.seq_snap)) |index| {
                return self.catalog_objects.items[index].compositeRelationOid();
            }
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(self.seq_snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') continue;
                const table = &self.tables[found.slot];
                if (table.namespace != namespace) continue;
                if (S.keyed(table)) {
                    const primary = indexName(table) catch Name{};
                    if (types.same(primary.slice(), name)) return S.primaryIndexOid(table);
                }
                for (table.indexes[0..table.index_count]) |*index| {
                    if (index.oid != 0 and types.same(index.name.slice(), name)) return index.oid;
                }
            }
            return null;
        }

        fn namespaceIdentifier(raw: []const u8) Error!Name {
            if (raw.len == 0) return error.InvalidName;
            var result: Name = .{};
            if (raw[0] == '"') {
                if (raw.len < 3 or raw[raw.len - 1] != '"') return error.InvalidName;
                const name = raw[1 .. raw.len - 1];
                var index: usize = 0;
                while (index < name.len) : (index += 1) {
                    const byte = name[index];
                    if (byte == '"') {
                        index += 1;
                        if (index == name.len or name[index] != '"') return error.InvalidName;
                    }
                    if (byte == 0) return error.InvalidName;
                    if (result.len == result.bytes.len) return error.NameCapacity;
                    result.bytes[result.len] = byte;
                    result.len += 1;
                }
                return result;
            }
            if (raw.len > result.bytes.len) return error.NameCapacity;
            for (raw, 0..) |byte, index| {
                switch (byte) { '.', '"', ' ', '\t', '\r', '\n', 0 => return error.InvalidName, else => {} }
                result.bytes[index] = types.lower(byte);
            }
            result.len = raw.len;
            return result;
        }

        fn postgresNamespaceLookup(ptr: *anyopaque, text: []const u8, strict: bool) Error!?u32 {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            const raw = std.mem.trim(u8, text, " \t\r\n");
            if (try numericRegOid(raw)) |oid| return oid;
            const name = try namespaceIdentifier(raw);
            if (namespaceFor(&self.catalog, name.slice(), self.seq_snap)) |oid| return oid;
            if (strict) return error.UndefinedSchema;
            return null;
        }

        fn postgresNamespaceName(ptr: *anyopaque, oid: u32, out: []u8) Error!?usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            for (catalog_module.namespaces) |known| {
                if (oid == known.oid) return try self.writeNamespaceName(known.name, out);
            }
            var schemas: [K.relation_rows]K.SchemaFound = undefined;
            const count = self.catalog.visibleSchemas(self.seq_snap, &schemas);
            for (schemas[0..count]) |found| {
                if (oid == found.oid) return try self.writeNamespaceName(self.schemas[found.slot].name.slice(), out);
            }
            return null;
        }

        fn builtinShadowsRoutine(routine: *const RC.Routine) bool {
            for (operator_catalog.functions) |op| {
                if (!types.same(op.function_name, routine.name.slice())) continue;
                const args = routine.args();
                if (op.left == 0 and args.len == 1 and args[0] == op.right) return true;
                if (op.left != 0 and args.len == 2 and args[0] == op.left and args[1] == op.right) return true;
            }
            return false;
        }

        fn routineByName(self: *const Self, namespace: ?u32, name: []const u8) Error!?u32 {
            var oid: ?u32 = null;
            if (namespace == null or namespace.? == catalog_module.catalog_namespace) {
                for (catalog_module.access_methods) |am| {
                    if (!types.same(am.handler_name, name)) continue;
                    if (oid != null) return error.AmbiguousFunction;
                    oid = am.handler;
                }
                for (catalog_module.builtin_callbacks) |callback| {
                    if (!types.same(callback.name, name)) continue;
                    if (oid != null) return error.AmbiguousFunction;
                    oid = callback.oid;
                }
                for (operator_catalog.functions) |op| {
                    if (!types.same(op.function_name, name)) continue;
                    if (oid != null) return error.AmbiguousFunction;
                    oid = op.function_oid;
                }
            }
            if ((namespace orelse catalog_module.public_namespace) != catalog_module.public_namespace) return oid;
            if (namespace == null and !self.session.public_schema_on_path) return oid;
            for (&self.objects.routines) |*routine| {
                if (!routine.live or routine.namespace != catalog_module.public_namespace or
                    !routine.stamp.visible(self.seq_snap) or !types.same(routine.name.slice(), name)) continue;
                if (namespace == null and oid != null and builtinShadowsRoutine(routine)) continue;
                if (oid != null) return error.AmbiguousFunction;
                oid = routine.oid;
            }
            return oid;
        }

        fn postgresRoutineLookup(ptr: *anyopaque, raw: []const u8, strict: bool) Error!?u32 {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            const missing: Error!?u32 = if (strict) error.UndefinedFunction else null;
            const whitespace = " \t\r\n";
            var namespace: ?u32 = null;
            var name_text = raw;
            if (regclassSeparator(raw)) |dot| {
                name_text = raw[dot + 1 ..];
                if (regclassSeparator(name_text) != null) return missing;
                const schema = namespaceIdentifier(std.mem.trim(u8, raw[0..dot], whitespace)) catch return missing;
                namespace = (try self.namespaceForUsage(self.session.role, schema.slice(), self.seq_snap)) orelse return missing;
            }
            const name = namespaceIdentifier(std.mem.trim(u8, name_text, whitespace)) catch return missing;
            const oid = self.routineByName(namespace, name.slice()) catch |err| {
                if (err == error.AmbiguousFunction and !strict) return null;
                return err;
            };
            return oid orelse return missing;
        }

        fn postgresRoutineName(ptr: *anyopaque, oid: u32, out: []u8) Error!?usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            var namespace: u32 = catalog_module.catalog_namespace;
            const name = catalog_module.builtinRoutineName(oid) orelse blk: {
                const index = self.objects.routineByOid(oid, self.seq_snap) orelse return null;
                const routine = &self.objects.routines[index];
                namespace = routine.namespace;
                break :blk routine.name.slice();
            };
            var writer: CatalogTextWriter = .{ .out = out, .quote_all = self.session.quote_all_identifiers };
            const visible = self.routineByName(null, name) catch null;
            if (visible == null or visible.? != oid) {
                writer.ident(self.namespaceName(namespace));
                writer.add(".");
            }
            writer.ident(name);
            if (writer.shortened) return error.TextCapacity;
            return writer.len;
        }

        fn writeNamespaceName(self: *const Self, name: []const u8, out: []u8) Error!usize {
            var text: CatalogTextWriter = .{ .out = out, .quote_all = self.session.quote_all_identifiers };
            text.ident(name);
            if (text.shortened) return error.TextCapacity;
            return text.len;
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

        const RelationIdentity = struct { name: []const u8, namespace: u32 };

        fn relationIdentity(self: *const Self, oid: u32, primary_name: *Name) ?RelationIdentity {
            for (catalog_module.bootstrap_relations) |relation| {
                if (relation.oid != oid or (relation.view == .pg_database and self.catalog.databases == null)) continue;
                return .{ .name = @tagName(relation.view), .namespace = catalog_module.catalog_namespace };
            }
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(self.seq_snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') {
                    const seq = &self.seqs[found.slot];
                    if (seq.oid == oid) return .{ .name = seq.name.slice(), .namespace = seq.namespace };
                    continue;
                }
                const table = &self.tables[found.slot];
                if (table.oid == oid) return .{ .name = table.name.slice(), .namespace = table.namespace };
                if (oid != 0 and S.primaryIndexOid(table) == oid) {
                    primary_name.* = indexName(table) catch return null;
                    return .{ .name = primary_name.slice(), .namespace = table.namespace };
                }
                for (table.indexes[0..table.index_count]) |*index| {
                    if (index.oid != 0 and index.oid == oid) return .{ .name = index.name.slice(), .namespace = table.namespace };
                }
            }
            for (&self.catalog_objects.items) |*object| {
                if (object.kind == .composite_type and O.visible(object, self.seq_snap) and object.compositeRelationOid() == oid) {
                    return .{ .name = object.name.slice(), .namespace = object.target };
                }
            }
            return null;
        }

        fn relationName(ptr: *anyopaque, oid: u32, out: *[64]u8) ?usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            var primary: Name = undefined;
            const identity = self.relationIdentity(oid, &primary) orelse return null;
            if (identity.name.len > out.len) return null;
            @memcpy(out[0..identity.name.len], identity.name);
            return identity.name.len;
        }

        fn relationDisplayName(ptr: *anyopaque, oid: u32, out: []u8) Error!?usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            var primary: Name = undefined;
            const identity = self.relationIdentity(oid, &primary) orelse return null;
            var output: CatalogTextWriter = .{ .out = out, .quote_all = self.session.quote_all_identifiers };
            if (!self.inRelationSearchPath(identity.namespace, identity.name)) {
                output.ident(self.namespaceName(identity.namespace));
                output.add(".");
            }
            output.ident(identity.name);
            if (output.shortened) return error.TextCapacity;
            return output.len;
        }

        fn inRelationSearchPath(self: *const Self, namespace: u32, name: []const u8) bool {
            // The supported relation path resolves pg_catalog before public.
            return namespace == catalog_module.catalog_namespace or
                (self.session.public_schema_on_path and namespace == catalog_module.public_namespace and self.catalog.findSystemView(null, name) == null);
        }

        fn relationVisible(ptr: *anyopaque, oid: u32) ?bool {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            var primary: Name = undefined;
            const identity = self.relationIdentity(oid, &primary) orelse return null;
            return self.inRelationSearchPath(identity.namespace, identity.name);
        }

        fn relationPublishable(ptr: *anyopaque, oid: u32) ?bool {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            if (self.visibleTableSlot(oid, self.seq_snap)) |index| return CO.publicationRelationKind(self.tables[index].relkind);
            if (relationVisible(ptr, oid) != null) return false;
            return null;
        }

        /// pg_get_serial_sequence: the table is regclass text (42P01), the
        /// column an exact attribute name (42703); the result names the
        /// SERIAL or identity sequence the column owns (sequences live in
        /// public), quoted like quote_identifier, or null.
        fn serialSequence(ptr: *anyopaque, table_text: []const u8, column: []const u8, out: *[value_module.serial_name_bytes]u8) Error!?usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const oid = try self.regclassOid(table_text, true);
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(self.seq_snap, &relations);
            var owner: ?*const S.Table = null;
            for (relations[0..count]) |found| {
                if (found.kind == 'S') {
                    // A sequence's own attributes own nothing.
                    if (self.seqs[found.slot].oid != oid) continue;
                    for ([_][]const u8{ "last_value", "log_cnt", "is_called" }) |name| if (types.same(name, column)) return null;
                    return error.ColumnNotFound;
                }
                const table = &self.tables[found.slot];
                if (table.oid == oid) {
                    owner = table;
                    break;
                }
                if (oid != 0 and S.primaryIndexOid(table) == oid) {
                    // The primary-key index: its attributes are the key columns.
                    var key_columns: [config.columns]u8 = undefined;
                    for (primaryColumns(table, &key_columns)) |index| if (types.same(table.columns[index].name.slice(), column)) return null;
                    return error.ColumnNotFound;
                }
            }
            const table = owner orelse return error.TableNotFound;
            const position = for (table.columns[0..table.column_count], 0..) |*entry, index| {
                if (types.same(entry.name.slice(), column)) break index;
            } else return error.ColumnNotFound;
            for (&self.seqs) |*seq| {
                if (!seq.live or seq.owner != table.oid or seq.owner_column != position or seq.dead_csn != 0) continue;
                if (seq.pending_create and seq.creator != self.seq_slot) continue;
                if (seq.pending_drop and seq.creator == self.seq_slot) continue;
                var at: usize = 0;
                for ([_][]const u8{ self.namespaceName(seq.namespace), seq.name.slice() }, 0..) |part, index| {
                    if (2 * part.len + 3 > out.len - at) return error.NameCapacity;
                    if (index != 0) {
                        out[at] = '.';
                        at += 1;
                    }
                    at += quoteIdentifier(part, out[at..], self.session.quote_all_identifiers);
                }
                return at;
            }
            return null;
        }

        /// quote_identifier: quotes unless the name is lower-case letters,
        /// digits and underscores not starting with a digit. `out` holds at
        /// least 2 * name.len + 2 bytes.
        fn quoteIdentifier(name: []const u8, out: []u8, quote_all: bool) usize {
            var safe = !quote_all and name.len != 0 and !types.digit(name[0]) and !lexer.reserved(lexer.classify(name));
            for (name) |byte| {
                if (!((byte >= 'a' and byte <= 'z') or types.digit(byte) or byte == '_')) safe = false;
            }
            if (safe) {
                @memcpy(out[0..name.len], name);
                return name.len;
            }
            var at: usize = 0;
            out[at] = '"';
            at += 1;
            for (name) |byte| {
                out[at] = byte;
                at += 1;
                if (byte == '"') {
                    out[at] = '"';
                    at += 1;
                }
            }
            out[at] = '"';
            return at + 1;
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

        /// A literal nextval default records a normal dependency on the
        /// sequence. pg_dump uses it to order the default after the sequence.
        fn defaultSequence(self: *const Self, pool: *A.Pool, column: *const V.Column, snapshot: Snapshot) ?*const Q.Seq {
            const node_len = pool.len;
            const query_len = pool.query_len;
            const window_len = pool.window_len;
            const complex = pool.complex;
            defer {
                pool.len = node_len;
                pool.query_len = query_len;
                pool.window_len = window_len;
                pool.complex = complex;
            }
            const source = column.expression.slice();
            const id = P.parseExpressionAt(source, 0, source.len, pool) catch return null;
            const call = &pool.nodes[id];
            if (call.kind != .function or call.b == ast.none or
                !types.same(identName(source, call.name).slice(), "nextval") or
                (call.qualifier.len != 0 and !types.same(identName(source, call.qualifier).slice(), "pg_catalog"))) return null;
            const argument = &pool.nodes[call.b];
            if (argument.next != ast.none) return null;
            const literal = if (argument.kind == .cast and argument.typmod == ast.regclass_typmod)
                &pool.nodes[argument.a]
            else
                argument;
            if (literal.kind != .text_literal) return null;
            const text = E.literalText(source, literal.text);
            const raw = text.slice();
            const separator = regclassSeparator(raw);
            const whitespace = " \t\r\n";
            const schema = if (separator) |dot|
                namespaceIdentifier(std.mem.trim(u8, raw[0..dot], whitespace)) catch return null
            else
                null;
            const offset = if (separator) |dot| dot + 1 else 0;
            const name = namespaceIdentifier(std.mem.trim(u8, raw[offset..], whitespace)) catch return null;
            const namespace = namespaceFor(&self.catalog, if (schema) |qualifier| qualifier.slice() else null, snapshot) orelse return null;
            const found = self.catalog.findIn(namespace, name.slice(), snapshot) orelse return null;
            return if (found.kind == 'S') &self.seqs[found.slot] else null;
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
            if (view == .pg_settings) return settingRows(self.sessionState(), sink);
            return self.fillViewRows(&self.session,self.seq_snap,&self.workspace.nodes,view,sink);
        }

        const ClassProperties = struct {
            checks: i64 = 0,
            has_index: bool = false,
            has_rule: bool = false,
            has_trigger: bool = false,
            security: u32 = 0,
            partition: bool = false,
            populated: bool = true,
            partition_bound: Cell = .null_value,
            row_type: u32 = 0,
            owner: u32 = CO.bootstrap_role,
            acl: Cell = .null_value,
        };

        fn classRow(sink: *X.RowSink, oid: u32, name: []const u8, namespace: u32, kind: u8, columns: usize, properties: ClassProperties) Error!void {
            const access: u32 = switch (kind) {
                'r', 'm' => catalog_module.heap_access_method,
                'i', 'I' => catalog_module.btree_access_method,
                else => 0,
            };
            const identity = switch (kind) { 'r', 'p', 'm' => "d", else => "n" };
            // Relations use the database's tablespace and inline value
            // storage. The current engine has no typed table definitions.
            try sink.add(&.{
                intCell(oid), nameCell(name), intCell(namespace), .{ .pg_internal_char = kind }, intCell(@intCast(columns)),
                intCell(properties.checks), boolCell(properties.has_index), boolCell(properties.has_rule), boolCell(properties.has_trigger),
                boolCell(properties.security & CO.rls_enabled != 0), boolCell(properties.security & CO.rls_forced != 0), boolCell(properties.partition),
                intCell(0), intCell(0), nameCell("p"), nameCell(identity), intCell(0), intCell(access), boolCell(properties.populated), properties.partition_bound,
                // This engine does not use pages, visibility maps or native
                // PostgreSQL transaction IDs. It has no ANALYZE row estimate.
                intCell(properties.row_type), intCell(properties.owner), intCell(0), .{ .float4 = -1 },
                intCell(0), intCell(0), intCell(0), intCell(0), properties.acl, .null_value,
            });
        }

        fn tableClass(self: *const Self, table: *const S.Table, snapshot: Snapshot, relations: []const K.Found, session_values: *const value_module.Session, include_acl: bool) Error!ClassProperties {
            var properties: ClassProperties = .{
                .has_index = S.keyed(table) or table.index_count != 0,
                .has_rule = table.relkind == 'v' or table.relkind == 'm',
                .security = self.catalog_objects.securityFlags(table.oid, snapshot),
                .partition = table.parent != 0 and table.partition.bound != .none,
                .populated = table.populated,
                .owner = self.catalog_objects.owner(table.oid, snapshot),
                .acl = if (include_acl) try self.relationAcl(table.oid, snapshot) else .null_value,
            };
            if (properties.partition) properties.partition_bound = try self.partitionBoundText(table, snapshot, session_values);
            for (table.constraints[0..table.constraint_count]) |*constraint| switch (constraint.kind) {
                .check => properties.checks += 1,
                .unique, .exclusion => properties.has_index = true,
                .foreign => properties.has_trigger = true,
                .primary => {},
            };
            for (&self.objects.rules) |*rule| {
                if (rule.live and rule.table_oid == table.oid and rule.stamp.visible(snapshot)) {
                    properties.has_rule = true;
                    break;
                }
            }
            for (&self.objects.triggers) |*trigger| {
                if (trigger.live and trigger.table_oid == table.oid and trigger.stamp.visible(snapshot)) {
                    properties.has_trigger = true;
                    break;
                }
            }
            if (!properties.has_trigger) referenced: for (relations) |relation| {
                if (relation.kind == 'S') continue;
                const child = &self.tables[relation.slot];
                for (child.constraints[0..child.constraint_count]) |*constraint| {
                    if (constraint.kind == .foreign and constraint.ref_oid == table.oid) {
                        properties.has_trigger = true;
                        break :referenced;
                    }
                }
            };
            return properties;
        }

        const AttributeMetadata = struct {
            not_null: bool = false,
            identity: u8 = 0,
            generated: u8 = 0,
            has_expression: bool = false,
            local: bool = true,
        };

        fn attributeRow(sink: *X.RowSink, relation: i64, name: []const u8, data_type: DataType, typmod: i32, ordinal: i64, metadata: AttributeMetadata) Error!void {
            const info = types.typeInfo(data_type);
            // Stock tools see the default settings. RamSQL materializes
            // added columns and has no TOAST, column ACLs or per-column FDW overrides.
            try sink.add(&.{
                intCell(relation), nameCell(name), intCell(info.oid), intCell(typmod), intCell(ordinal),
                boolCell(metadata.not_null), boolCell(false), .{ .pg_internal_char = metadata.identity },
                .{ .pg_internal_char = metadata.generated }, boolCell(metadata.has_expression),
                intCell(collation.typeCollation(types.typeOfData(data_type))), intCell(info.len),
                .{ .pg_internal_char = info.alignment }, intCell(-1), .{ .pg_internal_char = types.typeStorage(data_type) },
                boolCell(metadata.local), .null_value, .null_value, .{ .pg_internal_char = 0 }, boolCell(false), .null_value, .null_value,
            });
        }

        fn attributeIsLocal(self: *const Self, table: *const S.Table, name: []const u8, snapshot: Snapshot) bool {
            if (table.parent == 0) return true;
            if (table.partition.bound != .none) return false;
            const parent_index = self.visibleTableSlot(table.parent, snapshot) orelse return true;
            const parent = &self.tables[parent_index];
            // INHERITS copies the parent's columns and forbids a local
            // column of the same name.
            for (parent.columns[0..parent.column_count]) |*column| {
                if (types.same(column.name.slice(), name)) return false;
            }
            return true;
        }

        fn compositeCatalogRows(self: *const Self, view: catalog_module.View, snapshot: Snapshot, sink: *X.RowSink) Error!void {
            for (&self.catalog_objects.items) |*object| {
                if (object.kind != .composite_type or !O.visible(object, snapshot)) continue;
                const relation = object.compositeRelationOid();
                if (view == .pg_class) {
                    try classRow(sink, relation, object.name.slice(), object.target, 'c', object.composite_field_count, .{ .row_type = object.oid, .owner = object.owner });
                    continue;
                }
                var fields = object.compositeFields();
                var ordinal: i64 = 1;
                while (fields.next()) |field| : (ordinal += 1) {
                    const data_type = types.typeFromOid(field.oid) orelse return error.UndefinedObject;
                    try attributeRow(sink, relation, field.name, data_type, field.typmod, ordinal, .{});
                }
            }
        }

        fn dependencyRow(sink: *X.RowSink, class: u32, object: u32, referenced_class: u32, referenced_object: u32, referenced_subobject: i64, kind: u8) Error!void {
            try sink.add(&.{
                intCell(class), intCell(object), intCell(0), intCell(referenced_class),
                intCell(referenced_object), intCell(referenced_subobject), .{ .pg_internal_char = kind },
            });
        }

        fn singleCatalogArray(data_type: DataType, value: i64) Error!V.Cell {
            var out: V.Text = .{};
            var shape: array_module.Shape = .{ .element = data_type, .ndim = 1 };
            shape.dims[0] = 1;
            var writer = try V.Arrays.Writer.begin(&out, &shape);
            try writer.append(&intCell(value));
            return .{ .array = out };
        }

        fn partitionCatalogRow(self: *const Self, table: *const S.Table, relations: []const K.Found, sink: *X.RowSink) Error!void {
            const strategy: u8 = switch (table.partition.strategy) {
                .none => return,
                .range => 'r',
                .list => 'l',
            };
            const key = table.partition.key;
            const data_type = table.columns[key].data_type;
            const class = index_operator_catalog.lookupDefaultBtreeOid(data_type) orelse 0;
            var default_oid: u32 = 0;
            for (relations) |found| {
                if (found.kind == 'S') continue;
                const child = &self.tables[found.slot];
                if (child.parent != table.oid or child.partition.bound != .default) continue;
                default_oid = child.oid;
                break;
            }
            try sink.add(&.{
                intCell(table.oid), .{ .pg_internal_char = strategy }, intCell(1), intCell(default_oid),
                try singleCatalogArray(.smallint, @as(i64, key) + 1), try singleCatalogArray(.oid, class),
                try singleCatalogArray(.oid, collation.typeCollation(types.typeOfData(data_type))), .null_value,
            });
        }

        /// Derive only dependencies represented by visible stored definitions.
        /// No additional catalog identities or independently versioned rows are needed.
        fn dependencyRows(self: *const Self, session_values: *const value_module.Session, snapshot: Snapshot, pool: *A.Pool, relations: []const K.Found, sink: *X.RowSink) Error!void {
            const relation = CO.class_relation;
            const namespace = CO.class_namespace;
            const constraint_class = catalog_module.constraint_catalog;
            for (relations) |found| {
                if (found.kind == 'S') {
                    const seq = &self.seqs[found.slot];
                    try dependencyRow(sink, relation, seq.oid, namespace, seq.namespace, 0, 'n');
                    if (seq.owner == 0) continue;
                    const slot = self.visibleTableSlot(seq.owner, snapshot) orelse continue;
                    const owner = &self.tables[slot];
                    if (seq.owner_column >= owner.column_count) continue;
                    const kind: u8 = switch (owner.columns[seq.owner_column].default_kind) {
                        .identity_always, .identity_by_default => 'i',
                        else => 'a',
                    };
                    try dependencyRow(sink, relation, seq.oid, relation, owner.oid, @as(i64, seq.owner_column) + 1, kind);
                    continue;
                }
                const table = &self.tables[found.slot];
                try dependencyRow(sink, relation, table.oid, namespace, table.namespace, 0, 'n');
                if (table.relkind == 'v' or table.relkind == 'm') {
                    const rewrite = catalog_module.rewrite_catalog;
                    try dependencyRow(sink, rewrite, table.oid, relation, table.oid, 0, 'i');
                    for (table.depends[0..table.depend_count]) |referenced| {
                        if (referenced != table.oid) try dependencyRow(sink, rewrite, table.oid, relation, referenced, 0, 'n');
                    }
                }
                for (table.columns[0..table.column_count], 1..) |*column, number| {
                    if (column.default_oid == 0) continue;
                    const generated = column.default_kind == .generated;
                    const kind: u8 = if (generated) 'i' else 'a';
                    try dependencyRow(sink, catalog_module.attrdef_catalog, column.default_oid, relation, table.oid, @intCast(number), kind);
                    if (generated) {
                        const context: B.Context = .{ .source = column.expression.slice(), .tables = &self.tables,
                            .catalog = &self.catalog, .snapshot = snapshot, .pool = pool, .legacy = false,
                            .dialect = .postgres, .session = session_values, .routines = &self.objects };
                        const referenced = try B.generatedColumnDependencies(&context, found.slot);
                        for (referenced[0..table.column_count], 1..) |yes, field| {
                            if (yes and field != number) try dependencyRow(sink, catalog_module.attrdef_catalog,
                                column.default_oid, relation, table.oid, @intCast(field), 'n');
                        }
                    } else if (self.defaultSequence(pool, column, snapshot)) |seq| {
                        try dependencyRow(sink, catalog_module.attrdef_catalog, column.default_oid,
                            relation, seq.oid, 0, 'n');
                    }
                }
                if (S.keyed(table) and table.primary_constraint_oid != 0) {
                    const primary_index = S.primaryIndexOid(table);
                    try dependencyRow(sink, relation, primary_index, constraint_class, table.primary_constraint_oid, 0, 'i');
                    var keys: [config.columns]u8 = undefined;
                    for (primaryColumns(table, &keys)) |column| {
                        try dependencyRow(sink, constraint_class, table.primary_constraint_oid, relation, table.oid, @as(i64, column) + 1, 'a');
                    }
                }
                for (table.constraints[0..table.constraint_count]) |*item| {
                    if (item.kind != .foreign or item.oid == 0) continue;
                    if (self.visibleTableSlot(item.ref_oid, snapshot) == null) continue;
                    for (item.keyColumns()) |column| {
                        try dependencyRow(sink, constraint_class, item.oid, relation, table.oid, @as(i64, column) + 1, 'a');
                    }
                    for (item.refColumns()) |column| {
                        try dependencyRow(sink, constraint_class, item.oid, relation, item.ref_oid, @as(i64, column) + 1, 'n');
                    }
                    const index = self.referencedConstraintIndex(item, snapshot);
                    if (index != 0) try dependencyRow(sink, constraint_class, item.oid, relation, index, 0, 'n');
                }
            }
        }

        fn sequenceRows(ptr: *anyopaque, slot: usize, sink: *X.RowSink) Error!void {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            const seq = &self.seqs[slot];
            try sink.add(&.{ intCell(seq.last_value), intCell(seq.log_cnt), boolCell(seq.is_called) });
        }

        fn fillViewRows(self:*const Self,session_values:*const value_module.Session,snapshot:Snapshot,pool:*A.Pool,view:catalog_module.View,sink:*X.RowSink) Error!void {
            const include_class_acl = view == .pg_class and sink.referencesColumn(catalog_module.pg_class_acl_column);
            if (view == .pg_settings) return error.UnsupportedStatement;
            if (view == .sequence_state) return error.UnsupportedStatement;
            // This catalog stores explicit ALTER DEFAULT PRIVILEGES entries.
            // Built-in defaults come from acldefault() and do not create rows.
            if (view == .pg_default_acl) return;
            // Parameter grants have no persisted objects. Stock tools still
            // discover the typed catalog before exporting global roles.
            if (view == .pg_parameter_acl) return;
            // UTF-8 is the only client and server encoding. Identity
            // transfer does not invoke a catalog conversion procedure.
            if (view == .pg_conversion) return;
            // Relation triggers and DDL event triggers have separate catalogs.
            if (view == .pg_event_trigger) return;
            // Publication metadata does not create logical replication subscriptions.
            if (view == .pg_subscription) return;
            if (view == .pg_largeobject) {
                if (!self.catalog_objects.superuser(session_values.role, snapshot)) return error.InsufficientPrivilege;
                const pages = if (self.large_pages) |*store| store else return;
                const include_data = sink.referencesColumn(2);
                var cursor: large_object_pages.Pages.Cursor = .{};
                while (cursor.next(pages, snapshot)) |item| {
                    var data: Cell = .null_value;
                    if (include_data) {
                        data = .{ .bytea = .{} };
                        const bytes = pages.versionBytes(item.version);
                        if (bytes.len > data.bytea.bytes.len) return error.TextCapacity;
                        data.bytea.len = bytes.len;
                        @memcpy(data.bytea.bytes[0..bytes.len], bytes);
                    }
                    try sink.add(&.{ intCell(item.key.oid), intCell(item.key.page), data });
                }
                return;
            }
            // There are no security label providers.
            if (view == .pg_seclabel or view == .pg_shseclabel or view == .pg_seclabels) return;
            // Index comparisons use the store's typed comparator, with no
            // separately registered support-procedure routines.
            if (view == .pg_amproc) return;
            if (view == .pg_amop) {
                for (index_operator_catalog.btree_strategies) |entry| {
                    try sink.add(&.{
                        intCell(entry.oid), intCell(entry.family), intCell(entry.left), intCell(entry.right),
                        intCell(entry.number), .{ .pg_internal_char = 's' }, intCell(entry.operator),
                        intCell(catalog_module.btree_access_method), intCell(0),
                    });
                }
                return;
            }
            if (view == .pg_range) {
                for (catalog_module.ranges) |range| {
                    // Supported subtypes have no collation and no subdiff callback.
                    try sink.add(&.{ intCell(range.oid), intCell(range.subtype), intCell(range.multirange),
                        intCell(0), intCell(range.opclass), .{ .regproc = range.canonical }, .{ .regproc = 0 } });
                }
                return;
            }
            if (view == .pg_init_privs) {
                // These fixed bootstrap ACLs have explicit catalog values.
                const acl = try @import("sql/catalog_acl.sig").Acl(V).ownerAndPublic(CO.bootstrap_name, "UC", "U");
                const class = catalog_module.bootstrapRelationOid(.pg_namespace).?;
                for (catalog_module.namespaces) |namespace| {
                    if (namespace.oid == catalog_module.toast_namespace) continue;
                    try sink.add(&.{ intCell(namespace.oid), intCell(class), intCell(0), .{ .pg_internal_char = 'i' }, acl });
                }
                return;
            }
            if (view == .pg_cast) {
                for (catalog_module.binary_casts) |cast| {
                    try sink.add(&.{ intCell(cast.oid), intCell(types.typeOid(cast.source)), intCell(types.typeOid(cast.target)), intCell(0), .{ .pg_internal_char = 'i' }, .{ .pg_internal_char = 'b' } });
                }
                return;
            }
            // SQL and PL/pgSQL use the ordinary SQL representation directly.
            // The runtime supports no language-specific transform registration.
            if (view == .pg_transform) return;
            if (view == .pg_operator) {
                for (operator_catalog.operators) |op| {
                    // Commutators and negators link to supported signatures.
                    // Native planner estimator hooks are not part of this engine.
                    try sink.add(&.{
                        intCell(op.oid), nameCell(op.name), intCell(catalog_module.catalog_namespace), intCell(CO.bootstrap_role),
                        .{ .pg_internal_char = if (op.left == 0) 'l' else 'b' }, boolCell(false), boolCell(false),
                        intCell(op.left), intCell(op.right), intCell(op.result), intCell(op.commutator), intCell(op.negator),
                        .{ .regproc = op.function_oid }, .{ .regproc = 0 }, .{ .regproc = 0 },
                    });
                }
                return;
            }
            if (view == .pg_opclass or view == .pg_opfamily) {
                const method = intCell(catalog_module.btree_access_method);
                const namespace = intCell(catalog_module.catalog_namespace);
                const owner = intCell(CO.bootstrap_role);
                for (index_operator_catalog.btree_families) |family| {
                    if (view == .pg_opfamily) {
                        try sink.add(&.{ intCell(family.oid), method, nameCell(family.name), namespace, owner });
                        continue;
                    }
                    for (family.classes) |class| {
                        try sink.add(&.{ intCell(class.oid), method, nameCell(class.name), namespace, owner,
                            intCell(family.oid), intCell(types.typeOid(class.input)), boolCell(true), intCell(0) });
                    }
                }
                return;
            }
            if (view == .pg_ts_parser) {
                const parser = catalog_module.text_parser;
                // Headline generation is unavailable, so it has no callback.
                try sink.add(&.{
                    intCell(parser.oid), nameCell(parser.name), intCell(catalog_module.catalog_namespace),
                    .{ .regproc = parser.start.oid }, .{ .regproc = parser.next.oid }, .{ .regproc = parser.end.oid },
                    .{ .regproc = 0 }, .{ .regproc = parser.lex_type.oid },
                });
                return;
            }
            if (view == .pg_ts_template) {
                const template = catalog_module.simple_template;
                try sink.add(&.{ intCell(template.oid), nameCell(template.name), intCell(catalog_module.catalog_namespace),
                    .{ .regproc = template.init.oid }, .{ .regproc = template.lexize.oid } });
                return;
            }
            if (view == .pg_ts_dict) {
                const dictionary = catalog_module.simple_dictionary;
                try sink.add(&.{ intCell(dictionary.oid), nameCell(dictionary.name), intCell(catalog_module.catalog_namespace),
                    intCell(CO.bootstrap_role), intCell(dictionary.template_oid), .null_value });
                return;
            }
            if (view == .pg_ts_config) {
                const configuration = catalog_module.simple_configuration;
                try sink.add(&.{ intCell(configuration.oid), nameCell(configuration.name), intCell(catalog_module.catalog_namespace),
                    intCell(CO.bootstrap_role), intCell(configuration.parser_oid) });
                return;
            }
            if (view == .pg_language) {
                try sink.add(&.{ intCell(operator_catalog.internal_language_oid), nameCell("internal"), intCell(CO.bootstrap_role), boolCell(false), boolCell(false), intCell(0), intCell(0), intCell(0), .null_value });
                try sink.add(&.{ intCell(catalog_module.sql_language_oid), nameCell("sql"), intCell(CO.bootstrap_role), boolCell(false), boolCell(true), intCell(0), intCell(0), intCell(0), .null_value });
                try sink.add(&.{ intCell(catalog_module.plpgsql_language_oid), nameCell("plpgsql"), intCell(CO.bootstrap_role), boolCell(true), boolCell(true), intCell(0), intCell(0), intCell(0), .null_value });
                return;
            }
            if (view == .pg_tablespace) {
                // Only the implicit database and shared catalog placements
                // are supported. Relations use the implicit placement.
                try sink.add(&.{ intCell(catalog_module.default_tablespace), nameCell("pg_default"), intCell(CO.bootstrap_role), .null_value, .null_value });
                try sink.add(&.{ intCell(catalog_module.global_tablespace), nameCell("pg_global"), intCell(CO.bootstrap_role), .null_value, .null_value });
                return;
            }
            // SQL cannot install foreign tables. FDWs and foreign servers
            // have their own catalogs and do not imply a table binding.
            if (view == .pg_foreign_table) return;
            if (view == .pg_am) {
                for (catalog_module.access_methods) |am| {
                    try sink.add(&.{ intCell(am.oid), nameCell(am.name), .{ .regproc = am.handler }, .{ .pg_internal_char = am.kind } });
                }
                return;
            }
            if (view == .pg_collation) {
                for (collation.names, collation.oids) |name, oid| {
                    const native_provider = switch (oid) { 100 => "d", 962 => "b", else => "c" };
                    const encoding: i64 = if (oid == 962) 6 else -1;
                    try sink.add(&.{ intCell(oid), nameCell(name), intCell(catalog_module.catalog_namespace), intCell(CO.bootstrap_role), nameCell(native_provider), boolCell(true), intCell(encoding) });
                }
                return;
            }
            if (view == .pg_database) {
                const provider = self.catalog.databases orelse return error.TableNotFound;
                for (0..provider.capacity) |index| {
                    const entry = provider.row(provider.context, index) orelse continue;
                    const name = if (provider.use_session_database_name) session_values.database else entry.name;
                    // The engine uses UTF-8, bytewise ordering and the default tablespace.
                    // Rows do not have PostgreSQL physical transaction freeze horizons.
                    try sink.add(&.{
                        intCell(entry.oid), try objectTextCell(name), intCell(entry.owner), intCell(catalog_module.utf8_encoding),
                        .{ .pg_internal_char = 'c' }, boolCell(entry.is_template), boolCell(entry.allow_connections),
                        intCell(-1), intCell(0), intCell(0), intCell(catalog_module.default_tablespace),
                        nameCell("C"), nameCell("C"), .null_value, .null_value,
                        .null_value, .null_value, .null_value,
                    });
                }
                return;
            }
            const database = session_values.database;
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snapshot, &relations);
            if (view == .pg_class or view == .pg_attribute) try self.compositeCatalogRows(view, snapshot, sink);
            switch (view) {
                .pg_proc, .pg_trigger, .pg_rewrite, .pg_rules => return self.objectViewRows(snapshot, view, sink),
                .pg_depend => return self.dependencyRows(session_values, snapshot, pool, relations[0..count], sink),
                .pg_type => {
                    for (catalog_module.builtin_pseudo_types) |info| {
                        try sink.add(&.{ intCell(info.oid), nameCell(info.name), intCell(catalog_module.catalog_namespace), intCell(info.bytes), .{ .pg_internal_char = 'p' }, nameCell("P"), intCell(0), nameCell(","), nameCell(info.input), intCell(0), intCell(0), intCell(CO.bootstrap_role), intCell(-1), boolCell(false), intCell(0), intCell(0), .null_value, boolCell(true), .{ .pg_internal_char = info.storage } });
                    }
                    inline for (@typeInfo(DataType).@"enum".field_names) |field| {
                        const data_type = @field(DataType, field);
                        if (data_type == .mysql_bigint_unsigned) continue;
                        const info = types.typeInfo(data_type);
                        const category: [1]u8 = .{info.category};
                        const type_collation = intCell(collation.typeCollation(types.typeOfData(data_type)));
                        const kind: u8 = if (types.rangeSubtype(types.typeOfData(data_type)) != null) 'r' else 'b';
                        try sink.add(&.{ intCell(info.oid), nameCell(info.name), intCell(catalog_module.catalog_namespace), intCell(info.len), .{ .pg_internal_char = kind }, nameCell(&category), intCell(info.array), nameCell(","), nameCell(types.typeInputName(data_type)), intCell(0), intCell(0), intCell(CO.bootstrap_role), intCell(-1), boolCell(false), intCell(0), type_collation, .null_value, boolCell(true), .{ .pg_internal_char = types.typeStorage(data_type) } });
                        if (types.arrayData(data_type)) |array_type| {
                            const array_info = types.typeInfo(array_type);
                            try sink.add(&.{ intCell(array_info.oid), nameCell(array_info.name), intCell(catalog_module.catalog_namespace), intCell(array_info.len), .{ .pg_internal_char = 'b' }, nameCell("A"), intCell(0), nameCell(","), nameCell(types.typeInputName(array_type)), intCell(0), intCell(info.oid), intCell(CO.bootstrap_role), intCell(-1), boolCell(false), intCell(0), type_collation, .null_value, boolCell(true), .{ .pg_internal_char = types.typeStorage(array_type) } });
                        }
                    }
                    for (&self.catalog_objects.items) |*object| {
                        if (!CO.userType(object.kind) or !O.visible(object, snapshot)) continue;
                        const type_collation = intCell(if (object.kind == .domain) collation.typeCollation(object.domain.base) else 0);
                        switch (object.kind) {
                            .domain => {
                                const info = types.typeInfo(types.dataTypeOf(object.domain.base));
                                try sink.add(&.{ intCell(object.oid), nameCell(object.name.slice()), intCell(object.target), intCell(info.len), .{ .pg_internal_char = 'd' }, nameCell("N"), intCell(object.oid + 1), nameCell(","), nameCell("domain_in"), intCell(info.oid), intCell(0), intCell(object.owner), intCell(-1), boolCell(object.domain.not_null), intCell(0), type_collation, .null_value, boolCell(true), .{ .pg_internal_char = types.typeStorage(types.dataTypeOf(object.domain.base)) } });
                            },
                            .enum_type => try sink.add(&.{ intCell(object.oid), nameCell(object.name.slice()), intCell(object.target), intCell(4), .{ .pg_internal_char = 'e' }, nameCell("E"), intCell(object.oid + 1), nameCell(","), nameCell("enum_in"), intCell(0), intCell(0), intCell(object.owner), intCell(-1), boolCell(false), intCell(0), type_collation, .null_value, boolCell(true), .{ .pg_internal_char = 'p' } }),
                            .composite_type => try sink.add(&.{ intCell(object.oid), nameCell(object.name.slice()), intCell(object.target), intCell(-1), .{ .pg_internal_char = 'c' }, nameCell("C"), intCell(object.oid + 1), nameCell(","), nameCell("record_in"), intCell(0), intCell(0), intCell(object.owner), intCell(-1), boolCell(false), intCell(object.compositeRelationOid()), type_collation, .null_value, boolCell(true), .{ .pg_internal_char = 'x' } }),
                            else => unreachable,
                        }
                        try sink.add(&.{ intCell(object.oid + 1), nameCell(object.arrayName()), intCell(object.target), intCell(-1), .{ .pg_internal_char = 'b' }, nameCell("A"), intCell(0), nameCell(","), nameCell("array_in"), intCell(0), intCell(object.oid), intCell(object.owner), intCell(-1), boolCell(false), intCell(0), type_collation, .null_value, boolCell(true), .{ .pg_internal_char = 'x' } });
                    }
                },
                .pg_enum => for (&self.catalog_objects.items) |*object| {
                    if (object.kind != .enum_type or !O.visible(object, snapshot)) continue;
                    var labels = object.enumLabels();
                    var order: u32 = 1;
                    while (labels.next()) |label| : (order += 1) {
                        try sink.add(&.{ intCell(object.oid + 1 + order), intCell(object.oid), .{ .float4 = @floatFromInt(order) }, nameCell(label) });
                    }
                },
                .pg_largeobject_metadata, .pg_roles, .pg_authid, .pg_auth_members, .pg_db_role_setting, .pg_policy, .pg_policies, .pg_description, .pg_shdescription, .pg_foreign_data_wrapper, .pg_foreign_server, .pg_publication, .pg_publication_rel, .pg_publication_namespace, .pg_statistic_ext, .pg_extension, .pg_tables, .table_privileges => return self.catalogObjectRows(session_values, snapshot, view, sink),
                .pg_namespace, .schemata => {
                    const include_acl = view == .pg_namespace and sink.referencesColumn(catalog_module.pg_namespace_acl_column);
                    for (catalog_module.namespaces) |namespace| {
                        if (view == .pg_namespace) {
                            const acl = if (!include_acl or namespace.oid == catalog_module.toast_namespace) .null_value else
                                try @import("sql/catalog_acl.sig").Acl(V).ownerAndPublic(CO.bootstrap_name, "UC", "U");
                            try sink.add(&.{ intCell(namespace.oid), nameCell(namespace.name), intCell(CO.bootstrap_role), acl });
                        } else try sink.add(&.{ nameCell(database), nameCell(namespace.name) });
                    }
                    var schemas: [K.relation_rows]K.SchemaFound = undefined;
                    const schema_count = self.catalog.visibleSchemas(snapshot, &schemas);
                    for (schemas[0..schema_count]) |found| {
                        const schema = &self.schemas[found.slot];
                        if (view == .pg_namespace) {
                            const owner = self.schemaOwner(schema, snapshot);
                            try sink.add(&.{ intCell(found.oid), nameCell(schema.name.slice()), intCell(owner),
                                if (include_acl) try self.namespaceAcl(found.oid, owner, snapshot) else .null_value });
                        } else try sink.add(&.{ nameCell(database), nameCell(schema.name.slice()) });
                    }
                },
                else => for (relations[0..count]) |found| {
                    if (found.kind == 'S') {
                        const seq = &self.seqs[found.slot];
                        switch (view) {
                            .pg_class => try classRow(sink, seq.oid, seq.name.slice(), seq.namespace, 'S', 3,
                                .{ .owner = if (seq.owner == 0) CO.bootstrap_role else self.catalog_objects.owner(seq.owner, snapshot) }),
                            .pg_sequence => try sink.add(&.{ intCell(seq.oid), intCell(seq.spec.type_oid), intCell(seq.spec.start), intCell(seq.spec.increment), intCell(seq.spec.max), intCell(seq.spec.min), intCell(seq.spec.cache), boolCell(seq.spec.cycle) }),
                            else => {},
                        }
                        continue;
                    }
                    const table = &self.tables[found.slot];
                    // PostgreSQL's information-schema views use different
                    // privilege lists. This engine supports table-wide grants.
                    const column_privileges = CO.priv_select | CO.priv_insert | CO.priv_update | CO.priv_references;
                    const constraint_privileges = CO.priv_insert | CO.priv_update | CO.priv_delete |
                        CO.priv_truncate | CO.priv_references | CO.priv_trigger;
                    const discovery_privileges: u32 = switch (view) {
                        .tables, .columns => switch (table.relkind) {
                            'r', 'v', 'f', 'p' => if (view == .tables) constraint_privileges | CO.priv_select else column_privileges,
                            else => continue,
                        },
                        .table_constraints, .key_column_usage => switch (table.relkind) {
                            'r', 'p' => if (view == .table_constraints) constraint_privileges else column_privileges,
                            else => continue,
                        },
                        else => 0,
                    };
                    if (discovery_privileges != 0 and !self.catalog_objects.tableHasAnyPrivilege(
                        session_values.role, table.oid, discovery_privileges, snapshot,
                    )) continue;
                    const schema_name = self.namespaceName(table.namespace);
                    const name = table.name.slice();
                    const oid: i64 = table.oid;
                    const pkey = indexName(table) catch Name{};
                    var key_columns: [config.columns]u8 = undefined;
                    const primary_columns = primaryColumns(table, &key_columns);
                    switch (view) {
                        .pg_partitioned_table => if (table.relkind == 'p') try self.partitionCatalogRow(table, relations[0..count], sink),
                        .pg_class => {
                            try classRow(sink, table.oid, name, table.namespace, table.relkind, table.column_count, try self.tableClass(table, snapshot, relations[0..count], session_values, include_class_acl));
                            if (S.keyed(table)) try classRow(sink, S.primaryIndexOid(table), pkey.slice(), table.namespace, 'i', primary_columns.len, .{ .owner = self.catalog_objects.owner(table.oid, snapshot) });
                            for (table.indexes[0..table.index_count]) |*index| {
                                if (index.oid == 0) continue;
                                try classRow(sink, index.oid, index.name.slice(), table.namespace, 'i', index.key_count + index.include_count, .{ .owner = self.catalog_objects.owner(table.oid, snapshot) });
                            }
                        },
                        .tables => {
                            const table_type: []const u8 = switch (table.relkind) {
                                'v' => "VIEW",
                                'f' => "FOREIGN",
                                else => "BASE TABLE",
                            };
                            try sink.add(&.{ nameCell(database), nameCell(schema_name), nameCell(name), nameCell(table_type) });
                        },
                        .pg_index => {
                            if (S.keyed(table)) try indexCatalogRow(sink, S.primaryIndexOid(table), oid, primary_columns, null);
                            for (table.indexes[0..table.index_count]) |*index| {
                                if (index.oid == 0) continue;
                                try indexCatalogRow(sink, index.oid, oid, index.keyColumns(), index);
                            }
                        },
                        .pg_constraint => {
                            const primary = if (S.primaryConstraint(table)) |position| &table.constraints[position] else null;
                            if (table.primary_constraint_oid != 0) {
                                try self.constraintRow(sink, table, table.primary_constraint_oid, pkey.slice(), primary, .primary, snapshot);
                            }
                            for (table.constraints[0..table.constraint_count]) |*constraint| {
                                if (constraint.kind == .primary) continue;
                                try self.constraintRow(sink, table, constraint.oid, constraint.name.slice(), constraint, constraint.kind, snapshot);
                            }
                        },
                        .pg_indexes => {
                            var text: [512]u8 = undefined;
                            const quote_all = session_values.quote_all_identifiers;
                            if (S.keyed(table)) try sink.add(&.{ nameCell(schema_name), nameCell(name), nameCell(pkey.slice()), .null_value, nameCell(indexDefinition(table, schema_name, pkey.slice(), true, primary_columns, &text, quote_all)) });
                            for (table.constraints[0..table.constraint_count]) |*constraint| {
                                if (constraint.kind != .unique) continue;
                                try sink.add(&.{ nameCell(schema_name), nameCell(name), nameCell(constraint.name.slice()), .null_value, nameCell(indexDefinition(table, schema_name, constraint.name.slice(), true, constraint.keyColumns(), &text, quote_all)) });
                            }
                            for (table.indexes[0..table.index_count]) |*index| {
                                try sink.add(&.{ nameCell(schema_name), nameCell(name), nameCell(index.name.slice()), .null_value, nameCell(secondaryDefinition(table, schema_name, index, &text, quote_all)) });
                            }
                            for (table.constraints[0..table.constraint_count]) |*constraint| {
                                if (constraint.kind != .exclusion) continue;
                                var definition: CatalogTextWriter = .{ .out = &text, .quote_all = quote_all };
                                definition.add("CREATE INDEX ");
                                definition.ident(constraint.name.slice());
                                definition.add(" ON ");
                                definition.ident(schema_name);
                                definition.add(".");
                                definition.ident(name);
                                definition.add(" USING ");
                                definition.ident("gist");
                                definition.add(" (");
                                for (constraint.keyColumns(), 0..) |column, position| {
                                    if (position != 0) definition.add(", ");
                                    definition.ident(table.columns[column].name.slice());
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
                            const identity: u8 = switch (kind) {
                                .identity_always => 'a',
                                .identity_by_default => 'd',
                                else => 0,
                            };
                            const has_expression = kind == .default or kind == .generated;
                            switch (view) {
                                .pg_attribute => {
                                    try attributeRow(sink, oid, column.name.slice(), column.data_type, column.typmod, attnum, .{
                                        .not_null = column.not_null,
                                        .identity = identity,
                                        .generated = if (kind != .generated) 0 else if (column.virtual) 'v' else 's',
                                        .has_expression = has_expression,
                                        .local = self.attributeIsLocal(table, column.name.slice(), snapshot),
                                    });
                                },
                                .pg_attrdef => if (has_expression) {
                                    var expression = expressionTextWithPool(pool, column);
                                    if (kind == .default and !session_values.public_schema_on_path) {
                                        if (self.defaultSequence(pool, column, snapshot)) |seq| {
                                            if (seq.namespace == catalog_module.public_namespace)
                                                expression = .{ .text = try B.serialDefault("public", seq.name) };
                                        }
                                    }
                                    try sink.add(&.{ intCell(oid), intCell(attnum), expression, intCell(column.default_oid) });
                                },
                                .columns => {
                                    const numeric = numericPrecision(column);
                                    try sink.add(&.{
                                        nameCell(database),                                       nameCell(schema_name),                          nameCell(name),            nameCell(column.name.slice()),
                                        intCell(attnum),                                          if (kind == .default) expressionTextWithPool(pool,column) else .null_value, nameCell(if (column.not_null) "NO" else "YES"), nameCell(if (types.elementData(column.data_type) != null) "ARRAY" else types.sqlTypeName(column.data_type)),
                                        optionalInt(characterMaximumLength(column)),              optionalInt(numeric[0]),                     optionalInt(numeric[1]),   optionalInt(numeric[2]),
                                        optionalInt(datetimePrecision(column)),                   nameCell(if (identity != 0) "YES" else "NO"), if (identity == 0) .null_value else nameCell(if (kind == .identity_always) "ALWAYS" else "BY DEFAULT"), nameCell(if (kind == .generated) "ALWAYS" else "NEVER"),
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
        fn indexDefinition(table: *const S.Table, schema_name: []const u8, index_name: []const u8, unique: bool, columns: []const u8, out: *[512]u8, quote_all: bool) []const u8 {
            var text: CatalogTextWriter = .{ .out = out, .quote_all = quote_all };
            writeIndexDefinition(table, schema_name, index_name, unique, columns, null, false, &text);
            return text.slice();
        }

        /// pg_indexes.indexdef of a secondary index (expression elements and
        /// the predicate are their stored source texts).
        fn secondaryDefinition(table: *const S.Table, schema_name: []const u8, index: *const S.Index, out: *[512]u8, quote_all: bool) []const u8 {
            var text: CatalogTextWriter = .{ .out = out, .quote_all = quote_all };
            writeIndexDefinition(table, schema_name, index.name.slice(), index.unique, index.keyColumns(), index, false, &text);
            return text.slice();
        }

        fn writeIndexDefinition(table: *const S.Table, schema: ?[]const u8, index_name: []const u8, unique: bool, keys: []const u8, index: ?*const S.Index, pretty: bool, text: *CatalogTextWriter) void {
            text.add(if (unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
            text.ident(index_name);
            text.add(" ON ");
            if (schema) |name| {
                text.ident(name);
                text.add(".");
            }
            text.ident(table.name.slice());
            text.add(" USING ");
            text.ident("btree");
            text.add(" (");
            var expressions = if (index) |secondary| secondary.expressions.slice() else &.{};
            for (keys, 0..) |column, position| {
                if (position != 0) text.add(", ");
                writeIndexKey(table, column, &expressions, text);
                if (index) |secondary| {
                    const descending = secondary.options[position] & 1 != 0;
                    const nulls_first = secondary.options[position] & 2 != 0;
                    if (descending) text.add(" DESC");
                    if (nulls_first and !descending) text.add(" NULLS FIRST");
                    if (!nulls_first and descending) text.add(" NULLS LAST");
                }
            }
            text.add(")");
            const secondary = index orelse return;
            if (secondary.include_count != 0) {
                text.add(" INCLUDE (");
                for (secondary.includes[0..secondary.include_count], 0..) |column, position| {
                    if (position != 0) text.add(", ");
                    text.ident(table.columns[column].name.slice());
                }
                text.add(")");
            }
            if (secondary.nulls_not_distinct) text.add(" NULLS NOT DISTINCT");
            if (secondary.predicate.len != 0) {
                text.add(if (pretty) " WHERE " else " WHERE (");
                text.add(secondary.predicate.slice());
                if (!pretty) text.add(")");
            }
        }

        fn takeIndexExpression(expressions: *[]const u8) []const u8 {
            const source = expressions.*;
            const end = std.mem.indexOfScalar(u8, source, 0) orelse source.len;
            expressions.* = if (end == source.len) &.{} else source[end + 1 ..];
            return source[0..end];
        }

        fn writeIndexKey(table: *const S.Table, column: u8, expressions: *[]const u8, text: *CatalogTextWriter) void {
            if (column == S.expression_key) {
                text.add("(");
                text.add(takeIndexExpression(expressions));
                text.add(")");
            } else text.ident(table.columns[column].name.slice());
        }

        fn postgresIndexDefinition(ptr: *anyopaque, oid: u32, column: i32, pretty: bool, out: []u8) Error!?usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(self.seq_snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') continue;
                const table = &self.tables[found.slot];
                if (oid != 0 and S.primaryIndexOid(table) == oid) {
                    var columns: [config.columns]u8 = undefined;
                    const name = try indexName(table);
                    return try self.renderIndex(table, name.slice(), true, primaryColumns(table, &columns), null, column, pretty, out);
                }
                for (table.indexes[0..table.index_count]) |*index| {
                    if (index.oid != 0 and index.oid == oid) {
                        return try self.renderIndex(table, index.name.slice(), index.unique, index.keyColumns(), index, column, pretty, out);
                    }
                }
            }
            return null;
        }

        fn foreignActionCode(action: S.ForeignAction) []const u8 {
            return switch (action) { .no_action => "a", .restrict => "r", .cascade => "c", .set_null => "n", .set_default => "d" };
        }

        fn foreignActionText(action: S.ForeignAction) []const u8 {
            return switch (action) { .no_action => "NO ACTION", .restrict => "RESTRICT", .cascade => "CASCADE", .set_null => "SET NULL", .set_default => "SET DEFAULT" };
        }

        fn constraintRow(self: *const Self, sink: *X.RowSink, table: *const S.Table, oid: u32, name: []const u8, constraint: ?*const S.Constraint, kind: S.ConstraintKind, snapshot: Snapshot) Error!void {
            const label = switch (kind) { .check => "c", .unique => "u", .primary => "p", .foreign => "f", .exclusion => "x" };
            const deferrable = if (constraint) |item| item.deferrable else false;
            const deferred = if (constraint) |item| item.initially_deferred else false;
            const foreign = if (kind == .foreign) constraint else null;
            const index = if (kind == .primary) S.primaryIndexOid(table) else if (foreign) |item| self.referencedConstraintIndex(item, snapshot) else 0;
            try sink.add(&.{
                intCell(oid), nameCell(name), intCell(table.namespace), nameCell(label),
                boolCell(deferrable), boolCell(deferred), boolCell(true), boolCell(true),
                intCell(table.oid), intCell(0), intCell(index), intCell(0),
                intCell(if (foreign) |item| item.ref_oid else 0),
                nameCell(if (foreign) |item| foreignActionCode(item.on_update) else " "),
                nameCell(if (foreign) |item| foreignActionCode(item.on_delete) else " "),
                nameCell(if (foreign != null) "s" else " "), boolCell(false),
                boolCell(kind != .check or self.checkConstraintIsLocal(table, name, snapshot)),
            });
        }

        fn checkConstraintIsLocal(self: *const Self, table: *const S.Table, name: []const u8, snapshot: Snapshot) bool {
            if (table.parent == 0) return true;
            const slot = self.visibleTableSlot(table.parent, snapshot) orelse return true;
            const parent = &self.tables[slot];
            for (parent.constraints[0..parent.constraint_count]) |*constraint| {
                if (constraint.kind == .check and types.same(constraint.name.slice(), name)) return false;
            }
            return true;
        }

        fn sameIndexKeys(expected: []const u8, actual: []const u8) bool {
            if (expected.len != actual.len) return false;
            for (expected) |column| {
                if (std.mem.indexOfScalar(u8, actual, column) == null) return false;
            }
            return true;
        }

        fn referencedConstraintIndex(self: *const Self, constraint: *const S.Constraint, snapshot: Snapshot) u32 {
            const slot = self.visibleTableSlot(constraint.ref_oid, snapshot) orelse return 0;
            const parent = &self.tables[slot];
            var keys: [config.columns]u8 = undefined;
            if (sameIndexKeys(constraint.refColumns(), primaryColumns(parent, &keys))) return S.primaryIndexOid(parent);
            for (parent.indexes[0..parent.index_count]) |*index| {
                if (index.unique and index.predicate.len == 0 and sameIndexKeys(constraint.refColumns(), index.keyColumns())) return index.oid;
            }
            return 0;
        }

        fn writeConstraintColumns(table: *const S.Table, columns: []const u8, text: *CatalogTextWriter) void {
            text.add("(");
            for (columns, 0..) |column, position| {
                if (position != 0) text.add(", ");
                text.ident(table.columns[column].name.slice());
            }
            text.add(")");
        }

        fn postgresStatisticsColumns(ptr: *anyopaque, oid: u32, out: []u8) Error!?usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            const index = self.catalog_objects.byOid(.statistics, oid, self.seq_snap) orelse return null;
            const object = &self.catalog_objects.items[index];
            const slot = self.visibleTableSlot(object.grantee, self.seq_snap) orelse return null;
            const table = &self.tables[slot];
            var text: CatalogTextWriter = .{ .out = out, .quote_all = self.session.quote_all_identifiers };
            for (object.textSlice(), 0..) |column, position| {
                if (position != 0) text.add(", ");
                text.ident(table.columns[column].name.slice());
            }
            if (text.shortened) return error.TextCapacity;
            return text.len;
        }

        fn postgresPartitionKey(ptr: *anyopaque, oid: u32, out: []u8) Error!?usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            const index = self.visibleTableSlot(oid, self.seq_snap) orelse return null;
            const table = &self.tables[index];
            const prefix = switch (table.partition.strategy) {
                .none => return null,
                .range => "RANGE (",
                .list => "LIST (",
            };
            var text: CatalogTextWriter = .{ .out = out, .quote_all = self.session.quote_all_identifiers };
            text.add(prefix);
            text.ident(table.columns[table.partition.key].name.slice());
            text.add(")");
            if (text.shortened) return error.TextCapacity;
            return text.len;
        }

        fn postgresConstraintDefinition(ptr: *anyopaque, oid: u32, pretty: bool, out: []u8) Error!?usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(self.seq_snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') continue;
                const table = &self.tables[found.slot];
                if (oid != 0 and table.primary_constraint_oid == oid) {
                    const primary = if (S.primaryConstraint(table)) |position| &table.constraints[position] else null;
                    return try self.renderConstraint(table, primary, .primary, pretty, out);
                }
                for (table.constraints[0..table.constraint_count]) |*constraint| {
                    if (oid != 0 and constraint.oid == oid) {
                        return try self.renderConstraint(table, constraint, constraint.kind, pretty, out);
                    }
                }
            }
            return null;
        }

        const ViewAliasEdit = struct { start: usize, end: usize, column: usize };

        /// Projection aliases can be replaced directly where no clause
        /// resolves names against the SELECT list. Keep the raw expressions
        /// and FROM items so dependent views retain their original shape.
        fn viewAliasEdits(source: []const u8, pool: *const A.Pool, root: *const A.Select, view: *const S.Table, edits: *[config.columns]ViewAliasEdit) usize {
            if (root.set_op != .none or root.values != ast.none or root.count != view.column_count or
                root.order_count != 0 or root.group_count != 0 or root.grouping_sets != ast.none or
                root.distinct_on_count != 0)
                return 0;
            for (root.targets[0..root.count]) |projection| {
                if (projection.star or projection.expression_end == 0) return 0;
            }
            var count: usize = 0;
            for (root.targets[0..root.count], view.columns[0..view.column_count], 0..) |projection, *column, index| {
                const node = &pool.nodes[projection.expr];
                if (projection.alias) |alias| {
                    if (std.mem.eql(u8, identName(source, alias).slice(), column.name.slice())) continue;
                    const quote: usize = @intFromBool(alias.quoted);
                    edits[count] = .{ .start = alias.span.start - quote, .end = alias.span.start + alias.span.len + quote, .column = index };
                } else {
                    const matches = switch (node.kind) {
                        .column => std.mem.eql(u8, identName(source, node.name).slice(), column.name.slice()),
                        .int_literal, .decimal_literal, .text_literal, .bool_literal, .null_literal, .binary =>
                        std.mem.eql(u8, "?column?", column.name.slice()),
                        else => continue,
                    };
                    if (matches) continue;
                    edits[count] = .{ .start = projection.expression_end, .end = projection.expression_end, .column = index };
                }
                count += 1;
            }
            return count;
        }

        fn postgresViewDefinition(ptr: *anyopaque, oid: u32, _: bool, out: []u8) Error!?usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const slot = self.visibleTableSlot(oid, self.seq_snap) orelse return null;
            const view = &self.tables[slot];
            if (view.relkind != 'v' and view.relkind != 'm') return null;
            const source = view.query.slice();
            const pool = &self.workspace.nodes;
            const node_len = pool.len;
            const query_len = pool.query_len;
            const window_len = pool.window_len;
            const complex = pool.complex;
            defer {
                pool.len = node_len;
                pool.query_len = query_len;
                pool.window_len = window_len;
                pool.complex = complex;
            }
            const root = try P.parseQueryAt(source, 0, source.len, pool);
            const blocks = pool.queries[query_len..pool.query_len];
            var changes: std.StaticBitSet(config.text_bytes + 1) = .empty;
            for (blocks) |*block| for (block.items[0..block.item_count]) |*item| {
                if (item.schema != null or item.query != ast.none or item.function != ast.none or item.name.len == 0) continue;
                const name = identName(source, item.name);
                if (self.catalog.findSystemView(null, name.slice()) != null) continue;
                // A CTE can shadow a public relation. Preserve its spelling
                // even if a separate reference depends on that relation.
                var cte = false;
                for (blocks) |*other| for (other.ctes[0..other.cte_count]) |*definition| {
                    cte = cte or types.same(identName(source, definition.name).slice(), name.slice());
                };
                if (cte) continue;
                const relation = self.catalog.findIn(catalog_module.public_namespace, name.slice(), self.seq_snap) orelse continue;
                if (relation.kind == 'S') continue;
                const dependency = self.tables[relation.slot].oid;
                for (view.depends[0..view.depend_count]) |oid_ref| {
                    if (oid_ref != dependency) continue;
                    changes.set(item.name.span.start - @intFromBool(item.name.quoted));
                    break;
                }
            };
            var aliases: [config.columns]ViewAliasEdit = undefined;
            const alias_count = viewAliasEdits(source, pool, &pool.queries[root], view, &aliases);
            for (aliases[0..alias_count]) |edit| changes.set(edit.start);
            var text: CatalogTextWriter = .{ .out = out, .quote_all = self.session.quote_all_identifiers };
            var start: usize = 0;
            var alias_index: usize = 0;
            var positions = changes.iterator(.{});
            while (positions.next()) |position| {
                text.add(source[start..position]);
                start = position;
                if (alias_index < alias_count and aliases[alias_index].start == position) {
                    const edit = aliases[alias_index];
                    if (edit.start == edit.end) text.add(" AS ");
                    text.ident(view.columns[edit.column].name.slice());
                    if (edit.start == edit.end and edit.end < source.len and
                        (types.digit(source[edit.end]) or types.lower(source[edit.end]) >= 'a' and types.lower(source[edit.end]) <= 'z'))
                        text.add(" ");
                    start = edit.end;
                    alias_index += 1;
                } else {
                    text.ident("public");
                    text.add(".");
                }
            }
            text.add(source[start..]);
            text.add("\n;");
            if (text.shortened) return error.TextCapacity;
            return text.len;
        }

        fn postgresTriggerDefinition(ptr: *anyopaque, oid: u32, pretty: bool, out: []u8) Error!?usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            const snapshot = self.seq_snap;
            for (&self.objects.triggers) |*trigger| {
                if (!trigger.live or trigger.oid != oid or !trigger.stamp.visible(snapshot)) continue;
                const slot = self.visibleTableSlot(trigger.table_oid, snapshot) orelse return null;
                const table = &self.tables[slot];
                const routine_slot = self.objects.routineByOid(trigger.function_oid, snapshot) orelse return null;
                const routine = &self.objects.routines[routine_slot];
                var text: CatalogTextWriter = .{ .out = out, .quote_all = self.session.quote_all_identifiers };
                text.add("CREATE TRIGGER ");
                text.ident(trigger.name.slice());
                text.add(if (trigger.tgtype & tg.tg_before != 0) " BEFORE " else " AFTER ");
                var preceding_event = false;
                inline for (.{ .{ tg.tg_insert, "INSERT" }, .{ tg.tg_delete, "DELETE" }, .{ tg.tg_update, "UPDATE" }, .{ tg.tg_truncate, "TRUNCATE" } }) |event| {
                    if (trigger.tgtype & event[0] != 0) {
                        if (preceding_event) text.add(" OR ");
                        text.add(event[1]);
                        preceding_event = true;
                        if (event[0] == tg.tg_update and trigger.column_count != 0) {
                            text.add(" OF ");
                            for (trigger.columns[0..trigger.column_count], 0..) |column, index| {
                                if (column >= table.column_count) return error.ColumnNotFound;
                                if (index != 0) text.add(", ");
                                text.ident(table.columns[column].name.slice());
                            }
                        }
                    }
                }
                text.add(" ON ");
                if (!pretty or !self.inRelationSearchPath(table.namespace, table.name.slice())) {
                    text.ident(self.namespaceName(table.namespace));
                    text.add(".");
                }
                text.ident(table.name.slice());
                text.add(if (trigger.tgtype & tg.tg_row != 0) " FOR EACH ROW " else " FOR EACH STATEMENT ");
                if (trigger.when.len != 0) {
                    text.add("WHEN (");
                    text.add(trigger.when.slice());
                    text.add(") ");
                }
                text.add("EXECUTE FUNCTION ");
                text.ident(routine.name.slice());
                text.add("(");
                for (0..trigger.nargs) |index| {
                    if (index != 0) text.add(", ");
                    text.literal(trigger.argument(index));
                }
                text.add(")");
                if (text.shortened) return error.TextCapacity;
                return text.len;
            }
            return null;
        }

        fn postgresPartitionAncestors(ptr: *anyopaque, oid: u32, out: []u32) Error!usize {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            const snapshot = self.seq_snap;
            var slot = self.visibleTableSlot(oid, snapshot) orelse return 0;
            const first = &self.tables[slot];
            if (first.relkind != 'p' and first.partition.bound == .none) return 0;
            var count: usize = 0;
            while (true) {
                if (count == out.len) return error.InvalidChangeRecord;
                const table = &self.tables[slot];
                out[count] = table.oid;
                count += 1;
                if (table.partition.bound == .none) return count;
                slot = self.visibleTableSlot(table.parent, snapshot) orelse return error.InvalidChangeRecord;
            }
        }

        fn renderConstraint(self: *const Self, table: *const S.Table, constraint: ?*const S.Constraint, kind: S.ConstraintKind, pretty: bool, out: []u8) Error!usize {
            var text: CatalogTextWriter = .{ .out = out, .quote_all = self.session.quote_all_identifiers };
            switch (kind) {
                .primary => {
                    var keys: [config.columns]u8 = undefined;
                    text.add("PRIMARY KEY ");
                    writeConstraintColumns(table, primaryColumns(table, &keys), &text);
                },
                .unique => {
                    const item = constraint.?;
                    text.add(if (item.nulls_not_distinct) "UNIQUE NULLS NOT DISTINCT " else "UNIQUE ");
                    writeConstraintColumns(table, item.keyColumns(), &text);
                },
                .check => {
                    const expression = constraint.?.expression.slice();
                    text.add(if (pretty) "CHECK (" else "CHECK ((");
                    text.add(expression);
                    text.add(if (pretty) ")" else "))");
                },
                .foreign => {
                    const item = constraint.?;
                    const slot = self.visibleTableSlot(item.ref_oid, self.seq_snap) orelse return error.TableNotFound;
                    const parent = &self.tables[slot];
                    text.add("FOREIGN KEY ");
                    writeConstraintColumns(table, item.keyColumns(), &text);
                    text.add(" REFERENCES ");
                    if (!self.inRelationSearchPath(parent.namespace, parent.name.slice())) {
                        text.ident(self.namespaceName(parent.namespace));
                        text.add(".");
                    }
                    text.ident(parent.name.slice());
                    writeConstraintColumns(parent, item.refColumns(), &text);
                    if (item.on_update != .no_action) {
                        text.add(" ON UPDATE ");
                        text.add(foreignActionText(item.on_update));
                    }
                    if (item.on_delete != .no_action) {
                        text.add(" ON DELETE ");
                        text.add(foreignActionText(item.on_delete));
                    }
                },
                // The original exclusion definition does not retain the
                // chosen access method, so it cannot be reconstructed yet.
                .exclusion => return error.UnsupportedStatement,
            }
            if (constraint) |item| {
                if (item.deferrable) text.add(" DEFERRABLE");
                if (item.initially_deferred) text.add(" INITIALLY DEFERRED");
            }
            if (text.shortened) return error.TextCapacity;
            return text.len;
        }

        fn renderIndex(self: *const Self, table: *const S.Table, name: []const u8, unique: bool, keys: []const u8, index: ?*const S.Index, column: i32, pretty: bool, out: []u8) Error!usize {
            var text: CatalogTextWriter = .{ .out = out, .quote_all = self.session.quote_all_identifiers };
            if (column == 0) {
                const schema = if (pretty and self.inRelationSearchPath(table.namespace, table.name.slice())) null else self.namespaceName(table.namespace);
                writeIndexDefinition(table, schema, name, unique, keys, index, pretty, &text);
            } else if (column > 0) {
                const position: usize = @intCast(column - 1);
                if (position < keys.len) {
                    var expressions = if (index) |secondary| secondary.expressions.slice() else &.{};
                    for (keys[0..position]) |key| if (key == S.expression_key) {
                        _ = takeIndexExpression(&expressions);
                    };
                    writeIndexKey(table, keys[position], &expressions, &text);
                } else if (index) |secondary| {
                    const included = position - keys.len;
                    if (included < secondary.include_count) text.ident(table.columns[secondary.includes[included]].name.slice());
                }
            }
            if (text.shortened) return error.TextCapacity;
            return text.len;
        }

        const CatalogTextWriter = struct {
            out: []u8,
            len: usize = 0,
            shortened: bool = false,
            quote_all: bool = false,

            fn add(self: *CatalogTextWriter, bytes: []const u8) void {
                const take = @min(bytes.len, self.out.len - self.len);
                @memcpy(self.out[self.len..][0..take], bytes[0..take]);
                self.len += take;
                self.shortened = self.shortened or take != bytes.len;
            }

            fn ident(self: *CatalogTextWriter, name: []const u8) void {
                // The catalog limits stored identifiers to 255 bytes.
                var quoted: [512]u8 = undefined;
                self.add(quoted[0..quoteIdentifier(name, &quoted, self.quote_all)]);
            }

            fn literal(self: *CatalogTextWriter, value: []const u8) void {
                self.add("'");
                for (value, 0..) |byte, index| {
                    if (byte == '\'') self.add("'");
                    self.add(value[index..][0..1]);
                }
                self.add("'");
            }

            fn slice(self: *const CatalogTextWriter) []const u8 {
                return self.out[0..self.len];
            }
        };

        fn partitionBoundText(self: *const Self, table: *const S.Table, snapshot: Snapshot, session_values: *const value_module.Session) Error!Cell {
            if (table.partition.bound == .none) return .null_value;
            if (table.partition.bound == .default) return nameCell("DEFAULT");
            const parent_index = self.visibleTableSlot(table.parent, snapshot) orelse return error.TableNotFound;
            const parent = &self.tables[parent_index];
            const family = types.typeOfData(parent.columns[parent.partition.key].data_type);
            const bound = &table.partition;
            var buffer: [config.text_bytes]u8 = undefined;
            var rendered: CatalogTextWriter = .{ .out = &buffer };
            if (bound.bound == .range) {
                rendered.add("FOR VALUES FROM (");
                if (bound.unbounded & 1 != 0) rendered.add("MINVALUE") else try partitionLiteral(&rendered, &bound.values[0], family, session_values);
                rendered.add(") TO (");
                if (bound.unbounded & 2 != 0) rendered.add("MAXVALUE") else try partitionLiteral(&rendered, &bound.values[1], family, session_values);
            } else {
                rendered.add("FOR VALUES IN (");
                for (bound.values[0..bound.count], 0..) |*cell, index| {
                    if (index != 0) rendered.add(", ");
                    try partitionLiteral(&rendered, cell, family, session_values);
                }
            }
            rendered.add(")");
            if (rendered.shortened) return error.TextCapacity;
            return objectTextCell(rendered.slice());
        }

        fn partitionLiteral(rendered: *CatalogTextWriter, cell: *const Cell, family: types.Type, session_values: *const value_module.Session) Error!void {
            if (cell.* == .null_value) {
                rendered.add("NULL");
                return;
            }
            var buffer: [Io.format_bytes]u8 = undefined;
            const formatted = try Io.format(cell, family == .boolean, session_values, &buffer);
            const unquoted = switch (family) {
                .boolean => true,
                .int4, .numeric => formatted.len != 0 and (formatted[0] >= '0' and formatted[0] <= '9'),
                else => false,
            };
            if (unquoted) rendered.add(formatted) else rendered.literal(formatted);
        }

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

        fn indexCatalogRow(sink: *X.RowSink, oid: u32, table: i64, keys: []const u8, index: ?*const S.Index) Error!void {
            const included = if (index) |item| item.includes[0..item.include_count] else &.{};
            var key_buffer: [8 * config.columns]u8 = undefined;
            var key: CatalogTextWriter = .{ .out = &key_buffer };
            for ([_][]const u8{ keys, included }) |columns| {
                for (columns) |column| {
                    if (key.slice().len != 0) key.add(" ");
                    var digits: [4]u8 = undefined;
                    key.add(formatUnsigned(if (column == S.expression_key) 0 else @as(usize, column) + 1, &digits));
                }
            }
            var expressions: V.Text = .{};
            var source = if (index) |item| item.expressions.slice() else &.{};
            if (source.len != 0) {
                var text: CatalogTextWriter = .{ .out = &expressions.bytes };
                while (source.len != 0) {
                    if (text.slice().len != 0) text.add(", ");
                    text.add(takeIndexExpression(&source));
                }
                if (text.shortened) return error.TextCapacity;
                expressions.len = text.slice().len;
            }
            try sink.add(&.{
                intCell(oid), intCell(table), boolCell(index == null), boolCell(if (index) |item| item.unique else true),
                try E.textCell(key.slice()), boolCell(true), boolCell(false), boolCell(false), boolCell(true),
                intCell(@intCast(keys.len)), intCell(@intCast(keys.len + included.len)),
                boolCell(if (index) |item| item.nulls_not_distinct else false),
                if (expressions.len == 0) .null_value else .{ .text = expressions },
            });
        }

        fn formatUnsigned(value: usize, out: []u8) []const u8 {
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

        /// Detached statements hold the caller's immutable read grant, but do
        /// not acquire AccessShare. Use the lock-taking path while an
        /// AccessExclusive owner or an earlier conflicting waiter exists.
        pub fn detachedReadsBlocked(self: *const Self) bool {
            return self.locks.access_exclusive_count != 0 or self.exclusive_table_waiters.any();
        }

        fn setTableWait(self: *Self, slot: usize, waiting: ?M.TableWait) void {
            self.txs[slot].table_wait = waiting;
            if (waiting != null and waiting.?.mode == .access_exclusive) {
                self.exclusive_table_waiters.add(slot);
            } else {
                self.exclusive_table_waiters.remove(slot);
            }
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
                    self.setTableWait(slot, .{ .table = @intCast(table), .mode = mode, .seq = self.wait_counter });
                }
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            if (self.locks.grantTable(table, slot, mode)) try M.recordLock(self, slot, .{ .kind = .table, .table = @intCast(table), .mode = @intFromEnum(mode) });
            self.setTableWait(slot, null);
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
                if (entry.hasDeletion()) {
                    const deletion_csn = entry.deletionCsn();
                    if (deletion_csn != 0) {
                        if (strict and deletion_csn > snap.csn) return error.SerializationFailure;
                        current = S.successor(table, current) orelse return .skip;
                        continue;
                    }
                    const deletion = entry.pendingDeletion().?;
                    if (snap.own(deletion.tx)) return if (deletion.cid == snap.cid) .authored else .skip;
                    waits.add(deletion.tx.slot);
                }
                self.locks.rowHolders(table_index, table.rows[entry.rowSlot()].rowid, slot, mode, waits);
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
                        const rowid = table.rows[table.versions[newest].rowSlot()].rowid;
                        if (try db.locks.grantRow(table_index, rowid, self.slot, self.mode)) |granted| try M.recordLock(db, self.slot, granted);
                        return newest;
                    },
                }
            }
        };

        fn reserveWrites(self: *const Self, slot: u16, count: usize) Error!void {
            if (M.write_capacity - self.txs[slot].write_len < count) return error.WriteSetCapacity;
        }

        /// The experimental heterogeneous banks are chosen in WAL order.
        /// Overlapping table DDL can commit in a different order from slot
        /// acquisition. Replay also makes DROP slots available immediately.
        fn fenceBankPlacement(self: *Self, slot: u16, creating: bool) Error!void {
            if (!S.anyIntegralBank(&self.tables)) return;
            for (&self.txs, 0..) |*tx, owner| {
                if (owner == slot or !tx.active) continue;
                for (tx.writes[0..tx.write_len]) |entry| switch (entry.kind) {
                    .create_table, .drop_table, .alter_table => return error.SerializationFailure,
                    else => {},
                };
            }
            if (creating) {
                self.reclaimTables(self.horizon());
                for (&self.tables) |*table| {
                    if (table.live and (table.pending_drop or table.dead_csn != 0)) return error.SerializationFailure;
                }
            }
        }

        fn createTable(self: *Self, slot: u16, create: *const B.Create, snap: Snapshot, source: []const u8) Error!usize {
            try self.fenceBankPlacement(slot, true);
            const tx = &self.txs[slot];
            // CREATE TABLE AS / MATERIALIZED VIEW read their sources first,
            // so a lock wait parks before anything is written.
            if (create.plan != ast.none) try self.lockSources(slot);
            try self.checkRelationTypeName(slot, create.namespace, create.name.slice(), snap);
            if (self.catalog.creator(create.name.slice(), snap)) |owner| {
                var waits: L.Set = .{};
                waits.add(owner);
                tx.fresh = tx.write_len == tx.subs[tx.sub_len - 1].write_start;
                return self.park(slot, waits);
            }
            try self.checkNamespaceForCreate(slot, create.namespace);
            const creator = self.session.role;
            const write_owner = self.dialect == .postgres and create.plain_definition and creator != CO.bootstrap_role;
            if (write_owner) {
                if (self.catalog_objects.pendingReference(creator, snap)) |other| return self.objectPark(slot, other);
                var authority = snap;
                authority.csn = self.csn;
                if (self.catalog_objects.roleName(creator, authority) == null) return error.InsufficientPrivilege;
            }
            try self.reserveWrites(slot, 2 + create.count + @intFromBool(write_owner));
            const columns = create.columns[0..create.count];
            var destination: ?usize = null;
            for (0..2) |attempt| {
                for (&self.tables, 0..) |*table, index| if (!table.live and S.createBankFits(table, columns, create.extras.index_count)) {
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
            S.reset(table, change_log.first_oid + self.oid_counter, create.name, columns);
            table.namespace = create.namespace;
            S.setConstraints(table, create.constraints[0..create.constraint_count]);
            S.setExtras(table, &create.extras);
            try self.assignConstraintOids(table, null);
            try C.assignDefaultOids(table.columns[0..table.column_count], &.{}, &.{}, &self.next_default_oid);
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
            if (write_owner) {
                var ownership: O.Object = .{ .kind = .relation, .target = table.oid, .owner = creator };
                _ = try self.objectInsert(slot, &ownership, false, snap);
            }
            // Keep identity sequences ahead of SERIAL in the OID order.
            for ([_]bool{ false, true }) |serial| {
                for (create.sequences[0..create.sequence_count]) |seq| {
                    if ((table.columns[seq.column].default_kind == .default) == serial)
                        try self.createSequence(slot, table.namespace, seq.name, seq.spec, table.oid, seq.column, serial, snap);
                }
            }
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
            try self.truncateSlot(slot, index, snap, .refresh_rows);
            if (!refresh.with_data) return 0;
            return self.fillFromPlan(slot, index, source, refresh.plan, snap);
        }

        /// AccessExclusive already stabilizes the table. Retire its latest
        /// committed rows and our earlier writes, as logical WAL replay does.
        fn checkPendingLatePrimary(table: *const S.Table) Error!void {
            if (table.pending_create and table.pending_late_primary) return error.UnsupportedStatement;
        }

        fn truncateSlot(self: *Self, slot: u16, index: usize, snap: Snapshot, comptime kind: M.WriteKind) Error!void {
            try self.reserveWrites(slot, 1);
            const tx = &self.txs[slot];
            const table = &self.tables[index];
            try checkPendingLatePrimary(table);
            var current = snap;
            current.csn = self.csn;
            for (0..table.row_high) |row| {
                if (table.rows[row].newest == 0) continue;
                const version = S.visibleAt(table, row, current) orelse continue;
                const entry = &table.versions[version];
                entry.markDeletion(tx.ref(slot), snap.cid);
            }
            const previous_cid = table.pending_truncate.cid;
            if (comptime kind == .truncate) table.pending_truncate = .{ .owner = tx.ref(slot), .cid = snap.cid };
            tx.push(.{ .kind = kind, .table = @intCast(index), .old = snap.cid, .new = previous_cid }) catch unreachable;
        }

        fn dropTable(self: *Self, slot: u16, index: usize, cascade: bool, snap: Snapshot) Error!usize {
            try checkPendingLatePrimary(&self.tables[index]);
            try self.fenceBankPlacement(slot, false);
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

        /// Acquire AccessExclusive on every target before writing. One
        /// truncate entry per table covers all latest rows. Commit stamps
        /// those marks, and abort or ROLLBACK TO clears them.
        fn truncateTables(self: *Self, slot: u16, truncate: *const B.Truncate, snap: Snapshot) Error!void {
            for (truncate.tables[0..truncate.count]) |index| try self.lockTable(slot, index, .access_exclusive);
            var current = snap;
            current.csn = self.csn;
            // Check current relation identities and dependencies under the
            // target locks. A pinned catalog snapshot may name a retired slot
            // or miss a newly committed reference.
            var relations: [K.relation_rows]K.Found = undefined;
            const relation_count = self.catalog.visibleRelations(current, &relations);
            for (truncate.tables[0..truncate.count]) |index| {
                var present = false;
                for (relations[0..relation_count]) |found| {
                    if (found.kind == 'S') continue;
                    present = present or found.slot == index;
                    var listed = false;
                    for (truncate.tables[0..truncate.count]) |other| listed = listed or other == found.slot;
                    if (listed) continue;
                    const other = &self.tables[found.slot];
                    for (other.constraints[0..other.constraint_count]) |*constraint| {
                        if (constraint.kind == .foreign and constraint.ref_oid == self.tables[index].oid) return error.UnsupportedStatement;
                    }
                }
                if (!present) return error.SerializationFailure;
            }
            // RESTART IDENTITY: every sequence a column of the table owns
            // (identity, SERIAL) restarts, transactionally (ALTER SEQUENCE).
            if (truncate.restart_identity or self.dialect == .mysql) {
                // Collect first: each restart fills another sequence slot.
                var owned: [config.sequences]bool = @splat(false);
                for (truncate.tables[0..truncate.count]) |index| {
                    const oid = self.tables[index].oid;
                    const auto = mysqlAutoColumn(&self.tables[index]);
                    for (&self.seqs, 0..) |*seq, position| {
                        if (!seq.live or seq.owner != oid or seq.dead_csn != 0) continue;
                        if (!truncate.restart_identity and (auto == null or seq.owner_column != auto.?)) continue;
                        if (seq.pending_create and seq.creator != slot) continue;
                        if (seq.pending_drop and seq.creator == slot) continue;
                        owned[position] = true;
                    }
                }
                for (owned, 0..) |restart, position| if (restart) try self.alterSequence(slot, position, .{ .restart = true }, null, snap);
            }
            try self.reserveWrites(slot, truncate.count);
            for (truncate.tables[0..truncate.count]) |index| try self.truncateSlot(slot, index, snap, .truncate);
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
            // ALTER acquires a new bank live and replays in place. Even a
            // dense bank move can change later heterogeneous CREATE choices.
            if (S.anyIntegralBank(&self.tables)) return error.UnsupportedStatement;
            const source = &self.tables[alter.table];
            try checkPendingLatePrimary(source);
            var primary = false;
            for (alter.columns[0..alter.count]) |*column| primary = primary or column.primary_key;
            for (alter.constraints[0..alter.constraint_count]) |*constraint| primary = primary or constraint.kind == .primary;
            const late_primary = primary and !S.keyed(source);
            var fold_created_primary = false;
            if (late_primary) {
                const tx = &self.txs[slot];
                var fresh_definition: ?usize = null;
                for (tx.writes[0..tx.write_len]) |entry| switch (entry.kind) {
                    .create_table => if (self.tables[entry.table].oid == source.oid) {
                        fresh_definition = entry.table;
                    },
                    .insert => {
                        if (self.tables[entry.table].oid == source.oid and fresh_definition != entry.table)
                            return error.UnsupportedStatement;
                    },
                    .alter_table => {
                        if (self.tables[entry.table].oid != source.oid) continue;
                        if (fresh_definition != entry.old or !self.alters[entry.table].foldable_defaults)
                            return error.UnsupportedStatement;
                        fresh_definition = entry.table;
                    },
                    .update, .delete, .truncate, .refresh_rows, .drop_table => {
                        if (self.tables[entry.table].oid == source.oid) return error.UnsupportedStatement;
                    },
                    else => {},
                };
                fold_created_primary = fresh_definition == alter.table;
            }
            if (!types.same(alter.name.slice(), source.name.slice())) {
                try self.checkRelationTypeName(slot, source.namespace, alter.name.slice(), snap);
            }
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
            if (S.keyed(copy)) copy.primary_index_oid = source.primary_index_oid;
            try self.assignConstraintOids(copy, source);
            try C.assignDefaultOids(copy.columns[0..copy.column_count], source.columns[0..source.column_count], alter.sources[0..alter.count], &self.next_default_oid);
            S.copyRelayout(copy, source, alter.sources[0..alter.count], fills[0..alter.count]);
            copy.live = true;
            copy.pending_create = true;
            source.pending_drop = true;
            self.alters[index] = .{
                .fold_created_primary = fold_created_primary,
                .foldable_defaults = alter.identity != null or alter.sets_defaults,
                .sources = alter.sources,
                .fills = fills,
            };
            tx.push(.{ .kind = .alter_table, .table = @intCast(index), .old = @intCast(alter.table), .new = snap.cid }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            var count = self.catalog.drop(alter.table, source.column_count, snap, tx.ref(slot), snap.cid, 0, &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_delete, .table = @intFromEnum(change.relation), .old = change.version }) catch unreachable;
            count = try self.catalog.create(index, copy, tx.ref(slot), snap.cid, 0, self.horizon(), &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_insert, .table = @intFromEnum(change.relation), .new = change.version }) catch unreachable;
            // A rewrite changes every row's definition. Include writes that
            // committed before the exclusive lock, even for an older snapshot.
            var validation_snap = snap;
            validation_snap.csn = self.csn;
            try self.validateAltered(slot, index, alter, validation_snap);
            // CREATE INDEX: OIDs are taken last, so a failed statement
            // leaves the counter as it was (abort restores a tail OID).
            for (copy.indexes[0..copy.index_count]) |*created| if (created.oid == 0) {
                if (self.oid_counter >= 0xffffffff - change_log.first_oid) return error.TableCapacity;
                created.oid = change_log.first_oid + self.oid_counter;
                self.oid_counter += 1;
            };
            if (late_primary) {
                copy.primary_index_oid = try self.takeOid();
                copy.pending_late_primary = !fold_created_primary;
            }
            try self.remapColumnComments(slot, source.oid, alter.sources[0..alter.count], snap);
            try self.remapStatistics(slot, source.oid, alter.sources[0..alter.count], snap);
            if (alter.identity) |identity| try self.createSequence(slot, copy.namespace, identity.name, identity.spec, copy.oid, identity.column, false, snap);
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
            if (table.primary_column == null) {
                if (S.primaryConstraint(table)) |primary| {
                    if (alter.check_constraint[primary]) {
                        try S.validatePrimaryColumns(table, table.constraints[primary].keyColumns(), table.columns[0..table.column_count], snap, self.session.control);
                    }
                }
            }
            var ctx = self.evalContext("");
            var row_scratch: S.VersionRowScratch = undefined;
            for (0..table.row_high) |row| {
                if (table.rows[row].newest == 0) continue;
                const version = S.visibleAt(table, row, snap) orelse continue;
                try self.session.checkpoint();
                const cells = S.borrowVersionRow(table, version, &row_scratch);
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
                    if (!alter.check_constraint[position]) continue;
                    const status = if (constraint.kind == .primary)
                        if (table.primary_column) |column| S.primaryKeyCheck(table, &cells[column], @intCast(row), snap) else continue
                    else if (S.scannedUnique(table, constraint))
                        S.uniqueCheck(table, constraint, cells, @intCast(row), snap)
                    else
                        continue;
                    switch (status) {
                        .free => {},
                        .taken => return error.PrimaryKeyViolation,
                        .wait => |owner| {
                            var waits: L.Set = .{};
                            waits.add(owner);
                            return self.park(slot, waits);
                        },
                    }
                }
                if (alter.check_index) |which| switch (try S.indexUniqueCheck(table, which, cells, @intCast(row), snap, self.session.control)) {
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
            tx.mysql_insert_value = null;
        }

        fn mysqlAutoColumn(table: *const S.Table) ?usize {
            const index = table.primary_column orelse return null;
            return if (table.columns[index].default_kind == .mysql_auto_increment) index else null;
        }

        fn mysqlSetCounter(self: *Self, slot: u16, sequence_index: usize, value: i64) Error!void {
            const sequence = &self.seqs[sequence_index];
            if (value < sequence.last_value or (value == sequence.last_value and sequence.is_called)) return;
            try Q.set(sequence, value, true);
            self.txs[slot].seq_dirty.add(sequence_index);
            self.seq_carried.add(sequence_index);
        }

        fn mysqlInsertValue(self: *Self, slot: u16, ctx: *E.Context, table: usize, column: usize, id: u16) Error!D.InsertValue {
            const tx = &self.txs[slot];
            if (tx.mysql_insert_value) |pending| return .{ .column = column, .value = pending.value };
            ctx.row = null;
            const evaluated: Cell = if (id == ast.none or ctx.pool.nodes[id].kind == .default_value) .null_value else try E.eval(ctx, id);
            const generated = evaluated == .null_value or
                (evaluated == .integer and evaluated.integer == 0 and !self.session.mysql_keep_zero);
            var value: i64 = undefined;
            if (generated) {
                const sequence_index = try self.identitySequence(table, column);
                const sequence = &self.seqs[sequence_index];
                if (sequence.is_called and sequence.last_value == sequence.spec.max) return error.SequenceLimit;
                value = sequence.last_value + @as(i64, @intFromBool(sequence.is_called));
                try self.mysqlSetCounter(slot, sequence_index, value);
            } else {
                if (evaluated != .integer) return error.TypeMismatch;
                value = evaluated.integer;
            }
            tx.mysql_insert_value = .{ .value = value, .generated = generated };
            return .{ .column = column, .value = value };
        }

        /// ON CONFLICT DO UPDATE on the conflicting row (the newest committed
        /// or own version, not the statement snapshot's): wait for a live
        /// writer or locker (the whole row is retried on resume), 21000 when
        /// this statement already wrote the row, WHERE false locks the row
        /// and skips it. Returns rows affected (0 or 1).
        fn conflictUpdate(self: *Self, slot: u16, ctx: *E.Context, table_index: usize, update: *const B.Update, version: u32, proposed: *const E.Row, snap: Snapshot) Error!usize {
            const table = &self.tables[table_index];
            const entry = &table.versions[version];
            if (entry.pendingCreation()) |creation| {
                if (snap.own(creation.tx) and creation.cid == snap.cid) return error.CardinalityViolation;
            }
            var waits: L.Set = .{};
            const goal = switch (try self.target(slot, table_index, version, snap, .write, &waits)) {
                .wait => return self.park(slot, waits),
                .ready => |newest| newest,
                .skip, .authored => return error.CardinalityViolation,
            };
            // REPEATABLE READ: the conflicting row must be visible to the
            // snapshot (ExecCheckTupleVisible).
            if (transactionSnapshot(self.txs[slot].isolation) and table.versions[goal].creationAfter(snap)) return error.SerializationFailure;
            const row = table.versions[goal].rowSlot();
            const previous_row = ctx.row;
            defer ctx.row = previous_row;
            var row_scratch: S.VersionRowScratch = undefined;
            const old = S.borrowVersionRow(table, goal, &row_scratch);
            ctx.tuple[1] = proposed;
            if (!try X.keep(ctx, update.where, old)) {
                if (try self.locks.grantRow(table_index, table.rows[row].rowid, slot, .update)) |granted| try M.recordLock(self, slot, granted);
                return 0;
            }
            return @intFromBool(try self.updateOne(slot, ctx, update, row, goal, old, snap));
        }

        /// A primary-key replacement is one real delete and one insert. More
        /// than one uniqueness key, trigger and foreign-key effects require
        /// their own replacement path before those schemas can be admitted.
        fn validateMysqlReplace(self: *const Self, slot: u16, table_index: usize, snap: Snapshot) Error!void {
            const table = &self.tables[table_index];
            if (self.dialect != .mysql or self.txs[slot].isolation != .read_committed or table.relkind != 'r' or
                table.index_count != 0 or self.hasChildren(table.oid, snap) or
                self.catalog_objects.securityFlags(table.oid, snap) & CO.rls_enabled != 0) return error.UnsupportedStatement;
            for (table.constraints[0..table.constraint_count]) |constraint| switch (constraint.kind) {
                .check => {},
                .primary => if (table.primary_column == null or constraint.column_count != 1) return error.UnsupportedStatement,
                else => return error.UnsupportedStatement,
            };
            for (table.columns[0..table.column_count]) |column| {
                if (column.default_kind == .identity_always or column.default_kind == .identity_by_default)
                    return error.UnsupportedStatement;
            }
            var triggers: [config.triggers]u8 = undefined;
            if (self.objects.tableTriggers(table.oid, snap, &triggers) != 0 or
                self.ruleKind(table_index, '3', snap) != .none or self.ruleKind(table_index, '4', snap) != .none) return error.UnsupportedStatement;
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind == 'S') continue;
                const other = &self.tables[found.slot];
                for (other.constraints[0..other.constraint_count]) |constraint| {
                    if (constraint.kind == .foreign and constraint.ref_oid == table.oid) return error.UnsupportedStatement;
                }
            }
        }

        fn replaceMysqlConflict(self: *Self, slot: u16, table_index: usize, cells: *const E.Row, snap: Snapshot) Error!bool {
            const conflict = (try self.arbiterTaken(slot, table_index, .primary, cells, snap)) orelse return false;
            var waits: L.Set = .{};
            const version = switch (try self.target(slot, table_index, conflict, snap, .write, &waits)) {
                .ready => |latest| latest,
                .wait => return self.park(slot, waits),
                .skip, .authored => return error.SerializationFailure,
            };
            try self.reserveWrites(slot, 2);
            const mutation = &self.txs[slot];
            const previous = &self.tables[table_index].versions[version];
            previous.markDeletion(mutation.ref(slot), snap.cid);
            mutation.push(.{ .kind = .delete, .table = @intCast(table_index), .old = version }) catch unreachable;
            return true;
        }

        fn insertOne(self: *Self, slot: u16, ctx: *E.Context, insert: *const B.Insert, values: *const [config.columns]u16, derived: D.Derived, snap: Snapshot) Error!usize {
            // BEFORE ROW triggers and conditional rules see the row before
            // NOT NULL, generated columns and CHECKs (B11 wave 3).
            const hooked = self.insertHooks(insert.table, snap);
            const target_table = &self.tables[insert.table];
            const auto = mysqlAutoColumn(target_table);
            var cells = if (auto) |column| blk: {
                const replacement = try self.mysqlInsertValue(slot, ctx, insert.table, column, values[column]);
                break :blk try D.insertedRowWithValue(ctx, target_table, values, derived, replacement);
            } else if (hooked) try D.insertedRowDeferred(ctx, target_table, values, derived) else try D.insertedRow(ctx, target_table, values, derived);
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
            const replaced = insert.replace and try self.replaceMysqlConflict(slot, table_index, &cells, snap);
            // ON CONFLICT: the arbiter is checked first (PostgreSQL's
            // speculative pre-check); other unique indexes still raise 23505.
            const conflict = &insert.conflict;
            if (conflict.action != .none) if (try self.arbiterTaken(slot, table_index, conflict.arbiter, &cells, snap)) |version| switch (conflict.action) {
                .nothing, .none => return 0,
                .update => return self.conflictUpdate(slot, ctx, table_index, &conflict.update, version, &cells, snap),
            };
            if (table.primary_column) |column| switch (S.primaryKeyCheck(table, &cells[column], 0xffffffff, snap)) {
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
            if (auto) |column| {
                const tx = &self.txs[slot];
                const allocated = tx.mysql_insert_value.?;
                if (allocated.generated) {
                    if (tx.mysql_first_generated == 0) tx.mysql_first_generated = @intCast(allocated.value);
                } else {
                    try self.mysqlSetCounter(slot, try self.identitySequence(table_index, column), allocated.value);
                    tx.mysql_explicit_insert_id = @bitCast(allocated.value);
                }
            }
            return 1 + @as(usize, @intFromBool(replaced));
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
                if (version.rowLink() == 0 or version.rowSlot() == own_slot) continue;
                var all = true;
                for (constraint.keyColumns(), constraint.operators[0..constraint.column_count]) |column, operator| {
                    if (!all) break;
                    var temporary: V.Cell = undefined;
                    const stored = S.borrowVersionCell(table, index, column, &temporary);
                    all = try exclusionMatch(operator, stored, &cells[column]);
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
                if (version.rowLink() == 0) continue;
                var equal = true;
                for (columns, key_columns) |column, source| {
                    var temporary: V.Cell = undefined;
                    const stored = S.borrowVersionCell(table, index, column, &temporary);
                    if (stored.* == .null_value or V.compare(stored, &key[source]) != 0) equal = false;
                }
                if (!equal) continue;
                if (version.pendingCreation()) |creation| {
                    if (!snap.own(creation.tx) or version.deletionOwnedBy(snap)) continue;
                    return .{ .found = @intCast(index) };
                }
                if (!version.hasDeletion()) return .{ .found = @intCast(index) };
                const deletion = version.pendingDeletion() orelse continue;
                if (snap.own(deletion.tx)) continue;
                if (waiting == null) waiting = deletion.tx.slot;
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
                    if (parent.versions[version].creationCsn() == 0) return;
                    const rowid = parent.rows[parent.versions[version].rowSlot()].rowid;
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
                if (entry.rowLink() == 0) continue;
                var equal = true;
                for (constraint.keyColumns(), constraint.refColumns()) |column, key| {
                    var temporary: V.Cell = undefined;
                    const stored = S.borrowVersionCell(child, version, column, &temporary);
                    if (stored.* == .null_value or V.compare(stored, &old[key]) != 0) equal = false;
                }
                if (!equal) continue;
                var goal = version;
                if (entry.pendingCreation()) |creation| {
                    if (!snap.own(creation.tx)) {
                        var waits: L.Set = .{};
                        waits.add(creation.tx.slot);
                        return self.park(slot, waits);
                    }
                    if (entry.deletionOwnedBy(snap)) continue;
                } else {
                    if (entry.hasDeletion() and (entry.deletionCsn() != 0 or entry.deletionOwnedBy(snap))) continue;
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
                        var updated: E.Row = undefined;
                        S.copyVersionRow(child, goal, &updated);
                        for (constraint.keyColumns(), constraint.refColumns()) |column, key| updated[column] = try D.store(&child.columns[column], cells[key], &self.session);
                        try self.cascadeUpdate(slot, child_index, goal, &updated, .none, snap);
                    } else {
                        var row_scratch: S.VersionRowScratch = undefined;
                        const prior = S.borrowVersionRow(child, goal, &row_scratch);
                        try self.referencedChange(slot, child_index, prior, null, snap);
                        if (child.versions[goal].hasDeletion()) continue;
                        try self.reserveWrites(slot, 1);
                        child.versions[goal].markDeletion(tx.ref(slot), snap.cid);
                        tx.push(.{ .kind = .delete, .table = @intCast(child_index), .old = goal }) catch unreachable;
                    },
                    .set_null, .set_default => {
                        var updated: E.Row = undefined;
                        S.copyVersionRow(child, goal, &updated);
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
            const row = table.versions[old].rowSlot();
            if (table.primary_column) |column| if (!S.versionCellEquals(table, old, column, &cells[column])) switch (S.primaryKeyCheck(table, &cells[column], row, snap)) {
                .free => {},
                .taken => return error.PrimaryKeyViolation,
                .wait => |owner| {
                    var waits: L.Set = .{};
                    waits.add(owner);
                    return self.park(slot, waits);
                },
            };
            var row_scratch: S.VersionRowScratch = undefined;
            const old_cells = S.borrowVersionRow(table, old, &row_scratch);
            if ((try self.uniqueTaken(slot, table_index, cells, row, old_cells, snap)) != null) return error.PrimaryKeyViolation;
            try self.exclusionTaken(slot, table_index, cells, row, old_cells, snap);
            if (check != .none) try self.checkReferences(slot, table_index, cells, if (check == .all) null else old_cells, snap);
            try self.referencedChange(slot, table_index, old_cells, cells, snap);
            if (table.versions[old].hasDeletion()) return;
            try self.placeUpdate(slot, table_index, row, old, cells, snap);
        }

        /// Writes the new version of `row` over `old` (checks done).
        fn placeUpdate(self: *Self, slot: u16, table_index: usize, row: u32, old: u32, cells: *const E.Row, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const table = &self.tables[table_index];
            try checkPendingLatePrimary(table);
            try self.reserveWrites(slot, 1);
            try S.ensureVersions(table, 1, self.horizon());
            const version = S.createVersion(table, .{ .row = row, .xmin = tx.ref(slot), .cid = snap.cid, .older = old + 1 }, cells);
            table.versions[old].markDeletion(tx.ref(slot), snap.cid);
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
            var row_scratch: S.VersionRowScratch = undefined;
            if (!tx.active or !tx.deferred_checks) return;
            const snap: Snapshot = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid +% 1 };
            for (tx.writes[start..tx.write_len]) |entry| {
                if (entry.kind != .insert and entry.kind != .update and entry.kind != .delete) continue;
                const table = &self.tables[entry.table];
                if (!table.live or table.pending_drop) continue;
                if (entry.kind != .delete) {
                    const version = &table.versions[entry.new];
                    if (version.rowLink() != 0 and !version.hasDeletion()) try self.deferredRow(slot, table, S.borrowVersionRow(table, entry.new, &row_scratch), version.rowSlot(), immediate_only, snap);
                }
                if (entry.kind != .insert) try self.deferredParent(slot, table, S.borrowVersionRow(table, entry.old, &row_scratch), immediate_only, snap);
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
                    break :blk S.primaryKeyCheck(table, &cells[column], 0xffffffff, snap);
                },
                .constraint => |index| S.uniqueCheck(table, &table.constraints[index], cells, 0xffffffff, snap),
                .index => |which| try S.indexUniqueCheck(table, which, cells, 0xffffffff, snap, self.session.control),
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
                switch (try S.indexUniqueCheck(table, which, cells, own_slot, snap, self.session.control)) {
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

        /// Whether every backed secondary hash covers the allocated versions.
        pub fn indexConsistent(self: *const Self, table_name: []const u8) ?bool {
            const index = self.committedIndex(table_name) orelse return null;
            const table = &self.tables[index];
            for (0..table.index_count) |which| {
                if (!S.hasIndexHash(table, which)) continue;
                if (S.indexEntries(table, which) != table.version_used) return false;
            }
            return true;
        }

        /// Places a new row version (key already checked). Capacity errors
        /// leave the table and write set unchanged.
        fn appendRow(self: *Self, slot: u16, table_index: usize, cells: *const E.Row, snap: Snapshot) Error!void {
            const rowid = self.tables[table_index].next_rowid;
            if (rowid == 0xffffffffffffffff) return error.RowCapacity;
            return self.placeInsert(slot, table_index, rowid, cells, snap);
        }

        fn placeInsert(self: *Self, slot: u16, table_index: usize, rowid: u64, cells: *const E.Row, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const table = &self.tables[table_index];
            try checkPendingLatePrimary(table);
            try self.reserveWrites(slot, 1);
            const at = self.horizon();
            try S.ensureVersions(table, 1, at);
            try S.ensureRowSlot(table, at);
            const row = S.allocRow(table, rowid);
            table.next_rowid = @max(table.next_rowid, rowid + 1);
            const version = S.createVersion(table, .{ .row = row, .xmin = tx.ref(slot), .cid = snap.cid }, cells);
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

        const CopyQuoteNames = struct {
            columns: [config.columns]Name,
            count: usize,
        };

        const CopyForceQuote = union(enum) {
            none,
            all,
            fields: [config.columns]bool,
            names: CopyQuoteNames,
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
            force_quote: CopyForceQuote = .none,

            /// A query's output names are only known after describing it.
            pub fn needsQuoteColumns(self: *const CopyInfo) bool {
                return self.force_quote == .names;
            }

            pub fn resolveQuoteColumns(self: *CopyInfo, names: []const Name) Error!void {
                const requested = switch (self.force_quote) {
                    .names => |*list| list,
                    else => return,
                };
                var fields: [config.columns]bool = @splat(false);
                for (requested.columns[0..requested.count]) |*wanted| {
                    for (names, 0..) |*name, field| {
                        if (!types.same(name.slice(), wanted.slice())) continue;
                        if (fields[field]) return error.DuplicateColumn;
                        fields[field] = true;
                        break;
                    } else return error.ColumnNotFound;
                }
                self.force_quote = .{ .fields = fields };
            }

            pub fn forceQuoteColumn(self: *const CopyInfo, field: usize) bool {
                return switch (self.force_quote) {
                    .none => false,
                    .all => true,
                    .fields => |*fields| fields[field],
                    .names => unreachable,
                };
            }
        };

        pub const copy_line_bytes = config.copy_line_bytes;

        /// PostgreSQL ProcessCopyOptions (PostgreSQL 16 SQLSTATEs): binary
        /// with DELIMITER/NULL 42601; non-single-byte DELIMITER/QUOTE/ESCAPE,
        /// QUOTE/ESCAPE outside CSV, HEADER in binary and HEADER MATCH in
        /// COPY TO 0A000; newline delimiters/NULL, a text delimiter from
        /// `\.a-z0-9`, delimiter = quote and delimiter or quote inside NULL
        /// 22023. NULL longer than 64 bytes is TextCapacity (54000).
        fn copyOptions(copy: *const A.Copy) Error!CopyOptions {
            const given = &copy.options;
            const direction = copy.direction;
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
            if ((copy.force_quote_all or copy.force_quote_count != 0) and (!csv or direction != .to)) return error.UnsupportedStatement;
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
            self.installRole();
            const copy = try self.parseCopy(source);
            var info: CopyInfo = .{ .direction = copy.direction, .options = try copyOptions(&copy) };
            if (copy.force_quote_all) info.force_quote = .all;
            var snap: Snapshot = .{ .csn = self.csn };
            if (slot) |owner| if (self.active(owner)) {
                snap = .{ .csn = self.csn, .slot = owner, .epoch = self.txs[owner].epoch, .cid = self.txs[owner].cid +% 1 };
            };
            if (copy.query) |span| {
                if (copy.force_quote_count != 0) info.force_quote = .{ .names = .{
                    .columns = copy.force_quote_columns,
                    .count = copy.force_quote_count,
                } };
                var used: usize = 0;
                try appendText(select, &used, span.slice(source));
                info.select_len = used;
                return info;
            }
            const context = self.bindContext(source, .standard, snap);
            const bound = try B.bindCopy(&context, &copy, false);
            if (copy.force_quote_count != 0) info.force_quote = .{ .fields = bound.force_quote };
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
                try appendText(select, &used, " FROM ONLY ");
                if (copy.table.schema) |qualifier| {
                    const namespace = identName(source, qualifier);
                    try appendQuoted(select, &used, namespace.slice());
                    try appendText(select, &used, ".");
                }
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
                _ = try copyOptions(&copy);
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
                if (try self.checkRowSecurity(self.session.role, self.tables[bound.table].oid, self.session.row_security, snap)) return error.UnsupportedStatement;
            }
            var info: CopyInfo = .{ .direction = .from, .options = try copyOptions(&copy), .count = bound.count };
            const table = &self.tables[bound.table];
            for (bound.mapping[0..bound.count], 0..) |column, field| {
                info.names[field] = table.columns[column].name;
                info.types[field] = table.columns[column].data_type;
                info.typmods[field] = table.columns[column].typmod;
            }
            tx.waiting_for = .{};
            self.setTableWait(slot, null);
            tx.copy_table = @intCast(bound.table);
            tx.copy_snap = snap;
            tx.copy_rows = 0;
            return info;
        }

        fn statementHooks(self: *Self, slot: u16, snap: Snapshot) void {
            self.seq_hook = .{ .ptr = self, .call = &sequenceCall, .large_object = &largeObjectCall, .large_object_data = &largeObjectDataCall, .large_object_truncate = &truncateLargeObject, .relation_name = &relationName, .relation_display_name = &relationDisplayName, .catalog_text = &catalogText, .schema_path = &catalogSchemaPath, .serial_sequence = &serialSequence, .relation_visible = &relationVisible, .index_definition = &postgresIndexDefinition, .constraint_definition = &postgresConstraintDefinition, .view_definition = &postgresViewDefinition, .trigger_definition = &postgresTriggerDefinition, .statistics_columns = &postgresStatisticsColumns, .relation_publishable = &relationPublishable, .partition_key_definition = &postgresPartitionKey, .partition_ancestors = &postgresPartitionAncestors, .namespace_lookup = &postgresNamespaceLookup, .namespace_name = &postgresNamespaceName, .routine_lookup = &postgresRoutineLookup, .routine_name = &postgresRoutineName };
            self.session.sequences = &self.seq_hook;
            self.seq_slot = slot;
            self.seq_snap = snap;
            self.workspace.query.views = .{ .ptr = self, .rows = &viewRows, .sequence_rows = &sequenceRows };
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
            if (table.primary_column) |column| switch (S.primaryKeyCheck(table, &row.cells[column], 0xffffffff, snap)) {
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
            self.setTableWait(slot, null);
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
            var row_scratch: S.VersionRowScratch = undefined;
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
                    if (!try X.keep(&ctx, merge.on, S.borrowVersionRow(table, version, &row_scratch))) continue;
                    matched = true;
                    try self.mergeMatched(slot, &ctx, &row_scratch, merge, @intCast(target_row), version, false, snap);
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
                    if (try X.keep(&ctx, merge.on, S.borrowVersionRow(table, version, &row_scratch))) matched = true;
                }
                if (!matched) {
                    for (1..config.relations) |relation| ctx.tuple[relation] = null;
                    try self.mergeMatched(slot, &ctx, &row_scratch, merge, @intCast(target_row), version, true, snap);
                }
                tx.progress = position + 1;
            };
            return tx.progress_affected;
        }

        fn mergeMatched(self: *Self, slot: u16, ctx: *E.Context, row_scratch: *S.VersionRowScratch, merge: *const B.Merge, row: u32, version: u32, by_source: bool, snap: Snapshot) Error!void {
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
            const cells = S.borrowVersionRow(table, goal, row_scratch);
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
                    if (!try self.updateOne(slot, ctx, &update, row, goal, cells, snap)) return;
                },
                .delete => {
                    if (self.rowHooks(merge.table, routine_catalog.tg_delete, '4', snap) and !try self.beforeRow(merge.table, routine_catalog.tg_delete, null, cells, null, snap)) return;
                    try self.referencedChange(slot, merge.table, cells, null, snap);
                    if (!table.versions[goal].hasDeletion()) {
                        try self.reserveWrites(slot, 1);
                        table.versions[goal].markDeletion(tx.ref(slot), snap.cid);
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
            var row_scratch: S.VersionRowScratch = undefined;
            var affected: usize = 0;
            const joined = try self.joinedRows(source, update.from, &update.offsets, snap);
            switch (try X.candidates(&ctx, table, update.key, snap)) {
                .empty => {},
                .slot => |hit| affected += try self.updateSlot(slot, &ctx, &row_scratch, update, hit.row, snap, joined),
                .scan => {
                    const high = table.row_high;
                    for (0..high) |row| affected += try self.updateSlot(slot, &ctx, &row_scratch, update, @intCast(row), snap, joined);
                },
            }
            return affected;
        }

        fn updateSlot(self: *Self, slot: u16, ctx: *E.Context, row_scratch: *S.VersionRowScratch, update: *const B.Update, row: u32, snap: Snapshot, joined: ?Joined) Error!usize {
            try self.session.checkpoint();
            const table = &self.tables[update.table];
            if (table.rows[row].newest == 0) return 0;
            const version = S.visibleAt(table, row, snap) orelse return 0;
            var waits: L.Set = .{};
            const plan = try self.target(slot, update.table, version, snap, .write, &waits);
            if (plan == .authored) return 1;
            var old_cells = S.borrowVersionRow(table, version, row_scratch);
            if (!try self.keepJoined(ctx, update.where, joined, old_cells)) return 0;
            const goal = switch (plan) {
                .skip, .authored => return 0,
                .wait => return self.park(slot, waits),
                .ready => |newest| newest,
            };
            if (goal != version) {
                old_cells = S.borrowVersionRow(table, goal, row_scratch);
                if (!try self.keepJoined(ctx, update.where, joined, old_cells)) return 0;
            }
            return @intFromBool(try self.updateOne(slot, ctx, update, row, goal, old_cells, snap));
        }

        /// Returns false when a BEFORE ROW trigger or a rule skipped the row.
        fn updateOne(self: *Self, slot: u16, ctx: *E.Context, update: *const B.Update, row: u32, old: u32, old_cells: *const E.Row, snap: Snapshot) Error!bool {
            const tx = &self.txs[slot];
            const table = &self.tables[update.table];
            const derived: D.Derived = .{ .defaults = &update.defaults, .generated = &update.generated, .checks = &update.checks };
            const hooked = self.rowHooks(update.table, routine_catalog.tg_update, '2', snap);
            var cells = if (hooked) try D.updatedRowDeferred(ctx, table, &update.values, derived, old_cells) else try D.updatedRow(ctx, table, &update.values, derived, old_cells);
            if (hooked) {
                if (try self.ruleSkips(update.table, '2', &cells, old_cells, snap)) return false;
                if (!try self.beforeRow(update.table, routine_catalog.tg_update, &cells, old_cells, &update.values, snap)) return false;
                try D.finishRow(ctx, table, derived, &cells);
            }
            try self.securityCheck(ctx, update.table, &cells);
            try self.partitionBound(update.table, &cells, snap);
            if (table.primary_column) |column| {
                if (update.values[column] != ast.none) switch (S.primaryKeyCheck(table, &cells[column], row, snap)) {
                    .free => {},
                    .taken => return error.PrimaryKeyViolation,
                    .wait => |owner| {
                        var waits: L.Set = .{};
                        waits.add(owner);
                        return self.park(slot, waits);
                    },
                };
            }
            if ((try self.uniqueTaken(slot, update.table, &cells, row, old_cells, snap)) != null) return error.PrimaryKeyViolation;
            try self.exclusionTaken(slot, update.table, &cells, row, old_cells, snap);
            try self.checkReferences(slot, update.table, &cells, old_cells, snap);
            try self.referencedChange(slot, update.table, old_cells, &cells, snap);
            // A referential action of this statement may have replaced it.
            if (table.versions[old].hasDeletion()) return true;
            _ = tx;
            try self.placeUpdate(slot, update.table, row, old, &cells, snap);
            if (mysqlAutoColumn(table)) |column| {
                if (update.values[column] != ast.none) try self.mysqlSetCounter(slot,
                    try self.identitySequence(update.table, column), cells[column].integer);
            }
            return true;
        }

        fn deleteRows(self: *Self, slot: u16, source: []const u8, delete: *const B.Delete, snap: Snapshot) Error!usize {
            const table = &self.tables[delete.table];
            var ctx = self.evalContext(source);
            var row_scratch: S.VersionRowScratch = undefined;
            var affected: usize = 0;
            const joined = try self.joinedRows(source, delete.using, &delete.offsets, snap);
            switch (try X.candidates(&ctx, table, delete.key, snap)) {
                .empty => {},
                .slot => |hit| affected += try self.deleteSlot(slot, &ctx, &row_scratch, delete, hit.row, snap, joined),
                .scan => {
                    const high = table.row_high;
                    for (0..high) |row| affected += try self.deleteSlot(slot, &ctx, &row_scratch, delete, @intCast(row), snap, joined);
                },
            }
            return affected;
        }

        fn deleteSlot(self: *Self, slot: u16, ctx: *E.Context, row_scratch: *S.VersionRowScratch, delete: *const B.Delete, row: u32, snap: Snapshot, joined: ?Joined) Error!usize {
            try self.session.checkpoint();
            const table = &self.tables[delete.table];
            if (table.rows[row].newest == 0) return 0;
            const version = S.visibleAt(table, row, snap) orelse return 0;
            var waits: L.Set = .{};
            const plan = try self.target(slot, delete.table, version, snap, .write, &waits);
            if (plan == .authored) return 1;
            var old_cells = S.borrowVersionRow(table, version, row_scratch);
            if (!try self.keepJoined(ctx, delete.where, joined, old_cells)) return 0;
            const goal = switch (plan) {
                .skip, .authored => return 0,
                .wait => return self.park(slot, waits),
                .ready => |newest| newest,
            };
            if (goal != version) {
                old_cells = S.borrowVersionRow(table, goal, row_scratch);
                if (!try self.keepJoined(ctx, delete.where, joined, old_cells)) return 0;
            }
            if (self.rowHooks(delete.table, routine_catalog.tg_delete, '4', snap)) {
                if (try self.ruleSkips(delete.table, '4', null, old_cells, snap)) return 0;
                if (!try self.beforeRow(delete.table, routine_catalog.tg_delete, null, old_cells, null, snap)) return 0;
            }
            try self.referencedChange(slot, delete.table, old_cells, null, snap);
            // A self-referencing CASCADE of this statement already deleted it.
            if (table.versions[goal].hasDeletion()) return 1;
            try self.placeDelete(slot, delete.table, goal, snap);
            return 1;
        }

        fn placeDelete(self: *Self, slot: u16, table_index: usize, goal: u32, snap: Snapshot) Error!void {
            const tx = &self.txs[slot];
            const table = &self.tables[table_index];
            try checkPendingLatePrimary(table);
            try self.reserveWrites(slot, 1);
            table.versions[goal].markDeletion(tx.ref(slot), snap.cid);
            tx.push(.{ .kind = .delete, .table = @intCast(table_index), .old = goal }) catch unreachable;
        }

        /// A primary key added to a table created in this transaction changes
        /// the key and metadata but leaves the preceding insert row layout
        /// intact. Log the checked keyed definition before those insert records.
        fn createForWal(self: *const Self, index: usize, writes: anytype) *const S.Table {
            const source = &self.tables[index];
            if (!source.pending_drop) return source;
            var previous = index;
            for (writes) |entry| {
                if (entry.kind != .alter_table or entry.old != previous) continue;
                const change = &self.alters[entry.table];
                if (change.fold_created_primary) return &self.tables[entry.table];
                if (!change.foldable_defaults) break;
                previous = entry.table;
            }
            return source;
        }

        /// Encode writes and their dependencies; rolled-back slices were truncated.
        fn encodeWrites(self: *const Self, writer: *change_log.Writer, slot: u16) Error!void {
            const tx = &self.txs[slot];
            var row_scratch: S.VersionRowScratch = undefined;
            for (tx.writes[0..tx.write_len]) |entry| {
                switch (entry.kind) {
                    .insert, .update => {
                        const table = &self.tables[entry.table];
                        const version = &table.versions[entry.new];
                        const tag: change_log.Op = if (entry.kind == .insert) .insert else .update;
                        try C.encodeRow(writer, tag, table.oid, table.rows[version.rowSlot()].rowid, S.versionValues(table, entry.new, &row_scratch));
                    },
                    .delete => {
                        const table = &self.tables[entry.table];
                        try C.encodeDelete(writer, table.oid, table.rows[table.versions[entry.old].rowSlot()].rowid);
                    },
                    .create_table => try C.encodeCreate(writer, self.createForWal(entry.table, tx.writes[0..tx.write_len])),
                    .drop_table => try C.encodeDrop(writer, self.tables[entry.table].oid),
                    .create_sequence => try C.encodeCreateSequence(writer, &self.seqs[entry.table], entry.new != 0),
                    .drop_sequence => try C.encodeDropSequence(writer, self.seqs[entry.table].oid),
                    .truncate, .refresh_rows => try C.encodeTruncate(writer, self.tables[entry.table].oid),
                    .alter_sequence => {
                        const seq = &self.seqs[entry.table];
                        const previous = &self.seqs[entry.old];
                        const ownership_changed = seq.owner != previous.owner or seq.owner_column != previous.owner_column;
                        try C.encodeAlterSequence(writer, seq, ownership_changed);
                    },
                    .create_schema => try C.encodeCreateSchema(writer, &self.schemas[entry.table]),
                    .drop_schema => try C.encodeDropSchema(writer, self.schemas[entry.table].oid),
                    .alter_table => {
                        const alter = &self.alters[entry.table];
                        if (alter.fold_created_primary) continue;
                        const table = &self.tables[entry.table];
                        // The fresh CREATE carries these defaults if a later
                        // primary key was folded into the definition.
                        if (alter.foldable_defaults and self.createForWal(entry.table, tx.writes[0..tx.write_len]) != table) continue;
                        try C.encodeAlter(writer, table, alter.sources[0..table.column_count], alter.fills[0..table.column_count]);
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
                    .large_object_page => {
                        const pages = &self.large_pages.?;
                        const change = pages.changeFromVersions(entry.old, entry.new);
                        try change_log.encodeLargeObjectPage(writer, change.key, if (change.replacement) |version| pages.versionBytes(version) else null);
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

        fn roleBoolean(values: *Sess.Values, setting: CO.RoleBoolean) *bool {
            return switch (setting) {
                .check_function_bodies => &values.check_function_bodies,
                .quote_all_identifiers => &values.quote_all_identifiers,
                .row_security => &values.row_security,
                .synchronize_seqscans => &values.synchronize_seqscans,
                .default_transaction_read_only => &values.read_only,
                .default_transaction_deferrable => &values.deferrable,
            };
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

        const SettingKind = enum { search_path, check_function_bodies, row_security, synchronize_seqscans, restrict_nonsystem_relation_kind, default_transaction_isolation, default_transaction_read_only, default_transaction_deferrable, transaction_isolation, transaction_read_only, transaction_deferrable, custom, role, session_authorization, quote_all_identifiers };

        const SettingDescriptor = struct {
            kind: SettingKind,
            vartype: []const u8,
            description: []const u8,
            category: []const u8 = "Client Connection Defaults / Statement Behavior",
        };

        const setting_descriptors = [_]SettingDescriptor{
            .{ .kind = .check_function_bodies, .vartype = "bool", .description = "Validate routine bodies during CREATE FUNCTION and CREATE PROCEDURE." },
            .{ .kind = .default_transaction_deferrable, .vartype = "bool", .description = "Default deferrable mode for new transactions." },
            .{ .kind = .default_transaction_isolation, .vartype = "enum", .description = "Default isolation level for new transactions." },
            .{ .kind = .default_transaction_read_only, .vartype = "bool", .description = "Default read-only mode for new transactions." },
            .{ .kind = .quote_all_identifiers, .vartype = "bool", .description = "When generating SQL fragments, quote all identifiers.", .category = "Version and Platform Compatibility / Previous PostgreSQL Versions" },
            .{ .kind = .restrict_nonsystem_relation_kind, .vartype = "string", .description = "Disallow access to selected kinds of non-system relations." },
            .{ .kind = .search_path, .vartype = "string", .description = "Schema search order for unqualified names." },
        };

        fn settingOriginBit(kind: SettingKind) u8 {
            for (setting_descriptors, 0..) |descriptor, index| {
                if (descriptor.kind == kind) return @as(u8, 1) << @as(u3, @intCast(index));
            }
            return 0;
        }

        fn engineSettingValue(values: *const Sess.Values, kind: SettingKind) ?[]const u8 {
            return switch (kind) {
                .search_path => values.search_path.slice(),
                .check_function_bodies => onOff(values.check_function_bodies),
                .quote_all_identifiers => onOff(values.quote_all_identifiers),
                .restrict_nonsystem_relation_kind => values.restriction_text.slice(),
                .default_transaction_isolation => levelName(values.isolation),
                .default_transaction_read_only => onOff(values.read_only),
                .default_transaction_deferrable => onOff(values.deferrable),
                else => null,
            };
        }

        fn isolationNames() Error!Cell {
            const levels = [_]M.Level{ .serializable, .repeatable_read, .read_committed, .read_uncommitted };
            var out: Text = .{};
            var shape: array_module.Shape = .{ .element = .text, .ndim = 1 };
            shape.dims[0] = levels.len;
            var writer = try V.Arrays.Writer.begin(&out, &shape);
            for (levels) |level| {
                const cell = nameCell(levelName(level));
                try writer.append(&cell);
            }
            return .{ .array = out };
        }

        fn settingRows(state: *const Sess.State, sink: *X.RowSink) Error!void {
            const boot: Sess.Values = .{};
            // A projection can run set_config. The scan exposes a consistent
            // initial image even if a row changes its session while projecting.
            const values = state.values;
            for (setting_descriptors, 0..) |descriptor, index| {
                const bit = @as(u8, 1) << @as(u3, @intCast(index));
                const source: []const u8 = if (values.session_settings & bit != 0) "session" else if (values.client_settings & bit != 0) "client" else if (values.role_settings & bit != 0) "user" else "default";
                const enumvals: Cell = if (descriptor.kind == .default_transaction_isolation) try isolationNames() else .null_value;
                try sink.add(&.{
                    try objectTextCell(@tagName(descriptor.kind)), try objectTextCell(engineSettingValue(&values, descriptor.kind).?), .null_value,
                    try objectTextCell(descriptor.category), try objectTextCell(descriptor.description), .null_value,
                    nameCell("user"), nameCell(descriptor.vartype), nameCell(source), .null_value, .null_value, enumvals,
                    try objectTextCell(engineSettingValue(&boot, descriptor.kind).?), try objectTextCell(engineSettingValue(&state.startup, descriptor.kind).?),
                    .null_value, .null_value, boolCell(false),
                });
            }
        }

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
            for ([_][]const u8{ "timezone", "datestyle", "intervalstyle", "xmloption", "application_name", "client_encoding", "client_min_messages", "statement_timeout", "lock_timeout", "idle_in_transaction_session_timeout", "transaction_timeout", "deadlock_timeout", "standard_conforming_strings", "server_version", "server_encoding", "integer_datetimes", "extra_float_digits", "default_table_access_method", "default_tablespace" }) |known| {
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
        /// resolution supports the default public path and an empty explicit
        /// path. Additional schema orderings require resolver support.
        fn searchPath(raw: []const u8, kind: SettingValueKind, out: *Sess.SettingText) Error!void {
            if (kind == .configuration_text and std.mem.trim(u8, raw, " \t\r\n").len == 0) return out.set("");
            if (kind == .string and raw.len == 0) return out.set("\"\"");
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

        fn assignRelationRestrictions(into: *Sess.Values, value_kind: SettingValueKind, value: []const u8) Error!void {
            const spaces = " \t\n\r\x0b\x0c";
            const separators = spaces ++ ",";
            var remainder = std.mem.trim(u8, value, spaces);
            var kinds: value_module.RestrictedRelationKinds = .{};
            var display: Sess.SettingText = .{};
            while (remainder.len != 0) {
                const quote = remainder[0];
                const quoted = quote == '"' or (quote == '\'' and value_kind == .word);
                const end = if (quoted)
                    (std.mem.indexOfScalar(u8, remainder[1..], quote) orelse return error.InvalidSettingValue) + 1
                else
                    std.mem.indexOfAny(u8, remainder, separators) orelse remainder.len;
                const token = remainder[@intFromBool(quoted)..end];
                const canonical: []const u8 = if (Sess.sameInsensitive(token, "view")) name: {
                    kinds.view = true;
                    break :name "view";
                } else if (Sess.sameInsensitive(token, "foreign-table")) name: {
                    kinds.foreign_table = true;
                    break :name "foreign-table";
                } else return error.InvalidSettingValue;
                if (value_kind == .word) {
                    const prefix: []const u8 = if (display.len == 0) "" else ", ";
                    const length: usize = display.len;
                    if (prefix.len + canonical.len > display.bytes.len - length) return error.SessionCapacity;
                    @memcpy(display.bytes[length..][0..prefix.len], prefix);
                    @memcpy(display.bytes[length + prefix.len ..][0..canonical.len], canonical);
                    display.len = @intCast(length + prefix.len + canonical.len);
                }
                remainder = std.mem.trimStart(u8, remainder[end + @intFromBool(quoted) ..], spaces);
                if (remainder.len == 0) break;
                if (remainder[0] != ',') return error.InvalidSettingValue;
                remainder = std.mem.trimStart(u8, remainder[1..], spaces);
                if (remainder.len == 0) return error.InvalidSettingValue;
            }
            if (value_kind != .word) try display.set(value);
            into.restricted_relation_kinds = kinds;
            into.restriction_text = display;
        }

        fn assignSetting(into: *Sess.Values, which: SettingKind, name: []const u8, kind: SettingValueKind, value: []const u8) Error!void {
            switch (which) {
                .search_path => try searchPath(value, kind, &into.search_path),
                .check_function_bodies => into.check_function_bodies = parseBool(value) orelse return error.InvalidSettingValue,
                .row_security => into.row_security = parseBool(value) orelse return error.InvalidSettingValue,
                .synchronize_seqscans => into.synchronize_seqscans = parseBool(value) orelse return error.InvalidSettingValue,
                .quote_all_identifiers => into.quote_all_identifiers = parseBool(value) orelse return error.InvalidSettingValue,
                .restrict_nonsystem_relation_kind => try assignRelationRestrictions(into, kind, value),
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
                .role, .session_authorization => return error.UnsupportedStatement,
            }
        }

        /// Copies one setting from `source` into `target`.
        fn copySetting(into: *Sess.Values, source: *const Sess.Values, which: SettingKind, name: []const u8) Error!void {
            switch (which) {
                .search_path => into.search_path = source.search_path,
                .check_function_bodies => into.check_function_bodies = source.check_function_bodies,
                .row_security => into.row_security = source.row_security,
                .synchronize_seqscans => into.synchronize_seqscans = source.synchronize_seqscans,
                .quote_all_identifiers => into.quote_all_identifiers = source.quote_all_identifiers,
                .restrict_nonsystem_relation_kind => {
                    into.restricted_relation_kinds = source.restricted_relation_kinds;
                    into.restriction_text = source.restriction_text;
                },
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
                .session_authorization => {
                    into.authorization = source.authorization;
                    into.role = source.role;
                },
            }
            const bit = settingOriginBit(which);
            into.client_settings = (into.client_settings & ~bit) | (source.client_settings & bit);
            into.session_settings = (into.session_settings & ~bit) | (source.session_settings & bit);
            into.role_settings = (into.role_settings & ~bit) | (source.role_settings & bit);
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
                .session_authorization => if (self.dialect != .postgres) return error.UnsupportedStatement,
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
                next.role = try self.roleSetting(slot, kind, value, false);
            } else if (which == .session_authorization) {
                next.authorization = try self.roleSetting(slot, kind, value, true);
                next.role = 0;
            } else {
                try assignSetting(&next, which, name, kind, value);
                const bit = settingOriginBit(which);
                next.client_settings &= ~bit;
                next.session_settings |= bit;
            }
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
        fn roleSetting(self: *Self, slot: ?u16, kind: SettingValueKind, value: []const u8, authorization: bool) Error!u32 {
            var folded: [64]u8 = undefined;
            var length: usize = 0;
            if (kind == .word and value.len >= 2 and value[0] == '"') {
                // A quoted identifier keeps its case; "" is one quote.
                var index: usize = 1;
                while (index + 1 < value.len) : (index += 1) {
                    if (length == folded.len) return error.InvalidSettingValue;
                    folded[length] = value[index];
                    length += 1;
                    if (value[index] == '"') index += 1;
                }
                if (length == 0) return error.InvalidSettingValue;
            } else {
                if (value.len > folded.len) return error.InvalidSettingValue;
                for (value, 0..) |byte, index| folded[index] = if (kind == .word) types.lower(byte) else byte;
                length = value.len;
                if (!authorization and kind == .word and types.same(folded[0..length], "none")) return 0;
            }
            const name = folded[0..length];
            const snap = self.settingSnapshot(slot);
            const oid = self.catalog_objects.roleByName(name, snap) orelse return if (authorization) error.UndefinedObject else error.InvalidSettingValue;
            const state = self.sessionState();
            if (authorization) {
                if (oid == state.session_role) return 0;
                if (!self.catalog_objects.superuser(state.session_role, snap)) return error.InsufficientPrivilege;
                return oid;
            }
            const session_role = state.sessionUser();
            if (!self.catalog_objects.superuser(session_role, snap) and !self.catalog_objects.membershipPath(session_role, oid, .set, snap)) return error.InsufficientPrivilege;
            return oid;
        }

        /// current_user / session_user of the next statement, from the
        /// session state (SET ROLE).
        fn installRole(self: *Self) void {
            const state = self.session_state orelse &self.default_session_state;
            self.session.session_role = state.sessionUser();
            self.session.role = effectiveRole(state);
            self.session.public_schema_on_path = state.values.publicSchemaOnPath();
            self.session.row_security = state.values.row_security;
            self.session.synchronize_seqscans = self.dialect == .postgres and state.values.synchronize_seqscans;
            self.session.quote_all_identifiers = state.values.quote_all_identifiers;
            self.session.restricted_relation_kinds = state.values.restricted_relation_kinds;
        }

        /// RESET ALL of the engine settings (transaction modes excepted).
        fn resetSettings(self: *Self, slot: ?u16) Error!void {
            const state = self.sessionState();
            if (slot != null) try state.preserve();
            const active_role = state.values.role;
            const active_authorization = state.values.authorization;
            const base_role = state.base.role;
            const base_authorization = state.base.authorization;
            state.values = state.startup;
            state.base = state.startup;
            state.values.role = active_role;
            state.values.authorization = active_authorization;
            state.base.role = base_role;
            state.base.authorization = base_authorization;
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
            const text: []const u8 = engineSettingValue(&state.values, which) orelse switch (which) {
                .row_security => onOff(state.values.row_security),
                .synchronize_seqscans => onOff(state.values.synchronize_seqscans),
                .transaction_isolation => levelName(if (tx) |t| t.isolation else state.values.isolation),
                .transaction_read_only => onOff(if (tx) |t| t.read_only else state.values.read_only),
                .transaction_deferrable => onOff(if (tx) |t| t.deferrable else state.values.deferrable),
                .custom => blk: {
                    const index = state.values.findCustom(name) orelse return error.UndefinedSetting;
                    break :blk state.values.custom[index].value.slice();
                },
                .role => if (state.values.role == 0) "none" else self.catalog_objects.roleName(state.values.role, self.settingSnapshot(slot)) orelse "none",
                .session_authorization => self.catalog_objects.roleName(state.sessionUser(), self.settingSnapshot(slot)) orelse return error.UndefinedObject,
                else => unreachable,
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

        /// Engine settings safe to configure before a connection authenticates.
        pub fn sessionStartupSetting(self: *Self, name: []const u8, value: []const u8) Error!bool {
            const setting = settingKind(name) orelse return false;
            switch (setting) {
                .check_function_bodies, .row_security, .synchronize_seqscans, .restrict_nonsystem_relation_kind, .quote_all_identifiers,
                .default_transaction_read_only, .default_transaction_deferrable => {},
                else => return false,
            }
            try self.setSetting(null, false, name, .string, value);
            const state = self.sessionState();
            const bit = settingOriginBit(setting);
            state.values.session_settings &= ~bit;
            state.values.client_settings |= bit;
            inline for (@typeInfo(CO.RoleBoolean).@"enum".field_names) |field| {
                if (setting == @field(SettingKind, field)) state.client_role_booleans |= @field(CO.RoleBoolean, field).bit();
            }
            state.base = state.values;
            state.startup = state.values;
            return true;
        }

        /// Apply committed defaults once the PostgreSQL session's role is known.
        /// Explicit startup options already in the state have higher priority.
        pub fn applyRoleDefaults(self: *const Self, state: *Sess.State) void {
            const key: O.Object = .{ .kind = .role_settings, .target = state.session_role };
            const found = self.catalog_objects.findKey(&key, .{ .csn = self.csn }) orelse return;
            const row = &self.catalog_objects.items[found];
            const applicable = row.flags & ~state.client_role_booleans;
            inline for (@typeInfo(CO.RoleBoolean).@"enum".field_names) |field| {
                const setting = @field(CO.RoleBoolean, field);
                const bit = setting.bit();
                if (applicable & bit != 0) {
                    roleBoolean(&state.values, setting).* = row.grant_flags & bit != 0;
                    state.values.role_settings |= settingOriginBit(@field(SettingKind, field));
                }
            }
            state.base = state.values;
            state.startup = state.values;
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

        fn runControl(self: *Self, slot: u16, source: []const u8, command: ast.Control, snap: Snapshot, result: *Result) Error!void {
            switch (command) {
                .maintenance => |spec| {
                    if (self.dialect != .postgres) return error.UnsupportedStatement;
                    if (spec.operation == .vacuum and !self.statement_implicit) return error.ActiveSqlTransaction;
                    const context = self.bindContext(source, .standard, snap);
                    const index = try B.resolveQualified(&context, spec.schema, spec.name);
                    const table = &self.tables[index];
                    if (table.relkind != 'r' and table.relkind != 'm') return error.WrongObjectType;
                    if (self.hasChildren(table.oid, snap)) return error.UnsupportedStatement;
                    const owner = self.catalog_objects.owner(table.oid, snap);
                    const role = self.session.role;
                    if (role != CO.bootstrap_role and !self.catalog_objects.memberOf(role, owner, true, snap)) return error.InsufficientPrivilege;
                    try self.lockTable(slot, index, .share_update_exclusive);
                    if (spec.operation == .analyze) {
                        try self.analyzeTable(table);
                        self.outcome = .{ .command = .analyze, .noop = true };
                        return;
                    }
                    const horizon_csn = self.horizon();
                    var first: usize = 0;
                    while (first < table.version_high) {
                        const count = @min(table.version_high - first, 256);
                        try self.session.checkpoints(count);
                        _ = S.vacuumRange(table, horizon_csn, first, first + count);
                        first += count;
                    }
                    self.outcome = .{ .command = .vacuum, .noop = true };
                },
                // Already in a transaction block: PostgreSQL warns and ignores it.
                // An implicit (autocommit) statement cannot open a block: it
                // would commit at once while the caller believes it is open.
                .begin => {
                    if (self.statement_implicit) return error.UnsupportedStatement;
                    self.outcome = .{ .command = .begin };
                },
                .commit, .rollback, .prepared_transaction, .savepoint, .release, .rollback_to => return error.UnsupportedStatement,
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

        fn analyzeTable(self: *Self, table: *S.Table) Error!void {
            // Build the committed statistics off to the side. Existing rollups
            // and historical integer bounds have their own maintenance rules.
            if (!table.summary.valid) return error.UnsupportedStatement;
            const committed: Snapshot = .{ .csn = self.csn };
            var summary: S.Summary = .{ .valid = true, .csn = committed.csn };
            var first: usize = 0;
            var row_scratch: S.VersionRowScratch = undefined;
            while (first < table.row_high) {
                const count = @min(table.row_high - first, 256);
                try self.session.checkpoints(count);
                for (first..first + count) |row| {
                    const version = S.visibleAt(table, row, committed) orelse continue;
                    S.observeSummary(&summary, S.versionValues(table, version, &row_scratch), table.primary_column, true, committed.csn);
                }
                first += count;
            }
            table.summary = summary;
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
                if (reference.schema == null and !self.session.public_schema_on_path) return error.TableNotFound;
                const schema_name = if (reference.schema) |qualifier| identName(source, qualifier) else Name{};
                const namespace = (try self.namespaceForUsage(self.session.role, if (reference.schema != null) schema_name.slice() else null, snap)) orelse return error.UndefinedSchema;
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
            const inner = try P.parseWithOptions(inner_source, &self.workspace.nodes, .{ .mode = mode, .dialect = self.dialect });
            const locking = switch (inner) {
                .select, .query => |query| self.workspace.nodes.queries[query].lock.strength != .none,
                else => return error.Syntax,
            };
            // PostgreSQL: FOR UPDATE/SHARE cursors cannot be SCROLL or WITH HOLD.
            if (locking and ((declare.scroll orelse false) or declare.hold)) return error.UnsupportedStatement;
            try self.body(slot, inner_source, &inner, snap, result, .{ .mode = mode });
            const rows = result.row_count;
            if (rows > Sess.cursor_row_capacity - self.cursors.used_rows) return error.SessionCapacity;
            const columns = result.column_count;
            var values: types.ValueBytes = .{ .bytes = &self.cursors.value_backing, .used = self.cursors.value_used };
            const value_base = values.used;
            if (result.values.used > values.available().len) return error.SessionCapacity;
            for (0..rows) |row| {
                const destination = self.cursors.rows[self.cursors.used_rows + row].cells[0..columns];
                const input = result.rows[row].cells[0..columns];
                if (result.values.used == 0) {
                    @memcpy(destination, input);
                } else {
                    for (destination, input) |*to, *from| {
                        to.* = if (V.largeBytes(from)) |bytes| V.largeCell(from, try values.copy(bytes)) else from.*;
                    }
                }
            }
            const cursor = &self.cursors.slots[index];
            cursor.* = .{ .used = true, .session = state.id, .hold = declare.hold, .scroll = declare.scroll orelse true, .epoch = tx.epoch, .slot = slot, .depth = tx.userSavepoints(), .column_count = columns, .base = self.cursors.used_rows, .count = rows, .value_base = value_base, .value_len = values.used - value_base };
            @memcpy(cursor.name.bytes[0..name.len], name.slice());
            cursor.name.len = name.len;
            @memcpy(cursor.names[0..columns], result.column_names[0..columns]);
            @memcpy(cursor.column_types[0..columns], result.column_types[0..columns]);
            @memcpy(cursor.typmods[0..columns], result.column_typmods[0..columns]);
            cursor.has_nominal_types = result.has_nominal_types;
            if (result.has_nominal_types) @memcpy(cursor.nominal_types[0..columns], result.nominal_types[0..columns]);
            self.cursors.used_rows += rows;
            self.cursors.value_used = values.used;
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
            if (cursor.has_nominal_types) result.setNominalTypes(cursor.nominal_types[0..columns]);
            for (0..step.rows) |row| {
                const at = if (step.backward) step.first - row else step.first + row;
                const output = result.rows[row].cells[0..columns];
                const input = self.cursors.rows[cursor.base + at - 1].cells[0..columns];
                if (cursor.value_len != 0) try result.copyCells(output, input) else @memcpy(output, input);
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
            const inner = try P.parseWithOptions(text, &self.workspace.nodes, .{ .mode = mode, .dialect = self.dialect });
            self.active_params = &params;
            defer self.active_params = null;
            var copy = inner;
            // Parse analysis checks no privileges (EXECUTE does).
            const expanded = try expandRelations(self, &self.workspace, text, snap, &copy, CO.bootstrap_role, &self.session);
            var context = self.bindContext(expanded, mode, snap);
            context.stored_source_start = text.len;
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
            const inner = try P.parseWithOptions(text, &self.workspace.nodes, .{ .mode = mode, .dialect = self.dialect });
            self.active_params = &params;
            self.session.params = @ptrCast(&self.param_values);
            defer {
                self.active_params = null;
                self.session.params = null;
            }
            try self.body(slot, text, &inner, snap, result, .{ .mode = mode });
        }

        /// current_setting / set_config / advisory locks / pg_backend_pid
        /// for the running statement (Session.engine).
        fn sessionCall(ptr: *anyopaque, kind: value_module.SessionCall, a: []const u8, b: []const u8, x: i64, y: i64, flags: u8, out: []u8) Error!value_module.SessionReply {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const slot = self.seq_slot;
            switch (kind) {
                .backend_pid => return .{ .integer = self.sessionState().pid },
                .recovery_status => return .{ .integer = @intFromBool(self.startupRecoveryActive()) },
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
                    const form: SettingValueKind = if (flags & 2 != 0) .default else if (Sess.sameInsensitive(a, "search_path")) .configuration_text else .string;
                    try self.setSetting(slot, flags & 1 != 0, a, form, b);
                    self.installRole();
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
                try self.body(slot, text, parsed, snap, result, .{ .mode = .standard });
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
            const source = try expandRelations(self, &self.workspace, text, snap, parsed, self.session.role, &self.session);
            var context = self.bindContext(source, .standard, snap);
            context.stored_source_start = text.len;
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
                try self.secureNewRows(&bound, source, snap);
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
                .grant_execute, .revoke_execute => |*grant| try self.grantRoutine(slot, grant, kind == .grant_execute, snap),
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

        fn takeConstraintOid(self: *Self) Error!u32 {
            if (self.next_constraint_oid == 0xffffffff) return error.TableCapacity;
            const oid = self.next_constraint_oid;
            self.next_constraint_oid += 1;
            return oid;
        }

        fn assignConstraintOids(self: *Self, table: *S.Table, previous: ?*const S.Table) Error!void {
            if (S.keyed(table)) {
                const saved = if (previous) |old| old.primary_constraint_oid else 0;
                table.primary_constraint_oid = if (saved == 0) try self.takeConstraintOid() else saved;
            }
            for (table.constraints[0..table.constraint_count]) |*constraint| {
                if (constraint.kind == .primary) continue;
                if (previous == null or constraint.oid == 0) constraint.oid = try self.takeConstraintOid();
            }
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

        /// CREATE [OR REPLACE] FUNCTION / PROCEDURE: validates the signature
        /// and optionally analyzes the quoted body before writing its version.
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
                if (!self.ownsRoutine(old, snap)) return error.InsufficientPrivilege;
                if (old.kind != kind) return error.WrongObjectType;
                if (old.return_oid != definition.return_oid or old.return_typmod != definition.return_typmod) return error.InvalidFunctionDefinition;
                for (0..old.arg_count) |position| {
                    if (!types.same(old.arg_names[position].slice(), definition.args[position].name.slice())) return error.InvalidFunctionDefinition;
                }
            }
            const owner = if (existing) |old| self.objects.routines[old].owner else self.session.role;
            if (self.catalog_objects.pendingReference(owner, snap)) |other| return self.objectPark(slot, other);
            var latest = snap;
            latest.csn = self.csn;
            if (self.catalog_objects.roleName(owner, latest) == null) return error.SerializationFailure;
            if (definition.return_oid == tg.trigger_oid and (definition.language == 0 or definition.arg_count != 0)) return error.InvalidFunctionDefinition;
            if (self.sessionState().values.check_function_bodies) try self.validateRoutine(definition, snap);
            try self.reserveWrites(slot, 2);
            const index = try self.objectSlot(.routine);
            const oid = if (existing) |old| self.objects.routines[old].oid else try self.takeOid();
            const acl: RC.ExecuteAcl = if (existing) |old| self.objects.routines[old].acl else .{};
            if (existing) |old| try self.dropObject(slot, .routine, old, snap);
            const item = &self.objects.routines[index];
            item.* = .{ .oid = oid, .namespace = namespace, .owner = owner, .acl = acl, .name = definition.name, .kind = kind, .language = definition.language, .volatility = definition.volatility, .strict = definition.strict, .arg_count = definition.arg_count, .return_oid = definition.return_oid, .return_typmod = definition.return_typmod, .body = definition.body };
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
                const source = try expandRelations(self, &self.workspace, text, snap, &parsed, CO.bootstrap_role, &self.session);
                var context = self.bindContext(source, .standard, snap);
                context.stored_source_start = text.len;
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
        fn ownsRoutine(self: *const Self, routine: *const RC.Routine, snap: Snapshot) bool {
            return self.catalog_objects.superuser(self.session.role, snap) or self.catalog_objects.memberOf(self.session.role, routine.owner, true, snap);
        }

        fn canExecuteRoutine(self: *const Self, routine: *const RC.Routine, snap: Snapshot) bool {
            if (routine.acl.public or self.catalog_objects.superuser(self.session.role, snap)) return true;
            if (routine.acl.owner and self.catalog_objects.memberOf(self.session.role, routine.owner, true, snap)) return true;
            for (routine.acl.roles()) |role| {
                if (self.catalog_objects.memberOf(self.session.role, role, true, snap)) return true;
            }
            return false;
        }

        fn findRoutineTarget(self: *Self, slot: u16, drop: *const R.DropRoutine, snap: Snapshot) Error!?usize {
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
            if (found) |index| {
                if ((self.objects.routines[index].kind == 'p') != drop.procedure) return error.WrongObjectType;
            }
            return found;
        }

        fn grantRoutine(self: *Self, slot: u16, grant: *const R.ExecuteGrant, allow: bool, snap: Snapshot) Error!void {
            const index = (try self.findRoutineTarget(slot, &grant.routine, snap)) orelse return error.UndefinedFunction;
            const old = &self.objects.routines[index];
            if (!self.ownsRoutine(old, snap)) return error.InsufficientPrivilege;
            const role = if (grant.grantee.len == 0) CO.public_role else
                self.catalog_objects.roleByName(grant.grantee.slice(), snap) orelse return error.UndefinedObject;
            if (role != CO.public_role) {
                if (self.catalog_objects.pendingReference(role, snap)) |other| return self.objectPark(slot, other);
                var latest = snap;
                latest.csn = self.csn;
                if (self.catalog_objects.roleName(role, latest) == null) return error.SerializationFailure;
            }
            var acl = old.acl;
            try acl.set(role, old.owner, allow);
            try self.reserveWrites(slot, 2);
            const next = try self.objectSlot(.routine);
            try self.dropObject(slot, .routine, index, snap);
            self.objects.routines[next] = old.*;
            self.objects.routines[next].acl = acl;
            self.createdObject(slot, .routine, next, snap);
        }

        fn dropRoutine(self: *Self, slot: u16, drop: *const R.DropRoutine, snap: Snapshot) Error!void {
            const index = (try self.findRoutineTarget(slot, drop, snap)) orelse {
                if (drop.if_exists) return;
                return error.UndefinedFunction;
            };
            const routine = &self.objects.routines[index];
            if (!self.ownsRoutine(routine, snap)) return error.InsufficientPrivilege;
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
            if (!self.canExecuteRoutine(routine, snap)) return error.InsufficientPrivilege;
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
            if (!self.canExecuteRoutine(routine, self.routine_snap)) return error.InsufficientPrivilege;
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
                if (entry.kind != .delete) S.copyVersionRow(table, entry.new, &new_row);
                if (entry.kind != .insert) S.copyVersionRow(table, entry.old, &old_row);
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
            if (!self.canExecuteRoutine(routine, snap)) return error.InsufficientPrivilege;
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
            if (name.schema.len == 0 and !self.session.public_schema_on_path) return error.TableNotFound;
            const namespace = (try self.namespaceForUsage(self.session.role, if (name.schema.len != 0) name.schema.slice() else null, snap)) orelse return error.UndefinedSchema;
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

        fn routineAcl(self: *const Self, routine: *const RC.Routine, snapshot: Snapshot) Error!Cell {
            const acl = &routine.acl;
            if (!acl.explicit) return .null_value;
            const owner = self.catalog_objects.roleName(routine.owner, snapshot) orelse return error.UndefinedObject;
            const Acl = @import("sql/catalog_acl.sig").Acl(V);
            var output: Text = .{};
            const count = @as(u32, acl.count) + @intFromBool(acl.public) + @intFromBool(acl.owner);
            var writer = try Acl.begin(&output, count);
            if (acl.public) try Acl.append(&writer, "", "X", owner);
            if (acl.owner) try Acl.append(&writer, owner, "X", owner);
            for (acl.roles()) |role| {
                const name = self.catalog_objects.roleName(role, snapshot) orelse return error.UndefinedObject;
                try Acl.append(&writer, name, "X", owner);
            }
            return .{ .array = output };
        }

        /// pg_proc, pg_trigger, pg_rewrite and pg_rules rows.
        fn objectViewRows(self: *const Self, snapshot: Snapshot, view: catalog_module.View, sink: *X.RowSink) Error!void {
            switch (view) {
                .pg_proc => {
                    for (catalog_module.builtin_callbacks) |callback| {
                        var buffer: [43]u8 = undefined;
                        var argtypes: CatalogTextWriter = .{ .out = &buffer };
                        for (callback.args, 0..) |oid, index| {
                            if (index != 0) argtypes.add(" ");
                            var digits: [10]u8 = undefined;
                            argtypes.add(std.fmt.bufPrint(&digits, "{d}", .{oid}) catch unreachable);
                        }
                        try sink.add(&.{
                            intCell(callback.oid), nameCell(callback.name), intCell(catalog_module.catalog_namespace),
                            .{ .pg_internal_char = 'f' }, intCell(callback.language), .{ .pg_internal_char = callback.volatility },
                            boolCell(callback.strict), intCell(@intCast(callback.args.len)), intCell(callback.result), nameCell(argtypes.slice()),
                            nameCell(callback.source orelse callback.name), intCell(CO.bootstrap_role), .null_value,
                        });
                    }
                    for (catalog_module.access_methods) |am| {
                        var args: [10]u8 = undefined;
                        const arg_oid = std.fmt.bufPrint(&args, "{d}", .{catalog_module.internal_type_oid}) catch unreachable;
                        try sink.add(&.{
                            intCell(am.handler), nameCell(am.handler_name), intCell(catalog_module.catalog_namespace),
                            .{ .pg_internal_char = 'f' }, intCell(operator_catalog.internal_language_oid), .{ .pg_internal_char = 'v' },
                            boolCell(true), intCell(1), intCell(am.result), nameCell(arg_oid), nameCell(am.handler_name),
                            intCell(CO.bootstrap_role), .null_value,
                        });
                    }
                    for (operator_catalog.functions) |op| {
                        var buffer: [24]u8 = undefined;
                        const args = if (op.left == 0)
                            std.fmt.bufPrint(&buffer, "{d}", .{op.right}) catch unreachable
                        else
                            std.fmt.bufPrint(&buffer, "{d} {d}", .{ op.left, op.right }) catch unreachable;
                        try sink.add(&.{
                            intCell(op.function_oid), nameCell(op.function_name), intCell(catalog_module.catalog_namespace),
                            .{ .pg_internal_char = 'f' }, intCell(operator_catalog.internal_language_oid), .{ .pg_internal_char = op.volatility },
                            boolCell(op.strict), intCell(if (op.left == 0) 1 else 2), intCell(op.result), nameCell(args),
                            nameCell(op.function_name), intCell(CO.bootstrap_role), .null_value,
                        });
                    }
                    for (&self.objects.routines) |*routine| {
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
                        const language = if (routine.language == 0) catalog_module.sql_language_oid else catalog_module.plpgsql_language_oid;
                        try sink.add(&.{ intCell(routine.oid), nameCell(routine.name.slice()), intCell(routine.namespace), .{ .pg_internal_char = routine.kind }, intCell(language), .{ .pg_internal_char = routine.volatility }, boolCell(routine.strict), intCell(@intCast(routine.arg_count)), intCell(routine.return_oid), nameCell(argtypes[0..at]), nameCell(routine.body.slice()), intCell(routine.owner), try self.routineAcl(routine, snapshot) });
                    }
                },
                .pg_trigger => for (&self.objects.triggers) |*trigger| {
                    if (!trigger.live or !trigger.stamp.visible(snapshot)) continue;
                    try sink.add(&.{ intCell(trigger.oid), intCell(trigger.table_oid), nameCell(trigger.name.slice()), intCell(trigger.function_oid), intCell(trigger.tgtype), nameCell("O"), boolCell(false), intCell(@intCast(trigger.nargs)), intCell(0) });
                },
                .pg_rewrite => {
                    for (&self.objects.rules) |*rule| {
                        if (!rule.live or !rule.stamp.visible(snapshot)) continue;
                        try sink.add(&.{ intCell(rule.oid), nameCell(rule.name.slice()), intCell(rule.table_oid), .{ .pg_internal_char = rule.event }, .{ .pg_internal_char = 'O' }, boolCell(rule.instead) });
                    }
                    var visible: [K.relation_rows]K.Found = undefined;
                    const count = self.catalog.visibleRelations(snapshot, &visible);
                    for (visible[0..count]) |relation| {
                        if (relation.kind != 'v' and relation.kind != 'm') continue;
                        const relation_oid = self.tables[relation.slot].oid;
                        // Catalog identities are (class, OID). An explicit
                        // rule uses a different allocated OID from its view.
                        try sink.add(&.{ intCell(relation_oid), nameCell("_RETURN"), intCell(relation_oid), .{ .pg_internal_char = '1' }, .{ .pg_internal_char = 'O' }, boolCell(true) });
                    }
                },
                .pg_rules => for (&self.objects.rules) |*rule| {
                    if (!rule.live or !rule.stamp.visible(snapshot)) continue;
                    const table_index = self.visibleTableSlot(rule.table_oid, snapshot) orelse continue;
                    const table = &self.tables[table_index];
                    const schema_name = self.namespaceName(table.namespace);
                    var text: [512]u8 = undefined;
                    var definition: CatalogTextWriter = .{ .out = &text };
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
                lexer.decodeQuotedIdentifier(source, .{ .start = ident.span.start, .end = ident.span.start + ident.span.len, .len = ident.len }, &out.bytes);
            } else for (raw, 0..) |byte, index| {
                out.bytes[index] = types.lower(byte);
            }
        }

        fn settingName(source: []const u8, name: ast.SettingName, out: *ControlText) Error!void {
            const special: []const u8 = switch (name.special) {
                .none => return decodeIdent(source, name.ident, out),
                .time_zone => "timezone",
                .xml_option => "xmloption",
                .session_authorization => "session_authorization",
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
                .word => {
                    const raw = value.span.slice(source);
                    if (raw.len > out.bytes.len) return error.InvalidSettingValue;
                    out.len = raw.len;
                    @memcpy(out.bytes[0..raw.len], raw);
                },
                .number => {
                    var raw = value.span.slice(source);
                    if (value.integer) {
                        while (raw.len > 1 and raw[0] == '0' and types.digit(raw[1])) raw = raw[1..];
                    }
                    const prefix: usize = @intFromBool(value.number_sign != 0);
                    if (raw.len + prefix > out.bytes.len) return error.InvalidSettingValue;
                    if (prefix != 0) out.bytes[0] = value.number_sign;
                    @memcpy(out.bytes[prefix..][0..raw.len], raw);
                    out.len = raw.len + prefix;
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
            if (@import("std").ascii.eqlIgnoreCase(first.raw(source), "prepare")) {
                const second = tokens.next() catch return false;
                return second.isWord("TRANSACTION");
            }
            return switch (first.keyword) {
                .begin, .start, .commit, .end, .abort, .rollback, .savepoint, .release, .set, .show, .reset => true,
                else => false,
            };
        }

        /// Decodes a transaction-control or session command; `.none` for an
        /// ordinary statement. Syntax errors in a control command return.
        pub fn control(self: *Self, source: []const u8) Error!Control {
            if (!controlWord(source)) return .none;
            const parsed = try P.parseWithOptions(source, &self.workspace.nodes, .{ .dialect = self.dialect });
            const command = switch (parsed) {
                .control => |command| command,
                else => return .none,
            };
            var out: Control = .none;
            switch (command) {
                .maintenance => {}, // The statement path owns the relation lock and interruption state.
                .begin => |modes| out = .{ .begin = modes },
                .commit => out = .commit,
                .rollback => out = .rollback,
                .prepared_transaction => |prepared| {
                    var gid: ?two_phase.Gid = null;
                    if (prepared.gid.len <= 199) {
                        var decoded: [199]u8 = undefined;
                        lexer.decodeQuoted(source, prepared.gid, &decoded);
                        gid = two_phase.Gid.init(decoded[0..prepared.gid.len]) catch null;
                    }
                    out = .{ .prepared_transaction = .{ .action = prepared.action, .gid = gid } };
                },
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
            self.installRole();
            if (R.classify(source)) |kind| {
                var routine: R.Statement = undefined;
                try R.parse(source, &self.workspace.nodes, &routine);
                result.clear(0);
                result.command = R.command(kind);
                return;
            }
            const top = try P.parseTopWithOptions(source, &self.workspace.nodes, .{ .dialect = self.dialect });
            const parsed = top.command;
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
            const expanded = try expandRelations(self, &self.workspace, source, snap, &statement_copy, CO.bootstrap_role, &self.session);
            var context = self.bindContext(expanded, .standard, snap);
            context.stored_source_start = source.len;
            context.describe_only=true;
            if (parsed == .select) context.user_type_catalog = &self.catalog_objects;
            const bound = try B.bind(&context, &statement_copy);
            if (top.explain != null) {
                try self.validateExplain(&bound);
                explainHeader(result);
                return;
            }
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
                result.non_null_columns = list.non_null_columns;
                @memcpy(result.column_names[0..list.count], list.names[0..list.count]);
                @memcpy(result.column_types[0..list.count], list.types[0..list.count]);
                @memcpy(result.column_typmods[0..list.count], list.typmods[0..list.count]);
            }
            if (bound == .select) {
                result.column_count = bound.select.count;
                result.non_null_columns = bound.select.non_null_columns;
                if (bound.select.has_nominal_types) result.setNominalTypes(bound.select.nominal_types[0..bound.select.count]);
                for (0..bound.select.count) |index| {
                    result.column_names[index] = bound.select.names[index];
                    result.column_types[index] = bound.select.types[index];
                    result.column_typmods[index] = bound.select.typmods[index];
                }
            }
            if (bound == .query) {
                const plan = &self.workspace.plans.items[bound.query];
                result.column_count = plan.count;
                result.non_null_columns = plan.non_null_columns;
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
            if (S.anyIntegralBank(&self.tables)) for (&self.txs) |*tx| {
                if (tx.active) return error.InvalidParameterValue;
            };
            if (comptime config.external_workspace) if (self.workspace.query.cells.len == 0) return error.InvalidParameterValue;
            if (comptime config.external_storage) if (self.workspace.query.refs.len == 0) return error.InvalidParameterValue;
            try C.apply(self, record, scratch);
            self.reclaimTables(self.csn);
            self.wake_epoch +%= 1;
        }

        pub fn replayQuiescent(self: *const Self) bool {
            for (&self.txs) |*tx| if (tx.active) return false;
            return true;
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

        /// Appends catalog OID counters and every live table's next row ID.
        pub fn encodeCatalogCounters(self: *const Self, record: []u8, used: *usize) Error!void {
            var writer = try change_log.Writer.init(record, used.*);
            try C.encodeCounters(&writer, change_log.first_oid + self.oid_counter, self.next_constraint_oid, self.next_default_oid, &self.tables);
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
            if (self.large_pages) |*pages| freed += pages.reclaim(at);
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
