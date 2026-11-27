//! Durable single-writer streams. Signed checkpoints authenticate one writer's
//! state, not a global ledger. No clocks, allocation, filesystem or transport.
const std = @import("std");
pub const Key = [32]u8;
pub const Identity = std.crypto.sign.Ed25519.KeyPair;
pub const payload_capacity = 224;
pub const header_size = 120;
pub const frame_capacity = header_size + payload_capacity + 64;
pub const Kind = enum(u8) { event = 1, snapshot = 2 };
pub const Result = enum { changed, duplicate, stale };
pub const Error = error{ InvalidFrame, WrongRealm, BadSignature, UntrustedWriter, Capacity, HistoryGap, Conflict, SnapshotRequired, CorruptJournal, MissingJournal, Poisoned, Exhausted };
pub fn put(comptime T: type, bytes: []u8, value: T) void {
    inline for (0..@sizeOf(T)) |i| bytes[i] = @truncate(value >> (i * 8));
}
pub fn get(comptime T: type, bytes: []const u8) T {
    var value: T = 0;
    inline for (0..@sizeOf(T)) |i| value |= @as(T, bytes[i]) << (i * 8);
    return value;
}
pub fn hash(bytes: []const u8) Key {
    var out: Key = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
pub const View = struct { kind: Kind, origin: Key, sequence: u64, previous: Key, body: []const u8 };
pub fn decode(bytes: []const u8, realm: Key) !View {
    if (bytes.len < header_size + 64 or bytes.len > frame_capacity or !std.mem.eql(u8, bytes[0..5], "ZMH1\x01") or bytes[6] != 0 or bytes[7] != 0) return error.InvalidFrame;
    for (bytes[114..120]) |b| if (b != 0) return error.InvalidFrame;
    const size = get(u16, bytes[112..114]);
    if (bytes.len != header_size + @as(usize, size) + 64) return error.InvalidFrame;
    if (!std.mem.eql(u8, bytes[8..40], &realm)) return error.WrongRealm;
    const kind = std.enums.fromInt(Kind, bytes[5]) orelse return error.InvalidFrame;
    const view: View = .{ .kind = kind, .origin = bytes[40..72].*, .sequence = get(u64, bytes[72..80]), .previous = bytes[80..112].*, .body = bytes[120 .. 120 + size] };
    if (kind == .event and view.sequence == 0) return error.InvalidFrame;
    const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(view.origin) catch return error.BadSignature;
    std.crypto.sign.Ed25519.Signature.fromBytes(bytes[bytes.len - 64 ..][0..64].*).verifyStrict(bytes[0 .. bytes.len - 64], key) catch return error.BadSignature;
    return view;
}
pub fn encode(identity: *const Identity, realm: Key, kind: Kind, sequence: u64, previous: Key, body: []const u8, out: []u8) !usize {
    if (body.len > payload_capacity or out.len < header_size + body.len + 64 or (kind == .event and sequence == 0)) return error.Capacity;
    const size = header_size + body.len + 64;
    @memset(out[0..size], 0);
    @memcpy(out[0..5], "ZMH1\x01");
    out[5] = @backingInt(kind);
    @memcpy(out[8..40], &realm);
    @memcpy(out[40..72], &identity.public_key.toBytes());
    put(u64, out[72..80], sequence);
    @memcpy(out[80..112], &previous);
    put(u16, out[112..114], @intCast(body.len));
    @memcpy(out[120..][0..body.len], body);
    const signature = try identity.sign(out[0 .. size - 64], null);
    @memcpy(out[size - 64 .. size], &signature.toBytes());
    return size;
}
/// Reducer.initial/validate/apply operate on one fixed canonical byte record.
/// Only listed writers may update their own stream. Configure the same ordered,
/// unique writer list on recovery; changing it requires an explicit migration.
pub fn Journal(comptime writers: usize, comptime retention: usize, comptime state_size: usize, comptime Reducer: type) type {
    if (writers == 0 or writers > 64 or retention == 0 or retention > 256 or state_size == 0 or state_size > payload_capacity) @compileError("Invalid journal bounds");
    return struct {
        const Self = @This();
        pub const writer_count = writers;
        pub const State = [state_size]u8;
        pub const Frame = struct { bytes: [frame_capacity]u8 = undefined, len: u16 = 0 };
        pub const Stream = struct {
            origin: Key,
            cursor: u64 = 0,
            head: Key = @splat(0),
            state: State = Reducer.initial(),
            anchor: Frame = .{},
            events: [retention]Frame = @splat(.{}),
            count: usize = 0,
        };
        pub const image_capacity = 88 + writers * (76 + frame_capacity + retention * (2 + frame_capacity)) + 32;
        realm: Key,
        owner: Key,
        generation: u64 = 0,
        streams: [writers]Stream = undefined,
        pub fn initInPlace(self: *Self, realm: Key, owner: Key, origins: [writers]Key) !void {
            self.realm = realm;
            self.owner = owner;
            self.generation = 0;
            for (origins, 0..) |origin, i| {
                _ = std.crypto.sign.Ed25519.PublicKey.fromBytes(origin) catch return error.UntrustedWriter;
                for (origins[0..i]) |other| if (std.mem.eql(u8, &origin, &other)) return error.UntrustedWriter;
                self.streams[i] = .{ .origin = origin };
            }
            try Reducer.validate(&Reducer.initial());
        }
        pub fn find(self: *const Self, origin: Key) !usize {
            for (self.streams, 0..) |stream, i| if (std.mem.eql(u8, &stream.origin, &origin)) return i;
            return error.UntrustedWriter;
        }
        fn anchorCursor(stream: *const Stream) u64 {
            return if (stream.anchor.len == 0) 0 else get(u64, stream.anchor.bytes[72..80]);
        }
        fn push(stream: *Stream, bytes: []const u8) void {
            if (stream.count == retention) {
                for (1..retention) |i| stream.events[i - 1] = stream.events[i];
                stream.count -= 1;
            }
            const frame = &stream.events[stream.count];
            @memcpy(frame.bytes[0..bytes.len], bytes);
            frame.len = @intCast(bytes.len);
            stream.count += 1;
        }
        fn event(self: *Self, bytes: []const u8, local_checkpoint: bool) !Result {
            const view = try decode(bytes, self.realm);
            if (view.kind != .event) return error.InvalidFrame;
            const stream = &self.streams[try self.find(view.origin)];
            const digest = hash(bytes);
            if (view.sequence == stream.cursor) return if (std.mem.eql(u8, &digest, &stream.head)) .duplicate else error.Conflict;
            if (view.sequence < stream.cursor) return .stale;
            if (stream.cursor == std.math.maxInt(u64)) return error.Exhausted;
            if (view.sequence != stream.cursor + 1) return error.HistoryGap;
            if (!std.mem.eql(u8, &view.previous, &stream.head)) return error.Conflict;
            if (!local_checkpoint and stream.count == retention and get(u64, stream.events[0].bytes[72..80]) > anchorCursor(stream)) return error.SnapshotRequired;
            var state = stream.state;
            try Reducer.apply(&state, view.body);
            try Reducer.validate(&state);
            push(stream, bytes);
            stream.state = state;
            stream.cursor = view.sequence;
            stream.head = digest;
            return .changed;
        }
        pub fn acceptEvent(self: *Self, bytes: []const u8) !Result {
            return self.event(bytes, false);
        }
        pub fn append(self: *Self, identity: *const Identity, payload: []const u8, scratch: []u8) !void {
            const origin = identity.public_key.toBytes();
            const i = try self.find(origin);
            if (!std.mem.eql(u8, &origin, &self.owner)) return error.UntrustedWriter;
            const stream = &self.streams[i];
            if (stream.cursor == std.math.maxInt(u64)) return error.Exhausted;
            const size = try encode(identity, self.realm, .event, stream.cursor + 1, stream.head, payload, scratch);
            _ = try self.event(scratch[0..size], true);
            stream.anchor.len = @intCast(try encode(identity, self.realm, .snapshot, stream.cursor, stream.head, &stream.state, &stream.anchor.bytes));
        }
        pub fn acceptSnapshot(self: *Self, bytes: []const u8) !Result {
            const view = try decode(bytes, self.realm);
            if (view.kind != .snapshot or view.body.len != state_size) return error.InvalidFrame;
            const stream = &self.streams[try self.find(view.origin)];
            const state: State = view.body[0..state_size].*;
            try Reducer.validate(&state);
            if (view.sequence == 0 and (!std.mem.eql(u8, &state, &Reducer.initial()) or !std.mem.eql(u8, &view.previous, &@as(Key, @splat(0))))) return error.Conflict;
            if (view.sequence < stream.cursor) return .stale;
            if (view.sequence == stream.cursor) {
                if (!std.mem.eql(u8, &stream.head, &view.previous) or !std.mem.eql(u8, &stream.state, &state)) return error.Conflict;
                if (std.mem.eql(u8, stream.anchor.bytes[0..stream.anchor.len], bytes)) return .duplicate;
            } else {
                stream.cursor = view.sequence;
                stream.head = view.previous;
                stream.state = state;
                stream.count = 0;
            }
            @memcpy(stream.anchor.bytes[0..bytes.len], bytes);
            stream.anchor.len = @intCast(bytes.len);
            return .changed;
        }
        pub fn accept(self: *Self, bytes: []const u8) !Result {
            if (bytes.len < 6) return error.InvalidFrame;
            return if (bytes[5] == @backingInt(Kind.event)) self.acceptEvent(bytes) else self.acceptSnapshot(bytes);
        }
        /// Prefer the exact next event. If retained history cannot bridge the
        /// cursor, return a writer-signed snapshot or an explicit unavailable error.
        pub fn after(self: *const Self, origin: Key, cursor: u64, head: Key, force_snapshot: bool) !?[]const u8 {
            const stream = &self.streams[try self.find(origin)];
            if (cursor > stream.cursor) return null;
            if (cursor == stream.cursor) {
                if (!std.mem.eql(u8, &head, &stream.head)) return error.Conflict;
                return null;
            }
            if (!force_snapshot) for (stream.events[0..stream.count]) |*frame| {
                if (get(u64, frame.bytes[72..80]) == cursor + 1) {
                    if (!std.mem.eql(u8, frame.bytes[80..112], &head)) return error.Conflict;
                    return frame.bytes[0..frame.len];
                }
            };
            if (stream.anchor.len != 0 and anchorCursor(stream) > cursor) return stream.anchor.bytes[0..stream.anchor.len];
            return error.SnapshotRequired;
        }
        fn advance(self: *Self) !void {
            if (self.generation == std.math.maxInt(u64)) return error.Exhausted;
            self.generation += 1;
        }
        pub fn encodeImage(self: *const Self, out: []u8) !usize {
            if (out.len < image_capacity) return error.Capacity;
            @memset(out[0..88], 0);
            @memcpy(out[0..5], "ZMD1\x01");
            @memcpy(out[8..40], &self.realm);
            @memcpy(out[40..72], &self.owner);
            put(u64, out[72..80], self.generation);
            put(u16, out[80..82], writers);
            var pos: usize = 88;
            for (self.streams) |stream| {
                @memcpy(out[pos..][0..32], &stream.origin);
                put(u64, out[pos + 32 ..][0..8], stream.cursor);
                @memcpy(out[pos + 40 ..][0..32], &stream.head);
                put(u16, out[pos + 72 ..][0..2], stream.anchor.len);
                put(u16, out[pos + 74 ..][0..2], @intCast(stream.count));
                pos += 76;
                @memcpy(out[pos..][0..stream.anchor.len], stream.anchor.bytes[0..stream.anchor.len]);
                pos += stream.anchor.len;
                for (stream.events[0..stream.count]) |frame| {
                    put(u16, out[pos..][0..2], frame.len);
                    pos += 2;
                    @memcpy(out[pos..][0..frame.len], frame.bytes[0..frame.len]);
                    pos += frame.len;
                }
            }
            @memcpy(out[pos..][0..32], &hash(out[0..pos]));
            return pos + 32;
        }
        /// Call on staging storage. Decode authenticates every retained frame and
        /// replays from its signed anchor/genesis, then checks the persisted cursor.
        pub fn decodeImage(self: *Self, bytes: []const u8) !void {
            if (bytes.len < 120 or bytes.len > image_capacity or !std.mem.eql(u8, bytes[0..8], "ZMD1\x01\x00\x00\x00") or !std.mem.eql(u8, bytes[8..40], &self.realm) or !std.mem.eql(u8, bytes[40..72], &self.owner) or get(u16, bytes[80..82]) != writers or !std.mem.eql(u8, bytes[bytes.len - 32 ..], &hash(bytes[0 .. bytes.len - 32]))) return error.CorruptJournal;
            for (bytes[82..88]) |b| if (b != 0) return error.CorruptJournal;
            const generation = get(u64, bytes[72..80]);
            if (generation == 0) return error.CorruptJournal;
            var pos: usize = 88;
            const end = bytes.len - 32;
            for (&self.streams) |*stream| {
                if (pos > end or end - pos < 76 or !std.mem.eql(u8, bytes[pos..][0..32], &stream.origin)) return error.CorruptJournal;
                const target = get(u64, bytes[pos + 32 ..][0..8]);
                const target_head: Key = bytes[pos + 40 ..][0..32].*;
                const anchor_len = get(u16, bytes[pos + 72 ..][0..2]);
                const count = get(u16, bytes[pos + 74 ..][0..2]);
                pos += 76;
                if (anchor_len > frame_capacity or count > retention or anchor_len > end - pos) return error.CorruptJournal;
                stream.* = .{ .origin = stream.origin };
                if (anchor_len != 0) {
                    _ = try self.acceptSnapshot(bytes[pos..][0..anchor_len]);
                    pos += anchor_len;
                }
                const anchor_cursor = stream.cursor;
                var prior_sequence: ?u64 = null;
                var prior_hash: Key = undefined;
                for (0..count) |_| {
                    if (end - pos < 2) return error.CorruptJournal;
                    const size = get(u16, bytes[pos..][0..2]);
                    pos += 2;
                    if (size > frame_capacity or size > end - pos) return error.CorruptJournal;
                    const frame = bytes[pos..][0..size];
                    const view = try decode(frame, self.realm);
                    pos += size;
                    if (view.kind != .event or !std.mem.eql(u8, &view.origin, &stream.origin) or view.sequence > target) return error.CorruptJournal;
                    if (prior_sequence) |prior| {
                        if (prior == std.math.maxInt(u64) or view.sequence != prior + 1 or !std.mem.eql(u8, &view.previous, &prior_hash)) return error.CorruptJournal;
                    }
                    const digest = hash(frame);
                    prior_sequence = view.sequence;
                    prior_hash = digest;
                    if (view.sequence == anchor_cursor and !std.mem.eql(u8, &digest, &stream.head)) return error.CorruptJournal;
                    if (view.sequence > anchor_cursor) {
                        if (stream.cursor == std.math.maxInt(u64) or view.sequence != stream.cursor + 1 or !std.mem.eql(u8, &view.previous, &stream.head)) return error.CorruptJournal;
                        try Reducer.apply(&stream.state, view.body);
                        try Reducer.validate(&stream.state);
                        stream.cursor = view.sequence;
                        stream.head = digest;
                    }
                    push(stream, frame);
                }
                if (stream.cursor != target or !std.mem.eql(u8, &stream.head, &target_head)) return error.CorruptJournal;
                if (prior_sequence) |last| if (last != target or !std.mem.eql(u8, &prior_hash, &target_head)) return error.CorruptJournal;
            }
            if (pos != end) return error.CorruptJournal;
            self.generation = generation;
        }
        pub fn fingerprint(self: *const Self) Key {
            var order: [writers]usize = undefined;
            for (&order, 0..) |*i, index| i.* = index;
            for (0..writers) |i| for (i + 1..writers) |j| {
                if (std.mem.order(u8, &self.streams[order[j]].origin, &self.streams[order[i]].origin) == .lt) std.mem.swap(usize, &order[i], &order[j]);
            };
            var digest = std.crypto.hash.sha2.Sha256.init(.{});
            digest.update(&self.realm);
            for (order) |i| {
                const stream = &self.streams[i];
                digest.update(&stream.origin);
                var cursor: [8]u8 = undefined;
                put(u64, &cursor, stream.cursor);
                digest.update(&cursor);
                digest.update(&stream.head);
                digest.update(&stream.state);
            }
            var result: Key = undefined;
            digest.final(&result);
            return result;
        }
        /// Backend.load/save use caller buffers and atomic durable replacement.
        /// A save error is ambiguous: fail closed until reloading the disk image.
        pub fn Durable(comptime Backend: type) type {
            return struct {
                const DurableSelf = @This();
                pub const Core = Self;
                live: Self,
                staged: Self,
                buffer: [image_capacity]u8 = undefined,
                scratch: [frame_capacity]u8 = undefined,
                poisoned: bool = false,
                pub fn init(self: *DurableSelf, realm: Key, owner: Key, origins: [writers]Key, create: bool) !void {
                    self.poisoned = true;
                    try self.live.initInPlace(realm, owner, origins);
                    self.staged = self.live;
                    if (try Backend.load(&self.buffer)) |size| {
                        try self.staged.decodeImage(self.buffer[0..size]);
                        self.live = self.staged;
                    } else {
                        if (!create) return error.MissingJournal;
                        try self.commit();
                    }
                    self.poisoned = false;
                }
                fn commit(self: *DurableSelf) !void {
                    try self.staged.advance();
                    const size = try self.staged.encodeImage(&self.buffer);
                    Backend.save(self.buffer[0..size]) catch |err| {
                        self.poisoned = true;
                        return err;
                    };
                    self.live = self.staged;
                }
                pub fn append(self: *DurableSelf, identity: *const Identity, payload: []const u8) !void {
                    if (self.poisoned) return error.Poisoned;
                    self.staged = self.live;
                    try self.staged.append(identity, payload, &self.scratch);
                    try self.commit();
                }
                pub fn accept(self: *DurableSelf, frame: []const u8) !Result {
                    if (self.poisoned) return error.Poisoned;
                    self.staged = self.live;
                    const result = try self.staged.accept(frame);
                    if (result == .changed) try self.commit();
                    return result;
                }
            };
        }
    };
}
