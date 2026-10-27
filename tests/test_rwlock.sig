const std=@import("std");
const threads=@import("worker_thread");
var gate:threads.RwLock=.{};
var go:std.atomic.Value(bool)=.init(false);
var active_readers:std.atomic.Value(u32)=.init(0);
var active_writer:std.atomic.Value(bool)=.init(false);
var failed:std.atomic.Value(bool)=.init(false);
var reads:std.atomic.Value(u32)=.init(0);
var value:u64=0;var inverse:u64=~@as(u64,0);
fn reader(_: ?*anyopaque) void {
    while(!go.load(.acquire)) std.atomic.spinLoopHint();
    for(0..2000) |_| {
        gate.lockRead();_ = active_readers.fetchAdd(1,.acq_rel);
        if(active_writer.load(.acquire) or inverse!=~value) failed.store(true,.release);
        _=reads.fetchAdd(1,.monotonic);_=active_readers.fetchSub(1,.release);gate.unlockRead();
    }
}
fn writer(_: ?*anyopaque) void {
    while(!go.load(.acquire)) std.atomic.spinLoopHint();
    for(0..2000) |_| {
        gate.lockWrite();
        if(active_writer.swap(true,.acq_rel) or active_readers.load(.acquire)!=0) failed.store(true,.release);
        value+=1;inverse=~value;active_writer.store(false,.release);gate.unlockWrite();
    }
}
pub fn main(init:std.process.Init) !void {
    if(!threads.available) {try std.Io.File.stdout().writeStreamingAll(init.io,"SKIP native reader/writer contention: unsupported worker backend\n");return;}
    if(!gate.tryLockRead()) return error.SharedTryLockFailed;
    if(gate.tryLockWrite()) return error.WriterBypassedReaders;
    gate.unlockRead();
    if(!gate.tryLockWrite()) return error.ExclusiveTryLockFailed;
    if(gate.tryLockRead()) return error.ReaderBypassedWriter;
    gate.unlockWrite();
    var workers:[8]threads.Thread=@splat(.{});var started:usize=0;
    defer {go.store(true,.release);for(workers[0..started]) |*worker| worker.join() catch @panic("live gate worker");}
    for(&workers,0..) |*worker,index| {try worker.start(if(index<6) reader else writer,null);started+=1;}
    go.store(true,.release);
    for(&workers) |*worker| try worker.join();started=0;
    if(failed.load(.acquire) or reads.load(.acquire)!=12000 or value!=4000 or inverse!=~value) return error.ReadWriteGateContract;
    try std.Io.File.stdout().writeStreamingAll(init.io,"PASS reader/writer gate: 12000 reads and 4000 exclusive publications, native workers=8\n");
}
