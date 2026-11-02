//! Generated native-reference aggregate-state demand probes; intentionally red.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=3,.columns=8,.rows_per_table=16,.work_rows=128,.result_rows=64,.expr_nodes=512,.text_bytes=128});
var db:DB=.{};var result:DB.Result=.{};
const Column=struct{name:[]const u8,oid:u32};
const Event=struct{source:[]const u8,state:[]const u8,columns:[]const Column=&.{},rows:[]const []const ?[]const u8=&.{}};
const Case=struct{id:[]const u8,setup:[]const []const u8,events:[]const Event};
fn same(a:[]const u8,b:[]const u8) bool{return std.mem.eql(u8,a,b);}
// Finite core-test adapter for native SQLSTATEs in this fixture; protocol mapping
// remains separately qualified through the PostgreSQL codec/client suites.
fn stateOf(err:anyerror) []const u8 {return switch(err){
 error.DivisionByZero=>"22012",error.ColumnNotFound=>"42703",error.UndefinedFunction=>"42883",
 error.GroupingError=>"42803",error.IntegerOverflow,error.NumericValueOutOfRange=>"22003",
 else=>@errorName(err),
};}
fn sameRow(wanted:[]const ?[]const u8,index:usize) !bool {
 var buffer:[DB.Io.format_bytes]u8=undefined;
 for(wanted,0..) |value,column| {
  const cell=&result.rows[index].cells[column];
  if(value) |text| {if(cell.*==.null_value or !same(text,try DB.Io.format(cell,false,&db.session,&buffer))) return false;}
  else if(cell.*!=.null_value) return false;
 }
 return true;
}
fn verify(event:*const Event) !bool {
 if(!same(event.state,"00000") or result.command!=.select or result.row_count!=event.rows.len or result.column_count!=event.columns.len) return false;
 for(event.columns,0..) |column,index| if(sql.typeOid(result.column_types[index])!=column.oid or !same(result.column_names[index].slice(),column.name)) return false;
 // Compare bags, preserving duplicate rows. These probes do not close ORDER BY.
 var used:[64]bool=@splat(false);
 for(event.rows) |row| {
  var found=false;
  for(0..result.row_count) |i| if(!used[i] and try sameRow(row,i)) {used[i]=true;found=true;break;};
  if(!found) return false;
 }
 return true;
}
const cases=[_]Case{
 .{.id="aggregate_probe_0",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_1",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(v) AS x,1/0 AS y FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_2",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT x FROM (SELECT sum(v) AS x,sum(1/0) AS y FROM t) q",.state="00000",.columns=&.{.{.name="x",.oid=20}},.rows=&.{&.{"3"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_3",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t WHERE FALSE) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_4",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t GROUP BY v) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"},&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_5",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t GROUP BY v HAVING count(*)>0) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"},&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_6",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t ORDER BY x) q",.state="22012"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_7",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT DISTINCT sum(1/0) AS x FROM t) q",.state="22012"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_8",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) FILTER(WHERE FALSE) AS x FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_9",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(nextval('seq')) AS x FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"3"}}},
 }},
 .{.id="aggregate_probe_10",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT count(*) FILTER(WHERE nextval('seq')>0) AS x FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"3"}}},
 }},
 .{.id="aggregate_probe_11",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT x FROM (SELECT sum(v) AS x,sum(nextval('seq')) AS y FROM t) q",.state="00000",.columns=&.{.{.name="x",.oid=20}},.rows=&.{&.{"3"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"3"}}},
 }},
 .{.id="aggregate_probe_12",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="WITH q AS(SELECT sum(1/0) AS x FROM t) SELECT 7 FROM q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_13",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="WITH q AS(SELECT sum(1/0) AS x FROM t) SELECT 7 FROM q a,q b",.state="22012"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_14",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t LIMIT 0) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_probe_15",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(2)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t HAVING FALSE) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_duplicate_groups",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) AS dead FROM t GROUP BY v) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"},&.{"7"},&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_empty_groups",.setup=&.{"CREATE TABLE t(v INT)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/0) AS dead FROM t GROUP BY v) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_live_group_keys",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT g FROM (SELECT v AS g,sum(1/(v-1)) AS dead FROM t GROUP BY v) q ORDER BY g NULLS LAST",.state="00000",.columns=&.{.{.name="g",.oid=23}},.rows=&.{&.{"1"},&.{"2"},&.{null}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_selective_having",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/(v-1)) AS dead FROM t GROUP BY v HAVING count(*)>1) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_row_dependent",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/(v-1)) AS dead FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_dead_before_live",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT live FROM (SELECT sum(1/(v-1)) AS dead,sum(v) AS live FROM t) q",.state="00000",.columns=&.{.{.name="live",.oid=20}},.rows=&.{&.{"4"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_dead_after_live",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT live FROM (SELECT sum(v) AS live,sum(1/(v-1)) AS dead FROM t) q",.state="00000",.columns=&.{.{.name="live",.oid=20}},.rows=&.{&.{"4"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_deduplicated_dead",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/(v-1)) AS a,sum(1/(v-1)) AS b FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_deduplicated_live",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT a+b FROM (SELECT sum(1/(v-1)) AS a,sum(1/(v-1)) AS b FROM t) q",.state="22012"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_live_false_filter",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT x FROM (SELECT sum(1/(v-1)) FILTER(WHERE FALSE) AS x FROM t) q",.state="00000",.columns=&.{.{.name="x",.oid=20}},.rows=&.{&.{null}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_live_selective_filter",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT x FROM (SELECT sum(1/(v-1)) FILTER(WHERE v<>1) AS x FROM t) q",.state="00000",.columns=&.{.{.name="x",.oid=20}},.rows=&.{&.{"1"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_dead_false_filter",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/(v-1)) FILTER(WHERE FALSE) AS x FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_dead_distinct_arg",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(DISTINCT 1/(v-1)) AS x FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_live_distinct_and_dead",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT live FROM (SELECT count(DISTINCT v) AS live,sum(1/(v-1)) AS dead FROM t) q",.state="00000",.columns=&.{.{.name="live",.oid=20}},.rows=&.{&.{"2"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_live_having_dependency",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(v) AS x FROM t HAVING sum(1/(v-1))>0) q",.state="22012"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_hidden_order_dependency",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(v) AS x FROM t ORDER BY sum(1/(v-1))) q",.state="22012"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_hidden_order_limit_zero",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/(v-1)) AS x FROM t ORDER BY x LIMIT 0) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_distinct_dependency",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT DISTINCT sum(1/(v-1)) AS x FROM t) q",.state="22012"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_shared_cte_dependency",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="WITH q AS(SELECT sum(1/(v-1)) AS x FROM t) SELECT 7 FROM q a,q b",.state="22012"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_single_cte_pruning",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="WITH q AS(SELECT sum(1/(v-1)) AS x FROM t) SELECT 7 FROM q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_empty_null_outputs",.setup=&.{"CREATE TABLE t(v INT)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT s,c,mn,mx,av FROM (SELECT sum(v) AS s,count(v) AS c,min(v) AS mn,max(v) AS mx,avg(v) AS av,sum(1/(v-1)) AS dead FROM t) q",.state="00000",.columns=&.{.{.name="s",.oid=20},.{.name="c",.oid=20},.{.name="mn",.oid=23},.{.name="mx",.oid=23},.{.name="av",.oid=1700}},.rows=&.{&.{null,"0",null,null,null}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_all_null_outputs",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(NULL),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT s,c,mn,mx,av FROM (SELECT sum(v) AS s,count(v) AS c,min(v) AS mn,max(v) AS mx,avg(v) AS av,sum(1/(v-1)) AS dead FROM t) q",.state="00000",.columns=&.{.{.name="s",.oid=20},.{.name="c",.oid=20},.{.name="mn",.oid=23},.{.name="mx",.oid=23},.{.name="av",.oid=1700}},.rows=&.{&.{null,"0",null,null,null}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_semantic_missing_column",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(missing) AS dead FROM t) q",.state="42703"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_semantic_wrong_type",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum('bad'::text) AS dead FROM t) q",.state="42883"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_semantic_nested_aggregate",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(sum(v)) AS dead FROM t) q",.state="42803"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_semantic_ungrouped_column",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT v,sum(v) AS dead FROM t) q",.state="42803"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_volatile_filter",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT count(*) FILTER(WHERE nextval('seq')>0) AS dead FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"5"}}},
 }},
 .{.id="aggregate_volatile_dead_case",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(CASE WHEN FALSE THEN nextval('seq') ELSE 1 END) AS dead FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_volatile_row_case",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(CASE WHEN v=1 THEN nextval('seq') ELSE 0 END) AS dead FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"3"}}},
 }},
 .{.id="aggregate_volatile_throwing_filter",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/(v-1)) FILTER(WHERE nextval('seq')>0) AS dead FROM t) q",.state="22012"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"2"}}},
 }},
 .{.id="aggregate_float_overflow_dead",.setup=&.{"CREATE TABLE t(v DOUBLE PRECISION)","INSERT INTO t VALUES('1e308'::float8),('1e308'::float8)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(v) AS dead FROM t) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_float_overflow_live",.setup=&.{"CREATE TABLE t(v DOUBLE PRECISION)","INSERT INTO t VALUES('1e308'::float8),('1e308'::float8)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT x FROM (SELECT sum(v) AS x FROM t) q",.state="22003"},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_rollup_cardinality",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT 7 FROM (SELECT sum(1/(v-1)) AS dead FROM t GROUP BY ROLLUP(v)) q",.state="00000",.columns=&.{.{.name="?column?",.oid=23}},.rows=&.{&.{"7"},&.{"7"},&.{"7"},&.{"7"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
 .{.id="aggregate_live_having_group",.setup=&.{"CREATE TABLE t(v INT)","INSERT INTO t VALUES(1),(1),(2),(NULL)","CREATE SEQUENCE seq"},.events=&.{
  .{.source="SELECT g,n FROM (SELECT v AS g,count(*) AS n,sum(1/(v-1)) AS dead FROM t GROUP BY v HAVING count(*)>1) q",.state="00000",.columns=&.{.{.name="g",.oid=23},.{.name="n",.oid=20}},.rows=&.{&.{"1","2"}}},
  .{.source="SELECT nextval('seq')",.state="00000",.columns=&.{.{.name="nextval",.oid=20}},.rows=&.{&.{"1"}}},
 }},
};
pub fn main() !void {
 var passed:usize=0;var failed:usize=0;
 for(&cases) |*c| {
  db=.{};result=.{};var ok=true;
  for(c.setup) |source| db.execute(source,&result) catch |err| {std.debug.print("GAP {s} setup: {s}\n",.{c.id,@errorName(err)});ok=false;break;};
  if(!ok) {failed+=1;continue;}
  for(c.events,0..) |*event,index| {
   const matched=if(db.execute(event.source,&result)) |_| try verify(event) else |err| same(event.state,stateOf(err));
   if(!matched) {ok=false;std.debug.print("GAP {s} event {d}: {s}\n",.{c.id,index,event.source});}
  }
  if(ok) {passed+=1;} else {failed+=1;}
 }
 std.debug.print("aggregate demand: {d} passing, {d} gaps, {d} programs\n",.{passed,failed,cases.len});
 if(failed!=0) return error.SqlAggregateDemandIncomplete;
}
