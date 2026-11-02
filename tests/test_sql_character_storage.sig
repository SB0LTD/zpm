//! Character coercion, exact codecs, replay validation and failure ownership.
const std=@import("std");const sql=@import("sql");const pg=@import("pg_types");
const DB=sql.Database(.{.tables=2,.columns=4,.rows_per_table=8,.text_bytes=32,.work_rows=32,.result_rows=8,.nulls_first_ascending=false});
const Wire=pg.Types(DB.Result);
var db:DB=.{};var restored:DB=.{};var result:DB.Result=.{};var scratch:DB.ReplayScratch=.{};
var assertions:usize=0;var record:[4096]u8=undefined;
fn check(ok:bool) !void{assertions+=1;if(!ok)return error.CharacterStorageContractFailed;}
fn same(a:[]const u8,b:[]const u8) bool{return std.mem.eql(u8,a,b);}
fn idle() !void{const u=db.usage();try check(u.transactions==0 and u.row_locks==0 and u.pending_versions==0);}
fn run(q:[]const u8) !void{db.execute(q,&result) catch |err| {std.debug.print("{s}: {s}\n",.{q,@errorName(err)});return err;};}
fn rejected(q:[]const u8,wanted:anyerror) !void{
 const before=result;
 if(db.execute(q,&result)) |_| return error.InvalidCharacterAccepted else |err| try check(err==wanted);
 try check(result.column_count==before.column_count and result.row_count==before.row_count);
 for(0..before.row_count) |i| for(0..before.column_count) |j| try check(std.meta.eql(before.rows[i].cells[j],result.rows[i].cells[j]));
 try idle();
}
fn values() !void{
 for([_][]const u8{"\x00","\x80","\xc0\xaf","\xe0\x80\x80","\xed\xa0\x80","\xf4\x90\x80\x80","\xf5\x80\x80\x80","\xf0\x9f"}) |bad| {
  if(DB.Io.varcharText(bad,-1,false)) |_| return error.InvalidUtf8Accepted else |err| try check(err==error.CharacterNotInRepertoire);
 }
 if(DB.Io.varcharText("a\xff",5,true)) |_| return error.InvalidSuffixAccepted else |err| try check(err==error.CharacterNotInRepertoire);
 for([_][]const u8{"a\x00b","\x80","\xc0\xaf","\xf0\x9f"}) |bad| {
  var buffer:[128]u8=undefined;
  for([_]u16{0,1}) |format| {
   if(Wire.literal(bad,1043,format,&buffer)) |_| return error.InvalidParameterAccepted else |err| try check(err==error.CharacterNotInRepertoire);
  }
  if(Wire.receiveText(bad,.varchar,&buffer)) |_| return error.InvalidCopyFieldAccepted else |err| try check(err==error.CharacterNotInRepertoire);
 }
 const cell=try DB.Io.varcharText("\xc3\xa9\xf0\x9f\x99\x82x",6,true);try check(same(cell.text.slice(),"\xc3\xa9\xf0\x9f\x99\x82"));
 const spaces=try DB.Io.parse(.varchar,5,"a                                        ",&db.session);try check(same(spaces.text.slice(),"a"));
 if(DB.Io.parse(.varchar,5,"ab",&db.session)) |_| return error.LengthOverflowAccepted else |err| try check(err==error.StringDataRightTruncation);
 if(DB.Io.parse(.varchar,-1,"abcdefghijklmnopqrstuvwxyzabcdefg",&db.session)) |_| return error.StorageOverflowAccepted else |err| try check(err==error.TextCapacity);
 const clipped=try DB.Io.cast(.{.integer=12345},.int4,.varchar,6,&db.session);try check(same(clipped.text.slice(),"12"));
 var binary:[64]u8=undefined;const n=try Wire.sendBinary(&cell,.varchar,&db.session,&binary);try check(same(binary[0..n],cell.text.slice()));
 var literal:[128]u8=undefined;const used=try Wire.literal(binary[0..n],1043,1,&literal);
 var query:[160]u8=undefined;try run(try std.fmt.bufPrint(&query,"SELECT {s}",.{literal[0..used]}));
 try check(result.column_types[0]==.varchar and same(result.rows[0].cells[0].text.slice(),cell.text.slice()));
 try check(same(try Wire.receiveText(binary[0..n],.varchar,&literal),cell.text.slice()));
}
fn replay() !void{
 db=.{};var used:usize=0;
 try db.executeChanges("CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3) DEFAULT 'abcd'::varchar(2))",&result,&record,&used,null,null);
 try db.executeChanges("INSERT INTO t VALUES(1,'abc')",&result,&record,&used,null,null);
 restored=.{};try restored.applyChangeRecord(record[0..used],&scratch);
 try restored.execute("INSERT INTO t(id) VALUES(2)",&result);
 try restored.execute("SELECT v FROM t ORDER BY id",&result);
 try check(result.column_types[0]==.varchar and result.column_typmods[0]==7 and result.row_count==2);
 try check(same(result.rows[0].cells[0].text.slice(),"abc") and same(result.rows[1].cells[0].text.slice(),"ab"));
 for(0..used) |cut| {
  restored=.{};
  if(restored.applyChangeRecord(record[0..cut],&scratch)) |_| return error.TruncatedReplayAccepted else |err| try check(err==error.InvalidChangeRecord or err==error.UnsupportedLogVersion);
  try check(restored.tableCount()==0);
 }
 const needle=[_]u8{0x13,0x04,0,0,7,0,0,0};const index=std.mem.indexOf(u8,record[0..used],&needle) orelse return error.MissingVarcharMetadata;
 var damaged:[4096]u8=undefined;@memcpy(damaged[0..used],record[0..used]);damaged[index+4]=4;
 restored=.{};if(restored.applyChangeRecord(damaged[0..used],&scratch)) |_| return error.InvalidTypmodReplayAccepted else |err| try check(err==error.InvalidChangeRecord);
 try check(restored.tableCount()==0);
 damaged[index+4]=6;restored=.{};
 if(restored.applyChangeRecord(damaged[0..used],&scratch)) |_| return error.InvalidValueReplayAccepted else |err| try check(err==error.ChangeRecordConflict);
 try check(restored.tableCount()==0);
}
const Pulse=struct{
 calls:usize=0,stop:usize,
 fn poll(raw:?*anyopaque) sql.Error!void{const p:*@This()=@ptrCast(@alignCast(raw.?));p.calls+=1;if(p.calls==p.stop)return error.QueryCanceled;}
};
fn transactions() !void{
 db=.{};try run("CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(3))");try run("INSERT INTO t VALUES(1,'a'),(2,'abc')");
 const writer=try db.begin();try db.statement(writer,"UPDATE t SET v='xy' WHERE id=1",&result,.{});
 const reader=try db.begin();try db.statement(reader,"SELECT v FROM t WHERE id=1",&result,.{});try check(same(result.rows[0].cells[0].text.slice(),"a"));
 try db.statement(writer,"SELECT v FROM t WHERE id=1",&result,.{});try check(same(result.rows[0].cells[0].text.slice(),"xy"));
 db.abort(writer);db.abort(reader);try idle();
 try run("SELECT id,v FROM t ORDER BY id");try rejected("UPDATE t SET v=v||'x'",error.StringDataRightTruncation);
 try run("SELECT v FROM t WHERE id=1");try check(same(result.rows[0].cells[0].text.slice(),"a"));
 for(1..41) |point| {
  var pulse:Pulse=.{.stop=point};var control:sql.ExecutionControl=.{.context=&pulse,.poll=Pulse.poll,.poll_interval=1};db.session.control=&control;
  if(db.execute("SELECT COALESCE(NULL::varchar(3),'xy'::varchar(3))",&result)) |_| {try check(pulse.calls<point);}
  else |err| {try check(err==error.QueryCanceled and pulse.calls>=point);}
  db.session.control=null;try idle();
 }
 db=.{};try run("CREATE TABLE t(id VARCHAR(2) PRIMARY KEY)");try run("INSERT INTO t VALUES('ab')");
 try rejected("INSERT INTO t VALUES('ab ')",error.PrimaryKeyViolation);try run("SELECT id FROM t WHERE id='ab'");try check(result.row_count==1);
}
pub fn main() !void{try values();try replay();try transactions();std.debug.print("character storage: {d} assertions\n",.{assertions});}
