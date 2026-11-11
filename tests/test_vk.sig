//! Galaxy's Vulkan driver (src/vk) through its C entry points, as the
//! loader reaches them (icd.getInstanceProcAddr, the library's
//! vk_icdGetInstanceProcAddr): what vulkaninfo asks, then compute work —
//! naga's SPIR-V for WGSL shaders (tests/data/vk) — on the emulated RTX
//! (sm_120 in sm120_emu, discrete memory) and on KIR's interpreter
//! (EmuDevice, unified memory), the results checked on the CPU.

const std = @import("std");
const gpu = @import("gpu");
const vk = @import("vk");
const nvidia = @import("nvidia");
const abi = vk.abi;
const icd = vk.icd;
const kir = gpu.kir;
const ST = abi.StructureType;
const R = abi.result;
const testing = std.testing;

// ── The devices a test gives the driver ────────────────────────────────────

const D = struct {
    var arena: [64 << 20]u8 align(4096) = undefined;
    var view: [64 << 20]u8 align(4096) = undefined;
    var rtx_work: nvidia.sm120_emu.Work = undefined;
    var rtx: gpu.nvidia_device.Emu = undefined;
    var emu_mem: [64 << 20]u8 align(4096) = undefined;
    var emu_work: [16 << 20]u8 align(64) = undefined;
    var emu: gpu.EmuDevice = undefined;
    var work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined;
    var log_buf: [4096]u8 = undefined;
    var log_len: usize = 0;
};

fn compileAny(k: *const kir.Kernel, caps: gpu.Caps, work: *gpu.Work, out: []u8) anyerror!gpu.Binary {
    return gpu.compile(k, caps, work, out);
}

fn openRtx() ?icd.Gpu {
    D.rtx.init(&D.arena, &D.view, &D.rtx_work);
    return .{ .dev = D.rtx.device(), .compile = compileAny, .work = &D.work };
}

fn openInterp() ?icd.Gpu {
    D.emu = gpu.EmuDevice.init(gpu.interp_caps, &D.emu_mem, &D.emu_work);
    return .{ .dev = D.emu.device(), .compile = compileAny, .work = &D.work };
}

fn openNone() ?icd.Gpu {
    return null;
}

fn logTo(msg: []const u8) void {
    std.debug.print("driver: {s}\n", .{msg});
    const n = @min(msg.len, D.log_buf.len - D.log_len);
    @memcpy(D.log_buf[D.log_len..][0..n], msg[0..n]);
    D.log_len += n;
}

fn use(open: *const fn () ?icd.Gpu) void {
    icd.reset();
    icd.opener = open;
    icd.log_fn = &logTo;
    D.log_len = 0;
}

// ── Entry points, as the loader gets them ──────────────────────────────────

const Ptr = ?*anyopaque;
const H = u64;

fn get(inst: Ptr, comptime name: [:0]const u8, comptime Fp: type) Fp {
    const f = icd.getInstanceProcAddr(inst, name) orelse @panic("no entry point " ++ name);
    return @ptrCast(f);
}

const Res = i32;

// ── vulkaninfo ─────────────────────────────────────────────────────────────

test "vk: what vulkaninfo asks, through the ICD's entry points, on the emulated RTX" {
    use(&openRtx);
    var ver: u32 = 7;
    try testing.expectEqual(R.success, icd.negotiate(&ver));
    try testing.expectEqual(@as(u32, 5), ver);

    var iv: u32 = 0;
    try testing.expectEqual(R.success, get(null, "vkEnumerateInstanceVersion", *const fn (*u32) callconv(.c) Res)(&iv));
    try testing.expectEqual(icd.makeVersion(1, 1, 0), iv);

    const enumInstExt = get(null, "vkEnumerateInstanceExtensionProperties", *const fn (?[*:0]const u8, *u32, ?[*]abi.ExtensionProperties) callconv(.c) Res);
    var n: u32 = 0;
    try testing.expectEqual(R.success, enumInstExt(null, &n, null));
    try testing.expectEqual(@as(u32, 1), n);
    var exts: [8]abi.ExtensionProperties = undefined;
    try testing.expectEqual(R.success, enumInstExt(null, &n, &exts));
    try testing.expectEqualStrings("VK_KHR_get_physical_device_properties2", std.mem.sliceTo(&exts[0].extensionName, 0));

    // an instance asking for a later version (allowed since interface 5), and an extension it does not have
    const createInstance = get(null, "vkCreateInstance", *const fn (*const abi.InstanceCreateInfo, ?*const anyopaque, *Ptr) callconv(.c) Res);
    const app = abi.ApplicationInfo{ .sType = ST.application_info, .pNext = null, .pApplicationName = "test", .applicationVersion = 1, .pEngineName = "wgpu", .engineVersion = 1, .apiVersion = icd.makeVersion(1, 3, 0) };
    const bad_ext = [_]?[*:0]const u8{"VK_KHR_surface"};
    var inst: Ptr = null;
    var ici = abi.InstanceCreateInfo{ .sType = ST.instance_create_info, .pNext = null, .flags = 0, .pApplicationInfo = @ptrCast(&app), .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = 1, .ppEnabledExtensionNames = &bad_ext };
    try testing.expectEqual(R.error_extension_not_present, createInstance(&ici, null, &inst));
    const good_ext = [_]?[*:0]const u8{"VK_KHR_get_physical_device_properties2"};
    ici.ppEnabledExtensionNames = &good_ext;
    try testing.expectEqual(R.success, createInstance(&ici, null, &inst));
    defer get(inst, "vkDestroyInstance", *const fn (Ptr, ?*const anyopaque) callconv(.c) void)(inst, null);

    // one physical device
    const enumPhys = get(inst, "vkEnumeratePhysicalDevices", *const fn (Ptr, *u32, ?[*]Ptr) callconv(.c) Res);
    try testing.expectEqual(R.success, enumPhys(inst, &n, null));
    try testing.expectEqual(@as(u32, 1), n);
    var phys: [2]Ptr = undefined;
    n = 2;
    try testing.expectEqual(R.success, enumPhys(inst, &n, &phys));
    try testing.expectEqual(@as(u32, 1), n);
    const pd = phys[0];

    var props: abi.PhysicalDeviceProperties = undefined;
    get(inst, "vkGetPhysicalDeviceProperties", *const fn (Ptr, *abi.PhysicalDeviceProperties) callconv(.c) void)(pd, &props);
    try testing.expectEqual(icd.makeVersion(1, 1, 0), props.apiVersion);
    try testing.expectEqual(@as(u32, 0x10de), props.vendorID);
    try testing.expectEqual(@as(u32, 2), props.deviceType); // discrete
    try testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&props.deviceName, 0), "emulated RTX") != null);
    const caps = gpu.nvidia_device.emuCaps();
    try testing.expectEqual(caps.max_group, props.limits.maxComputeWorkGroupInvocations);
    try testing.expectEqual(caps.shared_bytes, props.limits.maxComputeSharedMemorySize);
    try testing.expectEqual(@as(u32, 128), props.limits.maxPushConstantsSize);
    try testing.expect(props.limits.maxBoundDescriptorSets >= 4);
    try testing.expectEqual(@as(u32, 8192), props.limits.maxImageDimension2D);
    try testing.expectEqual(@as(u32, 8), props.limits.maxColorAttachments);
    // (WebGPU's default limits: 16 inter-stage variables, the position apart)
    try testing.expect(props.limits.maxVertexOutputComponents / 4 - 1 >= 16);
    try testing.expect(props.limits.maxPerStageDescriptorUniformBuffers >= 12 and props.limits.maxPerStageDescriptorStorageBuffers >= 8);
    try testing.expect(props.limits.maxPerStageDescriptorSampledImages >= 16 and props.limits.maxPerStageDescriptorSamplers >= 16);

    // Properties2 with a chain: timeline and subgroup properties filled, an unknown struct left alone
    var unknown = [_]u32{ 999_999, 0, 0, 0, 0xabcd, 0 };
    var sub = std.mem.zeroes(abi.PhysicalDeviceSubgroupProperties);
    sub.sType = ST.physical_device_subgroup_properties;
    sub.pNext = &unknown;
    var tsp = std.mem.zeroes(abi.PhysicalDeviceTimelineSemaphoreProperties);
    tsp.sType = ST.physical_device_timeline_semaphore_properties;
    tsp.pNext = &sub;
    var props2 = std.mem.zeroes(abi.PhysicalDeviceProperties2);
    props2.sType = ST.physical_device_properties_2;
    props2.pNext = &tsp;
    get(inst, "vkGetPhysicalDeviceProperties2KHR", *const fn (Ptr, *abi.PhysicalDeviceProperties2) callconv(.c) void)(pd, &props2);
    try testing.expectEqual(props.limits.maxComputeWorkGroupSize, props2.properties.limits.maxComputeWorkGroupSize);
    try testing.expect(tsp.maxTimelineSemaphoreValueDifference > 0);
    try testing.expectEqual(@as(u32, 32), sub.subgroupSize);
    try testing.expectEqual(@as(u32, 0xabcd), unknown[4]);

    var feats: abi.PhysicalDeviceFeatures = undefined;
    get(inst, "vkGetPhysicalDeviceFeatures", *const fn (Ptr, *abi.PhysicalDeviceFeatures) callconv(.c) void)(pd, &feats);
    try testing.expectEqual(@as(u32, 1), feats.robustBufferAccess);
    try testing.expectEqual(@as(u32, 0), feats.shaderInt64);
    var tsf = std.mem.zeroes(abi.PhysicalDeviceTimelineSemaphoreFeatures);
    tsf.sType = ST.physical_device_timeline_semaphore_features;
    var f2 = std.mem.zeroes(abi.PhysicalDeviceFeatures2);
    f2.sType = ST.physical_device_features_2;
    f2.pNext = &tsf;
    get(inst, "vkGetPhysicalDeviceFeatures2", *const fn (Ptr, *abi.PhysicalDeviceFeatures2) callconv(.c) void)(pd, &f2);
    try testing.expectEqual(@as(u32, 1), tsf.timelineSemaphore);

    // one queue family: graphics, compute and transfer (wgpu wants graphics on the first)
    const qfp = get(inst, "vkGetPhysicalDeviceQueueFamilyProperties", *const fn (Ptr, *u32, ?[*]abi.QueueFamilyProperties) callconv(.c) void);
    qfp(pd, &n, null);
    try testing.expectEqual(@as(u32, 1), n);
    var qf: [1]abi.QueueFamilyProperties = undefined;
    qfp(pd, &n, &qf);
    try testing.expectEqual(@as(u32, 0x7), qf[0].queueFlags);
    try testing.expectEqual(@as(u32, 1), qf[0].queueCount);

    // memory: VRAM, system memory, BAR1
    var mp: abi.PhysicalDeviceMemoryProperties = undefined;
    get(inst, "vkGetPhysicalDeviceMemoryProperties", *const fn (Ptr, *abi.PhysicalDeviceMemoryProperties) callconv(.c) void)(pd, &mp);
    try testing.expectEqual(@as(u32, 3), mp.memoryTypeCount);
    try testing.expectEqual(@as(u32, 2), mp.memoryHeapCount);
    try testing.expectEqual(@as(u32, 1), mp.memoryTypes[0].propertyFlags);
    try testing.expectEqual(@as(u32, 0xe), mp.memoryTypes[1].propertyFlags);
    try testing.expectEqual(@as(u32, 0x7), mp.memoryTypes[2].propertyFlags);
    try testing.expectEqual(caps.device_bytes, mp.memoryHeaps[0].size);

    // device extensions, with the two-call protocol cut short
    const enumDevExt = get(inst, "vkEnumerateDeviceExtensionProperties", *const fn (Ptr, ?[*:0]const u8, *u32, ?[*]abi.ExtensionProperties) callconv(.c) Res);
    try testing.expectEqual(R.success, enumDevExt(pd, null, &n, null));
    try testing.expectEqual(@as(u32, 3), n);
    n = 1;
    try testing.expectEqual(R.incomplete, enumDevExt(pd, null, &n, &exts));
    try testing.expectEqual(@as(u32, 1), n);
    n = 8;
    try testing.expectEqual(R.success, enumDevExt(pd, null, &n, &exts));
    try testing.expectEqualStrings("VK_KHR_timeline_semaphore", std.mem.sliceTo(&exts[2].extensionName, 0));
    try testing.expectEqual(R.error_layer_not_present, enumDevExt(pd, "VK_LAYER_x", &n, null));

    // formats: RGBA8 a colour attachment, the depth formats WebGPU needs
    // (wgpu's WEBGPU_TEXTURE_FORMAT_SUPPORT: S8 or D24S8, D24S8 or D32S8, D32)
    var fp: abi.FormatProperties = undefined;
    const fmtProps = get(inst, "vkGetPhysicalDeviceFormatProperties", *const fn (Ptr, u32, *abi.FormatProperties) callconv(.c) void);
    fmtProps(pd, 37, &fp);
    try testing.expect(fp.optimalTilingFeatures & 0x181 == 0x181); // sampled, colour attachment, blend
    for ([_]u32{ 126, 127, 129, 130 }) |f| {
        fmtProps(pd, f, &fp);
        try testing.expect(fp.optimalTilingFeatures & 0x201 == 0x201); // sampled, depth-stencil attachment
    }
    fmtProps(pd, 97, &fp); // R16G16B16A16_SFLOAT: a vertex format, not an image one yet
    try testing.expectEqual(@as(u32, 0), fp.optimalTilingFeatures);
    try testing.expect(fp.bufferFeatures & 0x40 != 0);
    const imgFmt = get(inst, "vkGetPhysicalDeviceImageFormatProperties", *const fn (Ptr, u32, u32, u32, u32, u32, ?*abi.ImageFormatProperties) callconv(.c) Res);
    var ifp: abi.ImageFormatProperties = undefined;
    try testing.expectEqual(R.success, imgFmt(pd, 37, 1, 0, 0x14, 0, &ifp));
    try testing.expectEqual(@as(u32, 8192), ifp.maxExtent.width);
    try testing.expectEqual(@as(u32, 1), ifp.sampleCounts);
    try testing.expectEqual(R.error_format_not_supported, imgFmt(pd, 43, 1, 0, 0x10, 0, &ifp)); // sRGB is not drawn into

    var groups: [1]abi.PhysicalDeviceGroupProperties = undefined;
    groups[0].sType = ST.physical_device_group_properties;
    groups[0].pNext = null;
    n = 1;
    try testing.expectEqual(R.success, get(inst, "vkEnumeratePhysicalDeviceGroups", *const fn (Ptr, *u32, ?[*]abi.PhysicalDeviceGroupProperties) callconv(.c) Res)(inst, &n, &groups));
    try testing.expectEqual(@as(u32, 1), groups[0].physicalDeviceCount);
    try testing.expectEqual(pd, groups[0].physicalDevices[0]);

    // devices: a feature or extension it lacks is refused; one it has is made
    const createDevice = get(inst, "vkCreateDevice", *const fn (Ptr, *const abi.DeviceCreateInfo, ?*const anyopaque, *Ptr) callconv(.c) Res);
    const prio = [_]f32{1.0};
    const qci = abi.DeviceQueueCreateInfo{ .sType = ST.device_queue_create_info, .pNext = null, .flags = 0, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
    var want = std.mem.zeroes(abi.PhysicalDeviceFeatures);
    want.shaderFloat64 = 1;
    var dci = abi.DeviceCreateInfo{ .sType = ST.device_create_info, .pNext = null, .flags = 0, .queueCreateInfoCount = 1, .pQueueCreateInfos = @ptrCast(&qci), .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = 0, .ppEnabledExtensionNames = null, .pEnabledFeatures = @ptrCast(&want) };
    var dev: Ptr = null;
    try testing.expectEqual(R.error_feature_not_present, createDevice(pd, &dci, null, &dev));
    want = std.mem.zeroes(abi.PhysicalDeviceFeatures);
    want.robustBufferAccess = 1;
    const swapchain = [_]?[*:0]const u8{"VK_KHR_swapchain"};
    dci.enabledExtensionCount = 1;
    dci.ppEnabledExtensionNames = &swapchain;
    try testing.expectEqual(R.error_extension_not_present, createDevice(pd, &dci, null, &dev));
    const dexts = [_]?[*:0]const u8{ "VK_KHR_timeline_semaphore", "VK_KHR_maintenance1" };
    dci.enabledExtensionCount = 2;
    dci.ppEnabledExtensionNames = &dexts;
    try testing.expectEqual(R.success, createDevice(pd, &dci, null, &dev));
    const gdpa = get(inst, "vkGetDeviceProcAddr", *const fn (Ptr, [*:0]const u8) callconv(.c) ?*const anyopaque);
    try testing.expect(gdpa(dev, "vkCmdDispatch") != null);
    try testing.expect(gdpa(dev, "vkCreateInstance") == null);
    var q: Ptr = null;
    get(inst, "vkGetDeviceQueue", *const fn (Ptr, u32, u32, *Ptr) callconv(.c) void)(dev, 0, 0, &q);
    try testing.expect(q != null);
    get(inst, "vkDestroyDevice", *const fn (Ptr, ?*const anyopaque) callconv(.c) void)(dev, null);
}

test "vk: no GPU, no physical device" {
    use(&openNone);
    const createInstance = get(null, "vkCreateInstance", *const fn (*const abi.InstanceCreateInfo, ?*const anyopaque, *Ptr) callconv(.c) Res);
    const ici = abi.InstanceCreateInfo{ .sType = ST.instance_create_info, .pNext = null, .flags = 0, .pApplicationInfo = null, .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = 0, .ppEnabledExtensionNames = null };
    var inst: Ptr = null;
    try testing.expectEqual(R.success, createInstance(&ici, null, &inst));
    var n: u32 = 5;
    try testing.expectEqual(R.success, get(inst, "vkEnumeratePhysicalDevices", *const fn (Ptr, *u32, ?[*]Ptr) callconv(.c) Res)(inst, &n, null));
    try testing.expectEqual(@as(u32, 0), n);
    get(inst, "vkDestroyInstance", *const fn (Ptr, ?*const anyopaque) callconv(.c) void)(inst, null);
}

// ── Compute ────────────────────────────────────────────────────────────────

const Shaders = struct {
    const axpy align(4) = @embedFile("data/vk/axpy.spv").*;
    const reduce align(4) = @embedFile("data/vk/reduce.spv").*;
};

/// A device and the entry points a compute test uses.
const Vk = struct {
    inst: Ptr,
    dev: Ptr,
    queue: Ptr,
    mp: abi.PhysicalDeviceMemoryProperties,

    fn f(v: *const Vk, comptime name: [:0]const u8, comptime Fp: type) Fp {
        return get(v.inst, name, Fp);
    }

    fn open() !Vk {
        var v: Vk = undefined;
        const ici = abi.InstanceCreateInfo{ .sType = ST.instance_create_info, .pNext = null, .flags = 0, .pApplicationInfo = null, .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = 0, .ppEnabledExtensionNames = null };
        try testing.expectEqual(R.success, get(null, "vkCreateInstance", *const fn (*const abi.InstanceCreateInfo, ?*const anyopaque, *Ptr) callconv(.c) Res)(&ici, null, &v.inst));
        var n: u32 = 1;
        var pd: [1]Ptr = undefined;
        try testing.expectEqual(R.success, v.f("vkEnumeratePhysicalDevices", *const fn (Ptr, *u32, ?[*]Ptr) callconv(.c) Res)(v.inst, &n, &pd));
        v.f("vkGetPhysicalDeviceMemoryProperties", *const fn (Ptr, *abi.PhysicalDeviceMemoryProperties) callconv(.c) void)(pd[0], &v.mp);
        const prio = [_]f32{1.0};
        const qci = abi.DeviceQueueCreateInfo{ .sType = ST.device_queue_create_info, .pNext = null, .flags = 0, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
        var want = std.mem.zeroes(abi.PhysicalDeviceFeatures);
        want.robustBufferAccess = 1;
        var tsf = std.mem.zeroes(abi.PhysicalDeviceTimelineSemaphoreFeatures);
        tsf.sType = ST.physical_device_timeline_semaphore_features;
        tsf.timelineSemaphore = 1;
        const dexts = [_]?[*:0]const u8{"VK_KHR_timeline_semaphore"};
        const dci = abi.DeviceCreateInfo{ .sType = ST.device_create_info, .pNext = &tsf, .flags = 0, .queueCreateInfoCount = 1, .pQueueCreateInfos = @ptrCast(&qci), .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = 1, .ppEnabledExtensionNames = &dexts, .pEnabledFeatures = @ptrCast(&want) };
        try testing.expectEqual(R.success, v.f("vkCreateDevice", *const fn (Ptr, *const abi.DeviceCreateInfo, ?*const anyopaque, *Ptr) callconv(.c) Res)(pd[0], &dci, null, &v.dev));
        v.f("vkGetDeviceQueue", *const fn (Ptr, u32, u32, *Ptr) callconv(.c) void)(v.dev, 0, 0, &v.queue);
        return v;
    }

    fn close(v: *Vk) void {
        _ = v.f("vkDeviceWaitIdle", *const fn (Ptr) callconv(.c) Res)(v.dev);
        v.f("vkDestroyDevice", *const fn (Ptr, ?*const anyopaque) callconv(.c) void)(v.dev, null);
        v.f("vkDestroyInstance", *const fn (Ptr, ?*const anyopaque) callconv(.c) void)(v.inst, null);
    }

    fn memType(v: *const Vk, want: u32, bits: u32) u32 {
        for (0..v.mp.memoryTypeCount) |i| {
            if (bits >> @intCast(i) & 1 != 0 and v.mp.memoryTypes[i].propertyFlags & want == want) return @intCast(i);
        }
        @panic("no memory type");
    }

    const Buf = struct { buf: H, mem: H, ptr: ?[*]u8 };

    /// A buffer in memory of its own with `flags`; mapped when host-visible.
    fn buffer(v: *const Vk, size: u64, flags: u32) !Buf {
        var b: Buf = undefined;
        const bci = abi.BufferCreateInfo{ .sType = ST.buffer_create_info, .pNext = null, .flags = 0, .size = size, .usage = 0x1ff, .sharingMode = 0, .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null };
        try testing.expectEqual(R.success, v.f("vkCreateBuffer", *const fn (Ptr, *const abi.BufferCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &bci, null, &b.buf));
        var req: abi.MemoryRequirements = undefined;
        v.f("vkGetBufferMemoryRequirements", *const fn (Ptr, H, *abi.MemoryRequirements) callconv(.c) void)(v.dev, b.buf, &req);
        const mai = abi.MemoryAllocateInfo{ .sType = ST.memory_allocate_info, .pNext = null, .allocationSize = req.size, .memoryTypeIndex = v.memType(flags, req.memoryTypeBits) };
        try testing.expectEqual(R.success, v.f("vkAllocateMemory", *const fn (Ptr, *const abi.MemoryAllocateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &mai, null, &b.mem));
        try testing.expectEqual(R.success, v.f("vkBindBufferMemory", *const fn (Ptr, H, H, u64) callconv(.c) Res)(v.dev, b.buf, b.mem, 0));
        b.ptr = null;
        if (flags & 2 != 0) {
            var p: ?*anyopaque = null;
            try testing.expectEqual(R.success, v.f("vkMapMemory", *const fn (Ptr, H, u64, u64, u32, *?*anyopaque) callconv(.c) Res)(v.dev, b.mem, 0, ~@as(u64, 0), 0, &p));
            b.ptr = @ptrCast(p);
        }
        return b;
    }

    fn shader(v: *const Vk, words: []align(4) const u8) !H {
        var m: H = 0;
        const smci = abi.ShaderModuleCreateInfo{ .sType = ST.shader_module_create_info, .pNext = null, .flags = 0, .codeSize = words.len, .pCode = @ptrCast(words.ptr) };
        try testing.expectEqual(R.success, v.f("vkCreateShaderModule", *const fn (Ptr, *const abi.ShaderModuleCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &smci, null, &m));
        return m;
    }

    fn setLayout(v: *const Vk, types: []const u32) !H {
        var b: [8]abi.DescriptorSetLayoutBinding = undefined;
        for (types, 0..) |t, i| b[i] = .{ .binding = @intCast(i), .descriptorType = t, .descriptorCount = 1, .stageFlags = 0x20, .pImmutableSamplers = null };
        const ci = abi.DescriptorSetLayoutCreateInfo{ .sType = ST.descriptor_set_layout_create_info, .pNext = null, .flags = 0, .bindingCount = @intCast(types.len), .pBindings = &b };
        var l: H = 0;
        try testing.expectEqual(R.success, v.f("vkCreateDescriptorSetLayout", *const fn (Ptr, *const abi.DescriptorSetLayoutCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &ci, null, &l));
        return l;
    }

    fn pipeline(v: *const Vk, module: H, layout: H) !H {
        const stage = abi.PipelineShaderStageCreateInfo{ .sType = ST.pipeline_shader_stage_create_info, .pNext = null, .flags = 0, .stage = 0x20, .module = module, .pName = "main", .pSpecializationInfo = null };
        const ci = abi.ComputePipelineCreateInfo{ .sType = ST.compute_pipeline_create_info, .pNext = null, .flags = 0, .stage = stage, .layout = layout, .basePipelineHandle = 0, .basePipelineIndex = -1 };
        var pl: H = 0;
        try testing.expectEqual(R.success, v.f("vkCreateComputePipelines", *const fn (Ptr, H, u32, [*]const abi.ComputePipelineCreateInfo, ?*const anyopaque, [*]H) callconv(.c) Res)(v.dev, 0, 1, @ptrCast(&ci), null, @ptrCast(&pl)));
        return pl;
    }

    fn write(v: *const Vk, set: H, binding: u32, dtype: u32, b: H, offset: u64, range: u64) void {
        const bi = abi.DescriptorBufferInfo{ .buffer = b, .offset = offset, .range = range };
        const w = abi.WriteDescriptorSet{ .sType = ST.write_descriptor_set, .pNext = null, .dstSet = set, .dstBinding = binding, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = dtype, .pImageInfo = null, .pBufferInfo = @ptrCast(&bi), .pTexelBufferView = null };
        v.f("vkUpdateDescriptorSets", *const fn (Ptr, u32, [*]const abi.WriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void)(v.dev, 1, @ptrCast(&w), 0, null);
    }
};

const STORAGE: u32 = 7;
const UNIFORM: u32 = 6;
const STORAGE_DYNAMIC: u32 = 9;

fn axpyThroughVulkan(open: *const fn () ?icd.Gpu) !void {
    use(open);
    var v = try Vk.open();
    defer v.close();
    // src and the uniform block in host-visible memory; dst in device-local
    // memory, copied to a host-visible readback buffer
    const src = try v.buffer(90 * 4, 2);
    const params = try v.buffer(16, 2);
    const dst = try v.buffer(100 * 4, 1);
    const back = try v.buffer(100 * 4, 2);
    const fsrc: [*]f32 = @ptrCast(@alignCast(src.ptr.?));
    for (0..90) |i| fsrc[i] = @as(f32, @floatFromInt(i)) * 0.5 - 7.25;
    const pw: [*]u32 = @ptrCast(@alignCast(params.ptr.?));
    pw[0] = 90;
    pw[1] = @bitCast(@as(f32, 1.5));

    const layout = try v.setLayout(&.{ STORAGE, STORAGE, UNIFORM });
    const plci = abi.PipelineLayoutCreateInfo{ .sType = ST.pipeline_layout_create_info, .pNext = null, .flags = 0, .setLayoutCount = 1, .pSetLayouts = @ptrCast(&layout), .pushConstantRangeCount = 0, .pPushConstantRanges = null };
    var pl_layout: H = 0;
    try testing.expectEqual(R.success, v.f("vkCreatePipelineLayout", *const fn (Ptr, *const abi.PipelineLayoutCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &plci, null, &pl_layout));
    const sizes = [_]abi.DescriptorPoolSize{ .{ .@"type" = STORAGE, .descriptorCount = 2 }, .{ .@"type" = UNIFORM, .descriptorCount = 1 } };
    const dpci = abi.DescriptorPoolCreateInfo{ .sType = ST.descriptor_pool_create_info, .pNext = null, .flags = 1, .maxSets = 1, .poolSizeCount = 2, .pPoolSizes = &sizes };
    var pool: H = 0;
    try testing.expectEqual(R.success, v.f("vkCreateDescriptorPool", *const fn (Ptr, *const abi.DescriptorPoolCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &dpci, null, &pool));
    const dsai = abi.DescriptorSetAllocateInfo{ .sType = ST.descriptor_set_allocate_info, .pNext = null, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = @ptrCast(&layout) };
    var set: H = 0;
    const allocSets = v.f("vkAllocateDescriptorSets", *const fn (Ptr, *const abi.DescriptorSetAllocateInfo, [*]H) callconv(.c) Res);
    try testing.expectEqual(R.success, allocSets(v.dev, &dsai, @ptrCast(&set)));
    // (the pool holds one set)
    var set2: H = 0;
    try testing.expectEqual(R.error_out_of_pool_memory, allocSets(v.dev, &dsai, @ptrCast(&set2)));
    v.write(set, 0, STORAGE, src.buf, 0, ~@as(u64, 0));
    v.write(set, 1, STORAGE, dst.buf, 0, 100 * 4);
    v.write(set, 2, UNIFORM, params.buf, 0, 8);

    const module = try v.shader(&Shaders.axpy);
    const pipe = try v.pipeline(module, pl_layout);
    v.f("vkDestroyShaderModule", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, module, null);

    const cpci = abi.CommandPoolCreateInfo{ .sType = ST.command_pool_create_info, .pNext = null, .flags = 2, .queueFamilyIndex = 0 };
    var cpool: H = 0;
    try testing.expectEqual(R.success, v.f("vkCreateCommandPool", *const fn (Ptr, *const abi.CommandPoolCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &cpci, null, &cpool));
    const cbai = abi.CommandBufferAllocateInfo{ .sType = ST.command_buffer_allocate_info, .pNext = null, .commandPool = cpool, .level = 0, .commandBufferCount = 1 };
    var cb: Ptr = null;
    try testing.expectEqual(R.success, v.f("vkAllocateCommandBuffers", *const fn (Ptr, *const abi.CommandBufferAllocateInfo, *Ptr) callconv(.c) Res)(v.dev, &cbai, &cb));
    const cbbi = abi.CommandBufferBeginInfo{ .sType = ST.command_buffer_begin_info, .pNext = null, .flags = 1, .pInheritanceInfo = null };
    try testing.expectEqual(R.success, v.f("vkBeginCommandBuffer", *const fn (Ptr, *const abi.CommandBufferBeginInfo) callconv(.c) Res)(cb, &cbbi));
    // dst filled with a pattern first (the kernel overwrites every word)
    v.f("vkCmdFillBuffer", *const fn (Ptr, H, u64, u64, u32) callconv(.c) void)(cb, dst.buf, 0, ~@as(u64, 0), 0xdead_beef);
    v.f("vkCmdPipelineBarrier", *const fn (Ptr, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void)(cb, 0x1000, 0x800, 0, 0, null, 0, null, 0, null);
    v.f("vkCmdBindPipeline", *const fn (Ptr, u32, H) callconv(.c) void)(cb, 1, pipe);
    v.f("vkCmdBindDescriptorSets", *const fn (Ptr, u32, H, u32, u32, [*]const H, u32, ?[*]const u32) callconv(.c) void)(cb, 1, pl_layout, 0, 1, @ptrCast(&set), 0, null);
    v.f("vkCmdDispatch", *const fn (Ptr, u32, u32, u32) callconv(.c) void)(cb, 2, 1, 1);
    const region = abi.BufferCopy{ .srcOffset = 0, .dstOffset = 0, .size = 100 * 4 };
    v.f("vkCmdCopyBuffer", *const fn (Ptr, H, H, u32, [*]const abi.BufferCopy) callconv(.c) void)(cb, dst.buf, back.buf, 1, @ptrCast(&region));
    // an update and an unaligned copy after it, in the readback buffer's tail
    const tail = [_]u32{ 11, 22, 33, 44 };
    v.f("vkCmdUpdateBuffer", *const fn (Ptr, H, u64, u64, *const anyopaque) callconv(.c) void)(cb, back.buf, 0, 16, &tail);
    const odd = abi.BufferCopy{ .srcOffset = 1, .dstOffset = 391, .size = 6 };
    v.f("vkCmdCopyBuffer", *const fn (Ptr, H, H, u32, [*]const abi.BufferCopy) callconv(.c) void)(cb, back.buf, back.buf, 1, @ptrCast(&odd));
    try testing.expectEqual(R.success, v.f("vkEndCommandBuffer", *const fn (Ptr) callconv(.c) Res)(cb));

    // a fence and a timeline semaphore the submission signals
    const fci = abi.FenceCreateInfo{ .sType = ST.fence_create_info, .pNext = null, .flags = 0 };
    var fence: H = 0;
    try testing.expectEqual(R.success, v.f("vkCreateFence", *const fn (Ptr, *const abi.FenceCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &fci, null, &fence));
    const stci = abi.SemaphoreTypeCreateInfo{ .sType = ST.semaphore_type_create_info, .pNext = null, .semaphoreType = 1, .initialValue = 3 };
    const sci = abi.SemaphoreCreateInfo{ .sType = ST.semaphore_create_info, .pNext = &stci, .flags = 0 };
    var sem: H = 0;
    try testing.expectEqual(R.success, v.f("vkCreateSemaphore", *const fn (Ptr, *const abi.SemaphoreCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &sci, null, &sem));
    const counter = v.f("vkGetSemaphoreCounterValueKHR", *const fn (Ptr, H, *u64) callconv(.c) Res);
    var value: u64 = 0;
    try testing.expectEqual(R.success, counter(v.dev, sem, &value));
    try testing.expectEqual(@as(u64, 3), value);
    const signal_value = [_]u64{7};
    const tssi = abi.TimelineSemaphoreSubmitInfo{ .sType = ST.timeline_semaphore_submit_info, .pNext = null, .waitSemaphoreValueCount = 0, .pWaitSemaphoreValues = null, .signalSemaphoreValueCount = 1, .pSignalSemaphoreValues = &signal_value };
    const si = abi.SubmitInfo{ .sType = ST.submit_info, .pNext = &tssi, .waitSemaphoreCount = 0, .pWaitSemaphores = null, .pWaitDstStageMask = null, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&cb), .signalSemaphoreCount = 1, .pSignalSemaphores = @ptrCast(&sem) };
    try testing.expectEqual(R.success, v.f("vkQueueSubmit", *const fn (Ptr, u32, [*]const abi.SubmitInfo, H) callconv(.c) Res)(v.queue, 1, @ptrCast(&si), fence));
    const wait_values = [_]u64{7};
    const swi = abi.SemaphoreWaitInfo{ .sType = ST.semaphore_wait_info, .pNext = null, .flags = 0, .semaphoreCount = 1, .pSemaphores = @ptrCast(&sem), .pValues = &wait_values };
    try testing.expectEqual(R.success, v.f("vkWaitSemaphores", *const fn (Ptr, *const abi.SemaphoreWaitInfo, u64) callconv(.c) Res)(v.dev, &swi, 5_000_000_000));
    try testing.expectEqual(R.success, v.f("vkWaitForFences", *const fn (Ptr, u32, [*]const H, u32, u64) callconv(.c) Res)(v.dev, 1, @ptrCast(&fence), 1, ~@as(u64, 0)));
    try testing.expectEqual(R.success, v.f("vkGetFenceStatus", *const fn (Ptr, H) callconv(.c) Res)(v.dev, fence));
    try testing.expectEqual(R.success, counter(v.dev, sem, &value));
    try testing.expectEqual(@as(u64, 7), value);

    // the results, as the CPU computes them
    const out: [*]const f32 = @ptrCast(@alignCast(back.ptr.?));
    const raw: [*]const u8 = back.ptr.?;
    var expect_bytes: [400]u8 = undefined;
    var expect: [100]f32 = undefined;
    for (0..2) |grp| {
        var s: f32 = 0;
        for (0..64) |l| {
            const i = grp * 64 + l;
            s += if (i < 90) fsrc[i] else 0;
        }
        for (0..64) |l| {
            const i = grp * 64 + l;
            if (i >= 100) continue;
            const x: f32 = if (i < 90) fsrc[i] else 0;
            expect[i] = (x * 2.0) * 1.5 + s + @as(f32, @floatFromInt(i % 7));
        }
    }
    @memcpy(&expect_bytes, std.mem.asBytes(&expect));
    @memcpy(expect_bytes[0..16], std.mem.asBytes(&tail));
    @memcpy(expect_bytes[391..397], expect_bytes[1..7]);
    for (4..97) |i| {
        if (i * 4 >= 391) break;
        testing.expectEqual(expect[i], out[i]) catch |e| {
            std.debug.print("axpy through Vulkan: [{d}] = {d}, want {d}\n", .{ i, out[i], expect[i] });
            return e;
        };
    }
    try testing.expectEqualSlices(u8, &expect_bytes, raw[0..400]);

    // a second submission of the same command buffer, fence reset
    try testing.expectEqual(R.success, v.f("vkResetFences", *const fn (Ptr, u32, [*]const H) callconv(.c) Res)(v.dev, 1, @ptrCast(&fence)));
    @memset(back.ptr.?[0..400], 0);
    const si2 = abi.SubmitInfo{ .sType = ST.submit_info, .pNext = null, .waitSemaphoreCount = 0, .pWaitSemaphores = null, .pWaitDstStageMask = null, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&cb), .signalSemaphoreCount = 0, .pSignalSemaphores = null };
    try testing.expectEqual(R.success, v.f("vkQueueSubmit", *const fn (Ptr, u32, [*]const abi.SubmitInfo, H) callconv(.c) Res)(v.queue, 1, @ptrCast(&si2), fence));
    try testing.expectEqual(R.success, v.f("vkWaitForFences", *const fn (Ptr, u32, [*]const H, u32, u64) callconv(.c) Res)(v.dev, 1, @ptrCast(&fence), 1, ~@as(u64, 0)));
    try testing.expectEqualSlices(u8, &expect_bytes, raw[0..400]);

    v.f("vkDestroyFence", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, fence, null);
    v.f("vkDestroySemaphore", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, sem, null);
    v.f("vkFreeCommandBuffers", *const fn (Ptr, H, u32, [*]const Ptr) callconv(.c) void)(v.dev, cpool, 1, @ptrCast(&cb));
    v.f("vkDestroyCommandPool", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, cpool, null);
    v.f("vkDestroyPipeline", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, pipe, null);
    v.f("vkDestroyPipelineLayout", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, pl_layout, null);
    v.f("vkDestroyDescriptorPool", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, pool, null);
    v.f("vkDestroyDescriptorSetLayout", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, layout, null);
    for ([_]Vk.Buf{ src, params, dst, back }) |b| {
        v.f("vkDestroyBuffer", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, b.buf, null);
        v.f("vkFreeMemory", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, b.mem, null);
    }
}

test "vk: naga's axpy through the ICD on the emulated RTX (fill, dispatch, copies, update, fence, timeline semaphore)" {
    try axpyThroughVulkan(&openRtx);
}

test "vk: naga's axpy through the ICD on KIR's interpreter (unified memory)" {
    try axpyThroughVulkan(&openInterp);
}

/// The reduction with push constants, a dynamic storage offset, an
/// indirect dispatch and a dynamically offset output.
fn reduceThroughVulkan(open: *const fn () ?icd.Gpu) !void {
    use(open);
    var v = try Vk.open();
    defer v.close();
    const n: u32 = 150;
    // the input at offset 256 of its buffer (a dynamic offset), the output
    // at offset 64 of another (a dynamic offset too)
    const input = try v.buffer(256 + 192 * 4, 2);
    const output = try v.buffer(64 + 16, 2);
    const args = try v.buffer(16, 2);
    const fin: [*]f32 = @ptrCast(@alignCast(input.ptr.? + 256));
    for (0..192) |i| fin[i] = @as(f32, @floatFromInt(@as(i32, @intCast(i % 17)) - 8)) + 0.5;
    const aw: [*]u32 = @ptrCast(@alignCast(args.ptr.?));
    aw[0] = 3;
    aw[1] = 1;
    aw[2] = 1;
    const layout = try v.setLayout(&.{ STORAGE_DYNAMIC, STORAGE_DYNAMIC });
    const pcr = abi.PushConstantRange{ .stageFlags = 0x20, .offset = 0, .size = 8 };
    const plci = abi.PipelineLayoutCreateInfo{ .sType = ST.pipeline_layout_create_info, .pNext = null, .flags = 0, .setLayoutCount = 1, .pSetLayouts = @ptrCast(&layout), .pushConstantRangeCount = 1, .pPushConstantRanges = @ptrCast(&pcr) };
    var pl_layout: H = 0;
    try testing.expectEqual(R.success, v.f("vkCreatePipelineLayout", *const fn (Ptr, *const abi.PipelineLayoutCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &plci, null, &pl_layout));
    const sizes = [_]abi.DescriptorPoolSize{.{ .@"type" = STORAGE_DYNAMIC, .descriptorCount = 2 }};
    const dpci = abi.DescriptorPoolCreateInfo{ .sType = ST.descriptor_pool_create_info, .pNext = null, .flags = 0, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &sizes };
    var pool: H = 0;
    try testing.expectEqual(R.success, v.f("vkCreateDescriptorPool", *const fn (Ptr, *const abi.DescriptorPoolCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &dpci, null, &pool));
    const dsai = abi.DescriptorSetAllocateInfo{ .sType = ST.descriptor_set_allocate_info, .pNext = null, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = @ptrCast(&layout) };
    var set: H = 0;
    try testing.expectEqual(R.success, v.f("vkAllocateDescriptorSets", *const fn (Ptr, *const abi.DescriptorSetAllocateInfo, [*]H) callconv(.c) Res)(v.dev, &dsai, @ptrCast(&set)));
    v.write(set, 0, STORAGE_DYNAMIC, input.buf, 0, 192 * 4);
    v.write(set, 1, STORAGE_DYNAMIC, output.buf, 0, 16);
    const module = try v.shader(&Shaders.reduce);
    const pipe = try v.pipeline(module, pl_layout);

    const cpci = abi.CommandPoolCreateInfo{ .sType = ST.command_pool_create_info, .pNext = null, .flags = 0, .queueFamilyIndex = 0 };
    var cpool: H = 0;
    try testing.expectEqual(R.success, v.f("vkCreateCommandPool", *const fn (Ptr, *const abi.CommandPoolCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &cpci, null, &cpool));
    const cbai = abi.CommandBufferAllocateInfo{ .sType = ST.command_buffer_allocate_info, .pNext = null, .commandPool = cpool, .level = 0, .commandBufferCount = 1 };
    var cb: Ptr = null;
    try testing.expectEqual(R.success, v.f("vkAllocateCommandBuffers", *const fn (Ptr, *const abi.CommandBufferAllocateInfo, *Ptr) callconv(.c) Res)(v.dev, &cbai, &cb));
    const cbbi = abi.CommandBufferBeginInfo{ .sType = ST.command_buffer_begin_info, .pNext = null, .flags = 0, .pInheritanceInfo = null };
    try testing.expectEqual(R.success, v.f("vkBeginCommandBuffer", *const fn (Ptr, *const abi.CommandBufferBeginInfo) callconv(.c) Res)(cb, &cbbi));
    v.f("vkCmdBindPipeline", *const fn (Ptr, u32, H) callconv(.c) void)(cb, 1, pipe);
    const dyn = [_]u32{ 256, 64 };
    v.f("vkCmdBindDescriptorSets", *const fn (Ptr, u32, H, u32, u32, [*]const H, u32, ?[*]const u32) callconv(.c) void)(cb, 1, pl_layout, 0, 1, @ptrCast(&set), 2, &dyn);
    const scale: f32 = 0.25;
    const pc = [_]u32{ n, @bitCast(scale) };
    v.f("vkCmdPushConstants", *const fn (Ptr, H, u32, u32, u32, *const anyopaque) callconv(.c) void)(cb, pl_layout, 0x20, 0, 8, &pc);
    v.f("vkCmdDispatchIndirect", *const fn (Ptr, H, u64) callconv(.c) void)(cb, args.buf, 0);
    try testing.expectEqual(R.success, v.f("vkEndCommandBuffer", *const fn (Ptr) callconv(.c) Res)(cb));
    const si = abi.SubmitInfo{ .sType = ST.submit_info, .pNext = null, .waitSemaphoreCount = 0, .pWaitSemaphores = null, .pWaitDstStageMask = null, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&cb), .signalSemaphoreCount = 0, .pSignalSemaphores = null };
    try testing.expectEqual(R.success, v.f("vkQueueSubmit", *const fn (Ptr, u32, [*]const abi.SubmitInfo, H) callconv(.c) Res)(v.queue, 1, @ptrCast(&si), 0));
    try testing.expectEqual(R.success, v.f("vkQueueWaitIdle", *const fn (Ptr) callconv(.c) Res)(v.queue));
    const fout: [*]const f32 = @ptrCast(@alignCast(output.ptr.? + 64));
    for (0..3) |grp| {
        var sh: [64]f32 = undefined;
        for (&sh, 0..) |*x, l| {
            const i = grp * 64 + l;
            x.* = if (i < n) fin[i] else 0;
        }
        var s: usize = 32;
        while (s > 0) : (s >>= 1) {
            for (0..s) |l| sh[l] += sh[l + s];
        }
        try testing.expectEqual(sh[0] * scale, fout[grp]);
    }
    v.f("vkDestroyPipeline", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, pipe, null);
    v.f("vkDestroyCommandPool", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, cpool, null);
}

test "vk: naga's reduction with push constants, dynamic offsets and an indirect dispatch on KIR's interpreter" {
    try reduceThroughVulkan(&openInterp);
}

test "vk: naga's reduction with push constants, dynamic offsets and an indirect dispatch on the emulated RTX" {
    try reduceThroughVulkan(&openRtx);
}

test "vk: a shader the front end cannot take fails its pipeline, with the reason logged" {
    use(&openInterp);
    var v = try Vk.open();
    defer v.close();
    // a module with no "main" GLCompute entry point
    var words: [Shaders.axpy.len]u8 align(4) = Shaders.axpy;
    const w: []u32 = std.mem.bytesAsSlice(u32, &words);
    for (w, 0..) |x, i| {
        if (x == 0x6e69_616d) w[i] = 0x6e69_616e; // "main" -> "nain"
    }
    const module = try v.shader(&words);
    const stage = abi.PipelineShaderStageCreateInfo{ .sType = ST.pipeline_shader_stage_create_info, .pNext = null, .flags = 0, .stage = 0x20, .module = module, .pName = "main", .pSpecializationInfo = null };
    const ci = abi.ComputePipelineCreateInfo{ .sType = ST.compute_pipeline_create_info, .pNext = null, .flags = 0, .stage = stage, .layout = 0, .basePipelineHandle = 0, .basePipelineIndex = -1 };
    var pl: H = 0;
    try testing.expectEqual(R.error_unknown, v.f("vkCreateComputePipelines", *const fn (Ptr, H, u32, [*]const abi.ComputePipelineCreateInfo, ?*const anyopaque, [*]H) callconv(.c) Res)(v.dev, 0, 1, @ptrCast(&ci), null, @ptrCast(&pl)));
    try testing.expectEqual(@as(H, 0), pl);
    try testing.expect(std.mem.indexOf(u8, D.log_buf[0..D.log_len], "no GLCompute entry point") != null);
}

// ── Graphics ───────────────────────────────────────────────────────────────
//
// naga's SPIR-V for WGSL vertex and fragment shaders (tests/data/vk
// triangle.wgsl, quad.wgsl; `naga --keep-coordinate-space`, as wgpu, which
// flips y by a negative viewport height), drawn by gfxapi's raster through
// the ICD, read back by vkCmdCopyImageToBuffer and checked pixel by pixel.

const GShaders = struct {
    const triangle align(4) = @embedFile("data/vk/triangle.spv").*;
    const quad align(4) = @embedFile("data/vk/quad.spv").*;
    const targets align(4) = @embedFile("data/vk/targets.spv").*;
};

const RGBA8: u32 = 37;
const D32F: u32 = 126;
const SAMPLED: u32 = 2;
const SAMPLER: u32 = 0;

const G = struct {
    v: *Vk,
    cpool: H = 0,
    cb: Ptr = null,
    fence: H = 0,

    fn f(g: *const G, comptime name: [:0]const u8, comptime Fp: type) Fp {
        return g.v.f(name, Fp);
    }

    fn init(v: *Vk) !G {
        var g = G{ .v = v };
        const cpci = abi.CommandPoolCreateInfo{ .sType = ST.command_pool_create_info, .pNext = null, .flags = 2, .queueFamilyIndex = 0 };
        try testing.expectEqual(R.success, g.f("vkCreateCommandPool", *const fn (Ptr, *const abi.CommandPoolCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &cpci, null, &g.cpool));
        const cbai = abi.CommandBufferAllocateInfo{ .sType = ST.command_buffer_allocate_info, .pNext = null, .commandPool = g.cpool, .level = 0, .commandBufferCount = 1 };
        try testing.expectEqual(R.success, g.f("vkAllocateCommandBuffers", *const fn (Ptr, *const abi.CommandBufferAllocateInfo, *Ptr) callconv(.c) Res)(v.dev, &cbai, &g.cb));
        const fci = abi.FenceCreateInfo{ .sType = ST.fence_create_info, .pNext = null, .flags = 0 };
        try testing.expectEqual(R.success, g.f("vkCreateFence", *const fn (Ptr, *const abi.FenceCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &fci, null, &g.fence));
        return g;
    }

    fn begin(g: *G) !void {
        const cbbi = abi.CommandBufferBeginInfo{ .sType = ST.command_buffer_begin_info, .pNext = null, .flags = 1, .pInheritanceInfo = null };
        try testing.expectEqual(R.success, g.f("vkBeginCommandBuffer", *const fn (Ptr, *const abi.CommandBufferBeginInfo) callconv(.c) Res)(g.cb, &cbbi));
    }

    /// Ends the command buffer, submits it and waits.
    fn run(g: *G) !void {
        try testing.expectEqual(R.success, g.f("vkEndCommandBuffer", *const fn (Ptr) callconv(.c) Res)(g.cb));
        const si = abi.SubmitInfo{ .sType = ST.submit_info, .pNext = null, .waitSemaphoreCount = 0, .pWaitSemaphores = null, .pWaitDstStageMask = null, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&g.cb), .signalSemaphoreCount = 0, .pSignalSemaphores = null };
        try testing.expectEqual(R.success, g.f("vkQueueSubmit", *const fn (Ptr, u32, [*]const abi.SubmitInfo, H) callconv(.c) Res)(g.v.queue, 1, @ptrCast(&si), g.fence));
        try testing.expectEqual(R.success, g.f("vkWaitForFences", *const fn (Ptr, u32, [*]const H, u32, u64) callconv(.c) Res)(g.v.dev, 1, @ptrCast(&g.fence), 1, ~@as(u64, 0)));
        try testing.expectEqual(R.success, g.f("vkResetFences", *const fn (Ptr, u32, [*]const H) callconv(.c) Res)(g.v.dev, 1, @ptrCast(&g.fence)));
    }

    const Img = struct { img: H, mem: H };

    fn newImage(g: *G, fmt: u32, w: u32, h: u32, levels: u32, layers: u32, usage: u32) !Img {
        var x: Img = undefined;
        const ci = abi.ImageCreateInfo{ .sType = ST.image_create_info, .pNext = null, .flags = 0, .imageType = 1, .format = fmt, .extent = .{ .width = w, .height = h, .depth = 1 }, .mipLevels = levels, .arrayLayers = layers, .samples = 1, .tiling = 0, .usage = usage, .sharingMode = 0, .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null, .initialLayout = 0 };
        try testing.expectEqual(R.success, g.f("vkCreateImage", *const fn (Ptr, *const abi.ImageCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(g.v.dev, &ci, null, &x.img));
        var req: abi.MemoryRequirements = undefined;
        g.f("vkGetImageMemoryRequirements", *const fn (Ptr, H, *abi.MemoryRequirements) callconv(.c) void)(g.v.dev, x.img, &req);
        const mai = abi.MemoryAllocateInfo{ .sType = ST.memory_allocate_info, .pNext = null, .allocationSize = req.size, .memoryTypeIndex = g.v.memType(1, req.memoryTypeBits) };
        try testing.expectEqual(R.success, g.f("vkAllocateMemory", *const fn (Ptr, *const abi.MemoryAllocateInfo, ?*const anyopaque, *H) callconv(.c) Res)(g.v.dev, &mai, null, &x.mem));
        try testing.expectEqual(R.success, g.f("vkBindImageMemory", *const fn (Ptr, H, H, u64) callconv(.c) Res)(g.v.dev, x.img, x.mem, 0));
        return x;
    }

    fn newView(g: *G, img: H, fmt: u32, vtype: u32, aspect: u32, layer: u32, layers: u32) !H {
        const ci = abi.ImageViewCreateInfo{ .sType = ST.image_view_create_info, .pNext = null, .flags = 0, .image = img, .viewType = vtype, .format = fmt, .components = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .subresourceRange = .{ .aspectMask = aspect, .baseMipLevel = 0, .levelCount = 0xffff_ffff, .baseArrayLayer = layer, .layerCount = layers } };
        var x: H = 0;
        try testing.expectEqual(R.success, g.f("vkCreateImageView", *const fn (Ptr, *const abi.ImageViewCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(g.v.dev, &ci, null, &x));
        return x;
    }

    /// A render pass: one colour attachment (cleared), and a depth one if asked.
    fn renderPass(g: *G, depth: bool) !H {
        const atts = [_]abi.AttachmentDescription{
            .{ .flags = 0, .format = RGBA8, .samples = 1, .loadOp = 1, .storeOp = 0, .stencilLoadOp = 2, .stencilStoreOp = 1, .initialLayout = 0, .finalLayout = 2 },
            .{ .flags = 0, .format = D32F, .samples = 1, .loadOp = 1, .storeOp = 0, .stencilLoadOp = 2, .stencilStoreOp = 1, .initialLayout = 0, .finalLayout = 3 },
        };
        const cref = abi.AttachmentReference{ .attachment = 0, .layout = 2 };
        const dref = abi.AttachmentReference{ .attachment = 1, .layout = 3 };
        const sp = abi.SubpassDescription{ .flags = 0, .pipelineBindPoint = 0, .inputAttachmentCount = 0, .pInputAttachments = null, .colorAttachmentCount = 1, .pColorAttachments = @ptrCast(&cref), .pResolveAttachments = null, .pDepthStencilAttachment = if (depth) &dref else null, .preserveAttachmentCount = 0, .pPreserveAttachments = null };
        const ci = abi.RenderPassCreateInfo{ .sType = ST.render_pass_create_info, .pNext = null, .flags = 0, .attachmentCount = if (depth) 2 else 1, .pAttachments = &atts, .subpassCount = 1, .pSubpasses = @ptrCast(&sp), .dependencyCount = 0, .pDependencies = null };
        var x: H = 0;
        try testing.expectEqual(R.success, g.f("vkCreateRenderPass", *const fn (Ptr, *const abi.RenderPassCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(g.v.dev, &ci, null, &x));
        return x;
    }

    fn framebuffer(g: *G, rp: H, views: []const H, w: u32, h: u32) !H {
        const ci = abi.FramebufferCreateInfo{ .sType = ST.framebuffer_create_info, .pNext = null, .flags = 0, .renderPass = rp, .attachmentCount = @intCast(views.len), .pAttachments = views.ptr, .width = w, .height = h, .layers = 1 };
        var x: H = 0;
        try testing.expectEqual(R.success, g.f("vkCreateFramebuffer", *const fn (Ptr, *const abi.FramebufferCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(g.v.dev, &ci, null, &x));
        return x;
    }

    fn newLayout(g: *G, set_layouts: []const H) !H {
        const ci = abi.PipelineLayoutCreateInfo{ .sType = ST.pipeline_layout_create_info, .pNext = null, .flags = 0, .setLayoutCount = @intCast(set_layouts.len), .pSetLayouts = set_layouts.ptr, .pushConstantRangeCount = 0, .pPushConstantRanges = null };
        var x: H = 0;
        try testing.expectEqual(R.success, g.f("vkCreatePipelineLayout", *const fn (Ptr, *const abi.PipelineLayoutCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(g.v.dev, &ci, null, &x));
        return x;
    }

    const PipeDesc = struct {
        module: H,
        vs: [*:0]const u8 = "vs_main",
        fs: [*:0]const u8 = "fs_main",
        layout: H,
        rp: H,
        binds: []const abi.VertexInputBindingDescription = &.{},
        attrs: []const abi.VertexInputAttributeDescription = &.{},
        depth: bool = false,
        blend: bool = false,
        targets: u32 = 1,
    };

    /// A graphics pipeline as wgpu makes one: viewport and scissor
    /// dynamic, a triangle list, no culling.
    fn pipeline(g: *G, d: PipeDesc) !Res {
        var x: H = 0;
        return g.pipelineOut(d, &x);
    }

    fn pipelineOut(g: *G, d: PipeDesc, out: *H) Res {
        const stages = [_]abi.PipelineShaderStageCreateInfo{
            .{ .sType = ST.pipeline_shader_stage_create_info, .pNext = null, .flags = 0, .stage = 0x1, .module = d.module, .pName = d.vs, .pSpecializationInfo = null },
            .{ .sType = ST.pipeline_shader_stage_create_info, .pNext = null, .flags = 0, .stage = 0x10, .module = d.module, .pName = d.fs, .pSpecializationInfo = null },
        };
        const vi = abi.PipelineVertexInputStateCreateInfo{ .sType = 19, .pNext = null, .flags = 0, .vertexBindingDescriptionCount = @intCast(d.binds.len), .pVertexBindingDescriptions = d.binds.ptr, .vertexAttributeDescriptionCount = @intCast(d.attrs.len), .pVertexAttributeDescriptions = d.attrs.ptr };
        const ia = abi.PipelineInputAssemblyStateCreateInfo{ .sType = 20, .pNext = null, .flags = 0, .topology = 3, .primitiveRestartEnable = 0 };
        const vps = abi.PipelineViewportStateCreateInfo{ .sType = 22, .pNext = null, .flags = 0, .viewportCount = 1, .pViewports = null, .scissorCount = 1, .pScissors = null };
        const rs = abi.PipelineRasterizationStateCreateInfo{ .sType = 23, .pNext = null, .flags = 0, .depthClampEnable = 0, .rasterizerDiscardEnable = 0, .polygonMode = 0, .cullMode = 0, .frontFace = 0, .depthBiasEnable = 0, .depthBiasConstantFactor = 0, .depthBiasClamp = 0, .depthBiasSlopeFactor = 0, .lineWidth = 1 };
        const ms = abi.PipelineMultisampleStateCreateInfo{ .sType = 24, .pNext = null, .flags = 0, .rasterizationSamples = 1, .sampleShadingEnable = 0, .minSampleShading = 0, .pSampleMask = null, .alphaToCoverageEnable = 0, .alphaToOneEnable = 0 };
        const so = abi.StencilOpState{ .failOp = 0, .passOp = 0, .depthFailOp = 0, .compareOp = 7, .compareMask = 0xff, .writeMask = 0xff, .reference = 0 };
        const ds = abi.PipelineDepthStencilStateCreateInfo{ .sType = 25, .pNext = null, .flags = 0, .depthTestEnable = @intFromBool(d.depth), .depthWriteEnable = @intFromBool(d.depth), .depthCompareOp = 1, .depthBoundsTestEnable = 0, .stencilTestEnable = 0, .front = so, .back = so, .minDepthBounds = 0, .maxDepthBounds = 1 };
        // (blending: src alpha over)
        // (the first attachment blended if asked, the others not)
        const att = [2]abi.PipelineColorBlendAttachmentState{
            .{ .blendEnable = @intFromBool(d.blend), .srcColorBlendFactor = 6, .dstColorBlendFactor = 7, .colorBlendOp = 0, .srcAlphaBlendFactor = 1, .dstAlphaBlendFactor = 7, .alphaBlendOp = 0, .colorWriteMask = 0xf },
            .{ .blendEnable = 0, .srcColorBlendFactor = 1, .dstColorBlendFactor = 0, .colorBlendOp = 0, .srcAlphaBlendFactor = 1, .dstAlphaBlendFactor = 0, .alphaBlendOp = 0, .colorWriteMask = 0xf },
        };
        const cbs = abi.PipelineColorBlendStateCreateInfo{ .sType = 26, .pNext = null, .flags = 0, .logicOpEnable = 0, .logicOp = 0, .attachmentCount = d.targets, .pAttachments = &att, .blendConstants = .{ 0, 0, 0, 0 } };
        const dyn = [_]u32{ 0, 1, 4, 8 };
        const dys = abi.PipelineDynamicStateCreateInfo{ .sType = 27, .pNext = null, .flags = 0, .dynamicStateCount = dyn.len, .pDynamicStates = &dyn };
        const ci = abi.GraphicsPipelineCreateInfo{ .sType = ST.graphics_pipeline_create_info, .pNext = null, .flags = 0, .stageCount = 2, .pStages = &stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pTessellationState = null, .pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms, .pDepthStencilState = &ds, .pColorBlendState = &cbs, .pDynamicState = &dys, .layout = d.layout, .renderPass = d.rp, .subpass = 0, .basePipelineHandle = 0, .basePipelineIndex = -1 };
        return g.f("vkCreateGraphicsPipelines", *const fn (Ptr, H, u32, [*]const abi.GraphicsPipelineCreateInfo, ?*const anyopaque, [*]H) callconv(.c) Res)(g.v.dev, 0, 1, @ptrCast(&ci), null, @ptrCast(out));
    }

    /// Begins the render pass over (w, h), as wgpu does: a flipped viewport, the scissor.
    fn beginPass(g: *G, rp: H, fb: H, w: u32, h: u32, clears: []const abi.ClearValue) void {
        const bi = abi.RenderPassBeginInfo{ .sType = ST.render_pass_begin_info, .pNext = null, .renderPass = rp, .framebuffer = fb, .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = w, .height = h } }, .clearValueCount = @intCast(clears.len), .pClearValues = clears.ptr };
        const vp = abi.Viewport{ .x = 0, .y = @floatFromInt(h), .width = @floatFromInt(w), .height = -@as(f32, @floatFromInt(h)), .minDepth = 0, .maxDepth = 1 };
        const sc = abi.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = w, .height = h } };
        g.f("vkCmdSetViewport", *const fn (Ptr, u32, u32, [*]const abi.Viewport) callconv(.c) void)(g.cb, 0, 1, @ptrCast(&vp));
        g.f("vkCmdSetScissor", *const fn (Ptr, u32, u32, [*]const abi.Rect2D) callconv(.c) void)(g.cb, 0, 1, @ptrCast(&sc));
        g.f("vkCmdBeginRenderPass", *const fn (Ptr, *const abi.RenderPassBeginInfo, u32) callconv(.c) void)(g.cb, &bi, 0);
    }

    /// Image (level, layer, aspect) to a buffer, rows tightly packed.
    fn toBuffer(g: *G, img: H, buf: H, w: u32, h: u32, level: u32, layer: u32, aspect: u32) void {
        const r = abi.BufferImageCopy{ .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = aspect, .mipLevel = level, .baseArrayLayer = layer, .layerCount = 1 }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{ .width = w, .height = h, .depth = 1 } };
        g.f("vkCmdCopyImageToBuffer", *const fn (Ptr, H, u32, H, u32, [*]const abi.BufferImageCopy) callconv(.c) void)(g.cb, img, 6, buf, 1, @ptrCast(&r));
    }

    fn fromBuffer(g: *G, buf: H, off: u64, img: H, w: u32, h: u32, level: u32, layer: u32) void {
        const r = abi.BufferImageCopy{ .bufferOffset = off, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = 1, .mipLevel = level, .baseArrayLayer = layer, .layerCount = 1 }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{ .width = w, .height = h, .depth = 1 } };
        g.f("vkCmdCopyBufferToImage", *const fn (Ptr, H, H, u32, u32, [*]const abi.BufferImageCopy) callconv(.c) void)(g.cb, buf, img, 7, 1, @ptrCast(&r));
    }

    fn newSet(g: *G, pool: H, l: H) !H {
        const dsai = abi.DescriptorSetAllocateInfo{ .sType = ST.descriptor_set_allocate_info, .pNext = null, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = @ptrCast(&l) };
        var x: H = 0;
        try testing.expectEqual(R.success, g.f("vkAllocateDescriptorSets", *const fn (Ptr, *const abi.DescriptorSetAllocateInfo, [*]H) callconv(.c) Res)(g.v.dev, &dsai, @ptrCast(&x)));
        return x;
    }

    fn writeImage(g: *G, s: H, binding: u32, dtype: u32, view_h: H, sampler: H) void {
        const ii = abi.DescriptorImageInfo{ .sampler = sampler, .imageView = view_h, .imageLayout = 5 };
        const w = abi.WriteDescriptorSet{ .sType = ST.write_descriptor_set, .pNext = null, .dstSet = s, .dstBinding = binding, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = dtype, .pImageInfo = @ptrCast(&ii), .pBufferInfo = null, .pTexelBufferView = null };
        g.f("vkUpdateDescriptorSets", *const fn (Ptr, u32, [*]const abi.WriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void)(g.v.dev, 1, @ptrCast(&w), 0, null);
    }

    fn newPool(g: *G) !H {
        const sizes = [_]abi.DescriptorPoolSize{ .{ .@"type" = UNIFORM, .descriptorCount = 8 }, .{ .@"type" = SAMPLED, .descriptorCount = 8 }, .{ .@"type" = SAMPLER, .descriptorCount = 8 } };
        const dpci = abi.DescriptorPoolCreateInfo{ .sType = ST.descriptor_pool_create_info, .pNext = null, .flags = 1, .maxSets = 8, .poolSizeCount = sizes.len, .pPoolSizes = &sizes };
        var x: H = 0;
        try testing.expectEqual(R.success, g.f("vkCreateDescriptorPool", *const fn (Ptr, *const abi.DescriptorPoolCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(g.v.dev, &dpci, null, &x));
        return x;
    }

    fn setLayout(g: *G, types: []const u32) !H {
        var b: [8]abi.DescriptorSetLayoutBinding = undefined;
        for (types, 0..) |t, i| b[i] = .{ .binding = @intCast(i), .descriptorType = t, .descriptorCount = 1, .stageFlags = 0x11, .pImmutableSamplers = null };
        const ci = abi.DescriptorSetLayoutCreateInfo{ .sType = ST.descriptor_set_layout_create_info, .pNext = null, .flags = 0, .bindingCount = @intCast(types.len), .pBindings = &b };
        var l: H = 0;
        try testing.expectEqual(R.success, g.f("vkCreateDescriptorSetLayout", *const fn (Ptr, *const abi.DescriptorSetLayoutCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(g.v.dev, &ci, null, &l));
        return l;
    }
};

fn px(b: [*]const u8, w: u32, x: u32, y: u32) [4]u8 {
    const at = (y * w + x) * 4;
    return .{ b[at], b[at + 1], b[at + 2], b[at + 3] };
}

/// naga's triangle: a vertex buffer (two attributes), a uniform block
/// read by the vertex stage, a depth attachment, a varying colour.
fn triangleThroughVulkan(open: *const fn () ?icd.Gpu) !void {
    use(open);
    var v = try Vk.open();
    defer v.close();
    var g = try G.init(&v);
    const W = 32;
    const color = try g.newImage(RGBA8, W, W, 1, 1, 0x11);
    const depth = try g.newImage(D32F, W, W, 1, 1, 0x21);
    const cview = try g.newView(color.img, RGBA8, 1, 1, 0, 1);
    const dview = try g.newView(depth.img, D32F, 1, 2, 0, 1);
    const rp = try g.renderPass(true);
    const fb = try g.framebuffer(rp, &.{ cview, dview }, W, W);
    // vertices: x, y, r, g, b (a stride of 20 bytes); the buffer starts 16 bytes in
    const vb = try v.buffer(256, 2);
    const vf: [*]f32 = @ptrCast(@alignCast(vb.ptr.? + 16));
    const verts = [_]f32{ -0.5, -0.5, 1, 0, 0, 0.5, -0.5, 1, 0, 0, 0, 0.5, 1, 0, 0 };
    @memcpy(vf[0..verts.len], &verts);
    const ub = try v.buffer(64, 2);
    const uf: [*]f32 = @ptrCast(@alignCast(ub.ptr.?));
    uf[0..5].* = .{ 1, 0.5, 1, 1, 0.25 };
    const sl = try g.setLayout(&.{UNIFORM});
    const pl = try g.newLayout(&.{sl});
    const pool = try g.newPool();
    const set = try g.newSet(pool, sl);
    v.write(set, 0, UNIFORM, ub.buf, 0, 32);
    const module = try v.shader(&GShaders.triangle);
    const binds = [_]abi.VertexInputBindingDescription{.{ .binding = 0, .stride = 20, .inputRate = 0 }};
    const attrs = [_]abi.VertexInputAttributeDescription{ .{ .location = 0, .binding = 0, .format = 103, .offset = 0 }, .{ .location = 1, .binding = 0, .format = 106, .offset = 8 } };
    var pipe: H = 0;
    try testing.expectEqual(R.success, g.pipelineOut(.{ .module = module, .layout = pl, .rp = rp, .binds = &binds, .attrs = &attrs, .depth = true }, &pipe));
    // (the module may go: the pipeline holds it)
    v.f("vkDestroyShaderModule", *const fn (Ptr, H, ?*const anyopaque) callconv(.c) void)(v.dev, module, null);
    const back = try v.buffer(W * W * 4 * 2, 2);

    try g.begin();
    const clears = [_]abi.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 0.5, 1 } } }, .{ .depthStencil = .{ .depth = 1, .stencil = 0 } } };
    g.beginPass(rp, fb, W, W, &clears);
    g.f("vkCmdBindPipeline", *const fn (Ptr, u32, H) callconv(.c) void)(g.cb, 0, pipe);
    g.f("vkCmdBindDescriptorSets", *const fn (Ptr, u32, H, u32, u32, [*]const H, u32, ?[*]const u32) callconv(.c) void)(g.cb, 0, pl, 0, 1, @ptrCast(&set), 0, null);
    const off = [_]u64{16};
    g.f("vkCmdBindVertexBuffers", *const fn (Ptr, u32, u32, [*]const H, [*]const u64) callconv(.c) void)(g.cb, 0, 1, @ptrCast(&vb.buf), &off);
    g.f("vkCmdDraw", *const fn (Ptr, u32, u32, u32, u32) callconv(.c) void)(g.cb, 3, 1, 0, 0);
    g.f("vkCmdEndRenderPass", *const fn (Ptr) callconv(.c) void)(g.cb);
    g.toBuffer(color.img, back.buf, W, W, 0, 0, 1);
    // the depth aspect as f32, after the colour
    const r = abi.BufferImageCopy{ .bufferOffset = W * W * 4, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = 2, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{ .width = W, .height = W, .depth = 1 } };
    g.f("vkCmdCopyImageToBuffer", *const fn (Ptr, H, u32, H, u32, [*]const abi.BufferImageCopy) callconv(.c) void)(g.cb, depth.img, 6, back.buf, 1, @ptrCast(&r));
    try g.run();

    const out = back.ptr.?;
    const dz: [*]const f32 = @ptrCast(@alignCast(out + W * W * 4));
    // the triangle: (8, 24), (24, 24), (16, 8) in pixels (y down); the
    // colour (1, 0, 0) x the tint (1, 0.5, 1, 1)
    var inside: u32 = 0;
    for (0..W) |yy| for (0..W) |xx| {
        const x: f32 = @as(f32, @floatFromInt(xx)) + 0.5;
        const y: f32 = @as(f32, @floatFromInt(yy)) + 0.5;
        const p = px(out, W, @intCast(xx), @intCast(yy));
        const z = dz[yy * W + xx];
        // well inside or well outside (the edges' pixels are the tie rule's)
        const e0 = 24 - y;
        const e1 = (y - 8) - 2 * (x - 16);
        const e2 = (y - 8) + 2 * (x - 16);
        const m = @min(e0, @min(e1 / 2.24, e2 / 2.24));
        if (m > 0.5) {
            inside += 1;
            testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &p) catch |e| {
                std.debug.print("triangle: pixel ({d}, {d}) = {any}, want red\n", .{ xx, yy, p });
                return e;
            };
            try testing.expectApproxEqAbs(@as(f32, 0.25), z, 1e-6);
        } else if (m < -0.5) {
            testing.expectEqualSlices(u8, &.{ 0, 0, 128, 255 }, &p) catch |e| {
                std.debug.print("triangle: pixel ({d}, {d}) = {any}, want the clear colour\n", .{ xx, yy, p });
                return e;
            };
            try testing.expectEqual(@as(f32, 1), z);
        }
    };
    try testing.expect(inside > 80);
}

/// naga's textured quad: corners from the vertex index, an index buffer, a
/// texture with two levels sampled (implicit LOD: derivatives over quads;
/// an explicit level), and a layer of a 2D array fetched.
fn quadThroughVulkan(open: *const fn () ?icd.Gpu) !void {
    use(open);
    var v = try Vk.open();
    defer v.close();
    var g = try G.init(&v);
    const W = 16;
    const color = try g.newImage(RGBA8, W, W, 1, 1, 0x11);
    const cview = try g.newView(color.img, RGBA8, 1, 1, 0, 1);
    const rp = try g.renderPass(false);
    const fb = try g.framebuffer(rp, &.{cview}, W, W);
    // the texture: 4 x 4 (level 0) and 2 x 2 (level 1); the array: 2 layers of 4 x 4
    const tex = try g.newImage(RGBA8, 4, 4, 2, 1, 0x6);
    const arr = try g.newImage(RGBA8, 4, 4, 1, 2, 0x6);
    const tview = try g.newView(tex.img, RGBA8, 1, 1, 0, 1);
    const aview = try g.newView(arr.img, RGBA8, 5, 1, 0, 2);
    const staging = try v.buffer(4096, 2);
    const sw: [*]u32 = @ptrCast(@alignCast(staging.ptr.?));
    for (0..16) |i| sw[i] = @as(u32, @intCast(i * 16)) | 0x40 << 8 | 0x80 << 16 | 0xff << 24; // level 0
    for (0..4) |i| sw[16 + i] = 0x11 * @as(u32, @intCast(i + 1)) | 0xff << 24; // level 1
    for (0..32) |i| sw[32 + i] = @as(u32, @intCast(i)) << 8 | 0xff << 24; // the array's two layers
    const sampler_ci = abi.SamplerCreateInfo{ .sType = ST.sampler_create_info, .pNext = null, .flags = 0, .magFilter = 0, .minFilter = 0, .mipmapMode = 0, .addressModeU = 2, .addressModeV = 2, .addressModeW = 2, .mipLodBias = 0, .anisotropyEnable = 0, .maxAnisotropy = 1, .compareEnable = 0, .compareOp = 0, .minLod = 0, .maxLod = 32, .borderColor = 0, .unnormalizedCoordinates = 0 };
    var sampler: H = 0;
    try testing.expectEqual(R.success, g.f("vkCreateSampler", *const fn (Ptr, *const abi.SamplerCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &sampler_ci, null, &sampler));
    const ub = try v.buffer(64, 2);
    const uf: [*]f32 = @ptrCast(@alignCast(ub.ptr.?));
    uf[0..3].* = .{ 1, 1, 1 };
    const ib = try v.buffer(64, 2);
    const iw: [*]u16 = @ptrCast(@alignCast(ib.ptr.?));
    iw[0..8].* = .{ 9, 9, 0, 1, 2, 2, 1, 3 };
    const sl0 = try g.setLayout(&.{ SAMPLED, SAMPLER });
    const sl1 = try g.setLayout(&.{ UNIFORM, SAMPLED });
    const pl = try g.newLayout(&.{ sl0, sl1 });
    const pool = try g.newPool();
    const set0 = try g.newSet(pool, sl0);
    const set1 = try g.newSet(pool, sl1);
    g.writeImage(set0, 0, SAMPLED, tview, 0);
    g.writeImage(set0, 1, SAMPLER, 0, sampler);
    v.write(set1, 0, UNIFORM, ub.buf, 0, 16);
    g.writeImage(set1, 1, SAMPLED, aview, 0);
    const module = try v.shader(&GShaders.quad);
    var pipes: [3]H = undefined;
    for ([_][*:0]const u8{ "fs_main", "fs_lod", "fs_fetch" }, 0..) |name, i| {
        try testing.expectEqual(R.success, g.pipelineOut(.{ .module = module, .fs = name, .layout = pl, .rp = rp }, &pipes[i]));
    }
    const back = try v.buffer(W * W * 4 * 3, 2);

    // the uploads, then each pipeline into the target, read back after each
    try g.begin();
    g.fromBuffer(staging.buf, 0, tex.img, 4, 4, 0, 0);
    g.fromBuffer(staging.buf, 64, tex.img, 2, 2, 1, 0);
    g.fromBuffer(staging.buf, 128, arr.img, 4, 4, 0, 0);
    g.fromBuffer(staging.buf, 192, arr.img, 4, 4, 0, 1);
    const clears = [_]abi.ClearValue{.{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } }};
    for (pipes, 0..) |pipe, i| {
        g.beginPass(rp, fb, W, W, &clears);
        g.f("vkCmdBindPipeline", *const fn (Ptr, u32, H) callconv(.c) void)(g.cb, 0, pipe);
        const sets = [_]H{ set0, set1 };
        g.f("vkCmdBindDescriptorSets", *const fn (Ptr, u32, H, u32, u32, [*]const H, u32, ?[*]const u32) callconv(.c) void)(g.cb, 0, pl, 0, 2, &sets, 0, null);
        g.f("vkCmdBindIndexBuffer", *const fn (Ptr, H, u64, u32) callconv(.c) void)(g.cb, ib.buf, 0, 0);
        g.f("vkCmdDrawIndexed", *const fn (Ptr, u32, u32, u32, i32, u32) callconv(.c) void)(g.cb, 6, 1, 2, 0, 0);
        g.f("vkCmdEndRenderPass", *const fn (Ptr) callconv(.c) void)(g.cb);
        const r = abi.BufferImageCopy{ .bufferOffset = i * W * W * 4, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = 1, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{ .width = W, .height = W, .depth = 1 } };
        g.f("vkCmdCopyImageToBuffer", *const fn (Ptr, H, u32, H, u32, [*]const abi.BufferImageCopy) callconv(.c) void)(g.cb, color.img, 6, back.buf, 1, @ptrCast(&r));
    }
    try g.run();

    const names = [_][]const u8{ "textureSample", "textureSampleLevel 1", "textureLoad of layer 1" };
    for (0..3) |which| {
        const out = back.ptr.? + which * W * W * 4;
        for (0..W) |y| for (0..W) |x| {
            const p = px(out, W, @intCast(x), @intCast(y));
            const want: u32 = switch (which) {
                0 => sw[(y / 4) * 4 + x / 4],
                1 => sw[16 + (y / 8) * 2 + x / 8],
                else => sw[32 + 16 + (y / 4) * 4 + x / 4],
            };
            const got = std.mem.readInt(u32, &p, .little);
            if (got != want) {
                std.debug.print("quad, {s}: pixel ({d}, {d}) = 0x{x:0>8}, want 0x{x:0>8}\n", .{ names[which], x, y, got, want });
                return error.TestUnexpectedResult;
            }
        };
    }
}

test "vk: naga's triangle drawn on the emulated RTX (vertex buffer, uniform block, depth), read back" {
    try triangleThroughVulkan(&openRtx);
}

test "vk: naga's triangle drawn on KIR's interpreter (unified memory)" {
    try triangleThroughVulkan(&openInterp);
}

test "vk: naga's textured quad on the emulated RTX (index buffer, mipmaps, sampler, texture array, three fragment shaders)" {
    try quadThroughVulkan(&openRtx);
}

/// Two colour attachments from one fragment shader (each its own pass of
/// the raster): the first blended over its clear, the second the fragment's
/// position (FragCoord's y from the top); then vkCmdClearAttachments over a
/// corner of the second.
fn targetsThroughVulkan(open: *const fn () ?icd.Gpu) !void {
    use(open);
    var v = try Vk.open();
    defer v.close();
    var g = try G.init(&v);
    const W = 16;
    const BGRA8: u32 = 44;
    const a = try g.newImage(RGBA8, W, W, 1, 1, 0x11);
    const b = try g.newImage(BGRA8, W, W, 1, 1, 0x11);
    const av = try g.newView(a.img, RGBA8, 1, 1, 0, 1);
    const bv = try g.newView(b.img, BGRA8, 1, 1, 0, 1);
    const atts = [_]abi.AttachmentDescription{
        .{ .flags = 0, .format = RGBA8, .samples = 1, .loadOp = 1, .storeOp = 0, .stencilLoadOp = 2, .stencilStoreOp = 1, .initialLayout = 0, .finalLayout = 2 },
        .{ .flags = 0, .format = BGRA8, .samples = 1, .loadOp = 2, .storeOp = 0, .stencilLoadOp = 2, .stencilStoreOp = 1, .initialLayout = 0, .finalLayout = 2 },
    };
    const refs = [_]abi.AttachmentReference{ .{ .attachment = 0, .layout = 2 }, .{ .attachment = 1, .layout = 2 } };
    const sp = abi.SubpassDescription{ .flags = 0, .pipelineBindPoint = 0, .inputAttachmentCount = 0, .pInputAttachments = null, .colorAttachmentCount = 2, .pColorAttachments = &refs, .pResolveAttachments = null, .pDepthStencilAttachment = null, .preserveAttachmentCount = 0, .pPreserveAttachments = null };
    const rpci = abi.RenderPassCreateInfo{ .sType = ST.render_pass_create_info, .pNext = null, .flags = 0, .attachmentCount = 2, .pAttachments = &atts, .subpassCount = 1, .pSubpasses = @ptrCast(&sp), .dependencyCount = 0, .pDependencies = null };
    var rp: H = 0;
    try testing.expectEqual(R.success, g.f("vkCreateRenderPass", *const fn (Ptr, *const abi.RenderPassCreateInfo, ?*const anyopaque, *H) callconv(.c) Res)(v.dev, &rpci, null, &rp));
    const fb = try g.framebuffer(rp, &.{ av, bv }, W, W);
    const pl = try g.newLayout(&.{});
    const module = try v.shader(&GShaders.targets);
    var pipe: H = 0;
    try testing.expectEqual(R.success, g.pipelineOut(.{ .module = module, .layout = pl, .rp = rp, .blend = true, .targets = 2 }, &pipe));
    const back = try v.buffer(W * W * 4 * 2, 2);

    try g.begin();
    const clears = [_]abi.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } }, .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } } };
    g.beginPass(rp, fb, W, W, &clears);
    g.f("vkCmdBindPipeline", *const fn (Ptr, u32, H) callconv(.c) void)(g.cb, 0, pipe);
    g.f("vkCmdDraw", *const fn (Ptr, u32, u32, u32, u32) callconv(.c) void)(g.cb, 3, 1, 0, 0);
    const ca = abi.ClearAttachment{ .aspectMask = 1, .colorAttachment = 1, .clearValue = .{ .color = .{ .float32 = .{ 1, 0, 0, 1 } } } };
    const cr = abi.ClearRect{ .rect = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 4, .height = 4 } }, .baseArrayLayer = 0, .layerCount = 1 };
    g.f("vkCmdClearAttachments", *const fn (Ptr, u32, [*]const abi.ClearAttachment, u32, [*]const abi.ClearRect) callconv(.c) void)(g.cb, 1, @ptrCast(&ca), 1, @ptrCast(&cr));
    g.f("vkCmdEndRenderPass", *const fn (Ptr) callconv(.c) void)(g.cb);
    g.toBuffer(a.img, back.buf, W, W, 0, 0, 1);
    const r = abi.BufferImageCopy{ .bufferOffset = W * W * 4, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = 1, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{ .width = W, .height = W, .depth = 1 } };
    g.f("vkCmdCopyImageToBuffer", *const fn (Ptr, H, u32, H, u32, [*]const abi.BufferImageCopy) callconv(.c) void)(g.cb, b.img, 6, back.buf, 1, @ptrCast(&r));
    try g.run();

    const out = back.ptr.?;
    for (0..W) |y| for (0..W) |x| {
        // (0.25, 0.5, 0.75) x 0.5 over black; alpha 0.5 + 1 x 0.5
        const pa = px(out, W, @intCast(x), @intCast(y));
        testing.expectEqualSlices(u8, &.{ 32, 64, 96, 255 }, &pa) catch |e| {
            std.debug.print("targets, the blended one: pixel ({d}, {d}) = {any}\n", .{ x, y, pa });
            return e;
        };
        // B, G, R, A in memory: R = (x + 0.5) / 16, G = (y + 0.5) / 16
        const pb = px(out + W * W * 4, W, @intCast(x), @intCast(y));
        const want: [4]u8 = if (x < 4 and y < 4) .{ 0, 0, 255, 255 } else .{ 0, @intFromFloat(@round((@as(f32, @floatFromInt(y)) + 0.5) / 16 * 255)), @intFromFloat(@round((@as(f32, @floatFromInt(x)) + 0.5) / 16 * 255)), 255 };
        testing.expectEqualSlices(u8, &want, &pb) catch |e| {
            std.debug.print("targets, the position: pixel ({d}, {d}) = {any}\n", .{ x, y, pb });
            return e;
        };
    };
}

test "vk: two colour attachments, blending and vkCmdClearAttachments on the emulated RTX" {
    try targetsThroughVulkan(&openRtx);
}
