//! Shared SQL configuration, errors, command tags and cell values (Layer 0).
//! Sub-files of `sql.sig` import each other relatively; nothing outside the
//! `sql` module imports this file directly.
const numeric = @import("numeric.sig");
const temporal = @import("temporal.sig");
const jsonb = @import("jsonb.sig");
const character = @import("character.sig");
const uuid = @import("uuid.sig");
const time_of_day = @import("time_of_day.sig");
const bit_string = @import("bit_string.sig");
const array_module = @import("array.sig");
const range_module = @import("range.sig");
const network = @import("network.sig");
const geometric = @import("geometric.sig");
const jsonpath_module = @import("jsonpath.sig");

pub const Config = struct {
    /// Caller supplies row/version/index buffers and query reference workspace.
    /// Stored-row capacity then comes from those buffers, not rows_per_table.
    /// Cells/results/schema/transaction capacities remain separately budgeted.
    external_storage: bool = false,
    /// Query cells are a separately bound caller-owned runtime budget.
    external_workspace: bool = false,
    /// Result rows are bound independently by each serialized caller/session.
    external_results: bool = false,
    /// Optional caller-backed committed integral scan projection. Old snapshots
    /// and own writes retain MVCC row scans. Currently external storage only.
    compact_integral_scans: bool = false,
    /// Optional conservative 256-bit presence summary per 64-row scan block
    /// and column. Borrowed external backing; exact comparisons remain required.
    block_presence_filters: bool = false,
    /// Opt-in exact aggregate-before-unique-key-join execution. Unsupported
    /// expressions, visibility or caller-workspace budgets retain ordinary SQL.
    factorized_aggregates: bool = false,
    /// Caller-arena typed COUNT/SUM/AVG channels for committed integral GROUP
    /// BY. Unsupported expressions, visibility and budgets retain ordinary SQL.
    typed_grouped_aggregates: bool = false,
    /// Precontract a unique-key dimension to group IDs before combining one
    /// dimension label with one integral fact key in caller-owned group state.
    dimension_group_ids: bool = false,
    /// Typed grouped COUNT(DISTINCT fact integer) over unique dimension chains.
    /// Exact membership bitmaps borrow the query arena and remain per snapshot.
    dimension_distinct_groups: bool = false,
    /// Optional exact committed GROUP BY synopses per supported column. This
    /// budgets metadata groups, not SQL results: overflow retains scan paths.
    summary_groups: usize = 0,
    /// Speculative ordered hash probes on a proven dense integer primary-key
    /// domain. Budget exhaustion restarts the ordinary scan; 0 disables it.
    ordered_probe_rows: usize = 8192,
    tables: usize = 4,
    columns: usize = 8,
    rows_per_table: usize = 128,
    name_bytes: usize = 32,
    text_bytes: usize = 128,
    /// Maximum boolean leaf predicates (comparison, IS, IN, BETWEEN, LIKE)
    /// in one WHERE clause; more raise PredicateCapacity (54000).
    predicates: usize = 8,
    /// MySQL-style ordering by default; PostgreSQL uses false (ASC NULLS LAST).
    nulls_first_ascending: bool = true,
    /// What an unqualified INTEGER means outside the PostgreSQL dialect (MySQL
    /// and TDS sessions) and in legacy_alpha replay. On the PostgreSQL path
    /// INTEGER/INT/INT4 is always int4; BIGINT/INT8 is always int8.
    integer_bits: u8 = 64,
    /// Row-version arena slots per table. 0 selects 2 x rows_per_table; an
    /// explicit value must exceed rows_per_table.
    versions_per_table: usize = 0,
    /// Write-set entries per transaction (row versions, row marks and catalog
    /// versions it created or marked). 0 selects 2 x rows_per_table (at least
    /// 64); RAMSQL sets 4096. Exceeding it is WriteSetCapacity (53200) with
    /// the statement rolled back.
    tx_writes: usize = 0,
    /// Statement-scoped expression node pool inside Database.workspace.
    expr_nodes: usize = 512,
    /// Maximum parser nesting depth.
    expr_depth: usize = 64,
    /// Concurrent transaction slots (RAMSQL: clients + 2). Exhaustion is
    /// TransactionCapacity (53200).
    transactions: usize = 8,
    /// User savepoints per transaction; one more slot is reserved for the
    /// running statement's subtransaction.
    savepoints: usize = 32,
    /// FOR UPDATE / FOR SHARE row-lock entries shared by all transactions;
    /// exhaustion is LockCapacity (53200).
    row_locks: usize = 256,
    /// FOR SHARE holders per locked row.
    share_holders: usize = 8,
    /// Sequence catalog capacity (cat_sequences; sequences arrive with FEAT-007).
    sequences: usize = 16,
    /// NUMERIC coefficient capacity in decimal digits (1..76). Results that
    /// need more significant digits raise NumericCapacity (54000).
    numeric_digits: usize = 64,
    /// JSONB nesting depth; deeper documents raise StatementTooComplex (54001).
    json_depth: usize = 64,
    /// Query workspace row slots (design §4.9): sorts, groups, joins, CTEs,
    /// derived tables and set operations of one statement share
    /// work_rows x 2 x columns cells. 0 selects rows_per_table. Exhaustion is
    /// WorkspaceCapacity (54000) before anything is published.
    work_rows: usize = 0,
    /// Rows one statement can return (Result.rows). 0 selects rows_per_table.
    result_rows: usize = 0,
    /// FROM items (tables, derived tables, CTE references) per query block.
    relations: usize = 4,
    /// Query blocks per statement (subqueries, CTE bodies, set-operation
    /// branches); more raise StatementTooComplex (54001).
    subqueries: usize = 16,
    /// Common table expressions per statement (StatementTooComplex beyond).
    ctes: usize = 4,
    /// COPY FROM: longest data row (text/CSV line or binary tuple) a codec
    /// carries across CopyData messages; longer rows are TextCapacity (54000).
    copy_line_bytes: usize = 8192,
    /// Table-level constraints per table beyond NOT NULL and a single-column
    /// PRIMARY KEY: CHECK, UNIQUE and composite PRIMARY KEY. More raise
    /// ColumnCapacity (54000) and change nothing.
    table_constraints: usize = 8,
    /// User schemas (CREATE SCHEMA) beyond pg_catalog, public and
    /// information_schema. More raise TableCapacity (54000).
    schemas: usize = 4,
    /// Secondary indexes per table (CREATE INDEX). More raise IndexCapacity
    /// (54000) and change nothing.
    table_indexes: usize = 4,
    /// Entries one secondary index can hold: every row version of its table
    /// (pending and dead ones until reclaimed). 0 selects the version arena
    /// capacity (versions_per_table) with inline storage. External storage
    /// must leave it 0 and size index storage at runtime (external_indexes,
    /// Backing.index_slots). A write past it, after reclamation, is IndexCapacity
    /// (54000) with the statement rolled back. Entries live inline in the
    /// table: table_indexes x 2 x index_entries u32 per table (power of two).
    index_entries: usize = 0,
    /// Statement text plus the view, inheritance and partition expansions
    /// it reads, copied into the statement workspace. A statement that reads
    /// a view, an inheritance parent or a partitioned table and needs more
    /// is TextCapacity (54000).
    expansion_bytes: usize = 4096,
    /// SET CONSTRAINTS name lists remembered per transaction (names beyond
    /// it are TableCapacity, 54000).
    constraint_modes: usize = 8,
    /// external_storage only: secondary indexes per table whose entry
    /// hashes Database.bindMemory/bindMemoryFor carve from the caller's
    /// region (backingBytes/backingBytesFor count them), at most
    /// table_indexes. Each takes key_index-sized storage, pow2(2 x the
    /// table's runtime versions) u32, so its entries cover every version
    /// (no cap below the version arena). 0 binds none: CREATE INDEX is
    /// IndexCapacity (54000) and memory plans are unchanged. bindStorage
    /// callers bind any count per table through Backing.index_slots.
    external_indexes: usize = 0,
    /// Tx-session lane (session.sig). Every limit below is SessionCapacity
    /// (54000) when exceeded, with nothing changed.
    /// Declared parameters of one SQL prepared statement (PREPARE).
    statement_parameters: usize = 16,
    /// SQL prepared statements per session and the text bytes of each.
    prepared_statements: usize = 8,
    prepared_bytes: usize = 1024,
    /// Open cursors of all sessions, and the materialized rows they share
    /// (inline in the Database; 0 selects result_rows).
    cursors: usize = 4,
    cursor_rows: usize = 64,
    /// Placeholder (`prefix.name`) settings per session, and the bytes of
    /// an engine setting name or value (search_path, placeholders).
    custom_settings: usize = 4,
    setting_bytes: usize = 64,
    /// Savepoint levels of one transaction that can change engine
    /// settings (each keeps the level's starting values).
    setting_snapshots: usize = 4,
    /// LISTEN channels per session (also its pending LISTEN/UNLISTEN
    /// actions), listening sessions, committed notifications not yet read
    /// by every listener, uncommitted NOTIFY entries of all transactions
    /// and the payload bytes of one notification.
    listen_channels: usize = 8,
    listeners: usize = 8,
    notify_queue: usize = 32,
    notify_pending: usize = 16,
    notify_payload_bytes: usize = 256,
    /// Advisory-lock keys held or awaited at once (all sessions).
    advisory_locks: usize = 32,
    /// SERIALIZABLE transaction records (active, and committed ones that
    /// overlap an active one); 0 selects 2 x transactions.
    serializable_transactions: usize = 0,
    // Routines, triggers and rules (B11 wave 3, routine_catalog.sig).
    /// Function and procedure versions (CREATE [OR REPLACE] FUNCTION /
    /// PROCEDURE); more are TableCapacity (54000).
    routines: usize = 8,
    /// Trigger versions (CREATE TRIGGER); more are TableCapacity (54000).
    triggers: usize = 8,
    /// Rewrite-rule versions (CREATE RULE); more are TableCapacity (54000).
    rules: usize = 4,
    /// Arguments per routine and CALL (more are ColumnCapacity, 54000).
    routine_args: usize = 8,
    /// A routine body, trigger WHEN condition or rule qualification
    /// (decoded text); longer ones are TextCapacity (54000).
    routine_bytes: usize = 1024,
    /// Nested routine calls and trigger firings (functions calling
    /// functions, triggers fired by routines); deeper is 54001.
    routine_depth: usize = 16,
    /// PL/pgSQL variables per routine frame (parameters, DECLAREd
    /// variables, FOUND, loop variables, TG_*); more are ColumnCapacity.
    routine_variables: usize = 24,
    /// SQL/JSON path (B11 json-agg lane): parsed nodes of one jsonpath
    /// (more is StatementTooComplex, 54001) and the items one evaluation
    /// holds at once for predicate operands and subscripts (more is
    /// ProgramLimitExceeded, 54000).
    jsonpath_nodes: usize = 128,
    jsonpath_items: usize = 128,
    /// Catalog object versions (catalog_objects.sig): roles, memberships,
    /// table grants, table owners/RLS flags, policies, comments, foreign-data
    /// wrappers, servers and publications, including uncommitted and dead
    /// versions until reclaimed. More raise TableCapacity (54000).
    catalog_objects: usize = 32,
    /// Inline text of one catalog object (a comment, or a policy's USING
    /// plus WITH CHECK canonical text). Longer is TextCapacity (54000).
    object_text_bytes: usize = 256,
    /// Roles one policy names (TO ...). More raise ProgramLimitExceeded (54000).
    policy_roles: usize = 4,
};

pub fn workRows(comptime config: Config) usize {
    return if (config.work_rows == 0) config.rows_per_table else config.work_rows;
}

pub fn resultRows(comptime config: Config) usize {
    return if (config.result_rows == 0) config.rows_per_table else config.result_rows;
}

pub const Error = error{
    Syntax,
    UnsupportedStatement,
    TableCapacity,
    ColumnCapacity,
    RowCapacity,
    NameCapacity,
    TextCapacity,
    PredicateCapacity,
    TableExists,
    TableNotFound,
    ColumnNotFound,
    DuplicateColumn,
    TypeMismatch,
    NotNullViolation,
    PrimaryKeyViolation,
    IntegerOverflow,
    /// SQLSTATE 54001: node pool or parser depth exhausted.
    StatementTooComplex,
    /// SQLSTATE 53200: no reclaimable row version or directory slot remains.
    VersionCapacity,
    /// SQLSTATE 53200: a change record does not fit its caller-owned buffer.
    TransactionLogCapacity,
    /// Unknown change-record version or a legacy SQL record outside the alpha grammar.
    UnsupportedLogVersion,
    /// Truncated, corrupt or structurally invalid change record.
    InvalidChangeRecord,
    /// A change record names an unknown OID, a conflicting rowid or exceeds capacity.
    ChangeRecordConflict,
    /// SQLSTATE 42883: no operator or function matches the argument types.
    UndefinedFunction,
    /// SQLSTATE 42725: an operator over untyped literals is ambiguous.
    AmbiguousFunction,
    /// SQLSTATE 42846: no cast exists between the two types.
    CannotCoerce,
    /// SQLSTATE 22P02: text is not valid input for the target type.
    InvalidTextRepresentation,
    /// SQLSTATE 22012.
    DivisionByZero,
    /// SQLSTATE2201F: square root/power domain error.
    InvalidArgumentForPowerFunction,
    /// SQLSTATE 22025: invalid LIKE escape string or reached trailing escape.
    InvalidEscapeSequence,
    /// SQLSTATE 22021: bytes that are not valid UTF-8 (pg_verifymbstr).
    CharacterNotInRepertoire,
    /// SQLSTATE 22011: negative substring length.
    SubstringError,
    /// SQLSTATE 2201E: logarithm of zero or a negative number.
    InvalidArgumentForLogarithm,
    /// SQLSTATE 54000: a requested character or value exceeds a fixed limit
    /// (chr of 0, a surrogate or a code point above U+10FFFF).
    ProgramLimitExceeded,
    /// SQLSTATE 42P02: a $n placeholder reached the engine unbound.
    UndefinedParameter,
    /// SQLSTATE 42P10: invalid ORDER BY reference or window-frame variable.
    InvalidColumnReference,
    /// Not an error for subtransaction purposes: the statement met a lock held
    /// by a live transaction and is parked (design §4.4/§4.5). Resume it by
    /// re-delivering the same statement.
    WouldBlock,
    /// SQLSTATE 40001: interim same-row conflict (unused once locks wait).
    SerializationFailure,
    /// SQLSTATE 40P01.
    DeadlockDetected,
    /// SQLSTATE 55P03: NOWAIT or lock_timeout.
    LockNotAvailable,
    /// SQLSTATE 57014: cancel request or statement_timeout.
    QueryCanceled,
    /// SQLSTATE 53200: the transaction table is full.
    TransactionCapacity,
    /// SQLSTATE 53200: a transaction's write set (Config.tx_writes) is full.
    WriteSetCapacity,
    /// SQLSTATE 53200: the row-lock table or a lock's share holders are full.
    LockCapacity,
    /// SQLSTATE 53200: a catalog relation has no free version or row.
    CatalogCapacity,
    /// SQLSTATE 53200: too many savepoints in one transaction.
    SavepointCapacity,
    /// SQLSTATE 3B001.
    SavepointNotFound,
    /// SQLSTATE 25P01: SAVEPOINT/RELEASE/ROLLBACK TO outside a block.
    NoActiveTransaction,
    /// SQLSTATE 25006: the caller does not permit writes (storage unavailable).
    ReadOnlyTransaction,
    /// SQLSTATE 42704: unrecognized configuration parameter.
    UndefinedSetting,
    /// SQLSTATE 22023: invalid value for a configuration parameter.
    InvalidSettingValue,
    /// SQLSTATE 22003: a NUMERIC, REAL/DOUBLE or SMALLINT value is out of range.
    NumericValueOutOfRange,
    /// SQLSTATE 54000: a NUMERIC result needs more than Config.numeric_digits
    /// significant digits or a larger display scale (capacity limit).
    NumericCapacity,
    /// SQLSTATE 22023: invalid type modifier or function argument.
    InvalidParameterValue,
    /// SQLSTATE 22007: text is not a valid date/time/interval.
    InvalidDatetimeFormat,
    /// SQLSTATE 22008: a date/time field or value is out of range.
    DatetimeFieldOverflow,
    /// SQLSTATE 22015: an input interval field is out of range.
    IntervalFieldOverflow,
    /// SQLSTATE 22P05: \u0000 in JSONB.
    UntranslatableCharacter,
    /// SQLSTATE 0A000: the statement needs a wall clock and none is available.
    ClockUnavailable,
    /// SQLSTATE 54000: the statement's query workspace (Config.work_rows) is full.
    WorkspaceCapacity,
    /// SQLSTATE 42803: an ungrouped column or misplaced aggregate.
    GroupingError,
    /// SQLSTATE 42P20: misplaced or nested window function.
    WindowingError,
    /// SQLSTATE 22013: negative window frame offset.
    InvalidWindowFrameOffset,
    /// SQLSTATE 22014: NTILE bucket count must be positive.
    InvalidArgumentForNtile,
    InvalidArgumentForNthValue,
    /// SQLSTATE 22004: NULL window frame offset.
    NullWindowFrameOffset,
    /// SQLSTATE 42702: an unqualified column name matches several relations.
    AmbiguousColumn,
    /// SQLSTATE 21000: a scalar subquery returned more than one row.
    CardinalityViolation,
    /// SQLSTATE 2201W: LIMIT is negative.
    InvalidRowCountInLimit,
    /// SQLSTATE 2201X: OFFSET is negative.
    InvalidRowCountInResultOffset,
    /// SQLSTATE 428C9: a value assigned to a GENERATED ALWAYS column.
    GeneratedAlways,
    /// SQLSTATE 42P17: invalid generated-column definition.
    InvalidObjectDefinition,
    /// SQLSTATE 2200H: nextval reached the sequence bound without CYCLE.
    SequenceLimit,
    /// SQLSTATE 55000: currval/lastval before nextval in this session.
    SequenceNotReady,
    /// SQLSTATE 42809: the relation is not of the expected kind.
    WrongObjectType,
    /// SQLSTATE 2BP01: an identity column owns the sequence.
    DependentObjects,
    /// SQLSTATE 42704: a named constraint (ON CONFLICT ON CONSTRAINT) does not exist.
    UndefinedObject,
    /// SQLSTATE 22P04: malformed COPY data (field count, quoting, header,
    /// binary signature).
    BadCopyFormat,
    /// SQLSTATE 22P03: a binary COPY field has the wrong length or layout.
    InvalidBinaryRepresentation,
    /// SQLSTATE 54000: the configured statement work budget was exhausted.
    QueryWorkLimit,
    /// SQLSTATE 22001: a value is longer than its declared length
    /// (VARCHAR(n)/CHAR(n) assignment or input).
    StringDataRightTruncation,
    /// SQLSTATE 22009: a time zone displacement beyond +-15:59:59.
    InvalidTimeZoneDisplacement,
    /// SQLSTATE 22026: a BIT(n) value does not have exactly n bits.
    StringDataLengthMismatch,
    /// SQLSTATE 23514: a row fails a CHECK constraint.
    CheckViolation,
    /// SQLSTATE 42710: a constraint or schema name is already in use.
    DuplicateObject,
    /// SQLSTATE 42P16: invalid table definition (several primary keys).
    InvalidTableDefinition,
    /// SQLSTATE 3F000: a schema name does not exist.
    UndefinedSchema,
    /// SQLSTATE 42P06: CREATE SCHEMA of an existing name.
    DuplicateSchema,
    /// SQLSTATE 42P18: the type of an expression (an empty ARRAY[]) cannot
    /// be determined.
    IndeterminateDatatype,
    /// SQLSTATE 2202E: mismatched array dimensions or subscripts.
    ArraySubscriptError,
    /// SQLSTATE 22000: invalid data (array_append to a multi-dimensional array).
    DataException,
    /// SQLSTATE 2200N: text is not well-formed XML content.
    InvalidXmlContent,
    /// SQLSTATE 2200M: text is not a well-formed XML document.
    InvalidXmlDocument,
    /// SQLSTATE 2200L: XMLSERIALIZE(DOCUMENT ...) of a value that is not one.
    NotAnXmlDocument,
    /// SQLSTATE 23503: a row violates a FOREIGN KEY constraint.
    ForeignKeyViolation,
    /// SQLSTATE 23P01: a row conflicts with an EXCLUDE constraint.
    ExclusionViolation,
    /// SQLSTATE 54000: a table's secondary indexes (Config.table_indexes)
    /// or a secondary index's entries (Config.index_entries) are full.
    IndexCapacity,
    /// SQLSTATE 42830: a FOREIGN KEY whose referenced columns are not a
    /// primary key or unique constraint of the referenced table.
    InvalidForeignKey,
    /// SQLSTATE 55000: a materialized view that has not been populated.
    ObjectNotInPrerequisiteState,
    /// SQLSTATE 2202H: invalid TABLESAMPLE argument (B11).
    InvalidTablesampleArgument,
    /// SQLSTATE 2202G: NULL TABLESAMPLE REPEATABLE seed (B11).
    InvalidTablesampleRepeat,
    /// SQLSTATE 25001: a transaction mode set after the first query or in
    /// a subtransaction.
    ActiveSqlTransaction,
    /// SQLSTATE 26000: no such SQL prepared statement.
    StatementNotFound,
    /// SQLSTATE 34000: no such cursor.
    PortalNotFound,
    /// SQLSTATE 42P05: the prepared statement name is taken.
    DuplicateStatement,
    /// SQLSTATE 42P03: the cursor name is taken.
    DuplicatePortal,
    /// SQLSTATE 54000: a tx-session capacity (cursors, prepared statements,
    /// settings, LISTEN, NOTIFY queue, advisory locks, SERIALIZABLE records).
    SessionCapacity,
    // Routines, triggers and rules (B11 wave 3).
    /// SQLSTATE 42723: a function or procedure with this signature exists.
    DuplicateFunction,
    /// SQLSTATE 42P13: invalid function definition (return type, body).
    InvalidFunctionDefinition,
    /// SQLSTATE P0001: PL/pgSQL RAISE EXCEPTION.
    RaiseException,
    /// SQLSTATE P0002: SELECT ... INTO STRICT found no row.
    NoDataFound,
    /// SQLSTATE P0003: SELECT ... INTO STRICT found more than one row.
    TooManyRows,
    /// SQLSTATE 2F005: control reached the end of a function without RETURN.
    FunctionExecutedNoReturn,
    /// SQLSTATE 20000: CASE statement without a matching branch or ELSE.
    CaseNotFound,
    /// SQLSTATE 54001: routine or trigger nesting beyond Config.routine_depth.
    StackDepthExceeded,
    /// SQLSTATE 22004: NULL assigned to a NOT NULL PL/pgSQL variable.
    NullValueNotAllowed,
    /// SQLSTATE 22005: assignment to a CONSTANT PL/pgSQL variable.
    ErrorInAssignment,
    // SQL/JSON path errors (B11 json-agg lane, jsonpath_exec.c).
    /// SQLSTATE 22039: an array accessor or .size() on a non-array (strict).
    SqlJsonArrayNotFound,
    /// SQLSTATE 2203A: a missing key or a member accessor on a non-object (strict).
    SqlJsonMemberNotFound,
    /// SQLSTATE 2203C: a wildcard member accessor on a non-object (strict).
    SqlJsonObjectNotFound,
    /// SQLSTATE 22033: an invalid or out-of-bounds array subscript.
    InvalidSqlJsonSubscript,
    /// SQLSTATE 22038: an operand that is not a single numeric item, or a
    /// jsonb_path_match result that is not a single boolean.
    SingletonSqlJsonItemRequired,
    /// SQLSTATE 22036: an item method over a value of the wrong type.
    NonNumericSqlJsonItem,
    /// SQLSTATE 2203B: a unary operator over a non-numeric item.
    SqlJsonNumberNotFound,
    /// SQLSTATE 2203F: a JSON_TABLE column needs a scalar.
    SqlJsonScalarRequired,
    /// SQLSTATE 2203G: a SQL/JSON item cannot be cast to the column type.
    SqlJsonItemCannotBeCast,
    /// SQLSTATE 22034: a column path returned more than one item.
    MoreThanOneSqlJsonItem,
    /// SQLSTATE 22035: a column path returned no item (ERROR ON EMPTY).
    NoSqlJsonItem,
    /// SQLSTATE 42501: missing privilege, ownership or role attribute, or a
    /// new row violating a row-level security policy (B11 wave 3).
    InsufficientPrivilege,
    /// SQLSTATE 42939: a reserved role name (public, none, pg_*).
    ReservedName,
    /// SQLSTATE 55006: the object is in use (DROP ROLE of the current user).
    ObjectInUse,
    /// SQLSTATE 0LP01: a role grant that would make a role its own member.
    InvalidGrantOperation,
    /// SQLSTATE 42P21: two different explicit collations (COLLATE) meet in
    /// one expression (B11 text).
    CollationMismatch,
};

/// Caller-owned execution accounting and interrupt polling. This is independent
/// of clocks/platforms: the caller's poll hook can enforce deadlines or cancel.
/// A hook must not execute SQL or mutate database storage. It may only inspect
/// time/interrupt state and return a terminal error. Checks never run during
/// rollback or durable publication, so cleanup/publication stay infallible.
pub const ExecutionControl = struct {
    context: ?*anyopaque = null,
    poll: ?*const fn (?*anyopaque) Error!void = null,
    max_work: u64 = 0,
    used: u64 = 0,
    poll_interval: u32 = 256,
    until_poll: u32 = 0,

    pub fn reset(self: *ExecutionControl, limit: u64) void {
        self.max_work = limit;
        self.used = 0;
        self.until_poll = 0;
    }

    pub fn checkpoint(self: *ExecutionControl) Error!void {
        if (self.max_work != 0 and self.used >= self.max_work) return error.QueryWorkLimit;
        if (self.used != 0xffffffffffffffff) self.used += 1;
        if (self.until_poll == 0) {
            if (self.poll) |poll| try poll(self.context);
            self.until_poll = @max(self.poll_interval, 1);
        }
        self.until_poll -= 1;
    }

    /// Equivalent to count checkpoint calls, including exact work-limit and
    /// callback positions. Jump only over the interval with no observable poll.
    pub fn advance(self:*ExecutionControl,count:usize) Error!void {
        var remaining=count;
        while(remaining!=0) {
            if(self.until_poll==0) {
                try self.checkpoint();remaining-=1;continue;
            }
            var steps=@min(remaining,@as(usize,self.until_poll));
            if(self.max_work!=0) {
                if(self.used>=self.max_work) return error.QueryWorkLimit;
                steps=@intCast(@min(@as(u64,@intCast(steps)),self.max_work-self.used));
            }
            self.used+|=@intCast(steps);
            self.until_poll-=@intCast(steps);remaining-=steps;
        }
    }
};

/// Session dialect. It changes only assignment coercion (MySQL/TDS BIT
/// clients send booleans as integer 0/1) and what an unqualified INTEGER
/// means (Config.integer_bits outside PostgreSQL). Expression typing is the
/// same in every dialect.
pub const Dialect = enum { postgres, mysql, tds };

/// Stored column / result types. `integer` is int8 (BIGINT) and
/// `integer32` int4 (INTEGER); the others are named after PostgreSQL.
/// The unnamed values are array types: the element's ordinal with
/// array_bit set (arrayData/elementData); there are no arrays of arrays.
pub const DataType = enum(u8) { integer, integer32, boolean, text, smallint, numeric, real, double, name, oid, date, timestamp, timestamptz, interval, json, jsonb, varchar, bpchar, uuid, bytea, time, timetz, bit, varbit, money, pg_lsn, xid8, int4range, int8range, numrange, daterange, tsrange, tstzrange, inet, cidr, macaddr, point, box, xml, jsonpath, regtype, _ };

/// Bound expression type. `unknown` is an untyped string or NULL literal
/// that has not been resolved by context yet. Unnamed values are array
/// types, encoded like DataType's (arrayType/elementType).
pub const Type = enum(u8) { unknown, int2, int4, int8, numeric, float4, float8, boolean, text, name, oid, date, timestamp, timestamptz, interval, json, jsonb, varchar, bpchar, uuid, bytea, time, timetz, bit, varbit, money, pg_lsn, xid8, int4range, int8range, numrange, daterange, tsrange, tstzrange, inet, cidr, macaddr, point, box, xml, jsonpath, regtype, _ };

/// Array types set this bit over the element type's ordinal.
pub const array_bit: u8 = 0x80;
const data_type_count = @typeInfo(DataType).@"enum".field_names.len;
const type_count = @typeInfo(Type).@"enum".field_names.len;

/// The array type of a named element type (null for an array).
pub fn arrayData(element: DataType) ?DataType {
    const raw = @intFromEnum(element);
    if (raw >= data_type_count) return null;
    return @enumFromInt(raw | array_bit);
}

/// The element type of an array type (null for a scalar type).
pub fn elementData(data_type: DataType) ?DataType {
    const raw = @intFromEnum(data_type);
    if (raw < array_bit or raw & ~array_bit >= data_type_count) return null;
    return @enumFromInt(raw & ~array_bit);
}

pub fn arrayType(element: Type) ?Type {
    const raw = @intFromEnum(element);
    if (element == .unknown or raw >= type_count) return null;
    return @enumFromInt(raw | array_bit);
}

pub fn elementType(ty: Type) ?Type {
    const raw = @intFromEnum(ty);
    if (raw < array_bit or raw & ~array_bit >= type_count or raw & ~array_bit == 0) return null;
    return @enumFromInt(raw & ~array_bit);
}

pub fn isArray(ty: Type) bool {
    return elementType(ty) != null;
}

/// The subtype of a built-in range type (null otherwise).
pub fn rangeSubtype(ty: Type) ?Type {
    return switch (ty) {
        .int4range => .int4,
        .int8range => .int8,
        .numrange => .numeric,
        .daterange => .date,
        .tsrange => .timestamp,
        .tstzrange => .timestamptz,
        else => null,
    };
}

/// The range type over a subtype stored as `subtype` (one per subtype).
pub fn rangeOfData(subtype: DataType) ?DataType {
    return switch (subtype) {
        .integer32 => .int4range,
        .integer => .int8range,
        .numeric => .numrange,
        .date => .daterange,
        .timestamp => .tsrange,
        .timestamptz => .tstzrange,
        else => null,
    };
}

pub fn isRange(ty: Type) bool {
    return rangeSubtype(ty) != null;
}

pub fn dataTypeOf(ty: Type) DataType {
    return switch (ty) {
        .int2 => .smallint,
        .int4 => .integer32,
        .int8 => .integer,
        .numeric => .numeric,
        .float4 => .real,
        .float8 => .double,
        .boolean => .boolean,
        .text, .unknown => .text,
        .name => .name,
        .oid => .oid,
        .date => .date,
        .timestamp => .timestamp,
        .timestamptz => .timestamptz,
        .interval => .interval,
        .json => .json,
        .jsonb => .jsonb,
        .varchar => .varchar,
        .bpchar => .bpchar,
        .uuid => .uuid,
        .bytea => .bytea,
        .time => .time,
        .timetz => .timetz,
        .bit => .bit,
        .varbit => .varbit,
        .money => .money,
        .pg_lsn => .pg_lsn,
        .xid8 => .xid8,
        .int4range => .int4range,
        .int8range => .int8range,
        .numrange => .numrange,
        .daterange => .daterange,
        .tsrange => .tsrange,
        .tstzrange => .tstzrange,
        .inet => .inet,
        .cidr => .cidr,
        .macaddr => .macaddr,
        .point => .point,
        .box => .box,
        .xml => .xml,
        .jsonpath => .jsonpath,
        .regtype => .regtype,
        _ => if (elementType(ty)) |element| arrayData(dataTypeOf(element)).? else .text,
    };
}

pub fn typeOfData(data_type: DataType) Type {
    return switch (data_type) {
        .smallint => .int2,
        .integer32 => .int4,
        .integer => .int8,
        .numeric => .numeric,
        .real => .float4,
        .double => .float8,
        .boolean => .boolean,
        .text => .text,
        .name => .name,
        .oid => .oid,
        .date => .date,
        .timestamp => .timestamp,
        .timestamptz => .timestamptz,
        .interval => .interval,
        .json => .json,
        .jsonb => .jsonb,
        .varchar => .varchar,
        .bpchar => .bpchar,
        .uuid => .uuid,
        .bytea => .bytea,
        .time => .time,
        .timetz => .timetz,
        .bit => .bit,
        .varbit => .varbit,
        .money => .money,
        .pg_lsn => .pg_lsn,
        .xid8 => .xid8,
        .int4range => .int4range,
        .int8range => .int8range,
        .numrange => .numrange,
        .daterange => .daterange,
        .tsrange => .tsrange,
        .tstzrange => .tstzrange,
        .inet => .inet,
        .cidr => .cidr,
        .macaddr => .macaddr,
        .point => .point,
        .box => .box,
        .xml => .xml,
        .jsonpath => .jsonpath,
        .regtype => .regtype,
        _ => if (elementData(data_type)) |element| arrayType(typeOfData(element)).? else .text,
    };
}

/// Static type table (pg_type subset): OID, typname, typlen, typcategory,
/// array type OID (arrays are reported for catalog fidelity only).
pub const TypeInfo = struct { oid: u32, name: []const u8, len: i16, category: u8, array: u32 };

pub fn typeInfo(data_type: DataType) TypeInfo {
    if (elementData(data_type)) |element| {
        const base = baseInfo(element);
        return .{ .oid = base.array, .name = array_names[@intFromEnum(element)], .len = -1, .category = 'A', .array = 0 };
    }
    return baseInfo(data_type);
}

/// typname of each named type's array type: `_` + the element typname.
const array_names = blk: {
    const fields = @typeInfo(DataType).@"enum".field_names;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, index| names[index] = "_" ++ baseInfo(@field(DataType, field)).name;
    break :blk names;
};

/// SQL spelling of each named type's array type (`integer[]`).
const array_sql_names = blk: {
    const fields = @typeInfo(DataType).@"enum".field_names;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, index| names[index] = baseSqlName(@field(DataType, field)) ++ "[]";
    break :blk names;
};

fn baseInfo(data_type: DataType) TypeInfo {
    return switch (data_type) {
        .boolean => .{ .oid = 16, .name = "bool", .len = 1, .category = 'B', .array = 1000 },
        .name => .{ .oid = 19, .name = "name", .len = 64, .category = 'S', .array = 1003 },
        .integer => .{ .oid = 20, .name = "int8", .len = 8, .category = 'N', .array = 1016 },
        .smallint => .{ .oid = 21, .name = "int2", .len = 2, .category = 'N', .array = 1005 },
        .integer32 => .{ .oid = 23, .name = "int4", .len = 4, .category = 'N', .array = 1007 },
        .text => .{ .oid = 25, .name = "text", .len = -1, .category = 'S', .array = 1009 },
        .oid => .{ .oid = 26, .name = "oid", .len = 4, .category = 'N', .array = 1028 },
        .json => .{ .oid = 114, .name = "json", .len = -1, .category = 'U', .array = 199 },
        .real => .{ .oid = 700, .name = "float4", .len = 4, .category = 'N', .array = 1021 },
        .double => .{ .oid = 701, .name = "float8", .len = 8, .category = 'N', .array = 1022 },
        .date => .{ .oid = 1082, .name = "date", .len = 4, .category = 'D', .array = 1182 },
        .timestamp => .{ .oid = 1114, .name = "timestamp", .len = 8, .category = 'D', .array = 1115 },
        .timestamptz => .{ .oid = 1184, .name = "timestamptz", .len = 8, .category = 'D', .array = 1185 },
        .interval => .{ .oid = 1186, .name = "interval", .len = 16, .category = 'T', .array = 1187 },
        .numeric => .{ .oid = 1700, .name = "numeric", .len = -1, .category = 'N', .array = 1231 },
        .jsonb => .{ .oid = 3802, .name = "jsonb", .len = -1, .category = 'U', .array = 3807 },
        .bpchar => .{ .oid = 1042, .name = "bpchar", .len = -1, .category = 'S', .array = 1014 },
        .varchar => .{ .oid = 1043, .name = "varchar", .len = -1, .category = 'S', .array = 1015 },
        .uuid => .{ .oid = 2950, .name = "uuid", .len = 16, .category = 'U', .array = 2951 },
        .bytea => .{ .oid = 17, .name = "bytea", .len = -1, .category = 'U', .array = 1001 },
        .time => .{ .oid = 1083, .name = "time", .len = 8, .category = 'D', .array = 1183 },
        .timetz => .{ .oid = 1266, .name = "timetz", .len = 12, .category = 'D', .array = 1270 },
        .bit => .{ .oid = 1560, .name = "bit", .len = -1, .category = 'V', .array = 1561 },
        .varbit => .{ .oid = 1562, .name = "varbit", .len = -1, .category = 'V', .array = 1563 },
        .money => .{ .oid = 790, .name = "money", .len = 8, .category = 'N', .array = 791 },
        .pg_lsn => .{ .oid = 3220, .name = "pg_lsn", .len = 8, .category = 'U', .array = 3221 },
        .xid8 => .{ .oid = 5069, .name = "xid8", .len = 8, .category = 'U', .array = 271 },
        .int4range => .{ .oid = 3904, .name = "int4range", .len = -1, .category = 'R', .array = 3905 },
        .int8range => .{ .oid = 3926, .name = "int8range", .len = -1, .category = 'R', .array = 3927 },
        .numrange => .{ .oid = 3906, .name = "numrange", .len = -1, .category = 'R', .array = 3907 },
        .daterange => .{ .oid = 3912, .name = "daterange", .len = -1, .category = 'R', .array = 3913 },
        .tsrange => .{ .oid = 3908, .name = "tsrange", .len = -1, .category = 'R', .array = 3909 },
        .tstzrange => .{ .oid = 3910, .name = "tstzrange", .len = -1, .category = 'R', .array = 3911 },
        .inet => .{ .oid = 869, .name = "inet", .len = -1, .category = 'I', .array = 1041 },
        .cidr => .{ .oid = 650, .name = "cidr", .len = -1, .category = 'I', .array = 651 },
        .macaddr => .{ .oid = 829, .name = "macaddr", .len = 6, .category = 'U', .array = 1040 },
        .point => .{ .oid = 600, .name = "point", .len = 16, .category = 'G', .array = 1017 },
        .box => .{ .oid = 603, .name = "box", .len = 32, .category = 'G', .array = 1020 },
        .xml => .{ .oid = 142, .name = "xml", .len = -1, .category = 'U', .array = 143 },
        .jsonpath => .{ .oid = 4072, .name = "jsonpath", .len = -1, .category = 'U', .array = 4073 },
        .regtype => .{ .oid = 2206, .name = "regtype", .len = 4, .category = 'N', .array = 2211 },
        _ => .{ .oid = 0, .name = "", .len = -1, .category = 'A', .array = 0 },
    };
}

/// PostgreSQL type OIDs carried by change records and descriptions.
pub fn typeOid(data_type: DataType) u32 {
    return typeInfo(data_type).oid;
}

/// SQL spelling of a type (format_type with no typmod, regtype output,
/// information_schema.columns.data_type).
pub fn sqlTypeName(data_type: DataType) []const u8 {
    if (elementData(data_type)) |element| return array_sql_names[@intFromEnum(element)];
    return baseSqlName(data_type);
}

fn baseSqlName(data_type: DataType) []const u8 {
    return switch (data_type) {
        .integer => "bigint",
        .integer32 => "integer",
        .smallint => "smallint",
        .boolean => "boolean",
        .text => "text",
        .numeric => "numeric",
        .real => "real",
        .double => "double precision",
        .name => "name",
        .oid => "oid",
        .date => "date",
        .timestamp => "timestamp without time zone",
        .timestamptz => "timestamp with time zone",
        .interval => "interval",
        .json => "json",
        .jsonb => "jsonb",
        .varchar => "character varying",
        .bpchar => "character",
        .uuid => "uuid",
        .bytea => "bytea",
        .time => "time without time zone",
        .timetz => "time with time zone",
        .bit => "bit",
        .varbit => "bit varying",
        .money => "money",
        .pg_lsn => "pg_lsn",
        .xid8 => "xid8",
        .int4range => "int4range",
        .int8range => "int8range",
        .numrange => "numrange",
        .daterange => "daterange",
        .tsrange => "tsrange",
        .tstzrange => "tstzrange",
        .inet => "inet",
        .cidr => "cidr",
        .macaddr => "macaddr",
        .point => "point",
        .box => "box",
        .xml => "xml",
        .jsonpath => "jsonpath",
        .regtype => "regtype",
        _ => "",
    };
}

/// pg_type.typinput (input function name).
pub fn typeInputName(data_type: DataType) []const u8 {
    return switch (data_type) {
        .integer => "int8in",
        .integer32 => "int4in",
        .smallint => "int2in",
        .boolean => "boolin",
        .text => "textin",
        .numeric => "numeric_in",
        .real => "float4in",
        .double => "float8in",
        .name => "namein",
        .oid => "oidin",
        .date => "date_in",
        .timestamp => "timestamp_in",
        .timestamptz => "timestamptz_in",
        .interval => "interval_in",
        .json => "json_in",
        .jsonb => "jsonb_in",
        .varchar => "varcharin",
        .bpchar => "bpcharin",
        .uuid => "uuid_in",
        .bytea => "byteain",
        .time => "time_in",
        .timetz => "timetz_in",
        .bit => "bit_in",
        .varbit => "varbit_in",
        .money => "cash_in",
        .pg_lsn => "pg_lsn_in",
        .xid8 => "xid8in",
        .int4range, .int8range, .numrange, .daterange, .tsrange, .tstzrange => "range_in",
        .inet => "inet_in",
        .cidr => "cidr_in",
        .macaddr => "macaddr_in",
        .point => "point_in",
        .box => "box_in",
        .xml => "xml_in",
        .jsonpath => "jsonpath_in",
        .regtype => "regtypein",
        _ => "array_in",
    };
}

/// regtype input: type names and aliases, optionally pg_catalog-qualified
/// or quoted, any typmod suffix ignored. null when unknown.
pub fn typeByName(input: []const u8) ?DataType {
    var trimmed = input;
    while (trimmed.len != 0 and (trimmed[trimmed.len - 1] == ' ' or trimmed[trimmed.len - 1] == '\t')) trimmed = trimmed[0 .. trimmed.len - 1];
    // `element[]` (any number of bracket pairs: arrays have no dimension type).
    if (trimmed.len > 2 and trimmed[trimmed.len - 1] == ']') {
        var end = trimmed.len;
        while (end > 0 and trimmed[end - 1] == ']') {
            var open = end - 1;
            while (open > 0 and trimmed[open - 1] != '[') open -= 1;
            if (open == 0) return null;
            for (trimmed[open .. end - 1]) |byte| if (!digit(byte)) return null;
            end = open - 1;
            while (end > 0 and trimmed[end - 1] == ' ') end -= 1;
        }
        const element = scalarByName(trimmed[0..end]) orelse return null;
        return arrayData(element);
    }
    return scalarByName(trimmed);
}

fn scalarByName(input: []const u8) ?DataType {
    var text = input;
    while (text.len != 0 and (text[0] == ' ' or text[0] == '\t')) text = text[1..];
    while (text.len != 0 and (text[text.len - 1] == ' ' or text[text.len - 1] == '\t')) text = text[0 .. text.len - 1];
    if (text.len > 11 and keyword(text[0..11], "pg_catalog.")) text = text[11..];
    var buffer: [40]u8 = undefined;
    var length: usize = 0;
    var quoted = false;
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        quoted = true;
        text = text[1 .. text.len - 1];
    }
    for (text) |byte| {
        if (byte == '(' and !quoted) break;
        if (length == buffer.len) return null;
        buffer[length] = if (quoted) byte else lower(byte);
        length += 1;
    }
    while (length != 0 and buffer[length - 1] == ' ') length -= 1;
    const name = buffer[0..length];
    const aliases = [_]struct { name: []const u8, data_type: DataType }{
        .{ .name = "integer", .data_type = .integer32 },     .{ .name = "int", .data_type = .integer32 },
        .{ .name = "bigint", .data_type = .integer },        .{ .name = "smallint", .data_type = .smallint },
        .{ .name = "boolean", .data_type = .boolean },       .{ .name = "real", .data_type = .real },
        .{ .name = "double precision", .data_type = .double }, .{ .name = "decimal", .data_type = .numeric },
        .{ .name = "timestamp without time zone", .data_type = .timestamp }, .{ .name = "timestamp with time zone", .data_type = .timestamptz },
        .{ .name = "character varying", .data_type = .varchar }, .{ .name = "char varying", .data_type = .varchar },
        .{ .name = "character", .data_type = .bpchar },      .{ .name = "char", .data_type = .bpchar },
        .{ .name = "time without time zone", .data_type = .time }, .{ .name = "time with time zone", .data_type = .timetz },
        .{ .name = "bit varying", .data_type = .varbit },
    };
    for (aliases) |alias| if (same(name, alias.name)) return alias.data_type;
    inline for (@typeInfo(DataType).@"enum".field_names) |field| {
        const data_type = @field(DataType, field);
        if (same(name, typeInfo(data_type).name)) return data_type;
        // `_element`: the array type's typname.
        if (name.len > 1 and name[0] == '_' and same(name[1..], typeInfo(data_type).name)) return arrayData(data_type);
    }
    return null;
}

/// regtypeout: the SQL name of a type OID ("-" for 0), including the
/// pseudo/catalog types an expression can report without a DataType.
pub fn regtypeName(oid: u32) ?[]const u8 {
    switch (oid) {
        0 => return "-",
        705 => return "unknown",
        2205 => return "regclass",
        else => {},
    }
    const data_type = typeFromOid(oid) orelse return null;
    return sqlTypeName(data_type);
}

/// regtypein: a numeric OID, "-" (0) or a type name (42704 when unknown).
pub fn regtypeInput(input: []const u8) error{ UndefinedObject, NumericValueOutOfRange }!u32 {
    if (input.len != 0 and input.len <= 10) {
        var value: u64 = 0;
        for (input) |byte| {
            if (!digit(byte)) break;
            value = value * 10 + (byte - '0');
        } else {
            if (value > 0xffffffff) return error.NumericValueOutOfRange;
            return @intCast(value);
        }
    }
    if (input.len == 1 and input[0] == '-') return 0;
    if (keyword(input, "unknown")) return 705;
    if (keyword(input, "regclass")) return 2205;
    const data_type = typeByName(input) orelse return error.UndefinedObject;
    return typeOid(data_type);
}

pub fn typeFromOid(oid: u32) ?DataType {
    inline for (@typeInfo(DataType).@"enum".field_names) |field| {
        if (typeInfo(@field(DataType, field)).oid == oid) return @field(DataType, field);
    }
    inline for (@typeInfo(DataType).@"enum".field_names) |field| {
        if (oid != 0 and baseInfo(@field(DataType, field)).array == oid) return arrayData(@field(DataType, field));
    }
    return null;
}

/// How a column gets a value it is not assigned (design §4.11).
pub const DefaultKind = enum(u8) { none = 0, default = 1, identity_always = 2, identity_by_default = 3, generated = 4 };

/// Statement kind of a completed (or described) statement.
pub const CommandTag = enum { none, select, insert, update, delete, create_table, drop_table, begin, commit, rollback, savepoint, release, set, show, reset, create_sequence, drop_sequence, copy, truncate, alter_table, alter_sequence, create_schema, drop_schema, create_index, drop_index, create_view, drop_view, create_materialized_view, drop_materialized_view, refresh_materialized_view, merge, set_constraints, create_table_as, lock_table, declare_cursor, fetch, move, close_cursor, prepare, deallocate, listen, notify, unlisten, create_function, drop_function, create_procedure, drop_procedure, call, do_block, create_trigger, drop_trigger, create_rule, drop_rule,
    // Catalog objects (B11 wave 3).
    create_role, alter_role, drop_role, grant, revoke, grant_role, revoke_role, create_policy, alter_policy, drop_policy, comment,
    create_foreign_data_wrapper, drop_foreign_data_wrapper, create_server, drop_server, create_publication, drop_publication, create_extension };

pub fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

pub fn letter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
}

pub fn digit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

pub fn keyword(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (lower(left) != lower(right)) return false;
    return true;
}

pub fn bytesOrder(a: []const u8, b: []const u8) i8 {
    const count = @min(a.len, b.len);
    for (0..count) |index| {
        if (a[index] < b[index]) return -1;
        if (a[index] > b[index]) return 1;
    }
    return if (a.len < b.len) -1 else if (a.len > b.len) 1 else 0;
}

pub fn Values(comptime config: Config) type {
    return struct {
        pub const Name = struct {
            bytes: [config.name_bytes]u8 = @splat(0),
            len: usize = 0,

            pub fn slice(self: *const Name) []const u8 {
                return self.bytes[0..self.len];
            }
        };

        pub const Text = struct {
            bytes: [config.text_bytes]u8 = @splat(0),
            len: usize = 0,

            pub fn slice(self: *const Text) []const u8 {
                return self.bytes[0..self.len];
            }
        };

        /// BIT and BIT VARYING values (bit_string.sig).
        pub const BitString = bit_string.Bits(config.text_bytes);

        /// smallint/int4/int8/oid are `integer`; text/name/json are `text`;
        /// `jsonb` holds the canonical binary (jsonb.sig) in a Text.
        /// varchar is `text`; `bpchar` (CHAR(n)) holds its padded bytes and
        /// compares/hashes without trailing spaces.
        pub const CellTag = enum { null_value, integer, boolean, text, float4, float8, numeric, date, timestamp, timestamptz, interval, jsonb, bpchar, uuid, bytea, time, timetz, bits, money, pg_lsn, xid8, array, range, inet, macaddr, point, box, xml, regtype };

        pub const Cell = union(CellTag) {
            null_value: void,
            integer: i64,
            boolean: bool,
            text: Text,
            float4: f32,
            float8: f64,
            numeric: numeric.Numeric,
            date: i32,
            timestamp: i64,
            timestamptz: i64,
            interval: temporal.Interval,
            jsonb: Text,
            bpchar: Text,
            uuid: uuid.Uuid,
            /// BYTEA raw bytes (not text).
            bytea: Text,
            /// TIME: microseconds since midnight (0 through 24:00:00).
            time: i64,
            timetz: time_of_day.TimeTz,
            /// BIT and BIT VARYING.
            bits: BitString,
            /// MONEY: cents (money.sig).
            money: i64,
            /// pg_lsn: a 64-bit WAL position (catalog_ids.sig).
            pg_lsn: u64,
            /// xid8: a 64-bit full transaction id (catalog_ids.sig).
            xid8: u64,
            /// Arrays of every element type (array.sig layout).
            array: Text,
            /// Built-in ranges (range.sig layout).
            range: Text,
            /// inet and cidr (network.sig; `cidr` marks a cidr value).
            inet: network.Inet,
            macaddr: network.Mac,
            point: geometric.Point,
            box: geometric.Box,
            /// XML: the stored (validated) text.
            xml: Text,
            /// regtype (pg_typeof): a type OID that prints as the type name.
            regtype: u32,
        };

        /// Range values of these cells (range.sig).
        pub const Ranges = range_module.Ranges(@This());

        /// Array values of these cells (array.sig).
        pub const Arrays = array_module.Arrays(@This());

        pub const Row = struct {
            cells: [config.columns]Cell = @splat(.null_value),
        };

        pub const Column = struct {
            name: Name = .{},
            data_type: DataType = .integer,
            /// PostgreSQL atttypmod: NUMERIC(p,s) ((p << 16) | s) + 4,
            /// TIMESTAMP[TZ](p) p, VARCHAR(n)/CHAR(n) n + 4; -1 when absent.
            typmod: i32 = -1,
            not_null: bool = false,
            primary_key: bool = false,
            /// DEFAULT, identity (owned sequence) or GENERATED ... STORED.
            default_kind: DefaultKind = .none,
            /// Source text of the DEFAULT or generation expression.
            expression: Text = .{},
            /// GENERATED ALWAYS AS (expr) VIRTUAL (default_kind generated):
            /// catalogs report 'v'. The immutable expression is evaluated
            /// when a row is written, so reads equal evaluation on read.
            virtual: bool = false,
        };

        pub fn cellTag(data_type: DataType) CellTag {
            return switch (data_type) {
                .integer, .integer32, .smallint, .oid => .integer,
                .boolean => .boolean,
                .text, .name, .json, .varchar, .jsonpath => .text,
                .real => .float4,
                .double => .float8,
                .numeric => .numeric,
                .date => .date,
                .timestamp => .timestamp,
                .timestamptz => .timestamptz,
                .interval => .interval,
                .jsonb => .jsonb,
                .bpchar => .bpchar,
                .uuid => .uuid,
                .bytea => .bytea,
                .time => .time,
                .timetz => .timetz,
                .bit, .varbit => .bits,
                .money => .money,
                .pg_lsn => .pg_lsn,
                .xid8 => .xid8,
                .int4range, .int8range, .numrange, .daterange, .tsrange, .tstzrange => .range,
                .inet, .cidr => .inet,
                .macaddr => .macaddr,
                .point => .point,
                .box => .box,
                .xml => .xml,
                .regtype => .regtype,
                _ => .array,
            };
        }

        /// NULL sorts first for ASC, last for DESC. Values have strict schema
        /// types (the binder inserts every implicit cast), so both sides carry
        /// the same tag; different tags order by tag.
        pub fn compare(left: *const Cell, right: *const Cell) i8 {
            if (left.* == .null_value) return if (right.* == .null_value) 0 else -1;
            if (right.* == .null_value) return 1;
            const lt = @intFromEnum(@as(CellTag, left.*));
            const rt = @intFromEnum(@as(CellTag, right.*));
            if (lt != rt) return if (lt < rt) -1 else 1;
            return switch (left.*) {
                .null_value => 0,
                .integer => |value| order(i64, value, right.integer),
                .boolean => |value| if (value == right.boolean) 0 else if (value) 1 else -1,
                .text => |*value| bytesOrder(value.slice(), right.text.slice()),
                .float4 => |value| floatOrder(f32, value, right.float4),
                .float8 => |value| floatOrder(f64, value, right.float8),
                .numeric => |*value| numeric.compareValues(value, &right.numeric),
                .date => |value| order(i32, value, right.date),
                .timestamp => |value| order(i64, value, right.timestamp),
                .timestamptz => |value| order(i64, value, right.timestamptz),
                .interval => |value| temporal.compareInterval(value, right.interval),
                .jsonb => |*value| J.compare(value.slice(), right.jsonb.slice()),
                .bpchar => |*value| bytesOrder(character.trimmed(value.slice()), character.trimmed(right.bpchar.slice())),
                .uuid => |*value| bytesOrder(value, &right.uuid),
                .bytea => |*value| bytesOrder(value.slice(), right.bytea.slice()),
                .time => |value| order(i64, value, right.time),
                .timetz => |value| time_of_day.compareTimeTz(value, right.timetz),
                .bits => |*value| BitString.compare(value, &right.bits),
                .money => |value| order(i64, value, right.money),
                .pg_lsn => |value| order(u64, value, right.pg_lsn),
                .xid8 => |value| order(u64, value, right.xid8),
                .array => |*value| Arrays.compare(value.slice(), right.array.slice()),
                .range => |*value| Ranges.compare(value.slice(), right.range.slice()),
                .inet => |*value| network.compare(value, &right.inet),
                .macaddr => |*value| bytesOrder(value, &right.macaddr),
                .point => |value| geometric.comparePoints(value, right.point),
                .box => |value| geometric.compareBoxes(value, right.box),
                .xml => |*value| bytesOrder(value.slice(), right.xml.slice()),
                // regtype sorts with oid's operators (binary coercible).
                .regtype => |value| order(u32, value, right.regtype),
            };
        }

        const J = jsonb.Jsonb(config.text_bytes, config.json_depth, config.numeric_digits);

        fn order(comptime T: type, a: T, b: T) i8 {
            return if (a < b) -1 else if (a > b) 1 else 0;
        }

        fn floatOrder(comptime T: type, a: T, b: T) i8 {
            const a_nan = a != a;
            const b_nan = b != b;
            if (a_nan or b_nan) return if (a_nan and b_nan) 0 else if (a_nan) 1 else -1;
            return order(T, a, b);
        }

        fn mix(code: *u64, bits_in: u64) void {
            var bits = bits_in;
            for (0..8) |_| {
                code.* = (code.* ^ @as(u8, @truncate(bits))) *% 1099511628211;
                bits >>= 8;
            }
        }

        /// Consistent with compare: equal values hash equally.
        fn wordHash(bits: u64, tag: u64) usize {
            var code = bits ^ (tag *% 0x9e3779b97f4a7c15);
            // Full 64-bit avalanche; unlike bytewise FNV this has no serial
            // dependency chain proportional to the fixed key's byte width.
            code ^= code >> 33;
            code *%= 0xff51afd7ed558ccd;
            code ^= code >> 33;
            code *%= 0xc4ceb9fe1a85ec53;
            code ^= code >> 33;
            return @truncate(code);
        }

        pub fn hash(value: *const Cell) usize {
            var code: u64 = 14695981039346656037;
            const tag: u64 = @intFromEnum(@as(CellTag, value.*));
            // Fixed-width keys do not need a serial byte-at-a-time FNV chain.
            // Include the type domain, then avalanche the normalized word below.
            // Variable/composite representations retain their canonical hashing.
            switch (value.*) {
                .integer => |integer| return wordHash(@bitCast(integer), tag),
                .text, .bytea, .xml => |*text| {
                    mix(&code, tag);
                    for (text.slice()) |byte| code = (code ^ byte) *% 1099511628211;
                },
                .boolean => |boolean| return wordHash(@intFromBool(boolean), tag),
                .float4 => |float| return wordHash(@bitCast(normalFloat(@floatCast(float))), tag),
                .float8 => |float| return wordHash(@bitCast(normalFloat(float)), tag),
                .numeric => |*number| {
                    mix(&code, tag);
                    for (numeric.numeric_hash(number)) |limb| mix(&code, limb);
                },
                .date => |days| return wordHash(@bitCast(@as(i64, days)), tag),
                .timestamp, .timestamptz, .time, .money => |us| return wordHash(@bitCast(us), tag),
                .pg_lsn, .xid8 => |word| return wordHash(word, tag),
                .regtype => |oid| return wordHash(oid, tag),
                .array => |*items| return wordHash(Arrays.hash(items.slice()), tag),
                .range => |*span| return wordHash(Ranges.hash(span.slice()), tag),
                // network_cmp ignores the cidr flag; so does the hash.
                .inet => |*address| {
                    mix(&code, tag);
                    mix(&code, @as(u64, address.family) << 8 | address.bits);
                    for (address.address) |byte| code = (code ^ byte) *% 1099511628211;
                },
                .macaddr => |*bytes| {
                    mix(&code, tag);
                    for (bytes) |byte| code = (code ^ byte) *% 1099511628211;
                },
                .point => |point| {
                    mix(&code, tag);
                    mix(&code, @bitCast(normalFloat(point.x)));
                    mix(&code, @bitCast(normalFloat(point.y)));
                },
                .box => |box| {
                    mix(&code, tag);
                    for ([_]f64{ box.high.x, box.high.y, box.low.x, box.low.y }) |coordinate| mix(&code, @bitCast(normalFloat(coordinate)));
                },
                .timetz => |time| {
                    mix(&code, tag);
                    mix(&code, @bitCast(time.us));
                    mix(&code, @as(u32, @bitCast(time.zone)));
                },
                .bits => |*bits| {
                    mix(&code, tag);
                    mix(&code, bits.len);
                    for (bits.slice()) |byte| code = (code ^ byte) *% 1099511628211;
                },
                .interval => |span| {
                    mix(&code, tag);
                    const total = temporal.intervalSpan(span);
                    mix(&code, @truncate(@as(u128, @bitCast(total))));
                    mix(&code, @truncate(@as(u128, @bitCast(total)) >> 64));
                },
                .jsonb => |*document| {
                    mix(&code, tag);
                    J.hash(document.slice(), 0, &code);
                },
                .bpchar => |*text| {
                    mix(&code, tag);
                    for (character.trimmed(text.slice())) |byte| code = (code ^ byte) *% 1099511628211;
                },
                .uuid => |*bytes| {
                    mix(&code, tag);
                    for (bytes) |byte| code = (code ^ byte) *% 1099511628211;
                },
                .null_value => unreachable,
            }
            // Mix low bits before the power-of-two table mask.
            code ^= code >> 33;
            code *%= 0xff51afd7ed558ccd;
            code ^= code >> 33;
            return @truncate(code);
        }

        fn normalFloat(value: f64) f64 {
            if (value != value) return @bitCast(@as(u64, 0x7ff8000000000000));
            return if (value == 0) 0 else value;
        }

        /// Stored-value checks: NOT NULL, exact type tag and integer ranges.
        pub fn validate(column: *const Column, value: *const Cell) Error!void {
            if (value.* == .null_value) {
                if (column.not_null) return error.NotNullViolation;
                return;
            }
            if (@as(CellTag, value.*) != cellTag(column.data_type)) return error.TypeMismatch;
            if (value.* == .inet and value.inet.cidr != (column.data_type == .cidr)) return error.TypeMismatch;
            if (value.* == .range) {
                const subtype = typeOfData(Ranges.subtypeOf(value.range.slice()));
                if (rangeSubtype(typeOfData(column.data_type)) != subtype) return error.TypeMismatch;
                return;
            }
            if (value.* == .array) {
                // The element type and every element's own checks (CHAR(n),
                // VARCHAR(n) and BIT(n) lengths apply to elements).
                const element = elementData(column.data_type) orelse return error.TypeMismatch;
                if (Arrays.elementType(value.array.slice()) != element) return error.TypeMismatch;
                const member: Column = .{ .data_type = element, .typmod = column.typmod };
                var reader = Arrays.Reader.init(value.array.slice());
                var cell: Cell = undefined;
                while (reader.next(&cell)) try validate(&member, &cell);
                return;
            }
            switch (column.data_type) {
                .varchar => if (!character.fits(value.text.slice(), column.typmod)) return error.StringDataRightTruncation,
                .bpchar => if (!character.fits(value.bpchar.slice(), column.typmod)) return error.StringDataRightTruncation,
                .bit, .varbit => {
                    _ = try bit_string.coercedLength(value.bits.len, column.typmod, column.data_type == .bit, .implicit);
                },
                // A stored jsonpath is its own canonical text (B11).
                .jsonpath => if (!jsonpath_module.Engine(config).validStored(value.text.slice())) return error.InvalidTextRepresentation,
                else => {},
            }
            if (value.* == .integer) {
                const integer = value.integer;
                switch (column.data_type) {
                    .integer32 => if (integer < -2147483648 or integer > 2147483647) return error.IntegerOverflow,
                    .smallint => if (integer < -32768 or integer > 32767) return error.NumericValueOutOfRange,
                    .oid => if (integer < 0 or integer > 4294967295) return error.NumericValueOutOfRange,
                    else => {},
                }
            }
        }
    };
}
