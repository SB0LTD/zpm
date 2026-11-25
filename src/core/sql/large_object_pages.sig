//! Caller-backed PostgreSQL large-object pages. The ordinary row directory
//! and MVCC version arena index each page by (object OID, page number).
//! The object catalog owns existence, permissions, length, and transaction
//! publication. It supplies each statement's snapshot and reclamation horizon.
//! The caller provides the same read/write exclusion as for ordinary tables.
const row_store = @import("storage.sig");
const types = @import("types.sig");
const Error = types.Error;

pub const page_bytes = 2048;
pub const end_page: u32 = 0x7fff_ffff;
pub const max_size: u64 = @as(u64, end_page) * page_bytes;

const profile: types.Config = .{
    .columns = 1,
    .rows_per_table = 1,
    .text_bytes = page_bytes,
    .external_storage = true,
    .split_external_versions = true,
    .table_constraints = 1,
    .table_indexes = 0,
};
const S = row_store.Storage(profile);

pub const Key = struct {
    oid: u32,
    page: u32,

    pub fn rowId(self: Key) u64 {
        return (@as(u64, self.oid) << 32) | self.page;
    }
};

pub const Mutation = struct {
    snapshot: row_store.Snapshot,
    owner: row_store.TxRef,
    horizon: u64,
    /// The write command may precede the visibility command by one so repeated
    /// volatile calls within a SQL statement can see their own page changes.
    command: ?u32 = null,

    fn validate(self: Mutation) Error!void {
        if (!self.snapshot.own(self.owner) or self.horizon > self.snapshot.csn or
            (self.command orelse self.snapshot.cid) > self.snapshot.cid)
            return error.InvalidParameterValue;
    }
};

/// Contiguous caller-owned storage. The version arena admits twice as many
/// versions as committed pages. Regions are charged by the hosting process.
pub const Layout = struct {
    pub const alignment = @max(@alignOf(Pages.RowSlot), @alignOf(Pages.Version), @alignOf(Pages.PageRow), @alignOf(u32));
    rows: usize,
    versions: usize,
    row_index: usize,
    key_index: usize,
    offsets: [5]usize,
    bytes: usize,

    pub fn plan(rows: usize) Error!Layout {
        const std = @import("std");
        if (rows == 0 or rows > 0x3fff_ffff) return error.InvalidParameterValue;
        const versions = 2 * rows;
        const row_index = std.math.ceilPowerOfTwo(usize, 2 * rows) catch return error.InvalidParameterValue;
        const key_index = std.math.ceilPowerOfTwo(usize, 2 * versions) catch return error.InvalidParameterValue;
        const counts = [_]usize{ rows, versions, versions, row_index, key_index };
        const classes = .{ Pages.RowSlot, Pages.Version, Pages.PageRow, u32, u32 };
        var offsets: [classes.len]usize = undefined;
        var bytes: usize = 0;
        inline for (classes, 0..) |T, i| {
            const padding = (0 -% bytes) & (@alignOf(T) - 1);
            offsets[i] = std.math.add(usize, bytes, padding) catch return error.InvalidParameterValue;
            const part = std.math.mul(usize, counts[i], @sizeOf(T)) catch return error.InvalidParameterValue;
            bytes = std.math.add(usize, offsets[i], part) catch return error.InvalidParameterValue;
        }
        return .{ .rows = rows, .versions = versions, .row_index = row_index, .key_index = key_index, .offsets = offsets, .bytes = bytes };
    }

    pub fn backing(self: Layout, bytes: []u8) Error!Pages.Backing {
        if (bytes.len < self.bytes) return error.WorkspaceCapacity;
        if (@intFromPtr(bytes.ptr) % alignment != 0) return error.InvalidParameterValue;
        return .{
            .rows = span(Pages.RowSlot, bytes, self.offsets[0], self.rows),
            .versions = span(Pages.Version, bytes, self.offsets[1], self.versions),
            .version_rows = span(Pages.PageRow, bytes, self.offsets[2], self.versions),
            .row_index = span(u32, bytes, self.offsets[3], self.row_index),
            .key_index = span(u32, bytes, self.offsets[4], self.key_index),
        };
    }

    fn span(comptime T: type, bytes: []u8, offset: usize, count: usize) []T {
        return @as([*]T, @ptrCast(@alignCast(bytes[offset..].ptr)))[0..count];
    }
};

pub const Pages = struct {
    const Self = @This();

    pub const Backing = S.Backing;
    pub const RowSlot = S.RowSlot;
    pub const Version = S.Version;
    pub const PageRow = S.VersionRow;
    pub const Change = struct {
        key: Key,
        previous: ?u32,
        replacement: ?u32,
    };

    pub const no_version: u32 = 0xffffffff;
    table: S.Table = .{},
    committed_count: usize = 0,

    /// The caller owns the disjoint slices exclusively for the store's lifetime.
    pub fn init(memory: Backing) Error!Self {
        if (!memory.valid()) return error.InvalidParameterValue;
        var pages: Self = .{};
        S.bindBacking(&pages.table, memory);
        S.reset(&pages.table, 2613, .{}, &.{.{ .data_type = .bytea }});
        return pages;
    }

    pub fn versionBytes(self: *const Self, version: u32) []const u8 {
        var scratch: S.VersionRowScratch = undefined;
        return S.borrowVersionRow(&self.table, version, &scratch)[0].bytea.slice();
    }

    /// An existing page's valid prefix. Borrow until the next mutation or
    /// reclaim on this store. Missing pages and zero-length pages differ.
    pub fn page(self: *const Self, key: Key, snapshot: row_store.Snapshot) ?[]const u8 {
        const slot = S.findRow(&self.table, key.rowId()) orelse return null;
        return self.versionBytes(S.visibleAt(&self.table, slot, snapshot) orelse return null);
    }

    /// Copy up to output.len bytes before the caller's snapshot-visible EOF.
    /// Absent pages and unwritten page tails below EOF read as zero.
    pub fn read(self: *const Self, oid: u32, length: u64, offset: u64, output: []u8, snapshot: row_store.Snapshot) Error!usize {
        if (oid == 0 or length > max_size or offset > max_size) return error.InvalidParameterValue;
        if (offset >= length) return 0;
        const count: usize = @intCast(@min(length - offset, output.len));
        var done: usize = 0;
        while (done < count) {
            const position = offset + done;
            const within: usize = @intCast(position % page_bytes);
            const target = output[done..][0..@min(page_bytes - within, count - done)];
            const bytes = self.page(.{ .oid = oid, .page = @intCast(position / page_bytes) }, snapshot) orelse &.{};
            const copied = if (within < bytes.len) @min(target.len, bytes.len - within) else 0;
            if (copied != 0) @memcpy(target[0..copied], bytes[within..][0..copied]);
            @memset(target[copied..], 0);
            done += target.len;
        }
        return count;
    }

    fn writableVersion(self: *const Self, key: Key, mutation: Mutation) Error!?u32 {
        const slot = S.findRow(&self.table, key.rowId()) orelse return null;
        // A row linked in the directory has at least one live arena version.
        const latest = &self.table.versions[self.table.rows[slot].newest - 1];
        if (latest.creationAfter(mutation.snapshot) or latest.deletionCsn() > mutation.snapshot.csn)
            return error.SerializationFailure;
        if (latest.pendingCreation()) |change| {
            if (!mutation.snapshot.own(change.tx) or change.cid >= mutation.snapshot.cid)
                return error.SerializationFailure;
        }
        if (latest.pendingDeletion()) |change| {
            if (!mutation.snapshot.own(change.tx) or change.cid >= mutation.snapshot.cid)
                return error.SerializationFailure;
        }
        return S.visibleAt(&self.table, slot, mutation.snapshot);
    }

    fn replace(self: *Self, key: Key, old: ?u32, payload: *const PageRow, mutation: Mutation) Error!Change {
        try S.ensureVersions(&self.table, 1, mutation.horizon);
        const row = S.findRow(&self.table, key.rowId()) orelse blk: {
            try S.ensureRowSlot(&self.table, mutation.horizon);
            break :blk S.allocRow(&self.table, key.rowId());
        };
        const replacement = S.createVersion(&self.table, .{
            .row = row,
            .xmin = mutation.owner,
            .cid = mutation.command orelse mutation.snapshot.cid,
            .older = self.table.rows[row].newest,
        }, payload);
        if (old) |version| self.table.versions[version].markDeletion(mutation.owner, mutation.command orelse mutation.snapshot.cid);
        return .{ .key = key, .previous = old, .replacement = replacement };
    }

    /// Stage a complete page image, or remove the page with null. The final
    /// page number can hold the zero-length EOF marker used by truncation.
    pub fn stagePage(self: *Self, key: Key, bytes: ?[]const u8, mutation: Mutation) Error!?Change {
        try mutation.validate();
        if (key.oid == 0 or key.page > end_page) return error.InvalidParameterValue;
        const old = try self.writableVersion(key, mutation);
        if (bytes) |image| {
            if (image.len > page_bytes or (key.page == end_page and image.len != 0)) return error.InvalidParameterValue;
            var payload: PageRow = .{.{ .bytea = .{ .len = image.len } }};
            @memcpy(payload[0].bytea.bytes[0..image.len], image);
            return try self.replace(key, old, &payload, mutation);
        }
        const version = old orelse return null;
        self.table.versions[version].markDeletion(mutation.owner, mutation.command orelse mutation.snapshot.cid);
        return .{ .key = key, .previous = old, .replacement = null };
    }

    /// Stage a write across page boundaries. Only touched pages claim backing.
    /// On failure the entire span is rolled back, including prior touched
    /// pages. Use the returned changes for outer rollback or publication.
    pub fn stageWrite(self: *Self, oid: u32, offset: u64, input: []const u8, mutation: Mutation, changes: []Change) Error!usize {
        try mutation.validate();
        if (oid == 0 or offset > max_size or input.len > max_size - offset) return error.InvalidParameterValue;
        if (input.len == 0) return 0;
        const touched = (offset + input.len - 1) / page_bytes - offset / page_bytes + 1;
        if (touched > changes.len) return error.WriteSetCapacity;
        var used: usize = 0;
        errdefer self.rollback(changes[0..used]);
        var done: usize = 0;
        while (done < input.len) {
            const position = offset + done;
            const within: usize = @intCast(position % page_bytes);
            const count = @min(page_bytes - within, input.len - done);
            const key: Key = .{ .oid = oid, .page = @intCast(position / page_bytes) };
            const old = try self.writableVersion(key, mutation);
            const bytes = input[done..][0..count];
            var payload: PageRow = .{.{ .bytea = .{} }};
            const image = &payload[0].bytea;
            if (count != page_bytes) {
                const previous = if (old) |version| self.versionBytes(version) else &.{};
                @memcpy(image.bytes[0..previous.len], previous);
                image.len = previous.len;
            }
            @memcpy(image.bytes[within..][0..count], bytes);
            image.len = @max(image.len, within + count);
            changes[used] = try self.replace(key, old, &payload, mutation);
            used += 1;
            done += count;
        }
        return used;
    }

    /// Undo a suffix of the caller's pending changes in reverse write order.
    pub fn rollback(self: *Self, changes: []const Change) void {
        var remaining = changes.len;
        while (remaining != 0) {
            remaining -= 1;
            const change = changes[remaining];
            if (change.replacement) |version| S.reclaimVersion(&self.table, version);
            if (change.previous) |version| self.table.versions[version].clearDeletion();
        }
    }

    /// Stamp the staged versions at the caller's durable commit boundary.
    /// Call after flushing the WAL and before exposing the commit sequence.
    pub fn publish(self: *Self, changes: []const Change, csn: u64) void {
        for (changes) |change| {
            self.committed_count += @intFromBool(change.previous == null);
            self.committed_count -= @intFromBool(change.replacement == null);
            if (change.previous) |version| self.table.versions[version].publishDeletion(csn);
            if (change.replacement) |version| self.table.versions[version].publishCreation(csn);
        }
    }

    pub fn changeFromVersions(self: *const Self, previous: u32, replacement: u32) Change {
        const present = if (replacement != no_version) replacement else previous;
        const encoded = self.table.rows[self.table.versions[present].rowSlot()].rowid;
        return .{
            .key = .{ .oid = @truncate(encoded >> 32), .page = @truncate(encoded) },
            .previous = if (previous == no_version) null else previous,
            .replacement = if (replacement == no_version) null else replacement,
        };
    }

    pub const Cursor = struct {
        next_slot: usize = 0,

        pub fn next(cursor: *Cursor, self: *const Self, snapshot: row_store.Snapshot) ?struct { key: Key, version: u32 } {
            while (cursor.next_slot < self.table.row_high) {
                const index = cursor.next_slot;
                cursor.next_slot += 1;
                if (self.table.rows[index].newest == 0) continue;
                const version = S.visibleAt(&self.table, index, snapshot) orelse continue;
                const encoded = self.table.rows[index].rowid;
                return .{ .key = .{ .oid = @truncate(encoded >> 32), .page = @truncate(encoded) }, .version = version };
            }
            return null;
        }
    };

    pub fn reclaimPrevious(self: *Self, previous: u32, horizon: u64) void {
        if (previous == no_version) return;
        const version = &self.table.versions[previous];
        const dead = version.deletionCsn();
        if (version.rowLink() != 0 and dead != 0 and dead <= horizon) S.reclaimVersion(&self.table, previous);
    }

    pub fn backing(self: *const Self) Backing {
        return S.backingOf(&self.table);
    }

    pub fn capacity(self: *const Self) usize {
        return self.table.rows.len;
    }

    /// The replay caller owns a quiescent store and has validated the entire
    /// WAL frame, including its peak live page count. Updates may overwrite
    /// the committed image because no older snapshots are active.
    pub fn replay(self: *Self, key: Key, bytes: ?[]const u8, csn: u64) void {
        const existing = S.findRow(&self.table, key.rowId());
        if (bytes) |payload| {
            if (existing) |row| {
                const version = self.table.rows[row].newest - 1;
                const image = &self.table.version_rows[version][0].bytea;
                image.len = payload.len;
                @memcpy(image.bytes[0..payload.len], payload);
            } else {
                S.ensureRowSlot(&self.table, csn) catch unreachable;
                S.ensureVersions(&self.table, 1, csn) catch unreachable;
                const row = S.allocRow(&self.table, key.rowId());
                var data: PageRow = .{.{ .bytea = .{ .len = payload.len } }};
                @memcpy(data[0].bytea.bytes[0..payload.len], payload);
                _ = S.createVersion(&self.table, .{ .row = row, .xmin = .{ .epoch = 1 }, .cid = 0, .csn = csn }, &data);
                self.committed_count += 1;
            }
        } else {
            const row = existing orelse unreachable;
            S.reclaimVersion(&self.table, self.table.rows[row].newest - 1);
            self.committed_count -= 1;
        }
    }

    pub fn replayStart(self: *Self, at: u64) void {
        if (self.table.version_used != self.committed_count) _ = self.reclaim(at);
    }

    pub fn copyCommitted(self: *Self, source: *const Self, csn: u64) void {
        self.clear();
        var cursor: Cursor = .{};
        while (cursor.next(source, .{ .csn = csn })) |item| self.replay(item.key, source.versionBytes(item.version), csn);
    }

    pub fn clear(self: *Self) void {
        S.reset(&self.table, 2613, .{}, &.{.{ .data_type = .bytea }});
        self.committed_count = 0;
    }

    pub fn reclaim(self: *Self, horizon: u64) usize {
        return S.vacuum(&self.table, horizon);
    }
};
