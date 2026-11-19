//! DOS paths and the host's names. A DOS path (drive, '\' or '/', '.' and
//! '..', any case, names cut to 8.3) becomes a canonical one ("DIR\FILE.EXT"
//! from C:'s root), and that becomes the host's path under c_root by
//! listing each folder and matching its entries' DOS names: a host name
//! that is a valid 8.3 name in any case is that name upper-cased; a longer
//! one gets an alias (the first six usable characters, "~N", the first
//! three of its extension) numbered among the folder's names with the
//! same alias stem, in the host's listing order.

const std = @import("std");
const host_mod = @import("host.sig");
const Host = host_mod.Host;
const st_mod = @import("dos_state.sig");
const State = st_mod.State;
const PATH_MAX = st_mod.PATH_MAX;
const DOS_PATH = st_mod.DOS_PATH;

pub const Err = error{ NotFound, PathNotFound, BadDrive, BadName };

/// The DOS error code for a path error (an invalid drive in a path is
/// "path not found", as DOS says).
pub fn code(e: Err) u16 {
    return switch (e) {
        error.NotFound, error.BadName => 2,
        error.PathNotFound, error.BadDrive => 3,
    };
}

pub fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

/// A character DOS allows in a file name.
pub fn nameChar(c: u8) bool {
    if (c >= 0x80) return true;
    if (c <= 0x20) return false;
    return switch (c) {
        '"', '*', '+', ',', '.', '/', ':', ';', '<', '=', '>', '?', '[', '\\', ']', '|', 0x7F => false,
        else => true,
    };
}

// ── 8.3 names ────────────────────────────────────────────────────────────

/// A name's 11-byte FCB form (name and extension blank-padded, upper
/// case; '*' fills its field with '?'). Null: not a name.
pub fn toFcb(name: []const u8) ?[11]u8 {
    var out = [_]u8{' '} ** 11;
    if (std.mem.eql(u8, name, ".")) {
        out[0] = '.';
        return out;
    }
    if (std.mem.eql(u8, name, "..")) {
        out[0] = '.';
        out[1] = '.';
        return out;
    }
    var i: usize = 0;
    var o: usize = 0;
    while (i < name.len and name[i] != '.') : (i += 1) {
        const c = name[i];
        if (c == '*') {
            while (o < 8) : (o += 1) out[o] = '?';
            continue;
        }
        if (c != '?' and !nameChar(c)) return null;
        if (o < 8) {
            out[o] = upper(c);
            o += 1;
        }
    }
    if (i < name.len) {
        i += 1;
        o = 8;
        while (i < name.len) : (i += 1) {
            const c = name[i];
            if (c == '*') {
                while (o < 11) : (o += 1) out[o] = '?';
                continue;
            }
            if (c == '.') return null;
            if (c != '?' and !nameChar(c)) return null;
            if (o < 11) {
                out[o] = upper(c);
                o += 1;
            }
        }
    }
    if (out[0] == ' ') return null;
    return out;
}

/// The FCB form back to "NAME.EXT" (no dot without an extension).
pub fn fromFcb(f: [11]u8, out: *[13]u8) []u8 {
    var n: usize = 0;
    for (f[0..8]) |c| {
        if (c == ' ') break;
        out[n] = c;
        n += 1;
    }
    if (f[8] != ' ') {
        out[n] = '.';
        n += 1;
        for (f[8..11]) |c| {
            if (c == ' ') break;
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

pub fn hasWild(f: [11]u8) bool {
    return std.mem.indexOfScalar(u8, &f, '?') != null;
}

/// DOS's wildcard rule: '?' in the pattern matches any character there.
pub fn matches(pattern: [11]u8, name: [11]u8) bool {
    for (pattern, name) |p, c| {
        if (p != '?' and p != c) return false;
    }
    return true;
}

/// A host name as a valid 8.3 name (upper-cased), or null.
pub fn shortName(name: []const u8) ?[11]u8 {
    if (name.len == 0 or name.len > 12) return null;
    if (name[0] == '.') return null;
    var dot: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '.') {
            if (dot != null) return null;
            dot = i;
        } else if (!nameChar(c)) return null;
    }
    const base_len = dot orelse name.len;
    const ext_len = if (dot) |d| name.len - d - 1 else 0;
    if (base_len == 0 or base_len > 8 or ext_len > 3) return null;
    if (dot != null and ext_len == 0) return null;
    return toFcb(name);
}

/// A long name's alias stem and extension: its usable characters, upper
/// case, the base cut to six, the extension (after the last dot) to three.
pub const Alias = struct { stem: [6]u8 = [_]u8{' '} ** 6, stem_len: u8 = 0, ext: [3]u8 = [_]u8{' '} ** 3 };

pub fn aliasParts(name: []const u8) Alias {
    var r: Alias = .{};
    const last_dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const base_end = if (last_dot) |d| (if (d == 0) name.len else d) else name.len;
    for (name[0..base_end]) |c| {
        if (r.stem_len == 6) break;
        if (c == '.' or !nameChar(c)) continue;
        r.stem[r.stem_len] = upper(c);
        r.stem_len += 1;
    }
    if (r.stem_len == 0) {
        r.stem[0] = '_';
        r.stem_len = 1;
    }
    if (last_dot) |d| if (d > 0) {
        var n: usize = 0;
        for (name[d + 1 ..]) |c| {
            if (n == 3) break;
            if (!nameChar(c)) continue;
            r.ext[n] = upper(c);
            n += 1;
        }
    };
    return r;
}

fn skipEntry(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

/// The DOS name of host entry number `index` (in listing order, "." and
/// ".." counted as the host lists them) named `name` in folder `dir`.
pub fn dosNameOf(host: Host, dir: []const u8, name: []const u8, index: u32) [11]u8 {
    if (shortName(name)) |s| return s;
    const p = aliasParts(name);
    // N: 1 + the long names before it with the same stem and extension.
    var n: u32 = 1;
    if (index > 0) {
        const d = host.dirOpen(dir);
        if (d >= 0) {
            var e: host_mod.DirEntry = .{};
            var i: u32 = 0;
            while (i < index and host.dirNext(d, &e)) : (i += 1) {
                const other = e.str();
                if (skipEntry(other) or shortName(other) != null) continue;
                const q = aliasParts(other);
                if (q.stem_len == p.stem_len and std.mem.eql(u8, &q.stem, &p.stem) and std.mem.eql(u8, &q.ext, &p.ext)) n += 1;
            }
            host.dirClose(d);
        }
    }
    var out = [_]u8{' '} ** 11;
    var digits: [10]u8 = undefined;
    const ds = std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable;
    const keep = @min(@as(usize, p.stem_len), 7 - ds.len);
    @memcpy(out[0..keep], p.stem[0..keep]);
    out[keep] = '~';
    @memcpy(out[keep + 1 ..][0..ds.len], ds);
    @memcpy(out[8..11], &p.ext);
    return out;
}

// ── Canonical DOS paths ──────────────────────────────────────────────────

/// `path` (as a program gives it) made canonical in `out`: upper case,
/// '\'-separated, from the root, no "." or ".."; each name cut to 8.3.
/// Wildcards are kept in the last name (callers that take none check).
pub fn canonical(st: *const State, path: []const u8, out: *[DOS_PATH]u8) Err![]u8 {
    var p = path;
    // Trailing blanks are not part of a name.
    while (p.len > 0 and (p[p.len - 1] == ' ' or p[p.len - 1] == '\t')) p = p[0 .. p.len - 1];
    if (p.len >= 2 and p[1] == ':') {
        const d = upper(p[0]);
        if (d < 'A' or d > 'Z') return error.BadDrive;
        if (d != 'C') return error.BadDrive;
        p = p[2..];
    }
    var n: usize = 0;
    if (p.len == 0 or (p[0] != '\\' and p[0] != '/')) {
        const cwd = st.cwdPath();
        @memcpy(out[0..cwd.len], cwd);
        n = cwd.len;
    }
    var it = std.mem.tokenizeAny(u8, p, "\\/");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (n == 0) return error.PathNotFound;
            while (n > 0 and out[n - 1] != '\\') n -= 1;
            if (n > 0) n -= 1;
            continue;
        }
        const f = toFcb(comp) orelse return error.BadName;
        var nb: [13]u8 = undefined;
        const name = fromFcb(f, &nb);
        if (n + 1 + name.len > DOS_PATH) return error.PathNotFound;
        if (n > 0) {
            out[n] = '\\';
            n += 1;
        }
        @memcpy(out[n..][0..name.len], name);
        n += name.len;
    }
    return out[0..n];
}

/// A canonical path's folder and last name.
pub fn split(canon: []const u8) struct { dir: []const u8, name: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, canon, '\\')) |i| return .{ .dir = canon[0..i], .name = canon[i + 1 ..] };
    return .{ .dir = canon[0..0], .name = canon };
}

/// The character device a name is (whatever its folder and extension).
pub fn device(canon: []const u8) ?st_mod.Kind {
    const name = split(canon).name;
    const base = if (std.mem.indexOfScalar(u8, name, '.')) |i| name[0..i] else name;
    const devs = [_]struct { n: []const u8, k: st_mod.Kind }{
        .{ .n = "CON", .k = .con },     .{ .n = "NUL", .k = .nul },
        .{ .n = "AUX", .k = .aux },     .{ .n = "COM1", .k = .aux },
        .{ .n = "COM2", .k = .aux },    .{ .n = "COM3", .k = .aux },
        .{ .n = "COM4", .k = .aux },    .{ .n = "PRN", .k = .prn },
        .{ .n = "LPT1", .k = .prn },    .{ .n = "LPT2", .k = .prn },
        .{ .n = "LPT3", .k = .prn },    .{ .n = "CLOCK$", .k = .clock },
        .{ .n = "EMMXXXX0", .k = .emm },
    };
    for (devs) |d| if (std.mem.eql(u8, base, d.n)) return d.k;
    return null;
}

// ── Host paths ───────────────────────────────────────────────────────────

pub const HostPath = struct {
    len: u16 = 0,
    buf: [PATH_MAX]u8 = undefined,
    /// The last name exists (as a file, or a folder: `dir`).
    exists: bool = false,
    dir: bool = false,
    pub fn str(self: *const HostPath) []const u8 {
        return self.buf[0..self.len];
    }
    fn set(self: *HostPath, s: []const u8) bool {
        if (s.len > PATH_MAX) return false;
        @memcpy(self.buf[0..s.len], s);
        self.len = @intCast(s.len);
        return true;
    }
    /// Appends "/" + name (no '/' after an empty root or one ending in it).
    pub fn push(self: *HostPath, name: []const u8) bool {
        const sep: usize = if (self.len == 0 or self.buf[self.len - 1] == '/') 0 else 1;
        if (self.len + sep + name.len > PATH_MAX) return false;
        if (sep == 1) self.buf[self.len] = '/';
        @memcpy(self.buf[self.len + sep ..][0..name.len], name);
        self.len += @intCast(sep + name.len);
        return true;
    }
    fn mark(self: *const HostPath) u16 {
        return self.len;
    }
};

/// Finds the entry of host folder `hp` whose DOS name is `want` (FCB form)
/// and appends its real name to `hp`; whether it is a folder, or null.
fn lookup(host: Host, hp: *HostPath, want: [11]u8) ?bool {
    var nb: [13]u8 = undefined;
    const dos = fromFcb(want, &nb);
    const base = hp.mark();
    // The name as DOS spells it, then in lower case (hosts that match
    // case-insensitively, or keep DOS's upper-case names, answer at once).
    var lower_buf: [13]u8 = undefined;
    for (dos, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const tries = [_][]const u8{ dos, lower_buf[0..dos.len] };
    for (tries) |name| {
        if (!hp.push(name)) return null;
        var s: host_mod.Stat = .{};
        if (host.stat(hp.str(), &s)) {
            // (a case-insensitive host's stat: the real spelling may
            // differ; the listing below would give it, and any spelling
            // opens there)
            return s.dir;
        }
        hp.len = base;
    }
    const d = host.dirOpen(hp.str());
    if (d < 0) return null;
    defer host.dirClose(d);
    var e: host_mod.DirEntry = .{};
    var index: u32 = 0;
    while (host.dirNext(d, &e)) : (index += 1) {
        const name = e.str();
        if (skipEntry(name)) continue;
        const f = dosNameOf(host, hp.str(), name, index);
        if (!std.mem.eql(u8, &f, &want)) continue;
        if (!hp.push(name)) return null;
        return e.dir;
    }
    return null;
}

/// A canonical path's host path: every folder must exist; the last name
/// may not (`exists` says, and the path then ends in the DOS name).
pub fn resolve(st: *const State, host: Host, canon: []const u8, out: *HostPath) Err!void {
    out.* = .{};
    if (!out.set(st.rootPath())) return error.PathNotFound;
    if (canon.len == 0) {
        out.exists = true;
        out.dir = true;
        return;
    }
    var it = std.mem.splitScalar(u8, canon, '\\');
    while (it.next()) |comp| {
        const last = it.peek() == null;
        const f = toFcb(comp) orelse return error.BadName;
        if (lookup(host, out, f)) |is_dir| {
            if (last) {
                out.exists = true;
                out.dir = is_dir;
                return;
            }
            if (!is_dir) return error.PathNotFound;
        } else {
            if (!last) return error.PathNotFound;
            if (!out.push(comp)) return error.PathNotFound;
            out.exists = false;
            return;
        }
    }
}

/// The host path of a canonical path's folder (which must exist).
pub fn resolveDir(st: *const State, host: Host, canon_dir: []const u8, out: *HostPath) Err!void {
    try resolve(st, host, canon_dir, out);
    if (!out.exists or !out.dir) return error.PathNotFound;
}

/// A program's path to the host's: canonical, then resolved.
pub fn map(st: *const State, host: Host, path: []const u8, canon_buf: *[DOS_PATH]u8, out: *HostPath) Err![]u8 {
    const canon = try canonical(st, path, canon_buf);
    if (toFcb(split(canon).name)) |f| {
        if (hasWild(f)) return error.NotFound;
    }
    try resolve(st, host, canon, out);
    return canon;
}
