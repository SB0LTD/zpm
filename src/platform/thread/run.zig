// Thread pool — entry point, re-exports full public API
// Layer 1: Platform

const w = @import("workers.zig");
const p = @import("pool.zig");
const f = @import("files.zig");

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
