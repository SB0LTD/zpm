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
    escape = 13,
    open_adapter = 14,
    close_adapter = 15,
    free_gpu_va = 16,
    map_gpu_va = 17,
    reserve_gpu_va = 18,
    submit_command = 20,
    get_device_state = 28,
    get_internal_adapter_info = 36,
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

comptime {
    // (the C layouts' sizes: natural alignment, no packing)
    if (@sizeOf(VmToHost) != 24 or @sizeOf(VgpuToHost) != 24 or @sizeOf(ExtHeader) != 16) @compileError("gpu: header sizes");
    if (@sizeOf(CreateProcess) != 568 or @offsetOf(CreateProcess, "process_name") != 40 or @offsetOf(CreateProcess, "kind") != 562) @compileError("gpu: create_process");
    if (@sizeOf(SetIoSpaceRegion) != 48 or @sizeOf(OpenAdapter) != 40 or @sizeOf(OpenAdapterReturn) != 16) @compileError("gpu: io space, open adapter");
    if (@sizeOf(AdapterInfo) != 712 or @offsetOf(AdapterInfo, "device_description") != 24) @compileError("gpu: adapter info");
    if (@sizeOf(QueryAdapterInfo) != 32 or @sizeOf(CreateDevice) != 40) @compileError("gpu: query, device");
}

pub const Error = error{
    /// The host did not answer in time (or the ring was full).
    NoAnswer,
    /// The host answered with a failure (its NTSTATUS in `Gpu.status`).
    Refused,
    /// The reply was shorter than its kind.
    ShortReply,
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
        /// The step `start` stopped at.
        failed: ?Step = null,
        rx: [8192]u8 align(8) = undefined,
        tx: [4096]u8 align(8) = undefined,

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
            const id = ch.send(self.frame(bytes), true) orelse return error.NoAnswer;
            var waited: u32 = 0;
            while (waited < TIMEOUT_US) {
                while (ch.receive(&self.rx)) |p| {
                    if (p.kind == vmbus.pkt.COMPLETION and p.id == id) return p.body;
                    // (the host's own messages, guest events and data on the
                    // global channel: nothing here waits for them)
                }
                ch.host.delayUs(20);
                waited += 20;
            }
            return error.NoAnswer;
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
            if (io_len != 0) {
                self.failed = .io_space;
                const m = SetIoSpaceRegion{ .start = io_start, .length = io_len };
                try self.ntstatus(try self.call(&self.global, std.mem.asBytes(&m)));
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
            var cp = CreateProcess{ .process = 1, .process_id = 1 };
            for (name[0..@min(name.len, PROCESS_NAME_LENGTH)], 0..) |c, i| cp.process_name[i] = c;
            const p = try reply(CreateProcessReturn, try self.call(&self.global, std.mem.asBytes(&cp)));
            if (p.hprocess == 0) return error.Refused;
            self.process = p.hprocess;

            self.failed = .query_pci;
            var q: [@sizeOf(QueryAdapterInfo) + 32]u8 align(8) = @splat(0);
            const qh = QueryAdapterInfo{ .hdr = .{ .process = self.process, .command_type = @intFromEnum(Command.query_adapter_info) }, .query_type = QUERY_PCI_IDS, .private_data_size = 32 };
            @memcpy(q[0..@sizeOf(QueryAdapterInfo)], std.mem.asBytes(&qh));
            const qr = try self.call(self.adapterChannel(), &q);
            try self.ntstatus(qr);
            if (qr.len < 4 + 32) return error.ShortReply;
            for (&self.pci, 0..) |*w, i| w.* = std.mem.readInt(u32, qr[4 + 4 * i ..][0..4], .little);

            self.failed = .create_device;
            const cd = CreateDevice{ .hdr = .{ .process = self.process, .command_type = @intFromEnum(Command.create_device) } };
            const d = try reply(CreateDeviceReturn, try self.call(self.adapterChannel(), std.mem.asBytes(&cd)));
            if (d.device == 0) return error.Refused;
            self.device = d.device;
            self.failed = null;
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

// ── Tests: the handshake against a host the test plays ──────────────────────

const testing = std.testing;

const Play = struct {
    g: *Gpu(vmbus.testing.Host),
    step: u32 = 0,

    fn answer(ctx: *anyopaque) void {
        const s: *Play = @ptrCast(@alignCast(ctx));
        var buf: [1024]u8 align(8) = undefined;
        // the guest's newest message: on the vGPU channel or the global one
        for ([_]*vmbus.Channel(vmbus.testing.Host){ &s.g.vgpu, &s.g.global }) |ch| {
            const n = ch.out.read(&buf) orelse continue;
            const id = std.mem.readInt(u64, buf[8..16], .little);
            const body = buf[16..n];
            const cmd = std.mem.readInt(u32, body[16..20], .little);
            var r: [800]u8 align(8) = @splat(0);
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
                    std.mem.writeInt(u32, r[8..12], 0x10de, .little);
                    std.mem.writeInt(u32, r[12..16], 0x1e07, .little);
                    len = 36;
                },
                @intFromEnum(Command.create_device) => std.mem.writeInt(u32, r[0..4], 0x4000_0040, .little),
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
    try testing.expectEqual(@as(u32, 0x1e07), g.pci[2]);
    try testing.expectEqual(@as(u32, 0x4000_0040), g.device);
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("NVIDIA GeForce RTX 2080 Ti", g.description(&b));
}
