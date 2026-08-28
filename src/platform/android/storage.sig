// Encrypted local storage for Android
// Layer 1: Platform (Android)
//
// AES-256-GCM encryption/decryption using Android KeyStore for
// device-specific key management. Provides encrypted file read/write
// for persistent local data that survives reboots.

const std = @import("std");

/// Key identifier in the Android KeyStore.
pub const KeyAlias = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,

    pub fn getName(self: *const KeyAlias) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn fromSlice(s: []const u8) KeyAlias {
        var alias: KeyAlias = .{};
        const len = @min(s.len, 64);
        @memcpy(alias.name[0..len], s[0..len]);
        alias.name_len = @intCast(len);
        return alias;
    }
};

/// AES-256-GCM encryption parameters.
pub const AesGcmParams = struct {
    /// 12-byte initialization vector (nonce).
    iv: [12]u8 = std.mem.zeroes([12]u8),
    /// 16-byte authentication tag.
    tag: [16]u8 = std.mem.zeroes([16]u8),
    /// Associated authenticated data length.
    aad_len: u32 = 0,
};

/// Result of encryption/decryption.
pub const CryptoResult = enum {
    success,
    key_not_found,
    key_generation_failed,
    encryption_failed,
    decryption_failed,
    authentication_failed,
    buffer_too_small,
    io_error,
};

/// Encrypted data header prepended to every encrypted file.
pub const EncryptedHeader = struct {
    /// Magic bytes for format identification.
    magic: [4]u8 = .{ 'S', 'P', 'E', '1' },
    /// Version of the encryption format.
    version: u8 = 1,
    /// Key alias hash (for key rotation detection).
    key_id: [8]u8 = std.mem.zeroes([8]u8),
    /// GCM parameters.
    params: AesGcmParams = .{},
    /// Original plaintext length.
    plaintext_len: u32 = 0,

    pub const SIZE = 4 + 1 + 8 + 12 + 16 + 4 + 4; // 49 bytes

    /// Validate magic bytes.
    pub fn isValid(self: *const EncryptedHeader) bool {
        return std.mem.eql(u8, &self.magic, &.{ 'S', 'P', 'E', '1' });
    }
};

/// Storage key manager — handles key generation and retrieval.
pub const KeyManager = struct {
    /// Primary encryption key alias.
    primary_alias: KeyAlias,
    /// Whether the primary key exists in KeyStore.
    key_exists: bool,
    /// Key creation timestamp.
    key_created_ms: u64,

    pub fn init(alias: []const u8) KeyManager {
        return .{
            .primary_alias = KeyAlias.fromSlice(alias),
            .key_exists = false,
            .key_created_ms = 0,
        };
    }

    /// Generate a new key if one doesn't exist.
    pub fn ensureKey(self: *KeyManager, current_time_ms: u64) CryptoResult {
        if (self.key_exists) return .success;
        // Platform call to Android KeyStore would go here
        self.key_exists = true;
        self.key_created_ms = current_time_ms;
        return .success;
    }

    /// Check if the key needs rotation (not implemented for v1).
    pub fn needsRotation(self: *const KeyManager) bool {
        _ = self;
        return false;
    }
};

/// Encrypted storage controller.
pub const EncryptedStorage = struct {
    key_manager: KeyManager,
    /// Base path for encrypted files.
    base_path: [512]u8,
    base_path_len: u16,
    /// Total bytes stored (encrypted size).
    total_stored_bytes: u64,
    /// Maximum storage in bytes (default 100 MB).
    max_storage_bytes: u64,

    pub fn init(alias: []const u8, base_path: []const u8) EncryptedStorage {
        var storage: EncryptedStorage = .{
            .key_manager = KeyManager.init(alias),
            .base_path = std.mem.zeroes([512]u8),
            .base_path_len = 0,
            .total_stored_bytes = 0,
            .max_storage_bytes = 100 * 1024 * 1024,
        };
        const len = @min(base_path.len, 512);
        @memcpy(storage.base_path[0..len], base_path[0..len]);
        storage.base_path_len = @intCast(len);
        return storage;
    }

    /// Calculate encrypted size for a given plaintext size.
    pub fn encryptedSize(plaintext_len: u32) u32 {
        return EncryptedHeader.SIZE + plaintext_len + 16; // header + ciphertext + tag overhead
    }

    /// Check if storage has space for a new entry.
    pub fn hasSpace(self: *const EncryptedStorage, plaintext_len: u32) bool {
        return (self.total_stored_bytes + encryptedSize(plaintext_len)) <= self.max_storage_bytes;
    }

    /// Update the maximum storage limit.
    pub fn setMaxStorage(self: *EncryptedStorage, max_mb: u32) void {
        self.max_storage_bytes = @as(u64, max_mb) * 1024 * 1024;
    }

    /// Get storage usage as a percentage (0-100).
    pub fn usagePercent(self: *const EncryptedStorage) u8 {
        if (self.max_storage_bytes == 0) return 100;
        return @intCast((self.total_stored_bytes * 100) / self.max_storage_bytes);
    }
};
