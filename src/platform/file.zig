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
