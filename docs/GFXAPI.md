# zpm gfxapi: Galaxy's GPU driver for apps

`src/gfxapi/` is the GPU driver Linux apps on Galaxy draw through: OpenGL ES and EGL first, then Vulkan. Apps reach these interfaces under the names they use to find Mesa's. The driver is pure Sig and allocation-free, with no C and no Mesa. It runs over zpm's GPU-neutral layer (`src/gpu`, docs/GPU.md): its kernels are written once in KIR and compiled to ir3 for the Surface's Adreno and to sm_120 for the PC's RTX.

Unmodified Firefox and Chromium (Alpine's and Flatpak's) are the first targets. They need one EGL and GLES implementation between them: Firefox's WebRender uses GLES 3.0 through EGL, and Chromium runs ANGLE's GL backend on the system's GLES (`--use-angle=gles`).

## Files

| File | What it is |
|---|---|
| `gfxapi.sig` | The module root (`gfxapi` in zpm's build). |
| `engine.sig` | Images in GPU memory, filled and copied by KIR kernels through any `gpu.Device`. It batches work, waits only where needed, keeps the caches in step, and falls back to the CPU. |
| `gles.sig` | OpenGL ES 3.0's objects and state: what the C entry points call. |
| `raster.sig` | Drawing: GL's draws as three KIR kernels (vertices, triangle setup, tiles), the same on every GPU and on the CPU. |
| `glenum.sig` | GL's enum values. |
| `program.sig` | GL's shader and program objects: sources, compiles and their logs, links, attribute and uniform locations, uniform values. |
| `glsl/` | The GLSL ES compiler: `lex.sig` (tokens, keywords by version), `pp.sig` (the preprocessor), `parse.sig` (the AST), `sema.sig` (types, scopes, built-ins, ES's rules), `glsl.sig` (a compile, its log and its interface), `gen.sig` (a checked shader as KIR, inside the draw kernels). |
| `egl.sig` | EGL 1.5 for OpenGL ES: displays, configs, contexts with share groups, window and pbuffer surfaces, swaps, fence syncs, errors per thread. |
| `wayland.sig` | EGL's Wayland platform: a window's frames handed to the compositor as dma-bufs (`zwp_linux_dmabuf_v1`), through the app's own `libwayland-client`. |
| `thread.sig` | What EGL and GL keep per thread: the current context and surfaces, EGL's last error, the bound API. |
| `dl.sig` | The host program's functions found by name: weak `dlsym`, else the loaded objects' symbol tables. |
| `host.sig` | What EGL asks of the process: dma-bufs out and in, fence files, dup, poll, a file mapped. The library's root gives Linux's calls and the render node; tests give their own. |
| `node.sig` | Galaxy's render node (`/dev/dri/renderD128`) as zpm's raw devices and then as a `gpu.Device`: the 'G' calls; zero-copy import of the program's memory (`G_IMPORT`); PRIME export and import (dma-bufs in, through `MSM_GEM_INFO`); fence files (`G_FENCE_FD`). The same client as galaxy-think's `think_gpu.sig`, for any program. |
| `libgalaxy_gl.sig` | The shared library's root, `libgalaxy-gl.so`: the `egl*` entry points, the driver behind them, and `libgles.sig`'s. |
| `libgles.sig` | The `gl*` entry points and `getProcAddress`. |

## How it works

### The engine

- **Batched.** Fills and copies are recorded and then run together: one `Device.run`, so one submission and one fence per batch. A batch is cut at `glFlush` or `glFinish`, when the CPU needs pixels a batch touches, or when the batch is full. The CPU keeps going while the GPU works.
- **Waits only where needed.** Each image remembers the last batch that used it. A CPU read or write of an image waits for that batch alone.
- **Cache upkeep.** Before the CPU reads what the GPU wrote, the engine calls `fromDevice` on the rows read. Before the CPU writes rows the GPU wrote, it calls `fromDevice` on them too, because a partly written cache line would otherwise carry stale bytes back; after writing, it calls `toDevice`.
- **Frees after the GPU.** A buffer that a batch in flight may still use is freed only once that batch is done.
- **Shared memory.** An EGLImage and the GL textures and renderbuffers made of it name one memory (`Shared`). What the GPU has pending on it is tracked once, for every name, and the memory is freed with the last of them.
- **The CPU fallback.** Each op also has a CPU form that gives the same bytes. When a run fails, its batch is done again on the CPU, and the engine stays on the CPU. GL reports this as a context reset (`glGetGraphicsResetStatus`), so an app can recreate its context or draw in software.
- **Rows.** Rectangles are in GL's coordinates, with y counted from the bottom. A window's buffer is top-down, and the engine flips its rows.

### GLES

Textures, buffers and renderbuffers live in an `Objects` table held by a share group's contexts. Framebuffer objects and vertex array objects belong to each context. Every table is fixed, in memory the caller owns.

### Draws

A draw is three KIR kernels, recorded as three dispatches in the engine's open batch:

1. **Vertices**, a thread per vertex of each instance.
   - Attributes are fetched in any of GL's integer and float formats, normalized or not, or taken from `glVertexAttrib*` where an array is off, or per instance (divisor 1).
   - Every fetch, and the element array's, stays inside its buffer, so a bad offset can't fault the GPU.
   - The shader's vertex code runs, then clip space goes to window space: the position snapped to 1/16 pixel, depth through the depth range, 1/w, and the varyings multiplied by 1/w (or kept, for flat ones).
2. **Setup**, a thread per triangle.
   - It takes a topology's vertices (lists, strips, fans; the last vertex provokes).
   - It computes the signed area exactly in 64 bits, culls, and turns the triangle counter-clockwise.
   - It records the triangle's pixel box, three integer edge equations with a tie rule, and plane equations for depth, 1/w and the varyings.
3. **Tiles**, a group per 8×8 pixels.
   - The tile's pixels and depth are loaded once, then every triangle is drawn in GL's order.
   - A tile outside a triangle's box, or wholly outside one edge, skips it. Otherwise each edge's constant for the tile is computed in 64 bits, then each pixel's coverage in 32.
   - Then come the depth test, perspective-correct varyings, the shader's fragment code, and blending (every GL factor and equation, `SRC_ALPHA_SATURATE` too), with color masks and scissor. The pixels and depth are stored once.

Coverage is integer arithmetic, and every float operation is one KIR defines bit for bit, so a frame is the same bytes on the Adreno, the RTX and the CPU. A pixel on an edge two triangles share is drawn exactly once.

On the CPU (no GPU, or it is lost), KIR's interpreter runs the same three kernels on the images' memory.

Shaders are KIR emitters (`raster.Shaders`): a GLSL program's (below), or the driver's own (`usePipeline`). A draw has up to 60 scalar varyings (GL ES's 15 vectors). A flat varying keeps the provoking vertex's bits, so an integer's survive.

### GLSL

A shader's source goes through four passes, each in fixed tables of one compile scratch:

1. **The preprocessor** (`pp.sig`). Comments and line continuations go first, keeping line numbers. Directives are handled line by line: `#version` (100, or 300 es), `#define` (object-like and function-like, with `##`), `#undef`, `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif` (integer expressions with `defined`), `#extension`, `#line`, `#error`, `#pragma`. Expansion runs over a stack of token streams, with no recursion, and a macro is off while its own expansion is read. `GL_ES`, `__VERSION__`, `__LINE__`, `GL_FRAGMENT_PRECISION_HIGH` and the extensions' macros are predefined.
2. **The parser** (`parse.sig`), recursive descent with GLSL's precedence, into nodes in one array linked by index. It covers qualifiers, `layout(location)`, precision statements, structs, arrays and array constructors, functions and prototypes, every statement, and every operator.
3. **The checker** (`sema.sig`). It types every expression, with ES's rule of no implicit conversions. It covers scopes, structs, swizzles, constructors, l-values, constant integers (array sizes, case labels), and the qualifiers each stage and version allows. A fragment shader needs a default float precision. Integer varyings must be flat in 3.00. The built-in functions are a table of 201 signatures (and `outerProduct`): genType patterns bind one size per call, and sampler patterns one kind (float, int, uint). Version and stage gate them: 1.00's `texture2D`, 3.00's `texture`, `texelFetch` and `textureSize`, derivatives in fragment shaders, `GL_EXT_shader_texture_lod`, and `samplerExternalOES`.
4. **The interface** (`glsl.sig`): the shader's inputs, outputs and uniforms, with struct uniforms flattened to GL's names (`s[1].m`), each with its type, location and whether the shader uses it.

Logs are in Mesa's form (`0:LINE: error: ...`).

Shaders and programs share one namespace. Names are the process's, and each object belongs to its share group. A shader keeps only its source, in a text pool that is compacted when full. A link compiles both shaders again and then:

- places the active attributes: a `layout(location)` first, then `glBindAttribLocation`'s, then the lowest free locations (a matrix takes one per column);
- matches each varying the fragment shader uses to a vertex output by name, type and interpolation, and gives it its words;
- merges the two stages' uniforms (one type per name), each with consecutive locations (one per array element) and its words in the program's uniform storage, which is tight (a float, an int, a bool or a sampler's unit is one word);
- places 3.00's fragment outputs, or notes 1.00's `gl_FragColor`/`gl_FragData`.

As in Mesa, only what a shader uses is active. `glGetUniformLocation` takes `u`, `u[k]`, `s.m` and `s[1].m[2]`. `glUniform*` checks the type, count and sampler units, and `glGetUniform*` converts. `glUniformMatrix*` takes `transpose`. There are no binary formats. Interface blocks (uniform blocks) are refused for now. Every call takes the program table's lock.

### GLSL to KIR

A link keeps copies of its shaders' sources and makes the program's pipeline. Its vertex and fragment emitters compile a source again and generate it (`gen.sig`) into the vertex and raster kernels, when the engine builds them: at the pipeline's first draw on a GPU, at every draw on the CPU. The link generates both shaders once, into a kernel of their own, and verifies it, so code that can't be generated fails the link with a log, not a draw. A draw with the program in use copies its uniforms into the draw.

- **Values.** A value is a list of KIR operands, one per scalar component. A struct's and an array's components are flattened in order. Swizzles, fields and constant indices only pick from the list, with no code. Bools are preds, floats f32, ints i32, uints and samplers u32. Constants stay immediates, folded where KIR's result is exact.
- **Variables are SSA.** An assignment in straight code rebinds the variable's components and emits no instruction. A variable that an if, loop, switch or early-return function body may write gets registers of its own before it. Those writes are found in the construct and in the functions it calls. KIR has no phi, and a register written more than once lives through every loop around it, the raster's triangle loop too. So the fewer, the more a GPU's group fits.
- **Uniforms** are words of the uniform binding, in the link's tight layout. Small ones are loaded once at the shader's start. Arrays are loaded where indexed, a dynamic index clamped to the array, so the GPU never reads past it.
- **Dynamic indices** into registers choose among every element: a select chain to read, a select per element to write. An index out of range reads the first element and writes none.
- **Functions** are inlined, since GLSL ES has no recursion. A function whose return is not its last statement runs in a KIR loop it leaves. A return inside the function's own loops sets a flag that leaves each of them.
- **Loops** are KIR loops. A `for` with a `continue` runs its step at the top of each pass but the first, so `continue` (KIR's cont) still steps. A switch is a loop that `break` leaves, its cases a flag that falls through. A `continue` inside a switch leaves it and continues the loop around.
- **`discard`** drops the fragment (the raster's discard pred). In main it also returns.
- **Integer division** is exact: shifts for powers of two, else 32 steps of long division.
- **Built-ins:** every one of the checker's. Approximate ones use KIR's approximate ops: `sin`, `cos`, `exp2`, `log2`, `inversesqrt`, `normalize`, and what is built of them. `atan` is a polynomial with an error of about 1e-5. `sqrt`, `length` and divisions are exact. Half floats are packed in integer arithmetic, exactly.
- **Not yet:** texture sampling (a texture reads 0, stage 5d), derivatives (0: the raster has no helper pixels yet), `gl_FragDepth`, `gl_PointSize`, and color attachments past the first.

Errors behave as in Mesa: the first error is kept until `glGetError` reads it.

### EGL

- **The driver.** The library's root opens Galaxy's GPU through the render node at the first `eglInitialize`, with this image's backend (ir3 on AArch64, sm_120 on x86-64), and starts the engine on it. Without a GPU, or after it is lost, `eglInitialize` fails (`EGL_NOT_INITIALIZED`). The app then draws in software (Firefox's SWGL, Chromium's SwiftShader), which beats GL done on the CPU.
- **Displays.** `EGL_DEFAULT_DISPLAY` and `EGL_PLATFORM_SURFACELESS_MESA` give the surfaceless display: pbuffers and surfaceless contexts. A `wl_display`, from `eglGetDisplay` or `EGL_PLATFORM_WAYLAND_KHR`, gives a Wayland display: window surfaces of `wl_egl_window`s.
- **Configs.** There are four: ARGB8888 and XRGB8888, each with and without depth 24 + stencil 8. All take windows and pbuffers, and OpenGL ES 2 and 3. The native visual is DRM's fourcc. `eglChooseConfig` matches and sorts as EGL 1.5's §3.4.1 says.
- **Contexts.** OpenGL ES 2.0 and 3.0 (ES 3.0 either way, as Mesa gives), with share groups. The robustness attributes are taken: the engine reports a lost GPU as a reset. `EGL_KHR_no_config_context` and `EGL_KHR_surfaceless_context` are supported.
- **Windows.**
  - EGL works through the app's own `libwayland-client`, as Mesa does, found by name in the process. Its events go to a queue of its own, through libwayland's generic dispatcher.
  - `zwp_linux_dmabuf_v1` is bound at version 4 where offered. Version 4 tells its formats by the default feedback: a format table (mapped), with tranches of indices into it. Versions 3 and below tell them by `modifier` events. EGL wants linear ARGB8888 and XRGB8888; Galaxy's bridge offers them only while the GPU runs and this driver is installed.
  - A window has up to 4 buffers. Each is an engine image in GPU memory, top-down BGRA with rows `width * 4` bytes apart, made a `wl_buffer` from its dma-buf (PRIME) by `create_immed`.
  - **A swap** flushes the engine and doesn't wait for the GPU: Galaxy's dma-buf fences cover a context that uses Galaxy's calls, and the compositor's GPU reads on the same ring. Then come attach, damage, frame, commit and flush.
  - **Swap interval 1** waits for the frame callback before the next commit.
  - **The next back buffer** is one the compositor has released, else a new one. Before choosing, EGL dispatches the events it has already received, as Mesa does.
  - **A resize** (`wl_egl_window_resize`) takes effect at the next GL drawing, as in Mesa: the GL context checks before it uses the default framebuffer.
  - `EGL_EXT_buffer_age` and `EGL_KHR_swap_buffers_with_damage` are supported. Damage rectangles are flipped to the buffer's rows.
- **Syncs.** `EGL_KHR_fence_sync`, `EGL_KHR_wait_sync` and EGL 1.5's syncs are supported. A fence is the engine's mark, its work flushed, and the CPU waits on it. `eglWaitSync` waits for nothing, since one in-order GPU ring already orders the work.
- **Native fences.** `EGL_ANDROID_native_fence_sync`:
  - **Handed out:** a fence of this process's GPU work, as a `sync_file` from Galaxy's `G_FENCE_FD` (SB0LTD/galaxy#74), a new one at each `eglDupNativeFenceFDANDROID`.
  - **Handed in:** a `sync_file` the sync owns, polled while waiting and closed with the sync.
- **Images.** `EGL_KHR_image_base` with `EGL_EXT_image_dma_buf_import` and `_modifiers`:
  - A single-plane, linear ARGB8888, XRGB8888, ABGR8888 or XBGR8888 dma-buf is imported into this context: PRIME, then `MSM_GEM_INFO` for its GPU address and mmap offset. The fd stays the caller's.
  - GL takes it as a texture or an external texture (`OES_EGL_image`, `OES_EGL_image_external`), or as a renderbuffer. Drawing into it works through a framebuffer object.
  - The memory is shared with every name and freed with the last; GL keeps it after `eglDestroyImage`.
  - The image's offset, pitch and size are checked against the buffer.
- **The lock.** EGL's calls take one futex lock. GL's take none.

### The C ABI

The library is `libgalaxy-gl.so`, with 58 `egl*` and 187 `gl*` entry points. It is packaged as `libEGL.so.1` and `libGLESv2.so.2`, both links to the one file. The dynamic linker loads a file once, whatever name finds it, so EGL and GL share their state.

Each context is current per thread. The current context is kept in a fixed table keyed by the thread pointer (`TPIDR_EL0` on AArch64, `%fs:0` on x86-64), so the library needs no thread-local storage and no C library.

The library's panic handler prints one line and exits, as a failed assertion in a C driver does. It needs neither TLS nor a stack walk. EGL's tables, and the render node's, are filled at first use, so they take no room in the file.

As built (`sig build-lib -dynamic -target <arch>-linux-none -fPIC`), the library has no `DT_NEEDED` entries and no TLS segment. Its only undefined symbols are the weak `dlsym` and `dl_iterate_phdr`, which the dynamic linker binds from the program's C library. It is 1293 KB on aarch64 and 1321 KB on x86_64: the CPU fallback carries KIR's interpreter and the draw kernels' builders, and the GLSL compiler adds about 310 KB. Its tables (EGL's, the engine's kernel space, the compile scratch, the code generator's, the text pool, the programs) are bss, about 48 MB of address space, touched only as used.

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

**Stage 4a, EGL** ([SB0LTD/zpm#126](https://github.com/SB0LTD/zpm/pull/126)): EGL 1.5, the Wayland platform, surfaceless and pbuffers, fence syncs.

**Stage 4b** ([SB0LTD/zpm#129](https://github.com/SB0LTD/zpm/pull/129)): EGLImages from dma-bufs, GL's `OES_EGL_image`, native fences (with Galaxy's `G_FENCE_FD`, SB0LTD/galaxy#74), and `zwp_linux_dmabuf_v1` version 4's feedback.

**Stage 5a, draws** ([SB0LTD/zpm#130](https://github.com/SB0LTD/zpm/pull/130)):
- the pipeline above;
- vertex array objects, attribute pointers (integer ones too), generic attributes, divisors;
- `glDrawArrays`, `glDrawElements` (8, 16 and 32-bit indices), `glDrawArraysInstanced`, `glDrawElementsInstanced`, `glDrawRangeElements`;
- blend functions, equations and color; the depth function and range; cull face and front face.

That makes 114 GL entry points.

**Stage 5b, GLSL's front end:**
- the compiler above, GLSL ES 1.00 and 3.00;
- `glCreateShader` .. `glDeleteShader`, `glShaderSource`, `glCompileShader`, `glGetShaderiv`, `glGetShaderInfoLog`, `glGetShaderSource`, `glGetShaderPrecisionFormat`;
- `glCreateProgram` .. `glDeleteProgram`, attach and detach, `glLinkProgram`, `glValidateProgram`, `glUseProgram`, `glGetProgramiv`, `glGetProgramInfoLog`, `glProgramParameteri`;
- `glBindAttribLocation`, `glGetAttribLocation`, `glGetActiveAttrib`, `glGetUniformLocation`, `glGetActiveUniform`, `glGetActiveUniformsiv`, `glGetUniformIndices`, `glGetFragDataLocation`;
- every `glUniform*`, `glUniformMatrix*` and `glGetUniform*`;
- the shader limits in `glGetIntegerv`.

That makes 187 GL entry points.

**Stage 5c, GLSL to KIR:** the code generator above; draws run the program in use, its uniforms and attributes as linked; 60 scalar varyings, flat ones bit-exact; kernels of up to 65536 KIR instructions.

**Not yet:**
- texture sampling and samplers (a texture reads 0), derivatives, uniform blocks, transform feedback, queries, GL sync objects;
- points and lines;
- clipping: a triangle with a vertex at w ≤ 0, or past a guard band of 24576 pixels, is dropped;
- stencil tests, several color attachments, depth-only drawing;
- half-float and packed attribute formats, divisors past 1, attribute arrays in client memory;
- binning triangles to tiles, which every tile now visits in turn;
- texture levels above 0;
- other texture targets and formats;
- multisampling;
- EGLImages of GL textures (`EGL_KHR_gl_texture_2D_image`) and dma-buf export (`EGL_MESA_image_dma_buf_export`), with `libgbm` (stage 7);
- multi-plane and YUV dma-bufs;
- native fences and dma-buf import on the PC: they wait for per-app RTX contexts;
- a Wayland connection of EGL's own, for `EGL_PLATFORM_WAYLAND_KHR` with `EGL_DEFAULT_DISPLAY`.

## Tests

```
sig build test-gfxapi
```

- `test-gfxapi-module`: the engine and the pool on the CPU; float-to-unorm conversion (rounding to nearest even, as Mesa does); the render-node client against `node.Fake`, Galaxy's calls over the emulated Adreno, covering buffers, cache upkeep, import, export, a hang and a missing GPU.
- `test-gfxapi-glsl`: three GLSL programs compiled, linked and drawn through GL's shader and program objects, on the CPU, on `EmuDevice` and on the emulated Adreno (ir3). Each run gives the same bytes and the pixels GLSL says.
  - A 3.00 program: a mat4 uniform times a vec4; a uniform array indexed by `gl_VertexID / 3`; `gl_Position.xy +=`; a flat int varying; a struct uniform array read in a loop with an early return; a switch with a default; a local array indexed by a varying; out parameters; `for`, `do` and `while` with `continue` and `break`; `%` by 7; `discard`; `?:`, `mix`, `step` and `clamp`.
  - A 1.00 program as WebGL 1 writes it: attribute, varying, `gl_FragColor`, a bool uniform, a return from main.
  - A program of 30 checks, each setting a bit the pixel's bytes carry: matrix inverse, determinant, transpose and products; struct and array copies; dynamic array writes; integer division folded and at run time; transcendentals within tolerance; half, unorm and snorm packing; `?:` and `&&` with side effects; `inout`; returns from nested loops; switch fall-through; `continue` through a switch; the relational built-ins; constructors and conversions.
- `test-gfxapi-libgles`: GL through its C entry points, and `getProcAddress`. Shaders and programs: a 3.00 program (sources in parts, a bound attribute, an unused one inactive, uniform arrays by element, sampler units, a bool, a transposed matrix, the errors `glUniform*` gives), a 1.00 program as WebGL 1 writes them, compile and link logs, and deletes deferred while attached or in use.
- `test-gfxapi-module` also runs the compiler's own tests: tokens, macros and conditionals, the parser, the checker on shaders as WebRender and WebGL write them, what ES forbids (each with its message), and an interface with struct uniforms flattened.
- `test-gfxapi-lib`: EGL and GL through their C entry points: a surfaceless display, a pbuffer, a clear read back, a fence, errors, `eglGetProcAddress`.
- `test-gfxapi-draw`: one GL scene of triangles drawn three ways (the CPU, `EmuDevice`, the emulated Adreno through Galaxy's calls with the kernels compiled to ir3), each giving the same bytes. It covers:
  - the fill rule: a square's two triangles added, the diagonal through pixel centers, every pixel exactly once;
  - a strip's interpolated colors, the depth test, culling by winding;
  - indexed instanced quads with a per-instance attribute;
  - scissor with a color mask, flat shading, and a fan on the window's top-down buffer.

  With the tie rule broken, the check fails.
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
  - version 4's feedback (the format table mapped and let go, its fd closed) and version 3's events;
  - configs, sharing, surfaceless contexts, fences, and destroys while current;
  - EGLImages: another program's dma-buf (an `EmuDevice` buffer imported zero-copy) as a texture read and drawn on the GPU, its producer seeing the pixels, as an external texture and a renderbuffer, kept by GL after its handle goes, freed with its last name; the errors EGL gives; the format and modifier queries;
  - native fences: one handed out (a new `sync_file` at each dup), one handed in (polled, owned, closed).
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
| 4b | Done: EGLImages and `EGL_EXT_image_dma_buf_import`, GL's `OES_EGL_image`; `EGL_ANDROID_native_fence_sync`; `zwp_linux_dmabuf_v1` v4 feedback | zpm + Galaxy |
| 5a | Done: draws. Vertex arrays, the three draw kernels (vertices, setup, tiles), exact coverage, depth, blending, culling, instancing; the same bytes on every GPU and the CPU | zpm |
| 5b | Done: the GLSL ES 1.00 and 3.00 front end (the preprocessor, parser, types and built-ins); shader and program objects, linking, uniforms and attributes by name | zpm |
| 5c | Done: GLSL to KIR, the vertex and fragment code draws run; the same bytes on the CPU and the emulated Adreno | zpm |
| 5d | Texture sampling (filters, wraps, the formats WebRender uses: R8, RG8, RGBA16F, RGBA32F, ...), samplers; triangles binned to tiles | zpm |
| 5e | What WebRender asks beyond that, until Firefox's WebRender draws on the GPU | zpm |
| 6 | Chromium through ANGLE on GLES | zpm |
| 7 | `libgbm.so.1` | zpm |
| 8 | Packaging: the libraries in Galaxy's root under Mesa's names; `mesa-*` provided by Galaxy; a Flatpak GL extension | Galaxy |
| 9 | A fixed-function Adreno backend (the 3D pipe), for speed | zpm |
| 10 | The PC: per-app RTX contexts in `nv_drm`, then the same driver on sm_120 | Galaxy + zpm |
| 11 | A Vulkan ICD (SPIR-V to KIR) | zpm |
