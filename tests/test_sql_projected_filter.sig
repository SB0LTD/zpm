//! Independent row models, MVCC fallback, and checkpoint-equivalent filtering.
const std=@import("std");
const sql=@import("sql");
const cfg:sql.Config=.{.external_storage=true,.external_workspace=true,.tables=1,.columns=4,.rows_per_table=4,
    .work_rows=256,.result_rows=128,.text_bytes=24,.compact_integral_scans=true};
const DB=sql.Database(cfg);
const Scalar=sql.Database(.{.external_storage=true,.external_workspace=true,.tables=1,.columns=4,.rows_per_table=4,
    .work_rows=256,.result_rows=128,.text_bytes=24,.compact_integral_scans=false});
const n=1024;
var bytes:[DB.backingBytes(n,n*3,8192) catch unreachable]u8 align(16)=undefined;
var scalar_bytes:[Scalar.backingBytes(n,n*3,8192) catch unreachable]u8 align(16)=undefined;
var db:DB=.{};var scalar:Scalar=.{};
var cells:[256*8]DB.Cell=undefined;var scalar_cells:[256*8]Scalar.Cell=undefined;
var result:DB.Result=.{};var other:Scalar.Result=.{};
var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.ProjectedFilterContract;}
fn both(source:[]const u8) !void {try db.execute(source,&result);try scalar.execute(source,&other);}
fn same(source:[]const u8,expected:usize) !void {
    var a:sql.ExecutionControl=.{};var b:sql.ExecutionControl=.{};
    db.session.control=&a;scalar.session.control=&b;
    defer {db.session.control=null;scalar.session.control=null;}
    try both(source);
    try check(result.row_count==expected and other.row_count==expected);
    try check(a.used==b.used);
    for(0..expected) |i| for(0..result.column_count) |column| {
        const x=result.rows[i].cells[column];const y=other.rows[i].cells[column];
        try check(std.meta.activeTag(x)==std.meta.activeTag(y));
        if(x==.integer) try check(x.integer==y.integer);
        if(x==.text) try check(std.mem.eql(u8,x.text.slice(),y.text.slice()));
    };
}
fn canceled(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
pub fn main() !void {
    try db.bindMemory(&bytes,n,n*3,8192);try scalar.bindMemory(&scalar_bytes,n,n*3,8192);
    try db.bindWorkspace(&cells);try scalar.bindWorkspace(&scalar_cells);
    try both("CREATE TABLE data(id INT PRIMARY KEY,g INT NOT NULL,n BIGINT NOT NULL,label TEXT)");
    var text:[160]u8=undefined;
    for(0..n) |i| try both(try std.fmt.bufPrint(&text,"INSERT INTO data VALUES({d},{d},{d},'row-{d}')",.{i,i%16,i,i}));
    try same("SELECT id,n,label FROM data WHERE g=3 AND n>511",32);
    try check(db.workspace.query.read_stats.projected_filter_scans==1);
    // Low-byte collisions must be rejected by exact value comparison.
    try same("SELECT id FROM data WHERE n=257",1);
    try same("SELECT id FROM data WHERE n=513",1);
    try same("SELECT id FROM data WHERE n=-255",0);
    try same("SELECT id FROM data WHERE n=0",1);
    try same("SELECT id FROM data WHERE n=1023",1);
    try same("SELECT id FROM data WHERE 3=g AND 900<n AND n<1000",6);
    try same("SELECT id FROM data WHERE g=99 AND n>0",0);
    for(0..16) |group| {
        const lower=group*31;
        var expected:usize=0;
        for(0..n) |i| if(i%16==group and i>=lower and i<lower+97) {expected+=1;};
        try same(try std.fmt.bufPrint(&text,"SELECT id,label FROM data WHERE g={d} AND n>={d} AND {d}>n",.{group,lower,lower+97}),expected);
    }
    try same("SELECT id FROM data WHERE g<>3 AND n<=10",10);
    try same("SELECT id FROM data WHERE g=3 AND n>=-1 AND n<=51",4);
    try same("SELECT id FROM data WHERE g=3 OR n>1020",67);
    try check(db.workspace.query.read_stats.projected_filter_scans==0);
    try same("SELECT id FROM data WHERE g=3 LIMIT 2",2);
    try check(db.workspace.query.read_stats.projected_filter_scans==0);
    try same("SELECT id FROM data WHERE g=3 ORDER BY id DESC LIMIT 3",3);
    try both("DELETE FROM data WHERE id=515");
    try same("SELECT id FROM data WHERE g=3 AND n>511",31);
    try both("UPDATE data SET g=3 WHERE id=516");
    try same("SELECT id FROM data WHERE g=3 AND n>511",32);
    const before=db.csn;
    try both("INSERT INTO data VALUES(2000,3,2000,NULL)");
    try db.execute("SELECT id FROM data WHERE g=99",&result);
    const owner=try db.begin();
    try db.statement(owner,"UPDATE data SET g=4 WHERE id=516",&result,.{});
    try db.statement(owner,"SELECT id FROM data WHERE g=3 AND n>511",&result,.{});
    try check(result.row_count==32 and db.workspace.query.read_stats.projected_filter_scans==0);
    db.abort(owner);
    // An old snapshot uses the original versions, never the current projection.
    const ContextDB=DB;
    var context:ContextDB.ReadContext=.{};
    var scratch:[ContextDB.ReadContext.backingBytes(256) catch unreachable]u8 align(16)=undefined;
    try context.bindMemory(&scratch,256);
    try context.execute(&db,"SELECT id FROM data WHERE g=3 AND n>511",.{.csn=before},&result);
    try check(result.row_count==32 and context.workspace.query.read_stats.projected_filter_scans==0);
    try db.execute("SELECT 777",&result);
    var control:sql.ExecutionControl=.{.max_work=100};db.session.control=&control;
    if(db.execute("SELECT id FROM data WHERE g=3 AND n>511",&result)) |_| return error.LimitIgnored else |err| try check(err==error.QueryWorkLimit);
    try check(result.row_count==1 and result.rows[0].cells[0].integer==777);
    control=.{.poll=canceled};
    if(db.execute("SELECT id FROM data WHERE g=3 AND n>511",&result)) |_| return error.CancelIgnored else |err| try check(err==error.QueryCanceled);
    db.session.control=null;
    try both("DROP TABLE data");
    try both("CREATE TABLE data(id INT PRIMARY KEY,g INT,n INT,label TEXT)");
    try both("INSERT INTO data VALUES(1,NULL,5,'a'),(2,3,NULL,'b'),(3,3,10,'c')");
    try same("SELECT id FROM data WHERE g=3 AND n>0",1);
    try check(db.workspace.query.read_stats.projected_filter_scans==0);
    std.debug.print("PASS projected filter: {d} assertions, independent scalar executor and row models\n",.{assertions});
}
