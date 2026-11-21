//! PostgreSQL identities for the default index classes exposed by RAMSQL.
//! Every listed type has equality and ordering support in the SQL engine.
//! Stock tooling qualification verifies the catalog links and exercises each
//! class through CREATE UNIQUE INDEX, ordered reads and duplicate rejection.
const types = @import("types.sig");
const operator_catalog = @import("operator_catalog.sig");

const Class = struct { oid: u32, name: []const u8, input: types.DataType };
const Family = struct { oid: u32, name: []const u8, classes: []const Class };

pub const btree_families = [_]Family{
    .{ .oid = 423, .name = "bit_ops", .classes = &.{.{ .oid = 10002, .name = "bit_ops", .input = .bit }} },
    .{ .oid = 424, .name = "bool_ops", .classes = &.{.{ .oid = 10003, .name = "bool_ops", .input = .boolean }} },
    .{ .oid = 426, .name = "bpchar_ops", .classes = &.{.{ .oid = 10004, .name = "bpchar_ops", .input = .bpchar }} },
    .{ .oid = 428, .name = "bytea_ops", .classes = &.{.{ .oid = 10006, .name = "bytea_ops", .input = .bytea }} },
    .{ .oid = 429, .name = "char_ops", .classes = &.{.{ .oid = 10007, .name = "char_ops", .input = .pg_internal_char }} },
    .{ .oid = 434, .name = "datetime_ops", .classes = &.{
        .{ .oid = 3122, .name = "date_ops", .input = .date },
        .{ .oid = 3127, .name = "timestamptz_ops", .input = .timestamptz },
        .{ .oid = 3128, .name = "timestamp_ops", .input = .timestamp },
    } },
    .{ .oid = 1970, .name = "float_ops", .classes = &.{
        .{ .oid = 3123, .name = "float8_ops", .input = .double },
        .{ .oid = 10012, .name = "float4_ops", .input = .real },
    } },
    .{ .oid = 1974, .name = "network_ops", .classes = &.{.{ .oid = 10015, .name = "inet_ops", .input = .inet }} },
    .{ .oid = 1976, .name = "integer_ops", .classes = &.{
        .{ .oid = 1978, .name = "int4_ops", .input = .integer32 },
        .{ .oid = 1979, .name = "int2_ops", .input = .smallint },
        .{ .oid = 3124, .name = "int8_ops", .input = .integer },
    } },
    .{ .oid = 1982, .name = "interval_ops", .classes = &.{.{ .oid = 10022, .name = "interval_ops", .input = .interval }} },
    .{ .oid = 1984, .name = "macaddr_ops", .classes = &.{.{ .oid = 10024, .name = "macaddr_ops", .input = .macaddr }} },
    .{ .oid = 1988, .name = "numeric_ops", .classes = &.{.{ .oid = 3125, .name = "numeric_ops", .input = .numeric }} },
    .{ .oid = 1989, .name = "oid_ops", .classes = &.{.{ .oid = 1981, .name = "oid_ops", .input = .oid }} },
    .{ .oid = 1994, .name = "text_ops", .classes = &.{.{ .oid = 3126, .name = "text_ops", .input = .text }} },
    .{ .oid = 1996, .name = "time_ops", .classes = &.{.{ .oid = 10038, .name = "time_ops", .input = .time }} },
    .{ .oid = 2000, .name = "timetz_ops", .classes = &.{.{ .oid = 10041, .name = "timetz_ops", .input = .timetz }} },
    .{ .oid = 2002, .name = "varbit_ops", .classes = &.{.{ .oid = 10043, .name = "varbit_ops", .input = .varbit }} },
    .{ .oid = 2099, .name = "money_ops", .classes = &.{.{ .oid = 10047, .name = "money_ops", .input = .money }} },
    .{ .oid = 2968, .name = "uuid_ops", .classes = &.{.{ .oid = 10065, .name = "uuid_ops", .input = .uuid }} },
    .{ .oid = 3253, .name = "pg_lsn_ops", .classes = &.{.{ .oid = 10067, .name = "pg_lsn_ops", .input = .pg_lsn }} },
    .{ .oid = 4033, .name = "jsonb_ops", .classes = &.{.{ .oid = 10088, .name = "jsonb_ops", .input = .jsonb }} },
};

pub fn defaultBtreeOid(comptime data_type: types.DataType) u32 {
    return lookupDefaultBtreeOid(data_type) orelse unreachable;
}

const Strategy = struct { oid: u32, family: u32, left: u32, right: u32, number: u16, operator: u32 };
const Strategies = struct {
    items: [operator_catalog.operators.len]Strategy = undefined,
    len: usize = 0,
};

fn btreeStrategies() Strategies {
    @setEvalBranchQuota(100000);
    var result: Strategies = .{};
    for (operator_catalog.operators) |op| {
        const number: u16 = if (types.same(op.name, "<")) 1 else if (types.same(op.name, "<=")) 2
            else if (types.same(op.name, "=")) 3 else if (types.same(op.name, ">=")) 4
            else if (types.same(op.name, ">")) 5 else continue;
        if (op.result != 16) continue;
        for (btree_families) |family| {
            var left = false;
            var right = false;
            for (family.classes) |class| {
                const oid = types.typeOid(class.input);
                left = left or oid == op.left;
                right = right or oid == op.right;
            }
            if (!left or !right) continue;
            // Built-in strategy rows have engine-local identities. Each
            // exposed operator belongs to at most one of these families.
            result.items[result.len] = .{ .oid = op.oid, .family = family.oid, .left = op.left, .right = op.right, .number = number, .operator = op.oid };
            result.len += 1;
            break;
        }
    }
    return result;
}

const strategies = btreeStrategies();
pub const btree_strategies = strategies.items[0..strategies.len];

pub fn lookupDefaultBtreeOid(data_type: types.DataType) ?u32 {
    for (btree_families) |family| {
        for (family.classes) |class| {
            if (class.input == data_type) return class.oid;
        }
    }
    return null;
}
