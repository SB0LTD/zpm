//! @zpm/gpu kir_interp — the definition of KIR: runs a kernel on the CPU,
//! exactly, under a device's Caps.
//!
//! Each group runs in lockstep: one instruction for all its threads, then
//! the next, with masks for divergence. Subgroups are Caps.subgroup
//! consecutive threads (x fastest). The floating-point ops are computed in
//! software where the host's own could differ (fused multiply-add, NaN
//! bits), so the result is the same bits on any CPU.

const std = @import("std");
const kir = @import("kir.sig");
const device = @import("device.sig");
const Caps = device.Caps;
const Inst = kir.Inst;

/// What stopped a kernel.
pub const Trap = struct {
    what: What = .none,
    /// the instruction's index
    pc: u32 = 0,
    group: [3]u32 = .{ 0, 0, 0 },
    /// the thread's linear index in its group
    thread: u32 = 0,
    /// the binding (global) or 0xff (shared) and the byte offset
    binding: u8 = 0,
    offset: u64 = 0,

    pub const What = enum {
        none,
        /// an access outside its binding or the group's shared memory
        out_of_bounds,
        /// an access not aligned to its width
        misaligned,
        /// a binding with no buffer
        bad_binding,
        /// two threads of a group on one shared word between barriers
        /// (one of them writing), without atomics
        shared_race,
        /// a barrier some of the group's threads did not reach
        divergent_barrier,
        /// a shuffle from a lane that is not active
        inactive_lane,
        /// the program is malformed (unbalanced flow, bad operands)
        bad_program,
    };
};

pub const Error = error{
    /// The kernel trapped; `Trap` says where.
    Trap,
    /// The program or launch is malformed.
    BadProgram,
    /// The Work is too small for this launch.
    NoWork,
};

/// Counts for one run.
pub const Stats = struct {
    groups: u64 = 0,
    /// instructions issued (per group)
    issued: u64 = 0,
    /// thread-instructions executed (active lanes)
    lane_ops: u64 = 0,
};

/// A dispatch for the interpreter.
pub const Launch = struct {
    code: []const Inst,
    regs: u32,
    group: [3]u32,
    shared_bytes: u32,
    groups: [3]u32,
    /// each binding's bytes as the GPU sees them
    bindings: []const []u8,
    /// the words after the bindings
    params: []const u32,
};

/// Run `l` under `caps` with scratch space from `work` (given back after).
pub fn run(l: Launch, caps: Caps, work: *device.Work, trap: *Trap, stats: *Stats) Error!void {
    _ = l;
    _ = caps;
    _ = work;
    trap.* = .{};
    stats.* = .{};
    return error.BadProgram;
}

/// Run a kernel as built (verified first): the tests' shortcut.
pub fn runKernel(k: *const kir.Kernel, caps: Caps, groups: [3]u32, bindings: []const []u8, params: []const u32, work: *device.Work, trap: *Trap) (Error || kir.Error)!Stats {
    try kir.verify(k, caps);
    var stats: Stats = .{};
    try run(.{
        .code = k.code(),
        .regs = k.nv,
        .group = k.group,
        .shared_bytes = k.shared_bytes,
        .groups = groups,
        .bindings = bindings,
        .params = params,
    }, caps, work, trap, &stats);
    return stats;
}
