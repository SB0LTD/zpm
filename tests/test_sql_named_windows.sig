//! Native PostgreSQL distribution-window fixtures: partition/order/frame, NULL, typing and errors.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=2,.columns=16,.rows_per_table=16,.text_bytes=128,.expr_nodes=1024,.work_rows=64,.nulls_first_ascending=false});
var db:DB=.{};var result:DB.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.NamedWindowContractFailed;}
fn rows(source:[]const u8,expected:[]const [3]?[]const u8) !void {
 db.execute(source,&result) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
 try check(result.row_count==expected.len and result.column_count==2);
 try check(std.mem.eql(u8,result.column_names[1].slice(),"value"));
 for(expected,0..) |wanted,i| {
  try check(result.rows[i].cells[0].integer==try std.fmt.parseInt(i64,wanted[0].?,10));
  const oid:u32=if(std.mem.eql(u8,wanted[2].?,"integer")) 23 else if(std.mem.eql(u8,wanted[2].?,"bigint")) 20 else if(std.mem.eql(u8,wanted[2].?,"text")) 25 else if(std.mem.eql(u8,wanted[2].?,"numeric")) 1700 else if(std.mem.eql(u8,wanted[2].?,"jsonb")) 3802 else if(std.mem.eql(u8,wanted[2].?,"date")) 1082 else if(std.mem.eql(u8,wanted[2].?,"timestamp without time zone")) 1114 else if(std.mem.eql(u8,wanted[2].?,"double precision")) 701 else return error.UnknownFixtureType;
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
fn equivalent(inline_sql:[]const u8,named_sql:[]const u8) !void {
 const Saved=struct{id:i64,is_null:bool,bytes:[128]u8=undefined,len:usize=0};
 var saved:[8]Saved=undefined;var buffer:[DB.Io.format_bytes]u8=undefined;
 try db.execute(inline_sql,&result);const count=result.row_count;const ty=result.column_types[1];try check(count<=saved.len);
 for(0..count) |i| {const cell=&result.rows[i].cells[1];saved[i]=.{.id=result.rows[i].cells[0].integer,.is_null=cell.*==.null_value};
  if(!saved[i].is_null){const text=try DB.Io.format(cell,false,&db.session,&buffer);@memcpy(saved[i].bytes[0..text.len],text);saved[i].len=text.len;}
 }
 try db.execute(named_sql,&result);try check(result.row_count==count and result.column_types[1]==ty);
 for(0..count) |i| {try check(result.rows[i].cells[0].integer==saved[i].id);const cell=&result.rows[i].cells[1];try check((cell.*==.null_value)==saved[i].is_null);
  if(!saved[i].is_null) try check(std.mem.eql(u8,try DB.Io.format(cell,false,&db.session,&buffer),saved[i].bytes[0..saved[i].len]));
 }
}
fn properties() !void {
 try db.execute("CREATE TABLE aux(id INTEGER PRIMARY KEY,g INTEGER,v INTEGER)",&result);
 try db.execute("INSERT INTO aux VALUES(1,1,10),(2,1,10),(3,1,10),(4,1,NULL),(5,2,20),(6,2,20),(7,NULL,NULL),(8,NULL,NULL)",&result);
 var inline_buffer:[512]u8=undefined;var named_buffer:[512]u8=undefined;
 for([_] []const u8{"COUNT(v)","SUM(v)","AVG(v)","MIN(v)","MAX(v)","BOOL_AND(id>2)","BOOL_OR(id<3)"}) |function|
 for([_] []const u8{"ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING","ROWS UNBOUNDED PRECEDING","ROWS CURRENT ROW EXCLUDE CURRENT ROW","GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES","GROUPS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP","RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING","RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING EXCLUDE TIES"}) |frame| {
  const inline_sql=try std.fmt.bufPrint(&inline_buffer,"SELECT id,{s} OVER(PARTITION BY g ORDER BY v {s}) AS value FROM aux ORDER BY id",.{function,frame});
  const named_sql=try std.fmt.bufPrint(&named_buffer,"SELECT id,{s} OVER c AS value FROM aux WINDOW a AS(PARTITION BY g),b AS(a ORDER BY v),c AS(b {s}) ORDER BY id",.{function,frame});
  try equivalent(inline_sql,named_sql);
 };
}
fn cancel(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
fn resources() !void {
 const query="SELECT id,sum(v) OVER z AS value FROM w WINDOW x AS(PARTITION BY g),y AS(x ORDER BY id),z AS(y ROWS 1 PRECEDING) ORDER BY id";
 var control:sql.ExecutionControl=.{};db.session.control=&control;defer db.session.control=null;
 try db.execute(query,&result);const work=control.used;try check(work>10);
 var limit:u64=1;while(limit<work):(limit+=1){control.reset(limit);try rejects(query,error.QueryWorkLimit);}
 control.reset(0);control.poll=cancel;try rejects(query,error.QueryCanceled);
}
const Small=sql.Database(.{.tables=1,.columns=4,.rows_per_table=2,.expr_nodes=32,.subqueries=4,.work_rows=32});
var small:Small=.{};var small_result:Small.Result=.{};
fn capacities() !void {
 var source:[2048]u8=undefined;var at:usize=0;
 const head="SELECT 1 WINDOW ";@memcpy(source[0..head.len],head);at=head.len;
 for(0..17) |i| {const text=try std.fmt.bufPrint(source[at..],"w{d} AS(){s}",.{i,if(i==16) "" else ","});at+=text.len;}
 if(small.execute(source[0..at],&small_result)) |_| return error.CapacityNotEnforced else |err| try check(err==error.StatementTooComplex);
 try check(small.usage().transactions==0 and small.usage().pending_versions==0);
 try small.execute("SELECT 1",&small_result);try check(small_result.row_count==1);
}
pub fn main() !void {
 try db.execute("CREATE TABLE w(id INTEGER PRIMARY KEY,g INTEGER,v INTEGER)",&result);
 try db.execute("INSERT INTO w VALUES(1,1,10),(2,1,NULL),(3,1,30),(4,2,40),(5,2,50),(6,NULL,60)",&result);
    try rows("SELECT id,sum(v) OVER x AS value FROM w WINDOW x AS(ORDER BY id) ORDER BY id", &.{.{"1","10","bigint"},.{"2","10","bigint"},.{"3","40","bigint"},.{"4","80","bigint"},.{"5","130","bigint"},.{"6","190","bigint"}});
    try rows("SELECT id,sum(v) OVER x AS value FROM w WINDOW x AS(PARTITION BY g ORDER BY id ROWS 1 PRECEDING) ORDER BY id", &.{.{"1","10","bigint"},.{"2","10","bigint"},.{"3","30","bigint"},.{"4","40","bigint"},.{"5","90","bigint"},.{"6","60","bigint"}});
    try rows("SELECT id,lag(v) OVER x AS value FROM w WINDOW x AS(PARTITION BY g ORDER BY id ROWS CURRENT ROW) ORDER BY id", &.{.{"1",null,"integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5","40","integer"},.{"6",null,"integer"}});
    try rows("SELECT id,cume_dist() OVER x AS value FROM w WINDOW x AS(PARTITION BY g ORDER BY v) ORDER BY id", &.{.{"1","0.3333333333333333","double precision"},.{"2","1","double precision"},.{"3","0.6666666666666666","double precision"},.{"4","0.5","double precision"},.{"5","1","double precision"},.{"6","1","double precision"}});
    try rows("SELECT id,ntile(2) OVER x AS value FROM w WINDOW x AS(PARTITION BY g ORDER BY id) ORDER BY id", &.{.{"1","1","integer"},.{"2","1","integer"},.{"3","2","integer"},.{"4","1","integer"},.{"5","2","integer"},.{"6","1","integer"}});
    try rows("SELECT id,sum(v) OVER (x ORDER BY id) AS value FROM w WINDOW x AS(PARTITION BY g) ORDER BY id", &.{.{"1","10","bigint"},.{"2","10","bigint"},.{"3","40","bigint"},.{"4","40","bigint"},.{"5","90","bigint"},.{"6","60","bigint"}});
    try rows("SELECT id,sum(v) OVER (x ROWS 1 PRECEDING) AS value FROM w WINDOW x AS(ORDER BY id) ORDER BY id", &.{.{"1","10","bigint"},.{"2","10","bigint"},.{"3","30","bigint"},.{"4","70","bigint"},.{"5","90","bigint"},.{"6","110","bigint"}});
    try rows("SELECT id,sum(v) OVER z AS value FROM w WINDOW x AS(PARTITION BY g),y AS(x ORDER BY id),z AS(y ROWS 1 PRECEDING) ORDER BY id", &.{.{"1","10","bigint"},.{"2","10","bigint"},.{"3","30","bigint"},.{"4","40","bigint"},.{"5","90","bigint"},.{"6","60","bigint"}});
    try rows("SELECT id,sum(v) OVER (x) AS value FROM w WINDOW x AS(ORDER BY id) ORDER BY id", &.{.{"1","10","bigint"},.{"2","10","bigint"},.{"3","40","bigint"},.{"4","80","bigint"},.{"5","130","bigint"},.{"6","190","bigint"}});
    try rows("SELECT id,sum(v) OVER x AS value FROM w WINDOW x AS(ROWS UNBOUNDED PRECEDING) ORDER BY id", &.{.{"1","10","bigint"},.{"2","10","bigint"},.{"3","40","bigint"},.{"4","80","bigint"},.{"5","130","bigint"},.{"6","190","bigint"}});
    try rejects("SELECT id,sum(v) OVER (x) AS value FROM w WINDOW x AS(ROWS UNBOUNDED PRECEDING) ORDER BY id", error.WindowingError);
    try rejects("SELECT id,sum(v) OVER (x PARTITION BY g) AS value FROM w WINDOW x AS() ORDER BY id", error.WindowingError);
    try rejects("SELECT id,sum(v) OVER (x ORDER BY id) AS value FROM w WINDOW x AS(ORDER BY v) ORDER BY id", error.WindowingError);
    try rejects("SELECT id,sum(v) OVER missing AS value FROM w WINDOW x AS() ORDER BY id", error.UndefinedObject);
    try rejects("SELECT id,sum(v) OVER x AS value FROM w WINDOW x AS(y),y AS() ORDER BY id", error.UndefinedObject);
    try rejects("SELECT id,sum(v) OVER x AS value FROM w WINDOW x AS(x) ORDER BY id", error.UndefinedObject);
    try rejects("SELECT id,sum(v) OVER x AS value FROM w WINDOW x AS(),x AS() ORDER BY id", error.WindowingError);
    try rejects("SELECT id,sum(v) OVER z AS value FROM w WINDOW x AS(ORDER BY id RANGE UNBOUNDED PRECEDING),z AS(x) ORDER BY id", error.WindowingError);
    try rows("SELECT id,sum(v) OVER \x22X\x22 AS value FROM w WINDOW \x22X\x22 AS(ORDER BY id) ORDER BY id", &.{.{"1","10","bigint"},.{"2","10","bigint"},.{"3","40","bigint"},.{"4","80","bigint"},.{"5","130","bigint"},.{"6","190","bigint"}});
    try rejects("SELECT id,sum(v) OVER \x22X\x22 AS value FROM w WINDOW x AS(ORDER BY id) ORDER BY id", error.UndefinedObject);
    try rows("SELECT id,sum(v) OVER x AS value FROM w WINDOW x AS(ORDER BY id GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW) ORDER BY id", &.{.{"1",null,"bigint"},.{"2","40","bigint"},.{"3","40","bigint"},.{"4","80","bigint"},.{"5","100","bigint"},.{"6","50","bigint"}});
    try rejects("SELECT 1 AS id,1 AS value FROM w WINDOW x AS(ORDER BY nonexistent)", error.ColumnNotFound);
    try rows("SELECT 1 AS id,1 AS value FROM w WINDOW x AS(ORDER BY sum(v))", &.{.{"1","1","integer"}});
    try rejects("SELECT 1 AS id,count(*) AS value FROM w WINDOW x AS(ORDER BY v)", error.GroupingError);
    try rejects("SELECT id,(SELECT sum(v) OVER x FROM w) AS value FROM w WINDOW x AS() ORDER BY id", error.UndefinedObject);
    try rejects("SELECT id,sum(v) OVER x AS value FROM w WHERE FALSE WINDOW x AS(ROWS -1 PRECEDING)", error.InvalidWindowFrameOffset);
    try rejects("SELECT id,sum(v) OVER x AS value FROM w WINDOW x AS(ROWS (1/0) PRECEDING) LIMIT 0", error.DivisionByZero);
 try db.execute("CREATE SEQUENCE named_seq",&result);
 try rows("SELECT id,sum(nextval('named_seq')) OVER n AS value FROM w WINDOW n AS(ORDER BY id DESC ROWS UNBOUNDED PRECEDING) ORDER BY id",&.{.{"1","21","numeric"},.{"2","15","numeric"},.{"3","10","numeric"},.{"4","6","numeric"},.{"5","3","numeric"},.{"6","1","numeric"}});
 try rejects("SELECT sum(nextval('named_seq')) OVER n FROM w WINDOW n AS(ORDER BY id) LIMIT 1",error.UnsupportedStatement);
 try rejects("SELECT sum(nextval('named_seq')) OVER n,sum(nextval('named_seq')) OVER n FROM w WINDOW n AS()",error.UnsupportedStatement);
 try db.execute("CREATE SEQUENCE unused_seq",&result);
 try rows("SELECT 1 AS id,1 AS value FROM w WINDOW n AS(ORDER BY sum(nextval('unused_seq')))",&.{.{"1","1","integer"}});
 try rows("SELECT 1 AS id,currval('unused_seq') AS value",&.{.{"1","6","bigint"}});
 try rows("WITH z AS(SELECT id,v,sum(v) OVER n AS s FROM w WINDOW n AS(ORDER BY id)) SELECT id,lag(s) OVER n AS value FROM z WINDOW n AS(ORDER BY id DESC) ORDER BY id",&.{.{"1","10","bigint"},.{"2","40","bigint"},.{"3","80","bigint"},.{"4","130","bigint"},.{"5","190","bigint"},.{"6",null,"bigint"}});
 try rejects("SELECT 1 WINDOW n AS(ORDER BY 1/0)",error.DivisionByZero);
 try rejects("SELECT 1 WINDOW n AS(ROWS (1/0) PRECEDING)",error.DivisionByZero);
 try properties();try resources();try capacities();
 try db.execute("CREATE SEQUENCE key_seq",&result);
 try rows("SELECT id,rank() OVER n*10+row_number() OVER n AS value FROM w WINDOW n AS(ORDER BY nextval('key_seq')) ORDER BY id",&.{.{"1","11","bigint"},.{"2","22","bigint"},.{"3","33","bigint"},.{"4","44","bigint"},.{"5","55","bigint"},.{"6","66","bigint"}});
 try rows("SELECT 1 AS id,currval('key_seq') AS value",&.{.{"1","6","bigint"}});
 try db.execute("CREATE SEQUENCE scalar_key_seq",&result);
 try db.execute("SELECT id,rank() OVER n*10+row_number() OVER n AS value FROM w WINDOW n AS(ORDER BY (SELECT nextval('scalar_key_seq'))) ORDER BY id",&result);
 try check(result.row_count==6);var total:i64=0;for(0..6) |i| {total+=result.rows[i].cells[1].integer;}try check(total==81);
 try rows("SELECT 1 AS id,currval('scalar_key_seq') AS value",&.{.{"1","1","bigint"}});
 try db.execute("CREATE SEQUENCE correlated_key_seq",&result);
 try db.execute("SELECT id,rank() OVER n*10+row_number() OVER n AS value FROM w WINDOW n AS(ORDER BY (SELECT nextval('correlated_key_seq')+w.id)) ORDER BY id",&result);
 try check(result.row_count==6);total=0;for(0..6) |i| {total+=result.rows[i].cells[1].integer;}try check(total==231);
 try rows("SELECT 1 AS id,currval('correlated_key_seq') AS value",&.{.{"1","6","bigint"}});
 try rows("SELECT id,count(v) OVER n*1000+sum(v) OVER n AS value FROM w WINDOW n AS(ORDER BY id ROWS (SELECT 1 UNION SELECT 1) PRECEDING) ORDER BY id",&.{.{"1","1010","bigint"},.{"2","1010","bigint"},.{"3","1030","bigint"},.{"4","2070","bigint"},.{"5","2090","bigint"},.{"6","2110","bigint"}});
 std.debug.print("{{\"suite\":\"named-windows\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
