// Log — public re-export shim
// Callers import this file; implementation lives in log/
const run = @import("log/run.zig");
pub const Level = run.Level;
pub const isDebug = run.isDebug;
pub const init = run.init;
pub const err = run.err;
pub const warn = run.warn;
pub const info = run.info;
pub const debug = run.debug;
pub const trace = run.trace;
