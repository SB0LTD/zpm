//! The guest's side of Hyper-V's GPU paravirtualization (GPU-PV, "GPU
//! partitioning"): a machine given a partition of the host's GPU
//! (Add-VMGpuPartitionAdapter) is offered two VMBus channels, dxgkrnl's
//! global one and one per virtual GPU, over which the guest makes the
//! host's dxgkrnl calls (Windows' D3DKMT) as WSL's Linux kernel does. The
//! host's GPU driver (NVIDIA's) then runs the guest's work on the real GPU:
//! the guest writes the same private data and pushbuffers zpm's dxg writes
//! through /dev/dxg in WSL.
//!
//! The layouts are those of the WSL2 Linux kernel's drivers/hv/dxgkrnl
//! (dxgvmbus.h, dxgkrnl.h; linux-msft-wsl-6.6.y), restated field by field
//! (documentation only); each size is checked below against the C layout.
//!
//! The handshake (`Gpu.start`), as dxgkrnl's: the IO space (a window of the
//! machine's MMIO the host maps its fence pages into) on the global
//! channel, then the adapter opened and described on the vGPU channel, then
//! a process (every later call names it) and a device. Version 27 of the
//! interface needs nothing else; 40 adds a header to every message and is
//! agreed through the virtual PCI device's config space (not done here).
//!
//! Zero allocation, freestanding; the channels are vmbus.sig's.

const std = @import("std");
const vmbus = @import("vmbus.sig");

/// The channels' kinds, as the host offers them.
pub const GLOBAL = vmbus.guid("dde9cbc0-5060-4436-9448-ea1254a5d177");
pub const VGPU = vmbus.guid("6e382d18-3336-4f4b-acc4-2b7703d4df4a");

/// The interface's versions: 40 with dxgvmb_ext_header (agreed through the
/// virtual PCI device), 27 without; the oldest the guest still speaks.
pub const VERSION: u32 = 40;
pub const VERSION_OLD: u32 = 27;
pub const LAST_COMPATIBLE: u32 = 16;
/// Each channel's rings: 256 KiB each way, as dxgkrnl's.
pub const RING_PAGES: u32 = 64;
pub const MAX_PACKET = 128 << 10;
/// A reply waited for at most this long.
pub const TIMEOUT_US: u32 = 5_000_000;

pub const ChannelType = enum(u32) { vgpu_to_host = 0, vm_to_host = 1, host_to_vm = 2 };

/// The global channel's commands (dxgkvmb_commandtype_global).
pub const Global = enum(u32) {
    create_process = 1000,
    destroy_process = 1001,
    set_iospace_region = 1010,
    _,
};

/// The vGPU's commands (dxgkvmb_commandtype).
pub const Command = enum(u32) {
    create_device = 0,
    destroy_device = 1,
    query_adapter_info = 2,
    create_allocation = 4,
    destroy_allocation = 5,
    create_context_virtual = 6,
    destroy_context = 7,
    create_sync_object = 8,
    create_paging_queue = 9,
    destroy_paging_queue = 10,
    make_resident = 11,
    evict = 12,
    escape = 13,
    open_adapter = 14,
    close_adapter = 15,
    free_gpu_va = 16,
    map_gpu_va = 17,
    reserve_gpu_va = 18,
    submit_command = 20,
    wait_for_sync_object_from_cpu = 22,
    wait_for_sync_object_from_gpu = 25,
    signal_sync_object = 26,
    get_device_state = 28,
    get_internal_adapter_info = 36,
    query_allocation_residency = 41,
    set_existing_sysmem_store = 45,
    set_existing_sysmem_pages = 66,
    _,
};

pub const Luid = extern struct { a: u32 = 0, b: u32 = 0 };

/// The vGPU channel's LUID, as dxgkrnl takes it: the first 8 bytes of the
/// channel's instance GUID (the host sets them to its adapter's LUID).
pub fn luidOf(instance: vmbus.Guid) Luid {
    return .{ .a = std.mem.readInt(u32, instance[0..4], .little), .b = std.mem.readInt(u32, instance[4..8], .little) };
}

// ── Headers ─────────────────────────────────────────────────────────────────

/// dxgkvmb_command_vm_to_host: the global channel's.
pub const VmToHost = extern struct {
    command_id: u64 = 0,
    process: u32 = 0,
    channel_type: u32 = @intFromEnum(ChannelType.vm_to_host),
    command_type: u32,
};

/// dxgkvmb_command_vgpu_to_host: the vGPU's (channel type in the low 8 bits
/// of `flags`, bit 8 an asynchronous message).
pub const VgpuToHost = extern struct {
    command_id: u64 = 0,
    process: u32 = 0,
    flags: u32 = @intFromEnum(ChannelType.vgpu_to_host),
    command_type: u32,
};

/// dxgvmb_ext_header: before every message from version 40.
pub const ExtHeader = extern struct {
    command_offset: u32 = @sizeOf(ExtHeader),
    reserved: u32 = 0,
    vgpu_luid: Luid = .{},
};

// ── The handshake's messages ────────────────────────────────────────────────

pub const PROCESS_NAME_LENGTH = 260;

pub const CreateProcess = extern struct {
    hdr: VmToHost = .{ .command_type = @intFromEnum(Global.create_process) },
    /// The guest's own cookie for the process (dxgkrnl: its pointer).
    process: u64,
    process_id: u64,
    process_name: [PROCESS_NAME_LENGTH + 1]u16 = @splat(0),
    /// csrss 0, dwm 1, wow64 2, linux 3.
    kind: u8 = LINUX_PROCESS,
};
pub const LINUX_PROCESS: u8 = 1 << 3;
pub const CreateProcessReturn = extern struct { hprocess: u32 };

pub const SetIoSpaceRegion = extern struct {
    hdr: VmToHost = .{ .command_type = @intFromEnum(Global.set_iospace_region) },
    start: u64,
    length: u64,
    shared_page_gpadl: u32 = 0,
};

pub const OpenAdapter = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.open_adapter) },
    version: u32,
    last_compatible: u32 = LAST_COMPATIBLE,
    guest_adapter_luid: Luid,
};
pub const OpenAdapterReturn = extern struct {
    host_adapter_handle: u32,
    status: i32,
    version: u32,
    last_compatible: u32,
};

pub const GetInternalAdapterInfo = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.get_internal_adapter_info) },
};
pub const AdapterInfo = extern struct {
    device_types: u32,
    driver_store_copy_mode: u32,
    driver_ddi_version: u32,
    /// INFO_* bits.
    flags: u32,
    host_adapter_luid: Luid,
    device_description: [80]u16,
    device_instance_id: [260]u16,
    /// Version 40 only (the reply is 8 bytes shorter before).
    host_vgpu_luid: Luid,
};
pub const INFO_HW_SCH_ENABLED: u32 = 1 << 3;
pub const INFO_HW_SCH_CAPABLE: u32 = 1 << 4;
pub const INFO_ASYNC_MSG: u32 = 1 << 6;

pub const QueryAdapterInfo = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.query_adapter_info) },
    query_type: u32,
    private_data_size: u32,
    // (the query's data follows)
};

pub const CreateDevice = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.create_device) },
    flags: u32 = 0,
    cdd_device: u8 = 0,
    /// Where the host reports device errors (SETGUESTDATA): a guest address.
    error_code: u64 = 0,
};
pub const CreateDeviceReturn = extern struct { device: u32 };

// ── After the handshake: memory, contexts, work ─────────────────────────────
//
// Each is a D3DKMT call's arguments behind the vGPU header, as WSL's /dev/dxg
// passes them through (the pointers in them mean nothing to the host; the
// data they name follows the message instead). Handles are the host's.

/// d3dkmt_createpagingqueue's: the queue maps and residency changes run on;
/// its fence (a monitored fence the host keeps in a page of the IO space).
pub const CreatePagingQueue = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.create_paging_queue) },
    device: u32,
    priority: i32 = 0,
    paging_queue: u32 = 0,
    sync_object: u32 = 0,
    fence_cpu: u64 = 0,
    physical_adapter_index: u32 = 0,
};
pub const CreatePagingQueueReturn = extern struct {
    paging_queue: u32,
    sync_object: u32,
    /// The fence's page: a guest physical address in the IO space.
    fence_storage: u64,
    fence_storage_offset: u64,
};

/// An allocation (one, the driver's private data for it after the info).
pub const CreateAllocation = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.create_allocation) },
    device: u32,
    resource: u32 = 0,
    private_runtime_data_size: u32 = 0,
    /// The resource's own private data (none here).
    priv_size: u32 = 0,
    alloc_count: u32 = 1,
    /// ALLOC_* bits (d3dkmt_createallocationflags).
    flags: u32,
    private_runtime_resource_handle: u64 = 0,
    make_resident: u8 = 0,
};
pub const AllocInfo = extern struct { flags: u32 = 0, priv_size: u32, vidpn_source_id: u32 = 0 };
pub const AllocInfoReturn = extern struct {
    allocation: u32,
    priv_size: u32,
    flags: u32,
    size: u64,
    /// dxgkarg_describeallocation (the display's view; not used).
    driver_info: [6]u64,
};
pub const CreateAllocationReturn = extern struct {
    flags: u32,
    resource: u32,
    global_share: u32,
    vgpu_flags: u32,
    info: AllocInfoReturn,
    // (the driver's private data for the allocation follows, as it kept it)
};
/// d3dkmt_createallocationflags: a resource made with it, the guest's own
/// memory behind it (then named with set_existing_sysmem_store).
pub const ALLOC_CREATE_RESOURCE: u32 = 1 << 0;
pub const ALLOC_EXISTING_SYSMEM: u32 = 1 << 5;

/// The guest's pages behind an allocation: a GPADL (on the global channel)
/// that names them.
pub const SetSysmemStore = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.set_existing_sysmem_store) },
    device: u32,
    allocation: u32,
    gpadl: u32,
};

pub const MakeResident = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.make_resident) },
    /// (dxgkrnl leaves it 0)
    device: u32 = 0,
    paging_queue: u32,
    /// bit 0: cant_trim_further (as NVIDIA's driver asks)
    flags: u32 = 1,
    alloc_count: u32 = 1,
    allocation: u32,
};
pub const MakeResidentReturn = extern struct { paging_fence: u64, bytes_to_trim: u64, status: i32 };

pub const ReserveGpuVa = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.reserve_gpu_va) },
    adapter: u32,
    base: u64,
    minimum: u64 = 0,
    maximum: u64 = 0,
    size: u64,
    reservation_type: u32 = 0,
    driver_protection: u64 = 0,
    va: u64 = 0,
    paging_fence: u64 = 0,
};
pub const ReserveGpuVaReturn = extern struct { va: u64, paging_fence: u64 };

pub const MapGpuVa = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.map_gpu_va) },
    paging_queue: u32,
    base: u64,
    minimum: u64 = 0,
    maximum: u64 = 0,
    allocation: u32,
    offset_pages: u64 = 0,
    size_pages: u64,
    /// D3DDDIGPUVA_PROTECTION_TYPE: bit 0 writable.
    protection: u64 = 1,
    driver_protection: u64 = 0,
    reserved0: u32 = 0,
    reserved1: u64 = 0,
    va: u64 = 0,
    paging_fence: u64 = 0,
    /// 0, as dxgkrnl sends it (its ioctl passes no device: the paging
    /// queue names it); a device's handle here is refused (0xC000000D,
    /// galaxy-turing's RTX 2080 Ti, 2026-11-22).
    device: u32 = 0,
};
pub const MapGpuVaReturn = extern struct { va: u64, paging_fence: u64, status: i32 };

/// A context; the driver's private data follows at CONTEXT_DATA_AT (the
/// host answers with the message itself, the context's handle in it).
pub const CreateContext = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.create_context_virtual) },
    context: u32 = 0,
    device: u32,
    node: u32 = 0,
    engine_affinity: u32 = 1,
    flags: u32 = 0,
    client_hint: u32 = 0,
    priv_size: u32,
};
pub const CONTEXT_DATA_AT = 52;

pub const DestroyContext = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.destroy_context) },
    context: u32,
};

pub const DestroyAllocation = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.destroy_allocation) },
    device: u32,
    resource: u32 = 0,
    alloc_count: u32 = 1,
    /// bit 0: assume_not_in_use
    flags: u32 = 0,
    allocation: u32,
};

/// d3dkmt_submitcommand's, the driver's private data after it.
pub const SubmitCommand = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.submit_command) },
    command_buffer: u64 = 0,
    command_length: u32 = 0,
    flags: u32 = 0,
    present_history_token: u64 = 0,
    broadcast_context_count: u32 = 1,
    broadcast_context: [64]u32 = @splat(0),
    reserved: u32 = 0,
    priv: u64 = 0,
    priv_size: u32 = 0,
    num_primaries: u32 = 0,
    written_primaries: [16]u32 = @splat(0),
    num_history_buffers: u32 = 0,
    reserved1: u32 = 0,
    history_buffer_array: u64 = 0,
};

/// The context waits (on the GPU's side: Windows' scheduler holds its later
/// work) for fence values of monitored fences: the values at
/// WAIT_GPU_FENCES_AT, then the objects' handles.
pub const WaitFromGpu = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.wait_for_sync_object_from_gpu) },
    context: u32,
    object_count: u32 = 1,
    legacy_fence_object: u8 = 0,
};
pub const WAIT_GPU_FENCES_AT = 40;

/// The guest is told (SIGNALGUESTEVENT on the global channel, naming
/// `guest_event`) when the objects reach their values; their handles, then
/// the values, follow.
pub const WaitFromCpu = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.wait_for_sync_object_from_cpu) },
    device: u32,
    object_count: u32 = 1,
    /// bit 0: wait_any
    flags: u32 = 0,
    guest_event: u64,
    dereference_event: u8 = 0,
};

pub const GetDeviceState = extern struct {
    hdr: VgpuToHost = .{ .command_type = @intFromEnum(Command.get_device_state) },
    device: u32,
    state_type: u32,
    /// The answer's union (d3dkmt_getdevicestate's: the execution state, or
    /// the page fault's sequence, stage, entry, flags, code and address).
    state: [48]u8 = @splat(0),
};
pub const DEVICESTATE_EXECUTION: u32 = 1;
pub const DEVICESTATE_PAGE_FAULT: u32 = 5;

/// What the host sends the guest on the global channel
/// (dxgkvmb_commandtype_host_to_vm).
pub const HOST_SIGNAL_GUEST_EVENT: u32 = 0;
pub const HOST_SET_GUEST_DATA: u32 = 2;
pub const HOST_SIGNAL_GUEST_EVENT_PASSIVE: u32 = 3;

/// NTSTATUS STATUS_PENDING: a map or residency change the paging fence
/// finishes (the call itself succeeded).
pub const STATUS_PENDING: i32 = 259;

comptime {
    // (the C layouts' sizes: natural alignment, no packing)
    if (@sizeOf(VmToHost) != 24 or @sizeOf(VgpuToHost) != 24 or @sizeOf(ExtHeader) != 16) @compileError("gpu: header sizes");
    if (@sizeOf(CreateProcess) != 568 or @offsetOf(CreateProcess, "process_name") != 40 or @offsetOf(CreateProcess, "kind") != 562) @compileError("gpu: create_process");
    if (@sizeOf(SetIoSpaceRegion) != 48 or @sizeOf(OpenAdapter) != 40 or @sizeOf(OpenAdapterReturn) != 16) @compileError("gpu: io space, open adapter");
    if (@sizeOf(AdapterInfo) != 712 or @offsetOf(AdapterInfo, "device_description") != 24) @compileError("gpu: adapter info");
    if (@sizeOf(QueryAdapterInfo) != 32 or @sizeOf(CreateDevice) != 40) @compileError("gpu: query, device");
    if (@sizeOf(CreatePagingQueue) != 56 or @offsetOf(CreatePagingQueue, "fence_cpu") != 40 or @sizeOf(CreatePagingQueueReturn) != 24) @compileError("gpu: paging queue");
    if (@sizeOf(CreateAllocation) != 64 or @offsetOf(CreateAllocation, "private_runtime_resource_handle") != 48 or @sizeOf(AllocInfo) != 12) @compileError("gpu: create_allocation");
    if (@sizeOf(AllocInfoReturn) != 72 or @offsetOf(AllocInfoReturn, "size") != 16 or @sizeOf(CreateAllocationReturn) != 88 or @offsetOf(CreateAllocationReturn, "info") != 16) @compileError("gpu: create_allocation's answer");
    if (@sizeOf(SetSysmemStore) != 40 or @sizeOf(MakeResident) != 48 or @sizeOf(MakeResidentReturn) != 24) @compileError("gpu: sysmem, residency");
    if (@sizeOf(ReserveGpuVa) != 96 or @offsetOf(ReserveGpuVa, "size") != 56 or @offsetOf(ReserveGpuVa, "va") != 80) @compileError("gpu: reserve_gpu_va");
    if (@sizeOf(MapGpuVa) != 136 or @offsetOf(MapGpuVa, "allocation") != 56 or @offsetOf(MapGpuVa, "va") != 112 or @offsetOf(MapGpuVa, "device") != 128 or @sizeOf(MapGpuVaReturn) != 24) @compileError("gpu: map_gpu_va");
    if (@sizeOf(CreateContext) != 56 or @offsetOf(CreateContext, "priv_size") != 48) @compileError("gpu: create_context_virtual");
    if (@sizeOf(SubmitCommand) != 408 or @offsetOf(SubmitCommand, "broadcast_context") != 52 or @offsetOf(SubmitCommand, "priv_size") != 320) @compileError("gpu: submit_command");
    if (@sizeOf(WaitFromGpu) != 40 or @sizeOf(WaitFromCpu) != 56 or @offsetOf(WaitFromCpu, "guest_event") != 40) @compileError("gpu: waits");
    if (@sizeOf(GetDeviceState) != 80 or @sizeOf(DestroyAllocation) != 48 or @sizeOf(DestroyContext) != 32) @compileError("gpu: device state, destroys");
}

pub const Error = error{
    /// The host did not answer in time (or the ring was full).
    NoAnswer,
    /// The host answered with a failure (its NTSTATUS in `Gpu.status`).
    Refused,
    /// The reply was shorter than its kind.
    ShortReply,
    /// A message bigger than the guest's buffer for it.
    TooBig,
};

/// The handshake's results, for the log.
pub const Step = enum { io_space, open_adapter, adapter_info, create_process, query_pci, create_device };

/// The guest's GPU over its two channels.
pub fn Gpu(comptime Host: type) type {
    return struct {
        const Self = @This();
        pub const Channel = vmbus.Channel(Host);

        global: Channel,
        vgpu: Channel,
        version: u32 = VERSION_OLD,
        guest_luid: Luid = .{},
        process: u32 = 0,
        adapter: u32 = 0,
        device: u32 = 0,
        info: AdapterInfo = undefined,
        pci: [8]u32 = @splat(0),
        /// The last NTSTATUS the host answered.
        status: i32 = 0,
        /// set_iospace_region's NTSTATUS (-1: no answer; 0 when not asked).
        io_status: i32 = 0,
        /// The step `start` stopped at.
        failed: ?Step = null,
        /// The command (its type) of the last call made, and its answer's
        /// length, for the log.
        command: u32 = 0,
        reply_len: usize = 0,
        /// Guest events the host signaled (SIGNALGUESTEVENT) and no one
        /// has taken yet (0: a free slot).
        events: [16]u64 = @splat(0),
        rx: [8192]u8 align(8) = undefined,
        tx: [8192]u8 align(8) = undefined,
        /// A message being put together (its parts after its head).
        msg: [8192]u8 align(8) = undefined,

        /// The adapter's messages go on the vGPU channel until the host
        /// says it takes them asynchronously on the global one.
        fn adapterChannel(self: *Self) *Channel {
            return if (self.info.flags & INFO_ASYNC_MSG != 0 and self.device != 0) &self.global else &self.vgpu;
        }

        /// A message's bytes as sent (version 40's header first).
        fn frame(self: *Self, bytes: []const u8) []const u8 {
            var n: usize = 0;
            if (self.version >= VERSION) {
                const h = ExtHeader{ .vgpu_luid = self.info.host_vgpu_luid };
                @memcpy(self.tx[0..@sizeOf(ExtHeader)], std.mem.asBytes(&h));
                n = @sizeOf(ExtHeader);
            }
            @memcpy(self.tx[n..][0..bytes.len], bytes);
            return self.tx[0 .. n + bytes.len];
        }

        /// One message and the host's reply (its bytes, in `rx`).
        pub fn call(self: *Self, ch: *Channel, bytes: []const u8) Error![]const u8 {
            if (bytes.len >= 20) self.command = std.mem.readInt(u32, bytes[16..20], .little);
            const id = ch.send(self.frame(bytes), true) orelse return error.NoAnswer;
            var waited: u32 = 0;
            while (waited < TIMEOUT_US) {
                while (ch.receive(&self.rx)) |p| {
                    if (p.kind == vmbus.pkt.COMPLETION and p.id == id) return p.body;
                    self.hostPacket(ch, p);
                }
                ch.host.delayUs(20);
                waited += 20;
            }
            return error.NoAnswer;
        }

        /// A message from the host (not an answer): a guest event it
        /// signals is kept for `signaled`; the rest (its data for the guest,
        /// notifications) nothing here waits for.
        fn hostPacket(self: *Self, ch: *Channel, p: vmbus.Packet) void {
            if (ch != &self.global or p.kind != vmbus.pkt.DATA_INBAND or p.body.len < 32) return;
            const t = std.mem.readInt(u32, p.body[16..20], .little);
            if (t != HOST_SIGNAL_GUEST_EVENT and t != HOST_SIGNAL_GUEST_EVENT_PASSIVE) return;
            const ev = std.mem.readInt(u64, p.body[24..32], .little);
            for (&self.events) |*e| {
                if (e.* == 0) {
                    e.* = ev;
                    return;
                }
            }
        }

        /// The host's messages on the global channel taken (between calls).
        pub fn pollHost(self: *Self) void {
            while (self.global.receive(&self.rx)) |p| self.hostPacket(&self.global, p);
        }

        /// Whether the host has signaled guest event `event` (each signal
        /// taken once).
        pub fn signaled(self: *Self, event: u64) bool {
            self.pollHost();
            for (&self.events) |*e| {
                if (e.* == event) {
                    e.* = 0;
                    return true;
                }
            }
            return false;
        }

        /// A vGPU message's header for this process.
        fn head(self: *const Self, c: Command) VgpuToHost {
            return .{ .process = self.process, .command_type = @intFromEnum(c) };
        }

        /// The adapter's call (on its channel).
        fn vcall(self: *Self, bytes: []const u8) Error![]const u8 {
            return self.call(self.adapterChannel(), bytes);
        }

        /// `first` (a message's head) and `rest` after it, in `msg`.
        fn build(self: *Self, first: []const u8, rest: []const []const u8) Error![]const u8 {
            var n = first.len;
            for (rest) |r| n += r.len;
            if (n > self.msg.len - @sizeOf(ExtHeader)) return error.TooBig;
            @memcpy(self.msg[0..first.len], first);
            n = first.len;
            for (rest) |r| {
                @memcpy(self.msg[n..][0..r.len], r);
                n += r.len;
            }
            return self.msg[0..n];
        }

        /// An answer of kind T; a shorter one is the host's NTSTATUS alone
        /// (a refusal), kept in `status`.
        fn answer(self: *Self, comptime T: type, body: []const u8) Error!T {
            self.reply_len = body.len;
            if (body.len >= @sizeOf(T)) return std.mem.bytesToValue(T, body[0..@sizeOf(T)]);
            if (body.len < 4) return error.ShortReply;
            self.status = std.mem.readInt(i32, body[0..4], .little);
            return error.Refused;
        }

        /// An NTSTATUS that may be STATUS_PENDING (the paging fence finishes
        /// the work).
        fn pendingOk(self: *Self, status: i32) Error!void {
            self.status = status;
            if (status != 0 and status != STATUS_PENDING) return error.Refused;
        }

        // ── Memory, contexts, work (after `start`) ──────────────────────────

        pub const PagingQueue = struct {
            handle: u32,
            /// Its fence: a monitored fence (for waitFromGpu, waitFromCpu).
            sync_object: u32,
            /// The fence's page (a guest physical address in the IO space:
            /// the u64 the host moves as the queue's work finishes).
            fence_page: u64,
        };

        pub fn createPagingQueue(self: *Self) Error!PagingQueue {
            const m = CreatePagingQueue{ .hdr = self.head(.create_paging_queue), .device = self.device };
            const r = try self.answer(CreatePagingQueueReturn, try self.vcall(std.mem.asBytes(&m)));
            if (r.paging_queue == 0) return error.Refused;
            return .{ .handle = r.paging_queue, .sync_object = r.sync_object, .fence_page = r.fence_storage };
        }

        pub const Allocation = struct { handle: u32, resource: u32, size: u64 };

        /// One allocation with the driver's private data `priv`; `flags`
        /// the call's (ALLOC_* and the driver's own). With
        /// ALLOC_EXISTING_SYSMEM the guest names its pages next
        /// (setSysmemStore) before anything uses it.
        pub fn createAllocation(self: *Self, priv: []const u8, flags: u32) Error!Allocation {
            const m = CreateAllocation{ .hdr = self.head(.create_allocation), .device = self.device, .flags = flags };
            const info = AllocInfo{ .priv_size = @intCast(priv.len) };
            const b = try self.vcall(try self.build(std.mem.asBytes(&m), &.{ std.mem.asBytes(&info), priv }));
            const r = try self.answer(CreateAllocationReturn, b);
            if (r.info.allocation == 0) return error.Refused;
            return .{ .handle = r.info.allocation, .resource = r.resource, .size = r.info.size };
        }

        /// The guest's pages behind `allocation`: the GPADL `gpadl` (made
        /// on the global channel) that names them.
        pub fn setSysmemStore(self: *Self, allocation: u32, gpadl: u32) Error!void {
            const m = SetSysmemStore{ .hdr = self.head(.set_existing_sysmem_store), .device = self.device, .allocation = allocation, .gpadl = gpadl };
            try self.ntstatus(try self.vcall(std.mem.asBytes(&m)));
        }

        /// `allocation` resident; the paging fence's value that says so.
        pub fn makeResident(self: *Self, paging_queue: u32, allocation: u32) Error!u64 {
            const m = MakeResident{ .hdr = self.head(.make_resident), .paging_queue = paging_queue, .allocation = allocation };
            const r = try self.answer(MakeResidentReturn, try self.vcall(std.mem.asBytes(&m)));
            try self.pendingOk(r.status);
            return r.paging_fence;
        }

        /// GPU addresses [base, base + size) kept for this process's maps.
        pub fn reserveVa(self: *Self, base: u64, size: u64) Error!u64 {
            const m = ReserveGpuVa{ .hdr = self.head(.reserve_gpu_va), .adapter = self.adapter, .base = base, .size = size };
            const r = try self.answer(ReserveGpuVaReturn, try self.vcall(std.mem.asBytes(&m)));
            if (r.va == 0) return error.Refused;
            return r.va;
        }

        pub const Mapped = struct { va: u64, paging_fence: u64 };

        /// `pages` of `allocation` at GPU address `base` (in a reserved
        /// range; 0: where the host likes in [minimum, maximum]).
        pub fn mapVa(self: *Self, paging_queue: u32, allocation: u32, base: u64, minimum: u64, maximum: u64, pages: u64) Error!Mapped {
            return self.map(.{ .paging_queue = paging_queue, .base = base, .minimum = minimum, .maximum = maximum, .allocation = allocation, .size_pages = pages });
        }

        /// The map `m` as given (its offset and protection too; its
        /// header made here).
        pub fn map(self: *Self, args: MapGpuVa) Error!Mapped {
            var m = args;
            m.hdr = self.head(.map_gpu_va);
            m.device = 0;
            const r = try self.answer(MapGpuVaReturn, try self.vcall(std.mem.asBytes(&m)));
            try self.pendingOk(r.status);
            return .{ .va = r.va, .paging_fence = r.paging_fence };
        }

        /// A context on engine `node` with the driver's data `priv`; its
        /// handle. (The message is sized as dxgkrnl sizes it: the C
        /// struct's size, less its one-byte data array, plus the data.)
        pub fn createContext(self: *Self, node: u32, flags: u32, client: u32, priv: []const u8) Error!u32 {
            const m = CreateContext{ .hdr = self.head(.create_context_virtual), .device = self.device, .node = node, .flags = flags, .client_hint = client, .priv_size = @intCast(priv.len) };
            const n = @sizeOf(CreateContext) - 1 + priv.len;
            if (n > self.msg.len - @sizeOf(ExtHeader)) return error.TooBig;
            @memset(self.msg[0..n], 0);
            @memcpy(self.msg[0..CONTEXT_DATA_AT], std.mem.asBytes(&m)[0..CONTEXT_DATA_AT]);
            @memcpy(self.msg[CONTEXT_DATA_AT..][0..priv.len], priv);
            const b = try self.vcall(self.msg[0..n]);
            if (b.len < 28) {
                if (b.len >= 4) self.status = std.mem.readInt(i32, b[0..4], .little);
                return if (b.len >= 4) error.Refused else error.ShortReply;
            }
            const ctx = std.mem.readInt(u32, b[24..28], .little);
            if (ctx == 0) return error.Refused;
            return ctx;
        }

        pub fn destroyContext(self: *Self, context: u32) void {
            const m = DestroyContext{ .hdr = self.head(.destroy_context), .context = context };
            _ = self.vcall(std.mem.asBytes(&m)) catch {};
        }

        pub fn destroyAllocation(self: *Self, allocation: u32) void {
            const m = DestroyAllocation{ .hdr = self.head(.destroy_allocation), .device = self.device, .allocation = allocation, .flags = 1 };
            _ = self.vcall(std.mem.asBytes(&m)) catch {};
        }

        /// The driver's command buffer `command_buffer`, `command_length`
        /// long, on `context`, with its private data `priv`. Synchronous
        /// unless the host takes the adapter's messages asynchronously
        /// (then sent on the global channel, no answer).
        pub fn submit(self: *Self, context: u32, command_buffer: u64, command_length: u32, priv: []const u8) Error!void {
            var m = SubmitCommand{ .hdr = self.head(.submit_command), .command_buffer = command_buffer, .command_length = command_length, .priv_size = @intCast(priv.len) };
            m.broadcast_context[0] = context;
            if (self.info.flags & INFO_ASYNC_MSG != 0) {
                m.hdr.flags |= 1 << 8;
                const bytes = try self.build(std.mem.asBytes(&m), &.{priv});
                _ = self.global.send(self.frame(bytes), false) orelse return error.NoAnswer;
                return;
            }
            try self.ntstatus(try self.vcall(try self.build(std.mem.asBytes(&m), &.{priv})));
        }

        /// `context`'s later work held until monitored fence `object`
        /// reaches `value` (Windows' scheduler waits, not the CPU).
        pub fn waitFromGpu(self: *Self, context: u32, object: u32, value: u64) Error!void {
            const m = WaitFromGpu{ .hdr = self.head(.wait_for_sync_object_from_gpu), .context = context };
            var tail: [12]u8 = undefined;
            std.mem.writeInt(u64, tail[0..8], value, .little);
            std.mem.writeInt(u32, tail[8..12], object, .little);
            try self.ntstatus(try self.vcall(try self.build(std.mem.asBytes(&m), &.{&tail})));
        }

        /// Guest event `event` signaled (`signaled`) when monitored fence
        /// `object` reaches `value`.
        pub fn waitFromCpu(self: *Self, object: u32, value: u64, event: u64) Error!void {
            const m = WaitFromCpu{ .hdr = self.head(.wait_for_sync_object_from_cpu), .device = self.device, .guest_event = event };
            var tail: [12]u8 = undefined;
            std.mem.writeInt(u32, tail[0..4], object, .little);
            std.mem.writeInt(u64, tail[4..12], value, .little);
            try self.ntstatus(try self.vcall(try self.build(std.mem.asBytes(&m), &.{&tail})));
        }

        /// The device's state of kind `state_type` (DEVICESTATE_*): the
        /// answer's union (execution: its first u32; page fault: sequence
        /// u64, stage, entry, flags, code u32s, address u64).
        pub fn deviceState(self: *Self, state_type: u32) Error![48]u8 {
            const m = GetDeviceState{ .hdr = self.head(.get_device_state), .device = self.device, .state_type = state_type };
            const b = try self.vcall(std.mem.asBytes(&m));
            if (b.len < 60) {
                if (b.len >= 4) self.status = std.mem.readInt(i32, b[0..4], .little);
                return if (b.len >= 4) error.Refused else error.ShortReply;
            }
            self.status = std.mem.readInt(i32, b[56..60], .little);
            if (self.status != 0) return error.Refused;
            return b[8..56].*;
        }

        fn reply(comptime T: type, body: []const u8) Error!T {
            if (body.len < @sizeOf(T)) return error.ShortReply;
            return std.mem.bytesToValue(T, body[0..@sizeOf(T)]);
        }

        fn ntstatus(self: *Self, body: []const u8) Error!void {
            if (body.len < 4) return error.ShortReply;
            self.status = std.mem.readInt(i32, body[0..4], .little);
            if (self.status != 0) return error.Refused;
        }

        /// The handshake: the IO space window (none when `io_len` is 0),
        /// the adapter, a process named `name`, the adapter's PCI ids, a
        /// device. `failed` names the step an error came from.
        pub fn start(self: *Self, io_start: u64, io_len: u64, name: []const u8) Error!void {
            self.guest_luid = luidOf(self.vgpu.offer.instance);
            // (a refused IO space is kept in io_status and the rest tried:
            // only fence pages need it)
            if (io_len != 0) {
                const m = SetIoSpaceRegion{ .start = io_start, .length = io_len };
                if (self.call(&self.global, std.mem.asBytes(&m))) |b| {
                    self.io_status = if (b.len >= 4) std.mem.readInt(i32, b[0..4], .little) else -1;
                } else |_| self.io_status = -1;
            }
            self.failed = .open_adapter;
            const oa = OpenAdapter{ .version = self.version, .guest_adapter_luid = self.guest_luid };
            const r = try reply(OpenAdapterReturn, try self.call(&self.vgpu, std.mem.asBytes(&oa)));
            self.status = r.status;
            if (r.status != 0) return error.Refused;
            self.adapter = r.host_adapter_handle;

            self.failed = .adapter_info;
            const gi = GetInternalAdapterInfo{};
            const body = try self.call(&self.vgpu, std.mem.asBytes(&gi));
            const want: usize = if (self.version >= VERSION) @sizeOf(AdapterInfo) else @sizeOf(AdapterInfo) - @sizeOf(Luid);
            if (body.len < want) return error.ShortReply;
            self.info = std.mem.zeroes(AdapterInfo);
            @memcpy(std.mem.asBytes(&self.info)[0..want], body[0..want]);

            self.failed = .create_process;
            self.process = try self.createProcess(name, 1);

            self.failed = .query_pci;
            // (D3DKMT_QUERY_DEVICE_IDS: the physical adapter's index, then
            // vendor, device, subsystem vendor, subsystem, revision, bus
            // type: `pci` from the vendor on)
            var ids: [PCI_IDS_BYTES]u8 = @splat(0);
            const got = try self.queryAdapterInfo(QUERY_PCI_IDS, &ids);
            if (got < 16) return error.ShortReply;
            self.pci = @splat(0);
            for (self.pci[0..@min(got / 4 - 1, self.pci.len)], 0..) |*w, i| w.* = std.mem.readInt(u32, ids[4 + 4 * i ..][0..4], .little);

            self.failed = .create_device;
            self.device = try self.createDevice();
            self.failed = null;
        }

        /// The adapter's answer to query `query_type` (KMTQAITYPE) into
        /// `out` (its size the size asked); how many bytes came.
        pub fn queryAdapterInfo(self: *Self, query_type: u32, out: []u8) Error!usize {
            const qh = QueryAdapterInfo{ .hdr = self.head(.query_adapter_info), .query_type = query_type, .private_data_size = @intCast(out.len) };
            if (@sizeOf(QueryAdapterInfo) + out.len > self.msg.len - @sizeOf(ExtHeader)) return error.TooBig;
            @memset(self.msg[0 .. @sizeOf(QueryAdapterInfo) + out.len], 0);
            @memcpy(self.msg[0..@sizeOf(QueryAdapterInfo)], std.mem.asBytes(&qh));
            const r = try self.vcall(self.msg[0 .. @sizeOf(QueryAdapterInfo) + out.len]);
            // (the answer is the query's data alone, no NTSTATUS: the WDDM
            // 2.7 caps came back as 0x9, the PCI ids with the adapter's
            // index first, galaxy-turing's RTX 2080 Ti, 2026-11-22; a
            // shorter one is taken for the host's refusal)
            self.reply_len = r.len;
            if (r.len < out.len) {
                if (r.len >= 4) self.status = std.mem.readInt(i32, r[0..4], .little);
                return error.Refused;
            }
            @memcpy(out, r[0..out.len]);
            return out.len;
        }

        /// A process (every later call names one; each has its own GPU
        /// address space) named `name`; its handle. `cookie`: the guest's
        /// own number for it.
        pub fn createProcess(self: *Self, name: []const u8, cookie: u64) Error!u32 {
            var cp = CreateProcess{ .process = cookie, .process_id = cookie };
            for (name[0..@min(name.len, PROCESS_NAME_LENGTH)], 0..) |c, i| cp.process_name[i] = c;
            const p = try self.answer(CreateProcessReturn, try self.call(&self.global, std.mem.asBytes(&cp)));
            if (p.hprocess == 0) return error.Refused;
            return p.hprocess;
        }

        /// A device of this process; its handle.
        pub fn createDevice(self: *Self) Error!u32 {
            const cd = CreateDevice{ .hdr = self.head(.create_device) };
            const d = try self.answer(CreateDeviceReturn, try self.vcall(std.mem.asBytes(&cd)));
            if (d.device == 0) return error.Refused;
            return d.device;
        }

        /// The adapter's description (UTF-16, ASCII kept) into `out`.
        pub fn description(self: *const Self, out: []u8) []const u8 {
            var n: usize = 0;
            for (self.info.device_description) |c| {
                if (c == 0 or n == out.len) break;
                out[n] = if (c < 128) @intCast(c) else '?';
                n += 1;
            }
            return out[0..n];
        }
    };
}

/// KMTQAITYPE 31: the adapter's PCI ids (dxg.kmt.PciIds: reserved, vendor,
/// device, subsystem vendor, subsystem, revision, bus type).
pub const QUERY_PCI_IDS: u32 = 31;
pub const PCI_IDS_BYTES: u32 = 28;

// ── Tests: the handshake against a host the test plays ──────────────────────

const testing = std.testing;

const Play = struct {
    g: *Gpu(vmbus.testing.Host),
    step: u32 = 0,
    /// What the guest sent, as the host saw it (the later calls' checks).
    gpadl: u32 = 0,
    waited: u64 = 0,
    wait_object: u32 = 0,
    submitted: [16]u8 = @splat(0),
    submit_bytes: u32 = 0,
    context_bytes: usize = 0,

    fn answer(ctx: *anyopaque) void {
        const s: *Play = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 align(8) = undefined;
        // the guest's newest message: on the vGPU channel or the global one
        for ([_]*vmbus.Channel(vmbus.testing.Host){ &s.g.vgpu, &s.g.global }) |ch| {
            const n = ch.out.read(&buf) orelse continue;
            const id = std.mem.readInt(u64, buf[8..16], .little);
            const body = buf[16..n];
            const cmd = std.mem.readInt(u32, body[16..20], .little);
            var r: [1024]u8 align(8) = @splat(0);
            var len: usize = 4;
            switch (cmd) {
                @intFromEnum(Global.set_iospace_region) => {},
                @intFromEnum(Command.open_adapter) => {
                    std.mem.writeInt(u32, r[0..4], 0x4000_0000, .little);
                    len = 16;
                },
                @intFromEnum(Command.get_internal_adapter_info) => {
                    const name = "NVIDIA GeForce RTX 2080 Ti";
                    for (name, 0..) |c, i| r[24 + 2 * i] = c;
                    len = 704;
                },
                @intFromEnum(Global.create_process) => std.mem.writeInt(u32, r[0..4], 0x8000_0001, .little),
                @intFromEnum(Command.query_adapter_info) => {
                    std.mem.writeInt(u32, r[4..8], 0x10de, .little);
                    std.mem.writeInt(u32, r[8..12], 0x1e07, .little);
                    len = 28;
                },
                @intFromEnum(Command.create_device) => std.mem.writeInt(u32, r[0..4], 0x4000_0040, .little),
                @intFromEnum(Command.create_paging_queue) => {
                    std.mem.writeInt(u32, r[0..4], 0x11, .little);
                    std.mem.writeInt(u32, r[4..8], 0x12, .little);
                    std.mem.writeInt(u64, r[8..16], 0xf_e000_1000, .little);
                    len = 24;
                },
                @intFromEnum(Command.create_allocation) => {
                    // the driver's data (at 64 + 12) comes back after the answer
                    const priv = std.mem.readInt(u32, body[68..72], .little);
                    std.mem.writeInt(u32, r[4..8], 0x21, .little);
                    std.mem.writeInt(u32, r[16..20], 0x22, .little);
                    std.mem.writeInt(u32, r[20..24], priv, .little);
                    std.mem.writeInt(u64, r[32..40], 0x1_0000, .little);
                    @memcpy(r[88..][0..priv], body[76..][0..priv]);
                    len = 88 + priv;
                },
                @intFromEnum(Command.set_existing_sysmem_store) => s.gpadl = std.mem.readInt(u32, body[32..36], .little),
                @intFromEnum(Command.make_resident) => {
                    std.mem.writeInt(u64, r[0..8], 5, .little);
                    std.mem.writeInt(i32, r[16..20], STATUS_PENDING, .little);
                    len = 24;
                },
                @intFromEnum(Command.reserve_gpu_va) => {
                    @memcpy(r[0..8], body[32..40]);
                    len = 16;
                },
                @intFromEnum(Command.map_gpu_va) => {
                    @memcpy(r[0..8], body[32..40]);
                    std.mem.writeInt(u64, r[8..16], 6, .little);
                    std.mem.writeInt(i32, r[16..20], STATUS_PENDING, .little);
                    len = 24;
                },
                @intFromEnum(Command.create_context_virtual) => {
                    // the message itself, the context's handle in it
                    s.context_bytes = body.len;
                    @memcpy(r[0..body.len], body);
                    std.mem.writeInt(u32, r[24..28], 0x31, .little);
                    len = body.len;
                },
                @intFromEnum(Command.wait_for_sync_object_from_gpu) => {
                    s.waited = std.mem.readInt(u64, body[40..48], .little);
                    s.wait_object = std.mem.readInt(u32, body[48..52], .little);
                },
                @intFromEnum(Command.submit_command) => {
                    s.submit_bytes = std.mem.readInt(u32, body[320..324], .little);
                    @memcpy(&s.submitted, body[408..424]);
                },
                @intFromEnum(Command.wait_for_sync_object_from_cpu) => {
                    // answered, then the event signaled on the global channel
                    _ = vmbus.testing.fromHost(ch.in, vmbus.pkt.COMPLETION, id, r[0..4]);
                    var ev: [48]u8 = @splat(0);
                    std.mem.writeInt(u32, ev[12..16], @intFromEnum(ChannelType.host_to_vm), .little);
                    std.mem.writeInt(u32, ev[16..20], HOST_SIGNAL_GUEST_EVENT, .little);
                    @memcpy(ev[24..32], body[40..48]);
                    _ = vmbus.testing.fromHost(s.g.global.in, vmbus.pkt.DATA_INBAND, 0, &ev);
                    s.step += 1;
                    continue;
                },
                @intFromEnum(Command.get_device_state) => {
                    std.mem.writeInt(u32, r[8..12], 1, .little);
                    len = 64;
                },
                else => {},
            }
            _ = vmbus.testing.fromHost(ch.in, vmbus.pkt.COMPLETION, id, r[0..len]);
            s.step += 1;
        }
    }
};

test "GPU-PV: the headers and messages are the C layouts' sizes" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(VgpuToHost));
    try testing.expectEqual(@as(usize, 568), @sizeOf(CreateProcess));
    try testing.expectEqual(@as(usize, 712), @sizeOf(AdapterInfo));
    const l = luidOf(vmbus.guid("12345678-9abc-def0-1122-334455667788"));
    try testing.expectEqual(@as(u32, 0x12345678), l.a);
    try testing.expectEqual(@as(u32, 0xdef09abc), l.b);
}

test "GPU-PV: the handshake against a played host (io space, adapter, process, PCI ids, device)" {
    var host = vmbus.testing.Host{};
    var mem_g: [4 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var mem_v: [4 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    @memset(&mem_g, 0);
    @memset(&mem_v, 0);
    var g = Gpu(vmbus.testing.Host){
        .global = vmbus.testing.channel(vmbus.testing.Host, &host, &mem_g, 2),
        .vgpu = vmbus.testing.channel(vmbus.testing.Host, &host, &mem_v, 2),
    };
    var play = Play{ .g = &g };
    host.answer = Play.answer;
    host.ctx = &play;
    try g.start(0xf_e000_0000, 64 << 20, "galaxy");
    try testing.expectEqual(@as(u32, 6), play.step);
    try testing.expectEqual(@as(u32, 0x4000_0000), g.adapter);
    try testing.expectEqual(@as(u32, 0x8000_0001), g.process);
    try testing.expectEqual(@as(u32, 0x1e07), g.pci[1]);
    try testing.expectEqual(@as(u32, 0x4000_0040), g.device);
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("NVIDIA GeForce RTX 2080 Ti", g.description(&b));
}

test "GPU-PV: memory, a context and work against a played host" {
    var host = vmbus.testing.Host{};
    var mem_g: [4 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var mem_v: [4 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    @memset(&mem_g, 0);
    @memset(&mem_v, 0);
    var g = Gpu(vmbus.testing.Host){
        .global = vmbus.testing.channel(vmbus.testing.Host, &host, &mem_g, 2),
        .vgpu = vmbus.testing.channel(vmbus.testing.Host, &host, &mem_v, 2),
    };
    var play = Play{ .g = &g };
    host.answer = Play.answer;
    host.ctx = &play;
    try g.start(0, 0, "galaxy");

    const pq = try g.createPagingQueue();
    try testing.expectEqual(@as(u32, 0x11), pq.handle);
    try testing.expectEqual(@as(u64, 0xf_e000_1000), pq.fence_page);
    var priv: [16]u8 = @splat(0xab);
    const a = try g.createAllocation(&priv, ALLOC_CREATE_RESOURCE | ALLOC_EXISTING_SYSMEM);
    try testing.expectEqual(@as(u32, 0x22), a.handle);
    try testing.expectEqual(@as(u32, 0x21), a.resource);
    try g.setSysmemStore(a.handle, 0xe1e20);
    try testing.expectEqual(@as(u32, 0xe1e20), play.gpadl);
    try testing.expectEqual(@as(u64, 5), try g.makeResident(pq.handle, a.handle));
    try testing.expectEqual(@as(u64, 0x2_0000_0000), try g.reserveVa(0x2_0000_0000, 64 << 20));
    const m = try g.mapVa(pq.handle, a.handle, 0x2_0000_0000, 0x500_0000, 0xffff_ffff_ffff_0000, 16);
    try testing.expectEqual(@as(u64, 0x2_0000_0000), m.va);
    try testing.expectEqual(@as(u64, 6), m.paging_fence);
    const ctx = try g.createContext(0, 4, 5, &priv);
    try testing.expectEqual(@as(u32, 0x31), ctx);
    // (the C struct's size less its one-byte array, plus the data; the
    // ring's packet pads it to 8)
    try testing.expectEqual(@as(usize, (@sizeOf(CreateContext) - 1 + priv.len + 7) & ~@as(usize, 7)), play.context_bytes);
    try g.waitFromGpu(ctx, pq.sync_object, 6);
    try testing.expectEqual(@as(u64, 6), play.waited);
    try testing.expectEqual(@as(u32, 0x12), play.wait_object);
    try g.submit(ctx, 1, 16, &priv);
    try testing.expectEqual(@as(u32, 16), play.submit_bytes);
    try testing.expectEqualSlices(u8, &priv, &play.submitted);
    try testing.expect(!g.signaled(0x6a1a));
    try g.waitFromCpu(pq.sync_object, 6, 0x6a1a);
    try testing.expect(g.signaled(0x6a1a));
    try testing.expect(!g.signaled(0x6a1a));
    const st = try g.deviceState(DEVICESTATE_EXECUTION);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, st[0..4], .little));
}
