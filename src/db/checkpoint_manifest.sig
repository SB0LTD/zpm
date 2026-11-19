//! Fixed-size selection record for one sealed checkpoint and its WAL anchor.
//! The caller holds the stable database writer lock, creates a temporary file
//! exclusively, then publishes it atomically through the native file layer.
const std = @import("std");
const Hash = std.crypto.hash.Blake3;
const magic = "RAMSQLM1";
const body_size = 128;
pub const record_size = body_size + Hash.digest_length;

pub const DatabaseIdentity = struct {
    database: [16]u8,
    namespace: [16]u8,
    oid: u32,

    pub fn same(self: DatabaseIdentity, expected: DatabaseIdentity) bool {
        return self.oid == expected.oid and std.mem.eql(u8, &self.database, &expected.database) and
            std.mem.eql(u8, &self.namespace, &expected.namespace);
    }
};

pub const Selection = struct {
    identity: DatabaseIdentity,
    generation: u64,
    /// Sequence included in the image. The anchor is the next sequence.
    base_sequence: u64,
    sql_csn: u64,
    image_bytes: u64,
    image_digest: [Hash.digest_length]u8,
    anchor_offset: u64,
    anchor_length: u32,
    anchor_kind: u16,

    pub fn anchorSequence(self: Selection) !u64 {
        return std.math.add(u64, self.base_sequence, 1) catch error.InvalidCheckpointManifest;
    }

    fn validate(self: Selection) !void {
        if (self.identity.oid == 0 or self.generation == 0 or self.base_sequence == std.math.maxInt(u64) or
            self.anchor_kind == 0 or self.anchor_kind >= 32 or self.anchor_length == 0 or
            self.anchor_offset > std.math.maxInt(i64) or self.image_bytes > std.math.maxInt(i64)) return error.InvalidCheckpointManifest;
    }

    pub fn encode(self: Selection) ![record_size]u8 {
        try self.validate();
        var bytes: [record_size]u8 = @splat(0);
        @memcpy(bytes[0..8], magic);
        bytes[8..24].* = self.identity.database;
        bytes[24..40].* = self.identity.namespace;
        std.mem.writeInt(u32, bytes[40..44], self.identity.oid, .little);
        std.mem.writeInt(u16, bytes[44..46], self.anchor_kind, .little);
        std.mem.writeInt(u64, bytes[48..56], self.generation, .little);
        std.mem.writeInt(u64, bytes[56..64], self.base_sequence, .little);
        std.mem.writeInt(u64, bytes[64..72], self.sql_csn, .little);
        std.mem.writeInt(u64, bytes[72..80], self.image_bytes, .little);
        bytes[80..112].* = self.image_digest;
        std.mem.writeInt(u64, bytes[112..120], self.anchor_offset, .little);
        std.mem.writeInt(u32, bytes[120..124], self.anchor_length, .little);
        Hash.hash(bytes[0..body_size], bytes[body_size..], .{});
        return bytes;
    }

    pub fn decode(bytes: []const u8) !Selection {
        if (bytes.len != record_size) return error.InvalidCheckpointManifest;
        if (!std.mem.eql(u8, bytes[0..8], magic)) return error.UnsupportedCheckpointManifest;
        var digest: [Hash.digest_length]u8 = undefined;
        Hash.hash(bytes[0..body_size], &digest, .{});
        if (!std.mem.eql(u8, bytes[body_size..], &digest)) return error.CheckpointManifestDigestMismatch;
        if (std.mem.readInt(u16, bytes[46..48], .little) != 0 or std.mem.readInt(u32, bytes[124..128], .little) != 0)
            return error.InvalidCheckpointManifest;
        const selected: Selection = .{
            .identity = .{
                .database = bytes[8..24].*,
                .namespace = bytes[24..40].*,
                .oid = std.mem.readInt(u32, bytes[40..44], .little),
            },
            .anchor_kind = std.mem.readInt(u16, bytes[44..46], .little),
            .generation = std.mem.readInt(u64, bytes[48..56], .little),
            .base_sequence = std.mem.readInt(u64, bytes[56..64], .little),
            .sql_csn = std.mem.readInt(u64, bytes[64..72], .little),
            .image_bytes = std.mem.readInt(u64, bytes[72..80], .little),
            .image_digest = bytes[80..112].*,
            .anchor_offset = std.mem.readInt(u64, bytes[112..120], .little),
            .anchor_length = std.mem.readInt(u32, bytes[120..124], .little),
        };
        try selected.validate();
        return selected;
    }

    /// Write and sync an exclusively created temporary record. The caller
    /// closes and atomically selects this file only after success.
    pub fn write(self: Selection, file: anytype) !void {
        if (try file.length() != 0) return error.CheckpointManifestDestinationNotEmpty;
        const bytes = try self.encode();
        try file.appendAll(&bytes);
        if (try file.length() != bytes.len) return error.InvalidCheckpointManifest;
        try file.sync();
    }

    pub fn read(file: anytype, expected: DatabaseIdentity) !Selection {
        var bytes: [record_size]u8 = undefined;
        if (try file.length() != bytes.len) return error.InvalidCheckpointManifest;
        var filled: usize = 0;
        while (filled < bytes.len) {
            const count = try file.readAt(filled, bytes[filled..]);
            if (count == 0 or count > bytes.len - filled) return error.InvalidCheckpointManifest;
            filled += count;
        }
        if (try file.length() != bytes.len) return error.InvalidCheckpointManifest;
        const output = try decode(&bytes);
        if (!output.identity.same(expected)) return error.CheckpointDatabaseMismatch;
        return output;
    }
};
