const std=@import("std");
const budget=@import("resource_budget");
const pages=@import("page_region");
const regions=@import("budgeted_region");
fn check(ok:bool) !void {if(!ok) return error.BudgetedRegionContract;}
fn rejected(comptime expected:anyerror,actual:anytype) !void {
    if(actual) |_| return error.ExpectedFailure else |err| try check(err==expected);
}
pub fn main(init:std.process.Init) !void {
    var slots:[3]budget.Slot=undefined;var ledger:budget.Ledger=.{};
    const page=pages.pageSize();try ledger.bind(&slots,page*2);
    var a:regions.Region=.{};defer a.close() catch @panic("region a ownership");
    var b:regions.Region=.{};defer b.close() catch @panic("region b ownership");
    var c:regions.Region=.{};defer c.close() catch @panic("region c ownership");
    try a.reserve(&ledger,1);try check(a.memory.bytes.len==page and ledger.stats().used==page);
    try rejected(error.AlreadyReserved,a.reserve(&ledger,1));
    try b.reserve(&ledger,page);try check(ledger.stats().used==page*2);
    try rejected(error.BudgetExceeded,c.reserve(&ledger,1));try check(c.owner==0 and ledger.stats().active==2);
    var copied=a;try rejected(error.InvalidOwner,copied.close());
    a.memory.bytes[0]=71;try check(a.memory.bytes[0]==71);
    try ledger.resize(page);try check(ledger.stats().pressure);
    try a.close();try a.close();try check(!ledger.stats().pressure and ledger.stats().used==page);
    try rejected(error.BudgetExceeded,c.reserve(&ledger,1));
    try b.close();try c.reserve(&ledger,1);try c.close();try check(ledger.stats().used==0);
    try rejected(error.ArithmeticOverflow,c.reserve(&ledger,std.math.maxInt(usize)));
    try check(ledger.stats().used==0);
    // A representable but impossible reservation exercises OS failure rollback.
    try ledger.resize(std.math.maxInt(u64));
    if(c.reserve(&ledger,std.math.maxInt(usize)/2)) |_| return error.ImpossibleReservationAccepted else |err| try check(err==error.MemoryReservationFailed);
    try check(ledger.stats().used==0 and ledger.stats().active==0 and c.owner==0);
    try std.Io.File.stdout().writeStreamingAll(init.io,"PASS budgeted regions: native rounding, unique ownership, pressure and OS failure rollback\n");
}
