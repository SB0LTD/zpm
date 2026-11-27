//! Bounded multi-peer QUIC service. All storage belongs to the caller. Single-thread owned.
const std = @import("std");
const overlay = @import("mesh_overlay");
const transport = @import("mesh_transport");
const conn = @import("conn");
const streams = @import("streams");
const udp = @import("udp");
const w = @import("win32");
pub const Config = struct {
    realm: overlay.Key,
    identity: *const overlay.Identity,
    /// Must increase durably on every process incarnation. Never derive from a
    /// resettable sequence counter. Host owns persistence and UTC clock policy.
    epoch: u64,
    endpoint: overlay.Endpoint,
    scope: overlay.Scope = .loopback,
    seeds: []const overlay.Endpoint = &.{},
};
pub fn Network(comptime member_capacity: usize, comptime link_capacity: usize, comptime history: usize) type {
    return NetworkWithBudget(member_capacity, link_capacity, history, .{});
}
pub fn NetworkWithBudget(comptime member_capacity: usize, comptime link_capacity: usize, comptime history: usize, comptime budget: streams.Budget) type {
    if (link_capacity == 0 or link_capacity > member_capacity) @compileError("Invalid link capacity");
    return struct {
        const Self = @This();
        pub const Core = overlay.Overlay(member_capacity, history, 16);
        pub const Storage = struct { connections: [link_capacity]conn.Connection = undefined, streams: [link_capacity]streams.Storage(budget) = undefined };
        const Link = struct {
            used: bool = false,
            peer: overlay.Key = @splat(0),
            epoch: u64 = 0,
            server: bool = false,
            mesh: transport.Mesh = undefined,
            inbox: udp.Inbox = .{},
            source: w.sockaddr_in = .{},
            activity: u64 = 0,
            received: u64 = 0,
            sent_bytes: u64 = 0,
            received_bytes: u64 = 0,
            started: u64 = 0,
            next_dial: u64 = 0,
            next_sync: u64 = 0,
            card_cursor: usize = 0,
            data_cursor: usize = 0,
        };
        cfg: Config,
        core: Core,
        storage: *Storage,
        listener: udp.UdpSocket,
        links: [link_capacity]Link = @splat(.{}),
        sequence: u64 = 0,
        next_advert: u64 = 0,
        seed_attempts: u8 = 0,
        discovery_deadline: u64 = 0,
        discovery_failed: bool = false,
        card: [overlay.card_size]u8 = undefined,
        card_len: usize = 0,
        certificate: [65]u8 = undefined,
        secret: [32]u8 = undefined,
        scratch: [1500]u8 = undefined,
        wire: [overlay.frame_capacity]u8 = undefined,
        started: bool = false,
        bytes_sent: u64 = 0,
        bytes_received: u64 = 0,
        dropped: u64 = 0,
        reconnects: u64 = 0,
        pub fn init(self: *Self, storage: *Storage, config: Config, now: u64) !void {
            if (config.epoch == 0 or !config.endpoint.allowed(config.scope)) return error.ScopeDenied;
            if (config.seeds.len > member_capacity) return error.Capacity;
            for (config.seeds) |seed| if (!seed.allowed(config.scope)) return error.ScopeDenied;
            self.* = .{ .cfg = config, .core = Core.init(config.realm, config.scope, config.identity.public_key.toBytes()), .storage = storage, .listener = udp.UdpSocket.init() };
            errdefer self.listener.deinit();
            if (self.listener.bind(address(config.endpoint)) != .none) return error.BindFailed;
            var seed: [32]u8 = undefined;
            if (w.BCryptGenRandom(null, &seed, 32, w.BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return error.Entropy;
            const cert = try std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generateDeterministic(seed);
            self.certificate = cert.public_key.toUncompressedSec1();
            self.secret = cert.secret_key.toBytes();
            try self.refreshCard(now);
            self.discovery_deadline = now + 30_000;
            self.started = true;
        }
        pub fn retryDiscovery(self: *Self, now: u64) void {
            self.seed_attempts = 0;
            self.discovery_failed = false;
            self.discovery_deadline = now + 30_000;
            self.next_advert = now;
            for (&self.core.peers) |*peer| {
                peer.attempts = 0;
                peer.exhausted = false;
                peer.next_attempt = now;
            }
        }
        pub fn stop(self: *Self) void {
            if (!self.started) return;
            for (0..link_capacity) |i| self.close(i, 0);
            self.listener.deinit();
            std.crypto.secureZero(u8, &self.secret);
            self.started = false;
        }
        fn next(self: *Self) !u64 {
            if (self.sequence == std.math.maxInt(u64)) return error.Exhausted;
            self.sequence += 1;
            return self.sequence;
        }
        fn expires(now: u64) !u64 {
            return std.math.add(u64, now, overlay.lease_ms) catch error.Exhausted;
        }
        fn refreshCard(self: *Self, now: u64) !void {
            self.card_len = try overlay.encode(self.cfg.identity, self.cfg.realm, .card, self.cfg.epoch, try self.next(), try expires(now), &overlay.cardBody(self.cfg.endpoint), &self.card);
        }
        pub fn broadcast(self: *Self, payload: []const u8, now: u64) !void {
            if (!self.started) return error.NotStarted;
            const size = try overlay.encode(self.cfg.identity, self.cfg.realm, .data, self.cfg.epoch, try self.next(), try expires(now), payload, &self.wire);
            try self.core.retainOwn(self.wire[0..size], now);
            // Expedite forwarding; periodic cache sync also repairs lost datagrams.
            for (&self.links) |*link| if (link.used) {
                if (link.mesh.ready()) link.mesh.broadcastGossip(self.wire[0..size]) catch {};
                link.next_sync = 0;
            };
        }
        pub fn poll(self: *Self) ?[]const u8 {
            return self.core.poll();
        }
        fn close(self: *Self, index: usize, now: u64) void {
            var link = &self.links[index];
            if (!link.used) return;
            self.core.setConnected(link.peer, false) catch {};
            self.storage.connections[index].deinit();
            link.used = false;
            if (self.core.find(link.peer)) |p| self.core.peers[p].next_attempt = now + 500;
        }
        fn linkFor(self: *Self, key: overlay.Key) ?usize {
            for (self.links, 0..) |link, i| if (link.used and std.mem.eql(u8, &link.peer, &key)) return i;
            return null;
        }
        fn vacant(self: *Self) ?usize {
            for (self.links, 0..) |link, i| if (!link.used) return i;
            return null;
        }
        fn open(self: *Self, index: usize, member: usize, server: bool, source: w.sockaddr_in, now: u64) !void {
            var link = &self.links[index];
            link.* = .{};
            link.used = true;
            link.peer = self.core.peers[member].key;
            link.epoch = self.core.peers[member].epoch;
            link.server = server;
            link.source = source;
            link.activity = now;
            link.started = now;
            const c = &self.storage.connections[index];
            if (server) {
                c.initServerScopedInPlace(&self.storage.streams[index], 0, if (self.cfg.scope == .loopback) .loopback else .lan);
                c.socket.deinit();
                c.socket = self.listener.borrow(&link.inbox);
                if (!c.loadTlsCertificate(&self.certificate, &self.secret)) {
                    c.deinit();
                    link.used = false;
                    return error.Certificate;
                }
            } else c.initClientInPlace(&self.storage.streams[index], source, 0);
            if (!c.socket.bound) {
                c.deinit();
                link.used = false;
                return error.BindFailed;
            }
            link.mesh = transport.Mesh.init(c, .{ .identity = self.cfg.identity, .peer = link.peer, .loopback_only = self.cfg.scope == .loopback });
        }
        fn sendRaw(self: *Self, socket: *udp.UdpSocket, bytes: []const u8, destination: w.sockaddr_in) void {
            const result = socket.send(bytes, destination);
            if (result.err == .none) self.bytes_sent += result.bytes_sent else self.dropped += 1;
        }
        fn ingress(self: *Self, bytes: []const u8, source: w.sockaddr_in, now: u64) void {
            if (!conn.addressAllowed(if (self.cfg.scope == .loopback) .loopback else .lan, source.sin_addr)) return;
            if (std.mem.startsWith(u8, bytes, "ZMO1")) {
                const view = overlay.decode(bytes, self.cfg.realm, now, self.cfg.scope) catch {
                    self.dropped += 1;
                    return;
                };
                if (view.kind == .data) {
                    self.dropped += 1;
                    return;
                } // never accept data from raw UDP
                const old = self.core.find(view.origin);
                const fresh = if (old) |p| view.epoch > self.core.peers[p].epoch or view.sequence > overlay.get(u64, self.core.peers[p].card[80..88]) else true;
                const member = self.core.learn(bytes, now) catch {
                    self.dropped += 1;
                    return;
                };
                if (view.kind == .dial) {
                    if (self.linkFor(view.origin)) |existing| {
                        const link = &self.links[existing];
                        if (!sameAddress(link.source, source)) {
                            // A signed, newer dial may replace a stalled server
                            // session. Replaying a card cannot evict a live peer.
                            if (link.server and fresh and (!link.mesh.ready() or now - link.activity > 1000)) {
                                self.close(existing, now);
                                self.open(existing, member, true, source, now) catch {
                                    self.dropped += 1;
                                };
                            } else self.dropped += 1;
                        }
                    } else if (self.vacant()) |free| self.open(free, member, true, source, now) catch {
                        self.dropped += 1;
                    };
                } else {
                    // Signed discovery response, not a live authenticated link.
                    if (fresh and view.endpoint().port == w.ntohs(source.sin_port) and address(view.endpoint()).sin_addr == source.sin_addr)
                        self.sendRaw(&self.listener, self.card[0..self.card_len], source);
                }
                return;
            }
            for (&self.links) |*link| {
                if (link.used and link.server and sameAddress(link.source, source)) {
                    if (!link.inbox.push(bytes, source)) self.dropped += 1;
                    return;
                }
            }
            self.dropped += 1;
        }
        /// Bounded work: at most 16 listener packets, one dial candidate and three
        /// sync frames per link per tick. No thread, socket, queue or allocation growth.
        pub fn tick(self: *Self, now: u64) !void {
            if (!self.started) return error.NotStarted;
            if (now < self.core.last_now) return error.ClockRollback;
            self.core.last_now = now;
            if (now >= self.next_advert) {
                try self.refreshCard(now);
                if (self.connectedCount() > 0) {
                    self.seed_attempts = 0;
                    self.discovery_failed = false;
                    self.discovery_deadline = now + 30_000;
                }
                if (self.seed_attempts < 5) {
                    for (self.cfg.seeds) |seed| self.sendRaw(&self.listener, self.card[0..self.card_len], address(seed));
                    self.seed_attempts += 1;
                }
                if (now >= self.discovery_deadline and self.connectedCount() == 0) self.discovery_failed = true;
                self.next_advert = now + 5000;
            }
            for (0..16) |_| {
                const received = self.listener.recv(&self.scratch);
                if (received.err != .none) break;
                self.bytes_received += received.bytes_read;
                self.ingress(self.scratch[0..received.bytes_read], received.src_addr, now);
            }
            if (!self.discovery_failed) if (self.vacant()) |free| {
                // The smaller identity initiates, avoiding duplicate connections.
                // Do not spend retry budgets on peers already occupying a slot.
                for (&self.core.peers, 0..) |*peer, p| {
                    if (peer.used and !peer.connected and peer.attempts == 5 and now >= peer.next_attempt) peer.exhausted = true;
                    if (!peer.used or peer.expires <= now or peer.exhausted or peer.connected or self.linkFor(peer.key) != null or now < peer.next_attempt or std.mem.order(u8, &self.core.own, &peer.key) != .lt) continue;
                    if (peer.attempts == 5) {
                        peer.exhausted = true;
                        continue;
                    }
                    peer.attempts += 1;
                    peer.next_attempt = now + 6000;
                    self.open(free, p, false, address(peer.endpoint), now) catch {
                        self.dropped += 1;
                    };
                    break;
                }
            };
            for (&self.links, 0..) |*link, i| {
                if (!link.used) continue;
                const member = self.core.find(link.peer) orelse {
                    self.close(i, now);
                    continue;
                };
                if (self.core.peers[member].epoch != link.epoch) {
                    self.close(i, now);
                    continue;
                }
                if (!link.server and !link.mesh.ready() and now >= link.next_dial) {
                    const size = try overlay.encode(self.cfg.identity, self.cfg.realm, .dial, self.cfg.epoch, try self.next(), try expires(now), &overlay.cardBody(self.cfg.endpoint), &self.wire);
                    self.sendRaw(&self.storage.connections[i].socket, self.wire[0..size], link.source);
                    link.next_dial = now + 250;
                }
                const state = link.mesh.tick();
                const count = self.storage.connections[i].telem.packets_received;
                const telemetry = &self.storage.connections[i].telem;
                self.bytes_sent += telemetry.bytes_sent - link.sent_bytes;
                if (!link.server) self.bytes_received += telemetry.bytes_received - link.received_bytes;
                link.sent_bytes = telemetry.bytes_sent;
                link.received_bytes = telemetry.bytes_received;
                if (count != link.received) {
                    link.received = count;
                    link.activity = now;
                }
                if (state == .closed or now - link.activity > 6000 or (!link.mesh.ready() and now - link.started > 6000)) {
                    self.close(i, now);
                    self.reconnects += 1;
                    continue;
                }
                if (!link.mesh.ready()) continue;
                try self.core.setConnected(link.peer, true);
                while (link.mesh.pollGossip()) |message| {
                    self.core.receive(link.peer, message, now) catch |err| {
                        switch (err) {
                            error.Replay => {},
                            else => self.dropped += 1,
                        }
                        continue;
                    };
                    // Forward each newly accepted signed data frame promptly.
                    // The bounded rotating cache remains the loss-repair path.
                    if (message.len >= 8 and message[5] == 2) for (&self.links, 0..) |*other, j| {
                        if (j != i and other.used and other.mesh.ready()) other.mesh.broadcastGossip(message) catch {};
                    };
                    // A new incarnation's own signed card on this authenticated
                    // channel identifies this very session. Third-party cards
                    // still invalidate an old session on the next tick.
                    if (message.len == overlay.card_size and std.mem.eql(u8, message[40..72], &link.peer)) {
                        const peer = &self.core.peers[member];
                        if (std.mem.eql(u8, message, peer.card[0..peer.card_len])) link.epoch = peer.epoch;
                    }
                }
                if (now < link.next_sync) continue;
                // One own card heartbeat and one rotating membership/cache item.
                link.mesh.broadcastGossip(self.card[0..self.card_len]) catch {};
                for (0..member_capacity) |_| {
                    const p = link.card_cursor;
                    link.card_cursor = (p + 1) % member_capacity;
                    const card = self.core.peers[p];
                    if (card.used and card.expires > now) {
                        link.mesh.broadcastGossip(card.card[0..card.card_len]) catch {};
                        break;
                    }
                }
                for (0..history) |_| {
                    const h = link.data_cursor;
                    link.data_cursor = (h + 1) % history;
                    const frame = &self.core.cache[h];
                    if (frame.len != 0 and frame.expires > now) {
                        link.mesh.broadcastGossip(frame.bytes[0..frame.len]) catch {};
                        break;
                    }
                }
                link.next_sync = now + 100;
            }
        }
        pub fn connectedCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.links) |link| {
                if (link.used and link.mesh.ready()) n += 1;
            }
            return n;
        }
    };
}
pub fn address(endpoint: overlay.Endpoint) w.sockaddr_in {
    return .{ .sin_addr = overlay.get(u32, &endpoint.address), .sin_port = w.htons(endpoint.port) };
}
fn sameAddress(a: w.sockaddr_in, b: w.sockaddr_in) bool {
    return a.sin_addr == b.sin_addr and a.sin_port == b.sin_port;
}
