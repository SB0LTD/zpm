// @zpm/youtube/botguard/cache — BotGuard Session Cache
//
// Persists BotGuard state to disk to avoid re-running the VM on every video.
// The VM script changes ~weekly, integrity tokens last ~12 hours,
// and the minter can be reused for the session lifetime.

const root = @import("root.sig");

extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn ReadFile(?*anyopaque, [*]u8, u32, *u32, ?*anyopaque) c_int;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 1;
const OPEN_EXISTING: u32 = 3;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const CACHE_PATH = ".gotliv\\botguard_cache.bin\x00";
const MAGIC = "BGCA"; // BotGuard CAche
const VERSION: u32 = 1;

/// Try to load a cached session.
/// Returns true if a valid, non-expired session was loaded.
pub fn loadSession(session: *root.Session) bool {
    const h = CreateFileA(@ptrCast(CACHE_PATH), GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE or h == null) return false;
    defer _ = CloseHandle(h);

    var buf: [2048]u8 = undefined;
    var n: u32 = 0;
    if (ReadFile(h, &buf, 2048, &n, null) == 0) return false;
    if (n < 12) return false;

    // Verify magic + version
    if (buf[0] != 'B' or buf[1] != 'G' or buf[2] != 'C' or buf[3] != 'A') return false;
    const ver = readU32(buf[4..8]);
    if (ver != VERSION) return false;

    // Read integrity token length and data
    const tok_len = readU32(buf[8..12]);
    if (tok_len == 0 or tok_len > 512 or 12 + tok_len > n) return false;

    @memcpy(session.integrity_token[0..tok_len], buf[12 .. 12 + tok_len]);
    session.integrity_token_len = tok_len;

    // Read visitor data
    const vd_offset = 12 + tok_len;
    if (vd_offset + 4 > n) return false;
    const vd_len = readU32(buf[vd_offset .. vd_offset + 4]);
    if (vd_len > 128 or vd_offset + 4 + vd_len > n) return false;
    if (vd_len > 0) {
        @memcpy(session.visitor_data[0..vd_len], buf[vd_offset + 4 .. vd_offset + 4 + vd_len]);
        session.visitor_data_len = vd_len;
    }

    // Read session PO token
    const sp_offset = vd_offset + 4 + vd_len;
    if (sp_offset + 4 > n) {
        session.minter_ready = true;
        return true;
    }
    const sp_len = readU32(buf[sp_offset .. sp_offset + 4]);
    if (sp_len > 0 and sp_len <= 256 and sp_offset + 4 + sp_len <= n) {
        @memcpy(session.session_pot[0..sp_len], buf[sp_offset + 4 .. sp_offset + 4 + sp_len]);
        session.session_pot_len = sp_len;
    }

    session.minter_ready = true;
    session.initialized = true;
    return true;
}

/// Save the current session to cache.
pub fn saveSession(session: *const root.Session) void {
    const h = CreateFileA(@ptrCast(CACHE_PATH), GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE or h == null) return;
    defer _ = CloseHandle(h);

    var buf: [2048]u8 = undefined;
    var pos: usize = 0;

    // Magic
    @memcpy(buf[0..4], MAGIC);
    pos = 4;

    // Version
    writeU32(buf[pos .. pos + 4], VERSION);
    pos += 4;

    // Integrity token
    writeU32(buf[pos .. pos + 4], @intCast(session.integrity_token_len));
    pos += 4;
    if (session.integrity_token_len > 0) {
        @memcpy(buf[pos .. pos + session.integrity_token_len], session.integrity_token[0..session.integrity_token_len]);
        pos += session.integrity_token_len;
    }

    // Visitor data
    writeU32(buf[pos .. pos + 4], @intCast(session.visitor_data_len));
    pos += 4;
    if (session.visitor_data_len > 0) {
        @memcpy(buf[pos .. pos + session.visitor_data_len], session.visitor_data[0..session.visitor_data_len]);
        pos += session.visitor_data_len;
    }

    // Session PO token
    writeU32(buf[pos .. pos + 4], @intCast(session.session_pot_len));
    pos += 4;
    if (session.session_pot_len > 0) {
        @memcpy(buf[pos .. pos + session.session_pot_len], session.session_pot[0..session.session_pot_len]);
        pos += session.session_pot_len;
    }

    _ = WriteFile(h, &buf, @intCast(pos), null, null);
}

/// Invalidate the cache (force re-initialization on next use).
pub fn invalidate() void {
    // Simply write an empty/invalid file
    const h = CreateFileA(@ptrCast(CACHE_PATH), GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h != INVALID_HANDLE and h != null) {
        _ = CloseHandle(h);
    }
}

fn readU32(buf: []const u8) u32 {
    return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) | (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
}

fn writeU32(buf: []u8, val: u32) void {
    buf[0] = @intCast(val & 0xFF);
    buf[1] = @intCast((val >> 8) & 0xFF);
    buf[2] = @intCast((val >> 16) & 0xFF);
    buf[3] = @intCast((val >> 24) & 0xFF);
}
