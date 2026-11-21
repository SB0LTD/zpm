//! System-view contracts (design §4.10, §5.14/§5.15): pg_catalog and
//! information_schema views are computed at scan time from the versioned
//! catalog, the table definitions and the static type table under the
//! statement snapshot, so they change after every mutation (create, drop,
//! recreate at Config.tables = 2 without CatalogCapacity), follow
//! transactional DDL (uncommitted CREATE invisible to others, ROLLBACK
//! removes it) and survive change-record replay with the same OIDs. No code
//! path is keyed on query text. The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");
// Catalog views share the query workspace with the correlated collation
// lookup. Provision both sources and the nested join in this fixture.
const DB = sql.Database(.{ .tables = 2, .columns = 6, .projection_columns = 48, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .work_rows = 512 });
var assertions: usize = 0;
var db: DB = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("catalog contract failed at assertion {d}\n", .{assertions});
        return error.CatalogContractFailed;
    }
}

var text_buffer: [4096]u8 = undefined;
fn render(result: *const DB.Result) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [DB.Io.format_bytes]u8 = undefined;
    for (0..result.row_count) |row| {
        if (row != 0) {
            text_buffer[at] = ';';
            at += 1;
        }
        for (0..result.column_count) |column| {
            if (column != 0) {
                text_buffer[at] = '|';
                at += 1;
            }
            const cell = &result.rows[row].cells[column];
            const text = if (cell.* == .null_value) "NULL" else try DB.Io.format(cell, false, DB.Result.default_session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn expectOn(target: *DB, source: []const u8, wanted: []const u8) !void {
    var result: DB.Result = .{};
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    const got = try render(&result);
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("{s}\n  got  {s}\n  want {s}\n", .{ source, got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn expect(source: []const u8, wanted: []const u8) !void {
    return expectOn(&db, source, wanted);
}

fn run(source: []const u8) !void {
    var result: DB.Result = .{};
    db.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn rejects(source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    if (db.execute(source, &result)) |_| return error.InvalidStatementAccepted else |err| {
        if (err != wanted) std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        try check(err == wanted);
    }
}

const public_tables = "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name";
const public_classes = "SELECT relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY relname";

fn types() !void {
    try expect("SELECT oid, typname FROM pg_catalog.pg_type WHERE typname = 'int4'", "23|int4");
    try expect("SELECT COUNT(*), MIN(typnamespace), MAX(typnamespace) FROM pg_type", "99|11|11");
    try expect("SELECT oid, typname, typlen, typarray, typelem FROM pg_type WHERE oid IN (1033,1034) ORDER BY oid", "1033|aclitem|16|1034|0;1034|_aclitem|-1|0|1033");
    try expect("SELECT oid, typname, typlen, typarray, typelem FROM pg_type WHERE oid IN (18,1002) ORDER BY oid", "18|char|1|1002|0;1002|_char|-1|0|18");
    try expect("SELECT typname, typlen, typcategory, typarray, typinput FROM pg_type WHERE oid IN (4072, 4073) ORDER BY oid", "jsonpath|-1|U|4073|jsonpath_in;_jsonpath|-1|A|0|array_in");
    try expect("SELECT typname, typlen, typcategory, typarray, typdelim, typinput FROM pg_type WHERE oid IN (16, 1700, 3802) ORDER BY oid", "bool|1|B|1000|,|boolin;numeric|-1|N|1231|,|numeric_in;jsonb|-1|U|3807|,|jsonb_in");
    try expect("SELECT typname, oid::regtype::text, format_type(oid, NULL) FROM pg_type WHERE typname IN ('int8', 'float8', 'timestamptz') ORDER BY typname", "float8|double precision|double precision;int8|bigint|bigint;timestamptz|timestamp with time zone|timestamp with time zone");
    try expect("SELECT typname FROM pg_type t WHERE t.oid = to_regtype('integer')", "int4");
    try expect("SELECT 23::PG_CATALOG.regtype::pg_catalog.text, CAST('23' AS \"pg_catalog\".\"oid\"), ARRAY['x','y']::pg_catalog.text[]", "integer|23|{x,y}");
    try rejects("SELECT 23::pg_catalog.\"TEXT\"", error.UndefinedObject);
    try expect("SELECT to_regtype('nope') IS NULL, to_regtype('pg_catalog.numeric(10,2)'), 'int8'::regtype = 20::oid", "t|1700|t");
    try expect("SELECT format_type(1700, 655366), format_type(1184, 3), format_type(23, -1), format_type(99999, NULL)", "numeric(10,2)|timestamp(3) with time zone|integer|???");
    try rejects("SELECT 'nope'::regtype", error.UndefinedObject);
    try expect("SELECT current_database(), current_schema()", "postgres|public");
    try expect("SELECT nspname FROM pg_namespace ORDER BY oid", "pg_catalog;pg_toast;public;information_schema");
    try expect("SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'public'", "public");
    try expect(public_tables, "");
}

fn dumpDiscovery() !void {
    try expect("SELECT oid,spcname,spcowner,spcacl IS NULL,spcoptions IS NULL FROM pg_tablespace ORDER BY oid",
        "1663|pg_default|10|t|t;1664|pg_global|10|t|t");
    try expect("SELECT COUNT(*) FROM pg_foreign_table", "0");
    try expect("SELECT array_remove(ARRAY[1,NULL,1,3],1), array_remove(ARRAY[1,NULL,3],NULL)", "{NULL,3}|{1,3}");
    try expect("SELECT array_remove('[0:2]={1,2,1}'::int4[], 1)", "[0:0]={2}");
    try rejects("SELECT array_remove(ARRAY[[1,2],[3,4]], 1)", error.UnsupportedStatement);
    try run("CREATE TABLE discoverable(id INT)");
    try expect("SELECT c.relname, c.relowner, c.relpages, c.reltuples, c.relallvisible, c.relallfrozen, "
        ++ "c.relfrozenxid, c.relminmxid, c.reloptions IS NULL, c.relacl IS NULL, s.spcname IS NULL "
        ++ "FROM pg_class c LEFT JOIN pg_tablespace s ON c.reltablespace = s.oid WHERE c.relname='discoverable'",
        "discoverable|10|0|-1|0|0|0|0|t|t|t");
    try expect("SELECT pg_typeof(c.relfrozenxid)::text, pg_typeof(c.relacl)::text FROM pg_class c WHERE c.relname='discoverable'",
        "xid|aclitem[]");
    try run("CREATE ROLE catalog_reader");
    try run("GRANT SELECT, MAINTAIN ON discoverable TO catalog_reader WITH GRANT OPTION");
    try expect("SELECT relacl::text FROM pg_class WHERE relname='discoverable'",
        "{ramsql=arwdDxt/ramsql,catalog_reader=r*m*/ramsql}");
    try run("REVOKE ALL ON discoverable FROM catalog_reader");
    try expect("SELECT relacl IS NULL FROM pg_class WHERE relname='discoverable'", "t");
    try run("DROP ROLE catalog_reader");
    try expect("SELECT 1,2,3,4,5,6,7,8,9,10", "1|2|3|4|5|6|7|8|9|10");
    try run("INSERT INTO discoverable VALUES (2),(1),(1)");
    try expect("SELECT DISTINCT 1,2,3,4,5,6,7,8,9,id FROM discoverable ORDER BY 10",
        "1|2|3|4|5|6|7|8|9|1;1|2|3|4|5|6|7|8|9|2");
    try rejects("CREATE TABLE still_bounded(a INT,b INT,c INT,d INT,e INT,f INT,g INT)", error.ColumnCapacity);
    try run("DROP TABLE discoverable");
}

fn typeDiscovery() !void {
    try expect("SELECT oid,typacl,typisdefined,typtype,typname[0] FROM pg_type WHERE oid IN (23,1007,3904) ORDER BY oid",
        "23|NULL|t|b|i;1007|NULL|t|b|_;3904|NULL|t|r|i");
    try expect("SELECT pg_typeof(typacl)::text,acldefault('T',typowner)::text,acldefault('t',typowner)::text FROM pg_type WHERE oid=23",
        "aclitem[]|{=U/ramsql,ramsql=U/ramsql}|{ramsql=C/ramsql}");
    try expect("SELECT ('abc'::name)[0],('abc'::name)[2],('abc'::name)[3]::int,('abc'::name)[63]::int,('abc'::name)[64],('abc'::name)[-1],('abc'::name)[NULL]",
        "a|c|0|0|NULL|NULL|NULL");
    try expect("SELECT ('é'::name)[0]::int,('é'::name)[1]::int,('abc'::name)[0][1],(NULL::name)[0]", "-61|-87|NULL|NULL");
    try expect("SELECT length((repeat('a',62) || 'é')::name::text)", "62");
    try rejects("SELECT ('abc'::name)[0:1]", error.UnsupportedStatement);
}

fn indexOperatorDiscovery() !void {
    try expect("SELECT COUNT(*),COUNT(DISTINCT opcfamily) FROM pg_opclass", "26|21");
    try expect("SELECT c.tableoid,c.oid,a.amname,t.typname,f.opfname,c.opcdefault,c.opckeytype "
        ++ "FROM pg_opclass c JOIN pg_am a ON a.oid=c.opcmethod JOIN pg_type t ON t.oid=c.opcintype "
        ++ "JOIN pg_opfamily f ON f.oid=c.opcfamily AND f.opfmethod=a.oid WHERE c.opcname='int4_ops'",
        "2616|1978|btree|int4|integer_ops|t|0");
    try expect("SELECT tableoid,oid,opfmethod,opfnamespace,opfowner FROM pg_opfamily WHERE opfname='integer_ops'",
        "2753|1976|403|11|10");
}

fn textParserDiscovery() !void {
    try expect("SELECT tableoid,oid,prsname,prsnamespace,prsstart::oid,prstoken::oid,"
        ++ "prsend::oid,prsheadline::oid,prslextype::oid FROM pg_catalog.pg_ts_parser",
        "3601|3722|default|11|3717|3718|3719|0|3721");
    try expect("SELECT prsstart,prstoken,prsend,prsheadline,prslextype FROM pg_ts_parser",
        "prsd_start|prsd_nexttoken|prsd_end|-|prsd_lextype");
    try expect("SELECT to_regproc('pg_catalog.prsd_end')::oid,pg_typeof(prslextype)::text FROM pg_ts_parser",
        "3719|regproc");
    try expect("SELECT typname,typtype FROM pg_type WHERE oid=2278", "void|p");
}

fn textTemplateDiscovery() !void {
    try expect("SELECT tableoid,oid,tmplname,tmplnamespace,tmplinit::oid,tmpllexize::oid FROM pg_ts_template",
        "3764|3727|simple|11|3725|3726");
    try expect("SELECT tmplinit,tmpllexize,pg_typeof(tmpllexize)::text FROM pg_catalog.pg_ts_template",
        "dsimple_init|dsimple_lexize|regproc");
    try expect("SELECT to_regproc('pg_catalog.dsimple_init')::oid,to_regproc('dsimple_lexize')::oid",
        "3725|3726");
}

fn textDictionaryDiscovery() !void {
    try expect("SELECT tableoid,oid,dictname,dictnamespace,dictowner,dicttemplate,dictinitoption IS NULL FROM pg_ts_dict",
        "3600|3765|simple|11|10|3727|t");
    try expect("SELECT d.dictname,n.nspname,t.tmplname FROM pg_catalog.pg_ts_dict d "
        ++ "JOIN pg_namespace n ON n.oid=d.dictnamespace JOIN pg_ts_template t ON t.oid=d.dicttemplate "
        ++ "JOIN pg_roles r ON r.oid=d.dictowner WHERE r.oid=10",
        "simple|pg_catalog|simple");
}

fn textConfigurationDiscovery() !void {
    try expect("SELECT tableoid,oid,cfgname,cfgnamespace,cfgowner,cfgparser FROM pg_ts_config",
        "3602|3748|simple|11|10|3722");
    try expect("SELECT c.cfgname,n.nspname,p.prsname FROM pg_catalog.pg_ts_config c "
        ++ "JOIN pg_namespace n ON n.oid=c.cfgnamespace JOIN pg_ts_parser p ON p.oid=c.cfgparser "
        ++ "JOIN pg_roles r ON r.oid=c.cfgowner WHERE r.oid=10",
        "simple|pg_catalog|default");
}

fn foreignWrapperDiscovery() !void {
    const options = "array_to_string(ARRAY(SELECT quote_ident(option_name) || ' ' || quote_literal(option_value) "
        ++ "FROM pg_options_to_table(fdwoptions) ORDER BY option_name), E',\\n    ')";
    const discovery = "SELECT tableoid,oid,fdwname,fdwowner,fdwhandler::pg_catalog.regproc,fdwvalidator::pg_catalog.regproc,"
        ++ "fdwacl,acldefault('F',fdwowner)," ++ options ++ " AS fdwoptions FROM pg_foreign_data_wrapper";
    try expect(discovery, "");
    try run("CREATE FOREIGN DATA WRAPPER catalog_wrapper");
    try expect("SELECT tableoid,fdwname,fdwhandler::pg_catalog.regproc,fdwacl IS NULL,acldefault('F',fdwowner)::text,"
        ++ options ++ " FROM pg_foreign_data_wrapper", "2328|catalog_wrapper|-|t|{ramsql=U/ramsql}|");
    try run("DROP FOREIGN DATA WRAPPER catalog_wrapper");
    try expect("SELECT * FROM pg_catalog.pg_options_to_table(ARRAY['z=a=b','a=','flag']) WITH ORDINALITY",
        "z|a=b|1;a||2;flag|NULL|3");
    try expect("SELECT COUNT(*) FROM pg_options_to_table(NULL)", "0");
    try expect("SELECT COUNT(*) FROM pg_options_to_table('{}'::text[])", "0");
    try rejects("SELECT * FROM pg_options_to_table(ARRAY[NULL]::text[])", error.NullValueNotAllowed);
    try expect("SELECT id," ++ options
        ++ " FROM (VALUES (1, ARRAY['mixed Case=don''t','_safe=path']), (2, ARRAY['select=x'])) AS f(id,fdwoptions) ORDER BY id",
        "1|_safe 'path',\n    \"mixed Case\" 'don''t';2|\"select\" 'x'");
    try expect("SELECT quote_ident('A\"B'),quote_literal(E'a\\\\b'),quote_literal(42),quote_ident(NULL)",
        "\"A\"\"B\"|E'a\\\\b'|'42'|NULL");
}

fn defaultAclDiscovery() !void {
    const baseline = "CASE WHEN defaclnamespace=0 THEN acldefault("
        ++ "CASE WHEN defaclobjtype='S' THEN 's'::\"char\" ELSE defaclobjtype END,defaclrole) ELSE '{}' END";
    try expect("SELECT oid,tableoid,defaclrole,defaclnamespace,defaclobjtype,defaclacl,"
        ++ baseline ++ " AS acldefault FROM pg_catalog.pg_default_acl", "");
    try expect("SELECT 'pg_catalog.pg_default_acl'::regclass::oid", "826");
    try expect("SELECT (" ++ baseline ++ ")::text FROM (VALUES "
        ++ "(0::oid,'S'::\"char\",10::oid),(0::oid,'L'::\"char\",10::oid),(11::oid,'f'::\"char\",10::oid)) "
        ++ "AS entries(defaclnamespace,defaclobjtype,defaclrole)", "{ramsql=rwU/ramsql};{ramsql=rw/ramsql};{}");
    try expect("SELECT acldefault('d',10)::text,acldefault('p',10)::text,acldefault('c',10)::text,"
        ++ "acldefault(NULL,10) IS NULL,acldefault('n',NULL) IS NULL",
        "{=Tc/ramsql,ramsql=CTc/ramsql}|{ramsql=sA/ramsql}|{}|t|t");
}

fn conversionDiscovery() !void {
    try expect("SELECT tableoid,oid,conname,connamespace,conowner FROM pg_conversion", "");
    try expect("SELECT 'pg_catalog.pg_conversion'::regclass::oid, count(*) FROM pg_catalog.pg_conversion", "2607|0");
}

fn rangeDiscovery() !void {
    try expect("SELECT 'pg_catalog.pg_range'::regclass::oid", "3541");
    try expect("SELECT r.tableoid,r.rngtypid,r.rngsubtype,r.rngmultitypid,c.opcname,r.rngcanonical,r.rngsubdiff "
        ++ "FROM pg_range r JOIN pg_opclass c ON c.oid=r.rngsubopc ORDER BY r.rngtypid",
        "3541|3904|23|4451|int4_ops|int4range_canonical|-;3541|3906|1700|4532|numeric_ops|-|-;"
        ++ "3541|3908|1114|4533|timestamp_ops|-|-;3541|3910|1184|4534|timestamptz_ops|-|-;"
        ++ "3541|3912|1082|4535|date_ops|daterange_canonical|-;3541|3926|20|4536|int8_ops|int8range_canonical|-");
    try expect("SELECT c.castsource,c.casttarget FROM (VALUES (3904::oid,4451::oid),(3904::oid,4532::oid)) "
        ++ "AS c(castsource,casttarget) WHERE NOT EXISTS (SELECT 1 FROM pg_range r "
        ++ "WHERE c.castsource=r.rngtypid AND c.casttarget=r.rngmultitypid)", "3904|4532");
}

fn eventTriggerDiscovery() !void {
    const tags = "array_to_string(ARRAY(SELECT quote_literal(x) FROM unnest(evttags) AS t(x)), ', ')";
    try expect("SELECT e.tableoid,e.oid,evtname,evtenabled,evtevent,evtowner,"
        ++ tags ++ " AS evttags,e.evtfoid::regproc AS evtfname FROM pg_event_trigger e ORDER BY e.oid", "");
    try expect("SELECT 'pg_catalog.pg_event_trigger'::regclass::oid", "3466");
    try expect("SELECT id," ++ tags ++ " FROM (VALUES (1,ARRAY['DROP TABLE','CREATE TABLE']),"
        ++ "(2,ARRAY['b''c',NULL]),(3,NULL::text[])) AS e(id,evttags) ORDER BY id",
        "1|'DROP TABLE', 'CREATE TABLE';2|'b''c';3|");
    try expect("SELECT * FROM pg_catalog.unnest('[0:1][4:5]={{1,NULL},{3,4}}'::int[]) WITH ORDINALITY",
        "1|1;NULL|2;3|3;4|4");
    try expect("SELECT COUNT(*) FROM unnest(ARRAY[]::int[])", "0");
    try rejects("SELECT * FROM unnest(123)", error.UndefinedFunction);
}

fn columnDiscovery() !void {
    try run("CREATE TABLE attr_parent (id integer NOT NULL, amount numeric(10,2), CONSTRAINT parent_check CHECK (id > 0))");
    try run("CREATE TABLE attr_child (label text DEFAULT 'x') INHERITS (attr_parent)");
    try expect("SELECT a.attname,a.attstattarget,a.attstorage,t.typstorage,a.attislocal,a.atthasmissing,"
        ++ "pg_typeof(a.attmissingval)::text,a.attmissingval IS NULL,a.attoptions IS NULL,a.attfdwoptions IS NULL "
        ++ "FROM pg_attribute a JOIN pg_type t ON a.atttypid=t.oid "
        ++ "WHERE a.attrelid='attr_child'::regclass ORDER BY a.attnum",
        "id|-1|p|p|f|f|anyarray|t|t|t;amount|-1|m|m|f|f|anyarray|t|t|t;label|-1|x|x|t|f|anyarray|t|t|t");
    try expect("SELECT attname,CASE WHEN atthasmissing AND NOT attisdropped THEN attmissingval ELSE NULL END IS NULL "
        ++ "FROM pg_attribute WHERE attrelid='attr_child'::regclass ORDER BY attnum", "id|t;amount|t;label|t");
    try expect("SELECT conname,conislocal,convalidated FROM pg_constraint WHERE conrelid='attr_child'::regclass AND contype='c'",
        "parent_check|f|t");
    try run("DROP TABLE attr_child");
    try run("DROP TABLE attr_parent");
}

fn indexDumpDiscovery() !void {
    try run("CREATE TABLE dump_index (id integer PRIMARY KEY, lookup integer, detail text)");
    try run("CREATE UNIQUE INDEX dump_index_lookup ON dump_index (lookup) INCLUDE (detail) NULLS NOT DISTINCT");
    try expect("SELECT c.relname,i.indkey,i.indisvalid,i.indisready,i.indnkeyatts,i.indnatts,i.indnullsnotdistinct,"
        ++ "i.indexprs IS NULL FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid "
        ++ "WHERE i.indrelid='dump_index'::regclass ORDER BY i.indisprimary DESC",
        "dump_index_pkey|1|t|t|1|1|f|t;dump_index_lookup|2 3|t|t|1|2|t|t");
    try run("DROP TABLE dump_index");
}

fn lifecycle() !void {
    try run("CREATE TABLE a (id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, amount NUMERIC(10,2), at TIMESTAMPTZ(3), doc JSONB, label TEXT DEFAULT 'd', n INTEGER DEFAULT 2 + 3)");
    try expect(public_tables, "a");
    try expect(public_classes, "a|r;a_id_seq|S;a_pkey|i");
    try expect("SELECT c.relname, c.relnatts FROM pg_class c WHERE c.oid = 'a'::regclass", "a|6");
    try expect("SELECT 'a'::regclass::text, 'a_pkey'::regclass::text, 'public.a_id_seq'::regclass::text, to_regclass('nope') IS NULL", "a|a_pkey|a_id_seq|t");
    try rejects("SELECT 'nope'::regclass", error.TableNotFound);
    try expect("SELECT i.indisprimary, i.indkey, c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = 'a'::regclass", "t|1|a_pkey");
    try expect("SELECT attname, atttypid, atttypmod, attnotnull, attidentity, atthasdef FROM pg_attribute WHERE attrelid = 'a'::regclass AND attnum > 0 ORDER BY attnum",
        "id|23|-1|t|a|f;amount|1700|655366|f||f;at|1184|3|f||f;doc|3802|-1|f||f;label|25|-1|f||t;n|23|-1|f||t");
    try expect("SELECT column_name, data_type, numeric_precision, numeric_scale, datetime_precision, is_nullable FROM information_schema.columns WHERE table_name = 'a' ORDER BY ordinal_position",
        "id|integer|32|0|NULL|NO;amount|numeric|10|2|NULL|YES;at|timestamp with time zone|NULL|NULL|3|YES;doc|jsonb|NULL|NULL|NULL|YES;label|text|NULL|NULL|NULL|YES;n|integer|32|0|NULL|YES");
    try expect("SELECT column_name, column_default, is_identity, identity_generation FROM information_schema.columns WHERE table_name = 'a' ORDER BY ordinal_position",
        "id|NULL|YES|ALWAYS;amount|NULL|NO|NULL;at|NULL|NO|NULL;doc|NULL|NO|NULL;label|'d'::text|NO|NULL;n|(2 + 3)|NO|NULL");
    try expect("SELECT adnum, pg_get_expr(adbin, adrelid) FROM pg_attrdef WHERE adrelid = 'a'::regclass ORDER BY adnum", "5|'d'::text;6|(2 + 3)");
    try expect("SELECT seqtypid, seqstart, seqincrement, seqmax, seqcycle FROM pg_sequence WHERE seqrelid = 'a_id_seq'::regclass", "23|1|1|2147483647|f");
    try expect("SELECT tc.constraint_name, tc.constraint_type, k.column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage k ON k.constraint_name = tc.constraint_name WHERE tc.table_name = 'a'", "a_pkey|PRIMARY KEY|id");
    // A second table (capacity 2), drop, recreate: no catalog exhaustion.
    try run("CREATE TABLE b (k TEXT)");
    try expect(public_tables, "a;b");
    try run("DROP TABLE a");
    try expect(public_classes, "b|r");
    try run("CREATE TABLE a (id INTEGER GENERATED BY DEFAULT AS IDENTITY, v INTEGER)");
    try expect(public_classes, "a|r;a_id_seq|S;b|r");
    try expect("SELECT identity_generation FROM information_schema.columns WHERE table_name = 'a' AND column_name = 'id'", "BY DEFAULT");
    for (0..6) |_| {
        try run("DROP TABLE a");
        try run("CREATE TABLE a (id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v INTEGER)");
    }
    try expect(public_classes, "a|r;a_id_seq|S;a_pkey|i;b|r");
    // Uncommitted DDL is visible only to its own transaction.
    const owner = try db.begin();
    var result: DB.Result = .{};
    try db.statement(owner, "DROP TABLE b", &result, .{});
    try db.statement(owner, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public'", &result, .{});
    try check(result.rows[0].cells[0].integer == 1);
    const other = try db.begin();
    try db.statement(other, "SELECT COUNT(*) FROM pg_class WHERE relname = 'b'", &result, .{});
    try check(result.rows[0].cells[0].integer == 1);
    db.abort(other);
    db.abort(owner);
    try expect(public_tables, "a;b");
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0);
}

var primary: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [8192]u8 = undefined;

fn replicated(source: []const u8) !void {
    var result: DB.Result = .{};
    var used: usize = 0;
    try primary.executeChanges(source, &result, &record, &used, null, null);
    if (used != 0) try replica.applyChangeRecord(record[0..used], &scratch);
}

/// Replay reproduces catalog metadata including OIDs (index and sequence
/// OIDs follow the table's).
fn replay() !void {
    try replicated("CREATE TABLE x (id INTEGER PRIMARY KEY, v TEXT DEFAULT 'v')");
    try replicated("CREATE TABLE y (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY)");
    try replicated("DROP TABLE x");
    try replicated("CREATE TABLE x (k INTEGER)");
    const query = "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid";
    var a: DB.Result = .{};
    var b: DB.Result = .{};
    try primary.execute(query, &a);
    try replica.execute(query, &b);
    const left = try render(&a);
    var copy: [512]u8 = undefined;
    @memcpy(copy[0..left.len], left);
    const right = try render(&b);
    if (!std.mem.eql(u8, copy[0..left.len], right)) std.debug.print("primary {s}\nreplica {s}\n", .{ copy[0..left.len], right });
    try check(std.mem.eql(u8, copy[0..left.len], right));
    try check(a.row_count == 4);
    try expectOn(&replica, "SELECT column_default FROM information_schema.columns WHERE table_name = 'x'", "NULL");
    try replicated("DROP TABLE x");
    try replicated("CREATE TABLE am_refs (handler regproc, handlers regproc[])");
    try replicated("INSERT INTO am_refs VALUES ('bthandler'::regproc, ARRAY['heap_tableam_handler'::regproc, 330::regproc])");
    try expectOn(&replica, "SELECT handler::oid, handlers[1]::oid, handlers[2]::text FROM am_refs", "330|3|bthandler");
}

/// Native PostgreSQL 16 reports data_type as character_data (OID 1043).
fn characterMetadata() !void {
    db = .{};
    try run("CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))");
    var result: DB.Result = .{};
    try db.execute(
        "SELECT column_name,data_type,character_maximum_length FROM information_schema.columns WHERE table_name='t' ORDER BY ordinal_position",
        &result,
    );
    try check(result.column_count == 3);
    try check(sql.typeOid(result.column_types[1]) == 1043 and result.column_typmods[1] == -1);
    try check(std.mem.eql(u8, try render(&result), "id|integer|NULL;v|character varying|3"));
}

fn relationMetadata() !void {
    db = .{};
    try run("CREATE TABLE t(id INT PRIMARY KEY, amount INT CHECK (amount >= 0))");
    try run("CREATE INDEX t_amount ON t (amount)");
    try run("CREATE VIEW v AS SELECT id FROM t");
    try expect("SELECT 't'::pg_catalog.regclass::pg_catalog.text", "t");
    try expect("SELECT oid, amname, amhandler, amtype FROM pg_catalog.pg_am ORDER BY oid", "2|heap|heap_tableam_handler|t;403|btree|bthandler|i");
    try expect("SELECT amhandler::oid,pg_typeof(amhandler)::text FROM pg_catalog.pg_am ORDER BY oid", "3|regproc;330|regproc");
    try expect("SELECT to_regproc('pg_catalog.bthandler')::oid, '-'::regproc::text, (NULL::regproc)::oid, to_regproc('nonexistent')::oid",
        "330|-|NULL|NULL");
    try rejects("SELECT 'nonexistent'::regproc", error.UndefinedFunction);
    try expect("SELECT c.relname,c.relkind,c.relchecks,c.relhasindex,c.relhasrules,a.amname FROM pg_catalog.pg_class c LEFT JOIN pg_catalog.pg_am a ON c.relam=a.oid ORDER BY c.relname", "t|r|1|t|f|heap;t_amount|i|0|f|f|btree;t_pkey|i|0|f|f|btree;v|v|0|f|t|NULL");
    try expect("SELECT relname,relpersistence,relreplident,reltablespace,reloftype,reltoastrelid FROM pg_class ORDER BY relname", "t|p|d|0|0|0;t_amount|p|n|0|0|0;t_pkey|p|n|0|0|0;v|p|n|0|0|0");
    try expect("SELECT relhastriggers,relrowsecurity,relforcerowsecurity,relispartition,relispopulated FROM pg_class WHERE relname='t'", "f|f|f|f|t");
    const writer = try db.begin();
    var result: DB.Result = .{};
    try db.statement(writer, "ALTER TABLE t ENABLE ROW LEVEL SECURITY", &result, .{});
    try db.statement(writer, "ALTER TABLE t FORCE ROW LEVEL SECURITY", &result, .{});
    const security = "SELECT relrowsecurity,relforcerowsecurity FROM pg_class WHERE relname='t'";
    try db.statement(writer, security, &result, .{});
    try check(std.mem.eql(u8, try render(&result), "t|t"));
    try expect(security, "f|f");
    db.abort(writer);
    try expect(security, "f|f");
    try run("ALTER TABLE t ENABLE ROW LEVEL SECURITY");
    try expect(security, "t|f");
}

fn collationMetadata() !void {
    db = .{};
    try run("CREATE DOMAIN shown_int AS INT");
    try run("CREATE TABLE t(a TEXT,b VARCHAR(3),c NAME,d NAME[],e TEXT[],f INT)");
    try expect("SELECT oid,collname,collnamespace,collprovider,collisdeterministic,collencoding FROM pg_catalog.pg_collation ORDER BY oid", "100|default|11|d|t|-1;950|C|11|c|t|-1;951|POSIX|11|c|t|-1;962|ucs_basic|11|b|t|6");
    try expect("SELECT typname,typcollation FROM pg_type WHERE typname IN ('name','_name','text','_text','int4','_int4','shown_int','_shown_int') ORDER BY typname", "_int4|0;_name|950;_shown_int|0;_text|100;int4|0;name|950;shown_int|0;text|100");
    try expect("SELECT attname,attcollation FROM pg_attribute WHERE attrelid='t'::regclass AND attnum>0 ORDER BY attnum", "a|100;b|100;c|950;d|950;e|100;f|0");
    try expect("SELECT a.attname,(SELECT c.collname FROM pg_catalog.pg_collation c,pg_catalog.pg_type t WHERE c.oid=a.attcollation AND t.oid=a.atttypid AND a.attcollation<>t.typcollation) FROM pg_catalog.pg_attribute a WHERE a.attrelid='t'::regclass AND a.attnum>0 ORDER BY a.attnum", "a|NULL;b|NULL;c|NULL;d|NULL;e|NULL;f|NULL");
}

pub fn main(init: std.process.Init) !void {
    try types();
    try dumpDiscovery();
    try typeDiscovery();
    try indexOperatorDiscovery();
    try textParserDiscovery();
    try textTemplateDiscovery();
    try textDictionaryDiscovery();
    try textConfigurationDiscovery();
    try foreignWrapperDiscovery();
    try defaultAclDiscovery();
    try conversionDiscovery();
    try rangeDiscovery();
    try eventTriggerDiscovery();
    try columnDiscovery();
    try indexDumpDiscovery();
    try lifecycle();
    try replay();
    try characterMetadata();
    try relationMetadata();
    try collationMetadata();
    var buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-catalog\",\"pass\":true,\"assertions\":{d},\"database_bytes\":{d}}}\n", .{ assertions, DB.storageBytes() });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
