//! Collations (Layer 0): the COLLATE clause's catalog and PostgreSQL's
//! collation derivation (parse_collate.c), conformance lane B11 "text".
//!
//! This engine's database collation is C: text compares by bytes (code
//! point order for UTF-8) and its ctype is C/POSIX (ASCII-only case
//! mapping and character classes; functions_string.sig, regex.sig). The
//! collations of pg_collation.dat that behave exactly like that are
//! supported: "default" (100), "C" (950), "POSIX" (951) and "ucs_basic"
//! (962, code point order with C character semantics). The built-in
//! Unicode collations (pg_c_utf8 811, unicode 963, pg_unicode_fast 6411)
//! exist on every PostgreSQL 18 server but need Unicode case mapping or
//! ICU ordering: naming one is 0A000. Any other name is 42704, as on a
//! server without imported system locales. Names match exactly (an
//! unquoted name is folded to lower case first: `COLLATE C` is "c", which
//! does not exist).
//!
//! Derivation follows parse_collate.c for explicit collations: a COLLATE
//! clause makes its operand's collation explicit, a collatable result
//! inherits its inputs' explicit collation, and two different explicit
//! collations meeting in one expression are 42P21 (collation mismatch).
//! Implicit collations never conflict here: every collatable column has
//! the database collation (column COLLATE clauses other than "default"
//! are 0A000) and `name` (implicit "C") yields to nothing it could clash
//! with.
const types = @import("types.sig");

/// Node.collation values: 0 none (implicit or not collatable), 1 through
/// `names.len` an entry of `names`, `unknown` an undefined name (42704,
/// raised after the operand's type is checked), `unsupported` a built-in
/// collation this engine cannot honour (0A000).
pub const none: u8 = 0;
pub const unknown: u8 = 0xff;
pub const unsupported: u8 = 0xfe;
/// The database collation "default" (OID 100).
pub const database_default: u8 = 1;

/// Supported collations: pg_collation OID and collname. Indexes are
/// Node.collation - 1 (stable: append only).
pub const oids = [_]u32{ 100, 950, 951, 962 };
pub const names = [_][]const u8{ "default", "C", "POSIX", "ucs_basic" };
/// generate_collation_name spellings (quote_identifier).
pub const sql_names = [_][]const u8{ "\"default\"", "\"C\"", "\"POSIX\"", "ucs_basic" };

/// Built-in collations of PostgreSQL 18 that are not supported here.
const foreign = [_][]const u8{ "pg_c_utf8", "pg_unicode_fast", "unicode" };

/// The Node.collation of a collation name (exact match), or `unknown` /
/// `unsupported`.
pub fn lookup(name: []const u8) u8 {
    for (names, 0..) |candidate, index| if (types.same(candidate, name)) return @intCast(index + 1);
    for (foreign) |candidate| if (types.same(candidate, name)) return unsupported;
    return unknown;
}

/// A supported Node.collation value (an entry of `names`).
pub fn known(value: u8) bool {
    return value != none and value <= names.len;
}

/// Types with a collation (typcollation != 0): the string types, name
/// ("C"), and arrays of them. Unknown literals take one when resolved.
pub fn collatable(ty: types.Type) bool {
    const base = types.elementType(ty) orelse ty;
    return switch (base) {
        .text, .varchar, .bpchar, .name, .unknown => true,
        else => false,
    };
}
