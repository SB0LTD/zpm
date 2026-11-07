//! Conservative block rejection versus disabled execution and an independent
//! live-row model. Includes publication, snapshot, copy and compaction boundaries.
const std=@import("std");const sql=@import("sql");
fn config(comptime enabled:bool) sql.Config {return .{.external_storage=true,.compact_integral_scans=true,.block_presence_filters=enabled,.factorized_aggregates=enabled,
    .tables=2,.columns=6,.rows_per_table=2,.work_rows=128,.result_rows=16,.tx_writes=2048,.text_bytes=16,.name_bytes=16,.integer_bits=32};}
const Fast=sql.Database(config(true));const Slow=sql.Database(config(false));
var fast:Fast=.{};var slow:Slow=.{};var twin:Fast=.{};var fr:Fast.Result=.{};var sr:Slow.Result=.{};var tr:Fast.Result=.{};
var memory:[3][4194304]u8 align(64)=undefined;var reader:Fast.ReadContext=.{};var refs:[8192]u32=undefined;
const Item=struct {alive:bool=false,k:?i64=null,g:i64=0,v:?i64=null};var items:[1300]Item=@splat(.{});var used_items:usize=1025;
var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) {std.debug.print("presence assertion {d}\n",.{assertions});return error.BlockPresenceContract;}}
fn equal() !void {
    try check(fr.row_count==sr.row_count and fr.column_count==sr.column_count);
    for(fr.rows[0..fr.row_count],sr.rows[0..sr.row_count]) |a,b| for(0..fr.column_count) |column| {
        const x=a.cells[column];const y=b.cells[column];try check(std.meta.activeTag(x)==std.meta.activeTag(y));
        switch(x) {.null_value=>{},.integer=>|v|try check(v==y.integer),.numeric=>|v|try check(std.meta.eql(v,y.numeric)),.text=>|v|try check(std.mem.eql(u8,v.slice(),y.text.slice())),else=>return error.UnexpectedValue}
    };
}
fn execute(source:[]const u8) !void {
    fast.execute(source,&fr) catch |err| {std.debug.print("presence fast {s}: {s}\n",.{@errorName(err),source});return err;};
    slow.execute(source,&sr) catch |err| {std.debug.print("presence slow {s}: {s}\n",.{@errorName(err),source});return err;};try equal();
}
const query="SELECT g,COUNT(*),COUNT(v),SUM(v) FROM facts WHERE k={d} GROUP BY g ORDER BY g";
fn model(key:i64) !void {
    var counts:[3]i64=@splat(0);var nonnull:[3]i64=@splat(0);var sums:[3]i64=@splat(0);
    for(items[0..used_items]) |item| {
        if(!item.alive or item.k==null or item.k.?!=key) continue;
        const g:usize=@intCast(item.g);counts[g]+=1;if(item.v) |v| {nonnull[g]+=1;sums[g]+=v;}
    }
    var row:usize=0;for(0..3) |g| {
        if(counts[g]==0) continue;const cells=fr.rows[row].cells;row+=1;
        try check(cells[0].integer==g and cells[1].integer==counts[g] and cells[2].integer==nonnull[g]);
        if(nonnull[g]==0) try check(cells[3]==.null_value) else try check(cells[3]==.integer and cells[3].integer==sums[g]);
    }try check(fr.row_count==row);
}
fn noFalseNegatives() !void {
    const table=&fast.tables[0];const blocks=(table.rows.len+63)/64;
    for(0..table.scan_high) |slot| {
        if(table.scan_live[slot]==0) continue;
        for(0..table.column_count) |column| {
            const ty=table.columns[column].data_type;
            if(ty!=.integer and ty!=.integer32 and ty!=.smallint and ty!=.date and ty!=.oid) continue;
            if(table.scan_nonnull[slot]&(@as(u64,1)<<@intCast(column))==0) continue;
            const v=table.scan_values[column*table.rows.len+slot];const residue:u8=@truncate(@as(u64,@bitCast(v)));
            try check(table.scan_presence[(column*blocks+slot/64)*4+residue/64]&(@as(u64,1)<<@as(u6,@truncate(residue)))!=0);
        }
    }
}
fn failFlush(_: ?*anyopaque,_:[]const u8) anyerror!void {return error.InjectedFlushFailure;}
fn reject(source:[]const u8,wanted:sql.Error) !void {
    const before=fr;if(fast.execute(source,&fr)) |_| return error.ExpectedFailure else |err| try check(err==wanted);
    try check(fr.row_count==before.row_count and fr.column_count==before.column_count);
    for(fr.rows[0..fr.row_count],before.rows[0..before.row_count]) |a,b| for(0..fr.column_count) |c| try check(Fast.compareCells(&a.cells[c],&b.cells[c])==0);
}
pub fn main() !void {
    @memset(std.mem.asBytes(&memory),0xa5);try fast.bindMemory(&memory[0],1100,2200,8192);try slow.bindMemory(&memory[1],1100,2200,8192);
    const extra=try Fast.backingBytes(1100,2200,8192);const base=try Slow.backingBytes(1100,2200,8192);const words=((1100+63)/64)*6*4;
    try check(extra>=base+words*8*2 and extra<base+words*8*2+16);
    try execute("CREATE TABLE facts(id INT PRIMARY KEY,k BIGINT,g INT,v INT,d DATE,t TEXT)");try execute("CREATE TABLE dims(id INT PRIMARY KEY)");try execute("INSERT INTO dims VALUES(0),(1),(2)");
    var text:[1024]u8=undefined;
    for(0..1025) |i| {
        const key=@as(i64,@intCast(i/64))-8;const v=@as(i64,@intCast(i%19))-9;
        var ktext:[32]u8=undefined;var vtext:[32]u8=undefined;
        const k=if(i%13==0) "NULL" else try std.fmt.bufPrint(&ktext,"{d}",.{key});const value=if(i%11==0) "NULL" else try std.fmt.bufPrint(&vtext,"{d}",.{v});
        items[i]=.{.alive=true,.k=if(i%13==0) null else key,.g=@intCast(i%3),.v=if(i%11==0) null else v};
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO facts VALUES({d},{s},{d},{s},DATE '2025-05-15','x')",.{i,k,i%3,value}));
    }
    try noFalseNegatives();
    for(0..17) |i| {
        const key=@as(i64,@intCast(i))-8;const source=try std.fmt.bufPrint(&text,query,.{key});
        var fc:sql.ExecutionControl=.{};var sc:sql.ExecutionControl=.{};fast.session.control=&fc;slow.session.control=&sc;
        try execute(source);fast.session.control=null;slow.session.control=null;
        try model(key);try check(fc.used==sc.used and fast.workspace.query.stream_stats.presence_rejected_blocks>0);
    }
    try execute("SELECT d.id,COUNT(*),SUM(f.v) FROM facts f JOIN dims d ON d.id=f.g WHERE f.k=7 GROUP BY d.id ORDER BY d.id");try check(fast.workspace.query.stream_stats.factor_plans==1 and fast.workspace.query.stream_stats.presence_rejected_blocks>0);
    // Residue collisions never authorize rows; exact predicates still run.
    try execute("UPDATE facts SET k=263 WHERE id=70");items[70].k=263;try execute(try std.fmt.bufPrint(&text,query,.{7}));try model(7);
    try execute(try std.fmt.bufPrint(&text,query,.{263}));try model(263);try noFalseNegatives();
    const ft=try fast.begin();const st=try slow.begin();try fast.statement(ft,"UPDATE facts SET k=7 WHERE id=10",&fr,.{});try slow.statement(st,"UPDATE facts SET k=7 WHERE id=10",&sr,.{});
    const q="SELECT g,COUNT(*),COUNT(v),SUM(v) FROM facts WHERE k=7 GROUP BY g ORDER BY g";
    try fast.statement(ft,q,&fr,.{});try slow.statement(st,q,&sr,.{});try equal();try check(fast.workspace.query.stream_stats.presence_rejected_blocks==0);fast.abort(ft);slow.abort(st);
    const pin=try fast.begin();const snap:Fast.Snapshot=.{.csn=fast.csn};fast.txs[pin].pin=snap;try fast.execute("UPDATE facts SET k=7 WHERE id=10",&fr);
    reader.workspace.query.refs=&refs;try reader.execute(&fast,q,snap,&fr);try slow.execute(q,&sr);try equal();try model(7);try check(reader.workspace.query.stream_stats.presence_rejected_blocks==0);fast.abort(pin);
    try slow.execute("UPDATE facts SET k=7 WHERE id=10",&sr);items[10].k=7;try execute(q);try model(7);
    var record:[65536]u8=undefined;var used:usize=0;
    var before_presence:[words]u64=undefined;@memcpy(&before_presence,fast.tables[0].scan_presence);
    if(fast.executeChanges("UPDATE facts SET k=123456 WHERE id=11",&fr,&record,&used,null,failFlush)) |_| return error.ExpectedFlushFailure else |err| try check(err==error.InjectedFlushFailure);
    try check(used==0 and std.mem.eql(u64,&before_presence,fast.tables[0].scan_presence));try execute(q);try model(7);try noFalseNegatives();
    try execute(try std.fmt.bufPrint(&text,query,.{123456}));try model(123456);try check(fast.workspace.query.stream_stats.presence_rejected_blocks>0);
    try twin.bindMemory(&memory[2],1300,2600,8192);try twin.copyFromInto(&fast);
    try fast.executeChanges("UPDATE facts SET k=7 WHERE id=12",&fr,&record,&used,null,null);try slow.execute("UPDATE facts SET k=7 WHERE id=12",&sr);items[12].k=7;
    var replay:Fast.ReplayScratch=.{};try twin.applyChangeRecord(record[0..used],&replay);try execute(q);try model(7);try twin.execute(q,&tr);
    try check(fr.row_count==tr.row_count and fr.column_count==tr.column_count);for(fr.rows[0..fr.row_count],tr.rows[0..tr.row_count]) |a,b| for(0..fr.column_count) |c| try check(Fast.compareCells(&a.cells[c],&b.cells[c])==0);
    for([_]i64{-8,0,7,8,263}) |key| {
        const source=try std.fmt.bufPrint(&text,query,.{key});try execute(source);try model(key);try twin.execute(source,&tr);
        try check(fr.row_count==tr.row_count and fr.column_count==tr.column_count);for(fr.rows[0..fr.row_count],tr.rows[0..tr.row_count]) |a,b| for(0..fr.column_count) |c| try check(Fast.compareCells(&a.cells[c],&b.cells[c])==0);
    }
    // Binding/reader validation includes metadata, not only value arrays.
    const raw:[*]u32=@ptrCast(fast.tables[0].scan_presence.ptr);reader.workspace.query.refs=raw[0..fast.tables[0].scan_presence.len*2];
    if(reader.execute(&fast,q,.{.csn=fast.csn},&fr)) |_| return error.ExpectedAliasRejection else |err| try check(err==error.InvalidParameterValue);reader.workspace.query.refs=&refs;
    // Reused directory slots cross block boundaries; rebuild only after moves.
    try execute("DELETE FROM facts WHERE id>=600");for(items[600..1025]) |*item| item.alive=false;
    for(0..150) |i| {try execute(try std.fmt.bufPrint(&text,"INSERT INTO facts VALUES({d},7,{d},1,DATE '2025-06-01','n')",.{2000+i,i%3}));items[1025+i]=.{.alive=true,.k=7,.g=@intCast(i%3),.v=1};}used_items+=150;
    try check(fast.tables[0].row_high<1025);try noFalseNegatives();try execute(q);try model(7);
    try execute("SELECT d.id,COUNT(*),SUM(f.v) FROM facts f JOIN dims d ON d.id=f.g WHERE f.d=DATE '2025-05-15' GROUP BY d.id ORDER BY d.id");try check(fast.workspace.query.stream_stats.factor_plans==1 and fast.workspace.query.stream_stats.presence_rejected_blocks>0);
    try execute("UPDATE facts SET k=-9223372036854775808 WHERE id=30");items[30].k=-9223372036854775808;
    try execute("UPDATE facts SET k=9223372036854775807 WHERE id=31");items[31].k=9223372036854775807;try noFalseNegatives();
    for([_]i64{-9223372036854775808,-9223372036854775552,9223372036854775807}) |key| {try execute(try std.fmt.bufPrint(&text,query,.{key}));try model(key);}
    try execute("SELECT g,COUNT(*),SUM(v) FROM facts WHERE k<>7 GROUP BY g ORDER BY g");try execute("SELECT g,COUNT(*) FROM facts WHERE k IS NULL GROUP BY g ORDER BY g");
    @memset(fast.tables[0].scan_presence,0xffffffffffffffff);try execute(q);try model(7);try check(fast.workspace.query.stream_stats.presence_rejected_blocks==0);
    var limited:sql.ExecutionControl=.{.max_work=100};fast.session.control=&limited;try reject(q,error.QueryWorkLimit);fast.session.control=null;
    std.debug.print("PASS SQL block presence: {d} assertions, exact scalar/canonical results, no false negatives, ownership/publication/compaction and identical work totals\n",.{assertions});
}
