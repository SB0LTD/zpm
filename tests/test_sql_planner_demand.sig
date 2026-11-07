//! Plain query demand and immutable diagnostics, frozen against native PostgreSQL.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=3,.columns=6,.rows_per_table=16,.text_bytes=256});
var db:DB=.{};var result:DB.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.PlannerDemandContractFailed;}
fn rows(source:[]const u8,oids:[]const u32,wanted:[]const []const ?[]const u8) !void {
 db.execute(source,&result) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
 if(result.row_count!=wanted.len or result.column_count!=oids.len) std.debug.print("{s}: dimensions {d}/{d}, expected {d}/{d}\n",.{source,result.row_count,result.column_count,wanted.len,oids.len});
 try check(result.row_count==wanted.len and result.column_count==oids.len);
 for(oids,0..) |oid,i| try check(sql.typeOid(result.column_types[i])==oid);
 for(wanted,0..) |row,i| for(row,0..) |text,j| {
  const cell=&result.rows[i].cells[j];
  if(text) |expected| {var buffer:[DB.Io.format_bytes]u8=undefined;const actual=try DB.Io.format(cell,false,&db.session,&buffer);if(!std.mem.eql(u8,expected,actual))std.debug.print("{s}: got {s}, expected {s}\n",.{source,actual,expected});try check(std.mem.eql(u8,expected,actual));}
  else try check(cell.*==.null_value);
 };
}
fn rejects(source:[]const u8,wanted:anyerror) !void {
 const before=result;
 if(db.execute(source,&result)) |_| {std.debug.print("accepted {s}\n",.{source});return error.InvalidPlanAccepted;} else |err| {if(err!=wanted)std.debug.print("{s}: got {s}, expected {s}\n",.{source,@errorName(err),@errorName(wanted)});try check(err==wanted);}
 try check(result.row_count==before.row_count and result.column_count==before.column_count);
 for(0..result.row_count) |i| for(0..result.column_count) |j| try check(std.meta.eql(result.rows[i].cells[j],before.rows[i].cells[j]));
}
const Pulse=struct {
 calls:usize=0,stop:usize,
 fn poll(raw:?*anyopaque) sql.Error!void {
  const self:*@This()=@ptrCast(@alignCast(raw.?));self.calls+=1;
  if(self.calls==self.stop) return error.QueryCanceled;
 }
};
pub fn main(init:std.process.Init) !void {
 try db.execute("CREATE TABLE t(id INT,v INT)",&result);
 try db.execute("INSERT INTO t VALUES(1,-1),(2,4)",&result);
 try db.execute("CREATE SEQUENCE seq",&result);
 try rejects("SELECT sqrt(-1::numeric) WHERE FALSE",error.InvalidArgumentForPowerFunction);
 try rejects("SELECT 1/0 WHERE FALSE",error.DivisionByZero);
 try rejects("SELECT 1/0 LIMIT 0",error.DivisionByZero);
 try rows("SELECT CASE WHEN FALSE THEN 1/0 ELSE 7 END WHERE FALSE",&.{23},&.{});
 try rejects("SELECT CASE WHEN v>0 THEN 7 ELSE 1/0 END FROM t WHERE FALSE",error.DivisionByZero);
 try rows("SELECT 7 FROM (SELECT trunc(NULL::numeric,(1/0)::int4) AS x) q",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT sqrt(-1::numeric) AS x FROM t) q",&.{23},&.{&.{"7"},&.{"7"}});
 try rejects("SELECT 7 FROM (SELECT 1/0 AS x ORDER BY x) q",error.DivisionByZero);
 try rows("SELECT 7 FROM (SELECT 1/0 AS x LIMIT 0) q",&.{23},&.{});
 try rejects("SELECT x FROM (SELECT 1/0 AS x LIMIT 0) q",error.DivisionByZero);
 try rejects("SELECT 7 FROM (SELECT DISTINCT 1/0 AS x) q",error.DivisionByZero);
 try rows("SELECT 7 FROM (SELECT nextval('seq') AS x FROM t) q",&.{23},&.{&.{"7"},&.{"7"}});
 try rows("SELECT currval('seq')",&.{20},&.{&.{"2"}});
 try rows("SELECT 1 FROM t WHERE FALSE AND 1/0=0",&.{23},&.{});
 try rejects("SELECT 1 FROM t WHERE 1/0=0 AND FALSE",error.DivisionByZero);
 try rows("SELECT 1 FROM t WHERE v>0 AND FALSE AND 1/0=0",&.{23},&.{});
 try rejects("SELECT 1 FROM t WHERE v>0 AND 1/0=0 AND FALSE",error.DivisionByZero);
 try rows("SELECT 1 FROM t WHERE TRUE OR 1/0=0",&.{23},&.{&.{"1"},&.{"1"}});
 try rejects("SELECT 1 FROM t WHERE 1/0=0 OR TRUE",error.DivisionByZero);
 try rows("SELECT 7 FROM (SELECT 1 AS a,1/0 AS b) q WHERE a=1",&.{23},&.{&.{"7"}});
 try rejects("SELECT 7 FROM (SELECT 1 AS a,1/0 AS b) q WHERE b=1",error.DivisionByZero);
 try rows("SELECT a FROM (SELECT 1 AS a,1/0 AS b) q ORDER BY a",&.{23},&.{&.{"1"}});
 try rows("SELECT 7 FROM (SELECT v AS a,sqrt(-1::numeric) AS b FROM t WHERE id=1) q",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT 1/0 AS b FROM t WHERE FALSE) q",&.{23},&.{});
 try rejects("SELECT b FROM (SELECT 1/0 AS b FROM t WHERE FALSE) q",error.DivisionByZero);
 try rows("SELECT 7 FROM (SELECT 1/0 AS b FROM t) q JOIN t x ON TRUE",&.{23},&.{&.{"7"},&.{"7"},&.{"7"},&.{"7"}});
 try rows("SELECT 7 FROM (SELECT 1 AS a,1/0 AS b) q JOIN t x ON q.a=x.id",&.{23},&.{&.{"7"}});
 try rows("WITH q AS(SELECT 1 AS a,1/0 AS b) SELECT a FROM q",&.{23},&.{&.{"1"}});
 try rejects("WITH q AS(SELECT 1 AS a,1/0 AS b) SELECT x.a FROM q x,q y",error.DivisionByZero);
 try rejects("WITH q AS(SELECT 1 AS a,1/0 AS b) SELECT x.a,y.b FROM q x,q y",error.DivisionByZero);
 try rows("SELECT 7 FROM (SELECT 1/0 AS x) q WHERE FALSE",&.{23},&.{});
 try rows("SELECT 7 FROM (SELECT 1/0 AS x) q LIMIT 0",&.{23},&.{});
 try rows("SELECT 7 FROM (SELECT nextval('seq') AS x,1/0 AS y) q",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT 1/0 AS x) q WHERE CASE WHEN FALSE THEN x>0 ELSE TRUE END",&.{23},&.{&.{"7"}});
 try rows("SELECT CASE WHEN FALSE THEN (SELECT 1/0) ELSE 7 END",&.{23},&.{&.{"7"}});
 try rows("SELECT coalesce(7,(SELECT 1/0))",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT 1 AS x) q WHERE x=1 OR 1/0=0",&.{23},&.{&.{"7"}});
 try rows("SELECT setval('seq',1,false)",&.{20},&.{&.{"1"}});
 try rejects("SELECT abs(-2147483648) WHERE FALSE",error.IntegerOverflow);
 try rejects("SELECT abs(-2147483648) LIMIT 0",error.IntegerOverflow);
 try rejects("SELECT floor(1/0::numeric) FROM t WHERE FALSE",error.DivisionByZero);
 try rejects("SELECT ceil(1/0::numeric) LIMIT 0",error.DivisionByZero);
 try rejects("SELECT sign(1/0::numeric) WHERE FALSE",error.DivisionByZero);
 try rejects("SELECT round(1/0::numeric) WHERE FALSE",error.DivisionByZero);
 try rejects("SELECT trunc(NULL::numeric,(1/0)::int4) WHERE FALSE",error.DivisionByZero);
 try rows("SELECT CASE WHEN FALSE THEN sqrt(-1::numeric) ELSE 7 END LIMIT 0",&.{1700},&.{});
 try rows("SELECT coalesce(7,1/0) WHERE FALSE",&.{23},&.{});
 try rejects("SELECT coalesce(v,1/0) FROM t WHERE FALSE",error.DivisionByZero);
 try rejects("SELECT CASE WHEN id>0 THEN 7 ELSE sqrt(-1::numeric) END FROM t LIMIT 0",error.InvalidArgumentForPowerFunction);
 try rejects("SELECT 1/0,missing FROM t",error.ColumnNotFound);
 try rejects("SELECT 7 FROM (SELECT 1/0 AS x,missing FROM t) q",error.ColumnNotFound);
 try rejects("SELECT 7 FROM (SELECT sqrt(TRUE) AS x) q",error.UndefinedFunction);
 try rows("SELECT 7 FROM (SELECT 1/0 AS x) q ORDER BY 1",&.{23},&.{&.{"7"}});
 try rows("SELECT q.a FROM (SELECT 1 AS a,1/0 AS b) q WHERE q.a+1=2 OR 1/0=0",&.{23},&.{&.{"1"}});
 try rows("SELECT 7 FROM (SELECT 1+1 AS x) q WHERE x=2 OR 1/0=0",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT 1.0+1.0 AS x) q WHERE x=2 OR 1/0=0",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT 1/0 AS x) q LEFT JOIN t ON TRUE",&.{23},&.{&.{"7"},&.{"7"}});
 try rows("SELECT nextval('seq') LIMIT 0",&.{20},&.{});
 try rows("SELECT nextval('seq')",&.{20},&.{&.{"1"}});
 try rows("SELECT currval('seq')",&.{20},&.{&.{"1"}});
 try rejects("SELECT sqrt(-1::numeric) WHERE FALSE AND 1/0=0",error.InvalidArgumentForPowerFunction);
 try rows("SELECT CASE WHEN FALSE THEN 1/0 ELSE 7 END FROM (SELECT 1/0 AS x) q",&.{23},&.{&.{"7"}});
 try rejects("INSERT INTO t(id,v) SELECT 3,1/0 WHERE FALSE",error.DivisionByZero);
 try rejects("UPDATE t SET v=1/0 WHERE FALSE",error.DivisionByZero);
 try rejects("DELETE FROM t WHERE FALSE RETURNING 1/0",error.DivisionByZero);
 try rows("SELECT id,v FROM t ORDER BY id",&.{23,23},&.{&.{"1","-1"},&.{"2","4"}});
 try rejects("SELECT sqrt(-1::numeric) FROM (SELECT 1) q WHERE 1/0=0",error.InvalidArgumentForPowerFunction);
 try rejects("SELECT 1/0 FROM (SELECT 1) q WHERE sqrt(-1::numeric)=0",error.DivisionByZero);
 try rejects("SELECT sqrt(-1::numeric) FROM (SELECT 1) q WHERE (1/0=0 AND FALSE)",error.InvalidArgumentForPowerFunction);
 try rejects("SELECT sqrt(-1::numeric) FROM (SELECT 1) q WHERE CASE WHEN 1/0=0 THEN TRUE ELSE FALSE END",error.InvalidArgumentForPowerFunction);
 try rows("SELECT 7 FROM (SELECT ROW(1/0,2) IN(NULL) AS x) q",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT ROW(1/0,2) BETWEEN NULL AND NULL AS x) q",&.{23},&.{&.{"7"}});
 try rows("SELECT CASE WHEN FALSE THEN ROW(1/0,2) IN(NULL) ELSE TRUE END",&.{16},&.{&.{"t"}});
 try rows("SELECT FALSE AND ROW(1/0,2) IN(NULL)",&.{16},&.{&.{"f"}});
 try rejects("SELECT ROW(1/0,2) IN(NULL) WHERE FALSE",error.DivisionByZero);
 try rows("SELECT 7 FROM (SELECT 1.0 AS x) q WHERE x=1 OR 1/0=0",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT 'abc' AS x) q WHERE x='abc' OR 1/0=0",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT NULL::int AS x) q WHERE x IS NULL OR 1/0=0",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT DATE '2026-11-01' AS x) q WHERE x=DATE '2026-11-01' OR 1/0=0",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT 1 AS x,1/0 AS y) q WHERE x=1 OR y=0",&.{23},&.{&.{"7"}});
 try rejects("SELECT 7 FROM (SELECT CASE WHEN FALSE THEN nextval('seq') ELSE 1 END AS x) q WHERE x=1 OR 1/0=0",error.DivisionByZero);
 try rows("SELECT 7 FROM (SELECT abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(1)))))))))))))))))))))))))))))))))))))))) AS x) q WHERE abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(x))))))))))))))))))))))))))))))))))))))))=1",&.{23},&.{&.{"7"}});
 try rejects("SELECT 7 FROM (SELECT DISTINCT 1 AS x) q WHERE x=1 OR 1/0=0",error.DivisionByZero);
 try rejects("SELECT 7 FROM (SELECT 1 AS x ORDER BY x) q WHERE x=1 OR 1/0=0",error.DivisionByZero);
 try rejects("SELECT 7 FROM (SELECT 1 AS x LIMIT 0) q WHERE x=1 OR 1/0=0",error.DivisionByZero);
 try rejects("SELECT 7 FROM (SELECT 1 AS x LIMIT 1) q WHERE x=1 OR 1/0=0",error.DivisionByZero);
 try rejects("SELECT 7 FROM (SELECT 1 AS x OFFSET 0) q WHERE x=1 OR 1/0=0",error.DivisionByZero);
 try rejects("SELECT 7 FROM (SELECT 1 AS x,sum(v) AS y FROM t) q WHERE x=1 OR 1/0=0",error.DivisionByZero);
 try rows("WITH q AS(SELECT 1 AS x) SELECT 7 FROM q WHERE x=1 OR 1/0=0",&.{23},&.{&.{"7"}});
 try rejects("WITH q AS(SELECT 1 AS x) SELECT 7 FROM q a,q b WHERE a.x=1 OR 1/0=0",error.DivisionByZero);
 try rejects("WITH q AS(SELECT 1 AS x) SELECT 7 FROM (SELECT x FROM q) a,q b WHERE a.x=1 OR 1/0=0",error.DivisionByZero);
 try rows("WITH q AS(SELECT 1 AS x) SELECT 7 FROM (SELECT 1 AS x FROM q) a,q b WHERE a.x=1 OR 1/0=0",&.{23},&.{&.{"7"}});
 try rows("SELECT 7 FROM (SELECT trunc(NULL::numeric,1::int) AS x) q WHERE x IS NULL OR 1/0=0",&.{23},&.{&.{"7"}});
 try rejects("SELECT 7 FROM (SELECT trunc(NULL::numeric,nextval('seq')::int) AS x) q WHERE x IS NULL OR 1/0=0",error.DivisionByZero);
 // A shared constant DAG must fit a linear, caller-enforced work grant.
 var dag:[4096]u8=undefined;const base="SELECT 1 AS x";@memcpy(dag[0..base.len],base);var used:usize=base.len;
 for(0..14) |_| {
  const prefix="SELECT x+x AS x FROM (";const suffix=") q";
  std.mem.copyBackwards(u8,dag[prefix.len..][0..used],dag[0..used]);@memcpy(dag[0..prefix.len],prefix);
  used+=prefix.len;@memcpy(dag[used..][0..suffix.len],suffix);used+=suffix.len;
 }
 var dag_control:sql.ExecutionControl=.{.max_work=20000};db.session.control=&dag_control;
 try rows(dag[0..used],&.{23},&.{&.{"16384"}});try check(dag_control.used<20000);db.session.control=null;
 // Metadata-only binding preserves types but defers execution planning errors.
 for([_]struct{source:[]const u8,oid:u32}{
  .{.source="SELECT sqrt(-1::numeric) WHERE FALSE",.oid=1700},
  .{.source="SELECT sqrt(-1::numeric) FROM (SELECT 1) q WHERE FALSE",.oid=1700},
  .{.source="SELECT 1/0 LIMIT 0",.oid=23},
 }) |item| {
  try db.describe(item.source,&result);try check(result.row_count==0 and result.column_count==1);
  try check(sql.typeOid(result.column_types[0])==item.oid);
 }
 if(db.describe("SELECT 1/0,missing FROM t",&result)) |_| return error.InvalidDescriptionAccepted else |err| try check(err==error.ColumnNotFound);
 // A one-shot cancellation must survive speculative constant inspection.
 for(1..81) |point| {
  var pulse:Pulse=.{.stop=point};var control:sql.ExecutionControl=.{.context=&pulse,.poll=Pulse.poll,.poll_interval=1};
  db.session.control=&control;
  if(db.execute("SELECT 7 FROM (SELECT CASE WHEN FALSE THEN sqrt(-1::numeric) ELSE 1 END AS x) q WHERE x=1 OR 1/0=0",&result)) |_| {
   try check(pulse.calls<point);
  } else |err| {try check(err==error.QueryCanceled);try check(pulse.calls>=point);}
  db.session.control=null;
 }
 try rows("SELECT 7",&.{23},&.{&.{"7"}});
 // Existing configured64-level AST ceiling remains intact.
 try rejects("SELECT abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(abs(1))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))",error.StatementTooComplex);
 var buffer:[160]u8=undefined;const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"planner-demand\",\"assertions\":{d},\"database_bytes\":{d}}}\n",.{assertions,@sizeOf(DB)});try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
