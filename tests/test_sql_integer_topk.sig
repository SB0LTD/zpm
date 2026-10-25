//! Cached integer top-K must match an independent full insertion-sort model.
//! Include NULL placement, mixed directions, extremes, stable ties, updates,
//! fewer matches than K, cancellation and late predicate failures.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables = 1, .columns = 4, .rows_per_table = 512,
    .work_rows = 32, .result_rows = 32, .integer_bits = 64, .nulls_first_ascending = false });
const n = 257;
var db: DB = .{};
var result: DB.Result = .{};
var first: [n]?i64 = undefined;
var second: [n]?i64 = undefined;
var assertions: usize = 0;
fn check(ok: bool) !void { assertions += 1; if (!ok) return error.IntegerTopKFailed; }
fn order(a: ?i64, b: ?i64, descending: bool, nulls_first: bool) i8 {
    if (a == null or b == null) {
        if (a == null and b == null) return 0;
        return if ((a == null) == nulls_first) -1 else 1;
    }
    const result_order: i8 = if (a.? < b.?) -1 else if (a.? > b.?) 1 else 0;
    return if (descending) -result_order else result_order;
}
fn before(a: u32, b: u32, d1: bool, d2: bool, nf1: bool, nf2: bool) bool {
    const x = order(first[a],first[b],d1,nf1);
    if (x != 0) return x < 0;
    const y = order(second[a],second[b],d2,nf2);
    return if (y != 0) y < 0 else a < b;
}
fn model(d1: bool,d2: bool,nf1: bool,nf2: bool,only: usize,out: *[n]u32) usize {
    const count = @min(n,only);
    for (0..count) |i| out[i]=@intCast(i);
    for (1..count) |i| {
        const item=out[i];var j=i;
        while (j>0 and before(item,out[j-1],d1,d2,nf1,nf2)) : (j-=1) out[j]=out[j-1];
        out[j]=item;
    }
    return count;
}
fn runs() !void {
    var source: [256]u8=undefined;var expected: [n]u32=undefined;
    for (0..16) |mask| {
        const d1=mask&1!=0;const d2=mask&2!=0;const nf1=mask&4!=0;const nf2=mask&8!=0;
        for ([_]usize{0,1,16,32}) |k| for ([_]usize{3,n}) |only| {
            const count=model(d1,d2,nf1,nf2,only,&expected);
            const text=try std.fmt.bufPrint(&source,"SELECT id FROM t WHERE id < {d} ORDER BY a {s} NULLS {s}, b {s} NULLS {s} LIMIT {d}",.{only,if(d1) "DESC" else "ASC",if(nf1) "FIRST" else "LAST",if(d2) "DESC" else "ASC",if(nf2) "FIRST" else "LAST",k});
            try db.execute(text,&result);try check(result.row_count==@min(k,count));
            for (0..result.row_count) |i| try check(result.rows[i].cells[0].integer==expected[i]);
        };
    }
}
fn rejects(source: []const u8,wanted: sql.Error) !void {
    const old=result;
    if (db.execute(source,&result)) |_| return error.ExpectedFailure else |err| try check(err==wanted);
    try check(result.row_count==old.row_count and result.column_count==old.column_count);
    for (0..old.row_count) |i| try check(DB.compareCells(&result.rows[i].cells[0],&old.rows[i].cells[0])==0);
}
pub fn main() !void {
    try db.execute("CREATE TABLE t (id BIGINT PRIMARY KEY, a BIGINT, b BIGINT)",&result);
    var source: [256]u8=undefined;var a_text: [32]u8=undefined;var b_text: [32]u8=undefined;
    for (0..n) |i| {
        first[i]=if (i%13==0) null else if(i%17==0) -9223372036854775807-1 else if(i%19==0) 9223372036854775807 else @as(i64,@intCast(i%7))-3;
        second[i]=if(i%11==0) null else @as(i64,@intCast(i%5))-2;
        const a=if(first[i])|v| try std.fmt.bufPrint(&a_text,"{d}",.{v}) else "NULL";
        const b=if(second[i])|v| try std.fmt.bufPrint(&b_text,"{d}",.{v}) else "NULL";
        try db.execute(try std.fmt.bufPrint(&source,"INSERT INTO t VALUES ({d},{s},{s})",.{i,a,b}),&result);
    }
    try runs();
    // Version IDs change on updates; the stable tie ordinal must not.
    try db.execute("UPDATE t SET a = 1, b = 1 WHERE id = 0",&result);first[0]=1;second[0]=1;
    try db.execute("UPDATE t SET a = 1, b = 1 WHERE id = 1",&result);first[1]=1;second[1]=1;
    try runs();
    try rejects("SELECT id FROM t WHERE id < 250 OR 1 / (id - 250) = 0 ORDER BY a LIMIT 16",error.DivisionByZero);
    var control: sql.ExecutionControl=.{.max_work=100};db.session.control=&control;
    try rejects("SELECT id FROM t ORDER BY a,b LIMIT 16",error.QueryWorkLimit);
    db.session.control=null;
    try runs();
    std.debug.print("{{\"suite\":\"sql-integer-topk\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
