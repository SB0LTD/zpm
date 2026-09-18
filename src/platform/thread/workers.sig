// Worker count policies — CPU-aware thread budget allocation
// Layer 1: Platform

const w32 = @import("win32");

/// Hard ceiling on worker threads for any single parallel operation.
/// I/O-bound backfill spends most of its time waiting on the network, so a
/// ceiling above core count lets many symbol fetches run concurrently. 24
/// keeps ~3 workers/slot across an 8-symbol basket while staying well under
/// exchange rate limits (the fetch path self-throttles on 429).
pub const MAX_WORKERS: usize = 24;

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

/// Maximal CPU worker count — uses ALL logical processors (no core reserved).
/// For short, bursty batch compute (e.g. running a backtest matrix) where we
/// want every thread saturated for the duration.
pub fn cpuBoundWorkersAll(max_for_task: usize) usize {
    return @min(cpuCount(), @min(max_for_task, MAX_WORKERS));
}

/// A snapshot of the host CPU/memory characteristics used to size work.
pub const HwProfile = struct {
    logical_processors: usize = 1,
    page_size: u32 = 0,
    allocation_granularity: u32 = 0,
    processor_arch: u16 = 0, // 9 = x64, 5 = ARM, 12 = ARM64
    processor_level: u16 = 0,
    active_mask: usize = 0,

    pub fn archName(self: *const HwProfile) []const u8 {
        return switch (self.processor_arch) {
            9 => "x64",
            5 => "ARM",
            12 => "ARM64",
            6 => "IA64",
            0 => "x86",
            else => "unknown",
        };
    }
};

/// Profile the current hardware (CPU count, arch, page size, affinity mask).
pub fn profile() HwProfile {
    var info: w32.SYSTEM_INFO = .{};
    w32.GetSystemInfo(&info);
    return .{
        .logical_processors = @max(1, info.dwNumberOfProcessors),
        .page_size = info.dwPageSize,
        .allocation_granularity = info.dwAllocationGranularity,
        .processor_arch = info.wProcessorArchitecture,
        .processor_level = info.wProcessorLevel,
        .active_mask = info.dwActiveProcessorMask,
    };
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
/// Each slot gets at least 3 workers; total is capped at MAX_WORKERS. The
/// floor of 3 keeps each symbol's history fetching in several parallel chunks
/// even when many slots run at once (8 slots × 3 = 24 = MAX_WORKERS).
pub fn ioBoundWorkersPerSlot(n_slots: usize) usize {
    if (n_slots == 0) return ioBoundWorkers(MAX_WORKERS);
    const total = ioBoundWorkers(MAX_WORKERS);
    const per_slot = @max(3, total / n_slots);
    return @min(per_slot, MAX_WORKERS);
}
