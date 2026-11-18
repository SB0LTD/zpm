//! @zpm/ps5 pthread — a PS5 program's threads and what they wait on, the
//! part of the console's libkernel that is FreeBSD's thread library:
//! threads, mutexes, condition variables, read-write locks, thread-specific
//! keys and once. Written in Sig on two things the kernel gives: `thr_new`
//! and `thr_exit` for the threads, and `_umtx_op`'s plain wait and wake for
//! everything that sleeps.
//!
//! The locks live in user memory. One nobody else holds is taken and given
//! back with a single compare-and-swap and no system call; a thread enters
//! the kernel only to sleep, or to wake one that does.
//!
//! As on the console, a program's `pthread_mutex_t` (and cond, rwlock,
//! attribute) is a pointer this library fills in: 0 is "not made yet" (a
//! static initialiser; the object is made on first use). The objects come
//! from a pool of 64-byte slots mapped a chunk at a time: nothing is
//! allocated from a heap, and a slot given back is used again.
//!
//! Two faces for every call, as libkernel has them:
//!   - `pthread_*`: 0, or an errno as the result;
//!   - `scePthread*`: 0, or 0x80020000 + errno.
//!
//! Not here: cancelling a thread (its state and type are kept, and
//! nothing ever cancels), signals to a thread, priority inheritance and
//! ceilings (the attributes are kept and read back; scheduling is the
//! kernel's own), process-shared objects, semaphores.
//!
//! No Sony code: the behaviour is FreeBSD 11's libthr (BSD licence) as
//! documented, and Sony's names for it as open projects list them. x86-64
//! only. Allocation-free.

const std = @import("std");
const sys = @import("sys.sig");
const abi = @import("abi.sig");

const S = abi.Sys;
const E = abi.E;
const PAGE = abi.PAGE;
const RW = abi.PROT.READ | abi.PROT.WRITE;
const NO_FD: u64 = ~@as(u64, 0);

// ── Waiting and waking ──────────────────────────────────────────────────────

/// Sleeps while `word` holds `value` (until woken, or `until`). 0, or a
/// negated errno: ETIMEDOUT, EINTR.
fn waitWord(word: *const u32, value: u32, until: ?*const abi.UmtxTime) i64 {
    if (until) |t| return sys.call(S._umtx_op, @intFromPtr(word), abi.UMTX.WAIT_UINT_PRIVATE, value, @sizeOf(abi.UmtxTime), @intFromPtr(t), 0);
    return sys.call(S._umtx_op, @intFromPtr(word), abi.UMTX.WAIT_UINT_PRIVATE, value, 0, 0, 0);
}

fn wakeWord(word: *const u32, count: u32) void {
    _ = sys.call(S._umtx_op, @intFromPtr(word), abi.UMTX.WAKE_PRIVATE, count, 0, 0, 0);
}

const EVERYONE: u32 = std.math.maxInt(i32);

/// The same two for the runtime's own waits (a module's start function
/// that another thread must see finished).
pub fn waitWhile(word: *const u32, value: u32) void {
    _ = waitWord(word, value, null);
}
pub fn wakeAll(word: *const u32) void {
    wakeWord(word, EVERYONE);
}

/// A lock in one word: 0 free, 1 held, 2 held and someone may be asleep on
/// it. Taking a free one and giving back an uncontended one never enter
/// the kernel.
fn lockWord(word: *u32, until: ?*const abi.UmtxTime, spins: u32) bool {
    // (a lock held for a few instructions is cheaper to wait out than to
    // sleep on, when there is another core to be holding it)
    var n = if (cores > 1) spins else 0;
    while (n != 0) : (n -= 1) {
        if (@atomicLoad(u32, word, .monotonic) == 0 and @cmpxchgWeak(u32, word, 0, 1, .acquire, .monotonic) == null) return true;
        std.atomic.spinLoopHint();
    }
    while (@atomicRmw(u32, word, .Xchg, 2, .acquire) != 0) {
        // (out of time: one last look, since a lock taken must be kept)
        if (waitWord(word, 2, until) == -@as(i64, E.TIMEDOUT)) return @atomicRmw(u32, word, .Xchg, 2, .acquire) == 0;
    }
    return true;
}

fn tryWord(word: *u32) bool {
    return @cmpxchgStrong(u32, word, 0, 1, .acquire, .monotonic) == null;
}

fn unlockWord(word: *u32) void {
    if (@atomicRmw(u32, word, .Xchg, 0, .release) == 2) wakeWord(word, 1);
}

/// The library's own lock (its lists and pool: held for a few instructions).
pub const Lock = struct {
    word: u32 = 0,

    pub fn lock(l: *Lock) void {
        if (!tryWord(&l.word)) _ = lockWord(&l.word, null, 0);
    }
    pub fn unlock(l: *Lock) void {
        unlockWord(&l.word);
    }
};

/// Cores a thread may run on (a lock spins only when there are several).
var cores: u32 = 1;

// ── Time ────────────────────────────────────────────────────────────────────

/// A wait's end, `usec` from now: an absolute time on the clock that does
/// not jump, so a wait that is resumed does not start over.
fn after(usec: u64) abi.UmtxTime {
    var now: abi.Timespec = .{};
    _ = sys.call(S.clock_gettime, abi.CLOCK.MONOTONIC, @intFromPtr(&now), 0, 0, 0, 0);
    const nsec = @as(u64, @intCast(now.nsec)) + (usec % 1_000_000) * 1000;
    return .{
        .timeout = .{ .sec = now.sec +| @as(i64, @intCast(@min(usec / 1_000_000, 1 << 40))) + @as(i64, @intCast(nsec / 1_000_000_000)), .nsec = @intCast(nsec % 1_000_000_000) },
        .flags = abi.UmtxTime.ABSTIME,
        .clockid = abi.CLOCK.MONOTONIC,
    };
}

/// A wait's end a program gave as a length of time. Null when it is not
/// one.
fn afterSpec(length: ?*const abi.Timespec) ?abi.UmtxTime {
    const t = length orelse return null;
    if (t.sec < 0 or t.nsec < 0 or t.nsec >= 1_000_000_000) return null;
    return after(@as(u64, @intCast(t.sec)) *| 1_000_000 +| @as(u64, @intCast(t.nsec)) / 1000);
}

/// A wait's end a program gave as a time of day (or on `clock`). Null when
/// it is not a time at all.
fn at(when: ?*const abi.Timespec, clock: u32) ?abi.UmtxTime {
    const t = when orelse return null;
    if (t.sec < 0 or t.nsec < 0 or t.nsec >= 1_000_000_000) return null;
    return .{ .timeout = t.*, .flags = abi.UmtxTime.ABSTIME, .clockid = clock };
}

// ── The pool the objects come from ──────────────────────────────────────────

const SLOT = 64;

const Slot = extern struct {
    next: ?*Slot align(SLOT),
    rest: [SLOT - 8]u8,
};

const pool = struct {
    const CHUNK: u64 = 64 << 10;
    var lock: Lock = .{};
    var free: ?*Slot = null;

    /// A zeroed slot, or null when the kernel has no more memory.
    fn take() ?*Slot {
        lock.lock();
        if (free == null) {
            const r = sys.call(S.mmap, 0, CHUNK, RW, abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
            if (r < 0) {
                lock.unlock();
                return null;
            }
            const slots: [*]Slot = @ptrFromInt(@as(usize, @intCast(r)));
            var i: usize = CHUNK / SLOT;
            while (i != 0) {
                i -= 1;
                slots[i].next = free;
                free = &slots[i];
            }
        }
        const s = free.?;
        free = s.next;
        lock.unlock();
        s.* = std.mem.zeroes(Slot);
        return s;
    }

    fn give(s: *Slot) void {
        // (its tag goes first: a stale handle to it is then refused)
        s.* = std.mem.zeroes(Slot);
        lock.lock();
        s.next = free;
        free = s;
        lock.unlock();
    }
};

fn make(comptime T: type) ?*T {
    comptime std.debug.assert(@sizeOf(T) <= SLOT and @alignOf(T) <= SLOT);
    const s = pool.take() orelse return null;
    const t: *T = @ptrCast(s);
    t.tag = T.TAG;
    return t;
}

fn unmake(p: anytype) void {
    pool.give(@ptrCast(@alignCast(p)));
}

/// What a program's handle holds for an object not made yet (a static
/// initialiser), and for one destroyed.
const UNMADE: usize = 0;
const ADAPTIVE_UNMADE: usize = 1;

/// The object a handle names, made now if its handle is a static
/// initialiser. Null: no handle, a destroyed one, or not such an object.
fn object(comptime T: type, handle: ?*usize) ?*T {
    const h = handle orelse return null;
    var v = @atomicLoad(usize, h, .acquire);
    if (v == UNMADE or (T == Mutex and v == ADAPTIVE_UNMADE)) {
        const fresh = make(T) orelse return null;
        fresh.init(v);
        if (@cmpxchgStrong(usize, h, v, @intFromPtr(fresh), .acq_rel, .acquire)) |other| {
            // (another thread made it first: theirs is the one)
            unmake(fresh);
            v = other;
        } else return fresh;
    }
    if (v < 4096 or v & (@alignOf(T) - 1) != 0) return null;
    const t: *T = @ptrFromInt(v);
    return if (t.tag == T.TAG) t else null;
}

/// The object a handle names, for a call that only reads it (an attribute
/// object: never made on the way).
fn existing(comptime T: type, handle: ?*const usize) ?*T {
    const h = handle orelse return null;
    const v = h.*;
    if (v < 4096 or v & (@alignOf(T) - 1) != 0) return null;
    const t: *T = @ptrFromInt(v);
    return if (t.tag == T.TAG) t else null;
}

/// Destroys what a handle names. A static initialiser never used has
/// nothing to destroy.
fn destroy(comptime T: type, handle: ?*usize) c_int {
    const h = handle orelse return E.INVAL;
    const v = h.*;
    if (v == UNMADE or (T == Mutex and v == ADAPTIVE_UNMADE)) {
        h.* = DESTROYED;
        return 0;
    }
    const t = existing(T, h) orelse return E.INVAL;
    if (t.busy()) {
        // FreeBSD refuses a mutex that is held. A condition or a
        // read-write lock in use it destroys all the same: the handle
        // goes, and the slot is not used again, since threads still
        // inside it will write to it on their way out.
        if (T == Mutex) return E.BUSY;
        h.* = DESTROYED;
        return 0;
    }
    h.* = DESTROYED;
    unmake(t);
    return 0;
}

const DESTROYED: usize = 2;

// ── A thread ────────────────────────────────────────────────────────────────

pub const KEYS = 256;

const Specific = extern struct { value: ?*anyopaque = null, seq: u32 = 0, _pad: u32 = 0 };

pub const Entry = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

/// What the library keeps for each thread; the thread's control block (FS)
/// points at it from its third word, and a program's `pthread_t` is its
/// address.
pub const Thread = extern struct {
    errno: c_int = 0,
    magic: u32 = 0,
    /// The kernel's id for it (the kernel writes it before the thread runs).
    tid: i64 = 0,
    /// 1 once the kernel has ended the thread: its stack is then free.
    exited: i64 = 0,
    entry: ?Entry = null,
    arg: ?*anyopaque = null,
    result: ?*anyopaque = null,
    /// Under `threads.lock`: nobody will join it; its code has returned;
    /// someone is joining it.
    detached: bool = false,
    done: bool = false,
    joined: bool = false,
    /// Read locks it holds (a reader that holds one is not made to stand
    /// behind a waiting writer: it would wait for itself).
    rdlocks: u32 = 0,
    /// The memory made for it (0: not this library's, the first thread).
    mapping: u64 = 0,
    mapping_size: u64 = 0,
    stack_addr: u64 = 0,
    stack_size: u64 = 0,
    guard_size: u64 = 0,
    /// Its thread pointer.
    tp: u64 = 0,
    policy: i32 = SCHED_FIFO,
    prio: i32 = PRIO_DEFAULT,
    affinity: u64 = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    next: ?*Thread = null,
    next_dead: ?*Thread = null,
    /// What it pushed to run should it end early (the newest first).
    cleanup: ?*Cleanup = null,
    /// What it said about being cancelled (kept; nothing cancels).
    cancel_state: c_int = 0,
    cancel_type: c_int = 0,
    specific: [KEYS]Specific = [_]Specific{.{}} ** KEYS,

    const MAGIC: u32 = 0x5448_5244; // "THRD"
};

/// The control block FS points at: itself, the thread's storage vector,
/// its Thread (FreeBSD's layout, which a game's own code reads: `fs:0`).
pub const Tcb = extern struct {
    self: u64,
    dtv: u64 = 0,
    thread: u64,
};

/// Bytes the control block takes before the Thread that follows it.
const TCB_BYTES = 64;

const SCHED_FIFO = 1;
/// Sony's default priority (its range is 256 to 767; lower runs first).
const PRIO_DEFAULT = 700;
const PRIO_MIN = 256;
const PRIO_MAX = 767;

/// A new thread's stack when its attributes do not say (the console's),
/// the least one may ask for, and the page nothing may touch below it.
/// SIZE_MOST: the most a stack or its guard may be said to be (more than
/// any address space here has: the sums below cannot wrap).
const STACK_DEFAULT: u64 = 1 << 20;
const STACK_MIN: u64 = 16 << 10;
const GUARD_DEFAULT: u64 = PAGE;
const SIZE_MOST: u64 = 1 << 40;

/// Threads' memory given back so far (a test's question).
pub var given_back: u32 = 0;

var early: Thread = .{};

/// Set once the first thread has its control block: from then on every
/// thread has one before it runs a game's code.
pub var threads_ready: bool = false;

/// The calling thread's state (before the first control block exists: one
/// shared block, for the code that runs first).
pub fn thread() *Thread {
    if (!threads_ready) return &early;
    const t = sys.fs16();
    return if (t == 0) &early else @ptrFromInt(t);
}

const threads = struct {
    var lock: Lock = .{};
    /// Every thread that has memory or a handle: running, or done and
    /// waiting to be joined or reaped.
    var all: ?*Thread = null;
    /// Detached threads whose code has returned: their memory goes once
    /// the kernel says they are gone.
    var dead: ?*Thread = null;
    /// Threads still running the program's code.
    var active: u32 = 1;
};

/// What a thread's storage needs below its thread pointer, and how one is
/// filled: the runtime's (it has the linker). The size is fixed before the
/// first thread and has room to spare, so a module loaded later finds its
/// place in every thread already running.
pub var tls_capacity: u64 = 0;
pub var tls_init: ?*const fn (tp: u64) void = null;

/// The first thread, which the kernel made: `t` becomes its state, with
/// its thread pointer and the stack the runtime gave it.
pub fn adoptFirst(t: *Thread, tp: u64, stack_addr: u64, stack_size: u64) void {
    var tid: i64 = 0;
    _ = sys.call(S.thr_self, @intFromPtr(&tid), 0, 0, 0, 0, 0);
    t.* = .{ .magic = Thread.MAGIC, .tid = tid, .tp = tp, .stack_addr = stack_addr, .stack_size = stack_size, .guard_size = GUARD_DEFAULT };
    t.errno = early.errno;
    @memcpy(t.name[0..10], "MainThread");
    threads.all = t;
    var n: u32 = 0;
    var len: u64 = 4;
    var mib = [_]i32{ abi.CTL.HW, abi.CTL.HW_NCPU };
    if (sys.call(S.__sysctl, @intFromPtr(&mib), 2, @intFromPtr(&n), @intFromPtr(&len), 0, 0) == 0 and n != 0) cores = n;
    t.affinity = allCores();
}

fn allCores() u64 {
    return if (cores >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(cores)) - 1;
}

/// Calls `f` with every thread's thread pointer (a module loaded while
/// threads run: its storage is filled in each).
pub fn forEachThread(f: *const fn (tp: u64) void) void {
    threads.lock.lock();
    defer threads.lock.unlock();
    var t = threads.all;
    while (t) |x| : (t = x.next) {
        if (x.tp != 0) f(x.tp);
    }
}

/// The thread a handle names, if there is such a thread: looked for by
/// its address among the threads there are, never read through (the
/// handle of a detached thread that has ended names memory that is gone,
/// and FreeBSD answers ESRCH for it). The caller holds `threads.lock`,
/// and reads or writes the thread only while it does.
fn find(target: ?*Thread) ?*Thread {
    const x = target orelse return null;
    var t = threads.all;
    while (t) |y| : (t = y.next) {
        if (y == x) return x;
    }
    return null;
}

fn unlink(t: *Thread) void {
    var link: *?*Thread = &threads.all;
    while (link.*) |x| : (link = &x.next) {
        if (x == t) {
            link.* = t.next;
            return;
        }
    }
}

/// Gives a thread's memory back. It is off every list, and the kernel has
/// said it is gone.
fn unmap(t: *Thread) void {
    t.magic = 0;
    if (t.mapping == 0) return;
    _ = sys.call(S.munmap, t.mapping, t.mapping_size, 0, 0, 0, 0);
    _ = @atomicRmw(u32, &given_back, .Add, 1, .monotonic);
}

/// The memory of detached threads that have ended.
fn reap() void {
    if (@atomicLoad(?*Thread, &threads.dead, .monotonic) == null) return;
    var gone: ?*Thread = null;
    threads.lock.lock();
    var link: *?*Thread = &threads.dead;
    while (link.*) |t| {
        if (@atomicLoad(i64, &t.exited, .acquire) == 1) {
            link.* = t.next_dead;
            unlink(t);
            t.next_dead = gone;
            gone = t;
        } else link = &t.next_dead;
    }
    threads.lock.unlock();
    while (gone) |t| {
        gone = t.next_dead;
        unmap(t);
    }
}

/// Where a new thread begins: the kernel starts it here with its Thread.
fn threadMain(t: *Thread) callconv(.c) noreturn {
    exitThread(t.entry.?(t.arg));
}

/// What the program's C library asked to have run when a thread ends (its
/// C++ `thread_local` destructors).
var thread_dtors: ?*const fn () callconv(.c) void = null;

fn exitThread(result: ?*anyopaque) noreturn {
    const t = thread();
    // FreeBSD's order: what the thread pushed, the C library's own, then
    // the keys' destructors.
    while (t.cleanup != null) __pthread_cleanup_pop_imp(1);
    if (@atomicLoad(?*const fn () callconv(.c) void, &thread_dtors, .acquire)) |dtors| dtors();
    runDestructors(t);
    threads.lock.lock();
    t.result = result;
    t.done = true;
    threads.active -= 1;
    const last = threads.active == 0;
    if (t.detached and t.mapping != 0) {
        t.next_dead = threads.dead;
        @atomicStore(?*Thread, &threads.dead, t, .release);
    }
    threads.lock.unlock();
    // (the last thread to go ends the process, as FreeBSD's library does)
    if (last) _ = sys.call(S.exit, 0, 0, 0, 0, 0, 0);
    // The kernel stores 1 in `exited` and wakes who waits on it, when this
    // thread no longer runs on its stack.
    _ = sys.call(S.thr_exit, @intFromPtr(&t.exited), 0, 0, 0, 0, 0);
    while (true) {}
}

const AttrValues = struct {
    detached: bool = false,
    stack_addr: u64 = 0,
    stack_size: u64 = STACK_DEFAULT,
    guard_size: u64 = GUARD_DEFAULT,
    policy: i32 = SCHED_FIFO,
    prio: i32 = PRIO_DEFAULT,
    affinity: u64 = 0,
};

fn create(out: ?*?*Thread, attr: ?*const usize, entry: ?Entry, arg: ?*anyopaque, name: ?[*:0]const u8) c_int {
    const o = out orelse return E.INVAL;
    const f = entry orelse return E.INVAL;
    var a = AttrValues{};
    if (attr) |h| {
        if (h.* != 0) a = (existing(Attr, h) orelse return E.INVAL).values();
    }
    reap();
    // One mapping: a page nothing may touch, the stack above it, the
    // thread's storage, then its control block and state. (A stack the
    // program brought: only the last two.)
    const own_stack = a.stack_addr == 0;
    const stack = if (own_stack) std.mem.alignForward(u64, @max(a.stack_size, STACK_MIN), PAGE) else 0;
    const guard = if (own_stack) std.mem.alignForward(u64, a.guard_size, PAGE) else 0;
    const storage = std.mem.alignForward(u64, tls_capacity, PAGE);
    const tail = std.mem.alignForward(u64, TCB_BYTES + @sizeOf(Thread), PAGE);
    const total = guard + stack + storage + tail;
    const r = sys.call(S.mmap, 0, total, RW, abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
    if (r < 0) return E.AGAIN;
    const base: u64 = @intCast(r);
    if (guard != 0 and sys.call(S.mprotect, base, guard, 0, 0, 0, 0) != 0) {
        _ = sys.call(S.munmap, base, total, 0, 0, 0, 0);
        return E.AGAIN;
    }
    const tp = base + guard + stack + storage;
    const t: *Thread = @ptrFromInt(@as(usize, @intCast(tp + TCB_BYTES)));
    @as(*Tcb, @ptrFromInt(@as(usize, @intCast(tp)))).* = .{ .self = tp, .thread = @intFromPtr(t) };
    // (the mapping is zeroes: only what is not zero is written, and the
    // keys' page is not touched until the thread uses one)
    t.magic = Thread.MAGIC;
    t.entry = f;
    t.arg = arg;
    t.detached = a.detached;
    t.mapping = base;
    t.mapping_size = total;
    t.stack_addr = if (own_stack) base + guard else a.stack_addr;
    t.stack_size = if (own_stack) stack else a.stack_size;
    t.guard_size = guard;
    t.tp = tp;
    t.policy = a.policy;
    t.prio = a.prio;
    t.affinity = if (a.affinity != 0) a.affinity else allCores();
    setName(t, name);

    // Its storage is filled and the thread listed in one step: a module
    // loaded meanwhile either is among those filled here, or finds this
    // thread in the list and fills its own part (forEachThread).
    threads.lock.lock();
    if (tls_init) |fill| fill(tp);
    t.next = threads.all;
    threads.all = t;
    threads.active += 1;
    threads.lock.unlock();
    // (before it runs: a new thread may read its own handle from there)
    o.* = t;
    var prm = abi.ThrParam{
        .start_func = @intFromPtr(&threadMain),
        .arg = @intFromPtr(t),
        .stack_base = t.stack_addr,
        .stack_size = t.stack_size,
        .tls_base = tp,
        .tls_size = storage,
        .child_tid = @intFromPtr(&t.tid),
        .parent_tid = 0,
        .flags = 0,
        .rtp = 0,
    };
    const k = sys.call(S.thr_new, @intFromPtr(&prm), @sizeOf(abi.ThrParam), 0, 0, 0, 0);
    if (k < 0) {
        threads.lock.lock();
        unlink(t);
        threads.active -= 1;
        threads.lock.unlock();
        o.* = null;
        unmap(t);
        return E.AGAIN;
    }
    return 0;
}

fn setName(t: *Thread, name: ?[*:0]const u8) void {
    @memset(&t.name, 0);
    const n = std.mem.span(name orelse return);
    const len = @min(n.len, t.name.len - 1);
    @memcpy(t.name[0..len], n[0..len]);
}

fn join(target: ?*Thread, out: ?*?*anyopaque) c_int {
    threads.lock.lock();
    const t = find(target) orelse {
        threads.lock.unlock();
        return E.SRCH;
    };
    // (FreeBSD's answers: itself, a detached one, one somebody joins already)
    const refused: c_int = if (t == thread()) E.DEADLK else if (t.detached) E.INVAL else if (t.joined) E.OPNOTSUPP else 0;
    if (refused != 0) {
        threads.lock.unlock();
        return refused;
    }
    // (from here it is this joiner's: nobody else unmaps it)
    t.joined = true;
    threads.lock.unlock();
    // The kernel's word for "gone": only then is its stack nobody's.
    while (@atomicLoad(i64, &t.exited, .acquire) != 1) {
        _ = sys.call(S._umtx_op, @intFromPtr(&t.exited), abi.UMTX.WAIT, 0, 0, 0, 0);
    }
    if (out) |p| p.* = t.result;
    threads.lock.lock();
    unlink(t);
    threads.lock.unlock();
    unmap(t);
    reap();
    return 0;
}

fn detach(target: ?*Thread) c_int {
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return E.SRCH;
    if (t.detached or t.joined) return E.INVAL;
    t.detached = true;
    if (t.done and t.mapping != 0) {
        t.next_dead = threads.dead;
        @atomicStore(?*Thread, &threads.dead, t, .release);
    }
    return 0;
}

// ── Threads, as a program calls them ────────────────────────────────────────

fn pthread_create(out: ?*?*Thread, attr: ?*const usize, entry: ?Entry, arg: ?*anyopaque) callconv(.c) c_int {
    return create(out, attr, entry, arg, null);
}
fn pthread_create_name_np(out: ?*?*Thread, attr: ?*const usize, entry: ?Entry, arg: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) c_int {
    return create(out, attr, entry, arg, name);
}
fn scePthreadCreate(out: ?*?*Thread, attr: ?*const usize, entry: ?Entry, arg: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) c_int {
    return sx(create(out, attr, entry, arg, name));
}
fn pthread_join(t: ?*Thread, out: ?*?*anyopaque) callconv(.c) c_int {
    return join(t, out);
}
fn pthread_detach(t: ?*Thread) callconv(.c) c_int {
    return detach(t);
}
fn pthread_exit(result: ?*anyopaque) callconv(.c) noreturn {
    exitThread(result);
}
fn pthread_self() callconv(.c) *Thread {
    return thread();
}
fn pthread_equal(a: ?*Thread, b: ?*Thread) callconv(.c) c_int {
    return @intFromBool(a == b);
}
fn pthread_yield() callconv(.c) void {
    _ = sys.call(S.sched_yield, 0, 0, 0, 0, 0, 0);
}
fn pthread_getthreadid_np() callconv(.c) c_int {
    return @intCast(thread().tid);
}
fn pthread_rename_np(target: ?*Thread, name: ?[*:0]const u8) callconv(.c) c_int {
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return E.SRCH;
    setName(t, name);
    return 0;
}
fn pthread_set_name_np(target: ?*Thread, name: ?[*:0]const u8) callconv(.c) void {
    _ = pthread_rename_np(target, name);
}
/// A thread's name, into 32 bytes of the caller's.
fn scePthreadGetname(target: ?*Thread, out: ?*[32]u8) callconv(.c) c_int {
    const o = out orelse return sx(E.INVAL);
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return sx(E.SRCH);
    o.* = t.name;
    return 0;
}
/// 1 on the program's first thread, 0 on any other.
fn pthread_main_np() callconv(.c) c_int {
    return @intFromBool(thread().mapping == 0);
}

const SchedParam = extern struct { priority: c_int };

fn pthread_setprio(target: ?*Thread, prio: c_int) callconv(.c) c_int {
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return E.SRCH;
    t.prio = prio;
    return 0;
}
fn scePthreadGetprio(target: ?*Thread, out: ?*c_int) callconv(.c) c_int {
    const o = out orelse return sx(E.INVAL);
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return sx(E.SRCH);
    o.* = t.prio;
    return 0;
}
fn pthread_setschedparam(target: ?*Thread, policy: c_int, param: ?*const SchedParam) callconv(.c) c_int {
    const p = param orelse return E.INVAL;
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return E.SRCH;
    t.policy = policy;
    t.prio = p.priority;
    return 0;
}
fn pthread_getschedparam(target: ?*Thread, policy: ?*c_int, param: ?*SchedParam) callconv(.c) c_int {
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return E.SRCH;
    if (policy) |p| p.* = t.policy;
    if (param) |p| p.priority = t.prio;
    return 0;
}
fn scePthreadSetaffinity(target: ?*Thread, mask: u64) callconv(.c) c_int {
    if (mask == 0) return sx(E.INVAL);
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return sx(E.SRCH);
    t.affinity = mask;
    return 0;
}
fn scePthreadGetaffinity(target: ?*Thread, out: ?*u64) callconv(.c) c_int {
    const o = out orelse return sx(E.INVAL);
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return sx(E.SRCH);
    o.* = t.affinity;
    return 0;
}
/// Sony's priorities, for any policy: 256 runs first, 767 last.
fn sched_get_priority_min(_: c_int) callconv(.c) c_int {
    return PRIO_MIN;
}
fn sched_get_priority_max(_: c_int) callconv(.c) c_int {
    return PRIO_MAX;
}

// ── What a thread runs when it ends, and being cancelled ────────────────────

/// One handler a thread pushed, in the storage its caller gave (FreeBSD's
/// `struct _pthread_cleanup_info`: eight words).
pub const Cleanup = extern struct {
    prev: ?*Cleanup,
    routine: ?*const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
    onheap: c_int = 0,
};

fn __pthread_cleanup_push_imp(routine: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque, info: ?*Cleanup) callconv(.c) void {
    const c = info orelse return;
    const t = thread();
    c.* = .{ .prev = t.cleanup, .routine = routine, .arg = arg };
    t.cleanup = c;
}

fn __pthread_cleanup_pop_imp(execute: c_int) callconv(.c) void {
    const t = thread();
    const c = t.cleanup orelse return;
    t.cleanup = c.prev;
    if (execute != 0) {
        if (c.routine) |run| run(c.arg);
    }
}

/// What the program's C library wants run at every thread's end.
fn _sceKernelSetThreadDtors(dtors: ?*const fn () callconv(.c) void) callconv(.c) void {
    @atomicStore(?*const fn () callconv(.c) void, &thread_dtors, dtors, .release);
}

/// Cancellation: no thread is ever cancelled here, so its state and type
/// are only kept and given back (a C library sets them around its own
/// calls whether or not anything cancels).
fn pthread_setcancelstate(state: c_int, old: ?*c_int) callconv(.c) c_int {
    if (state != 0 and state != 1) return E.INVAL;
    const t = thread();
    if (old) |o| o.* = t.cancel_state;
    t.cancel_state = state;
    return 0;
}
fn pthread_setcanceltype(kind: c_int, old: ?*c_int) callconv(.c) c_int {
    if (kind != 0 and kind != 2) return E.INVAL;
    const t = thread();
    if (old) |o| o.* = t.cancel_type;
    t.cancel_type = kind;
    return 0;
}
fn pthread_testcancel() callconv(.c) void {}

// ── Thread attributes ───────────────────────────────────────────────────────

pub const Attr = extern struct {
    tag: u32 align(SLOT),
    detached: u32 = 0,
    stack_addr: u64 = 0,
    stack_size: u64 = STACK_DEFAULT,
    guard_size: u64 = GUARD_DEFAULT,
    policy: i32 = SCHED_FIFO,
    prio: i32 = PRIO_DEFAULT,
    inherit: i32 = 4, // PTHREAD_INHERIT_SCHED
    _pad: i32 = 0,
    affinity: u64 = 0,

    const TAG: u32 = 0x5254_5441; // "ATTR"

    fn values(a: *const Attr) AttrValues {
        return .{ .detached = a.detached != 0, .stack_addr = a.stack_addr, .stack_size = a.stack_size, .guard_size = a.guard_size, .policy = a.policy, .prio = a.prio, .affinity = a.affinity };
    }
};

fn pthread_attr_init(h: ?*usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    const a = make(Attr) orelse return E.NOMEM;
    a.* = .{ .tag = Attr.TAG };
    p.* = @intFromPtr(a);
    return 0;
}
fn pthread_attr_destroy(h: ?*usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    const a = existing(Attr, p) orelse return E.INVAL;
    p.* = 0;
    unmake(a);
    return 0;
}
fn pthread_attr_setstacksize(h: ?*const usize, size: u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    if (size < STACK_MIN or size > SIZE_MOST) return E.INVAL;
    a.stack_size = size;
    return 0;
}
fn pthread_attr_getstacksize(h: ?*const usize, out: ?*u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    (out orelse return E.INVAL).* = a.stack_size;
    return 0;
}
fn pthread_attr_setstackaddr(h: ?*const usize, addr: u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    if (addr == 0) return E.INVAL;
    a.stack_addr = addr;
    return 0;
}
fn pthread_attr_getstackaddr(h: ?*const usize, out: ?*u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    (out orelse return E.INVAL).* = a.stack_addr;
    return 0;
}
fn pthread_attr_setstack(h: ?*const usize, addr: u64, size: u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    if (addr == 0 or size < STACK_MIN or size > SIZE_MOST) return E.INVAL;
    a.stack_addr = addr;
    a.stack_size = size;
    return 0;
}
fn pthread_attr_getstack(h: ?*const usize, addr: ?*u64, size: ?*u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    (addr orelse return E.INVAL).* = a.stack_addr;
    (size orelse return E.INVAL).* = a.stack_size;
    return 0;
}
fn pthread_attr_setguardsize(h: ?*const usize, size: u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    if (size > SIZE_MOST) return E.INVAL;
    a.guard_size = size;
    return 0;
}
fn pthread_attr_getguardsize(h: ?*const usize, out: ?*u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    (out orelse return E.INVAL).* = a.guard_size;
    return 0;
}
fn pthread_attr_setdetachstate(h: ?*const usize, state: c_int) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    if (state != 0 and state != 1) return E.INVAL;
    a.detached = @intCast(state);
    return 0;
}
fn pthread_attr_getdetachstate(h: ?*const usize, out: ?*c_int) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    (out orelse return E.INVAL).* = @intCast(a.detached);
    return 0;
}
fn pthread_attr_setinheritsched(h: ?*const usize, inherit: c_int) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    a.inherit = inherit;
    return 0;
}
fn pthread_attr_getinheritsched(h: ?*const usize, out: ?*c_int) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    (out orelse return E.INVAL).* = a.inherit;
    return 0;
}
fn pthread_attr_setschedpolicy(h: ?*const usize, policy: c_int) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    a.policy = policy;
    return 0;
}
fn pthread_attr_getschedpolicy(h: ?*const usize, out: ?*c_int) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    (out orelse return E.INVAL).* = a.policy;
    return 0;
}
fn pthread_attr_setschedparam(h: ?*const usize, param: ?*const SchedParam) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    a.prio = (param orelse return E.INVAL).priority;
    return 0;
}
fn pthread_attr_getschedparam(h: ?*const usize, param: ?*SchedParam) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    (param orelse return E.INVAL).priority = a.prio;
    return 0;
}
fn scePthreadAttrSetaffinity(h: ?*const usize, mask: u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return sx(E.INVAL);
    a.affinity = mask;
    return 0;
}
fn scePthreadAttrGetaffinity(h: ?*const usize, out: ?*u64) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return sx(E.INVAL);
    (out orelse return sx(E.INVAL)).* = if (a.affinity != 0) a.affinity else allCores();
    return 0;
}
/// A running thread's attributes, into an attribute object the program made.
fn pthread_attr_get_np(target: ?*Thread, h: ?*const usize) callconv(.c) c_int {
    const a = existing(Attr, h) orelse return E.INVAL;
    threads.lock.lock();
    defer threads.lock.unlock();
    const t = find(target) orelse return E.SRCH;
    a.detached = @intFromBool(t.detached);
    a.stack_addr = t.stack_addr;
    a.stack_size = t.stack_size;
    a.guard_size = t.guard_size;
    a.policy = t.policy;
    a.prio = t.prio;
    a.affinity = t.affinity;
    return 0;
}

// ── Mutexes ─────────────────────────────────────────────────────────────────

/// FreeBSD's mutex types (Sony's are the same numbers).
const MUTEX_ERRORCHECK = 1;
const MUTEX_RECURSIVE = 2;
const MUTEX_NORMAL = 3;
const MUTEX_ADAPTIVE = 4;

/// How long an adaptive mutex is watched before its waiter sleeps.
const ADAPTIVE_SPINS = 200;

pub const Mutex = extern struct {
    tag: u32 align(SLOT),
    /// The lock (lockWord).
    word: u32 = 0,
    /// Who holds it (a thread id; 0: nobody).
    owner: i64 = 0,
    /// Times its holder took it again (a recursive one).
    depth: u32 = 0,
    kind: u32 = MUTEX_ERRORCHECK,
    protocol: u32 = 0,

    const TAG: u32 = 0x5854_554d; // "MUTX"

    fn init(m: *Mutex, initialiser: usize) void {
        m.kind = if (initialiser == ADAPTIVE_UNMADE) MUTEX_ADAPTIVE else MUTEX_ERRORCHECK;
    }
    fn busy(m: *const Mutex) bool {
        return @atomicLoad(u32, &m.word, .monotonic) != 0;
    }
};

pub const MutexAttr = extern struct {
    tag: u32 align(SLOT),
    kind: u32 = MUTEX_ERRORCHECK,
    protocol: u32 = 0,
    ceiling: u32 = 0,
    pshared: u32 = 0,

    const TAG: u32 = 0x5254_414d; // "MATR"
};

fn me() i64 {
    return thread().tid;
}

/// A thread taking a mutex it holds.
fn mutexAgain(m: *Mutex, until: ?*const abi.UmtxTime, wait: bool) c_int {
    switch (m.kind) {
        MUTEX_RECURSIVE => {
            if (m.depth == std.math.maxInt(u32)) return E.AGAIN;
            m.depth += 1;
            return 0;
        },
        else => {
            if (!wait) return E.BUSY;
            // A checked one says so at once; with a time given, and for a
            // plain one, it waits for itself, as FreeBSD's does: until
            // that time, or for good.
            if (m.kind != MUTEX_NORMAL and until == null) return E.DEADLK;
            var never: u32 = 0;
            while (true) {
                if (waitWord(&never, 0, until) == -@as(i64, E.TIMEDOUT)) return E.TIMEDOUT;
            }
        },
    }
}

fn mutexLock(m: *Mutex, until: ?*const abi.UmtxTime) c_int {
    const tid = me();
    if (!tryWord(&m.word)) {
        if (@atomicLoad(i64, &m.owner, .monotonic) == tid) return mutexAgain(m, until, true);
        if (!lockWord(&m.word, until, if (m.kind == MUTEX_ADAPTIVE) ADAPTIVE_SPINS else 0)) return E.TIMEDOUT;
    }
    @atomicStore(i64, &m.owner, tid, .monotonic);
    return 0;
}

fn mutexTry(m: *Mutex) c_int {
    const tid = me();
    if (!tryWord(&m.word)) {
        return if (@atomicLoad(i64, &m.owner, .monotonic) == tid) mutexAgain(m, null, false) else E.BUSY;
    }
    @atomicStore(i64, &m.owner, tid, .monotonic);
    return 0;
}

fn mutexUnlock(m: *Mutex) c_int {
    if (@atomicLoad(i64, &m.owner, .monotonic) != me()) return E.PERM;
    if (m.depth != 0) {
        m.depth -= 1;
        return 0;
    }
    @atomicStore(i64, &m.owner, 0, .monotonic);
    unlockWord(&m.word);
    return 0;
}

fn pthread_mutex_init(h: ?*usize, attr: ?*const usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    var kind: u32 = MUTEX_ERRORCHECK;
    var protocol: u32 = 0;
    if (attr) |ah| {
        if (ah.* != 0) {
            const a = existing(MutexAttr, ah) orelse return E.INVAL;
            kind = a.kind;
            protocol = a.protocol;
        }
    }
    const m = make(Mutex) orelse return E.NOMEM;
    m.kind = kind;
    m.protocol = protocol;
    p.* = @intFromPtr(m);
    return 0;
}
fn pthread_mutex_destroy(h: ?*usize) callconv(.c) c_int {
    return destroy(Mutex, h);
}
fn pthread_mutex_lock(h: ?*usize) callconv(.c) c_int {
    return mutexLock(object(Mutex, h) orelse return E.INVAL, null);
}
fn pthread_mutex_trylock(h: ?*usize) callconv(.c) c_int {
    return mutexTry(object(Mutex, h) orelse return E.INVAL);
}
fn pthread_mutex_timedlock(h: ?*usize, when: ?*const abi.Timespec) callconv(.c) c_int {
    const m = object(Mutex, h) orelse return E.INVAL;
    // (a free one is taken whatever the time says)
    if (mutexTry(m) == 0) return 0;
    const until = at(when, abi.CLOCK.REALTIME) orelse return E.INVAL;
    return mutexLock(m, &until);
}
fn scePthreadMutexTimedlock(h: ?*usize, usec: u32) callconv(.c) c_int {
    const m = object(Mutex, h) orelse return sx(E.INVAL);
    const until = after(usec);
    return sx(mutexLock(m, &until));
}
fn pthread_mutex_unlock(h: ?*usize) callconv(.c) c_int {
    return mutexUnlock(object(Mutex, h) orelse return E.INVAL);
}
/// The same with a length of time, not a time of day.
fn pthread_mutex_reltimedlock_np(h: ?*usize, length: ?*const abi.Timespec) callconv(.c) c_int {
    const m = object(Mutex, h) orelse return E.INVAL;
    if (mutexTry(m) == 0) return 0;
    const until = afterSpec(length) orelse return E.INVAL;
    return mutexLock(m, &until);
}
/// Whether the calling thread holds it.
fn pthread_mutex_isowned_np(h: ?*usize) callconv(.c) c_int {
    const m = existing(Mutex, h) orelse return 0;
    return @intFromBool(@atomicLoad(i64, &m.owner, .monotonic) == me());
}

fn pthread_mutexattr_init(h: ?*usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    const a = make(MutexAttr) orelse return E.NOMEM;
    a.* = .{ .tag = MutexAttr.TAG };
    p.* = @intFromPtr(a);
    return 0;
}
fn pthread_mutexattr_destroy(h: ?*usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    const a = existing(MutexAttr, p) orelse return E.INVAL;
    p.* = 0;
    unmake(a);
    return 0;
}
fn pthread_mutexattr_settype(h: ?*const usize, kind: c_int) callconv(.c) c_int {
    const a = existing(MutexAttr, h) orelse return E.INVAL;
    if (kind < MUTEX_ERRORCHECK or kind > MUTEX_ADAPTIVE) return E.INVAL;
    a.kind = @intCast(kind);
    return 0;
}
fn pthread_mutexattr_gettype(h: ?*const usize, out: ?*c_int) callconv(.c) c_int {
    const a = existing(MutexAttr, h) orelse return E.INVAL;
    (out orelse return E.INVAL).* = @intCast(a.kind);
    return 0;
}
fn pthread_mutexattr_setprotocol(h: ?*const usize, protocol: c_int) callconv(.c) c_int {
    const a = existing(MutexAttr, h) orelse return E.INVAL;
    if (protocol < 0 or protocol > 2) return E.INVAL;
    a.protocol = @intCast(protocol);
    return 0;
}
fn pthread_mutexattr_getprotocol(h: ?*const usize, out: ?*c_int) callconv(.c) c_int {
    const a = existing(MutexAttr, h) orelse return E.INVAL;
    (out orelse return E.INVAL).* = @intCast(a.protocol);
    return 0;
}

// ── Condition variables ─────────────────────────────────────────────────────

pub const Cond = extern struct {
    tag: u32 align(SLOT),
    /// Counts signals: a waiter sleeps while it has not moved.
    seq: u32 = 0,
    /// Threads inside a wait (a signal with none enters no kernel).
    waiters: u32 = 0,
    /// The clock its timed waits are on.
    clock: u32 = abi.CLOCK.REALTIME,

    const TAG: u32 = 0x444e_4f43; // "COND"

    fn init(c: *Cond, _: usize) void {
        c.clock = abi.CLOCK.REALTIME;
    }
    fn busy(c: *const Cond) bool {
        return @atomicLoad(u32, &c.waiters, .monotonic) != 0;
    }
};

pub const CondAttr = extern struct {
    tag: u32 align(SLOT),
    clock: u32 = abi.CLOCK.REALTIME,
    pshared: u32 = 0,

    const TAG: u32 = 0x5254_4143; // "CATR"
};

fn condWait(c: *Cond, m: *Mutex, until: ?*const abi.UmtxTime) c_int {
    const tid = me();
    if (@atomicLoad(i64, &m.owner, .monotonic) != tid) return E.PERM;
    // Counted in, then the signal count read, both while the mutex is
    // held: a signal sent once the mutex is free moves the count, and the
    // sleep below does not begin.
    _ = @atomicRmw(u32, &c.waiters, .Add, 1, .seq_cst);
    const seq = @atomicLoad(u32, &c.seq, .seq_cst);
    // (a recursive mutex is given back whole, and taken back as deep)
    const depth = m.depth;
    m.depth = 0;
    @atomicStore(i64, &m.owner, 0, .monotonic);
    unlockWord(&m.word);
    const r = waitWord(&c.seq, seq, until);
    _ = @atomicRmw(u32, &c.waiters, .Sub, 1, .seq_cst);
    if (!tryWord(&m.word)) _ = lockWord(&m.word, null, 0);
    @atomicStore(i64, &m.owner, tid, .monotonic);
    m.depth = depth;
    return if (r == -@as(i64, E.TIMEDOUT)) E.TIMEDOUT else 0;
}

fn condWake(c: *Cond, count: u32) void {
    if (@atomicLoad(u32, &c.waiters, .seq_cst) == 0) return;
    _ = @atomicRmw(u32, &c.seq, .Add, 1, .seq_cst);
    wakeWord(&c.seq, count);
}

fn pthread_cond_init(h: ?*usize, attr: ?*const usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    var clock: u32 = abi.CLOCK.REALTIME;
    if (attr) |ah| {
        if (ah.* != 0) clock = (existing(CondAttr, ah) orelse return E.INVAL).clock;
    }
    const c = make(Cond) orelse return E.NOMEM;
    c.clock = clock;
    p.* = @intFromPtr(c);
    return 0;
}
fn pthread_cond_destroy(h: ?*usize) callconv(.c) c_int {
    return destroy(Cond, h);
}
fn pthread_cond_wait(h: ?*usize, mh: ?*usize) callconv(.c) c_int {
    const c = object(Cond, h) orelse return E.INVAL;
    return condWait(c, object(Mutex, mh) orelse return E.INVAL, null);
}
fn pthread_cond_timedwait(h: ?*usize, mh: ?*usize, when: ?*const abi.Timespec) callconv(.c) c_int {
    const c = object(Cond, h) orelse return E.INVAL;
    const m = object(Mutex, mh) orelse return E.INVAL;
    const until = at(when, c.clock) orelse return E.INVAL;
    return condWait(c, m, &until);
}
fn scePthreadCondTimedwait(h: ?*usize, mh: ?*usize, usec: u32) callconv(.c) c_int {
    const c = object(Cond, h) orelse return sx(E.INVAL);
    const m = object(Mutex, mh) orelse return sx(E.INVAL);
    const until = after(usec);
    return sx(condWait(c, m, &until));
}
fn pthread_cond_reltimedwait_np(h: ?*usize, mh: ?*usize, length: ?*const abi.Timespec) callconv(.c) c_int {
    const c = object(Cond, h) orelse return E.INVAL;
    const m = object(Mutex, mh) orelse return E.INVAL;
    const until = afterSpec(length) orelse return E.INVAL;
    return condWait(c, m, &until);
}
fn pthread_cond_signal(h: ?*usize) callconv(.c) c_int {
    condWake(object(Cond, h) orelse return E.INVAL, 1);
    return 0;
}
fn pthread_cond_broadcast(h: ?*usize) callconv(.c) c_int {
    condWake(object(Cond, h) orelse return E.INVAL, EVERYONE);
    return 0;
}

fn pthread_condattr_init(h: ?*usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    const a = make(CondAttr) orelse return E.NOMEM;
    a.* = .{ .tag = CondAttr.TAG };
    p.* = @intFromPtr(a);
    return 0;
}
fn pthread_condattr_destroy(h: ?*usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    const a = existing(CondAttr, p) orelse return E.INVAL;
    p.* = 0;
    unmake(a);
    return 0;
}
fn pthread_condattr_setclock(h: ?*const usize, clock: c_int) callconv(.c) c_int {
    const a = existing(CondAttr, h) orelse return E.INVAL;
    if (clock < 0 or abi.clockToLinux(@intCast(clock)) == null) return E.INVAL;
    a.clock = @bitCast(clock);
    return 0;
}
fn pthread_condattr_getclock(h: ?*const usize, out: ?*c_int) callconv(.c) c_int {
    const a = existing(CondAttr, h) orelse return E.INVAL;
    (out orelse return E.INVAL).* = @bitCast(a.clock);
    return 0;
}

// ── Read-write locks ────────────────────────────────────────────────────────

pub const Rwlock = extern struct {
    tag: u32 align(SLOT),
    /// A writer holds it (WRITER), writers wait for it (WAITING: readers
    /// stand back), and how many readers hold it.
    state: u32 = 0,
    /// Threads asleep on `state` (a release with none enters no kernel).
    sleepers: u32 = 0,
    _pad: u32 = 0,
    /// The writer (a thread id).
    owner: i64 = 0,

    const TAG: u32 = 0x4b4c_5752; // "RWLK"
    const WRITER: u32 = 1 << 31;
    const WAITING: u32 = 1 << 30;
    const READERS: u32 = WAITING - 1;

    fn init(_: *Rwlock, _: usize) void {}
    fn busy(l: *const Rwlock) bool {
        return @atomicLoad(u32, &l.state, .monotonic) & (WRITER | READERS) != 0;
    }

    fn sleep(l: *Rwlock, seen: u32, until: ?*const abi.UmtxTime) bool {
        _ = @atomicRmw(u32, &l.sleepers, .Add, 1, .seq_cst);
        const r = waitWord(&l.state, seen, until);
        _ = @atomicRmw(u32, &l.sleepers, .Sub, 1, .seq_cst);
        return r != -@as(i64, E.TIMEDOUT);
    }

    fn wakeAll(l: *Rwlock) void {
        if (@atomicLoad(u32, &l.sleepers, .seq_cst) != 0) wakeWord(&l.state, EVERYONE);
    }

    fn read(l: *Rwlock, until: ?*const abi.UmtxTime, wait: bool) c_int {
        const t = thread();
        while (true) {
            const s = @atomicLoad(u32, &l.state, .seq_cst);
            if (s & WRITER == 0 and (s & WAITING == 0 or t.rdlocks != 0)) {
                if (s & READERS == READERS) return E.AGAIN;
                if (@cmpxchgWeak(u32, &l.state, s, s + 1, .seq_cst, .seq_cst) == null) {
                    t.rdlocks += 1;
                    return 0;
                }
                continue;
            }
            if (!wait) return E.BUSY;
            if (s & WRITER != 0 and @atomicLoad(i64, &l.owner, .monotonic) == t.tid) return E.DEADLK;
            if (!l.sleep(s, until)) return E.TIMEDOUT;
        }
    }

    fn write(l: *Rwlock, until: ?*const abi.UmtxTime, wait: bool) c_int {
        const tid = me();
        while (true) {
            var s = @atomicLoad(u32, &l.state, .seq_cst);
            if (s & (WRITER | READERS) == 0) {
                // (taking it clears WAITING: writers still waiting say so again)
                if (@cmpxchgWeak(u32, &l.state, s, WRITER, .seq_cst, .seq_cst) == null) {
                    @atomicStore(i64, &l.owner, tid, .monotonic);
                    return 0;
                }
                continue;
            }
            if (!wait) return E.BUSY;
            if (s & WRITER != 0 and @atomicLoad(i64, &l.owner, .monotonic) == tid) return E.DEADLK;
            if (s & WAITING == 0) {
                if (@cmpxchgWeak(u32, &l.state, s, s | WAITING, .seq_cst, .seq_cst) != null) continue;
                s |= WAITING;
            }
            if (!l.sleep(s, until)) {
                // (it gives up: readers it kept back may come in)
                _ = @atomicRmw(u32, &l.state, .And, ~WAITING, .seq_cst);
                l.wakeAll();
                return E.TIMEDOUT;
            }
        }
    }

    fn unlock(l: *Rwlock) c_int {
        const t = thread();
        var s = @atomicLoad(u32, &l.state, .seq_cst);
        if (s & WRITER != 0) {
            if (@atomicLoad(i64, &l.owner, .monotonic) != t.tid) return E.PERM;
            @atomicStore(i64, &l.owner, 0, .monotonic);
            @atomicStore(u32, &l.state, 0, .seq_cst);
            l.wakeAll();
            return 0;
        }
        while (true) {
            if (s & READERS == 0) return E.PERM;
            // (the last reader out clears WAITING with itself: whoever
            // waits looks again)
            const next = if (s & READERS == 1) 0 else s - 1;
            if (@cmpxchgWeak(u32, &l.state, s, next, .seq_cst, .seq_cst)) |now| {
                s = now;
                continue;
            }
            if (t.rdlocks != 0) t.rdlocks -= 1;
            if (next == 0) l.wakeAll();
            return 0;
        }
    }
};

pub const RwlockAttr = extern struct {
    tag: u32 align(SLOT),
    pshared: u32 = 0,

    const TAG: u32 = 0x5254_4152; // "RATR"
};

fn pthread_rwlock_init(h: ?*usize, _: ?*const usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    const l = make(Rwlock) orelse return E.NOMEM;
    p.* = @intFromPtr(l);
    return 0;
}
fn pthread_rwlock_destroy(h: ?*usize) callconv(.c) c_int {
    return destroy(Rwlock, h);
}
fn pthread_rwlock_rdlock(h: ?*usize) callconv(.c) c_int {
    return (object(Rwlock, h) orelse return E.INVAL).read(null, true);
}
fn pthread_rwlock_tryrdlock(h: ?*usize) callconv(.c) c_int {
    return (object(Rwlock, h) orelse return E.INVAL).read(null, false);
}
fn pthread_rwlock_timedrdlock(h: ?*usize, when: ?*const abi.Timespec) callconv(.c) c_int {
    const l = object(Rwlock, h) orelse return E.INVAL;
    if (l.read(null, false) == 0) return 0;
    const until = at(when, abi.CLOCK.REALTIME) orelse return E.INVAL;
    return l.read(&until, true);
}
fn scePthreadRwlockTimedrdlock(h: ?*usize, usec: u32) callconv(.c) c_int {
    const l = object(Rwlock, h) orelse return sx(E.INVAL);
    const until = after(usec);
    return sx(l.read(&until, true));
}
fn pthread_rwlock_wrlock(h: ?*usize) callconv(.c) c_int {
    return (object(Rwlock, h) orelse return E.INVAL).write(null, true);
}
fn pthread_rwlock_trywrlock(h: ?*usize) callconv(.c) c_int {
    return (object(Rwlock, h) orelse return E.INVAL).write(null, false);
}
fn pthread_rwlock_timedwrlock(h: ?*usize, when: ?*const abi.Timespec) callconv(.c) c_int {
    const l = object(Rwlock, h) orelse return E.INVAL;
    if (l.write(null, false) == 0) return 0;
    const until = at(when, abi.CLOCK.REALTIME) orelse return E.INVAL;
    return l.write(&until, true);
}
fn scePthreadRwlockTimedwrlock(h: ?*usize, usec: u32) callconv(.c) c_int {
    const l = object(Rwlock, h) orelse return sx(E.INVAL);
    const until = after(usec);
    return sx(l.write(&until, true));
}
fn pthread_rwlock_unlock(h: ?*usize) callconv(.c) c_int {
    return (object(Rwlock, h) orelse return E.INVAL).unlock();
}
fn pthread_rwlockattr_init(h: ?*usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    const a = make(RwlockAttr) orelse return E.NOMEM;
    p.* = @intFromPtr(a);
    return 0;
}
fn pthread_rwlockattr_destroy(h: ?*usize) callconv(.c) c_int {
    const p = h orelse return E.INVAL;
    const a = existing(RwlockAttr, p) orelse return E.INVAL;
    p.* = 0;
    unmake(a);
    return 0;
}

// ── Thread-specific keys ────────────────────────────────────────────────────

const Destructor = *const fn (?*anyopaque) callconv(.c) void;

const Key = struct {
    /// Odd while the key is in use; it moves each time the key is made or
    /// deleted, so a value set under an earlier life of the number is not
    /// read back under a later one.
    seq: u32 = 0,
    destructor: ?Destructor = null,
};

const keys = struct {
    var lock: Lock = .{};
    var all: [KEYS]Key = [_]Key{.{}} ** KEYS;

    /// A program's key number as a place in `all`. The numbers start at 1,
    /// as FreeBSD 11's do (the PS5's base; 0 is then never a key, which
    /// code that keeps "no key yet" as 0 counts on).
    fn slot(key: c_int) ?usize {
        return if (key < 1 or key > KEYS) null else @intCast(key - 1);
    }
};

/// The rounds a thread's values' destructors get at its end (one may set
/// a value again).
const DESTRUCTOR_ROUNDS = 4;

fn pthread_key_create(out: ?*c_int, destructor: ?Destructor) callconv(.c) c_int {
    const o = out orelse return E.INVAL;
    keys.lock.lock();
    defer keys.lock.unlock();
    for (&keys.all, 0..) |*k, i| {
        if (k.seq & 1 != 0) continue;
        k.destructor = destructor;
        @atomicStore(u32, &k.seq, k.seq + 1, .release);
        o.* = @intCast(i + 1);
        return 0;
    }
    return E.AGAIN;
}

fn pthread_key_delete(key: c_int) callconv(.c) c_int {
    const i = keys.slot(key) orelse return E.INVAL;
    keys.lock.lock();
    defer keys.lock.unlock();
    const k = &keys.all[i];
    if (k.seq & 1 == 0) return E.INVAL;
    k.destructor = null;
    @atomicStore(u32, &k.seq, k.seq + 1, .release);
    return 0;
}

fn pthread_setspecific(key: c_int, value: ?*anyopaque) callconv(.c) c_int {
    const i = keys.slot(key) orelse return E.INVAL;
    const seq = @atomicLoad(u32, &keys.all[i].seq, .acquire);
    if (seq & 1 == 0) return E.INVAL;
    thread().specific[i] = .{ .value = value, .seq = seq };
    return 0;
}

fn pthread_getspecific(key: c_int) callconv(.c) ?*anyopaque {
    const i = keys.slot(key) orelse return null;
    const s = &thread().specific[i];
    return if (s.seq & 1 != 0 and s.seq == @atomicLoad(u32, &keys.all[i].seq, .acquire)) s.value else null;
}

fn runDestructors(t: *Thread) void {
    var round: u32 = 0;
    while (round < DESTRUCTOR_ROUNDS) : (round += 1) {
        var any = false;
        for (&keys.all, 0..) |*k, i| {
            const seq = @atomicLoad(u32, &k.seq, .acquire);
            if (seq & 1 == 0) continue;
            const s = &t.specific[i];
            const v = s.value orelse continue;
            if (s.seq != seq) continue;
            s.value = null;
            if (k.destructor) |d| {
                d(v);
                any = true;
            }
        }
        if (!any) return;
    }
}

// ── Once ────────────────────────────────────────────────────────────────────

/// FreeBSD's `pthread_once_t`: a state and a mutex it no longer needs.
pub const Once = extern struct { state: u32 = 0, mutex: usize = 0 };

const ONCE_NEVER = 0;
const ONCE_DONE = 1;
const ONCE_RUNNING = 2;
const ONCE_AWAITED = 3;

fn pthread_once(once: ?*Once, f: ?*const fn () callconv(.c) void) callconv(.c) c_int {
    const o = once orelse return E.INVAL;
    const run = f orelse return E.INVAL;
    const w = &o.state;
    while (true) {
        const s = @atomicLoad(u32, w, .acquire);
        switch (s) {
            ONCE_DONE => return 0,
            ONCE_NEVER => {
                if (@cmpxchgStrong(u32, w, ONCE_NEVER, ONCE_RUNNING, .acq_rel, .acquire) != null) continue;
                run();
                if (@atomicRmw(u32, w, .Xchg, ONCE_DONE, .acq_rel) == ONCE_AWAITED) wakeWord(w, EVERYONE);
                return 0;
            },
            ONCE_RUNNING => {
                if (@cmpxchgStrong(u32, w, ONCE_RUNNING, ONCE_AWAITED, .acq_rel, .acquire) != null) continue;
                _ = waitWord(w, ONCE_AWAITED, null);
            },
            ONCE_AWAITED => _ = waitWord(w, ONCE_AWAITED, null),
            else => return E.INVAL,
        }
    }
}

// ── The table ───────────────────────────────────────────────────────────────

/// Sony's way to say an errno: 0x80020000 + errno, as a negative number.
fn sx(e: c_int) c_int {
    return if (e == 0) 0 else @bitCast(abi.SCE_KERNEL_ERROR_BASE + @as(u32, @intCast(e)));
}

/// Sony's face of a POSIX function: the same call, its error said Sony's way.
fn Sce(comptime f: anytype) *const anyopaque {
    const P = @typeInfo(@TypeOf(f)).@"fn".param_types;
    return switch (P.len) {
        0 => &struct {
            fn w() callconv(.c) c_int {
                return sx(f());
            }
        }.w,
        1 => &struct {
            fn w(a: P[0].?) callconv(.c) c_int {
                return sx(f(a));
            }
        }.w,
        2 => &struct {
            fn w(a: P[0].?, b: P[1].?) callconv(.c) c_int {
                return sx(f(a, b));
            }
        }.w,
        3 => &struct {
            fn w(a: P[0].?, b: P[1].?, c: P[2].?) callconv(.c) c_int {
                return sx(f(a, b, c));
            }
        }.w,
        else => @compileError("Sce: a function of more arguments"),
    };
}

pub const Export = struct { []const u8, *const anyopaque };

fn one(comptime name: []const u8, comptime f: anytype) [1]Export {
    return .{.{ name, @ptrCast(f) }};
}

/// A POSIX name and Sony's for the same call.
fn two(comptime posix: []const u8, comptime sony: []const u8, comptime f: anytype) [2]Export {
    return .{ .{ posix, @ptrCast(&f) }, .{ sony, Sce(f) } };
}

/// Every name here, for libkernel's table.
pub const exports = one("pthread_create", &pthread_create) ++
    one("pthread_create_name_np", &pthread_create_name_np) ++
    one("scePthreadCreate", &scePthreadCreate) ++
    two("pthread_join", "scePthreadJoin", pthread_join) ++
    two("pthread_detach", "scePthreadDetach", pthread_detach) ++
    one("pthread_exit", &pthread_exit) ++
    one("scePthreadExit", &pthread_exit) ++
    one("pthread_self", &pthread_self) ++
    one("scePthreadSelf", &pthread_self) ++
    one("pthread_equal", &pthread_equal) ++
    one("scePthreadEqual", &pthread_equal) ++
    one("pthread_yield", &pthread_yield) ++
    one("scePthreadYield", &pthread_yield) ++
    one("pthread_getthreadid_np", &pthread_getthreadid_np) ++
    one("scePthreadGetthreadid", &pthread_getthreadid_np) ++
    two("pthread_rename_np", "scePthreadRename", pthread_rename_np) ++
    one("pthread_set_name_np", &pthread_set_name_np) ++
    two("pthread_setprio", "scePthreadSetprio", pthread_setprio) ++
    one("scePthreadGetprio", &scePthreadGetprio) ++
    two("pthread_setschedparam", "scePthreadSetschedparam", pthread_setschedparam) ++
    two("pthread_getschedparam", "scePthreadGetschedparam", pthread_getschedparam) ++
    one("scePthreadSetaffinity", &scePthreadSetaffinity) ++
    one("scePthreadGetaffinity", &scePthreadGetaffinity) ++
    one("scePthreadGetname", &scePthreadGetname) ++
    one("pthread_main_np", &pthread_main_np) ++
    one("sched_get_priority_min", &sched_get_priority_min) ++
    one("sched_get_priority_max", &sched_get_priority_max) ++
    one("__pthread_cleanup_push_imp", &__pthread_cleanup_push_imp) ++
    one("__pthread_cleanup_pop_imp", &__pthread_cleanup_pop_imp) ++
    one("_sceKernelSetThreadDtors", &_sceKernelSetThreadDtors) ++
    two("pthread_setcancelstate", "scePthreadSetcancelstate", pthread_setcancelstate) ++
    two("pthread_setcanceltype", "scePthreadSetcanceltype", pthread_setcanceltype) ++
    one("pthread_testcancel", &pthread_testcancel) ++
    one("scePthreadTestcancel", &pthread_testcancel) ++
    // attributes
    two("pthread_attr_init", "scePthreadAttrInit", pthread_attr_init) ++
    two("pthread_attr_destroy", "scePthreadAttrDestroy", pthread_attr_destroy) ++
    two("pthread_attr_setstacksize", "scePthreadAttrSetstacksize", pthread_attr_setstacksize) ++
    two("pthread_attr_getstacksize", "scePthreadAttrGetstacksize", pthread_attr_getstacksize) ++
    two("pthread_attr_setstackaddr", "scePthreadAttrSetstackaddr", pthread_attr_setstackaddr) ++
    two("pthread_attr_getstackaddr", "scePthreadAttrGetstackaddr", pthread_attr_getstackaddr) ++
    two("pthread_attr_setstack", "scePthreadAttrSetstack", pthread_attr_setstack) ++
    two("pthread_attr_getstack", "scePthreadAttrGetstack", pthread_attr_getstack) ++
    two("pthread_attr_setguardsize", "scePthreadAttrSetguardsize", pthread_attr_setguardsize) ++
    two("pthread_attr_getguardsize", "scePthreadAttrGetguardsize", pthread_attr_getguardsize) ++
    two("pthread_attr_setdetachstate", "scePthreadAttrSetdetachstate", pthread_attr_setdetachstate) ++
    two("pthread_attr_getdetachstate", "scePthreadAttrGetdetachstate", pthread_attr_getdetachstate) ++
    two("pthread_attr_setinheritsched", "scePthreadAttrSetinheritsched", pthread_attr_setinheritsched) ++
    two("pthread_attr_getinheritsched", "scePthreadAttrGetinheritsched", pthread_attr_getinheritsched) ++
    two("pthread_attr_setschedpolicy", "scePthreadAttrSetschedpolicy", pthread_attr_setschedpolicy) ++
    two("pthread_attr_getschedpolicy", "scePthreadAttrGetschedpolicy", pthread_attr_getschedpolicy) ++
    two("pthread_attr_setschedparam", "scePthreadAttrSetschedparam", pthread_attr_setschedparam) ++
    two("pthread_attr_getschedparam", "scePthreadAttrGetschedparam", pthread_attr_getschedparam) ++
    one("scePthreadAttrSetaffinity", &scePthreadAttrSetaffinity) ++
    one("scePthreadAttrGetaffinity", &scePthreadAttrGetaffinity) ++
    two("pthread_attr_get_np", "scePthreadAttrGet", pthread_attr_get_np) ++
    // mutexes
    two("pthread_mutex_init", "scePthreadMutexInit", pthread_mutex_init) ++
    two("pthread_mutex_destroy", "scePthreadMutexDestroy", pthread_mutex_destroy) ++
    two("pthread_mutex_lock", "scePthreadMutexLock", pthread_mutex_lock) ++
    two("pthread_mutex_trylock", "scePthreadMutexTrylock", pthread_mutex_trylock) ++
    one("pthread_mutex_timedlock", &pthread_mutex_timedlock) ++
    one("scePthreadMutexTimedlock", &scePthreadMutexTimedlock) ++
    one("pthread_mutex_reltimedlock_np", &pthread_mutex_reltimedlock_np) ++
    one("pthread_mutex_isowned_np", &pthread_mutex_isowned_np) ++
    two("pthread_mutex_unlock", "scePthreadMutexUnlock", pthread_mutex_unlock) ++
    two("pthread_mutexattr_init", "scePthreadMutexattrInit", pthread_mutexattr_init) ++
    two("pthread_mutexattr_destroy", "scePthreadMutexattrDestroy", pthread_mutexattr_destroy) ++
    two("pthread_mutexattr_settype", "scePthreadMutexattrSettype", pthread_mutexattr_settype) ++
    two("pthread_mutexattr_gettype", "scePthreadMutexattrGettype", pthread_mutexattr_gettype) ++
    two("pthread_mutexattr_setprotocol", "scePthreadMutexattrSetprotocol", pthread_mutexattr_setprotocol) ++
    two("pthread_mutexattr_getprotocol", "scePthreadMutexattrGetprotocol", pthread_mutexattr_getprotocol) ++
    // condition variables
    two("pthread_cond_init", "scePthreadCondInit", pthread_cond_init) ++
    two("pthread_cond_destroy", "scePthreadCondDestroy", pthread_cond_destroy) ++
    two("pthread_cond_wait", "scePthreadCondWait", pthread_cond_wait) ++
    one("pthread_cond_timedwait", &pthread_cond_timedwait) ++
    one("scePthreadCondTimedwait", &scePthreadCondTimedwait) ++
    one("pthread_cond_reltimedwait_np", &pthread_cond_reltimedwait_np) ++
    two("pthread_cond_signal", "scePthreadCondSignal", pthread_cond_signal) ++
    two("pthread_cond_broadcast", "scePthreadCondBroadcast", pthread_cond_broadcast) ++
    two("pthread_condattr_init", "scePthreadCondattrInit", pthread_condattr_init) ++
    two("pthread_condattr_destroy", "scePthreadCondattrDestroy", pthread_condattr_destroy) ++
    one("pthread_condattr_setclock", &pthread_condattr_setclock) ++
    one("pthread_condattr_getclock", &pthread_condattr_getclock) ++
    // read-write locks
    two("pthread_rwlock_init", "scePthreadRwlockInit", pthread_rwlock_init) ++
    two("pthread_rwlock_destroy", "scePthreadRwlockDestroy", pthread_rwlock_destroy) ++
    two("pthread_rwlock_rdlock", "scePthreadRwlockRdlock", pthread_rwlock_rdlock) ++
    two("pthread_rwlock_tryrdlock", "scePthreadRwlockTryrdlock", pthread_rwlock_tryrdlock) ++
    one("pthread_rwlock_timedrdlock", &pthread_rwlock_timedrdlock) ++
    one("scePthreadRwlockTimedrdlock", &scePthreadRwlockTimedrdlock) ++
    two("pthread_rwlock_wrlock", "scePthreadRwlockWrlock", pthread_rwlock_wrlock) ++
    two("pthread_rwlock_trywrlock", "scePthreadRwlockTrywrlock", pthread_rwlock_trywrlock) ++
    one("pthread_rwlock_timedwrlock", &pthread_rwlock_timedwrlock) ++
    one("scePthreadRwlockTimedwrlock", &scePthreadRwlockTimedwrlock) ++
    two("pthread_rwlock_unlock", "scePthreadRwlockUnlock", pthread_rwlock_unlock) ++
    two("pthread_rwlockattr_init", "scePthreadRwlockattrInit", pthread_rwlockattr_init) ++
    two("pthread_rwlockattr_destroy", "scePthreadRwlockattrDestroy", pthread_rwlockattr_destroy) ++
    // keys and once
    two("pthread_key_create", "scePthreadKeyCreate", pthread_key_create) ++
    two("pthread_key_delete", "scePthreadKeyDelete", pthread_key_delete) ++
    two("pthread_setspecific", "scePthreadSetspecific", pthread_setspecific) ++
    one("pthread_getspecific", &pthread_getspecific) ++
    one("scePthreadGetspecific", &pthread_getspecific) ++
    two("pthread_once", "scePthreadOnce", pthread_once);

// ── Tests ───────────────────────────────────────────────────────────────────
//
// What needs no kernel: the layouts a program's code and the kernel read,
// and the words the locks are made of when nobody else wants them. Threads
// that really run, wait and wake are tested where a kernel speaks this ABI
// (Galaxy's twin: galaxy/ps5/tests/threads.sig there).

test "the control block and a thread's state are where FreeBSD's code looks" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Tcb, "self"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Tcb, "thread"));
    try std.testing.expect(@sizeOf(Tcb) <= TCB_BYTES);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Thread, "errno"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Thread, "tid"));
    // (the kernel stores a long at each)
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Thread, "exited") % 8);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Once));
}

test "every object fits a slot of the pool" {
    inline for (.{ Mutex, MutexAttr, Cond, CondAttr, Rwlock, RwlockAttr, Attr }) |T| {
        try std.testing.expect(@sizeOf(T) <= SLOT);
        try std.testing.expectEqual(@as(usize, 0), @offsetOf(T, "tag"));
    }
    // (no two kinds share a tag: a handle of one is refused as another)
    const tags = [_]u32{ Mutex.TAG, MutexAttr.TAG, Cond.TAG, CondAttr.TAG, Rwlock.TAG, RwlockAttr.TAG, Attr.TAG };
    for (tags, 0..) |a, i| {
        for (tags[i + 1 ..]) |b| try std.testing.expect(a != b);
    }
}

test "Sony's error for an errno" {
    try std.testing.expectEqual(@as(c_int, 0), sx(0));
    try std.testing.expectEqual(@as(c_int, @bitCast(@as(u32, 0x8002_0016))), sx(E.INVAL));
    try std.testing.expectEqual(@as(c_int, @bitCast(@as(u32, 0x8002_003c))), sx(E.TIMEDOUT));
}

test "a lock nobody else wants: taken and given back without a kernel" {
    var w: u32 = 0;
    try std.testing.expect(tryWord(&w));
    try std.testing.expectEqual(@as(u32, 1), w);
    try std.testing.expect(!tryWord(&w));
    // (given back with nobody asleep on it: no wake is sent, so this runs
    // on any kernel)
    unlockWord(&w);
    try std.testing.expectEqual(@as(u32, 0), w);
    try std.testing.expect(lockWord(&w, null, 0));
    try std.testing.expectEqual(@as(u32, 2), w);
}

test "a read-write lock's word" {
    try std.testing.expectEqual(@as(u32, 0x8000_0000), Rwlock.WRITER);
    try std.testing.expectEqual(@as(u32, 0x3fff_ffff), Rwlock.READERS);
    try std.testing.expectEqual(@as(u32, 0), Rwlock.WRITER & Rwlock.WAITING);
}

test "a key's number starts at 1" {
    try std.testing.expectEqual(@as(?usize, null), keys.slot(0));
    try std.testing.expectEqual(@as(?usize, 0), keys.slot(1));
    try std.testing.expectEqual(@as(?usize, KEYS - 1), keys.slot(KEYS));
    try std.testing.expectEqual(@as(?usize, null), keys.slot(KEYS + 1));
    try std.testing.expectEqual(@as(?usize, null), keys.slot(-1));
}

test "a pushed handler fits the storage a program gives for it" {
    // (FreeBSD's `struct _pthread_cleanup_info` is eight words)
    try std.testing.expect(@sizeOf(Cleanup) <= 64);
}

test "a length of time that is not one is refused" {
    try std.testing.expect(afterSpec(null) == null);
    const bad = abi.Timespec{ .sec = -1, .nsec = 0 };
    try std.testing.expect(afterSpec(&bad) == null);
}

test "a time of day that is not one is refused" {
    try std.testing.expect(at(null, abi.CLOCK.REALTIME) == null);
    const bad = abi.Timespec{ .sec = 1, .nsec = 1_000_000_000 };
    try std.testing.expect(at(&bad, abi.CLOCK.REALTIME) == null);
    const good = abi.Timespec{ .sec = 5, .nsec = 999_999_999 };
    const t = at(&good, abi.CLOCK.MONOTONIC).?;
    try std.testing.expectEqual(@as(u32, abi.UmtxTime.ABSTIME), t.flags);
    try std.testing.expectEqual(@as(u32, abi.CLOCK.MONOTONIC), t.clockid);
}
