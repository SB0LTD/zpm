// Thread pool — public API (delegates to thread/ directory module)
// Layer 1: Platform

const w = @import("thread/workers.zig");
const p = @import("thread/pool.zig");
const f = @import("thread/files.zig");

pub const MAX_WORKERS = w.MAX_WORKERS;
pub const cpuCount = w.cpuCount;
pub const cpuBoundWorkers = w.cpuBoundWorkers;
pub const ioBoundWorkers = w.ioBoundWorkers;
pub const ioBoundWorkersPerSlot = w.ioBoundWorkersPerSlot;

pub const ChunkRange = p.ChunkRange;
pub const divideRange = p.divideRange;
pub const launchThreads = p.launchThreads;
pub const joinAll = p.joinAll;

pub const buildTempPath = f.buildTempPath;
pub const createTempFile = f.createTempFile;
pub const deleteTempFiles = f.deleteTempFiles;
pub const currentTimeMs = f.currentTimeMs;
pub const currentTimeSec = f.currentTimeSec;
