//! Native checkpoint composition contract, including atomic generation
//! selection under a database-wide lock.
const std = @import("std");
const builtin = @import("builtin");
const disk = @import("db_file");
const log = @import("durable_log");
const snapshot = @import("snapshot_envelope");
const manifest = @import("checkpoint_manifest");
const sql = @import("sql");
const Raw = sql.Database(.{
    .external_storage = true,
    .split_external_versions = true,
    .integral_external_versions = true,
    .tables = 2,
    .columns = 3,
    .rows_per_table = 8,
    .work_rows = 64,
    .result_rows = 16,
    .tx_writes = 32,
    .text_bytes = 64,
    .integer_bits = 32,
});
const Store = @import("db_store").Store(Raw);
const EnvelopeWriter = snapshot.Writer(disk.File);
const budgets: [2]Raw.TableBudget = .{
    .{ .rows = 8, .versions = 16, .integral_row_words = 2 },
    .{ .rows = 8, .versions = 16 },
};
const Win = struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
};
const identity_kind = 8;
const change_kind = 3;
const marker_kind = 24;
const identity_len = 36;
const marker_len = identity_len + 8 * 4 + 32;
const Identity = manifest.DatabaseIdentity;
const fixture_identity: Identity = .{
    .database = "fixture-database".*,
    .namespace = "fixture-nspace-1".*,
    .oid = 16397,
};
var live: Store = .{};
var staged: Store = .{};
var result: Raw.Result = .{};
var backing: [2][131072]u8 align(64) = undefined;
var replay: Raw.ReplayScratch = .{};
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("native checkpoint assertion {d}\n", .{assertions});
        return error.NativeCheckpointContractFailed;
    }
}

fn bind(store: *Store, index: usize, identity: Identity) !void {
    store.* = .{};
    store.database_oid = identity.oid;
    const refs = 4096;
    const needed = try Raw.backingBytesFor(budgets, refs);
    try store.database.bindMemoryFor(backing[index][0..needed], budgets, refs);
}

const Journal = struct {
    file: disk.File,
    sequence: u64 = 0,

    fn append(self: *Journal, kind: u16, bytes: []const u8) !void {
        try log.appendKind(&self.file, self.sequence + 1, bytes, kind);
        self.sequence += 1;
    }

    fn persist(context: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Journal = @ptrCast(@alignCast(context.?));
        if (try Raw.changeRecordOps(bytes) == 0) return error.EmptyCommitRecord;
        try self.append(change_kind, bytes);
    }
};

const ImageSink = struct {
    writer: *EnvelopeWriter,

    pub fn appendAll(self: ImageSink, bytes: []const u8) !void {
        try self.writer.append(bytes);
    }
};

// The envelope is checked first, using the same exclusive native file handle
// kept stable while the positioned SQL decoder reads the verified payload.
const ImageSource = struct {
    file: *disk.File,
    payload_len: u64,

    pub fn length(self: ImageSource) !u64 {
        return self.payload_len;
    }

    pub fn readAt(self: ImageSource, offset: u64, bytes: []u8) !usize {
        if (offset >= self.payload_len) return 0;
        const count = @min(bytes.len, self.payload_len - offset);
        return self.file.readAt(snapshot.header_size + offset, bytes[0..count]);
    }
};

fn encodeMarker(identity: Identity, seal: snapshot.Seal) [marker_len]u8 {
    var bytes: [marker_len]u8 = undefined;
    bytes[0..identity_len].* = identityPayload(identity);
    std.mem.writeInt(u64, bytes[36..44], seal.identity.generation, .little);
    std.mem.writeInt(u64, bytes[44..52], seal.identity.wal_sequence, .little);
    std.mem.writeInt(u64, bytes[52..60], seal.identity.sql_csn, .little);
    std.mem.writeInt(u64, bytes[60..68], seal.payload_bytes, .little);
    bytes[68..100].* = seal.digest;
    return bytes;
}

fn identityPayload(identity: Identity) [identity_len]u8 {
    var bytes: [identity_len]u8 = undefined;
    bytes[0..16].* = identity.database;
    bytes[16..32].* = identity.namespace;
    std.mem.writeInt(u32, bytes[32..36], identity.oid, .little);
    return bytes;
}

const Recovery = struct {
    identity: Identity,
    seal: snapshot.Seal,
    published: bool = false,

    fn verifyMarker(self: *Recovery, frame: log.Frame, bytes: []const u8) !void {
        if (frame.kind != marker_kind or frame.sequence - 1 != self.seal.identity.wal_sequence or
            !std.mem.eql(u8, bytes, &encodeMarker(self.identity, self.seal))) return error.CheckpointMarkerMismatch;
    }

    fn apply(_: *Recovery, _: log.Frame, bytes: []const u8) !void {
        try staged.database.applyChangeRecord(bytes, &replay);
    }

    fn restore(self: *Recovery, wal: *disk.File, image: *disk.File, marker: log.Frame) !log.Recovery {
        var scratch: [2048]u8 = undefined;
        const encoded = try log.readFrame(wal, &scratch, .{ .offset = 0, .sequence = 1, .kind = identity_kind, .payload_len = identity_len });
        if (!std.mem.eql(u8, encoded, &identityPayload(self.identity)) or
            !std.mem.eql(u8, &self.identity.database, &self.seal.identity.database_id)) return error.CheckpointDatabaseMismatch;
        try snapshot.verify(image, scratch[0..53], self.seal);
        const source: ImageSource = .{ .file = image, .payload_len = self.seal.payload_bytes };
        try Raw.BaseSnapshot.restore(&staged.database, source, self.seal.identity.sql_csn, scratch[0..96], &replay);
        const recovered = try log.recoverAfterFrame(wal, &scratch, marker, self, verifyMarker, apply, null, @as(u32, 1) << change_kind);
        self.published = true;
        return recovered;
    }
};

fn refuses(recovery: *Recovery, wal: *disk.File, image: *disk.File, marker: log.Frame, expected: anyerror) !void {
    try bind(&staged, 1, recovery.identity);
    const length = try wal.length();
    var tail: [16]u8 = undefined;
    const tail_at = length - tail.len;
    try check(try wal.readAt(tail_at, &tail) == tail.len);
    if (recovery.restore(wal, image, marker)) |_| return error.InvalidCheckpointAccepted else |err| try check(err == expected);
    try check(!recovery.published and try wal.length() == length);
    var after: [16]u8 = undefined;
    try check(try wal.readAt(tail_at, &after) == after.len and std.mem.eql(u8, &tail, &after));
}

fn copyImage(source: *disk.File, target: *disk.File, length: u64, damage_at: ?u64) !void {
    try target.truncate(0);
    var scratch: [73]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const count = @min(scratch.len, length - offset);
        if (try source.readAt(offset, scratch[0..count]) != count) return error.ShortFixtureRead;
        if (damage_at) |at| if (at >= offset and at < offset + count) {
            scratch[at - offset] ^= 1;
        };
        try target.appendAll(scratch[0..count]);
        offset += count;
    }
    try target.sync();
}

fn generationPath(out: []u8, pid: u32, generation: u64, extension: []const u8) ![]u8 {
    return std.fmt.bufPrint(out, "sig-out/native-checkpoint-{d}-{d}.{s}", .{ pid, generation, extension });
}

fn selectionFor(id: Identity, seal: snapshot.Seal, anchor: log.Frame) manifest.Selection {
    return .{
        .identity = id, .generation = seal.identity.generation, .base_sequence = seal.identity.wal_sequence,
        .sql_csn = seal.identity.sql_csn, .image_bytes = seal.payload_bytes, .image_digest = seal.digest,
        .anchor_offset = anchor.offset, .anchor_kind = anchor.kind, .anchor_length = anchor.payload_len,
    };
}

fn manifestContract(record: manifest.Selection) !void {
    const bytes = try record.encode();
    const decoded = try manifest.Selection.decode(&bytes);
    try check(std.meta.eql(record, decoded) and try decoded.anchorSequence() == record.base_sequence + 1);
    if (manifest.Selection.decode(bytes[0 .. bytes.len - 1])) |_| return error.ShortManifestAccepted else |err| try check(err == error.InvalidCheckpointManifest);
    var bad = bytes;
    bad[0] ^= 1;
    if (manifest.Selection.decode(&bad)) |_| return error.UnknownManifestAccepted else |err| try check(err == error.UnsupportedCheckpointManifest);
    bad = bytes;
    bad[112] ^= 1;
    if (manifest.Selection.decode(&bad)) |_| return error.ManifestChecksumIgnored else |err| try check(err == error.CheckpointManifestDigestMismatch);
    bad = bytes;
    bad[47] = 1;
    std.crypto.hash.Blake3.hash(bad[0..128], bad[128..], .{});
    if (manifest.Selection.decode(&bad)) |_| return error.ReservedManifestAccepted else |err| try check(err == error.InvalidCheckpointManifest);
    var invalid = record;
    invalid.base_sequence = std.math.maxInt(u64);
    if (invalid.encode()) |_| return error.ManifestCounterOverflowAccepted else |err| try check(err == error.InvalidCheckpointManifest);
    if (invalid.anchorSequence()) |_| return error.ManifestAnchorOverflowAccepted else |err| try check(err == error.InvalidCheckpointManifest);
}

const SelectionCut = enum { none, during_temp_write, after_temp_sync };

fn publishSelection(selected_path: []const u8, temp_path: []const u8, record: manifest.Selection, cut: SelectionCut) !void {
    var temp = try disk.File.createExclusive(temp_path);
    defer temp.close();
    if (cut == .during_temp_write) {
        const bytes = try record.encode();
        try temp.appendAll(bytes[0 .. bytes.len / 2]);
        return error.SelectionInterrupted;
    }
    try record.write(&temp);
    if (cut == .after_temp_sync) return error.SelectionInterrupted;
    temp.close();
    try disk.replaceAtomic(temp_path, selected_path);
}

const SelectedRecovery = struct { generation: u64, wal: log.Recovery };

fn recoverSelected(pid: u32, path: []const u8, id: Identity, published: *bool) !SelectedRecovery {
    var selected_file = try disk.File.openExisting(path);
    defer selected_file.close();
    const selected = try manifest.Selection.read(&selected_file, id);
    var image_name: [128]u8 = undefined;
    var wal_name: [128]u8 = undefined;
    var image = try disk.File.openExisting(try generationPath(&image_name, pid, selected.generation, "image"));
    defer image.close();
    var wal = try disk.File.openExisting(try generationPath(&wal_name, pid, selected.generation, "wal"));
    defer wal.close();
    try bind(&staged, 1, id);
    var recovery: Recovery = .{
        .identity = id,
        .seal = .{
            .identity = .{ .database_id = id.database, .generation = selected.generation, .wal_sequence = selected.base_sequence, .sql_csn = selected.sql_csn },
            .payload_bytes = selected.image_bytes, .digest = selected.image_digest,
        },
    };
    const anchor: log.Frame = .{
        .offset = selected.anchor_offset, .sequence = try selected.anchorSequence(),
        .kind = selected.anchor_kind, .payload_len = selected.anchor_length,
    };
    const recovered = try recovery.restore(&wal, &image, anchor);
    published.* = recovery.published;
    return .{ .generation = selected.generation, .wal = recovered };
}

fn exerciseSelection(pid: u32, writer: *Store.Connection, first: manifest.Selection, first_end: log.Recovery) !void {
    const id = first.identity;
    const generation = first.generation + 1;
    var manifest_name: [128]u8 = undefined;
    var temp_name: [128]u8 = undefined;
    var partial_name: [128]u8 = undefined;
    var delayed_name: [128]u8 = undefined;
    var image_name: [128]u8 = undefined;
    var wal_name: [128]u8 = undefined;
    var image_temp_name: [128]u8 = undefined;
    var wal_temp_name: [128]u8 = undefined;
    var hidden_name: [128]u8 = undefined;
    const selected_path = try generationPath(&manifest_name, pid, 0, "manifest");
    const temp_path = try generationPath(&temp_name, pid, 0, "manifest-new");
    const partial_path = try generationPath(&partial_name, pid, 0, "manifest-partial");
    const delayed_path = try generationPath(&delayed_name, pid, 0, "manifest-synced");
    const image_path = try generationPath(&image_name, pid, generation, "image");
    const wal_path = try generationPath(&wal_name, pid, generation, "wal");
    const image_temp = try generationPath(&image_temp_name, pid, generation, "image-pending");
    const wal_temp = try generationPath(&wal_temp_name, pid, generation, "wal-pending");
    const hidden_path = try generationPath(&hidden_name, pid, generation, "image-hidden");

    try manifestContract(first);
    try publishSelection(selected_path, temp_path, first, .none);
    defer disk.remove(selected_path) catch {};
    defer disk.remove(temp_path) catch {};
    var published = false;
    const initial = try recoverSelected(pid, selected_path, id, &published);
    try check(published and initial.generation == first.generation and initial.wal.sequence == first_end.sequence);

    var image = try disk.File.createExclusive(image_temp);
    defer disk.remove(image_temp) catch {};
    defer image.close();
    var wal: Journal = .{ .file = try disk.File.createExclusive(wal_temp), .sequence = first_end.sequence };
    defer disk.remove(wal_temp) catch {};
    defer wal.file.close();
    // The previous generation is untouched. The fresh WAL contains the same
    // database identity followed by an independently positioned anchor.
    try log.appendKind(&wal.file, 1, &identityPayload(id), identity_kind);
    const snapshot_id: snapshot.Identity = .{
        .database_id = id.database, .generation = generation, .wal_sequence = first_end.sequence, .sql_csn = live.database.csn,
    };
    var envelope = try EnvelopeWriter.begin(&image, snapshot_id);
    var scratch: [96]u8 = undefined;
    try Raw.BaseSnapshot.write(&live.database, ImageSink{ .writer = &envelope }, &scratch);
    const seal = try envelope.finish();
    const anchor: log.Frame = .{
        .offset = try wal.file.length(), .sequence = wal.sequence + 1, .kind = marker_kind, .payload_len = marker_len,
    };
    try wal.append(marker_kind, &encodeMarker(id, seal));
    const next = selectionFor(id, seal, anchor);
    image.close();
    wal.file.close();
    // Persist both generation names before changing the selected manifest.
    try disk.publishNew(image_temp, image_path);
    defer disk.remove(image_path) catch {};
    try disk.publishNew(wal_temp, wal_path);
    defer disk.remove(wal_path) catch {};

    defer disk.remove(partial_path) catch {};
    defer disk.remove(delayed_path) catch {};
    if (publishSelection(selected_path, partial_path, next, .during_temp_write)) |_| return error.PartialManifestPublished else |err| try check(err == error.SelectionInterrupted);
    if (publishSelection(selected_path, delayed_path, next, .after_temp_sync)) |_| return error.UnselectedManifestPublished else |err| try check(err == error.SelectionInterrupted);
    var partial = try disk.File.openExisting(partial_path);
    defer partial.close();
    if (manifest.Selection.read(&partial, id)) |_| return error.PartialManifestValid else |err| try check(err == error.InvalidCheckpointManifest);
    var complete = try disk.File.openExisting(delayed_path);
    defer complete.close();
    try check(std.meta.eql(try manifest.Selection.read(&complete, id), next));
    var foreign = id;
    foreign.oid += 1;
    if (manifest.Selection.read(&complete, foreign)) |_| return error.ForeignManifestAccepted else |err| try check(err == error.CheckpointDatabaseMismatch);
    published = false;
    const still_first = try recoverSelected(pid, selected_path, id, &published);
    try check(published and still_first.generation == first.generation and still_first.wal.sequence == first_end.sequence);

    try publishSelection(selected_path, temp_path, next, .none);
    wal.file = try disk.File.openExisting(wal_path);
    live.commit_ctx = &wal;
    defer live.commit_ctx = null;
    try writer.execute("INSERT INTO ledger VALUES (9,90)", &result);
    const sequence = wal.sequence;
    wal.file.close();
    published = false;
    const after = try recoverSelected(pid, selected_path, id, &published);
    try check(published and after.generation == generation and after.wal.sequence == sequence);
    try check(staged.database.csn == live.database.csn);
    var reader: Store.Connection = .{ .store = &staged, .id = 2 };
    try reader.execute("SELECT cents FROM ledger WHERE id=9", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 90);

    try disk.publishNew(image_path, hidden_path);
    defer disk.remove(hidden_path) catch {};
    published = false;
    if (recoverSelected(pid, selected_path, id, &published)) |_| return error.MissingSelectedImageIgnored else |err| try check(err == error.FileNotFound);
    try check(!published);
    var intact = try disk.File.openExisting(hidden_path);
    defer intact.close();
    image = try disk.File.createExclusive(image_path);
    try copyImage(&intact, &image, try intact.length(), snapshot.header_size + 27);
    image.close();
    if (recoverSelected(pid, selected_path, id, &published)) |_| return error.CorruptSelectedImageIgnored else |err| try check(err == error.SnapshotDigestMismatch);
    try check(!published);
}

pub fn main() !void {
    const pid: u32 = if (builtin.os.tag == .windows) Win.GetCurrentProcessId() else if (builtin.os.tag == .macos) @intCast(std.c.getpid()) else @intCast(std.os.linux.getpid());
    var lock_name: [128]u8 = undefined;
    var wal_name: [128]u8 = undefined;
    var image_name: [128]u8 = undefined;
    var published_wal_name: [128]u8 = undefined;
    var published_image_name: [128]u8 = undefined;
    var bad_name: [128]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_name, "sig-out/native-checkpoint-{d}.lock", .{pid});
    const generation = 2;
    const wal_path = try generationPath(&wal_name, pid, generation, "wal-pending");
    const image_path = try generationPath(&image_name, pid, generation, "image-pending");
    const published_wal = try generationPath(&published_wal_name, pid, generation, "wal");
    const published_image = try generationPath(&published_image_name, pid, generation, "image");
    const bad_path = try std.fmt.bufPrint(&bad_name, "sig-out/native-checkpoint-{d}.bad", .{pid});
    var lock: disk.WriterLock = .{};
    try lock.acquire(lock_path);
    defer disk.remove(lock_path) catch {};
    defer lock.close();
    var wal: Journal = .{ .file = try disk.File.createExclusive(wal_path) };
    defer disk.remove(wal_path) catch {};
    defer wal.file.close();
    var image = try disk.File.createExclusive(image_path);
    defer disk.remove(image_path) catch {};
    defer image.close();
    var broken = try disk.File.createExclusive(bad_path);
    defer disk.remove(bad_path) catch {};
    defer broken.close();

    const id = fixture_identity;
    try wal.append(identity_kind, &identityPayload(id));
    try bind(&live, 0, id);
    var commits: [2048]u8 = undefined;
    live.durability_required = true;
    live.encode_buffer = &commits;
    live.commit_ctx = &wal;
    live.commit_fn = &Journal.persist;
    var writer: Store.Connection = .{ .store = &live, .id = 1 };
    try writer.execute("CREATE TABLE ledger (id INT PRIMARY KEY, cents BIGINT)", &result);
    try writer.execute("CREATE TABLE labels (id INT PRIMARY KEY, name TEXT)", &result);
    try writer.execute("INSERT INTO ledger VALUES (1,10),(4,NULL)", &result);
    try writer.execute("INSERT INTO labels VALUES (1,'old'),(2,'keep')", &result);
    const envelope_id: snapshot.Identity = .{ .database_id = id.database, .generation = generation, .wal_sequence = wal.sequence, .sql_csn = live.database.csn };
    try check(envelope_id.wal_sequence == envelope_id.sql_csn + 1);
    var envelope = try EnvelopeWriter.begin(&image, envelope_id);
    var image_scratch: [96]u8 = undefined;
    try writer.beginTransaction();
    if (Raw.BaseSnapshot.write(&live.database, ImageSink{ .writer = &envelope }, &image_scratch)) |_| return error.ActiveCheckpointAccepted else |err| try check(err == error.SnapshotUnsupportedState);
    try check(envelope.payload_bytes == 0);
    try writer.rollbackTransaction();
    try Raw.BaseSnapshot.write(&live.database, ImageSink{ .writer = &envelope }, &image_scratch);
    const seal = try envelope.finish();
    try check(seal.payload_bytes > image_scratch.len);
    image.close();
    image = try disk.File.openExisting(image_path);

    const marker: log.Frame = .{ .offset = try wal.file.length(), .sequence = wal.sequence + 1, .kind = marker_kind, .payload_len = marker_len };
    var recovery: Recovery = .{ .seal = seal, .identity = id };
    try refuses(&recovery, &wal.file, &image, marker, error.UnexpectedEndOfLog);

    var foreign = id;
    foreign.namespace[0] ^= 1;
    try wal.append(marker_kind, &encodeMarker(foreign, seal));
    try refuses(&recovery, &wal.file, &image, marker, error.CheckpointMarkerMismatch);
    try wal.file.truncate(marker.offset);
    wal.sequence -= 1;
    try wal.append(marker_kind, &encodeMarker(id, seal));

    try writer.beginTransaction();
    try writer.execute("UPDATE ledger SET cents=30 WHERE id=1", &result);
    try writer.execute("DELETE FROM labels WHERE id=1", &result);
    try writer.execute("INSERT INTO labels VALUES (3,'suffix')", &result);
    try writer.commitTransaction();
    const suffix_end = try wal.file.length();
    const suffix_sequence = wal.sequence;
    var trailer: [log.trailer_size]u8 = undefined;
    const trailer_offset = suffix_end - trailer.len;
    try check(try wal.file.readAt(trailer_offset, &trailer) == trailer.len);
    try wal.file.truncate(trailer_offset);
    var corrupt_trailer = trailer;
    corrupt_trailer[0] ^= 1;
    try wal.file.appendAll(&corrupt_trailer);
    try wal.file.sync();
    try refuses(&recovery, &wal.file, &image, marker, error.CorruptLogRecord);
    try wal.file.truncate(trailer_offset);
    try wal.file.appendAll(&trailer);
    // The last committed frame has a partial successor after the crash.
    try wal.file.appendAll("RAMSQLW1");
    try wal.file.sync();
    wal.file.close();
    var contender: disk.WriterLock = .{};
    if (contender.acquire(lock_path)) |_| return error.SecondWriterAdmitted else |err| try check(err == error.DataDirectoryBusy);
    wal.file = try disk.File.openExisting(wal_path);

    var wrong_identity: Recovery = .{ .seal = seal, .identity = foreign };
    try refuses(&wrong_identity, &wal.file, &image, marker, error.CheckpointDatabaseMismatch);
    wrong_identity.identity = id;
    wrong_identity.identity.database[0] ^= 1;
    try refuses(&wrong_identity, &wal.file, &image, marker, error.CheckpointDatabaseMismatch);
    var wrong_generation: Recovery = recovery;
    wrong_generation.seal.identity.generation += 1;
    try refuses(&wrong_generation, &wal.file, &image, marker, error.SnapshotIdentityMismatch);
    const image_len = try image.length();
    try copyImage(&image, &broken, image_len - 1, null);
    try refuses(&recovery, &wal.file, &broken, marker, error.TruncatedSnapshot);
    try copyImage(&image, &broken, image_len, snapshot.header_size + 27);
    try refuses(&recovery, &wal.file, &broken, marker, error.SnapshotDigestMismatch);

    try bind(&staged, 1, id);
    const recovered = try recovery.restore(&wal.file, &image, marker);
    try check(recovery.published and recovered.truncated_tail and recovered.sequence == suffix_sequence);
    try check(recovered.valid_bytes == suffix_end and try wal.file.length() == suffix_end);
    try check(staged.database.csn == live.database.csn and staged.database.oid_counter == live.database.oid_counter);
    try check(staged.database.tables[0].integral_rows.len != 0 and staged.database.tables[1].integral_rows.len == 0);
    for (&live.database.tables, &staged.database.tables) |*source, *target| {
        try check(source.oid == target.oid and source.next_rowid == target.next_rowid);
    }
    var reader: Store.Connection = .{ .store = &staged, .id = 2 };
    try reader.execute("SELECT cents FROM ledger ORDER BY id", &result);
    try check(result.row_count == 2 and result.rows[0].cells[0].integer == 30 and result.rows[1].cells[0] == .null_value);
    try reader.execute("SELECT id,name FROM labels ORDER BY id", &result);
    try check(result.row_count == 2 and result.rows[0].cells[0].integer == 2 and std.mem.eql(u8, result.rows[1].cells[1].text.slice(), "suffix"));

    wal.file.close();
    wal.file = try disk.File.openExisting(wal_path);
    recovery.published = false;
    try bind(&staged, 1, id);
    const reopened = try recovery.restore(&wal.file, &image, marker);
    try check(recovery.published and !reopened.truncated_tail and reopened.sequence == suffix_sequence and reopened.valid_bytes == suffix_end);
    wal.file.close();
    image.close();
    try disk.publishNew(wal_path, published_wal);
    defer disk.remove(published_wal) catch {};
    try disk.publishNew(image_path, published_image);
    defer disk.remove(published_image) catch {};
    try exerciseSelection(pid, &writer, selectionFor(id, seal, marker), reopened);
    std.debug.print("{{\"suite\":\"native_store_checkpoint\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
}
