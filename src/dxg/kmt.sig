//! @zpm/dxg kmt — dxgkrnl's user-mode interface (WSL's /dev/dxg): the
//! ioctls and their arguments, as the WSL2 Linux kernel's public uapi
//! header include/uapi/misc/d3dkmthk.h defines them (the D3DKMT calls of
//! Windows' WDDM, type 0x47). Restated here field by field; each size is
//! checked at compile time, the offsets were checked against the header
//! with offsetof (x86_64).
//!
//! A handle (D3DKMTHANDLE) is a u32 the kernel hands out per process.
//! Pointers are u64 user addresses.

const std = @import("std");
const linux = std.os.linux;

pub const Handle = u32;

/// The ioctl numbers (_IOWR(0x47, nr, the argument)).
pub const Nr = enum(u8) {
    open_adapter_from_luid = 0x01,
    create_device = 0x02,
    create_context_virtual = 0x04,
    destroy_context = 0x05,
    create_allocation = 0x06,
    create_paging_queue = 0x07,
    reserve_gpu_va = 0x08,
    query_adapter_info = 0x09,
    make_resident = 0x0b,
    map_gpu_va = 0x0c,
    escape = 0x0d,
    get_device_state = 0x0e,
    submit_command = 0x0f,
    destroy_allocation2 = 0x13,
    close_adapter = 0x15,
    create_hw_queue = 0x18,
    destroy_device = 0x19,
    destroy_hw_queue = 0x1b,
    destroy_paging_queue = 0x1c,
    free_gpu_va = 0x20,
    submit_to_hw_queue = 0x34,
    enum_adapters3 = 0x3e,
};

pub fn request(nr: Nr, comptime T: type) u32 {
    return 0xc000_0000 | (@as(u32, @sizeOf(T)) << 16) | (0x47 << 8) | @intFromEnum(nr);
}

/// STATUS_PENDING: a map or a residency change the paging queue's fence
/// finishes (the call itself succeeded).
pub const STATUS_PENDING: isize = 259;

pub const Error = error{
    /// dxgkrnl refused the call (its errno or NTSTATUS in `last_status`).
    Refused,
};

/// What the last refused call answered (a negative errno, or an NTSTATUS).
pub threadlocal var last_status: isize = 0;
pub threadlocal var last_nr: u8 = 0;

/// The call `nr` with argument `arg` (its size makes the request). Success
/// and STATUS_PENDING return; anything else is error.Refused.
pub fn call(fd: i32, nr: Nr, arg: anytype) Error!isize {
    const T = @typeInfo(@TypeOf(arg)).pointer.child;
    const rc: isize = @bitCast(linux.ioctl(fd, request(nr, T), @intFromPtr(arg)));
    if (rc == 0 or rc == STATUS_PENDING) return rc;
    last_status = rc;
    last_nr = @intFromEnum(nr);
    return error.Refused;
}

pub const Luid = extern struct { low: u32 = 0, high: i32 = 0 };

pub const AdapterInfo = extern struct {
    adapter: Handle = 0,
    luid: Luid = .{},
    num_sources: u32 = 0,
    present_move_regions_preferred: u32 = 0,
};

pub const EnumAdapters3 = extern struct {
    /// (bit 0: include compute-only adapters)
    filter: u64 = 1,
    count: u32 = 0,
    reserved: u32 = 0,
    adapters: u64 = 0,
};

pub const CloseAdapter = extern struct { adapter: Handle };

pub const QueryAdapterInfo = extern struct {
    adapter: Handle,
    type: u32,
    data: u64,
    size: u32,
    pad: u32 = 0,
};

/// KMTQAITYPE 31: the adapter's PCI ids (what each u32 of the answer is).
pub const QUERY_PCI_IDS: u32 = 31;
pub const PciIds = extern struct {
    reserved: u32 = 0,
    vendor: u32 = 0,
    device: u32 = 0,
    subsystem_vendor: u32 = 0,
    subsystem: u32 = 0,
    revision: u32 = 0,
    bus_type: u32 = 0,
};

pub const CreateDevice = extern struct {
    adapter: Handle,
    reserved3: u32 = 0,
    flags: u32 = 0,
    device: Handle = 0,
    command_buffer: u64 = 0,
    command_buffer_size: u32 = 0,
    reserved: u32 = 0,
    allocation_list: u64 = 0,
    allocation_list_size: u32 = 0,
    reserved1: u32 = 0,
    patch_location_list: u64 = 0,
    patch_location_list_size: u32 = 0,
    reserved2: u32 = 0,
};

pub const DestroyDevice = extern struct { device: Handle };

/// d3dkmt_getdevicestate; state_type 1 (execution: `seq` low word the
/// state) or 5 (the page fault: where, from which stage, how).
pub const GetDeviceState = extern struct {
    device: Handle,
    state_type: u32,
    seq: u64 = 0,
    stage: u32 = 0,
    bind_entry: u32 = 0,
    flags: u32 = 0,
    error_code: u32 = 0,
    va: u64 = 0,
    rest: [16]u8 = [_]u8{0} ** 16,
};
pub const DEVICESTATE_EXECUTION: u32 = 1;
pub const DEVICESTATE_PAGE_FAULT: u32 = 5;

comptime {
    if (@sizeOf(GetDeviceState) != 56) @compileError("d3dkmt_getdevicestate is 56 bytes");
}

/// D3DDDI_CREATECONTEXTFLAGS
pub const CONTEXT_DISABLE_GPU_TIMEOUT: u32 = 1 << 2;
pub const CONTEXT_HW_QUEUE_SUPPORTED: u32 = 1 << 4;

pub const CreateContextVirtual = extern struct {
    device: Handle,
    node_ordinal: u32 = 0,
    engine_affinity: u32 = 1,
    flags: u32 = 0,
    priv: u64 = 0,
    priv_size: u32 = 0,
    /// D3DKMT_CLIENTHINT (5: CUDA)
    client_hint: u32 = 0,
    context: Handle = 0,
    pad: u32 = 0,
};

pub const DestroyContext = extern struct { context: Handle };

pub const CreatePagingQueue = extern struct {
    device: Handle,
    priority: i32 = 0,
    paging_queue: Handle = 0,
    sync_object: Handle = 0,
    /// The paging fence's value (u64), mapped by the kernel.
    fence_cpu: u64 = 0,
    physical_adapter_index: u32 = 0,
    pad: u32 = 0,
};

pub const DestroyPagingQueue = extern struct { paging_queue: Handle };

pub const ReserveGpuVa = extern struct {
    adapter: Handle,
    pad: u32 = 0,
    base: u64 = 0,
    minimum: u64 = 0,
    maximum: u64 = 0,
    size: u64,
    reservation_type: u32 = 0,
    pad2: u32 = 0,
    driver_protection: u64 = 0,
    va: u64 = 0,
    paging_fence: u64 = 0,
};

pub const FreeGpuVa = extern struct { adapter: Handle, pad: u32 = 0, base: u64, size: u64 };

pub const AllocationInfo2 = extern struct {
    allocation: Handle = 0,
    pad: u32 = 0,
    /// The process's own memory backing it (0: the GPU's memory).
    sysmem: u64 = 0,
    priv: u64 = 0,
    priv_size: u32 = 0,
    vidpn_source_id: u32 = 0,
    flags: u32 = 0,
    pad2: u32 = 0,
    gpu_va: u64 = 0,
    priority: u64 = 0,
    reserved: [5]u64 = .{0} ** 5,
};

/// D3DKMT_CREATEALLOCATIONFLAGS as NVIDIA's driver sets them for its own
/// allocations (create_resource, and bit 18).
pub const CREATE_ALLOCATION_NV: u32 = 0x0004_0001;

pub const CreateAllocation = extern struct {
    device: Handle,
    resource: Handle = 0,
    global_share: Handle = 0,
    reserved: u32 = 0,
    private_runtime_data: u64 = 0,
    private_runtime_data_size: u32 = 0,
    reserved1: u32 = 0,
    priv: u64 = 0,
    priv_size: u32 = 0,
    count: u32 = 1,
    info: u64 = 0,
    flags: u32 = CREATE_ALLOCATION_NV,
    reserved2: u32 = 0,
    private_runtime_resource_handle: u64 = 0,
};

pub const DestroyAllocation2 = extern struct {
    device: Handle,
    resource: Handle = 0,
    allocations: u64 = 0,
    count: u32 = 0,
    flags: u32 = 0,
};

pub const MakeResident = extern struct {
    paging_queue: Handle,
    count: u32 = 1,
    allocations: u64,
    priorities: u64 = 0,
    /// (bit 0: cant_trim_further, as NVIDIA's driver asks)
    flags: u32 = 1,
    pad: u32 = 0,
    paging_fence: u64 = 0,
    bytes_to_trim: u64 = 0,
};

/// D3DDDIGPUVA_PROTECTION_TYPE bit 0: writable.
pub const PROTECTION_WRITE: u64 = 1;

pub const MapGpuVa = extern struct {
    paging_queue: Handle,
    pad: u32 = 0,
    base: u64,
    minimum: u64 = 0,
    maximum: u64 = 0,
    allocation: Handle,
    pad2: u32 = 0,
    offset_pages: u64 = 0,
    size_pages: u64,
    protection: u64 = PROTECTION_WRITE,
    driver_protection: u64 = 0,
    reserved0: u32 = 0,
    pad3: u32 = 0,
    reserved1: u64 = 0,
    va: u64 = 0,
    paging_fence: u64 = 0,
};

pub const Escape = extern struct {
    adapter: Handle,
    device: Handle = 0,
    type: u32 = 0,
    flags: u32 = 0,
    priv: u64,
    priv_size: u32,
    context: Handle = 0,
};

pub const CreateHwQueue = extern struct {
    context: Handle,
    flags: u32 = 0,
    priv_size: u32 = 0,
    reserved: u32 = 0,
    priv: u64 = 0,
    queue: Handle = 0,
    progress_fence: Handle = 0,
    /// The queue's progress fence (u64): CPU and GPU addresses.
    progress_cpu: u64 = 0,
    progress_gpu: u64 = 0,
};

pub const DestroyHwQueue = extern struct { queue: Handle };

/// A legacy context's submission (d3dkmt_submitcommand): NVIDIA's video
/// engines' contexts take their work so (no hardware queue): the command
/// buffer, and NVIDIA's private data naming it as a GPFIFO entry.
pub const SubmitCommand = extern struct {
    command_buffer: u64 = 0,
    command_length: u32 = 0,
    flags: u32 = 0,
    present_history_token: u64 = 0,
    broadcast_context_count: u32 = 0,
    broadcast_context: [64]Handle = @splat(0),
    reserved: u32 = 0,
    priv: u64 = 0,
    priv_size: u32 = 0,
    num_primaries: u32 = 0,
    written_primaries: [16]Handle = @splat(0),
    num_history_buffers: u32 = 0,
    reserved1: u32 = 0,
    history_buffer_array: u64 = 0,
};

pub const SubmitToHwQueue = extern struct {
    queue: Handle,
    reserved: u32 = 0,
    /// The value the queue's progress fence reaches when this work is done.
    progress_fence: u64,
    command_buffer: u64 = 0,
    command_length: u32 = 0,
    priv_size: u32 = 0,
    priv: u64 = 0,
    num_primaries: u32 = 0,
    reserved1: u32 = 0,
    written_primaries: u64 = 0,
};

comptime {
    const sizes = .{
        .{ AdapterInfo, 20 },         .{ EnumAdapters3, 24 },   .{ QueryAdapterInfo, 24 },
        .{ CreateDevice, 64 },        .{ CreateContextVirtual, 40 }, .{ CreatePagingQueue, 32 },
        .{ ReserveGpuVa, 72 },        .{ AllocationInfo2, 96 }, .{ CreateAllocation, 72 },
        .{ DestroyAllocation2, 24 },  .{ MakeResident, 48 },    .{ MapGpuVa, 104 },
        .{ Escape, 32 },              .{ CreateHwQueue, 48 },   .{ SubmitToHwQueue, 56 },
        .{ SubmitCommand, 384 },
        .{ PciIds, 28 },
    };
    for (sizes) |s| {
        if (@sizeOf(s[0]) != s[1]) @compileError(@typeName(s[0]) ++ ": not the header's size");
    }
    // (the offsets offsetof gave)
    if (@offsetOf(MapGpuVa, "allocation") != 32 or @offsetOf(MapGpuVa, "size_pages") != 48 or
        @offsetOf(MapGpuVa, "protection") != 56 or @offsetOf(MapGpuVa, "va") != 88 or
        @offsetOf(MapGpuVa, "paging_fence") != 96) @compileError("MapGpuVa offsets");
    if (@offsetOf(MakeResident, "paging_fence") != 32) @compileError("MakeResident offsets");
    if (@offsetOf(SubmitCommand, "broadcast_context") != 28 or @offsetOf(SubmitCommand, "priv") != 288 or @offsetOf(SubmitCommand, "priv_size") != 296) @compileError("SubmitCommand offsets");
    if (@offsetOf(CreateAllocation, "info") != 48 or @offsetOf(CreateAllocation, "flags") != 56) @compileError("CreateAllocation offsets");
    if (@offsetOf(AllocationInfo2, "gpu_va") != 40 or @offsetOf(AllocationInfo2, "priority") != 48) @compileError("AllocationInfo2 offsets");
    if (@offsetOf(CreateHwQueue, "priv") != 16 or @offsetOf(CreateHwQueue, "progress_gpu") != 40) @compileError("CreateHwQueue offsets");
    if (@offsetOf(SubmitToHwQueue, "priv_size") != 28 or @offsetOf(SubmitToHwQueue, "priv") != 32) @compileError("SubmitToHwQueue offsets");
    if (@offsetOf(ReserveGpuVa, "size") != 32 or @offsetOf(ReserveGpuVa, "va") != 56) @compileError("ReserveGpuVa offsets");
    if (@offsetOf(CreateContextVirtual, "client_hint") != 28 or @offsetOf(CreateContextVirtual, "context") != 32) @compileError("CreateContextVirtual offsets");
    if (@offsetOf(EnumAdapters3, "adapters") != 16) @compileError("EnumAdapters3 offsets");
}

test "requests are the header's _IOWR numbers" {
    try std.testing.expectEqual(@as(u32, 0xc038_4734), request(.submit_to_hw_queue, SubmitToHwQueue));
    try std.testing.expectEqual(@as(u32, 0xc068_470c), request(.map_gpu_va, MapGpuVa));
    try std.testing.expectEqual(@as(u32, 0xc030_470b), request(.make_resident, MakeResident));
}
