//! Galaxy's Vulkan driver (src/vk) with a Host and a Wayland client, as
//! libvulkan_galaxy.so has them on Galaxy: what Firefox's WebGPU does to
//! hand a canvas to WebRender (gfx/wgpu_bindings/src/server.rs, Firefox
//! 151: wgpu_vkimage_create_with_dma_buf, wgpu_vkimage_get_file_descriptor,
//! wgpu_vksemaphore_create_signal_semaphore and _get_file_descriptor),
//! step by step through the entry points; and a swapchain on a fake
//! Wayland compositor that answers as Galaxy's bridge does (the same as
//! gfxapi's EGL tests: zwp_linux_dmabuf_v1 version 4's feedback with
//! linear ARGB8888 and XRGB8888, create_immed, a buffer released when the
//! next one is shown, frame callbacks answered at the next dispatch).
//!
//! The GPU is KIR's interpreter (EmuDevice, unified memory); a dma-buf fd
//! is 200 + an EmuDevice buffer's handle, and importing one maps that
//! buffer's bytes again (as the kernel's PRIME import maps the same pages).

const std = @import("std");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const vk = @import("vk");
const abi = vk.abi;
const icd = vk.icd;
const wl = gfxapi.wayland;
const kir = gpu.kir;
const ST = abi.StructureType;
const R = abi.result;
const testing = std.testing;
const EH = abi.ExternalHandle;

// ── The fake compositor ────────────────────────────────────────────────────

var display_iface = wl.Interface{ .name = "wl_display", .version = 1, .method_count = 0, .methods = null, .event_count = 0, .events = null };
var registry_iface = wl.Interface{ .name = "wl_registry", .version = 1, .method_count = 0, .methods = null, .event_count = 0, .events = null };
var buffer_iface = wl.Interface{ .name = "wl_buffer", .version = 1, .method_count = 0, .methods = null, .event_count = 0, .events = null };
var callback_iface = wl.Interface{ .name = "wl_callback", .version = 1, .method_count = 0, .methods = null, .event_count = 0, .events = null };
var surface_iface = wl.Interface{ .name = "wl_surface", .version = 6, .method_count = 0, .methods = null, .event_count = 0, .events = null };

/// A proxy: its interface first, as a wl_display's is.
const P = extern struct {
    iface: ?*const wl.Interface = null,
    version: u32 = 0,
    used: bool = false,
    disp: ?wl.Dispatcher = null,
    impl: ?*const anyopaque = null,
    queue: ?*wl.Queue = null,
    of: ?*P = null,
    w: i32 = 0,
    h: i32 = 0,
    format: u32 = 0,
    fd: i32 = -1,
    stride: u32 = 0,
    modifier: u64 = 0,
};

const Event = struct { p: *P, opcode: u32, args: [4]wl.Arg, later: bool };

const Fake = struct {
    var proxies: [64]P = undefined;
    var events: [64]Event = undefined;
    var n_events: usize = 0;
    var queue_mark: u8 = 0;
    var queues: u32 = 0;
    var commits: u32 = 0;
    var frames: u32 = 0;
    var flushes: u32 = 0;
    var attached: ?*P = null;
    var shown: ?*P = null;
    var buffers_made: u32 = 0;
    var buffers_destroyed: u32 = 0;
    var closes: u32 = 0;
    var last_closed: i32 = -1;
    var fence_fds: u32 = 0;
    var polls: u32 = 0;
    var imports: u32 = 0;

    const TABLE_FD: i32 = 55;
    var table: [32]u8 = undefined;
    var idx = [2]u16{ 0, 1 };
    var idx_array = wl.Array{ .size = 4, .alloc = 4, .data = &idx };

    fn reset() void {
        for (&proxies) |*p| p.* = .{};
        n_events = 0;
        queues = 0;
        commits = 0;
        frames = 0;
        flushes = 0;
        attached = null;
        shown = null;
        buffers_made = 0;
        buffers_destroyed = 0;
        closes = 0;
        last_closed = -1;
        fence_fds = 0;
        polls = 0;
        imports = 0;
        @memset(&table, 0);
        std.mem.writeInt(u32, table[0..4], wl.DRM_FORMAT_ARGB8888, .little);
        std.mem.writeInt(u32, table[16..20], wl.DRM_FORMAT_XRGB8888, .little);
    }

    fn new(iface: ?*const wl.Interface, version: u32, queue: ?*wl.Queue) *P {
        for (&proxies) |*p| {
            if (!p.used) {
                p.* = .{ .iface = iface, .version = version, .used = true, .queue = queue };
                return p;
            }
        }
        @panic("fake compositor: out of proxies");
    }

    fn live() usize {
        var n: usize = 0;
        for (&proxies) |*p| n += @intFromBool(p.used);
        return n;
    }

    fn of(p: *wl.Proxy) *P {
        const x: *P = @ptrCast(@alignCast(p));
        return x.of orelse x;
    }

    fn post(p: *P, opcode: u32, args: [4]wl.Arg, later: bool) void {
        events[n_events] = .{ .p = p, .opcode = opcode, .args = args, .later = later };
        n_events += 1;
    }

    fn deliver(all: bool) c_int {
        var n: c_int = 0;
        var keep: usize = 0;
        var i: usize = 0;
        const end = n_events;
        while (i < end) : (i += 1) {
            var e = events[i];
            if (e.later and !all) {
                events[keep] = e;
                keep += 1;
                continue;
            }
            if (!e.p.used) continue;
            if (e.p.disp) |d| _ = d(e.p.impl, e.p, e.opcode, null, &e.args);
            n += 1;
        }
        std.mem.copyForwards(Event, events[keep .. keep + (n_events - end)], events[end..n_events]);
        n_events = keep + (n_events - end);
        return n;
    }

    fn createQueue(_: *wl.Proxy) callconv(.c) ?*wl.Queue {
        queues += 1;
        return @ptrCast(&queue_mark);
    }
    fn queueDestroy(_: *wl.Queue) callconv(.c) void {
        queues -= 1;
    }
    fn createWrapper(p: *wl.Proxy) callconv(.c) ?*wl.Proxy {
        const o = of(p);
        const x = new(o.iface, o.version, null);
        x.of = o;
        return @ptrCast(x);
    }
    fn wrapperDestroy(p: *wl.Proxy) callconv(.c) void {
        const x: *P = @ptrCast(@alignCast(p));
        x.used = false;
    }
    fn setQueue(p: *wl.Proxy, q: ?*wl.Queue) callconv(.c) void {
        const x: *P = @ptrCast(@alignCast(p));
        x.queue = q;
    }
    fn addDispatcher(p: *wl.Proxy, f: wl.Dispatcher, impl: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const x: *P = @ptrCast(@alignCast(p));
        x.disp = f;
        x.impl = impl;
        return 0;
    }
    fn destroy(p: *wl.Proxy) callconv(.c) void {
        const x: *P = @ptrCast(@alignCast(p));
        x.used = false;
    }
    fn getVersion(p: *wl.Proxy) callconv(.c) u32 {
        const x: *P = @ptrCast(@alignCast(p));
        return x.version;
    }
    fn roundtrip(_: *wl.Proxy, _: *wl.Queue) callconv(.c) c_int {
        return deliver(true);
    }
    fn dispatch(_: *wl.Proxy, _: *wl.Queue) callconv(.c) c_int {
        if (n_events == 0) return -1;
        return deliver(true);
    }
    fn dispatchPending(_: *wl.Proxy, _: *wl.Queue) callconv(.c) c_int {
        return deliver(false);
    }
    fn flush(_: *wl.Proxy) callconv(.c) c_int {
        flushes += 1;
        return 0;
    }
    fn marshalCtor(p: *wl.Proxy, opcode: u32, args: [*]wl.Arg, iface: *const wl.Interface, version: u32) callconv(.c) ?*wl.Proxy {
        return marshalFlags(p, opcode, iface, version, 0, args);
    }
    fn marshal(p: *wl.Proxy, opcode: u32, args: [*]wl.Arg) callconv(.c) void {
        _ = marshalFlags(p, opcode, null, 0, 0, args);
    }

    fn marshalFlags(pp: *wl.Proxy, opcode: u32, iface: ?*const wl.Interface, version: u32, flags: u32, args: [*]wl.Arg) callconv(.c) ?*wl.Proxy {
        const wrapper: *P = @ptrCast(@alignCast(pp));
        const p = of(pp);
        var out: ?*P = null;
        if (iface) |i| out = new(i, version, wrapper.queue);
        const none = [4]wl.Arg{ .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } };
        if (p.iface == &display_iface and opcode == 1) { // get_registry
            post(out.?, 0, .{ .{ .u = 9 }, .{ .s = "zwp_linux_dmabuf_v1" }, .{ .u = 4 }, .{ .u = 0 } }, false);
        } else if (p.iface == &wl.dmabuf_interface and opcode == 2) { // get_default_feedback
            const f = out.?;
            post(f, 1, .{ .{ .h = TABLE_FD }, .{ .u = table.len }, .{ .u = 0 }, .{ .u = 0 } }, false);
            post(f, 5, .{ .{ .a = &idx_array }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } }, false);
            post(f, 3, none, false);
            post(f, 0, none, false);
        } else if (p.iface == &wl.params_interface) {
            switch (opcode) {
                1 => { // add
                    p.fd = args[0].h;
                    p.stride = args[3].u;
                    p.modifier = @as(u64, args[4].u) << 32 | args[5].u;
                },
                3 => { // create_immed
                    const b = out.?;
                    b.w = args[1].i;
                    b.h = args[2].i;
                    b.format = args[3].u;
                    b.fd = p.fd;
                    b.stride = p.stride;
                    b.modifier = p.modifier;
                    buffers_made += 1;
                },
                else => {},
            }
        } else if (p.iface == &buffer_iface and opcode == 0) {
            buffers_destroyed += 1;
        } else if (p.iface == &surface_iface) {
            switch (opcode) {
                1 => attached = @ptrCast(@alignCast(args[0].o)),
                3 => {
                    frames += 1;
                    post(out.?, 0, .{ .{ .u = 1000 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } }, true);
                },
                6 => {
                    commits += 1;
                    if (shown) |old| {
                        if (old != attached) post(old, 0, none, false);
                    }
                    shown = attached;
                },
                else => {},
            }
        }
        if (flags & wl.DESTROY != 0) p.used = false;
        return @ptrCast(out);
    }

    const client = wl.Client{
        .create_queue = createQueue,
        .queue_destroy = queueDestroy,
        .create_wrapper = createWrapper,
        .wrapper_destroy = wrapperDestroy,
        .set_queue = setQueue,
        .marshal_flags = marshalFlags,
        .marshal_ctor = marshalCtor,
        .marshal = marshal,
        .add_dispatcher = addDispatcher,
        .destroy = destroy,
        .get_version = getVersion,
        .roundtrip_queue = roundtrip,
        .dispatch_queue = dispatch,
        .dispatch_pending = dispatchPending,
        .flush = flush,
        .display_interface = &display_iface,
        .registry_interface = &registry_iface,
        .buffer_interface = &buffer_iface,
        .callback_interface = &callback_iface,
        .surface_interface = &surface_iface,
    };
};

// ── The GPU and the Host ───────────────────────────────────────────────────

const D = struct {
    var emu_mem: [32 << 20]u8 align(4096) = undefined;
    var emu_work: [16 << 20]u8 align(64) = undefined;
    var emu: gpu.EmuDevice = undefined;
    var work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined;
};

fn compileAny(k: *const kir.Kernel, caps: gpu.Caps, work: *gpu.Work, out: []u8) anyerror!gpu.Binary {
    return gpu.compile(k, caps, work, out);
}

fn exportFd(_: ?*anyopaque, b: gpu.Buffer) i64 {
    return 200 + @as(i64, b.handle);
}
fn importFd(_: ?*anyopaque, fd: i32) ?gpu.Buffer {
    if (fd < 201 or fd - 201 >= D.emu.n_regions) return null;
    const rg = &D.emu.regions[@intCast(fd - 201)];
    if (!rg.live or rg.cpu.len == 0) return null;
    Fake.imports += 1;
    return D.emu.device().import(rg.cpu);
}
fn fenceFd(_: ?*anyopaque) i64 {
    Fake.fence_fds += 1;
    return 400 + @as(i64, Fake.fence_fds);
}
fn closeFd(_: ?*anyopaque, fd: i32) void {
    Fake.last_closed = fd;
    Fake.closes += 1;
}
fn dupFd(_: ?*anyopaque, fd: i32) i32 {
    return fd + 1000;
}
fn pollFd(_: ?*anyopaque, _: i32, _: i32) i32 {
    Fake.polls += 1;
    return 1;
}
fn mapFd(_: ?*anyopaque, fd: i32, size: usize) ?[]const u8 {
    if (fd != Fake.TABLE_FD or size > Fake.table.len) return null;
    return Fake.table[0..size];
}
fn unmapFd(_: ?*anyopaque, _: []const u8) void {}
const host = gfxapi.host.Host{ .exportFd = exportFd, .importFd = importFd, .fenceFd = fenceFd, .close = closeFd, .dup = dupFd, .poll = pollFd, .map = mapFd, .unmap = unmapFd };
fn client() ?*const wl.Client {
    return &Fake.client;
}

fn openHosted() ?icd.Gpu {
    D.emu = gpu.EmuDevice.init(gpu.interp_caps, &D.emu_mem, &D.emu_work);
    return .{ .dev = D.emu.device(), .compile = compileAny, .work = &D.work, .host = host, .wayland = client };
}

fn logTo(msg: []const u8) void {
    std.debug.print("driver: {s}\n", .{msg});
}

// ── Entry points ───────────────────────────────────────────────────────────

const Ptr = ?*anyopaque;
const H = u64;
const Res = i32;

fn get(inst: Ptr, comptime name: [:0]const u8, comptime Fp: type) Fp {
    const f = icd.getInstanceProcAddr(inst, name) orelse @panic("no entry point " ++ name);
    return @ptrCast(f);
}

/// An instance, its physical device, a device with `exts` and its queue.
const Setup = struct {
    inst: Ptr = null,
    pd: Ptr = null,
    dev: Ptr = null,
    q: Ptr = null,
    pool: H = 0,

    fn init(s: *Setup, exts: []const ?[*:0]const u8) !void {
        icd.reset();
        icd.opener = &openHosted;
        icd.log_fn = &logTo;
        Fake.reset();
        const iexts = [_]?[*:0]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface", "VK_KHR_get_physical_device_properties2", "VK_KHR_external_memory_capabilities", "VK_KHR_external_semaphore_capabilities" };
        const ici = abi.InstanceCreateInfo{ .sType = ST.instance_create_info, .pNext = null, .flags = 0, .pApplicationInfo = null, .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = iexts.len, .ppEnabledExtensionNames = &iexts };
        try testing.expectEqual(R.success, get(null, "vkCreateInstance", *const fn (*const abi.InstanceCreateInfo, ?*const anyopaque, *Ptr) callconv(.c) Res)(&ici, null, &s.inst));
        var n: u32 = 1;
        var phys: [1]Ptr = undefined;
        try testing.expectEqual(R.success, get(s.inst, "vkEnumeratePhysicalDevices", *const fn (Ptr, *u32, ?[*]Ptr) callconv(.c) Res)(s.inst, &n, &phys));
        s.pd = phys[0];
        const prio = [_]f32{1.0};
        const qci = abi.DeviceQueueCreateInfo{ .sType = ST.device_queue_create_info, .pNext = null, .flags = 0, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
        const dci = abi.DeviceCreateInfo{ .sType = ST.device_create_info, .pNext = null, .flags = 0, .queueCreateInfoCount = 1, .pQueueCreateInfos = @ptrCast(&qci), .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = @intCast(exts.len), .ppEnabledExtensionNames = exts.ptr, .pEnabledFeatures = null };
        try testing.expectEqual(R.success, get(s.inst, "vkCreateDevice", *const fn (Ptr, *const abi.DeviceCreateInfo, ?*const anyopaque, *Ptr) callconv(.c) Res)(s.pd, &dci, null, &s.dev));
        get(s.inst, "vkGetDeviceQueue", *const fn (Ptr, u32, u32, *Ptr) callconv(.c) void)(s.dev, 0, 0, &s.q);
        const cpi = abi.CommandPoolCreateInfo{ .sType = ST.command_pool_create_info, .pNext = null, .flags = 2, .queueFamilyIndex = 0 };
        try testing.expectEqual(R.success, get(s.inst, "vkCreateCommandPool", *const fn (Ptr, *const abi.CommandPoolCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(s.dev, &cpi, null, &s.pool));
    }

    fn deinit(s: *Setup) void {
        get(s.inst, "vkDestroyCommandPool", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(s.dev, s.pool, null);
        get(s.inst, "vkDestroyDevice", *const fn (Ptr, ?*const anyopaque) callconv(.c) void)(s.dev, null);
        get(s.inst, "vkDestroyInstance", *const fn (Ptr, ?*const anyopaque) callconv(.c) void)(s.inst, null);
    }

    /// Image `img` cleared to `rgba` (float) on the GPU, submitted with
    /// `signal` (0: none) and `fence` (0: none).
    fn clear(s: *Setup, img: H, rgba: [4]f32, signal: H, fence: H) !void {
        const cbai = abi.CommandBufferAllocateInfo{ .sType = ST.command_buffer_allocate_info, .pNext = null, .commandPool = s.pool, .level = 0, .commandBufferCount = 1 };
        var cb: [1]Ptr = undefined;
        try testing.expectEqual(R.success, get(s.inst, "vkAllocateCommandBuffers", *const fn (Ptr, *const abi.CommandBufferAllocateInfo, [*]Ptr) callconv(.c) Res)(s.dev, &cbai, &cb));
        const bi = abi.CommandBufferBeginInfo{ .sType = ST.command_buffer_begin_info, .pNext = null, .flags = 1, .pInheritanceInfo = null };
        try testing.expectEqual(R.success, get(s.inst, "vkBeginCommandBuffer", *const fn (Ptr, *const abi.CommandBufferBeginInfo) callconv(.c) Res)(cb[0], &bi));
        const color = abi.ClearColorValue{ .float32 = rgba };
        const range = abi.ImageSubresourceRange{ .aspectMask = 1, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        get(s.inst, "vkCmdClearColorImage", *const fn (Ptr, H, u32, *const abi.ClearColorValue, u32, [*]const abi.ImageSubresourceRange) callconv(.c) void)(cb[0], img, 7, &color, 1, @ptrCast(&range));
        try testing.expectEqual(R.success, get(s.inst, "vkEndCommandBuffer", *const fn (Ptr) callconv(.c) Res)(cb[0]));
        const sig = [_]H{signal};
        const si = abi.SubmitInfo{ .sType = ST.submit_info, .pNext = null, .waitSemaphoreCount = 0, .pWaitSemaphores = null, .pWaitDstStageMask = null, .commandBufferCount = 1, .pCommandBuffers = &cb, .signalSemaphoreCount = @intFromBool(signal != 0), .pSignalSemaphores = &sig };
        try testing.expectEqual(R.success, get(s.inst, "vkQueueSubmit", *const fn (Ptr, u32, [*]const abi.SubmitInfo, H) callconv(.c) Res)(s.q, 1, @ptrCast(&si), fence));
    }
};

fn semaphore(s: *Setup, exported: bool) !H {
    const esci = abi.ExportSemaphoreCreateInfo{ .sType = ST.export_semaphore_create_info, .pNext = null, .handleTypes = EH.opaque_fd };
    const sci = abi.SemaphoreCreateInfo{ .sType = ST.semaphore_create_info, .pNext = if (exported) @ptrCast(&esci) else null, .flags = 0 };
    var h: H = 0;
    try testing.expectEqual(R.success, get(s.inst, "vkCreateSemaphore", *const fn (Ptr, *const abi.SemaphoreCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(s.dev, &sci, null, &h));
    return h;
}

fn extNamed(list: []const abi.ExtensionProperties, name: []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, std.mem.sliceTo(&e.extensionName, 0), name)) return true;
    return false;
}

// ── Firefox's WebGPU canvas as a dma-buf ───────────────────────────────────

const firefox_exts = [_]?[*:0]const u8{ "VK_KHR_external_memory_fd", "VK_EXT_external_memory_dma_buf", "VK_EXT_image_drm_format_modifier", "VK_KHR_external_semaphore_fd", "VK_KHR_swapchain", "VK_KHR_image_format_list" };

test "vk: Firefox's WebGPU canvas: a linear BGRA8 image in exported memory, its dma-buf read where it is imported, the semaphore's fd" {
    var s = Setup{};
    try s.init(&firefox_exts);
    defer s.deinit();
    const inst = s.inst;
    const pd = s.pd;
    const dev = s.dev;

    // what server.rs checks before it enables the shared-texture swapchain
    var n: u32 = 32;
    var exts: [32]abi.ExtensionProperties = undefined;
    try testing.expectEqual(R.success, get(inst, "vkEnumerateDeviceExtensionProperties", *const fn (Ptr, ?[*:0]const u8, *u32, ?[*]abi.ExtensionProperties) callconv(.c) Res)(pd, null, &n, &exts));
    for (firefox_exts) |e| try testing.expect(extNamed(exts[0..n], std.mem.span(e.?)));
    const sem_info = abi.PhysicalDeviceExternalSemaphoreInfo{ .sType = ST.physical_device_external_semaphore_info, .pNext = null, .handleType = EH.opaque_fd };
    var sem_props = std.mem.zeroes(abi.ExternalSemaphoreProperties);
    get(inst, "vkGetPhysicalDeviceExternalSemaphoreProperties", *const fn (Ptr, *const abi.PhysicalDeviceExternalSemaphoreInfo, *abi.ExternalSemaphoreProperties) callconv(.c) void)(pd, &sem_info, &sem_props);
    try testing.expect(sem_props.externalSemaphoreFeatures & EH.exportable != 0);

    // wgpu_vkimage_create_with_dma_buf: B8G8R8A8_UNORM's modifiers (two calls)
    const fp2 = get(inst, "vkGetPhysicalDeviceFormatProperties2", *const fn (Ptr, u32, *abi.FormatProperties2) callconv(.c) void);
    var ml = abi.DrmFormatModifierPropertiesListEXT{ .sType = ST.drm_format_modifier_properties_list_ext, .pNext = null, .drmFormatModifierCount = 0, .pDrmFormatModifierProperties = null };
    var f2 = abi.FormatProperties2{ .sType = ST.format_properties_2, .pNext = &ml, .formatProperties = undefined };
    fp2(pd, 44, &f2);
    try testing.expectEqual(@as(u32, 1), ml.drmFormatModifierCount);
    var mods: [1]abi.DrmFormatModifierPropertiesEXT = undefined;
    ml.pDrmFormatModifierProperties = &mods;
    fp2(pd, 44, &f2);
    try testing.expectEqual(abi.DRM_MOD_LINEAR, mods[0].drmFormatModifier);
    try testing.expectEqual(@as(u32, 1), mods[0].drmFormatModifierPlaneCount);
    try testing.expect(mods[0].drmFormatModifierTilingFeatures & 0x80 != 0); // colour attachment

    // is_dmabuf_supported: the modifier, a dma-buf, a colour attachment
    const mod_info = abi.PhysicalDeviceImageDrmFormatModifierInfoEXT{ .sType = ST.physical_device_image_drm_format_modifier_info_ext, .pNext = null, .drmFormatModifier = abi.DRM_MOD_LINEAR, .sharingMode = 0, .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null };
    const ext_info = abi.PhysicalDeviceExternalImageFormatInfo{ .sType = ST.physical_device_external_image_format_info, .pNext = &mod_info, .handleType = EH.dma_buf };
    const ifi = abi.PhysicalDeviceImageFormatInfo2{ .sType = ST.physical_device_image_format_info_2, .pNext = &ext_info, .format = 44, .@"type" = 1, .tiling = abi.TILING_DRM_FORMAT_MODIFIER, .usage = 0x10, .flags = 0 };
    var eifp = std.mem.zeroes(abi.ExternalImageFormatProperties);
    eifp.sType = ST.external_image_format_properties;
    var ifp2 = abi.ImageFormatProperties2{ .sType = ST.image_format_properties_2, .pNext = &eifp, .imageFormatProperties = undefined };
    const ifp2f = get(inst, "vkGetPhysicalDeviceImageFormatProperties2", *const fn (Ptr, *const abi.PhysicalDeviceImageFormatInfo2, *abi.ImageFormatProperties2) callconv(.c) Res);
    try testing.expectEqual(R.success, ifp2f(pd, &ifi, &ifp2));
    try testing.expect(eifp.externalMemoryProperties.compatibleHandleTypes & EH.dma_buf != 0);
    try testing.expect(eifp.externalMemoryProperties.externalMemoryFeatures & EH.memory_exportable != 0);
    // (a tiled modifier is not had)
    var tiled = mod_info;
    tiled.drmFormatModifier = 0x0300_0000_0000_0014;
    var ext_tiled = ext_info;
    ext_tiled.pNext = &tiled;
    var ifi_tiled = ifi;
    ifi_tiled.pNext = &ext_tiled;
    try testing.expectEqual(R.error_format_not_supported, ifp2f(pd, &ifi_tiled, &ifp2));

    // the image: ALIAS, DRM-modifier tiling, the modifier list, external memory
    const W = 6;
    const HH = 3;
    const mods_list = [_]u64{abi.DRM_MOD_LINEAR};
    const mlci = abi.ImageDrmFormatModifierListCreateInfoEXT{ .sType = ST.image_drm_format_modifier_list_create_info_ext, .pNext = null, .drmFormatModifierCount = 1, .pDrmFormatModifiers = &mods_list };
    const emci = abi.ExternalMemoryCreateInfo{ .sType = ST.external_memory_image_create_info, .pNext = &mlci, .handleTypes = EH.dma_buf };
    const ici = abi.ImageCreateInfo{ .sType = ST.image_create_info, .pNext = &emci, .flags = 0x400, .imageType = 1, .format = 44, .extent = .{ .width = W, .height = HH, .depth = 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = 1, .tiling = abi.TILING_DRM_FORMAT_MODIFIER, .usage = 0x10 | 0x2, .sharingMode = 0, .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null, .initialLayout = 0 };
    var img: H = 0;
    try testing.expectEqual(R.success, get(inst, "vkCreateImage", *const fn (Ptr, *const abi.ImageCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(dev, &ici, null, &img));
    var mprops = abi.ImageDrmFormatModifierPropertiesEXT{ .sType = ST.image_drm_format_modifier_properties_ext, .pNext = null, .drmFormatModifier = 77 };
    try testing.expectEqual(R.success, get(inst, "vkGetImageDrmFormatModifierPropertiesEXT", *const fn (Ptr, H, *abi.ImageDrmFormatModifierPropertiesEXT) callconv(.c) Res)(dev, img, &mprops));
    try testing.expectEqual(abi.DRM_MOD_LINEAR, mprops.drmFormatModifier);

    // DEVICE_LOCAL memory, dedicated, for export
    var req: abi.MemoryRequirements = undefined;
    get(inst, "vkGetImageMemoryRequirements", *const fn (Ptr, H, *abi.MemoryRequirements) callconv(.c) void)(dev, img, &req);
    try testing.expect(req.size >= W * 4 * HH);
    var mp: abi.PhysicalDeviceMemoryProperties = undefined;
    get(inst, "vkGetPhysicalDeviceMemoryProperties", *const fn (Ptr, *abi.PhysicalDeviceMemoryProperties) callconv(.c) void)(pd, &mp);
    try testing.expect(mp.memoryTypes[0].propertyFlags & 1 != 0);
    const ema = abi.ExportMemoryAllocateInfo{ .sType = ST.export_memory_allocate_info, .pNext = null, .handleTypes = EH.dma_buf };
    const dai = abi.MemoryDedicatedAllocateInfo{ .sType = ST.memory_dedicated_allocate_info, .pNext = &ema, .image = img, .buffer = 0 };
    const mai = abi.MemoryAllocateInfo{ .sType = ST.memory_allocate_info, .pNext = &dai, .allocationSize = req.size, .memoryTypeIndex = 0 };
    const allocate = get(inst, "vkAllocateMemory", *const fn (Ptr, *const abi.MemoryAllocateInfo, ?*const anyopaque, *H) callconv(.c) Res);
    var mem: H = 0;
    try testing.expectEqual(R.success, allocate(dev, &mai, null, &mem));
    try testing.expectEqual(R.success, get(inst, "vkBindImageMemory", *const fn (Ptr, H, H, u64) callconv(.c) Res)(dev, img, mem, 0));

    // plane 0's layout (MEMORY_PLANE_0): offset 0, rows of 6 texels
    const sub = abi.ImageSubresource{ .aspectMask = 0x80, .mipLevel = 0, .arrayLayer = 0 };
    var lay: abi.SubresourceLayout = undefined;
    get(inst, "vkGetImageSubresourceLayout", *const fn (Ptr, H, *const abi.ImageSubresource, *abi.SubresourceLayout) callconv(.c) void)(dev, img, &sub, &lay);
    try testing.expectEqual(@as(u64, 0), lay.offset);
    try testing.expectEqual(@as(u64, W * 4), lay.rowPitch);

    // wgpu_vkimage_get_file_descriptor: the memory's dma-buf
    const gfd = abi.MemoryGetFdInfoKHR{ .sType = ST.memory_get_fd_info_khr, .pNext = null, .memory = mem, .handleType = EH.dma_buf };
    var fd: i32 = -1;
    try testing.expectEqual(R.success, get(inst, "vkGetMemoryFdKHR", *const fn (Ptr, *const abi.MemoryGetFdInfoKHR, *i32) callconv(.c) Res)(dev, &gfd, &fd));
    try testing.expect(fd > 200);
    var fdp = abi.MemoryFdPropertiesKHR{ .sType = ST.memory_fd_properties_khr, .pNext = null, .memoryTypeBits = 0 };
    try testing.expectEqual(R.success, get(inst, "vkGetMemoryFdPropertiesKHR", *const fn (Ptr, u32, i32, *abi.MemoryFdPropertiesKHR) callconv(.c) Res)(dev, EH.dma_buf, fd, &fdp));
    try testing.expect(fdp.memoryTypeBits & 1 != 0);

    // the other side (WebRender, here this device again) imports the
    // dma-buf as host-visible memory: the fd is the driver's then
    const imfd = abi.ImportMemoryFdInfoKHR{ .sType = ST.import_memory_fd_info_khr, .pNext = null, .handleType = EH.dma_buf, .fd = fd };
    const imai = abi.MemoryAllocateInfo{ .sType = ST.memory_allocate_info, .pNext = &imfd, .allocationSize = W * 4 * HH, .memoryTypeIndex = 0 };
    var imported: H = 0;
    try testing.expectEqual(R.success, allocate(dev, &imai, null, &imported));
    try testing.expectEqual(@as(u32, 1), Fake.imports);
    try testing.expectEqual(fd, Fake.last_closed);
    var bad = imfd;
    bad.fd = 199;
    var nothing: H = 0;
    var bad_ai = imai;
    bad_ai.pNext = &bad;
    try testing.expectEqual(R.error_invalid_external_handle, allocate(dev, &bad_ai, null, &nothing));

    // wgpu_vksemaphore_create_signal_semaphore: an exportable one, signaled
    // by the submission that draws the canvas (here a clear), its fd taken
    const sem = try semaphore(&s, true);
    const sgfd = abi.SemaphoreGetFdInfoKHR{ .sType = ST.semaphore_get_fd_info_khr, .pNext = null, .semaphore = sem, .handleType = EH.opaque_fd };
    var sfd: i32 = -1;
    try testing.expectEqual(R.success, get(inst, "vkGetSemaphoreFdKHR", *const fn (Ptr, *const abi.SemaphoreGetFdInfoKHR, *i32) callconv(.c) Res)(dev, &sgfd, &sfd));
    try testing.expectEqual(@as(i32, 401), sfd);
    try s.clear(img, .{ 1.0, 0.5, 0.0, 1.0 }, sem, 0);

    // the submission that signals an exported semaphore is done when
    // vkQueueSubmit returns: the imported memory has the pixels (BGRA)
    var p: ?*anyopaque = null;
    try testing.expectEqual(R.success, get(inst, "vkMapMemory", *const fn (Ptr, H, u64, u64, u32, *?*anyopaque) callconv(.c) Res)(dev, imported, 0, ~@as(u64, 0), 0, &p));
    const px: [*]const u8 = @ptrCast(p.?);
    for (0..W * HH) |i| {
        try testing.expectEqual(@as(u8, 0), px[i * 4 + 0]);
        try testing.expect(px[i * 4 + 1] == 127 or px[i * 4 + 1] == 128);
        try testing.expectEqual(@as(u8, 255), px[i * 4 + 2]);
        try testing.expectEqual(@as(u8, 255), px[i * 4 + 3]);
    }
    get(inst, "vkUnmapMemory", *const fn (Ptr, H) callconv(.c) void)(dev, imported);

    // an explicit layout must be the one the driver keeps
    const wrong = abi.SubresourceLayout{ .offset = 0, .size = 0, .rowPitch = 64, .arrayPitch = 0, .depthPitch = 0 };
    const xci = abi.ImageDrmFormatModifierExplicitCreateInfoEXT{ .sType = ST.image_drm_format_modifier_explicit_create_info_ext, .pNext = null, .drmFormatModifier = abi.DRM_MOD_LINEAR, .drmFormatModifierPlaneCount = 1, .pPlaneLayouts = @ptrCast(&wrong) };
    var xici = ici;
    xici.pNext = &xci;
    var ximg: H = 0;
    try testing.expectEqual(R.error_invalid_drm_format_modifier_plane_layout_ext, get(inst, "vkCreateImage", *const fn (Ptr, *const abi.ImageCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(dev, &xici, null, &ximg));

    const free = get(inst, "vkFreeMemory", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void);
    get(inst, "vkDestroySemaphore", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(dev, sem, null);
    get(inst, "vkDestroyImage", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(dev, img, null);
    free(dev, imported, null);
    free(dev, mem, null);
}

// ── A swapchain on Wayland ─────────────────────────────────────────────────

test "vk: a swapchain on a Wayland surface: dma-buf wl_buffers, acquire, present (FIFO), released buffers reused" {
    var s = Setup{};
    const exts = [_]?[*:0]const u8{"VK_KHR_swapchain"};
    try s.init(&exts);
    defer s.deinit();
    const inst = s.inst;
    const pd = s.pd;
    const dev = s.dev;

    const native_display = Fake.new(&display_iface, 1, null);
    const native_surface = Fake.new(&surface_iface, 6, null);
    // (the loader's VkIcdSurfaceWayland)
    var surf = abi.IcdSurfaceWayland{ .platform = abi.ICD_WSI_PLATFORM_WAYLAND, .display = native_display, .surface = native_surface };
    const surface: H = @intFromPtr(&surf);

    var ok: u32 = 0;
    try testing.expectEqual(R.success, get(inst, "vkGetPhysicalDeviceSurfaceSupportKHR", *const fn (Ptr, u32, H, *u32) callconv(.c) Res)(pd, 0, surface, &ok));
    try testing.expectEqual(@as(u32, 1), ok);
    try testing.expectEqual(@as(u32, 1), get(inst, "vkGetPhysicalDeviceWaylandPresentationSupportKHR", *const fn (Ptr, u32, ?*anyopaque) callconv(.c) u32)(pd, 0, native_display));
    var caps: abi.SurfaceCapabilitiesKHR = undefined;
    try testing.expectEqual(R.success, get(inst, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR", *const fn (Ptr, H, *abi.SurfaceCapabilitiesKHR) callconv(.c) Res)(pd, surface, &caps));
    try testing.expectEqual(@as(u32, 0xffff_ffff), caps.currentExtent.width);
    try testing.expect(caps.minImageCount >= 2 and caps.maxImageCount >= 3);
    try testing.expect(caps.supportedUsageFlags & 0x10 != 0);
    var n: u32 = 4;
    var formats: [4]abi.SurfaceFormatKHR = undefined;
    try testing.expectEqual(R.success, get(inst, "vkGetPhysicalDeviceSurfaceFormatsKHR", *const fn (Ptr, H, *u32, ?[*]abi.SurfaceFormatKHR) callconv(.c) Res)(pd, surface, &n, &formats));
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expectEqual(@as(u32, 44), formats[0].format);
    var modes: [4]u32 = undefined;
    n = 4;
    try testing.expectEqual(R.success, get(inst, "vkGetPhysicalDeviceSurfacePresentModesKHR", *const fn (Ptr, H, *u32, ?[*]u32) callconv(.c) Res)(pd, surface, &n, &modes));
    try testing.expectEqual(@as(u32, 2), modes[0]); // FIFO

    // three images of 5x4, opaque
    const W = 5;
    const HH = 4;
    const sci = abi.SwapchainCreateInfoKHR{ .sType = ST.swapchain_create_info_khr, .pNext = null, .flags = 0, .surface = surface, .minImageCount = 3, .imageFormat = 44, .imageColorSpace = 0, .imageExtent = .{ .width = W, .height = HH }, .imageArrayLayers = 1, .imageUsage = 0x10 | 0x2, .imageSharingMode = 0, .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null, .preTransform = 1, .compositeAlpha = 1, .presentMode = 2, .clipped = 1, .oldSwapchain = 0 };
    var sc: H = 0;
    try testing.expectEqual(R.success, get(inst, "vkCreateSwapchainKHR", *const fn (Ptr, *const abi.SwapchainCreateInfoKHR, ?*const anyopaque, *H) callconv(.c) Res)(dev, &sci, null, &sc));
    try testing.expectEqual(@as(u32, 3), Fake.buffers_made);
    var imgs: [4]H = undefined;
    n = 4;
    try testing.expectEqual(R.success, get(inst, "vkGetSwapchainImagesKHR", *const fn (Ptr, H, *u32, ?[*]H) callconv(.c) Res)(dev, sc, &n, &imgs));
    try testing.expectEqual(@as(u32, 3), n);
    // each wl_buffer: a dma-buf, linear XRGB8888, rows of 5 texels
    var bufs: usize = 0;
    for (&Fake.proxies) |*p| {
        if (!p.used or p.iface != &buffer_iface) continue;
        bufs += 1;
        try testing.expectEqual(@as(i32, W), p.w);
        try testing.expectEqual(@as(i32, HH), p.h);
        try testing.expectEqual(wl.DRM_FORMAT_XRGB8888, p.format);
        try testing.expectEqual(@as(u32, W * 4), p.stride);
        try testing.expectEqual(@as(u64, 0), p.modifier);
        try testing.expect(p.fd > 200);
    }
    try testing.expectEqual(@as(usize, 3), bufs);

    const acquire = get(inst, "vkAcquireNextImageKHR", *const fn (Ptr, H, u64, H, H, *u32) callconv(.c) Res);
    const present = get(inst, "vkQueuePresentKHR", *const fn (Ptr, *const abi.PresentInfoKHR) callconv(.c) Res);
    const sem = try semaphore(&s, false);
    const done = try semaphore(&s, false);

    // frame 1: acquire, clear to blue, present
    var idx: u32 = 9;
    try testing.expectEqual(R.success, acquire(dev, sc, ~@as(u64, 0), sem, 0, &idx));
    try testing.expect(idx < 3);
    try s.clear(imgs[idx], .{ 0.0, 0.0, 1.0, 1.0 }, done, 0);
    const scs = [_]H{sc};
    var idxs = [_]u32{idx};
    const waits = [_]H{done};
    const pi = abi.PresentInfoKHR{ .sType = ST.present_info_khr, .pNext = null, .waitSemaphoreCount = 1, .pWaitSemaphores = &waits, .swapchainCount = 1, .pSwapchains = &scs, .pImageIndices = &idxs, .pResults = null };
    try testing.expectEqual(R.success, present(s.q, &pi));
    try testing.expectEqual(@as(u32, 1), Fake.commits);
    try testing.expectEqual(@as(u32, 1), Fake.frames);
    const first = Fake.shown.?;
    // the compositor's buffer has the pixels: B=255 first (BGRA)
    {
        const rg = &D.emu.regions[@intCast(first.fd - 201)];
        try testing.expectEqual(@as(u8, 255), rg.cpu[0]);
        try testing.expectEqual(@as(u8, 0), rg.cpu[2]);
        try testing.expectEqual(@as(u8, 255), rg.cpu[(W * HH - 1) * 4]);
    }

    // frame 2: another image (the first is the compositor's); FIFO waits
    // for frame 1's callback before it commits
    var idx2: u32 = 9;
    try testing.expectEqual(R.success, acquire(dev, sc, ~@as(u64, 0), sem, 0, &idx2));
    try testing.expect(idx2 != idx);
    try s.clear(imgs[idx2], .{ 1.0, 0.0, 0.0, 1.0 }, done, 0);
    idxs[0] = idx2;
    try testing.expectEqual(R.success, present(s.q, &pi));
    try testing.expectEqual(@as(u32, 2), Fake.commits);
    try testing.expect(Fake.shown.? != first);
    // (frame 1's buffer released at frame 2's commit: acquirable again)
    var seen = [_]bool{false} ** 3;
    for (0..2) |_| {
        var k: u32 = 9;
        try testing.expectEqual(R.success, acquire(dev, sc, 0, 0, 0, &k));
        seen[k] = true;
    }
    try testing.expect(seen[idx] and !seen[idx2]);
    // every image out now: with no time to wait, not ready
    var none: u32 = 9;
    try testing.expectEqual(R.not_ready, acquire(dev, sc, 0, 0, 0, &none));

    get(inst, "vkDestroySemaphore", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(dev, sem, null);
    get(inst, "vkDestroySemaphore", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(dev, done, null);
    get(inst, "vkDestroySwapchainKHR", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(dev, sc, null);
    try testing.expectEqual(@as(u32, 3), Fake.buffers_destroyed);
    try testing.expectEqual(@as(u32, 0), Fake.queues);
    // (left: the app's display and surface)
    try testing.expectEqual(@as(usize, 2), Fake.live());
}

test "vk: without a Host, no swapchain and no external memory are offered" {
    icd.reset();
    icd.opener = struct {
        fn open() ?icd.Gpu {
            D.emu = gpu.EmuDevice.init(gpu.interp_caps, &D.emu_mem, &D.emu_work);
            return .{ .dev = D.emu.device(), .compile = compileAny, .work = &D.work };
        }
    }.open;
    icd.log_fn = &logTo;
    const ici = abi.InstanceCreateInfo{ .sType = ST.instance_create_info, .pNext = null, .flags = 0, .pApplicationInfo = null, .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = 0, .ppEnabledExtensionNames = null };
    var inst: Ptr = null;
    try testing.expectEqual(R.success, get(null, "vkCreateInstance", *const fn (*const abi.InstanceCreateInfo, ?*const anyopaque, *Ptr) callconv(.c) Res)(&ici, null, &inst));
    defer get(inst, "vkDestroyInstance", *const fn (Ptr, ?*const anyopaque) callconv(.c) void)(inst, null);
    var n: u32 = 1;
    var phys: [1]Ptr = undefined;
    try testing.expectEqual(R.success, get(inst, "vkEnumeratePhysicalDevices", *const fn (Ptr, *u32, ?[*]Ptr) callconv(.c) Res)(inst, &n, &phys));
    var exts: [32]abi.ExtensionProperties = undefined;
    n = 32;
    try testing.expectEqual(R.success, get(inst, "vkEnumerateDeviceExtensionProperties", *const fn (Ptr, ?[*:0]const u8, *u32, ?[*]abi.ExtensionProperties) callconv(.c) Res)(phys[0], null, &n, &exts));
    try testing.expect(!extNamed(exts[0..n], "VK_KHR_swapchain"));
    try testing.expect(!extNamed(exts[0..n], "VK_KHR_external_memory_fd"));
    const sem_info = abi.PhysicalDeviceExternalSemaphoreInfo{ .sType = ST.physical_device_external_semaphore_info, .pNext = null, .handleType = EH.opaque_fd };
    var sem_props = std.mem.zeroes(abi.ExternalSemaphoreProperties);
    get(inst, "vkGetPhysicalDeviceExternalSemaphoreProperties", *const fn (Ptr, *const abi.PhysicalDeviceExternalSemaphoreInfo, *abi.ExternalSemaphoreProperties) callconv(.c) void)(phys[0], &sem_info, &sem_props);
    try testing.expectEqual(@as(u32, 0), sem_props.externalSemaphoreFeatures);
}
