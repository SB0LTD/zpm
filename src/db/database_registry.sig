//! Checked caller-owned database identities and connection leases.
//!
//! Serialize every operation with the owner's registry lock. A Store and
//! its backing must remain stable until finishDrop returns it. Startup
//! authentication and physical WAL creation belong to the caller.
const std = @import("std");

pub const Error = error{
    InvalidDatabaseName,
    InvalidDatabaseIdentity,
    DuplicateDatabase,
    DatabaseNotFound,
    DatabaseBusy,
    DatabaseCapacity,
    AdmissionDenied,
    LeaseCapacity,
    StaleDatabase,
    StaleLease,
    StoreAlreadyRegistered,
    StoreNotStaged,
};

pub fn Registry(comptime Store: type, comptime name_capacity: usize) type {
    return struct {
        const Self = @This();
        const State = enum { empty, reserved, ready, draining };

        pub const Id = struct { index: usize, generation: u64 };
        pub const Lease = struct { index: usize, generation: u64 };

        pub const Entry = struct {
            state: State = .empty,
            generation: u64 = 0,
            oid: u32 = 0,
            owner: u32 = 0,
            name: [name_capacity]u8 = undefined,
            name_len: usize = 0,
            store: ?*Store = null,
            clients: usize = 0,
        };

        pub const LeaseEntry = struct {
            generation: u64 = 0,
            database: ?Id = null,
        };

        pub const Metadata = struct {
            id: Id,
            oid: u32,
            owner: u32,
            name: []const u8,
        };

        pub const Admission = struct {
            /// The caller verifies the identity before invoking attach.
            principal: u32,
            context: ?*anyopaque = null,
            /// Runs synchronously under the registry lock and cannot reenter it.
            allowed: *const fn (?*anyopaque, u32, Metadata) bool,
        };

        pub const Binding = struct {
            database: Id,
            lease: Lease,
            store: *Store,
        };

        entries: []Entry,
        leases: []LeaseEntry,
        oid_high_water: u32 = 0,

        /// Initialize fresh ownership with no extant IDs or leases. Restore
        /// published identities in monotonically increasing OID order.
        pub fn init(entries: []Entry, leases: []LeaseEntry) Self {
            @memset(entries, .{});
            @memset(leases, .{});
            return .{ .entries = entries, .leases = leases };
        }

        /// Preserve a recovered allocator high-water mark after loading the
        /// live entries of a durable registry snapshot.
        pub fn raiseOidHighWater(self: *Self, oid: u32) void {
            self.oid_high_water = @max(self.oid_high_water, oid);
        }

        fn find(self: *const Self, name: []const u8) ?usize {
            for (self.entries, 0..) |*entry, index| {
                if (entry.state != .empty and std.mem.eql(u8, entry.name[0..entry.name_len], name)) return index;
            }
            return null;
        }

        fn get(self: *Self, id: Id, state: State) Error!*Entry {
            if (id.index >= self.entries.len) return error.StaleDatabase;
            const entry = &self.entries[id.index];
            if (entry.generation != id.generation or entry.state != state) return error.StaleDatabase;
            return entry;
        }

        /// Reserve the exact durable identity before provisioning its Store.
        /// Abort consumes the identity, but frees the slot and the name.
        pub fn reserve(self: *Self, name: []const u8, oid: u32, owner: u32) Error!Id {
            if (name.len == 0 or name.len > name_capacity or
                std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidDatabaseName;
            if (self.find(name) != null) return error.DuplicateDatabase;
            if (oid <= self.oid_high_water or owner == 0) return error.InvalidDatabaseIdentity;
            for (self.entries, 0..) |*entry, index| {
                if (entry.state != .empty or entry.generation == ~@as(u64, 0)) continue;
                entry.generation += 1;
                entry.state = .reserved;
                entry.oid = oid;
                entry.owner = owner;
                entry.name_len = name.len;
                @memcpy(entry.name[0..name.len], name);
                self.oid_high_water = oid;
                return .{ .index = index, .generation = entry.generation };
            }
            return error.DatabaseCapacity;
        }

        /// Validate and retain the fully initialized Store before the owner
        /// commits durable publication. A staged entry cannot serve clients.
        pub fn stageStore(self: *Self, id: Id, store: *Store) Error!void {
            const entry = try self.get(id, .reserved);
            if (entry.store != null) return error.StoreAlreadyRegistered;
            for (self.entries) |*other| {
                if (other.store == store) return error.StoreAlreadyRegistered;
            }
            entry.store = store;
        }

        /// Expose a previously staged Store after committing publication.
        pub fn publish(self: *Self, id: Id) Error!void {
            const entry = try self.get(id, .reserved);
            if (entry.store == null) return error.StoreNotStaged;
            entry.state = .ready;
        }

        pub fn abortReservation(self: *Self, id: Id) Error!?*Store {
            const entry = try self.get(id, .reserved);
            const store = entry.store;
            clear(entry);
            return store;
        }

        fn clear(entry: *Entry) void {
            const generation = entry.generation;
            entry.* = .{ .generation = generation };
        }

        /// The name borrows its entry. Copy it before releasing the owner's
        /// lock if the metadata must survive a lifecycle change.
        pub fn metadataAt(self: *const Self, index: usize) ?Metadata {
            if (index >= self.entries.len) return null;
            const entry = &self.entries[index];
            if (entry.state != .ready) return null;
            return .{
                .id = .{ .index = index, .generation = entry.generation },
                .oid = entry.oid,
                .owner = entry.owner,
                .name = entry.name[0..entry.name_len],
            };
        }

        pub fn lookup(self: *const Self, name: []const u8) ?Metadata {
            return self.metadataAt(self.find(name) orelse return null);
        }

        /// Authorize before creating a lease. A rejected route never gives
        /// its caller a Store pointer or contributes to a database's clients.
        pub fn attach(self: *Self, name: []const u8, admission: Admission) Error!Binding {
            if (admission.principal == 0) return error.AdmissionDenied;
            const metadata = self.lookup(name) orelse return error.DatabaseNotFound;
            if (!admission.allowed(admission.context, admission.principal, metadata)) return error.AdmissionDenied;
            const entry = &self.entries[metadata.id.index];
            for (self.leases, 0..) |*lease, index| {
                if (lease.database != null or lease.generation == ~@as(u64, 0)) continue;
                lease.generation += 1;
                lease.database = metadata.id;
                entry.clients += 1;
                return .{
                    .database = metadata.id,
                    .lease = .{ .index = index, .generation = lease.generation },
                    .store = entry.store.?,
                };
            }
            return error.LeaseCapacity;
        }

        /// Disconnect the connection from its Store before releasing.
        pub fn release(self: *Self, token: Lease) Error!void {
            if (token.index >= self.leases.len) return error.StaleLease;
            const lease = &self.leases[token.index];
            if (lease.generation != token.generation) return error.StaleLease;
            const id = lease.database orelse return error.StaleLease;
            const entry = try self.get(id, .ready);
            entry.clients -= 1;
            lease.database = null;
        }

        /// Fence routing only when all clients have detached. The owner must
        /// also check prepared transactions and other non-client Store users.
        pub fn beginDrop(self: *Self, id: Id) Error!void {
            const entry = try self.get(id, .ready);
            if (entry.clients != 0) return error.DatabaseBusy;
            entry.state = .draining;
        }

        /// A failed durable drop can safely make this same identity live.
        pub fn cancelDrop(self: *Self, id: Id) Error!void {
            const entry = try self.get(id, .draining);
            entry.state = .ready;
        }

        /// After durable tombstone publication, return sole ownership of the
        /// old Store and free its slot without allowing stale handles reuse.
        pub fn finishDrop(self: *Self, id: Id) Error!*Store {
            const entry = try self.get(id, .draining);
            const store = entry.store.?;
            clear(entry);
            return store;
        }
    };
}
