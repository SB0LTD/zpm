//! Intentionally red aggregate-state demand probes; not in green regression aggregate.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=2,.columns=6,.rows_per_table=16,.text_bytes=64});
var db:DB=.{};var result:DB.Result=.{};
const Case=struct{source:[]const u8,division_error:bool=false,oid:u32=23,rows:usize=0,value:i64=7,next:i64=1};
const cases=[_]Case{
 .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t) q",.division_error=false,.oid=23,.rows=1,.value=7,.next=1},
 .{.source="SELECT 7 FROM (SELECT sum(v) AS x,1/0 AS y FROM t) q",.division_error=false,.oid=23,.rows=1,.value=7,.next=1},
 .{.source="SELECT x FROM (SELECT sum(v) AS x,sum(1/0) AS y FROM t) q",.division_error=false,.oid=20,.rows=1,.value=3,.next=1},
 .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t WHERE FALSE) q",.division_error=false,.oid=23,.rows=1,.value=7,.next=1},
 .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t GROUP BY v) q",.division_error=false,.oid=23,.rows=2,.value=7,.next=1},
 .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t GROUP BY v HAVING count(*)>0) q",.division_error=false,.oid=23,.rows=2,.value=7,.next=1},
 .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t ORDER BY x) q",.division_error=true,.oid=0,.rows=0,.value=7,.next=1},
 .{.source="SELECT 7 FROM (SELECT DISTINCT sum(1/0) AS x FROM t) q",.division_error=true,.oid=0,.rows=0,.value=7,.next=1},
 .{.source="SELECT 7 FROM (SELECT sum(1/0) FILTER(WHERE FALSE) AS x FROM t) q",.division_error=false,.oid=23,.rows=1,.value=7,.next=1},
 .{.source="SELECT 7 FROM (SELECT sum(nextval('seq')) AS x FROM t) q",.division_error=false,.oid=23,.rows=1,.value=7,.next=3},
 .{.source="SELECT 7 FROM (SELECT count(*) FILTER(WHERE nextval('seq')>0) AS x FROM t) q",.division_error=false,.oid=23,.rows=1,.value=7,.next=3},
 .{.source="SELECT x FROM (SELECT sum(v) AS x,sum(nextval('seq')) AS y FROM t) q",.division_error=false,.oid=20,.rows=1,.value=3,.next=3},
 .{.source="WITH q AS(SELECT sum(1/0) AS x FROM t) SELECT 7 FROM q",.division_error=false,.oid=23,.rows=1,.value=7,.next=1},
 .{.source="WITH q AS(SELECT sum(1/0) AS x FROM t) SELECT 7 FROM q a,q b",.division_error=true,.oid=0,.rows=0,.value=7,.next=1},
 .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t LIMIT 0) q",.division_error=false,.oid=23,.rows=0,.value=7,.next=1},
 .{.source="SELECT 7 FROM (SELECT sum(1/0) AS x FROM t HAVING FALSE) q",.division_error=false,.oid=23,.rows=0,.value=7,.next=1},
};
pub fn main() !void {
 try db.execute("CREATE TABLE t(v INT)",&result);try db.execute("INSERT INTO t VALUES(1),(2)",&result);
 var passed:usize=0;var failed:usize=0;
 for(cases,0..) |c,index| {
  try db.execute("CREATE SEQUENCE seq",&result);
  var ok=true;
  if(db.execute(c.source,&result)) |_| {
   ok=!c.division_error and result.column_count==1 and sql.typeOid(result.column_types[0])==c.oid and result.row_count==c.rows;
   if(ok) for(0..result.row_count) |i| {if(result.rows[i].cells[0]!=.integer or result.rows[i].cells[0].integer!=c.value) {ok=false;break;}};
  } else |err| {ok=c.division_error and err==error.DivisionByZero;}
  try db.execute("SELECT nextval('seq')",&result);
  ok=ok and result.row_count==1 and result.rows[0].cells[0]==.integer and result.rows[0].cells[0].integer==c.next;
  try db.execute("DROP SEQUENCE seq",&result);
  if(ok) {passed+=1;} else {failed+=1;std.debug.print("GAP {d}: {s}\n",.{index,c.source});}
 }
 std.debug.print("aggregate demand: {d} passing, {d} gaps, {d} programs\n",.{passed,failed,cases.len});
 if(failed!=0) return error.SqlAggregateDemandIncomplete;
}
