//! Conditional DDL must preserve existing state and transaction ownership.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=2,.columns=8,.rows_per_table=8,.text_bytes=128,.work_rows=64});
var db:DB=.{};var result:DB.Result=.{};var assertions:usize=0;
var transaction:?u16=null;
var phase:[]const u8="main";
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("failed assertion {d}, {s}\n",.{assertions,phase});return error.ConditionalDdlContractFailed;}}
fn execute(source:[]const u8) sql.Error!void {if(transaction) |slot| return db.statement(slot,source,&result,.{});return db.execute(source,&result);}
fn run(source:[]const u8) !void {execute(source) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};}
fn rejects(source:[]const u8,wanted:anyerror) !void {
 if(execute(source)) |_| return error.InvalidDdlAccepted else |err| {if(err!=wanted)std.debug.print("{s}: got {s}, want {s}\n",.{source,@errorName(err),@errorName(wanted)});try check(err==wanted);}
}
fn integer(source:[]const u8,wanted:i64) !void {try run(source);try check(result.row_count==1 and result.rows[0].cells[0].integer==wanted);}
pub fn main() !void {
 try run("CREATE TABLE IF NOT EXISTS a(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)");
 try run("INSERT INTO a VALUES(1,10)");
 try run("CREATE TABLE IF NOT EXISTS a(other TEXT DEFAULT undefined_function())");
 try run("CREATE TABLE IF NOT EXISTS a(id INTEGER PRIMARY KEY,v INTEGER PRIMARY KEY)");
 try run("CREATE TABLE IF NOT EXISTS a(id INTEGER NOT NULL NOT NULL)");
 try run("CREATE TABLE IF NOT EXISTS a(id INTEGER DEFAULT 1 DEFAULT 2)");
 try integer("SELECT v FROM a WHERE id=1",10);
 try run("CREATE TABLE IF NOT EXISTS a(id INTEGER GENERATED ALWAYS AS IDENTITY)");
 try integer("SELECT COUNT(*) FROM a",1);
 try run("DROP TABLE IF EXISTS missing");try integer("SELECT v FROM a",10);
 try run("CREATE SEQUENCE IF NOT EXISTS s START WITH 19 INCREMENT BY 3");
 try integer("SELECT nextval('s')",19);
 try run("CREATE SEQUENCE IF NOT EXISTS s START WITH 0 INCREMENT BY 0");
 try run("CREATE SEQUENCE IF NOT EXISTS s AS TEXT");
 try run("CREATE SEQUENCE IF NOT EXISTS s AS TEXT AS BIGINT");
 try rejects("CREATE SEQUENCE IF NOT EXISTS absent AS TEXT AS BIGINT",error.Syntax);
 try integer("SELECT nextval('s')",22);
 try run("CREATE TABLE IF NOT EXISTS s(id INTEGER)");
 try run("CREATE SEQUENCE IF NOT EXISTS a INCREMENT BY 0");
 try rejects("DROP TABLE IF EXISTS s",error.WrongObjectType);
 try rejects("DROP SEQUENCE IF EXISTS a",error.WrongObjectType);
 try run("DROP SEQUENCE IF EXISTS missing");
 try run("DROP SEQUENCE IF EXISTS s");try run("DROP SEQUENCE IF EXISTS s");
 transaction=try db.begin();try run("CREATE TABLE IF NOT EXISTS b(id INTEGER)");try run("CREATE TABLE IF NOT EXISTS b(other TEXT)");db.abort(transaction.?);transaction=null;
 try rejects("SELECT * FROM b",error.TableNotFound);
 transaction=try db.begin();try run("UPDATE a SET v=30");try run("DROP TABLE IF EXISTS missing");try run("CREATE TABLE IF NOT EXISTS a(other TEXT)");db.abort(transaction.?);transaction=null;
 try integer("SELECT v FROM a",10);
 try run("DROP TABLE IF EXISTS a");try run("DROP TABLE IF EXISTS a");
 try run("CREATE TABLE IF NOT EXISTS a(id INTEGER)");
 try run("CREATE TABLE IF NOT EXISTS b(id INTEGER)");
 try run("CREATE TABLE IF NOT EXISTS a(id INTEGER)");
 try rejects("CREATE TABLE IF NOT EXISTS capacity_extra(id INTEGER)",error.TableCapacity);
 try run("DROP TABLE IF EXISTS a");try run("DROP TABLE IF EXISTS b");
 try run("CREATE TABLE if(id INTEGER)");try run("DROP TABLE if");
 try run("CREATE SEQUENCE if");try run("DROP SEQUENCE if");
 try callbacks();try nativeFixtures();try concurrentDdl();try carriedSequence();try resources();try quotedReplay();
 try check(db.usage().transactions==0 and db.usage().pending_versions==0);
 std.debug.print("conditional-ddl assertions {d}\n",.{assertions});
}

fn concurrentDdl() !void {
 for(0..2) |kind| for(0..2) |publishes| {
  phase=if(kind==0) (if(publishes==0) "table abort" else "table commit") else (if(publishes==0) "sequence abort" else "sequence commit");
  fixture_db=.{};
  const a=try fixture_db.begin();const b=try fixture_db.begin();
  const first=if(kind==0) "CREATE TABLE race(id INTEGER DEFAULT 7)" else "CREATE SEQUENCE race START WITH 19";
  const second=if(kind==0) "CREATE TABLE IF NOT EXISTS race(id INTEGER DEFAULT 9)" else "CREATE SEQUENCE IF NOT EXISTS race START WITH 29";
  try fixture_db.statement(a,first,&fixture_result,.{});
  if(fixture_db.statement(b,second,&fixture_result,.{})) |_| return error.ExpectedPark else |err| try check(err==error.WouldBlock);
  if(publishes==1) fixture_db.publishCommit(a) else fixture_db.abort(a);
  try fixture_db.statement(b,second,&fixture_result,.{.@"resume"=true});
  if(fixture_db.outcome.noop!=(publishes==1) or fixture_db.readOnly(b)!=(publishes==1)) std.debug.print("create retry kind{d} publish{d}: noop{} readOnly{}\n",.{kind,publishes,fixture_db.outcome.noop,fixture_db.readOnly(b)});
  try check(fixture_db.outcome.noop==(publishes==1) and fixture_db.readOnly(b)==(publishes==1));
  fixture_db.publishCommit(b);
  if(kind==0) {
   try fixture_db.execute("INSERT INTO race DEFAULT VALUES",&fixture_result);try fixture_db.execute("SELECT id FROM race",&fixture_result);
   try check(fixture_result.rows[0].cells[0].integer==if(publishes==1) @as(i64,7) else 9);
  } else {
   try fixture_db.execute("SELECT nextval('race')",&fixture_result);try check(fixture_result.rows[0].cells[0].integer==if(publishes==1) @as(i64,19) else 29);
  }
  // A competing DROP must become a no-op after committed deletion, and
  // perform the deletion after rollback of its predecessor.
  const x=try fixture_db.begin();const y=try fixture_db.begin();
  const drop=if(kind==0) "DROP TABLE IF EXISTS race" else "DROP SEQUENCE IF EXISTS race";
  try fixture_db.statement(x,drop,&fixture_result,.{});
  if(fixture_db.statement(y,drop,&fixture_result,.{})) |_| return error.ExpectedPark else |err| try check(err==error.WouldBlock);
  if(publishes==1) fixture_db.publishCommit(x) else fixture_db.abort(x);
  try fixture_db.statement(y,drop,&fixture_result,.{.@"resume"=true});
  if(fixture_db.outcome.noop!=(publishes==1)) std.debug.print("drop retry kind{d} publish{d}: noop{}\n",.{kind,publishes,fixture_db.outcome.noop});
  try check(fixture_db.outcome.noop==(publishes==1));fixture_db.publishCommit(y);
  try check(fixture_db.usage().transactions==0 and fixture_db.usage().pending_versions==0);
 };
 fixture_db=.{};try fixture_db.execute("CREATE SEQUENCE ordinary",&fixture_result);
 const x=try fixture_db.begin();const y=try fixture_db.begin();
 try fixture_db.statement(x,"DROP SEQUENCE ordinary",&fixture_result,.{});
 if(fixture_db.statement(y,"DROP SEQUENCE ordinary",&fixture_result,.{})) |_| return error.ExpectedPark else |err| try check(err==error.WouldBlock);
 fixture_db.publishCommit(x);
 if(fixture_db.statement(y,"DROP SEQUENCE ordinary",&fixture_result,.{.@"resume"=true})) |_| return error.StaleDropAccepted else |err| try check(err==error.TableNotFound);
 fixture_db.abort(y);try check(fixture_db.usage().transactions==0 and fixture_db.usage().pending_versions==0);
}
var restored:DB=.{};var replay_scratch:DB.ReplayScratch=.{};
fn carriedSequence() !void {
 phase="carried sequence";
 fixture_db=.{};restored=.{};
 var buffer:[4096]u8=undefined;var used:usize=0;
 try fixture_db.executeChanges("CREATE SEQUENCE s",&fixture_result,&buffer,&used,null,null);
 try restored.applyChangeRecord(buffer[0..used],&replay_scratch);
 const a=try fixture_db.begin();try fixture_db.statement(a,"SELECT nextval('s')",&fixture_result,.{});fixture_db.abort(a);
 callbacks_seen=0;
 if(fixture_db.executeWithCommit("DROP TABLE IF EXISTS missing",&fixture_result,null,callback)) |_| return error.CommitFailureIgnored else |err| try check(err==error.UnexpectedCommit);
 try check(callbacks_seen==1 and fixture_db.usage().transactions==0);
 used=0;try fixture_db.executeChanges("DROP TABLE IF EXISTS missing",&fixture_result,&buffer,&used,null,null);
 try check(used>sql.change_records.header_size);
 try restored.applyChangeRecord(buffer[0..used],&replay_scratch);
 try restored.execute("SELECT nextval('s')",&fixture_result);try check(fixture_result.rows[0].cells[0].integer==34);
}
fn cancel(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
fn quotedReplay() !void {
 phase="quoted identifier WAL replay";
 const cases=[_][2][]const u8{
  .{"\"UPPER\"","\"Column\""},.{"\"space name\"","\"space col\""},
  .{"\"1numeric\"","\"1col\""},.{"\"q\"\"x\"","\"c\"\"x\""},
  .{"cost$","col$"},.{"\"\xc3\xa9\"","\"\xce\xa9\""},
 };
 var source:[512]u8=undefined;var buffer:[4096]u8=undefined;
 for(cases) |names| {
  fixture_db=.{};restored=.{};var used:usize=0;
  const create=try std.fmt.bufPrint(&source,"CREATE TABLE {s}({s} INTEGER PRIMARY KEY)",.{names[0],names[1]});
  try fixture_db.executeChanges(create,&fixture_result,&buffer,&used,null,null);
  const insert=try std.fmt.bufPrint(&source,"INSERT INTO {s} VALUES(17)",.{names[0]});
  try fixture_db.executeChanges(insert,&fixture_result,&buffer,&used,null,null);
  try restored.applyChangeRecord(buffer[0..used],&replay_scratch);
  const select=try std.fmt.bufPrint(&source,"SELECT {s} FROM {s}",.{names[1],names[0]});
  try restored.execute(select,&fixture_result);try check(fixture_result.rows[0].cells[0].integer==17);
 }
 // A valid quoted sequence name is also part of the typed schema journal.
 fixture_db=.{};restored=.{};var used:usize=0;
 try fixture_db.executeChanges("CREATE SEQUENCE \"Seq Space\"",&fixture_result,&buffer,&used,null,null);
 try restored.applyChangeRecord(buffer[0..used],&replay_scratch);
 try check(std.mem.eql(u8,restored.seqs[0].name.slice(),"Seq Space"));
 // Empty and NUL names must be rejected before any replay publication.
 for([_]usize{13,14}) |bad| {
  var damaged:[4096]u8=undefined;@memcpy(damaged[0..used],buffer[0..used]);damaged[bad]=0;
  restored=.{};
  if(restored.applyChangeRecord(damaged[0..used],&replay_scratch)) |_| return error.InvalidNameAccepted else |err| try check(err==error.InvalidChangeRecord);
  try check(restored.tableCount()==0 and !restored.seqs[0].live);
 }
 try rejects("CREATE TABLE \"\"(id INTEGER)",error.Syntax);
 try rejects("CREATE TABLE \"bad\x00name\"(id INTEGER)",error.Syntax);
}
fn resources() !void {
 phase="resources";
 try run("CREATE TABLE a(id INTEGER)");
 var control:sql.ExecutionControl=.{};db.session.control=&control;defer db.session.control=null;
 const source="CREATE TABLE IF NOT EXISTS a(v INTEGER DEFAULT undefined_function())";
 try run(source);const work=control.used;try check(work>0);
 var budget:u64=1;while(budget<work):(budget+=1){control.reset(budget);try rejects(source,error.QueryWorkLimit);}
 control.reset(work);try run(source);try check(control.used==work);
 control.reset(0);control.poll=cancel;try rejects(source,error.QueryCanceled);
 control.poll=null;control.reset(0);try run(source);try run("DROP TABLE a");
 try check(db.usage().transactions==0 and db.usage().pending_versions==0);
}
var callbacks_seen:usize=0;
fn callback(_: ?*anyopaque) anyerror!void {callbacks_seen+=1;return error.UnexpectedCommit;}
fn recordCallback(_: ?*anyopaque,_:[]const u8) anyerror!void {callbacks_seen+=1;return error.UnexpectedCommit;}
fn callbacks() !void {
 try run("CREATE TABLE a(id INTEGER)");
 const statements=[_][]const u8{"CREATE TABLE IF NOT EXISTS a(other TEXT)","CREATE SEQUENCE IF NOT EXISTS a","DROP TABLE IF EXISTS missing","DROP SEQUENCE IF EXISTS missing"};
 const tags=[_]sql.CommandTag{.create_table,.create_sequence,.drop_table,.drop_sequence};
 for(statements,0..) |source,index| {
  callbacks_seen=0;
  const oid=db.oid_counter;
  try db.executeWithCommit(source,&result,null,callback);
  try check(callbacks_seen==0 and result.affected_rows==0 and result.command==tags[index] and db.oid_counter==oid);
  var used:usize=0;var buffer:[0]u8=.{};
  try db.executeChanges(source,&result,&buffer,&used,null,recordCallback);
  try check(used==0 and callbacks_seen==0);
 }
 try run("DROP TABLE a");
}


var fixture_db:DB=.{};var fixture_result:DB.Result=.{};
fn fixture(setup:[]const []const u8,source:[]const u8,probe:[]const u8,wanted:?anyerror,expected:[]const []const ?[]const u8,noop:bool) !void {
 phase=source;
 fixture_db=.{};const slot=try fixture_db.begin();defer fixture_db.abort(slot);
 for(setup) |statement| try fixture_db.statement(slot,statement,&fixture_result,.{});
 const oid=fixture_db.oid_counter;const writes=fixture_db.txs[slot].write_len;
 if(fixture_db.statement(slot,source,&fixture_result,.{})) |_| {
  if(wanted!=null) return error.InvalidDdlAccepted;
 } else |err| {if(wanted==null or err!=wanted.?) {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;}try check(true);return;}
 if(noop) try check(fixture_db.outcome.noop and fixture_db.oid_counter==oid and fixture_db.txs[slot].write_len==writes);
 try fixture_db.statement(slot,probe,&fixture_result,.{});try check(fixture_result.row_count==expected.len);
 for(expected,0..) |row,i| {
  try check(fixture_result.column_count==row.len);
  for(row,0..) |wanted_cell,j| {
   const cell=&fixture_result.rows[i].cells[j];
   if(wanted_cell) |text| {var buffer:[DB.Io.format_bytes]u8=undefined;try check(std.mem.eql(u8,text,try DB.Io.format(cell,false,&fixture_db.session,&buffer)));}
   else try check(cell.*==.null_value);
  }
 }
}
fn nativeFixtures() !void {
 try fixture(&.{},"CREATE TABLE IF NOT EXISTS t(id INTEGER)","SELECT COUNT(*) AS value FROM t",null,&.{&.{"0"}},false);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE IF NOT EXISTS t(other TEXT)","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE IF NOT EXISTS t(other INTEGER DEFAULT undefined_function())","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE IF NOT EXISTS t(other INTEGER DEFAULT 1/0)","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE IF NOT EXISTS t(id INTEGER GENERATED ALWAYS AS IDENTITY(INCREMENT BY 0))","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE IF NOT EXISTS t(id INTEGER GENERATED ALWAYS AS(nonexistent) STORED)","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE IF NOT EXISTS t(id INTEGER,id INTEGER)","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY,v INTEGER PRIMARY KEY)","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE IF NOT EXISTS t(id INTEGER NOT NULL NOT NULL)","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE IF NOT EXISTS t(id INTEGER DEFAULT 1 DEFAULT 2)","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE TABLE IF NOT EXISTS s(id INTEGER)","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE SEQUENCE IF NOT EXISTS t INCREMENT BY 0","SELECT id,v FROM t ORDER BY id",null,&.{&.{"1","10"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s INCREMENT BY 0","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s AS TEXT","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s MINVALUE 10 MAXVALUE 1","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s CACHE 0","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s START WITH 100 INCREMENT BY -1","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s AS TEXT AS BIGINT","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s INCREMENT BY 1 INCREMENT BY 2","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s MINVALUE 1 NO MINVALUE","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s NO MAXVALUE MAXVALUE 20","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s START 1 START 2","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s CACHE 1 CACHE 1","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE IF NOT EXISTS s CYCLE NO CYCLE","SELECT nextval('s') AS value",null,&.{&.{"19"}},true);
 try fixture(&.{},"CREATE SEQUENCE IF NOT EXISTS s AS TEXT AS BIGINT","SELECT 1 AS value",error.Syntax,&.{},false);
 try fixture(&.{},"CREATE SEQUENCE IF NOT EXISTS s INCREMENT BY 1 INCREMENT BY 2","SELECT 1 AS value",error.Syntax,&.{},false);
 try fixture(&.{},"CREATE SEQUENCE IF NOT EXISTS s MINVALUE 1 NO MINVALUE","SELECT 1 AS value",error.Syntax,&.{},false);
 try fixture(&.{},"CREATE SEQUENCE IF NOT EXISTS s NO MAXVALUE MAXVALUE 20","SELECT 1 AS value",error.Syntax,&.{},false);
 try fixture(&.{},"CREATE SEQUENCE IF NOT EXISTS s START 1 START 2","SELECT 1 AS value",error.Syntax,&.{},false);
 try fixture(&.{},"CREATE SEQUENCE IF NOT EXISTS s CACHE 1 CACHE 1","SELECT 1 AS value",error.Syntax,&.{},false);
 try fixture(&.{},"CREATE SEQUENCE IF NOT EXISTS s CYCLE NO CYCLE","SELECT 1 AS value",error.Syntax,&.{},false);
 try fixture(&.{},"CREATE SEQUENCE IF NOT EXISTS s AS TEXT","SELECT 1 AS value",error.InvalidParameterValue,&.{},false);
 try fixture(&.{},"CREATE SEQUENCE IF NOT EXISTS s START WITH 9","SELECT nextval('s') AS value",null,&.{&.{"9"}},false);
 try fixture(&.{},"DROP TABLE IF EXISTS missing","SELECT 1 AS value",null,&.{&.{"1"}},true);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"DROP TABLE IF EXISTS t","SELECT 1 AS value",null,&.{&.{"1"}},false);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"DROP TABLE IF EXISTS s","SELECT 1 AS value",error.WrongObjectType,&.{},false);
 try fixture(&.{},"CREATE TABLE if(id INTEGER)","SELECT 1 AS value",null,&.{&.{"1"}},false);
 try fixture(&.{"CREATE TABLE if(id INTEGER)"},"DROP TABLE if","SELECT 1 AS value",null,&.{&.{"1"}},false);
 try fixture(&.{},"DROP SEQUENCE IF EXISTS missing","SELECT 1 AS value",null,&.{&.{"1"}},true);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"DROP SEQUENCE IF EXISTS s","SELECT 1 AS value",null,&.{&.{"1"}},false);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"DROP SEQUENCE IF EXISTS t","SELECT 1 AS value",error.WrongObjectType,&.{},false);
 try fixture(&.{},"CREATE SEQUENCE if","SELECT 1 AS value",null,&.{&.{"1"}},false);
 try fixture(&.{"CREATE SEQUENCE if"},"DROP SEQUENCE if","SELECT 1 AS value",null,&.{&.{"1"}},false);
 try fixture(&.{"CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)","INSERT INTO t VALUES(1,10)"},"CREATE TABLE t(id INTEGER)","SELECT 1 AS value",error.TableExists,&.{},false);
 try fixture(&.{"CREATE SEQUENCE s START WITH 19 INCREMENT BY 3"},"CREATE SEQUENCE s","SELECT 1 AS value",error.TableExists,&.{},false);
 try fixture(&.{},"CREATE TABLE IF EXISTS t(id INTEGER)","SELECT 1 AS value",error.Syntax,&.{},false);
 try fixture(&.{},"DROP TABLE IF NOT EXISTS t","SELECT 1 AS value",error.Syntax,&.{},false);
 try fixture(&.{"CREATE TABLE t(id INTEGER GENERATED ALWAYS AS IDENTITY)"},"DROP SEQUENCE IF EXISTS t_id_seq","SELECT 1 AS value",error.DependentObjects,&.{},false);
 try fixture(&.{"CREATE TABLE \x22T\x22(id INTEGER)"},"CREATE TABLE IF NOT EXISTS t(id INTEGER)","SELECT COUNT(*) AS value FROM t",null,&.{&.{"0"}},false);
}
