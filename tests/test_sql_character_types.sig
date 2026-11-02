const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=3,.columns=8,.rows_per_table=32,.work_rows=128,.result_rows=64,.expr_nodes=1024,.text_bytes=256,.nulls_first_ascending=false});
var db:DB=.{};var result:DB.Result=.{};
const Column=struct{name:[]const u8,oid:u32,typmod:i32};
const Event=struct{source:[]const u8,state:[]const u8,command:sql.CommandTag=.none,affected:usize=0,columns:[]const Column=&.{},rows:[]const []const ?[]const u8=&.{}};
const Case=struct{id:[]const u8,setup:[]const []const u8,events:[]const Event};
fn same(a:[]const u8,b:[]const u8) bool{return std.mem.eql(u8,a,b);}
fn stateOf(err:anyerror) []const u8{return switch(err){error.Syntax=>"42601",error.InvalidParameterValue=>"22023",error.StringDataRightTruncation=>"22001",error.InvalidTextRepresentation=>"22P02",error.DivisionByZero=>"22012",error.TypeMismatch=>"42804",error.UndefinedFunction=>"42883",error.ColumnNotFound=>"42703",error.NotNullViolation=>"23502",error.PrimaryKeyViolation=>"23505",else=>@errorName(err)};}
fn verify(e:*const Event) !bool{
 if(!same(e.state,"00000") or result.command!=e.command or result.column_count!=e.columns.len or result.row_count!=e.rows.len) return false;
 if(e.command!=.select and result.affected_rows!=e.affected) return false;
 for(e.columns,0..) |c,i| if(sql.typeOid(result.column_types[i])!=c.oid or result.column_typmods[i]!=c.typmod or !same(result.column_names[i].slice(),c.name)) return false;
 var buffer:[DB.Io.format_bytes]u8=undefined;
 for(e.rows,0..) |row,i| for(row,0..) |wanted,j| {
  const cell=&result.rows[i].cells[j];
  if(wanted) |text| {if(cell.*==.null_value or !same(text,try DB.Io.format(cell,false,&db.session,&buffer))) return false;}
  else if(cell.*!=.null_value) return false;
 };
 return true;
}
const cases=[_]Case{
.{.id="varchar_unbounded",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR)",.state="00000",.command=.create_table,.affected=0,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t VALUES(1,''),(2,'abc '),(3,'\xc3\xa9\xf0\x9f\x99\x82'),(4,NULL)",.state="00000",.command=.insert,.affected=4,.columns=&.{},.rows=&.{}},
.{.source="SELECT id,v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=-1}},.rows=&.{&.{"1",""},&.{"2","abc "},&.{"3","\xc3\xa9\xf0\x9f\x99\x82"},&.{"4",null}}},
}},
.{.id="varchar_varying_alias",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(v CHARACTER VARYING(3))",.state="00000",.command=.create_table,.affected=0,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t VALUES('abc ')",.state="00000",.command=.insert,.affected=1,.columns=&.{},.rows=&.{}},
.{.source="SELECT v FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"abc"}}},
}},
.{.id="varchar_casts",.setup=&.{},.events=&.{
.{.source="SELECT 'abcdef'::varchar(3),CAST('\xc3\xa9\xf0\x9f\x99\x82x' AS CHARACTER VARYING(2)),NULL::varchar(3)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="varchar",.oid=1043,.typmod=7},.{.name="varchar",.oid=1043,.typmod=6},.{.name="varchar",.oid=1043,.typmod=7}},.rows=&.{&.{"abc","\xc3\xa9\xf0\x9f\x99\x82",null}}},
.{.source="SELECT 12345::varchar(2),true::varchar(3)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="varchar",.oid=1043,.typmod=6},.{.name="varchar",.oid=1043,.typmod=7}},.rows=&.{&.{"12","tru"}}},
.{.source="SELECT 'ab  '::varchar(2),'abc '::varchar",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="varchar",.oid=1043,.typmod=6},.{.name="varchar",.oid=1043,.typmod=-1}},.rows=&.{&.{"ab","abc "}}},
}},
.{.id="varchar_assignment_spaces",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="INSERT INTO t VALUES(1,'abc '),(2,'ab '),(3,'')",.state="00000",.command=.insert,.affected=3,.columns=&.{},.rows=&.{}},
.{.source="SELECT id,v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"1","abc"},&.{"2","ab "},&.{"3",""}}},
}},
.{.id="varchar_assignment_error",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="INSERT INTO t VALUES(1,'abc')",.state="00000",.command=.insert,.affected=1,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t VALUES(2,'xy'),(3,'abcd')",.state="22001"},
.{.source="SELECT id,v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"1","abc"}}},
}},
.{.id="varchar_assignment_unicode",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="INSERT INTO t VALUES(1,'\xc3\xa9\xf0\x9f\x99\x82x'),(2,'a\xcc\x81b'),(3,'\xf0\x9f\x99\x82\xf0\x9f\x99\x82\xf0\x9f\x99\x82')",.state="00000",.command=.insert,.affected=3,.columns=&.{},.rows=&.{}},
.{.source="SELECT id,v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"1","\xc3\xa9\xf0\x9f\x99\x82x"},&.{"2","a\xcc\x81b"},&.{"3","\xf0\x9f\x99\x82\xf0\x9f\x99\x82\xf0\x9f\x99\x82"}}},
.{.source="INSERT INTO t VALUES(4,'\xf0\x9f\x99\x82\xf0\x9f\x99\x82\xf0\x9f\x99\x82\xf0\x9f\x99\x82')",.state="22001"},
.{.source="SELECT COUNT(*) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="count",.oid=20,.typmod=-1}},.rows=&.{&.{"3"}}},
}},
.{.id="varchar_assignment_not_space",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="INSERT INTO t VALUES(1,'abc\x09')",.state="22001"},
.{.source="INSERT INTO t VALUES(2,'abc\xc2\xa0')",.state="22001"},
.{.source="SELECT COUNT(*) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="count",.oid=20,.typmod=-1}},.rows=&.{&.{"0"}}},
}},
.{.id="varchar_update_atomic",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="INSERT INTO t VALUES(1,'a'),(2,'abc')",.state="00000",.command=.insert,.affected=2,.columns=&.{},.rows=&.{}},
.{.source="UPDATE t SET v=v||'x'",.state="22001"},
.{.source="SELECT id,v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"1","a"},&.{"2","abc"}}},
.{.source="UPDATE t SET v='xy '",.state="00000",.command=.update,.affected=2,.columns=&.{},.rows=&.{}},
.{.source="SELECT id,v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"1","xy "},&.{"2","xy "}}},
}},
.{.id="varchar_explicit_then_assignment",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="INSERT INTO t VALUES(1,'abcd'::varchar(3))",.state="00000",.command=.insert,.affected=1,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t VALUES(2,'abcd'::varchar(4))",.state="22001"},
.{.source="SELECT id,v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"1","abc"}}},
}},
.{.id="varchar_numeric_assignment",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="INSERT INTO t VALUES(1,123)",.state="00000",.command=.insert,.affected=1,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t VALUES(2,1234)",.state="22001"},
.{.source="SELECT id,v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"1","123"}}},
}},
.{.id="varchar_defaults_generated",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3) DEFAULT 'abcd'::varchar(2),g VARCHAR(3) GENERATED ALWAYS AS(v||'x') STORED)",.state="00000",.command=.create_table,.affected=0,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t(id) VALUES(1)",.state="00000",.command=.insert,.affected=1,.columns=&.{},.rows=&.{}},
.{.source="SELECT id,v,g FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=7},.{.name="g",.oid=1043,.typmod=7}},.rows=&.{&.{"1","ab","abx"}}},
.{.source="UPDATE t SET v='abc' WHERE id=1",.state="22001"},
.{.source="SELECT id,v,g FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="id",.oid=23,.typmod=-1},.{.name="v",.oid=1043,.typmod=7},.{.name="g",.oid=1043,.typmod=7}},.rows=&.{&.{"1","ab","abx"}}},
}},
.{.id="varchar_default_overflow",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(v VARCHAR(3) DEFAULT 'abcd')",.state="00000",.command=.create_table,.affected=0,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t DEFAULT VALUES",.state="22001"},
.{.source="SELECT COUNT(*) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="count",.oid=20,.typmod=-1}},.rows=&.{&.{"0"}}},
}},
.{.id="varchar_relational",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="INSERT INTO t VALUES(1,'a'),(2,'a '),(3,'b')",.state="00000",.command=.insert,.affected=3,.columns=&.{},.rows=&.{}},
.{.source="SELECT v,COUNT(*) FROM t GROUP BY v ORDER BY v",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="v",.oid=1043,.typmod=7},.{.name="count",.oid=20,.typmod=-1}},.rows=&.{&.{"a","1"},&.{"a ","1"},&.{"b","1"}}},
.{.source="SELECT v FROM t UNION SELECT v FROM t ORDER BY v",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"a"},&.{"a "},&.{"b"}}},
.{.source="SELECT MIN(v),MAX(v) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="min",.oid=25,.typmod=-1},.{.name="max",.oid=25,.typmod=-1}},.rows=&.{&.{"a","b"}}},
.{.source="SELECT v,v='a',v LIKE 'a%' FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="v",.oid=1043,.typmod=7},.{.name="?column?",.oid=16,.typmod=-1},.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"a","t","t"},&.{"a ","f","t"},&.{"b","f","f"}}},
}},
.{.id="varchar_coalesce_case",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))","INSERT INTO t VALUES(1,'a'),(2,'b')"},.events=&.{
.{.source="SELECT COALESCE(NULL::varchar(3),'xy'::varchar(3)) AS a,CASE WHEN 1=1 THEN 'a'::varchar(3) ELSE 'b'::varchar(3) END AS b",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=1043,.typmod=7},.{.name="b",.oid=1043,.typmod=7}},.rows=&.{&.{"xy","a"}}},
.{.source="SELECT COALESCE(NULL::varchar(2),'xyz'::varchar(3)),GREATEST('x'::varchar(2),'y'::varchar(3))",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="coalesce",.oid=1043,.typmod=7},.{.name="greatest",.oid=1043,.typmod=-1}},.rows=&.{&.{"xyz","y"}}},
.{.source="SELECT CASE WHEN id=1 THEN v ELSE 'x'::varchar(3) END AS v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"a"},&.{"x"}}},
}},
.{.id="varchar_type_catalog",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="SELECT 'varchar'::regtype::text,'character varying'::regtype::text,format_type(1043,-1),format_type(1043,7)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="text",.oid=25,.typmod=-1},.{.name="text",.oid=25,.typmod=-1},.{.name="format_type",.oid=25,.typmod=-1},.{.name="format_type",.oid=25,.typmod=-1}},.rows=&.{&.{"character varying","character varying","character varying","character varying(3)"}}},
.{.source="SELECT attname,atttypid,atttypmod FROM pg_attribute WHERE attrelid='t'::regclass AND attnum>0 ORDER BY attnum",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="attname",.oid=19,.typmod=-1},.{.name="atttypid",.oid=26,.typmod=-1},.{.name="atttypmod",.oid=23,.typmod=-1}},.rows=&.{&.{"id","23","-1"},&.{"v","1043","7"}}},
.{.source="SELECT column_name,data_type,character_maximum_length FROM information_schema.columns WHERE table_name='t' ORDER BY ordinal_position",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="column_name",.oid=19,.typmod=-1},.{.name="data_type",.oid=1043,.typmod=-1},.{.name="character_maximum_length",.oid=23,.typmod=-1}},.rows=&.{&.{"id","integer",null},&.{"v","character varying","3"}}},
}},
.{.id="varchar_invalid_0",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(v VARCHAR(0))",.state="22023"},
}},
.{.id="varchar_invalid_minus1",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(v VARCHAR(-1))",.state="42601"},
}},
.{.id="varchar_invalid_10485761",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(v VARCHAR(10485761))",.state="22023"},
}},
.{.id="varchar_invalid_2_3",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(v VARCHAR(2,3))",.state="42601"},
}},
.{.id="varchar_invalid_1_5",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(v VARCHAR(1.5))",.state="42601"},
}},
.{.id="varchar_max_modifier",.setup=&.{},.events=&.{
.{.source="CREATE TABLE t(v VARCHAR(10485760))",.state="00000",.command=.create_table,.affected=0,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t VALUES('x')",.state="00000",.command=.insert,.affected=1,.columns=&.{},.rows=&.{}},
.{.source="SELECT v FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="v",.oid=1043,.typmod=10485764}},.rows=&.{&.{"x"}}},
}},
.{.id="varchar_null_empty",.setup=&.{},.events=&.{
.{.source="SELECT NULL::varchar(1),''::varchar(1),''::character varying",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="varchar",.oid=1043,.typmod=5},.{.name="varchar",.oid=1043,.typmod=5},.{.name="varchar",.oid=1043,.typmod=-1}},.rows=&.{&.{null,"",""}}},
.{.source="CREATE TABLE t(v VARCHAR(1))",.state="00000",.command=.create_table,.affected=0,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t VALUES(NULL),('')",.state="00000",.command=.insert,.affected=2,.columns=&.{},.rows=&.{}},
.{.source="SELECT v FROM t ORDER BY v",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="v",.oid=1043,.typmod=5}},.rows=&.{&.{""},&.{null}}},
}},
.{.id="varchar_text_conversion",.setup=&.{},.events=&.{
.{.source="SELECT '123'::varchar::int,('12'::varchar||'3') AS x,CAST('x ' AS varchar)='x'::text",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="int4",.oid=23,.typmod=-1},.{.name="x",.oid=25,.typmod=-1},.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"123","123","f"}}},
}},
.{.id="varchar_metadata_unreachable",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))","INSERT INTO t VALUES(1,'a'),(2,NULL)"},.events=&.{
.{.source="SELECT COALESCE(v,NULL::varchar(2)),COALESCE(v,'x'::varchar(3)),GREATEST(v,'x'::varchar(3)) FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="coalesce",.oid=1043,.typmod=7},.{.name="coalesce",.oid=1043,.typmod=7},.{.name="greatest",.oid=1043,.typmod=7}},.rows=&.{&.{"a","a","x"},&.{null,"x","x"}}},
.{.source="SELECT CASE WHEN id=1 THEN v END AS a,CASE WHEN id=1 THEN v ELSE 'x'::varchar(2) END AS b FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=1043,.typmod=-1},.{.name="b",.oid=1043,.typmod=-1}},.rows=&.{&.{"a","a"},&.{null,"x"}}},
.{.source="SELECT CASE WHEN TRUE THEN 'a'::varchar(2) ELSE 'b'::varchar(3) END,CASE WHEN FALSE THEN 'a'::varchar(2) ELSE 'b'::varchar(3) END",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="case",.oid=1043,.typmod=6},.{.name="case",.oid=1043,.typmod=7}},.rows=&.{&.{"a","b"}}},
}},
.{.id="varchar_string_overloads",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))"},.events=&.{
.{.source="SELECT to_regtype('integer'::varchar)::text,to_regclass('t'::varchar)::text,'integer'::varchar::regtype::text",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="to_regtype",.oid=25,.typmod=-1},.{.name="to_regclass",.oid=25,.typmod=-1},.{.name="text",.oid=25,.typmod=-1}},.rows=&.{&.{"integer","t","integer"}}},
.{.source="SELECT '{\x22a\x22:1}'::jsonb->'a'::varchar,'{\x22a\x22:1}'::jsonb ? 'a'::varchar",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=3802,.typmod=-1},.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"1","t"}}},
.{.source="SELECT TIMESTAMP '2026-01-02 03:04:05' AT TIME ZONE 'UTC'::varchar",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="timezone",.oid=1184,.typmod=-1}},.rows=&.{&.{"2026-01-02 03:04:05+00"}}},
}},
.{.id="varchar_independent_review_adversarial",.setup=&.{"CREATE TABLE t(id int,v varchar(3))","INSERT INTO t VALUES(1,'abc'),(2,NULL)","CREATE SEQUENCE seq"},.events=&.{
.{.source="SELECT NULLIF(v,'x') AS a,NULLIF(v,'x'::varchar) AS b,NULLIF(v,'x'::text) AS c FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=25,.typmod=-1},.{.name="b",.oid=25,.typmod=-1},.{.name="c",.oid=25,.typmod=-1}},.rows=&.{&.{"abc","abc","abc"},&.{null,null,null}}},
.{.source="SELECT COALESCE('a'::name,'b'::varchar) AS a,COALESCE('a'::varchar,'b'::name) AS b",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=19,.typmod=-1},.{.name="b",.oid=19,.typmod=-1}},.rows=&.{&.{"a","a"}}},
.{.source="SELECT CASE WHEN id=1 THEN 'a'::name ELSE v END AS a FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=19,.typmod=-1}},.rows=&.{&.{"a"},&.{null}}},
.{.source="SELECT GREATEST('a'::name,'b'::varchar) AS a",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=19,.typmod=-1}},.rows=&.{&.{"b"}}},
.{.source="SELECT nextval('seq'::varchar)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nextval",.oid=20,.typmod=-1}},.rows=&.{&.{"1"}}},
.{.source="SELECT currval('seq'::varchar)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="currval",.oid=20,.typmod=-1}},.rows=&.{&.{"1"}}},
.{.source="SELECT setval('seq'::varchar,7)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="setval",.oid=20,.typmod=-1}},.rows=&.{&.{"7"}}},
.{.source="SELECT nextval('seq')",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nextval",.oid=20,.typmod=-1}},.rows=&.{&.{"8"}}},
.{.source="SELECT v FROM t UNION ALL SELECT 'de'::varchar(3)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="v",.oid=1043,.typmod=7}},.rows=&.{&.{"abc"},&.{null},&.{"de"}}},
.{.source="SELECT 'ab'::varchar(3) UNION ALL SELECT 'cd'::varchar(4)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="varchar",.oid=1043,.typmod=-1}},.rows=&.{&.{"ab"},&.{"cd"}}},
.{.source="SELECT MIN(v),MAX(v) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="min",.oid=25,.typmod=-1},.{.name="max",.oid=25,.typmod=-1}},.rows=&.{&.{"abc","abc"}}},
.{.source="SELECT FIRST_VALUE(v) OVER(ORDER BY id),LAG(v) OVER(ORDER BY id) FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="first_value",.oid=1043,.typmod=-1},.{.name="lag",.oid=1043,.typmod=-1}},.rows=&.{&.{"abc",null},&.{"abc","abc"}}},
.{.source="SELECT COALESCE(NULL::varchar(2),v),GREATEST(v,NULL::varchar(3)) FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="coalesce",.oid=1043,.typmod=7},.{.name="greatest",.oid=1043,.typmod=7}},.rows=&.{&.{"abc","abc"},&.{null,null}}},
.{.source="SELECT CASE WHEN id=1 THEN v ELSE NULL::varchar(3) END FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="case",.oid=1043,.typmod=7}},.rows=&.{&.{"abc"},&.{null}}},
.{.source="SELECT v LIKE 'a%'::varchar ESCAPE '!'::varchar FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"t"},&.{null}}},
}},
.{.id="varchar_name_utf8_boundary",.setup=&.{},.events=&.{
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\xc3\xa9'::varchar::name::text",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="text",.oid=25,.typmod=-1}},.rows=&.{&.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}},
}},
.{.id="varchar_name_comparison",.setup=&.{},.events=&.{
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar AS eq1,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name AS eq2,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name<'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar AS lt",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="eq1",.oid=16,.typmod=-1},.{.name="eq2",.oid=16,.typmod=-1},.{.name="lt",.oid=16,.typmod=-1}},.rows=&.{&.{"f","f","t"}}},
.{.source="SELECT NULLIF('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar) AS n1,NULLIF('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name) AS n2",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="n1",.oid=19,.typmod=-1},.{.name="n2",.oid=25,.typmod=-1}},.rows=&.{&.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"}}},
}},
.{.id="varchar_name_in_between",.setup=&.{},.events=&.{
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name IN('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar) AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"f"}}},
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name IN('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac'::varchar) AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"t"}}},
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar IN('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name) AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"f"}}},
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar IN('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name,'z'::name) AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"f"}}},
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name NOT IN('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac'::varchar) AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"f"}}},
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name BETWEEN 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar AND 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac'::varchar AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"f"}}},
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar BETWEEN 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name AND 'z'::name AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"t"}}},
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name BETWEEN 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name AND 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"t"}}},
.{.source="SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name BETWEEN SYMMETRIC 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar AND 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac'::varchar AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"f"}}},
.{.source="SELECT ('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name) IN(('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar)) AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"f"}}},
.{.source="SELECT ('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::name) IN(('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar),('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac'::varchar,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac'::varchar)) AS value",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="value",.oid=16,.typmod=-1}},.rows=&.{&.{"f"}}},
}},
.{.id="varchar_name_in_variables",.setup=&.{"CREATE TABLE t(n NAME,v VARCHAR,z VARCHAR)","INSERT INTO t VALUES('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac')"},.events=&.{
.{.source="SELECT n IN(v,z),n IN(v,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac'::varchar),n IN(v||'',z||'') FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1},.{.name="?column?",.oid=16,.typmod=-1},.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"f","f","f"}}},
.{.source="SELECT n IN('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac'::varchar) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"t"}}},
.{.source="SELECT n IN(v,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab'::varchar,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac'::varchar) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"t"}}},
}},
.{.id="varchar_grouped_metadata",.setup=&.{"CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))","INSERT INTO t VALUES(1,'abc'),(2,NULL)"},.events=&.{
.{.source="SELECT (SELECT 'a'::varchar(3)) AS a",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=1043,.typmod=7}},.rows=&.{&.{"a"}}},
.{.source="SELECT COALESCE(v,'abc'::varchar(3)) AS a FROM t GROUP BY COALESCE(v,'abc'::varchar(3))",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=1043,.typmod=7}},.rows=&.{&.{"abc"}}},
.{.source="SELECT CASE WHEN id>0 THEN v ELSE NULL::varchar(3) END AS a FROM t GROUP BY CASE WHEN id>0 THEN v ELSE NULL::varchar(3) END ORDER BY a NULLS LAST",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=1043,.typmod=7}},.rows=&.{&.{"abc"},&.{null}}},
}},
.{.id="varchar_in_array_effects",.setup=&.{"CREATE TABLE t(v VARCHAR)","INSERT INTO t VALUES('x')","CREATE SEQUENCE seq"},.events=&.{
.{.source="SELECT 'x'::name IN('x'::varchar,nextval('seq')::varchar)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"t"}}},
.{.source="SELECT nextval('seq')",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nextval",.oid=20,.typmod=-1}},.rows=&.{&.{"2"}}},
.{.source="SELECT 'x'::name IN(v||nextval('seq')::text,'x'::varchar,nextval('seq')::varchar) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"t"}}},
.{.source="SELECT nextval('seq')",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nextval",.oid=20,.typmod=-1}},.rows=&.{&.{"4"}}},
}},
.{.id="varchar_string_common_order",.setup=&.{"CREATE TABLE t(id int)","INSERT INTO t VALUES(0),(1)"},.events=&.{
.{.source="SELECT COALESCE('a'::varchar(3),'b'::text) AS vt,COALESCE('a'::text,'b'::varchar(3)) AS tv",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="vt",.oid=1043,.typmod=7},.{.name="tv",.oid=25,.typmod=-1}},.rows=&.{&.{"a","a"}}},
.{.source="SELECT GREATEST('a'::varchar(3),'b'::text) AS vt,GREATEST('a'::text,'b'::varchar(3)) AS tv",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="vt",.oid=1043,.typmod=-1},.{.name="tv",.oid=25,.typmod=-1}},.rows=&.{&.{"b","b"}}},
.{.source="SELECT CASE WHEN id=1 THEN 'a'::varchar(3) ELSE 'b'::text END AS then_v_else_t,CASE WHEN id=1 THEN 'a'::text ELSE 'b'::varchar(3) END AS then_t_else_v FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="then_v_else_t",.oid=25,.typmod=-1},.{.name="then_t_else_v",.oid=1043,.typmod=-1}},.rows=&.{&.{"b","b"},&.{"a","a"}}},
.{.source="SELECT CASE WHEN id=1 THEN 'a'::name ELSE 'b'::text END AS then_n_else_t,CASE WHEN id=1 THEN 'a'::text ELSE 'b'::name END AS then_t_else_n FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="then_n_else_t",.oid=25,.typmod=-1},.{.name="then_t_else_n",.oid=19,.typmod=-1}},.rows=&.{&.{"b","b"},&.{"a","a"}}},
.{.source="SELECT COALESCE('a'::name,'b'::text) AS nt,COALESCE('a'::text,'b'::name) AS tn",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nt",.oid=19,.typmod=-1},.{.name="tn",.oid=25,.typmod=-1}},.rows=&.{&.{"a","a"}}},
.{.source="SELECT GREATEST('a'::name,'b'::text) AS nt,GREATEST('a'::text,'b'::name) AS tn",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nt",.oid=19,.typmod=-1},.{.name="tn",.oid=25,.typmod=-1}},.rows=&.{&.{"b","b"}}},
.{.source="SELECT CASE WHEN TRUE THEN 'a'::varchar(3) ELSE 'b'::text END AS then_v_else_t,CASE WHEN TRUE THEN 'a'::text ELSE 'b'::varchar(3) END AS then_t_else_v",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="then_v_else_t",.oid=25,.typmod=-1},.{.name="then_t_else_v",.oid=1043,.typmod=-1}},.rows=&.{&.{"a","a"}}},
.{.source="SELECT CASE WHEN id=1 THEN 'a'::varchar(3) WHEN id=0 THEN 'b'::varchar(4) ELSE 'c'::text END AS a,CASE WHEN id=1 THEN 'a'::text WHEN id=0 THEN 'b'::text ELSE 'c'::varchar(3) END AS b FROM t ORDER BY id",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="a",.oid=25,.typmod=-1},.{.name="b",.oid=1043,.typmod=-1}},.rows=&.{&.{"b","b"},&.{"a","a"}}},
}},
.{.id="varchar_independent_unknown_in_priority",.setup=&.{},.events=&.{
.{.source="SELECT 7 FROM(SELECT 'bad' IN(1,'x'::varchar) AS unused)q",.state="22P02"},
.{.source="SELECT 7 FROM(SELECT 'bad' IN('bad'::varchar,1) AS unused)q",.state="22P02"},
.{.source="SELECT 'bad' IN('bad'::varchar,1)",.state="22P02"},
.{.source="SELECT '1' IN(1,'x'::varchar)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"t"}}},
}},
.{.id="varchar_in_volatile_scalar",.setup=&.{"CREATE TABLE t(n NAME,v VARCHAR)","INSERT INTO t VALUES('0','2')","CREATE SEQUENCE seq"},.events=&.{
.{.source="SELECT nextval('seq')::varchar IN(n,v) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"t"}}},
.{.source="SELECT nextval('seq')",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nextval",.oid=20,.typmod=-1}},.rows=&.{&.{"3"}}},
.{.source="SELECT nextval('seq')::varchar IN('0'::name,'0'::varchar,v) FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{"f"}}},
.{.source="SELECT nextval('seq')",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nextval",.oid=20,.typmod=-1}},.rows=&.{&.{"6"}}},
}},
.{.id="varchar_in_null_array",.setup=&.{"CREATE SEQUENCE seq"},.events=&.{
.{.source="SELECT NULL::varchar IN('x'::name,nextval('seq')::varchar)",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="?column?",.oid=16,.typmod=-1}},.rows=&.{&.{null}}},
.{.source="SELECT nextval('seq')",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nextval",.oid=20,.typmod=-1}},.rows=&.{&.{"2"}}},
.{.source="SELECT 'x'::name IN('x'::varchar,(1/0)::varchar)",.state="22012"},
.{.source="SELECT nextval('seq')",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="nextval",.oid=20,.typmod=-1}},.rows=&.{&.{"3"}}},
}},
.{.id="varchar_typed_literals_identifiers",.setup=&.{},.events=&.{
.{.source="SELECT VARCHAR(2) 'abcd',CHARACTER VARYING(2) '\xc3\xa9\xf0\x9f\x99\x82x',VARCHAR 'abc'",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="varchar",.oid=1043,.typmod=6},.{.name="varchar",.oid=1043,.typmod=6},.{.name="varchar",.oid=1043,.typmod=-1}},.rows=&.{&.{"ab","\xc3\xa9\xf0\x9f\x99\x82","abc"}}},
.{.source="CREATE TABLE t(varchar INT,character INT,varying INT)",.state="00000",.command=.create_table,.affected=0,.columns=&.{},.rows=&.{}},
.{.source="INSERT INTO t VALUES(1,2,3)",.state="00000",.command=.insert,.affected=1,.columns=&.{},.rows=&.{}},
.{.source="SELECT varchar,character,varying FROM t",.state="00000",.command=.select,.affected=0,.columns=&.{.{.name="varchar",.oid=23,.typmod=-1},.{.name="character",.oid=23,.typmod=-1},.{.name="varying",.oid=23,.typmod=-1}},.rows=&.{&.{"1","2","3"}}},
}},
};
pub fn main() !void{
 var passed:usize=0;var gaps:usize=0;
 for(&cases) |*c| {
  db=.{};result=.{};var ok=true;
  for(c.setup) |q| db.execute(q,&result) catch |err| {std.debug.print("GAP {s} setup {s}\n",.{c.id,@errorName(err)});ok=false;break;};
  if(!ok){gaps+=1;continue;}
  for(c.events,0..) |*e,i| {
   const match=if(db.execute(e.source,&result)) |_| try verify(e) else |err| same(e.state,stateOf(err));
   if(!match){ok=false;std.debug.print("GAP {s} event{d}: {s}\n",.{c.id,i,e.source});}
  }
  if(ok){passed+=1;}else{gaps+=1;}
 }
 std.debug.print("character types: {d} passing, {d} gaps, {d} programs\n",.{passed,gaps,cases.len});
 if(gaps!=0)return error.SqlCharacterTypesIncomplete;
}
