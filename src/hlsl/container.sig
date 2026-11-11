//! @zpm/hlsl container — the DXBC container Direct3D loads: its chunks
//! (RDEF reflection, ISGN/OSGN/OSG5 signatures, SHDR/SHEX code, STAT
//! statistics) and the header's checksum, DXBC's variant of MD5 over
//! everything after it (the runtime refuses a blob whose checksum is
//! wrong). And the reader of RDEF for D3DReflect.

const std = @import("std");

// ── the checksum ───────────────────────────────────────────────────────────

/// DXBC's checksum of `data` (the container from byte 20): MD5's rounds,
/// with the length placed as the last block's first word (bits) and last
/// word (2 * bytes + 1) instead of MD5's tail.
pub fn checksum(data: []const u8) [4]u32 {
    var st = [4]u32{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 };
    const n: u32 = @intCast(data.len);
    const full = data.len / 64;
    for (0..full) |b| {
        var x: [16]u32 = undefined;
        for (0..16) |k| x[k] = std.mem.readInt(u32, data[b * 64 + k * 4 ..][0..4], .little);
        md5Block(&st, &x);
    }
    const left = data.len - full * 64;
    var tail: [128]u8 = [_]u8{0} ** 128;
    if (left < 56) {
        // one block: [bits][data][0x80 0...][2n+1]
        std.mem.writeInt(u32, tail[0..4], n << 3, .little);
        @memcpy(tail[4..][0..left], data[full * 64 ..]);
        tail[4 + left] = 0x80;
        std.mem.writeInt(u32, tail[60..64], (n << 1) | 1, .little);
        var x: [16]u32 = undefined;
        for (0..16) |k| x[k] = std.mem.readInt(u32, tail[k * 4 ..][0..4], .little);
        md5Block(&st, &x);
    } else {
        // two: [data][0x80 0...] then [bits][0...][2n+1]
        @memcpy(tail[0..left], data[full * 64 ..]);
        tail[left] = 0x80;
        var x: [16]u32 = undefined;
        for (0..16) |k| x[k] = std.mem.readInt(u32, tail[k * 4 ..][0..4], .little);
        md5Block(&st, &x);
        @memset(&x, 0);
        x[0] = n << 3;
        x[15] = (n << 1) | 1;
        md5Block(&st, &x);
    }
    return st;
}

fn md5Block(st: *[4]u32, x: *const [16]u32) void {
    const s = [64]u5{ 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21 };
    const K = comptime blk: {
        var k: [64]u32 = undefined;
        for (0..64) |i| k[i] = @intFromFloat(@floor(@abs(@sin(@as(f64, @floatFromInt(i + 1)))) * 4294967296.0));
        break :blk k;
    };
    var a = st[0];
    var b = st[1];
    var c = st[2];
    var d = st[3];
    for (0..64) |i| {
        var f: u32 = undefined;
        var g: usize = undefined;
        if (i < 16) {
            f = (b & c) | (~b & d);
            g = i;
        } else if (i < 32) {
            f = (d & b) | (~d & c);
            g = (5 * i + 1) % 16;
        } else if (i < 48) {
            f = b ^ c ^ d;
            g = (3 * i + 5) % 16;
        } else {
            f = c ^ (b | ~d);
            g = (7 * i) % 16;
        }
        const t = d;
        d = c;
        c = b;
        b = b +% std.math.rotl(u32, a +% f +% K[i] +% x[g], s[i]);
        a = t;
    }
    st[0] +%= a;
    st[1] +%= b;
    st[2] +%= c;
    st[3] +%= d;
}

/// Writes a blob's checksum into its header.
pub fn sign(blob: []u8) void {
    const c = checksum(blob[20..]);
    for (0..4) |k| std.mem.writeInt(u32, blob[4 + k * 4 ..][0..4], c[k], .little);
}

// ── a byte writer ──────────────────────────────────────────────────────────

pub const W = struct {
    buf: []u8,
    n: usize = 0,
    over: bool = false,

    pub fn u32_(w: *W, v: u32) void {
        if (w.n + 4 > w.buf.len) {
            w.over = true;
            return;
        }
        std.mem.writeInt(u32, w.buf[w.n..][0..4], v, .little);
        w.n += 4;
    }

    pub fn u16_(w: *W, v: u16) void {
        if (w.n + 2 > w.buf.len) {
            w.over = true;
            return;
        }
        std.mem.writeInt(u16, w.buf[w.n..][0..2], v, .little);
        w.n += 2;
    }

    pub fn bytes(w: *W, s: []const u8) void {
        if (w.n + s.len > w.buf.len) {
            w.over = true;
            return;
        }
        @memcpy(w.buf[w.n..][0..s.len], s);
        w.n += s.len;
    }

    pub fn str(w: *W, s: []const u8) u32 {
        const at: u32 = @intCast(w.n);
        w.bytes(s);
        w.bytes(&.{0});
        return at;
    }

    /// Pads to 4 bytes with 0xab (as fxc does).
    pub fn pad(w: *W) void {
        while (w.n % 4 != 0 and !w.over) w.bytes(&.{0xab});
    }

    pub fn patch(w: *W, at: usize, v: u32) void {
        if (at + 4 <= w.buf.len) std.mem.writeInt(u32, w.buf[at..][0..4], v, .little);
    }
};

// ── signatures ─────────────────────────────────────────────────────────────

pub const SigElem = struct {
    name: []const u8,
    index: u32,
    /// D3D_NAME
    sys: u32,
    /// D3D_REGISTER_COMPONENT_TYPE
    comp: u32,
    reg: u32,
    mask: u8,
    rw: u8,
    stream: u32 = 0,
};

/// An ISGN/OSGN chunk's bytes (OSG5 with `streams`).
pub fn signature(w: *W, elems: []const SigElem, streams: bool) void {
    const base = w.n;
    w.u32_(@intCast(elems.len));
    w.u32_(8);
    const stride: usize = if (streams) 28 else 24;
    const table = w.n;
    for (elems) |_| {
        for (0..stride / 4) |_| w.u32_(0);
    }
    for (elems, 0..) |e, k| {
        // (one copy of each name)
        var off: ?u32 = null;
        for (elems[0..k], 0..) |p, j| {
            if (std.mem.eql(u8, p.name, e.name)) {
                off = std.mem.readInt(u32, w.buf[table + j * stride + (stride - 24) ..][0..4], .little);
                break;
            }
        }
        const name_off = off orelse @as(u32, @intCast(w.str(e.name) - base));
        var at = table + k * stride;
        if (streams) {
            w.patch(at, e.stream);
            at += 4;
        }
        w.patch(at, name_off);
        w.patch(at + 4, e.index);
        w.patch(at + 8, e.sys);
        w.patch(at + 12, e.comp);
        w.patch(at + 16, e.reg);
        w.patch(at + 20, @as(u32, e.mask) | (@as(u32, e.rw) << 8));
    }
    w.pad();
}

// ── reflection (RDEF) ──────────────────────────────────────────────────────

/// D3D_SHADER_VARIABLE_CLASS
pub const SVC = struct {
    pub const scalar: u16 = 0;
    pub const vector: u16 = 1;
    pub const matrix_rows: u16 = 2;
    pub const matrix_columns: u16 = 3;
    pub const object: u16 = 4;
    pub const structure: u16 = 5;
};

/// D3D_SHADER_VARIABLE_TYPE (the numeric ones)
pub const SVT = struct {
    pub const void_: u16 = 0;
    pub const bool_: u16 = 1;
    pub const int: u16 = 2;
    pub const float: u16 = 3;
    pub const uint: u16 = 19;
    pub const double: u16 = 39;
};

pub const RType = struct {
    class: u16,
    type: u16,
    rows: u16,
    cols: u16,
    elements: u16,
    /// structs: their members (RMember indices)
    first: u32 = 0,
    nmembers: u16 = 0,
    name: []const u8 = "",
};

pub const RMember = struct { name: []const u8, ty: u32, offset: u32 };

pub const RVar = struct {
    name: []const u8,
    offset: u32,
    size: u32,
    /// D3D_SVF_USED (2), USERPACKED (1)
    flags: u32,
    ty: u32,
};

pub const RBuffer = struct {
    name: []const u8,
    first: u32,
    nvars: u32,
    size: u32,
    flags: u32 = 0,
    /// D3D_CBUFFER_TYPE: 0 cbuffer, 1 tbuffer
    kind: u32 = 0,
};

pub const RBind = struct {
    name: []const u8,
    /// D3D_SHADER_INPUT_TYPE: 0 cbuffer, 1 tbuffer, 2 texture, 3 sampler
    type: u32,
    /// D3D_RESOURCE_RETURN_TYPE
    ret: u32 = 0,
    /// D3D_SRV_DIMENSION
    dim: u32 = 0,
    samples: u32 = 0,
    bind: u32,
    count: u32 = 1,
    flags: u32 = 0,
};

pub const MAX_R = 512;

/// A shader's reflection, as written and as read back.
pub const Reflection = struct {
    types: [MAX_R * 2]RType = undefined,
    ntypes: u32 = 0,
    members: [MAX_R * 2]RMember = undefined,
    nmembers: u32 = 0,
    vars: [MAX_R]RVar = undefined,
    nvars: u32 = 0,
    bufs: [32]RBuffer = undefined,
    nbufs: u32 = 0,
    binds: [MAX_R]RBind = undefined,
    nbinds: u32 = 0,
    /// 0xFFFE (vertex), 0xFFFF (pixel), 0x4753 (geometry) and the version
    program: u32 = 0,
    flags: u32 = 0,
    creator: []const u8 = "",

    pub fn addType(r: *Reflection, t: RType) u32 {
        if (r.ntypes >= r.types.len) return 0;
        r.types[r.ntypes] = t;
        r.ntypes += 1;
        return r.ntypes - 1;
    }

    // ── writing ──

    /// The RDEF chunk's bytes; `sm5` writes RD11's longer records.
    pub fn write(r: *const Reflection, w: *W, sm5: bool) void {
        const base = w.n;
        const var_size: usize = if (sm5) 40 else 24;
        const type_size: usize = if (sm5) 36 else 16;
        // header
        w.u32_(r.nbufs);
        const cb_off_at = w.n;
        w.u32_(0);
        w.u32_(r.nbinds);
        const bind_off_at = w.n;
        w.u32_(0);
        w.u32_(r.program);
        w.u32_(r.flags);
        const creator_at = w.n;
        w.u32_(0);
        if (sm5) {
            w.bytes("RD11");
            w.u32_(60);
            w.u32_(24);
            w.u32_(32);
            w.u32_(@intCast(var_size));
            w.u32_(@intCast(type_size));
            w.u32_(12);
            w.u32_(0);
        }
        // the bindings
        w.patch(bind_off_at, @intCast(w.n - base));
        const binds_at = w.n;
        for (0..r.nbinds) |_| {
            for (0..8) |_| w.u32_(0);
        }
        // the buffers
        w.patch(cb_off_at, @intCast(w.n - base));
        const bufs_at = w.n;
        for (0..r.nbufs) |_| {
            for (0..6) |_| w.u32_(0);
        }
        // each buffer's variables
        var vars_at: [32]usize = undefined;
        for (r.bufs[0..r.nbufs], 0..) |b, k| {
            vars_at[k] = w.n;
            for (0..b.nvars * var_size / 4) |_| w.u32_(0);
        }
        // names, types: as they come
        for (r.binds[0..r.nbinds], 0..) |b, k| {
            const at = binds_at + k * 32;
            w.patch(at, @intCast(w.str(b.name) - base));
            w.patch(at + 4, b.type);
            w.patch(at + 8, b.ret);
            w.patch(at + 12, b.dim);
            w.patch(at + 16, b.samples);
            w.patch(at + 20, b.bind);
            w.patch(at + 24, b.count);
            w.patch(at + 28, b.flags);
        }
        w.pad();
        for (r.bufs[0..r.nbufs], 0..) |b, k| {
            const at = bufs_at + k * 24;
            w.patch(at, @intCast(w.str(b.name) - base));
            w.patch(at + 4, b.nvars);
            w.patch(at + 8, @intCast(vars_at[k] - base));
            w.patch(at + 12, b.size);
            w.patch(at + 16, b.flags);
            w.patch(at + 20, b.kind);
        }
        w.pad();
        var type_off: [MAX_R * 2]u32 = undefined;
        var type_done: [MAX_R * 2]bool = undefined;
        @memset(type_done[0..r.ntypes], false);
        for (r.bufs[0..r.nbufs], 0..) |b, k| {
            for (0..b.nvars) |j| {
                const v = r.vars[b.first + j];
                const at = vars_at[k] + j * var_size;
                w.patch(at, @intCast(w.str(v.name) - base));
                w.pad();
                w.patch(at + 4, v.offset);
                w.patch(at + 8, v.size);
                w.patch(at + 12, v.flags);
                w.patch(at + 16, r.writeType(w, base, v.ty, sm5, &type_off, &type_done));
                w.patch(at + 20, 0);
                if (sm5) {
                    w.patch(at + 24, 0xffff_ffff);
                    w.patch(at + 28, 0);
                    w.patch(at + 32, 0xffff_ffff);
                    w.patch(at + 36, 0);
                }
            }
        }
        w.patch(creator_at, @intCast(w.str(r.creator) - base));
        w.pad();
    }

    fn writeType(r: *const Reflection, w: *W, base: usize, ty: u32, sm5: bool, off: *[MAX_R * 2]u32, done: *[MAX_R * 2]bool) u32 {
        if (done[ty]) return off[ty];
        const t = r.types[ty];
        // members first (their types, names), then this type
        var moff: u32 = 0;
        if (t.nmembers > 0) {
            var mt: [64]u32 = undefined;
            var mn: [64]u32 = undefined;
            const nm = @min(t.nmembers, 64);
            for (0..nm) |k| {
                const m = r.members[t.first + k];
                mn[k] = @intCast(w.str(m.name) - base);
                w.pad();
                mt[k] = r.writeType(w, base, m.ty, sm5, off, done);
            }
            moff = @intCast(w.n - base);
            for (0..nm) |k| {
                w.u32_(mn[k]);
                w.u32_(mt[k]);
                w.u32_(r.members[t.first + k].offset);
            }
        }
        var name_off: u32 = 0;
        if (sm5) {
            name_off = @intCast(w.str(t.name) - base);
            w.pad();
        }
        const at: u32 = @intCast(w.n - base);
        w.u16_(t.class);
        w.u16_(t.type);
        w.u16_(t.rows);
        w.u16_(t.cols);
        w.u16_(t.elements);
        w.u16_(t.nmembers);
        w.u32_(moff);
        if (sm5) {
            w.u32_(0);
            w.u32_(0);
            w.u32_(0);
            w.u32_(0);
            w.u32_(name_off);
        }
        off[ty] = at;
        done[ty] = true;
        return at;
    }

    // ── reading ──

    /// Reads an RDEF chunk (its bytes) into `r`; false when damaged.
    pub fn read(r: *Reflection, d: []const u8) bool {
        r.* = .{};
        if (d.len < 28) return false;
        const ncb = rd(d, 0);
        const cb_off = rd(d, 4);
        const nb = rd(d, 8);
        const b_off = rd(d, 12);
        r.program = rd(d, 16);
        r.flags = rd(d, 20);
        r.creator = cstr(d, rd(d, 24));
        const sm5 = d.len >= 32 and std.mem.eql(u8, d[28..32], "RD11");
        const var_size: u32 = if (sm5) 40 else 24;
        if (nb > MAX_R or ncb > 32) return false;
        for (0..nb) |k| {
            const at = b_off + @as(u32, @intCast(k)) * 32;
            if (at + 32 > d.len) return false;
            r.binds[k] = .{ .name = cstr(d, rd(d, at)), .type = rd(d, at + 4), .ret = rd(d, at + 8), .dim = rd(d, at + 12), .samples = rd(d, at + 16), .bind = rd(d, at + 20), .count = rd(d, at + 24), .flags = rd(d, at + 28) };
        }
        r.nbinds = nb;
        for (0..ncb) |k| {
            const at = cb_off + @as(u32, @intCast(k)) * 24;
            if (at + 24 > d.len) return false;
            const nv = rd(d, at + 4);
            const voff = rd(d, at + 8);
            r.bufs[k] = .{ .name = cstr(d, rd(d, at)), .first = r.nvars, .nvars = nv, .size = rd(d, at + 12), .flags = rd(d, at + 16), .kind = rd(d, at + 20) };
            for (0..nv) |j| {
                const va = voff + @as(u32, @intCast(j)) * var_size;
                if (va + var_size > d.len or r.nvars >= MAX_R) return false;
                const ty = r.readType(d, rd(d, va + 16), sm5) orelse return false;
                r.vars[r.nvars] = .{ .name = cstr(d, rd(d, va)), .offset = rd(d, va + 4), .size = rd(d, va + 8), .flags = rd(d, va + 12), .ty = ty };
                r.nvars += 1;
            }
        }
        r.nbufs = ncb;
        return true;
    }

    fn readType(r: *Reflection, d: []const u8, at: u32, sm5: bool) ?u32 {
        if (at + 16 > d.len) return null;
        var t = RType{
            .class = rd16(d, at),
            .type = rd16(d, at + 2),
            .rows = rd16(d, at + 4),
            .cols = rd16(d, at + 6),
            .elements = rd16(d, at + 8),
            .nmembers = rd16(d, at + 10),
        };
        if (sm5 and at + 36 <= d.len) t.name = cstr(d, rd(d, at + 32));
        const moff = rd(d, at + 12);
        const me = r.nmembers;
        if (t.nmembers > 0) {
            if (r.nmembers + t.nmembers > r.members.len) return null;
            r.nmembers += t.nmembers;
            for (0..t.nmembers) |k| {
                const ma = moff + @as(u32, @intCast(k)) * 12;
                if (ma + 12 > d.len) return null;
                const mty = r.readType(d, rd(d, ma + 4), sm5) orelse return null;
                r.members[me + k] = .{ .name = cstr(d, rd(d, ma)), .ty = mty, .offset = rd(d, ma + 8) };
            }
        }
        t.first = me;
        return r.addType(t);
    }

    /// Whether two types are the same (recursively; names ignored).
    pub fn sameType(a: *const Reflection, ta: u32, b: *const Reflection, tb: u32) bool {
        const x = a.types[ta];
        const y = b.types[tb];
        if (x.class != y.class or x.type != y.type or x.rows != y.rows or x.cols != y.cols or x.elements != y.elements or x.nmembers != y.nmembers) return false;
        for (0..x.nmembers) |k| {
            const mx = a.members[x.first + k];
            const my = b.members[y.first + k];
            if (!std.mem.eql(u8, mx.name, my.name) or mx.offset != my.offset) return false;
            if (!sameType(a, mx.ty, b, my.ty)) return false;
        }
        return true;
    }
};

fn rd(d: []const u8, at: u32) u32 {
    if (at + 4 > d.len) return 0;
    return std.mem.readInt(u32, d[at..][0..4], .little);
}

fn rd16(d: []const u8, at: u32) u16 {
    if (at + 2 > d.len) return 0;
    return std.mem.readInt(u16, d[at..][0..2], .little);
}

fn cstr(d: []const u8, at: u32) []const u8 {
    if (at >= d.len) return "";
    return std.mem.sliceTo(d[at..], 0);
}

// ── the container ──────────────────────────────────────────────────────────

pub const Chunk = struct { tag: *const [4]u8, data: []const u8 };

/// Writes the container (header, chunk offsets, chunks) and signs it; the
/// size, or null when `out` is too small.
pub fn container(out: []u8, chunks: []const Chunk) ?usize {
    var w = W{ .buf = out };
    w.bytes("DXBC");
    for (0..4) |_| w.u32_(0);
    w.u32_(1);
    const size_at = w.n;
    w.u32_(0);
    w.u32_(@intCast(chunks.len));
    const offs = w.n;
    for (chunks) |_| w.u32_(0);
    for (chunks, 0..) |c, k| {
        w.patch(offs + k * 4, @intCast(w.n));
        w.bytes(c.tag);
        w.u32_(@intCast(c.data.len));
        w.bytes(c.data);
    }
    if (w.over) return null;
    w.patch(size_at, @intCast(w.n));
    sign(out[0..w.n]);
    return w.n;
}

/// A container's chunk by tag.
pub fn findChunk(blob: []const u8, tag: []const u8) ?[]const u8 {
    if (blob.len < 32 or !std.mem.eql(u8, blob[0..4], "DXBC")) return null;
    const total = @min(rd(blob, 24), @as(u32, @intCast(blob.len)));
    const n = rd(blob, 28);
    for (0..n) |k| {
        const off = rd(blob, 32 + @as(u32, @intCast(k)) * 4);
        if (off + 8 > total) return null;
        const size = rd(blob, off + 4);
        if (off + 8 + size > total) return null;
        if (std.mem.eql(u8, blob[off..][0..4], tag)) return blob[off + 8 ..][0..size];
    }
    return null;
}

test "checksum: an empty-ish container signs and checks" {
    var buf: [256]u8 = undefined;
    const n = container(&buf, &.{.{ .tag = "TEST", .data = "abcd" }}).?;
    const c = checksum(buf[20..n]);
    try std.testing.expectEqual(c[0], std.mem.readInt(u32, buf[4..8], .little));
}
