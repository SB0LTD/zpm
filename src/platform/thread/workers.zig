// Worker count policies — CPU-aware thread budget allocation
// Layer 1: Platform

const w32 = @import("win32");

/// Hard ceiling on worker threads for any single parallel operation.
pub const MAX_WORKERS: usize = 16;

/// Cached logical processor count. Populated on first call to cpuCount().
var g_cpu_count: usize = 0;

/// Return the number of logical processors on this machine (cached).
pub fn cpuCount() usize {
    if (g_cpu_count > 0) return g_cpu_count;
    var info: w32.SYSTEM_INFO = .{};
    w32.GetSystemInfo(&info);
    g_cpu_count = @max(1, info.dwNumberOfProcessors);
    return g_cpu_count;
}

/// Optimal worker count for CPU-bound parallel work.
/// Uses cpus-1 to leave one core for the render thread.
pub fn cpuBoundWorkers(max_for_task: usize) usize {
    const cpus = cpuCount();
    const from_cpus = @max(1, if (cpus > 1) cpus - 1 else 1);
    return @min(from_cpus, @min(max_for_task, MAX_WORKERS));
}

/// Optimal worker count for I/O-bound parallel work (HTTP fetches, file I/O).
/// More threads than cores is correct — they spend most time waiting.
/// Formula: clamp(cpus * 2, 4, MAX_WORKERS).
pub fn ioBoundWorkers(max_for_task: usize) usize {
    const cpus = cpuCount();
    const from_io = @max(4, cpus * 2);
    return @min(from_io, @min(max_for_task, MAX_WORKERS));
}

/// Distribute an I/O worker budget across `n_slots` concurrent backfill slots.
/// Each slot gets at least 2 workers; total is capped at MAX_WORKERS.
pub fn ioBoundWorkersPerSlot(n_slots: usize) usize {
    if (n_slots == 0) return ioBoundWorkers(MAX_WORKERS);
    const total = ioBoundWorkers(MAX_WORKERS);
    const per_slot = @max(2, total / n_slots);
    return @min(per_slot, MAX_WORKERS);
}
