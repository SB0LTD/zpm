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
    try testing.expectEqual(icd.makeVersion(1, 0, 0), props.apiVersion);
    try testing.expectEqual(@as(u32, 0x10de), props.vendorID);
    try testing.expectEqual(@as(u32, 2), props.deviceType); // discrete
    try testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&props.deviceName, 0), "emulated RTX") != null);
    const caps = gpu.nvidia_device.emuCaps();
    try testing.expectEqual(caps.max_group, props.limits.maxComputeWorkGroupInvocations);
    try testing.expectEqual(caps.shared_bytes, props.limits.maxComputeSharedMemorySize);
    try testing.expectEqual(@as(u32, 128), props.limits.maxPushConstantsSize);
    try testing.expect(props.limits.maxBoundDescriptorSets >= 4);
    try testing.expectEqual(@as(u32, 0), props.limits.maxImageDimension2D); // (no images yet)

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

    // one queue family: compute and transfer
    const qfp = get(inst, "vkGetPhysicalDeviceQueueFamilyProperties", *const fn (Ptr, *u32, ?[*]abi.QueueFamilyProperties) callconv(.c) void);
    qfp(pd, &n, null);
    try testing.expectEqual(@as(u32, 1), n);
    var qf: [1]abi.QueueFamilyProperties = undefined;
    qfp(pd, &n, &qf);
    try testing.expectEqual(@as(u32, 0x6), qf[0].queueFlags);
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

    // no image format has a feature yet
    var fp: abi.FormatProperties = undefined;
    get(inst, "vkGetPhysicalDeviceFormatProperties", *const fn (Ptr, u32, *abi.FormatProperties) callconv(.c) void)(pd, 37, &fp);
    try testing.expectEqual(@as(u32, 0), fp.optimalTilingFeatures | fp.linearTilingFeatures | fp.bufferFeatures);
    try testing.expectEqual(R.error_format_not_supported, get(inst, "vkGetPhysicalDeviceImageFormatProperties", *const fn (Ptr, u32, u32, u32, u32, u32, ?*abi.ImageFormatProperties) callconv(.c) Res)(pd, 37, 1, 0, 4, 0, null));

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
