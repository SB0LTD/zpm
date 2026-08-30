//! LSP document store — Layer 0 (pure data, no allocator, no I/O).
//!
//! A fixed pool of open text documents keyed by URI. Zero allocator: each slot
//! has a bounded URI buffer and a bounded text buffer. Lookups are linear over
//! the small slot set. This module is platform-independent and reusable by any
//! Sig language server (hosted or SB0-native).

const std = @import("std");

/// Maximum number of documents open at once.
pub const MAX_DOCUMENTS = 32;
/// Maximum URI byte length (file:// URIs are typically well under this).
pub const MAX_URI = 1024;
/// Maximum document text size held in a slot (128 KiB).
pub const MAX_TEXT = 128 * 1024;

pub const Document = struct {
    uri_buf: [MAX_URI]u8 = undefined,
    uri_len: usize = 0,
    text_buf: [MAX_TEXT]u8 = undefined,
    text_len: usize = 0,
    version: i64 = 0,
    in_use: bool = false,

    pub fn uri(self: *const Document) []const u8 {
        return self.uri_buf[0..self.uri_len];
    }

    pub fn text(self: *const Document) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

pub const StoreError = error{
    UriTooLong,
    TextTooLong,
    StoreFull,
};

pub const Store = struct {
    docs: [MAX_DOCUMENTS]Document = [_]Document{.{}} ** MAX_DOCUMENTS,

    /// Find the slot index for a URI, or null if not open.
    pub fn find(self: *Store, target: []const u8) ?usize {
        for (&self.docs, 0..) |*doc, i| {
            if (doc.in_use and std.mem.eql(u8, doc.uri(), target)) return i;
        }
        return null;
    }

    pub fn get(self: *Store, target: []const u8) ?*Document {
        const idx = self.find(target) orelse return null;
        return &self.docs[idx];
    }

    /// Number of currently open documents.
    pub fn count(self: *const Store) usize {
        var n: usize = 0;
        for (&self.docs) |*doc| {
            if (doc.in_use) n += 1;
        }
        return n;
    }

    /// Open (or replace) a document. If the URI is already open, its contents
    /// are overwritten in place.
    pub fn open(self: *Store, target: []const u8, contents: []const u8, version: i64) StoreError!*Document {
        if (target.len > MAX_URI) return error.UriTooLong;
        if (contents.len > MAX_TEXT) return error.TextTooLong;

        const idx = self.find(target) orelse (self.freeSlot() orelse return error.StoreFull);
        var doc = &self.docs[idx];
        @memcpy(doc.uri_buf[0..target.len], target);
        doc.uri_len = target.len;
        @memcpy(doc.text_buf[0..contents.len], contents);
        doc.text_len = contents.len;
        doc.version = version;
        doc.in_use = true;
        return doc;
    }

    /// Replace the full text of an already-open document (didChange, full sync).
    pub fn replace(self: *Store, target: []const u8, contents: []const u8, version: i64) StoreError!*Document {
        if (contents.len > MAX_TEXT) return error.TextTooLong;
        const doc = self.get(target) orelse return self.open(target, contents, version);
        @memcpy(doc.text_buf[0..contents.len], contents);
        doc.text_len = contents.len;
        doc.version = version;
        return doc;
    }

    /// Close a document, freeing its slot. Returns true if it was open.
    pub fn close(self: *Store, target: []const u8) bool {
        const idx = self.find(target) orelse return false;
        self.docs[idx].in_use = false;
        self.docs[idx].uri_len = 0;
        self.docs[idx].text_len = 0;
        return true;
    }

    fn freeSlot(self: *Store) ?usize {
        for (&self.docs, 0..) |*doc, i| {
            if (!doc.in_use) return i;
        }
        return null;
    }
};

// Test instances live in static storage, not on the stack: the Store holds many
// large fixed slots, and a stack local would overflow smaller test stacks.
var test_store: Store = .{};

test "open, get, replace, close roundtrip" {
    const store = &test_store;
    store.* = .{};
    try std.testing.expectEqual(@as(usize, 0), store.count());

    const doc = try store.open("file:///a.sig", "pub fn main() void {}", 1);
    try std.testing.expectEqualStrings("file:///a.sig", doc.uri());
    try std.testing.expectEqualStrings("pub fn main() void {}", doc.text());
    try std.testing.expectEqual(@as(usize, 1), store.count());

    _ = try store.replace("file:///a.sig", "const x = 1;", 2);
    try std.testing.expectEqualStrings("const x = 1;", store.get("file:///a.sig").?.text());
    try std.testing.expectEqual(@as(i64, 2), store.get("file:///a.sig").?.version);

    try std.testing.expect(store.close("file:///a.sig"));
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "open replaces existing slot rather than duplicating" {
    const store = &test_store;
    store.* = .{};
    _ = try store.open("file:///a.sig", "one", 1);
    _ = try store.open("file:///a.sig", "two", 2);
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expectEqualStrings("two", store.get("file:///a.sig").?.text());
}

test "store enforces length bounds" {
    const store = &test_store;
    store.* = .{};
    var uri_buf: [MAX_URI + 1]u8 = undefined;
    @memset(&uri_buf, 'x');
    try std.testing.expectError(error.UriTooLong, store.open(&uri_buf, "", 1));
}
