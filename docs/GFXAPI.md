# zpm gfxapi: Galaxy's GPU driver for apps

`src/gfxapi/` is the GPU driver Linux apps on Galaxy draw through: OpenGL ES and EGL first, then Vulkan. Apps reach these interfaces under the names they use to find Mesa's. The driver is pure Sig and allocation-free, with no C and no Mesa. It runs over zpm's GPU-neutral layer (`src/gpu`, docs/GPU.md): its kernels are written once in KIR and compiled to ir3 for the Surface's Adreno and to sm_120 for the PC's RTX.

Unmodified Firefox and Chromium (Alpine's and Flatpak's) are the first targets. They need one EGL and GLES implementation between them: Firefox's WebRender uses GLES 3.0 through EGL, and Chromium runs ANGLE's GL backend on the system's GLES (`--use-angle=gles`).

## Files

| File | What it is |
|---|---|
| `gfxapi.sig` | The module root (`gfxapi` in zpm's build). |
| `engine.sig` | Images in GPU memory, filled and copied by KIR kernels through any `gpu.Device`. It batches work, waits only where needed, keeps the caches in step, and falls back to the CPU. |
| `gles.sig` | OpenGL ES 3.0's objects and state: what the C entry points call. |
| `glenum.sig` | GL's enum values. |
| `libgles.sig` | The C ABI: the `gl*` entry points, the per-thread current context and `getProcAddress`. It is the shared library's root. |
| `node.sig` | Galaxy's render node (`/dev/dri/renderD128`): the 'G' calls, zero-copy import (`G_IMPORT`) and PRIME export, as zpm's raw devices and then as a `gpu.Device`. The same client as galaxy-think's `think_gpu.sig`, for any program. |

## How it works

### The engine

- **Batched.** Fills and copies are recorded and then run together: one `Device.run`, so one submission and one fence per batch. A batch is cut at `glFlush` or `glFinish`, when the CPU needs pixels a batch touches, or when the batch is full. The CPU keeps going while the GPU works.
- **Waits only where needed.** Each image remembers the last batch that used it. A CPU read or write of an image waits for that batch alone.
- **Cache upkeep.** Before the CPU reads what the GPU wrote, the engine calls `fromDevice` on the rows read. Before the CPU writes rows the GPU wrote, it calls `fromDevice` on them too, because a partly written cache line would otherwise carry stale bytes back; after writing, it calls `toDevice`.
- **Frees after the GPU.** A buffer that a batch in flight may still use is freed only once that batch is done.
- **The CPU fallback.** Each op also has a CPU form that gives the same bytes. When a run fails, its batch is done again on the CPU, and the engine stays on the CPU. GL reports this as a context reset (`glGetGraphicsResetStatus`), so an app can recreate its context or draw in software.
- **Rows.** Rectangles are in GL's coordinates, with y counted from the bottom. A window's buffer is top-down, and the engine flips its rows.

### GLES

Textures, buffers and renderbuffers live in an `Objects` table held by a share group's contexts. Framebuffer objects belong to each context. Every table is fixed, in memory the caller owns.

Errors behave as in Mesa: the first error is kept until `glGetError` reads it.

### The C ABI

Each context is current per thread. The current context is kept in a fixed table keyed by the thread pointer (`TPIDR_EL0` on AArch64, `%fs:0` on x86-64), so the library needs no thread-local storage and no C library.

The library's panic handler prints one line and exits, as a failed assertion in a C driver does. It needs neither TLS nor a stack walk.

As built (`sig build-lib -dynamic -target <arch>-linux-none -fPIC`), the library has no `DT_NEEDED` entries, no TLS segment and no undefined symbols, on aarch64 and on x86_64.

## This stage

**Implemented:**
- the engine, with fill, masked fill and copy kernels, each with its CPU form;
- the render-node client;
- the GLES core, with no shaders yet:
  - state, errors, enables, clear state and masks, viewport and scissor, pixel store state;
  - buffer objects;
  - 2D textures (level 0, RGBA8 and BGRA8, with unpack buffers);
  - renderbuffers (RGBA8, BGRA8, depth, stencil, depth-stencil);
  - framebuffer objects with 4 color attachments, draw and read buffers, and ES 3.0's completeness rules;
  - `glClear` and `glClearBuffer*`, `glReadPixels` (also into pack buffers);
  - `glTexImage2D`, `glTexSubImage2D`, `glTexStorage2D`, `glCopyTexSubImage2D`, `glCopyTexImage2D`;
- 76 C entry points.

**Not yet:**
- draws, shaders and GLSL, vertex arrays, samplers, queries, sync objects;
- texture levels above 0;
- other texture targets and formats;
- multisampling;
- EGL, which is the next stage.

Until EGL makes a context current, the library's entry points do nothing.

## Tests

```
sig build test-gfxapi
```

- `test-gfxapi-module`: the engine and the pool on the CPU; float-to-unorm conversion (rounding to nearest even, as Mesa does); the render-node client against `node.Fake`, Galaxy's calls over the emulated Adreno, covering buffers, cache upkeep, import, export, a hang and a missing GPU.
- `test-gfxapi-libgles`: GL through its C entry points, `getProcAddress`, and the per-thread table.
- `test-gfxapi-gpu`: one GL scenario, run three ways:
  - on the CPU;
  - on `EmuDevice`: KIR's interpreter, with memory that is not coherent, so a missing cache call gives wrong bytes;
  - on the emulated Adreno through Galaxy's calls: KIR compiled to ir3, PM4 streams, `ir3_emu`.

  The scenario covers clears with a scissor and a color mask, a top-down BGRA window, a texture upload with an unpack skip, a framebuffer object, a copy that flips and swaps, depth and stencil under a write mask, and a pack buffer. All three runs must give the same bytes. Further tests cover batching, a free deferred until its batch is done, and a GPU lost mid-batch.

## Stages ahead

| # | Stage | Where |
|---|---|---|
| 3 | This: the engine, the render-node client, the GLES core and the C ABI | zpm |
| 4 | EGL 1.5: the Wayland platform (`wl_egl_window`, `zwp_linux_dmabuf_v1` v4, frame callbacks), surfaceless and pbuffer surfaces, `EGL_KHR_fence_sync`, `EGL_ANDROID_native_fence_sync`, `EGL_EXT_image_dma_buf_import`. One library, `libgalaxy-gl.so`, with `libEGL.so.1` and `libGLESv2.so.2` linked to it (the loader loads one file once) | zpm |
| 5 | The rest of GLES 3.0 that WebRender uses: a GLSL ES 3.00 compiler to KIR, and a tiled compute rasterizer (triangles binned into tiles, fragments in KIR, blending and depth in the tile). Firefox's WebRender on the GPU | zpm |
| 6 | Chromium through ANGLE on GLES | zpm |
| 7 | `libgbm.so.1` | zpm |
| 8 | Packaging: the libraries in Galaxy's root under Mesa's names; `mesa-*` provided by Galaxy; a Flatpak GL extension | Galaxy |
| 9 | A fixed-function Adreno backend (the 3D pipe), for speed | zpm |
| 10 | The PC: per-app RTX contexts in `nv_drm`, then the same driver on sm_120 | Galaxy + zpm |
| 11 | A Vulkan ICD (SPIR-V to KIR) | zpm |
