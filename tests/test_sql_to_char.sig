const std=@import("std");const sql=@import("sql");
const Db=sql.Database(.{.tables=2,.columns=8,.rows_per_table=128,.work_rows=2048,.text_bytes=128,.expr_nodes=2048,.expr_depth=64});
var db:Db=.{};var result:Db.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.ToCharContract;}
fn text(query:[]const u8,expected:[]const u8) !void {
    db.execute(query,&result) catch |err| {std.debug.print("{s}: {s}\n",.{@errorName(err),query});return err;};
    try check(result.row_count==1 and result.column_count==1);
    if(result.rows[0].cells[0]!=.text or !std.mem.eql(u8,result.rows[0].cells[0].text.slice(),expected)) {
        if(result.rows[0].cells[0]==.text) std.debug.print("expected [{s}], got [{s}]: {s}\n",.{expected,result.rows[0].cells[0].text.slice(),query});
        return error.ToCharMismatch;
    }
    try check(true);
}
fn reject(query:[]const u8,expected:sql.Error) !void {
    const saved=result;
    if(db.execute(query,&result)) |_| return error.ExpectedError else |err| {if(err!=expected){std.debug.print("expected {s}, got {s}\n",.{@errorName(expected),@errorName(err)});return err;}}
    try check(result.row_count==saved.row_count and result.column_count==saved.column_count);
    for(result.rows[0..result.row_count],saved.rows[0..saved.row_count]) |a,b| for(0..result.column_count) |i| try check(Db.compareCells(&a.cells[i],&b.cells[i])==0);
}

fn groupedDateKeys() !void {
    try db.execute("CREATE TABLE stores(id INTEGER PRIMARY KEY, region TEXT)",&result);
    try db.execute("INSERT INTO stores VALUES(1,'west')",&result);
    try db.execute("INSERT INTO sales VALUES(5,'2024-01-01',60),(6,'2026-10-21',70),(7,'2024-01-01',80),(8,'infinity',90),(9,'-infinity',100),(10,'2024-01-01',110)",&result);
    try db.execute("SELECT st.region,to_char(s.d,'YYYY-MM'),COUNT(*),SUM(s.amount) FROM sales s JOIN stores st ON st.id=1 GROUP BY st.region,to_char(s.d,'YYYY-MM') ORDER BY 1,2 NULLS LAST",&result);
    const cached = result;
    try check(cached.row_count == 4 and db.workspace.query.stream_stats.date_key_memo_hits == 2);
    try check(db.workspace.query.stream_stats.date_key_memo_misses == 8);
    // Dates 1024 days apart share a cache slot. A computed format takes the
    // ordinary evaluator so exact values and counts can be compared.
    try db.execute("SELECT st.region,to_char(s.d,'YYYY-'||'MM'),COUNT(*),SUM(s.amount) FROM sales s JOIN stores st ON st.id=1 GROUP BY st.region,to_char(s.d,'YYYY-'||'MM') ORDER BY 1,2 NULLS LAST",&result);
    try check(result.row_count == cached.row_count and db.workspace.query.stream_stats.date_key_memo_hits == 0);
    for (0..result.row_count) |row| for (0..result.column_count) |column| {
        try check(Db.compareCells(&result.rows[row].cells[column], &cached.rows[row].cells[column]) == 0);
    };
    try db.execute("SELECT to_char(d,'YYYY-MM-DD') AS day,COUNT(*) FROM sales GROUP BY to_char(d,'YYYY-MM-DD') ORDER BY 1 NULLS LAST",&result);
    try check(result.row_count == 5 and result.rows[0].cells[1].integer == 4);
    try check(std.mem.eql(u8,result.rows[0].cells[0].text.slice(),"2024-01-01"));
    try reject("SELECT to_char(d,'IYYY-IW'),COUNT(*) FROM sales GROUP BY to_char(d,'IYYY-IW')",error.UnsupportedStatement);
}

pub fn main() !void {
    var fixtures=std.mem.splitScalar(u8,@embedFile("evidence/to-char-pg16.tsv"),'\n');
    while(fixtures.next()) |line| {
        if(line.len==0) continue;
        const tab=std.mem.indexOfScalar(u8,line,'\t') orelse return error.InvalidFixture;
        try text(line[0..tab],line[tab+1..]);
    }
    try text("SELECT to_char(DATE '2024-02-29','YYYY-MM-DD')","2024-02-29");
    try text("SELECT to_char(TIMESTAMP '1999-12-31 23:59:58.123456','YYYY-MM-DD HH24:MI:SS.MS US FF1 FF6')","1999-12-31 23:59:58.123 123456 1 123456");
    try text("SELECT to_char(TIMESTAMP '2000-01-01','YYYY YY YYY Y Y,YYY CC DDD WW W Q J D')","2000 00 000 0 2,000 20 001 01 1 1 2451545 7");
    try text("SELECT to_char(DATE '2024-02-29','MONTH|Month|month|MON|Mon|mon|DAY|Day|day|DY|Dy|dy')","FEBRUARY |February |february |FEB|Feb|feb|THURSDAY |Thursday |thursday |THU|Thu|thu");
    try text("SELECT to_char(DATE '2024-02-03','FMMonth FMDDth FMYYYY')","February 3rd 2024");
    try text("SELECT to_char(TIMESTAMP '0001-01-01 BC','YYYY BC B.C. AD A.D.')","0001 BC B.C. BC B.C.");
    try text("SELECT to_char(TIMESTAMP '2024-01-01 00:00:00','HH HH12 HH24 AM PM A.M. p.m.')","12 12 00 AM AM A.M. a.m.");
    try text("SELECT to_char(TIMESTAMP '2024-01-01 13:00:00','HH HH12 HH24 AM PM A.M. p.m.')","01 01 13 PM PM P.M. p.m.");
    try text("SELECT to_char(DATE '2024-01-01','\"literal YYYY\" YYYY')","literal YYYY 2024");
    for([_] []const u8{"SELECT to_char(DATE '2024-01-01','')","SELECT to_char(NULL::timestamp,'YYYY')","SELECT to_char(DATE '2024-01-01',NULL)","SELECT to_char(TIMESTAMP 'infinity','YYYY')","SELECT to_char(TIMESTAMP '-infinity','YYYY')"}) |q| {
        try db.execute(q,&result);try check(result.rows[0].cells[0]==.null_value);
    }
    try reject("SELECT to_char(1,'YYYY')",error.UndefinedFunction);
    try reject("SELECT to_char('2024-01-01','YYYY')",error.AmbiguousFunction);
    try reject("SELECT to_char(TIMESTAMP '2024-01-01','IYYY-IW')",error.UnsupportedStatement);
    try reject("SELECT to_char(TIMESTAMP '2024-01-01','iyyy-iw')",error.UnsupportedStatement);
    try reject("SELECT to_char(DATE '2024-01-01')",error.UndefinedFunction);
    try reject("SELECT to_char(DATE '2024-01-01','YYYY',1)",error.UndefinedFunction);
    db.session.zone=.{.kind=.fixed,.offset=7200};
    try text("SELECT to_char(TIMESTAMPTZ '2024-01-01 23:30:00+00','YYYY-MM-DD HH24:MI')","2024-01-02 01:30");
    try db.execute("CREATE TABLE sales(id INTEGER PRIMARY KEY,d DATE,amount INTEGER)",&result);
    try db.execute("INSERT INTO sales VALUES(1,'2024-01-01',10),(2,'2024-01-31',20),(3,'2024-02-29',40),(4,NULL,50)",&result);
    try db.execute("SELECT to_char(d,'YYYY-MM'),COUNT(*),SUM(amount) FROM sales GROUP BY to_char(d,'YYYY-MM') ORDER BY 1 NULLS LAST",&result);
    try check(result.row_count==3 and result.rows[0].cells[1].integer==2 and result.rows[0].cells[2].integer==30);
    try check(result.rows[1].cells[2].integer==40 and result.rows[2].cells[0]==.null_value);
    try groupedDateKeys();
    // Output is expanded per token; bounded value storage must fail atomically.
    var query:[256]u8=undefined;var pattern:[128]u8=undefined;
    for(0..32) |i| @memcpy(pattern[i*4..][0..4],"YYYY");
    const q=try std.fmt.bufPrint(&query,"SELECT to_char(TIMESTAMP '10000-01-01','{s}')",.{pattern});
    try reject(q,error.TextCapacity);
    std.debug.print("PASS temporal to_char: {d} assertions\n",.{assertions});
}
