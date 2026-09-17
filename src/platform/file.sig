// File I/O via Win32 — read small config files into stack buffers
// Layer 1: Platform

const w32 = @import("win32");

/// Max config file size (8 KB should be plenty)
const MAX_FILE_SIZE = 8192;

pub const FileBuffer = struct {
    data: [MAX_FILE_SIZE]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const FileBuffer) []const u8 {
        return self.data[0..self.len];
    }
};

// ── Directory listing ───────────────────────────────────────────────

pub const MAX_DIR_ENTRIES: usize = 64;
pub const MAX_NAME_LEN: usize = 128;

/// A single directory entry's file name (ASCII, from the UTF-16 cFileName).
pub const DirEntry = struct {
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    len: usize = 0,
    pub fn slice(self: *const DirEntry) []const u8 {
        return self.name[0..self.len];
    }
};

pub const DirListing = struct {
    entries: [MAX_DIR_ENTRIES]DirEntry = [_]DirEntry{.{}} ** MAX_DIR_ENTRIES,
    count: usize = 0,
};

/// List files in `dir_utf16` (a directory path with NO trailing slash) whose
/// names end with `ext` (e.g. ".pine"). Files only (skips subdirectories).
/// Names are returned ASCII-downconverted (non-ASCII bytes dropped). Sorted by
/// insertion (FindFirstFile order); callers sort if they need a stable order.
pub fn listDir(dir_utf16: []const u16, ext: []const u8, out: *DirListing) usize {
    out.count = 0;

    // Build "<dir>\*" search pattern in UTF-16.
    var pat: [w32.MAX_PATH]u16 = undefined;
    var pi: usize = 0;
    for (dir_utf16) |c| {
        if (c == 0) break;
        if (pi >= w32.MAX_PATH - 3) break;
        pat[pi] = c;
        pi += 1;
    }
    pat[pi] = '\\';
    pi += 1;
    pat[pi] = '*';
    pi += 1;
    pat[pi] = 0;

    var fd: w32.WIN32_FIND_DATAW = .{};
    const h = w32.FindFirstFileW(@ptrCast(&pat), &fd);
    if (h == w32.INVALID_HANDLE_VALUE) return 0;
    defer _ = w32.FindClose(h);

    while (true) {
        const is_dir = (fd.dwFileAttributes & w32.FILE_ATTRIBUTE_DIRECTORY) != 0;
        if (!is_dir) {
            // Down-convert cFileName (UTF-16) to ASCII.
            var name: [MAX_NAME_LEN]u8 = undefined;
            var nl: usize = 0;
            var k: usize = 0;
            while (k < fd.cFileName.len and fd.cFileName[k] != 0) : (k += 1) {
                const ch = fd.cFileName[k];
                if (ch < 128 and nl < MAX_NAME_LEN) {
                    name[nl] = @intCast(ch);
                    nl += 1;
                }
            }
            if (endsWith(name[0..nl], ext) and out.count < MAX_DIR_ENTRIES) {
                var e = &out.entries[out.count];
                @memcpy(e.name[0..nl], name[0..nl]);
                e.len = nl;
                out.count += 1;
            }
        }
        if (w32.FindNextFileW(h, &fd) == 0) break;
    }
    return out.count;
}

fn endsWith(s: []const u8, suffix: []const u8) bool {
    if (suffix.len > s.len) return false;
    return eqlBytes(s[s.len - suffix.len ..], suffix);
}
fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Read an entire file into a stack buffer. Returns null on failure.
pub fn readFileToBuffer(path: w32.LPCWSTR) ?FileBuffer {
    const handle = w32.CreateFileW(
        path,
        w32.GENERIC_READ,
        w32.FILE_SHARE_READ,
        null,
        w32.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == w32.INVALID_HANDLE_VALUE) return null;
    defer _ = w32.CloseHandle(handle);

    var buf = FileBuffer{};
    var bytes_read: u32 = 0;
    const ok = w32.ReadFile(handle, &buf.data, MAX_FILE_SIZE, &bytes_read, null);
    if (ok == 0) return null;
    buf.len = bytes_read;
    return buf;
}
