//! Portable append-only committed transaction framing (Layer 0).
//! Never serializes native structs. Integers are little endian, version is 1,
//! and CRC-32 protects header and payload independently. Recovery only discards
//! a physically incomplete final record; a complete corrupt record fails closed.
//! Backends provide length/readAt/appendAll/truncate/sync. append's success means
//! the commit trailer AND its preceding bytes have reached backend stable storage.
//! Any append error poisons a writer: do not acknowledge or continue until recovery.

pub const header_size: usize = 32;
pub const trailer_size: usize = 16;
pub const overhead: usize = header_size + trailer_size;
const magic = "RAMSQLW1";
const commit_magic = "CMIT";
pub const Recovery = struct { sequence: u64 = 0, valid_bytes: u64 = 0, truncated_tail: bool = false };

fn put(comptime T: type, out: []u8, value: T) void {
    for (0..@sizeOf(T)) |i| out[i] = @truncate(value >> @intCast(i * 8));
}
fn get(comptime T: type, input: []const u8) T {
    var value: T = 0;
    for (0..@sizeOf(T)) |i| value |= @as(T, input[i]) << @intCast(i * 8);
    return value;
}
fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
const crc_table = block: {
    @setEvalBranchQuota(20000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var value: u32 = @intCast(i);
        for (0..8) |_| value = (value >> 1) ^ (if (value & 1 != 0) @as(u32, 0xedb88320) else 0);
        table[i] = value;
    }
    break :block table;
};
pub fn checksum(bytes: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (bytes) |byte| crc = crc_table[@as(u8, @truncate(crc)) ^ byte] ^ (crc >> 8);
    return ~crc;
}

pub fn append(file: anytype, sequence: u64, payload: []const u8) !void {
    return appendKind(file, sequence, payload, 1);
}

/// Product-owned payload semantics are versioned independently from framing.
/// A nonzero kind must be checked during recovery before replaying any SQL.
pub fn appendKind(file: anytype, sequence: u64, payload: []const u8, kind: u16) !void {
    if (kind == 0) return error.UnsupportedLogVersion;
    if (sequence == 0) return error.InvalidSequence;
    if (payload.len == 0 or payload.len > 0xffffffff) return error.InvalidPayloadLength;
    var header: [header_size]u8 = @splat(0);
    @memcpy(header[0..8], magic);
    put(u16, header[8..10], 1);
    put(u16, header[10..12], kind);
    put(u32, header[12..16], @intCast(payload.len));
    put(u64, header[16..24], sequence);
    put(u32, header[24..28], checksum(&header));
    var trailer: [trailer_size]u8 = undefined;
    put(u32, trailer[0..4], checksum(payload));
    @memcpy(trailer[4..8], commit_magic);
    put(u64, trailer[8..16], sequence);
    // Ordinary SQL records fit one small, bounded staging buffer. Coalescing
    // their framing avoids three native write calls per synchronous commit.
    // Large transactions retain the streaming path and constant stack bound.
    var small_record: [4096]u8 = undefined;
    if (payload.len <= small_record.len - overhead) {
        @memcpy(small_record[0..header_size], &header);
        @memcpy(small_record[header_size..][0..payload.len], payload);
        @memcpy(small_record[header_size + payload.len ..][0..trailer_size], &trailer);
        try file.appendAll(small_record[0 .. payload.len + overhead]);
    } else {
        try file.appendAll(&header);
        try file.appendAll(payload);
        try file.appendAll(&trailer);
    }
    try file.sync();
}

fn readExact(file: anytype, offset: u64, bytes: []u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = try file.readAt(offset + done, bytes[done..]);
        if (n == 0 or n > bytes.len - done) return error.UnexpectedEndOfLog;
        done += n;
    }
}

/// scratch bounds transaction bytes and is reused between records. The replay
/// callback must apply each entire batch atomically. Semantic replay failures
/// propagate without repairing or truncating the source. First sequence is 1.
pub fn recover(file: anytype, scratch: []u8, context: anytype, comptime replay: anytype) !Recovery {
    return recoverKind(file, scratch, context, replay, 1);
}

/// Refuses incompatible payload semantics without modifying the original WAL.
pub fn recoverKind(file: anytype, scratch: []u8, context: anytype, comptime replay: anytype, kind: u16) !Recovery {
    if (kind == 0 or kind > 31) return error.UnsupportedLogVersion;
    return recoverImpl(file, scratch, context, replay, @as(u32, 1) << @intCast(kind), false);
}

/// Like recoverKind, but accepts every kind whose bit is set in accepted_mask
/// (bit k accepts kind k; bit 0 is ignored) and calls
/// replay(context, kind, sequence, payload). Any other kind fails closed with
/// UnsupportedLogVersion before its payload is replayed.
pub fn recoverKinds(file: anytype, scratch: []u8, context: anytype, comptime replay: anytype, accepted_mask: u32) !Recovery {
    if (accepted_mask & ~@as(u32, 1) == 0) return error.UnsupportedLogVersion;
    return recoverImpl(file, scratch, context, replay, accepted_mask & ~@as(u32, 1), true);
}

fn recoverImpl(file: anytype, scratch: []u8, context: anytype, comptime replay: anytype, accepted_mask: u32, comptime with_kind: bool) !Recovery {
    const length: u64 = try file.length();
    var result: Recovery = .{};
    while (result.valid_bytes < length) {
        const remaining = length - result.valid_bytes;
        if (remaining < header_size) break;
        var header: [header_size]u8 = undefined;
        try readExact(file, result.valid_bytes, &header);
        const expected_crc = get(u32, header[24..28]);
        @memset(header[24..28], 0);
        if (!equal(header[0..8], magic) or checksum(&header) != expected_crc) return error.CorruptLogHeader;
        const kind = get(u16, header[10..12]);
        if (get(u16, header[8..10]) != 1 or kind == 0 or kind > 31 or accepted_mask & (@as(u32, 1) << @intCast(kind)) == 0) return error.UnsupportedLogVersion;
        if (get(u32, header[28..32]) != 0) return error.CorruptLogHeader;
        const payload_len: usize = get(u32, header[12..16]);
        if (payload_len == 0) return error.InvalidPayloadLength;
        if (payload_len > scratch.len) return error.LogPayloadCapacity;
        const sequence = get(u64, header[16..24]);
        if (result.sequence == 0xffffffffffffffff or sequence != result.sequence + 1) return error.InvalidSequence;
        const record_length: u64 = @as(u64, payload_len) + overhead;
        if (record_length > remaining) break;
        const payload = scratch[0..payload_len];
        try readExact(file, result.valid_bytes + header_size, payload);
        var trailer: [trailer_size]u8 = undefined;
        try readExact(file, result.valid_bytes + header_size + payload_len, &trailer);
        if (get(u32, trailer[0..4]) != checksum(payload) or !equal(trailer[4..8], commit_magic) or
            get(u64, trailer[8..16]) != sequence) return error.CorruptLogRecord;
        if (with_kind) try replay(context, kind, sequence, payload) else try replay(context, sequence, payload);
        result.sequence = sequence;
        result.valid_bytes += record_length;
    }
    if (result.valid_bytes != length) {
        try file.truncate(result.valid_bytes);
        try file.sync();
        result.truncated_tail = true;
    }
    return result;
}
