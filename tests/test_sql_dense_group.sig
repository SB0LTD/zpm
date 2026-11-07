//! Independent grouping model across NULLs, directions, own/pending writes,
//! wide-domain fallback, copying, aborts and generic aggregate transitions.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=1,.columns=4,.rows_per_table=128,.work_rows=128,.result_rows=128,.text_bytes=64,.integer_bits=32});
const Item=struct {key:?i64=null,value:?i64=null};
const Group=struct {key:?i64=null,count:i64=0,nonnull:i64=0,total:i128=0};
var db:DB=.{};var copy:DB=.{};var result:DB.Result=.{};var items:[96]Item=undefined;var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("dense assertion {d}\n",.{assertions});return error.DenseGroupFailed;}}
fn same(a:?i64,b:?i64)bool {return if(a)|x|if(b)|y|x==y else false else b==null;}
fn before(a:?i64,b:?i64,descending:bool,nulls_first:bool)bool {
    if(a==null or b==null)return if(a==null) b!=null and nulls_first else !nulls_first;
    return if(descending) a.?>b.? else a.?<b.?;
}
fn verify(database:*DB,dense:bool,descending:bool,nulls_first:bool,filtered:bool) !void {
    var groups:[96]Group=undefined;var used:usize=0;
    for(items,0..)|item,i|{
        if(filtered and i%3!=0)continue;
        var at:usize=0;while(at<used and !same(groups[at].key,item.key)) : (at+=1) {}
        if(at==used){groups[at]=.{.key=item.key};used+=1;}
        groups[at].count+=1;if(item.value)|value|{groups[at].nonnull+=1;groups[at].total+=value;}
    }
    for(1..used)|i|{var at=i;while(at>0 and before(groups[at].key,groups[at-1].key,descending,nulls_first)) : (at-=1){const tmp=groups[at];groups[at]=groups[at-1];groups[at-1]=tmp;}}
    try check(result.row_count==used);
    for(groups[0..used],0..)|group,i|{
        const cells=&result.rows[i].cells;
        if(group.key)|key|try check(cells[0].integer==key) else try check(cells[0]==.null_value);
        try check(cells[1].integer==group.count and cells[2].integer==group.nonnull);
        if(group.nonnull==0)try check(cells[3]==.null_value) else {
            var text:[64]u8=undefined;
            try check(std.mem.eql(u8,cells[3].text.slice(),try std.fmt.bufPrint(&text,"{d}",.{group.total})));
        }
    }
    const stats=database.workspace.query.stream_stats;
    try check(stats.rows==96 and stats.groups==used and stats.dense_plans==@intFromBool(dense));
    if(dense)try check(stats.probes==if(filtered) @as(usize,32) else 96);
}
fn read(database:*DB,dense:bool,descending:bool,nulls_first:bool,filtered:bool,slot:?u16) !void {
    var text:[384]u8=undefined;
    const query=try std.fmt.bufPrint(&text,"SELECT g, COUNT(*), COUNT(v), SUM(v)::TEXT FROM t {s} GROUP BY g ORDER BY g {s} NULLS {s}",
        .{if(filtered) "WHERE id % 3 = 0" else "",if(descending) "DESC" else "ASC",if(nulls_first) "FIRST" else "LAST"});
    if(slot)|s|try database.statement(s,query,&result,.{}) else try database.execute(query,&result);
    try verify(database,dense,descending,nulls_first,filtered);
}
pub fn main() !void {
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, g INT, v BIGINT)",&result);
    var text:[256]u8=undefined;var key:[32]u8=undefined;var val:[32]u8=undefined;
    for(&items,0..)|*item,i|{
        item.*=.{.key=if(i%11==0)null else @as(i64,@intCast(i%16))-8,.value=if(i%7==0)null else (@as(i64,@intCast(i))-49)*1000000000000};
        const k=if(item.key)|v|try std.fmt.bufPrint(&key,"{d}",.{v}) else "NULL";
        const v=if(item.value)|v|try std.fmt.bufPrint(&val,"{d}",.{v}) else "NULL";
        try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO t VALUES ({d},{s},{s})",.{i,k,v}),&result);
    }
    for(0..4)|mask|try read(&db,true,mask&1!=0,mask&2!=0,false,null);
    try read(&db,true,false,true,true,null);
    try copy.copyFromInto(&db);try read(&copy,true,false,true,false,null);
    // Generic MIN/MAX/AVG transitions retain the same evaluation order.
    try db.execute("SELECT g,MIN(v),MAX(v),AVG(v) FROM t GROUP BY g ORDER BY g",&result);const expected=result;
    try check(db.workspace.query.stream_stats.dense_plans==1);
    try db.execute("SELECT g+0,MIN(v),MAX(v),AVG(v) FROM t GROUP BY g+0 ORDER BY g+0",&result);
    try check(db.workspace.query.stream_stats.dense_plans==0 and result.row_count==expected.row_count);
    for(0..result.row_count)|r|for(0..4)|c|try check(DB.compareCells(&expected.rows[r].cells[c],&result.rows[r].cells[c])==0);
    const writer=try db.begin();try db.statement(writer,"UPDATE t SET g = 2147483647 WHERE id = 0",&result,.{});
    try read(&db,false,false,true,false,null);
    const old=items[0];items[0].key=2147483647;try read(&db,false,false,true,false,writer);
    db.abort(writer);items[0]=old;
    // Bounds deliberately retain aborted outliers: fallback is conservative.
    try read(&db,false,true,false,false,null);
    // The copied database retained its independent tight domain.
    try read(&copy,true,false,true,false,null);
    std.debug.print("{{\"suite\":\"sql-dense-group\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
