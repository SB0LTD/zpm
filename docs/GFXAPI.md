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
| `egl.sig` | EGL 1.5 for OpenGL ES: displays, configs, contexts with share groups, window and pbuffer surfaces, swaps, fence syncs, errors per thread. |
| `wayland.sig` | EGL's Wayland platform: a window's frames handed to the compositor as dma-bufs (`zwp_linux_dmabuf_v1`), through the app's own `libwayland-client`. |
| `thread.sig` | What EGL and GL keep per thread: the current context and surfaces, EGL's last error, the bound API. |
| `dl.sig` | The host program's functions found by name: weak `dlsym`, else the loaded objects' symbol tables. |
| `node.sig` | Galaxy's render node (`/dev/dri/renderD128`): the 'G' calls, zero-copy import (`G_IMPORT`) and PRIME export, as zpm's raw devices and then as a `gpu.Device`. The same client as galaxy-think's `think_gpu.sig`, for any program. |
| `libgalaxy_gl.sig` | The shared library's root, `libgalaxy-gl.so`: the `egl*` entry points, the driver behind them, and `libgles.sig`'s. |
| `libgles.sig` | The `gl*` entry points and `getProcAddress`. |

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

### EGL

- **The driver.** The library's root opens Galaxy's GPU through the render node at the first `eglInitialize`, with this image's backend (ir3 on AArch64, sm_120 on x86-64), and starts the engine on it. Without a GPU, or after it is lost, `eglInitialize` fails (`EGL_NOT_INITIALIZED`). The app then draws in software (Firefox's SWGL, Chromium's SwiftShader), which beats GL done on the CPU.
- **Displays.** `EGL_DEFAULT_DISPLAY` and `EGL_PLATFORM_SURFACELESS_MESA` give the surfaceless display: pbuffers and surfaceless contexts. A `wl_display`, from `eglGetDisplay` or `EGL_PLATFORM_WAYLAND_KHR`, gives a Wayland display: window surfaces of `wl_egl_window`s.
- **Configs.** There are four: ARGB8888 and XRGB8888, each with and without depth 24 + stencil 8. All take windows and pbuffers, and OpenGL ES 2 and 3. The native visual is DRM's fourcc. `eglChooseConfig` matches and sorts as EGL 1.5's §3.4.1 says.
- **Contexts.** OpenGL ES 2.0 and 3.0 (ES 3.0 either way, as Mesa gives), with share groups. The robustness attributes are taken: the engine reports a lost GPU as a reset. `EGL_KHR_no_config_context` and `EGL_KHR_surfaceless_context` are supported.
- **Windows.**
  - EGL works through the app's own `libwayland-client`, as Mesa does, found by name in the process. Its events go to a queue of its own, through libwayland's generic dispatcher.
  - `zwp_linux_dmabuf_v1` is bound at version 3; its `modifier` events say whether the compositor takes linear ARGB8888 and XRGB8888. Galaxy's bridge offers them only while the GPU runs and this driver is installed.
  - A window has up to 4 buffers. Each is an engine image in GPU memory, top-down BGRA with rows `width * 4` bytes apart, made a `wl_buffer` from its dma-buf (PRIME) by `create_immed`.
  - **A swap** flushes the engine and doesn't wait for the GPU: Galaxy's dma-buf fences cover a context that uses Galaxy's calls, and the compositor's GPU reads on the same ring. Then come attach, damage, frame, commit and flush.
  - **Swap interval 1** waits for the frame callback before the next commit.
  - **The next back buffer** is one the compositor has released, else a new one. Before choosing, EGL dispatches the events it has already received, as Mesa does.
  - **A resize** (`wl_egl_window_resize`) takes effect at the next GL drawing, as in Mesa: the GL context checks before it uses the default framebuffer.
  - `EGL_EXT_buffer_age` and `EGL_KHR_swap_buffers_with_damage` are supported. Damage rectangles are flipped to the buffer's rows.
- **Syncs.** `EGL_KHR_fence_sync`, `EGL_KHR_wait_sync` and EGL 1.5's syncs are supported. A fence is the engine's mark, its work flushed, and the CPU waits on it. `eglWaitSync` waits for nothing, since one in-order GPU ring already orders the work.
- **The lock.** EGL's calls take one futex lock. GL's take none.

### The C ABI

The library is `libgalaxy-gl.so`, with 53 `egl*` and 76 `gl*` entry points. It is packaged as `libEGL.so.1` and `libGLESv2.so.2`, both links to the one file. The dynamic linker loads a file once, whatever name finds it, so EGL and GL share their state.

Each context is current per thread. The current context is kept in a fixed table keyed by the thread pointer (`TPIDR_EL0` on AArch64, `%fs:0` on x86-64), so the library needs no thread-local storage and no C library.

The library's panic handler prints one line and exits, as a failed assertion in a C driver does. It needs neither TLS nor a stack walk. EGL's tables, and the render node's, are filled at first use, so they take no room in the file.

As built (`sig build-lib -dynamic -target <arch>-linux-none -fPIC`), the library has no `DT_NEEDED` entries and no TLS segment. Its only undefined symbols are the weak `dlsym` and `dl_iterate_phdr`, which the dynamic linker binds from the program's C library. It is 557 KB on aarch64 and 584 KB on x86_64.

## What is done

**Stage 3** ([SB0LTD/zpm#122](https://github.com/SB0LTD/zpm/pull/122)):
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

**Stage 4a, EGL:** everything in the EGL section above.

**Not yet:**
- draws, shaders and GLSL, vertex arrays, samplers, queries, GL sync objects;
- texture levels above 0;
- other texture targets and formats;
- multisampling;
- EGLImages and `EGL_EXT_image_dma_buf_import`;
- `EGL_ANDROID_native_fence_sync` (sync_file fences);
- `zwp_linux_dmabuf_v1` version 4's feedback;
- a Wayland connection of EGL's own, for `EGL_PLATFORM_WAYLAND_KHR` with `EGL_DEFAULT_DISPLAY`.

## Tests

```
sig build test-gfxapi
```

- `test-gfxapi-module`: the engine and the pool on the CPU; float-to-unorm conversion (rounding to nearest even, as Mesa does); the render-node client against `node.Fake`, Galaxy's calls over the emulated Adreno, covering buffers, cache upkeep, import, export, a hang and a missing GPU.
- `test-gfxapi-libgles`: GL through its C entry points, and `getProcAddress`.
- `test-gfxapi-lib`: EGL and GL through their C entry points: a surfaceless display, a pbuffer, a clear read back, a fence, errors, `eglGetProcAddress`.
- `test-gfxapi-egl`: EGL on a fake Wayland compositor that answers as Galaxy's bridge does, with the engine on `EmuDevice`. It checks:
  - the display's queue and binding;
  - each frame's dma-buf (fd, stride, modifier), `create_immed`'s size and format, and attach, damage, frame, commit and flush;
  - the buffers' pixels, top-down;
  - interval 1 waiting for the frame callback, and buffers reused once released, with their age;
  - damage flipped to the buffer's rows;
  - a resize taking effect at the next drawing;
  - an XRGB window reading back as opaque;
  - every proxy and buffer given back at the end;
  - a compositor without dma-bufs, refused;
  - configs, sharing, surfaceless contexts, fences, and destroys while current.
- `test-gfxapi-gpu`: one GL scenario, run three ways:
  - on the CPU;
  - on `EmuDevice`: KIR's interpreter, with memory that is not coherent, so a missing cache call gives wrong bytes;
  - on the emulated Adreno through Galaxy's calls: KIR compiled to ir3, PM4 streams, `ir3_emu`.

  The scenario covers clears with a scissor and a color mask, a top-down BGRA window, a texture upload with an unpack skip, a framebuffer object, a copy that flips and swaps, depth and stencil under a write mask, and a pack buffer. All three runs must give the same bytes. Further tests cover batching, a free deferred until its batch is done, and a GPU lost mid-batch.

## Stages ahead

| # | Stage | Where |
|---|---|---|
| 3 | Done: the engine, the render-node client, the GLES core and the C ABI | zpm |
| 4a | Done: EGL 1.5, the Wayland platform, surfaceless and pbuffers, fence syncs, one `libgalaxy-gl.so` | zpm |
| 4b | EGLImages and `EGL_EXT_image_dma_buf_import`; `EGL_ANDROID_native_fence_sync`; `zwp_linux_dmabuf_v1` v4 feedback | zpm |
| 5 | The rest of GLES 3.0 that WebRender uses: a GLSL ES 3.00 compiler to KIR, and a tiled compute rasterizer (triangles binned into tiles, fragments in KIR, blending and depth in the tile). Firefox's WebRender on the GPU | zpm |
| 6 | Chromium through ANGLE on GLES | zpm |
| 7 | `libgbm.so.1` | zpm |
| 8 | Packaging: the libraries in Galaxy's root under Mesa's names; `mesa-*` provided by Galaxy; a Flatpak GL extension | Galaxy |
| 9 | A fixed-function Adreno backend (the 3D pipe), for speed | zpm |
| 10 | The PC: per-app RTX contexts in `nv_drm`, then the same driver on sm_120 | Galaxy + zpm |
| 11 | A Vulkan ICD (SPIR-V to KIR) | zpm |
