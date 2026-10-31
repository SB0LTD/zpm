//! Native PostgreSQL distribution-window fixtures: partition/order/frame, NULL, typing and errors.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=2,.columns=16,.rows_per_table=16,.text_bytes=128,.expr_nodes=1024,.work_rows=64,.nulls_first_ascending=false});
var db:DB=.{};var result:DB.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.WindowOffsetContractFailed;}
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
fn properties() !void {
 var query:[256]u8=undefined;
 for(1..10) |n| for(1..26) |k| {
  const source=try std.fmt.bufPrint(&query,"SELECT id,ntile({d}) OVER(ORDER BY id) AS value FROM r WHERE id<={d} ORDER BY id",.{k,n});
  try db.execute(source,&result);try check(result.row_count==n and sql.typeOid(result.column_types[1])==23);
  const small=n/k;const extra=n%k;const wide=(small+1)*extra;
  for(0..n) |i| {const wanted=if(i<wide) i/(small+1)+1 else extra+(i-wide)/small+1;
   try check(result.rows[i].cells[1].integer==wanted);
  }
 };
}
fn cancel(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
fn resources() !void {
 const query="SELECT id,cume_dist() OVER(PARTITION BY g ORDER BY v) AS value FROM r ORDER BY id";
 var control:sql.ExecutionControl=.{};db.session.control=&control;defer db.session.control=null;
 try db.execute(query,&result);const work=control.used;try check(work>10);
 var limit:u64=1;while(limit<work):(limit+=1){control.reset(limit);try rejects(query,error.QueryWorkLimit);}
 control.reset(0);control.poll=cancel;try rejects(query,error.QueryCanceled);
}
pub fn main() !void {
 try db.execute("CREATE TABLE r(id INTEGER PRIMARY KEY,g INTEGER,v INTEGER,b INTEGER)",&result);
 try db.execute("INSERT INTO r VALUES(1,1,10,NULL),(2,1,10,2),(3,1,30,3),(4,2,40,2),(5,2,40,0),(6,2,NULL,-1),(7,NULL,60,3),(8,NULL,60,1),(9,3,70,NULL)",&result);
    try rows("SELECT id,percent_rank() OVER () AS value FROM r ORDER BY id", &.{.{"1","0","double precision"},.{"2","0","double precision"},.{"3","0","double precision"},.{"4","0","double precision"},.{"5","0","double precision"},.{"6","0","double precision"},.{"7","0","double precision"},.{"8","0","double precision"},.{"9","0","double precision"}});
    try rows("SELECT id,percent_rank() OVER (ORDER BY v) AS value FROM r ORDER BY id", &.{.{"1","0","double precision"},.{"2","0","double precision"},.{"3","0.25","double precision"},.{"4","0.375","double precision"},.{"5","0.375","double precision"},.{"6","1","double precision"},.{"7","0.625","double precision"},.{"8","0.625","double precision"},.{"9","0.875","double precision"}});
    try rows("SELECT id,percent_rank() OVER (ORDER BY v DESC NULLS LAST) AS value FROM r ORDER BY id", &.{.{"1","0.75","double precision"},.{"2","0.75","double precision"},.{"3","0.625","double precision"},.{"4","0.375","double precision"},.{"5","0.375","double precision"},.{"6","1","double precision"},.{"7","0.125","double precision"},.{"8","0.125","double precision"},.{"9","0","double precision"}});
    try rows("SELECT id,percent_rank() OVER (PARTITION BY g ORDER BY v) AS value FROM r ORDER BY id", &.{.{"1","0","double precision"},.{"2","0","double precision"},.{"3","1","double precision"},.{"4","0","double precision"},.{"5","0","double precision"},.{"6","1","double precision"},.{"7","0","double precision"},.{"8","0","double precision"},.{"9","0","double precision"}});
    try rows("SELECT id,percent_rank() OVER (PARTITION BY g) AS value FROM r ORDER BY id", &.{.{"1","0","double precision"},.{"2","0","double precision"},.{"3","0","double precision"},.{"4","0","double precision"},.{"5","0","double precision"},.{"6","0","double precision"},.{"7","0","double precision"},.{"8","0","double precision"},.{"9","0","double precision"}});
    try rows("SELECT id,percent_rank() OVER (ORDER BY v,id ROWS BETWEEN -1 PRECEDING AND CURRENT ROW) AS value FROM r ORDER BY id", &.{.{"1","0","double precision"},.{"2","0.125","double precision"},.{"3","0.25","double precision"},.{"4","0.375","double precision"},.{"5","0.5","double precision"},.{"6","1","double precision"},.{"7","0.625","double precision"},.{"8","0.75","double precision"},.{"9","0.875","double precision"}});
    try rows("SELECT id,percent_rank() OVER (ORDER BY v,id ROWS BETWEEN NULL PRECEDING AND CURRENT ROW) AS value FROM r ORDER BY id", &.{.{"1","0","double precision"},.{"2","0.125","double precision"},.{"3","0.25","double precision"},.{"4","0.375","double precision"},.{"5","0.5","double precision"},.{"6","1","double precision"},.{"7","0.625","double precision"},.{"8","0.75","double precision"},.{"9","0.875","double precision"}});
    try rejects("SELECT id,percent_rank(1) OVER () AS value FROM r ORDER BY id", error.WrongObjectType);
    try rejects("SELECT id,percent_rank(NULL) OVER () AS value FROM r ORDER BY id", error.WrongObjectType);
    try rows("SELECT id,percent_rank(*) OVER () AS value FROM r ORDER BY id", &.{.{"1","0","double precision"},.{"2","0","double precision"},.{"3","0","double precision"},.{"4","0","double precision"},.{"5","0","double precision"},.{"6","0","double precision"},.{"7","0","double precision"},.{"8","0","double precision"},.{"9","0","double precision"}});
    try rows("SELECT id,cume_dist() OVER () AS value FROM r ORDER BY id", &.{.{"1","1","double precision"},.{"2","1","double precision"},.{"3","1","double precision"},.{"4","1","double precision"},.{"5","1","double precision"},.{"6","1","double precision"},.{"7","1","double precision"},.{"8","1","double precision"},.{"9","1","double precision"}});
    try rows("SELECT id,cume_dist() OVER (ORDER BY v) AS value FROM r ORDER BY id", &.{.{"1","0.2222222222222222","double precision"},.{"2","0.2222222222222222","double precision"},.{"3","0.3333333333333333","double precision"},.{"4","0.5555555555555556","double precision"},.{"5","0.5555555555555556","double precision"},.{"6","1","double precision"},.{"7","0.7777777777777778","double precision"},.{"8","0.7777777777777778","double precision"},.{"9","0.8888888888888888","double precision"}});
    try rows("SELECT id,cume_dist() OVER (ORDER BY v DESC NULLS LAST) AS value FROM r ORDER BY id", &.{.{"1","0.8888888888888888","double precision"},.{"2","0.8888888888888888","double precision"},.{"3","0.6666666666666666","double precision"},.{"4","0.5555555555555556","double precision"},.{"5","0.5555555555555556","double precision"},.{"6","1","double precision"},.{"7","0.3333333333333333","double precision"},.{"8","0.3333333333333333","double precision"},.{"9","0.1111111111111111","double precision"}});
    try rows("SELECT id,cume_dist() OVER (PARTITION BY g ORDER BY v) AS value FROM r ORDER BY id", &.{.{"1","0.6666666666666666","double precision"},.{"2","0.6666666666666666","double precision"},.{"3","1","double precision"},.{"4","0.6666666666666666","double precision"},.{"5","0.6666666666666666","double precision"},.{"6","1","double precision"},.{"7","1","double precision"},.{"8","1","double precision"},.{"9","1","double precision"}});
    try rows("SELECT id,cume_dist() OVER (PARTITION BY g) AS value FROM r ORDER BY id", &.{.{"1","1","double precision"},.{"2","1","double precision"},.{"3","1","double precision"},.{"4","1","double precision"},.{"5","1","double precision"},.{"6","1","double precision"},.{"7","1","double precision"},.{"8","1","double precision"},.{"9","1","double precision"}});
    try rows("SELECT id,cume_dist() OVER (ORDER BY v,id ROWS BETWEEN -1 PRECEDING AND CURRENT ROW) AS value FROM r ORDER BY id", &.{.{"1","0.1111111111111111","double precision"},.{"2","0.2222222222222222","double precision"},.{"3","0.3333333333333333","double precision"},.{"4","0.4444444444444444","double precision"},.{"5","0.5555555555555556","double precision"},.{"6","1","double precision"},.{"7","0.6666666666666666","double precision"},.{"8","0.7777777777777778","double precision"},.{"9","0.8888888888888888","double precision"}});
    try rows("SELECT id,cume_dist() OVER (ORDER BY v,id ROWS BETWEEN NULL PRECEDING AND CURRENT ROW) AS value FROM r ORDER BY id", &.{.{"1","0.1111111111111111","double precision"},.{"2","0.2222222222222222","double precision"},.{"3","0.3333333333333333","double precision"},.{"4","0.4444444444444444","double precision"},.{"5","0.5555555555555556","double precision"},.{"6","1","double precision"},.{"7","0.6666666666666666","double precision"},.{"8","0.7777777777777778","double precision"},.{"9","0.8888888888888888","double precision"}});
    try rejects("SELECT id,cume_dist(1) OVER () AS value FROM r ORDER BY id", error.WrongObjectType);
    try rejects("SELECT id,cume_dist(NULL) OVER () AS value FROM r ORDER BY id", error.WrongObjectType);
    try rows("SELECT id,cume_dist(*) OVER () AS value FROM r ORDER BY id", &.{.{"1","1","double precision"},.{"2","1","double precision"},.{"3","1","double precision"},.{"4","1","double precision"},.{"5","1","double precision"},.{"6","1","double precision"},.{"7","1","double precision"},.{"8","1","double precision"},.{"9","1","double precision"}});
    try rows("SELECT id,ntile(1) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","1","integer"},.{"3","1","integer"},.{"4","1","integer"},.{"5","1","integer"},.{"6","1","integer"},.{"7","1","integer"},.{"8","1","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(1) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","1","integer"},.{"3","1","integer"},.{"4","1","integer"},.{"5","1","integer"},.{"6","1","integer"},.{"7","1","integer"},.{"8","1","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(2) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","1","integer"},.{"3","2","integer"},.{"4","1","integer"},.{"5","1","integer"},.{"6","2","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(2) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","2","integer"},.{"2","2","integer"},.{"3","2","integer"},.{"4","2","integer"},.{"5","1","integer"},.{"6","1","integer"},.{"7","1","integer"},.{"8","1","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(3) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","2","integer"},.{"3","3","integer"},.{"4","1","integer"},.{"5","2","integer"},.{"6","3","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(3) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","3","integer"},.{"2","3","integer"},.{"3","3","integer"},.{"4","2","integer"},.{"5","2","integer"},.{"6","2","integer"},.{"7","1","integer"},.{"8","1","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(4) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","2","integer"},.{"3","3","integer"},.{"4","1","integer"},.{"5","2","integer"},.{"6","3","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(4) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","4","integer"},.{"2","4","integer"},.{"3","3","integer"},.{"4","3","integer"},.{"5","2","integer"},.{"6","2","integer"},.{"7","1","integer"},.{"8","1","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(8) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","2","integer"},.{"3","3","integer"},.{"4","1","integer"},.{"5","2","integer"},.{"6","3","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(8) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","8","integer"},.{"2","7","integer"},.{"3","6","integer"},.{"4","5","integer"},.{"5","4","integer"},.{"6","3","integer"},.{"7","2","integer"},.{"8","1","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(9) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","2","integer"},.{"3","3","integer"},.{"4","1","integer"},.{"5","2","integer"},.{"6","3","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(9) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","9","integer"},.{"2","8","integer"},.{"3","7","integer"},.{"4","6","integer"},.{"5","5","integer"},.{"6","4","integer"},.{"7","3","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(10) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","2","integer"},.{"3","3","integer"},.{"4","1","integer"},.{"5","2","integer"},.{"6","3","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(10) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","9","integer"},.{"2","8","integer"},.{"3","7","integer"},.{"4","6","integer"},.{"5","5","integer"},.{"6","4","integer"},.{"7","3","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(2147483647) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","2","integer"},.{"3","3","integer"},.{"4","1","integer"},.{"5","2","integer"},.{"6","3","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(2147483647) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","9","integer"},.{"2","8","integer"},.{"3","7","integer"},.{"4","6","integer"},.{"5","5","integer"},.{"6","4","integer"},.{"7","3","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(NULL) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"},.{"7",null,"integer"},.{"8",null,"integer"},.{"9",null,"integer"}});
    try rows("SELECT id,ntile(NULL) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"},.{"7",null,"integer"},.{"8",null,"integer"},.{"9",null,"integer"}});
    try rows("SELECT id,ntile(b) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1",null,"integer"},.{"2","1","integer"},.{"3","1","integer"},.{"4","1","integer"},.{"5","1","integer"},.{"6","2","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9",null,"integer"}});
    try rows("SELECT id,ntile(b) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","1","integer"},.{"3","1","integer"},.{"4","1","integer"},.{"5","1","integer"},.{"6","1","integer"},.{"7","1","integer"},.{"8","1","integer"},.{"9",null,"integer"}});
    try rows("SELECT id,ntile('2') OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","1","integer"},.{"3","2","integer"},.{"4","1","integer"},.{"5","1","integer"},.{"6","2","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile('2') OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","2","integer"},.{"2","2","integer"},.{"3","2","integer"},.{"4","2","integer"},.{"5","1","integer"},.{"6","1","integer"},.{"7","1","integer"},.{"8","1","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(2::smallint) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","1","integer"},.{"3","2","integer"},.{"4","1","integer"},.{"5","1","integer"},.{"6","2","integer"},.{"7","1","integer"},.{"8","2","integer"},.{"9","1","integer"}});
    try rows("SELECT id,ntile(2::smallint) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", &.{.{"1","2","integer"},.{"2","2","integer"},.{"3","2","integer"},.{"4","2","integer"},.{"5","1","integer"},.{"6","1","integer"},.{"7","1","integer"},.{"8","1","integer"},.{"9","1","integer"}});
    try rejects("SELECT id,ntile(0) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", error.InvalidArgumentForNtile);
    try rejects("SELECT id,ntile(0) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", error.InvalidArgumentForNtile);
    try rejects("SELECT id,ntile(-1) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", error.InvalidArgumentForNtile);
    try rejects("SELECT id,ntile(-1) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", error.InvalidArgumentForNtile);
    try rejects("SELECT id,ntile(-2147483648) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", error.InvalidArgumentForNtile);
    try rejects("SELECT id,ntile(-2147483648) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", error.InvalidArgumentForNtile);
    try rejects("SELECT id,ntile(2::bigint) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,ntile(2::bigint) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,ntile(1.5) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,ntile(1.5) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,ntile(true) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,ntile(true) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,ntile(1/0) OVER (PARTITION BY g ORDER BY v,id) AS value FROM r ORDER BY id", error.DivisionByZero);
    try rejects("SELECT id,ntile(1/0) OVER (ORDER BY id DESC) AS value FROM r ORDER BY id", error.DivisionByZero);
    try rows("SELECT id,ntile(3) OVER (ORDER BY id ROWS BETWEEN -1 PRECEDING AND CURRENT ROW) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","1","integer"},.{"3","1","integer"},.{"4","2","integer"},.{"5","2","integer"},.{"6","2","integer"},.{"7","3","integer"},.{"8","3","integer"},.{"9","3","integer"}});
    try rows("SELECT id,ntile(3) OVER (ORDER BY id ROWS BETWEEN NULL PRECEDING AND CURRENT ROW) AS value FROM r ORDER BY id", &.{.{"1","1","integer"},.{"2","1","integer"},.{"3","1","integer"},.{"4","2","integer"},.{"5","2","integer"},.{"6","2","integer"},.{"7","3","integer"},.{"8","3","integer"},.{"9","3","integer"}});
    try rejects("SELECT id,ntile() OVER () AS value FROM r ORDER BY id", error.UndefinedFunction);
    try rejects("SELECT id,ntile(2,3) OVER () AS value FROM r ORDER BY id", error.UndefinedFunction);
 try rejects("SELECT ntile(2) OVER(ROWS (1/0) PRECEDING)",error.DivisionByZero);
 try rejects("SELECT percent_rank() OVER(ROWS (1/0) PRECEDING) LIMIT 0",error.DivisionByZero);
 try rejects("SELECT cume_dist() OVER(ROWS (1/0) PRECEDING)",error.DivisionByZero);
 try rejects("SELECT ntile(2)",error.WrongObjectType);
 try rejects("SELECT rank()",error.WrongObjectType);
 try rejects("SELECT dense_rank()",error.WrongObjectType);
 try rejects("SELECT row_number()",error.WrongObjectType);
 try rejects("SELECT cume_dist()",error.WrongObjectType);
 try rejects("SELECT percent_rank()",error.WrongObjectType);
 try db.execute("SELECT ntile(0) OVER() FROM r WHERE FALSE",&result);try check(result.row_count==0 and sql.typeOid(result.column_types[0])==23);
 try db.execute("SELECT ntile(-1) OVER() FROM r LIMIT 0",&result);try check(result.row_count==0);
 try properties();try resources();
 std.debug.print("{{\"suite\":\"window-ranking\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
