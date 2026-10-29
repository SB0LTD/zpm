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
//! ZONE, the JSONB operators `-> ->> #> #>> @> <@ ?`, CASE, COALESCE, NULLIF,
//! `::`/CAST, now() / CURRENT_TIMESTAMP / statement_timestamp() /
//! clock_timestamp() / CURRENT_DATE, jsonb_typeof and jsonb_array_length,
//! typed with PostgreSQL's implicit-cast rules. Constraints are NOT NULL and
//! a single-column PRIMARY KEY. Unquoted identifiers are ASCII and case
//! insensitive; quoted identifiers keep case; text comparison is bytewise.
//! Window functions, other functions, arrays and secondary indices are
//! outside this SQL subset; this is not full SQL-standard or PostgreSQL
//! compatibility.
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

        pub const Outcome = struct { affected: usize = 0, command: CommandTag = .none, returning: Returned = .{} };

        /// Statement-scoped scratch inside caller-owned database storage.
        pub const Workspace = struct {
            nodes: A.Pool = .{},
            plans: B.Plans = .{},
            query: X.Work = .{},
        };
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
                    for(&db.tables) |*table| inline for(.{"rows","versions","row_index","key_index","scan_values","scan_nonnull","scan_live","scan_presence"}) |name| {
                        if(overlaps(part,try span(@field(table,name)[0..]))) return error.InvalidParameterValue;
                    };
                }
            }
            /// Callbacks in session (clock/zone resolver/control) must themselves
            /// be safe for concurrent reads. Sequence hooks are always disabled.
            pub fn prepare(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot) Error!void {
                try self.validate(db,source,null);
                self.prepared=null;
                self.preparation_error=null;self.database=db;self.source=source;self.snapshot=snapshot;
                self.prepareBody(db,source,snapshot) catch |err| {self.preparation_error=err;return err;};
            }
            fn prepareBody(self:*Context,db:*const Self,source:[]const u8,snapshot:Snapshot) Error!void {
                self.session.sequences=null;
                const parsed=try P.parse(source,&self.workspace.nodes,.standard);
                switch(parsed){.select,.query=>{},else=>return error.UnsupportedStatement}
                try self.session.checkpoint();
                for(self.workspace.nodes.queries[0..self.workspace.nodes.query_len]) |query| {
                    if(query.lock.strength!=.none) return error.UnsupportedStatement;
                }
                const context:B.Context=.{.source=source,.tables=&db.tables,.catalog=&db.catalog,.snapshot=snapshot,
                    .pool=&self.workspace.nodes,.legacy=false,.dialect=self.dialect,.session=&self.session,.plans=&self.workspace.plans};
                const bound=try B.bind(&context,&parsed);
                for(self.workspace.nodes.nodes[0..self.workspace.nodes.len]) |node| switch(node.func) {
                    .nextval,.currval,.setval,.lastval,.identity_next=>return error.UnsupportedStatement,
                    else=>{},
                };
                self.prepared=switch(bound){.select=>|select| .{.simple=select},.query=>|root| .{.general=root},else=>return error.UnsupportedStatement};
                self.database=db;self.source=source;self.snapshot=snapshot;
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
                    .simple=>|*select| try X.select(&db.tables,self.source,&self.workspace.nodes,select,self.snapshot,result,X.NoLock{},
                        &self.session,self.snapshot.epoch==0,&self.workspace.query.read_stats,&self.workspace.query),
                    .general=>|root| try X.runQuery(&db.tables,self.source,&self.workspace.nodes,&self.workspace.plans,root,self.snapshot,result,
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
        catalog: K = .{},
        /// Sequence slots (Config.sequences); values are non-transactional.
        seqs: [config.sequences]Q.Seq = @splat(.{}),
        /// Log-ahead values of aborted transactions, carried into the next
        /// change record any transaction writes (design §4.6).
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
        /// Session values of the next statement (TimeZone, clocks); set per
        /// call like `dialect`. Not database state.
        session: value_module.Session = .{},
        workspace: Workspace = .{},

        const BackingLayout = struct {
            offsets: [config.tables][8]usize,
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
                for (&self.tables) |*table| inline for (.{ "rows", "versions", "row_index", "key_index", "scan_values", "scan_nonnull", "scan_live", "scan_presence" }) |field| {
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
            var spans: [config.tables * 8 + 3]StorageSpan = undefined;
            spans[0] = .{ .start = @intFromPtr(self), .end = @intFromPtr(self) + @sizeOf(Self) };
            spans[1] = StorageSpan.of(refs);
            spans[spans.len - 1] = if (comptime config.external_workspace) StorageSpan.of(self.workspace.query.cells) else .{ .start = 0, .end = 0 };
            for (backings, 0..) |backing, i| {
                if (!backing.valid()) return error.InvalidParameterValue;
                spans[2 + i * 8] = StorageSpan.of(backing.rows);
                spans[3 + i * 8] = StorageSpan.of(backing.versions);
                spans[4 + i * 8] = StorageSpan.of(backing.row_index);
                spans[5 + i * 8] = StorageSpan.of(backing.key_index);
                spans[6 + i * 8] = StorageSpan.of(backing.scan_values);
                spans[7 + i * 8] = StorageSpan.of(backing.scan_nonnull);
                spans[8 + i * 8] = StorageSpan.of(backing.scan_live);
                spans[9 + i * 8] = StorageSpan.of(backing.scan_presence);
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
            self.seqs = source.seqs;
            self.seq_carried = source.seq_carried;
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
            self.statement(slot, source, result, .{ .mode = mode, .hold_result = true }) catch |err| {
                self.abort(slot);
                return err;
            };
            // The hook may observe the database (read-only), which reuses
            // `outcome`; keep this statement's own.
            const outcome = self.outcome;
            sink.before(self, slot, outcome.command == .select and self.readOnly(slot)) catch |err| {
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
                tx.fresh = false;
                tx.waiting_for = .{};
                tx.table_wait = null;
                tx.seq_dirty = .{};
                tx.copy_table = null;
                tx.copy_rows = 0;
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
            tx.copy_table = null;
            tx.copy_rows = 0;
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
            if (comptime config.external_results) if (result.rows.len == 0) return error.InvalidParameterValue;
            if (comptime config.external_workspace) if (self.workspace.query.cells.len == 0) return error.InvalidParameterValue;
            if (comptime config.external_storage) if (self.workspace.query.refs.len == 0) return error.InvalidParameterValue;
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
                tx.progress = 0;
                tx.progress_affected = 0;
                snap = .{ .csn = self.csn, .slot = slot, .epoch = tx.epoch, .cid = tx.cid };
                tx.subs[tx.sub_len] = .{ .statement = true, .write_start = @intCast(tx.write_len), .lock_start = @intCast(tx.lock_len) };
                tx.sub_len += 1;
            }
            const start = tx.subs[tx.sub_len - 1].write_start;
            self.statementHooks(slot, snap);
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
            return .{ .source = source, .tables = &self.tables, .catalog = &self.catalog, .snapshot = snap, .pool = &self.workspace.nodes, .legacy = mode == .legacy_alpha, .dialect = self.dialect, .session = &self.session, .plans = &self.workspace.plans };
        }

        fn evalContext(self: *const Self, source: []const u8) E.Context {
            return .{ .source = source, .pool = &self.workspace.nodes, .session = &self.session };
        }

        fn body(self: *Self, slot: u16, source: []const u8, parsed: *const A.Statement, snap: Snapshot, result: *Result, mode: ParseMode) Error!void {
            self.workspace.query.read_stats = .{};
            try self.session.checkpoint();
            const context = self.bindContext(source, mode, snap);
            const bound = try B.bind(&context, parsed);
            switch (bound) {
                .control => return error.UnsupportedStatement,
                .select => |*select| {
                    self.outcome = .{ .affected = 0, .command = .select };
                    if (select.table) |table| try self.lockTable(slot, table, .access_share);
                    if (select.lock.strength == .none)
                        return X.select(&self.tables, source, &self.workspace.nodes, select, snap, result, X.NoLock{}, &self.session, self.txs[slot].write_len == 0, &self.workspace.query.read_stats, &self.workspace.query);
                    const locker: RowLocker = .{ .db = self, .slot = slot, .snap = snap, .mode = if (select.lock.strength == .update) .update else .share, .wait = select.lock.wait };
                    return X.select(&self.tables, source, &self.workspace.nodes, select, snap, result, locker, &self.session, self.txs[slot].write_len == 0, &self.workspace.query.read_stats, &self.workspace.query);
                },
                .query => |root| {
                    self.outcome = .{ .affected = 0, .command = .select };
                    const plans = &self.workspace.plans;
                    for (plans.items[0..plans.len]) |*plan| {
                        for (plan.sources[0..plan.source_count]) |*item| if (item.table) |table| try self.lockTable(slot, table, .access_share);
                    }
                    return X.runQuery(&self.tables, source, &self.workspace.nodes, plans, root, snap, result, &self.session, &self.workspace.query, self.txs[slot].write_len == 0);
                },
                else => {},
            }
            const affected: usize = switch (bound) {
                .create_table => |*create| try self.createTable(slot, create, snap),
                .drop_table => |index| try self.dropTable(slot, index, snap),
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
                    break :blk try self.insertRows(slot, source, insert, snap);
                },
                .update => |*update| blk: {
                    try self.lockTable(slot, update.table, .row_exclusive);
                    break :blk try self.updateRows(slot, source, update, snap);
                },
                .delete => |*delete| blk: {
                    try self.lockTable(slot, delete.table, .row_exclusive);
                    break :blk try self.deleteRows(slot, source, delete, snap);
                },
                .select, .query, .control => unreachable,
            };
            self.outcome = .{ .affected = affected, .command = B.command(&bound) };
            switch (bound) {
                .insert => |*insert| if (insert.returning.count != 0) try self.returnRows(slot, source, &insert.returning, insert.table, insert.plan == ast.none, result.rows.len),
                .update => |*update| if (update.returning.count != 0) try self.returnRows(slot, source, &update.returning, update.table, true, result.rows.len),
                .delete => |*delete| if (delete.returning.count != 0) try self.returnRows(slot, source, &delete.returning, delete.table, true, result.rows.len),
                else => {},
            }
        }

        /// RETURNING: one row per row this statement wrote, in write order
        /// (new versions for INSERT/UPDATE, the deleted version for DELETE).
        /// The statement's write slice survives a park, so a resumed
        /// statement emits every row exactly once. Every value is computed
        /// into the workspace first; a failure leaves the result untouched.
        fn returnRows(self: *Self, slot: u16, source: []const u8, list: *const B.Returning, table_index: usize, fresh: bool, result_capacity: usize) Error!void {
            const tx = &self.txs[slot];
            const start = tx.subs[tx.sub_len - 1].write_start;
            const writes = tx.writes[start..tx.write_len];
            var count: usize = 0;
            for (writes) |entry| if (rowWrite(entry.kind) and entry.table == table_index) {
                count += 1;
            };
            if (count > result_capacity) return error.RowCapacity;
            const work = &self.workspace.query;
            if (fresh) X.resetWork(work);
            const width = list.count;
            const base = try X.stageCells(work, count * width);
            var ctx = self.evalContext(source);
            const table = &self.tables[table_index];
            var row: usize = 0;
            for (writes) |entry| {
                if (!rowWrite(entry.kind) or entry.table != table_index) continue;
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
            for (&self.seqs) |*seq| if (seq.live and seq.dead_csn != 0 and seq.dead_csn <= at) {
                seq.live = false;
                seq.dead_csn = 0;
                freed = true;
            };
            if (freed) _ = self.catalog.vacuum(at);
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
                return self.park(slot, waits);
            }
            try self.reserveWrites(slot, 3);
            seq.pending_drop = true;
            seq.creator = slot;
            tx.push(.{ .kind = .drop_sequence, .table = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const count = self.catalog.dropSequence(index, snap, tx.ref(slot), snap.cid, 0, &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_delete, .table = @intFromEnum(change.relation), .old = change.version }) catch unreachable;
        }

        /// The identity sequence of a table column visible to the statement.
        fn identitySequence(self: *const Self, table_index: usize, column: usize) Error!usize {
            const oid = self.tables[table_index].oid;
            for (&self.seqs, 0..) |*seq, index| {
                if (!seq.live or seq.owner != oid or seq.owner_column != column or seq.dead_csn != 0) continue;
                if (seq.pending_create and seq.creator != self.seq_slot) continue;
                return index;
            }
            return error.TableNotFound;
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
            const name = regclassName(text) orelse return missing;
            if (self.catalog.find(name.slice(), self.seq_snap)) |found| {
                return if (found.kind == 'S') self.seqs[found.slot].oid else self.tables[found.slot].oid;
            }
            var relations: [K.relation_rows]K.Found = undefined;
            const count = self.catalog.visibleRelations(self.seq_snap, &relations);
            for (relations[0..count]) |found| {
                if (found.kind != 'r') continue;
                const table = &self.tables[found.slot];
                if (table.primary_column == null) continue;
                const index_name = indexName(table) catch continue;
                if (types.same(index_name.slice(), name.slice())) return table.oid + 1;
            }
            return missing;
        }

        fn indexName(table: *const S.Table) Error!Name {
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
                    } else if (table.primary_column != null and table.oid + 1 == oid) {
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
            switch (kind) {
                .nextval, .identity => {
                    const out = try Q.next(seq);
                    if (out.logged) tx.seq_dirty.add(index);
                    session.record(seq.oid, out.value, LiveOids{ .db = self });
                    return out.value;
                },
                .currval => return session.currval(seq.oid) orelse error.SequenceNotReady,
                .setval => {
                    try Q.set(seq, amount, called);
                    tx.seq_dirty.add(index);
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

        fn datetimePrecision(column: *const V.Column) ?i64 {
            return switch (column.data_type) {
                .date => 0,
                .timestamp, .timestamptz => if (column.typmod >= 0) column.typmod else 6,
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
                .pg_type => inline for (@typeInfo(DataType).@"enum".field_names) |field| {
                    const data_type = @field(DataType, field);
                    const info = types.typeInfo(data_type);
                    var category: [1]u8 = .{info.category};
                    try sink.add(&.{ intCell(info.oid), nameCell(info.name), intCell(catalog_module.catalog_namespace), intCell(info.len), nameCell("b"), nameCell(&category), intCell(info.array), nameCell(","), nameCell(types.typeInputName(data_type)) });
                },
                .pg_namespace => for (catalog_module.namespaces) |namespace| {
                    try sink.add(&.{ intCell(namespace.oid), nameCell(namespace.name) });
                },
                .schemata => for (catalog_module.namespaces) |namespace| {
                    try sink.add(&.{ nameCell(database), nameCell(namespace.name) });
                },
                else => for (relations[0..count]) |found| {
                    if (found.kind == 'S') {
                        const seq = &self.seqs[found.slot];
                        switch (view) {
                            .pg_class => try sink.add(&.{ intCell(seq.oid), nameCell(seq.name.slice()), intCell(public), nameCell("S"), intCell(3) }),
                            .pg_sequence => try sink.add(&.{ intCell(seq.oid), intCell(seq.spec.type_oid), intCell(seq.spec.start), intCell(seq.spec.increment), intCell(seq.spec.max), intCell(seq.spec.min), intCell(1), boolCell(seq.spec.cycle) }),
                            else => {},
                        }
                        continue;
                    }
                    const table = &self.tables[found.slot];
                    const name = table.name.slice();
                    const oid: i64 = table.oid;
                    const pkey = indexName(table) catch Name{};
                    switch (view) {
                        .pg_class => {
                            try sink.add(&.{ intCell(oid), nameCell(name), intCell(public), nameCell("r"), intCell(@intCast(table.column_count)) });
                            if (table.primary_column != null) try sink.add(&.{ intCell(oid + 1), nameCell(pkey.slice()), intCell(public), nameCell("i"), intCell(1) });
                        },
                        .tables => try sink.add(&.{ nameCell(database), nameCell("public"), nameCell(name), nameCell("BASE TABLE") }),
                        .pg_index => if (table.primary_column) |column| {
                            var key: [4]u8 = undefined;
                            const digits = formatSmall(column + 1, &key);
                            try sink.add(&.{ intCell(oid + 1), intCell(oid), boolCell(true), boolCell(true), nameCell(digits) });
                        },
                        .table_constraints => if (table.primary_column != null) {
                            try sink.add(&.{ nameCell(database), nameCell("public"), nameCell(pkey.slice()), nameCell(database), nameCell("public"), nameCell(name), nameCell("PRIMARY KEY") });
                        },
                        .key_column_usage => if (table.primary_column) |column| {
                            try sink.add(&.{ nameCell(database), nameCell("public"), nameCell(pkey.slice()), nameCell(database), nameCell("public"), nameCell(name), nameCell(table.columns[column].name.slice()), intCell(1) });
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
                                .pg_attribute => try sink.add(&.{ intCell(oid), nameCell(column.name.slice()), intCell(types.typeOid(column.data_type)), intCell(column.typmod), intCell(attnum), boolCell(column.not_null), boolCell(false), nameCell(identity), nameCell(if (kind == .generated) "s" else ""), boolCell(has_expression) }),
                                .pg_attrdef => if (has_expression) {
                                    try sink.add(&.{ intCell(oid), intCell(attnum), expressionTextWithPool(pool,column) });
                                },
                                .columns => {
                                    const numeric = numericPrecision(column);
                                    try sink.add(&.{
                                        nameCell(database),                                       nameCell("public"),                          nameCell(name),            nameCell(column.name.slice()),
                                        intCell(attnum),                                          if (kind == .default) expressionTextWithPool(pool,column) else .null_value, nameCell(if (column.not_null) "NO" else "YES"), nameCell(types.sqlTypeName(column.data_type)),
                                        .null_value,                                              optionalInt(numeric[0]),                     optionalInt(numeric[1]),   optionalInt(numeric[2]),
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
            // A primary key's index owns the next OID (pg_class relkind i).
            self.oid_counter += 1 + @as(u32, @intFromBool(table.primary_column != null));
            tx.push(.{ .kind = .create_table, .table = @intCast(index) }) catch unreachable;
            var changes: [K.max_changes]K.Change = undefined;
            const count = try self.catalog.create(index, table, tx.ref(slot), snap.cid, 0, self.horizon(), &changes);
            for (changes[0..count]) |change| tx.push(.{ .kind = .catalog_insert, .table = @intFromEnum(change.relation), .new = change.version }) catch unreachable;
            if (create.identity) |identity| try self.createSequence(slot, identity.name, identity.spec, table.oid, identity.column, snap);
            return 0;
        }

        fn dropTable(self: *Self, slot: u16, index: usize, snap: Snapshot) Error!usize {
            try self.lockTable(slot, index, .access_exclusive);
            const tx = &self.txs[slot];
            const table = &self.tables[index];
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
            return 0;
        }

        /// Inserts every VALUES row, SELECT row or the DEFAULT VALUES row in
        /// order. A resumed statement continues after the rows it already
        /// handled (Tx.progress); their writes are in its write slice.
        fn insertRows(self: *Self, slot: u16, source: []const u8, insert: *const B.Insert, snap: Snapshot) Error!usize {
            const tx = &self.txs[slot];
            const done = tx.progress;
            var ctx = self.evalContext(source);
            const derived: D.Derived = .{ .defaults = &insert.defaults, .generated = &insert.generated };
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
            const goal = switch (self.target(slot, table_index, version, snap, .write, &waits)) {
                .wait => return self.park(slot, waits),
                .ready => |newest| newest,
                .skip, .authored => return error.CardinalityViolation,
            };
            const row = table.versions[goal].row - 1;
            ctx.tuple[1] = proposed;
            if (!try X.keep(ctx, update.where, &table.versions[goal].cells)) {
                if (try self.locks.grantRow(table_index, table.rows[row].rowid, slot, .update)) |index| {
                    self.txs[slot].pushLock(.{ .kind = .row, .table = @intCast(table_index), .mode = @intFromEnum(locks_module.RowMode.update), .index = index });
                }
                return 0;
            }
            try self.updateOne(slot, ctx, update, row, goal, snap);
            return 1;
        }

        fn insertOne(self: *Self, slot: u16, ctx: *E.Context, insert: *const B.Insert, values: *const [config.columns]u16, derived: D.Derived, snap: Snapshot) Error!usize {
            const table_index = insert.table;
            const table = &self.tables[table_index];
            const cells = try D.insertedRow(ctx, table, values, derived);
            if (table.primary_column) |column| switch (D.keyCheck(table, &cells[column], 0xffffffff, snap)) {
                .free => {},
                .taken => |version| switch (insert.conflict.action) {
                    .none => return error.PrimaryKeyViolation,
                    .nothing => return 0,
                    .update => return self.conflictUpdate(slot, ctx, table_index, &insert.conflict.update, version, &cells, snap),
                },
                .wait => |owner| {
                    var waits: L.Set = .{};
                    waits.add(owner);
                    return self.park(slot, waits);
                },
            };
            try self.appendRow(slot, table_index, &cells, snap);
            return 1;
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
                tx.subs[tx.sub_len] = .{ .statement = true, .write_start = @intCast(tx.write_len), .lock_start = @intCast(tx.lock_len) };
                tx.sub_len += 1;
            }
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
            const tx = &self.txs[slot];
            const copy = try self.parseCopy(source);
            const context = self.bindContext(source, .standard, snap);
            const bound = try B.bindCopy(&context, &copy, false);
            try self.lockTable(slot, bound.table, .row_exclusive);
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
            self.seq_hook = .{ .ptr = self, .call = &sequenceCall, .relation_name = &relationName };
            self.session.sequences = &self.seq_hook;
            self.seq_slot = slot;
            self.seq_snap = snap;
            self.workspace.query.views = .{ .ptr = self, .rows = &viewRows };
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
            out.cells = try D.copiedRow(&ctx, table, &provided, .{ .defaults = &bound.defaults, .generated = &bound.generated });
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
                .slot => |hit| affected += try self.updateSlot(slot, &ctx, update, hit.row, snap),
                .scan => {
                    const high = table.row_high;
                    for (0..high) |row| affected += try self.updateSlot(slot, &ctx, update, @intCast(row), snap);
                },
            }
            return affected;
        }

        fn updateSlot(self: *Self, slot: u16, ctx: *E.Context, update: *const B.Update, row: u32, snap: Snapshot) Error!usize {
            try self.session.checkpoint();
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
            const cells = try D.updatedRow(ctx, table, &update.values, .{ .defaults = &update.defaults, .generated = &update.generated }, &table.versions[old].cells);
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
                .slot => |hit| affected += try self.deleteSlot(slot, &ctx, delete, hit.row, snap),
                .scan => {
                    const high = table.row_high;
                    for (0..high) |row| affected += try self.deleteSlot(slot, &ctx, delete, @intCast(row), snap);
                },
            }
            return affected;
        }

        fn deleteSlot(self: *Self, slot: u16, ctx: *E.Context, delete: *const B.Delete, row: u32, snap: Snapshot) Error!usize {
            try self.session.checkpoint();
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
                    .create_sequence => try C.encodeCreateSequence(writer, &self.seqs[entry.table]),
                    .drop_sequence => try C.encodeDropSequence(writer, self.seqs[entry.table].oid),
                    .catalog_insert, .catalog_delete => {},
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
