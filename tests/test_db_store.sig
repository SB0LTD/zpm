const sql = @import("sql");
const store_module = @import("db_store");
const DB = sql.Database(.{ .tables = 2, .columns = 3, .rows_per_table = 8, .text_bytes = 32 });
const Store = store_module.Store(DB);
var assertions: usize = 0;
fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.StoreContractFailed;
}
pub fn main() !void {
    var store: Store = .{};
    var a: Store.Connection = .{ .store = &store, .id = 1 };
    var b: Store.Connection = .{ .store = &store, .id = 2 };
    var out: DB.Result = .{};
    try a.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)", &out);
    try a.beginTransaction();
    try a.execute("INSERT INTO t VALUES (1, 'rollback')", &out);
    if (b.execute("SELECT * FROM t", &out)) |_| return error.DirtyRead else |err| try check(err == error.DatabaseBusy);
    try check(a.transactionStatus() == 'T' and b.transactionStatus() == 'I');
    try a.rollbackTransaction();
    try b.execute("SELECT * FROM t", &out);
    try check(out.row_count == 0);
    try a.execute("BEGIN", &out);
    try a.execute("INSERT INTO t VALUES (1, 'commit')", &out);
    try a.execute("COMMIT", &out);
    try b.execute("SELECT * FROM t", &out);
    try check(out.row_count == 1);
    try a.beginTransaction();
    try a.execute("UPDATE t SET value = 'gone'", &out);
    a.failTransaction();
    try check(a.transactionStatus() == 'E');
    if (a.execute("SELECT * FROM t", &out)) |_| return error.AbortIgnored else |err| try check(err == error.TransactionFailed);
    try a.commitTransaction();
    try b.execute("SELECT * FROM t", &out);
    try check(out.rows[0].cells[1].text.slice()[0] == 'c');
    try a.setAutocommit(false);
    try a.execute("DELETE FROM t", &out);
    try check(store.owner == 1);
    a.disconnect();
    try b.execute("SELECT * FROM t", &out);
    try check(out.row_count == 1);
    try b.execute("SELECT 1", &out);
    try check(out.rows[0].cells[0].integer == 1);
    if (b.execute("SET unknown = 1", &out)) |_| return error.UnknownSettingAccepted else |_| {}
    var invalid: Store.Connection = .{ .store = &store, .id = 0, .failed = true };
    invalid.disconnect();
    try check(invalid.transactionStatus() == 'I');
    if (invalid.commitTransaction()) |_| return error.InvalidConnectionAccepted else |err| try check(err == error.InvalidConnection);
    try b.execute("SELECT * FROM t", &out);
    try check(out.row_count == 1);
    if (b.execute("B E G I N", &out)) |_| return error.InvalidCommandAccepted else |_| {}
    if (b.execute("BEGIN; DELETE FROM t", &out)) |_| return error.BatchCommandAccepted else |_| {}
    try check(assertions >= 10);
}
