//! Cursor request/reply protocol over an authenticated opaque message channel.
//! Historical signatures survive transport TTL. Replies are bounded and bound
//! to recipient, requested writer, process incarnation and request nonce.
const std = @import("std");
const history = @import("mesh_history");
pub const request_size = 128;
pub const prefix_size = 88;
pub const capacity = prefix_size + history.frame_capacity; // 496; fits mesh-overlay payload
pub const Stats = struct { requests: u64 = 0, replies: u64 = 0, events: u64 = 0, snapshots: u64 = 0, duplicates: u64 = 0, gaps: u64 = 0, unavailable: u64 = 0, rejected: u64 = 0, conflicts: u64 = 0 };
pub fn Session(comptime Durable: type) type {
    return struct {
        const Self = @This();
        const Pending = struct { active: bool = false, nonce: u64 = 0, cursor: u64 = 0, head: history.Key = @splat(0), deadline: u64 = 0, force: bool = false };
        epoch: u64,
        nonce: u64 = 0,
        round_robin: usize = 0,
        pending: [Durable.Core.writer_count]Pending = @splat(.{}),
        stats: Stats = .{},
        last_now: u64 = 0,
        pub fn init(epoch: u64) !Self {
            if (epoch == 0) return error.BadIncarnation;
            return .{ .epoch = epoch };
        }
        pub fn request(self: *Self, store: *const Durable, now: u64, out: []u8) !usize {
            if (store.poisoned) return error.Poisoned;
            if (out.len < request_size) return error.Capacity;
            if (now < self.last_now) return error.ClockRollback;
            self.last_now = now;
            const index = self.round_robin;
            self.round_robin = (index + 1) % Durable.Core.writer_count;
            const stream = &store.live.streams[index];
            var pending = &self.pending[index];
            if (!pending.active or pending.cursor != stream.cursor or !std.mem.eql(u8, &pending.head, &stream.head) or now >= pending.deadline) {
                if (self.nonce == std.math.maxInt(u64) or now > std.math.maxInt(u64) - 30_000) return error.Exhausted;
                self.nonce += 1;
                pending.* = .{ .active = true, .nonce = self.nonce, .cursor = stream.cursor, .head = stream.head, .deadline = now + 30_000, .force = pending.force };
            }
            @memset(out[0..request_size], 0);
            @memcpy(out[0..5], "ZMS1\x01");
            out[5] = if (pending.force) 3 else 1;
            @memcpy(out[40..72], &stream.origin);
            history.put(u64, out[72..80], self.epoch);
            history.put(u64, out[80..88], pending.nonce);
            history.put(u64, out[88..96], stream.cursor);
            @memcpy(out[96..128], &stream.head);
            self.stats.requests += 1;
            return request_size;
        }
        /// `sender` is the authenticated outer-envelope origin. Applications
        /// must not call this directly on unsigned UDP payloads.
        pub fn receive(self: *Self, store: *Durable, sender: history.Key, bytes: []const u8, out: []u8) !?usize {
            if (store.poisoned) return error.Poisoned;
            if (bytes.len < prefix_size or bytes.len > capacity or !std.mem.eql(u8, bytes[0..5], "ZMS1\x01") or bytes[6] != 0 or bytes[7] != 0) return error.InvalidMessage;
            const writer: history.Key = bytes[40..72].*;
            const epoch = history.get(u64, bytes[72..80]);
            const nonce = history.get(u64, bytes[80..88]);
            if (epoch == 0 or nonce == 0) return error.InvalidMessage;
            const index = try store.live.find(writer);
            if (bytes[5] == 1 or bytes[5] == 3) {
                if (bytes.len != request_size or !std.mem.eql(u8, bytes[8..40], &@as(history.Key, @splat(0)))) return error.InvalidMessage;
                const frame = store.live.after(writer, history.get(u64, bytes[88..96]), bytes[96..128].*, bytes[5] == 3) catch |err| switch (err) {
                    error.SnapshotRequired => {
                        self.stats.gaps += 1;
                        if (out.len < request_size) return error.Capacity;
                        @memcpy(out[0..prefix_size], bytes[0..prefix_size]);
                        out[5] = 4;
                        @memcpy(out[8..40], &sender);
                        const stream = &store.live.streams[index];
                        history.put(u64, out[88..96], stream.cursor);
                        @memcpy(out[96..128], &stream.head);
                        return request_size;
                    },
                    error.Conflict => {
                        self.stats.conflicts += 1;
                        return err;
                    },
                    else => return err,
                } orelse return null;
                if (out.len < prefix_size + frame.len) return error.Capacity;
                @memcpy(out[0..prefix_size], bytes[0..prefix_size]);
                out[5] = 2;
                @memcpy(out[8..40], &sender);
                @memcpy(out[prefix_size..][0..frame.len], frame);
                self.stats.replies += 1;
                return prefix_size + frame.len;
            }
            if ((bytes[5] != 2 and bytes[5] != 4) or !std.mem.eql(u8, bytes[8..40], &store.live.owner)) return error.UnsolicitedReply;
            const pending = &self.pending[index];
            if (!pending.active or epoch != self.epoch or nonce != pending.nonce) return error.UnsolicitedReply;
            if (bytes[5] == 4) {
                if (bytes.len != request_size) return error.InvalidMessage;
                // A peer's unavailable hint cannot cancel an outstanding valid
                // reply from another peer, and never changes durable state.
                pending.force = true;
                self.stats.unavailable += 1;
                return null;
            }
            const frame = bytes[prefix_size..];
            const view = try history.decode(frame, store.live.realm);
            if (!std.mem.eql(u8, &view.origin, &writer)) return error.UntrustedWriter;
            if (view.sequence <= pending.cursor) return error.UnsolicitedReply;
            const result = store.accept(frame) catch |err| switch (err) {
                error.HistoryGap, error.SnapshotRequired => {
                    pending.force = true;
                    self.stats.gaps += 1;
                    return null;
                },
                error.Conflict => {
                    self.stats.conflicts += 1;
                    return err;
                },
                else => {
                    self.stats.rejected += 1;
                    return err;
                },
            };
            pending.active = false;
            pending.force = false;
            if (result == .changed) {
                if (view.kind == .event) self.stats.events += 1 else self.stats.snapshots += 1;
            } else self.stats.duplicates += 1;
            return null;
        }
    };
}
