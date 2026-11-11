# Galaxy's Vulkan driver: the plan

The goal: Firefox's WebGPU (wgpu's Vulkan backend, `dom.webgpu.enabled` and
`gfx.webgpu.ignore-blocklist`) and, later, Firefox's Vulkan video decode, on
the PC's RTX 5070 (GB206, sm_120), through this ICD. Pure Sig, allocation-free,
no Mesa; zpm is pinned by Galaxy, never vendored.

## Where it stands (milestone 1, branch `sig-vulkan`)

- `src/spirv`: SPIR-V compute shaders to KIR (naga's WGSL output first).
- `src/vk/icd.sig`: a Vulkan 1.0 compute device (instance 1.1) with
  VK_KHR_maintenance1, VK_KHR_storage_buffer_storage_class and
  VK_KHR_timeline_semaphore; buffers, descriptors, compute pipelines, command
  buffers, submission, fences, semaphores. One COMPUTE|TRANSFER queue family.
- `src/vk/libgalaxy_vk.sig`: libvulkan_galaxy.so, the loader's ICD interface
  version 5; `galaxy_icd.json` its manifest.
- Tests (`sig build test-vk`): the front end on naga's SPIR-V on KIR's
  interpreter and the emulated RTX; the ICD through its entry points.

**wgpu does not take this adapter yet.** `expose_adapter` (wgpu-hal 30,
`vulkan/adapter.rs`) hides an adapter whose first queue family lacks
GRAPHICS. Everything below is what it takes to get past that and then to be
useful to Firefox.

## 1. Galaxy integration (small, first)

- `scripts/build-vk.sh` in Galaxy, as `build-gl.sh`: `sig build-lib -dynamic
  -target x86_64-linux-none --name vulkan_galaxy` over the pinned zpm (the
  wiring is in `libgalaxy_vk.sig`'s header). Install as
  `/usr/lib/libvulkan_galaxy.so` and `galaxy_icd.json` as
  `/usr/share/vulkan/icd.d/galaxy_icd.json`. Alpine's `vulkan-loader` package
  only, no Mesa ICDs.
- Let the render node hand its PCI ids to `icd.Gpu.vendor_id/device_id`
  (wgpu uses vendor/device ids for workarounds and for `AdapterInfo`).
- The kernel gate: apps reach the RTX only where `galaxy_uspace.mayUseGpu`
  says so, as for EGL. A second process context on the RTX next to EGL's
  (Firefox has both: WebRender on GL, WebGPU on Vulkan) needs a check on the
  PC (channels, memory).
- First on-hardware test: a tiny compute app (or `vulkaninfo`, with
  `VK_LOADER_DEBUG=driver`) on the PC.

## 2. Compute completeness (what WebGPU compute shaders still hit)

- **Atomics**: KIR has add, min, max, exchange. WGSL's `atomicAnd/Or/Xor`
  and `atomicCompareExchangeWeak` need KIR atom ops `and`, `or`, `xor`,
  `cmpxchg` in `src/gpu` (kir.sig, the interpreter, kir_sm120 `ATOM`/`ATOMS`,
  kir_ir3, kir_gcn4). This is a src/gpu change across every backend: its own
  PR.
- **Subgroups** (`wgt::Features::SUBGROUP`): OpGroupNonUniform* (elect,
  ballot, broadcast, shuffle, arithmetic) over KIR's `shfl` and `vote`, and
  ballot (KIR has no ballot: another src/gpu op). Report
  `VkPhysicalDeviceSubgroupProperties.supportedOperations` truthfully as they land.
- **f16** (`SHADER_F16`, VK_KHR_shader_float16_int8, VK_KHR_16bit_storage):
  KIR has f16 registers; the front end needs 16-bit loads/stores and f16
  arithmetic.
- **Dispatch indirect on the GPU**: today the counts are copied back and read
  by the CPU (a wait inside vkQueueSubmit). The RTX can launch from a QMD the
  GPU writes; needs a `gpu.Device` dispatch-indirect hook (src/gpu).
- **Zero-initialized workgroup memory**
  (VK_KHR_zero_initialize_workgroup_memory): naga's polyfill works now; the
  extension would let wgpu skip it.
- **Pipeline cache data**: kir_sm120 binaries keyed by a hash of the SPIR-V
  and the spec constants (compiles take the driver lock and are slow for big
  shaders).
- **Timestamp queries** (`TIMESTAMP_QUERY`): query pools, `vkCmdWriteTimestamp`,
  `vkCmdResetQueryPool`, `vkGetQueryPoolResults`, `vkCmdCopyQueryPoolResults`;
  `gpu.Device.timestampNs` exists. Then set the queue's `timestampValidBits` (>= 36).
- **Waits without the lock**: `vkWaitForFences` polls with the driver lock let
  go between 1 ms waits; a futex wait on the node's fence fd is better.
- **Wait-before-signal** of timeline semaphores across threads: today a
  submission waiting on a value only the host will signal spins in
  vkQueueSubmit. A deferred-submission queue (fixed, in .bss) instead.

## 3. Graphics (the GRAPHICS queue flag; wgpu takes the adapter here)

wgpu-hal uses classic render passes and framebuffers (`vkCreateRenderPass`,
`vkCreateFramebuffer`, `vkCmdBeginRenderPass`), not dynamic rendering.

- **Images and memory**: `vkCreateImage`, `vkGetImageMemoryRequirements(2)`,
  `vkBindImageMemory(2)`, image views, linear and optimal tiling (optimal =
  the engine's layout; gfxapi's `engine.sig` images and `texfmt.sig` formats
  first: RGBA8/BGRA8/R8/RG8, the 16F/32F/int ones), `vkGetImageSubresourceLayout`.
- **Formats**: `vkGetPhysicalDeviceFormatProperties` truthful per format.
  WebGPU's required set includes depth formats: wgpu sets
  `WEBGPU_TEXTURE_FORMAT_SUPPORT` only with S8 or D24S8, D24S8 or D32S8, and
  D32 (gfxapi's raster has depth 24 + stencil 8 already).
- **Transfers**: `vkCmdCopyBufferToImage`, `vkCmdCopyImageToBuffer`,
  `vkCmdCopyImage`, `vkCmdBlitImage`, `vkCmdClearColorImage`,
  `vkCmdClearDepthStencilImage`, `vkCmdResolveImage` (wgpu's `CLEAR_TEXTURE`
  is advertised unconditionally). The engine's copy and blit kernels.
- **Samplers**: `vkCreateSampler` over `texture.sig`'s descriptors; sampled
  images, storage images, combined image samplers in descriptor sets; SPIR-V
  OpImage* in the front end (`OpImageSampleImplicitLod`, `OpImageFetch`,
  `OpImageRead/Write`, `OpImageQuerySize`).
- **Graphics pipelines**: vertex and fragment SPIR-V to the raster's KIR
  emitters (as `glsl/gen.sig` and `dxbc/gen.sig` do), vertex input state,
  input assembly, rasterization (cull, front face, depth bias), depth/stencil,
  color blend, dynamic viewport and scissor, blend constants, stencil
  reference. `vkCmdDraw`, `vkCmdDrawIndexed`, the indirect forms,
  `vkCmdBindVertexBuffers`, `vkCmdBindIndexBuffer`.
- **Render passes**: load/store ops, clears at begin, subpass 0 only at
  first, resolves later (MSAA: the raster has none yet).
- Core 1.0 features wgpu turns into downlevel flags, each only when true:
  `independentBlend`, `imageCubeArray`, `sampleRateShading`,
  `fragmentStoresAndAtomics`, `fullDrawIndexUint32`, `depthBiasClamp`,
  `samplerAnisotropy`.
- Limits then become real: `maxImageDimension*` (WebGPU's defaults: 8192 2D,
  2048 3D, 256 layers), vertex input limits, `maxColorAttachments`, sample counts.

Vulkan version: once images and graphics are in, report 1.1 (VK 1.1 needs
`multiview`, descriptor update templates, `vkGetDescriptorSetLayoutSupport`,
the 1.1 entry points; wgpu takes the 1.1 paths for maintenance1/2/3 then).
Not 1.2 while `VK_KHR_driver_properties` would carry conformance version 0:
wgpu hides such an adapter unless `ALLOW_UNDERLYING_NONCOMPLIANT_ADAPTER`
(adapter.rs, `driver.conformance_version.major == 0`).

## 4. Presentation (Wayland swapchain)

wgpu's instance asks for `VK_KHR_surface`, `VK_KHR_wayland_surface` (and
xlib/xcb), `VK_EXT_swapchain_colorspace`, `VK_KHR_get_physical_device_properties2`,
`VK_EXT_debug_utils` (each only if offered). Device: `VK_KHR_swapchain` is
always in wgpu's list (dropped quietly when absent; then wgpu has no surfaces).

- Instance: `VK_KHR_surface` + `VK_KHR_wayland_surface`. The loader makes the
  `VkSurfaceKHR` (its `VkIcdSurfaceWayland`: display and surface pointers);
  the ICD answers `vkGetPhysicalDeviceSurfaceSupportKHR`,
  `...SurfaceCapabilitiesKHR`, `...SurfaceFormatsKHR`, `...SurfacePresentModesKHR`.
- Device: `VK_KHR_swapchain`: `vkCreateSwapchainKHR` over gfxapi's
  `wayland.sig` (zwp_linux_dmabuf_v1 through the app's own libwayland-client,
  found by name: `dl.sig`), images as engine images with PRIME export,
  `vkAcquireNextImageKHR`, `vkQueuePresentKHR` (attach, damage, frame,
  commit), FIFO and MAILBOX. `VK_KHR_swapchain_mutable_format` for wgpu's
  `SURFACE_VIEW_FORMATS`.

## 5. Firefox's WebGPU presentation (dma-bufs)

Firefox's GPU process does not present through a Vulkan swapchain: it renders
into textures it exports and hands to WebRender (and the compositor) as
dma-bufs. wgpu-hal enables these when offered (adapter.rs: `external_memory_fd`,
`external_memory_dma_buf`, `image_drm_format_modifier`; wgpu's
`VULKAN_EXTERNAL_MEMORY_DMA_BUF` feature needs all three):

- `VK_KHR_external_memory_fd`, `VK_EXT_external_memory_dma_buf`:
  `vkGetMemoryFdKHR` (PRIME export: node.sig has it),
  `vkGetMemoryFdPropertiesKHR`, imports through `VkImportMemoryFdInfoKHR`
  (PRIME import + G_INFO, as EGL's dma-buf import).
- `VK_EXT_image_drm_format_modifier`: linear (and later the RTX's block-linear
  modifiers, which EGL's side must sample too).
- `VK_KHR_external_semaphore_fd` / sync_file (`G_FENCE_FD`) so WebRender
  waits for WebGPU's frame instead of the CPU waiting.
- `vkGetPhysicalDeviceExternalBufferProperties` and friends answer truthfully then.

## 6. wgpu's exact extension list (wgpu-hal 30, `get_required_extensions`)

For a device API version below 1.1, below 1.2 and below 1.3 respectively,
wgpu asks for (when supported; required ones fail the adapter if missing):

| Extension | wgpu | Here |
|---|---|---|
| VK_KHR_swapchain | always asked | §4 |
| VK_KHR_maintenance1 | required < 1.1 | yes |
| VK_KHR_maintenance2, VK_KHR_maintenance3 | optional < 1.1 | §3 |
| VK_KHR_storage_buffer_storage_class | required < 1.1 | yes |
| VK_KHR_multiview | if MULTIVIEW asked | later |
| VK_KHR_sampler_ycbcr_conversion | if TEXTURE_FORMAT_NV12 asked | §7 |
| VK_KHR_16bit_storage, VK_KHR_shader_draw_parameters | if SHADER_F16/I16 asked | §2 |
| VK_KHR_image_format_list, VK_KHR_driver_properties | optional < 1.2 | §3; driver_properties: see the conformance note |
| VK_KHR_timeline_semaphore | optional < 1.2 | yes |
| VK_EXT_descriptor_indexing | if binding arrays asked | later |
| VK_KHR_shader_float16_int8 | optional | §2 |
| VK_KHR_spirv_1_4 | if needed by features | later (the front end does not depend on the SPIR-V version) |
| VK_KHR_maintenance4, VK_EXT_image_robustness, VK_EXT_subgroup_size_control, VK_KHR_shader_integer_dot_product | optional < 1.3 | dot product: KIR's dot4 |
| VK_KHR_swapchain_mutable_format | optional | §4 |
| VK_EXT_robustness2 | optional | robustBufferAccess2 = our checks, nearly |
| VK_KHR_external_memory_fd, VK_EXT_external_memory_dma_buf, VK_EXT_image_drm_format_modifier | optional | §5 |
| VK_EXT_memory_budget | optional | easy: the node's VRAM numbers |
| VK_KHR_draw_indirect_count, acceleration structures, ray query, mesh shaders, cooperative matrix, atomics int64/float | feature-gated | not planned |

wgpu also reads, at `expose_adapter`: the first queue family's flags
(GRAPHICS), `timestampValidBits`, memory types (it wants a host-visible
coherent type; we have it), `nonCoherentAtomSize`, `maxSamplerAllocationCount`,
format support for depth formats, and limits (`to_wgpu_limits`:
`maxBoundDescriptorSets`, `maxComputeWorkGroupCount`, offset alignments; ours
are 8, 65535 and 16).

## 7. Vulkan Video (last)

Firefox 153+ can decode through Vulkan Video (H.264, H.265, AV1). The RTX's
NVDEC is already driven for VA-API (galaxy#114, zpm#161: Sig VA driver).
Expose a video decode queue family, `VK_KHR_video_queue`,
`VK_KHR_video_decode_queue`, `VK_KHR_video_decode_h264/h265/av1`, video
sessions and parameters over the same NVDEC code, decoded pictures as images
(NV12: `VK_KHR_sampler_ycbcr_conversion` for sampling them). Encode stays out.
