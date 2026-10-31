//! Native PostgreSQL offset-window fixtures: partition/order/frame, NULL, typing and errors.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=2,.columns=16,.rows_per_table=8,.text_bytes=128,.expr_nodes=1024,.work_rows=32,.nulls_first_ascending=false});
var db:DB=.{};var result:DB.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.WindowOffsetContractFailed;}
fn rows(source:[]const u8,expected:[]const [3]?[]const u8) !void {
 db.execute(source,&result) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
 try check(result.row_count==expected.len and result.column_count==2);
 try check(std.mem.eql(u8,result.column_names[1].slice(),"value"));
 for(expected,0..) |wanted,i| {
  try check(result.rows[i].cells[0].integer==try std.fmt.parseInt(i64,wanted[0].?,10));
  const oid:u32=if(std.mem.eql(u8,wanted[2].?,"integer")) 23 else if(std.mem.eql(u8,wanted[2].?,"bigint")) 20 else if(std.mem.eql(u8,wanted[2].?,"text")) 25 else if(std.mem.eql(u8,wanted[2].?,"numeric")) 1700 else if(std.mem.eql(u8,wanted[2].?,"jsonb")) 3802 else if(std.mem.eql(u8,wanted[2].?,"date")) 1082 else if(std.mem.eql(u8,wanted[2].?,"timestamp without time zone")) 1114 else return error.UnknownFixtureType;
  try check(sql.typeOid(result.column_types[1])==oid);
  const cell=&result.rows[i].cells[1];
  if(wanted[1]) |value| {var buffer:[DB.Io.format_bytes]u8=undefined;const got=try DB.Io.format(cell,false,&db.session,&buffer);
   if(!std.mem.eql(u8,got,value)) std.debug.print("{s}: row{d} got{s} want{s}\n",.{source,i,got,value});
   try check(std.mem.eql(u8,got,value));
  } else try check(cell.*==.null_value);
 }
 try check(db.usage().transactions==0 and db.usage().pending_versions==0);
}
fn rejects(source:[]const u8,wanted:anyerror) !void {
 if(db.execute(source,&result)) |_| {std.debug.print("accepted{s}\n",.{source});return error.InvalidSqlAccepted;} else |err| {
  if(err!=wanted) std.debug.print("{s}: got{s} want{s}\n",.{source,@errorName(err),@errorName(wanted)});try check(err==wanted);
 }
 try check(db.usage().transactions==0 and db.usage().pending_versions==0);
}
const Probe=struct {
 control:*sql.ExecutionControl, at:u64,
 fn poll(raw:?*anyopaque) sql.Error!void {const self:*Probe=@ptrCast(@alignCast(raw.?));if(self.control.used>=self.at) return error.QueryCanceled;}
};
fn resources() !void {
 const query="SELECT id,lag(v,1,-9) OVER(PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id";
 var control:sql.ExecutionControl=.{};db.session.control=&control;defer db.session.control=null;
 try db.execute(query,&result);const work=control.used;try check(work>10);
 var limit:u64=1;while(limit<work):(limit+=1) {control.reset(limit);try rejects(query,error.QueryWorkLimit);}
 var probe:Probe=.{.control=&control,.at=1};control.context=&probe;control.poll=Probe.poll;control.poll_interval=1;
 for([_]u64{1,work/2,work}) |boundary| {control.reset(0);probe.at=boundary;try rejects(query,error.QueryCanceled);}
}
fn lazyAndVolatile() !void {
 try db.execute("CREATE TABLE w_null(id INTEGER,g INTEGER)",&result);
 try db.execute("INSERT INTO w_null VALUES(1,NULL),(2,1),(3,NULL),(4,1)",&result);
 try db.execute("CREATE SEQUENCE null_seq",&result);
 try rows("SELECT id,lag(nextval('null_seq'),0) OVER(PARTITION BY g ORDER BY id) AS value FROM w_null ORDER BY id",&.{.{"1","3","bigint"},.{"2","1","bigint"},.{"3","4","bigint"},.{"4","2","bigint"}});
 try rows("SELECT id,lag(nextval('null_seq'),0) OVER(PARTITION BY g ORDER BY id) AS value FROM w_null ORDER BY g NULLS LAST,id LIMIT 1",&.{.{"2","5","bigint"}});
 try rejects("SELECT id,lag(nextval('null_seq'),0) OVER(PARTITION BY g ORDER BY id) AS value FROM w_null ORDER BY g NULLS FIRST,id LIMIT 1",error.UnsupportedStatement);
 try db.execute("CREATE SEQUENCE value_seq",&result);try db.execute("CREATE SEQUENCE default_seq",&result);
 try rows("SELECT id,lag(nextval('value_seq')*100+id,o,nextval('default_seq')*1000+id) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","1001","bigint"},.{"2","102","bigint"},.{"3","204","bigint"},.{"4",null,"bigint"},.{"5","2005","bigint"},.{"6","3006","bigint"}});
 try rows("SELECT currval('value_seq') AS id,currval('default_seq') AS value",&.{.{"2","3","bigint"}});
 try rows("SELECT id,lag(v,0,100/(id-id)) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","30","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
 try rows("SELECT id,lag(100/(id-6)) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2","-20","integer"},.{"3","-25","integer"},.{"4","-33","integer"},.{"5","-50","integer"},.{"6","-100","integer"}});
 try rejects("SELECT * FROM (SELECT lag(nextval('value_seq'),0) OVER(ORDER BY id) AS v FROM w) q LIMIT 1",error.UnsupportedStatement);
 try rejects("WITH q AS (SELECT lag(nextval('value_seq'),0) OVER(ORDER BY id) AS v FROM w) SELECT * FROM q LIMIT 1",error.UnsupportedStatement);
 try db.execute("SELECT lag(nextval('value_seq'),0) OVER(ORDER BY id) FROM w LIMIT 1",&result);
 try check(result.row_count==1 and result.rows[0].cells[0].integer==3);
 try rows("SELECT currval('value_seq') AS id,currval('default_seq') AS value",&.{.{"3","3","bigint"}});
 try rows("SELECT id,lag(10/(id-6),0) OVER(ORDER BY id) AS value FROM w LIMIT 1",&.{.{"1","-2","integer"}});
 try rows("SELECT id,lag(10/(id-6),0) OVER(ORDER BY id) AS value FROM w ORDER BY id LIMIT 1",&.{.{"1","-2","integer"}});
 try rows("SELECT id,lead(10/(id-1)) OVER(ORDER BY id DESC) AS value FROM w ORDER BY id DESC LIMIT 2 OFFSET 1",&.{.{"5","3","integer"},.{"4","5","integer"}});
 try rows("SELECT id,lag(10/(id-6),0) OVER(PARTITION BY g ORDER BY id) AS value FROM w ORDER BY g,id LIMIT 2 OFFSET 1",&.{.{"2","-2","integer"},.{"3","-3","integer"}});
 try rejects("SELECT * FROM (SELECT lag(10/(id-6),0) OVER(ORDER BY id) AS v FROM w) q LIMIT 1",error.UnsupportedStatement);
 try rejects("SELECT lag(nextval('value_seq')) OVER(ORDER BY id),lead(v) OVER(ORDER BY id) FROM w",error.UnsupportedStatement);
 try rejects("SELECT nextval('value_seq'),lag(nextval('value_seq')) OVER(ORDER BY id) FROM w",error.UnsupportedStatement);
}
const Small=sql.Database(.{.tables=1,.columns=4,.rows_per_table=2,.work_rows=32});var small:Small=.{};var small_result:Small.Result=.{};
fn capacity() !void {
 try small.execute("CREATE TABLE t(id INTEGER,v INTEGER)",&small_result);
 try small.execute("INSERT INTO t VALUES(1,1),(2,2)",&small_result);
 // Four outputs need five internal cells; that is legal (2*columns targets).
 try small.execute("SELECT id,lag(v) OVER(ORDER BY id),lead(v) OVER(ORDER BY id),rank() OVER(ORDER BY id) FROM t",&small_result);
 try check(small_result.column_count==4 and small_result.row_count==2);
 try check(small_result.rows[0].cells[1]==.null_value and small_result.rows[1].cells[1].integer==1);
 try check(small_result.rows[0].cells[2].integer==2 and small_result.rows[1].cells[2]==.null_value);
 try check(small.usage().transactions==0);
}
pub fn main() !void {
 try db.execute("CREATE TABLE w(id INTEGER PRIMARY KEY,g INTEGER,v INTEGER,o INTEGER)",&result);
 try db.execute("INSERT INTO w VALUES(1,1,10,1),(2,1,NULL,0),(3,1,30,-1),(4,2,40,NULL),(5,2,50,99),(6,2,60,-2147483648)",&result);
    try rows("SELECT id,lag(v) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5","40","integer"},.{"6","50","integer"}});
    try rows("SELECT id,lag(v) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","30","integer"},.{"3","40","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lag(v,0) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","30","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
    try rows("SELECT id,lag(v,0) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","30","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
    try rows("SELECT id,lag(v,1) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5","40","integer"},.{"6","50","integer"}});
    try rows("SELECT id,lag(v,1) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","30","integer"},.{"3","40","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lag(v,-1) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","30","integer"},.{"3",null,"integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lag(v,-1) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4","30","integer"},.{"5","40","integer"},.{"6","50","integer"}});
    try rows("SELECT id,lag(v,2,-99) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","-99","integer"},.{"2","-99","integer"},.{"3","10","integer"},.{"4","-99","integer"},.{"5","-99","integer"},.{"6","40","integer"}});
    try rows("SELECT id,lag(v,2,-99) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","30","integer"},.{"2","40","integer"},.{"3","50","integer"},.{"4","60","integer"},.{"5","-99","integer"},.{"6","-99","integer"}});
    try rows("SELECT id,lag(v,-2,-99) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","30","integer"},.{"2","-99","integer"},.{"3","-99","integer"},.{"4","60","integer"},.{"5","-99","integer"},.{"6","-99","integer"}});
    try rows("SELECT id,lag(v,-2,-99) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","-99","integer"},.{"2","-99","integer"},.{"3","10","integer"},.{"4",null,"integer"},.{"5","30","integer"},.{"6","40","integer"}});
    try rows("SELECT id,lag(v,99,0) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","0","integer"},.{"2","0","integer"},.{"3","0","integer"},.{"4","0","integer"},.{"5","0","integer"},.{"6","0","integer"}});
    try rows("SELECT id,lag(v,99,0) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","0","integer"},.{"2","0","integer"},.{"3","0","integer"},.{"4","0","integer"},.{"5","0","integer"},.{"6","0","integer"}});
    try rows("SELECT id,lag(v,-99,0) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","0","integer"},.{"2","0","integer"},.{"3","0","integer"},.{"4","0","integer"},.{"5","0","integer"},.{"6","0","integer"}});
    try rows("SELECT id,lag(v,-99,0) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","0","integer"},.{"2","0","integer"},.{"3","0","integer"},.{"4","0","integer"},.{"5","0","integer"},.{"6","0","integer"}});
    try rows("SELECT id,lag(v,NULL,9) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lag(v,NULL,9) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lag(v,o,id*100) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","100","integer"},.{"2",null,"integer"},.{"3","300","integer"},.{"4",null,"integer"},.{"5","500","integer"},.{"6","600","integer"}});
    try rows("SELECT id,lag(v,o,id*100) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5","500","integer"},.{"6","600","integer"}});
    try rows("SELECT id,lag(v,2147483647,7) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","7","integer"},.{"2","7","integer"},.{"3","7","integer"},.{"4","7","integer"},.{"5","7","integer"},.{"6","7","integer"}});
    try rows("SELECT id,lag(v,2147483647,7) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","7","integer"},.{"2","7","integer"},.{"3","7","integer"},.{"4","7","integer"},.{"5","7","integer"},.{"6","7","integer"}});
    try rows("SELECT id,lag(v,-2147483648,7) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","7","integer"},.{"2","7","integer"},.{"3","7","integer"},.{"4","7","integer"},.{"5","7","integer"},.{"6","7","integer"}});
    try rows("SELECT id,lag(v,-2147483648,7) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","7","integer"},.{"2","7","integer"},.{"3","7","integer"},.{"4","7","integer"},.{"5","7","integer"},.{"6","7","integer"}});
    try rows("SELECT id,lag(id::text,1,'outside') OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","outside","text"},.{"2","1","text"},.{"3","2","text"},.{"4","outside","text"},.{"5","4","text"},.{"6","5","text"}});
    try rows("SELECT id,lag(id::text,1,'outside') OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","2","text"},.{"2","3","text"},.{"3","4","text"},.{"4","5","text"},.{"5","6","text"},.{"6","outside","text"}});
    try rows("SELECT id,lag(v::numeric,1,2.50) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","2.50","numeric"},.{"2","10","numeric"},.{"3",null,"numeric"},.{"4","2.50","numeric"},.{"5","40","numeric"},.{"6","50","numeric"}});
    try rows("SELECT id,lag(v::numeric,1,2.50) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"numeric"},.{"2","30","numeric"},.{"3","40","numeric"},.{"4","50","numeric"},.{"5","60","numeric"},.{"6","2.50","numeric"}});
    try rows("SELECT id,lag(NULL,1,NULL) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"text"},.{"2",null,"text"},.{"3",null,"text"},.{"4",null,"text"},.{"5",null,"text"},.{"6",null,"text"}});
    try rows("SELECT id,lag(NULL,1,NULL) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"text"},.{"2",null,"text"},.{"3",null,"text"},.{"4",null,"text"},.{"5",null,"text"},.{"6",null,"text"}});
    try rows("SELECT id,lag(NULL,1,'outside') OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","outside","text"},.{"2",null,"text"},.{"3",null,"text"},.{"4","outside","text"},.{"5",null,"text"},.{"6",null,"text"}});
    try rows("SELECT id,lag(NULL,1,'outside') OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"text"},.{"2",null,"text"},.{"3",null,"text"},.{"4",null,"text"},.{"5",null,"text"},.{"6","outside","text"}});
    try rows("SELECT id,lag('{\x22a\x22:1}'::jsonb,1,'{}') OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","{}","jsonb"},.{"2","{\x22a\x22: 1}","jsonb"},.{"3","{\x22a\x22: 1}","jsonb"},.{"4","{}","jsonb"},.{"5","{\x22a\x22: 1}","jsonb"},.{"6","{\x22a\x22: 1}","jsonb"}});
    try rows("SELECT id,lag('{\x22a\x22:1}'::jsonb,1,'{}') OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","{\x22a\x22: 1}","jsonb"},.{"2","{\x22a\x22: 1}","jsonb"},.{"3","{\x22a\x22: 1}","jsonb"},.{"4","{\x22a\x22: 1}","jsonb"},.{"5","{\x22a\x22: 1}","jsonb"},.{"6","{}","jsonb"}});
    try rows("SELECT id,lag(v,1::smallint,99) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","99","integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4","99","integer"},.{"5","40","integer"},.{"6","50","integer"}});
    try rows("SELECT id,lag(v,1::smallint,99) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","30","integer"},.{"3","40","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6","99","integer"}});
    try rejects("SELECT id,lag() OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lag(v,1,2,3) OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lag(v,1::bigint) OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lag(v,1.5) OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lag(v,true) OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lag(v,0,1/0) OVER () AS value FROM w ORDER BY id", error.DivisionByZero);
    try rejects("SELECT id,lag(v) OVER (ORDER BY id ROWS BETWEEN -1 PRECEDING AND CURRENT ROW) AS value FROM w ORDER BY id", error.InvalidWindowFrameOffset);
    try rejects("SELECT id,lag(v) OVER (ORDER BY id ROWS BETWEEN NULL PRECEDING AND CURRENT ROW) AS value FROM w ORDER BY id", error.NullWindowFrameOffset);
    try rejects("SELECT id,lag(v) FILTER (WHERE true) OVER () AS value FROM w ORDER BY id", error.UnsupportedStatement);
    try rows("SELECT id,lead(v) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","30","integer"},.{"3",null,"integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lead(v) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4","30","integer"},.{"5","40","integer"},.{"6","50","integer"}});
    try rows("SELECT id,lead(v,0) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","30","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
    try rows("SELECT id,lead(v,0) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","30","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
    try rows("SELECT id,lead(v,1) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","30","integer"},.{"3",null,"integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lead(v,1) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4","30","integer"},.{"5","40","integer"},.{"6","50","integer"}});
    try rows("SELECT id,lead(v,-1) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5","40","integer"},.{"6","50","integer"}});
    try rows("SELECT id,lead(v,-1) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","30","integer"},.{"3","40","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lead(v,2,-99) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","30","integer"},.{"2","-99","integer"},.{"3","-99","integer"},.{"4","60","integer"},.{"5","-99","integer"},.{"6","-99","integer"}});
    try rows("SELECT id,lead(v,2,-99) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","-99","integer"},.{"2","-99","integer"},.{"3","10","integer"},.{"4",null,"integer"},.{"5","30","integer"},.{"6","40","integer"}});
    try rows("SELECT id,lead(v,-2,-99) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","-99","integer"},.{"2","-99","integer"},.{"3","10","integer"},.{"4","-99","integer"},.{"5","-99","integer"},.{"6","40","integer"}});
    try rows("SELECT id,lead(v,-2,-99) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","30","integer"},.{"2","40","integer"},.{"3","50","integer"},.{"4","60","integer"},.{"5","-99","integer"},.{"6","-99","integer"}});
    try rows("SELECT id,lead(v,99,0) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","0","integer"},.{"2","0","integer"},.{"3","0","integer"},.{"4","0","integer"},.{"5","0","integer"},.{"6","0","integer"}});
    try rows("SELECT id,lead(v,99,0) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","0","integer"},.{"2","0","integer"},.{"3","0","integer"},.{"4","0","integer"},.{"5","0","integer"},.{"6","0","integer"}});
    try rows("SELECT id,lead(v,-99,0) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","0","integer"},.{"2","0","integer"},.{"3","0","integer"},.{"4","0","integer"},.{"5","0","integer"},.{"6","0","integer"}});
    try rows("SELECT id,lead(v,-99,0) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","0","integer"},.{"2","0","integer"},.{"3","0","integer"},.{"4","0","integer"},.{"5","0","integer"},.{"6","0","integer"}});
    try rows("SELECT id,lead(v,NULL,9) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lead(v,NULL,9) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
    try rows("SELECT id,lead(v,o,id*100) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5","500","integer"},.{"6","600","integer"}});
    try rows("SELECT id,lead(v,o,id*100) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","100","integer"},.{"2",null,"integer"},.{"3","40","integer"},.{"4",null,"integer"},.{"5","500","integer"},.{"6","600","integer"}});
    try rows("SELECT id,lead(v,2147483647,7) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","7","integer"},.{"2","7","integer"},.{"3","7","integer"},.{"4","7","integer"},.{"5","7","integer"},.{"6","7","integer"}});
    try rows("SELECT id,lead(v,2147483647,7) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","7","integer"},.{"2","7","integer"},.{"3","7","integer"},.{"4","7","integer"},.{"5","7","integer"},.{"6","7","integer"}});
    try rows("SELECT id,lead(v,-2147483648,7) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","7","integer"},.{"2","7","integer"},.{"3","7","integer"},.{"4","7","integer"},.{"5","7","integer"},.{"6","7","integer"}});
    try rows("SELECT id,lead(v,-2147483648,7) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","7","integer"},.{"2","7","integer"},.{"3","7","integer"},.{"4","7","integer"},.{"5","7","integer"},.{"6","7","integer"}});
    try rows("SELECT id,lead(id::text,1,'outside') OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","2","text"},.{"2","3","text"},.{"3","outside","text"},.{"4","5","text"},.{"5","6","text"},.{"6","outside","text"}});
    try rows("SELECT id,lead(id::text,1,'outside') OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","outside","text"},.{"2","1","text"},.{"3","2","text"},.{"4","3","text"},.{"5","4","text"},.{"6","5","text"}});
    try rows("SELECT id,lead(v::numeric,1,2.50) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"numeric"},.{"2","30","numeric"},.{"3","2.50","numeric"},.{"4","50","numeric"},.{"5","60","numeric"},.{"6","2.50","numeric"}});
    try rows("SELECT id,lead(v::numeric,1,2.50) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","2.50","numeric"},.{"2","10","numeric"},.{"3",null,"numeric"},.{"4","30","numeric"},.{"5","40","numeric"},.{"6","50","numeric"}});
    try rows("SELECT id,lead(NULL,1,NULL) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"text"},.{"2",null,"text"},.{"3",null,"text"},.{"4",null,"text"},.{"5",null,"text"},.{"6",null,"text"}});
    try rows("SELECT id,lead(NULL,1,NULL) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1",null,"text"},.{"2",null,"text"},.{"3",null,"text"},.{"4",null,"text"},.{"5",null,"text"},.{"6",null,"text"}});
    try rows("SELECT id,lead(NULL,1,'outside') OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"text"},.{"2",null,"text"},.{"3","outside","text"},.{"4",null,"text"},.{"5",null,"text"},.{"6","outside","text"}});
    try rows("SELECT id,lead(NULL,1,'outside') OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","outside","text"},.{"2",null,"text"},.{"3",null,"text"},.{"4",null,"text"},.{"5",null,"text"},.{"6",null,"text"}});
    try rows("SELECT id,lead('{\x22a\x22:1}'::jsonb,1,'{}') OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1","{\x22a\x22: 1}","jsonb"},.{"2","{\x22a\x22: 1}","jsonb"},.{"3","{}","jsonb"},.{"4","{\x22a\x22: 1}","jsonb"},.{"5","{\x22a\x22: 1}","jsonb"},.{"6","{}","jsonb"}});
    try rows("SELECT id,lead('{\x22a\x22:1}'::jsonb,1,'{}') OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","{}","jsonb"},.{"2","{\x22a\x22: 1}","jsonb"},.{"3","{\x22a\x22: 1}","jsonb"},.{"4","{\x22a\x22: 1}","jsonb"},.{"5","{\x22a\x22: 1}","jsonb"},.{"6","{\x22a\x22: 1}","jsonb"}});
    try rows("SELECT id,lead(v,1::smallint,99) OVER (PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id", &.{.{"1",null,"integer"},.{"2","30","integer"},.{"3","99","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6","99","integer"}});
    try rows("SELECT id,lead(v,1::smallint,99) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS value FROM w ORDER BY id", &.{.{"1","99","integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4","30","integer"},.{"5","40","integer"},.{"6","50","integer"}});
    try rejects("SELECT id,lead() OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lead(v,1,2,3) OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lead(v,1::bigint) OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lead(v,1.5) OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lead(v,true) OVER () AS value FROM w ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,lead(v,0,1/0) OVER () AS value FROM w ORDER BY id", error.DivisionByZero);
    try rejects("SELECT id,lead(v) OVER (ORDER BY id ROWS BETWEEN -1 PRECEDING AND CURRENT ROW) AS value FROM w ORDER BY id", error.InvalidWindowFrameOffset);
    try rejects("SELECT id,lead(v) OVER (ORDER BY id ROWS BETWEEN NULL PRECEDING AND CURRENT ROW) AS value FROM w ORDER BY id", error.NullWindowFrameOffset);
    try rejects("SELECT id,lead(v) FILTER (WHERE true) OVER () AS value FROM w ORDER BY id", error.UnsupportedStatement);
 try rejects("SELECT lag(1)",error.WrongObjectType);
 try rejects("SELECT lead(1)",error.WrongObjectType);
 try rejects("SELECT lag()",error.UndefinedFunction);
 try rejects("SELECT lead(1,1::bigint)",error.UndefinedFunction);
 try rejects("SELECT lag(1,1,false) OVER()",error.UndefinedFunction);
 try rejects("SELECT lead(1,1,false) OVER()",error.UndefinedFunction);
 try rejects("SELECT lag(1,0,'bad') OVER()",error.InvalidTextRepresentation);
 try rows("SELECT g AS id,lag(sum(v)) OVER(ORDER BY g) AS value FROM w GROUP BY g ORDER BY g",&.{.{"1",null,"bigint"},.{"2","40","bigint"}});
 try rows("SELECT id,lag(DATE '2000-01-01'+id,1,DATE '1999-01-01') OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","1999-01-01","date"},.{"2","2000-01-02","date"},.{"3","2000-01-03","date"},.{"4","2000-01-04","date"},.{"5","2000-01-05","date"},.{"6","2000-01-06","date"}});
 try rows("SELECT id,lag(DATE '2000-01-01'+id,1,TIMESTAMP '1999-01-01') OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","1999-01-01 00:00:00","timestamp without time zone"},.{"2","2000-01-02 00:00:00","timestamp without time zone"},.{"3","2000-01-03 00:00:00","timestamp without time zone"},.{"4","2000-01-04 00:00:00","timestamp without time zone"},.{"5","2000-01-05 00:00:00","timestamp without time zone"},.{"6","2000-01-06 00:00:00","timestamp without time zone"}});
 try lazyAndVolatile();try resources();try capacity();
 std.debug.print("{{\"suite\":\"window-offsets\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
