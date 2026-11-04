//! @zpm/amdgpu gcn3_emu — a functional emulator of GCN3/GCN4 compute
//! kernels, wave64 by wave64.
//!
//! There is no Polaris to test against on a PC, so kernels run here first:
//! the same words the GPU gets are decoded and executed, lane by lane under
//! EXEC, wave by wave (the waves of a workgroup take turns at s_barrier),
//! workgroup by workgroup, with the hardware's launch state: the user SGPRs
//! of the dispatch, the workgroup ids after them, the workitem ids in v0-v2,
//! and memory reached the way the hardware reaches it (SMEM and MUBUF
//! through 64-bit addresses and buffer resources with their range checks,
//! FLAT through 64-bit addresses, DS through the workgroup's LDS).
//!
//! It also checks what the hardware does not interlock, as errors rather
//! than stale reads:
//!   - a read (or overwrite) of a register a load has not delivered, i.e. a
//!     missing s_waitcnt vmcnt/lgkmcnt (SMEM returns out of order, so only
//!     lgkmcnt(0) waits for it; FLAT counts on both counters);
//!   - gfx8's manual wait states: a VALU SGPR write read by a VMEM
//!     instruction (5), by v_readlane/v_writelane's lane select (4), VCC by
//!     v_div_fmas (4), VCC/EXEC read as vccz/execz (5), and the data VGPRs
//!     of a store wider than 64 bits overwritten too soon (1);
//!   - LDS addresses past M0 (gfx8 clamps DS accesses to M0: kernels set it
//!     to -1) or past the workgroup's LDS;
//!   - registers past the kernel's VGPR/SGPR counts.
//!
//! Floating point is the host's IEEE arithmetic, with f32 denormals flushed
//! when the kernel's mode says so; v_mad/v_mac round twice, v_fma once. The
//! transcendentals (exp, log, rcp, rsq, sqrt, sin, cos) are exact here and
//! approximate on the GPU: compare their results with a tolerance.
//!
//! Allocation-free: the caller owns the Work (about 1.4 MB: keep it static).

const std = @import("std");
const gcn3 = @import("gcn3.sig");
const gcn3_asm = @import("gcn3_asm.sig");
const dispatch = @import("dispatch.sig");

const Instr = gcn3.Instr;
const Ty = gcn3.Ty;
const op = gcn3.op;

pub const LANES = 64;
pub const MAX_WAVES = 16;
pub const LDS_BYTES = 65536;
pub const MAX_CODE = 65536;

pub const Error = error{
    BadInstruction,
    Unsupported,
    Fault,
    Hazard,
    Timeout,
    BadDispatch,
    RegisterOutOfRange,
} || gcn3.Error;

/// A region of GPU-visible memory.
pub const Region = struct { va: u64, bytes: []u8 };

pub const Memory = struct {
    regions: []const Region,

    pub fn find(m: *const Memory, va: u64, len: usize) ?[]u8 {
        for (m.regions) |r| {
            if (va >= r.va and va + len <= r.va + r.bytes.len) return r.bytes[@intCast(va - r.va)..][0..len];
        }
        return null;
    }
};

pub const Dispatch = struct {
    kernel: *const gcn3_asm.Kernel,
    /// The user SGPR values (COMPUTE_USER_DATA_n), in the kernel's layout.
    user_sgprs: []const u32,
    groups: [3]u32,
    /// Where the code is (s_getpc_b64 reads it).
    code_va: u64 = 0x7f00_0000_0000,
    max_steps: u64 = 200_000_000,
    /// A buffer access past its V#'s records is an error (Fault), not the
    /// hardware's zero read and dropped write: for code that never means to
    /// rely on the range check.
    strict_buffers: bool = false,
};

pub const Stats = struct {
    workgroups: u64 = 0,
    waves: u64 = 0,
    instructions: u64 = 0,
    /// Lane-instructions of the vector ALU (per active lane).
    lane_ops: u64 = 0,
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    lds_bytes: u64 = 0,
};

const Pending = struct { vm: u32 = 0, lgkm: u32 = 0 };

pub const Wave = struct {
    /// The scalar registers by operand code: s0..s101, flat_scratch, vcc,
    /// tba, tma, ttmp0..11, m0, exec.
    s: [128]u32,
    v: [256][LANES]u32,
    scc: bool,
    /// In dwords.
    pc: u32,
    done: bool,
    barrier: bool,
    id: u32,
    // s_waitcnt: issue tickets and how many have certainly returned.
    vm_issued: u32,
    vm_done: u32,
    lgkm_issued: u32,
    lgkm_done: u32,
    smem_last: u32,
    pv: [256]Pending,
    ps: [128]Pending,
    // wait states: the count after each VALU SGPR write, and the VGPRs a
    // wide store still reads.
    ws: u64,
    valu_s: [128]u64,
    store_lo: u16,
    store_hi: u16,
    store_ws: u64,
    hw: [8]u32,

    fn exec(wv: *const Wave) u64 {
        return @as(u64, wv.s[gcn3.EXEC_HI]) << 32 | wv.s[gcn3.EXEC_LO];
    }
    fn setExec(wv: *Wave, x: u64) void {
        wv.s[gcn3.EXEC_LO] = @truncate(x);
        wv.s[gcn3.EXEC_HI] = @truncate(x >> 32);
    }
    fn vcc(wv: *const Wave) u64 {
        return @as(u64, wv.s[gcn3.VCC_HI]) << 32 | wv.s[gcn3.VCC_LO];
    }
};

pub const Work = struct {
    waves: [MAX_WAVES]Wave = undefined,
    lds: [LDS_BYTES]u8 = undefined,
    code: [MAX_CODE]Instr = undefined,
    starts: [MAX_CODE]bool = undefined,
    ncode: usize = 0,
    nwaves: usize = 0,
    lds_limit: u32 = 0,
    ftz32: bool = true,
    /// MODE.IEEE: min/max quiet a signaling NaN rather than take the other operand.
    ieee: bool = true,
    steps: u64 = 0,
    // Where the last error happened.
    err_pc: u32 = 0,
    err_wave: u32 = 0,
    err_group: [3]u32 = .{ 0, 0, 0 },
    msg_buf: [200]u8 = undefined,
    msg_len: usize = 0,

    fn fail(w: *Work, e: Error, comptime fmt: []const u8, args: anytype) Error {
        const out = std.fmt.bufPrint(&w.msg_buf, fmt, args) catch w.msg_buf[0..0];
        w.msg_len = out.len;
        return e;
    }

    /// What went wrong, and where (after run returned an error).
    pub fn message(w: *const Work) []const u8 {
        return w.msg_buf[0..w.msg_len];
    }

    /// The instruction the last error happened at, as text.
    pub fn errorInstr(w: *const Work, buf: []u8) []const u8 {
        if (w.err_pc >= w.ncode or !w.starts[w.err_pc]) return "?";
        return gcn3.format(&w.code[w.err_pc], buf) catch "?";
    }
};

/// Decode the kernel and check its registers fit its counts.
pub fn load(w: *Work, k: *const gcn3_asm.Kernel) Error!void {
    w.err_pc = std.math.maxInt(@TypeOf(w.err_pc));
    if (k.code.len > MAX_CODE) return w.fail(error.BadDispatch, "{d} code dwords (at most {d})", .{ k.code.len, MAX_CODE });
    @memset(w.starts[0..k.code.len], false);
    w.ncode = k.code.len;
    const vlimit = k.config.vgprs();
    const slimit = @max(k.config.next_free_sgpr, @as(u16, k.config.userSgprCount()) + k.config.systemSgprCount());
    var at: usize = 0;
    while (at < k.code.len) {
        var in: Instr = undefined;
        const n = gcn3.decode(k.code[at..], &in) catch {
            w.err_pc = @intCast(at);
            return w.fail(error.BadInstruction, "no instruction at dword {d} ({x:0>8})", .{ at, k.code[at] });
        };
        w.code[at] = in;
        w.starts[at] = true;
        const rl = gcn3.regs(&in);
        for ([_][]const gcn3.RegRef{ rl.readSlice(), rl.writeSlice() }) |list| {
            for (list) |r| {
                if (r.code >= gcn3.VGPR0 and r.code - gcn3.VGPR0 + r.n > vlimit) {
                    w.err_pc = @intCast(at);
                    return w.fail(error.RegisterOutOfRange, "v{d} past the kernel's {d} VGPRs", .{ r.code - gcn3.VGPR0 + r.n - 1, vlimit });
                }
                if (r.code < gcn3.SGPRS and r.code + r.n > slimit) {
                    w.err_pc = @intCast(at);
                    return w.fail(error.RegisterOutOfRange, "s{d} past the kernel's {d} SGPRs", .{ r.code + r.n - 1, slimit });
                }
            }
        }
        at += n;
    }
    w.ftz32 = k.config.float_denorm_mode_32 == 0;
    w.ieee = k.config.ieee_mode;
}

/// Run a dispatch: every workgroup of the grid, every wave of each.
pub fn run(w: *Work, mem: *const Memory, d: *const Dispatch, stats: *Stats) Error!void {
    const k = d.kernel;
    try load(w, k);
    const cfg = &k.config;
    if (d.user_sgprs.len != cfg.userSgprCount()) return w.fail(error.BadDispatch, "{d} user SGPRs given, the kernel takes {d}", .{ d.user_sgprs.len, cfg.userSgprCount() });
    const wg = k.workgroup_size;
    const lanes_per_group = @as(u32, wg[0]) * wg[1] * wg[2];
    const nwaves = (lanes_per_group + LANES - 1) / LANES;
    if (nwaves > MAX_WAVES or nwaves == 0) return w.fail(error.BadDispatch, "{d} waves a workgroup (1 to {d})", .{ nwaves, MAX_WAVES });
    w.nwaves = nwaves;
    w.lds_limit = @intCast(@min(LDS_BYTES, (cfg.group_segment_bytes + 511) / 512 * 512));
    w.steps = 0;
    var gz: u32 = 0;
    while (gz < d.groups[2]) : (gz += 1) {
        var gy: u32 = 0;
        while (gy < d.groups[1]) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < d.groups[0]) : (gx += 1) {
                w.err_group = .{ gx, gy, gz };
                try runGroup(w, mem, d, .{ gx, gy, gz }, nwaves, lanes_per_group, stats);
                stats.workgroups += 1;
            }
        }
    }
}

fn runGroup(w: *Work, mem: *const Memory, d: *const Dispatch, gid: [3]u32, nwaves: u32, lanes: u32, stats: *Stats) Error!void {
    const k = d.kernel;
    const cfg = &k.config;
    const wg = k.workgroup_size;
    @memset(w.lds[0..w.lds_limit], 0);
    for (0..nwaves) |i| {
        const wv = &w.waves[i];
        @memset(&wv.s, 0);
        for (&wv.v) |*r| @memset(r, 0);
        wv.scc = false;
        wv.pc = 0;
        wv.done = false;
        wv.barrier = false;
        wv.id = @intCast(i);
        wv.vm_issued = 0;
        wv.vm_done = 0;
        wv.lgkm_issued = 0;
        wv.lgkm_done = 0;
        wv.smem_last = 0;
        @memset(&wv.pv, .{});
        @memset(&wv.ps, .{});
        wv.ws = 0;
        @memset(&wv.valu_s, 0);
        wv.store_lo = 0;
        wv.store_hi = 0;
        wv.store_ws = 0;
        @memset(&wv.hw, 0);
        var sg: usize = 0;
        for (d.user_sgprs) |x| {
            wv.s[sg] = x;
            sg += 1;
        }
        for (0..3) |a| {
            if (cfg.workgroup_id[a]) {
                wv.s[sg] = gid[a];
                sg += 1;
            }
        }
        if (cfg.workgroup_info) {
            wv.s[sg] = nwaves;
            sg += 1;
        }
        if (cfg.private_segment_wave_offset) {
            wv.s[sg] = 0;
            sg += 1;
        }
        // MODE as the descriptor sets it; HW_ID's wave id.
        wv.hw[1] = @as(u32, cfg.float_round_mode_32) | @as(u32, cfg.float_round_mode_16_64) << 2 | @as(u32, cfg.float_denorm_mode_32) << 4 | @as(u32, cfg.float_denorm_mode_16_64) << 6 | @as(u32, @intFromBool(cfg.dx10_clamp)) << 8 | @as(u32, @intFromBool(cfg.ieee_mode)) << 9;
        wv.hw[4] = @intCast(i);
        var exec: u64 = 0;
        for (0..LANES) |l| {
            const item = @as(u32, @intCast(i)) * LANES + @as(u32, @intCast(l));
            if (item >= lanes) continue;
            exec |= @as(u64, 1) << @intCast(l);
            wv.v[0][l] = item % wg[0];
            if (cfg.workitem_id >= 1) wv.v[1][l] = item / wg[0] % wg[1];
            if (cfg.workitem_id >= 2) wv.v[2][l] = item / (@as(u32, wg[0]) * wg[1]);
        }
        wv.setExec(exec);
        stats.waves += 1;
    }
    while (true) {
        var live: usize = 0;
        var waiting: usize = 0;
        for (w.waves[0..nwaves]) |*wv| {
            if (wv.done) continue;
            if (!wv.barrier) try runWave(w, mem, d, wv, stats);
            if (!wv.done) {
                live += 1;
                if (wv.barrier) waiting += 1;
            }
        }
        if (live == 0) break;
        if (waiting == live) {
            for (w.waves[0..nwaves]) |*wv| wv.barrier = false;
        }
    }
}

fn runWave(w: *Work, mem: *const Memory, d: *const Dispatch, wv: *Wave, stats: *Stats) Error!void {
    while (!wv.done and !wv.barrier) {
        w.steps += 1;
        if (w.steps > d.max_steps) return w.fail(error.Timeout, "more than {d} instructions", .{d.max_steps});
        if (wv.pc >= w.ncode or !w.starts[wv.pc]) {
            w.err_pc = wv.pc;
            w.err_wave = wv.id;
            return w.fail(error.Fault, "pc 0x{x} is not an instruction", .{wv.pc * 4});
        }
        const in = &w.code[wv.pc];
        w.err_pc = wv.pc;
        w.err_wave = wv.id;
        try step(w, mem, d, wv, in, stats);
        stats.instructions += 1;
    }
}

// ── Hazards ─────────────────────────────────────────────────────────────────

fn ready(wv: *const Wave, p: Pending) bool {
    return p.vm <= wv.vm_done and p.lgkm <= wv.lgkm_done;
}

fn pendingOf(wv: *Wave, code: u16) ?*Pending {
    if (code >= gcn3.VGPR0) return &wv.pv[code - gcn3.VGPR0];
    if (code < 128) return &wv.ps[code];
    return null;
}

fn checkPending(w: *Work, wv: *Wave, rl: *const gcn3.RegList) Error!void {
    for ([_][]const gcn3.RegRef{ rl.readSlice(), rl.writeSlice() }, 0..) |list, k| {
        for (list) |r| {
            for (0..r.n) |i| {
                const p = pendingOf(wv, r.code + @as(u16, @intCast(i))) orelse continue;
                if (!ready(wv, p.*)) {
                    const what = if (k == 0) "reads" else "overwrites";
                    return w.fail(error.Hazard, "{s} a register a load has not delivered: s_waitcnt {s} missing", .{ what, if (p.vm > wv.vm_done) "vmcnt" else "lgkmcnt" });
                }
            }
        }
    }
}

fn markPending(wv: *Wave, code: u16, n: u8, vm: bool, lgkm: bool) void {
    for (0..n) |i| {
        const p = pendingOf(wv, code + @as(u16, @intCast(i))) orelse continue;
        if (vm) p.vm = wv.vm_issued;
        if (lgkm) p.lgkm = wv.lgkm_issued;
    }
}

fn waitStates(w: *Work, wv: *Wave, code: u16, n: u8, need: u64, what: []const u8) Error!void {
    for (0..n) |i| {
        const c = code + i;
        if (c >= 128) continue;
        const at = wv.valu_s[c];
        if (at != 0 and wv.ws - at < need) return w.fail(error.Hazard, "{s} {d} wait states after a VALU wrote the SGPR; {d} passed (s_nop)", .{ what, need, wv.ws - at });
    }
}

fn isValu(e: gcn3.Enc) bool {
    return e == .vop1 or e == .vop2 or e == .vopc or e == .vop3;
}

fn step(w: *Work, mem: *const Memory, d: *const Dispatch, wv: *Wave, in: *const Instr, stats: *Stats) Error!void {
    const enc = in.enc();
    const rl = gcn3.regs(in);
    try checkPending(w, wv, &rl);
    // gfx8's manual wait states
    switch (enc) {
        .mubuf, .mtbuf => {
            try waitStates(w, wv, in.src[1], 4, 5, "a VMEM instruction reads its resource");
            try waitStates(w, wv, in.src[2], 1, 5, "a VMEM instruction reads its offset");
        },
        else => {},
    }
    if (isValu(enc)) {
        if (in.op == op("v_readlane_b32") or in.op == op("v_writelane_b32")) try waitStates(w, wv, in.src[1], 1, 4, "the lane select needs");
        if (in.op == op("v_div_fmas_f32") or in.op == op("v_div_fmas_f64")) try waitStates(w, wv, gcn3.VCC_LO, 2, 4, "v_div_fmas reads VCC");
        for (in.src) |c| {
            if (c == gcn3.VCCZ) try waitStates(w, wv, gcn3.VCC_LO, 2, 5, "vccz needs");
            if (c == gcn3.EXECZ) try waitStates(w, wv, gcn3.EXEC_LO, 2, 5, "execz needs");
        }
        for (rl.writeSlice()) |r| {
            if (r.code >= gcn3.VGPR0 and wv.ws - wv.store_ws < 1) {
                const lo = r.code - gcn3.VGPR0;
                if (lo < wv.store_hi and lo + r.n > wv.store_lo) return w.fail(error.Hazard, "overwrites the data of a store wider than 64 bits too soon (1 wait state)", .{});
            }
        }
    }
    const ws_before = wv.ws;
    const next = wv.pc + in.dwords();
    wv.pc = next;
    switch (enc) {
        .sop2, .sop1, .sopc, .sopk, .sopp => try salu(w, d, wv, in, next),
        .smem => try smem(w, mem, wv, in, stats),
        .vop1, .vop2, .vopc, .vop3 => try valu(w, wv, in, stats),
        .ds => try lds(w, wv, in, stats),
        .mubuf, .mtbuf => try buffer(w, mem, wv, in, stats, d.strict_buffers),
        .flat => try flat(w, mem, wv, in, stats),
    }
    wv.ws = ws_before + (if (in.op == op("s_nop")) in.imm + 1 else 1);
    if (isValu(enc)) {
        for (rl.writeSlice()) |r| {
            if (r.code < 128) {
                for (0..r.n) |i| wv.valu_s[r.code + i] = ws_before + 1;
            }
        }
    }
}

// ── Scalar operands ─────────────────────────────────────────────────────────

fn mask(t: Ty) u64 {
    return switch (t.dwords()) {
        0 => 0,
        1 => if (t.is16()) 0xffff else 0xffff_ffff,
        else => ~@as(u64, 0),
    };
}

fn sread(w: *Work, wv: *const Wave, code: u16, lit: u32, t: Ty) Error!u64 {
    if (code < 128) {
        var x: u64 = wv.s[code];
        if (t.dwords() >= 2) {
            if (code + 1 >= 128) return w.fail(error.BadInstruction, "a 64-bit operand at the last SGPR", .{});
            x |= @as(u64, wv.s[code + 1]) << 32;
        }
        return x & mask(t);
    }
    switch (code) {
        gcn3.VCCZ => return @intFromBool(wv.vcc() == 0),
        gcn3.EXECZ => return @intFromBool(wv.exec() == 0),
        gcn3.SCC => return @intFromBool(wv.scc),
        gcn3.LDS_DIRECT => return w.fail(error.Unsupported, "lds_direct", .{}),
        else => {},
    }
    if (gcn3.constValue(code, lit, t)) |x| return x & mask(t);
    return w.fail(error.BadInstruction, "operand code {d} in a scalar slot", .{code});
}

fn swrite(wv: *Wave, code: u16, t: Ty, x: u64) void {
    if (code >= 128) return;
    wv.s[code] = @truncate(x);
    if (t.dwords() >= 2 and code + 1 < 128) wv.s[code + 1] = @truncate(x >> 32);
}

fn sext16(x: u32) u32 {
    return @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(x))))));
}

fn bfe(x: u64, off: u6, width: u7, signed: bool, bits_: u7) u64 {
    if (width == 0) return 0;
    var r = x >> off;
    if (width < 64) r &= (@as(u64, 1) << @intCast(width)) - 1;
    if (signed and width < bits_) {
        const sh: u6 = @intCast(64 - @as(u7, width));
        r = @bitCast(@as(i64, @bitCast(r << sh)) >> sh);
    }
    return r;
}

fn flbitSigned(x: u64, bits_: u7) u64 {
    const top = (x >> @intCast(bits_ - 1)) & 1;
    const y = if (top != 0) ~x & mask64(bits_) else x;
    if (y == 0) return 0xffff_ffff;
    return @clz(y) - (64 - @as(u64, bits_));
}

fn mask64(bits_: u7) u64 {
    return if (bits_ >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(bits_)) - 1;
}

fn hwField(imm: u32) struct { id: u32, off: u5, size: u6 } {
    return .{ .id = imm & 63, .off = @intCast(imm >> 6 & 31), .size = @intCast((imm >> 11 & 31) + 1) };
}

fn salu(w: *Work, d: *const Dispatch, wv: *Wave, in: *const Instr, next: u32) Error!void {
    const df = in.d();
    const o = in.op;
    switch (df.enc) {
        .sop2 => {
            const a = try sread(w, wv, in.src[0], in.lit, df.s[0]);
            const b = try sread(w, wv, in.src[1], in.lit, df.s[1]);
            const a32: u32 = @truncate(a);
            const bv: u32 = @truncate(b);
            const ia: i32 = @bitCast(a32);
            const ib: i32 = @bitCast(bv);
            var r: u64 = 0;
            var scc: ?bool = null;

            switch (o) {
                op("s_add_u32") => {
                    const t = @as(u64, a32) + bv;
                    r = t & 0xffff_ffff;
                    scc = t >> 32 != 0;
                },
                op("s_sub_u32") => {
                    r = a32 -% bv;
                    scc = bv > a32;
                },
                op("s_add_i32") => {
                    const t = @addWithOverflow(ia, ib);
                    r = @as(u32, @bitCast(t[0]));
                    scc = t[1] != 0;
                },
                op("s_sub_i32") => {
                    const t = @subWithOverflow(ia, ib);
                    r = @as(u32, @bitCast(t[0]));
                    scc = t[1] != 0;
                },
                op("s_addc_u32") => {
                    const t = @as(u64, a32) + bv + @intFromBool(wv.scc);
                    r = t & 0xffff_ffff;
                    scc = t >> 32 != 0;
                },
                op("s_subb_u32") => {
                    const c: u64 = @intFromBool(wv.scc);
                    r = (@as(u64, a32) -% bv -% c) & 0xffff_ffff;
                    scc = @as(u64, bv) + c > a32;
                },
                op("s_min_i32") => {
                    scc = ia < ib;
                    r = if (ia < ib) a32 else bv;
                },
                op("s_min_u32") => {
                    scc = a32 < bv;
                    r = @min(a32, bv);
                },
                op("s_max_i32") => {
                    scc = ia > ib;
                    r = if (ia > ib) a32 else bv;
                },
                op("s_max_u32") => {
                    scc = a32 > bv;
                    r = @max(a32, bv);
                },
                op("s_cselect_b32"), op("s_cselect_b64") => r = if (wv.scc) a else b,
                op("s_and_b32"), op("s_and_b64") => r = a & b,
                op("s_or_b32"), op("s_or_b64") => r = a | b,
                op("s_xor_b32"), op("s_xor_b64") => r = a ^ b,
                op("s_andn2_b32"), op("s_andn2_b64") => r = a & ~b,
                op("s_orn2_b32"), op("s_orn2_b64") => r = a | ~b,
                op("s_nand_b32"), op("s_nand_b64") => r = ~(a & b),
                op("s_nor_b32"), op("s_nor_b64") => r = ~(a | b),
                op("s_xnor_b32"), op("s_xnor_b64") => r = ~(a ^ b),
                op("s_lshl_b32") => r = @as(u64, a32 << @intCast(b & 31)),
                op("s_lshl_b64") => r = a << @intCast(b & 63),
                op("s_lshr_b32") => r = a32 >> @intCast(b & 31),
                op("s_lshr_b64") => r = a >> @intCast(b & 63),
                op("s_ashr_i32") => r = @as(u32, @bitCast(ia >> @intCast(b & 31))),
                op("s_ashr_i64") => r = @bitCast(@as(i64, @bitCast(a)) >> @intCast(b & 63)),
                op("s_bfm_b32") => r = ((@as(u64, 1) << @intCast(a & 31)) - 1) << @intCast(b & 31),
                op("s_bfm_b64") => r = ((@as(u64, 1) << @intCast(a & 63)) -% 1) << @intCast(b & 63),
                op("s_mul_i32") => r = a32 *% bv,
                op("s_bfe_u32") => r = bfe(a32, @intCast(b & 31), @intCast(b >> 16 & 0x7f), false, 32),
                op("s_bfe_i32") => r = bfe(a32, @intCast(b & 31), @intCast(b >> 16 & 0x7f), true, 32),
                op("s_bfe_u64") => r = bfe(a, @intCast(b & 63), @intCast(b >> 16 & 0x7f), false, 64),
                op("s_bfe_i64") => r = bfe(a, @intCast(b & 63), @intCast(b >> 16 & 0x7f), true, 64),
                op("s_absdiff_i32") => r = @abs(@as(i64, ia) - ib) & 0xffff_ffff,
                else => return w.fail(error.Unsupported, "{s}", .{df.name}),
            }
            r &= mask(df.d);
            if (scc == null) switch (o) {
                op("s_cselect_b32"), op("s_cselect_b64"), op("s_bfm_b32"), op("s_bfm_b64"), op("s_mul_i32") => {},
                else => scc = r != 0,
            };
            swrite(wv, in.dst, df.d, r);
            if (scc) |c| wv.scc = c;
        },
        .sop1 => try sop1(w, d, wv, in, next),
        .sopc => {
            const a = try sread(w, wv, in.src[0], in.lit, df.s[0]);
            const b = try sread(w, wv, in.src[1], in.lit, df.s[1]);
            const ia: i32 = @bitCast(@as(u32, @truncate(a)));
            const ib: i32 = @bitCast(@as(u32, @truncate(b)));
            wv.scc = switch (o) {
                op("s_cmp_eq_i32"), op("s_cmp_eq_u32"), op("s_cmp_eq_u64") => a == b,
                op("s_cmp_lg_i32"), op("s_cmp_lg_u32"), op("s_cmp_lg_u64") => a != b,
                op("s_cmp_gt_i32") => ia > ib,
                op("s_cmp_ge_i32") => ia >= ib,
                op("s_cmp_lt_i32") => ia < ib,
                op("s_cmp_le_i32") => ia <= ib,
                op("s_cmp_gt_u32") => a > b,
                op("s_cmp_ge_u32") => a >= b,
                op("s_cmp_lt_u32") => a < b,
                op("s_cmp_le_u32") => a <= b,
                op("s_bitcmp0_b32") => (a >> @intCast(b & 31)) & 1 == 0,
                op("s_bitcmp1_b32") => (a >> @intCast(b & 31)) & 1 == 1,
                op("s_bitcmp0_b64") => (a >> @intCast(b & 63)) & 1 == 0,
                op("s_bitcmp1_b64") => (a >> @intCast(b & 63)) & 1 == 1,
                else => return w.fail(error.Unsupported, "{s}", .{df.name}),
            };
        },
        .sopk => {
            const simm = sext16(in.imm);
            const cur = wv.s[in.dst];
            switch (o) {
                op("s_movk_i32") => wv.s[in.dst] = simm,
                op("s_cmovk_i32") => if (wv.scc) {
                    wv.s[in.dst] = simm;
                },
                op("s_cmpk_eq_i32") => wv.scc = cur == simm,
                op("s_cmpk_lg_i32") => wv.scc = cur != simm,
                op("s_cmpk_gt_i32") => wv.scc = @as(i32, @bitCast(cur)) > @as(i32, @bitCast(simm)),
                op("s_cmpk_ge_i32") => wv.scc = @as(i32, @bitCast(cur)) >= @as(i32, @bitCast(simm)),
                op("s_cmpk_lt_i32") => wv.scc = @as(i32, @bitCast(cur)) < @as(i32, @bitCast(simm)),
                op("s_cmpk_le_i32") => wv.scc = @as(i32, @bitCast(cur)) <= @as(i32, @bitCast(simm)),
                op("s_cmpk_eq_u32") => wv.scc = cur == in.imm,
                op("s_cmpk_lg_u32") => wv.scc = cur != in.imm,
                op("s_cmpk_gt_u32") => wv.scc = cur > in.imm,
                op("s_cmpk_ge_u32") => wv.scc = cur >= in.imm,
                op("s_cmpk_lt_u32") => wv.scc = cur < in.imm,
                op("s_cmpk_le_u32") => wv.scc = cur <= in.imm,
                op("s_addk_i32") => {
                    const t = @addWithOverflow(@as(i32, @bitCast(cur)), @as(i32, @bitCast(simm)));
                    wv.s[in.dst] = @bitCast(t[0]);
                    wv.scc = t[1] != 0;
                },
                op("s_mulk_i32") => wv.s[in.dst] = cur *% simm,
                op("s_getreg_b32") => {
                    const f = hwField(in.imm);
                    const v = if (f.id < wv.hw.len) wv.hw[f.id] else 0;
                    wv.s[in.dst] = @truncate((@as(u64, v) >> f.off) & mask64(f.size));
                },
                op("s_setreg_b32"), op("s_setreg_imm32_b32") => {
                    const f = hwField(in.imm);
                    const x: u64 = if (o == op("s_setreg_b32")) cur else in.lit;
                    if (f.id < wv.hw.len) {
                        const m = mask64(f.size) << f.off;
                        wv.hw[f.id] = @truncate((wv.hw[f.id] & ~m) | (x << f.off & m));
                    }
                },
                else => return w.fail(error.Unsupported, "{s}", .{df.name}),
            }
        },
        .sopp => {
            const rel: i32 = @as(i16, @bitCast(@as(u16, @truncate(in.imm))));
            const t64 = @as(i64, next) + rel;
            if (df.shape == .sopp_branch and (t64 < 0 or t64 >= w.ncode)) return w.fail(error.Fault, "branch to dword {d}, outside the code", .{t64});
            const target: u32 = if (t64 < 0) 0 else @intCast(t64);
            switch (o) {
                op("s_nop"), op("s_sleep"), op("s_setprio"), op("s_icache_inv"), op("s_incperflevel"), op("s_decperflevel"), op("s_ttracedata"), op("s_wakeup"), op("s_setkill"), op("s_sethalt") => {},
                op("s_endpgm"), op("s_endpgm_saved") => wv.done = true,
                op("s_branch") => wv.pc = target,
                op("s_cbranch_scc0") => if (!wv.scc) {
                    wv.pc = target;
                },
                op("s_cbranch_scc1") => if (wv.scc) {
                    wv.pc = target;
                },
                op("s_cbranch_vccz") => if (wv.vcc() == 0) {
                    wv.pc = target;
                },
                op("s_cbranch_vccnz") => if (wv.vcc() != 0) {
                    wv.pc = target;
                },
                op("s_cbranch_execz") => if (wv.exec() == 0) {
                    wv.pc = target;
                },
                op("s_cbranch_execnz") => if (wv.exec() != 0) {
                    wv.pc = target;
                },
                // no debugger is attached
                op("s_cbranch_cdbgsys"), op("s_cbranch_cdbguser"), op("s_cbranch_cdbgsys_or_user"), op("s_cbranch_cdbgsys_and_user") => {},
                op("s_barrier") => wv.barrier = true,
                op("s_waitcnt") => {
                    const vm = in.imm & 15;
                    const lgkm = in.imm >> 8 & 15;
                    if (wv.vm_issued - wv.vm_done > vm) wv.vm_done = wv.vm_issued - vm;
                    if (lgkm == 0) {
                        wv.lgkm_done = wv.lgkm_issued;
                    } else if (wv.smem_last <= wv.lgkm_done and wv.lgkm_issued - wv.lgkm_done > lgkm) {
                        // with SMEM outstanding, only lgkmcnt(0) says which returned
                        wv.lgkm_done = wv.lgkm_issued - lgkm;
                    }
                },
                else => return w.fail(error.Unsupported, "{s}", .{df.name}),
            }
        },
        else => unreachable,
    }
}

fn sop1(w: *Work, d: *const Dispatch, wv: *Wave, in: *const Instr, next: u32) Error!void {
    const df = in.d();
    const o = in.op;
    const a = if (df.s[0] != .none) try sread(w, wv, in.src[0], in.lit, df.s[0]) else 0;
    const bits_: u7 = if (df.s[0].dwords() == 2) 64 else 32;
    var r: u64 = 0;
    var scc: ?bool = null;
    var write = true;
    switch (o) {
        op("s_mov_b32"), op("s_mov_b64") => r = a,
        op("s_cmov_b32"), op("s_cmov_b64") => {
            if (!wv.scc) write = false;
            r = a;
        },
        op("s_not_b32"), op("s_not_b64") => {
            r = ~a & mask(df.d);
            scc = r != 0;
        },
        op("s_wqm_b32"), op("s_wqm_b64") => {
            var i: u7 = 0;
            while (i < bits_) : (i += 4) {
                if ((a >> @intCast(i)) & 15 != 0) r |= @as(u64, 15) << @intCast(i);
            }
            scc = r != 0;
        },
        op("s_brev_b32") => r = @bitReverse(@as(u32, @truncate(a))),
        op("s_brev_b64") => r = @bitReverse(a),
        op("s_bcnt0_i32_b32"), op("s_bcnt0_i32_b64") => {
            r = bits_ - @popCount(a);
            scc = r != 0;
        },
        op("s_bcnt1_i32_b32"), op("s_bcnt1_i32_b64") => {
            r = @popCount(a);
            scc = r != 0;
        },
        op("s_ff0_i32_b32"), op("s_ff0_i32_b64") => {
            const y = ~a & mask64(bits_);
            r = if (y == 0) 0xffff_ffff else @ctz(y);
        },
        op("s_ff1_i32_b32"), op("s_ff1_i32_b64") => r = if (a == 0) 0xffff_ffff else @ctz(a),
        op("s_flbit_i32_b32"), op("s_flbit_i32_b64") => r = if (a == 0) 0xffff_ffff else @clz(a) - (64 - @as(u64, bits_)),
        op("s_flbit_i32"), op("s_flbit_i32_i64") => r = flbitSigned(a, bits_),
        op("s_sext_i32_i8") => r = @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(a))))))),
        op("s_sext_i32_i16") => r = sext16(@truncate(a)),
        op("s_bitset0_b32"), op("s_bitset1_b32"), op("s_bitset0_b64"), op("s_bitset1_b64") => {
            const cur = try sread(w, wv, in.dst, 0, df.d);
            const bit = @as(u64, 1) << @intCast(a & (if (df.d.dwords() == 2) @as(u64, 63) else 31));
            r = if (o == op("s_bitset0_b32") or o == op("s_bitset0_b64")) cur & ~bit else cur | bit;
        },
        op("s_getpc_b64") => r = d.code_va + @as(u64, next) * 4,
        op("s_setpc_b64"), op("s_swappc_b64") => {
            r = d.code_va + @as(u64, next) * 4;
            if (a < d.code_va or (a - d.code_va) & 3 != 0 or (a - d.code_va) / 4 >= w.ncode) return w.fail(error.Fault, "jump to 0x{x}, outside the code", .{a});
            wv.pc = @intCast((a - d.code_va) / 4);
            if (o == op("s_setpc_b64")) write = false;
        },
        op("s_and_saveexec_b64"), op("s_or_saveexec_b64"), op("s_xor_saveexec_b64"), op("s_andn2_saveexec_b64"), op("s_orn2_saveexec_b64"), op("s_nand_saveexec_b64"), op("s_nor_saveexec_b64"), op("s_xnor_saveexec_b64") => {
            const e = wv.exec();
            r = e;
            const ne: u64 = switch (o) {
                op("s_and_saveexec_b64") => a & e,
                op("s_or_saveexec_b64") => a | e,
                op("s_xor_saveexec_b64") => a ^ e,
                op("s_andn2_saveexec_b64") => a & ~e,
                op("s_orn2_saveexec_b64") => a | ~e,
                op("s_nand_saveexec_b64") => ~(a & e),
                op("s_nor_saveexec_b64") => ~(a | e),
                else => ~(a ^ e),
            };
            // the old EXEC goes to the destination first (it may be EXEC)
            swrite(wv, in.dst, .b64, r);
            write = false;
            wv.setExec(ne);
            scc = ne != 0;
        },
        op("s_quadmask_b32"), op("s_quadmask_b64") => {
            var i: u7 = 0;
            while (i < bits_ / 4) : (i += 1) {
                if ((a >> @intCast(i * 4)) & 15 != 0) r |= @as(u64, 1) << @intCast(i);
            }
            scc = r != 0;
        },
        op("s_abs_i32") => {
            r = @abs(@as(i32, @bitCast(@as(u32, @truncate(a)))));
            scc = r != 0;
        },
        else => return w.fail(error.Unsupported, "{s}", .{df.name}),
    }
    if (write) swrite(wv, in.dst, df.d, r & mask(df.d));
    if (scc) |c| wv.scc = c;
}

// ── SMEM ────────────────────────────────────────────────────────────────────

fn readMem(w: *Work, mem: *const Memory, va: u64, out: []u8, stats: *Stats) Error!void {
    const m = mem.find(va, out.len) orelse return w.fail(error.Fault, "read of {d} bytes at 0x{x}: no memory there", .{ out.len, va });
    @memcpy(out, m);
    stats.bytes_read += out.len;
}

fn writeMem(w: *Work, mem: *const Memory, va: u64, data: []const u8, stats: *Stats) Error!void {
    const m = mem.find(va, data.len) orelse return w.fail(error.Fault, "write of {d} bytes at 0x{x}: no memory there", .{ data.len, va });
    @memcpy(m, data);
    stats.bytes_written += data.len;
}

fn smem(w: *Work, mem: *const Memory, wv: *Wave, in: *const Instr, stats: *Stats) Error!void {
    const df = in.d();
    switch (df.shape) {
        .smem_none => return,
        .smem_time => {
            wv.lgkm_issued += 1;
            wv.smem_last = wv.lgkm_issued;
            swrite(wv, in.dst, .b64, w.steps);
            markPending(wv, in.dst, 2, false, true);
            return;
        },
        else => {},
    }
    const off: u64 = if (in.soff_imm) in.imm else wv.s[in.src[1]];
    const n = df.d.dwords();
    var base: u64 = 0;
    var limit: u64 = std.math.maxInt(u64);
    if (df.s[0].dwords() == 4) {
        const rsrc = dispatch.BufferResource.fromWords(wv.s[in.src[0]..][0..4].*);
        base = rsrc.base;
        limit = rsrc.num_records;
    } else {
        base = (@as(u64, wv.s[in.src[0] + 1]) << 32 | wv.s[in.src[0]]) & 0xffff_ffff_ffff;
    }
    const addr = (base + off) & ~@as(u64, 3);
    for (0..n) |i| {
        const byte = off + 4 * i;
        const va = addr + 4 * i;
        if (df.shape == .smem_load) {
            var x = [4]u8{ 0, 0, 0, 0 };
            if (byte + 4 <= limit) try readMem(w, mem, va, &x, stats);
            if (in.dst + i < 128) wv.s[in.dst + i] = std.mem.readInt(u32, &x, .little);
        } else {
            var x: [4]u8 = undefined;
            std.mem.writeInt(u32, &x, wv.s[in.dst + i], .little);
            if (byte + 4 <= limit) try writeMem(w, mem, va, &x, stats);
        }
    }
    wv.lgkm_issued += 1;
    wv.smem_last = wv.lgkm_issued;
    if (df.shape == .smem_load) markPending(wv, in.dst, n, false, true);
}

// ── VALU ────────────────────────────────────────────────────────────────────

fn f32of(x: u64) f32 {
    return @bitCast(@as(u32, @truncate(x)));
}
fn f16of(x: u64) f16 {
    return @bitCast(@as(u16, @truncate(x)));
}
fn f64of(x: u64) f64 {
    return @bitCast(x);
}
fn b32(f: f32) u64 {
    return @as(u32, @bitCast(f));
}
fn b16(f: f16) u64 {
    return @as(u16, @bitCast(f));
}
fn b64(f: f64) u64 {
    return @bitCast(f);
}

fn flush32(f: f32) f32 {
    if (f != 0 and @abs(f) < std.math.floatMin(f32)) return if (std.math.signbit(f)) -0.0 else 0.0;
    return f;
}

fn rndne(comptime T: type, x: T) T {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) {
        const half = r / 2;
        if (half != @trunc(half)) return r - std.math.copysign(@as(T, 1), x);
    }
    return r;
}

fn fract(comptime T: type, x: T) T {
    if (std.math.isInf(x)) return std.math.nan(T);
    const r = x - @floor(x);
    const below_one = std.math.nextAfter(T, 1, 0);
    return @min(r, below_one);
}

fn cvtI32(f: f64) u64 {
    if (std.math.isNan(f)) return 0;
    if (f >= 2147483647.0) return 0x7fff_ffff;
    if (f <= -2147483648.0) return 0x8000_0000;
    return @as(u32, @bitCast(@as(i32, @intFromFloat(@trunc(f)))));
}

fn cvtU32(f: f64) u64 {
    if (std.math.isNan(f) or f <= 0) return 0;
    if (f >= 4294967295.0) return 0xffff_ffff;
    return @as(u32, @intFromFloat(@trunc(f)));
}

fn cvtI16(f: f32) u64 {
    if (std.math.isNan(f)) return 0;
    if (f >= 32767.0) return 0x7fff;
    if (f <= -32768.0) return 0x8000;
    return @as(u16, @bitCast(@as(i16, @intFromFloat(@trunc(f)))));
}

fn cvtU16(f: f32) u64 {
    if (std.math.isNan(f) or f <= 0) return 0;
    if (f >= 65535.0) return 0xffff;
    return @as(u16, @intFromFloat(@trunc(f)));
}

fn f16rtz(x: f32) u16 {
    if (std.math.isNan(x)) return 0x7e00;
    var h: u16 = @bitCast(@as(f16, @floatCast(x)));
    const back: f32 = @floatCast(@as(f16, @bitCast(h)));
    if (@abs(back) > @abs(x)) h -= 1;
    return h;
}

fn frexpMant(comptime T: type, x: T) T {
    if (std.math.isNan(x) or std.math.isInf(x) or x == 0) return x;
    return std.math.frexp(x).significand;
}
fn frexpExp(comptime T: type, x: T) i32 {
    if (std.math.isNan(x) or std.math.isInf(x) or x == 0) return 0;
    return std.math.frexp(x).exponent;
}

/// V_MIN_F32 / V_MAX_F32 as the GCN3 guide's pseudocode has them: with
/// IEEE mode a signaling NaN comes out quieted; otherwise a NaN operand
/// gives the other one; between equal operands (-0 and +0 included) the
/// second.
fn minMax(ieee: bool, a: f32, b: f32, want_max: bool) f32 {
    const ab: u32 = @bitCast(a);
    const bb: u32 = @bitCast(b);
    const a_nan = std.math.isNan(a);
    const b_nan = std.math.isNan(b);
    if (ieee) {
        if (a_nan and ab & 0x0040_0000 == 0) return @bitCast(ab | 0x0040_0000);
        if (b_nan and bb & 0x0040_0000 == 0) return @bitCast(bb | 0x0040_0000);
    }
    if (a_nan) return b;
    if (b_nan) return a;
    if (want_max) return if (a > b) a else b;
    return if (a < b) a else b;
}

fn med3(comptime T: type, a: T, b: T, c: T) T {
    return @max(@min(a, b), @min(@max(a, b), c));
}

fn sadU8(a: u32, b: u32) u32 {
    var s: u32 = 0;
    for (0..4) |i| {
        const x: i32 = @intCast(a >> @intCast(8 * i) & 0xff);
        const y: i32 = @intCast(b >> @intCast(8 * i) & 0xff);
        s += @abs(x - y);
    }
    return s;
}

fn perm(a: u32, b: u32, sel: u32) u32 {
    const data = @as(u64, a) << 32 | b;
    var r: u32 = 0;
    for (0..4) |i| {
        const s_ = sel >> @intCast(8 * i) & 0xff;
        const byte: u32 = switch (s_) {
            0...7 => @truncate(data >> @intCast(8 * s_) & 0xff),
            8 => if (data >> 15 & 1 != 0) 0xff else 0,
            9 => if (data >> 31 & 1 != 0) 0xff else 0,
            10 => if (data >> 47 & 1 != 0) 0xff else 0,
            11 => if (data >> 63 & 1 != 0) 0xff else 0,
            12 => 0,
            else => 0xff,
        };
        r |= byte << @intCast(8 * i);
    }
    return r;
}

fn sext24(x: u32) i64 {
    return @as(i32, @bitCast(x << 8)) >> 8;
}

/// One lane of the lanewise VALU ops; null: not here.
fn lane1(w: *const Work, o: gcn3.Op, a: u64, b: u64, c: u64, old: u64, ln: u32) ?u64 {
    const a32: u32 = @truncate(a);
    const b32_: u32 = @truncate(b);
    const c32: u32 = @truncate(c);
    const ia: i32 = @bitCast(a32);
    const ib: i32 = @bitCast(b32_);
    const ic: i32 = @bitCast(c32);
    const ftz = w.ftz32;
    const fa = if (ftz) flush32(f32of(a)) else f32of(a);
    const fb = if (ftz) flush32(f32of(b)) else f32of(b);
    const fc = if (ftz) flush32(f32of(c)) else f32of(c);
    const ha = f16of(a);
    const hb = f16of(b);
    const hc = f16of(c);
    const da = f64of(a);
    const db = f64of(b);
    const dc = f64of(c);
    const ua16: u16 = @truncate(a);
    const ub16: u16 = @truncate(b);
    const ia16: i16 = @bitCast(ua16);
    const ib16: i16 = @bitCast(ub16);
    const F = struct {
        fn f(x: f32, z: bool) u64 {
            return b32(if (z) flush32(x) else x);
        }
    }.f;
    return switch (o) {
        // moves and integer ALU
        op("v_mov_b32") => a32,
        op("v_not_b32") => ~a32,
        op("v_bfrev_b32") => @bitReverse(a32),
        op("v_ffbh_u32") => if (a32 == 0) 0xffff_ffff else @clz(a32),
        op("v_ffbl_b32") => if (a32 == 0) 0xffff_ffff else @ctz(a32),
        op("v_ffbh_i32") => flbitSigned(a32, 32),
        op("v_and_b32") => a32 & b32_,
        op("v_or_b32") => a32 | b32_,
        op("v_xor_b32") => a32 ^ b32_,
        op("v_lshlrev_b32") => b32_ << @intCast(a32 & 31),
        op("v_lshrrev_b32") => b32_ >> @intCast(a32 & 31),
        op("v_ashrrev_i32") => @as(u32, @bitCast(ib >> @intCast(a32 & 31))),
        op("v_min_i32") => @as(u32, @bitCast(@min(ia, ib))),
        op("v_max_i32") => @as(u32, @bitCast(@max(ia, ib))),
        op("v_min_u32") => @min(a32, b32_),
        op("v_max_u32") => @max(a32, b32_),
        op("v_mul_i32_i24") => @as(u32, @truncate(@as(u64, @bitCast(sext24(a32) * sext24(b32_))))),
        op("v_mul_hi_i32_i24") => @as(u32, @truncate(@as(u64, @bitCast(sext24(a32) * sext24(b32_))) >> 32)),
        op("v_mul_u32_u24") => @as(u32, @truncate((@as(u64, a32 & 0xffffff) * (b32_ & 0xffffff)))),
        op("v_mul_hi_u32_u24") => @as(u32, @truncate((@as(u64, a32 & 0xffffff) * (b32_ & 0xffffff)) >> 32)),
        op("v_mad_i32_i24") => @as(u32, @truncate(@as(u64, @bitCast(sext24(a32) * sext24(b32_) + ic)))),
        op("v_mad_u32_u24") => @as(u32, @truncate(@as(u64, a32 & 0xffffff) * (b32_ & 0xffffff) + c32)),
        op("v_mul_lo_u32") => a32 *% b32_,
        op("v_mul_hi_u32") => @as(u32, @truncate((@as(u64, a32) * b32_) >> 32)),
        op("v_mul_hi_i32") => @as(u32, @truncate(@as(u64, @bitCast(@as(i64, ia) * ib)) >> 32)),
        op("v_bfe_u32") => bfe(a32, @intCast(b32_ & 31), @intCast(c32 & 31), false, 32),
        op("v_bfe_i32") => bfe(a32, @intCast(b32_ & 31), @intCast(c32 & 31), true, 32) & 0xffff_ffff,
        op("v_bfi_b32") => (a32 & b32_) | (~a32 & c32),
        op("v_bfm_b32") => @as(u32, @truncate(((@as(u64, 1) << @intCast(a32 & 31)) - 1) << @intCast(b32_ & 31))),
        op("v_alignbit_b32") => @as(u32, @truncate((@as(u64, a32) << 32 | b32_) >> @intCast(c32 & 31))),
        op("v_alignbyte_b32") => @as(u32, @truncate((@as(u64, a32) << 32 | b32_) >> @intCast(8 * (c32 & 3)))),
        op("v_bcnt_u32_b32") => @popCount(a32) +% b32_,
        op("v_mbcnt_lo_u32_b32") => blk: {
            const m: u32 = if (ln >= 32) 0xffff_ffff else (@as(u32, 1) << @intCast(ln)) - 1;
            break :blk @popCount(a32 & m) +% b32_;
        },
        op("v_mbcnt_hi_u32_b32") => blk: {
            const m: u32 = if (ln < 32) 0 else (@as(u32, 1) << @intCast(ln - 32)) - 1;
            break :blk @popCount(a32 & m) +% b32_;
        },
        op("v_min3_i32") => @as(u32, @bitCast(@min(ia, ib, ic))),
        op("v_max3_i32") => @as(u32, @bitCast(@max(ia, ib, ic))),
        op("v_med3_i32") => @as(u32, @bitCast(med3(i32, ia, ib, ic))),
        op("v_min3_u32") => @min(a32, b32_, c32),
        op("v_max3_u32") => @max(a32, b32_, c32),
        op("v_med3_u32") => med3(u32, a32, b32_, c32),
        op("v_sad_u8") => sadU8(a32, b32_) +% c32,
        op("v_sad_hi_u8") => (sadU8(a32, b32_) << 16) +% c32,
        op("v_sad_u16") => @as(u32, @abs(@as(i32, @intCast(a32 & 0xffff)) - @as(i32, @intCast(b32_ & 0xffff)))) + @abs(@as(i32, @intCast(a32 >> 16)) - @as(i32, @intCast(b32_ >> 16))) +% c32,
        op("v_sad_u32") => @as(u32, @truncate(@abs(@as(i64, a32) - @as(i64, b32_)))) +% c32,
        op("v_perm_b32") => perm(a32, b32_, c32),
        op("v_lerp_u8") => blk: {
            var r: u32 = 0;
            for (0..4) |i| {
                const sh: u5 = @intCast(8 * i);
                const x = (a32 >> sh & 0xff) + (b32_ >> sh & 0xff) + (c32 >> sh & 1);
                r |= (x >> 1 & 0xff) << sh;
            }
            break :blk r;
        },
        op("v_cvt_pk_u16_u32") => (a32 & 0xffff) | (b32_ & 0xffff) << 16,
        op("v_cvt_pk_i16_i32") => blk: {
            const x: i32 = std.math.clamp(ia, -32768, 32767);
            const y: i32 = std.math.clamp(ib, -32768, 32767);
            break :blk @as(u32, @as(u16, @bitCast(@as(i16, @intCast(x))))) | @as(u32, @as(u16, @bitCast(@as(i16, @intCast(y))))) << 16;
        },
        op("v_lshlrev_b64") => b << @intCast(a32 & 63),
        op("v_lshrrev_b64") => b >> @intCast(a32 & 63),
        op("v_ashrrev_i64") => @bitCast(@as(i64, @bitCast(b)) >> @intCast(a32 & 63)),
        op("v_cvt_f32_ubyte0") => b32(@floatFromInt(a32 & 0xff)),
        op("v_cvt_f32_ubyte1") => b32(@floatFromInt(a32 >> 8 & 0xff)),
        op("v_cvt_f32_ubyte2") => b32(@floatFromInt(a32 >> 16 & 0xff)),
        op("v_cvt_f32_ubyte3") => b32(@floatFromInt(a32 >> 24)),
        // f32
        op("v_add_f32") => F(fa + fb, ftz),
        op("v_sub_f32") => F(fa - fb, ftz),
        op("v_subrev_f32") => F(fb - fa, ftz),
        op("v_mul_f32") => F(fa * fb, ftz),
        op("v_mul_legacy_f32") => if (fa == 0 or fb == 0) 0 else F(fa * fb, ftz),
        op("v_min_f32") => F(minMax(w.ieee, fa, fb, false), ftz),
        op("v_max_f32") => F(minMax(w.ieee, fa, fb, true), ftz),
        op("v_min3_f32") => F(@min(fa, fb, fc), ftz),
        op("v_max3_f32") => F(@max(fa, fb, fc), ftz),
        op("v_med3_f32") => F(med3(f32, fa, fb, fc), ftz),
        // v_mad/v_mac never keep f32 denormals on gfx8
        op("v_mac_f32") => b32(flush32(flush32(flush32(fa) * flush32(fb)) + flush32(f32of(old)))),
        op("v_mad_f32"), op("v_madmk_f32"), op("v_madak_f32") => b32(flush32(flush32(flush32(fa) * flush32(fb)) + flush32(fc))),
        op("v_mad_legacy_f32") => b32(flush32((if (fa == 0 or fb == 0) 0 else flush32(fa * fb)) + flush32(fc))),
        op("v_fma_f32") => F(@mulAdd(f32, fa, fb, fc), ftz),
        op("v_ldexp_f32") => F(std.math.ldexp(fa, ib), ftz),
        op("v_cvt_f32_i32") => b32(@floatFromInt(ia)),
        op("v_cvt_f32_u32") => b32(@floatFromInt(a32)),
        op("v_cvt_i32_f32") => cvtI32(fa),
        op("v_cvt_u32_f32") => cvtU32(fa),
        op("v_cvt_rpi_i32_f32") => cvtI32(@floor(@as(f64, fa) + 0.5)),
        op("v_cvt_flr_i32_f32") => cvtI32(@floor(fa)),
        op("v_cvt_f16_f32") => b16(@floatCast(fa)),
        op("v_cvt_f32_f16") => F(@floatCast(ha), ftz),
        op("v_cvt_pkrtz_f16_f32") => @as(u32, f16rtz(fa)) | @as(u32, f16rtz(fb)) << 16,
        op("v_cvt_f32_f64") => F(@floatCast(da), ftz),
        op("v_cvt_f64_f32") => b64(fa),
        op("v_fract_f32") => F(fract(f32, fa), ftz),
        op("v_trunc_f32") => F(@trunc(fa), ftz),
        op("v_ceil_f32") => F(@ceil(fa), ftz),
        op("v_rndne_f32") => F(rndne(f32, fa), ftz),
        op("v_floor_f32") => F(@floor(fa), ftz),
        op("v_exp_f32"), op("v_exp_legacy_f32") => F(@exp2(fa), ftz),
        op("v_log_f32"), op("v_log_legacy_f32") => F(@log2(fa), ftz),
        op("v_rcp_f32"), op("v_rcp_iflag_f32") => F(1.0 / fa, ftz),
        op("v_rsq_f32") => F(1.0 / @sqrt(fa), ftz),
        op("v_sqrt_f32") => F(@sqrt(fa), ftz),
        op("v_sin_f32") => F(@sin(fa * 2.0 * std.math.pi), ftz),
        op("v_cos_f32") => F(@cos(fa * 2.0 * std.math.pi), ftz),
        op("v_frexp_mant_f32") => F(frexpMant(f32, fa), ftz),
        op("v_frexp_exp_i32_f32") => @as(u32, @bitCast(frexpExp(f32, fa))),
        // f64
        op("v_add_f64") => b64(da + db),
        op("v_mul_f64") => b64(da * db),
        op("v_min_f64") => b64(@min(da, db)),
        op("v_max_f64") => b64(@max(da, db)),
        op("v_fma_f64") => b64(@mulAdd(f64, da, db, dc)),
        op("v_ldexp_f64") => b64(std.math.ldexp(da, ib)),
        op("v_cvt_i32_f64") => cvtI32(da),
        op("v_cvt_u32_f64") => cvtU32(da),
        op("v_cvt_f64_i32") => b64(@floatFromInt(ia)),
        op("v_cvt_f64_u32") => b64(@floatFromInt(a32)),
        op("v_trunc_f64") => b64(@trunc(da)),
        op("v_ceil_f64") => b64(@ceil(da)),
        op("v_rndne_f64") => b64(rndne(f64, da)),
        op("v_floor_f64") => b64(@floor(da)),
        op("v_fract_f64") => b64(fract(f64, da)),
        op("v_rcp_f64") => b64(1.0 / da),
        op("v_rsq_f64") => b64(1.0 / @sqrt(da)),
        op("v_sqrt_f64") => b64(@sqrt(da)),
        op("v_frexp_mant_f64") => b64(frexpMant(f64, da)),
        op("v_frexp_exp_i32_f64") => @as(u32, @bitCast(frexpExp(f64, da))),
        // f16 (gfx8 clears the high half of the VGPR)
        op("v_add_f16") => b16(ha + hb),
        op("v_sub_f16") => b16(ha - hb),
        op("v_subrev_f16") => b16(hb - ha),
        op("v_mul_f16") => b16(ha * hb),
        op("v_mac_f16") => b16(ha * hb + f16of(old)),
        op("v_mad_f16"), op("v_madmk_f16"), op("v_madak_f16") => b16(ha * hb + hc),
        op("v_fma_f16") => b16(@floatCast(@mulAdd(f32, ha, hb, hc))),
        op("v_max_f16") => b16(@max(ha, hb)),
        op("v_min_f16") => b16(@min(ha, hb)),
        op("v_ldexp_f16") => b16(std.math.ldexp(ha, ib16)),
        op("v_cvt_f16_u16") => b16(@floatFromInt(ua16)),
        op("v_cvt_f16_i16") => b16(@floatFromInt(ia16)),
        op("v_cvt_u16_f16") => cvtU16(ha),
        op("v_cvt_i16_f16") => cvtI16(ha),
        op("v_rcp_f16") => b16(1.0 / ha),
        op("v_sqrt_f16") => b16(@sqrt(ha)),
        op("v_rsq_f16") => b16(@floatCast(1.0 / @sqrt(@as(f32, ha)))),
        op("v_log_f16") => b16(@floatCast(@log2(@as(f32, ha)))),
        op("v_exp_f16") => b16(@floatCast(@exp2(@as(f32, ha)))),
        op("v_floor_f16") => b16(@floor(ha)),
        op("v_ceil_f16") => b16(@ceil(ha)),
        op("v_trunc_f16") => b16(@trunc(ha)),
        op("v_rndne_f16") => b16(rndne(f16, ha)),
        op("v_fract_f16") => b16(fract(f16, ha)),
        op("v_sin_f16") => b16(@floatCast(@sin(@as(f32, ha) * 2.0 * std.math.pi))),
        op("v_cos_f16") => b16(@floatCast(@cos(@as(f32, ha) * 2.0 * std.math.pi))),
        op("v_frexp_mant_f16") => b16(frexpMant(f16, ha)),
        op("v_frexp_exp_i16_f16") => @as(u16, @bitCast(@as(i16, @intCast(frexpExp(f16, ha))))),
        // 16-bit integers
        op("v_add_u16") => ua16 +% ub16,
        op("v_sub_u16") => ua16 -% ub16,
        op("v_subrev_u16") => ub16 -% ua16,
        op("v_mul_lo_u16") => ua16 *% ub16,
        op("v_lshlrev_b16") => ub16 << @intCast(ua16 & 15),
        op("v_lshrrev_b16") => ub16 >> @intCast(ua16 & 15),
        op("v_ashrrev_i16") => @as(u16, @bitCast(ib16 >> @intCast(ua16 & 15))),
        op("v_max_u16") => @max(ua16, ub16),
        op("v_max_i16") => @as(u16, @bitCast(@max(ia16, ib16))),
        op("v_min_u16") => @min(ua16, ub16),
        op("v_min_i16") => @as(u16, @bitCast(@min(ia16, ib16))),
        op("v_mad_u16") => ua16 *% ub16 +% @as(u16, @truncate(c)),
        op("v_mad_i16") => @as(u16, @bitCast(ia16 *% ib16 +% @as(i16, @bitCast(@as(u16, @truncate(c)))))),
        else => null,
    };
}

fn applyMods(x: u64, t: Ty, neg: bool, abs: bool) u64 {
    const sign: u64 = switch (t) {
        .f16 => 1 << 15,
        .f32 => 1 << 31,
        .f64 => 1 << 63,
        else => return x,
    };
    var r = x;
    if (abs) r &= ~sign;
    if (neg) r ^= sign;
    return r;
}

fn outMods(x: u64, t: Ty, clamp: bool, omod: u2) u64 {
    if (!clamp and omod == 0) return x;
    const k: f64 = switch (omod) {
        1 => 2,
        2 => 4,
        3 => 0.5,
        else => 1,
    };
    switch (t) {
        .f32 => {
            var f = f32of(x) * @as(f32, @floatCast(k));
            if (clamp) f = if (std.math.isNan(f)) 0 else std.math.clamp(f, 0, 1);
            return b32(f);
        },
        .f16 => {
            var f = f16of(x) * @as(f16, @floatCast(k));
            if (clamp) f = if (std.math.isNan(f)) 0 else std.math.clamp(f, 0, 1);
            return b16(f);
        },
        .f64 => {
            var f = f64of(x) * k;
            if (clamp) f = if (std.math.isNan(f)) 0 else std.math.clamp(f, 0, 1);
            return b64(f);
        },
        else => return x,
    }
}

/// An SDWA select: the byte or word `sel` names, zero- or sign-extended.
fn sdwaSrc(x: u32, sel: u3, sext: bool) u32 {
    const shift: u5, const width: u6 = switch (sel) {
        0...3 => .{ @as(u5, sel) * 8, 8 },
        4, 5 => .{ @as(u5, sel - 4) * 16, 16 },
        else => return x,
    };
    const f = (x >> shift) & ((@as(u32, 1) << @intCast(width)) - 1);
    if (sext and (f >> @intCast(width - 1)) & 1 != 0) return f | ~((@as(u32, 1) << @intCast(width)) - 1);
    return f;
}

/// An SDWA result into its byte or word of `old`: the other bits zero,
/// sign-extended above it (UNUSED_SEXT), or kept (UNUSED_PRESERVE).
fn sdwaDst(x: u32, sel: u3, unused: u2, old: u32) u32 {
    const shift: u5, const width: u6 = switch (sel) {
        0...3 => .{ @as(u5, sel) * 8, 8 },
        4, 5 => .{ @as(u5, sel - 4) * 16, 16 },
        else => return x,
    };
    const field = ((@as(u32, 1) << @intCast(width)) - 1) << shift;
    const v = (x << shift) & field;
    switch (unused) {
        2 => return (old & ~field) | v,
        1 => {
            const top = @as(u6, shift) + width;
            if (top < 32 and (x >> @intCast(width - 1)) & 1 != 0) return v | ~((@as(u32, 1) << @intCast(top)) - 1);
            return v;
        },
        else => return v,
    }
}

/// A 32-bit (or narrower) VALU result into its VGPR, through the SDWA
/// destination select when the instruction has one.
fn vwrite32(wv: *Wave, in: *const Instr, ln: usize, x: u32) void {
    const r = in.dst - gcn3.VGPR0;
    wv.v[r][ln] = if (in.sdwa) sdwaDst(x, in.dst_sel, in.dst_unused, wv.v[r][ln]) else x;
}

fn vsrc(w: *Work, wv: *const Wave, in: *const Instr, i: usize, t: Ty, ln: usize) Error!u64 {
    const code = in.src[i];
    var x: u64 = 0;
    if (code >= gcn3.VGPR0) {
        const r = code - gcn3.VGPR0;
        x = wv.v[r][ln];
        if (in.sdwa and i < 2) x = sdwaSrc(@truncate(x), in.sel[i], in.sext >> @intCast(i) & 1 != 0);
        if (t.dwords() == 2) x |= @as(u64, wv.v[r + 1][ln]) << 32;
        x &= mask(t);
    } else x = try sread(w, wv, code, in.lit, t);
    return applyMods(x, t, in.neg >> @intCast(i) & 1 != 0, in.abs >> @intCast(i) & 1 != 0);
}

fn vwrite(wv: *Wave, code: u16, t: Ty, ln: usize, x: u64) void {
    const r = code - gcn3.VGPR0;
    wv.v[r][ln] = @truncate(x);
    if (t.dwords() == 2) wv.v[r + 1][ln] = @truncate(x >> 32);
}

fn fcmp(cond: u32, a: f64, b: f64) bool {
    const un = std.math.isNan(a) or std.math.isNan(b);
    return switch (cond) {
        0 => false,
        1 => a < b,
        2 => a == b,
        3 => a <= b,
        4 => a > b,
        5 => a < b or a > b,
        6 => a >= b,
        7 => !un,
        8 => un,
        9 => !(a >= b),
        10 => !(a < b or a > b),
        11 => !(a > b),
        12 => !(a <= b),
        13 => !(a == b),
        14 => !(a < b),
        else => true,
    };
}

fn icmp(comptime T: type, cond: u32, a: T, b: T) bool {
    return switch (cond) {
        0 => false,
        1 => a < b,
        2 => a == b,
        3 => a <= b,
        4 => a > b,
        5 => a != b,
        6 => a >= b,
        else => true,
    };
}

fn class(x: u64, t: Ty, m: u32) bool {
    const f: f64 = switch (t) {
        .f16 => f16of(x),
        .f32 => f32of(x),
        else => f64of(x),
    };
    const neg = std.math.signbit(f);
    const sub = switch (t) {
        .f16 => @abs(f16of(x)) < std.math.floatMin(f16) and f != 0,
        .f32 => @abs(f32of(x)) < std.math.floatMin(f32) and f != 0,
        else => @abs(f) < std.math.floatMin(f64) and f != 0,
    };
    const bit: u5 = if (std.math.isNan(f)) blk: {
        const quiet = switch (t) {
            .f16 => x >> 9 & 1,
            .f32 => x >> 22 & 1,
            else => x >> 51 & 1,
        };
        break :blk if (quiet != 0) 1 else 0;
    } else if (std.math.isInf(f)) (if (neg) 2 else 9) else if (f == 0) (if (neg) 5 else 6) else if (sub) (if (neg) 4 else 7) else (if (neg) 3 else 8);
    return m >> bit & 1 != 0;
}

fn valu(w: *Work, wv: *Wave, in: *const Instr, stats: *Stats) Error!void {
    const df = in.d();
    const o = in.op;
    const exec = wv.exec();
    const active = @popCount(exec);
    stats.lane_ops += active;
    switch (df.shape) {
        .vop_none => {},
        .vopc => {
            var res: u64 = 0;
            const code = df.code;
            for (0..LANES) |ln| {
                if (exec >> @intCast(ln) & 1 == 0) continue;
                const a = try vsrc(w, wv, in, 0, df.s[0], ln);
                const b = try vsrc(w, wv, in, 1, df.s[1], ln);
                const t = df.s[0];
                const hit = if (code < 0x20) class(a, t, @truncate(b)) else if (code < 0x80) switch (t) {
                    .f16 => fcmp(code & 15, f16of(a), f16of(b)),
                    // (f32 compares see flushed inputs in flush mode)
                    .f32 => if (w.ftz32) fcmp(code & 15, flush32(f32of(a)), flush32(f32of(b))) else fcmp(code & 15, f32of(a), f32of(b)),
                    else => fcmp(code & 15, f64of(a), f64of(b)),
                } else blk: {
                    const unsigned = code & 8 != 0;
                    const cond = code & 7;
                    break :blk switch (t) {
                        .b16 => if (unsigned) icmp(u16, cond, @truncate(a), @truncate(b)) else icmp(i16, cond, @bitCast(@as(u16, @truncate(a))), @bitCast(@as(u16, @truncate(b)))),
                        .b32 => if (unsigned) icmp(u32, cond, @truncate(a), @truncate(b)) else icmp(i32, cond, @bitCast(@as(u32, @truncate(a))), @bitCast(@as(u32, @truncate(b)))),
                        else => if (unsigned) icmp(u64, cond, a, b) else icmp(i64, cond, @bitCast(a), @bitCast(b)),
                    };
                };
                if (hit) res |= @as(u64, 1) << @intCast(ln);
            }
            swrite(wv, in.sdst, .b64, res);
            const cmpx = if (code < 0x20) code & 1 != 0 else if (code < 0x80) code & 0x10 != 0 else code & 0x10 != 0;
            if (cmpx) wv.setExec(res);
        },
        .vop_carry, .vop_carry_in => {
            var carry: u64 = 0;
            const cin_mask = if (df.shape == .vop_carry_in) try sread(w, wv, in.src[2], 0, .b64) else 0;
            for (0..LANES) |ln| {
                if (exec >> @intCast(ln) & 1 == 0) continue;
                const a = try vsrc(w, wv, in, 0, .b32, ln);
                const b = try vsrc(w, wv, in, 1, .b32, ln);
                const cin: u64 = cin_mask >> @intCast(ln) & 1;
                var r: u64 = 0;
                var co = false;
                switch (o) {
                    op("v_add_u32"), op("v_addc_u32") => {
                        r = a + b + cin;
                        co = r >> 32 != 0;
                    },
                    op("v_sub_u32"), op("v_subb_u32") => {
                        r = a -% b -% cin;
                        co = b + cin > a;
                    },
                    else => {
                        r = b -% a -% cin;
                        co = a + cin > b;
                    },
                }
                if (co) carry |= @as(u64, 1) << @intCast(ln);
                vwrite32(wv, in, ln, @truncate(r));
            }
            swrite(wv, in.sdst, .b64, carry);
        },
        .vop_cndmask => {
            const m = try sread(w, wv, in.src[2], 0, .b64);
            for (0..LANES) |ln| {
                if (exec >> @intCast(ln) & 1 == 0) continue;
                const a = try vsrc(w, wv, in, 0, .b32, ln);
                const b = try vsrc(w, wv, in, 1, .b32, ln);
                vwrite32(wv, in, ln, @truncate(if (m >> @intCast(ln) & 1 != 0) b else a));
            }
        },
        .vop_sdst => {
            var ln: usize = 0;
            if (o == op("v_readfirstlane_b32")) {
                ln = if (exec == 0) 0 else @ctz(exec);
            } else {
                ln = @intCast((try sread(w, wv, in.src[1], 0, .b32)) & 63);
            }
            const x = try vsrc(w, wv, in, 0, .b32, ln);
            swrite(wv, in.dst, .b32, x);
        },
        .vop3b => {
            if (o != op("v_mad_u64_u32") and o != op("v_mad_i64_i32")) return w.fail(error.Unsupported, "{s}", .{df.name});
            var carry: u64 = 0;
            for (0..LANES) |ln| {
                if (exec >> @intCast(ln) & 1 == 0) continue;
                const a = try vsrc(w, wv, in, 0, .b32, ln);
                const b = try vsrc(w, wv, in, 1, .b32, ln);
                const c = try vsrc(w, wv, in, 2, .b64, ln);
                var r: u64 = 0;
                var co = false;
                if (o == op("v_mad_u64_u32")) {
                    const t = @as(u128, a) * b + c;
                    r = @truncate(t);
                    co = t >> 64 != 0;
                } else {
                    const t = @as(i128, @as(i32, @bitCast(@as(u32, @truncate(a))))) * @as(i32, @bitCast(@as(u32, @truncate(b)))) + @as(i64, @bitCast(c));
                    r = @bitCast(@as(i64, @truncate(t)));
                    co = t > std.math.maxInt(i64) or t < std.math.minInt(i64);
                }
                if (co) carry |= @as(u64, 1) << @intCast(ln);
                vwrite(wv, in.dst, .b64, ln, r);
            }
            swrite(wv, in.sdst, .b64, carry);
        },
        .vop, .vop_madmk, .vop_madak => {
            if (o == op("v_writelane_b32")) {
                const x = try sread(w, wv, in.src[0], in.lit, .b32);
                const ln: usize = @intCast((try sread(w, wv, in.src[1], in.lit, .b32)) & 63);
                wv.v[in.dst - gcn3.VGPR0][ln] = @truncate(x);
                return;
            }
            for (df.s) |t| {
                if (t.dwords() > 2) return w.fail(error.Unsupported, "{s}", .{df.name});
            }
            if (df.d.dwords() > 2) return w.fail(error.Unsupported, "{s}", .{df.name});
            for (0..LANES) |ln| {
                if (exec >> @intCast(ln) & 1 == 0) continue;
                var a: u64 = 0;
                var b: u64 = 0;
                var c: u64 = 0;
                if (df.s[0] != .none) a = try vsrc(w, wv, in, 0, df.s[0], ln);
                switch (df.shape) {
                    .vop_madmk => {
                        b = in.lit;
                        c = try vsrc(w, wv, in, 1, df.s[1], ln);
                    },
                    .vop_madak => {
                        b = try vsrc(w, wv, in, 1, df.s[1], ln);
                        c = in.lit;
                    },
                    else => {
                        if (df.s[1] != .none) b = try vsrc(w, wv, in, 1, df.s[1], ln);
                        if (df.s[2] != .none) c = try vsrc(w, wv, in, 2, df.s[2], ln);
                    },
                }
                const dr = in.dst - gcn3.VGPR0;
                var old: u64 = wv.v[dr][ln];
                if (df.d.dwords() == 2) old |= @as(u64, wv.v[dr + 1][ln]) << 32;
                const r = lane1(w, o, a, b, c, old, @intCast(ln)) orelse return w.fail(error.Unsupported, "{s}", .{df.name});
                const res = outMods(r & mask(df.d), df.d, in.clamp, in.omod);
                if (in.sdwa) vwrite32(wv, in, ln, @truncate(res)) else vwrite(wv, in.dst, df.d, ln, res);
            }
        },
        else => return w.fail(error.Unsupported, "{s}", .{df.name}),
    }
}

// ── LDS ─────────────────────────────────────────────────────────────────────

fn ldsCheck(w: *Work, wv: *const Wave, addr: u64, n: usize) Error!usize {
    const m0 = wv.s[gcn3.M0];
    if (addr + n > m0) return w.fail(error.Hazard, "LDS address 0x{x} past M0 (0x{x}): gfx8 limits DS accesses to M0, set it to -1", .{ addr, m0 });
    if (addr + n > w.lds_limit) return w.fail(error.Fault, "LDS address 0x{x} past the workgroup's {d} bytes", .{ addr, w.lds_limit });
    return @intCast(addr);
}

fn ldsRead(w: *Work, wv: *const Wave, addr: u64, n: usize) Error!u64 {
    const a = try ldsCheck(w, wv, addr, n);
    var x: u64 = 0;
    for (0..n) |i| x |= @as(u64, w.lds[a + i]) << @intCast(8 * i);
    return x;
}

fn ldsWrite(w: *Work, wv: *const Wave, addr: u64, n: usize, x: u64) Error!void {
    const a = try ldsCheck(w, wv, addr, n);
    for (0..n) |i| w.lds[a + i] = @truncate(x >> @intCast(8 * i));
}

fn vgpr64(wv: *const Wave, code: u16, ln: usize, n: u8) u64 {
    const r = code - gcn3.VGPR0;
    var x: u64 = wv.v[r][ln];
    if (n >= 2) x |= @as(u64, wv.v[r + 1][ln]) << 32;
    return x;
}

fn lds(w: *Work, wv: *Wave, in: *const Instr, stats: *Stats) Error!void {
    const df = in.d();
    const o = in.op;
    const exec = wv.exec();
    const name = df.name;
    if (in.gds) return w.fail(error.Unsupported, "GDS", .{});
    wv.lgkm_issued += 1;
    switch (df.shape) {
        .ds_none => return,
        .ds_swizzle => {
            var out: [LANES]u32 = undefined;
            const src = wv.v[in.src[0] - gcn3.VGPR0];
            const off = in.imm;
            for (0..LANES) |ln| {
                var from: usize = ln;
                if (off & 0x8000 != 0) {
                    from = (ln & ~@as(usize, 3)) | (off >> @intCast(2 * (ln & 3)) & 3);
                } else {
                    const j = ((ln & 31 & (off & 31)) | (off >> 5 & 31)) ^ (off >> 10 & 31);
                    from = (ln & 32) | j;
                }
                out[ln] = if (exec >> @intCast(from) & 1 != 0) src[from] else 0;
            }
            for (0..LANES) |ln| {
                if (exec >> @intCast(ln) & 1 != 0) wv.v[in.dst - gcn3.VGPR0][ln] = out[ln];
            }
            markPending(wv, in.dst, 1, false, true);
            return;
        },
        .ds_vdst => return w.fail(error.Unsupported, "{s}", .{name}),
        else => {},
    }
    if (o == op("ds_permute_b32") or o == op("ds_bpermute_b32")) {
        var out = [_]u32{0} ** LANES;
        const addr = wv.v[in.src[0] - gcn3.VGPR0];
        const data = wv.v[in.src[1] - gcn3.VGPR0];
        for (0..LANES) |ln| {
            if (exec >> @intCast(ln) & 1 == 0) continue;
            const sel: usize = @intCast(((addr[ln] +% in.imm) >> 2) & 63);
            if (o == op("ds_permute_b32")) {
                out[sel] = data[ln];
            } else {
                out[ln] = if (exec >> @intCast(sel) & 1 != 0) data[sel] else 0;
            }
        }
        for (0..LANES) |ln| {
            if (exec >> @intCast(ln) & 1 != 0) wv.v[in.dst - gcn3.VGPR0][ln] = out[ln];
        }
        markPending(wv, in.dst, 1, false, true);
        return;
    }
    // element size of the two-address forms and of reads/writes
    const two = df.shape == .ds_write2 or df.shape == .ds_read2 or df.shape == .ds_rtn_write2;
    // the element type ends the name: ds_write2st64_b32 is 32-bit
    const is64 = std.mem.endsWith(u8, name, "64");
    const st64 = std.mem.indexOf(u8, name, "st64") != null;
    for (0..LANES) |ln| {
        if (exec >> @intCast(ln) & 1 == 0) continue;
        const base: u64 = wv.v[in.src[0] - gcn3.VGPR0][ln];
        stats.lds_bytes += 4;
        if (two) {
            const esz: u64 = if (is64) 8 else 4;
            const scale: u64 = if (st64) esz * 64 else esz;
            const a0 = base + (in.imm & 0xff) * scale;
            const a1 = base + (in.imm >> 8) * scale;
            const n: u8 = if (is64) 2 else 1;
            switch (df.shape) {
                .ds_write2 => {
                    try ldsWrite(w, wv, a0, esz, vgpr64(wv, in.src[1], ln, n));
                    try ldsWrite(w, wv, a1, esz, vgpr64(wv, in.src[2], ln, n));
                },
                .ds_read2 => {
                    const x0 = try ldsRead(w, wv, a0, esz);
                    const x1 = try ldsRead(w, wv, a1, esz);
                    const r = in.dst - gcn3.VGPR0;
                    if (is64) {
                        wv.v[r][ln] = @truncate(x0);
                        wv.v[r + 1][ln] = @truncate(x0 >> 32);
                        wv.v[r + 2][ln] = @truncate(x1);
                        wv.v[r + 3][ln] = @truncate(x1 >> 32);
                    } else {
                        wv.v[r][ln] = @truncate(x0);
                        wv.v[r + 1][ln] = @truncate(x1);
                    }
                },
                else => {
                    // wrxchg2: old values out, data in
                    const x0 = try ldsRead(w, wv, a0, esz);
                    const x1 = try ldsRead(w, wv, a1, esz);
                    try ldsWrite(w, wv, a0, esz, vgpr64(wv, in.src[1], ln, n));
                    try ldsWrite(w, wv, a1, esz, vgpr64(wv, in.src[2], ln, n));
                    const r = in.dst - gcn3.VGPR0;
                    if (is64) {
                        wv.v[r][ln] = @truncate(x0);
                        wv.v[r + 1][ln] = @truncate(x0 >> 32);
                        wv.v[r + 2][ln] = @truncate(x1);
                        wv.v[r + 3][ln] = @truncate(x1 >> 32);
                    } else {
                        wv.v[r][ln] = @truncate(x0);
                        wv.v[r + 1][ln] = @truncate(x1);
                    }
                },
            }
            continue;
        }
        const addr = base + in.imm;
        switch (df.shape) {
            .ds_read => {
                const r = in.dst - gcn3.VGPR0;
                switch (o) {
                    op("ds_read_u8") => wv.v[r][ln] = @truncate(try ldsRead(w, wv, addr, 1)),
                    op("ds_read_i8") => wv.v[r][ln] = @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(try ldsRead(w, wv, addr, 1))))))),
                    op("ds_read_u16") => wv.v[r][ln] = @truncate(try ldsRead(w, wv, addr, 2)),
                    op("ds_read_i16") => wv.v[r][ln] = sext16(@truncate(try ldsRead(w, wv, addr, 2))),
                    else => for (0..df.d.dwords()) |i| {
                        wv.v[r + i][ln] = @truncate(try ldsRead(w, wv, addr + 4 * i, 4));
                    },
                }
            },
            .ds_addr_data => {
                const dn = df.s[1].dwords();
                switch (o) {
                    op("ds_write_b8") => try ldsWrite(w, wv, addr, 1, wv.v[in.src[1] - gcn3.VGPR0][ln]),
                    op("ds_write_b16") => try ldsWrite(w, wv, addr, 2, wv.v[in.src[1] - gcn3.VGPR0][ln]),
                    op("ds_write_b32"), op("ds_write_b64"), op("ds_write_b96"), op("ds_write_b128") => for (0..dn) |i| {
                        try ldsWrite(w, wv, addr + 4 * i, 4, wv.v[in.src[1] - gcn3.VGPR0 + i][ln]);
                    },
                    else => _ = try ldsAtomic(w, wv, o, name, addr, in, ln),
                }
            },
            .ds_rtn, .ds_rtn2, .ds_addr_data2 => {
                const old = try ldsAtomic(w, wv, o, name, addr, in, ln);
                if (df.shape != .ds_addr_data2) vwrite(wv, in.dst, df.d, ln, old);
            },
            else => return w.fail(error.Unsupported, "{s}", .{name}),
        }
    }
    if (df.d != .none) markPending(wv, in.dst, df.d.dwords(), false, true);
}

fn ldsAtomic(w: *Work, wv: *const Wave, o: gcn3.Op, name: []const u8, addr: u64, in: *const Instr, ln: usize) Error!u64 {
    const is64 = std.mem.endsWith(u8, name, "64");
    const n: usize = if (is64) 8 else 4;
    const dn: u8 = if (is64) 2 else 1;
    const old = try ldsRead(w, wv, addr, n);
    const d0 = vgpr64(wv, in.src[1], ln, dn);
    const d1 = if (in.d().s[2] != .none) vgpr64(wv, in.src[2], ln, dn) else 0;
    const m: u64 = if (is64) ~@as(u64, 0) else 0xffff_ffff;

    const so: i64 = if (is64) @bitCast(old) else @as(i32, @bitCast(@as(u32, @truncate(old))));
    const sd: i64 = if (is64) @bitCast(d0) else @as(i32, @bitCast(@as(u32, @truncate(d0))));

    const base = baseName(name);
    const new: u64 = if (eq(base, "add")) old +% d0 else if (eq(base, "sub")) old -% d0 else if (eq(base, "rsub")) d0 -% old else if (eq(base, "inc")) (if (old >= d0) 0 else old + 1) else if (eq(base, "dec")) (if (old == 0 or old > d0) d0 else old - 1) else if (eq(base, "min_i")) (if (sd < so) d0 else old) else if (eq(base, "max_i")) (if (sd > so) d0 else old) else if (eq(base, "min_u")) @min(old, d0) else if (eq(base, "max_u")) @max(old, d0) else if (eq(base, "and")) old & d0 else if (eq(base, "or")) old | d0 else if (eq(base, "xor")) old ^ d0 else if (eq(base, "mskor")) (old & ~d0) | d1 else if (eq(base, "wrxchg")) d0 else if (eq(base, "cmpst")) (if (old == d0) d1 else old) else if (eq(base, "add_f")) b32(f32of(old) + f32of(d0)) else if (eq(base, "min_f")) (if (is64) b64(@min(f64of(old), f64of(d0))) else b32(@min(f32of(old), f32of(d0)))) else if (eq(base, "max_f")) (if (is64) b64(@max(f64of(old), f64of(d0))) else b32(@max(f32of(old), f32of(d0)))) else return w.fail(error.Unsupported, "{s}", .{name});
    try ldsWrite(w, wv, addr, n, new & m);
    _ = o;
    return old;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// "ds_max_rtn_u32" -> "max_u"; "ds_add_f32" -> "add_f"; "ds_cmpst_rtn_b64" -> "cmpst".
fn baseName(name: []const u8) []const u8 {
    var s_ = name["ds_".len..];
    const us = std.mem.indexOfScalar(u8, s_, '_') orelse return s_;
    const word = s_[0..us];
    const last = s_[std.mem.lastIndexOfScalar(u8, s_, '_').? + 1 ..];
    if (eq(word, "min") or eq(word, "max")) {
        if (last[0] == 'i') return if (eq(word, "min")) "min_i" else "max_i";
        if (last[0] == 'u') return if (eq(word, "min")) "min_u" else "max_u";
        return if (eq(word, "min")) "min_f" else "max_f";
    }
    if (eq(word, "add") and last[0] == 'f') return "add_f";
    s_ = word;
    return s_;
}

// ── MUBUF / MTBUF ───────────────────────────────────────────────────────────

fn buffer(w: *Work, mem: *const Memory, wv: *Wave, in: *const Instr, stats: *Stats, strict: bool) Error!void {
    const df = in.d();
    const name = df.name;
    wv.vm_issued += 1;
    if (df.shape == .buf_none) return;
    const rsrc = dispatch.BufferResource.fromWords(wv.s[in.src[1]..][0..4].*);
    const soff: u64 = try sread(w, wv, in.src[2], 0, .b32);
    const exec = wv.exec();
    // bytes per lane and how they map to dwords
    var size: usize = 4 * @as(usize, df.d.dwords());
    var sub: enum { dword, ubyte, sbyte, ushort, sshort } = .dword;
    if (std.mem.indexOf(u8, name, "d16") != null) return w.fail(error.Unsupported, "{s}", .{name});
    if (std.mem.endsWith(u8, name, "_ubyte") or std.mem.endsWith(u8, name, "_byte")) {
        size = 1;
        sub = .ubyte;
    } else if (std.mem.endsWith(u8, name, "_sbyte")) {
        size = 1;
        sub = .sbyte;
    } else if (std.mem.endsWith(u8, name, "_ushort") or std.mem.endsWith(u8, name, "_short")) {
        size = 2;
        sub = .ushort;
    } else if (std.mem.endsWith(u8, name, "_sshort")) {
        size = 2;
        sub = .sshort;
    }
    if (std.mem.indexOf(u8, name, "format") != null) {
        const fmt: u32 = if (df.enc == .mtbuf) in.fmt else (rsrc.word3 >> 15 & 15) | (rsrc.word3 >> 12 & 7) << 4;
        const dfmt = fmt & 15;
        const nfmt = fmt >> 4;
        if (!(dfmt == 4 or dfmt == 11 or dfmt == 13 or dfmt == 14) or !(nfmt == 4 or nfmt == 5 or nfmt == 7)) return w.fail(error.Unsupported, "{s} with format {d}", .{ name, fmt });
    }
    const atomic = df.shape == .buf_atomic;
    const ndw = df.d.dwords();
    const vaddr = in.src[0] - gcn3.VGPR0;
    for (0..LANES) |ln| {
        if (exec >> @intCast(ln) & 1 == 0) continue;
        const index: u64 = if (in.idxen) wv.v[vaddr][ln] else 0;
        const voff: u64 = if (in.offen) wv.v[vaddr + @intFromBool(in.idxen)][ln] else 0;
        const offset = in.imm + voff;
        const addr = rsrc.base + soff + offset + @as(u64, rsrc.stride) * index;
        const dr = in.dst - gcn3.VGPR0;
        // range: raw buffers check the offset, structured ones the index
        const in_range = if (rsrc.stride == 0) offset + size <= rsrc.num_records else index < rsrc.num_records;
        if (!in_range and strict) return w.fail(error.Fault, "{s} lane {d}: offset 0x{x} past the V#'s 0x{x} records", .{ name, ln, offset, rsrc.num_records });
        if (atomic) {
            const is64 = ndw == 2 and !std.mem.endsWith(u8, name, "cmpswap") or ndw == 4;
            const n: usize = if (is64) 8 else 4;
            var old: u64 = 0;
            if (in_range) {
                var buf: [8]u8 = undefined;
                try readMem(w, mem, addr, buf[0..n], stats);
                old = std.mem.readInt(u64, &buf, .little) & (if (is64) ~@as(u64, 0) else 0xffff_ffff);
                const half: u8 = if (is64) 2 else 1;
                const src = vgpr64(wv, in.dst, ln, half);
                const cmp = if (std.mem.indexOf(u8, name, "cmpswap") != null) vgpr64Off(wv, in.dst, ln, half) else 0;
                const new = try bufAtomic(w, name, old, src, cmp, is64);
                std.mem.writeInt(u64, &buf, new, .little);
                try writeMem(w, mem, addr, buf[0..n], stats);
            }
            if (in.glc) {
                wv.v[dr][ln] = @truncate(old);
                if (is64) wv.v[dr + 1][ln] = @truncate(old >> 32);
            }
            continue;
        }
        if (df.shape == .buf_load) {
            if (sub == .dword) {
                for (0..ndw) |i| {
                    var x = [4]u8{ 0, 0, 0, 0 };
                    if (rsrc.stride != 0 and in_range or rsrc.stride == 0 and offset + 4 * i + 4 <= rsrc.num_records) try readMem(w, mem, addr + 4 * i, &x, stats);
                    wv.v[dr + i][ln] = std.mem.readInt(u32, &x, .little);
                }
            } else {
                var x = [4]u8{ 0, 0, 0, 0 };
                if (in_range) try readMem(w, mem, addr, x[0..size], stats);
                const raw = std.mem.readInt(u32, &x, .little);
                wv.v[dr][ln] = switch (sub) {
                    .sbyte => @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw)))))),
                    .sshort => sext16(raw),
                    else => raw,
                };
            }
            if (in.tfe) wv.v[dr + ndw][ln] = 0;
        } else {
            if (sub == .dword) {
                for (0..ndw) |i| {
                    if (!(rsrc.stride != 0 and in_range or rsrc.stride == 0 and offset + 4 * i + 4 <= rsrc.num_records)) continue;
                    var x: [4]u8 = undefined;
                    std.mem.writeInt(u32, &x, wv.v[dr + i][ln], .little);
                    try writeMem(w, mem, addr + 4 * i, &x, stats);
                }
            } else if (in_range) {
                var x: [4]u8 = undefined;
                std.mem.writeInt(u32, &x, wv.v[dr][ln], .little);
                try writeMem(w, mem, addr, x[0..size], stats);
            }
        }
    }
    if (df.shape == .buf_load) markPending(wv, in.dst, @intCast(ndw + @intFromBool(in.tfe)), true, false);
    if (atomic and in.glc) markPending(wv, in.dst, @intCast(ndw), true, false);
    if (df.shape == .buf_store and ndw > 2 or (atomic and ndw > 2)) {
        wv.store_lo = in.dst - gcn3.VGPR0;
        wv.store_hi = wv.store_lo + ndw;
        wv.store_ws = wv.ws + 1;
    }
}

fn vgpr64Off(wv: *const Wave, code: u16, ln: usize, half: u8) u64 {
    return vgpr64(wv, code + half, ln, half);
}

fn bufAtomic(w: *Work, name: []const u8, old: u64, src: u64, cmp: u64, is64: bool) Error!u64 {
    const so: i64 = if (is64) @bitCast(old) else @as(i32, @bitCast(@as(u32, @truncate(old))));
    const sd: i64 = if (is64) @bitCast(src) else @as(i32, @bitCast(@as(u32, @truncate(src))));
    const kind = blk: {
        const s_ = name[std.mem.indexOf(u8, name, "atomic_").? + 7 ..];
        break :blk if (std.mem.indexOfScalar(u8, s_, '_')) |u| s_[0..u] else s_;
    };
    const m: u64 = if (is64) ~@as(u64, 0) else 0xffff_ffff;
    const r: u64 = if (eq(kind, "swap")) src else if (eq(kind, "cmpswap")) (if (old == cmp) src else old) else if (eq(kind, "add")) old +% src else if (eq(kind, "sub")) old -% src else if (eq(kind, "smin")) (if (sd < so) src else old) else if (eq(kind, "umin")) @min(old, src) else if (eq(kind, "smax")) (if (sd > so) src else old) else if (eq(kind, "umax")) @max(old, src) else if (eq(kind, "and")) old & src else if (eq(kind, "or")) old | src else if (eq(kind, "xor")) old ^ src else if (eq(kind, "inc")) (if (old >= src) 0 else old + 1) else if (eq(kind, "dec")) (if (old == 0 or old > src) src else old - 1) else return w.fail(error.Unsupported, "{s}", .{name});
    return r & m;
}

// ── FLAT ────────────────────────────────────────────────────────────────────

fn flat(w: *Work, mem: *const Memory, wv: *Wave, in: *const Instr, stats: *Stats) Error!void {
    const df = in.d();
    const name = df.name;
    const exec = wv.exec();
    wv.vm_issued += 1;
    wv.lgkm_issued += 1;
    var size: usize = 0;
    var signed = false;
    if (std.mem.endsWith(u8, name, "byte")) {
        size = 1;
        signed = std.mem.endsWith(u8, name, "sbyte");
    } else if (std.mem.endsWith(u8, name, "short")) {
        size = 2;
        signed = std.mem.endsWith(u8, name, "sshort");
    }
    for (0..LANES) |ln| {
        if (exec >> @intCast(ln) & 1 == 0) continue;
        const addr = vgpr64(wv, in.src[0], ln, 2);
        switch (df.shape) {
            .flat_load => {
                const dr = in.dst - gcn3.VGPR0;
                if (size != 0) {
                    var x = [4]u8{ 0, 0, 0, 0 };
                    try readMem(w, mem, addr, x[0..size], stats);
                    const raw = std.mem.readInt(u32, &x, .little);
                    wv.v[dr][ln] = if (!signed) raw else if (size == 1) @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw)))))) else sext16(raw);
                } else for (0..df.d.dwords()) |i| {
                    var x: [4]u8 = undefined;
                    try readMem(w, mem, addr + 4 * i, &x, stats);
                    wv.v[dr + i][ln] = std.mem.readInt(u32, &x, .little);
                }
            },
            .flat_store => {
                const sr = in.src[1] - gcn3.VGPR0;
                if (size != 0) {
                    var x: [4]u8 = undefined;
                    std.mem.writeInt(u32, &x, wv.v[sr][ln], .little);
                    try writeMem(w, mem, addr, x[0..size], stats);
                } else for (0..df.s[1].dwords()) |i| {
                    var x: [4]u8 = undefined;
                    std.mem.writeInt(u32, &x, wv.v[sr + i][ln], .little);
                    try writeMem(w, mem, addr + 4 * i, &x, stats);
                }
            },
            else => {
                const is64 = df.d.dwords() == 2;
                const n: usize = if (is64) 8 else 4;
                var buf = [_]u8{0} ** 8;
                try readMem(w, mem, addr, buf[0..n], stats);
                const old = std.mem.readInt(u64, &buf, .little);
                const half: u8 = if (is64) 2 else 1;
                const src = vgpr64(wv, in.src[1], ln, half);
                const cmp = vgpr64Off(wv, in.src[1], ln, half);
                const new = try bufAtomic(w, name, old, src, cmp, is64);
                std.mem.writeInt(u64, &buf, new, .little);
                try writeMem(w, mem, addr, buf[0..n], stats);
                if (in.glc) vwrite(wv, in.dst, df.d, ln, old);
            },
        }
    }
    if (df.shape == .flat_load or (df.shape == .flat_atomic and in.glc)) markPending(wv, in.dst, df.d.dwords(), true, true);
    if (df.shape == .flat_store and df.s[1].dwords() > 2 or (df.shape == .flat_atomic and df.s[1].dwords() > 2)) {
        wv.store_lo = in.src[1] - gcn3.VGPR0;
        wv.store_hi = wv.store_lo + df.s[1].dwords();
        wv.store_ws = wv.ws + 1;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

var test_work: Work = .{};
var test_asm: gcn3_asm.Work = .{};
var test_code: [4096]u32 = undefined;

fn assembleTest(src: []const u8) !gcn3_asm.Kernel {
    return gcn3_asm.assemble(src, &test_asm, &test_code) catch |e| {
        std.debug.print("line {d}: {s}\n", .{ test_asm.error_line, @errorName(e) });
        return e;
    };
}

fn runTest(k: *const gcn3_asm.Kernel, regions: []const Region, user: []const u32, groups: [3]u32) !Stats {
    var stats = Stats{};
    const mem = Memory{ .regions = regions };
    const d = Dispatch{ .kernel = k, .user_sgprs = user, .groups = groups };
    run(&test_work, &mem, &d, &stats) catch |e| {
        var buf: [160]u8 = undefined;
        std.debug.print("{s} at dword {d} ({s}), wave {d}: {s}\n", .{ @errorName(e), test_work.err_pc, test_work.errorInstr(&buf), test_work.err_wave, test_work.message() });
        return e;
    };
    return stats;
}

fn expectRunError(k: *const gcn3_asm.Kernel, regions: []const Region, user: []const u32, want: Error) !void {
    var stats = Stats{};
    const mem = Memory{ .regions = regions };
    const d = Dispatch{ .kernel = k, .user_sgprs = user, .groups = .{ 1, 1, 1 } };
    try std.testing.expectError(want, run(&test_work, &mem, &d, &stats));
}

const KARG_VA: u64 = 0x1000;
const A_VA: u64 = 0x10_0000;
const B_VA: u64 = 0x20_0000;
const C_VA: u64 = 0x30_0000;

fn kernargs(buf: []u8, ptrs: []const u64, words: []const u32) void {
    var at: usize = 0;
    for (ptrs) |p| {
        std.mem.writeInt(u64, buf[at..][0..8], p, .little);
        at += 8;
    }
    for (words) |x| {
        std.mem.writeInt(u32, buf[at..][0..4], x, .little);
        at += 4;
    }
}

/// dst[i] = src[i] for i < count, through buffer resources: the lanes past
/// count read 0 and write nothing (the V# range check).
pub const copy_src = @embedFile("testdata/copy.s");

var copy_in: [1024]u32 = undefined;
var copy_out: [1024]u32 = undefined;
var karg: [64]u8 = undefined;

test "a copy through buffer resources: the range check stops the last workgroup" {
    const k = try assembleTest(copy_src);
    const count = 1000;
    for (&copy_in, 0..) |*x, i| x.* = @as(u32, @intCast(i)) *% 0x9e3779b9;
    @memset(&copy_out, 0xdeadbeef);
    kernargs(&karg, &.{ A_VA, B_VA }, &.{count});
    const regions = [_]Region{
        .{ .va = KARG_VA, .bytes = &karg },
        .{ .va = A_VA, .bytes = std.mem.sliceAsBytes(&copy_in) },
        .{ .va = B_VA, .bytes = std.mem.sliceAsBytes(&copy_out) },
    };
    const stats = try runTest(&k, &regions, &.{ @truncate(KARG_VA), 0 }, .{ 16, 1, 1 });
    try std.testing.expectEqualSlices(u32, copy_in[0..count], copy_out[0..count]);
    for (copy_out[count..]) |x| try std.testing.expectEqual(@as(u32, 0xdeadbeef), x);
    try std.testing.expectEqual(@as(u64, 16), stats.waves);
    try std.testing.expectEqual(@as(u64, 4 * count), stats.bytes_written);
}

/// C = A x B, n x n fp32, row-major, n a multiple of 16. One C element per
/// work-item, 16 x 16 workgroups (four waves); 16 x 16 tiles of A and B are
/// staged in LDS between barriers.
pub const matmul_src = @embedFile("testdata/matmul.s");

const N = 64;
var mat_a: [N * N]f32 = undefined;
var mat_b: [N * N]f32 = undefined;
var mat_c: [N * N]f32 = undefined;

test "fp32 matmul: LDS tiles, barriers, four waves per workgroup, the CPU's sums bit for bit" {
    const k = try assembleTest(matmul_src);
    var rng = std.Random.DefaultPrng.init(42);
    const r = rng.random();
    for (&mat_a) |*x| x.* = r.float(f32) * 2 - 1;
    for (&mat_b) |*x| x.* = r.float(f32) * 2 - 1;
    @memset(&mat_c, std.math.nan(f32));
    kernargs(&karg, &.{ A_VA, B_VA, C_VA }, &.{N});
    const regions = [_]Region{
        .{ .va = KARG_VA, .bytes = &karg },
        .{ .va = A_VA, .bytes = std.mem.sliceAsBytes(&mat_a) },
        .{ .va = B_VA, .bytes = std.mem.sliceAsBytes(&mat_b) },
        .{ .va = C_VA, .bytes = std.mem.sliceAsBytes(&mat_c) },
    };
    const stats = try runTest(&k, &regions, &.{ @truncate(KARG_VA), 0 }, .{ N / 16, N / 16, 1 });
    for (0..N) |i| {
        for (0..N) |j| {
            // v_mac_f32 rounds the product, then the sum, in k order
            var acc: f32 = 0;
            for (0..N) |kk| acc = acc + mat_a[i * N + kk] * mat_b[kk * N + j];
            if (@as(u32, @bitCast(acc)) != @as(u32, @bitCast(mat_c[i * N + j]))) {
                std.debug.print("C[{d}][{d}] = {d}, the CPU says {d}\n", .{ i, j, mat_c[i * N + j], acc });
                return error.TestUnexpectedResult;
            }
        }
    }
    try std.testing.expectEqual(@as(u64, 16), stats.workgroups);
    try std.testing.expectEqual(@as(u64, 64), stats.waves);
    try std.testing.expectEqual(@as(u16, 20), k.config.vgprs());
    try std.testing.expect(k.config.reserve_vcc);
}

/// out[i] = i odd ? i * 3 : i + 100, as an if/else under EXEC.
const branch_src = @embedFile("testdata/branch.s");

test "divergence: v_cmp, s_and_saveexec, an else under the other lanes" {
    const k = try assembleTest(branch_src);
    kernargs(&karg, &.{C_VA}, &.{});
    @memset(&copy_out, 0);
    const regions = [_]Region{
        .{ .va = KARG_VA, .bytes = &karg },
        .{ .va = C_VA, .bytes = std.mem.sliceAsBytes(&copy_out) },
    };
    _ = try runTest(&k, &regions, &.{ @truncate(KARG_VA), 0 }, .{ 1, 1, 1 });
    for (0..64) |i| {
        const want: u32 = if (i & 1 != 0) @intCast(i * 3) else @intCast(i + 100);
        try std.testing.expectEqual(want, copy_out[i]);
    }
}

const salu_src =
    \\ .amdhsa_user_sgpr_kernarg_segment_ptr 1
    \\     s_load_dwordx2 s[2:3], s[0:1], 0x0
    \\     s_mov_b32 s4, -1
    \\     s_add_u32 s8, s4, 2                 ; 1, carry out
    \\     s_addc_u32 s9, 0, 0                 ; the carry: 1
    \\     s_mov_b32 s5, 0x12345678            ; one literal per instruction
    \\     s_bfe_u32 s10, s5, 0x80008          ; 8 bits from bit 8: 0x56
    \\     s_movk_i32 s6, 0xf0
    \\     s_bfe_i32 s11, s6, 0x40004          ; 4 bits from bit 4, signed: -1
    \\     s_ff1_i32_b32 s12, 0x100            ; 8
    \\     s_flbit_i32_b32 s13, 0x100          ; 23
    \\     s_movk_i32 s14, 0x8000              ; -32768
    \\     s_cmpk_lt_i32 s14, 0x0
    \\     s_cselect_b32 s15, 7, 9             ; SCC was set: 7
    \\     s_quadmask_b32 s16, 0x10f0          ; nibbles 1 and 3: 0xa
    \\     s_bcnt1_i32_b64 s17, -1             ; 64
    \\     s_lshl_b64 s[18:19], 1, 40
    \\     s_ashr_i32 s20, 0x80000000, 4
    \\     s_mul_i32 s21, -3, 7
    \\     s_abs_i32 s22, -5
    \\     s_absdiff_i32 s23, 3, 10
    \\     s_waitcnt lgkmcnt(0)
    \\     s_store_dwordx4 s[8:11], s[2:3], 0x0 glc
    \\     s_store_dwordx4 s[12:15], s[2:3], 0x10 glc
    \\     s_store_dwordx4 s[16:19], s[2:3], 0x20 glc
    \\     s_store_dwordx4 s[20:23], s[2:3], 0x30 glc
    \\     s_waitcnt lgkmcnt(0)
    \\     s_dcache_wb
    \\     s_endpgm
;

test "scalar ALU: carries, SCC, bit fields, find-first, quad masks" {
    const k = try assembleTest(salu_src);
    kernargs(&karg, &.{C_VA}, &.{});
    @memset(&copy_out, 0);
    const regions = [_]Region{
        .{ .va = KARG_VA, .bytes = &karg },
        .{ .va = C_VA, .bytes = std.mem.sliceAsBytes(&copy_out) },
    };
    _ = try runTest(&k, &regions, &.{ @truncate(KARG_VA), 0 }, .{ 1, 1, 1 });
    const want = [16]u32{ 1, 1, 0x56, 0xffffffff, 8, 23, 0xffff8000, 7, 0xa, 64, 0, 0x100, 0xf8000000, @bitCast(@as(i32, -21)), 5, 7 };
    try std.testing.expectEqualSlices(u32, &want, copy_out[0..16]);
}

const sdwa_src =
    \\ .amdhsa_user_sgpr_kernarg_segment_ptr 1
    \\     s_load_dwordx2 s[2:3], s[0:1], 0x0
    \\     v_mov_b32_e32 v1, 0x80ff7f01
    \\     v_mov_b32_e32 v2, 0xfe0000
    \\     v_mov_b32_e32 v3, 0x11223344
    \\     v_mov_b32_sdwa v4, v1 dst_sel:DWORD dst_unused:UNUSED_PAD src0_sel:BYTE_0
    \\     v_mov_b32_sdwa v5, sext(v1) dst_sel:DWORD dst_unused:UNUSED_PAD src0_sel:BYTE_2
    \\     v_mov_b32_sdwa v6, sext(v1) dst_sel:DWORD dst_unused:UNUSED_PAD src0_sel:WORD_1
    \\     v_mov_b32_sdwa v7, v1 dst_sel:DWORD dst_unused:UNUSED_PAD src0_sel:WORD_0
    \\     v_mul_i32_i24_sdwa v8, sext(v1), sext(v2) dst_sel:DWORD dst_unused:UNUSED_PAD src0_sel:BYTE_3 src1_sel:BYTE_2
    \\     v_mul_u32_u24_sdwa v9, v1, v2 dst_sel:DWORD dst_unused:UNUSED_PAD src0_sel:BYTE_3 src1_sel:BYTE_2
    \\     v_mov_b32_sdwa v3, v1 dst_sel:BYTE_1 dst_unused:UNUSED_PRESERVE src0_sel:BYTE_3
    \\     v_mov_b32_e32 v10, 0
    \\     v_mov_b32_sdwa v10, v1 dst_sel:BYTE_1 dst_unused:UNUSED_SEXT src0_sel:BYTE_3
    \\     v_mov_b32_sdwa v11, v1 dst_sel:WORD_1 dst_unused:UNUSED_PAD src0_sel:BYTE_1
    \\     v_add_u32_sdwa v12, vcc, sext(v1), v2 dst_sel:DWORD dst_unused:UNUSED_PAD src0_sel:BYTE_2 src1_sel:BYTE_2
    \\     v_cndmask_b32_e64 v17, 0, 1, vcc
    \\     v_cmp_gt_u32 vcc, v1, v2 src0_sel:BYTE_2 src1_sel:BYTE_2
    \\     v_cndmask_b32_e64 v13, 0, 1, vcc
    \\     v_mov_b32_e32 v15, 0x3c000000
    \\     v_mov_b32_e32 v16, 0x4000
    \\     v_mov_b32_e32 v14, 0x1234
    \\     v_add_f16_sdwa v14, v15, v16 dst_sel:WORD_1 dst_unused:UNUSED_PRESERVE src0_sel:WORD_1 src1_sel:WORD_0
    \\     v_readfirstlane_b32 s4, v4
    \\     v_readfirstlane_b32 s5, v5
    \\     v_readfirstlane_b32 s6, v6
    \\     v_readfirstlane_b32 s7, v7
    \\     v_readfirstlane_b32 s8, v8
    \\     v_readfirstlane_b32 s9, v9
    \\     v_readfirstlane_b32 s10, v3
    \\     v_readfirstlane_b32 s11, v10
    \\     v_readfirstlane_b32 s12, v11
    \\     v_readfirstlane_b32 s13, v12
    \\     v_readfirstlane_b32 s14, v17
    \\     v_readfirstlane_b32 s15, v13
    \\     v_readfirstlane_b32 s16, v14
    \\     s_mov_b32 s17, 0
    \\     s_mov_b64 s[18:19], 0
    \\     s_nop 4
    \\     s_waitcnt lgkmcnt(0)
    \\     s_store_dwordx4 s[4:7], s[2:3], 0x0 glc
    \\     s_store_dwordx4 s[8:11], s[2:3], 0x10 glc
    \\     s_store_dwordx4 s[12:15], s[2:3], 0x20 glc
    \\     s_store_dwordx4 s[16:19], s[2:3], 0x30 glc
    \\     s_waitcnt lgkmcnt(0)
    \\     s_dcache_wb
    \\     s_endpgm
;

test "SDWA: byte and word selects, sign-extended or not; the result into a byte or word, padded, sign-extended or kept" {
    const k = try assembleTest(sdwa_src);
    kernargs(&karg, &.{C_VA}, &.{});
    @memset(&copy_out, 0);
    const regions = [_]Region{
        .{ .va = KARG_VA, .bytes = &karg },
        .{ .va = C_VA, .bytes = std.mem.sliceAsBytes(&copy_out) },
    };
    _ = try runTest(&k, &regions, &.{ @truncate(KARG_VA), 0 }, .{ 1, 1, 1 });
    const want = [13]u32{
        0x01, 0xffffffff, 0xffff80ff, 0x7f01, // selects
        256, 128 * 254, // (-128) * (-2), 128 * 254
        0x11228044, 0xffff8000, 0x007f0000, // into byte 1 (kept, sign-extended), into word 1
        253, 1, 1, // -1 + 254 and its carry; 0xff > 0xfe
        0x42001234, // 1.0 + 2.0 into the high half, the low kept
    };
    try std.testing.expectEqualSlices(u32, &want, copy_out[0..13]);
}

const vmem_head =
    \\ .amdhsa_user_sgpr_kernarg_segment_ptr 1
    \\     s_load_dwordx4 s[8:11], s[0:1], 0x0
    \\     s_waitcnt lgkmcnt(0)
    \\     v_mov_b32_e32 v1, 0x27fac
    \\     v_readfirstlane_b32 s11, v1
    \\     s_mov_b32 s10, 64
    \\
;
const vmem_tail =
    \\
    \\     buffer_load_dword v2, off, s[8:11], 0
    \\     s_waitcnt vmcnt(0)
    \\     s_endpgm
;

test "hazards: a missing s_waitcnt, M0 left 0 for LDS, an SGPR read by VMEM too soon" {
    kernargs(&karg, &.{C_VA}, &.{});
    const regions = [_]Region{
        .{ .va = KARG_VA, .bytes = &karg },
        .{ .va = C_VA, .bytes = std.mem.sliceAsBytes(&copy_out) },
    };
    const user = [_]u32{ @truncate(KARG_VA), 0 };
    {
        const k = try assembleTest(
            \\ .amdhsa_user_sgpr_kernarg_segment_ptr 1
            \\     s_load_dwordx2 s[4:5], s[0:1], 0x0
            \\     v_mov_b32_e32 v1, s4
            \\     s_endpgm
        );
        try expectRunError(&k, &regions, &user, error.Hazard);
        try std.testing.expect(std.mem.indexOf(u8, test_work.message(), "lgkmcnt") != null);
    }
    {
        const k = try assembleTest(
            \\ .amdhsa_user_sgpr_kernarg_segment_ptr 1
            \\ .amdhsa_group_segment_fixed_size 256
            \\     v_lshlrev_b32_e32 v1, 2, v0
            \\     ds_write_b32 v1, v0
            \\     s_endpgm
        );
        try expectRunError(&k, &regions, &user, error.Hazard);
        try std.testing.expect(std.mem.indexOf(u8, test_work.message(), "M0") != null);
    }
    {
        // v_readfirstlane wrote s11; s_mov_b32 is one wait state and
        // s_nop N is N + 1, so s_nop 2 makes 4 (too few) and s_nop 3 five.
        const short = try assembleTest(vmem_head ++ "    s_nop 2" ++ vmem_tail);
        try expectRunError(&short, &regions, &user, error.Hazard);
        try std.testing.expect(std.mem.indexOf(u8, test_work.message(), "VMEM") != null);
        const enough = try assembleTest(vmem_head ++ "    s_nop 3" ++ vmem_tail);
        _ = try runTest(&enough, &regions, &user, .{ 1, 1, 1 });
    }
    {
        const k = try assembleTest(
            \\ .amdhsa_next_free_vgpr 2
            \\     v_mov_b32_e32 v5, 0
            \\     s_endpgm
        );
        try expectRunError(&k, &regions, &.{}, error.RegisterOutOfRange);
    }
}

test "LDS: write2/read2 offsets, swizzle and bpermute across the wave" {
    const k = try assembleTest(
        \\ .amdhsa_user_sgpr_kernarg_segment_ptr 1
        \\ .amdhsa_group_segment_fixed_size 512
        \\     s_load_dwordx2 s[2:3], s[0:1], 0x0
        \\     s_mov_b32 m0, -1
        \\     v_lshlrev_b32_e32 v1, 2, v0            ; lane * 4
        \\     v_add_u32_e32 v2, vcc, 0x3e8, v0       ; 1000 + lane
        \\     ds_write2_b32 v1, v2, v0 offset1:64    ; [lane] = 1000 + lane, [64 + lane] = lane
        \\     s_waitcnt lgkmcnt(0)
        \\     v_xor_b32_e32 v3, 0x80, v1             ; lane ^ 32, in bytes
        \\     ds_read2_b32 v[4:5], v3 offset1:64
        \\     ds_swizzle_b32 v6, v0 offset:swizzle(SWAP,1)
        \\     v_sub_u32_e32 v7, vcc, 0xfc, v1        ; (63 - lane) * 4
        \\     ds_bpermute_b32 v8, v7, v0
        \\     v_lshlrev_b32_e32 v9, 4, v0            ; 16 bytes per lane
        \\     s_waitcnt lgkmcnt(0)
        \\     v_mov_b32_e32 v11, s3
        \\     v_add_u32_e32 v10, vcc, s2, v9
        \\     v_addc_u32_e32 v11, vcc, 0, v11, vcc
        \\     v_mov_b32_e32 v7, v8
        \\     flat_store_dwordx4 v[10:11], v[4:7]
        \\     s_endpgm
    );
    kernargs(&karg, &.{C_VA}, &.{});
    @memset(&copy_out, 0);
    const regions = [_]Region{
        .{ .va = KARG_VA, .bytes = &karg },
        .{ .va = C_VA, .bytes = std.mem.sliceAsBytes(&copy_out) },
    };
    _ = try runTest(&k, &regions, &.{ @truncate(KARG_VA), 0 }, .{ 1, 1, 1 });
    for (0..64) |i| {
        const row = copy_out[4 * i ..][0..4];
        try std.testing.expectEqual(@as(u32, @intCast(1000 + (i ^ 32))), row[0]);
        try std.testing.expectEqual(@as(u32, @intCast(i ^ 32)), row[1]);
        try std.testing.expectEqual(@as(u32, @intCast(i ^ 1)), row[2]);
        try std.testing.expectEqual(@as(u32, @intCast(63 - i)), row[3]);
    }
}

test "LDS: the st64 forms stride 64 elements of their own width" {
    const k = try assembleTest(
        \\ .amdhsa_user_sgpr_kernarg_segment_ptr 1
        \\ .amdhsa_group_segment_fixed_size 2048
        \\     s_load_dwordx2 s[2:3], s[0:1], 0x0
        \\     s_mov_b32 m0, -1
        \\     v_lshlrev_b32_e32 v1, 2, v0            ; lane * 4
        \\     v_add_u32_e32 v2, vcc, 0x3e8, v0       ; 1000 + lane
        \\     ds_write2st64_b32 v1, v0, v2 offset1:1 ; [lane] = lane, [64 * 1 + lane] = 1000 + lane
        \\     v_lshlrev_b32_e32 v3, 3, v0            ; lane * 8
        \\     v_mov_b32_e32 v4, 7
        \\     v_mov_b32_e32 v5, v0
        \\     ds_write2st64_b64 v3, v[4:5], v[4:5] offset0:1 offset1:2 ; 64-bit, 512 bytes apart
        \\     s_waitcnt lgkmcnt(0)
        \\     ds_read_b32 v6, v1 offset:256
        \\     ds_read_b64 v[7:8], v3 offset:1024
        \\     v_lshlrev_b32_e32 v9, 4, v0
        \\     s_waitcnt lgkmcnt(0)
        \\     v_mov_b32_e32 v11, s3
        \\     v_add_u32_e32 v10, vcc, s2, v9
        \\     v_addc_u32_e32 v11, vcc, 0, v11, vcc
        \\     v_mov_b32_e32 v9, v0
        \\     flat_store_dwordx4 v[10:11], v[6:9]
        \\     s_endpgm
    );
    kernargs(&karg, &.{C_VA}, &.{});
    @memset(&copy_out, 0);
    const regions = [_]Region{
        .{ .va = KARG_VA, .bytes = &karg },
        .{ .va = C_VA, .bytes = std.mem.sliceAsBytes(&copy_out) },
    };
    _ = try runTest(&k, &regions, &.{ @truncate(KARG_VA), 0 }, .{ 1, 1, 1 });
    for (0..64) |i| {
        const row = copy_out[4 * i ..][0..4];
        try std.testing.expectEqual(@as(u32, @intCast(1000 + i)), row[0]);
        try std.testing.expectEqual(@as(u32, 7), row[1]);
        try std.testing.expectEqual(@as(u32, @intCast(i)), row[2]);
    }
}
