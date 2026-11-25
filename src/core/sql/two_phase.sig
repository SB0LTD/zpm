//! Durable prepared-transaction payload, independent of WAL framing.
//! A PREPARE contains stable lock identities followed by logical row changes.
//! A decision names the GID and exact sequence of its PREPARE frame.
const std = @import("std");
const Error = @import("types.sig").Error;

pub const wal_kind: u16 = 4;
const version: u16 = 1;
const prefix_bytes = 4;
const prepare_header_bytes = 28;
const decision_header_bytes = 12;
const lock_bytes = 13;

pub const Gid = struct {
    len: u8 = 0,
    bytes: [199]u8 = undefined,

    pub fn init(source: []const u8) Error!Gid {
        if (source.len > 199 or std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidParameterValue;
        var gid: Gid = .{ .len = @intCast(source.len) };
        @memcpy(gid.bytes[0..source.len], source);
        return gid;
    }

    pub fn slice(self: *const Gid) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Gid, other: *const Gid) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const Metadata = struct {
    gid: Gid,
    owner: u32,
    database: u32,
    prepared_at: i64,
};

/// A zero row ID names a table and `mode` is its complete mode mask.
/// Otherwise `mode` is the final explicit row-lock strength.
pub const Lock = struct {
    table_oid: u32,
    rowid: u64,
    mode: u8,

    fn valid(self: Lock) bool {
        if (self.table_oid == 0 or self.rowid == std.math.maxInt(u64)) return false;
        return if (self.rowid == 0) self.mode != 0 else switch (self.mode) {
            1, 2, 4, 5 => true,
            else => false,
        };
    }
};

pub const Locks = struct {
    bytes: []const u8,

    pub fn next(self: *Locks) ?Lock {
        if (self.bytes.len == 0) return null;
        const lock: Lock = .{
            .table_oid = std.mem.readInt(u32, self.bytes[0..4], .little),
            .rowid = std.mem.readInt(u64, self.bytes[4..12], .little),
            .mode = self.bytes[12],
        };
        self.bytes = self.bytes[lock_bytes..];
        return lock;
    }
};

pub const Prepared = struct {
    metadata: Metadata,
    locks: Locks,
    changes: []const u8,
};

pub const Decision = struct {
    gid: Gid,
    prepare_sequence: u64,
    commit: bool,
};

pub const Record = union(enum) { prepare: Prepared, decision: Decision };
const Operation = enum(u8) { prepare = 1, commit = 2, rollback = 3 };

pub const PrepareWriter = struct {
    buffer: []u8,
    used: usize,
    lock_count: u32 = 0,

    pub fn init(buffer: []u8, metadata: *const Metadata) Error!PrepareWriter {
        const gid = metadata.gid.slice();
        const used = prepare_header_bytes + gid.len;
        if (buffer.len < used) return error.TransactionLogCapacity;
        if (metadata.owner == 0 or metadata.database == 0) return error.InvalidParameterValue;
        writePrefix(buffer, .prepare, metadata.gid.len);
        std.mem.writeInt(u32, buffer[4..8], metadata.owner, .little);
        std.mem.writeInt(u32, buffer[8..12], metadata.database, .little);
        std.mem.writeInt(i64, buffer[12..20], metadata.prepared_at, .little);
        @memcpy(buffer[prepare_header_bytes..used], gid);
        return .{ .buffer = buffer, .used = used };
    }

    pub fn addLock(self: *PrepareWriter, lock: Lock) Error!void {
        if (!lock.valid()) return error.InvalidParameterValue;
        if (self.buffer.len - self.used < lock_bytes or self.lock_count == std.math.maxInt(u32)) return error.TransactionLogCapacity;
        const bytes = self.buffer[self.used..][0..lock_bytes];
        std.mem.writeInt(u32, bytes[0..4], lock.table_oid, .little);
        std.mem.writeInt(u64, bytes[4..12], lock.rowid, .little);
        bytes[12] = lock.mode;
        self.used += lock_bytes;
        self.lock_count += 1;
    }

    pub fn changes(self: *const PrepareWriter) []u8 {
        return self.buffer[self.used..];
    }

    pub fn finish(self: *const PrepareWriter, change_len: usize) Error![]const u8 {
        if (change_len > self.buffer.len - self.used or change_len > std.math.maxInt(u32)) return error.TransactionLogCapacity;
        std.mem.writeInt(u32, self.buffer[20..24], self.lock_count, .little);
        std.mem.writeInt(u32, self.buffer[24..28], @intCast(change_len), .little);
        return self.buffer[0 .. self.used + change_len];
    }
};

fn writePrefix(buffer: []u8, operation: Operation, gid_len: u8) void {
    std.mem.writeInt(u16, buffer[0..2], version, .little);
    buffer[2] = @intFromEnum(operation);
    buffer[3] = gid_len;
}

pub fn encodeDecision(buffer: []u8, decision: *const Decision) Error![]const u8 {
    const gid = decision.gid.slice();
    const length = decision_header_bytes + gid.len;
    if (decision.prepare_sequence == 0) return error.InvalidParameterValue;
    if (buffer.len < length) return error.TransactionLogCapacity;
    writePrefix(buffer, if (decision.commit) .commit else .rollback, decision.gid.len);
    std.mem.writeInt(u64, buffer[4..12], decision.prepare_sequence, .little);
    @memcpy(buffer[decision_header_bytes..length], gid);
    return buffer[0..length];
}

/// A clone preserves the prepare sequence and GID for its decision frame.
/// Only the source database identity becomes the new database identity.
pub fn rebindDatabase(payload: []u8, source: u32, destination: u32) Error!void {
    if (source == 0 or destination == 0 or source == destination) return error.InvalidParameterValue;
    switch (try decode(payload)) {
        .prepare => |entry| {
            if (entry.metadata.database != source) return error.ChangeRecordConflict;
            std.mem.writeInt(u32, payload[8..12], destination, .little);
        },
        .decision => {},
    }
}

pub fn decode(bytes: []const u8) Error!Record {
    if (bytes.len < prefix_bytes) return error.InvalidChangeRecord;
    if (std.mem.readInt(u16, bytes[0..2], .little) != version) return error.UnsupportedLogVersion;
    const gid_len: usize = bytes[3];
    switch (bytes[2]) {
        @intFromEnum(Operation.prepare) => {
            const lock_start = prepare_header_bytes + gid_len;
            if (bytes.len < lock_start) return error.InvalidChangeRecord;
            const count: usize = std.mem.readInt(u32, bytes[20..24], .little);
            if (count > (bytes.len - lock_start) / lock_bytes) return error.InvalidChangeRecord;
            const change_start = lock_start + count * lock_bytes;
            if (std.mem.readInt(u32, bytes[24..28], .little) != bytes.len - change_start) return error.InvalidChangeRecord;
            const owner = std.mem.readInt(u32, bytes[4..8], .little);
            const database = std.mem.readInt(u32, bytes[8..12], .little);
            if (owner == 0 or database == 0) return error.InvalidChangeRecord;
            const locks: Locks = .{ .bytes = bytes[lock_start..change_start] };
            var check = locks;
            while (check.next()) |lock| if (!lock.valid()) return error.InvalidChangeRecord;
            return .{ .prepare = .{
                .metadata = .{
                    .gid = Gid.init(bytes[prepare_header_bytes..lock_start]) catch return error.InvalidChangeRecord,
                    .owner = owner,
                    .database = database,
                    .prepared_at = std.mem.readInt(i64, bytes[12..20], .little),
                },
                .locks = locks,
                .changes = bytes[change_start..],
            } };
        },
        @intFromEnum(Operation.commit), @intFromEnum(Operation.rollback) => {
            if (bytes.len != decision_header_bytes + gid_len) return error.InvalidChangeRecord;
            const sequence = std.mem.readInt(u64, bytes[4..12], .little);
            if (sequence == 0) return error.InvalidChangeRecord;
            return .{ .decision = .{
                .gid = Gid.init(bytes[decision_header_bytes..]) catch return error.InvalidChangeRecord,
                .prepare_sequence = sequence,
                .commit = bytes[2] == @intFromEnum(Operation.commit),
            } };
        },
        else => return error.UnsupportedLogVersion,
    }
}
