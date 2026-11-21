//! Versioned catalog base relations (Layer 0, design §4.10, review M2).
//!
//! The catalog is ordinary MVCC data: four base relations stored with the
//! same row directory and version arena as user tables (storage.sig), so a
//! table's existence follows exactly the same snapshot visibility rules as
//! its rows and DDL is transactional:
//!
//!   cat_relations  (oid, relname, relkind, relnamespace, slot)   tables + sequences rows
//!   cat_attributes (attrelid, attnum, attname, atttypid, attnotnull, attpk)  tables x columns
//!   cat_attrdef    (adrelid, adnum, adbin)                       tables x columns (empty until defaults)
//!   cat_sequences  (seqrelid, start, increment, max, min, cycle)  sequences
//!                  (values are non-transactional and live in the sequence slots)
//!   cat_namespaces pg_catalog (11), public (2200), information_schema,
//!                  pg_toast (99): static;
//!                  user schemas are cat_relations rows of relkind 'n'
//!                  (Config.schemas slots) and tables carry their namespace
//!
//! Every relation is sized by the user-object limits (Config.tables,
//! columns, sequences) with two versions per row, so user DDL hits
//! TableCapacity before the catalog fills; a catalog exhaustion is
//! CatalogCapacity (53200) and rolls the statement back. Every name lookup
//! reads cat_relations under the statement snapshot. A dropped table's
//! storage slot is reused only after its catalog version passes the
//! reclamation horizon.
const types = @import("types.sig");
const storage = @import("storage.sig");
const Error = types.Error;

pub const Relation = enum(u8) { relations = 0, attributes = 1, attrdef = 2, sequences = 3 };

pub const Namespace = struct { oid: u32, name: []const u8 };

pub const namespaces = [_]Namespace{
    .{ .oid = 11, .name = "pg_catalog" },
    .{ .oid = 2200, .name = "public" },
    .{ .oid = 13000, .name = "information_schema" },
    // TOAST relations live here in PostgreSQL; ZPM stores no TOAST tables,
    // so the schema is always empty and closed to user objects.
    .{ .oid = 99, .name = "pg_toast" },
};

pub const public_namespace: u32 = 2200;
pub const catalog_namespace: u32 = 11;
pub const information_namespace: u32 = 13000;
pub const toast_namespace: u32 = 99;

/// System views (design §4.10): virtual relations computed at scan time from
/// the catalog base relations, the table definitions and the static type
/// table under the statement snapshot. Some legacy metadata columns use
/// text representations. SQL identifiers use name (OID 19) and
/// cardinal_number uses int4.
pub const View = enum(u8) { pg_type, pg_namespace, pg_class, pg_attribute, pg_index, pg_attrdef, pg_sequence, schemata, tables, columns, table_constraints, key_column_usage, pg_indexes, pg_views, pg_matviews, pg_inherits,
    // Routines, triggers and rules (B11 wave 3).
    pg_proc, pg_trigger, pg_rewrite, pg_rules,
    // Catalog objects (B11 wave 3, catalog_objects.sig).
    pg_roles, pg_authid, pg_auth_members, pg_policy, pg_policies, pg_description, pg_shdescription, pg_foreign_data_wrapper, pg_foreign_server, pg_publication, pg_extension, pg_tables, table_privileges, pg_enum, pg_database, pg_am, pg_collation, pg_constraint, pg_statistic_ext,
    pg_publication_rel, pg_publication_namespace, pg_settings, pg_depend, pg_tablespace, pg_foreign_table,
    pg_init_privs, pg_cast, pg_transform, pg_language, pg_operator, pg_opclass, pg_opfamily, pg_ts_parser, pg_ts_template, pg_ts_dict, pg_ts_config, pg_default_acl, pg_conversion, pg_range, pg_event_trigger, pg_partitioned_table, pg_subscription,
    pg_seclabel, pg_shseclabel, pg_seclabels, pg_db_role_setting, pg_amop, pg_amproc, pg_largeobject, pg_largeobject_metadata };

pub const sql_language_oid: u32 = 14;
pub const plpgsql_language_oid: u32 = 13002;

pub const DatabaseCatalogRow = struct { oid: u32, owner: u32, name: []const u8 };
pub const DatabaseCatalogProvider = struct {
    context: ?*const anyopaque = null,
    capacity: usize,
    row: *const fn (?*const anyopaque, usize) ?DatabaseCatalogRow,
    /// A single-store listener may admit aliases for its only database.
    use_session_database_name: bool = false,
};

pub const ViewColumn = struct { name: []const u8, ty: types.Type };

fn col(name: []const u8, ty: types.Type) ViewColumn {
    return .{ .name = name, .ty = ty };
}

const pg_type_columns = [_]ViewColumn{
    col("oid", .oid), col("typname", .name), col("typnamespace", .oid), col("typlen", .int2), col("typtype", .pg_internal_char), col("typcategory", .text),
    col("typarray", .oid), col("typdelim", .text), col("typinput", .text), col("typbasetype", .oid), col("typelem", .oid),
    col("typowner", .oid), col("typtypmod", .int4), col("typnotnull", .boolean), col("typrelid", .oid), col("typcollation", .oid),
    col("typacl", types.arrayType(.aclitem).?), col("typisdefined", .boolean), col("typstorage", .pg_internal_char),
};
const pg_namespace_columns = [_]ViewColumn{ col("oid", .oid), col("nspname", .name), col("nspowner", .oid), col("nspacl", types.arrayType(.aclitem).?) };
pub const pg_namespace_acl_column = pg_namespace_columns.len - 1;
const pg_enum_columns = [_]ViewColumn{ col("oid", .oid), col("enumtypid", .oid), col("enumsortorder", .float4), col("enumlabel", .name) };
pub const utf8_encoding: i64 = 6;
pub const default_tablespace: i64 = 1663;
const pg_database_columns = [_]ViewColumn{
    col("oid", .oid), col("datname", .name), col("datdba", .oid), col("encoding", .int4),
    col("datlocprovider", .pg_internal_char), col("datistemplate", .boolean), col("datallowconn", .boolean),
    col("datconnlimit", .int4), col("datfrozenxid", .xid), col("datminmxid", .xid), col("dattablespace", .oid),
    col("datcollate", .text), col("datctype", .text), col("daticulocale", .text), col("datlocale", .text),
    col("daticurules", .text), col("datcollversion", .text), col("datacl", types.arrayType(.aclitem).?),
};
pub const constraint_catalog: u32 = 2606;
pub const attrdef_catalog: u32 = 2604;
pub const heap_access_method: u32 = 2;
pub const btree_access_method: u32 = 403;
pub const access_methods = [_]struct { oid: u32, name: []const u8, kind: u8, handler: u32, handler_name: []const u8, result: u32 }{
    .{ .oid = heap_access_method, .name = "heap", .kind = 't', .handler = 3, .handler_name = "heap_tableam_handler", .result = 269 },
    .{ .oid = btree_access_method, .name = "btree", .kind = 'i', .handler = 330, .handler_name = "bthandler", .result = 325 },
};
pub const internal_type_oid: u32 = 2281;
pub const builtin_pseudo_types = [_]struct { oid: u32, name: []const u8, bytes: i16, input: []const u8, storage: u8 = 'p' }{
    .{ .oid = 269, .name = "table_am_handler", .bytes = 4, .input = "table_am_handler_in" },
    .{ .oid = 325, .name = "index_am_handler", .bytes = 4, .input = "index_am_handler_in" },
    .{ .oid = internal_type_oid, .name = "internal", .bytes = @sizeOf(usize), .input = "internal_in" },
    .{ .oid = types.catalog_anyarray_oid, .name = "anyarray", .bytes = -1, .input = "anyarray_in", .storage = 'x' },
    .{ .oid = 2278, .name = "void", .bytes = 4, .input = "void_in" },
};

pub fn builtinRoutineName(oid: u32) ?[]const u8 {
    for (access_methods) |am| if (am.handler == oid) return am.handler_name;
    for (builtin_callbacks) |callback| if (callback.oid == oid) return callback.name;
    for (@import("operator_catalog.sig").functions) |op| if (op.function_oid == oid) return op.function_name;
    return null;
}

const BuiltinCallback = struct { oid: u32, name: []const u8, args: []const u32, result: u32 };

/// Catalog identities of the tokenizer used by the simple configuration.
/// Parser.init and Parser.next own startup and tokenization. End releases
/// caller-owned state and tokenKind supplies the lexical descriptors.
pub const text_parser = struct {
    pub const oid: u32 = 3722;
    pub const name = "default";
    pub const start: BuiltinCallback = .{ .oid = 3717, .name = "prsd_start", .args = &.{ internal_type_oid, 23 }, .result = internal_type_oid };
    pub const next: BuiltinCallback = .{ .oid = 3718, .name = "prsd_nexttoken", .args = &.{ internal_type_oid, internal_type_oid, internal_type_oid }, .result = internal_type_oid };
    pub const end: BuiltinCallback = .{ .oid = 3719, .name = "prsd_end", .args = &.{internal_type_oid}, .result = 2278 };
    pub const lex_type: BuiltinCallback = .{ .oid = 3721, .name = "prsd_lextype", .args = &.{internal_type_oid}, .result = internal_type_oid };
};

/// The built-in dictionary uses stateless default initialization and
/// the ASCII folding in text_search.sig. Its options are fixed.
pub const simple_template = struct {
    pub const oid: u32 = 3727;
    pub const name = "simple";
    pub const init: BuiltinCallback = .{ .oid = 3725, .name = "dsimple_init", .args = &.{internal_type_oid}, .result = internal_type_oid };
    pub const lexize: BuiltinCallback = .{ .oid = 3726, .name = "dsimple_lexize",
        .args = &.{ internal_type_oid, internal_type_oid, internal_type_oid, internal_type_oid }, .result = internal_type_oid };
};

pub const simple_dictionary = struct {
    pub const oid: u32 = 3765;
    pub const name = "simple";
    pub const template_oid = simple_template.oid;
};

pub const simple_configuration = struct {
    pub const oid: u32 = 3748;
    pub const name = "simple";
    pub const parser_oid = text_parser.oid;
};

fn canonicalCallback(comptime ty: types.DataType, oid: u32) BuiltinCallback {
    const range_oid = comptime types.typeOid(ty);
    return .{ .oid = oid, .name = @tagName(ty) ++ "_canonical", .args = &.{range_oid}, .result = range_oid };
}

const int4range_canonical = canonicalCallback(.int4range, 3914);
const int8range_canonical = canonicalCallback(.int8range, 3928);
const daterange_canonical = canonicalCallback(.daterange, 3915);

pub const builtin_callbacks = [_]BuiltinCallback{
    text_parser.start, text_parser.next, text_parser.end, text_parser.lex_type,
    simple_template.init, simple_template.lexize,
    int4range_canonical, int8range_canonical, daterange_canonical,
};

const RangeEntry = struct { oid: u32, subtype: u32, multirange: u32, opclass: u32, canonical: u32 };

fn rangeEntry(comptime ty: types.DataType, multirange: u32, canonical: u32) RangeEntry {
    const subtype = comptime types.dataTypeOf(types.rangeSubtype(types.typeOfData(ty)).?);
    return .{
        .oid = types.typeOid(ty),
        .subtype = types.typeOid(subtype),
        .multirange = multirange,
        .opclass = @import("index_operator_catalog.sig").defaultBtreeOid(subtype),
        .canonical = canonical,
    };
}

// Multirange OIDs identify PostgreSQL's companion types for the stock
// cast filter. They do not register multirange values or casts.
pub const ranges = [_]RangeEntry{
    rangeEntry(.int4range, 4451, int4range_canonical.oid),
    rangeEntry(.numrange, 4532, 0),
    rangeEntry(.tsrange, 4533, 0),
    rangeEntry(.tstzrange, 4534, 0),
    rangeEntry(.daterange, 4535, daterange_canonical.oid),
    rangeEntry(.int8range, 4536, int8range_canonical.oid),
};
const pg_am_columns = [_]ViewColumn{ col("oid", .oid), col("amname", .name), col("amhandler", .regproc), col("amtype", .pg_internal_char) };
const pg_amop_columns = [_]ViewColumn{
    col("oid", .oid), col("amopfamily", .oid), col("amoplefttype", .oid), col("amoprighttype", .oid),
    col("amopstrategy", .int2), col("amoppurpose", .pg_internal_char), col("amopopr", .oid),
    col("amopmethod", .oid), col("amopsortfamily", .oid),
};
const pg_amproc_columns = [_]ViewColumn{
    col("oid", .oid), col("amprocfamily", .oid), col("amproclefttype", .oid), col("amprocrighttype", .oid),
    col("amprocnum", .int2), col("amproc", .regproc),
};
const pg_collation_columns = [_]ViewColumn{
    col("oid", .oid), col("collname", .name), col("collnamespace", .oid), col("collowner", .oid),
    col("collprovider", .text), col("collisdeterministic", .boolean), col("collencoding", .int4),
};
const pg_tablespace_columns = [_]ViewColumn{
    col("oid", .oid), col("spcname", .name), col("spcowner", .oid),
    col("spcacl", types.arrayType(.aclitem).?), col("spcoptions", types.arrayType(.text).?),
};
const pg_foreign_table_columns = [_]ViewColumn{
    col("ftrelid", .oid), col("ftserver", .oid), col("ftoptions", types.arrayType(.text).?),
};
const pg_class_columns = [_]ViewColumn{
    col("oid", .oid), col("relname", .name), col("relnamespace", .oid), col("relkind", .pg_internal_char), col("relnatts", .int2),
    col("relchecks", .int2), col("relhasindex", .boolean), col("relhasrules", .boolean), col("relhastriggers", .boolean),
    col("relrowsecurity", .boolean), col("relforcerowsecurity", .boolean), col("relispartition", .boolean),
    col("reltablespace", .oid), col("reloftype", .oid), col("relpersistence", .text), col("relreplident", .text),
    col("reltoastrelid", .oid), col("relam", .oid), col("relispopulated", .boolean), col("relpartbound", .text),
    col("reltype", .oid), col("relowner", .oid), col("relpages", .int4), col("reltuples", .float4),
    col("relallvisible", .int4), col("relallfrozen", .int4), col("relfrozenxid", .xid), col("relminmxid", .xid),
    col("relacl", types.arrayType(.aclitem).?), col("reloptions", types.arrayType(.text).?),
};
pub const pg_class_acl_column = pg_class_columns.len - 2;
const pg_attribute_columns = [_]ViewColumn{
    col("attrelid", .oid), col("attname", .name), col("atttypid", .oid), col("atttypmod", .int4),
    col("attnum", .int2), col("attnotnull", .boolean), col("attisdropped", .boolean),
    col("attidentity", .pg_internal_char), col("attgenerated", .pg_internal_char), col("atthasdef", .boolean),
    col("attcollation", .oid), col("attlen", .int2), col("attalign", .pg_internal_char),
    col("attstattarget", .int2), col("attstorage", .pg_internal_char), col("attislocal", .boolean),
    col("attoptions", types.arrayType(.text).?), col("attfdwoptions", types.arrayType(.text).?),
    col("attcompression", .pg_internal_char), col("atthasmissing", .boolean), col("attmissingval", types.catalog_anyarray),
    col("attacl", types.arrayType(.aclitem).?),
};
const pg_index_columns = [_]ViewColumn{
    col("indexrelid", .oid), col("indrelid", .oid), col("indisprimary", .boolean), col("indisunique", .boolean), col("indkey", .text),
    col("indisvalid", .boolean), col("indisclustered", .boolean), col("indisreplident", .boolean),
    col("indisready", .boolean), col("indnkeyatts", .int2), col("indnatts", .int2),
    col("indnullsnotdistinct", .boolean), col("indexprs", .text),
};
const pg_constraint_columns = [_]ViewColumn{
    col("oid", .oid), col("conname", .name), col("connamespace", .oid), col("contype", .text),
    col("condeferrable", .boolean), col("condeferred", .boolean), col("conenforced", .boolean), col("convalidated", .boolean),
    col("conrelid", .oid), col("contypid", .oid), col("conindid", .oid), col("conparentid", .oid),
    col("confrelid", .oid), col("confupdtype", .text), col("confdeltype", .text), col("confmatchtype", .text),
    col("conperiod", .boolean), col("conislocal", .boolean),
};
const pg_depend_columns = [_]ViewColumn{
    col("classid", .oid), col("objid", .oid), col("objsubid", .int4),
    col("refclassid", .oid), col("refobjid", .oid), col("refobjsubid", .int4), col("deptype", .pg_internal_char),
};
const pg_statistic_ext_columns = [_]ViewColumn{
    col("oid", .oid), col("stxrelid", .oid), col("stxname", .name), col("stxnamespace", .oid),
    col("stxowner", .oid), col("stxstattarget", .int2), col("stxkeys", .text), col("stxkind", text_array), col("stxexprs", .text),
};
const pg_attrdef_columns = [_]ViewColumn{ col("adrelid", .oid), col("adnum", .int2), col("adbin", .text), col("oid", .oid) };
const pg_sequence_columns = [_]ViewColumn{ col("seqrelid", .oid), col("seqtypid", .oid), col("seqstart", .int8), col("seqincrement", .int8), col("seqmax", .int8), col("seqmin", .int8), col("seqcache", .int8), col("seqcycle", .boolean) };
const schemata_columns = [_]ViewColumn{ col("catalog_name", .name), col("schema_name", .name) };
const tables_columns = [_]ViewColumn{ col("table_catalog", .name), col("table_schema", .name), col("table_name", .name), col("table_type", .text) };
const columns_columns = [_]ViewColumn{ col("table_catalog", .name), col("table_schema", .name), col("table_name", .name), col("column_name", .name), col("ordinal_position", .int4), col("column_default", .text), col("is_nullable", .text), col("data_type", .varchar), col("character_maximum_length", .int4), col("numeric_precision", .int4), col("numeric_precision_radix", .int4), col("numeric_scale", .int4), col("datetime_precision", .int4), col("is_identity", .text), col("identity_generation", .text), col("is_generated", .text), col("generation_expression", .text) };
const table_constraints_columns = [_]ViewColumn{ col("constraint_catalog", .name), col("constraint_schema", .name), col("constraint_name", .name), col("table_catalog", .name), col("table_schema", .name), col("table_name", .name), col("constraint_type", .text) };
const pg_indexes_columns = [_]ViewColumn{ col("schemaname", .name), col("tablename", .name), col("indexname", .name), col("tablespace", .name), col("indexdef", .text) };
const pg_views_columns = [_]ViewColumn{ col("schemaname", .name), col("viewname", .name), col("viewowner", .name), col("definition", .text) };
const pg_matviews_columns = [_]ViewColumn{ col("schemaname", .name), col("matviewname", .name), col("matviewowner", .name), col("tablespace", .name), col("hasindexes", .boolean), col("ispopulated", .boolean), col("definition", .text) };
const pg_inherits_columns = [_]ViewColumn{ col("inhrelid", .oid), col("inhparent", .oid), col("inhseqno", .int4), col("inhdetachpending", .boolean) };
const pg_proc_columns = [_]ViewColumn{ col("oid", .oid), col("proname", .name), col("pronamespace", .oid), col("prokind", .pg_internal_char), col("prolang", .oid), col("provolatile", .pg_internal_char), col("proisstrict", .boolean), col("pronargs", .int2), col("prorettype", .oid), col("proargtypes", .text), col("prosrc", .text), col("proowner", .oid), col("proacl", types.arrayType(.aclitem).?) };
const pg_init_privs_columns = [_]ViewColumn{ col("objoid", .oid), col("classoid", .oid), col("objsubid", .int4), col("privtype", .pg_internal_char), col("initprivs", types.arrayType(.aclitem).?) };
const pg_default_acl_columns = [_]ViewColumn{
    col("oid", .oid), col("defaclrole", .oid), col("defaclnamespace", .oid),
    col("defaclobjtype", .pg_internal_char), col("defaclacl", types.arrayType(.aclitem).?),
};
const pg_conversion_columns = [_]ViewColumn{
    col("oid", .oid), col("conname", .name), col("connamespace", .oid), col("conowner", .oid),
    col("conforencoding", .int4), col("contoencoding", .int4), col("conproc", .regproc), col("condefault", .boolean),
};
const pg_range_columns = [_]ViewColumn{
    col("rngtypid", .oid), col("rngsubtype", .oid), col("rngmultitypid", .oid),
    col("rngcollation", .oid), col("rngsubopc", .oid), col("rngcanonical", .regproc), col("rngsubdiff", .regproc),
};
const pg_event_trigger_columns = [_]ViewColumn{
    col("oid", .oid), col("evtname", .name), col("evtevent", .name), col("evtowner", .oid),
    col("evtfoid", .oid), col("evtenabled", .pg_internal_char), col("evttags", types.arrayType(.text).?),
};
const pg_partitioned_table_columns = [_]ViewColumn{
    col("partrelid", .oid), col("partstrat", .pg_internal_char), col("partnatts", .int2), col("partdefid", .oid),
    col("partattrs", types.arrayType(.int2).?), col("partclass", types.arrayType(.oid).?),
    col("partcollation", types.arrayType(.oid).?), col("partexprs", .text),
};
const pg_cast_columns = [_]ViewColumn{ col("oid", .oid), col("castsource", .oid), col("casttarget", .oid), col("castfunc", .oid), col("castcontext", .pg_internal_char), col("castmethod", .pg_internal_char) };
const pg_transform_columns = [_]ViewColumn{ col("oid", .oid), col("trftype", .oid), col("trflang", .oid), col("trffromsql", .oid), col("trftosql", .oid) };
const pg_language_columns = [_]ViewColumn{ col("oid", .oid), col("lanname", .name), col("lanowner", .oid), col("lanispl", .boolean), col("lanpltrusted", .boolean), col("lanplcallfoid", .oid), col("laninline", .oid), col("lanvalidator", .oid), col("lanacl", types.arrayType(.aclitem).?) };
const pg_operator_columns = [_]ViewColumn{
    col("oid", .oid), col("oprname", .name), col("oprnamespace", .oid), col("oprowner", .oid),
    col("oprkind", .pg_internal_char), col("oprcanmerge", .boolean), col("oprcanhash", .boolean),
    col("oprleft", .oid), col("oprright", .oid), col("oprresult", .oid), col("oprcom", .oid),
    col("oprnegate", .oid), col("oprcode", .regproc), col("oprrest", .regproc), col("oprjoin", .regproc),
};
const pg_opclass_columns = [_]ViewColumn{
    col("oid", .oid), col("opcmethod", .oid), col("opcname", .name), col("opcnamespace", .oid),
    col("opcowner", .oid), col("opcfamily", .oid), col("opcintype", .oid), col("opcdefault", .boolean), col("opckeytype", .oid),
};
const pg_opfamily_columns = [_]ViewColumn{
    col("oid", .oid), col("opfmethod", .oid), col("opfname", .name), col("opfnamespace", .oid), col("opfowner", .oid),
};
const pg_ts_parser_columns = [_]ViewColumn{
    col("oid", .oid), col("prsname", .name), col("prsnamespace", .oid),
    col("prsstart", .regproc), col("prstoken", .regproc), col("prsend", .regproc),
    col("prsheadline", .regproc), col("prslextype", .regproc),
};
const pg_ts_template_columns = [_]ViewColumn{
    col("oid", .oid), col("tmplname", .name), col("tmplnamespace", .oid),
    col("tmplinit", .regproc), col("tmpllexize", .regproc),
};
const pg_ts_dict_columns = [_]ViewColumn{
    col("oid", .oid), col("dictname", .name), col("dictnamespace", .oid),
    col("dictowner", .oid), col("dicttemplate", .oid), col("dictinitoption", .text),
};
const pg_ts_config_columns = [_]ViewColumn{
    col("oid", .oid), col("cfgname", .name), col("cfgnamespace", .oid),
    col("cfgowner", .oid), col("cfgparser", .oid),
};

/// Implemented cataloged casts that have no separately callable function.
/// PostgreSQL bootstrap OIDs identify these shared binary-coercion paths.
pub const binary_casts = [_]struct { oid: u32, source: types.DataType, target: types.DataType }{
    .{ .oid = 10088, .source = .oid, .target = .regtype },
    .{ .oid = 10089, .source = .regtype, .target = .oid },
    .{ .oid = 10126, .source = .text, .target = .varchar },
    .{ .oid = 10129, .source = .varchar, .target = .text },
    .{ .oid = 10181, .source = .cidr, .target = .inet },
    .{ .oid = 10183, .source = .bit, .target = .varbit },
    .{ .oid = 10184, .source = .varbit, .target = .bit },
};
const pg_trigger_columns = [_]ViewColumn{ col("oid", .oid), col("tgrelid", .oid), col("tgname", .name), col("tgfoid", .oid), col("tgtype", .int2), col("tgenabled", .text), col("tgisinternal", .boolean), col("tgnargs", .int2), col("tgparentid", .oid) };
const pg_rewrite_columns = [_]ViewColumn{ col("oid", .oid), col("rulename", .name), col("ev_class", .oid), col("ev_type", .text), col("ev_enabled", .text), col("is_instead", .boolean) };
const pg_rules_columns = [_]ViewColumn{ col("schemaname", .name), col("tablename", .name), col("rulename", .name), col("definition", .text) };
const key_column_usage_columns = [_]ViewColumn{ col("constraint_catalog", .name), col("constraint_schema", .name), col("constraint_name", .name), col("table_catalog", .name), col("table_schema", .name), col("table_name", .name), col("column_name", .name), col("ordinal_position", .int4) };

const oid_array = types.arrayType(.oid).?;
const name_array = types.arrayType(.name).?;
const text_array = types.arrayType(.text).?;
const pg_seclabel_columns = [_]ViewColumn{
    col("objoid", .oid), col("classoid", .oid), col("objsubid", .int4), col("provider", .text), col("label", .text),
};
const pg_shseclabel_columns = [_]ViewColumn{
    col("objoid", .oid), col("classoid", .oid), col("provider", .text), col("label", .text),
};
const pg_seclabels_columns = [_]ViewColumn{
    col("objoid", .oid), col("classoid", .oid), col("objsubid", .int4), col("objtype", .text),
    col("objnamespace", .oid), col("objname", .text), col("provider", .text), col("label", .text),
};
const pg_db_role_setting_columns = [_]ViewColumn{ col("setdatabase", .oid), col("setrole", .oid), col("setconfig", text_array) };
const pg_largeobject_columns = [_]ViewColumn{ col("loid", .oid), col("pageno", .int4), col("data", .bytea) };
const pg_largeobject_metadata_columns = [_]ViewColumn{
    col("oid", .oid), col("lomowner", .oid), col("lomacl", types.arrayType(.aclitem).?),
};
const pg_subscription_columns = [_]ViewColumn{
    col("oid", .oid), col("subdbid", .oid), col("subskiplsn", .pg_lsn), col("subname", .name),
    col("subowner", .oid), col("subenabled", .boolean), col("subbinary", .boolean),
    col("substream", .pg_internal_char), col("subtwophasestate", .pg_internal_char),
    col("subdisableonerr", .boolean), col("subpasswordrequired", .boolean), col("subrunasowner", .boolean),
    col("subfailover", .boolean), col("subconninfo", .text), col("subslotname", .name),
    col("subsynccommit", .text), col("subpublications", text_array), col("suborigin", .text),
};
const pg_roles_columns = [_]ViewColumn{ col("rolname", .name), col("rolsuper", .boolean), col("rolinherit", .boolean), col("rolcreaterole", .boolean), col("rolcreatedb", .boolean), col("rolcanlogin", .boolean), col("rolreplication", .boolean), col("rolconnlimit", .int4), col("rolpassword", .text), col("rolvaliduntil", .timestamptz), col("rolbypassrls", .boolean), col("rolconfig", text_array), col("oid", .oid) };
const pg_authid_columns = [_]ViewColumn{ col("oid", .oid), col("rolname", .name), col("rolsuper", .boolean), col("rolinherit", .boolean), col("rolcreaterole", .boolean), col("rolcreatedb", .boolean), col("rolcanlogin", .boolean), col("rolreplication", .boolean), col("rolbypassrls", .boolean), col("rolconnlimit", .int4), col("rolpassword", .text), col("rolvaliduntil", .timestamptz) };
const pg_auth_members_columns = [_]ViewColumn{ col("oid", .oid), col("roleid", .oid), col("member", .oid), col("grantor", .oid), col("admin_option", .boolean), col("inherit_option", .boolean), col("set_option", .boolean) };
const pg_policy_columns = [_]ViewColumn{ col("oid", .oid), col("polname", .name), col("polrelid", .oid), col("polcmd", .text), col("polpermissive", .boolean), col("polroles", oid_array), col("polqual", .text), col("polwithcheck", .text) };
const pg_policies_columns = [_]ViewColumn{ col("schemaname", .name), col("tablename", .name), col("policyname", .name), col("permissive", .text), col("roles", name_array), col("cmd", .text), col("qual", .text), col("with_check", .text) };
const pg_description_columns = [_]ViewColumn{ col("objoid", .oid), col("classoid", .oid), col("objsubid", .int4), col("description", .text) };
const pg_shdescription_columns = [_]ViewColumn{ col("objoid", .oid), col("classoid", .oid), col("description", .text) };
const pg_foreign_data_wrapper_columns = [_]ViewColumn{ col("oid", .oid), col("fdwname", .name), col("fdwowner", .oid), col("fdwhandler", .oid), col("fdwvalidator", .oid), col("fdwacl", types.arrayType(.aclitem).?), col("fdwoptions", text_array) };
const pg_foreign_server_columns = [_]ViewColumn{ col("oid", .oid), col("srvname", .name), col("srvowner", .oid), col("srvfdw", .oid), col("srvtype", .text), col("srvversion", .text), col("srvacl", text_array), col("srvoptions", text_array) };
const pg_publication_columns = [_]ViewColumn{ col("oid", .oid), col("pubname", .name), col("pubowner", .oid), col("puballtables", .boolean), col("pubinsert", .boolean), col("pubupdate", .boolean), col("pubdelete", .boolean), col("pubtruncate", .boolean), col("pubviaroot", .boolean), col("pubgencols", .text) };
const pg_publication_rel_columns = [_]ViewColumn{
    col("oid", .oid), col("prpubid", .oid), col("prrelid", .oid), col("prqual", .text), col("prattrs", types.arrayType(.int2).?),
};
const pg_publication_namespace_columns = [_]ViewColumn{ col("oid", .oid), col("pnpubid", .oid), col("pnnspid", .oid) };
const pg_extension_columns = [_]ViewColumn{ col("oid", .oid), col("extname", .name), col("extowner", .oid), col("extnamespace", .oid), col("extrelocatable", .boolean), col("extversion", .text), col("extconfig", oid_array), col("extcondition", text_array) };
const pg_tables_columns = [_]ViewColumn{ col("schemaname", .name), col("tablename", .name), col("tableowner", .name), col("tablespace", .name), col("hasindexes", .boolean), col("hasrules", .boolean), col("hastriggers", .boolean), col("rowsecurity", .boolean) };
const table_privileges_columns = [_]ViewColumn{ col("grantor", .name), col("grantee", .name), col("table_catalog", .name), col("table_schema", .name), col("table_name", .name), col("privilege_type", .text), col("is_grantable", .text), col("with_hierarchy", .text) };

const pg_settings_columns = [_]ViewColumn{
    col("name", .text), col("setting", .text), col("unit", .text), col("category", .text), col("short_desc", .text),
    col("extra_desc", .text), col("context", .text), col("vartype", .text), col("source", .text), col("min_val", .text),
    col("max_val", .text), col("enumvals", text_array), col("boot_val", .text), col("reset_val", .text),
    col("sourcefile", .text), col("sourceline", .int4), col("pending_restart", .boolean),
};

pub fn viewColumns(view: View) []const ViewColumn {
    return switch (view) {
        .pg_type => &pg_type_columns,
        .pg_enum => &pg_enum_columns,
        .pg_database => &pg_database_columns,
        .pg_namespace => &pg_namespace_columns,
        .pg_am => &pg_am_columns,
        .pg_collation => &pg_collation_columns,
        .pg_class => &pg_class_columns,
        .pg_tablespace => &pg_tablespace_columns,
        .pg_foreign_table => &pg_foreign_table_columns,
        .pg_settings => &pg_settings_columns,
        .pg_attribute => &pg_attribute_columns,
        .pg_index => &pg_index_columns,
        .pg_constraint => &pg_constraint_columns,
        .pg_depend => &pg_depend_columns,
        .pg_statistic_ext => &pg_statistic_ext_columns,
        .pg_attrdef => &pg_attrdef_columns,
        .pg_sequence => &pg_sequence_columns,
        .schemata => &schemata_columns,
        .tables => &tables_columns,
        .columns => &columns_columns,
        .table_constraints => &table_constraints_columns,
        .key_column_usage => &key_column_usage_columns,
        .pg_indexes => &pg_indexes_columns,
        .pg_views => &pg_views_columns,
        .pg_matviews => &pg_matviews_columns,
        .pg_inherits => &pg_inherits_columns,
        .pg_proc => &pg_proc_columns,
        .pg_init_privs => &pg_init_privs_columns,
        .pg_default_acl => &pg_default_acl_columns,
        .pg_conversion => &pg_conversion_columns,
        .pg_range => &pg_range_columns,
        .pg_event_trigger => &pg_event_trigger_columns,
        .pg_partitioned_table => &pg_partitioned_table_columns,
        .pg_subscription => &pg_subscription_columns,
        .pg_seclabel => &pg_seclabel_columns,
        .pg_shseclabel => &pg_shseclabel_columns,
        .pg_seclabels => &pg_seclabels_columns,
        .pg_db_role_setting => &pg_db_role_setting_columns,
        .pg_amop => &pg_amop_columns,
        .pg_amproc => &pg_amproc_columns,
        .pg_largeobject => &pg_largeobject_columns,
        .pg_largeobject_metadata => &pg_largeobject_metadata_columns,
        .pg_cast => &pg_cast_columns,
        .pg_transform => &pg_transform_columns,
        .pg_language => &pg_language_columns,
        .pg_operator => &pg_operator_columns,
        .pg_opclass => &pg_opclass_columns,
        .pg_opfamily => &pg_opfamily_columns,
        .pg_ts_parser => &pg_ts_parser_columns,
        .pg_ts_template => &pg_ts_template_columns,
        .pg_ts_dict => &pg_ts_dict_columns,
        .pg_ts_config => &pg_ts_config_columns,
        .pg_trigger => &pg_trigger_columns,
        .pg_rewrite => &pg_rewrite_columns,
        .pg_rules => &pg_rules_columns,
        .pg_roles => &pg_roles_columns,
        .pg_authid => &pg_authid_columns,
        .pg_auth_members => &pg_auth_members_columns,
        .pg_policy => &pg_policy_columns,
        .pg_policies => &pg_policies_columns,
        .pg_description => &pg_description_columns,
        .pg_shdescription => &pg_shdescription_columns,
        .pg_foreign_data_wrapper => &pg_foreign_data_wrapper_columns,
        .pg_foreign_server => &pg_foreign_server_columns,
        .pg_publication => &pg_publication_columns,
        .pg_publication_rel => &pg_publication_rel_columns,
        .pg_publication_namespace => &pg_publication_namespace_columns,
        .pg_extension => &pg_extension_columns,
        .pg_tables => &pg_tables_columns,
        .table_privileges => &table_privileges_columns,
    };
}

/// pg_catalog views resolve unqualified (pg_catalog is searched first);
/// information_schema views only when qualified.
pub fn findView(schema: ?[]const u8, name: []const u8) ?View {
    const catalog_views = [_]View{ .pg_type, .pg_enum, .pg_namespace, .pg_am, .pg_collation, .pg_class, .pg_settings, .pg_attribute, .pg_index, .pg_constraint, .pg_depend, .pg_statistic_ext, .pg_attrdef, .pg_sequence, .pg_indexes, .pg_views, .pg_matviews, .pg_inherits, .pg_proc, .pg_trigger, .pg_rewrite, .pg_rules,
        .pg_tablespace, .pg_foreign_table, .pg_roles, .pg_authid, .pg_auth_members, .pg_policy, .pg_policies, .pg_description, .pg_shdescription, .pg_foreign_data_wrapper, .pg_foreign_server, .pg_publication, .pg_publication_rel, .pg_publication_namespace, .pg_extension, .pg_tables,
        .pg_init_privs, .pg_cast, .pg_transform, .pg_language, .pg_operator, .pg_opclass, .pg_opfamily, .pg_ts_parser, .pg_ts_template, .pg_ts_dict, .pg_ts_config, .pg_default_acl, .pg_conversion, .pg_range, .pg_event_trigger, .pg_partitioned_table, .pg_subscription,
        .pg_seclabel, .pg_shseclabel, .pg_seclabels, .pg_db_role_setting, .pg_amop, .pg_amproc, .pg_largeobject, .pg_largeobject_metadata };
    const information_views = [_]View{ .schemata, .tables, .columns, .table_constraints, .key_column_usage, .table_privileges };
    const qualified = schema orelse {
        for (catalog_views) |view| if (types.same(@tagName(view), name)) return view;
        return null;
    };
    if (types.same(qualified, "pg_catalog")) {
        for (catalog_views) |view| if (types.same(@tagName(view), name)) return view;
    } else if (types.same(qualified, "information_schema")) {
        for (information_views) |view| if (types.same(@tagName(view), name)) return view;
    }
    return null;
}

/// PostgreSQL bootstrap identities for implemented pg_catalog relations.
/// These are catalog constants, unlike initdb-assigned ordinary view OIDs.
pub const bootstrap_relations = [_]struct { view: View, oid: u32 }{
    .{ .view = .pg_type, .oid = 1247 }, .{ .view = .pg_attribute, .oid = 1249 },
    .{ .view = .pg_proc, .oid = 1255 }, .{ .view = .pg_class, .oid = 1259 },
    .{ .view = .pg_cast, .oid = 2605 }, .{ .view = .pg_language, .oid = 2612 },
    .{ .view = .pg_init_privs, .oid = 3394 }, .{ .view = .pg_transform, .oid = 3576 },
    .{ .view = .pg_default_acl, .oid = 826 },
    .{ .view = .pg_conversion, .oid = 2607 },
    .{ .view = .pg_range, .oid = 3541 },
    .{ .view = .pg_event_trigger, .oid = 3466 },
    .{ .view = .pg_partitioned_table, .oid = 3350 },
    .{ .view = .pg_subscription, .oid = 6100 },
    .{ .view = .pg_seclabel, .oid = 3596 },
    .{ .view = .pg_shseclabel, .oid = 3592 },
    .{ .view = .pg_db_role_setting, .oid = 2964 },
    .{ .view = .pg_amop, .oid = 2602 }, .{ .view = .pg_amproc, .oid = 2603 },
    .{ .view = .pg_largeobject, .oid = 2613 }, .{ .view = .pg_largeobject_metadata, .oid = 2995 },
    .{ .view = .pg_operator, .oid = 2617 },
    .{ .view = .pg_opclass, .oid = 2616 }, .{ .view = .pg_opfamily, .oid = 2753 },
    .{ .view = .pg_ts_parser, .oid = 3601 },
    .{ .view = .pg_ts_template, .oid = 3764 },
    .{ .view = .pg_ts_dict, .oid = 3600 },
    .{ .view = .pg_ts_config, .oid = 3602 },
    .{ .view = .pg_tablespace, .oid = 1213 }, .{ .view = .pg_foreign_table, .oid = 3118 },
    .{ .view = .pg_authid, .oid = 1260 }, .{ .view = .pg_auth_members, .oid = 1261 },
    .{ .view = .pg_database, .oid = 1262 }, .{ .view = .pg_foreign_server, .oid = 1417 },
    .{ .view = .pg_sequence, .oid = 2224 }, .{ .view = .pg_foreign_data_wrapper, .oid = 2328 },
    .{ .view = .pg_shdescription, .oid = 2396 }, .{ .view = .pg_am, .oid = 2601 },
    .{ .view = .pg_attrdef, .oid = attrdef_catalog }, .{ .view = .pg_constraint, .oid = constraint_catalog },
    .{ .view = .pg_depend, .oid = 2608 }, .{ .view = .pg_description, .oid = 2609 }, .{ .view = .pg_index, .oid = 2610 },
    .{ .view = .pg_inherits, .oid = 2611 }, .{ .view = .pg_namespace, .oid = 2615 },
    .{ .view = .pg_rewrite, .oid = 2618 }, .{ .view = .pg_trigger, .oid = 2620 },
    .{ .view = .pg_extension, .oid = 3079 }, .{ .view = .pg_policy, .oid = 3256 },
    .{ .view = .pg_statistic_ext, .oid = 3381 }, .{ .view = .pg_enum, .oid = 3501 },
    .{ .view = .pg_collation, .oid = 3456 }, .{ .view = .pg_publication, .oid = 6104 },
    .{ .view = .pg_publication_rel, .oid = 6106 }, .{ .view = .pg_publication_namespace, .oid = 6237 },
};

pub fn bootstrapRelationOid(view: View) ?u32 {
    for (bootstrap_relations) |relation| {
        if (relation.view == view) return relation.oid;
    }
    return null;
}

pub fn Catalog(comptime config: types.Config) type {
    const rows = @max(config.tables * config.columns, config.tables + config.sequences + config.schemas);
    const cat_config: types.Config = .{
        .tables = 1,
        .columns = 6,
        .rows_per_table = rows,
        .name_bytes = config.name_bytes,
        .text_bytes = @max(config.name_bytes, 8),
        .integer_bits = 64,
        .tx_writes = 1,
    };
    const CV = types.Values(cat_config);
    const SC = storage.Storage(cat_config);
    return struct {
        const Self = @This();
        pub const Storage = SC;
        pub const Cell = CV.Cell;

        relations: [4]SC.Table = @splat(.{}),
        databases: ?DatabaseCatalogProvider = null,

        pub fn findSystemView(self: *const Self, schema: ?[]const u8, name: []const u8) ?View {
            if (self.databases != null and types.same(schema orelse "pg_catalog", "pg_catalog") and types.same(name, "pg_database")) return .pg_database;
            return findView(schema, name);
        }

        pub fn relation(self: *Self, which: Relation) *SC.Table {
            return &self.relations[@intFromEnum(which)];
        }

        pub fn relationConst(self: *const Self, which: Relation) *const SC.Table {
            return &self.relations[@intFromEnum(which)];
        }

        fn text(value: []const u8) CV.Cell {
            var out: CV.Text = .{ .len = value.len };
            @memcpy(out.bytes[0..value.len], value);
            return .{ .text = out };
        }

        fn int(value: i64) CV.Cell {
            return .{ .integer = value };
        }

        /// One catalog version created or marked by a statement.
        pub const Change = struct { relation: Relation, version: u32 };

        /// Room for one relation's catalog rows.
        pub const max_changes = 1 + config.columns;

        /// A visible relation row: kind 'r' (table) or 'S' (sequence) and
        /// its table or sequence slot.
        pub const Found = struct { kind: u8, slot: usize };

        fn sequenceRow(slot: usize) u64 {
            return config.tables + slot + 1;
        }

        fn schemaRow(slot: usize) u64 {
            return config.tables + config.sequences + slot + 1;
        }

        /// A user schema: cat_relations row (oid, name, 'n', 0, slot).
        pub fn createSchema(self: *Self, slot: usize, oid: u32, name: []const u8, xmin: storage.TxRef, cid: u32, csn: u64, horizon: u64, out: *[max_changes]Change) Error!usize {
            const cells = [_]CV.Cell{ int(oid), text(name), text("n"), int(0), int(@intCast(slot)) };
            out[0] = .{ .relation = .relations, .version = try self.addVersion(.relations, schemaRow(slot), &cells, xmin, cid, csn, horizon) };
            return 1;
        }

        pub fn dropSchema(self: *Self, slot: usize, snap: storage.Snapshot, xmax: storage.TxRef, cid: u32, csn: u64, out: *[max_changes]Change) usize {
            const relations = self.relation(.relations);
            const version = visibleRow(relations, schemaRow(slot), snap) orelse return 0;
            mark(relations, version, xmax, cid, csn);
            out[0] = .{ .relation = .relations, .version = version };
            return 1;
        }

        pub const SchemaFound = struct { oid: u32, slot: usize };

        /// A user schema named `name` visible to `snap`.
        pub fn findSchema(self: *const Self, name: []const u8, snap: storage.Snapshot) ?SchemaFound {
            const relations = self.relationConst(.relations);
            var row_scratch: SC.VersionRowScratch = undefined;
            for (0..relations.row_high) |row| {
                const version = SC.visibleAt(relations, row, snap) orelse continue;
                const cells = SC.borrowVersionRow(relations, version, &row_scratch);
                if (cells[2].text.bytes[0] != 'n' or !sameName(&cells[1], name)) continue;
                return .{ .oid = @intCast(cells[0].integer), .slot = @intCast(cells[4].integer) };
            }
            return null;
        }

        /// Every user schema visible to `snap`, in catalog row order.
        pub fn visibleSchemas(self: *const Self, snap: storage.Snapshot, out: *[rows]SchemaFound) usize {
            const relations = self.relationConst(.relations);
            var row_scratch: SC.VersionRowScratch = undefined;
            var count: usize = 0;
            for (0..relations.row_high) |row| {
                const version = SC.visibleAt(relations, row, snap) orelse continue;
                const cells = SC.borrowVersionRow(relations, version, &row_scratch);
                if (cells[2].text.bytes[0] != 'n') continue;
                out[count] = .{ .oid = @intCast(cells[0].integer), .slot = @intCast(cells[4].integer) };
                count += 1;
            }
            return count;
        }

        /// A live transaction other than the snapshot's own with an
        /// uncommitted relation row in namespace `namespace`.
        pub fn namespaceCreator(self: *const Self, namespace: u32, snap: storage.Snapshot) ?u16 {
            const relations = self.relationConst(.relations);
            var row_scratch: SC.VersionRowScratch = undefined;
            for (relations.versions[0..relations.version_high], 0..) |*version, index| {
                if (version.rowLink() == 0 or version.xmin_csn != 0 or snap.own(version.xmin)) continue;
                if (version.xmax.epoch != 0) continue;
                const cells = SC.borrowVersionRow(relations, index, &row_scratch);
                if (cells[3] == .integer and cells[3].integer == namespace and cells[2].text.bytes[0] != 'n') return version.xmin.slot;
            }
            return null;
        }

        /// cat_relations (relkind S) and cat_sequences rows for a sequence slot.
        pub fn createSequence(self: *Self, slot: usize, seq: anytype, xmin: storage.TxRef, cid: u32, csn: u64, horizon: u64, out: *[max_changes]Change) Error!usize {
            var count: usize = 0;
            errdefer for (out[0..count]) |change| SC.reclaimVersion(self.relation(change.relation), change.version);
            const oid: i64 = seq.oid;
            const relation_cells = [_]CV.Cell{ int(oid), text(seq.name.slice()), text("S"), int(seq.namespace), int(@intCast(slot)) };
            out[count] = .{ .relation = .relations, .version = try self.addVersion(.relations, sequenceRow(slot), &relation_cells, xmin, cid, csn, horizon) };
            count += 1;
            const spec = seq.spec;
            const cells = [_]CV.Cell{ int(oid), int(spec.start), int(spec.increment), int(spec.max), int(spec.min), .{ .boolean = spec.cycle } };
            out[count] = .{ .relation = .sequences, .version = try self.addVersion(.sequences, slot + 1, &cells, xmin, cid, csn, horizon) };
            count += 1;
            return count;
        }

        pub fn dropSequence(self: *Self, slot: usize, snap: storage.Snapshot, xmax: storage.TxRef, cid: u32, csn: u64, out: *[max_changes]Change) usize {
            var count: usize = 0;
            const relations = self.relation(.relations);
            if (visibleRow(relations, sequenceRow(slot), snap)) |version| {
                mark(relations, version, xmax, cid, csn);
                out[count] = .{ .relation = .relations, .version = version };
                count += 1;
            }
            const sequences = self.relation(.sequences);
            if (visibleRow(sequences, slot + 1, snap)) |version| {
                mark(sequences, version, xmax, cid, csn);
                out[count] = .{ .relation = .sequences, .version = version };
                count += 1;
            }
            return count;
        }

        pub const relation_rows = rows;

        /// Every relation (table or sequence) visible to `snap`, in
        /// catalog row order. Schemas are listed by visibleSchemas.
        pub fn visibleRelations(self: *const Self, snap: storage.Snapshot, out: *[rows]Found) usize {
            const relations = self.relationConst(.relations);
            var row_scratch: SC.VersionRowScratch = undefined;
            var count: usize = 0;
            for (0..relations.row_high) |row| {
                const version = SC.visibleAt(relations, row, snap) orelse continue;
                const cells = SC.borrowVersionRow(relations, version, &row_scratch);
                if (cells[2].text.bytes[0] == 'n') continue;
                out[count] = .{ .kind = cells[2].text.bytes[0], .slot = @intCast(cells[4].integer) };
                count += 1;
            }
            return count;
        }

        /// Any relation (table or sequence) named `name` in the public
        /// schema (the default search_path) visible to `snap`.
        pub fn find(self: *const Self, name: []const u8, snap: storage.Snapshot) ?Found {
            return self.findIn(public_namespace, name, snap);
        }

        /// A table or sequence named `name` in schema `namespace`.
        pub fn findIn(self: *const Self, namespace: u32, name: []const u8, snap: storage.Snapshot) ?Found {
            const relations = self.relationConst(.relations);
            var row_scratch: SC.VersionRowScratch = undefined;
            for (0..relations.row_high) |row| {
                const version = SC.visibleAt(relations, row, snap) orelse continue;
                const cells = SC.borrowVersionRow(relations, version, &row_scratch);
                if (cells[2].text.bytes[0] == 'n' or cells[3].integer != namespace) continue;
                if (sameName(&cells[1], name)) return .{ .kind = cells[2].text.bytes[0], .slot = @intCast(cells[4].integer) };
            }
            return null;
        }

        fn addVersion(self: *Self, which: Relation, rowid: u64, cells: []const CV.Cell, xmin: storage.TxRef, cid: u32, csn: u64, horizon: u64) Error!u32 {
            const table = self.relation(which);
            SC.ensureVersions(table, 1, horizon) catch return error.CatalogCapacity;
            SC.ensureRowSlot(table, horizon) catch return error.CatalogCapacity;
            if (SC.findRow(table, rowid) != null) _ = SC.vacuum(table, horizon);
            if (SC.findRow(table, rowid) != null) return error.CatalogCapacity;
            const slot = SC.allocRow(table, rowid);
            return SC.createVersion(table, .{ .row = slot, .xmin = xmin, .cid = cid, .csn = csn }, cells);
        }

        /// Writes cat_relations and cat_attributes rows for a table slot.
        /// `csn` 0 leaves them uncommitted (owned by xmin); replay passes the
        /// record's csn. On error every version created here is freed.
        pub fn create(self: *Self, slot: usize, table: anytype, xmin: storage.TxRef, cid: u32, csn: u64, horizon: u64, out: *[max_changes]Change) Error!usize {
            var count: usize = 0;
            errdefer for (out[0..count]) |change| SC.reclaimVersion(self.relation(change.relation), change.version);
            const oid: i64 = table.oid;
            const kind = [1]u8{table.relkind};
            const relation_cells = [_]CV.Cell{ int(oid), text(table.name.slice()), text(&kind), int(table.namespace), int(@intCast(slot)) };
            out[count] = .{ .relation = .relations, .version = try self.addVersion(.relations, slot + 1, &relation_cells, xmin, cid, csn, horizon) };
            count += 1;
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                const cells = [_]CV.Cell{ int(oid), int(@intCast(index + 1)), text(column.name.slice()), int(types.typeOid(column.data_type)), .{ .boolean = column.not_null }, .{ .boolean = column.primary_key } };
                out[count] = .{ .relation = .attributes, .version = try self.addVersion(.attributes, slot * config.columns + index + 1, &cells, xmin, cid, csn, horizon) };
                count += 1;
            }
            return count;
        }

        fn visibleRow(table: *const SC.Table, rowid: u64, snap: storage.Snapshot) ?u32 {
            const slot = SC.findRow(table, rowid) orelse return null;
            return SC.visibleAt(table, slot, snap);
        }

        /// Marks a table slot's visible catalog rows deleted by xmax.
        pub fn drop(self: *Self, slot: usize, column_count: usize, snap: storage.Snapshot, xmax: storage.TxRef, cid: u32, csn: u64, out: *[max_changes]Change) usize {
            var count: usize = 0;
            const relations = self.relation(.relations);
            if (visibleRow(relations, slot + 1, snap)) |version| {
                mark(relations, version, xmax, cid, csn);
                out[count] = .{ .relation = .relations, .version = version };
                count += 1;
            }
            const attributes = self.relation(.attributes);
            for (0..column_count) |index| {
                if (visibleRow(attributes, slot * config.columns + index + 1, snap)) |version| {
                    mark(attributes, version, xmax, cid, csn);
                    out[count] = .{ .relation = .attributes, .version = version };
                    count += 1;
                }
            }
            return count;
        }

        fn mark(table: *SC.Table, version: u32, xmax: storage.TxRef, cid: u32, csn: u64) void {
            table.versions[version].xmax = xmax;
            table.versions[version].xmax_cid = cid;
            table.versions[version].xmax_csn = csn;
        }

        fn sameName(cell: *const CV.Cell, name: []const u8) bool {
            return cell.* == .text and types.same(cell.text.slice(), name);
        }

        /// Table slot whose relation row named `name` is visible to `snap`.
        pub fn lookup(self: *const Self, name: []const u8, snap: storage.Snapshot) ?usize {
            const found = self.find(name, snap) orelse return null;
            return if (found.kind == 'r' or found.kind == 'm' or found.kind == 'p' or found.kind == 'v') found.slot else null;
        }

        /// A live transaction other than the snapshot's own that has an
        /// uncommitted relation row with this name.
        pub fn creator(self: *const Self, name: []const u8, snap: storage.Snapshot) ?u16 {
            return self.creatorIn(null, name, snap);
        }

        pub fn creatorIn(self: *const Self, namespace: ?u32, name: []const u8, snap: storage.Snapshot) ?u16 {
            const relations = self.relationConst(.relations);
            for (relations.versions[0..relations.version_high], 0..) |*version, index| {
                if (version.rowLink() == 0 or version.xmin_csn != 0 or snap.own(version.xmin)) continue;
                if (version.xmax.epoch != 0) continue;
                var temporary: CV.Cell = undefined;
                if (!sameName(SC.borrowVersionCell(relations, index, 1, &temporary), name)) continue;
                if (namespace) |requested| {
                    if (SC.borrowVersionCell(relations, index, 3, &temporary).integer != requested) continue;
                }
                return version.xmin.slot;
            }
            return null;
        }

        /// Column definitions of a slot as cat_attributes holds them.
        pub fn attributeCount(self: *const Self, slot: usize, snap: storage.Snapshot) usize {
            const attributes = self.relationConst(.attributes);
            var count: usize = 0;
            for (0..config.columns) |index| {
                if (visibleRow(attributes, slot * config.columns + index + 1, snap) != null) count += 1;
            }
            return count;
        }

        pub fn stamp(self: *Self, change: Change, csn: u64, creation: bool) void {
            const version = &self.relation(change.relation).versions[change.version];
            if (creation) version.xmin_csn = csn else version.xmax_csn = csn;
        }

        /// Undoes one change of an aborting (sub)transaction.
        pub fn undo(self: *Self, change: Change, creation: bool) void {
            const table = self.relation(change.relation);
            if (creation) {
                SC.reclaimVersion(table, change.version);
            } else {
                table.versions[change.version].xmax = .{};
                table.versions[change.version].xmax_cid = 0;
                table.versions[change.version].xmax_csn = 0;
            }
        }

        /// Reclaims dead catalog versions at the horizon.
        pub fn vacuum(self: *Self, horizon: u64) usize {
            var freed: usize = 0;
            for (&self.relations) |*table| freed += SC.vacuum(table, horizon);
            return freed;
        }

        /// Live (committed or pending) catalog versions, for leak checks.
        pub fn versions(self: *const Self) usize {
            var count: usize = 0;
            for (&self.relations) |*table| count += table.version_used;
            return count;
        }

        pub fn pending(self: *const Self) usize {
            var count: usize = 0;
            for (&self.relations) |*table| count += SC.stats(table).pending;
            return count;
        }

    };
}
