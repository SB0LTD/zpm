//! Nested statement execution (conformance lane B11 wave 4,
//! docs/SQL_NESTED_STATEMENTS.md): a statement that runs while another
//! statement is executing (the SQL of a trigger function, of a function
//! called from an expression, or a rule action) gets a pristine statement
//! workspace and leaves the suspended statement's workspace exactly as it
//! found it.
//!
//! The suspended statement keeps its query cells, refs and value bytes in
//! place: the nested statement works only in the free middle of the query
//! workspace (Work floors and tops). Everything else the nested statement
//! would overwrite (the used part of the node pool, the plans, the
//! expansion text and the statement-scoped scalars of the Database) is
//! copied into the top of that free middle, below the suspended statement's
//! top cells, and copied back when the nested statement ends, whether it
//! succeeded or failed. Nothing allocates; a workspace too full to hold the
//! saved state is WorkspaceCapacity (54000).
//!
//! One `Stream` walk serves three modes over the same field order: measure
//! (the bytes needed), save and restore. Variable-length parts follow the
//! scalars that give their length, so a restore reads the length before the
//! items. Saved values never point into the saved region itself.
pub const Mode = enum { measure, save, restore };

pub const Stream = struct {
    mode: Mode,
    bytes: [*]u8 = undefined,
    at: usize = 0,

    /// One value of any type.
    pub fn value(self: *Stream, pointer: anytype) void {
        const T = @typeInfo(@TypeOf(pointer)).pointer.child;
        self.raw(@ptrCast(pointer), @sizeOf(T));
    }

    /// The first `count` items of an array.
    pub fn prefix(self: *Stream, array: anytype, count: usize) void {
        const Array = @typeInfo(@TypeOf(array)).pointer.child;
        const Item = @typeInfo(Array).array.child;
        if (count == 0) return;
        self.raw(@ptrCast(&array[0]), count * @sizeOf(Item));
    }

    /// Every field of a struct except the named ones (in declaration order).
    pub fn fieldsExcept(self: *Stream, object: anytype, comptime skip: []const []const u8) void {
        const T = @typeInfo(@TypeOf(object)).pointer.child;
        inline for (@typeInfo(T).@"struct".field_names) |name| {
            if (comptime !listed(skip, name)) self.value(&@field(object, name));
        }
    }

    fn raw(self: *Stream, data: [*]u8, size: usize) void {
        switch (self.mode) {
            .measure => {},
            .save => @memcpy(self.bytes[self.at..][0..size], data[0..size]),
            .restore => @memcpy(data[0..size], self.bytes[self.at..][0..size]),
        }
        self.at += size;
    }
};

fn listed(comptime skip: []const []const u8, comptime name: []const u8) bool {
    for (skip) |entry| {
        if (entry.len == name.len) {
            var same = true;
            for (entry, name) |a, b| same = same and a == b;
            if (same) return true;
        }
    }
    return false;
}

/// The statement workspace parts a nested statement replaces: the used
/// node pool, plans and expansion texts, and the query workspace's
/// statement scalars (its cells, refs and value bytes stay in place).
pub fn workspace(stream: *Stream, ws: anytype) void {
    const pool = &ws.nodes;
    stream.fieldsExcept(pool, &.{ "windows", "nodes", "queries" });
    stream.prefix(&pool.windows, pool.window_len);
    stream.prefix(&pool.nodes, pool.len);
    stream.prefix(&pool.queries, pool.query_len);
    const plans = &ws.plans;
    stream.fieldsExcept(plans, &.{ "items", "ctes", "dml" });
    stream.prefix(&plans.items, plans.len);
    stream.prefix(&plans.ctes, plans.cte_len);
    stream.prefix(&plans.dml, plans.dml_len);
    stream.fieldsExcept(&ws.query, &.{ "cells", "refs", "value_backing" });
    stream.fieldsExcept(ws, &.{ "nodes", "plans", "query", "expansion", "expanded" });
    stream.prefix(&ws.expanded, @min(ws.expanded_count, ws.expanded.len));
    stream.prefix(&ws.expansion, @min(ws.expansion_used, ws.expansion.len));
}

/// Bytes of the suspended statement's value region (the nested statement's
/// value floor): what the running query's value bytes already hold.
pub fn valueFloor(work: anytype) usize {
    const values = &work.values;
    if (values.bytes.len == 0) return work.floor_values;
    const base = @intFromPtr(&work.value_backing);
    const at = @intFromPtr(values.bytes.ptr);
    if (at < base or at > base + work.value_backing.len) return work.floor_values;
    return @min(at - base + values.used, work.value_backing.len);
}

/// Cells needed to hold `bytes`.
pub fn cellsFor(comptime Cell: type, bytes: usize) usize {
    return (bytes + @sizeOf(Cell) - 1) / @sizeOf(Cell);
}
