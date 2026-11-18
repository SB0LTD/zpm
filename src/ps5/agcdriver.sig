//! @zpm/ps5 agcdriver — the graphics driver library (libSceAgcDriver),
//! written in Sig: what a game hands its finished command buffers to.
//!
//! On the console this library passes a buffer to the kernel, and the GPU
//! works through it on its own time while the game goes on. Here a worker
//! thread stands in for the GPU's command processor: a submit call puts
//! the buffer in a queue and returns, and the worker reads it packet by
//! packet (pm4.sig), straight from the game's memory, as the GPU would.
//!
//! What the packets ask for, and who does it:
//!   - register writes, index and instance state: kept here, a queue's
//!     state (`State`), for the draws that follow;
//!   - draws: handed to `renderer` with that state (the part that needs
//!     the host's graphics code, which is not in this module);
//!   - what the GPU writes to memory in passing (labels, copies) and the
//!     interrupts a game hears through an event queue: done here, in the
//!     order the buffer gives, after the renderer has finished what came
//!     before them;
//!   - waits on memory, skips, calls into other buffers: done here;
//!   - a flip, a wait for a display buffer: the display library's
//!     (videoout.sig). A flip in a buffer counts as pending from the
//!     moment the buffer is submitted, and a flip the game's own code asks
//!     for goes behind the work already in the queue.
//!
//! The renderer is also asked to finish (`sync`) before the queue reads
//! what the GPU's own work may have written: a skip's condition, an
//! indirect draw's record, a copy's source. Lists of registers and index
//! tables are read as the game's CPU wrote them.
//!
//! Not here yet: compute queues (the graphics queue is the only one),
//! draws of several records at once, stream-out, the GDS and constant RAM,
//! occlusion predicates, semaphores. A packet this does not carry out is
//! named once in the log and stepped over.
//!
//! No Sony code: the calls, their arguments and the packets are as open
//! projects document them. x86-64 only. Allocation-free.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.sig");
const abi = @import("abi.sig");
const nid = @import("nid.sig");
const pthread = @import("pthread.sig");
const equeue = @import("equeue.sig");
const videoout = @import("videoout.sig");
const pm4 = @import("pm4.sig");

const S = abi.Sys;
const OP = pm4.OP;

// ── Numbers and structures ──────────────────────────────────────────────────

pub const ERROR = struct {
    pub const UNAVAILABLE: i32 = @bitCast(@as(u32, 0x8A6D_0001));
    pub const FAILED: i32 = @bitCast(@as(u32, 0x8A6D_0003));
    pub const NO_REGISTRATION: i32 = @bitCast(@as(u32, 0x8A6C_9018));
    pub const NO_DEBUG: i32 = @bitCast(@as(u32, 0x8A6C_1000));
};

/// What a game hands a submit call: a command buffer.
pub const Submission = extern struct {
    commands: ?[*]const u32,
    words: u32,
    flags: u8 = 0,
    reserved: [3]u8 = .{ 0, 0, 0 },
};

/// A draw, as the packets and the state before it give it.
pub const Draw = struct {
    /// Vertices (or indices) and instances.
    count: u32,
    instances: u32,
    /// The indices: where they are and how many bytes each is (0: none,
    /// the vertices are taken in order).
    index_address: u64 = 0,
    index_size: u8 = 0,
    /// The first vertex's number (or what is added to every index), and
    /// the first instance's.
    base_vertex: i32 = 0,
    first_instance: u32 = 0,
};

/// A queue's registers and what else the packets set, for the draws that
/// follow.
pub const State = struct {
    sh: [0x400]u32,
    cx: [0x400]u32,
    uc: [0x4000]u32,
    /// The context registers a game put aside (one level).
    saved_cx: [0x400]u32,
    has_saved: bool,
    /// Bytes an index takes: 2, 4 or 1.
    index_size: u8,
    index_base: u64,
    /// Indices the index buffer holds (an indirect draw's limit).
    index_limit: u32,
    instances: u32,
    /// Where indirect draws' records are counted from.
    indirect_base: u64,
    /// Packets marked as predicated run only while this holds.
    predicate: bool,

    pub fn bank(s: *State, b: pm4.Bank) []u32 {
        return switch (b) {
            .sh => &s.sh,
            .cx => &s.cx,
            .uc => &s.uc,
        };
    }

    /// Everything as a queue starts.
    pub fn reset(s: *State) void {
        @memset(&s.sh, 0);
        @memset(&s.uc, 0);
        s.has_saved = false;
        s.index_size = 2;
        s.index_base = 0;
        s.index_limit = 0;
        s.instances = 1;
        s.indirect_base = 0;
        s.predicate = true;
        s.clearContext(false);
    }

    /// The context registers as the GPU's "clear state" leaves them.
    pub fn clearContext(s: *State, cleared: bool) void {
        const one: u32 = @bitCast(@as(f32, 1.0));
        @memset(&s.cx, 0);
        s.cx[0x202] = 0x00CC_0010;
        s.cx[0x009] = one;
        s.cx[0x083] = 0xFFFF;
        s.cx[0x08C] = 0xAA99_AAAA;
        s.cx[0x08E] = 0xFFFF_FFFF;
        s.cx[0x08F] = 0xFFFF_FFFF;
        // Scissors: the window's, the generic one, sixteen viewports', and
        // the screen's: each from the top left to 16384 x 16384.
        for ([_]u32{ 0x081, 0x090 }) |r| {
            s.cx[r] = 0x8000_0000;
            s.cx[r + 1] = 0x4000_4000;
        }
        for (0..16) |i| {
            s.cx[0x094 + 2 * i] = 0x8000_0000;
            s.cx[0x095 + 2 * i] = 0x4000_4000;
            // (a viewport: scale 1 and offset 0 in x, y and z)
            s.cx[0x10F + 6 * i] = one;
            s.cx[0x111 + 6 * i] = one;
            s.cx[0x113 + 6 * i] = one;
        }
        s.cx[0x00D] = 0x4000_4000;
        s.cx[0x280] = 0x0008_0008;
        s.cx[0x281] = 0xFFFF_0000;
        s.cx[0x282] = 8;
        s.cx[0x292] = 2;
        s.cx[0x2DC] = 0xAA00;
        s.cx[0x2F9] = 0x2D;
        s.cx[0x30E] = 0xFFFF_FFFF;
        s.cx[0x30F] = 0xFFFF_FFFF;
        s.cx[0x313] = 0x6000;
        for (0..8) |i| s.cx[0x1E0 + i] = 0x2001_0001;
        if (cleared) s.cx[0x1B6] = 2;
    }
};

/// User-configuration registers the draws read.
pub const UC = struct {
    pub const PRIMITIVE_TYPE = 0x242;
    pub const INDEX_TYPE = 0x243;
    /// The first vertex of a draw without indices.
    pub const INDEX_OFFSET = 0x24A;
};

// ── What the host gives ─────────────────────────────────────────────────────

/// Who draws.
pub const Renderer = struct {
    draw: *const fn (state: *const State, d: Draw) void,
    /// Everything drawn so far is in its targets: called before the GPU's
    /// word of it reaches the game (a label, an interrupt, a flip).
    sync: *const fn () void,
};

pub var renderer: ?Renderer = null;

/// Counts, for tests and for whoever wonders what a game sent.
pub const stats = struct {
    pub var submissions: u64 = 0;
    pub var packets: u64 = 0;
    pub var draws: u64 = 0;
    pub var flips: u64 = 0;
    pub var labels: u64 = 0;
    pub var interrupts: u64 = 0;
    pub var skipped: u64 = 0;
    pub var refused: u64 = 0;
};

fn say(comptime text: []const u8) void {
    // (a test's host is not this kernel)
    if (builtin.is_test) return;
    const msg = "[ps5] gpu: " ++ text ++ "\n";
    _ = sys.call(S.write, 2, @intFromPtr(msg.ptr), msg.len, 0, 0, 0);
}

fn sayOp(comptime text: []const u8, op: u8) void {
    if (builtin.is_test) return;
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[ps5] gpu: " ++ text ++ ": {s} (0x{x})\n", .{ pm4.opName(op), op }) catch return;
    _ = sys.call(S.write, 2, @intFromPtr(msg.ptr), msg.len, 0, 0, 0);
}

fn nowNs() u64 {
    return if (builtin.is_test) Testing.now_ns else pthread.nowNs();
}

fn nap(ns: u64) void {
    if (builtin.is_test) {
        // (a test's wait is turned by the test: see Testing.on_nap)
        Testing.now_ns += ns;
        if (Testing.on_nap) |f| f();
        return;
    }
    const t = abi.Timespec{ .sec = 0, .nsec = @intCast(ns) };
    _ = sys.call(S.nanosleep, @intFromPtr(&t), 0, 0, 0, 0, 0);
}

// ── The graphics queue ──────────────────────────────────────────────────────

/// What waits for the worker: a command buffer (with how many of its
/// flips were promised to the display when it was submitted, and up to
/// which word they were looked for), or a flip the game's own code asked
/// for while buffers were waiting.
const Work = union(enum) {
    commands: struct { at: [*]const u32, words: u32, promised: u32, looked: u32 },
    flip: struct { handle: i32, buffer: i32, mode: i32, arg: i64 },
};

/// Submissions that may wait for the worker.
const PENDING = 256;
/// Buffers a buffer may call into, one inside the other.
const NESTING = 16;
/// The graphics queue's number (compute queues' start at 0x20).
const GRAPHICS: u32 = 0;
/// Words of packets one submission may run through (a buffer that calls
/// or follows itself for ever is left there, as a GPU would hang on it).
var budget: u64 = 1 << 26;

const queue = struct {
    var lock: pthread.Lock = .{};
    var ring: [PENDING]Work = undefined;
    var head: usize = 0;
    var count: usize = 0;
    /// Goes up at each submit (the worker sleeps on it) and each time a
    /// submission is done (a submitter with no room, and waitIdle, sleep
    /// on that).
    var arrived: u32 = 0;
    var finished: u32 = 0;
    /// The worker is inside a submission.
    var busy: bool = false;
    var started: bool = false;
    var state: State = undefined;
    var state_ready: bool = false;
    /// Who hears of the queue's interrupts.
    var watchers: [8]Watcher = [_]Watcher{.{}} ** 8;
    /// Kinds of packet named in the log already.
    var said: [256]bool = [_]bool{false} ** 256;
};

const Watcher = struct { queue: usize = 0, ident: u64 = 0, used: bool = false };

/// The flips in a buffer's own packets (not in buffers it calls), up to
/// its end, a rewind, or what is not a packet: how many, and the word the
/// look ended at.
fn flipsIn(commands: []const u32) struct { count: u32, looked: u32 } {
    var r = pm4.Reader{ .words = commands };
    var count: u32 = 0;
    while (r.next() catch null) |p| {
        if (p.op() == OP.REWIND) return .{ .count = count, .looked = @intCast(p.at) };
        if (p.op() == OP.NOP and p.sub() == pm4.SUB.FLIP and p.body.len == 5) count += 1;
    }
    return .{ .count = count, .looked = @intCast(r.at) };
}

fn submit(commands: ?[*]const u32, words: u32) i32 {
    if (words == 0) return 0;
    const c = commands orelse return ERROR.FAILED;
    // Its flips are pending from now, as a game counts them.
    const flips = flipsIn(c[0..words]);
    if (flips.count != 0) videoout.reserve(flips.count);
    const r = enqueue(.{ .commands = .{ .at = c, .words = words, .promised = flips.count, .looked = flips.looked } });
    if (r != 0 and flips.count != 0) videoout.unreserve(flips.count);
    return r;
}

/// A flip the game's own code asked for (the display library asks here
/// first): behind the buffers waiting, when there are any; else null, and
/// the display queues it at once.
fn routeFlip(handle: i32, buffer: i32, mode: i32, arg: i64) ?i32 {
    queue.lock.lock();
    const idle = queue.count == 0 and !queue.busy;
    queue.lock.unlock();
    if (idle) return null;
    videoout.reserve(1);
    const r = enqueue(.{ .flip = .{ .handle = handle, .buffer = buffer, .mode = mode, .arg = arg } });
    if (r != 0) videoout.unreserve(1);
    return r;
}

fn enqueue(work: Work) i32 {
    while (true) {
        queue.lock.lock();
        if (queue.count < PENDING) break;
        // No room: wait for the worker to finish one.
        const seen = queue.finished;
        queue.lock.unlock();
        if (builtin.is_test) return ERROR.FAILED;
        pthread.waitWhile(&queue.finished, seen);
    }
    queue.ring[(queue.head + queue.count) % PENDING] = work;
    queue.count += 1;
    videoout.flip_router = routeFlip;
    queue.arrived +%= 1;
    stats.submissions += 1;
    if (!queue.started and !builtin.is_test) {
        queue.started = pthread.spawnService(workerMain, null, "SceAgcDriverGfx");
        if (!queue.started) say("no thread for the GPU's work: nothing a game submits will happen");
    }
    queue.lock.unlock();
    pthread.wakeAll(&queue.arrived);
    return 0;
}

/// Takes the oldest waiting submission and carries it out. False: none
/// was waiting. (The worker's loop; a test calls it itself.)
pub fn runOne() bool {
    queue.lock.lock();
    if (queue.count == 0) {
        queue.lock.unlock();
        return false;
    }
    const w = queue.ring[queue.head];
    queue.head = (queue.head + 1) % PENDING;
    queue.count -= 1;
    queue.busy = true;
    if (!queue.state_ready) {
        queue.state.reset();
        queue.state_ready = true;
    }
    queue.lock.unlock();

    switch (w) {
        .commands => |c| {
            const kept = execute(&queue.state, c.at[0..c.words], c.looked);
            // (promised flips the queue never came to: skipped, or past
            // where the buffer was left)
            if (kept < c.promised) videoout.unreserve(c.promised - kept);
        },
        .flip => |f| flipNow(f.handle, f.buffer, f.mode, f.arg, true),
    }

    queue.lock.lock();
    queue.busy = false;
    queue.finished +%= 1;
    queue.lock.unlock();
    pthread.wakeAll(&queue.finished);
    return true;
}

fn workerMain(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    while (true) {
        const seen = @atomicLoad(u32, &queue.arrived, .acquire);
        if (runOne()) continue;
        pthread.waitWhile(&queue.arrived, seen);
    }
}

/// Returns once everything submitted so far has been carried out.
pub fn waitIdle() void {
    while (true) {
        queue.lock.lock();
        const idle = queue.count == 0 and !queue.busy;
        const seen = queue.finished;
        queue.lock.unlock();
        if (idle) return;
        if (builtin.is_test) {
            _ = runOne();
            continue;
        }
        pthread.waitWhile(&queue.finished, seen);
    }
}

// ── Carrying a buffer out ───────────────────────────────────────────────────

fn word(address: u64) *align(1) volatile u32 {
    return @ptrFromInt(address);
}

fn word64(address: u64) *align(1) volatile u64 {
    return @ptrFromInt(address);
}

/// Carries a submitted buffer out. `looked` is the word up to which its
/// flips were promised to the display at submit; how many of those
/// promises were kept (its flips the queue came to) is the answer.
fn execute(s: *State, commands: []const u32, looked: usize) u32 {
    var stack: [NESTING]pm4.Reader = undefined;
    var depth: usize = 0;
    var r = pm4.Reader{ .words = commands };
    // (still in the buffer that was submitted, not one it went on to)
    var own = true;
    var kept: u32 = 0;
    var spent: u64 = 0;
    while (true) {
        const p = (r.next() catch {
            stats.refused += 1;
            say("a command buffer holds what is not a packet: the rest of it is left out");
            return kept;
        }) orelse {
            // (the end of a buffer that was called: back to its caller)
            if (depth == 0) return kept;
            depth -= 1;
            r = stack[depth];
            continue;
        };
        stats.packets += 1;
        spent += p.words();
        if (spent > budget) {
            stats.refused += 1;
            say("a command buffer goes on without end (it calls or follows itself): it is left there");
            return kept;
        }
        if (p.predicated() and !s.predicate) continue;
        switch (p.op()) {
            OP.NOP => if (p.sub() == pm4.SUB.FLIP and p.body.len == 5) {
                const b = p.body;
                const promised = own and depth == 0 and p.at < looked;
                if (promised) kept += 1;
                flipNow(@bitCast(b[0]), @bitCast(b[1]), @intCast(b[2] & 0xFF), @bitCast(@as(u64, b[4]) << 32 | b[3]), promised);
            } else packet(s, p),
            OP.INDIRECT_BUFFER => {
                if (p.body.len != 3) {
                    skip(p);
                    continue;
                }
                const target = p.pair(0) & 0xFFFF_FFFF_FFFC;
                const n = p.body[2] & 0xF_FFFF;
                const chain = p.body[2] & (1 << 20) != 0;
                if (target == 0 or n == 0) continue;
                if (!chain) {
                    if (depth == NESTING) {
                        stats.refused += 1;
                        say("command buffers call into each other too deep: a call is left out");
                        continue;
                    }
                    stack[depth] = r;
                    depth += 1;
                } else if (depth == 0) own = false;
                r = .{ .words = @as([*]const u32, @ptrFromInt(target))[0..n] };
            },
            OP.COND_EXEC => {
                if (p.body.len != 4) {
                    skip(p);
                    continue;
                }
                const address = p.pair(0);
                const n = p.body[3] & 0x3FFF;
                if (address == 0) continue;
                // (the word may be one the GPU's own work wrote)
                sync();
                if (word(address & ~@as(u64, 3)).* == 0) r.at = @min(r.at + n, r.words.len);
            },
            OP.REWIND => {
                // The game says later that what follows is written: the
                // word after the header, its top bit, in the buffer itself.
                if (p.body.len != 1) {
                    skip(p);
                    continue;
                }
                const flag: *const volatile u32 = &r.words[p.at + 1];
                while (flag.* >> 31 == 0) nap(200_000);
            },
            else => packet(s, p),
        }
    }
}

/// A packet this does not carry out: counted, and its kind said once.
fn skip(p: pm4.Packet) void {
    stats.skipped += 1;
    if (queue.said[p.op()]) return;
    queue.said[p.op()] = true;
    sayOp("a kind of packet this driver does not carry out yet (said once)", p.op());
}

fn sync() void {
    if (renderer) |r| r.sync();
}

fn packet(s: *State, p: pm4.Packet) void {
    const b = p.body;
    switch (p.op()) {
        OP.NOP => switch (p.sub()) {
            // (a flip packet of the right length is `execute`'s own)
            pm4.SUB.FLIP => skip(p),
            pm4.SUB.WAIT_SAFE => if (b.len == 3) videoout.waitSafe(@bitCast(b[0]), @bitCast(b[1])) else skip(p),
            pm4.SUB.DISPATCH_RESET => s.reset(),
            pm4.SUB.CONTEXT_STATE => contextState(s, b[0]),
            // (plain ones and markers: nothing to do)
            else => {},
        },
        OP.SET_SH_REG, OP.SET_CONTEXT_REG, OP.SET_UCONFIG_REG => {
            const offset = b[0] & 0x8FFF_FFFF;
            const bk = pm4.bankOf(p.op()).?;
            // (a write to the tag register says what the next packets are,
            // and changes nothing)
            if (bk == .uc and offset == pm4.UC_TAG) return;
            setRegisters(s, bk, offset, b[1..]);
        },
        // (the top bits say which index of a register with several)
        OP.SET_UCONFIG_REG_INDEX => setRegisters(s, .uc, b[0] & 0x0FFF_FFFF, b[1..]),
        OP.SET_SH_REG_INDIRECT, OP.SET_CONTEXT_REG_INDIRECT, OP.SET_UCONFIG_REG_INDIRECT => {
            if (b.len != 4) return skip(p);
            const list = p.pair(0);
            const n = b[3] & 0x3FFF;
            if (list == 0 or list & 3 != 0) return refuse();
            const bk = pm4.bankOf(p.op()).?;
            const from: [*]align(1) const u32 = @ptrFromInt(list);
            if (b[2] == 0x8000_0000) {
                // (pairs: a register and its value)
                for (0..n) |i| setRegisters(s, bk, from[2 * i], &.{from[2 * i + 1]});
            } else {
                for (0..n) |i| setRegisters(s, bk, b[2] +| @as(u32, @intCast(i)), &.{from[i]});
            }
        },
        OP.CONTEXT_REG_RMW => {
            if (b.len != 3 or b[0] >= s.cx.len) return refuse();
            // (the bits the mask names take the data's; the rest stay)
            s.cx[b[0]] = (s.cx[b[0]] & ~b[1]) | (b[2] & b[1]);
        },
        OP.CLEAR_STATE => s.clearContext(true),
        // What only orders the GPU's own caches and pipeline: nothing to
        // do when the work is done in order.
        OP.CONTEXT_CONTROL, OP.PFP_SYNC_ME, OP.ACQUIRE_MEM, OP.EVENT_WRITE => {},

        OP.INDEX_TYPE => setRegisters(s, .uc, UC.INDEX_TYPE, b[0..1]),
        OP.INDEX_BASE => if (b.len == 2) {
            s.index_base = p.pair(0);
        } else skip(p),
        OP.INDEX_BUFFER_SIZE => s.index_limit = b[0],
        OP.NUM_INSTANCES => s.instances = @max(b[0], 1),
        OP.SET_BASE => if (b.len == 3 and b[0] == 1) {
            if (!p.compute()) s.indirect_base = p.pair(1);
        } else skip(p),
        OP.INDEX_ATTRIBUTES_INDIRECT => {
            if (b.len != 3) return skip(p);
            const table = p.pair(0);
            if (table == 0 or table & 15 != 0) return refuse();
            const rec: [*]align(1) const u32 = @ptrFromInt(table + 16 * @as(u64, b[2] & 0xFFFF));
            s.index_base = @as(u64, rec[1]) << 32 | rec[0];
            s.index_limit = rec[2];
            setRegisters(s, .uc, UC.INDEX_TYPE, &.{rec[3]});
        },

        OP.DRAW_INDEX_AUTO => if (b.len == 2) draw(s, .{
            .count = b[0],
            .instances = s.instances,
            .base_vertex = @bitCast(s.uc[UC.INDEX_OFFSET]),
        }) else skip(p),
        OP.DRAW_INDEX_2 => if (b.len == 5) draw(s, .{
            .count = @min(b[3], b[0]),
            .instances = s.instances,
            .index_address = p.pair(1),
            .index_size = s.index_size,
        }) else skip(p),
        // (the first word is the most indices the draw may take, as this
        // project's graphics library writes it: the count itself)
        OP.DRAW_INDEX_OFFSET_2 => if (b.len == 4) draw(s, .{
            .count = @min(b[2], b[0]),
            .instances = s.instances,
            .index_address = s.index_base + @as(u64, b[1]) * s.index_size,
            .index_size = s.index_size,
        }) else skip(p),
        OP.DRAW_INDIRECT, OP.DRAW_INDEX_INDIRECT => {
            if (b.len != 4) return skip(p);
            const at = s.indirect_base + b[0];
            if (s.indirect_base == 0 or at & 3 != 0) return refuse();
            // (the record may be one the GPU's own work wrote)
            sync();
            const rec: [*]align(1) const u32 = @ptrFromInt(at);
            if (p.op() == OP.DRAW_INDIRECT) {
                // (vertices, instances, the first vertex, the first instance)
                toShader(s, b[1], rec[2]);
                toShader(s, b[2], rec[3]);
                draw(s, .{ .count = rec[0], .instances = rec[1], .base_vertex = @bitCast(rec[2]), .first_instance = rec[3] });
            } else {
                // (indices, instances, the first index, added to each
                // index, the first instance)
                toShader(s, b[1], rec[3]);
                toShader(s, b[2], rec[4]);
                draw(s, .{
                    .count = @min(rec[0], s.index_limit -| rec[2]),
                    .instances = rec[1],
                    .index_address = s.index_base + @as(u64, rec[2]) * s.index_size,
                    .index_size = s.index_size,
                    .base_vertex = @bitCast(rec[3]),
                    .first_instance = rec[4],
                });
            }
        },

        OP.WRITE_DATA => writeData(s, p),
        OP.RELEASE_MEM => releaseMem(p),
        OP.WAIT_REG_MEM => if (b.len == 6) waitMemory(b[0], p.pair(1), b[3], b[4], false) else skip(p),
        OP.WAIT_REG_MEM_64 => if (b.len == 8) waitMemory(b[0], p.pair(1), p.pair(3), p.pair(5), true) else skip(p),
        OP.COPY_DATA => copyData(s, p),
        OP.DMA_DATA => dmaData(p),
        OP.SET_PREDICATION => predication(s, p),
        else => skip(p),
    }
}

fn refuse() void {
    stats.refused += 1;
}

fn setRegisters(s: *State, bk: pm4.Bank, offset: u32, values: []const u32) void {
    const regs = s.bank(bk);
    if (offset >= regs.len or values.len > regs.len - offset) return refuse();
    @memcpy(regs[offset..][0..values.len], values);
    // (the index type is also what a draw's index size is read from)
    if (bk == .uc and offset <= UC.INDEX_TYPE and UC.INDEX_TYPE - offset < values.len) setIndexType(s, values[UC.INDEX_TYPE - offset]);
}

/// An indirect draw's base vertex or first instance, into the shader
/// register the packet names for it: one of the vertex-side stages' user
/// data registers. 0 (and 0x280): nowhere.
fn toShader(s: *State, register: u32, value: u32) void {
    const r = register & 0xFFFF;
    if ((r >= 0x8C and r <= 0xAB) or (r >= 0x10C and r <= 0x12B)) s.sh[r] = value;
}

fn setIndexType(s: *State, value: u32) void {
    s.index_size = switch (value & 3) {
        0 => 2,
        1 => 4,
        else => 1,
    };
}

fn contextState(s: *State, op: u32) void {
    switch (op) {
        0 => s.clearContext(true),
        1, 3 => {
            s.saved_cx = s.cx;
            s.has_saved = true;
            if (op == 3) s.clearContext(true);
        },
        2 => if (s.has_saved) {
            s.cx = s.saved_cx;
            s.has_saved = false;
        },
        else => refuse(),
    }
}

fn draw(s: *const State, d: Draw) void {
    stats.draws += 1;
    if (d.count == 0 or d.instances == 0) return;
    if (renderer) |r| {
        r.draw(s, d);
    } else if (!queue.said[OP.DRAW_INDEX_AUTO]) {
        queue.said[OP.DRAW_INDEX_AUTO] = true;
        say("draws arrive, and nothing here draws them yet (said once)");
    }
}

/// A flip the queue has come to: a display buffer of an output, when the
/// screen next refreshes. What was drawn before it is finished first.
/// `promised`: the display already counts it as pending.
fn flipNow(handle: i32, buffer: i32, mode: i32, arg: i64, promised: bool) void {
    sync();
    stats.flips += 1;
    while (true) {
        const r = if (promised) videoout.submitReserved(handle, buffer, mode, arg) else videoout.submit(handle, buffer, mode, arg);
        if (r != videoout.ERROR.FLIP_QUEUE_FULL) {
            if (r != 0) refuse();
            return;
        }
        // (the display has sixteen flips waiting: after its next refresh.
        // A display that closed meanwhile says so, and the flip is dropped)
        if (builtin.is_test or videoout.waitVblank(handle) != 0) {
            if (promised) videoout.unreserve(1);
            return refuse();
        }
    }
}

/// WRITE_DATA: words of the packet to memory (a label), or to one of the
/// tag registers.
fn writeData(s: *State, p: pm4.Packet) void {
    const b = p.body;
    if (b.len < 4) return skip(p);
    const destination = b[0] >> 8 & 0xF;
    const one_address = b[0] & (1 << 16) != 0;
    const data = b[3..];
    if (destination == 0) {
        // (registers: only the tag's own)
        const reg = pm4.Bank.of(b[1]) orelse return refuse();
        if (reg.bank != .uc or reg.offset < 0x340 or reg.offset > 0x347) return refuse();
        return setRegisters(s, .uc, reg.offset, data[0..@min(data.len, 0x348 - reg.offset)]);
    }
    if (destination == 4 or destination > 5) return skip(p);
    const address = p.pair(1);
    if (address == 0 or address & 3 != 0) return refuse();
    sync();
    stats.labels += 1;
    if (one_address) {
        word(address).* = data[data.len - 1];
    } else {
        for (data, 0..) |v, i| word(address + 4 * i).* = v;
    }
}

/// RELEASE_MEM: when the work before it has left the pipeline, a value is
/// written to memory (a label) and, if asked for, the game is interrupted
/// (it hears of it through its event queue).
fn releaseMem(p: pm4.Packet) void {
    const b = p.body;
    if (b.len != 7) return skip(p);
    const data_sel = b[1] >> 29;
    const int_sel = b[1] >> 24 & 7;
    const address = p.pair(2);
    sync();
    switch (data_sel) {
        0 => {},
        1 => if (address != 0 and address & 3 == 0) {
            word(address).* = b[4];
            stats.labels += 1;
        } else refuse(),
        2, 3 => if (address != 0 and address & 7 == 0) {
            // (3: the GPU's clock, which counts at 100 MHz)
            word64(address).* = if (data_sel == 2) p.pair(4) else nowNs() / 10;
            stats.labels += 1;
        } else refuse(),
        else => return skip(p),
    }
    if (int_sel == 0 or int_sel == 3) return;
    stats.interrupts += 1;
    interrupt(GRAPHICS, b[6] & 0x0FFF_FFFF);
}

/// What an interrupt's event carries: the queue it came from, and the
/// number the game gave it in the packet.
fn interruptData(_: i64, arg: u64) i64 {
    return @bitCast(arg);
}

fn interrupt(from: u32, context: u32) void {
    queue.lock.lock();
    defer queue.lock.unlock();
    for (&queue.watchers) |*w| {
        if (!w.used or w.ident != from) continue;
        // (a queue the game deleted, or another now at its address that
        // never asked, gives its place in the list back)
        if (equeue.post(w.queue, equeue.FILTER.GRAPHICS_CORE, w.ident, interruptData, (from & 0xFF) | @as(u64, context) << 16, null) != 0) w.* = .{};
    }
}

fn compare(function: u32, value: u64, reference: u64) bool {
    return switch (function & 7) {
        0 => true,
        1 => value < reference,
        2 => value <= reference,
        3 => value == reference,
        4 => value != reference,
        5 => value >= reference,
        6 => value > reference,
        else => true,
    };
}

/// WAIT_REG_MEM: the queue stands still until a word of memory, masked,
/// compares as asked with a reference. (Another thread of the game, or a
/// label, writes it.)
fn waitMemory(control: u32, address: u64, reference: u64, mask: u64, wide: bool) void {
    // (only memory: the GPU's own registers are not there to wait on)
    if (control & (1 << 4) == 0) return refuse();
    const eight = wide and mask >> 32 != 0;
    const at = address & ~@as(u64, if (eight) 7 else 3);
    if (at == 0) return refuse();
    sync();
    while (true) {
        const value: u64 = if (eight) word64(at).* else word(at).*;
        if (compare(control, value & mask, reference)) return;
        nap(100_000);
    }
}

/// COPY_DATA: a value from memory, the packet itself, a register or the
/// GPU's clock, into memory.
fn copyData(s: *State, p: pm4.Packet) void {
    const b = p.body;
    if (b.len != 5) return skip(p);
    const source = b[0] & 0xF;
    const destination = b[0] >> 8 & 0xF;
    const wide = b[0] & (1 << 16) != 0;
    const to = p.pair(3);
    if (destination != 1 and destination != 2 and destination != 5) return skip(p);
    if (to == 0 or to & 3 != 0) return refuse();
    if (source > 2 and source != 5 and source != 9) return skip(p);
    // (before the read: the source may be what the GPU's own work wrote)
    sync();
    const value: u64 = switch (source) {
        0 => blk: {
            const reg = pm4.Bank.of(b[1]) orelse return refuse();
            break :blk s.bank(reg.bank)[reg.offset];
        },
        1, 2 => blk: {
            const from = p.pair(1);
            if (from == 0 or from & 3 != 0) return refuse();
            break :blk if (wide) word64(from).* else word(from).*;
        },
        5 => p.pair(1),
        else => nowNs() / 10,
    };
    stats.labels += 1;
    if (wide) word64(to).* = value else word(to).* = @truncate(value);
}

/// DMA_DATA: bytes copied from one place in memory to another, or a place
/// filled with one word.
fn dmaData(p: pm4.Packet) void {
    const b = p.body;
    if (b.len != 6) return skip(p);
    const source = b[0] >> 29 & 3;
    const destination = b[0] >> 20 & 3;
    const bytes: usize = b[5] & 0x3FF_FFFF;
    // (nowhere: the GPU is only asked to bring the bytes near)
    if (destination == 2) return;
    if (destination == 1 or source == 1) return skip(p);
    const to = p.pair(3);
    if (to == 0) return refuse();
    sync();
    const out = @as([*]u8, @ptrFromInt(to))[0..bytes];
    if (source == 2) {
        const fill = std.mem.asBytes(&b[1]);
        for (out, 0..) |*o, i| o.* = fill[i & 3];
    } else {
        const from = p.pair(1);
        if (from == 0) return refuse();
        std.mem.copyForwards(u8, out, @as([*]const u8, @ptrFromInt(from))[0..bytes]);
    }
    stats.labels += 1;
}

/// SET_PREDICATION: whether the packets marked for it run, by a value in
/// memory. (By what a draw's pixels did: not yet; those run.)
fn predication(s: *State, p: pm4.Packet) void {
    const b = p.body;
    if (b.len != 3) return skip(p);
    const when_set = b[0] & (1 << 8) != 0;
    const address = p.pair(1);
    switch (b[0] >> 16 & 7) {
        0 => s.predicate = true,
        3, 4 => {
            if (address == 0) return refuse();
            sync();
            const value: u64 = if (b[0] >> 16 & 7 == 3) word64(address).* else word(address).*;
            s.predicate = (value != 0) == when_set;
        },
        else => {
            s.predicate = true;
            skip(p);
        },
    }
}

// ── What a game calls ───────────────────────────────────────────────────────

fn sceAgcDriverSubmitDcb(what: ?*const Submission) callconv(.c) i32 {
    const w = what orelse return ERROR.FAILED;
    if (w.flags != 0) return ERROR.FAILED;
    return submit(w.commands, w.words);
}

fn sceAgcDriverSubmitMultiDcbs(buffers: ?[*]const ?[*]const u32, sizes: ?[*]const u32, count: u32) callconv(.c) i32 {
    if (count == 0) return 0;
    const bufs = buffers orelse return ERROR.FAILED;
    const lens = sizes orelse return ERROR.FAILED;
    for (bufs[0..count], lens[0..count]) |b, n| {
        const r = submit(b, n);
        if (r != 0) return r;
    }
    return 0;
}

/// A queue's handle as a game holds it: the queue's number is its second
/// word.
const QueueContext = extern struct { reserved: u32, queue: u32 };

fn sceAgcDriverSubmitCommandBuffer(context: ?*const QueueContext, what: ?*const Submission) callconv(.c) i32 {
    const c = context orelse return abi.E.INVAL;
    const w = what orelse return abi.E.INVAL;
    if (c.queue != GRAPHICS) return ERROR.UNAVAILABLE;
    return submit(w.commands, w.words);
}

fn sceAgcDriverSubmitMultiCommandBuffers(context: ?*const QueueContext, buffers: ?[*]const ?[*]const u32, sizes: ?[*]const u32, count: u32) callconv(.c) i32 {
    const c = context orelse return abi.E.INVAL;
    if (c.queue != GRAPHICS) return ERROR.UNAVAILABLE;
    return sceAgcDriverSubmitMultiDcbs(buffers, sizes, count);
}

/// Has an event queue hear of the graphics queue's interrupts (`id` is the
/// queue's number: 0).
fn sceAgcDriverAddEqEvent(eq: usize, id: i32, udata: u64) callconv(.c) i32 {
    if (id != GRAPHICS) return ERROR.UNAVAILABLE;
    const ident: u64 = @intCast(id);
    if (equeue.add(eq, equeue.FILTER.GRAPHICS_CORE, ident, udata, .{ .flags = equeue.EV.CLEAR, .clear = true }) != 0) return ERROR.FAILED;
    queue.lock.lock();
    defer queue.lock.unlock();
    for (queue.watchers) |w| {
        if (w.used and w.queue == eq and w.ident == ident) return 0;
    }
    for (&queue.watchers) |*w| {
        if (!w.used) {
            w.* = .{ .queue = eq, .ident = ident, .used = true };
            return 0;
        }
    }
    _ = equeue.remove(eq, equeue.FILTER.GRAPHICS_CORE, ident);
    return ERROR.FAILED;
}

fn sceAgcDriverDeleteEqEvent(eq: usize, id: i32) callconv(.c) i32 {
    if (id < 0) return ERROR.FAILED;
    const ident: u64 = @intCast(id);
    queue.lock.lock();
    defer queue.lock.unlock();
    for (&queue.watchers) |*w| {
        if (w.used and w.queue == eq and w.ident == ident) {
            w.* = .{};
            _ = equeue.remove(eq, equeue.FILTER.GRAPHICS_CORE, ident);
            return 0;
        }
    }
    return ERROR.FAILED;
}

/// An interrupt event's kind: the queue it came from, in its low bits.
fn sceAgcDriverGetEqEventType(ev: ?*const equeue.Event) callconv(.c) i32 {
    const e = ev orelse return ERROR.FAILED;
    return @truncate(e.data);
}

/// The number the game gave the interrupt in its packet.
fn sceAgcDriverGetEqContextId(ev: ?*const equeue.Event) callconv(.c) u32 {
    const e = ev orelse return 0;
    return @truncate(@as(u64, @bitCast(e.data)) >> 16);
}

/// The sizes of the two packets this driver writes for a game's library.
fn sceAgcDriverGetSetFlipPacketSizeInDwords() callconv(.c) u32 {
    return 6;
}
fn sceAgcDriverGetWaitRenderingPacketSizeInDwords() callconv(.c) u32 {
    return 4;
}

/// Writes the packet that makes the queue wait until a display buffer may
/// be drawn to, where `*cursor` points, and moves it on.
fn sceAgcDriverWaitUntilSafeForRendering(cursor: ?*[*]u32, capacity: u32, mode: u32, handle: u32, buffer: i32) callconv(.c) i32 {
    const c = cursor orelse return ERROR.FAILED;
    if (capacity < 4 or mode != 0 or buffer < 0) return ERROR.FAILED;
    var w = pm4.Writer{ .words = c.*[0..4] };
    _ = w.putNop(pm4.SUB.WAIT_SAFE, &.{ handle, @bitCast(buffer), 0 });
    c.* += 4;
    return 0;
}

/// Nothing is being captured, traced or validated here; resources are not
/// registered by name (a game is told so and goes on).
fn no() callconv(.c) bool {
    return false;
}
fn zero() callconv(.c) i32 {
    return 0;
}
fn noRegistration() callconv(.c) i32 {
    return ERROR.NO_REGISTRATION;
}

// ── The table ───────────────────────────────────────────────────────────────

fn entry(comptime name: []const u8, comptime f: anytype) struct { []const u8, *const anyopaque } {
    return .{ name, @ptrCast(f) };
}

/// Every name this library answers, by NID.
pub const exports = nid.Table(*const anyopaque, &[_]struct { []const u8, *const anyopaque }{
    entry("sceAgcDriverSubmitDcb", &sceAgcDriverSubmitDcb),
    entry("sceAgcDriverAgrSubmitDcb", &sceAgcDriverSubmitDcb),
    entry("sceAgcDriverSubmitMultiDcbs", &sceAgcDriverSubmitMultiDcbs),
    entry("sceAgcDriverAgrSubmitMultiDcbs", &sceAgcDriverSubmitMultiDcbs),
    entry("sceAgcDriverSubmitCommandBuffer", &sceAgcDriverSubmitCommandBuffer),
    entry("sceAgcDriverSubmitMultiCommandBuffers", &sceAgcDriverSubmitMultiCommandBuffers),
    entry("sceAgcDriverAddEqEvent", &sceAgcDriverAddEqEvent),
    entry("sceAgcDriverDeleteEqEvent", &sceAgcDriverDeleteEqEvent),
    entry("sceAgcDriverGetEqEventType", &sceAgcDriverGetEqEventType),
    entry("sceAgcDriverGetEqContextId", &sceAgcDriverGetEqContextId),
    entry("sceAgcDriverGetSetFlipPacketSizeInDwords", &sceAgcDriverGetSetFlipPacketSizeInDwords),
    entry("sceAgcDriverGetWaitRenderingPacketSizeInDwords", &sceAgcDriverGetWaitRenderingPacketSizeInDwords),
    entry("sceAgcDriverWaitUntilSafeForRendering", &sceAgcDriverWaitUntilSafeForRendering),
    entry("sceAgcDriverIsCaptureInProgress", &no),
    entry("sceAgcDriverIsTraceInProgress", &no),
    entry("sceAgcDriverIsSubmitValidationEnabled", &no),
    entry("sceAgcDriverRegisterDefaultOwner", &zero),
    entry("sceAgcDriverGetDefaultOwner", &noRegistration),
});

/// The address of one of this library's functions, by the library a game
/// named and its NID; null when this is not the library or it has no such
/// function.
pub fn find(library: []const u8, n: nid.Nid) ?u64 {
    if (!std.mem.eql(u8, library, "libSceAgcDriver")) return null;
    const p = exports.find(n) orelse return null;
    return @intFromPtr(p);
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// With no kernel under them: the test is the worker (`runOne`, `waitIdle`),
// the buffers are its own memory, and a wait's sleep turns a hook.

const Testing = struct {
    var now_ns: u64 = 5_000_000_000;
    var on_nap: ?*const fn () void = null;
    var drawn: [8]Draw = undefined;
    var draws: usize = 0;
    var syncs: usize = 0;
    /// What the context register 0x80 held at each draw.
    var seen_cx: [8]u32 = undefined;
    /// A word of the test's, and what it held each time the renderer was
    /// told to finish (a label must not be there before its sync).
    var probe: ?*const u32 = null;
    var probed: [16]u32 = undefined;

    fn onDraw(s: *const State, d: Draw) void {
        if (draws < drawn.len) {
            drawn[draws] = d;
            seen_cx[draws] = s.cx[0x80];
        }
        draws += 1;
    }
    fn onSync() void {
        if (probe) |p| {
            if (syncs < probed.len) probed[syncs] = p.*;
        }
        syncs += 1;
    }

    fn reset() void {
        waitIdle();
        queue.state_ready = false;
        queue.said = [_]bool{false} ** 256;
        queue.watchers = [_]Watcher{.{}} ** 8;
        draws = 0;
        syncs = 0;
        on_nap = null;
        probe = null;
        budget = 1 << 26;
        videoout.flip_router = null;
        renderer = .{ .draw = onDraw, .sync = onSync };
        inline for (.{ "submissions", "packets", "draws", "flips", "labels", "interrupts", "skipped", "refused" }) |name| @field(stats, name) = 0;
    }

    fn run(words: []const u32) !void {
        const s = Submission{ .commands = words.ptr, .words = @intCast(words.len) };
        try std.testing.expectEqual(@as(i32, 0), sceAgcDriverSubmitDcb(&s));
        waitIdle();
    }

    var queue_storage: [3]equeue.TestQueue = undefined;
};

fn lo(p: anytype) u32 {
    return @truncate(@intFromPtr(p));
}
fn hi(p: anytype) u32 {
    return @truncate(@intFromPtr(p) >> 32);
}

test "a submission is what the SDK's structure is" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Submission));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Submission, "words"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Submission, "flags"));
}

test "registers reach the draws that follow them; index and instance state" {
    Testing.reset();
    var words: [96]u32 = undefined;
    var w = pm4.Writer{ .words = &words };
    var indices = [_]u16{ 0, 1, 2, 2, 1, 3 };
    _ = w.setRegisters(.cx, 0x80, &.{0x11});
    _ = w.setRegisters(.uc, UC.INDEX_OFFSET, &.{7});
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 3, 2 });
    // The tag register changes nothing (0x342, and the word after it).
    _ = w.setRegisters(.uc, pm4.UC_TAG, &.{ 0xC600_0005, 9 });
    _ = w.put(OP.CONTEXT_REG_RMW, 0, &.{ 0x80, 0xF0, 0xFF });
    _ = w.put(OP.NUM_INSTANCES, 0, &.{4});
    _ = w.put(OP.SET_UCONFIG_REG_INDEX, 0, &.{ 0x2000_0243, 1 });
    _ = w.put(OP.DRAW_INDEX_2, 0, &.{ 6, lo(&indices), hi(&indices), 6, 0 });
    _ = w.put(OP.INDEX_TYPE, 0, &.{0});
    _ = w.put(OP.INDEX_BASE, 0, &.{ lo(&indices), hi(&indices) });
    _ = w.put(OP.DRAW_INDEX_OFFSET_2, 0, &.{ 6, 3, 3, 0 });
    // The context registers put aside, cleared, and brought back.
    _ = w.putNop(pm4.SUB.CONTEXT_STATE, &.{ 3, 0 });
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 3, 2 });
    _ = w.putNop(pm4.SUB.CONTEXT_STATE, &.{ 2, 0 });
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 3, 2 });
    // (a draw of nothing is counted and not drawn)
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 0, 2 });
    try std.testing.expect(!w.full);
    try Testing.run(w.written());

    try std.testing.expectEqual(@as(usize, 5), Testing.draws);
    try std.testing.expectEqual(@as(u64, 6), stats.draws);
    // Without indices: the first vertex from its register.
    try std.testing.expectEqual(Draw{ .count = 3, .instances = 1, .base_vertex = 7 }, Testing.drawn[0]);
    try std.testing.expectEqual(@as(u32, 0x11), Testing.seen_cx[0]);
    // With 32-bit indices at an address, four instances; the register as
    // the masked write left it.
    try std.testing.expectEqual(Draw{ .count = 6, .instances = 4, .index_address = @intFromPtr(&indices), .index_size = 4 }, Testing.drawn[1]);
    try std.testing.expectEqual(@as(u32, 0xF1), Testing.seen_cx[1]);
    // From the fourth 16-bit index of the index buffer.
    try std.testing.expectEqual(Draw{ .count = 3, .instances = 4, .index_address = @intFromPtr(&indices) + 6, .index_size = 2 }, Testing.drawn[2]);
    try std.testing.expectEqual(@as(u32, 0), Testing.seen_cx[3]);
    try std.testing.expectEqual(@as(u32, 0xF1), Testing.seen_cx[4]);
    try std.testing.expectEqual(@as(u32, 0), queue.state.uc[pm4.UC_TAG]);
    try std.testing.expectEqual(@as(u64, 0), stats.skipped + stats.refused);
}

test "labels and interrupts come after what was drawn before them, in order" {
    Testing.reset();
    const q = equeue.testQueue(&Testing.queue_storage[0], "gpu");
    defer equeue.testDelete(q);
    // (two queues listen: each hears of an interrupt)
    const q2 = equeue.testQueue(&Testing.queue_storage[1], "gpu too");
    defer equeue.testDelete(q2);
    try std.testing.expectEqual(@as(i32, 0), sceAgcDriverAddEqEvent(q, 0, 0xE0));
    try std.testing.expectEqual(@as(i32, 0), sceAgcDriverAddEqEvent(q2, 0, 0xE2));
    try std.testing.expectEqual(ERROR.UNAVAILABLE, sceAgcDriverAddEqEvent(q, 0x20, 0));

    var label: u32 = 0;
    var wide: u64 = 0;
    var clock: u64 = 0;
    var row = [_]u32{0} ** 4;
    var copy: u32 = 0;
    var bytes = [_]u8{0} ** 8;
    var words: [96]u32 = undefined;
    var w = pm4.Writer{ .words = &words };
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 3, 2 });
    // A 32-bit label with an interrupt (the game's number for it: 0x123).
    _ = w.put(OP.RELEASE_MEM, 0, &.{ 0x2F, 1 << 29 | 2 << 24, lo(&label), hi(&label), 0xABCD, 0, 0x123 });
    // A 64-bit label, and the GPU's clock, with no interrupt.
    _ = w.put(OP.RELEASE_MEM, 0, &.{ 0x2F, 2 << 29, lo(&wide), hi(&wide), 0x1111_2222, 0x3333_4444, 0 });
    _ = w.put(OP.RELEASE_MEM, 0, &.{ 0x2F, 3 << 29, lo(&clock), hi(&clock), 0, 0, 0 });
    // Words of a packet to memory: in a row, and all to one address.
    _ = w.put(OP.WRITE_DATA, 0, &.{ 5 << 8, lo(&row), hi(&row), 1, 2, 3 });
    _ = w.put(OP.WRITE_DATA, 0, &.{ 5 << 8 | 1 << 16, lo(&row[3]), hi(&row[3]), 7, 8, 9 });
    _ = w.put(OP.COPY_DATA, 0, &.{ 2 | 5 << 8, lo(&label), hi(&label), lo(&copy), hi(&copy) });
    _ = w.put(OP.DMA_DATA, 0, &.{ 2 << 29, 0x4433_2211, 0, lo(&bytes), hi(&bytes), 6 });
    try std.testing.expect(!w.full);
    Testing.probe = &label;
    try Testing.run(w.written());

    // The first label was not there when the renderer was told to finish
    // before it, and was at every time after.
    try std.testing.expectEqual(@as(u32, 0), Testing.probed[0]);
    try std.testing.expectEqual(@as(u32, 0xABCD), Testing.probed[1]);
    try std.testing.expectEqual(@as(u32, 0xABCD), label);
    try std.testing.expectEqual(@as(u64, 0x3333_4444_1111_2222), wide);
    try std.testing.expectEqual(Testing.now_ns / 10, clock);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 9 }, &row);
    try std.testing.expectEqual(@as(u32, 0xABCD), copy);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44, 0x11, 0x22, 0, 0 }, &bytes);
    // The renderer was told to finish before each of them.
    try std.testing.expectEqual(@as(usize, 7), Testing.syncs);
    try std.testing.expectEqual(@as(u64, 1), stats.interrupts);

    var ev: [2]equeue.Event = undefined;
    try std.testing.expectEqual(@as(i64, 1), equeue.wait(q, &ev, 0));
    try std.testing.expectEqual(equeue.FILTER.GRAPHICS_CORE, ev[0].filter);
    try std.testing.expectEqual(@as(u64, 0xE0), ev[0].udata);
    try std.testing.expectEqual(@as(u32, 0x123), sceAgcDriverGetEqContextId(&ev[0]));
    try std.testing.expectEqual(@as(i32, 0x123 << 16), sceAgcDriverGetEqEventType(&ev[0]));
    try std.testing.expectEqual(@as(i64, 1), equeue.wait(q2, &ev, 0));
    try std.testing.expectEqual(@as(u64, 0xE2), ev[0].udata);
    // Read: no more until the next interrupt. Deleted: none at all.
    try std.testing.expectEqual(-@as(i64, abi.E.TIMEDOUT), equeue.wait(q, &ev, 0));
    try std.testing.expectEqual(@as(i32, 0), sceAgcDriverDeleteEqEvent(q, 0));
    try std.testing.expectEqual(ERROR.FAILED, sceAgcDriverDeleteEqEvent(q, 0));
    try Testing.run(w.written());
    try std.testing.expectEqual(-@as(i64, abi.E.TIMEDOUT), equeue.wait(q, &ev, 0));
    try std.testing.expectEqual(@as(u64, 0), stats.skipped + stats.refused);

    // A queue deleted without the driver being told gives its place back
    // at the next interrupt: more of them than there are places.
    try std.testing.expectEqual(@as(i32, 0), sceAgcDriverDeleteEqEvent(q2, 0));
    for (0..12) |_| {
        const gone = equeue.testQueue(&Testing.queue_storage[2], "gone");
        try std.testing.expectEqual(@as(i32, 0), sceAgcDriverAddEqEvent(gone, 0, 0));
        equeue.testDelete(gone);
        try Testing.run(w.written());
    }
    // And one at whose address another queue now is, which never asked.
    const stale = equeue.testQueue(&Testing.queue_storage[2], "stale");
    try std.testing.expectEqual(@as(i32, 0), sceAgcDriverAddEqEvent(stale, 0, 0));
    equeue.testDelete(stale);
    const other = equeue.testQueue(&Testing.queue_storage[2], "other");
    defer equeue.testDelete(other);
    try Testing.run(w.written());
    var used: u32 = 0;
    for (queue.watchers) |x| used += @intFromBool(x.used);
    try std.testing.expectEqual(@as(u32, 0), used);
}

var gate: u32 = 0;
var gate_naps: u32 = 0;

fn openGate() void {
    gate_naps += 1;
    if (gate_naps == 3) gate = 0x55;
}

test "the queue stands still at a wait, skips what a condition says, calls other buffers" {
    Testing.reset();
    var label: u32 = 0;
    var zero_word: u32 = 0;
    var one_word: u32 = 1;

    // A buffer that is called: a draw of 5.
    var inner: [8]u32 = undefined;
    var wi = pm4.Writer{ .words = &inner };
    _ = wi.put(OP.DRAW_INDEX_AUTO, 0, &.{ 5, 2 });

    var words: [96]u32 = undefined;
    var w = pm4.Writer{ .words = &words };
    // Wait until the gate word, masked, is 0x50 (another thread's write:
    // here the third look).
    gate = 0;
    gate_naps = 0;
    Testing.on_nap = openGate;
    _ = w.put(OP.WAIT_REG_MEM, 0, &.{ 3 | 1 << 4, lo(&gate), hi(&gate), 0x50, 0xF0, 10 });
    _ = w.put(OP.WRITE_DATA, 0, &.{ 5 << 8, lo(&label), hi(&label), 1 });
    // A word that is 0: the next packet (3 words) is skipped.
    _ = w.put(OP.COND_EXEC, 0, &.{ lo(&zero_word), hi(&zero_word), 0, 3 });
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 100, 2 });
    // A word that is not: the next packet runs.
    _ = w.put(OP.COND_EXEC, 0, &.{ lo(&one_word), hi(&one_word), 0, 3 });
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 3, 2 });
    // The other buffer, then on with this one.
    _ = w.put(OP.INDIRECT_BUFFER, 0, &.{ lo(&inner), hi(&inner), @intCast(wi.len) });
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 4, 2 });
    // Packets marked for it run only while the predicate holds.
    _ = w.put(OP.SET_PREDICATION, 0, &.{ 4 << 16 | 1 << 8, lo(&zero_word), hi(&zero_word) });
    _ = w.put(OP.DRAW_INDEX_AUTO, pm4.FLAG.PREDICATE, &.{ 200, 2 });
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 6, 2 });
    _ = w.put(OP.SET_PREDICATION, 0, &.{ 0, 0, 0 });
    _ = w.put(OP.DRAW_INDEX_AUTO, pm4.FLAG.PREDICATE, &.{ 7, 2 });
    try std.testing.expect(!w.full);
    try Testing.run(w.written());

    try std.testing.expectEqual(@as(u32, 3), gate_naps);
    try std.testing.expectEqual(@as(u32, 1), label);
    try std.testing.expectEqual(@as(usize, 5), Testing.draws);
    for ([_]u32{ 3, 5, 4, 6, 7 }, Testing.drawn[0..5]) |want, d| try std.testing.expectEqual(want, d.count);
    try std.testing.expectEqual(@as(u64, 0), stats.skipped + stats.refused);

    // A buffer that ends in a call that never returns (a chain): what
    // follows the call in the first buffer is not run.
    Testing.reset();
    w = pm4.Writer{ .words = &words };
    _ = w.put(OP.INDIRECT_BUFFER, 0, &.{ lo(&inner), hi(&inner), @as(u32, @intCast(wi.len)) | 1 << 20 });
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 9, 2 });
    try Testing.run(w.written());
    try std.testing.expectEqual(@as(usize, 1), Testing.draws);
    try std.testing.expectEqual(@as(u32, 5), Testing.drawn[0].count);

    // A skip that reaches past the buffer's end stops at the end.
    Testing.reset();
    w = pm4.Writer{ .words = &words };
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 1, 2 });
    _ = w.put(OP.COND_EXEC, 0, &.{ lo(&zero_word), hi(&zero_word), 0, 0x3FFF });
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 2, 2 });
    try Testing.run(w.written());
    try std.testing.expectEqual(@as(usize, 1), Testing.draws);
    // (the renderer was told to finish before the condition was read)
    try std.testing.expectEqual(@as(usize, 1), Testing.syncs);

    // A buffer that follows itself for ever is left, and the queue goes on
    // to the next submission.
    Testing.reset();
    budget = 4096;
    var ring: [8]u32 = undefined;
    var wr = pm4.Writer{ .words = &ring };
    _ = wr.put(OP.DRAW_INDEX_AUTO, 0, &.{ 1, 2 });
    _ = wr.put(OP.INDIRECT_BUFFER, 0, &.{ lo(&ring), hi(&ring), 7 | 1 << 20 });
    try Testing.run(wr.written());
    try std.testing.expectEqual(@as(u64, 1), stats.refused);
    try std.testing.expect(Testing.draws > 100);
    const before = Testing.draws;
    try Testing.run(wi.written());
    try std.testing.expectEqual(before + 1, Testing.draws);
    // So is one that calls itself: sixteen deep, then the calls are left
    // out and each level runs to its end.
    Testing.reset();
    wr = pm4.Writer{ .words = &ring };
    _ = wr.put(OP.INDIRECT_BUFFER, 0, &.{ lo(&ring), hi(&ring), 7 });
    _ = wr.put(OP.DRAW_INDEX_AUTO, 0, &.{ 1, 2 });
    try Testing.run(wr.written());
    try std.testing.expectEqual(@as(usize, NESTING + 1), Testing.draws);
    try std.testing.expectEqual(@as(u64, 1), stats.refused);
}

test "indirect draws: the record read after the renderer finished, its numbers given to the shader" {
    Testing.reset();
    var records = [_]u32{ 0, 0, 30, 2, 5, 9, 12, 3, 1, -%@as(u32, 4), 6 };
    var indices = [_]u16{0} ** 16;
    var words: [64]u32 = undefined;
    var w = pm4.Writer{ .words = &words };
    _ = w.put(OP.SET_BASE, 0, &.{ 1, lo(&records), hi(&records) });
    // Vertices: the record at byte 8; the base vertex into shader
    // register 0x8C, the first instance into 0x8D.
    _ = w.put(OP.DRAW_INDIRECT, 0, &.{ 8, 0x8C, 0x8D, 2 });
    // Indices: the record at byte 24; the limit is the index buffer's.
    _ = w.put(OP.INDEX_BASE, 0, &.{ lo(&indices), hi(&indices) });
    _ = w.put(OP.INDEX_BUFFER_SIZE, 0, &.{16});
    _ = w.put(OP.DRAW_INDEX_INDIRECT, 0, &.{ 24, 0x10C, 0, 0 });
    // An index type set as a plain register is the draws' index size too,
    // and a draw from an offset cannot run past what the buffer holds.
    _ = w.setRegisters(.uc, UC.INDEX_TYPE, &.{1});
    _ = w.put(OP.DRAW_INDEX_OFFSET_2, 0, &.{ 1, 3, 100, 0 });
    try std.testing.expect(!w.full);
    try Testing.run(w.written());

    try std.testing.expectEqual(@as(usize, 3), Testing.draws);
    try std.testing.expectEqual(Draw{ .count = 30, .instances = 2, .base_vertex = 5, .first_instance = 9 }, Testing.drawn[0]);
    try std.testing.expectEqual(@as(u32, 5), queue.state.sh[0x8C]);
    try std.testing.expectEqual(@as(u32, 9), queue.state.sh[0x8D]);
    try std.testing.expectEqual(Draw{ .count = 12, .instances = 3, .index_address = @intFromPtr(&indices) + 2, .index_size = 2, .base_vertex = -4, .first_instance = 6 }, Testing.drawn[1]);
    try std.testing.expectEqual(-%@as(u32, 4), queue.state.sh[0x10C]);
    try std.testing.expectEqual(Draw{ .count = 1, .instances = 1, .index_address = @intFromPtr(&indices) + 12, .index_size = 4 }, Testing.drawn[2]);
    // (told to finish before each record was read)
    try std.testing.expectEqual(@as(usize, 2), Testing.syncs);
    try std.testing.expectEqual(@as(u64, 0), stats.skipped + stats.refused);
}

var rewind_at: *u32 = undefined;

fn releaseRewind() void {
    rewind_at.* = 0x8000_0000;
}

test "a buffer finished later, what is not a packet, a kind not carried out" {
    Testing.reset();
    var words: [32]u32 = undefined;
    var w = pm4.Writer{ .words = &words };
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 1, 2 });
    const at = w.put(OP.REWIND, 0, &.{0}).?;
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 2, 2 });
    // The game says the rest is written when the worker first naps.
    rewind_at = &words[at + 1];
    Testing.on_nap = releaseRewind;
    try Testing.run(w.written());
    try std.testing.expectEqual(@as(usize, 2), Testing.draws);
    // The same in a buffer that is called.
    Testing.reset();
    words[at + 1] = 0;
    var outer: [8]u32 = undefined;
    var wo = pm4.Writer{ .words = &outer };
    _ = wo.put(OP.INDIRECT_BUFFER, 0, &.{ lo(&words), hi(&words), @intCast(w.len) });
    _ = wo.put(OP.DRAW_INDEX_AUTO, 0, &.{ 3, 2 });
    Testing.on_nap = releaseRewind;
    try Testing.run(wo.written());
    try std.testing.expectEqual(@as(usize, 3), Testing.draws);

    // A word that is no header ends the buffer there, and is counted.
    Testing.reset();
    const bad = [_]u32{ pm4.header(OP.DRAW_INDEX_AUTO, 3, 0), 3, 2, 0x0000_1234, pm4.header(OP.DRAW_INDEX_AUTO, 3, 0), 3, 2 };
    try Testing.run(&bad);
    try std.testing.expectEqual(@as(usize, 1), Testing.draws);
    try std.testing.expectEqual(@as(u64, 1), stats.refused);

    // A kind of packet not carried out is stepped over and counted; one
    // of the right kind and the wrong length is too.
    Testing.reset();
    w = pm4.Writer{ .words = &words };
    _ = w.put(OP.DISPATCH_DIRECT, 0, &.{ 1, 1, 1, 1 });
    _ = w.put(OP.RELEASE_MEM, 0, &.{ 0x2F, 0 });
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 3, 2 });
    try Testing.run(w.written());
    try std.testing.expectEqual(@as(u64, 2), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), Testing.draws);

    // What a submit call refuses.
    try std.testing.expectEqual(ERROR.FAILED, sceAgcDriverSubmitDcb(null));
    const flagged = Submission{ .commands = &bad, .words = 3, .flags = 1 };
    try std.testing.expectEqual(ERROR.FAILED, sceAgcDriverSubmitDcb(&flagged));
    const nothing = Submission{ .commands = null, .words = 3 };
    try std.testing.expectEqual(ERROR.FAILED, sceAgcDriverSubmitDcb(&nothing));
    const compute = QueueContext{ .reserved = 0, .queue = 0x20 };
    try std.testing.expectEqual(ERROR.UNAVAILABLE, sceAgcDriverSubmitCommandBuffer(&compute, &flagged));
}

test "a flip in a command buffer reaches the display, after what was drawn" {
    Testing.reset();
    const h = videoout.testOpen();
    defer videoout.testClose(h);
    var pixels = [_]u32{0xFF10_2030} ** 4;
    try std.testing.expectEqual(@as(i32, 0), videoout.testRegister(h, 0, &pixels, 2, 2));
    var words: [32]u32 = undefined;
    var w = pm4.Writer{ .words = &words };
    _ = w.put(OP.DRAW_INDEX_AUTO, 0, &.{ 3, 2 });
    _ = w.flip(@intCast(h), 0, 1, 0x7777);
    // (a flip of a buffer that was never registered is counted as refused)
    _ = w.flip(@intCast(h), 9, 1, 0);
    // The buffer's two flips are pending from the submit, before the
    // queue has come to them.
    const s = Submission{ .commands = &words, .words = @intCast(w.len) };
    try std.testing.expectEqual(@as(i32, 0), sceAgcDriverSubmitDcb(&s));
    try std.testing.expectEqual(@as(i32, 2), videoout.pendingFlips(h));
    // A flip the game's own code asks for now goes behind the buffer.
    try std.testing.expectEqual(@as(i32, 0), videoout.testFlip(h, 0, 0x8888));
    try std.testing.expectEqual(@as(i32, 3), videoout.pendingFlips(h));
    waitIdle();
    try std.testing.expectEqual(@as(u64, 3), stats.flips);
    try std.testing.expectEqual(@as(u64, 1), stats.refused);
    try std.testing.expectEqual(@as(usize, 3), Testing.syncs);
    // (the flip that could not be dropped its promise)
    try std.testing.expectEqual(@as(i32, 2), videoout.pendingFlips(h));
    videoout.tick();
    try std.testing.expectEqual(@as(i64, 0x7777), videoout.lastFlipArg(h));
    videoout.tick();
    try std.testing.expectEqual(@as(i64, 0x8888), videoout.lastFlipArg(h));
    try std.testing.expectEqual(@as(i32, 0), videoout.pendingFlips(h));
    // With the queue idle, such a flip is queued by the display at once.
    try std.testing.expectEqual(@as(i32, 0), videoout.testFlip(h, 0, 0x9999));
    try std.testing.expectEqual(@as(u64, 3), stats.flips);
    videoout.tick();
    try std.testing.expectEqual(@as(i64, 0x9999), videoout.lastFlipArg(h));

    // A flip a skip passes over, and one after a buffer was left: their
    // promises are taken back.
    Testing.reset();
    var zero_word: u32 = 0;
    w = pm4.Writer{ .words = &words };
    _ = w.put(OP.COND_EXEC, 0, &.{ lo(&zero_word), hi(&zero_word), 0, 6 });
    _ = w.flip(@intCast(h), 0, 1, 1);
    words[w.len] = 0x0000_1234;
    w.len += 1;
    _ = w.flip(@intCast(h), 0, 1, 2);
    try Testing.run(w.written());
    try std.testing.expectEqual(@as(u64, 0), stats.flips);
    try std.testing.expectEqual(@as(i32, 0), videoout.pendingFlips(h));

    // The packet a game's library asks this driver to write for it.
    var buf: [4]u32 = undefined;
    var cursor: [*]u32 = &buf;
    try std.testing.expectEqual(@as(i32, 0), sceAgcDriverWaitUntilSafeForRendering(&cursor, 4, 0, 1, 3));
    try std.testing.expectEqual(@intFromPtr(&buf) + 16, @intFromPtr(cursor));
    try std.testing.expectEqualSlices(u32, &.{ 0xC002_1018, 1, 3, 0 }, &buf);
    try std.testing.expectEqual(ERROR.FAILED, sceAgcDriverWaitUntilSafeForRendering(&cursor, 3, 0, 1, 3));
    try std.testing.expectEqual(@as(u32, 6), sceAgcDriverGetSetFlipPacketSizeInDwords());
}

test "names resolve by NID under the library's name" {
    try std.testing.expect(find("libSceAgcDriver", nid.of("sceAgcDriverSubmitDcb")) != null);
    try std.testing.expectEqual(@as(?u64, null), find("libSceAgc", nid.of("sceAgcDriverSubmitDcb")));
}
