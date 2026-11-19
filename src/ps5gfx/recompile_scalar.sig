//! @zpm/ps5gfx recompile_scalar — a shader's scalar side, run on the CPU
//! once a draw (recompile.sig's `evaluate`).
//!
//! The scalar instructions compute what is the same for every lane:
//! addresses, descriptors, constants. Inside the game's own process they
//! are simply executed: the user-data words are the first registers
//! (s8.. on the vertex side, s0.. for the pixel shader; every other
//! register starts at 0), SMEM loads read the game's memory through
//! `Memory`, and s_getpc_b64 gives the code's own address. On the way, the
//! values the lane code needs are recorded: each read slot's register, and
//! each buffer load's descriptor turned into a window, three words and the
//! key (see recompile.sig).
//!
//! The semantics are gfx10's, the same as the older GCN's for these
//! instructions (amdgpu/gcn3_emu.sig is this repository's reference):
//! SCC is the carry, the borrow or the signed overflow of the adds and
//! subtracts, "the result is not zero" for the logic, shifts and field
//! extracts, the comparison for s_cmp and s_cmpk, and for s_min and s_max
//! whether the first operand was chosen; shift counts are masked to the
//! operand's width.
//!
//! Not here: an s_buffer_load's range check is against the V#'s records
//! counted in bytes when its stride is 0 and as records times stride
//! otherwise (the hardware's rule for scalar buffer loads with a stride
//! was not confirmed); SMEM addresses are rounded down to 4 bytes and
//! kept to 48 bits; a 32-bit literal read by a 64-bit operand is
//! extended as gcn3.constValue does, not checked against hardware.
//!
//! Every value here is the game's (its code, its registers, its memory):
//! sums of them wrap or are compared without a sum that could overflow,
//! so no shader can make this trap.

const std = @import("std");
const rc = @import("recompile.sig");
const gfx10 = rc.gfx10;
const Instr = gfx10.Instr;
const op = gfx10.op;
const Error = rc.Error;

/// The scalar registers (codes 0..127: s0..s105, VCC, TTMP, M0, NULL,
/// EXEC) and SCC.
pub const Scalar = struct {
    s: [128]u32 = [_]u32{0} ** 128,
    scc: bool = false,

    pub fn get64(r: *const Scalar, code: u16) u64 {
        return @as(u64, r.s[code]) | @as(u64, r.s[code + 1]) << 32;
    }
};

/// A source operand's value: a register, an inline constant or the
/// literal, `ty` wide.
fn read(r: *const Scalar, in: *const Instr, code: u16, ty: gfx10.Ty) u64 {
    if (code < 128) {
        if (code == gfx10.NULL) return 0;
        if (ty.dwords() >= 2 and code + 1 < 128) return r.get64(code);
        return r.s[code];
    }
    if (code == gfx10.SCC) return @intFromBool(r.scc);
    if (gfx10.constValue(code, in.lit, ty)) |v| return if (ty.dwords() >= 2) v else v & 0xffff_ffff;
    return 0;
}

fn write(r: *Scalar, code: u16, ty: gfx10.Ty, v: u64) void {
    if (code >= 128 or code == gfx10.NULL) return;
    r.s[code] = @truncate(v);
    if (ty.dwords() >= 2 and code + 1 < 128) r.s[code + 1] = @truncate(v >> 32);
}

fn sext16(x: u32) u32 {
    return @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(x))))));
}

/// The field `width` bits wide from bit `off` of x (0 for width 0),
/// sign-extended when `signed`.
fn bfe32(x: u32, off: u5, width: u7, signed: bool) u32 {
    if (width == 0) return 0;
    // (s_bfe_i32 shifts the signed source: past bit 31 the field is the
    // sign's copies, as KIR's i32 bfe gives on the lane side)
    var v: u64 = if (signed) @bitCast(@as(i64, @as(i32, @bitCast(x))) >> off) else @as(u64, x) >> off;
    if (width < 64) v &= (@as(u64, 1) << @intCast(width)) - 1;
    if (signed and width < 64) {
        const sh: u6 = @intCast(64 - @as(u7, width));
        v = @bitCast(@as(i64, @bitCast(v << sh)) >> sh);
    }
    return @truncate(v);
}

/// Executes one scalar instruction.
fn exec(r: *Scalar, in: *const Instr, pc_next: u64, mem: rc.Memory, why: *rc.Log, word: u32) Error!void {
    const df = in.d();
    const o = in.op;
    switch (df.enc) {
        .sop2 => {
            const a = read(r, in, in.src[0], df.s[0]);
            const b = read(r, in, in.src[1], df.s[1]);
            const a32: u32 = @truncate(a);
            const b32: u32 = @truncate(b);
            const ia: i32 = @bitCast(a32);
            const ib: i32 = @bitCast(b32);
            var v: u64 = 0;
            var scc: ?bool = null;
            switch (o) {
                op("s_add_u32") => {
                    const t = @as(u64, a32) + b32;
                    v = t & 0xffff_ffff;
                    scc = t >> 32 != 0;
                },
                op("s_sub_u32") => {
                    v = a32 -% b32;
                    scc = b32 > a32;
                },
                op("s_add_i32") => {
                    const t = @addWithOverflow(ia, ib);
                    v = @as(u32, @bitCast(t[0]));
                    scc = t[1] != 0;
                },
                op("s_sub_i32") => {
                    const t = @subWithOverflow(ia, ib);
                    v = @as(u32, @bitCast(t[0]));
                    scc = t[1] != 0;
                },
                op("s_addc_u32") => {
                    const t = @as(u64, a32) + b32 + @intFromBool(r.scc);
                    v = t & 0xffff_ffff;
                    scc = t >> 32 != 0;
                },
                op("s_subb_u32") => {
                    const c: u64 = @intFromBool(r.scc);
                    v = (@as(u64, a32) -% b32 -% c) & 0xffff_ffff;
                    scc = @as(u64, b32) + c > a32;
                },
                op("s_lshl1_add_u32"), op("s_lshl2_add_u32"), op("s_lshl3_add_u32"), op("s_lshl4_add_u32") => {
                    const n: u6 = switch (o) {
                        op("s_lshl1_add_u32") => 1,
                        op("s_lshl2_add_u32") => 2,
                        op("s_lshl3_add_u32") => 3,
                        else => 4,
                    };
                    // (SCC: the carry out of the whole sum, the bits
                    // shifted out included)
                    const t = (@as(u64, a32) << n) + b32;
                    v = t & 0xffff_ffff;
                    scc = t >> 32 != 0;
                },
                op("s_min_i32") => {
                    scc = ia < ib;
                    v = if (ia < ib) a32 else b32;
                },
                op("s_min_u32") => {
                    scc = a32 < b32;
                    v = @min(a32, b32);
                },
                op("s_max_i32") => {
                    scc = ia > ib;
                    v = if (ia > ib) a32 else b32;
                },
                op("s_max_u32") => {
                    scc = a32 > b32;
                    v = @max(a32, b32);
                },
                op("s_cselect_b32"), op("s_cselect_b64") => v = if (r.scc) a else b,
                op("s_and_b32"), op("s_and_b64") => v = a & b,
                op("s_or_b32"), op("s_or_b64") => v = a | b,
                op("s_xor_b32"), op("s_xor_b64") => v = a ^ b,
                op("s_andn2_b32"), op("s_andn2_b64") => v = a & ~b,
                op("s_orn2_b32"), op("s_orn2_b64") => v = a | ~b,
                op("s_lshl_b32") => v = @as(u32, a32 << @intCast(b32 & 31)),
                op("s_lshl_b64") => v = a << @intCast(b32 & 63),
                op("s_lshr_b32") => v = a32 >> @intCast(b32 & 31),
                op("s_lshr_b64") => v = a >> @intCast(b32 & 63),
                op("s_ashr_i32") => v = @as(u32, @bitCast(ia >> @intCast(b32 & 31))),
                op("s_bfm_b32") => v = @as(u32, @truncate(((@as(u64, 1) << @intCast(a32 & 31)) - 1) << @intCast(b32 & 31))),
                op("s_mul_i32") => v = a32 *% b32,
                op("s_bfe_u32") => v = bfe32(a32, @intCast(b32 & 31), @intCast((b32 >> 16) & 0x7f), false),
                op("s_bfe_i32") => v = bfe32(a32, @intCast(b32 & 31), @intCast((b32 >> 16) & 0x7f), true),
                else => unreachable, // (analyse kept only these)
            }
            if (df.d.dwords() < 2) v &= 0xffff_ffff;
            if (scc == null) switch (o) {
                op("s_cselect_b32"), op("s_cselect_b64"), op("s_bfm_b32"), op("s_mul_i32") => {},
                else => scc = v != 0,
            };
            write(r, in.dst, df.d, v);
            if (scc) |c| r.scc = c;
        },
        .sop1 => switch (o) {
            op("s_mov_b32"), op("s_mov_b64") => write(r, in.dst, df.d, read(r, in, in.src[0], df.s[0])),
            op("s_not_b32"), op("s_not_b64") => {
                var v = ~read(r, in, in.src[0], df.s[0]);
                if (df.d.dwords() < 2) v &= 0xffff_ffff;
                write(r, in.dst, df.d, v);
                r.scc = v != 0;
            },
            op("s_getpc_b64") => write(r, in.dst, .b64, pc_next),
            else => unreachable,
        },
        .sopc => {
            const a = read(r, in, in.src[0], df.s[0]);
            const b = read(r, in, in.src[1], df.s[1]);
            const ia: i32 = @bitCast(@as(u32, @truncate(a)));
            const ib: i32 = @bitCast(@as(u32, @truncate(b)));
            r.scc = switch (o) {
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
                else => unreachable,
            };
        },
        .sopk => {
            const simm = sext16(in.imm);
            const cur = if (in.dst < 128) r.s[in.dst] else 0;
            const ic: i32 = @bitCast(cur);
            const is: i32 = @bitCast(simm);
            switch (o) {
                op("s_movk_i32") => write(r, in.dst, .b32, simm),
                op("s_addk_i32") => {
                    const t = @addWithOverflow(ic, is);
                    write(r, in.dst, .b32, @as(u32, @bitCast(t[0])));
                    r.scc = t[1] != 0;
                },
                op("s_cmpk_eq_i32") => r.scc = cur == simm,
                op("s_cmpk_lg_i32") => r.scc = cur != simm,
                op("s_cmpk_gt_i32") => r.scc = ic > is,
                op("s_cmpk_ge_i32") => r.scc = ic >= is,
                op("s_cmpk_lt_i32") => r.scc = ic < is,
                op("s_cmpk_le_i32") => r.scc = ic <= is,
                op("s_cmpk_eq_u32") => r.scc = cur == in.imm,
                op("s_cmpk_lg_u32") => r.scc = cur != in.imm,
                op("s_cmpk_gt_u32") => r.scc = cur > in.imm,
                op("s_cmpk_ge_u32") => r.scc = cur >= in.imm,
                op("s_cmpk_lt_u32") => r.scc = cur < in.imm,
                op("s_cmpk_le_u32") => r.scc = cur <= in.imm,
                else => {}, // (the s_waitcnt_* forms)
            }
        },
        .smem => try load(r, in, mem, why, word),
        else => unreachable,
    }
}

/// s_load_dword* and s_buffer_load_dword*.
fn load(r: *Scalar, in: *const Instr, mem: rc.Memory, why: *rc.Log, word: u32) Error!void {
    const df = in.d();
    const n = df.d.dwords();
    // (the 21-bit offset: signed bytes for s_load, unsigned for
    // s_buffer_load, as LLVM's assembler takes them for gfx10)
    const buffer = df.s[0].dwords() == 4;
    const imm: i64 = if (buffer) @as(i64, in.imm & 0x1f_ffff) else @as(i21, @bitCast(@as(u21, @truncate(in.imm))));
    const soff: u64 = if (in.src[1] == gfx10.NULL) 0 else r.s[in.src[1]];
    const off: u64 = @as(u64, @bitCast(imm)) +% soff;
    var words: [16]u32 = [_]u32{0} ** 16;
    if (buffer) {
        // s_buffer_load: through a V#, range-checked
        const vd = descriptor(r, in.src[0]);
        const base = vd.base;
        const size: u64 = if (vd.stride == 0) vd.records else @as(u64, vd.records) * vd.stride;
        const first = off & ~@as(u64, 3);
        for (0..n) |j| {
            const at = first +% 4 * @as(u64, j);
            // (the offset is the game's: no sum of it may overflow)
            if (at > size or size - at < 4) continue;
            var b: [4]u8 = undefined;
            if (!mem.read(mem.ctx, (base +% at) & 0xffff_ffff_ffff, &b)) return fail(why, base +% at, word);
            words[j] = std.mem.readInt(u32, &b, .little);
        }
    } else {
        // (the address is 48 bits, as a V#'s base is)
        const at = (r.get64(in.src[0]) +% off) & 0xffff_ffff_fffc;
        var b: [64]u8 = undefined;
        if (!mem.read(mem.ctx, at, b[0 .. 4 * n])) return fail(why, at, word);
        for (0..n) |j| words[j] = std.mem.readInt(u32, b[4 * j ..][0..4], .little);
    }
    for (0..n) |j| {
        const d = in.dst + @as(u16, @intCast(j));
        if (d < 128 and d != gfx10.NULL) r.s[d] = words[j];
    }
}

fn fail(why: *rc.Log, address: u64, word: u32) Error {
    why.set("the scalar load at word {d} could not read memory at 0x{x}", .{ word, address });
    return error.BadMemory;
}

/// A buffer descriptor (V#, section 4.4 of the notes).
pub const Desc = struct {
    base: u64,
    stride: u32,
    swizzle: bool,
    records: u32,
    dst_sel: u16,
    format: u8,
    add_tid: bool,
    /// the type field (0: a buffer)
    kind: u2,
};

pub fn descriptor(r: *const Scalar, code: u16) Desc {
    const w0 = r.s[code];
    const w1 = r.s[code + 1];
    const w2 = r.s[code + 2];
    const w3 = r.s[code + 3];
    return .{
        .base = @as(u64, w0) | (@as(u64, w1 & 0xffff) << 32),
        .stride = (w1 >> 16) & 0x3fff,
        .swizzle = (w1 >> 31) != 0,
        .records = w2,
        .dst_sel = @truncate(w3 & 0xfff),
        .format = @truncate((w3 >> 12) & 0x7f),
        .add_tid = ((w3 >> 23) & 1) != 0,
        .kind = @truncate(w3 >> 30),
    };
}

/// Runs `p`'s scalar side (see recompile.evaluate); `ev`, when given,
/// receives what the lane code reads.
pub fn run(p: *const rc.Program, user: []const u32, code_address: u64, mem: rc.Memory, regs: *Scalar, ev: ?*rc.Evaluation, why: *rc.Log) Error!void {
    regs.* = .{};
    const first: usize = if (p.stage == .vertex) 8 else 0;
    for (user, 0..) |w, k| {
        if (first + k >= gfx10.SGPRS) break;
        regs.s[first + k] = w;
    }
    if (ev) |e| {
        e.n_words = p.words();
        e.n_windows = 0;
        @memset(e.words[0..e.n_words], 0);
    }
    var next_read: usize = 0;
    var next_site: usize = 0;
    var i: u16 = 0;
    while (i < p.n) : (i += 1) {
        if (ev) |e| {
            // what the lane code reads, as it is just before instruction i
            while (next_read < p.n_reads and p.reads[next_read].at == i) : (next_read += 1) {
                const rd = p.reads[next_read];
                e.words[next_read] = if (rd.reg < 128) regs.s[rd.reg] else 0;
            }
            while (next_site < p.n_sites and p.sites[next_site].at == i) : (next_site += 1) {
                try site(p, @intCast(next_site), regs, e, why);
            }
        }
        if (p.side[i] != .scalar) continue;
        const in = &p.insts[i];
        const pc_next = code_address +% 4 * (@as(u64, p.word[i]) + in.dwords());
        try exec(regs, in, pc_next, mem, why, p.word[i]);
    }
    if (ev) |e| e.key = keyOf(p, e);
}

/// Site `s`'s descriptor as a window, its three words and what its code
/// depends on.
fn site(p: *const rc.Program, s: u8, regs: *const Scalar, e: *rc.Evaluation, why: *rc.Log) Error!void {
    const st = p.sites[s];
    const d = descriptor(regs, st.rsrc);
    const in = &p.insts[st.at];
    const w = p.siteWord(s);
    if (d.add_tid) {
        why.set("the buffer load at word {d}: add_tid_enable is not translated", .{p.word[st.at]});
        return error.Unsupported;
    }
    if (d.swizzle and d.stride != 0) {
        why.set("the buffer load at word {d}: swizzled buffers are not translated", .{p.word[st.at]});
        return error.Unsupported;
    }
    e.format[s] = 0;
    e.dst_sel[s] = 0;
    // (a V# whose type is not 0, or whose own format is 0, makes every
    // access out of bounds; a tbuffer load takes its format from the
    // instruction)
    var valid = d.kind == 0 and (st.kind == .tformat or d.format != 0);
    if (st.kind != .raw) {
        const f = if (st.kind == .tformat) in.fmt else d.format;
        if (f == 0) {
            valid = false;
        } else if (rc.formatOf(f) == null) {
            var nb: [32]u8 = undefined;
            why.set("the buffer load at word {d}: format {s} ({d}) is not translated", .{ p.word[st.at], rc.formatName(f, &nb), f });
            return error.Unsupported;
        }
        // (kept when nothing is read: a "one" channel is still 1 in the
        // format's kind)
        e.format[s] = f;
        e.dst_sel[s] = d.dst_sel;
    }
    var bytes: u64 = if (d.stride == 0) d.records else @as(u64, d.records) * d.stride;
    if (!valid) bytes = 0;
    if (bytes > rc.MAX_WINDOW_BYTES) {
        why.set("the buffer load at word {d}: a window of {d} bytes (stride {d}, {d} records), over the {d} MiB one may be", .{ p.word[st.at], bytes, d.stride, d.records, rc.MAX_WINDOW_BYTES >> 20 });
        return error.Unsupported;
    }
    e.words[w] = d.stride;
    e.words[w + 1] = if (valid) d.records else 0;
    e.words[w + 2] = @intCast(bytes);
    if (bytes == 0) {
        e.window_of[s] = rc.NO_WINDOW;
        return;
    }
    const win = rc.Window{ .address = d.base, .bytes = @intCast(bytes) };
    for (e.windows[0..e.n_windows], 0..) |x, j| {
        if (x.address == win.address and x.bytes == win.bytes) {
            e.window_of[s] = @intCast(j);
            return;
        }
    }
    if (e.n_windows >= rc.MAX_WINDOWS) {
        why.set("the buffer load at word {d}: more than {d} windows in one stage", .{ p.word[st.at], rc.MAX_WINDOWS });
        return error.Unsupported;
    }
    e.windows[e.n_windows] = win;
    e.window_of[s] = e.n_windows;
    e.n_windows += 1;
}

/// FNV-1a over what the emitted code depends on.
fn keyOf(p: *const rc.Program, e: *const rc.Evaluation) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    const mix = struct {
        fn f(x: *u64, v: u64) void {
            var k: u64 = v;
            for (0..8) |_| {
                x.* ^= k & 0xff;
                x.* *%= 0x0000_0100_0000_01b3;
                k >>= 8;
            }
        }
    }.f;
    mix(&h, @intFromEnum(p.stage));
    mix(&h, p.n_sites);
    for (0..p.n_sites) |s| {
        mix(&h, e.window_of[s]);
        mix(&h, e.format[s]);
        mix(&h, e.dst_sel[s]);
    }
    return h;
}
