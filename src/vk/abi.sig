//! Vulkan's C types, generated from vulkan_core.h (Vulkan-Headers main,
//! 2026-11) for the structures Galaxy's Vulkan driver reads and writes.
//! 64-bit layout: non-dispatchable handles are u64, dispatchable ones pointers.

pub const Result = i32;

pub const BaseInStructure = extern struct {
    sType: u32,
    pNext: ?[*]const BaseInStructure,
};
pub const BaseOutStructure = extern struct {
    sType: u32,
    pNext: ?[*]BaseOutStructure,
};
pub const ApplicationInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    pApplicationName: ?[*:0]const u8,
    applicationVersion: u32,
    pEngineName: ?[*:0]const u8,
    engineVersion: u32,
    apiVersion: u32,
};
pub const InstanceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    pApplicationInfo: ?[*]const ApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const ?[*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const ?[*:0]const u8,
};
pub const PhysicalDeviceFeatures = extern struct {
    robustBufferAccess: u32,
    fullDrawIndexUint32: u32,
    imageCubeArray: u32,
    independentBlend: u32,
    geometryShader: u32,
    tessellationShader: u32,
    sampleRateShading: u32,
    dualSrcBlend: u32,
    logicOp: u32,
    multiDrawIndirect: u32,
    drawIndirectFirstInstance: u32,
    depthClamp: u32,
    depthBiasClamp: u32,
    fillModeNonSolid: u32,
    depthBounds: u32,
    wideLines: u32,
    largePoints: u32,
    alphaToOne: u32,
    multiViewport: u32,
    samplerAnisotropy: u32,
    textureCompressionETC2: u32,
    textureCompressionASTC_LDR: u32,
    textureCompressionBC: u32,
    occlusionQueryPrecise: u32,
    pipelineStatisticsQuery: u32,
    vertexPipelineStoresAndAtomics: u32,
    fragmentStoresAndAtomics: u32,
    shaderTessellationAndGeometryPointSize: u32,
    shaderImageGatherExtended: u32,
    shaderStorageImageExtendedFormats: u32,
    shaderStorageImageMultisample: u32,
    shaderStorageImageReadWithoutFormat: u32,
    shaderStorageImageWriteWithoutFormat: u32,
    shaderUniformBufferArrayDynamicIndexing: u32,
    shaderSampledImageArrayDynamicIndexing: u32,
    shaderStorageBufferArrayDynamicIndexing: u32,
    shaderStorageImageArrayDynamicIndexing: u32,
    shaderClipDistance: u32,
    shaderCullDistance: u32,
    shaderFloat64: u32,
    shaderInt64: u32,
    shaderInt16: u32,
    shaderResourceResidency: u32,
    shaderResourceMinLod: u32,
    sparseBinding: u32,
    sparseResidencyBuffer: u32,
    sparseResidencyImage2D: u32,
    sparseResidencyImage3D: u32,
    sparseResidency2Samples: u32,
    sparseResidency4Samples: u32,
    sparseResidency8Samples: u32,
    sparseResidency16Samples: u32,
    sparseResidencyAliased: u32,
    variableMultisampleRate: u32,
    inheritedQueries: u32,
};
pub const FormatProperties = extern struct {
    linearTilingFeatures: u32,
    optimalTilingFeatures: u32,
    bufferFeatures: u32,
};
pub const Extent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};
pub const ImageFormatProperties = extern struct {
    maxExtent: Extent3D,
    maxMipLevels: u32,
    maxArrayLayers: u32,
    sampleCounts: u32,
    maxResourceSize: u64,
};
pub const PhysicalDeviceLimits = extern struct {
    maxImageDimension1D: u32,
    maxImageDimension2D: u32,
    maxImageDimension3D: u32,
    maxImageDimensionCube: u32,
    maxImageArrayLayers: u32,
    maxTexelBufferElements: u32,
    maxUniformBufferRange: u32,
    maxStorageBufferRange: u32,
    maxPushConstantsSize: u32,
    maxMemoryAllocationCount: u32,
    maxSamplerAllocationCount: u32,
    bufferImageGranularity: u64,
    sparseAddressSpaceSize: u64,
    maxBoundDescriptorSets: u32,
    maxPerStageDescriptorSamplers: u32,
    maxPerStageDescriptorUniformBuffers: u32,
    maxPerStageDescriptorStorageBuffers: u32,
    maxPerStageDescriptorSampledImages: u32,
    maxPerStageDescriptorStorageImages: u32,
    maxPerStageDescriptorInputAttachments: u32,
    maxPerStageResources: u32,
    maxDescriptorSetSamplers: u32,
    maxDescriptorSetUniformBuffers: u32,
    maxDescriptorSetUniformBuffersDynamic: u32,
    maxDescriptorSetStorageBuffers: u32,
    maxDescriptorSetStorageBuffersDynamic: u32,
    maxDescriptorSetSampledImages: u32,
    maxDescriptorSetStorageImages: u32,
    maxDescriptorSetInputAttachments: u32,
    maxVertexInputAttributes: u32,
    maxVertexInputBindings: u32,
    maxVertexInputAttributeOffset: u32,
    maxVertexInputBindingStride: u32,
    maxVertexOutputComponents: u32,
    maxTessellationGenerationLevel: u32,
    maxTessellationPatchSize: u32,
    maxTessellationControlPerVertexInputComponents: u32,
    maxTessellationControlPerVertexOutputComponents: u32,
    maxTessellationControlPerPatchOutputComponents: u32,
    maxTessellationControlTotalOutputComponents: u32,
    maxTessellationEvaluationInputComponents: u32,
    maxTessellationEvaluationOutputComponents: u32,
    maxGeometryShaderInvocations: u32,
    maxGeometryInputComponents: u32,
    maxGeometryOutputComponents: u32,
    maxGeometryOutputVertices: u32,
    maxGeometryTotalOutputComponents: u32,
    maxFragmentInputComponents: u32,
    maxFragmentOutputAttachments: u32,
    maxFragmentDualSrcAttachments: u32,
    maxFragmentCombinedOutputResources: u32,
    maxComputeSharedMemorySize: u32,
    maxComputeWorkGroupCount: [3]u32,
    maxComputeWorkGroupInvocations: u32,
    maxComputeWorkGroupSize: [3]u32,
    subPixelPrecisionBits: u32,
    subTexelPrecisionBits: u32,
    mipmapPrecisionBits: u32,
    maxDrawIndexedIndexValue: u32,
    maxDrawIndirectCount: u32,
    maxSamplerLodBias: f32,
    maxSamplerAnisotropy: f32,
    maxViewports: u32,
    maxViewportDimensions: [2]u32,
    viewportBoundsRange: [2]f32,
    viewportSubPixelBits: u32,
    minMemoryMapAlignment: usize,
    minTexelBufferOffsetAlignment: u64,
    minUniformBufferOffsetAlignment: u64,
    minStorageBufferOffsetAlignment: u64,
    minTexelOffset: i32,
    maxTexelOffset: u32,
    minTexelGatherOffset: i32,
    maxTexelGatherOffset: u32,
    minInterpolationOffset: f32,
    maxInterpolationOffset: f32,
    subPixelInterpolationOffsetBits: u32,
    maxFramebufferWidth: u32,
    maxFramebufferHeight: u32,
    maxFramebufferLayers: u32,
    framebufferColorSampleCounts: u32,
    framebufferDepthSampleCounts: u32,
    framebufferStencilSampleCounts: u32,
    framebufferNoAttachmentsSampleCounts: u32,
    maxColorAttachments: u32,
    sampledImageColorSampleCounts: u32,
    sampledImageIntegerSampleCounts: u32,
    sampledImageDepthSampleCounts: u32,
    sampledImageStencilSampleCounts: u32,
    storageImageSampleCounts: u32,
    maxSampleMaskWords: u32,
    timestampComputeAndGraphics: u32,
    timestampPeriod: f32,
    maxClipDistances: u32,
    maxCullDistances: u32,
    maxCombinedClipAndCullDistances: u32,
    discreteQueuePriorities: u32,
    pointSizeRange: [2]f32,
    lineWidthRange: [2]f32,
    pointSizeGranularity: f32,
    lineWidthGranularity: f32,
    strictLines: u32,
    standardSampleLocations: u32,
    optimalBufferCopyOffsetAlignment: u64,
    optimalBufferCopyRowPitchAlignment: u64,
    nonCoherentAtomSize: u64,
};
pub const PhysicalDeviceSparseProperties = extern struct {
    residencyStandard2DBlockShape: u32,
    residencyStandard2DMultisampleBlockShape: u32,
    residencyStandard3DBlockShape: u32,
    residencyAlignedMipSize: u32,
    residencyNonResidentStrict: u32,
};
pub const PhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: u32,
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    limits: PhysicalDeviceLimits,
    sparseProperties: PhysicalDeviceSparseProperties,
};
pub const QueueFamilyProperties = extern struct {
    queueFlags: u32,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: Extent3D,
};
pub const MemoryType = extern struct {
    propertyFlags: u32,
    heapIndex: u32,
};
pub const MemoryHeap = extern struct {
    size: u64,
    flags: u32,
};
pub const PhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]MemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]MemoryHeap,
};
pub const DeviceQueueCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: ?[*]const f32,
};
pub const DeviceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: ?[*]const DeviceQueueCreateInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const ?[*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const ?[*:0]const u8,
    pEnabledFeatures: ?[*]const PhysicalDeviceFeatures,
};
pub const ExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};
pub const LayerProperties = extern struct {
    layerName: [256]u8,
    specVersion: u32,
    implementationVersion: u32,
    description: [256]u8,
};
pub const SubmitInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?[*]const u64,
    pWaitDstStageMask: ?[*]const u32,
    commandBufferCount: u32,
    pCommandBuffers: ?[*]const ?*anyopaque,
    signalSemaphoreCount: u32,
    pSignalSemaphores: ?[*]const u64,
};
pub const MemoryAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    allocationSize: u64,
    memoryTypeIndex: u32,
};
pub const MappedMemoryRange = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    memory: u64,
    offset: u64,
    size: u64,
};
pub const MemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memoryTypeBits: u32,
};
pub const FenceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
};
pub const SemaphoreCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
};
pub const BufferCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    size: u64,
    usage: u32,
    sharingMode: u32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
};
pub const ShaderModuleCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    codeSize: usize,
    pCode: ?[*]const u32,
};
pub const PipelineCacheCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    initialDataSize: usize,
    pInitialData: ?*const anyopaque,
};
pub const SpecializationMapEntry = extern struct {
    constantID: u32,
    offset: u32,
    size: usize,
};
pub const SpecializationInfo = extern struct {
    mapEntryCount: u32,
    pMapEntries: ?[*]const SpecializationMapEntry,
    dataSize: usize,
    pData: ?*const anyopaque,
};
pub const PipelineShaderStageCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stage: u32,
    module: u64,
    pName: ?[*:0]const u8,
    pSpecializationInfo: ?[*]const SpecializationInfo,
};
pub const ComputePipelineCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stage: PipelineShaderStageCreateInfo,
    layout: u64,
    basePipelineHandle: u64,
    basePipelineIndex: i32,
};
pub const PushConstantRange = extern struct {
    stageFlags: u32,
    offset: u32,
    size: u32,
};
pub const PipelineLayoutCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    setLayoutCount: u32,
    pSetLayouts: ?[*]const u64,
    pushConstantRangeCount: u32,
    pPushConstantRanges: ?[*]const PushConstantRange,
};
pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32,
    stageFlags: u32,
    pImmutableSamplers: ?[*]const u64,
};
pub const DescriptorSetLayoutCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    bindingCount: u32,
    pBindings: ?[*]const DescriptorSetLayoutBinding,
};
pub const DescriptorPoolSize = extern struct {
    @"type": u32,
    descriptorCount: u32,
};
pub const DescriptorPoolCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: ?[*]const DescriptorPoolSize,
};
pub const DescriptorSetAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    descriptorPool: u64,
    descriptorSetCount: u32,
    pSetLayouts: ?[*]const u64,
};
pub const DescriptorImageInfo = extern struct {
    sampler: u64,
    imageView: u64,
    imageLayout: u32,
};
pub const DescriptorBufferInfo = extern struct {
    buffer: u64,
    offset: u64,
    range: u64,
};
pub const WriteDescriptorSet = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    dstSet: u64,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
    descriptorType: u32,
    pImageInfo: ?[*]const DescriptorImageInfo,
    pBufferInfo: ?[*]const DescriptorBufferInfo,
    pTexelBufferView: ?[*]const u64,
};
pub const CopyDescriptorSet = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    srcSet: u64,
    srcBinding: u32,
    srcArrayElement: u32,
    dstSet: u64,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
};
pub const CommandPoolCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
};
pub const CommandBufferAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    commandPool: u64,
    level: u32,
    commandBufferCount: u32,
};
pub const CommandBufferInheritanceInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    renderPass: u64,
    subpass: u32,
    framebuffer: u64,
    occlusionQueryEnable: u32,
    queryFlags: u32,
    pipelineStatistics: u32,
};
pub const CommandBufferBeginInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    pInheritanceInfo: ?[*]const CommandBufferInheritanceInfo,
};
pub const BufferCopy = extern struct {
    srcOffset: u64,
    dstOffset: u64,
    size: u64,
};
pub const SparseImageFormatProperties = extern struct {
    aspectMask: u32,
    imageGranularity: Extent3D,
    flags: u32,
};
pub const PhysicalDeviceFeatures2 = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    features: PhysicalDeviceFeatures,
};
pub const PhysicalDeviceProperties2 = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    properties: PhysicalDeviceProperties,
};
pub const FormatProperties2 = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    formatProperties: FormatProperties,
};
pub const ImageFormatProperties2 = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    imageFormatProperties: ImageFormatProperties,
};
pub const QueueFamilyProperties2 = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    queueFamilyProperties: QueueFamilyProperties,
};
pub const PhysicalDeviceMemoryProperties2 = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    memoryProperties: PhysicalDeviceMemoryProperties,
};
pub const SparseImageFormatProperties2 = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    properties: SparseImageFormatProperties,
};
pub const PhysicalDeviceSubgroupProperties = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    subgroupSize: u32,
    supportedStages: u32,
    supportedOperations: u32,
    quadOperationsInAllStages: u32,
};
pub const PhysicalDeviceIDProperties = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    deviceUUID: [16]u8,
    driverUUID: [16]u8,
    deviceLUID: [8]u8,
    deviceNodeMask: u32,
    deviceLUIDValid: u32,
};
pub const PhysicalDeviceMaintenance3Properties = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    maxPerSetDescriptors: u32,
    maxMemoryAllocationSize: u64,
};
pub const PhysicalDeviceTimelineSemaphoreFeatures = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    timelineSemaphore: u32,
};
pub const PhysicalDeviceTimelineSemaphoreProperties = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    maxTimelineSemaphoreValueDifference: u64,
};
pub const SemaphoreTypeCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    semaphoreType: u32,
    initialValue: u64,
};
pub const TimelineSemaphoreSubmitInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    waitSemaphoreValueCount: u32,
    pWaitSemaphoreValues: ?[*]const u64,
    signalSemaphoreValueCount: u32,
    pSignalSemaphoreValues: ?[*]const u64,
};
pub const SemaphoreWaitInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    semaphoreCount: u32,
    pSemaphores: ?[*]const u64,
    pValues: ?[*]const u64,
};
pub const SemaphoreSignalInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    semaphore: u64,
    value: u64,
};
pub const BindBufferMemoryInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    buffer: u64,
    memory: u64,
    memoryOffset: u64,
};
pub const BufferMemoryRequirementsInfo2 = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    buffer: u64,
};
pub const MemoryRequirements2 = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    memoryRequirements: MemoryRequirements,
};
pub const MemoryDedicatedRequirements = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    prefersDedicatedAllocation: u32,
    requiresDedicatedAllocation: u32,
};
pub const DeviceQueueInfo2 = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
    queueIndex: u32,
};
pub const PhysicalDeviceGroupProperties = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    physicalDeviceCount: u32,
    physicalDevices: [32]?*anyopaque,
    subsetAllocation: u32,
};
pub const ExternalMemoryProperties = extern struct {
    externalMemoryFeatures: u32,
    exportFromImportedHandleTypes: u32,
    compatibleHandleTypes: u32,
};
pub const ExternalBufferProperties = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    externalMemoryProperties: ExternalMemoryProperties,
};
pub const ExternalFenceProperties = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    exportFromImportedHandleTypes: u32,
    compatibleHandleTypes: u32,
    externalFenceFeatures: u32,
};
pub const ExternalSemaphoreProperties = extern struct {
    sType: u32,
    pNext: ?*anyopaque,
    exportFromImportedHandleTypes: u32,
    compatibleHandleTypes: u32,
    externalSemaphoreFeatures: u32,
};
pub const PhysicalDeviceExternalBufferInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    usage: u32,
    handleType: u32,
};
pub const PhysicalDeviceExternalFenceInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    handleType: u32,
};
pub const PhysicalDeviceExternalSemaphoreInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    handleType: u32,
};
pub const PhysicalDeviceImageFormatInfo2 = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    format: u32,
    @"type": u32,
    tiling: u32,
    usage: u32,
    flags: u32,
};
pub const PhysicalDeviceSparseImageFormatInfo2 = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    format: u32,
    @"type": u32,
    samples: u32,
    usage: u32,
    tiling: u32,
};
pub const DispatchIndirectCommand = extern struct {
    x: u32,
    y: u32,
    z: u32,
};

pub const StructureType = struct {
    pub const application_info: u32 = 0;
    pub const instance_create_info: u32 = 1;
    pub const device_queue_create_info: u32 = 2;
    pub const device_create_info: u32 = 3;
    pub const submit_info: u32 = 4;
    pub const memory_allocate_info: u32 = 5;
    pub const mapped_memory_range: u32 = 6;
    pub const fence_create_info: u32 = 8;
    pub const semaphore_create_info: u32 = 9;
    pub const buffer_create_info: u32 = 12;
    pub const shader_module_create_info: u32 = 16;
    pub const pipeline_cache_create_info: u32 = 17;
    pub const pipeline_shader_stage_create_info: u32 = 18;
    pub const compute_pipeline_create_info: u32 = 29;
    pub const pipeline_layout_create_info: u32 = 30;
    pub const descriptor_set_layout_create_info: u32 = 32;
    pub const descriptor_pool_create_info: u32 = 33;
    pub const descriptor_set_allocate_info: u32 = 34;
    pub const write_descriptor_set: u32 = 35;
    pub const copy_descriptor_set: u32 = 36;
    pub const command_pool_create_info: u32 = 39;
    pub const command_buffer_allocate_info: u32 = 40;
    pub const command_buffer_inheritance_info: u32 = 41;
    pub const command_buffer_begin_info: u32 = 42;
    pub const memory_barrier: u32 = 46;
    pub const loader_instance_create_info: u32 = 47;
    pub const loader_device_create_info: u32 = 48;
    pub const physical_device_subgroup_properties: u32 = 1000094000;
    pub const bind_buffer_memory_info: u32 = 1000157000;
    pub const memory_dedicated_requirements: u32 = 1000127000;
    pub const buffer_memory_requirements_info_2: u32 = 1000146000;
    pub const memory_requirements_2: u32 = 1000146003;
    pub const physical_device_features_2: u32 = 1000059000;
    pub const physical_device_properties_2: u32 = 1000059001;
    pub const format_properties_2: u32 = 1000059002;
    pub const image_format_properties_2: u32 = 1000059003;
    pub const physical_device_image_format_info_2: u32 = 1000059004;
    pub const queue_family_properties_2: u32 = 1000059005;
    pub const physical_device_memory_properties_2: u32 = 1000059006;
    pub const sparse_image_format_properties_2: u32 = 1000059007;
    pub const physical_device_sparse_image_format_info_2: u32 = 1000059008;
    pub const device_queue_info_2: u32 = 1000145003;
    pub const physical_device_id_properties: u32 = 1000071004;
    pub const physical_device_group_properties: u32 = 1000070000;
    pub const physical_device_maintenance_3_properties: u32 = 1000168000;
    pub const physical_device_timeline_semaphore_features: u32 = 1000207000;
    pub const physical_device_timeline_semaphore_properties: u32 = 1000207001;
    pub const semaphore_type_create_info: u32 = 1000207002;
    pub const timeline_semaphore_submit_info: u32 = 1000207003;
    pub const semaphore_wait_info: u32 = 1000207004;
    pub const semaphore_signal_info: u32 = 1000207005;
    pub const external_buffer_properties: u32 = 1000071003;
    pub const external_fence_properties: u32 = 1000112001;
    pub const external_semaphore_properties: u32 = 1000076001;
    pub const physical_device_external_buffer_info: u32 = 1000071002;
    pub const physical_device_external_fence_info: u32 = 1000112000;
    pub const physical_device_external_semaphore_info: u32 = 1000076000;
    pub const physical_device_vulkan_1_1_features: u32 = 49;
    pub const physical_device_vulkan_1_2_features: u32 = 51;
    pub const physical_device_driver_properties: u32 = 1000196000;
    pub const image_create_info: u32 = 14;
    pub const image_view_create_info: u32 = 15;
    pub const pipeline_vertex_input_state_create_info: u32 = 19;
    pub const graphics_pipeline_create_info: u32 = 28;
    pub const sampler_create_info: u32 = 31;
    pub const framebuffer_create_info: u32 = 37;
    pub const render_pass_create_info: u32 = 38;
    pub const render_pass_begin_info: u32 = 43;
    pub const bind_image_memory_info: u32 = 1000157001;
    pub const image_memory_requirements_info_2: u32 = 1000146001;
    pub const descriptor_update_template_create_info: u32 = 1000085000;
    pub const physical_device_multiview_features: u32 = 1000053001;
    pub const physical_device_multiview_properties: u32 = 1000053002;
    pub const physical_device_point_clipping_properties: u32 = 1000117000;
    pub const physical_device_protected_memory_properties: u32 = 1000145001;
    pub const memory_dedicated_allocate_info: u32 = 1000127001;
    pub const physical_device_external_image_format_info: u32 = 1000071000;
    pub const external_image_format_properties: u32 = 1000071001;
    pub const external_memory_buffer_create_info: u32 = 1000072000;
    pub const external_memory_image_create_info: u32 = 1000072001;
    pub const export_memory_allocate_info: u32 = 1000072002;
    pub const export_fence_create_info: u32 = 1000113000;
    pub const export_semaphore_create_info: u32 = 1000077000;
    pub const image_format_list_create_info: u32 = 1000147000;
    pub const import_memory_fd_info_khr: u32 = 1000074000;
    pub const memory_fd_properties_khr: u32 = 1000074001;
    pub const memory_get_fd_info_khr: u32 = 1000074002;
    pub const import_semaphore_fd_info_khr: u32 = 1000079000;
    pub const semaphore_get_fd_info_khr: u32 = 1000079001;
    pub const import_fence_fd_info_khr: u32 = 1000115000;
    pub const fence_get_fd_info_khr: u32 = 1000115001;
    pub const drm_format_modifier_properties_list_ext: u32 = 1000158000;
    pub const physical_device_image_drm_format_modifier_info_ext: u32 = 1000158002;
    pub const image_drm_format_modifier_list_create_info_ext: u32 = 1000158003;
    pub const image_drm_format_modifier_explicit_create_info_ext: u32 = 1000158004;
    pub const image_drm_format_modifier_properties_ext: u32 = 1000158005;
    pub const swapchain_create_info_khr: u32 = 1000001000;
    pub const present_info_khr: u32 = 1000001001;
    pub const device_group_present_capabilities_khr: u32 = 1000060007;
    pub const image_swapchain_create_info_khr: u32 = 1000060008;
    pub const bind_image_memory_swapchain_info_khr: u32 = 1000060009;
    pub const acquire_next_image_info_khr: u32 = 1000060010;
    pub const wayland_surface_create_info_khr: u32 = 1000006000;
    pub const physical_device_surface_info_2_khr: u32 = 1000119000;
    pub const surface_capabilities_2_khr: u32 = 1000119001;
    pub const surface_format_2_khr: u32 = 1000119002;
};

pub const result = struct {
    pub const success: Result = 0;
    pub const not_ready: Result = 1;
    pub const timeout: Result = 2;
    pub const incomplete: Result = 5;
    pub const error_out_of_host_memory: Result = -1;
    pub const error_out_of_device_memory: Result = -2;
    pub const error_initialization_failed: Result = -3;
    pub const error_device_lost: Result = -4;
    pub const error_memory_map_failed: Result = -5;
    pub const error_layer_not_present: Result = -6;
    pub const error_extension_not_present: Result = -7;
    pub const error_feature_not_present: Result = -8;
    pub const error_incompatible_driver: Result = -9;
    pub const error_too_many_objects: Result = -10;
    pub const error_format_not_supported: Result = -11;
    pub const error_fragmented_pool: Result = -12;
    pub const error_unknown: Result = -13;
    pub const error_validation_failed: Result = -1000011001;
    pub const error_out_of_pool_memory: Result = -1000069000;
    pub const error_invalid_external_handle: Result = -1000072003;
    pub const error_invalid_opaque_capture_address: Result = -1000257000;
    pub const error_fragmentation: Result = -1000161000;
    pub const error_not_permitted: Result = -1000174001;
    pub const error_surface_lost_khr: Result = -1000000000;
    pub const error_native_window_in_use_khr: Result = -1000000001;
    pub const error_out_of_date_khr: Result = -1000001004;
    pub const error_incompatible_display_khr: Result = -1000003001;
    pub const error_invalid_shader_nv: Result = -1000012000;
    pub const error_image_usage_not_supported_khr: Result = -1000023000;
    pub const error_video_picture_layout_not_supported_khr: Result = -1000023001;
    pub const error_video_profile_operation_not_supported_khr: Result = -1000023002;
    pub const error_video_profile_format_not_supported_khr: Result = -1000023003;
    pub const error_video_profile_codec_not_supported_khr: Result = -1000023004;
    pub const error_video_std_version_not_supported_khr: Result = -1000023005;
    pub const error_invalid_drm_format_modifier_plane_layout_ext: Result = -1000158000;
    pub const error_present_timing_queue_full_ext: Result = -1000208000;
    pub const error_full_screen_exclusive_mode_lost_ext: Result = -1000255000;
    pub const error_invalid_video_std_parameters_khr: Result = -1000299000;
    pub const error_compression_exhausted_ext: Result = -1000338000;
    pub const error_not_enough_space_khr: Result = -1000483000;
};

// ── Images, render passes and graphics pipelines ───────────────────────────

pub const Offset2D = extern struct { x: i32, y: i32 };
pub const Extent2D = extern struct { width: u32, height: u32 };
pub const Offset3D = extern struct { x: i32, y: i32, z: i32 };
pub const Rect2D = extern struct { offset: Offset2D, extent: Extent2D };
pub const Viewport = extern struct { x: f32, y: f32, width: f32, height: f32, minDepth: f32, maxDepth: f32 };

pub const ImageCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    imageType: u32,
    format: u32,
    extent: Extent3D,
    mipLevels: u32,
    arrayLayers: u32,
    samples: u32,
    tiling: u32,
    usage: u32,
    sharingMode: u32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
    initialLayout: u32,
};
pub const ComponentMapping = extern struct { r: u32, g: u32, b: u32, a: u32 };
pub const ImageSubresourceRange = extern struct { aspectMask: u32, baseMipLevel: u32, levelCount: u32, baseArrayLayer: u32, layerCount: u32 };
pub const ImageViewCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    image: u64,
    viewType: u32,
    format: u32,
    components: ComponentMapping,
    subresourceRange: ImageSubresourceRange,
};
pub const SamplerCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    magFilter: u32,
    minFilter: u32,
    mipmapMode: u32,
    addressModeU: u32,
    addressModeV: u32,
    addressModeW: u32,
    mipLodBias: f32,
    anisotropyEnable: u32,
    maxAnisotropy: f32,
    compareEnable: u32,
    compareOp: u32,
    minLod: f32,
    maxLod: f32,
    borderColor: u32,
    unnormalizedCoordinates: u32,
};
pub const ImageSubresource = extern struct { aspectMask: u32, mipLevel: u32, arrayLayer: u32 };
pub const SubresourceLayout = extern struct { offset: u64, size: u64, rowPitch: u64, arrayPitch: u64, depthPitch: u64 };
pub const ImageSubresourceLayers = extern struct { aspectMask: u32, mipLevel: u32, baseArrayLayer: u32, layerCount: u32 };
pub const BufferImageCopy = extern struct {
    bufferOffset: u64,
    bufferRowLength: u32,
    bufferImageHeight: u32,
    imageSubresource: ImageSubresourceLayers,
    imageOffset: Offset3D,
    imageExtent: Extent3D,
};
pub const ImageCopy = extern struct {
    srcSubresource: ImageSubresourceLayers,
    srcOffset: Offset3D,
    dstSubresource: ImageSubresourceLayers,
    dstOffset: Offset3D,
    extent: Extent3D,
};
pub const ImageBlit = extern struct {
    srcSubresource: ImageSubresourceLayers,
    srcOffsets: [2]Offset3D,
    dstSubresource: ImageSubresourceLayers,
    dstOffsets: [2]Offset3D,
};
pub const ClearColorValue = extern union { float32: [4]f32, int32: [4]i32, uint32: [4]u32 };
pub const ClearDepthStencilValue = extern struct { depth: f32, stencil: u32 };
pub const ClearValue = extern union { color: ClearColorValue, depthStencil: ClearDepthStencilValue };
pub const ClearAttachment = extern struct { aspectMask: u32, colorAttachment: u32, clearValue: ClearValue };
pub const ClearRect = extern struct { rect: Rect2D, baseArrayLayer: u32, layerCount: u32 };

pub const AttachmentDescription = extern struct {
    flags: u32,
    format: u32,
    samples: u32,
    loadOp: u32,
    storeOp: u32,
    stencilLoadOp: u32,
    stencilStoreOp: u32,
    initialLayout: u32,
    finalLayout: u32,
};
pub const AttachmentReference = extern struct { attachment: u32, layout: u32 };
pub const SubpassDescription = extern struct {
    flags: u32,
    pipelineBindPoint: u32,
    inputAttachmentCount: u32,
    pInputAttachments: ?[*]const AttachmentReference,
    colorAttachmentCount: u32,
    pColorAttachments: ?[*]const AttachmentReference,
    pResolveAttachments: ?[*]const AttachmentReference,
    pDepthStencilAttachment: ?*const AttachmentReference,
    preserveAttachmentCount: u32,
    pPreserveAttachments: ?[*]const u32,
};
pub const SubpassDependency = extern struct {
    srcSubpass: u32,
    dstSubpass: u32,
    srcStageMask: u32,
    dstStageMask: u32,
    srcAccessMask: u32,
    dstAccessMask: u32,
    dependencyFlags: u32,
};
pub const RenderPassCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    attachmentCount: u32,
    pAttachments: ?[*]const AttachmentDescription,
    subpassCount: u32,
    pSubpasses: ?[*]const SubpassDescription,
    dependencyCount: u32,
    pDependencies: ?[*]const SubpassDependency,
};
pub const FramebufferCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    renderPass: u64,
    attachmentCount: u32,
    pAttachments: ?[*]const u64,
    width: u32,
    height: u32,
    layers: u32,
};
pub const RenderPassBeginInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    renderPass: u64,
    framebuffer: u64,
    renderArea: Rect2D,
    clearValueCount: u32,
    pClearValues: ?[*]const ClearValue,
};

pub const VertexInputBindingDescription = extern struct { binding: u32, stride: u32, inputRate: u32 };
pub const VertexInputAttributeDescription = extern struct { location: u32, binding: u32, format: u32, offset: u32 };
pub const PipelineVertexInputStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    vertexBindingDescriptionCount: u32,
    pVertexBindingDescriptions: ?[*]const VertexInputBindingDescription,
    vertexAttributeDescriptionCount: u32,
    pVertexAttributeDescriptions: ?[*]const VertexInputAttributeDescription,
};
pub const PipelineInputAssemblyStateCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, topology: u32, primitiveRestartEnable: u32 };
pub const PipelineViewportStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    viewportCount: u32,
    pViewports: ?[*]const Viewport,
    scissorCount: u32,
    pScissors: ?[*]const Rect2D,
};
pub const PipelineRasterizationStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    depthClampEnable: u32,
    rasterizerDiscardEnable: u32,
    polygonMode: u32,
    cullMode: u32,
    frontFace: u32,
    depthBiasEnable: u32,
    depthBiasConstantFactor: f32,
    depthBiasClamp: f32,
    depthBiasSlopeFactor: f32,
    lineWidth: f32,
};
pub const PipelineMultisampleStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    rasterizationSamples: u32,
    sampleShadingEnable: u32,
    minSampleShading: f32,
    pSampleMask: ?[*]const u32,
    alphaToCoverageEnable: u32,
    alphaToOneEnable: u32,
};
pub const StencilOpState = extern struct { failOp: u32, passOp: u32, depthFailOp: u32, compareOp: u32, compareMask: u32, writeMask: u32, reference: u32 };
pub const PipelineDepthStencilStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    depthTestEnable: u32,
    depthWriteEnable: u32,
    depthCompareOp: u32,
    depthBoundsTestEnable: u32,
    stencilTestEnable: u32,
    front: StencilOpState,
    back: StencilOpState,
    minDepthBounds: f32,
    maxDepthBounds: f32,
};
pub const PipelineColorBlendAttachmentState = extern struct {
    blendEnable: u32,
    srcColorBlendFactor: u32,
    dstColorBlendFactor: u32,
    colorBlendOp: u32,
    srcAlphaBlendFactor: u32,
    dstAlphaBlendFactor: u32,
    alphaBlendOp: u32,
    colorWriteMask: u32,
};
pub const PipelineColorBlendStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    logicOpEnable: u32,
    logicOp: u32,
    attachmentCount: u32,
    pAttachments: ?[*]const PipelineColorBlendAttachmentState,
    blendConstants: [4]f32,
};
pub const PipelineDynamicStateCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, dynamicStateCount: u32, pDynamicStates: ?[*]const u32 };
pub const GraphicsPipelineCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stageCount: u32,
    pStages: ?[*]const PipelineShaderStageCreateInfo,
    pVertexInputState: ?*const PipelineVertexInputStateCreateInfo,
    pInputAssemblyState: ?*const PipelineInputAssemblyStateCreateInfo,
    pTessellationState: ?*const anyopaque,
    pViewportState: ?*const PipelineViewportStateCreateInfo,
    pRasterizationState: ?*const PipelineRasterizationStateCreateInfo,
    pMultisampleState: ?*const PipelineMultisampleStateCreateInfo,
    pDepthStencilState: ?*const PipelineDepthStencilStateCreateInfo,
    pColorBlendState: ?*const PipelineColorBlendStateCreateInfo,
    pDynamicState: ?*const PipelineDynamicStateCreateInfo,
    layout: u64,
    renderPass: u64,
    subpass: u32,
    basePipelineHandle: u64,
    basePipelineIndex: i32,
};
pub const ImageMemoryRequirementsInfo2 = extern struct { sType: u32, pNext: ?*const anyopaque, image: u64 };
pub const BindImageMemoryInfo = extern struct { sType: u32, pNext: ?*const anyopaque, image: u64, memory: u64, memoryOffset: u64 };
pub const DescriptorUpdateTemplateEntry = extern struct {
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
    descriptorType: u32,
    offset: usize,
    stride: usize,
};
pub const DescriptorUpdateTemplateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    descriptorUpdateEntryCount: u32,
    pDescriptorUpdateEntries: ?[*]const DescriptorUpdateTemplateEntry,
    templateType: u32,
    descriptorSetLayout: u64,
    pipelineBindPoint: u32,
    pipelineLayout: u64,
    set: u32,
};
pub const DrawIndirectCommand = extern struct { vertexCount: u32, instanceCount: u32, firstVertex: u32, firstInstance: u32 };
pub const DrawIndexedIndirectCommand = extern struct { indexCount: u32, instanceCount: u32, firstIndex: u32, vertexOffset: i32, firstInstance: u32 };
pub const PhysicalDeviceMultiviewFeatures = extern struct { sType: u32, pNext: ?*anyopaque, multiview: u32, multiviewGeometryShader: u32, multiviewTessellationShader: u32 };
pub const PhysicalDeviceMultiviewProperties = extern struct { sType: u32, pNext: ?*anyopaque, maxMultiviewViewCount: u32, maxMultiviewInstanceIndex: u32 };
pub const PhysicalDevicePointClippingProperties = extern struct { sType: u32, pNext: ?*anyopaque, pointClippingBehavior: u32 };
pub const PhysicalDeviceProtectedMemoryProperties = extern struct { sType: u32, pNext: ?*anyopaque, protectedNoFault: u32 };

// ── External memory, semaphores and fences (fds), DRM format modifiers ────

pub const ExternalHandle = struct {
    /// VkExternalMemoryHandleTypeFlagBits, ...Semaphore..., ...Fence...
    pub const opaque_fd: u32 = 0x1;
    pub const dma_buf: u32 = 0x200;
    pub const semaphore_sync_fd: u32 = 0x10;
    pub const fence_sync_fd: u32 = 0x8;
    /// VkExternalMemoryFeatureFlagBits
    pub const memory_dedicated_only: u32 = 0x1;
    pub const memory_exportable: u32 = 0x2;
    pub const memory_importable: u32 = 0x4;
    /// VkExternalSemaphoreFeatureFlagBits (and the fence's: the same bits)
    pub const exportable: u32 = 0x1;
    pub const importable: u32 = 0x2;
};
/// VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
pub const TILING_DRM_FORMAT_MODIFIER: u32 = 1000158000;
/// DRM_FORMAT_MOD_LINEAR
pub const DRM_MOD_LINEAR: u64 = 0;

pub const PhysicalDeviceExternalImageFormatInfo = extern struct { sType: u32, pNext: ?*const anyopaque, handleType: u32 };
pub const ExternalImageFormatProperties = extern struct { sType: u32, pNext: ?*anyopaque, externalMemoryProperties: ExternalMemoryProperties };
pub const ExternalMemoryCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, handleTypes: u32 };
pub const ExportMemoryAllocateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, handleTypes: u32 };
pub const ImportMemoryFdInfoKHR = extern struct { sType: u32, pNext: ?*const anyopaque, handleType: u32, fd: i32 };
pub const MemoryGetFdInfoKHR = extern struct { sType: u32, pNext: ?*const anyopaque, memory: u64, handleType: u32 };
pub const MemoryFdPropertiesKHR = extern struct { sType: u32, pNext: ?*anyopaque, memoryTypeBits: u32 };
pub const MemoryDedicatedAllocateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, image: u64, buffer: u64 };
pub const ExportSemaphoreCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, handleTypes: u32 };
pub const SemaphoreGetFdInfoKHR = extern struct { sType: u32, pNext: ?*const anyopaque, semaphore: u64, handleType: u32 };
pub const ImportSemaphoreFdInfoKHR = extern struct { sType: u32, pNext: ?*const anyopaque, semaphore: u64, flags: u32, handleType: u32, fd: i32 };
pub const FenceGetFdInfoKHR = extern struct { sType: u32, pNext: ?*const anyopaque, fence: u64, handleType: u32 };
pub const ImportFenceFdInfoKHR = extern struct { sType: u32, pNext: ?*const anyopaque, fence: u64, flags: u32, handleType: u32, fd: i32 };
pub const DrmFormatModifierPropertiesEXT = extern struct { drmFormatModifier: u64, drmFormatModifierPlaneCount: u32, drmFormatModifierTilingFeatures: u32 };
pub const DrmFormatModifierPropertiesListEXT = extern struct { sType: u32, pNext: ?*anyopaque, drmFormatModifierCount: u32, pDrmFormatModifierProperties: ?[*]DrmFormatModifierPropertiesEXT };
pub const PhysicalDeviceImageDrmFormatModifierInfoEXT = extern struct { sType: u32, pNext: ?*const anyopaque, drmFormatModifier: u64, sharingMode: u32, queueFamilyIndexCount: u32, pQueueFamilyIndices: ?[*]const u32 };
pub const ImageDrmFormatModifierListCreateInfoEXT = extern struct { sType: u32, pNext: ?*const anyopaque, drmFormatModifierCount: u32, pDrmFormatModifiers: ?[*]const u64 };
pub const ImageDrmFormatModifierExplicitCreateInfoEXT = extern struct { sType: u32, pNext: ?*const anyopaque, drmFormatModifier: u64, drmFormatModifierPlaneCount: u32, pPlaneLayouts: ?[*]const SubresourceLayout };
pub const ImageDrmFormatModifierPropertiesEXT = extern struct { sType: u32, pNext: ?*anyopaque, drmFormatModifier: u64 };

// ── Window system integration (VK_KHR_surface, _wayland_surface, _swapchain) ──

/// VkIcdSurfaceWayland (vk_icd.h): what the loader makes of
/// vkCreateWaylandSurfaceKHR and hands the driver as the VkSurfaceKHR.
pub const IcdSurfaceWayland = extern struct { platform: u32, display: ?*anyopaque, surface: ?*anyopaque };
pub const ICD_WSI_PLATFORM_WAYLAND: u32 = 1;
pub const SurfaceCapabilitiesKHR = extern struct {
    minImageCount: u32,
    maxImageCount: u32,
    currentExtent: Extent2D,
    minImageExtent: Extent2D,
    maxImageExtent: Extent2D,
    maxImageArrayLayers: u32,
    supportedTransforms: u32,
    currentTransform: u32,
    supportedCompositeAlpha: u32,
    supportedUsageFlags: u32,
};
pub const SurfaceFormatKHR = extern struct { format: u32, colorSpace: u32 };
pub const SwapchainCreateInfoKHR = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    surface: u64,
    minImageCount: u32,
    imageFormat: u32,
    imageColorSpace: u32,
    imageExtent: Extent2D,
    imageArrayLayers: u32,
    imageUsage: u32,
    imageSharingMode: u32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
    preTransform: u32,
    compositeAlpha: u32,
    presentMode: u32,
    clipped: u32,
    oldSwapchain: u64,
};
pub const PresentInfoKHR = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?[*]const u64,
    swapchainCount: u32,
    pSwapchains: ?[*]const u64,
    pImageIndices: ?[*]const u32,
    pResults: ?[*]Result,
};
pub const AcquireNextImageInfoKHR = extern struct { sType: u32, pNext: ?*const anyopaque, swapchain: u64, timeout: u64, semaphore: u64, fence: u64, deviceMask: u32 };
pub const DeviceGroupPresentCapabilitiesKHR = extern struct { sType: u32, pNext: ?*anyopaque, presentMask: [32]u32, modes: u32 };
pub const ImageSwapchainCreateInfoKHR = extern struct { sType: u32, pNext: ?*const anyopaque, swapchain: u64 };
pub const BindImageMemorySwapchainInfoKHR = extern struct { sType: u32, pNext: ?*const anyopaque, swapchain: u64, imageIndex: u32 };
pub const PhysicalDeviceSurfaceInfo2KHR = extern struct { sType: u32, pNext: ?*const anyopaque, surface: u64 };
pub const SurfaceCapabilities2KHR = extern struct { sType: u32, pNext: ?*anyopaque, surfaceCapabilities: SurfaceCapabilitiesKHR };
pub const SurfaceFormat2KHR = extern struct { sType: u32, pNext: ?*anyopaque, surfaceFormat: SurfaceFormatKHR };
