//! information_schema relations (B11 wave 5, catalog lane): their column
//! shapes as PostgreSQL 18 defines them (information_schema_data.sig) and
//! name lookup. Every relation is computed at scan time
//! (information_schema_rows.sig); none stores rows.
//!
//! Columns are typed by PostgreSQL's information_schema domains. A domain
//! column reports its base type and typmod on the wire, as PostgreSQL does:
//! sql_identifier is name, cardinal_number int4, character_data varchar,
//! yes_or_no varchar(3) (typmod 7) and time_stamp timestamptz(2).
const types = @import("types.sig");
const catalog = @import("catalog.sig");
pub const data = @import("information_schema_data.sig");

pub const Domain = data.Domain;

/// The domain's name, its base type and the base type's typmod.
pub fn domainName(domain: Domain) []const u8 {
    return switch (domain) {
        .id => "sql_identifier",
        .number => "cardinal_number",
        .chars => "character_data",
        .yes_no => "yes_or_no",
        .stamp => "time_stamp",
        .oid, .text_array, .name => "",
    };
}

/// A real information_schema domain (not a helper view's plain type).
pub fn isDomain(domain: Domain) bool {
    return switch (domain) {
        .oid, .text_array, .name => false,
        else => true,
    };
}

pub fn domainType(domain: Domain) types.Type {
    return switch (domain) {
        .id, .name => .name,
        .number => .int4,
        .chars, .yes_no => .varchar,
        .stamp => .timestamptz,
        .oid => .oid,
        .text_array => types.arrayType(.text).?,
    };
}

pub fn domainTypmod(domain: Domain) i32 {
    return switch (domain) {
        .yes_no => 3 + 4,
        .stamp => 2,
        else => -1,
    };
}

fn relationName(index: usize) []const u8 {
    const relation = data.relations[index];
    return data.names[relation.name_start..][0..relation.name_len];
}

const view_columns = blk: {
    @setEvalBranchQuota(100_000);
    var out: [data.columns.len]catalog.ViewColumn = undefined;
    for (data.columns, &out) |column, *view_column| {
        view_column.* = .{
            .name = data.names[column.name_start..][0..column.name_len],
            .ty = domainType(column.domain),
            .typmod = domainTypmod(column.domain),
            .domain = if (isDomain(column.domain)) column.domain else null,
        };
    }
    break :blk out;
};

const view_count = @typeInfo(catalog.View).@"enum".field_names.len;
const no_relation: u8 = 0xff;

/// information_schema relation index of each View tag (0xff: none).
const relation_of = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [view_count]u8 = @splat(no_relation);
    for (0..data.relations.len) |index| {
        const name = relationName(index);
        var found = false;
        for (@typeInfo(catalog.View).@"enum".field_names, @typeInfo(catalog.View).@"enum".field_values) |field, tag| {
            if (types.same(field, name)) {
                out[tag] = index;
                found = true;
            }
        }
        if (!found) @compileError("information_schema relation without a View tag: " ++ name);
    }
    break :blk out;
};

/// The information_schema relation of `view`, if it is one.
pub fn relationIndex(view: catalog.View) ?usize {
    const index = relation_of[@intFromEnum(view)];
    return if (index == no_relation) null else index;
}

pub fn isInformationSchema(view: catalog.View) bool {
    return relationIndex(view) != null;
}

/// 'r' for the four tables (sql_features ...), 'v' for views.
pub fn relationKind(view: catalog.View) u8 {
    const index = relationIndex(view) orelse return 'v';
    return data.relations[index].kind;
}

pub fn columnsOf(view: catalog.View) []const catalog.ViewColumn {
    const index = relationIndex(view) orelse return &.{};
    const relation = data.relations[index];
    return view_columns[relation.first..][0..relation.count];
}

/// The information_schema relation named `name` (qualified lookups only).
pub fn find(name: []const u8) ?catalog.View {
    for (0..data.relations.len) |index| {
        if (!types.same(relationName(index), name)) continue;
        for (relation_of, 0..) |relation, tag| {
            if (relation == index) return @enumFromInt(tag);
        }
    }
    return null;
}

/// Every information_schema relation in name order.
pub fn viewAt(index: usize) catalog.View {
    for (relation_of, 0..) |relation, tag| {
        if (relation == index) return @enumFromInt(tag);
    }
    return .schemata;
}

pub const relation_count = data.relations.len;
