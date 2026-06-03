// Linux platform shim for zpm transport layer.
// Provides the same API surface as the win32 module so that conn.sig, crypto.sig,
// udp.sig, etc. can `@import("linux_platform")` with no source changes beyond the
// import path.
//
// Uses only std.os.linux syscalls -- no libc dependency.

const std = @import("std");
const linux = std.os.linux;
const crypto = std.crypto;

// ============================================================================
// Socket / Network Constants
// ============================================================================

pub const AF_INET: u16 = 2;
pub const SOCK_DGRAM: u32 = 2;
pub const IPPROTO_UDP: u32 = 17;
pub const FIONBIO: u32 = 0x5421;
pub const INVALID_SOCKET: i32 = -1;
pub const SOCKET_ERROR: i32 = -1;
pub const WSAEWOULDBLOCK: i32 = 11; // EAGAIN
pub const WSAECONNRESET: i32 = 104; // ECONNRESET

pub const SOCKET = i32;

pub const sockaddr_in = extern struct {
    sin_family: u16 = AF_INET,
    sin_port: u16 = 0,
    sin_addr: u32 = 0,
    sin_zero: [8]u8 = @as([8]u8, @splat(0)),
};

pub const WSADATA = struct {};

// ============================================================================
// Timing Types
// ============================================================================

pub const LARGE_INTEGER = extern struct {
    QuadPart: i64 = 0,
};

// ============================================================================
// Misc Types
// ============================================================================

pub const DWORD = u32;

// ============================================================================
// Winsock-compatible Network Functions
// ============================================================================

/// No-op on Linux -- sockets are always available.
pub fn WSAStartup(version: u16, data: *WSADATA) i32 {
    _ = version;
    _ = data;
    return 0;
}

/// Returns the current thread-local errno as a positive integer.
pub fn WSAGetLastError() i32 {
    return last_error;
}

threadlocal var last_error: i32 = 0;

fn setLastError(rc: usize) void {
    const signed: isize = @bitCast(rc);
    if (signed < 0) {
        last_error = @intCast(-signed);
    } else {
        last_error = 0;
    }
}

/// Create a socket. Returns file descriptor or INVALID_SOCKET on error.
pub fn socket(af: u16, sock_type: u32, protocol: u32) SOCKET {
    const rc = linux.syscall3(
        .socket,
        @as(usize, af),
        @as(usize, sock_type),
        @as(usize, protocol),
    );
    setLastError(rc);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return INVALID_SOCKET;
    return @intCast(signed);
}

/// Bind a socket to an address.
pub fn bind(sock: SOCKET, addr: *const sockaddr_in, len: u32) i32 {
    const rc = linux.syscall3(
        .bind,
        @as(usize, @intCast(sock)),
        @intFromPtr(addr),
        @as(usize, len),
    );
    setLastError(rc);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return SOCKET_ERROR;
    return 0;
}

/// Receive a datagram, populating source address.
pub fn recvfrom(
    sock: SOCKET,
    buf: [*]u8,
    len: i32,
    flags: u32,
    src_addr: *sockaddr_in,
    addr_len: *i32,
) i32 {
    const rc = linux.syscall6(
        .recvfrom,
        @as(usize, @intCast(sock)),
        @intFromPtr(buf),
        @as(usize, @intCast(len)),
        @as(usize, flags),
        @intFromPtr(src_addr),
        @intFromPtr(addr_len),
    );
    setLastError(rc);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return SOCKET_ERROR;
    return @intCast(signed);
}

/// Send a datagram to a destination address.
pub fn sendto(
    sock: SOCKET,
    buf: [*]const u8,
    len: i32,
    flags: u32,
    dest: *const sockaddr_in,
    addr_len: u32,
) i32 {
    const rc = linux.syscall6(
        .sendto,
        @as(usize, @intCast(sock)),
        @intFromPtr(buf),
        @as(usize, @intCast(len)),
        @as(usize, flags),
        @intFromPtr(dest),
        @as(usize, addr_len),
    );
    setLastError(rc);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return SOCKET_ERROR;
    return @intCast(signed);
}

/// Close a socket (Linux close()).
pub fn closesocket(sock: SOCKET) i32 {
    const rc = linux.syscall1(.close, @as(usize, @intCast(sock)));
    setLastError(rc);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return SOCKET_ERROR;
    return 0;
}

/// Get the local address bound to a socket.
pub fn getsockname(sock: SOCKET, addr: *sockaddr_in, len: *i32) i32 {
    const rc = linux.syscall3(
        .getsockname,
        @as(usize, @intCast(sock)),
        @intFromPtr(addr),
        @intFromPtr(len),
    );
    setLastError(rc);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return SOCKET_ERROR;
    return 0;
}

/// Set socket to non-blocking mode (emulates ioctlsocket with FIONBIO).
pub fn ioctlsocket(sock: SOCKET, cmd: u32, arg: *u64) i32 {
    if (cmd == FIONBIO) {
        // Linux ioctl(FIONBIO) expects a pointer to a c_int (i32), not u64.
        var val: i32 = if (arg.* != 0) 1 else 0;
        const rc = linux.syscall3(
            .ioctl,
            @as(usize, @intCast(sock)),
            @as(usize, FIONBIO),
            @intFromPtr(&val),
        );
        setLastError(rc);
        const signed: isize = @bitCast(rc);
        if (signed < 0) return SOCKET_ERROR;
        return 0;
    }
    last_error = 22; // EINVAL
    return SOCKET_ERROR;
}

/// Host-to-network byte order for 16-bit values.
pub fn htons(val: u16) u16 {
    return @byteSwap(val);
}

/// Network-to-host byte order for 16-bit values.
pub fn ntohs(val: u16) u16 {
    return @byteSwap(val);
}
// ============================================================================
// Timing Functions
// ============================================================================

/// Reads CLOCK_MONOTONIC in nanoseconds.
pub fn QueryPerformanceCounter(out: *LARGE_INTEGER) i32 {
    var ts: linux.timespec = undefined;
    const rc = linux.syscall2(
        .clock_gettime,
        @as(usize, @intFromEnum(linux.CLOCK.MONOTONIC)),
        @intFromPtr(&ts),
    );
    if (@as(isize, @bitCast(rc)) < 0) return 0;
    out.QuadPart = @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
    return 1; // non-zero = success (matches Windows convention)
}

/// Returns 1,000,000,000 (nanosecond resolution).
pub fn QueryPerformanceFrequency(out: *LARGE_INTEGER) i32 {
    out.QuadPart = 1_000_000_000;
    return 1;
}

// ============================================================================
// Sleep
// ============================================================================

pub fn Sleep(ms: u32) void {
    const secs: i64 = @intCast(ms / 1000);
    const nsecs: i64 = @intCast(@as(u64, ms % 1000) * 1_000_000);
    var ts = linux.timespec{ .sec = secs, .nsec = nsecs };
    _ = linux.syscall2(.nanosleep, @intFromPtr(&ts), @intFromPtr(&ts));
}

// ============================================================================
// Crypto / BCrypt Shim
// ============================================================================

/// Opaque handle types (no-op on Linux -- we use std.crypto directly).
pub const BCRYPT_ALG_HANDLE = ?*anyopaque;
pub const BCRYPT_KEY_HANDLE = ?*anyopaque;
pub const BCRYPT_HASH_HANDLE = ?*anyopaque;

/// Algorithm identifier placeholders (wide strings on Windows, unused on Linux).
pub const BCRYPT_AES_ALGORITHM: [*:0]const u16 = &[_:0]u16{ 'A', 'E', 'S' };
pub const BCRYPT_HMAC_SHA256_ALG: [*:0]const u16 = &[_:0]u16{ 'H', 'M', 'A', 'C' };
pub const BCRYPT_CHAIN_MODE_GCM: [*:0]const u16 = &[_:0]u16{ 'G', 'C', 'M' };
pub const BCRYPT_CHAINING_MODE: [*:0]const u16 = &[_:0]u16{ 'C', 'h', 'M' };
pub const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 0x00000002;
pub const BCRYPT_ALG_HANDLE_HMAC_FLAG: u32 = 0x00000008;

/// AES-GCM authenticated cipher mode info.
pub const BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO = struct {
    cbSize: u32 = @sizeOf(BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO),
    dwInfoVersion: u32 = 1,
    pbNonce: ?[*]u8 = null,
    cbNonce: u32 = 0,
    pbAuthData: ?[*]const u8 = null,
    cbAuthData: u32 = 0,
    pbTag: ?[*]u8 = null,
    cbTag: u32 = 0,
    pbMacContext: ?[*]u8 = null,
    cbMacContext: u32 = 0,
    cbAAD: u32 = 0,
    cbData: u64 = 0,
    dwFlags: u32 = 0,
};

/// Key storage -- we keep the raw key bytes in a fixed-size slot pool.
const KeySlot = struct {
    key: [32]u8 = undefined,
    key_len: u8 = 0,
};

var key_slots: [16]KeySlot = @as([16]KeySlot, @splat(.{}));
var key_slot_used: [16]bool = @as([16]bool, @splat(false));

fn allocKeySlot() ?usize {
    for (0..16) |i| {
        if (!key_slot_used[i]) {
            key_slot_used[i] = true;
            return i;
        }
    }
    return null;
}

fn freeKeySlot(idx: usize) void {
    if (idx < 16) {
        key_slots[idx] = .{};
        key_slot_used[idx] = false;
    }
}

fn slotFromHandle(handle: BCRYPT_KEY_HANDLE) ?usize {
    const ptr_val = @intFromPtr(handle);
    if (ptr_val == 0) return null;
    const idx = ptr_val - 1;
    if (idx >= 16) return null;
    if (!key_slot_used[idx]) return null;
    return idx;
}

fn handleFromSlot(idx: usize) BCRYPT_KEY_HANDLE {
    return @ptrFromInt(idx + 1);
}

/// No-op -- AES-GCM via std.crypto is stateless.
pub fn BCryptOpenAlgorithmProvider(
    phAlgorithm: *BCRYPT_ALG_HANDLE,
    pszAlgId: [*:0]const u16,
    pszImplementation: ?[*:0]const u16,
    dwFlags: u32,
) i32 {
    _ = pszAlgId;
    _ = pszImplementation;
    _ = dwFlags;
    phAlgorithm.* = @ptrFromInt(0xAE5); // sentinel
    return 0;
}

/// No-op.
pub fn BCryptCloseAlgorithmProvider(hAlgorithm: BCRYPT_ALG_HANDLE, dwFlags: u32) i32 {
    _ = hAlgorithm;
    _ = dwFlags;
    return 0;
}

/// Store key bytes for later encrypt/decrypt.
pub fn BCryptGenerateSymmetricKey(
    hAlgorithm: BCRYPT_ALG_HANDLE,
    phKey: *BCRYPT_KEY_HANDLE,
    pbKeyObject: ?[*]u8,
    cbKeyObject: u32,
    pbSecret: [*]const u8,
    cbSecret: u32,
    dwFlags: u32,
) i32 {
    _ = hAlgorithm;
    _ = pbKeyObject;
    _ = cbKeyObject;
    _ = dwFlags;
    const idx = allocKeySlot() orelse return -1;
    const len: usize = @intCast(cbSecret);
    if (len > 32) return -1;
    @memcpy(key_slots[idx].key[0..len], pbSecret[0..len]);
    key_slots[idx].key_len = @intCast(len);
    phKey.* = handleFromSlot(idx);
    return 0;
}

/// Release key slot.
pub fn BCryptDestroyKey(hKey: BCRYPT_KEY_HANDLE) i32 {
    if (slotFromHandle(hKey)) |idx| {
        freeKeySlot(idx);
    }
    return 0;
}

// ── BCrypt Hash functions (HMAC via std.crypto) ──

const HashSlot = struct {
    key: [64]u8 = undefined,
    key_len: u8 = 0,
    data: [8192]u8 = undefined,
    data_len: u32 = 0,
    active: bool = false,
};

var hash_slots: [8]HashSlot = @as([8]HashSlot, @splat(HashSlot{}));

fn allocHashSlot() ?usize {
    for (0..8) |i| {
        if (!hash_slots[i].active) {
            hash_slots[i] = .{};
            hash_slots[i].active = true;
            return i;
        }
    }
    return null;
}

pub fn BCryptCreateHash(
    hAlgorithm: BCRYPT_ALG_HANDLE,
    phHash: *BCRYPT_HASH_HANDLE,
    pbHashObject: ?[*]u8,
    cbHashObject: u32,
    pbSecret: [*]const u8,
    cbSecret: u32,
    dwFlags: u32,
) i32 {
    _ = hAlgorithm;
    _ = pbHashObject;
    _ = cbHashObject;
    _ = dwFlags;
    const idx = allocHashSlot() orelse return -1;
    const len: usize = @intCast(cbSecret);
    if (len > 64) return -1;
    @memcpy(hash_slots[idx].key[0..len], pbSecret[0..len]);
    hash_slots[idx].key_len = @intCast(len);
    hash_slots[idx].data_len = 0;
    phHash.* = @ptrFromInt(idx + 100); // offset to distinguish from key handles
    return 0;
}

pub fn BCryptHashData(hHash: BCRYPT_HASH_HANDLE, pbInput: [*]const u8, cbInput: u32, dwFlags: u32) i32 {
    _ = dwFlags;
    const ptr_val = @intFromPtr(hHash);
    if (ptr_val < 100 or ptr_val >= 108) return -1;
    const idx = ptr_val - 100;
    const input_len: usize = @intCast(cbInput);
    const cur: usize = hash_slots[idx].data_len;
    if (cur + input_len > hash_slots[idx].data.len) return -1;
    @memcpy(hash_slots[idx].data[cur .. cur + input_len], pbInput[0..input_len]);
    hash_slots[idx].data_len = @intCast(cur + input_len);
    return 0;
}

pub fn BCryptFinishHash(hHash: BCRYPT_HASH_HANDLE, pbOutput: *[32]u8, cbOutput: u32, dwFlags: u32) i32 {
    _ = cbOutput;
    _ = dwFlags;
    const ptr_val = @intFromPtr(hHash);
    if (ptr_val < 100 or ptr_val >= 108) return -1;
    const idx = ptr_val - 100;
    const Hmac = crypto.auth.hmac.sha2.HmacSha256;
    const klen: usize = hash_slots[idx].key_len;
    const dlen: usize = hash_slots[idx].data_len;
    Hmac.create(pbOutput, hash_slots[idx].data[0..dlen], hash_slots[idx].key[0..klen]);
    return 0;
}

pub fn BCryptDestroyHash(hHash: BCRYPT_HASH_HANDLE) i32 {
    const ptr_val = @intFromPtr(hHash);
    if (ptr_val >= 100 and ptr_val < 108) {
        hash_slots[ptr_val - 100].active = false;
    }
    return 0;
}

/// AES-128/256-GCM encrypt using std.crypto.
pub fn BCryptEncrypt(
    hKey: BCRYPT_KEY_HANDLE,
    pbInput: [*]const u8,
    cbInput: u32,
    pPaddingInfo: ?*BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO,
    pbIV: ?[*]u8,
    cbIV: u32,
    pbOutput: ?[*]u8,
    cbOutput: u32,
    pcbResult: *u32,
    dwFlags: u32,
) i32 {
    _ = pbIV;
    _ = cbIV;
    _ = cbOutput;
    _ = dwFlags;
    const idx = slotFromHandle(hKey) orelse return -1;
    const key_len: usize = key_slots[idx].key_len;
    if (key_len != 16 and key_len != 32) return -1;
    const input_len: usize = @intCast(cbInput);

    // ECB/CBC mode (header protection): pPaddingInfo == null
    if (pPaddingInfo == null) {
        if (input_len != 16) return -1;
        const output = (pbOutput orelse return -1)[0..16];
        const input = pbInput[0..16];
        if (key_len == 16) {
            const key: [16]u8 = key_slots[idx].key[0..16].*;
            const ctx = crypto.core.aes.Aes128.initEnc(key);
            ctx.encrypt(output, input);
        } else {
            const key: [32]u8 = key_slots[idx].key[0..32].*;
            const ctx = crypto.core.aes.Aes256.initEnc(key);
            ctx.encrypt(output, input);
        }
        pcbResult.* = 16;
        return 0;
    }

    // GCM mode
    const info = pPaddingInfo.?;
    const nonce_len: usize = @intCast(info.cbNonce);
    const ad_len: usize = @intCast(info.cbAuthData);
    const tag_len: usize = @intCast(info.cbTag);

    if (nonce_len != 12) return -1;
    if (tag_len != 16) return -1;

    const nonce: *const [12]u8 = @ptrCast(info.pbNonce orelse return -1);
    const ad: []const u8 = if (info.pbAuthData) |p| p[0..ad_len] else &[_]u8{};
    const plaintext = pbInput[0..input_len];
    const output = (pbOutput orelse return -1)[0..input_len];
    const tag_out: *[16]u8 = @ptrCast(info.pbTag orelse return -1);

    if (key_len == 16) {
        const key: [16]u8 = key_slots[idx].key[0..16].*;
        crypto.aead.aes_gcm.Aes128Gcm.encrypt(output, tag_out, plaintext, ad, nonce.*, key);
    } else {
        const key: [32]u8 = key_slots[idx].key[0..32].*;
        crypto.aead.aes_gcm.Aes256Gcm.encrypt(output, tag_out, plaintext, ad, nonce.*, key);
    }

    pcbResult.* = cbInput;
    return 0;
}

/// AES-128/256-GCM decrypt using std.crypto.
pub fn BCryptDecrypt(
    hKey: BCRYPT_KEY_HANDLE,
    pbInput: [*]const u8,
    cbInput: u32,
    pPaddingInfo: ?*BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO,
    pbIV: ?[*]u8,
    cbIV: u32,
    pbOutput: ?[*]u8,
    cbOutput: u32,
    pcbResult: *u32,
    dwFlags: u32,
) i32 {
    _ = pbIV;
    _ = cbIV;
    _ = cbOutput;
    _ = dwFlags;
    const idx = slotFromHandle(hKey) orelse return -1;
    const info = pPaddingInfo orelse return -1;
    const key_len: usize = key_slots[idx].key_len;
    if (key_len != 16 and key_len != 32) return -1;

    const input_len: usize = @intCast(cbInput);
    const nonce_len: usize = @intCast(info.cbNonce);
    const ad_len: usize = @intCast(info.cbAuthData);
    const tag_len: usize = @intCast(info.cbTag);

    if (nonce_len != 12) return -1;
    if (tag_len != 16) return -1;

    const nonce: *const [12]u8 = @ptrCast(info.pbNonce orelse return -1);
    const ad: []const u8 = if (info.pbAuthData) |p| p[0..ad_len] else &[_]u8{};
    const ciphertext = pbInput[0..input_len];
    const output = (pbOutput orelse return -1)[0..input_len];
    const tag: *const [16]u8 = @ptrCast(info.pbTag orelse return -1);

    if (key_len == 16) {
        const key: [16]u8 = key_slots[idx].key[0..16].*;
        crypto.aead.aes_gcm.Aes128Gcm.decrypt(output, ciphertext, tag.*, ad, nonce.*, key) catch return -1;
    } else {
        const key: [32]u8 = key_slots[idx].key[0..32].*;
        crypto.aead.aes_gcm.Aes256Gcm.decrypt(output, ciphertext, tag.*, ad, nonce.*, key) catch return -1;
    }

    pcbResult.* = cbInput;
    return 0;
}

/// Generate random bytes using Linux getrandom() syscall.
pub fn BCryptGenRandom(handle: ?*anyopaque, buf: [*]u8, len: u32, flags: u32) i32 {
    _ = handle;
    _ = flags;
    const size: usize = @intCast(len);
    var offset: usize = 0;
    while (offset < size) {
        const rc = linux.syscall3(
            .getrandom,
            @intFromPtr(buf + offset),
            size - offset,
            0,
        );
        const signed: isize = @bitCast(rc);
        if (signed < 0) return -1;
        offset += @intCast(signed);
    }
    return 0;
}

/// No-op -- property setting is not needed for std.crypto.
pub fn BCryptSetProperty(
    hObject: BCRYPT_ALG_HANDLE,
    pszProperty: [*:0]const u16,
    pbInput: [*]const u8,
    cbInput: u32,
    dwFlags: u32,
) i32 {
    _ = hObject;
    _ = pszProperty;
    _ = pbInput;
    _ = cbInput;
    _ = dwFlags;
    return 0;
}
// ============================================================================
// TLS / SSPI Shim (Minimal QUIC TLS 1.3 stub)
// ============================================================================

pub const CredHandle = [2]u64;
pub const CtxtHandle = [2]u64;

pub const SecBuffer = struct {
    cbBuffer: u32 = 0,
    BufferType: u32 = 0,
    pvBuffer: ?[*]u8 = null,
};

pub const SecBufferDesc = struct {
    ulVersion: u32 = SECBUFFER_VERSION,
    cBuffers: u32 = 0,
    pBuffers: ?[*]SecBuffer = null,
};

// SecBuffer type constants
pub const SECBUFFER_VERSION: u32 = 0;
pub const SECBUFFER_EMPTY: u32 = 0;
pub const SECBUFFER_TOKEN: u32 = 2;
pub const SECBUFFER_EXTRA: u32 = 5;
pub const SECBUFFER_APPLICATION_PROTOCOLS: u32 = 18;

// Security status codes
pub const SEC_E_OK: i32 = 0;
pub const SEC_E_INCOMPLETE_MESSAGE: i32 = @bitCast(@as(u32, 0x80090318));
pub const SEC_I_CONTINUE_NEEDED: i32 = @bitCast(@as(u32, 0x00090312));
pub const SEC_I_COMPLETE_AND_CONTINUE: i32 = @bitCast(@as(u32, 0x00090313));

// SChannel credential flags
pub const SCH_CRED_NO_DEFAULT_CREDS: u32 = 0x00000010;
pub const SCH_CRED_MANUAL_CRED_VALIDATION: u32 = 0x00000008;
pub const SCH_CRED_NO_SERVERNAME_CHECK: u32 = 0x00000004;
pub const SCH_USE_STRONG_CRYPTO: u32 = 0x00400000;

// ISC/ASC request flags
pub const ISC_REQ_SEQUENCE_DETECT: u32 = 0x00000008;
pub const ISC_REQ_REPLAY_DETECT: u32 = 0x00000004;
pub const ISC_REQ_CONFIDENTIALITY: u32 = 0x00000010;
pub const ISC_REQ_ALLOCATE_MEMORY: u32 = 0x00000100;
pub const ISC_REQ_STREAM: u32 = 0x00008000;
pub const ISC_REQ_USE_SUPPLIED_CREDS: u32 = 0x00000080;
pub const ISC_REQ_MANUAL_CRED_VALIDATION: u32 = 0x00080000;

pub const ASC_REQ_SEQUENCE_DETECT: u32 = 0x00000008;
pub const ASC_REQ_REPLAY_DETECT: u32 = 0x00000004;
pub const ASC_REQ_CONFIDENTIALITY: u32 = 0x00000010;
pub const ASC_REQ_ALLOCATE_MEMORY: u32 = 0x00000100;
pub const ASC_REQ_STREAM: u32 = 0x00008000;

pub const SECPKG_CRED_INBOUND: u32 = 1;
pub const SECPKG_CRED_OUTBOUND: u32 = 2;

// ALPN constants
pub const SECPKG_ATTR_APPLICATION_PROTOCOL: u32 = 0x2E;
pub const SecApplicationProtocolNegotiationExt_ALPN: u32 = 1;
pub const SecApplicationProtocolNegotiationStatus_Success: u32 = 1;

/// SChannel credentials structure.
pub const SCH_CREDENTIALS = struct {
    dwVersion: u32 = 4,
    dwCredFormat: u32 = 0,
    cCreds: u32 = 0,
    paCred: ?*anyopaque = null,
    hRootStore: ?*anyopaque = null,
    cMappers: u32 = 0,
    aphMappers: ?*anyopaque = null,
    dwSessionLifespan: u32 = 0,
    dwFlags: u32 = 0,
    cTlsParameters: u32 = 0,
    pTlsParameters: ?*anyopaque = null,
};

/// Application protocol negotiation list.
pub const SEC_APPLICATION_PROTOCOL_LIST = struct {
    ProtoNegoExt: u32 = SecApplicationProtocolNegotiationExt_ALPN,
    ProtocolListSize: u16 = 0,
    ProtocolList: [256]u8 = @as([256]u8, @splat(0)),
};

/// Application protocols container.
pub const SEC_APPLICATION_PROTOCOLS = struct {
    ProtocolListsSize: u32 = 0,
    ProtocolLists: SEC_APPLICATION_PROTOCOL_LIST = .{},
};

/// Query result for negotiated ALPN.
pub const SecPkgContext_ApplicationProtocol = struct {
    ProtoNegoStatus: u32 = 0,
    ProtoNegoExt: u32 = 0,
    ProtocolIdSize: u8 = 0,
    ProtocolId: [256]u8 = @as([256]u8, @splat(0)),
};

/// UNISP provider name placeholder.
pub const UNISP_NAME_W: [*:0]const u16 = &[_:0]u16{
    'M', 'i', 'c', 'r', 'o', 's', 'o', 'f', 't', ' ',
    'U', 'n', 'i', 'f', 'i', 'e', 'd', ' ', 'S', 'e',
    'c', 'u', 'r', 'i', 't', 'y', ' ', 'P', 'r', 'o',
    't', 'o', 'c', 'o', 'l', ' ', 'P', 'r', 'o', 'v',
    'i', 'd', 'e', 'r',
};
// ============================================================================
// TLS / SSPI Functions
//
// These are stubs that implement the minimum needed for QUIC Initial packet
// protection (RFC 9001 Section 5.2). Full TLS 1.3 handshake is TODO.
// ============================================================================

/// QUIC v1 Initial Salt (RFC 9001 Section 5.2)
const quic_v1_initial_salt = [_]u8{
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3,
    0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
    0xcc, 0xbb, 0x7f, 0x0a,
};

/// Internal TLS context state backed by the real TLS 1.3 engine.
const tls13 = @import("tls13.sig");
pub const Tls13Engine = tls13.Tls13Engine;

const TlsContext = struct {
    is_server: bool = false,
    handshake_complete: bool = false,
    alpn: [16]u8 = @as([16]u8, @splat(0)),
    alpn_len: u8 = 0,
    engine: tls13.Tls13Engine = .{},
    initialized: bool = false,
};

var tls_contexts: [8]TlsContext = @as([8]TlsContext, @splat(.{}));
var tls_ctx_used: [8]bool = @as([8]bool, @splat(false));

fn allocTlsCtx(is_server: bool) ?usize {
    for (0..8) |i| {
        if (!tls_ctx_used[i]) {
            tls_ctx_used[i] = true;
            tls_contexts[i] = .{ .is_server = is_server };
            return i;
        }
    }
    return null;
}

fn freeTlsCtx(idx: usize) void {
    if (idx < 8) {
        tls_contexts[idx] = .{};
        tls_ctx_used[idx] = false;
    }
}

/// Acquire a credential handle. On Linux this initializes our TLS 1.3 engine.
pub fn AcquireCredentialsHandleW(
    pszPrincipal: ?[*:0]const u16,
    pszPackage: [*:0]const u16,
    fCredentialUse: u32,
    pvLogonId: ?*anyopaque,
    pAuthData: ?*anyopaque,
    pGetKeyFn: ?*anyopaque,
    pvGetKeyArgument: ?*anyopaque,
    phCredential: *CredHandle,
    ptsExpiry: ?*i64,
) i32 {
    _ = pszPrincipal;
    _ = pszPackage;
    _ = pvLogonId;
    _ = pAuthData;
    _ = pGetKeyFn;
    _ = pvGetKeyArgument;
    _ = ptsExpiry;
    const is_server = (fCredentialUse & SECPKG_CRED_INBOUND) != 0;
    const idx = allocTlsCtx(is_server) orelse return -1;

    // Initialize the TLS 1.3 engine
    if (is_server) {
        tls_contexts[idx].engine = tls13.Tls13Engine.initServer();
    }
    tls_contexts[idx].initialized = true;

    phCredential[0] = idx + 1;
    phCredential[1] = 0;
    return SEC_E_OK;
}

/// Server-side TLS handshake step using real TLS 1.3 engine.
/// Processes CRYPTO frame data and produces response messages.
pub fn AcceptSecurityContext(
    phCredential: *CredHandle,
    phContext: ?*CtxtHandle,
    pInput: ?*SecBufferDesc,
    fContextReq: u32,
    targetDataRep: u32,
    phNewContext: ?*CtxtHandle,
    pOutput: ?*SecBufferDesc,
    pfContextAttr: ?*u32,
    ptsExpiry: ?*i64,
) i32 {
    _ = phContext;
    _ = fContextReq;
    _ = targetDataRep;
    _ = pfContextAttr;
    _ = ptsExpiry;

    const ctx_idx = phCredential[0];
    if (ctx_idx == 0 or ctx_idx > 8) return -1;
    const idx = ctx_idx - 1;

    if (!tls_contexts[idx].initialized) return -1;
    var engine = &tls_contexts[idx].engine;

    // Extract input data from SecBufferDesc
    var input_data: ?[]const u8 = null;
    if (pInput) |in_desc| {
        if (in_desc.pBuffers) |buffers| {
            if (in_desc.cBuffers > 0 and buffers[0].cbBuffer > 0) {
                if (buffers[0].pvBuffer) |ptr| {
                    const data_ptr: [*]const u8 = @ptrCast(ptr);
                    input_data = data_ptr[0..buffers[0].cbBuffer];
                }
            }
        }
    }

    // Process the handshake message
    if (input_data) |data| {
        const result = engine.processMessage(data);

        if (result.err != .none) {
            tls_contexts[idx].handshake_complete = false;
            return -1; // Handshake failed
        }

        // Copy output to SecBuffer
        if (result.output_len > 0) {
            if (pOutput) |out_desc| {
                if (out_desc.pBuffers) |buffers| {
                    if (out_desc.cBuffers > 0) {
                        if (buffers[0].pvBuffer) |ptr| {
                            const out_ptr: [*]u8 = @ptrCast(ptr);
                            const copy_len = @min(result.output_len, buffers[0].cbBuffer);
                            @memcpy(out_ptr[0..copy_len], engine.output_buf[0..copy_len]);
                            buffers[0].cbBuffer = copy_len;
                        } else {
                            buffers[0].cbBuffer = 0;
                        }
                    }
                }
            }
        } else {
            if (pOutput) |out_desc| {
                if (out_desc.pBuffers) |buffers| {
                    if (out_desc.cBuffers > 0) {
                        buffers[0].cbBuffer = 0;
                    }
                }
            }
        }

        if (phNewContext) |ctx| {
            ctx[0] = ctx_idx;
            ctx[1] = 0;
        }

        if (result.complete) {
            tls_contexts[idx].handshake_complete = true;
            // Copy ALPN
            const alen = @min(result.alpn_len, 16);
            @memcpy(tls_contexts[idx].alpn[0..alen], result.alpn[0..alen]);
            tls_contexts[idx].alpn_len = @intCast(alen);
            return SEC_E_OK;
        }

        // Handshake in progress, need more data
        return SEC_I_CONTINUE_NEEDED;
    }

    // No input data — initial call
    if (pOutput) |out_desc| {
        if (out_desc.pBuffers) |buffers| {
            if (out_desc.cBuffers > 0) {
                buffers[0].cbBuffer = 0;
            }
        }
    }

    if (phNewContext) |ctx| {
        ctx[0] = ctx_idx;
        ctx[1] = 0;
    }

    return SEC_I_CONTINUE_NEEDED;
}

/// Client-side TLS handshake step.
/// For now, a minimal implementation that signals continue until complete.
pub fn InitializeSecurityContextW(
    phCredential: *CredHandle,
    phContext: ?*CtxtHandle,
    pszTargetName: ?[*:0]const u16,
    fContextReq: u32,
    reserved1: u32,
    targetDataRep: u32,
    pInput: ?*SecBufferDesc,
    reserved2: u32,
    phNewContext: ?*CtxtHandle,
    pOutput: ?*SecBufferDesc,
    pfContextAttr: ?*u32,
    ptsExpiry: ?*i64,
) i32 {
    _ = phContext;
    _ = pszTargetName;
    _ = fContextReq;
    _ = reserved1;
    _ = targetDataRep;
    _ = pInput;
    _ = reserved2;
    _ = pfContextAttr;
    _ = ptsExpiry;

    const ctx_idx = phCredential[0];
    if (ctx_idx == 0 or ctx_idx > 8) return -1;
    const idx = ctx_idx - 1;

    // Client TLS 1.3 — TODO: implement client-side handshake via tls13.sig
    // For now, mark as complete with ALPN "zpm" for basic functionality
    tls_contexts[idx].alpn[0] = 'z';
    tls_contexts[idx].alpn[1] = 'p';
    tls_contexts[idx].alpn[2] = 'm';
    tls_contexts[idx].alpn_len = 3;
    tls_contexts[idx].handshake_complete = true;

    if (pOutput) |out_desc| {
        if (out_desc.pBuffers) |buffers| {
            if (out_desc.cBuffers > 0) {
                buffers[0].cbBuffer = 0;
            }
        }
    }

    if (phNewContext) |ctx| {
        ctx[0] = ctx_idx;
        ctx[1] = 0;
    }

    return SEC_E_OK;
}

/// No-op on Linux.
pub fn CompleteAuthToken(phContext: *CtxtHandle, pToken: *SecBufferDesc) i32 {
    _ = phContext;
    _ = pToken;
    return SEC_E_OK;
}

/// Clean up a security context.
pub fn DeleteSecurityContext(phContext: *CtxtHandle) i32 {
    const idx = phContext[0];
    if (idx > 0 and idx <= 8) {
        freeTlsCtx(idx - 1);
    }
    phContext[0] = 0;
    phContext[1] = 0;
    return SEC_E_OK;
}

/// Free a credential handle.
pub fn FreeCredentialsHandle(phCredential: *CredHandle) i32 {
    const idx = phCredential[0];
    if (idx > 0 and idx <= 8) {
        freeTlsCtx(idx - 1);
    }
    phCredential[0] = 0;
    phCredential[1] = 0;
    return SEC_E_OK;
}

/// Query negotiated ALPN protocol.
pub fn QueryContextAttributesW(
    phContext: *CtxtHandle,
    ulAttribute: u32,
    pBuffer: *anyopaque,
) i32 {
    if (ulAttribute != SECPKG_ATTR_APPLICATION_PROTOCOL) return -1;

    const ctx_idx = phContext[0];
    if (ctx_idx == 0 or ctx_idx > 8) return -1;
    const idx = ctx_idx - 1;

    const result: *SecPkgContext_ApplicationProtocol = @ptrCast(@alignCast(pBuffer));
    result.ProtoNegoStatus = SecApplicationProtocolNegotiationStatus_Success;
    result.ProtoNegoExt = SecApplicationProtocolNegotiationExt_ALPN;
    result.ProtocolIdSize = tls_contexts[idx].alpn_len;

    const len: usize = tls_contexts[idx].alpn_len;
    @memcpy(result.ProtocolId[0..len], tls_contexts[idx].alpn[0..len]);

    return SEC_E_OK;
}
// ============================================================================
// QUIC Initial Key Derivation (RFC 9001 Section 5.2)
// ============================================================================

/// Derive QUIC Initial keys from a Destination Connection ID.
/// Uses HKDF-SHA256 with the QUIC v1 initial salt.
pub fn deriveQuicInitialKeys(
    dcid: []const u8,
    client_key: *[16]u8,
    client_iv: *[12]u8,
    client_hp: *[16]u8,
    server_key: *[16]u8,
    server_iv: *[12]u8,
    server_hp: *[16]u8,
) void {
    const Hkdf = crypto.kdf.hkdf.HkdfSha256;

    // initial_secret = HKDF-Extract(initial_salt, dcid)
    const initial_secret = Hkdf.extract(&quic_v1_initial_salt, dcid);

    // client_initial_secret = HKDF-Expand-Label(initial_secret, "client in", "", 32)
    const client_secret = hkdfExpandLabel(&initial_secret, "client in", 32);
    // server_initial_secret = HKDF-Expand-Label(initial_secret, "server in", "", 32)
    const server_secret = hkdfExpandLabel(&initial_secret, "server in", 32);

    // Derive client keys
    client_key.* = hkdfExpandLabel(&client_secret, "quic key", 16)[0..16].*;
    client_iv.* = hkdfExpandLabel(&client_secret, "quic iv", 12)[0..12].*;
    client_hp.* = hkdfExpandLabel(&client_secret, "quic hp", 16)[0..16].*;

    // Derive server keys
    server_key.* = hkdfExpandLabel(&server_secret, "quic key", 16)[0..16].*;
    server_iv.* = hkdfExpandLabel(&server_secret, "quic iv", 12)[0..12].*;
    server_hp.* = hkdfExpandLabel(&server_secret, "quic hp", 16)[0..16].*;
}

/// HKDF-Expand-Label as defined in TLS 1.3 / RFC 8446 Section 7.1.
/// label_str is the label WITHOUT the "tls13 " prefix (we prepend it).
fn hkdfExpandLabel(secret: *const [32]u8, comptime label_str: []const u8, comptime length: u16) [length]u8 {
    const Hkdf = crypto.kdf.hkdf.HkdfSha256;

    // HkdfLabel = length (2) || label_len (1) || "tls13 " || label || context_len (1) || context
    const full_label = "tls13 " ++ label_str;
    const hkdf_label_len = 2 + 1 + full_label.len + 1;
    var info: [hkdf_label_len]u8 = undefined;

    // Length (big-endian u16)
    info[0] = @intCast(length >> 8);
    info[1] = @intCast(length & 0xFF);
    // Label length + label
    info[2] = @intCast(full_label.len);
    @memcpy(info[3..][0..full_label.len], full_label);
    // Context length (0) + empty context
    info[3 + full_label.len] = 0;

    var out: [length]u8 = undefined;
    Hkdf.expand(&out, &info, secret.*);
    return out;
}

// ============================================================================
// TLS 1.3 Engine Management API
// ============================================================================

/// Load a certificate and private key into the TLS engine for a given credential handle.
/// cert_der: DER-encoded certificate bytes.
/// key_raw: 32-byte raw ECDSA P-256 private key scalar.
/// Returns 0 on success, -1 on error.
pub fn loadTlsCertificate(phCredential: *CredHandle, cert_der: []const u8, key_raw: []const u8) i32 {
    const ctx_idx = phCredential[0];
    if (ctx_idx == 0 or ctx_idx > 8) return -1;
    const idx = ctx_idx - 1;
    if (!tls_ctx_used[idx]) return -1;

    const err = tls_contexts[idx].engine.loadCertificate(cert_der, key_raw);
    if (err != .none) return -1;
    return 0;
}

/// Set ALPN protocol for the TLS engine.
/// alpn: protocol string (e.g., "zpm" or "h3").
pub fn setTlsAlpn(phCredential: *CredHandle, alpn: []const u8) i32 {
    const ctx_idx = phCredential[0];
    if (ctx_idx == 0 or ctx_idx > 8) return -1;
    const idx = ctx_idx - 1;
    if (!tls_ctx_used[idx]) return -1;

    tls_contexts[idx].engine.setAlpn(alpn);
    return 0;
}

/// Set QUIC transport parameters for the TLS engine.
pub fn setTlsTransportParams(phCredential: *CredHandle, params: []const u8) i32 {
    const ctx_idx = phCredential[0];
    if (ctx_idx == 0 or ctx_idx > 8) return -1;
    const idx = ctx_idx - 1;
    if (!tls_ctx_used[idx]) return -1;

    tls_contexts[idx].engine.setTransportParams(params);
    return 0;
}

/// Get the derived handshake keys after handshake progresses.
/// Returns a pointer to the TLS 1.3 engine for a given credential handle.
pub fn getTls13Engine(phCredential: *CredHandle) ?*tls13.Tls13Engine {
    const ctx_idx = phCredential[0];
    if (ctx_idx == 0 or ctx_idx > 8) return null;
    const idx = ctx_idx - 1;
    if (!tls_ctx_used[idx]) return null;
    return &tls_contexts[idx].engine;
}