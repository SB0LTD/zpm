//! Bounded, transport-independent membership and signed gossip. No game or ledger authority.
const std = @import("std");
pub const Key = [32]u8;
pub const Identity = std.crypto.sign.Ed25519.KeyPair;
pub const header_size = 104;
pub const payload_capacity = 512;
pub const frame_capacity = header_size + payload_capacity + 64;
pub const card_size = header_size + 8 + 64;
pub const lease_ms = 30_000;
/// Allow bounded sender clock lead. Expiry itself remains strict: no stale grace.
/// A receiver never accepts an envelope more than 35 seconds into its own future.
pub const clock_lead_ms = 5_000;
pub const Scope = enum { loopback, lan };
pub const Kind = enum(u8) { card = 1, data = 2, dial = 3 };
pub const Error = error{ InvalidFrame, WrongRealm, Expired, BadSignature, ScopeDenied, Capacity, UnknownPeer, Replay, Backpressure, Exhausted, ClockRollback };
pub const Endpoint = struct {
    address: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16,
    pub fn allowed(self: Endpoint, scope: Scope) bool {
        return self.port != 0 and (self.address[0] == 127 or (scope == .lan and
            (self.address[0] == 10 or (self.address[0] == 172 and self.address[1] >= 16 and self.address[1] <= 31) or (self.address[0] == 192 and self.address[1] == 168))));
    }
};
pub fn put(comptime T: type, bytes: []u8, value: T) void {
    inline for (0..@sizeOf(T)) |i| bytes[i] = @truncate(value >> (i * 8));
}
pub fn get(comptime T: type, bytes: []const u8) T {
    var value: T = 0;
    inline for (0..@sizeOf(T)) |i| value |= @as(T, bytes[i]) << (i * 8);
    return value;
}
pub const View = struct {
    kind: Kind,
    origin: Key,
    epoch: u64,
    sequence: u64,
    expires: u64,
    body: []const u8,
    pub fn endpoint(self: View) Endpoint {
        return .{ .address = self.body[0..4].*, .port = get(u16, self.body[4..6]) };
    }
};
pub fn decode(bytes: []const u8, realm: Key, now: u64, scope: Scope) Error!View {
    if (bytes.len < header_size + 64 or bytes.len > frame_capacity or !std.mem.eql(u8, bytes[0..5], "ZMO1\x01") or bytes[6] != 0 or bytes[7] != 0) return error.InvalidFrame;
    for (bytes[98..104]) |b| if (b != 0) return error.InvalidFrame;
    const kind = std.enums.fromInt(Kind, bytes[5]) orelse return error.InvalidFrame;
    const size = get(u16, bytes[96..98]);
    if (bytes.len != header_size + @as(usize, size) + 64 or (kind != .data and size != 8)) return error.InvalidFrame;
    if (!std.mem.eql(u8, bytes[8..40], &realm)) return error.WrongRealm;
    const expires = get(u64, bytes[88..96]);
    if (expires <= now or expires - now > lease_ms + clock_lead_ms) return error.Expired;
    const view: View = .{ .kind = kind, .origin = bytes[40..72].*, .epoch = get(u64, bytes[72..80]), .sequence = get(u64, bytes[80..88]), .expires = expires, .body = bytes[104 .. 104 + size] };
    if (view.epoch == 0 or view.sequence == 0) return error.InvalidFrame;
    if (kind != .data and (view.body[6] != 0 or view.body[7] != 0 or !view.endpoint().allowed(scope))) return error.ScopeDenied;
    const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(view.origin) catch return error.BadSignature;
    std.crypto.sign.Ed25519.Signature.fromBytes(bytes[bytes.len - 64 ..][0..64].*).verifyStrict(bytes[0 .. bytes.len - 64], key) catch return error.BadSignature;
    return view;
}
pub fn encode(identity: *const Identity, realm: Key, kind: Kind, epoch: u64, sequence: u64, expires: u64, body: []const u8, output: []u8) !usize {
    const size = header_size + body.len + 64;
    if (body.len > payload_capacity or size > output.len or (kind != .data and body.len != 8) or epoch == 0 or sequence == 0) return error.InvalidFrame;
    @memset(output[0..size], 0);
    @memcpy(output[0..5], "ZMO1\x01");
    output[5] = @backingInt(kind);
    @memcpy(output[8..40], &realm);
    @memcpy(output[40..72], &identity.public_key.toBytes());
    put(u64, output[72..80], epoch);
    put(u64, output[80..88], sequence);
    put(u64, output[88..96], expires);
    put(u16, output[96..98], @intCast(body.len));
    @memcpy(output[104..][0..body.len], body);
    const signature = try identity.sign(output[0 .. size - 64], null);
    @memcpy(output[size - 64 .. size], &signature.toBytes());
    return size;
}
pub fn cardBody(endpoint: Endpoint) [8]u8 {
    var out: [8]u8 = @splat(0);
    @memcpy(out[0..4], &endpoint.address);
    put(u16, out[4..6], endpoint.port);
    return out;
}
pub const Counters = struct { accepted: u64 = 0, duplicates: u64 = 0, rejected: u64 = 0, backpressure: u64 = 0, evicted: u64 = 0 };
pub fn Overlay(comptime members: usize, comptime history: usize, comptime inbox: usize) type {
    if (members < 2 or members > 64 or history == 0 or inbox == 0) @compileError("Invalid bounded mesh capacity");
    return struct {
        const Self = @This();
        pub const Member = struct {
            used: bool = false,
            key: Key = @splat(0),
            epoch: u64 = 0,
            high: u64 = 0,
            seen: u64 = 0,
            card: [card_size]u8 = undefined,
            card_len: u16 = 0,
            expires: u64 = 0,
            endpoint: Endpoint = .{ .port = 0 },
            connected: bool = false,
            attempts: u8 = 0,
            next_attempt: u64 = 0,
            exhausted: bool = false,
        };
        pub const Frame = struct { bytes: [frame_capacity]u8 = undefined, len: u16 = 0, expires: u64 = 0 };
        realm: Key,
        scope: Scope,
        own: Key,
        peers: [members]Member = @splat(.{}),
        cache: [history]Frame = @splat(.{}),
        cache_cursor: usize = 0,
        events: [inbox]Frame = @splat(.{}),
        event_head: usize = 0,
        event_tail: usize = 0,
        event_count: usize = 0,
        stats: Counters = .{},
        last_now: u64 = 0,
        pub fn init(realm: Key, scope: Scope, own: Key) Self {
            return .{ .realm = realm, .scope = scope, .own = own };
        }
        pub fn find(self: *const Self, key: Key) ?usize {
            for (self.peers, 0..) |p, i| if (p.used and std.mem.eql(u8, &p.key, &key)) return i;
            return null;
        }
        fn clock(self: *Self, now: u64) Error!void {
            if (now < self.last_now) return error.ClockRollback;
            self.last_now = now;
        }
        /// No eviction of identity/replay watermarks. A full table rejects new
        /// identities until explicit application reconfiguration, preventing replay
        /// after membership churn. Expired cards cease to be dial candidates.
        pub fn learn(self: *Self, bytes: []const u8, now: u64) !usize {
            try self.clock(now);
            // An exact byte match is already verified. Repeated signed cards
            // cannot refresh their lease or reset the dial budget.
            if (bytes.len == card_size) {
                if (self.find(bytes[40..72].*)) |known| {
                    const p = &self.peers[known];
                    if (p.expires > now and std.mem.eql(u8, p.card[0..p.card_len], bytes)) return known;
                }
            }
            const view = try decode(bytes, self.realm, now, self.scope);
            if (view.kind == .data) return error.InvalidFrame;
            if (std.mem.eql(u8, &view.origin, &self.own)) return error.Replay;
            var index = self.find(view.origin);
            if (index == null) {
                for (self.peers, 0..) |p, i| {
                    if (!p.used) {
                        index = i;
                        break;
                    }
                }
            }
            const i = index orelse return error.Capacity;
            const old = self.peers[i];
            if (old.used and (view.epoch < old.epoch or (view.epoch == old.epoch and view.sequence <= get(u64, old.card[80..88])))) return i;
            if (old.used and view.epoch == old.epoch and (old.endpoint.port != view.endpoint().port or !std.mem.eql(u8, &old.endpoint.address, &view.endpoint().address))) return error.InvalidFrame;
            var next = old;
            if (!old.used or view.epoch > old.epoch) {
                next = .{};
                next.used = true;
                next.key = view.origin;
                next.epoch = view.epoch;
            }
            // Card and data counters share one sender sequence namespace, but
            // membership refresh must not consume the data replay window.
            @memcpy(next.card[0..bytes.len], bytes);
            next.card_len = @intCast(bytes.len);
            next.expires = view.expires;
            next.endpoint = view.endpoint();
            self.peers[i] = next;
            return i;
        }
        pub fn setConnected(self: *Self, key: Key, value: bool) !void {
            const i = self.find(key) orelse return error.UnknownPeer;
            self.peers[i].connected = value;
            if (value) {
                self.peers[i].attempts = 0;
                self.peers[i].exhausted = false;
            }
        }
        /// Caller drives at most five attempts over a 30-second window. A fresh
        /// explicit retry resets this budget; advertisements alone cannot do so.
        pub fn candidate(self: *Self, now: u64) ?usize {
            for (&self.peers, 0..) |*p, i| {
                if (p.used and !p.connected and p.attempts == 5 and now >= p.next_attempt) p.exhausted = true;
                if (!p.used or p.connected or p.exhausted or p.expires <= now or now < p.next_attempt) continue;
                if (p.attempts == 5) {
                    p.exhausted = true;
                    continue;
                }
                p.attempts += 1;
                p.next_attempt = now + 6000;
                return i;
            }
            return null;
        }
        pub fn retry(self: *Self, key: Key, now: u64) !void {
            const i = self.find(key) orelse return error.UnknownPeer;
            self.peers[i].attempts = 0;
            self.peers[i].exhausted = false;
            self.peers[i].next_attempt = now;
        }
        fn store(self: *Self, bytes: []const u8, expires: u64) void {
            if (self.cache[self.cache_cursor].len != 0) self.stats.evicted += 1;
            var item = &self.cache[self.cache_cursor];
            @memcpy(item.bytes[0..bytes.len], bytes);
            item.len = @intCast(bytes.len);
            item.expires = expires;
            self.cache_cursor = (self.cache_cursor + 1) % history;
        }
        pub fn retainOwn(self: *Self, bytes: []const u8, now: u64) !void {
            const view = try decode(bytes, self.realm, now, self.scope);
            if (view.kind != .data or !std.mem.eql(u8, &view.origin, &self.own)) return error.InvalidFrame;
            self.store(bytes, view.expires);
        }
        /// Only authenticated links may deliver application frames. Signature,
        /// epoch, replay-window and capacity checks precede any mutation/delivery.
        pub fn receive(self: *Self, via: Key, bytes: []const u8, now: u64) !void {
            try self.clock(now);
            const link = self.find(via) orelse return error.UnknownPeer;
            if (!self.peers[link].connected) return error.UnknownPeer;
            // Already delivered sequence numbers may be discarded without
            // cryptographic work. This branch never applies/forwards bytes and
            // never advances a watermark, even if a duplicate header is forged.
            if (bytes.len >= header_size + 64 and std.mem.eql(u8, bytes[0..5], "ZMO1\x01") and bytes[5] == 2 and std.mem.eql(u8, bytes[8..40], &self.realm)) {
                if (self.find(bytes[40..72].*)) |known| {
                    const old = &self.peers[known];
                    const sequence = get(u64, bytes[80..88]);
                    if (get(u64, bytes[72..80]) == old.epoch and sequence <= old.high) {
                        const delta = old.high - sequence;
                        if (delta >= 64 or (old.seen & (@as(u64, 1) << @as(u6, @intCast(delta)))) != 0) {
                            self.stats.duplicates += 1;
                            return error.Replay;
                        }
                    }
                }
            }
            const view = decode(bytes, self.realm, now, self.scope) catch |err| {
                self.stats.rejected += 1;
                return err;
            };
            if (view.kind != .data) {
                _ = try self.learn(bytes, now);
                return;
            }
            if (std.mem.eql(u8, &view.origin, &self.own)) return error.Replay;
            const i = self.find(view.origin) orelse return error.UnknownPeer;
            var p = &self.peers[i];
            if (view.epoch != p.epoch) return error.Replay;
            var seen = p.seen;
            var high = p.high;
            if (view.sequence > high) {
                const delta = view.sequence - high;
                seen = if (delta >= 64) 1 else (seen << @as(u6, @intCast(delta))) | 1;
                high = view.sequence;
            } else {
                const delta = high - view.sequence;
                if (delta >= 64 or (seen & (@as(u64, 1) << @as(u6, @intCast(delta)))) != 0) {
                    self.stats.duplicates += 1;
                    return error.Replay;
                }
                seen |= @as(u64, 1) << @as(u6, @intCast(delta));
            }
            if (self.event_count == inbox) {
                self.stats.backpressure += 1;
                return error.Backpressure;
            }
            var item = &self.events[self.event_tail];
            @memcpy(item.bytes[0..bytes.len], bytes);
            item.len = @intCast(bytes.len);
            item.expires = view.expires;
            self.event_tail = (self.event_tail + 1) % inbox;
            self.event_count += 1;
            p.high = high;
            p.seen = seen;
            self.store(bytes, view.expires);
            self.stats.accepted += 1;
        }
        /// Borrow valid until this queue slot is reused. Consumers copy records
        /// into their own storage and decide application validity/authority.
        pub fn poll(self: *Self) ?[]const u8 {
            if (self.event_count == 0) return null;
            const item = &self.events[self.event_head];
            self.event_head = (self.event_head + 1) % inbox;
            self.event_count -= 1;
            return item.bytes[0..item.len];
        }
    };
}
