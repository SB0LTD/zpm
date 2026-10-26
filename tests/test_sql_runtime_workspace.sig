//! Runtime scratch ownership, image size and selective three-way joins.
const std = @import("std");
const sql = @import("sql");
const cfg: sql.Config = .{ .external_storage=true, .external_workspace=true, .external_results=true, .tables=3,
    .columns=4, .rows_per_table=32, .result_rows=32, .work_rows=16, .text_bytes=16,
    .integer_bits=32, .nulls_first_ascending=false, .tx_writes=256 };
const DB = sql.Database(cfg);
const Large = sql.Database(largeConfig());
fn largeConfig() sql.Config { var c=cfg; c.work_rows=1000000; return c; }
const bytes = DB.backingBytes(256,512,512) catch unreachable;
var memory:[bytes]u8 align(16)=undefined;
var other_memory:[bytes]u8 align(16)=undefined;
var scratch:[1024]DB.Cell=undefined;
var other_scratch:[1024]DB.Cell=undefined;
var db:DB=.{};
var copy:DB=.{};
var result:DB.Result=.{};
var result_bytes:[32*@sizeOf(DB.Row)]u8 align(16)=undefined;
var small_bytes:[@sizeOf(DB.Row)]u8 align(16)=undefined;
var assertions:usize=0;
fn check(ok:bool) !void { assertions+=1; if(!ok) return error.RuntimeWorkspaceContract; }
pub fn main(init:std.process.Init) !void {
    try result.bindMemory(&result_bytes,32);
    try check(@sizeOf(DB)==@sizeOf(Large));
    try check(@sizeOf(DB)<1024*1024);
    try check(try DB.queryWorkspaceBytes(1000000)==1000000*2*cfg.columns*@sizeOf(DB.Cell));
    if(DB.queryWorkspaceBytes(0)) |_| return error.ZeroAccepted else |err| try check(err==error.InvalidParameterValue);
    try db.bindMemory(&memory,256,512,512);
    if(db.execute("CREATE TABLE impossible(id INT)",&result)) |_| return error.UnboundAccepted else |err| try check(err==error.InvalidParameterValue);
    try db.bindWorkspace(&scratch);
    const original=db.workspace.query.cells.ptr;
    if(db.bindWorkspaceMemory(&memory,16)) |_| return error.AliasAccepted else |err| try check(err==error.InvalidParameterValue);
    try check(db.workspace.query.cells.ptr==original);
    try db.execute("CREATE TABLE facts(id INT PRIMARY KEY,p INT,shop INT)",&result);
    try db.execute("CREATE TABLE products(id INT PRIMARY KEY,unit INT)",&result);
    try db.execute("CREATE TABLE shops(id INT PRIMARY KEY)",&result);
    var text:[256]u8=undefined;
    for(0..128) |i| try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO facts VALUES({d},{d},{d})",.{i,i%8,i%32}),&result);
    for(0..8) |i| try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO products VALUES({d},{d})",.{i,10+i}),&result);
    for(0..32) |i| try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO shops VALUES({d})",.{i}),&result);
    try db.execute("SELECT s.id,COUNT(*),SUM(f.id) FROM facts f JOIN products p ON p.id=f.p JOIN shops s ON s.id=f.shop WHERE f.shop=3 AND p.unit=13 GROUP BY s.id",&result);
    try check(result.row_count==1 and result.rows[0].cells[0].integer==3 and result.rows[0].cells[1].integer==4 and result.rows[0].cells[2].integer==204);
    try db.execute("SELECT COUNT(*),SUM(f.id) FROM facts f JOIN products p ON p.id=f.p JOIN shops s ON s.id=f.shop WHERE f.shop=3 OR f.shop=4",&result);
    try check(result.row_count==1 and result.rows[0].cells[0].integer==8 and result.rows[0].cells[1].integer==412);
    // An OR depending on a later source must never discard earlier tuples.
    result.row_count=27;
    if(db.execute("SELECT COUNT(*) FROM facts f JOIN products p ON p.id=f.p JOIN shops s ON s.id=f.shop WHERE f.shop=3 OR s.id=2",&result)) |_| return error.ExpectedCapacity
        else |err| try check(err==error.WorkspaceCapacity);
    try check(result.row_count==27);
    try db.execute("DELETE FROM facts WHERE id>=2",&result);
    try db.execute("INSERT INTO facts VALUES(200,99,31)",&result);
    try db.execute("SELECT COUNT(*) FROM facts f LEFT JOIN products p ON p.id=f.p LEFT JOIN shops s ON s.id=f.shop WHERE p.id IS NULL",&result);
    try check(result.row_count==1 and result.rows[0].cells[0].integer==1);
    try copy.bindMemory(&other_memory,256,512,512);
    try copy.bindWorkspace(&other_scratch);
    const copied_cells=copy.workspace.query.cells.ptr;
    try copy.copyFromInto(&db);
    try check(copy.workspace.query.cells.ptr==copied_cells);
    try copy.execute("SELECT COUNT(*) FROM facts",&result);
    try check(result.rows[0].cells[0].integer==3);
    var small:DB.Result=.{};
    try small.bindMemory(&small_bytes,1);
    if(copy.execute("UPDATE facts SET shop=0 RETURNING id",&small)) |_| return error.SmallResultAccepted
        else |err| try check(err==error.RowCapacity);
    try copy.execute("SELECT COUNT(*) FROM facts WHERE shop=0",&result);
    try check(result.rows[0].cells[0].integer==1);
    try copy.execute("SELECT id FROM facts ORDER BY id",&result);
    try check(result.row_count==3 and result.rows[2].cells[0].integer==200);
    small.row_count=1; small.column_count=1; small.rows[0].cells[0]=.{.integer=777};
    if(small.copyFromChecked(&result)) |_| return error.SmallCopyAccepted else |err| try check(err==error.RowCapacity);
    try check(small.row_count==1 and small.rows[0].cells[0].integer==777);
    var output:[160]u8=undefined;
    try std.Io.File.stdout().writeStreamingAll(init.io,try std.fmt.bufPrint(&output,"{{\"suite\":\"runtime-workspace\",\"passed\":true,\"assertions\":{d},\"inline_bytes\":{d}}}\n",.{assertions,@sizeOf(DB)}));
}
