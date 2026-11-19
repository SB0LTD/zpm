//! @zpm/ps5 equeue — libkernel's event queues: what a game waits on to hear
//! that a frame was shown, that the GPU finished something, that a timer ran
//! out, or that another of its threads says so (a "user event").
//!
//! On the console an event queue is the kernel's kqueue. Here it is kept in
//! the process, because everything that posts to one lives in the process
//! too (the display library, the GPU path, the game's own threads, timers).
//! A post is a few instructions under a lock, and a wake only when a thread
//! is asleep on the queue; a wait that finds an event ready never enters
//! the kernel.
//!
//! A queue is one mapping with room for a fixed number of events. A game's
//! handle is its address, and is looked up among the queues there are
//! before anything is read through it.
//!
//! Not here: events on files and sockets (read, write, vnode), which need
//! the kernel's own queue.
//!
//! No Sony code: the behaviour is FreeBSD 11's kqueue as documented
//! (EVFILT_USER, EVFILT_TIMER), and Sony's names and extra filters as open
//! projects list them. x86-64 only. Allocation-free.

const std = @import("std");
const sys = @import("sys.sig");
const abi = @import("abi.sig");
const pthread = @import("pthread.sig");

const S = abi.Sys;
const E = abi.E;
const RW = abi.PROT.READ | abi.PROT.WRITE;
const NO_FD: u64 = ~@as(u64, 0);

/// An event as a game reads it: FreeBSD's `struct kevent`.
pub const Event = extern struct {
    ident: u64 = 0,
    filter: i16 = 0,
    flags: u16 = 0,
    fflags: u32 = 0,
    data: i64 = 0,
    udata: u64 = 0,
};

/// What an event is about. The first two are FreeBSD's; the rest Sony's.
pub const FILTER = struct {
    pub const TIMER: i16 = -7;
    pub const USER: i16 = -11;
    pub const VIDEO_OUT: i16 = -13;
    pub const GRAPHICS_CORE: i16 = -14;
    pub const HRTIMER: i16 = -15;
};

/// The flags an event carries back.
pub const EV = struct {
    pub const ONESHOT: u16 = 0x10;
    pub const CLEAR: u16 = 0x20;
};

const NOTE_USECONDS: u32 = 0x4;

// ── A queue ─────────────────────────────────────────────────────────────────

/// One thing a queue was asked to watch.
const Note = struct {
    ident: u64 = 0,
    udata: u64 = 0,
    data: i64 = 0,
    /// A timer: when it next runs out (ns on the clock that does not jump;
    /// 0: it has, and waits to be read) and how often (0: once).
    due: u64 = 0,
    period: u64 = 0,
    fflags: u32 = 0,
    filter: i16 = 0,
    flags: u16 = 0,
    used: bool = false,
    ready: bool = false,
    /// Read once and it is no longer ready, and its data starts again.
    clear: bool = false,
    /// Read once and it is gone.
    once: bool = false,
};

const BYTES: u64 = 64 << 10;
const HEAD = 128;
/// Events one queue can watch.
pub const CAPACITY = (BYTES - HEAD) / @sizeOf(Note);

const Queue = struct {
    /// Goes up at every post: what a waiting thread sleeps on.
    seq: u32 = 0,
    lock: pthread.Lock = .{},
    /// Threads asleep on `seq` (a post wakes only when there are any).
    sleepers: u32 = 0,
    /// Calls inside the queue. Under `queues.lock`; a deleted queue's
    /// memory goes back when the last one leaves.
    users: u32 = 0,
    /// Notes ever used (where a scan ends), and where the next read starts
    /// (so that an event always ready cannot hide the ones after it).
    high: u32 = 0,
    turn: u32 = 0,
    timers: u32 = 0,
    closing: bool = false,
    mapped: bool = false,
    next: ?*Queue = null,
    name: [32]u8 = [_]u8{0} ** 32,
    notes: [CAPACITY]Note = undefined,
};

comptime {
    std.debug.assert(@sizeOf(Queue) <= BYTES);
}

const queues = struct {
    var lock: pthread.Lock = .{};
    var all: ?*Queue = null;
};

fn setUp(q: *Queue, name: []const u8, mapped: bool) void {
    // (field by field: the notes are not touched. None is read before it
    // is written, since a scan ends at `high`)
    q.seq = 0;
    q.lock = .{};
    q.sleepers = 0;
    q.users = 0;
    q.high = 0;
    q.turn = 0;
    q.timers = 0;
    q.closing = false;
    q.mapped = mapped;
    q.name = [_]u8{0} ** 32;
    @memcpy(q.name[0..name.len], name);
    queues.lock.lock();
    q.next = queues.all;
    queues.all = q;
    queues.lock.unlock();
}

/// The queue a handle names, which cannot go away until `release`. Null:
/// not a queue there is.
fn hold(handle: usize) ?*Queue {
    queues.lock.lock();
    defer queues.lock.unlock();
    var q = queues.all;
    while (q) |x| : (q = x.next) {
        if (@intFromPtr(x) == handle) {
            x.users += 1;
            return x;
        }
    }
    return null;
}

fn release(q: *Queue) void {
    queues.lock.lock();
    q.users -= 1;
    const gone = q.closing and q.users == 0;
    queues.lock.unlock();
    if (gone and q.mapped) _ = sys.call(S.munmap, @intFromPtr(q), BYTES, 0, 0, 0, 0);
}

fn isTimer(filter: i16) bool {
    return filter == FILTER.TIMER or filter == FILTER.HRTIMER;
}

fn noteOf(q: *Queue, filter: i16, ident: u64) ?*Note {
    for (q.notes[0..q.high]) |*n| {
        if (n.used and n.filter == filter and n.ident == ident) return n;
    }
    return null;
}

fn freeNote(q: *Queue) ?*Note {
    for (q.notes[0..q.high]) |*n| {
        if (!n.used) return n;
    }
    if (q.high == CAPACITY) return null;
    q.high += 1;
    return &q.notes[q.high - 1];
}

/// Tells the threads asleep on the queue to look again. The queue's lock is
/// held on the way in and given back here.
fn changed(q: *Queue) void {
    q.seq +%= 1;
    const wake = @atomicLoad(u32, &q.sleepers, .monotonic) != 0;
    q.lock.unlock();
    if (wake) {
        _ = @atomicRmw(u64, &wakes, .Add, 1, .monotonic);
        pthread.wakeAll(&q.seq);
    }
}

/// Times a post entered the kernel to wake a sleeper (for tests: a post
/// with nobody asleep must not).
pub var wakes: u64 = 0;

// ── For the libraries that post events ──────────────────────────────────────

/// How an event behaves once it is on a queue.
pub const How = struct {
    /// What its `flags` and `fflags` say to the game.
    flags: u16 = 0,
    fflags: u32 = 0,
    clear: bool = false,
    once: bool = false,
    /// A timer: when it first runs out (ns, the clock that does not jump)
    /// and how often after (ns; 0: once).
    due: u64 = 0,
    period: u64 = 0,
};

/// Has queue `handle` watch for (`filter`, `ident`). One it watches already
/// takes the new settings and stays ready if it was. 0, or an errno: EBADF
/// (no such queue), ENOMEM (the queue is full).
pub fn add(handle: usize, filter: i16, ident: u64, udata: u64, how: How) c_int {
    const q = hold(handle) orelse return E.BADF;
    defer release(q);
    q.lock.lock();
    const n = noteOf(q, filter, ident) orelse fresh: {
        const f = freeNote(q) orelse {
            q.lock.unlock();
            return E.NOMEM;
        };
        f.* = .{ .used = true, .filter = filter, .ident = ident };
        if (isTimer(filter)) q.timers += 1;
        break :fresh f;
    };
    n.udata = udata;
    n.flags = how.flags;
    n.fflags = how.fflags;
    n.clear = how.clear;
    n.once = how.once;
    n.due = how.due;
    n.period = how.period;
    // (a thread asleep until an earlier timer must count this one in)
    if (isTimer(filter)) changed(q) else q.lock.unlock();
    return 0;
}

/// Stops queue `handle` watching for (`filter`, `ident`). 0, EBADF, or
/// ENOENT (it was not watching for that).
pub fn remove(handle: usize, filter: i16, ident: u64) c_int {
    const q = hold(handle) orelse return E.BADF;
    defer release(q);
    q.lock.lock();
    defer q.lock.unlock();
    const n = noteOf(q, filter, ident) orelse return E.NOENT;
    if (isTimer(filter)) q.timers -= 1;
    n.* = .{};
    return 0;
}

/// What a post does to an event's data: the old data and the poster's
/// argument in, the new data out.
pub const Change = *const fn (old: i64, arg: u64) i64;

/// Makes (`filter`, `ident`) ready on queue `handle` and wakes who waits
/// for it. `change` gives its data, `udata` (when given) replaces what the
/// game reads back as its user data. 0, EBADF, or ENOENT.
pub fn post(handle: usize, filter: i16, ident: u64, change: ?Change, arg: u64, udata: ?u64) c_int {
    const q = hold(handle) orelse return E.BADF;
    defer release(q);
    q.lock.lock();
    const n = noteOf(q, filter, ident) orelse {
        q.lock.unlock();
        return E.NOENT;
    };
    if (change) |f| n.data = f(n.data, arg);
    if (udata) |u| n.udata = u;
    n.ready = true;
    changed(q);
    return 0;
}

// ── Waiting ─────────────────────────────────────────────────────────────────

/// Marks the timers that have run out by `now` ready. When the next one
/// runs out, or null when none is running.
fn runTimers(q: *Queue, now: u64) ?u64 {
    var soonest: ?u64 = null;
    for (q.notes[0..q.high]) |*n| {
        if (!n.used or !isTimer(n.filter) or n.due == 0) continue;
        if (n.due <= now) {
            if (n.period == 0) {
                n.data = 1;
                n.due = 0;
            } else {
                // (how many times it ran out since it was last looked at)
                const times = 1 + (now - n.due) / n.period;
                n.data +|= @intCast(@min(times, std.math.maxInt(i32)));
                n.due += times * n.period;
            }
            n.ready = true;
        }
        if (n.due != 0) soonest = if (soonest) |s| @min(s, n.due) else n.due;
    }
    return soonest;
}

/// Copies the ready events out, starting after where the last read ended.
fn collect(q: *Queue, out: []Event) usize {
    var count: usize = 0;
    var seen: u32 = 0;
    var i = if (q.turn < q.high) q.turn else 0;
    while (seen < q.high and count < out.len) : (seen += 1) {
        const n = &q.notes[i];
        i = if (i + 1 == q.high) 0 else i + 1;
        if (!n.used or !n.ready) continue;
        out[count] = .{ .ident = n.ident, .filter = n.filter, .flags = n.flags, .fflags = n.fflags, .data = n.data, .udata = n.udata };
        count += 1;
        q.turn = i;
        if (n.once) {
            if (isTimer(n.filter)) q.timers -= 1;
            n.* = .{};
        } else if (n.clear) {
            n.ready = false;
            n.data = 0;
        }
    }
    return count;
}

/// Waits for events on queue `handle`: how many were copied to `out` (at
/// least one), or a negated errno: EBADF (no such queue, or it was deleted
/// meanwhile), ETIMEDOUT. No `timeout_us` waits for as long as it takes; 0
/// only looks.
pub fn wait(handle: usize, out: []Event, timeout_us: ?u64) i64 {
    const q = hold(handle) orelse return -@as(i64, E.BADF);
    defer release(q);
    var give_up: u64 = 0;
    while (true) {
        // (the clock is read only when something here is timed)
        const timed = (timeout_us orelse 0) != 0 or @atomicLoad(u32, &q.timers, .monotonic) != 0;
        const now: u64 = if (timed) pthread.nowNs() else 0;
        q.lock.lock();
        if (q.timers != 0 and !timed) {
            // (a timer was added just now: again, with the time)
            q.lock.unlock();
            continue;
        }
        const soonest: ?u64 = if (q.timers != 0) runTimers(q, now) else null;
        const n = collect(q, out);
        if (n != 0 or q.closing) {
            q.lock.unlock();
            return if (n != 0) @intCast(n) else -@as(i64, E.BADF);
        }
        var until = soonest;
        if (timeout_us) |us| {
            if (us != 0 and give_up == 0) give_up = now +| us *| 1000;
            if (us == 0 or now >= give_up) {
                q.lock.unlock();
                return -@as(i64, E.TIMEDOUT);
            }
            until = if (until) |s| @min(s, give_up) else give_up;
        }
        const seq = q.seq;
        _ = @atomicRmw(u32, &q.sleepers, .Add, 1, .monotonic);
        q.lock.unlock();
        pthread.waitWhileUntil(&q.seq, seq, until);
        _ = @atomicRmw(u32, &q.sleepers, .Sub, 1, .monotonic);
    }
}

// ── What a game calls ───────────────────────────────────────────────────────

fn sx(e: c_int) c_int {
    return if (e == 0) 0 else @bitCast(abi.SCE_KERNEL_ERROR_BASE + @as(u32, @intCast(e)));
}

fn identOf(id: c_int) u64 {
    return @bitCast(@as(i64, id));
}

fn sceKernelCreateEqueue(out: ?*usize, name: ?[*:0]const u8) callconv(.c) c_int {
    const o = out orelse return sx(E.INVAL);
    const n = std.mem.span(name orelse return sx(E.INVAL));
    if (n.len > 31) return sx(E.NAMETOOLONG);
    const r = sys.call(S.mmap, 0, BYTES, RW, abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
    if (r < 0) return sx(E.NOMEM);
    const q: *Queue = @ptrFromInt(@as(usize, @intCast(r)));
    setUp(q, n, true);
    o.* = @intFromPtr(q);
    return 0;
}

/// Deletes a queue. A thread waiting on it comes back with EBADF.
fn sceKernelDeleteEqueue(handle: usize) callconv(.c) c_int {
    queues.lock.lock();
    var link = &queues.all;
    const q = while (link.*) |x| : (link = &x.next) {
        if (@intFromPtr(x) == handle) break x;
    } else {
        queues.lock.unlock();
        return sx(E.BADF);
    };
    link.* = q.next;
    @atomicStore(bool, &q.closing, true, .release);
    q.users += 1;
    queues.lock.unlock();
    q.lock.lock();
    changed(q);
    release(q);
    return 0;
}

fn sceKernelWaitEqueue(handle: usize, events: ?[*]Event, num: c_int, out: ?*c_int, timeout: ?*const u32) callconv(.c) c_int {
    if (out) |o| o.* = 0;
    const ev = events orelse return sx(E.FAULT);
    if (num < 1) return sx(E.INVAL);
    const r = wait(handle, ev[0..@intCast(num)], if (timeout) |t| t.* else null);
    if (r < 0) return sx(@intCast(-r));
    if (out) |o| o.* = @intCast(r);
    return 0;
}

/// A user event that stays ready once posted, until it is deleted.
fn sceKernelAddUserEvent(handle: usize, id: c_int) callconv(.c) c_int {
    return sx(add(handle, FILTER.USER, identOf(id), 0, .{}));
}

/// A user event that is ready once for each time it is read after a post.
fn sceKernelAddUserEventEdge(handle: usize, id: c_int) callconv(.c) c_int {
    return sx(add(handle, FILTER.USER, identOf(id), 0, .{ .flags = EV.CLEAR, .clear = true }));
}

fn sceKernelDeleteUserEvent(handle: usize, id: c_int) callconv(.c) c_int {
    return sx(remove(handle, FILTER.USER, identOf(id)));
}

fn sceKernelTriggerUserEvent(handle: usize, id: c_int, udata: ?*anyopaque) callconv(.c) c_int {
    return sx(post(handle, FILTER.USER, identOf(id), null, 0, @intFromPtr(udata)));
}

/// A timer that runs out every `usec`. Its data, when read, is how many
/// times it has since it was last read.
fn sceKernelAddTimerEvent(handle: usize, id: c_int, usec: u32, udata: ?*anyopaque) callconv(.c) c_int {
    const period = @as(u64, @max(usec, 1)) * 1000;
    return sx(add(handle, FILTER.TIMER, identOf(id), @intFromPtr(udata), .{
        .flags = EV.CLEAR,
        .fflags = NOTE_USECONDS,
        .clear = true,
        .due = pthread.nowNs() + period,
        .period = period,
    }));
}

fn sceKernelDeleteTimerEvent(handle: usize, id: c_int) callconv(.c) c_int {
    return sx(remove(handle, FILTER.TIMER, identOf(id)));
}

/// A timer that runs out once, `length` from now, and is then gone.
fn sceKernelAddHRTimerEvent(handle: usize, id: c_int, length: ?*const abi.Timespec, udata: ?*anyopaque) callconv(.c) c_int {
    const t = length orelse return sx(E.FAULT);
    if (t.sec < 0 or t.nsec < 0 or t.nsec >= 1_000_000_000) return sx(E.INVAL);
    const ns = @max(@as(u64, @intCast(t.sec)) *| 1_000_000_000 +| @as(u64, @intCast(t.nsec)), 1);
    return sx(add(handle, FILTER.HRTIMER, identOf(id), @intFromPtr(udata), .{
        .flags = EV.ONESHOT,
        .once = true,
        .due = pthread.nowNs() +| ns,
    }));
}

fn sceKernelDeleteHRTimerEvent(handle: usize, id: c_int) callconv(.c) c_int {
    return sx(remove(handle, FILTER.HRTIMER, identOf(id)));
}

fn sceKernelGetEventId(ev: *const Event) callconv(.c) u64 {
    return ev.ident;
}
fn sceKernelGetEventFilter(ev: *const Event) callconv(.c) c_int {
    return ev.filter;
}
fn sceKernelGetEventFflags(ev: *const Event) callconv(.c) u32 {
    return ev.fflags;
}
fn sceKernelGetEventData(ev: *const Event) callconv(.c) i64 {
    return ev.data;
}
fn sceKernelGetEventUserData(ev: *const Event) callconv(.c) u64 {
    return ev.udata;
}
fn sceKernelGetEventError(ev: *const Event) callconv(.c) c_int {
    return @truncate(ev.data);
}

// ── The table ───────────────────────────────────────────────────────────────

fn entry(comptime name: []const u8, comptime f: anytype) pthread.Export {
    return .{ name, @ptrCast(f) };
}

/// Every name here, for libkernel's table.
pub const exports = [_]pthread.Export{
    entry("sceKernelCreateEqueue", &sceKernelCreateEqueue),
    entry("sceKernelDeleteEqueue", &sceKernelDeleteEqueue),
    entry("sceKernelWaitEqueue", &sceKernelWaitEqueue),
    entry("sceKernelAddUserEvent", &sceKernelAddUserEvent),
    entry("sceKernelAddUserEventEdge", &sceKernelAddUserEventEdge),
    entry("sceKernelDeleteUserEvent", &sceKernelDeleteUserEvent),
    entry("sceKernelTriggerUserEvent", &sceKernelTriggerUserEvent),
    entry("sceKernelAddTimerEvent", &sceKernelAddTimerEvent),
    entry("sceKernelDeleteTimerEvent", &sceKernelDeleteTimerEvent),
    entry("sceKernelAddHRTimerEvent", &sceKernelAddHRTimerEvent),
    entry("sceKernelDeleteHRTimerEvent", &sceKernelDeleteHRTimerEvent),
    entry("sceKernelGetEventId", &sceKernelGetEventId),
    entry("sceKernelGetEventFilter", &sceKernelGetEventFilter),
    entry("sceKernelGetEventFflags", &sceKernelGetEventFflags),
    entry("sceKernelGetEventData", &sceKernelGetEventData),
    entry("sceKernelGetEventUserData", &sceKernelGetEventUserData),
    entry("sceKernelGetEventError", &sceKernelGetEventError),
};

// ── Tests ───────────────────────────────────────────────────────────────────
//
// What needs no kernel: a queue in memory the test owns, events that are
// ready when they are asked for, and a wait that only looks. Threads that
// sleep on a queue and timers are tested under a kernel that speaks this
// ABI (Galaxy's twin test).

/// A queue in memory a test owns (no kernel to map one), for the tests of
/// the libraries that post events.
pub const TestQueue = Queue;

pub fn testQueue(storage: *TestQueue, name: []const u8) usize {
    // (memory that is a queue already is first taken off the list: listed
    // twice, it would follow itself)
    _ = sceKernelDeleteEqueue(@intFromPtr(storage));
    setUp(storage, name, false);
    return @intFromPtr(storage);
}

pub fn testDelete(handle: usize) void {
    _ = sceKernelDeleteEqueue(handle);
}

const Testing = struct {
    var storage: [3]Queue = undefined;

    fn queue(i: usize, name: []const u8) usize {
        setUp(&storage[i], name, false);
        return @intFromPtr(&storage[i]);
    }
};

test "an event is the kernel's kevent" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Event));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Event, "filter"));
    try std.testing.expectEqual(@as(usize, 10), @offsetOf(Event, "flags"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Event, "fflags"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Event, "data"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Event, "udata"));
    try std.testing.expect(CAPACITY >= 1000);
}

test "user events: one that stays ready, and one read once per post" {
    const q = Testing.queue(0, "test");
    defer _ = sceKernelDeleteEqueue(q);
    var ev: [4]Event = undefined;
    var n: c_int = -1;
    const now: u32 = 0;

    // Nothing posted: a look finds nothing, and says so Sony's way.
    try std.testing.expectEqual(sx(E.TIMEDOUT), sceKernelWaitEqueue(q, &ev, 4, &n, &now));
    try std.testing.expectEqual(@as(c_int, 0), n);
    // A post to an event the queue does not watch.
    try std.testing.expectEqual(sx(E.NOENT), sceKernelTriggerUserEvent(q, 7, null));

    try std.testing.expectEqual(@as(c_int, 0), sceKernelAddUserEvent(q, 7));
    try std.testing.expectEqual(@as(c_int, 0), sceKernelAddUserEventEdge(q, 8));
    try std.testing.expectEqual(@as(c_int, 0), sceKernelTriggerUserEvent(q, 7, @ptrFromInt(0x1111)));
    try std.testing.expectEqual(@as(c_int, 0), sceKernelTriggerUserEvent(q, 8, @ptrFromInt(0x2222)));

    try std.testing.expectEqual(@as(c_int, 0), sceKernelWaitEqueue(q, &ev, 4, &n, &now));
    try std.testing.expectEqual(@as(c_int, 2), n);
    try std.testing.expectEqual(@as(u64, 7), sceKernelGetEventId(&ev[0]));
    try std.testing.expectEqual(@as(c_int, FILTER.USER), sceKernelGetEventFilter(&ev[0]));
    try std.testing.expectEqual(@as(u64, 0x1111), sceKernelGetEventUserData(&ev[0]));
    try std.testing.expectEqual(@as(u64, 8), ev[1].ident);
    try std.testing.expectEqual(@as(u64, 0x2222), ev[1].udata);
    try std.testing.expectEqual(EV.CLEAR, ev[1].flags);

    // Read again: the first is still ready (until deleted), the second not.
    try std.testing.expectEqual(@as(c_int, 0), sceKernelWaitEqueue(q, &ev, 4, &n, &now));
    try std.testing.expectEqual(@as(c_int, 1), n);
    try std.testing.expectEqual(@as(u64, 7), ev[0].ident);
    try std.testing.expectEqual(@as(c_int, 0), sceKernelDeleteUserEvent(q, 7));
    try std.testing.expectEqual(sx(E.TIMEDOUT), sceKernelWaitEqueue(q, &ev, 4, &n, &now));
    try std.testing.expectEqual(sx(E.NOENT), sceKernelDeleteUserEvent(q, 7));

    // What a call is told that it cannot use.
    try std.testing.expectEqual(sx(E.FAULT), sceKernelWaitEqueue(q, null, 4, &n, &now));
    try std.testing.expectEqual(sx(E.INVAL), sceKernelWaitEqueue(q, &ev, 0, &n, &now));
    try std.testing.expectEqual(sx(E.INVAL), sceKernelCreateEqueue(null, "x"));
    var h: usize = 0;
    try std.testing.expectEqual(sx(E.INVAL), sceKernelCreateEqueue(&h, null));
    try std.testing.expectEqual(sx(E.NAMETOOLONG), sceKernelCreateEqueue(&h, "a name of more than thirty-one bytes"));
}

test "a handle is looked up, never read through" {
    const q = Testing.queue(1, "gone");
    var ev: [1]Event = undefined;
    var n: c_int = 0;
    const now: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 0), sceKernelAddUserEvent(q, 1));
    try std.testing.expectEqual(@as(c_int, 0), sceKernelDeleteEqueue(q));
    // Deleted: every call refuses the handle (its memory is still the
    // test's own, so a call that read through it would seem to work).
    try std.testing.expectEqual(sx(E.BADF), sceKernelDeleteEqueue(q));
    try std.testing.expectEqual(sx(E.BADF), sceKernelAddUserEvent(q, 2));
    try std.testing.expectEqual(sx(E.BADF), sceKernelTriggerUserEvent(q, 1, null));
    try std.testing.expectEqual(sx(E.BADF), sceKernelWaitEqueue(q, &ev, 1, &n, &now));
    // And numbers that never were a queue.
    try std.testing.expectEqual(sx(E.BADF), sceKernelAddUserEvent(0, 1));
    try std.testing.expectEqual(sx(E.BADF), sceKernelAddUserEvent(0x1234_5678, 1));
}

fn countUp(old: i64, arg: u64) i64 {
    return old + @as(i64, @intCast(arg));
}

test "a library's events: data that adds up between reads, a full queue, a fair turn" {
    const q = Testing.queue(2, "lib");
    defer _ = sceKernelDeleteEqueue(q);
    var ev: [2]Event = undefined;

    try std.testing.expectEqual(@as(c_int, 0), add(q, FILTER.VIDEO_OUT, 6, 0xAA, .{ .clear = true }));
    try std.testing.expectEqual(@as(c_int, E.NOENT), post(q, FILTER.VIDEO_OUT, 7, countUp, 1, null));
    try std.testing.expectEqual(@as(c_int, 0), post(q, FILTER.VIDEO_OUT, 6, countUp, 1, null));
    try std.testing.expectEqual(@as(c_int, 0), post(q, FILTER.VIDEO_OUT, 6, countUp, 2, null));
    try std.testing.expectEqual(@as(i64, 1), wait(q, &ev, 0));
    try std.testing.expectEqual(@as(i64, 3), ev[0].data);
    try std.testing.expectEqual(@as(u64, 0xAA), ev[0].udata);
    try std.testing.expectEqual(FILTER.VIDEO_OUT, ev[0].filter);
    // Read: it is no longer ready, and its data starts again.
    try std.testing.expectEqual(-@as(i64, E.TIMEDOUT), wait(q, &ev, 0));
    try std.testing.expectEqual(@as(c_int, 0), post(q, FILTER.VIDEO_OUT, 6, countUp, 5, null));
    try std.testing.expectEqual(@as(i64, 1), wait(q, &ev, 0));
    try std.testing.expectEqual(@as(i64, 5), ev[0].data);
    // The same identity under another filter is another event.
    try std.testing.expectEqual(@as(c_int, E.NOENT), post(q, FILTER.GRAPHICS_CORE, 6, null, 0, null));

    // Three events that stay ready, read two at a time: each gets its turn.
    try std.testing.expectEqual(@as(c_int, 0), remove(q, FILTER.VIDEO_OUT, 6));
    for (0..3) |i| {
        try std.testing.expectEqual(@as(c_int, 0), add(q, FILTER.USER, i, 0, .{}));
        try std.testing.expectEqual(@as(c_int, 0), post(q, FILTER.USER, i, null, 0, null));
    }
    var seen = [_]u32{0} ** 3;
    for (0..3) |_| {
        try std.testing.expectEqual(@as(i64, 2), wait(q, &ev, 0));
        seen[@intCast(ev[0].ident)] += 1;
        seen[@intCast(ev[1].ident)] += 1;
    }
    try std.testing.expectEqualSlices(u32, &.{ 2, 2, 2 }, &seen);

    // A queue has room for CAPACITY events and says when it is full.
    for (3..CAPACITY) |i| try std.testing.expectEqual(@as(c_int, 0), add(q, FILTER.USER, i, 0, .{}));
    try std.testing.expectEqual(@as(c_int, E.NOMEM), add(q, FILTER.USER, CAPACITY, 0, .{}));
    // (one it watches already is not a new one)
    try std.testing.expectEqual(@as(c_int, 0), add(q, FILTER.USER, 5, 0, .{}));
    try std.testing.expectEqual(@as(c_int, 0), remove(q, FILTER.USER, 5));
    try std.testing.expectEqual(@as(c_int, 0), add(q, FILTER.USER, CAPACITY, 0, .{}));
}
