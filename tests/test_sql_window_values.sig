//! Native PostgreSQL distribution-window fixtures: partition/order/frame, NULL, typing and errors.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=2,.columns=16,.rows_per_table=16,.text_bytes=128,.expr_nodes=1024,.work_rows=64,.nulls_first_ascending=false});
var db:DB=.{};var result:DB.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.ValueWindowContractFailed;}
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
 var source:[512]u8=undefined;
 const asc=[_]usize{1,3,4,5,6,2};const desc=[_]usize{6,5,4,1,3,2};
 const values=[_]i64{10,0,10,40,50,60};
 for(0..2) |direction| for(0..5) |preceding| for(0..5) |following| for(0..4) |exclusion| for(0..3) |fn_index| {
  const order=if(direction==0) asc else desc;
  const query=try std.fmt.bufPrint(&source,"SELECT id,{s}(id{s}) OVER(ORDER BY v {s} NULLS LAST ROWS BETWEEN {d} PRECEDING AND {d} FOLLOWING{s}) AS value FROM w ORDER BY id",.{
   ([_][]const u8{"first_value","last_value","nth_value"})[fn_index],if(fn_index==2) ",2" else "",if(direction==0) "ASC" else "DESC",preceding,following,
   ([_][]const u8{""," EXCLUDE CURRENT ROW"," EXCLUDE GROUP"," EXCLUDE TIES"})[exclusion]});
  try db.execute(query,&result);try check(result.row_count==6);
  for(0..6) |row| {
   var current:usize=0;while(order[current]!=row+1) current+=1;
   const a=current-@min(current,preceding);const b=@min(current+following+1,6);
   var selected:?usize=null;var seen:usize=0;
   for(a..b) |candidate| {
    const peer=values[order[candidate]-1]==values[row];
    const include=switch(exclusion){0=>true,1=>candidate!=current,2=>!peer,3=>candidate==current or !peer,else=>unreachable};
    if(!include) continue;seen+=1;
    if((fn_index==0 and seen==1) or fn_index==1 or (fn_index==2 and seen==2)) selected=order[candidate];
   }
   if(selected) |id| try check(result.rows[row].cells[1].integer==id) else try check(result.rows[row].cells[1]==.null_value);
  }
 };
}
fn cancel(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
fn resources() !void {
 const query="SELECT id,nth_value(v,2) OVER(ORDER BY v GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE TIES) AS value FROM w ORDER BY id";
 var control:sql.ExecutionControl=.{};db.session.control=&control;defer db.session.control=null;
 try db.execute(query,&result);const work=control.used;try check(work>10);
 var limit:u64=1;while(limit<work):(limit+=1){control.reset(limit);try rejects(query,error.QueryWorkLimit);}
 control.reset(0);control.poll=cancel;try rejects(query,error.QueryCanceled);
}
pub fn main() !void {
 try db.execute("CREATE TABLE w(id INTEGER PRIMARY KEY,g INTEGER,v INTEGER)",&result);
 try db.execute(" INSERT INTO w VALUES(1,1,10),(2,1,NULL),(3,1,10),(4,2,40),(5,2,50),(6,NULL,60)",&result);
 try rows("SELECT id,first_value(v) OVER() AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,first_value(v) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,first_value(v) OVER(PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","40","integer"},.{"6","60","integer"}});
 try rows("SELECT id,first_value(v) OVER(ORDER BY v NULLS LAST) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,first_value(v) OVER(ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4","10","integer"},.{"5","40","integer"},.{"6","50","integer"}});
 try rows("SELECT id,first_value(v) OVER(ORDER BY id ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,first_value(v) OVER(ORDER BY v GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","60","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","40","integer"},.{"6","50","integer"}});
 try rows("SELECT id,first_value(v) OVER(ORDER BY v RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","40","integer"},.{"6","50","integer"}});
 try rows("SELECT id,first_value(v) OVER(ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP) AS value FROM w ORDER BY id",&.{.{"1","40","integer"},.{"2","10","integer"},.{"3","40","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,first_value(v) OVER(ORDER BY id ROWS CURRENT ROW EXCLUDE CURRENT ROW) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,first_value(v) OVER(ORDER BY v DESC NULLS LAST ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","50","integer"},.{"2","10","integer"},.{"3","40","integer"},.{"4","60","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,first_value(v) OVER(ORDER BY v ASC NULLS LAST ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","40","integer"},.{"2",null,"integer"},.{"3","40","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
 try rows("SELECT id,last_value(v) OVER() AS value FROM w ORDER BY id",&.{.{"1","60","integer"},.{"2","60","integer"},.{"3","60","integer"},.{"4","60","integer"},.{"5","60","integer"},.{"6","60","integer"}});
 try rows("SELECT id,last_value(v) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
 try rows("SELECT id,last_value(v) OVER(PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
 try rows("SELECT id,last_value(v) OVER(ORDER BY v NULLS LAST) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
 try rows("SELECT id,last_value(v) OVER(ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2","10","integer"},.{"3","40","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6","60","integer"}});
 try rows("SELECT id,last_value(v) OVER(ORDER BY id ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,last_value(v) OVER(ORDER BY v GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
 try rows("SELECT id,last_value(v) OVER(ORDER BY v RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6","60","integer"}});
 try rows("SELECT id,last_value(v) OVER(ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2","60","integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,last_value(v) OVER(ORDER BY id ROWS CURRENT ROW EXCLUDE CURRENT ROW) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,last_value(v) OVER(ORDER BY v DESC NULLS LAST ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","40","integer"},.{"2","10","integer"},.{"3","40","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,last_value(v) OVER(ORDER BY v ASC NULLS LAST ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","40","integer"},.{"2",null,"integer"},.{"3","50","integer"},.{"4","60","integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,1) OVER() AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,nth_value(v,1) OVER(PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","40","integer"},.{"6","60","integer"}});
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY v NULLS LAST) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4","10","integer"},.{"5","40","integer"},.{"6","50","integer"}});
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY id ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY v GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","60","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","40","integer"},.{"6","50","integer"}});
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY v RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","40","integer"},.{"6","50","integer"}});
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP) AS value FROM w ORDER BY id",&.{.{"1","40","integer"},.{"2","10","integer"},.{"3","40","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY id ROWS CURRENT ROW EXCLUDE CURRENT ROW) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY v DESC NULLS LAST ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","50","integer"},.{"2","10","integer"},.{"3","40","integer"},.{"4","60","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,nth_value(v,1) OVER(ORDER BY v ASC NULLS LAST ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","40","integer"},.{"2",null,"integer"},.{"3","40","integer"},.{"4","50","integer"},.{"5","60","integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,2) OVER() AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,2) OVER(PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5","50","integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY v NULLS LAST) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY id ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY v GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4","10","integer"},.{"5","50","integer"},.{"6","60","integer"}});
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY v RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","50","integer"},.{"5","50","integer"},.{"6","60","integer"}});
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP) AS value FROM w ORDER BY id",&.{.{"1","50","integer"},.{"2","10","integer"},.{"3","50","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY id ROWS CURRENT ROW EXCLUDE CURRENT ROW) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY v DESC NULLS LAST ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1","40","integer"},.{"2","10","integer"},.{"3",null,"integer"},.{"4","50","integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,nth_value(v,2) OVER(ORDER BY v ASC NULLS LAST ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3","50","integer"},.{"4","60","integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER() AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER(PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY v NULLS LAST) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY id ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY v GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY v RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY id ROWS CURRENT ROW EXCLUDE CURRENT ROW) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY v DESC NULLS LAST ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,nth_value(v,7) OVER(ORDER BY v ASC NULLS LAST ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER() AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER(PARTITION BY g ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY v NULLS LAST) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY id ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY v GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY v RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY id ROWS CURRENT ROW EXCLUDE CURRENT ROW) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY v DESC NULLS LAST ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 // Native boundary deviation: assert independent frame-membership selection.
 try rows("SELECT id,nth_value(v,NULL) OVER(ORDER BY v ASC NULLS LAST ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING EXCLUDE TIES) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rejects("SELECT id,nth_value(v,0) OVER(ORDER BY id) AS value FROM w ORDER BY id",error.InvalidArgumentForNthValue);
 try rejects("SELECT id,nth_value(v,-1) OVER(ORDER BY id) AS value FROM w ORDER BY id",error.InvalidArgumentForNthValue);
 try rows("SELECT id,nth_value(v,g) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,2147483647) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rows("SELECT id,nth_value(v,1::smallint) OVER(ORDER BY id) AS value FROM w ORDER BY id",&.{.{"1","10","integer"},.{"2","10","integer"},.{"3","10","integer"},.{"4","10","integer"},.{"5","10","integer"},.{"6","10","integer"}});
 try rejects("SELECT id,nth_value(v,1::bigint) OVER(ORDER BY id) AS value FROM w ORDER BY id",error.UndefinedFunction);
 try rejects("SELECT id,nth_value(v,1.2) OVER(ORDER BY id) AS value FROM w ORDER BY id",error.UndefinedFunction);
 try rejects("SELECT id,first_value(NULL) OVER(ORDER BY id) AS value FROM w ORDER BY id",error.TypeMismatch);
 try rejects("SELECT id,last_value('text') OVER(ORDER BY id) AS value FROM w ORDER BY id",error.TypeMismatch);
 try rejects("SELECT id,first_value(v,1) OVER(ORDER BY id) AS value FROM w ORDER BY id",error.UndefinedFunction);
 try rejects("SELECT id,last_value() OVER(ORDER BY id) AS value FROM w ORDER BY id",error.UndefinedFunction);
 try rejects("SELECT id,nth_value(v) OVER(ORDER BY id) AS value FROM w ORDER BY id",error.UndefinedFunction);
 try rejects("SELECT id,first_value(*) OVER(ORDER BY id) AS value FROM w ORDER BY id",error.UndefinedFunction);
 try rejects("SELECT id,nth_value(v,1/0) OVER(ORDER BY id) AS value FROM w ORDER BY id",error.DivisionByZero);
 try rows("SELECT id,first_value(v) OVER x AS value FROM w WINDOW x AS(PARTITION BY g ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) ORDER BY id",&.{.{"1","10","integer"},.{"2",null,"integer"},.{"3","10","integer"},.{"4","40","integer"},.{"5","50","integer"},.{"6","60","integer"}});
 try rows("SELECT id,nth_value(v,0) OVER() AS value FROM w LIMIT 0",&.{});
 try rows("SELECT id,nth_value(v,0) OVER() AS value FROM w WHERE FALSE",&.{});
 try rows("SELECT id,first_value(v::text) OVER(ORDER BY id DESC) AS value FROM w ORDER BY id",&.{.{"1","60","text"},.{"2","60","text"},.{"3","60","text"},.{"4","60","text"},.{"5","60","text"},.{"6","60","text"}});
 try properties();try resources();
 try db.execute("CREATE SEQUENCE value_seq",&result);
 try rows("SELECT id,first_value(nextval('value_seq')) OVER(ORDER BY id) AS value FROM w ORDER BY id LIMIT 2",&.{.{"1","1","bigint"},.{"2","2","bigint"}});
 try rows("SELECT 1 AS id,currval('value_seq') AS value",&.{.{"1","2","bigint"}});
 try rows("SELECT id,first_value(1/(id-1)) OVER(ORDER BY id ROWS CURRENT ROW EXCLUDE CURRENT ROW) AS value FROM w ORDER BY id",&.{.{"1",null,"integer"},.{"2",null,"integer"},.{"3",null,"integer"},.{"4",null,"integer"},.{"5",null,"integer"},.{"6",null,"integer"}});
 try rejects("SELECT first_value(v) OVER(ROWS NULL PRECEDING) FROM w",error.NullWindowFrameOffset);
 try rejects("SELECT first_value(v) OVER(ROWS -1 PRECEDING) FROM w",error.InvalidWindowFrameOffset);
 try rejects("SELECT * FROM(SELECT first_value(nextval('value_seq')) OVER() FROM w)q LIMIT 1",error.UnsupportedStatement);
 try rejects("SELECT first_value(nextval('value_seq')) OVER(),last_value(nextval('value_seq')) OVER() FROM w",error.UnsupportedStatement);
 try rows("SELECT id,last_value(v) OVER() AS value FROM w WHERE FALSE",&.{});
 std.debug.print("value-windows assertions {d}\n",.{assertions});
}
