//! @zpm/ps5 videoout — the display library (libSceVideoOut), written in
//! Sig: a game opens the display, says which of its buffers hold frames,
//! asks for one to be shown (a "flip"), and waits on an event queue to hear
//! that it was, or that the screen began a new refresh (a "vblank").
//!
//! On the console this is a system module over the kernel's display driver.
//! Here it is in the process. A clock thread stands in for the screen's
//! refresh: at every tick it counts a vblank, and takes the oldest flip
//! waiting (at the rate the game set), shows it, and posts the events. So a
//! game that paces itself on flips runs at the screen's rate, as it does on
//! the console.
//!
//! Where a frame goes is the host's: `display` is a window, a screen, or
//! nothing (the flips still happen, and the events with them). Where a
//! frame comes from is the buffer's own memory when the program drew it
//! itself, and `source` when the GPU path did (its picture is not in the
//! program's memory).
//!
//! A game written for the PS5 registers its buffers one way
//! (sceVideoOutRegisterBuffers2, 64-bit format codes) and one written for
//! the PS4 another (sceVideoOutRegisterBuffers, 32-bit codes); the flip
//! status is then laid out as that console's is.
//!
//! Not here: stereo buffers, the cursor plane, HDR output (a 10-bit or
//! float buffer is shown as 8-bit, without tone mapping), the second
//! outputs (social screen, streaming), flips triggered by the GPU's end of
//! pipe. A buffer's memory is read when its flip is shown: a game that
//! unmaps a buffer without unregistering it first, with a flip of it still
//! waiting, faults, where a console would show stale pixels.
//!
//! No Sony code: the names, numbers and structures are the public SDK
//! surface as open projects document it. x86-64 only. Allocation-free.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.sig");
const abi = @import("abi.sig");
const nid = @import("nid.sig");
const pthread = @import("pthread.sig");
const equeue = @import("equeue.sig");

const S = abi.Sys;

// ── What the host gives ─────────────────────────────────────────────────────

/// Where frames are shown.
pub const Display = struct {
    /// A place for frames of this size. False: there is none.
    open: *const fn (width: u32, height: u32) bool,
    /// Where the next frame is to be written: width * height words, rows
    /// from the top, each 0xAARRGGBB. Null: not now.
    frame: *const fn () ?[*]u32,
    /// Shows what was written there.
    show: *const fn () void,
    close: *const fn () void,
    /// Called at each refresh while the place is open, whether a frame was
    /// shown or not (a window looks at what the person did to it).
    refresh: ?*const fn () void = null,
};

pub var display: ?Display = null;

/// The frame in a registered buffer when the program's own code did not
/// draw it (the GPU path did): writes it to `out` as the display takes it,
/// or says false (it knows nothing of that buffer).
pub const Source = *const fn (address: u64, width: u32, height: u32, out: [*]u32) bool;

pub var source: ?Source = null;

/// The screen's size as a game is told it (it picks its buffers' size from
/// this).
pub var screen = [2]u32{ 1920, 1080 };

// ── Numbers ─────────────────────────────────────────────────────────────────

pub const ERROR = struct {
    pub const INVALID_VALUE: i32 = @bitCast(@as(u32, 0x8029_0001));
    pub const INVALID_ADDRESS: i32 = @bitCast(@as(u32, 0x8029_0002));
    pub const INVALID_PIXEL_FORMAT: i32 = @bitCast(@as(u32, 0x8029_0003));
    pub const INVALID_PITCH: i32 = @bitCast(@as(u32, 0x8029_0004));
    pub const INVALID_RESOLUTION: i32 = @bitCast(@as(u32, 0x8029_0005));
    pub const INVALID_FLIP_MODE: i32 = @bitCast(@as(u32, 0x8029_0006));
    pub const INVALID_TILING_MODE: i32 = @bitCast(@as(u32, 0x8029_0007));
    pub const RESOURCE_BUSY: i32 = @bitCast(@as(u32, 0x8029_0009));
    pub const INVALID_INDEX: i32 = @bitCast(@as(u32, 0x8029_000A));
    pub const INVALID_HANDLE: i32 = @bitCast(@as(u32, 0x8029_000B));
    pub const INVALID_EVENT_QUEUE: i32 = @bitCast(@as(u32, 0x8029_000C));
    pub const INVALID_EVENT: i32 = @bitCast(@as(u32, 0x8029_000D));
    pub const NO_EMPTY_SLOT: i32 = @bitCast(@as(u32, 0x8029_000F));
    pub const SLOT_OCCUPIED: i32 = @bitCast(@as(u32, 0x8029_0010));
    pub const FLIP_QUEUE_FULL: i32 = @bitCast(@as(u32, 0x8029_0012));
    pub const INVALID_OPTION: i32 = @bitCast(@as(u32, 0x8029_001A));
};

/// How a buffer's pixels are stored: 8 bits a colour with blue or red in
/// the low byte, 10 bits a colour likewise, or four 16-bit floats with
/// blue or red first.
pub const Layout = enum(u8) { bgra8, rgba8, bgr10a2, rgb10a2, bgra16f, rgba16f };

/// The PS4's 32-bit format codes.
pub const FORMAT = struct {
    pub const A8R8G8B8_SRGB: u32 = 0x8000_0000;
    pub const A8B8G8R8_SRGB: u32 = 0x8000_2200;
    pub const A2R10G10B10: u32 = 0x8806_0000;
    pub const A2R10G10B10_SRGB: u32 = 0x8800_0000;
    pub const A2R10G10B10_BT2020_PQ: u32 = 0x8874_0000;
    pub const A16R16G16B16_FLOAT: u32 = 0xC106_0000;

    pub fn layout(code: u32) ?Layout {
        return switch (code) {
            A8R8G8B8_SRGB => .bgra8,
            A8B8G8R8_SRGB => .rgba8,
            A2R10G10B10, A2R10G10B10_SRGB, A2R10G10B10_BT2020_PQ => .bgr10a2,
            // (on the PS4 the floats are red first)
            A16R16G16B16_FLOAT => .rgba16f,
            else => null,
        };
    }
};

/// The PS5's 64-bit format codes.
pub const FORMAT5 = struct {
    pub const B8G8R8A8: u64 = 0x8000_0000_0000_0000;
    pub const R8G8B8A8: u64 = 0x8000_0000_2200_0000;
    pub const B10G10R10A2: u64 = 0x8100_0000_0000_0000;
    pub const R10G10B10A2: u64 = 0x8100_0000_2200_0000;
    pub const B10G10R10A2_PQ: u64 = 0x8100_0704_0000_0000;
    pub const R10G10B10A2_PQ: u64 = 0x8100_0704_2200_0000;
    pub const B16G16R16A16_FLOAT: u64 = 0xC001_0006_0000_0000;
    pub const R16G16B16A16_FLOAT: u64 = 0xC001_0006_2200_0000;

    pub fn layout(code: u64) ?Layout {
        return switch (code) {
            B8G8R8A8 => .bgra8,
            R8G8B8A8 => .rgba8,
            B10G10R10A2, B10G10R10A2_PQ => .bgr10a2,
            R10G10B10A2, R10G10B10A2_PQ => .rgb10a2,
            B16G16R16A16_FLOAT => .bgra16f,
            R16G16B16A16_FLOAT => .rgba16f,
            // (a PS4 code in the low word, as some titles pass it)
            else => if (code >> 32 == 0) FORMAT.layout(@truncate(code)) else null,
        };
    }
};

/// How a buffer's pixels are laid out: the GPU's tiles (only the GPU path
/// can read those), or rows.
pub const TILING = struct {
    pub const TILE: u32 = 0;
    pub const LINEAR: u32 = 1;
};

pub const BUFFERS = 16;
pub const GROUPS = 4;
/// Flips that may wait to be shown.
pub const QUEUE = 16;

/// The one output there is (the main one), as a game's handle.
const HANDLE: i32 = 1;
const BUS_MAIN: i32 = 0;

/// What an event is of, as the queue keeps it (the event's identity; a
/// game is not shown it: it asks sceVideoOutGetEventId) and as a game is
/// told it.
pub const EVENT = struct {
    pub const FLIP: u64 = 0x6 << 48;
    pub const VBLANK: u64 = 0x7 << 48;
    pub const ID_FLIP: i32 = 0;
    pub const ID_VBLANK: i32 = 1;
};

/// A screen's refresh, in nanoseconds (59.94 Hz), and its SDK number.
pub const REFRESH_NS: u64 = 16_683_350;
const REFRESH_59_94: u64 = 3;

// ── Structures a game hands over or gets back ───────────────────────────────

/// The PS4's buffer attributes.
pub const Attribute = extern struct {
    pixel_format: u32 = 0,
    tiling_mode: u32 = 0,
    aspect_ratio: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch_in_pixel: u32 = 0,
    option: u32 = 0,
    reserved0: u32 = 0,
    reserved1: u64 = 0,
};

/// The PS5's.
pub const Attribute2 = extern struct {
    reserved0: u32 = 0,
    tiling_mode: u32 = 0,
    aspect_ratio: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch_in_pixel: u32 = 0,
    option: u64 = 0,
    pixel_format: u64 = 0,
    dcc_clear_color: u64 = 0,
    dcc_control: u32 = 0,
    pad0: u32 = 0,
    reserved1: [3]u64 = .{ 0, 0, 0 },
};

/// One of the buffers a PS5 game registers: its pixels, and the GPU's
/// compression keys for them when it has any.
pub const Buffer2 = extern struct {
    data: u64 = 0,
    metadata: u64 = 0,
    reserved: [2]u64 = .{ 0, 0 },
};

/// The flip status as a PS4 game reads it (64 bytes).
pub const FlipStatus = extern struct {
    count: u64 = 0,
    process_time: u64 = 0,
    tsc: u64 = 0,
    flip_arg: i64 = -1,
    submit_tsc: u64 = 0,
    reserved0: u64 = 0,
    gc_queue_num: i32 = 0,
    flip_pending_num: i32 = 0,
    current_buffer: i32 = -1,
    reserved1: u32 = 0,
};

/// As a PS5 game reads it (128 bytes).
pub const FlipStatus5 = extern struct {
    count: u64 = 0,
    process_time: u64 = 0,
    reserved0: u64 = 0,
    flip_arg: i64 = -1,
    reserved1: u64 = 0,
    process_time_counter: u64 = 0,
    gc_queue_num: i32 = 0,
    flip_pending_num: i32 = 0,
    current_buffer: i32 = -1,
    reserved2: u32 = 0,
    submit_process_time_counter: u64 = 0,
    reserved3: [7]u64 = [_]u64{0} ** 7,
};

pub const VblankStatus = extern struct {
    count: u64 = 0,
    process_time: u64 = 0,
    tsc: u64 = 0,
    process_time_counter: u64 = 0,
    flags: u8 = 0,
    pad: [7]u8 = [_]u8{0} ** 7,
};

pub const ResolutionStatus = extern struct {
    full_width: i32 = 0,
    full_height: i32 = 0,
    pane_width: i32 = 0,
    pane_height: i32 = 0,
    refresh_rate: u64 = REFRESH_59_94,
    screen_size_in_inch: f32 = 50,
    flags: u16 = 0,
    reserved0: u16 = 0,
    reserved1: [3]u32 = [_]u32{0} ** 3,
};

const ColorSettings = extern struct { gamma: f32 = 1, reserved: [3]u32 = [_]u32{0} ** 3 };

// ── The output ──────────────────────────────────────────────────────────────

/// What a group of buffers was registered as.
const Group = struct { layout: Layout, tiled: bool, width: u32, height: u32, pitch: u32 };

const Flip = struct { buffer: i32 = -1, arg: i64 = 0, submit_tsc: u64 = 0 };

const Watcher = struct { queue: usize = 0, used: bool = false };

const port = struct {
    var lock: pthread.Lock = .{};
    var open: bool = false;
    /// Goes up each time the display is opened or closed: a flip taken
    /// before is not this opening's to count.
    var epoch: u32 = 0;
    /// The buffers were registered the PS4's way (the status structures
    /// are then laid out as the PS4's).
    var ps4: bool = false;
    /// A buffer: where it is, and the group (the attributes) it was
    /// registered with; -1: not registered.
    var address: [BUFFERS]u64 = [_]u64{0} ** BUFFERS;
    var group_of: [BUFFERS]i8 = [_]i8{-1} ** BUFFERS;
    var groups: [GROUPS]?Group = [_]?Group{null} ** GROUPS;
    /// Refreshes a frame stays up at least, less one (0: every refresh).
    var flip_rate: u32 = 0;
    var since_flip: u32 = 0;
    var queue: [QUEUE]Flip = undefined;
    var head: usize = 0;
    var waiting: usize = 0;
    /// A flip has left the queue and its picture is on its way to the
    /// display: still pending, as a game counts, and its buffer's memory
    /// is being read.
    var showing: bool = false;
    /// Flips promised and not yet in the queue: in a command buffer the
    /// GPU's queue has not come to, or behind its work. Pending too.
    var reserved: u32 = 0;
    /// Goes up when that ends (who unregisters buffers waits for it).
    var shown_turn: u32 = 0;
    var shown_waiters: u32 = 0;
    var status: FlipStatus = .{};
    var vblank: VblankStatus = .{};
    /// Goes up at each refresh, and when the display is closed: what
    /// sceVideoOutWaitVblank sleeps on.
    var beat: u32 = 0;
    var flip_watch: [8]Watcher = [_]Watcher{.{}} ** 8;
    var vblank_watch: [8]Watcher = [_]Watcher{.{}} ** 8;
    /// A word a buffer: not 0 while a flip of it waits to be shown. A
    /// game's GPU commands may read them; `flips_of` is the count behind
    /// each.
    var labels: [BUFFERS]u64 = [_]u64{0} ** BUFFERS;
    var flips_of: [BUFFERS]u32 = [_]u32{0} ** BUFFERS;
    /// The display as it is now open: its frames' size (0: not open).
    var shown: [2]u32 = .{ 0, 0 };
    var clock_started: bool = false;
    /// Said once each.
    var said_tiled: bool = false;
};

fn valid(handle: i32) bool {
    return handle == HANDLE and port.open;
}

/// Flips asked for and not shown yet, as a game counts them.
fn pendingNow() i32 {
    return @intCast(port.waiting + @intFromBool(port.showing) + port.reserved);
}

/// Has the flips of a command buffer the GPU's queue has taken counted as
/// pending before the queue comes to them.
pub fn reserve(n: u32) void {
    port.lock.lock();
    port.reserved += n;
    port.lock.unlock();
}

/// Takes that back, for promised flips that will not come.
pub fn unreserve(n: u32) void {
    port.lock.lock();
    port.reserved -|= n;
    port.lock.unlock();
}

/// The GPU path's say in a flip the game's own code asks for: when its
/// queue has work waiting, the flip goes behind that work, as on the
/// console (it answers the call's result); else null, and the flip is
/// queued here at once.
pub var flip_router: ?*const fn (handle: i32, buffer: i32, mode: i32, arg: i64) ?i32 = null;

fn say(comptime text: []const u8) void {
    // (a test's host is not this kernel)
    if (builtin.is_test) return;
    const msg = "[ps5] display: " ++ text ++ "\n";
    _ = sys.call(S.write, 2, @intFromPtr(msg.ptr), msg.len, 0, 0, 0);
}

/// Microseconds since the process started, as the status structures count
/// time.
fn processTime() u64 {
    return (nowNs() -% started_ns) / 1000;
}

var started_ns: u64 = 0;

/// The time (a test's host is not this kernel: its clock is a number).
fn nowNs() u64 {
    return if (builtin.is_test) 1_000_000 else pthread.nowNs();
}

// ── The clock: refreshes and flips ──────────────────────────────────────────

/// An event's data: the time (12 bits), how many times it happened since
/// it was read (4 bits, stopping at 15), and 48 bits of its own: a flip's
/// argument, a vblank's number.
fn eventData(old: i64, arg: u64) i64 {
    const before: u64 = @bitCast(old);
    const count: u64 = @min((before >> 12 & 0xF) + 1, 0xF);
    return @bitCast(arg << 16 | count << 12 | (arg >> 48 & 0xFFF));
}

/// What `eventData` is given: the event's own 48 bits, and the time in
/// the 12 above them (they are not part of what a game reads back).
fn eventArg(payload: u64, time: u64) u64 {
    return (payload & 0xFFFF_FFFF_FFFF) | (time & 0xFFF) << 48;
}

/// Posts an event to every queue that asked for it. A queue that is gone
/// (the game deleted it) gives its place in the list back.
fn post(list: *[8]Watcher, ident: u64, payload: u64, time: u64) void {
    for (list) |*w| {
        if (!w.used) continue;
        // (gone, or another queue now at its address that never asked)
        if (equeue.post(w.queue, equeue.FILTER.VIDEO_OUT, ident, eventData, eventArg(payload, time), null) != 0) w.* = .{};
    }
}

/// One refresh of the screen: a vblank is counted and told, and the oldest
/// waiting flip is shown if its turn has come. The clock thread calls this
/// at the screen's rate (a test calls it itself).
pub fn tick() void {
    port.lock.lock();
    if (!port.open) {
        port.lock.unlock();
        // (closed by the game: its window goes, from the one thread that
        // talks to the display)
        if (port.shown[0] != 0) {
            if (display) |d| d.close();
            port.shown = .{ 0, 0 };
        }
        return;
    }
    const epoch = port.epoch;
    const time = processTime();
    port.vblank.count += 1;
    port.vblank.process_time = time;
    port.vblank.tsc = sys.rdtsc();
    port.vblank.process_time_counter = port.vblank.tsc;
    port.since_flip +|= 1;
    var flip: ?Flip = null;
    if (port.waiting != 0 and port.since_flip > port.flip_rate) {
        flip = port.queue[port.head];
        port.head = (port.head + 1) % QUEUE;
        port.waiting -= 1;
        port.showing = true;
        port.since_flip = 0;
    }
    // What the flip shows is read out here. The picture itself is copied
    // with the lock given back (a game's threads go on submitting
    // meanwhile); a call that would take the buffer away waits until
    // `showing` is over.
    var from: ?Frame = null;
    if (flip) |f| {
        if (f.buffer >= 0) from = frameOf(@intCast(f.buffer));
    }
    port.lock.unlock();

    if (flip != null) show(from);
    if (port.shown[0] != 0) {
        if (display) |d| {
            if (d.refresh) |f| f();
        }
    }

    port.lock.lock();
    var wake_waiters = false;
    if (flip) |f| {
        port.showing = false;
        port.shown_turn +%= 1;
        wake_waiters = port.shown_waiters != 0;
        // (the display closed, or closed and opened again, meanwhile: the
        // flip was the old opening's)
        if (port.epoch == epoch) {
            port.status.count += 1;
            port.status.process_time = time;
            port.status.tsc = port.vblank.tsc;
            port.status.flip_arg = f.arg;
            port.status.submit_tsc = f.submit_tsc;
            port.status.current_buffer = f.buffer;
            if (f.buffer >= 0) flipLeft(@intCast(f.buffer));
            post(&port.flip_watch, EVENT.FLIP, @bitCast(f.arg), time);
        }
    }
    if (port.epoch == epoch) post(&port.vblank_watch, EVENT.VBLANK, port.vblank.count, time);
    port.beat +%= 1;
    port.lock.unlock();
    pthread.wakeAll(&port.beat);
    if (wake_waiters) pthread.wakeAll(&port.shown_turn);
}

/// One flip of a buffer fewer waits: its label is 0 when none does.
fn flipLeft(buffer: usize) void {
    port.flips_of[buffer] -|= 1;
    if (port.flips_of[buffer] == 0) port.labels[buffer] = 0;
}

fn clockMain(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var next = pthread.nowNs();
    while (true) {
        next += REFRESH_NS;
        const now = pthread.nowNs();
        if (next > now) {
            const nap = abi.Timespec{ .sec = 0, .nsec = @intCast(next - now) };
            _ = sys.call(S.nanosleep, @intFromPtr(&nap), 0, 0, 0, 0, 0);
        } else if (now - next > 6 * REFRESH_NS) {
            // (it fell far behind: the count starts again from now)
            next = now;
        }
        tick();
    }
}

/// With the port's lock held: the waiting flips of a group's buffers (or
/// of every buffer) become flips of no picture. They still happen, and
/// their events with them; the buffers are no longer busy.
fn blankFlipsOf(group: ?i8) void {
    for (0..port.waiting) |i| {
        const f = &port.queue[(port.head + i) % QUEUE];
        if (f.buffer < 0) continue;
        const b: usize = @intCast(f.buffer);
        if (group != null and port.group_of[b] != group.?) continue;
        f.buffer = -1;
    }
    for (&port.flips_of, &port.labels, port.group_of) |*n, *label, g| {
        if (group != null and g != group.?) continue;
        n.* = 0;
        label.* = 0;
    }
}

/// With the port's lock held: gives it back while a flip's picture is
/// being read from a buffer, and returns with it held once none is.
fn untilShown() void {
    while (port.showing) {
        const seen = port.shown_turn;
        port.shown_waiters += 1;
        port.lock.unlock();
        pthread.waitWhile(&port.shown_turn, seen);
        port.lock.lock();
        port.shown_waiters -= 1;
    }
}

// ── A frame to the display ──────────────────────────────────────────────────

const Frame = struct { address: u64, group: Group };

fn frameOf(buffer: usize) ?Frame {
    const g = port.group_of[buffer];
    if (g < 0) return null;
    return .{ .address = port.address[buffer], .group = port.groups[@intCast(g)].? };
}

/// Shows a frame (null: nothing, the screen is left as it is). Only the
/// clock's thread comes here.
fn show(from: ?Frame) void {
    const d = display orelse return;
    const f = from orelse return;
    const w = f.group.width;
    const h = f.group.height;
    if (port.shown[0] != w or port.shown[1] != h) {
        if (port.shown[0] != 0) d.close();
        port.shown = .{ 0, 0 };
        if (!d.open(w, h)) return;
        port.shown = .{ w, h };
    }
    const out = d.frame() orelse return;
    var drawn = false;
    if (source) |from_gpu| drawn = from_gpu(f.address, w, h, out);
    if (!drawn) drawn = convert(f, out);
    if (drawn) d.show();
}

/// A buffer's rows as the display's words. False: nothing here can read it.
fn convert(f: Frame, out: [*]u32) bool {
    const g = f.group;
    if (g.tiled) {
        if (!port.said_tiled) say("a frame in the GPU's tiles, and no GPU path that drew it: not shown");
        port.said_tiled = true;
        return false;
    }
    const w: usize = g.width;
    const pitch: usize = g.pitch;
    switch (g.layout) {
        .bgra8 => {
            const src: [*]const u32 = @ptrFromInt(f.address);
            for (0..g.height) |y| @memcpy(out[y * w ..][0..w], src[y * pitch ..][0..w]);
        },
        .rgba8 => {
            const src: [*]const u32 = @ptrFromInt(f.address);
            for (0..g.height) |y| {
                for (out[y * w ..][0..w], src[y * pitch ..][0..w]) |*o, p| {
                    // (red and blue change places)
                    o.* = p & 0xFF00_FF00 | (p & 0xFF) << 16 | (p >> 16 & 0xFF);
                }
            }
        },
        .bgr10a2, .rgb10a2 => {
            const src: [*]const u32 = @ptrFromInt(f.address);
            const red_low = g.layout == .rgb10a2;
            for (0..g.height) |y| {
                for (out[y * w ..][0..w], src[y * pitch ..][0..w]) |*o, p| {
                    // (each colour's top 8 of its 10 bits)
                    const low = p >> 2 & 0xFF;
                    const mid = p >> 12 & 0xFF;
                    const high = p >> 22 & 0xFF;
                    o.* = 0xFF00_0000 | mid << 8 | if (red_low) low << 16 | high else high << 16 | low;
                }
            }
        },
        .bgra16f, .rgba16f => {
            const src: [*]const [4]u16 = @ptrFromInt(f.address);
            const red: usize = if (g.layout == .rgba16f) 0 else 2;
            for (0..g.height) |y| {
                for (out[y * w ..][0..w], src[y * pitch ..][0..w]) |*o, p| {
                    o.* = 0xFF00_0000 | @as(u32, half8(p[red])) << 16 | @as(u32, half8(p[1])) << 8 | half8(p[2 - red]);
                }
            }
        },
    }
    return true;
}

/// A 16-bit float colour as 8 bits: 0 and below is 0, 1 and above 255.
fn half8(h: u16) u8 {
    const v: f32 = @floatCast(@as(f16, @bitCast(h)));
    if (!(v > 0)) return 0;
    return @intFromFloat(@min(v, 1) * 255 + 0.5);
}

// ── What a game calls ───────────────────────────────────────────────────────

fn sceVideoOutOpen(user: i32, bus: i32, index: i32, param: ?*const anyopaque) callconv(.c) i32 {
    _ = user;
    _ = param;
    if (bus != BUS_MAIN or index != 0) return ERROR.INVALID_VALUE;
    port.lock.lock();
    defer port.lock.unlock();
    if (port.open) return ERROR.RESOURCE_BUSY;
    if (started_ns == 0) started_ns = nowNs();
    port.open = true;
    port.epoch +%= 1;
    port.ps4 = false;
    port.status = .{};
    port.vblank = .{};
    port.head = 0;
    port.waiting = 0;
    port.since_flip = 0;
    port.flip_rate = 0;
    port.showing = false;
    port.labels = [_]u64{0} ** BUFFERS;
    port.flips_of = [_]u32{0} ** BUFFERS;
    // (the clock: one thread for the process's life; a test turns the
    // clock itself)
    if (!port.clock_started and !builtin.is_test) {
        port.clock_started = pthread.spawnService(clockMain, null, "SceVideoOutClock");
        if (!port.clock_started) say("no thread for the display's clock: flips will not happen");
    }
    return HANDLE;
}

fn sceVideoOutClose(handle: i32) callconv(.c) i32 {
    port.lock.lock();
    if (!valid(handle)) {
        port.lock.unlock();
        return ERROR.INVALID_HANDLE;
    }
    // (a buffer whose picture is being read is the game's to free only
    // after this call)
    untilShown();
    blankFlipsOf(null);
    port.open = false;
    port.epoch +%= 1;
    port.group_of = [_]i8{-1} ** BUFFERS;
    port.groups = [_]?Group{null} ** GROUPS;
    port.waiting = 0;
    for (&port.flip_watch) |*w| {
        if (w.used) _ = equeue.remove(w.queue, equeue.FILTER.VIDEO_OUT, EVENT.FLIP);
        w.* = .{};
    }
    for (&port.vblank_watch) |*w| {
        if (w.used) _ = equeue.remove(w.queue, equeue.FILTER.VIDEO_OUT, EVENT.VBLANK);
        w.* = .{};
    }
    // (a thread waiting for the next refresh is told there will be none)
    port.beat +%= 1;
    port.lock.unlock();
    pthread.wakeAll(&port.beat);
    return 0;
}

fn sceVideoOutSetBufferAttribute(attr: ?*Attribute, format: u32, tiling: u32, aspect: u32, width: u32, height: u32, pitch: u32) callconv(.c) void {
    const a = attr orelse return;
    a.* = .{ .pixel_format = format, .tiling_mode = tiling, .aspect_ratio = aspect, .width = width, .height = height, .pitch_in_pixel = pitch };
}

fn sceVideoOutSetBufferAttribute2(attr: ?*Attribute2, format: u64, tiling: u32, width: u32, height: u32, option: u64, dcc_control: u32, dcc_clear_color: u64) callconv(.c) void {
    const a = attr orelse return;
    a.* = .{ .pixel_format = format, .tiling_mode = tiling, .width = width, .height = height, .option = option, .dcc_control = dcc_control, .dcc_clear_color = dcc_clear_color };
}

const Made = union(enum) { ok: Group, err: i32 };

/// What both ways of registering check alike, and the group they make.
fn groupFrom(layout: ?Layout, tiling: u32, width: u32, height: u32, pitch: u32) Made {
    const l = layout orelse return .{ .err = ERROR.INVALID_PIXEL_FORMAT };
    if (tiling > TILING.LINEAR) return .{ .err = ERROR.INVALID_TILING_MODE };
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return .{ .err = ERROR.INVALID_RESOLUTION };
    if (pitch != 0 and pitch < width) return .{ .err = ERROR.INVALID_PITCH };
    return .{ .ok = .{ .layout = l, .tiled = tiling == TILING.TILE, .width = width, .height = height, .pitch = if (pitch == 0) width else pitch } };
}

/// The PS4's call: says that `count` of the game's buffers, from index
/// `first`, hold frames laid out as `attr` says. The group's number (the
/// first free one), or an error.
fn sceVideoOutRegisterBuffers(handle: i32, first: i32, addresses: ?[*]const u64, count: i32, attr: ?*const Attribute) callconv(.c) i32 {
    const addrs = addresses orelse return ERROR.INVALID_ADDRESS;
    const a = attr orelse return ERROR.INVALID_ADDRESS;
    if (first < 0 or first >= BUFFERS or count < 1 or count > BUFFERS or first + count > BUFFERS) return ERROR.INVALID_VALUE;
    const g = switch (groupFrom(FORMAT.layout(a.pixel_format), a.tiling_mode, a.width, a.height, a.pitch_in_pixel)) {
        .ok => |made| made,
        .err => |e| return e,
    };
    const from: usize = @intCast(first);
    const n: usize = @intCast(count);
    for (addrs[0..n]) |addr| {
        if (addr == 0) return ERROR.INVALID_ADDRESS;
    }
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    for (port.group_of[from..][0..n]) |used| {
        if (used >= 0) return ERROR.SLOT_OCCUPIED;
    }
    const group = for (&port.groups, 0..) |*slot, i| {
        if (slot.* == null) break i;
    } else return ERROR.NO_EMPTY_SLOT;
    port.groups[group] = g;
    port.ps4 = true;
    for (addrs[0..n], from..) |addr, i| take(i, addr, group);
    return @intCast(group);
}

/// The PS5's call: the game names the group itself. 0, or an error.
fn sceVideoOutRegisterBuffers2(handle: i32, group: i32, first: i32, buffers: ?[*]const Buffer2, count: i32, attr: ?*const Attribute2, category: i32, option: ?*const anyopaque) callconv(.c) i32 {
    _ = category;
    const bufs = buffers orelse return ERROR.INVALID_ADDRESS;
    const a = attr orelse return ERROR.INVALID_OPTION;
    if (option != null) return ERROR.INVALID_OPTION;
    if (group < 0 or group >= GROUPS or first < 0 or first >= BUFFERS or count < 1 or count > BUFFERS or first + count > BUFFERS) return ERROR.INVALID_VALUE;
    const g = switch (groupFrom(FORMAT5.layout(a.pixel_format), a.tiling_mode, a.width, a.height, a.pitch_in_pixel)) {
        .ok => |made| made,
        .err => |e| return e,
    };
    const from: usize = @intCast(first);
    const n: usize = @intCast(count);
    for (bufs[0..n]) |b| {
        if (b.data == 0) return ERROR.INVALID_ADDRESS;
    }
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    for (port.group_of[from..][0..n]) |used| {
        if (used >= 0) return ERROR.SLOT_OCCUPIED;
    }
    const slot: usize = @intCast(group);
    if (port.groups[slot] != null) return ERROR.INVALID_INDEX;
    port.groups[slot] = g;
    port.ps4 = false;
    for (bufs[0..n], from..) |b, i| take(i, b.data, slot);
    return 0;
}

fn take(buffer: usize, address: u64, group: usize) void {
    port.address[buffer] = address;
    port.group_of[buffer] = @intCast(group);
    port.labels[buffer] = 0;
    port.flips_of[buffer] = 0;
}

/// Forgets a group of buffers. Flips of them still waiting show nothing.
/// When it returns, nothing here reads their memory any more.
fn sceVideoOutUnregisterBuffers(handle: i32, group: i32) callconv(.c) i32 {
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    if (group < 0 or group >= GROUPS or port.groups[@intCast(group)] == null) return ERROR.INVALID_VALUE;
    untilShown();
    if (!port.open) return ERROR.INVALID_HANDLE;
    blankFlipsOf(@intCast(group));
    port.groups[@intCast(group)] = null;
    for (&port.group_of) |*g| {
        if (g.* == group) g.* = -1;
    }
    return 0;
}

fn sceVideoOutSetFlipRate(handle: i32, rate: i32) callconv(.c) i32 {
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    if (rate < 0 or rate > 2) return ERROR.INVALID_VALUE;
    port.flip_rate = @intCast(rate);
    return 0;
}

/// Asks for a buffer to be shown at a coming refresh (-1: no picture, the
/// flip still happens). `arg` comes back in the flip's event and status.
fn sceVideoOutSubmitFlip(handle: i32, buffer: i32, mode: i32, arg: i64) callconv(.c) i32 {
    // What can be refused is refused now; then the GPU path may take the
    // flip behind its own work.
    port.lock.lock();
    const refused = refusal(handle, buffer, mode);
    const full = pendingNow() >= QUEUE;
    port.lock.unlock();
    if (refused != 0) return refused;
    if (full) return ERROR.FLIP_QUEUE_FULL;
    if (flip_router) |route| {
        if (route(handle, buffer, mode, arg)) |r| return r;
    }
    return submit(handle, buffer, mode, arg);
}

/// With the port's lock held: why a flip cannot be, or 0.
fn refusal(handle: i32, buffer: i32, mode: i32) i32 {
    if (mode < 1 or mode > 6) return ERROR.INVALID_FLIP_MODE;
    // (-2: black, -1: blank; neither shows a buffer)
    if (buffer < -2 or buffer >= BUFFERS) return ERROR.INVALID_INDEX;
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    if (buffer >= 0 and port.group_of[@intCast(buffer)] < 0) return ERROR.INVALID_INDEX;
    return 0;
}

/// A flip into the queue, for the libraries here that flip on a game's
/// behalf (the GPU path, when its queue comes to a flip).
pub fn submit(handle: i32, buffer: i32, mode: i32, arg: i64) i32 {
    return submitAs(handle, buffer, mode, arg, false);
}

/// The same for a flip that was promised (`reserve`): the promise is kept
/// or dropped here, whatever the answer.
pub fn submitReserved(handle: i32, buffer: i32, mode: i32, arg: i64) i32 {
    return submitAs(handle, buffer, mode, arg, true);
}

fn submitAs(handle: i32, buffer: i32, mode: i32, arg: i64, promised: bool) i32 {
    port.lock.lock();
    defer port.lock.unlock();
    // (a promise still counts while there is no room, so that the caller
    // may wait for a refresh and ask again)
    if (port.waiting == QUEUE and refusal(handle, buffer, mode) == 0) return ERROR.FLIP_QUEUE_FULL;
    if (promised) port.reserved -|= 1;
    const refused = refusal(handle, buffer, mode);
    if (refused != 0) return refused;
    port.queue[(port.head + port.waiting) % QUEUE] = .{ .buffer = buffer, .arg = arg, .submit_tsc = sys.rdtsc() };
    port.waiting += 1;
    if (buffer >= 0) {
        port.flips_of[@intCast(buffer)] += 1;
        port.labels[@intCast(buffer)] = 1;
    }
    return 0;
}

/// Writes the flip status as the game's console lays it out: 128 bytes
/// for a PS5 game, 64 for one that registered its buffers the PS4's way.
fn sceVideoOutGetFlipStatus(handle: i32, out: ?*anyopaque) callconv(.c) i32 {
    const o = out orelse return ERROR.INVALID_ADDRESS;
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    const pending = pendingNow();
    const s = port.status;
    if (port.ps4) {
        var four = s;
        four.flip_pending_num = pending;
        @as(*align(1) FlipStatus, @ptrCast(o)).* = four;
    } else {
        @as(*align(1) FlipStatus5, @ptrCast(o)).* = .{
            .count = s.count,
            .process_time = s.process_time,
            .flip_arg = s.flip_arg,
            .process_time_counter = s.tsc,
            .flip_pending_num = pending,
            .current_buffer = s.current_buffer,
            .submit_process_time_counter = s.submit_tsc,
        };
    }
    return 0;
}

fn sceVideoOutIsFlipPending(handle: i32) callconv(.c) i32 {
    return pendingFlips(handle);
}

/// Flips asked for and not yet shown, or an error.
pub fn pendingFlips(handle: i32) i32 {
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    return pendingNow();
}

/// Writes the vblank status: 40 bytes for a PS5 game. For one that
/// registered its buffers the PS4's way, the 32 bytes every account of
/// the PS4's structure agrees on (count, time, counter, a word of 0).
fn sceVideoOutGetVblankStatus(handle: i32, out: ?*anyopaque) callconv(.c) i32 {
    const o = out orelse return ERROR.INVALID_ADDRESS;
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    if (port.ps4) {
        @as(*align(1) [4]u64, @ptrCast(o)).* = .{ port.vblank.count, port.vblank.process_time, port.vblank.tsc, 0 };
    } else {
        @as(*align(1) VblankStatus, @ptrCast(o)).* = port.vblank;
    }
    return 0;
}

fn sceVideoOutWaitVblank(handle: i32) callconv(.c) i32 {
    return waitVblank(handle);
}

/// Sleeps until the screen's next refresh. An error when the display is
/// not open, or is closed meanwhile.
pub fn waitVblank(handle: i32) i32 {
    port.lock.lock();
    const ok = valid(handle);
    const beat = port.beat;
    const clock = port.clock_started;
    port.lock.unlock();
    if (!ok) return ERROR.INVALID_HANDLE;
    if (!clock) {
        // (no clock thread: a refresh's length of sleep stands for it)
        if (!builtin.is_test) {
            const nap = abi.Timespec{ .sec = 0, .nsec = REFRESH_NS };
            _ = sys.call(S.nanosleep, @intFromPtr(&nap), 0, 0, 0, 0, 0);
        }
        return 0;
    }
    while (@atomicLoad(u32, &port.beat, .acquire) == beat) pthread.waitWhile(&port.beat, beat);
    // (the beat also moves when the display is closed)
    port.lock.lock();
    defer port.lock.unlock();
    return if (valid(handle)) 0 else ERROR.INVALID_HANDLE;
}

/// Returns once no flip of a display buffer waits to be shown: the buffer
/// may then be drawn to without the picture changing under the screen.
pub fn waitSafe(handle: i32, buffer: i32) void {
    if (buffer < 0 or buffer >= BUFFERS) return;
    while (true) {
        port.lock.lock();
        const busy = valid(handle) and port.flips_of[@intCast(buffer)] != 0;
        port.lock.unlock();
        if (!busy or builtin.is_test) return;
        if (waitVblank(handle) != 0) return;
    }
}

fn sceVideoOutGetResolutionStatus(handle: i32, out: ?*ResolutionStatus) callconv(.c) i32 {
    const o = out orelse return ERROR.INVALID_ADDRESS;
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    o.* = .{
        .full_width = @intCast(screen[0]),
        .full_height = @intCast(screen[1]),
        .pane_width = @intCast(screen[0]),
        .pane_height = @intCast(screen[1]),
    };
    return 0;
}

/// Where the 16 buffers' labels are (a word each: not 0 while a flip of
/// the buffer waits to be shown). How many there are.
fn sceVideoOutGetBufferLabelAddress(handle: i32, out: ?*u64) callconv(.c) i32 {
    const o = out orelse return ERROR.INVALID_ADDRESS;
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    o.* = @intFromPtr(&port.labels);
    return BUFFERS;
}

fn watch(list: *[8]Watcher, queue: usize, ident: u64, udata: u64) i32 {
    // (read once, an event's count starts again)
    if (equeue.add(queue, equeue.FILTER.VIDEO_OUT, ident, udata, .{ .clear = true }) != 0) return ERROR.INVALID_EVENT_QUEUE;
    for (list) |w| {
        if (w.used and w.queue == queue) return 0;
    }
    for (list) |*w| {
        if (!w.used) {
            w.* = .{ .queue = queue, .used = true };
            return 0;
        }
    }
    _ = equeue.remove(queue, equeue.FILTER.VIDEO_OUT, ident);
    return ERROR.NO_EMPTY_SLOT;
}

/// False: the queue was not listening for that.
fn unwatch(list: *[8]Watcher, queue: usize, ident: u64) bool {
    for (list) |*w| {
        if (w.used and w.queue == queue) {
            w.* = .{};
            _ = equeue.remove(queue, equeue.FILTER.VIDEO_OUT, ident);
            return true;
        }
    }
    return false;
}

fn sceVideoOutAddFlipEvent(queue: usize, handle: i32, udata: u64) callconv(.c) i32 {
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    return watch(&port.flip_watch, queue, EVENT.FLIP, udata);
}

fn sceVideoOutAddVblankEvent(queue: usize, handle: i32, udata: u64) callconv(.c) i32 {
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    return watch(&port.vblank_watch, queue, EVENT.VBLANK, udata);
}

fn sceVideoOutDeleteFlipEvent(queue: usize, handle: i32) callconv(.c) i32 {
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    return if (unwatch(&port.flip_watch, queue, EVENT.FLIP)) 0 else ERROR.INVALID_EVENT;
}

fn sceVideoOutDeleteVblankEvent(queue: usize, handle: i32) callconv(.c) i32 {
    port.lock.lock();
    defer port.lock.unlock();
    if (!valid(handle)) return ERROR.INVALID_HANDLE;
    // (a vblank event that was never there is deleted without complaint)
    _ = unwatch(&port.vblank_watch, queue, EVENT.VBLANK);
    return 0;
}

/// What an event from this library is of: a flip (0) or a vblank (1).
fn sceVideoOutGetEventId(ev: ?*const equeue.Event) callconv(.c) i32 {
    const e = ev orelse return ERROR.INVALID_ADDRESS;
    if (e.filter != equeue.FILTER.VIDEO_OUT) return ERROR.INVALID_EVENT;
    return switch (e.ident) {
        EVENT.FLIP => EVENT.ID_FLIP,
        EVENT.VBLANK => EVENT.ID_VBLANK,
        else => ERROR.INVALID_EVENT,
    };
}

/// An event's own 48 bits: a flip's argument (with its sign), a vblank's
/// number.
fn sceVideoOutGetEventData(ev: ?*const equeue.Event, out: ?*i64) callconv(.c) i32 {
    const e = ev orelse return ERROR.INVALID_ADDRESS;
    const o = out orelse return ERROR.INVALID_ADDRESS;
    if (e.filter != equeue.FILTER.VIDEO_OUT) return ERROR.INVALID_EVENT;
    o.* = if (e.ident == EVENT.FLIP) e.data >> 16 else @bitCast(@as(u64, @bitCast(e.data)) >> 16);
    return 0;
}

/// How many times the event happened since it was last read (15 at most).
fn sceVideoOutGetEventCount(ev: ?*const equeue.Event) callconv(.c) i32 {
    const e = ev orelse return ERROR.INVALID_ADDRESS;
    if (e.filter != equeue.FILTER.VIDEO_OUT) return ERROR.INVALID_EVENT;
    return @intCast(@as(u64, @bitCast(e.data)) >> 12 & 0xF);
}

/// The picture's margins in a window, its colours' gamma, what the screen
/// can do: accepted, and nothing here changes with them (no HDR is told).
fn sceVideoOutSetWindowModeMargins(handle: i32, top: i32, bottom: i32) callconv(.c) i32 {
    _ = top;
    _ = bottom;
    return if (handle == HANDLE) 0 else ERROR.INVALID_HANDLE;
}

fn sceVideoOutColorSettingsSetGamma(settings: ?*ColorSettings, gamma: f32) callconv(.c) i32 {
    const s = settings orelse return ERROR.INVALID_ADDRESS;
    if (!(gamma >= 0.1 and gamma <= 2.0)) return ERROR.INVALID_VALUE;
    s.gamma = gamma;
    return 0;
}

fn sceVideoOutAdjustColor(handle: i32, settings: ?*const ColorSettings) callconv(.c) i32 {
    if (settings == null) return ERROR.INVALID_ADDRESS;
    return if (handle == HANDLE) 0 else ERROR.INVALID_HANDLE;
}

fn sceVideoOutGetDeviceCapabilityInfo(handle: i32, out: ?*u64, size: u64) callconv(.c) i32 {
    const o = out orelse return ERROR.INVALID_ADDRESS;
    if (handle != HANDLE) return ERROR.INVALID_HANDLE;
    if (size != 8) return ERROR.INVALID_VALUE;
    // (what open projects answer; which capability the bit names is not known)
    o.* = 1;
    return 0;
}

// ── The table ───────────────────────────────────────────────────────────────

fn entry(comptime name: []const u8, comptime f: anytype) struct { []const u8, *const anyopaque } {
    return .{ name, @ptrCast(f) };
}

/// Every name this library answers, by NID.
pub const exports = nid.Table(*const anyopaque, &[_]struct { []const u8, *const anyopaque }{
    entry("sceVideoOutOpen", &sceVideoOutOpen),
    entry("sceVideoOutClose", &sceVideoOutClose),
    entry("sceVideoOutSetBufferAttribute", &sceVideoOutSetBufferAttribute),
    entry("sceVideoOutSetBufferAttribute2", &sceVideoOutSetBufferAttribute2),
    entry("sceVideoOutRegisterBuffers", &sceVideoOutRegisterBuffers),
    entry("sceVideoOutRegisterBuffers2", &sceVideoOutRegisterBuffers2),
    entry("sceVideoOutUnregisterBuffers", &sceVideoOutUnregisterBuffers),
    entry("sceVideoOutSetFlipRate", &sceVideoOutSetFlipRate),
    entry("sceVideoOutSubmitFlip", &sceVideoOutSubmitFlip),
    entry("sceVideoOutGetFlipStatus", &sceVideoOutGetFlipStatus),
    entry("sceVideoOutIsFlipPending", &sceVideoOutIsFlipPending),
    entry("sceVideoOutGetVblankStatus", &sceVideoOutGetVblankStatus),
    entry("sceVideoOutWaitVblank", &sceVideoOutWaitVblank),
    entry("sceVideoOutGetResolutionStatus", &sceVideoOutGetResolutionStatus),
    entry("sceVideoOutGetBufferLabelAddress", &sceVideoOutGetBufferLabelAddress),
    entry("sceVideoOutAddFlipEvent", &sceVideoOutAddFlipEvent),
    entry("sceVideoOutAddVblankEvent", &sceVideoOutAddVblankEvent),
    entry("sceVideoOutDeleteFlipEvent", &sceVideoOutDeleteFlipEvent),
    entry("sceVideoOutDeleteVblankEvent", &sceVideoOutDeleteVblankEvent),
    entry("sceVideoOutGetEventId", &sceVideoOutGetEventId),
    entry("sceVideoOutGetEventData", &sceVideoOutGetEventData),
    entry("sceVideoOutGetEventCount", &sceVideoOutGetEventCount),
    entry("sceVideoOutSetWindowModeMargins", &sceVideoOutSetWindowModeMargins),
    entry("sceVideoOutColorSettingsSetGamma_", &sceVideoOutColorSettingsSetGamma),
    entry("sceVideoOutAdjustColor_", &sceVideoOutAdjustColor),
    entry("sceVideoOutGetDeviceCapabilityInfo_", &sceVideoOutGetDeviceCapabilityInfo),
});

/// The address of one of this library's functions, by the library a game
/// named and its NID; null when this is not the library or it has no such
/// function.
pub fn find(library: []const u8, n: nid.Nid) ?u64 {
    if (!std.mem.eql(u8, library, "libSceVideoOut")) return null;
    const p = exports.find(n) orelse return null;
    return @intFromPtr(p);
}

// ── For the tests of the libraries that flip ────────────────────────────────

/// The display opened, and rows of 32-bit pixels registered as one of its
/// buffers, as a test of another library here needs them.
pub fn testOpen() i32 {
    return sceVideoOutOpen(0, BUS_MAIN, 0, null);
}
pub fn testClose(handle: i32) void {
    _ = sceVideoOutClose(handle);
}
pub fn testRegister(handle: i32, buffer: i32, pixels: [*]const u32, width: u32, height: u32) i32 {
    var attr: Attribute = undefined;
    sceVideoOutSetBufferAttribute(&attr, FORMAT.A8R8G8B8_SRGB, TILING.LINEAR, 0, width, height, width);
    const addr = [_]u64{@intFromPtr(pixels)};
    const r = sceVideoOutRegisterBuffers(handle, buffer, &addr, 1, &attr);
    return if (r < 0) r else 0;
}
/// A flip as the game's own code asks for one.
pub fn testFlip(handle: i32, buffer: i32, arg: i64) i32 {
    return sceVideoOutSubmitFlip(handle, buffer, 1, arg);
}
/// The argument of the flip shown last (-1: none yet).
pub fn lastFlipArg(handle: i32) i64 {
    port.lock.lock();
    defer port.lock.unlock();
    return if (valid(handle)) port.status.flip_arg else -1;
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// With no kernel under them: the clock is turned by hand (`tick`), the
// display is the test's own memory, and events are read with a wait that
// only looks.

const Testing = struct {
    var opened: [2]u32 = .{ 0, 0 };
    var opens: u32 = 0;
    var shows: u32 = 0;
    var pixels: [64]u32 = undefined;

    fn open(w: u32, h: u32) bool {
        if (w * h > pixels.len) return false;
        opened = .{ w, h };
        opens += 1;
        return true;
    }
    fn frame() ?[*]u32 {
        return &pixels;
    }
    fn showIt() void {
        shows += 1;
    }
    fn close() void {
        opened = .{ 0, 0 };
    }
    const it = Display{ .open = open, .frame = frame, .show = showIt, .close = close };

    fn reset() void {
        opens = 0;
        shows = 0;
        @memset(&pixels, 0);
        display = it;
        source = null;
        port.shown = .{ 0, 0 };
        started_ns = 1;
    }

    var queue_storage: [10]equeue.TestQueue = undefined;
    var routed: i32 = -9;
};

test "the structures are the SDK's sizes" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Attribute));
    try std.testing.expectEqual(@as(usize, 0x50), @sizeOf(Attribute2));
    try std.testing.expectEqual(@as(usize, 0x20), @offsetOf(Attribute2, "pixel_format"));
    try std.testing.expectEqual(@as(usize, 0x30), @offsetOf(Attribute2, "dcc_control"));
    try std.testing.expectEqual(@as(usize, 0x20), @sizeOf(Buffer2));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(FlipStatus));
    try std.testing.expectEqual(@as(usize, 0x80), @sizeOf(FlipStatus5));
    try std.testing.expectEqual(@as(usize, 0x18), @offsetOf(FlipStatus5, "flip_arg"));
    try std.testing.expectEqual(@as(usize, 0x34), @offsetOf(FlipStatus5, "flip_pending_num"));
    try std.testing.expectEqual(@as(usize, 0x38), @offsetOf(FlipStatus5, "current_buffer"));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(VblankStatus));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(ResolutionStatus));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ResolutionStatus, "refresh_rate"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(FlipStatus, "flip_arg"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(FlipStatus, "current_buffer"));
}

test "an event's data: the argument's 48 bits with their sign, a count that stops at 15" {
    var data: i64 = 0;
    for (0..20) |_| data = eventData(data, eventArg(@bitCast(@as(i64, -2)), 0x123));
    const ev = equeue.Event{ .ident = EVENT.FLIP, .filter = equeue.FILTER.VIDEO_OUT, .data = data };
    var arg: i64 = 0;
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutGetEventData(&ev, &arg));
    try std.testing.expectEqual(@as(i64, -2), arg);
    try std.testing.expectEqual(@as(i32, 15), sceVideoOutGetEventCount(&ev));
    try std.testing.expectEqual(EVENT.ID_FLIP, sceVideoOutGetEventId(&ev));
    try std.testing.expectEqual(@as(u64, 0x123), @as(u64, @bitCast(data)) & 0xFFF);
    // A vblank's number is not a signed thing.
    const vb = equeue.Event{ .ident = EVENT.VBLANK, .filter = equeue.FILTER.VIDEO_OUT, .data = eventData(0, eventArg(0x8000_0000_0001, 0)) };
    _ = sceVideoOutGetEventData(&vb, &arg);
    try std.testing.expectEqual(@as(i64, 0x8000_0000_0001), arg);
    // An event that is not this library's.
    const other = equeue.Event{ .ident = 1, .filter = equeue.FILTER.USER };
    try std.testing.expectEqual(ERROR.INVALID_EVENT, sceVideoOutGetEventId(&other));
    const unknown = equeue.Event{ .ident = 9, .filter = equeue.FILTER.VIDEO_OUT };
    try std.testing.expectEqual(ERROR.INVALID_EVENT, sceVideoOutGetEventId(&unknown));
}

test "flips: queued, shown one a refresh at the rate set, told by events and status" {
    Testing.reset();
    const q = equeue.testQueue(&Testing.queue_storage[0], "flips");
    defer equeue.testDelete(q);
    var ev: [4]equeue.Event = undefined;

    try std.testing.expectEqual(ERROR.INVALID_VALUE, sceVideoOutOpen(0, 5, 0, null));
    try std.testing.expectEqual(ERROR.INVALID_HANDLE, sceVideoOutSubmitFlip(HANDLE, -1, 1, 0));
    const h = sceVideoOutOpen(0, BUS_MAIN, 0, null);
    try std.testing.expectEqual(HANDLE, h);
    defer _ = sceVideoOutClose(h);
    try std.testing.expectEqual(ERROR.RESOURCE_BUSY, sceVideoOutOpen(0, BUS_MAIN, 0, null));

    // Two buffers of 4 x 2 in rows, 8 pixels to a row of memory.
    var a = [_]u32{0xFF11_2233} ** 16;
    var b = [_]u32{0xFF44_5566} ** 16;
    var attr: Attribute = undefined;
    sceVideoOutSetBufferAttribute(&attr, FORMAT.A8R8G8B8_SRGB, TILING.LINEAR, 0, 4, 2, 8);
    const addrs = [_]u64{ @intFromPtr(&a), @intFromPtr(&b) };
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutRegisterBuffers(h, 0, &addrs, 2, &attr));
    try std.testing.expectEqual(ERROR.SLOT_OCCUPIED, sceVideoOutRegisterBuffers(h, 1, &addrs, 1, &attr));
    try std.testing.expectEqual(ERROR.INVALID_VALUE, sceVideoOutRegisterBuffers(h, 15, &addrs, 2, &attr));
    try std.testing.expectEqual(ERROR.INVALID_INDEX, sceVideoOutSubmitFlip(h, 2, 1, 0));
    try std.testing.expectEqual(ERROR.INVALID_FLIP_MODE, sceVideoOutSubmitFlip(h, 0, 0, 0));

    try std.testing.expectEqual(@as(i32, 0), sceVideoOutAddFlipEvent(q, h, 0xF1));
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutAddVblankEvent(q, h, 0xB1));
    try std.testing.expectEqual(ERROR.INVALID_EVENT_QUEUE, sceVideoOutAddFlipEvent(0x1234, h, 0));

    // A refresh with no flip waiting: a vblank alone, with its number.
    tick();
    try std.testing.expectEqual(@as(i64, 1), equeue.wait(q, &ev, 0));
    try std.testing.expectEqual(EVENT.ID_VBLANK, sceVideoOutGetEventId(&ev[0]));
    try std.testing.expectEqual(@as(u64, 0xB1), ev[0].udata);
    var number: i64 = 0;
    _ = sceVideoOutGetEventData(&ev[0], &number);
    try std.testing.expectEqual(@as(i64, 1), number);
    try std.testing.expectEqual(@as(u32, 0), Testing.shows);

    // Two flips asked for: one is shown at each refresh, oldest first.
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutSubmitFlip(h, 0, 1, 100));
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutSubmitFlip(h, 1, 1, 200));
    try std.testing.expectEqual(@as(i32, 2), sceVideoOutIsFlipPending(h));
    var labels_at: u64 = 0;
    try std.testing.expectEqual(@as(i32, BUFFERS), sceVideoOutGetBufferLabelAddress(h, &labels_at));
    const labels: *const [BUFFERS]u64 = @ptrFromInt(labels_at);
    try std.testing.expectEqual(@as(u64, 1), labels[1]);
    tick();
    try std.testing.expectEqual(@as(u32, 1), Testing.shows);
    try std.testing.expectEqual([2]u32{ 4, 2 }, Testing.opened);
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), Testing.pixels[7]);
    // The status, as a PS4 game reads it (the buffers were registered the
    // PS4's way): 64 bytes, and nothing after them touched.
    var st: [2]FlipStatus = .{ .{}, .{ .count = 0xAAAA } };
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutGetFlipStatus(h, &st[0]));
    try std.testing.expectEqual(@as(u64, 1), st[0].count);
    try std.testing.expectEqual(@as(i64, 100), st[0].flip_arg);
    try std.testing.expectEqual(@as(i32, 0), st[0].current_buffer);
    try std.testing.expectEqual(@as(i32, 1), st[0].flip_pending_num);
    try std.testing.expectEqual(@as(u64, 0xAAAA), st[1].count);
    tick();
    try std.testing.expectEqual(@as(u32, 0xFF44_5566), Testing.pixels[0]);
    try std.testing.expectEqual(@as(u64, 0), labels[1]);
    // The display was opened once: the size did not change.
    try std.testing.expectEqual(@as(u32, 1), Testing.opens);

    // The queue has a flip event (it happened twice since it was read, and
    // carries the last flip's argument) and a vblank event.
    try std.testing.expectEqual(@as(i64, 2), equeue.wait(q, &ev, 0));
    const flip = if (sceVideoOutGetEventId(&ev[0]) == EVENT.ID_FLIP) ev[0] else ev[1];
    var arg: i64 = 0;
    _ = sceVideoOutGetEventData(&flip, &arg);
    try std.testing.expectEqual(@as(i64, 200), arg);
    try std.testing.expectEqual(@as(i32, 2), sceVideoOutGetEventCount(&flip));
    try std.testing.expectEqual(@as(u64, 0xF1), flip.udata);

    // A buffer asked for twice is busy until both flips of it are shown.
    _ = sceVideoOutSubmitFlip(h, 0, 1, 0);
    _ = sceVideoOutSubmitFlip(h, 0, 1, 0);
    tick();
    try std.testing.expectEqual(@as(u64, 1), labels[0]);
    tick();
    try std.testing.expectEqual(@as(u64, 0), labels[0]);

    // A frame every other refresh.
    try std.testing.expectEqual(ERROR.INVALID_VALUE, sceVideoOutSetFlipRate(h, 3));
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutSetFlipRate(h, 1));
    for (0..3) |i| try std.testing.expectEqual(@as(i32, 0), sceVideoOutSubmitFlip(h, 0, 1, @intCast(i)));
    const before = Testing.shows;
    for (0..4) |_| tick();
    try std.testing.expectEqual(before + 2, Testing.shows);

    // The queue of flips has an end.
    _ = sceVideoOutSetFlipRate(h, 0);
    while (sceVideoOutIsFlipPending(h) != 0) tick();
    for (0..QUEUE) |_| try std.testing.expectEqual(@as(i32, 0), sceVideoOutSubmitFlip(h, -1, 1, 0));
    try std.testing.expectEqual(ERROR.FLIP_QUEUE_FULL, sceVideoOutSubmitFlip(h, -1, 1, 0));
    // (a flip of no buffer happens, and shows nothing)
    const shown = Testing.shows;
    for (0..QUEUE) |_| tick();
    try std.testing.expectEqual(shown, Testing.shows);
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutIsFlipPending(h));

    // Events deleted: none arrive.
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutDeleteFlipEvent(q, h));
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutDeleteVblankEvent(q, h));
    // (a flip event that is not there is an error; a vblank one is not)
    try std.testing.expectEqual(ERROR.INVALID_EVENT, sceVideoOutDeleteFlipEvent(q, h));
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutDeleteVblankEvent(q, h));
    _ = equeue.wait(q, &ev, 0);
    tick();
    try std.testing.expectEqual(-@as(i64, abi.E.TIMEDOUT), equeue.wait(q, &ev, 0));
}

test "a queue the game deleted gives its place among the listeners back" {
    Testing.reset();
    const h = sceVideoOutOpen(0, BUS_MAIN, 0, null);
    defer _ = sceVideoOutClose(h);
    // More queues, one after another, than there are places: each is
    // deleted without the display being told, and found gone at the next
    // refresh.
    for (0..20) |round| {
        const q = equeue.testQueue(&Testing.queue_storage[round % 10], "round");
        try std.testing.expectEqual(@as(i32, 0), sceVideoOutAddVblankEvent(q, h, 0));
        try std.testing.expectEqual(@as(i32, 0), sceVideoOutAddFlipEvent(q, h, 0));
        equeue.testDelete(q);
        _ = sceVideoOutSubmitFlip(h, -1, 1, 0);
        tick();
    }
    // All eight places at once are still to be had.
    for (0..8) |i| {
        const q = equeue.testQueue(&Testing.queue_storage[i], "eight");
        try std.testing.expectEqual(@as(i32, 0), sceVideoOutAddVblankEvent(q, h, 0));
    }
    const ninth = equeue.testQueue(&Testing.queue_storage[8], "ninth");
    try std.testing.expectEqual(ERROR.NO_EMPTY_SLOT, sceVideoOutAddVblankEvent(ninth, h, 0));
    equeue.testDelete(ninth);
    _ = sceVideoOutClose(h);
    for (0..8) |i| equeue.testDelete(@intFromPtr(&Testing.queue_storage[i]));
}

fn fromGpu(address: u64, w: u32, h: u32, out: [*]u32) bool {
    if (address != 0x7000) return false;
    @memset(out[0 .. w * h], 0xFFAB_CDEF);
    return true;
}

test "frames: each pixel format as the display's words; a tiled one only from the GPU path" {
    Testing.reset();
    const h = sceVideoOutOpen(0, BUS_MAIN, 0, null);
    defer _ = sceVideoOutClose(h);
    var attr: Attribute = undefined;

    // Red and blue the other way round.
    var abgr = [_]u32{0x8011_2233} ** 4;
    sceVideoOutSetBufferAttribute(&attr, FORMAT.A8B8G8R8_SRGB, TILING.LINEAR, 0, 2, 2, 2);
    var addr = [_]u64{@intFromPtr(&abgr)};
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutRegisterBuffers(h, 0, &addr, 1, &attr));
    // Ten bits a colour: red 0x3FF, green 0x200, blue 0.
    var ten = [_]u32{@as(u32, 0x3FF) << 20 | @as(u32, 0x200) << 10} ** 4;
    sceVideoOutSetBufferAttribute(&attr, FORMAT.A2R10G10B10, TILING.LINEAR, 0, 2, 2, 2);
    addr[0] = @intFromPtr(&ten);
    try std.testing.expectEqual(@as(i32, 1), sceVideoOutRegisterBuffers(h, 1, &addr, 1, &attr));
    // Sixteen-bit floats: 1.0, 0.5, more than 1, and a negative alpha.
    const one: u16 = @bitCast(@as(f16, 1.0));
    const half: u16 = @bitCast(@as(f16, 0.5));
    const four: u16 = @bitCast(@as(f16, 4.0));
    var floats = [_][4]u16{.{ one, half, four, @bitCast(@as(f16, -1.0)) }} ** 4;
    sceVideoOutSetBufferAttribute(&attr, FORMAT.A16R16G16B16_FLOAT, TILING.LINEAR, 0, 2, 2, 2);
    addr[0] = @intFromPtr(&floats);
    try std.testing.expectEqual(@as(i32, 2), sceVideoOutRegisterBuffers(h, 2, &addr, 1, &attr));
    // In the GPU's tiles, at an address only the GPU path knows.
    sceVideoOutSetBufferAttribute(&attr, FORMAT.A8R8G8B8_SRGB, TILING.TILE, 0, 2, 2, 2);
    addr[0] = 0x7000;
    try std.testing.expectEqual(@as(i32, 3), sceVideoOutRegisterBuffers(h, 3, &addr, 1, &attr));
    try std.testing.expectEqual(ERROR.NO_EMPTY_SLOT, sceVideoOutRegisterBuffers(h, 4, &addr, 1, &attr));
    // What is not a format, a size or a pitch.
    sceVideoOutSetBufferAttribute(&attr, 0x1234, TILING.LINEAR, 0, 2, 2, 2);
    try std.testing.expectEqual(ERROR.INVALID_PIXEL_FORMAT, sceVideoOutRegisterBuffers(h, 4, &addr, 1, &attr));
    sceVideoOutSetBufferAttribute(&attr, FORMAT.A8R8G8B8_SRGB, TILING.LINEAR, 0, 4, 2, 2);
    try std.testing.expectEqual(ERROR.INVALID_PITCH, sceVideoOutRegisterBuffers(h, 4, &addr, 1, &attr));
    sceVideoOutSetBufferAttribute(&attr, FORMAT.A8R8G8B8_SRGB, 2, 0, 2, 2, 2);
    try std.testing.expectEqual(ERROR.INVALID_TILING_MODE, sceVideoOutRegisterBuffers(h, 4, &addr, 1, &attr));

    _ = sceVideoOutSubmitFlip(h, 0, 1, 0);
    tick();
    try std.testing.expectEqual(@as(u32, 0x8033_2211), Testing.pixels[0]);
    _ = sceVideoOutSubmitFlip(h, 1, 1, 0);
    tick();
    try std.testing.expectEqual(@as(u32, 0xFFFF_8000), Testing.pixels[3]);
    _ = sceVideoOutSubmitFlip(h, 2, 1, 0);
    tick();
    try std.testing.expectEqual(@as(u32, 0xFFFF_80FF), Testing.pixels[0]);

    // No GPU path: a tiled frame is not shown (and the flip still happens).
    const shows = Testing.shows;
    _ = sceVideoOutSubmitFlip(h, 3, 1, 0);
    tick();
    try std.testing.expectEqual(shows, Testing.shows);
    var st: FlipStatus = undefined;
    _ = sceVideoOutGetFlipStatus(h, &st);
    try std.testing.expectEqual(@as(i32, 3), st.current_buffer);
    // With one, its picture is.
    source = fromGpu;
    defer source = null;
    _ = sceVideoOutSubmitFlip(h, 3, 1, 0);
    tick();
    try std.testing.expectEqual(shows + 1, Testing.shows);
    try std.testing.expectEqual(@as(u32, 0xFFAB_CDEF), Testing.pixels[3]);
    // (what the GPU path does not know is read from memory as before)
    _ = sceVideoOutSubmitFlip(h, 0, 1, 0);
    tick();
    try std.testing.expectEqual(@as(u32, 0x8033_2211), Testing.pixels[0]);

    // A group forgotten: its buffer can be registered again; a flip of it
    // that was waiting shows nothing.
    _ = sceVideoOutSubmitFlip(h, 0, 1, 0);
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutUnregisterBuffers(h, 0));
    try std.testing.expectEqual(ERROR.INVALID_VALUE, sceVideoOutUnregisterBuffers(h, 0));
    const before = Testing.shows;
    tick();
    try std.testing.expectEqual(before, Testing.shows);

    // The display closed by the game: its window goes at the next refresh,
    // and a wait for a refresh is told there is no display.
    try std.testing.expectEqual([2]u32{ 2, 2 }, Testing.opened);
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutClose(h));
    tick();
    try std.testing.expectEqual([2]u32{ 0, 0 }, Testing.opened);
    try std.testing.expectEqual(ERROR.INVALID_HANDLE, sceVideoOutGetFlipStatus(h, &st));
    try std.testing.expectEqual(ERROR.INVALID_HANDLE, waitVblank(h));
}

test "a PS5 game's calls: 64-bit formats, groups it names, a status of 128 bytes" {
    Testing.reset();
    const h = sceVideoOutOpen(0, BUS_MAIN, 0, null);
    defer _ = sceVideoOutClose(h);
    var attr: Attribute2 = undefined;
    // Red in the low byte, in rows.
    var rgba = [_]u32{0xFF11_2233} ** 4;
    sceVideoOutSetBufferAttribute2(&attr, FORMAT5.R8G8B8A8, TILING.LINEAR, 2, 2, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), attr.pitch_in_pixel);
    var bufs = [_]Buffer2{.{ .data = @intFromPtr(&rgba) }};
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutRegisterBuffers2(h, 2, 5, &bufs, 1, &attr, 0, null));
    try std.testing.expectEqual(ERROR.SLOT_OCCUPIED, sceVideoOutRegisterBuffers2(h, 2, 5, &bufs, 1, &attr, 0, null));
    try std.testing.expectEqual(ERROR.INVALID_VALUE, sceVideoOutRegisterBuffers2(h, 4, 6, &bufs, 1, &attr, 0, null));
    // (a group is registered once)
    try std.testing.expectEqual(ERROR.INVALID_INDEX, sceVideoOutRegisterBuffers2(h, 2, 6, &bufs, 1, &attr, 0, null));
    // Ten bits a colour with red low: red 0x3FF, blue 0.
    var ten = [_]u32{0x3FF} ** 4;
    sceVideoOutSetBufferAttribute2(&attr, FORMAT5.R10G10B10A2_PQ, TILING.LINEAR, 2, 2, 0, 0, 0);
    bufs[0].data = @intFromPtr(&ten);
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutRegisterBuffers2(h, 0, 7, &bufs, 1, &attr, 0, null));
    sceVideoOutSetBufferAttribute2(&attr, 0x1234_0000_0000_0000, TILING.LINEAR, 2, 2, 0, 0, 0);
    try std.testing.expectEqual(ERROR.INVALID_PIXEL_FORMAT, sceVideoOutRegisterBuffers2(h, 1, 8, &bufs, 1, &attr, 0, null));

    _ = sceVideoOutSubmitFlip(h, 5, 1, -7);
    tick();
    try std.testing.expectEqual(@as(u32, 0xFF33_2211), Testing.pixels[0]);
    _ = sceVideoOutSubmitFlip(h, 7, 1, 9);
    _ = sceVideoOutSubmitFlip(h, -2, 1, 10);
    tick();
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), Testing.pixels[0]);

    // The status as a PS5 game reads it: all 128 bytes written (the last
    // of them, which hold nothing, to 0), and nothing after them.
    var st: [2]FlipStatus5 = undefined;
    @memset(std.mem.asBytes(&st), 0xEE);
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutGetFlipStatus(h, &st[0]));
    try std.testing.expectEqual(@as(u64, 2), st[0].count);
    try std.testing.expectEqual(@as(i64, 9), st[0].flip_arg);
    try std.testing.expectEqual(@as(i32, 7), st[0].current_buffer);
    try std.testing.expectEqual(@as(i32, 1), st[0].flip_pending_num);
    try std.testing.expectEqual(@as(u64, 0), st[0].reserved3[6]);
    try std.testing.expectEqual(@as(u64, 0xEEEE_EEEE_EEEE_EEEE), st[1].count);
    // The vblank status too: 40 bytes for a PS5 game.
    var vb: [6]u64 = [_]u64{0xEEEE} ** 6;
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutGetVblankStatus(h, &vb));
    try std.testing.expectEqual(@as(u64, 2), vb[0]);
    try std.testing.expectEqual(@as(u64, 0), vb[4]);
    try std.testing.expectEqual(@as(u64, 0xEEEE), vb[5]);
    var cap: u64 = 0;
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutGetDeviceCapabilityInfo(h, &cap, 8));
    try std.testing.expectEqual(ERROR.INVALID_VALUE, sceVideoOutGetDeviceCapabilityInfo(h, &cap, 16));
}

fn behindTheGpu(handle: i32, buffer: i32, mode: i32, arg: i64) ?i32 {
    _ = handle;
    _ = mode;
    if (arg != 77) return null;
    Testing.routed = buffer;
    reserve(1);
    return 0;
}

test "promised flips count as pending; a buffer given back takes its waiting flips with it" {
    Testing.reset();
    const h = sceVideoOutOpen(0, BUS_MAIN, 0, null);
    defer _ = sceVideoOutClose(h);
    var a = [_]u32{0xFF00_0001} ** 4;
    var b = [_]u32{0xFF00_0002} ** 4;
    try std.testing.expectEqual(@as(i32, 0), testRegister(h, 3, &a, 2, 2));

    // Flips in a command buffer the GPU's queue has not come to yet.
    reserve(2);
    try std.testing.expectEqual(@as(i32, 2), pendingFlips(h));
    try std.testing.expectEqual(@as(i32, 0), submitReserved(h, 3, 1, 5));
    try std.testing.expectEqual(@as(i32, 2), pendingFlips(h));
    // (one that cannot be, a buffer never registered, drops its promise)
    try std.testing.expectEqual(ERROR.INVALID_INDEX, submitReserved(h, 9, 1, 0));
    try std.testing.expectEqual(@as(i32, 1), pendingFlips(h));
    tick();
    try std.testing.expectEqual(@as(i32, 0), pendingFlips(h));

    // A flip the game's own code asks for goes behind the GPU's work when
    // the GPU path says so, and is pending meanwhile.
    flip_router = behindTheGpu;
    defer flip_router = null;
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutSubmitFlip(h, 3, 1, 77));
    try std.testing.expectEqual(@as(i32, 3), Testing.routed);
    try std.testing.expectEqual(@as(i32, 1), pendingFlips(h));
    try std.testing.expectEqual(ERROR.INVALID_INDEX, sceVideoOutSubmitFlip(h, 9, 1, 77));
    unreserve(1);
    // (and one the GPU path does not take is queued here)
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutSubmitFlip(h, 3, 1, 78));
    tick();
    try std.testing.expectEqual(@as(i64, 78), lastFlipArg(h));

    // Two flips of a buffer wait; the buffer is given back and its place
    // registered again with other memory. The old flips still happen and
    // show nothing; the new buffer is not busy, and its own flip shows it.
    var labels_at: u64 = 0;
    _ = sceVideoOutGetBufferLabelAddress(h, &labels_at);
    const labels: *const [BUFFERS]u64 = @ptrFromInt(labels_at);
    _ = sceVideoOutSubmitFlip(h, 3, 1, 1);
    _ = sceVideoOutSubmitFlip(h, 3, 1, 2);
    try std.testing.expectEqual(@as(u64, 1), labels[3]);
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutUnregisterBuffers(h, 0));
    try std.testing.expectEqual(@as(u64, 0), labels[3]);
    try std.testing.expectEqual(@as(i32, 0), testRegister(h, 3, &b, 2, 2));
    const shows = Testing.shows;
    tick();
    try std.testing.expectEqual(shows, Testing.shows);
    try std.testing.expectEqual(@as(i64, 1), lastFlipArg(h));
    _ = sceVideoOutSubmitFlip(h, 3, 1, 3);
    try std.testing.expectEqual(@as(u64, 1), labels[3]);
    tick();
    try std.testing.expectEqual(shows, Testing.shows);
    try std.testing.expectEqual(@as(u64, 1), labels[3]);
    tick();
    try std.testing.expectEqual(shows + 1, Testing.shows);
    try std.testing.expectEqual(@as(u32, 0xFF00_0002), Testing.pixels[0]);
    try std.testing.expectEqual(@as(u64, 0), labels[3]);

    // A PS4 game's vblank status: 32 bytes, and nothing after them.
    var vb: [5]u64 = [_]u64{0xEEEE} ** 5;
    try std.testing.expectEqual(@as(i32, 0), sceVideoOutGetVblankStatus(h, &vb));
    try std.testing.expectEqual(@as(u64, 5), vb[0]);
    try std.testing.expectEqual(@as(u64, 0), vb[3]);
    try std.testing.expectEqual(@as(u64, 0xEEEE), vb[4]);
}

test "names resolve by NID under the library's name" {
    try std.testing.expect(find("libSceVideoOut", nid.of("sceVideoOutOpen")) != null);
    try std.testing.expectEqual(@as(?u64, null), find("libkernel", nid.of("sceVideoOutOpen")));
    try std.testing.expectEqual(@as(?u64, null), find("libSceVideoOut", nid.of("sceVideoOutNoSuchFunction")));
    // The published NID of sceVideoOutOpen.
    try std.testing.expect(find("libSceVideoOut", nid.parse("Up36PTk687E").?) != null);
}
