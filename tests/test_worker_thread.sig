//! Assert ownership, reusable joined workers, contended increments and signals.
const std = @import("std");
const workers = @import("worker_thread");
var mutex: workers.Mutex = .{};
var signal: workers.Signal = .{};
var ready: std.atomic.Value(u32) = .init(0);
var go: std.atomic.Value(u32) = .init(0);
var count: u64 = 0;
var assertions: usize = 0;
fn check(ok: bool) !void { assertions += 1; if (!ok) return error.WorkerContract; }
fn entry(_: ?*anyopaque) void {
    _ = ready.fetchAdd(1, .release); signal.notify();
    while (go.load(.acquire) == 0) workers.waitForChange(&go, 0, 1000);
    for (0..20000) |_| { mutex.lock(); count += 1; mutex.unlock(); }
}
pub fn main(init: std.process.Init) !void {
    try check(mutex.tryLock());
    try check(!mutex.tryLock());
    mutex.unlock();
    if (!workers.available) {
        var unavailable: workers.Thread = .{};
        if (unavailable.start(&entry, null)) |_| return error.UnexpectedWorker else |err| try check(err == error.UnsupportedPlatform);
    } else {
        var threads: [8]workers.Thread = @splat(.{});
        var started: usize = 0;
        // Even failure must release and join all successfully started workers.
        defer {
            go.store(1, .release); workers.wakeAll(&go);
            for (threads[0..started]) |*thread| thread.join() catch @panic("join failed: control block remains owned");
        }
        for (&threads) |*thread| { try thread.start(&entry, null); started += 1; }
        while (ready.load(.acquire) != threads.len) {
            const epoch = signal.epoch.load(.acquire);
            if (ready.load(.acquire) != threads.len) signal.wait(epoch, 1000);
        }
        if (threads[0].start(&entry, null)) |_| return error.DoubleStart else |err| try check(err == error.AlreadyStarted);
        go.store(1, .release); workers.wakeAll(&go);
        for (&threads) |*thread| try thread.join();
        started = 0;
        try check(count == threads.len * 20000);
        try threads[0].join(); // joined handles are reusable and join is idempotent.
        try threads[0].start(&entry, null); started = 1;
        try threads[0].join(); started = 0;
        try check(count == (threads.len + 1) * 20000);
        const before = signal.epoch.load(.acquire);
        signal.notify();
        signal.wait(before, 1000); // already changed: must not sleep for timeout.
        try check(signal.epoch.load(.acquire) != before);
    }
    var buffer: [128]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "PASS native worker ownership/mutex/signal: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, message);
}
