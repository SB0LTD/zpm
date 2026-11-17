//! Portable streaming envelope for a durable, committed database image.
//! The caller owns the image codec, temporary file and publication order.
//! File backends supply length, readAt, appendAll and sync.
const std = @import("std");
const Hash = std.crypto.hash.Blake3;

// Version 1 uses little-endian integers. The footer digest covers the complete
// header, payload, and encoded payload length in that order.
const header_magic = "RAMSQLS1";
const footer_magic = "RAMSQLSE";
pub const header_size: usize = 48;
pub const footer_size: usize = 48;
pub const overhead: usize = header_size + footer_size;
pub const max_payload_bytes: u64 = @as(u64, std.math.maxInt(i64)) - overhead;

pub const Identity = struct {
    database_id: [16]u8,
    generation: u64,
    wal_sequence: u64,
    sql_csn: u64,
};

/// Keep this receipt in durable checkpoint metadata outside the image.
pub const Seal = struct {
    identity: Identity,
    payload_bytes: u64,
    digest: [Hash.digest_length]u8,
};

fn encodeHeader(identity: Identity) [header_size]u8 {
    var header: [header_size]u8 = undefined;
    @memcpy(header[0..8], header_magic);
    @memcpy(header[8..24], &identity.database_id);
    std.mem.writeInt(u64, header[24..32], identity.generation, .little);
    std.mem.writeInt(u64, header[32..40], identity.wal_sequence, .little);
    std.mem.writeInt(u64, header[40..48], identity.sql_csn, .little);
    return header;
}

fn checkLength(file: anytype, expected: u64) !void {
    const actual: u64 = try file.length();
    if (actual < expected) return error.TruncatedSnapshot;
    if (actual > expected) return error.TrailingSnapshotBytes;
}

fn readExact(file: anytype, offset: u64, bytes: []u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = try file.readAt(offset + done, bytes[done..]);
        if (n == 0 or n > bytes.len - done) return error.TruncatedSnapshot;
        done += n;
    }
}

/// Hold the exclusively created file at a stable address until finish.
/// A failed append or finish closes the writer to further use. The caller
/// owns cleanup of a failed temporary file.
pub fn Writer(comptime File: type) type {
    return struct {
        const Self = @This();
        file: *File,
        identity: Identity,
        hash: Hash,
        payload_bytes: u64 = 0,
        open: bool = true,

        pub fn begin(file: *File, identity: Identity) !Self {
            if (try file.length() != 0) return error.SnapshotDestinationNotEmpty;
            const header = encodeHeader(identity);
            try file.appendAll(&header);
            var hash = Hash.init(.{});
            hash.update(&header);
            return .{ .file = file, .identity = identity, .hash = hash };
        }

        pub fn append(self: *Self, bytes: []const u8) !void {
            if (!self.open) return error.SnapshotWriterClosed;
            if (bytes.len == 0) return;
            self.open = false;
            if (bytes.len > max_payload_bytes - self.payload_bytes) return error.SnapshotTooLarge;
            try self.file.appendAll(bytes);
            self.hash.update(bytes);
            self.payload_bytes += bytes.len;
            self.open = true;
        }

        /// Writes and syncs the footer. Verify the closed image against the
        /// returned seal before publishing a pointer to it.
        pub fn finish(self: *Self) !Seal {
            if (!self.open) return error.SnapshotWriterClosed;
            self.open = false;
            var footer: [footer_size]u8 = undefined;
            std.mem.writeInt(u64, footer[0..8], self.payload_bytes, .little);
            self.hash.update(footer[0..8]);
            self.hash.final(footer[8..40]);
            @memcpy(footer[40..48], footer_magic);
            try self.file.appendAll(&footer);
            try checkLength(self.file, overhead + self.payload_bytes);
            try self.file.sync();
            return .{ .identity = self.identity, .payload_bytes = self.payload_bytes, .digest = footer[8..40].* };
        }
    };
}

/// Checks a stable file against a trusted seal without keeping image bytes.
pub fn verify(file: anytype, scratch: []u8, expected: Seal) !void {
    try read(file, scratch, expected, {}, null);
}

/// Streams the image to unpublished caller-owned staging state. Only a
/// successful return establishes that every staged byte belongs to the trusted
/// seal. The receiver must consume each borrowed scratch slice before returning.
/// Keep the file unchanged and the scratch exclusive throughout this call.
pub fn read(file: anytype, scratch: []u8, expected: Seal, context: anytype, comptime receive: anytype) !void {
    if (scratch.len == 0) return error.SnapshotScratchEmpty;
    if (expected.payload_bytes > max_payload_bytes) return error.SnapshotTooLarge;
    const expected_length = overhead + expected.payload_bytes;
    try checkLength(file, expected_length);

    var header: [header_size]u8 = undefined;
    try readExact(file, 0, &header);
    if (!std.mem.eql(u8, header[0..8], header_magic)) return error.UnsupportedSnapshotFormat;
    const identity_header = encodeHeader(expected.identity);
    if (!std.mem.eql(u8, &header, &identity_header)) return error.SnapshotIdentityMismatch;

    var footer: [footer_size]u8 = undefined;
    const payload_end = header_size + expected.payload_bytes;
    try readExact(file, payload_end, &footer);
    if (!std.mem.eql(u8, footer[40..48], footer_magic) or
        std.mem.readInt(u64, footer[0..8], .little) != expected.payload_bytes) return error.InvalidSnapshotFooter;
    if (!std.mem.eql(u8, footer[8..40], &expected.digest)) return error.SnapshotDigestMismatch;

    var hash = Hash.init(.{});
    hash.update(&header);
    var offset: u64 = header_size;
    while (offset < payload_end) {
        const count: usize = @intCast(@min(payload_end - offset, scratch.len));
        const bytes = scratch[0..count];
        try readExact(file, offset, bytes);
        hash.update(bytes);
        if (comptime @TypeOf(receive) != @TypeOf(null)) try receive(context, bytes);
        offset += count;
    }
    hash.update(footer[0..8]);
    var digest: [Hash.digest_length]u8 = undefined;
    hash.final(&digest);
    if (!std.mem.eql(u8, &digest, &expected.digest)) return error.SnapshotDigestMismatch;
    try checkLength(file, expected_length);
}
