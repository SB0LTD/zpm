//! Reuse every canonical/model/lifecycle assertion with the sparse kernel on.
pub const test_sparse_factor=true;
comptime {if(!@import("test_sql_factor_join.sig").sparse_test) @compileError("sparse lifecycle kernel must be enabled");}
pub fn main() !void {try @import("test_sql_factor_join.sig").main();}
