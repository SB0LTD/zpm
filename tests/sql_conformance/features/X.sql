-- # X series: SQL/XML. PostgreSQL implements these with libxml2.

-- probe X010.xml_type
SELECT '<a>1</a>'::xml, pg_typeof('<a/>'::xml), XMLPARSE(CONTENT 'x<b/>y');
SELECT '<a>'::xml;
CREATE TABLE t(x XML);
INSERT INTO t VALUES ('<r v="1"/>');
SELECT x::text FROM t;

-- probe X011.xml_arrays
SELECT ARRAY['<a/>'::xml, '<b/>'::xml], pg_typeof(ARRAY['<a/>'::xml]);
CREATE TABLE t(xs XML[]);
INSERT INTO t VALUES (ARRAY['<a/>'::xml]);
SELECT xs[1] FROM t;

-- probe X014.xml_attributes
CREATE TYPE doc AS (id INT, body XML);
SELECT (ROW(1, '<p/>')::doc).body;
CREATE TABLE t(d doc);
INSERT INTO t VALUES (ROW(2, '<q/>'));
SELECT (d).body FROM t;

-- probe X016.persistent_xml
CREATE TABLE t(id INT, x XML);
INSERT INTO t VALUES (1, XMLPARSE(DOCUMENT '<root><a>1</a></root>'));
SELECT id, x FROM t;
SELECT xpath('/root/a/text()', x) FROM t;

-- probe X020.xmlconcat
SELECT XMLCONCAT('<a/>', '<b>x</b>'), XMLCONCAT(NULL, '<c/>'), XMLCONCAT(NULL, NULL);

-- probe X031.xmlelement
SELECT XMLELEMENT(NAME foo), XMLELEMENT(NAME foo, XMLATTRIBUTES(1 AS bar, 'x' AS "Baz"), 'content', XMLELEMENT(NAME child)), XMLELEMENT(NAME e, 'a<b');

-- probe X032.xmlforest
SELECT XMLFOREST(1 AS a, 'x' AS b, NULL AS c);
CREATE TABLE t(id INT, name TEXT);
INSERT INTO t VALUES (1, 'n');
SELECT XMLFOREST(id, name) FROM t;

-- probe X034.xmlagg
CREATE TABLE t(v TEXT);
INSERT INTO t VALUES ('a'), ('b');
SELECT XMLAGG(XMLELEMENT(NAME v, v) ORDER BY v) FROM t;
SELECT XMLAGG(XMLELEMENT(NAME v, v)) FROM t WHERE false;

-- probe X035.xmlagg_order
CREATE TABLE t(v INT);
INSERT INTO t VALUES (2), (1), (3);
SELECT XMLAGG(XMLELEMENT(NAME n, v) ORDER BY v DESC) FROM t;

-- probe X036.xmlcomment
SELECT XMLCOMMENT('hello'), XMLCOMMENT(NULL);
SELECT XMLCOMMENT('bad--comment');

-- probe X037.xmlpi
SELECT XMLPI(NAME php, 'echo 1;'), XMLPI(NAME foo);
SELECT XMLPI(NAME xml, 'x');

-- probe X038.xmltext
SELECT XMLTEXT('a < b & c'), XMLTEXT(NULL);

-- probe X040.table_mapping
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (1, 'x');
SELECT table_to_xml('t', false, false, '');
SELECT query_to_xml('SELECT a FROM t', false, false, '');

-- probe X041.table_mapping_null_absent
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (1, NULL);
SELECT table_to_xml('t', false, false, '');

-- probe X042.table_mapping_null_nil
CREATE TABLE t(a INT, b TEXT);
INSERT INTO t VALUES (1, NULL);
SELECT table_to_xml('t', true, false, '');

-- probe X043.table_mapping_forest
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1), (2);
SELECT table_to_xml('t', false, true, '');

-- probe X044.table_mapping_element
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1);
SELECT table_to_xml('t', false, false, '');

-- probe X045.table_mapping_namespace
CREATE TABLE t(a INT);
INSERT INTO t VALUES (1);
SELECT table_to_xml('t', false, false, 'urn:example');

-- probe X046.table_mapping_data
CREATE TABLE t(d DATE, n NUMERIC(4,1), b BOOLEAN);
INSERT INTO t VALUES ('2024-01-02', 1.5, true);
SELECT table_to_xml('t', false, false, '');

-- probe X047.table_mapping_metadata
CREATE TABLE t(a INT);
SELECT table_to_xmlschema('t', false, false, '');

-- probe X048.table_mapping_base64
CREATE TABLE t(b BYTEA);
INSERT INTO t VALUES ('\x0102ff');
SET xmlbinary = base64;
SELECT table_to_xml('t', false, false, '');

-- probe X049.table_mapping_hex
CREATE TABLE t(b BYTEA);
INSERT INTO t VALUES ('\x0102ff');
SET xmlbinary = hex;
SELECT table_to_xml('t', false, false, '');

-- probe X050.advanced_mapping
CREATE SCHEMA s;
CREATE TABLE s.t(a INT);
INSERT INTO s.t VALUES (1);
SELECT schema_to_xml('s', false, false, '');

-- probe X051.advanced_null_absent
CREATE SCHEMA s;
CREATE TABLE s.t(a INT, b TEXT);
INSERT INTO s.t VALUES (1, NULL);
SELECT schema_to_xml('s', false, false, '');

-- probe X052.advanced_null_nil
CREATE SCHEMA s;
CREATE TABLE s.t(a INT, b TEXT);
INSERT INTO s.t VALUES (1, NULL);
SELECT schema_to_xml('s', true, false, '');

-- probe X053.advanced_forest
CREATE SCHEMA s;
CREATE TABLE s.t(a INT);
INSERT INTO s.t VALUES (1);
SELECT schema_to_xml('s', false, true, '');

-- probe X054.advanced_element
CREATE SCHEMA s;
CREATE TABLE s.t(a INT);
INSERT INTO s.t VALUES (1);
SELECT schema_to_xml('s', false, false, '');

-- probe X055.advanced_namespace
CREATE SCHEMA s;
CREATE TABLE s.t(a INT);
SELECT schema_to_xml('s', false, false, 'urn:x');

-- probe X056.advanced_data
CREATE SCHEMA s;
CREATE TABLE s.t(ts TIMESTAMP, f REAL);
INSERT INTO s.t VALUES ('2024-01-02 03:04:05', 1.5);
SELECT schema_to_xml('s', false, false, '');

-- probe X057.advanced_metadata
CREATE SCHEMA s;
CREATE TABLE s.t(a INT);
SELECT schema_to_xmlschema('s', false, false, '');

-- probe X058.advanced_base64
CREATE SCHEMA s;
CREATE TABLE s.t(b BYTEA);
INSERT INTO s.t VALUES ('\xdead');
SET xmlbinary = base64;
SELECT schema_to_xml('s', false, false, '');

-- probe X059.advanced_hex
CREATE SCHEMA s;
CREATE TABLE s.t(b BYTEA);
INSERT INTO s.t VALUES ('\xdead');
SET xmlbinary = hex;
SELECT schema_to_xml('s', false, false, '');

-- probe X060.xmlparse_content
SELECT XMLPARSE(CONTENT 'text<a/>more'), XMLPARSE(CONTENT ''), XMLPARSE(CONTENT '<a/><b/>');
SELECT XMLPARSE(CONTENT '<a>');

-- probe X061.xmlparse_document
SELECT XMLPARSE(DOCUMENT '<?xml version="1.0"?><r/>'), XMLPARSE(DOCUMENT '<r><c/></r>');
SELECT XMLPARSE(DOCUMENT '<a/><b/>');

-- probe X069.xmlserialize_indent
SELECT XMLSERIALIZE(DOCUMENT '<a><b>1</b></a>' AS TEXT INDENT), XMLSERIALIZE(CONTENT '<a><b/></a>' AS TEXT NO INDENT);

-- probe X070.xmlserialize_content
SELECT XMLSERIALIZE(CONTENT 'x<a/>' AS TEXT), XMLSERIALIZE(CONTENT '<a>1</a>' AS VARCHAR(20)), pg_typeof(XMLSERIALIZE(CONTENT '<a/>' AS TEXT));

-- probe X071.xmlserialize_document
SELECT XMLSERIALIZE(DOCUMENT '<r/>' AS TEXT);
SELECT XMLSERIALIZE(DOCUMENT 'x<a/>' AS TEXT);

-- probe X072.xmlserialize
SELECT XMLSERIALIZE(CONTENT XMLELEMENT(NAME e, 1) AS CHARACTER VARYING(30));

-- probe X090.document_predicate
SELECT '<a/>'::xml IS DOCUMENT, 'x<a/>'::xml IS DOCUMENT, '<a/>'::xml IS NOT DOCUMENT, NULL::xml IS DOCUMENT;

-- probe X120.xml_params_sql_routines
CREATE FUNCTION wrap(x XML) RETURNS XML LANGUAGE SQL AS $$SELECT XMLELEMENT(NAME w, x)$$;
SELECT wrap('<i/>');

-- probe X121.xml_params_external
CREATE FUNCTION root_name(x XML) RETURNS TEXT LANGUAGE plpgsql AS $$BEGIN RETURN (xpath('name(/*)', x))[1]::text; END$$;
SELECT root_name('<abc/>');

-- probe X221.passing_by_value
SELECT * FROM XMLTABLE('/r/i' PASSING BY VALUE '<r><i>1</i><i>2</i></r>' COLUMNS v INT PATH '.');
SELECT XMLEXISTS('/r' PASSING BY VALUE '<r/>');

-- probe X301.xmltable_columns
SELECT * FROM XMLTABLE('/rows/row' PASSING '<rows><row a="1"><b>x</b></row><row a="2"><b>y</b></row></rows>' COLUMNS a INT PATH '@a', b TEXT PATH 'b');

-- probe X302.xmltable_ordinality
SELECT * FROM XMLTABLE('/r/i' PASSING '<r><i>p</i><i>q</i></r>' COLUMNS n FOR ORDINALITY, v TEXT PATH '.');

-- probe X303.xmltable_default
SELECT * FROM XMLTABLE('/r/i' PASSING '<r><i v="1"/><i/></r>' COLUMNS v INT PATH '@v' DEFAULT 0);

-- probe X304.xmltable_context
SELECT * FROM XMLTABLE('i' PASSING '<i>9</i>' COLUMNS v INT PATH '.');
SELECT * FROM XMLTABLE('/i' PASSING '<i>8</i>' COLUMNS v INT PATH '.');

-- probe X400.name_mapping
CREATE TABLE "a b"("c:d" INT, "_x" INT);
INSERT INTO "a b" VALUES (1, 2);
SELECT table_to_xml('"a b"', false, false, '');
SELECT XMLELEMENT(NAME "x y", 1);

-- probe X410.alter_xml_type
CREATE TABLE t(x TEXT);
INSERT INTO t VALUES ('<a/>');
ALTER TABLE t ALTER COLUMN x TYPE XML USING x::xml;
SELECT x, pg_typeof(x) FROM t;
ALTER TABLE t ALTER COLUMN x TYPE TEXT;
SELECT x FROM t;
