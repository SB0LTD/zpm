//! The recompiler's scalar interpreter, analysis and emitted KIR, on
//! shaders LLVM assembled (shader_fixtures.sig, from
//! tools/gen_ps5gfx_fixtures.py): every scalar instruction against
//! results worked out by hand, the lane masks told from scalars at the
//! wave's width, the refusals and their messages, the read slots; then
//! the lane code alone in KIR's interpreter, bit for bit (instructions,
//! compares, buffer loads, the pixel shader's entry and exits).

const std = @import("std");
const rc = @import("recompile.sig");
const fx = @import("shader_fixtures.sig");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const kir = gpu.kir;
const raster = gfxapi.raster;
const gfx10 = rc.gfx10;

const testing = std.testing;

/// A fake address space: `bytes` at `base`.
pub const FakeMemory = struct {
    base: u64,
    bytes: []const u8,

    pub fn memory(m: *FakeMemory) rc.Memory {
        return .{ .ctx = m, .read = read };
    }

    fn read(ctx: ?*anyopaque, address: u64, out: []u8) bool {
        const m: *FakeMemory = @ptrCast(@alignCast(ctx.?));
        if (address < m.base) return false;
        const off = address - m.base;
        if (off > m.bytes.len or m.bytes.len - off < out.len) return false;
        @memcpy(out, m.bytes[@intCast(off)..][0..out.len]);
        return true;
    }

    /// The bytes of window `w`.
    fn window(m: *const FakeMemory, w: rc.Window) []const u8 {
        const off: usize = @intCast(w.address - m.base);
        return m.bytes[off..][0..w.bytes];
    }
};

// (Programs are big: static storage, as a caller keeps them)
var prog: rc.Program = undefined;
var prog2: rc.Program = undefined;

const MEM_BASE: u64 = 0x2_0000_1000;

fn memWords() [64]u32 {
    var w: [64]u32 = undefined;
    for (&w, 0..) |*x, j| x.* = 0xa000_0000 + @as(u32, @intCast(j));
    return w;
}

fn expectLog(log: *const rc.Log, has: []const u8, also: []const u8) !void {
    const t = log.text();
    if (std.mem.indexOf(u8, t, has) == null or std.mem.indexOf(u8, t, also) == null) {
        std.debug.print("log: {s}\nwant: {s} ... {s}\n", .{ t, has, also });
        return error.TestExpectedEqual;
    }
}

fn expectRefused(code: []const u32, stage: rc.Stage, lanes: u8, has: []const u8, also: []const u8) !void {
    var log = rc.Log{};
    rc.analyse(code, stage, lanes, &prog, &log) catch |err| {
        try testing.expectEqual(error.Unsupported, err);
        return expectLog(&log, has, also);
    };
    std.debug.print("accepted, want refused: {s}\n", .{has});
    return error.TestExpectedError;
}

// ── The scalar side ─────────────────────────────────────────────────────────

test "recompile: every scalar instruction, SCC, pairs, loads and s_getpc" {
    var log = rc.Log{};
    try rc.analyse(&fx.scalar_ops, .pixel, 64, &prog, &log);
    var words = memWords();
    var fake = FakeMemory{ .base = MEM_BASE, .bytes = std.mem.sliceAsBytes(&words) };
    // s[4:5]: the memory's address, with junk in the bits past 48 (an
    // address is 48 bits); s[8:11]: a V# at the memory's byte 0x40, no
    // stride, 24 bytes
    const user = [_]u32{ 0x1234_5678, 0x8000_0001, 0xffff_fff0, 7, 0x0000_1000, 0xabcd_0002, 0, 0, 0x0000_1040, 2, 24, 0 };
    var s: rc.Scalar = .{};
    const code_address: u64 = 0x10_0000_0000;
    rc.runScalar(&prog, &user, code_address, fake.memory(), &s, &log) catch |e| {
        std.debug.print("{s}\n", .{log.text()});
        return e;
    };
    const R = s.s;
    // s_getpc_b64 is the first instruction: the next one is 4 bytes on
    try testing.expectEqual(@as(u64, code_address + 4), s.get64(16));
    const want = [_]struct { u16, u32 }{
        .{ 18, 0x1234_5678 }, .{ 19, 0xffff_8000 }, .{ 20, 2 },           .{ 21, 1 },
        .{ 22, 0xffff_fffe }, .{ 23, 1 },           .{ 24, 0x8000_0000 }, .{ 25, 2 },
        .{ 26, 0x7fff_ffff }, .{ 27, 8 },           .{ 28, 0xffff_ffeb }, .{ 29, 0x1200_5600 },
        .{ 30, 0x107 },       .{ 31, 0xedcb_a987 }, .{ 32, 0x1234_0000 }, .{ 33, 0xf },
        .{ 34, 0xffff_fff8 }, .{ 35, 0xe000_0000 }, .{ 36, 0xf },         .{ 37, 0xffff_fffc },
        .{ 38, 0x56 },        .{ 39, 0xffff_fffc }, .{ 40, 0xf00 },       .{ 41, 0x8000_0001 },
        .{ 42, 7 },           .{ 43, 7 },           .{ 44, 0x8000_0001 }, .{ 45, 0x12c },
        // 64-bit pairs
        .{ 46, 0x1234_5678 }, .{ 47, 0x8000_0001 }, .{ 48, 0xffff_ff00 }, .{ 49, 0x7f },
        .{ 50, 0x07ff_ffff }, .{ 51, 0 },           .{ 52, 0x1234_5670 }, .{ 53, 1 },
        .{ 54, 0x1234_5679 }, .{ 55, 0x8000_0001 }, .{ 56, 0xedcb_a987 }, .{ 57, 0x7fff_fffe },
        .{ 58, 0xf },         .{ 59, 0xffff_fff8 },
        // compares into SCC, read by s_cselect
        .{ 60, 7 },           .{ 61, 1 },           .{ 62, 1 },           .{ 63, 0 },
        .{ 64, 3 },           .{ 65, 4 },           .{ 66, 0xffff_fff0 }, .{ 67, 7 },
        // loads: words 4 and 5; byte 7 rounded down to word 1; through
        // the V# (byte 0x40 + 0x10 = word 20): 20, 21, then out of its 24
        // bytes: 0, 0
        .{ 68, 0xa000_0004 }, .{ 69, 0xa000_0005 }, .{ 70, 0xa000_0001 },
        .{ 72, 0xa000_0014 }, .{ 73, 0xa000_0015 }, .{ 74, 0 },           .{ 75, 0 },
    };
    for (want) |w| {
        if (R[w[0]] != w[1]) {
            std.debug.print("s{d}: got 0x{x}, want 0x{x}\n", .{ w[0], R[w[0]], w[1] });
            return error.TestExpectedEqual;
        }
    }
    // (the last compare, s_cmp_lg_u64 of equal pairs, left SCC clear)
    try testing.expect(!s.scc);
    // a load from memory that is not there fails with BadMemory
    const bad_user = [_]u32{ 0, 0, 0, 0, 0x0000_9000, 2, 0, 0, 0x0000_1040, 2, 24, 0 };
    try testing.expectError(error.BadMemory, rc.runScalar(&prog, &bad_user, code_address, fake.memory(), &s, &log));
    try testing.expect(std.mem.indexOf(u8, log.text(), "could not read memory") != null);
}

/// An s_buffer_load instruction's words, built with the encoder (LLVM
/// will not write an offset with bit 20 set).
fn sbufferLoad(op_name: []const u8, dst: u16, imm: u32, soffset: u16, out: []u32) usize {
    const in = gfx10.Instr{ .op = gfx10.lookup(op_name).?, .dst = dst, .src = .{ 8, soffset, 0 }, .imm = imm };
    return gfx10.encode(&in, out) catch unreachable;
}

test "recompile: scalar buffer loads at any offset: no sum traps, out of range reads 0" {
    // s_buffer_load_dword s20, s[8:11], 0x1ffffc; the same with soffset
    // s3 = 0xfffffffc; s_buffer_load_dwordx2 s[22:23] at 0x10 (in range,
    // then past), s_endpgm
    var code: [16]u32 = undefined;
    var n: usize = 0;
    n += sbufferLoad("s_buffer_load_dword", 20, 0x1f_fffc, gfx10.NULL, code[n..]);
    n += sbufferLoad("s_buffer_load_dword", 21, 0x1f_fffc, 3, code[n..]);
    n += sbufferLoad("s_buffer_load_dwordx2", 22, 0x14, gfx10.NULL, code[n..]);
    code[n] = 0xbf81_0000;
    n += 1;
    var log = rc.Log{};
    try rc.analyse(code[0..n], .pixel, 64, &prog, &log);
    var words = memWords();
    var fake = FakeMemory{ .base = MEM_BASE, .bytes = std.mem.sliceAsBytes(&words) };
    const user = [_]u32{ 0, 0, 0, 0xffff_fffc, 0, 0, 0, 0, 0x0000_1000, 2, 24, 0 };
    var s: rc.Scalar = .{};
    s.s[20] = 0x5555;
    try rc.runScalar(&prog, &user, 0, fake.memory(), &s, &log);
    try testing.expectEqual(@as(u32, 0), s.s[20]);
    try testing.expectEqual(@as(u32, 0), s.s[21]);
    try testing.expectEqual(@as(u32, 0xa000_0005), s.s[22]);
    try testing.expectEqual(@as(u32, 0), s.s[23]);
}

// ── Lane masks ──────────────────────────────────────────────────────────────

test "recompile: a lane mask in an SGPR pair is pred logic, a scalar pair is the interpreter's" {
    var log = rc.Log{};
    try rc.analyse(&fx.mask_pair, .pixel, 64, &prog, &log);
    try testing.expectEqual(@as(u16, 6), prog.n);
    try testing.expectEqual(rc.Side.lane, prog.side[0]); // v_cmp into s[4:5]
    try testing.expectEqual(rc.Side.mask, prog.side[1]); // s_and_b64 s[6:7], exec, s[4:5]
    try testing.expectEqual(rc.Side.scalar, prog.side[2]); // s_mov_b64 s[8:9], s[10:11]
    try testing.expectEqual(rc.Side.lane, prog.side[3]); // v_cndmask by s[6:7]
    try testing.expectEqual(rc.Side.lane, prog.side[4]); // v_mov_b32 v4, s8
    // the one scalar lane code reads: s8, as defined by s_mov_b64
    try testing.expectEqual(@as(u16, 1), prog.n_reads);
    try testing.expectEqual(@as(u16, 8), prog.reads[0].reg);
    try testing.expectEqual(@as(u16, 0), prog.slot[4][0]);
    try testing.expectEqual(rc.NO_SLOT, prog.slot[3][0]);
    var ev: rc.Evaluation = .{};
    var none = FakeMemory{ .base = 0, .bytes = &.{} };
    const user = [_]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x4242_0000, 0x77 };
    try rc.evaluate(&prog, &user, 0, none.memory(), &ev, &log);
    try testing.expectEqual(@as(u32, 1), ev.n_words);
    try testing.expectEqual(@as(u32, 0x4242_0000), ev.words[0]);
    // the same code is no 32-lane program: s_and_b64 on a one-register
    // mask
    try expectRefused(&fx.mask_pair, .pixel, 32, "s_and_b64 s[6:7], exec, s[4:5]", "EXEC only as a whole 32-lane mask");

    try expectRefused(&fx.mask_mixed, .pixel, 64, "s_and_b64 s[6:7], s[4:5], s[10:11]", "mixes a lane mask with a scalar value");
    try expectRefused(&fx.mask_as_scalar, .pixel, 64, "s_add_u32 s6, s4, 1", "part of a lane mask");
}

test "recompile: lane masks at the wave's width: the four unsound programs and their kin are refused" {
    // (a) 32 lanes: a mask in s5 copied as the pair s[4:5]
    try expectRefused(&fx.mask_a, .pixel, 32, "s_mov_b64 s[6:7], s[4:5]", "wrong width for 32-lane code");
    // (b) 32 lanes: the pair shifted as a number
    try expectRefused(&fx.mask_b, .pixel, 32, "s_lshr_b64 s[6:7], s[4:5], 1", "part of a lane mask");
    // (c) 64 lanes: one half overwritten, the pair used as a mask
    try expectRefused(&fx.mask_c, .pixel, 64, "v_cndmask_b32_e64 v3, 0, 1.0, s[4:5]", "its mask is part of a lane mask");
    // (d) 32 lanes: a mask moved as a pair, its high register used
    try expectRefused(&fx.mask_d, .pixel, 32, "s_mov_b64 s[0:1], s[2:3]", "wrong width");
    // a 64-lane mask into an odd register; 32-bit logic on half a pair
    try expectRefused(&fx.mask_odd, .pixel, 64, "v_cmp_gt_f32_e64", "odd register");
    try expectRefused(&fx.mask_b32_on64, .pixel, 64, "s_and_b32 s6, s4, exec_lo", "part of a lane mask");
    // s_cselect on SCC from mask logic
    try expectRefused(&fx.scc_lane_cselect, .pixel, 64, "s_cselect_b64 s[8:9], -1, 0", "reads SCC set by logic on lane masks");
    // 32 lanes: the register after a mask is a register of its own
    var log = rc.Log{};
    try rc.analyse(&fx.mask_next32, .pixel, 32, &prog, &log);
    try testing.expectEqual(@as(u16, 1), prog.n_reads);
    try testing.expectEqual(@as(u16, 5), prog.reads[0].reg);
    // ... and in 64-lane code it is the mask's high half
    try expectRefused(&fx.mask_next32, .pixel, 64, "v_cndmask_b32_e64 v3, 0, 1.0, s[4:5]", "part of a lane mask");
}

test "recompile: a branch, an EXEC write and an unknown instruction are refused by name" {
    try expectRefused(&fx.branch, .pixel, 64, "s_cbranch_scc1 1", "branches are not translated");
    try expectRefused(&fx.exec_write, .pixel, 32, "s_mov_b32 exec_lo, s0", "writes EXEC");
    try expectRefused(&fx.unknown, .pixel, 32, "v_sin_f32", "not translated");
    var log = rc.Log{};
    // words that decode to nothing, and code without s_endpgm
    const junk = [_]u32{0xffff_ffff};
    try testing.expectError(error.BadCode, rc.analyse(&junk, .pixel, 32, &prog, &log));
    try expectLog(&log, "word 0 (0xffffffff)", "not a gfx10 instruction");
    try testing.expectError(error.BadCode, rc.analyse(fx.redefine[0 .. fx.redefine.len - 1], .pixel, 32, &prog, &log));
    try expectLog(&log, "no s_endpgm", "");
    try testing.expectError(error.Unsupported, rc.analyse(&fx.redefine, .pixel, 16, &prog, &log));
}

test "recompile: a scalar redefined between two lane reads gets two slots" {
    var log = rc.Log{};
    try rc.analyse(&fx.redefine, .pixel, 32, &prog2, &log);
    try testing.expectEqual(@as(u16, 2), prog2.n_reads);
    // the first two reads share the user's s0; the third is s_mov_b32's
    try testing.expectEqual(@as(u16, 0), prog2.slot[0][0]);
    try testing.expectEqual(@as(u16, 0), prog2.slot[1][0]);
    try testing.expectEqual(@as(u16, 1), prog2.slot[3][0]);
    var ev: rc.Evaluation = .{};
    var none = FakeMemory{ .base = 0, .bytes = &.{} };
    const user = [_]u32{@bitCast(@as(f32, 0.25))};
    try rc.evaluate(&prog2, &user, 0, none.memory(), &ev, &log);
    try testing.expectEqual(@as(u32, 2), ev.n_words);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 0.25))), ev.words[0]);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 2.0))), ev.words[1]);
}

test "recompile: the vertex fetch's analysis: slots, sites, exports" {
    var log = rc.Log{};
    try rc.analyse(&fx.vs_fetch, .vertex, 32, &prog, &log);
    // three buffer loads, through the V#s s[24:27], s[28:31], s[52:55]
    try testing.expectEqual(@as(u8, 3), prog.n_sites);
    try testing.expectEqual(@as(u16, 24), prog.sites[0].rsrc);
    try testing.expectEqual(@as(u16, 28), prog.sites[1].rsrc);
    try testing.expectEqual(@as(u16, 52), prog.sites[2].rsrc);
    try testing.expectEqual(rc.SiteKind.format, prog.sites[0].kind);
    // lane code reads s22, s50, s57 (the compares), s49 (the colour's
    // soffset) and the sixteen matrix words
    try testing.expectEqual(@as(u16, 20), prog.n_reads);
    try testing.expectEqual(@as(u32, 20 + 3 * 3), prog.words());
    try testing.expect(prog.position);
    try testing.expectEqual(@as(u32, 0b11), prog.params);
}

test "recompile: buffer formats are named and converted" {
    try testing.expectEqual(rc.Format{ .bits = 8, .comps = 4, .nfmt = .unorm }, rc.formatOf(56).?);
    try testing.expectEqual(rc.Format{ .bits = 32, .comps = 3, .nfmt = .float }, rc.formatOf(74).?);
    try testing.expectEqual(rc.Format{ .bits = 32, .comps = 1, .nfmt = .uint }, rc.formatOf(20).?);
    try testing.expectEqual(rc.Format{ .bits = 16, .comps = 2, .nfmt = .float }, rc.formatOf(29).?);
    try testing.expectEqual(rc.Format{ .bits = 16, .comps = 4, .nfmt = .float }, rc.formatOf(71).?);
    try testing.expectEqual(@as(?rc.Format, null), rc.formatOf(36));
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("10_11_11 float", rc.formatName(36, &b));
    try testing.expectEqualStrings("8_8_8_8 unorm", rc.formatName(56, &b));
}

/// A V#: linear, `stride` bytes a record, `records` of them, `format`,
/// channels routed by `sel`.
pub fn vsharp(addr: u64, stride: u32, records: u32, format: u8, sel: u32) [4]u32 {
    return .{ @truncate(addr), (@as(u32, @truncate(addr >> 32)) & 0xffff) | (stride << 16), records, sel | (@as(u32, format) << 12) };
}

pub const IDENTITY_SEL: u32 = 0xfac;

test "recompile: a window past its cap is refused, for no stride and for a stride" {
    var log = rc.Log{};
    try rc.analyse(&fx.huge_window, .vertex, 32, &prog, &log);
    var none = FakeMemory{ .base = 0, .bytes = &.{} };
    var ev: rc.Evaluation = .{};
    var user: [8]u32 = undefined;
    @memcpy(user[0..4], &vsharp(0x1000, 0, 0xffff_ffff, 20, IDENTITY_SEL));
    try testing.expectError(error.Unsupported, rc.evaluate(&prog, &user, 0, none.memory(), &ev, &log));
    try expectLog(&log, "a window of 4294967295 bytes", "over the 256 MiB");
    @memcpy(user[0..4], &vsharp(0x1000, 16, 0x0200_0000, 20, IDENTITY_SEL));
    try testing.expectError(error.Unsupported, rc.evaluate(&prog, &user, 0, none.memory(), &ev, &log));
    try expectLog(&log, "a window of 536870912 bytes", "over the 256 MiB");
    // at the cap: a window
    @memcpy(user[0..4], &vsharp(0x1000, 0, rc.MAX_WINDOW_BYTES, 20, IDENTITY_SEL));
    try rc.evaluate(&prog, &user, 0, none.memory(), &ev, &log);
    try testing.expectEqual(rc.MAX_WINDOW_BYTES, ev.windows[0].bytes);
}

// ── The emitted KIR, run alone in KIR's interpreter ─────────────────────────

var k_insts: [8192]kir.Inst = undefined;
var k_tys: [8192]kir.Ty = undefined;
var k_work: [1 << 20]u8 align(64) = undefined;
var win_mem: [rc.MAX_WINDOWS][256]u8 align(16) = undefined;
var no_bytes: [0]u8 = .{};

/// Runs kernel `k` (one thread) with `binds` as its bindings.
fn runOne(k: *kir.Kernel, binds: []const []u8) !void {
    try k.finish();
    var w = gpu.Work.init(&k_work);
    var trap: gpu.interp.Trap = .{};
    _ = gpu.interp.runKernel(k, gpu.interp_caps, .{ 1, 1, 1 }, binds, &.{}, &w, &trap) catch |err| {
        std.debug.print("trap {s} at {d}, binding {d} offset {d}\n", .{ @tagName(trap.what), trap.pc, trap.binding, trap.offset });
        return err;
    };
}

fn storeAll(k: *kir.Kernel, b: u8, vals: []const kir.V) void {
    for (vals, 0..) |v, j| {
        var m = kir.global(b, 32);
        m.imm = @intCast(4 * j);
        const x = if (v == .none) k.mov(.u32, kir.u(0)) else k.mov(.u32, kir.r(v));
        k.store(.u32, m, kir.u(0), kir.r(x));
    }
}

/// The bindings: the uniform words, the outputs, then each window (its
/// bytes from `mem`, exactly as long as it is), as `bindings` of them.
fn bindingsOf(uni: []u32, out: []u32, ev: *const rc.Evaluation, mem: *const FakeMemory, bindings: u8, binds: *[2 + rc.MAX_WINDOWS][]u8) []const []u8 {
    binds[0] = std.mem.sliceAsBytes(uni);
    binds[1] = std.mem.sliceAsBytes(out);
    for (0..bindings) |j| {
        if (j < ev.n_windows) {
            const src = mem.window(ev.windows[j]);
            @memcpy(win_mem[j][0..src.len], src);
            binds[2 + j] = win_mem[j][0..src.len];
        } else binds[2 + j] = &no_bytes;
    }
    return binds[0 .. 2 + bindings];
}

/// Runs the vertex program `p` (analysed) for vertex `vid` with `user`:
/// its varyings into `out`.
fn runVertex(p: *const rc.Program, user: []const u32, mem: *FakeMemory, vid: u32, base_vertex: u32, first_instance: u32, out: []u32) !void {
    var log = rc.Log{};
    var ev: rc.Evaluation = .{};
    rc.evaluate(p, user, 0, mem.memory(), &ev, &log) catch |err| {
        std.debug.print("{s}\n", .{log.text()});
        return err;
    };
    var uni: [rc.MAX_WORDS + 2]u32 = undefined;
    const n = ev.n_words;
    @memcpy(uni[0..n], ev.words[0..n]);
    uni[n] = base_vertex;
    uni[n + 1] = first_instance;
    const lay = rc.Layout{ .base_vertex_word = n, .first_instance_word = n + 1, .varyings = 64 };
    var k = kir.Kernel.init(.{ .insts = &k_insts, .tys = &k_tys }, "vs", .{ 1, 1, 1 });
    const b_uni = k.binding();
    const b_out = k.binding();
    const bb = k.bindings;
    for (0..p.bindings()) |_| _ = k.binding();
    var io = raster.VertexIO{ .vertex_id = k.mov(.u32, kir.u(vid)), .instance_id = k.mov(.u32, kir.u(0)), .uniforms = b_uni, .buffers = bb };
    rc.emitVertex(p, &ev, lay, &k, &io);
    storeAll(&k, b_out, io.varying[0..out.len]);
    var binds: [2 + rc.MAX_WINDOWS][]u8 = undefined;
    try runOne(&k, bindingsOf(uni[0 .. n + 2], out, &ev, mem, p.bindings(), &binds));
}

fn expectWords(want: []const u32, got: []const u32, first_vgpr: usize) !void {
    for (want, 0..) |x, j| {
        if (got[j] != x) {
            std.debug.print("v{d}: got 0x{x}, want 0x{x}\n", .{ first_vgpr + j, got[j], x });
            return error.TestExpectedEqual;
        }
    }
}

fn fb(x: f32) u32 {
    return @bitCast(x);
}

test "recompile: every lane instruction's result, bit for bit, in KIR's interpreter" {
    var log = rc.Log{};
    try rc.analyse(&fx.vs_alu, .vertex, 32, &prog, &log);
    var none = FakeMemory{ .base = 0, .bytes = &.{} };
    const user = [_]u32{ fb(2.5), @bitCast(@as(i32, -3)), 0x1234_5678, fb(4.0) };
    var out: [64]u32 = undefined;
    // vertex 5 with base vertex 100, instance 0 with first instance 7
    try runVertex(&prog, &user, &none, 5, 100, 7, &out);
    const want = [64]u32{
        0x4020_0000, 0x4060_0000, 0xbfc0_0000, 0x3fc0_0000, // v20..v23
        0x4120_0000, 0x4110_0000, 0xc118_0000, 0x40c0_0000,
        0xc080_0000, 0x3f80_0000, 0x3e80_0000, 0x3f00_0000,
        0x3fc0_0000, 0xc040_0000, 0x4040_0000, 0xc000_0000,
        0x4000_0000, 0x3f40_0000, 0xc040_0000, 0x4380_0000,
        0x3e22_f983, 0xffff_fffe, 0, 0xc000_3c00,
        0x4120_0000, 0x3fa0_0000, 0, 0x42ac_0000,
        0x1200_5600, 0x1234_567f, 0xedcb_a987, 2, // v48..
        0x2345_6780, 0x0123_4567, 0xffff_fffe, 7,
        0xffff_fff3, 13, 0xc962_fc98, 0x1234,
        0x456, 0xffff_fff8, 0xf00, 0x5678,
        8, 0x13, 0x79, 12,
        0xffff_fffd, 1, 1, 0xffff_fffd,
        0x68_acf0, 0xffff_fff1, 0x68_acf1, 0x0234_5678,
        1, 1, 0, 1,
        1, 0, 105, 7, // v80..v83
    };
    try expectWords(&want, &out, 20);
}

test "recompile: compares with NaN and infinity, unsigned compares, mask logic and uniform masks" {
    var log = rc.Log{};
    try rc.analyse(&fx.vs_cmp, .vertex, 32, &prog, &log);
    var none = FakeMemory{ .base = 0, .bytes = &.{} };
    const user = [_]u32{ 0x7fc0_0000, 0x7f80_0000, fb(1.0), 0xffff_fffe, 5 };
    var out: [28]u32 = undefined;
    try runVertex(&prog, &user, &none, 0, 0, 0, &out);
    const want = [28]u32{
        0, 1, 1, 0, 0, 1, 0, 1, // s20..s27: NaN against 1 and itself
        1, 0, 1, 1, 0, 1, 0, // s28..s34: infinity
        1, 1, 1, 0, 0, // s35..s39: unsigned and signed
        0, 0, 1, 1, // s40..s43: logic on masks
        1, 0, 1, // s44..s46: uniform masks
        7,
    };
    try expectWords(&want, &out, 20);
    // the uniform masks follow the scalar: s12 = 6 makes s44 none and s45
    // every lane, and s46 (s44 and a lane mask) none
    const user6 = [_]u32{ 0x7fc0_0000, 0x7f80_0000, fb(1.0), 0xffff_fffe, 6 };
    try runVertex(&prog, &user6, &none, 0, 0, 0, &out);
    try testing.expectEqual(@as(u32, 0), out[24]);
    try testing.expectEqual(@as(u32, 1), out[25]);
    try testing.expectEqual(@as(u32, 0), out[26]);
}

test "recompile: s_bfe_i32 and v_bfe_i32 agree, inside and past bit 31" {
    var log = rc.Log{};
    try rc.analyse(&fx.bfe_both, .vertex, 32, &prog, &log);
    var none = FakeMemory{ .base = 0, .bytes = &.{} };
    var out: [4]u32 = undefined;
    // 0x8f000000: bits 28.. as 8 signed bits are the sign's copies: -8;
    // bits 24..27: 0xf, -1
    try runVertex(&prog, &[_]u32{0x8f00_0000}, &none, 0, 0, 0, &out);
    try testing.expectEqualSlices(u32, &.{ 0xffff_fff8, 0xffff_fff8, 0xffff_ffff, 0xffff_ffff }, &out);
    // a positive source: 4 and 7
    try runVertex(&prog, &[_]u32{0x4700_0000}, &none, 0, 0, 0, &out);
    try testing.expectEqualSlices(u32, &.{ 4, 4, 7, 7 }, &out);
}

const LOADS_BASE: u64 = 0x5_0000_0000;

test "recompile: lane buffer loads: raw, offen, bytes, records, no stride, no window, formats" {
    var log = rc.Log{};
    try rc.analyse(&fx.vs_loads, .vertex, 32, &prog, &log);
    var mem: [0x100]u8 align(4) = [_]u8{0} ** 0x100;
    const put = struct {
        fn f(m: *[0x100]u8, at: usize, w: u32) void {
            std.mem.writeInt(u32, m[at..][0..4], w, .little);
        }
    }.f;
    // A: raw, 20 bytes
    put(&mem, 0x00, 0x8091_f27f);
    put(&mem, 0x04, 0x1111_1111);
    put(&mem, 0x08, 0x2222_2222);
    put(&mem, 0x0c, 0x3333_3333);
    put(&mem, 0x10, 0x4444_4444);
    // (what lies past A's 20 bytes is not A's)
    put(&mem, 0x14, 0xdead_beef);
    // B: two records of 4 bytes
    put(&mem, 0x40, 0xb0b0_b0b0);
    put(&mem, 0x44, 0xb1b1_b1b1);
    // C: 16_16 snorm, record 1 = (0x8000, 0x4000)
    put(&mem, 0x64, 0x4000_8000);
    // D: 16_16_16_16 float, record 1 = (1.5, -2, 0.25, 7) as halves
    put(&mem, 0x88, 0xc000_3e00);
    put(&mem, 0x8c, 0x4700_3400);
    // F: 8_8 unorm (the instruction's format), record 1 = (0x33, 0xcc)
    put(&mem, 0xa0, 0xcc33_0000);
    // H: 16 unorm, record 1 = 0xffff
    put(&mem, 0xc0, 0xffff_0000);
    var fake = FakeMemory{ .base = LOADS_BASE, .bytes = &mem };
    var user: [28]u32 = undefined;
    const sel_d: u32 = 4 | (5 << 3) | (1 << 6) | (7 << 9); // X, Y, one, W
    const sel_e: u32 = 4 | (5 << 3) | (1 << 6) | (1 << 9); // X, Y, one, one
    @memcpy(user[0..4], &vsharp(LOADS_BASE, 0, 20, 20, IDENTITY_SEL));
    @memcpy(user[4..8], &vsharp(LOADS_BASE + 0x40, 4, 2, 20, IDENTITY_SEL));
    @memcpy(user[8..12], &vsharp(LOADS_BASE + 0x60, 4, 2, 24, IDENTITY_SEL));
    @memcpy(user[12..16], &vsharp(LOADS_BASE + 0x80, 8, 2, 71, sel_d));
    @memcpy(user[16..20], &vsharp(LOADS_BASE + 0xe0, 4, 0, 56, sel_e));
    @memcpy(user[20..24], &vsharp(LOADS_BASE + 0xa0, 2, 2, 20, IDENTITY_SEL));
    @memcpy(user[24..28], &vsharp(LOADS_BASE + 0xc0, 2, 2, 7, IDENTITY_SEL));
    var out: [36]u32 = undefined;
    try runVertex(&prog, &user, &fake, 1, 0, 0, &out);
    const want = [36]u32{
        // offen 8, four dwords of a 20-byte window: three in, one past
        0x2222_2222, 0x3333_3333, 0x4444_4444, 0,
        0x4444_4444, 0, // the last dword; past the bytes
        0xf2, 0xffff_fff2, 0x8091, 0xffff_8091, // ubyte, sbyte, ushort, sshort
        8, 0x4000_0001,
        0, // index 0x40000001 * 4 wraps to 4: past the records
        0xb1b1_b1b1, // record 1
        0, // record 1 + 4: past the bytes
        fb(-1.0), fb(16384.0 / 32767.0), // snorm, clamped at -1
        fb(1.5), fb(-2.0), fb(1.0), fb(7.0), // halves, a "one" channel
        2, 0, 0, fb(1.0), 0, // past the records: 0, 0, 1, 0
        0, 0, fb(1.0), fb(1.0), // no window: 0, 0, 1, 1
        fb(51.0 / 255.0), fb(204.0 / 255.0), // tbuffer's own format
        0x1111_1111, 0, 0, // no stride: the index adds nothing
        fb(1.0), // 16 unorm
    };
    try expectWords(&want, &out, 20);
}

// ── The pixel shader's entry and exits ─────────────────────────────────────

/// Runs the pixel program `p` with `user` in layout `lay` for the pixel
/// at the engine's (10.5, 3.5), depth 0.25, 1/w 0.5, a back face, in a
/// target 32 high: colour 0, 1 and 2's channels, then the depth.
fn runPixel(p: *const rc.Program, user: []const u32, lay_in: rc.Layout, out: *[13]u32) !void {
    var log = rc.Log{};
    var ev: rc.Evaluation = .{};
    var none = FakeMemory{ .base = 0, .bytes = &.{} };
    try rc.evaluate(p, user, 0, none.memory(), &ev, &log);
    try rc.checkPixel(p, lay_in, &log);
    var lay = lay_in;
    const n = ev.n_words;
    lay.height_word = n;
    var uni: [rc.MAX_WORDS + 1]u32 = undefined;
    @memcpy(uni[0..n], ev.words[0..n]);
    uni[n] = fb(32);
    var k = kir.Kernel.init(.{ .insts = &k_insts, .tys = &k_tys }, "ps", .{ 1, 1, 1 });
    const b_uni = k.binding();
    const b_out = k.binding();
    var io = raster.FragmentIO{ .uniforms = b_uni, .buffers = 2 };
    io.frag_coord = .{ k.mov(.f32, kir.f(10.5)), k.mov(.f32, kir.f(3.5)), k.mov(.f32, kir.f(0.25)), k.mov(.f32, kir.f(0.5)) };
    io.front_facing = k.mov(.pred, kir.u(0));
    rc.emitFragment(p, &ev, lay, &k, &io);
    const vals = [13]kir.V{ io.color[0], io.color[1], io.color[2], io.color[3], io.colors[1][0], io.colors[1][1], io.colors[1][2], io.colors[1][3], io.colors[2][0], io.colors[2][1], io.colors[2][2], io.colors[2][3], io.depth };
    storeAll(&k, b_out, &vals);
    var binds: [2 + rc.MAX_WINDOWS][]u8 = undefined;
    try runOne(&k, bindingsOf(uni[0 .. n + 1], out, &ev, &none, 0, &binds));
}

fn setupOf(enabled: u16, color_formats: u32) rc.state.PixelSetup {
    return .{ .inputs = 0, .lanes = 64, .enabled = enabled, .placed = enabled, .color_formats = color_formats, .may_kill = false, .writes_depth = false };
}

test "recompile: the pixel shader's position (y from the top), w, facing and fixed-point position" {
    var log = rc.Log{};
    try rc.analyse(&fx.ps_builtins, .pixel, 64, &prog, &log);
    var lay = rc.Layout{};
    lay.setup = setupOf(0x9f00, 0x99);
    var out: [13]u32 = undefined;
    try runPixel(&prog, &.{}, lay, &out);
    // the engine's y 3.5 (from the bottom) in a target 32 high: 28.5
    const fixed: u32 = 10 | (28 << 16);
    try testing.expectEqualSlices(u32, &.{ fb(10.5), fb(28.5), fb(0.25), fb(2.0), fb(-1.0), fixed, fixed, fixed }, out[0..8]);
}

test "recompile: 32_R, 32_GR and 32_AR colour formats, and the depth" {
    var log = rc.Log{};
    try rc.analyse(&fx.ps_exports, .pixel, 64, &prog, &log);
    var lay = rc.Layout{ .depth_export = true };
    lay.setup = setupOf(0, 0x321);
    var out: [13]u32 = undefined;
    try runPixel(&prog, &.{}, lay, &out);
    try testing.expectEqualSlices(u32, &.{
        fb(0.5), 0,        0, fb(1.0), // 32_R
        fb(0.5), fb(0.25), 0, fb(1.0), // 32_GR
        fb(0.5), 0,        0, fb(0.25), // 32_AR: alpha the second word
        fb(0.75), // the depth
    }, &out);
    // without depth export, mrtz is not the depth
    lay.depth_export = false;
    try runPixel(&prog, &.{}, lay, &out);
    try testing.expectEqual(@as(u32, 0), out[12]);
}

fn srgbRef(x: f64) f64 {
    return if (x <= 0.0031308) 12.92 * x else 1.055 * std.math.pow(f64, x, 1.0 / 2.4) - 0.055;
}

test "recompile: an sRGB target's colour is encoded from linear, alpha as it is" {
    var log = rc.Log{};
    try rc.analyse(&fx.ps_user4, .pixel, 64, &prog, &log);
    var lay = rc.Layout{ .srgb = true };
    lay.setup = setupOf(0, 9);
    const sets = [2][4]f32{ .{ 0.0, 0.002, 0.2, 0.3 }, .{ 0.5, 0.8, 1.0, 0.7 } };
    for (sets) |v| {
        var out: [13]u32 = undefined;
        try runPixel(&prog, &.{ fb(v[0]), fb(v[1]), fb(v[2]), fb(v[3]) }, lay, &out);
        for (0..3) |c| {
            const got: f64 = @as(f32, @bitCast(out[c]));
            const want = srgbRef(v[c]);
            if (@abs(got - want) > 1.0 / 255.0) {
                std.debug.print("srgb({d}): got {d}, want {d}\n", .{ v[c], got, want });
                return error.TestExpectedEqual;
            }
        }
        try testing.expectEqual(fb(v[3]), out[3]);
    }
    // not sRGB: as it is
    lay.srgb = false;
    var out: [13]u32 = undefined;
    try runPixel(&prog, &.{ fb(0.2), 0, 0, 0 }, lay, &out);
    try testing.expectEqual(fb(0.2), out[0]);
}

test "recompile: the sRGB encoding's worst error over 0..1" {
    var worst: f64 = 0;
    var base: u32 = 0;
    while (base < 4096) : (base += 256) {
        var k = kir.Kernel.init(.{ .insts = &k_insts, .tys = &k_tys }, "srgb", .{ 1, 1, 1 });
        const b_out = k.binding();
        var vals: [256]kir.V = undefined;
        for (&vals, 0..) |*v, j| v.* = @import("recompile_emit.sig").srgbEncode(&k, k.mov(.f32, kir.f(@as(f32, @floatFromInt(base + j)) / 4095.0)));
        storeAll(&k, b_out, &vals);
        var out: [256]u32 = undefined;
        const binds = [_][]u8{std.mem.sliceAsBytes(&out)};
        try runOne(&k, &binds);
        for (out, 0..) |o, j| {
            const x: f32 = @as(f32, @floatFromInt(base + @as(u32, @intCast(j)))) / 4095.0;
            const e = @abs(@as(f64, @as(f32, @bitCast(o))) - srgbRef(x));
            worst = @max(worst, e);
        }
    }
    // (the comment at srgbEncode states the worst measured)
    try testing.expect(worst < 1e-6);
}

test "recompile: a pixel layout the emitter cannot draw is refused" {
    var log = rc.Log{};
    try rc.analyse(&fx.ps_tint, .pixel, 32, &prog, &log);
    try testing.expectEqual(@as(u32, 0b111), prog.inputs);
    try testing.expectEqual(@as(u32, 0b110), prog.flat_reads);
    try testing.expectEqual(@as(u32, 0b001), prog.interp_reads);
    var lay = rc.Layout{};
    lay.setup = .{ .inputs = 3, .lanes = 32, .enabled = 0x302, .placed = 0x302, .color_formats = 4, .may_kill = false, .writes_depth = false };
    lay.inputs[0] = .{ .slot = 0, .flat = false, .default = 0, .halves = false };
    lay.inputs[1] = .{ .slot = 1, .flat = true, .default = 0, .halves = false };
    lay.inputs[2] = .{ .slot = null, .flat = false, .default = 3, .halves = false };
    try rc.checkPixel(&prog, lay, &log);
    // v_interp_mov_f32 of a smooth input
    lay.inputs[1].flat = false;
    try testing.expectError(error.Unsupported, rc.checkPixel(&prog, lay, &log));
    try expectLog(&log, "v_interp_mov_f32 reads input 1", "not flat");
    lay.inputs[1].flat = true;
    // an each-vertex input interpolated
    lay.inputs[0].each_vertex = true;
    lay.inputs[0].flat = true;
    try testing.expectError(error.Unsupported, rc.checkPixel(&prog, lay, &log));
    try expectLog(&log, "interpolate input 0", "each vertex's");
    lay.inputs[0] = .{ .slot = 0, .flat = false, .default = 0, .halves = false };
    // a compressed export into a 32-bit colour format
    lay.setup.color_formats = 9;
    try testing.expectError(error.Unsupported, rc.checkPixel(&prog, lay, &log));
    try expectLog(&log, "mrt0: colour format 9", "compressed");
    lay.setup.color_formats = 4;
    // an input past the setup's
    lay.setup.inputs = 2;
    try testing.expectError(error.Unsupported, rc.checkPixel(&prog, lay, &log));
    try expectLog(&log, "reads input 2", "the setup has 2");
}

test "recompile: a 64-lane uniform mask from s_cselect_b64, alone and with a lane mask" {
    var log = rc.Log{};
    try rc.analyse(&fx.umask64, .pixel, 64, &prog, &log);
    // s4 is read as a word, for both of its uses
    try testing.expectEqual(@as(u16, 1), prog.n_reads);
    try testing.expectEqual(@as(u16, 4), prog.reads[0].reg);
    var lay = rc.Layout{};
    lay.setup = setupOf(0x100, 9); // v0: the pixel's x (10.5 > 0.5)
    var out: [13]u32 = undefined;
    try runPixel(&prog, &.{5}, lay, &out);
    try testing.expectEqualSlices(u32, &.{ fb(1), fb(1), fb(1), fb(1) }, out[0..4]);
    try runPixel(&prog, &.{6}, lay, &out);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, out[0..4]);
}

test "recompile: a pipeline's layout key and whether it reads a flat value" {
    var log = rc.Log{};
    const P = struct {
        var a: rc.Pair = .{};
    };
    const setup = rc.state.PixelSetup{ .inputs = 3, .lanes = 32, .enabled = 0x302, .placed = 0x302, .color_formats = 4, .may_kill = false, .writes_depth = false };
    const in0 = rc.state.PixelInput{ .slot = 0, .flat = false, .default = 0, .halves = false };
    const in1 = rc.state.PixelInput{ .slot = 1, .flat = true, .default = 0, .halves = false };
    const in2 = rc.state.PixelInput{ .slot = null, .flat = false, .default = 3, .halves = false };
    try P.a.init(&fx.vs_fetch, 32, &fx.ps_tint, setup, &.{ in0, in1, in2 }, false, &log);
    try testing.expect(P.a.flat());
    const k1 = P.a.layoutKey();
    try P.a.init(&fx.vs_fetch, 32, &fx.ps_tint, setup, &.{ in0, in1, in2 }, true, &log);
    try testing.expect(k1 != P.a.layoutKey());
    var s2 = setup;
    s2.color_formats = 0;
    try P.a.init(&fx.vs_fetch, 32, &fx.ps_tint, s2, &.{ in0, in1, in2 }, false, &log);
    try testing.expect(k1 != P.a.layoutKey());
    try P.a.init(&fx.vs_fetch, 32, &fx.ps_tint, setup, &.{ in0, in1, in2 }, false, &log);
    try testing.expectEqual(k1, P.a.layoutKey());
    // input 1 from a slot the vertex side does not export: its default,
    // and then nothing flat is read
    const in1x = rc.state.PixelInput{ .slot = 9, .flat = true, .default = 0, .halves = false };
    try P.a.init(&fx.vs_fetch, 32, &fx.ps_tint, setup, &.{ in0, in1x, in2 }, false, &log);
    try testing.expectEqual(@as(?u5, null), P.a.ps_lay.inputs[1].slot);
    try testing.expect(!P.a.flat());
}
