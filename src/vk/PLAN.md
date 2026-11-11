# Galaxy's Vulkan driver: the plan

The goal: Firefox's WebGPU (wgpu's Vulkan backend, `dom.webgpu.enabled` and
`gfx.webgpu.ignore-blocklist`) and, later, Firefox's Vulkan video decode, on
the PC's RTX 5070 (GB206, sm_120), through this ICD. Pure Sig, allocation-free,
no Mesa; zpm is pinned by Galaxy, never vendored.

## Where it stands (milestone 4, branch `sig-vulkan`)

Milestone 4 (WebGPU's features):

- **KIR** (src/gpu, every backend): atom `and`/`or`/`xor`, `cas` (compare
  and swap) and `ballot`, after `ret` so the earlier ops keep their
  numbers. sm_120: ATOMG/ATOMS AND/OR/XOR, ATOMG.E.CAS (no descriptor,
  64-bit [Ra+offset]) and ATOMS.CAS from ptxas's words (testdata
  sm120_kir_raw.txt, tools/gen_sm120_vectors.py), ballot = VOTE.ANY Rd;
  ir3: atomic(.g).and/or/xor/cmpxchg (cmpxchg's pair new, compared, as
  Mesa's a6xx; not checked on hardware); gcn4: buffer_atomic_*/ds_*_rtn;
  ir3 and gcn4 take ballot as kir.expand's 32 votes. The GPU self-test has
  a compare-and-swap and ballots case (run it on the PC: it checks
  ATOMG.E.CAS on the real RTX). `gpu.Dispatch.stamp` (Caps.stamps): the
  GPU's clock written after a dispatch (the RTX's QMD four-word release).
- **Subgroups** (spirv): every OpGroupNonUniform* (elect, all, any,
  all-equal, broadcast(-first), ballot and its bit ops, shuffles, the
  arithmetic as reduce/inclusive/exclusive/clustered, quad broadcast and
  swap) and the mask built-ins; a butterfly when the subgroup is whole,
  else a walk over the active lanes. Reported in compute and fragment
  stages (a fragment kernel's lanes are the raster's pixels; not tested
  in a fragment shader yet).
- **f16** (spirv): f32 registers holding halves, every result rounded to
  half precision, 16 bits in buffers and push constants;
  VK_KHR_shader_float16_int8 (shaderFloat16), VK_KHR_16bit_storage.
- **Atomics** (spirv): and, or, xor, compare-exchange; OpAtomicLoad of
  memory is an atomic add of 0 (no cached word for a spinning reader).
- **Queries**: timestamp (a nop dispatch carrying a stamp: GPU-written,
  no CPU in the path; timestampValidBits 64), occlusion (whether a draw
  ran in the scope: the raster counts no samples), the GPU's
  vkCmdCopyQueryPoolResults (a KIR kernel), vkGetQueryPoolResults,
  vkResetQueryPool. Pipeline statistics are not offered.
- **Formats**: the 16-bit floats, RGBA16 unorm, 8/16-bit snorm and
  integers, RGB10A2 (unorm, uint), RG11B10 ufloat kept widened (a word a
  channel; the transfer kernel's widen/narrow at copies; optimal tiling
  only); storage rgba16float, rgba8snorm/uint/sint, rgba16uint/sint (a
  write rounded to the format); sRGB colour attachments (the fragment
  shader encodes); 32-bit floats filter (FLOAT32_FILTERABLE).
- **Pipeline cache**: compute binaries and their Info under SHA-256 of
  what the compile depends on; vkGetPipelineCacheData/
  vkCreatePipelineCache/vkMergePipelineCaches; the driver's own cache
  besides (8 MiB arena). Graphics pipelines (the raster's kernels) are not
  cached.
- **Indices**: 8-bit (VK_EXT_index_type_uint8; the raster reads any
  size) and a negative vertexOffset (the attributes' offset moved back in
  the raster's 32-bit arithmetic).
- Tests (`sig build test-vk`): 45, from 33 (test-spirv 13, test-vk-icd
  23, the module 5, wsi 3, lib 1); test-gpu, -ir3, -gcn4 and -selftest
  grew with the new ops (the self-test has 25 cases).

Milestone 3 (this branch, Galaxy's `webgpu` branch ships it):

- **Galaxy ships the driver** (galaxy `webgpu`): `galaxy/scripts/build-vk.sh`
  (x86-64: the RTX), `/usr/lib/libvulkan_galaxy.so` and
  `/usr/share/vulkan/icd.d/galaxy_icd.json` in the root image, Alpine's
  `vulkan-loader` (musl only, no Mesa) installed with Firefox, apps on the
  GPU told `VK_DRIVER_FILES=` that manifest, and galaxy.cfg turning
  `dom.webgpu.enabled` and `gfx.webgpu.ignore-blocklist` on under it.
- **Firefox's canvases as dma-bufs** (§5, done): VK_KHR_external_memory_fd,
  VK_EXT_external_memory_dma_buf, VK_EXT_image_drm_format_modifier (linear,
  one plane), VK_KHR_external_semaphore_fd (opaque and sync_file), external
  fence fds; the root's Host (gfxapi's: PRIME export/import, fence files).
- **Swapchains** (§4, done): VK_KHR_surface, VK_KHR_wayland_surface,
  VK_KHR_swapchain over gfxapi's wayland.Display.
- **Storage images** in compute shaders and **4x multisampling** that keeps
  one sample (below).
- Tests: 33 (`test-vk-wsi` added: Firefox's dma-buf sequence step by step,
  a FIFO swapchain on a fake compositor).

- `src/spirv`: SPIR-V to KIR (naga's WGSL output first): compute kernels;
  vertex and fragment stages emitted into gfxapi's raster kernels
  (`Gen.emitStage`), with images and samplers through the caller's texture
  unit (gfxapi's texture.sig), derivatives over quads.
- `src/vk/icd.sig`: a Vulkan 1.1 device (instance 1.1) with one
  GRAPHICS|COMPUTE|TRANSFER queue family; VK_KHR_maintenance1,
  VK_KHR_storage_buffer_storage_class, VK_KHR_timeline_semaphore. Buffers,
  descriptors (buffers, images, samplers, combined, templates), compute and
  graphics pipelines, images and views (1D, 2D, arrays, cube, 3D, mips),
  samplers, render passes and framebuffers (first subpass), draws (direct,
  indexed, indirect), clears, buffer/image copies, blits, submission, fences,
  semaphores. Draws are gfxapi's raster (the GL driver's draw path) on the
  same gpu.Device queue as the driver's kernels.
- `src/vk/format.sig`: the formats, how each is kept (gfxapi engine formats;
  every depth/stencil format as the raster's d24s8 word), what each can do.
- `src/vk/libgalaxy_vk.sig`: libvulkan_galaxy.so, the loader's ICD interface
  version 5; `galaxy_icd.json` its manifest.
- Tests (`sig build test-vk`, 26): the front end on naga's SPIR-V; the ICD
  through its entry points: compute (axpy, reduction), naga's triangle
  (vertex buffer, uniform block, depth read back) on the emulated RTX and
  KIR's interpreter, naga's textured quad (index buffer, mips, sampler, 2D
  array fetched, three fragment shaders), two colour attachments with
  blending and vkCmdClearAttachments. Pixels read back and checked.

**What wgpu (trunk `vulkan/adapter.rs`) sees now**, by reading the code; no
wgpu has run against it yet (the first on-hardware check is §1):

- `expose_adapter` takes it: the first family has GRAPHICS; API 1.1, so
  maintenance1 and storage_buffer_storage_class are core; no
  VK_KHR_driver_properties (so no conformance-version-0 hiding).
- Features: the always-on set (wgpu claims ADDRESS_MODE_CLAMP_TO_BORDER and
  _TO_ZERO unconditionally: the sampler clamps to the edge instead, see
  below), INDIRECT_FIRST_INSTANCE, DEPTH32FLOAT_STENCIL8. Not:
  TIMESTAMP_QUERY (timestampValidBits 0), FLOAT32_FILTERABLE,
  RG11B10UFLOAT_RENDERABLE, BGRA8UNORM_STORAGE, SHADER_F16, SUBGROUP,
  POLYGON_MODE_*, MULTIVIEW, texture compression.
- Downlevel flags: WEBGPU_TEXTURE_FORMAT_SUPPORT (S8, D24S8, D32, D32S8
  depth-stencil attachments, sampled), INDEPENDENT_BLEND,
  FULL_DRAW_INDEX_UINT32, READ_ONLY_DEPTH_STENCIL (1.1), SURFACE_VIEW_FORMATS
  (no swapchain extension), and the unconditional ones. Missing (not
  compliant): CUBE_ARRAY_TEXTURES, ANISOTROPIC_FILTERING,
  FRAGMENT_WRITABLE_STORAGE, MULTISAMPLED_SHADING, DEPTH_BIAS_CLAMP. wgpu-core
  only warns; Firefox does not filter on it.
- Limits (`to_wgpu_limits`): WebGPU's defaults or better, so Firefox's
  requestDevice with default limits fits: textures 8192 (1D, 2D), 2048 (3D),
  256 layers; 8 bind groups (8 here), 1000 bindings a group; a stage: 12
  uniform and 8 storage buffers, 16 sampled textures, 16 samplers, 4 storage
  textures (reported for the default; not compiled yet, see below); 8 and 4
  dynamic uniform and storage buffers; 64 KiB uniform and 2 GiB storage
  bindings; 16 vertex buffers, 16 attributes, stride 2048; 16 inter-stage
  variables (64 scalar varyings + position); 8 colour attachments; offset
  alignments 16; compute from gpu.Caps.

## Graphics: what is still missing (the next work, roughly by need)

- **Storage textures**: compute shaders only (spirv's storageImageOp), in
  Rgba8 unorm, the 32-bit formats and the widened WebGPU ones. Not yet:
  vertex/fragment-stage storage images (FRAGMENT_WRITABLE_STORAGE: the
  front end's emitStage would take them as buffers with the image words in
  the draw's uniform words), BGRA8 storage, storage texel buffers. Sampled
  images in compute shaders are not compiled yet either (spirv's imageRef
  wants the graphics Resources: compute needs texture bindings and
  descriptor words in the dispatch's parameters, texture.sig's ops).
- **Multisampling**: 4x is taken (images, attachments, limits, resolves)
  but keeps one sample a pixel: rendering is right, edges are not
  antialiased; sample shading, sample masks and alpha-to-coverage are
  ignored. Real MSAA needs the raster's coverage per sample (src/gfxapi),
  or a 2x2 supersampled image with a box-filter resolve (viewport, scissor
  and FragCoord scaled in the ICD).
- **Points and lines** (logged, not drawn), **primitive restart**, **depth
  bias**, **FragDepth**, **clip/cull distances**, rasterizer depth clamp.
- **Formats**: widened formats are not colour attachments (the raster
  writes 8-bit unorm only: rgba16float render targets need src/gfxapi's
  raster); an sRGB attachment blends on encoded values; a copy between a
  widened image and another format of the same texel size copies the wide
  words. Vertex formats are wider (format.sig).
- **Samplers**: CLAMP_TO_BORDER and MIRROR_CLAMP_TO_EDGE clamp/mirror to
  the edge; anisotropy is linear; cube arrays sample (face + 6 layer) but
  are not reported (imageCubeArray 0) until tested.
- **Depth precision**: D32_SFLOAT and D32_SFLOAT_S8_UINT hold 24 bits.
- **Several subpasses** (only the first is drawn), input attachments,
  imageless framebuffers, secondary command buffers, events; occlusion
  queries that count samples (the raster's).
- **Multiview** (a Vulkan 1.1 requirement this device does not meet).
- **Stencil-tested draws run on the CPU on sm_120**: gfxapi's stencil tile
  kernel does not compile for sm_120 (TooManyRegs, GL's too: GL falls back
  the same way). The driver waits for the GPU and fetches every memory
  first; on the PC that needs CPU views of the images' memory. The fix is
  in kir_sm120's register budget or a smaller stencil kernel (src/gfxapi).
- **Indirect draws** read their arguments back (the CPU waits inside
  vkQueueSubmit), as dispatch indirect. The plan for dispatch on the GPU
  (not done): a `gpu.Dispatch.indirect` the RTX takes by a patch kernel
  (precompiled SASS, embedded and checked against kir_sm120 by a test)
  writing the counts into the next QMD (GRID_WIDTH word 39, HEIGHT and
  DEPTH the low halves of 40 and 41) and cbuf0's CB_GRID before its
  launch, a zero count swapping in a nop program (word 32 and the
  prefetch word 59); EmuDevice reads the counts itself. Draws need the
  raster to read the vertex count from memory (src/gfxapi).
- Each colour attachment past the first re-runs the raster (vertex and
  setup too): depth EQUAL and not written, stencil off for those passes.
- **Depth bias clamp** (the raster has no depth bias), **anisotropic
  filtering** (texture.sig's linear; samplerAnisotropy 0), **cube arrays**
  (texture.sig samples face + 6 layer; imageCubeArray 0 until a test
  draws one), **border colours** (texture.sig has no border wrap).

## 1. Galaxy integration (done in galaxy `webgpu`; on-hardware check left)

- `scripts/build-vk.sh` in Galaxy, as `build-gl.sh`: `sig build-lib -dynamic
  -target x86_64-linux-none --name vulkan_galaxy` over the pinned zpm (the
  wiring is in `libgalaxy_vk.sig`'s header; the vk module now depends on
  gfxapi too, for the raster). Install as
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

- Atomics, subgroups, f16, timestamp queries and pipeline caches: done
  (milestone 4, above).
- **Dispatch indirect on the GPU**: today the counts are copied back and read
  by the CPU (a wait inside vkQueueSubmit). The RTX can launch from a QMD the
  GPU writes; needs a `gpu.Device` dispatch-indirect hook (src/gpu).
- **Zero-initialized workgroup memory**
  (VK_KHR_zero_initialize_workgroup_memory): naga's polyfill works now; the
  extension would let wgpu skip it.
- **Waits without the lock**: `vkWaitForFences` polls with the driver lock let
  go between 1 ms waits; a futex wait on the node's fence fd is better.
- **Wait-before-signal** of timeline semaphores across threads: today a
  submission waiting on a value only the host will signal spins in
  vkQueueSubmit. A deferred-submission queue (fixed, in .bss) instead.

## 3. Graphics (milestone 2: done, see above)

What is left of it is the list under "Graphics: what is still missing".
Not 1.2 while `VK_KHR_driver_properties` would carry conformance version 0:
wgpu hides such an adapter unless `ALLOW_UNDERLYING_NONCOMPLIANT_ADAPTER`
(adapter.rs, `driver.conformance_version.major == 0`).

## 4. Presentation (Wayland swapchain): done

What follows was the plan; icd.sig's "Presentation" section is what is.
The loader keeps its own VkIcdSurfaceWayland (the driver does not make
surfaces); a swapchain's images are system memory, as EGL's window
buffers, dma-bufs as linear ARGB8888/XRGB8888 wl_buffers.

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

## 5. Firefox's WebGPU presentation (dma-bufs): done

Firefox 151 (gfx/wgpu_bindings/src/server.rs) takes the dma-buf path only
when all four extensions are there and OPAQUE_FD semaphores export; it
then makes a B8G8R8A8_UNORM image with DRM-modifier tiling, dedicated
exported memory, reads plane 0's layout and the memory's fd, and before
each submission makes an exportable semaphore whose fd goes with the
surface. Galaxy's GL has no GL_EXT_semaphore_fd, so WebRender cannot wait
on it (Firefox logs once and goes on): a submission that signals a
semaphore made for export waits for its work inside vkQueueSubmit. A
canvas in another format than bgra8unorm goes by readback, which needs
nothing more. Left: EXT_semaphore_fd in gfxapi's GL (then no CPU wait),
and a check on the PC that Firefox's two contexts on the RTX (EGL's and
this driver's, each its own channel) share the dma-bufs.

The plan, as written before:

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
