// screencap SB0 backend — Nexus compositor client (userspace on SB0S/SB0X).
// Selected at comptime by screencap.sig for `-target aarch64-sb0`.
//
// This talks to the Nexus compositor over the SB0 v0 device-queue ABI (the
// same `svc #0` gate every native SB0 app uses). The kernel exposes three
// screen-capture operations on the pre-delegated device handles:
//
//   • display query, selector 2  -> enumerate capturable surfaces
//   • display capture (0x0013)    -> copy a surface's BGRX8888 pixels out
//   • input inject_pointer (0x03) -> synthesize a pointer click
//
// The ABI is a stable numeric contract, so this backend declares the small
// slice of it that it needs inline rather than taking a path dependency on the
// OS repo. Device handles follow the standard delegation: index 1 = display,
// index 2 = input (when the launcher grants them). If a handle was not granted
// or the queue handshake fails, the operation degrades to "no display" rather
// than faulting.

const api = @import("../screencap.sig");
const builtin = @import("builtin");

const WindowInfo = api.WindowInfo;
const Capture = api.Capture;
const EnumOptions = api.EnumOptions;

// ── SB0 v0 ABI (numeric contract; mirrors src/abi/sb0_v0.sig) ──

const Handle = u32;
const HANDLE_INVALID: Handle = 0xffff_ffff;

const OP_QUEUE_CREATE: u64 = 0x0200;
const OP_QUEUE_MAP: u64 = 0x0201;
const OP_QUEUE_SUBMIT: u64 = 0x0202;
const OP_QUEUE_WAIT: u64 = 0x0203;
const OP_TIME_SLEEP: u64 = 0x0801;

const DEVICE_DISPLAY: Handle = 1;
const DEVICE_INPUT: Handle = 2;

// DeviceIoOp opcodes carried in SQE.opcode.
const DIO_QUERY: u16 = 0x0000;
const DIO_INJECT_POINTER: u16 = 0x0003;
const DIO_CAPTURE: u16 = 0x0013;

const STATUS_SUCCESS: u64 = 0;
const FORMAT_BGRX8888: u32 = 0x3432_5258;

const SQE = extern struct {
    opcode: u16 = 0,
    flags: u16 = 0,
    handle: Handle = HANDLE_INVALID,
    user_data: u64 = 0,
    param: [5]u64 = @splat(0),
    _reserved: [8]u8 = @splat(0),
};

const CQE = extern struct {
    user_data: u64 = 0,
    result: i64 = 0,
    flags: u32 = 0,
    _reserved: u32 = 0,
};

const RingHeader = extern struct {
    head: u32 align(64) = 0,
    _pad_head: [60]u8 = @splat(0),
    tail: u32 align(64) = 0,
    _pad_tail: [60]u8 = @splat(0),
    mask: u32 = 0,
    depth: u32 = 0,
    flags: u32 = 0,
    _reserved: u32 = 0,
};

const CapturableSurface = extern struct {
    id: u64 = 0,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    flags: u32 = 0,
    _reserved: [2]u32 = @splat(0),
};

// ── Trap gate: single `svc #0`, opcode in x8, args x0..x5, results x0/x1/x2 ──

const RawResult = extern struct { value: u64 = 0, status: u64 = 0, extra: u64 = 0 };

extern fn zpmSb0Trap(op: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, out: *RawResult) callconv(.c) u64;

comptime {
    if (builtin.cpu.arch == .aarch64) {
        asm (
            \\.global zpmSb0Trap
            \\.type zpmSb0Trap, %function
            \\.p2align 2
            \\zpmSb0Trap:
            \\  mov x9, x7
            \\  mov x8, x0
            \\  mov x0, x1
            \\  mov x1, x2
            \\  mov x2, x3
            \\  mov x3, x4
            \\  mov x4, x5
            \\  mov x5, x6
            \\  svc #0
            \\  stp x0, x1, [x9]
            \\  str x2, [x9, #16]
            \\  mov x0, x1
            \\  ret
        );
    }
}

fn trap(op: u64, args: [6]u64) RawResult {
    var out = RawResult{};
    if (builtin.cpu.arch != .aarch64) return out;
    _ = zpmSb0Trap(op, args[0], args[1], args[2], args[3], args[4], args[5], &out);
    return out;
}

// ── Device queue binding + one-shot submit ──

const Queue = struct {
    ready: bool = false,
    device: Handle = HANDLE_INVALID,
    sq_handle: Handle = HANDLE_INVALID,
    cq_handle: Handle = HANDLE_INVALID,
    sq_header: *volatile RingHeader = undefined,
    cq_header: *volatile RingHeader = undefined,
    sq_entries: [*]volatile SQE = undefined,
    cq_entries: [*]volatile CQE = undefined,
};

fn openQueue(device: Handle) ?Queue {
    if (builtin.cpu.arch != .aarch64) return null;
    const created = trap(OP_QUEUE_CREATE, .{ 8, 0, device, 0, 0, 0 });
    if (created.status != STATUS_SUCCESS) return null;
    const sq_handle: Handle = @intCast(created.value);
    const cq_handle: Handle = @intCast(created.extra);

    const sq_map = trap(OP_QUEUE_MAP, .{ sq_handle, 0, 0, 0, 0, 0 });
    if (sq_map.status != STATUS_SUCCESS or sq_map.value == 0 or sq_map.extra == 0) return null;
    const cq_map = trap(OP_QUEUE_MAP, .{ cq_handle, 0, 0, 0, 0, 0 });
    if (cq_map.status != STATUS_SUCCESS or cq_map.value == 0 or cq_map.extra == 0) return null;

    return .{
        .ready = true,
        .device = device,
        .sq_handle = sq_handle,
        .cq_handle = cq_handle,
        .sq_header = @ptrFromInt(sq_map.value),
        .cq_header = @ptrFromInt(cq_map.value),
        .sq_entries = @ptrFromInt(sq_map.extra),
        .cq_entries = @ptrFromInt(cq_map.extra),
    };
}

fn barrier() void {
    if (builtin.cpu.arch == .aarch64) asm volatile ("dmb ish" ::: .{ .memory = true });
}

/// Submit one SQE and wait for its CQE. Returns null on any queue failure.
fn submit(queue: *Queue, request: SQE) ?CQE {
    if (!queue.ready) return null;
    var sqe = request;
    sqe.handle = queue.device;
    const tail = queue.sq_header.tail;
    queue.sq_entries[tail & queue.sq_header.mask] = sqe;
    barrier();
    queue.sq_header.tail = tail +% 1;

    const submitted = trap(OP_QUEUE_SUBMIT, .{ queue.sq_handle, 1, 0, 0, 0, 0 });
    if (submitted.status != STATUS_SUCCESS) return null;

    // Wait until at least one completion is available (bounded spin + wait).
    var spins: u32 = 0;
    while (queue.cq_header.head == queue.cq_header.tail) {
        const waited = trap(OP_QUEUE_WAIT, .{ queue.cq_handle, 1, 0, 0, 0, 0 });
        if (waited.status != STATUS_SUCCESS) {
            spins += 1;
            if (spins > 1024) return null;
        }
    }
    barrier();
    const head = queue.cq_header.head;
    const cqe = queue.cq_entries[head & queue.cq_header.mask];
    queue.cq_header.head = head +% 1;
    barrier();
    return cqe;
}

fn statusOk(cqe: CQE) bool {
    return (cqe.flags & 0xffff) == @as(u32, @intCast(STATUS_SUCCESS));
}

// ── Public backend API ──

pub fn enumerate(comptime capacity: usize, list: *api.WindowList(capacity), opts: EnumOptions) usize {
    list.len = 0;
    if (builtin.cpu.arch != .aarch64 or capacity == 0) return 0;

    var queue = openQueue(DEVICE_DISPLAY) orelse return 0;

    var surface: CapturableSurface = .{};
    var request = SQE{ .opcode = DIO_QUERY };
    request.param[0] = @intFromPtr(&surface);
    request.param[1] = @sizeOf(CapturableSurface);
    request.param[2] = 2; // selector 2 = enumerate capturable surfaces
    const cqe = submit(&queue, request) orelse return 0;
    if (!statusOk(cqe) or cqe.result <= 0) return 0;

    const w: i32 = @intCast(surface.width);
    const h: i32 = @intCast(surface.height);
    if (w < opts.min_width or h < opts.min_height) return 0;

    var info: WindowInfo = .{
        .handle = surface.id,
        .left = surface.x,
        .top = surface.y,
        .width = w,
        .height = h,
    };
    const title = "SB0 screen";
    for (title, 0..) |c, i| info.title[i] = c;
    info.title_len = title.len;

    list.items[0] = info;
    list.len = 1;
    return 1;
}

pub fn captureWindow(win: WindowInfo, out: []u8) Capture {
    if (builtin.cpu.arch != .aarch64) return api.captureFail(out);
    const width: u32 = @intCast(if (win.width > 0) win.width else 0);
    const height: u32 = @intCast(if (win.height > 0) win.height else 0);
    if (width == 0 or height == 0) return api.captureFail(out);
    const needed = @as(usize, width) * @as(usize, height) * 4;
    if (out.len < needed) return api.captureFail(out);

    var queue = openQueue(DEVICE_DISPLAY) orelse return api.captureFail(out);

    var request = SQE{ .opcode = DIO_CAPTURE };
    request.param[0] = win.handle; // surface id
    request.param[1] = @intFromPtr(out.ptr);
    request.param[2] = out.len;
    const cqe = submit(&queue, request) orelse return api.captureFail(out);
    if (!statusOk(cqe) or cqe.result <= 0) return api.captureFail(out);

    // The kernel wrote BGRX8888; swap to the RGBA this module's callers expect.
    var i: usize = 0;
    while (i < needed) : (i += 4) {
        const b = out[i];
        out[i] = out[i + 2];
        out[i + 2] = b;
        out[i + 3] = 255;
    }
    return .{ .pixels = out[0..needed], .width = width, .height = height, .ok = true };
}

pub fn clickAt(screen_x: i32, screen_y: i32) bool {
    if (builtin.cpu.arch != .aarch64) return false;
    var queue = openQueue(DEVICE_INPUT) orelse return false;
    var request = SQE{ .opcode = DIO_INJECT_POINTER };
    request.param[0] = 0; // kind 0 = left-button click
    request.param[1] = @bitCast(@as(i64, screen_x));
    request.param[2] = @bitCast(@as(i64, screen_y));
    const cqe = submit(&queue, request) orelse return false;
    return statusOk(cqe);
}

pub fn sleepMs(ms: u32) void {
    if (builtin.cpu.arch != .aarch64) return;
    // time_sleep takes architectural counter ticks; without the frequency here
    // we submit a best-effort tick count. Callers use this only to space out a
    // click and a verification capture, so precision is not critical.
    _ = trap(OP_TIME_SLEEP, .{ @as(u64, ms) * 1000, 0, 0, 0, 0, 0 });
}
