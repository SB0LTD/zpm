# zpm gfxapi: Galaxy's GPU driver for apps

`src/gfxapi/` is the GPU driver Linux apps on Galaxy draw through: OpenGL ES and EGL first, then Vulkan. Apps reach these interfaces under the names they use to find Mesa's. The driver is pure Sig and allocation-free, with no C and no Mesa. It runs over zpm's GPU-neutral layer (`src/gpu`, docs/GPU.md): its kernels are written once in KIR and compiled to ir3 for the Surface's Adreno and to sm_120 for the PC's RTX.

Unmodified Firefox and Chromium (Alpine's and Flatpak's) are the first targets. They need one EGL and GLES implementation between them: Firefox's WebRender uses GLES 3.0 through EGL, and Chromium runs ANGLE's GL backend on the system's GLES (`--use-angle=gles`).

## Files

| File | What it is |
|---|---|
| `gfxapi.sig` | The module root (`gfxapi` in zpm's build). |
| `engine.sig` | Images in GPU memory, filled and copied by KIR kernels through any `gpu.Device`. It batches work, waits only where needed, keeps the caches in step, and falls back to the CPU. |
| `gles.sig` | OpenGL ES 3.0's objects and state: what the C entry points call. |
| `raster.sig` | Drawing: GL's draws as KIR kernels (vertices, triangle setup, bins, tiles), the same on every GPU and on the CPU. |
| `glenum.sig` | GL's enum values. |
| `texture.sig` | Texture reads in KIR: `texelFetch`, sampled reads (nearest, bilinear or trilinear; repeat, clamp, mirrored repeat; the level of detail implicit, given or from gradients), `textureSize`, one code for every format. |
| `texfmt.sig` | GL ES's texture formats as the engine stores them: each upload GL allows, its conversion and its swizzle. |
| `program.sig` | GL's shader and program objects: sources, compiles and their logs, links, attribute and uniform locations, uniform values. |
| `glsl/` | The GLSL ES compiler: `lex.sig` (tokens, keywords by version), `pp.sig` (the preprocessor), `parse.sig` (the AST), `sema.sig` (types, scopes, built-ins, ES's rules), `glsl.sig` (a compile, its log and its interface), `gen.sig` (a checked shader as KIR, inside the draw kernels). |
| `dxbc/` | Direct3D's shaders: `dxbc.sig` reads the DXBC container (chunks, the input and output signatures) and Shader Model 4 and 5's tokens in place; `gen.sig` emits a vertex or pixel shader as the raster's KIR emitters, as `glsl/gen.sig` does GLSL's; `fixtures.sig` holds shaders compiled from `fixtures.hlsl` by Microsoft's compiler, and `draw_test.sig` draws them. |
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

Textures, buffers, renderbuffers, sampler objects and sync objects live in an `Objects` table held by a share group's contexts. Framebuffer objects and vertex array objects belong to each context. Every table is fixed, in memory the caller owns.

- **Mapped buffers** (`glMapBufferRange`, as WebRender uploads through pixel buffers). A map is the buffer's own memory, with no copy:
  - A synchronized map waits for the GPU's use of the buffer.
  - `MAP_UNSYNCHRONIZED_BIT` doesn't wait.
  - `MAP_INVALIDATE_BUFFER_BIT` on a buffer the GPU still uses gives it new storage instead of waiting; the old storage goes once the GPU is done.
  - What a write map wrote goes to the GPU at `glUnmapBuffer`, or at `glFlushMappedBufferRange` with `MAP_FLUSH_EXPLICIT_BIT`.
  - A mapped buffer can't be drawn from, uploaded from, read into or written by `glBufferSubData`. `glBufferData` and deletion unmap it.
- **Sync objects** (`glFenceSync` and the rest). A fence is the engine's mark after the work before it, and that work is run when the fence is made. `glClientWaitSync` waits for it, up to its timeout. `glWaitSync` waits for nothing, since the GPU's ring runs in order. A share group holds 1024 at once; past that `glFenceSync` gives null.
- **Blits** (`glBlitFramebuffer`): one engine kernel, run on the GPU or by KIR's interpreter.
  - Each destination pixel takes the source at its center, mapped back through the two rectangles. Flips and scaling are in the map, computed in exact float operations.
  - NEAREST leaves alone a pixel whose source falls outside the read buffer. LINEAR blends four texels clamped to the edge.
  - Color converts as copies do: RGBA8, BGRA8, RG8 and R8 in either direction. Depth and stencil are the 24 and 8 bits of their images.
  - Only the scissor test applies, as GL says.

### Draws

A draw is three KIR kernels of its pipeline's and one every pipeline shares, recorded as dispatches in the engine's open batch:

1. **Vertices**, a thread per vertex of each instance.
   - Attributes are fetched in any of GL's integer and float formats, normalized or not, or taken from `glVertexAttrib*` where an array is off, or per instance (divisor 1).
   - Every fetch, and the element array's, stays inside its buffer, so a bad offset can't fault the GPU.
   - The shader's vertex code runs, then clip space goes to window space: the position snapped to 1/16 pixel, depth through the depth range, 1/w, and the varyings multiplied by 1/w (or kept, for flat ones).
2. **Setup**, a thread per triangle.
   - It takes a topology's vertices (lists, strips, fans; the last vertex provokes).
   - It computes the signed area exactly in 64 bits, culls, and turns the triangle counter-clockwise.
   - It records the triangle's pixel box, three integer edge equations with a tie rule, and plane equations for depth, 1/w and the varyings.
3. **Bins**, a group per 64×64 pixels (8×8 tiles), shared by every pipeline.
   - Its 64 threads test 64 triangles' boxes against the bin at a time. The hits are compacted in GL's order through a scan in shared memory and listed after the triangle records.
   - A list holds up to 2048 triangles (fewer when the draw has fewer). Past that, the bin's tiles go through every triangle.
   - A draw whose rectangle is one bin is not binned.
4. **Tiles**, a group per 8×8 pixels.
   - The tile's pixels and depth are loaded once. Then the triangles of its bin's list (or all of them, unbinned) are culled 64 at a time: each thread tests one triangle's box against the tile, and the hits are compacted in order into shared memory. The group draws them in GL's order.
   - A tile wholly outside one of a triangle's edges skips it. Otherwise each edge's constant for the tile is computed in 64 bits, then each pixel's coverage in 32.
   - Then come the depth test, perspective-correct varyings, the shader's fragment code, and blending (every GL factor and equation, `SRC_ALPHA_SATURATE` too), with color masks and scissor. The pixels and depth are stored once.

Coverage is integer arithmetic, and every float operation is one KIR defines bit for bit, so a frame is the same bytes on the Adreno, the RTX and the CPU. A pixel on an edge two triangles share is drawn exactly once. Binning changes no pixel: binned, unbinned and with lists that run over, a frame is the same bytes as before it.

Culling 64 triangles at a time and binning cut the work a tile does for the triangles that miss it. On a 200×136 scene of 262 triangles, KIR's interpreter runs 167 million thread-instructions with the kernels before binning, 49 million unbinned and 43 million binned. Most of what remains is shading. Binning saves more as a target and its triangle count grow.

- **Color targets** are RGBA8, BGRA8, RG8 and R8 (WebRender's masks): 4, 2 or 1 bytes a pixel, loaded and stored at their width. An RG8 or R8 pixel's channels are RGBA8's first bytes: what it lacks reads 0, and alpha 1. Clears, color masks, copies and reads take them too.
- **Derivatives.** A fragment shader that takes them (`dFdx`, `dFdy`, `fwidth`) runs whole 2×2 quads. A quad with a pixel to draw runs the code in all four, and the pixels not drawn are helpers. A derivative is the difference with the quad's neighbour, through a shuffle. The tile's lanes are its pixels in order, so the neighbours are lanes `xor 1` and `xor 8`. Programs without derivatives run covered pixels alone.

On the CPU (no GPU, or it is lost), KIR's interpreter runs the same kernels on the images' memory.

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
- **Built-ins:** every one of the checker's. Approximate ones use KIR's approximate ops: `sin`, `cos`, `exp2`, `log2`, `inversesqrt`, `normalize`, and what is built of them. `atan` is a polynomial with an error of about 1e-5. `sqrt` and `length` are `frsq`'s seed with one Newton step, times x; 0 and infinity are their own roots. Half floats are packed in integer arithmetic, exactly.
- **Samplers** are their texture slots, as immediates, so they pass to functions as values. A texture function reads its slot through `texture.sig`.
- **Levels of detail.** `texture()` and the rest with an implicit LOD take, in a fragment shader, the derivatives of their coordinates through the quad, plus their bias. A program that uses one runs whole quads, as one taking `dFdx` does. In a vertex shader they read the base level. `textureLod` passes its LOD, and `textureGrad` its gradients. `texelFetch` and `textureSize` take a level past the base.
- **Divisions** are within GLSL's precision (2.5 ulp), as GPUs divide. Mesa's ir3 multiplies by `rcp`. A division by a power of two is a multiplication, giving the same result; by another constant, a multiplication by its reciprocal. Otherwise it is `frcp`'s seed, one Newton step, then a multiply: 5 to 7 instructions, where KIR's exact `fdiv` takes 77 on the Adreno, which has no fused multiply-add. A division by 0 keeps its infinity. On ir3 this halves the code of WebRender's largest shaders (a 119 KB fragment kernel is now 55 KB). It also fits its border shader, which the exact expansions made too long. The draw kernels' own divisions (1/w, unorm bytes) stay exact. A seed's last bit may differ between GPUs, as with the other approximate built-ins, so a GLSL program's frame may too. The tests compare the CPU with the emulated Adreno, whose seeds agree.
- **Derivatives** are shuffles with the quad's neighbour (see Draws). The link notes a fragment shader that takes them, and its draws run whole quads.
  - GL leaves a derivative undefined in control flow that is not uniform; here it is 0. A shuffle there could read a lane that isn't running: a trap in KIR's interpreter, garbage on a GPU.
  - After the fragment code is generated, a check finds where its control flow may differ between lanes. That is an `if` on a value that differs between pixels, the rest of a loop's pass after a break or continue on one, the whole of a loop left that way that runs more than one pass, and what follows a `return` or `discard` that some pixels take. It is a fixpoint over KIR: thread ids, shuffles and what they reach are divergent.
  - A derivative's shuffle at such a place becomes a copy of the pixel's own value, so the derivative is 0.
- **Not yet:** cube, 3D, array and shadow samplers (they read 0), a sampler chosen at run time, `gl_FragDepth`, `gl_PointSize`, and color attachments past the first.

### Direct3D's shaders (DXBC)

Windows programs draw through Direct3D, which hands the driver compiled shaders: DXBC, Shader Model 4 and 5's tokens. The same raster runs them, on every GPU and on the CPU, as KIR emitters (`dxbc/gen.sig`):

- **Registers.** DXBC's registers are typeless vectors of four 32-bit words. Each temp's and output's component is a u32 KIR register, `set` by every write. An instruction reads it as the type it computes in, since KIR's `mov` reinterprets any 32-bit value. An instruction reads all its sources before it writes, so `mov r0.yx, r0.xy` swaps.
- **Inputs and outputs.**
  - A vertex shader's inputs are its input layout's attributes (`Layout.attr`).
  - The varyings between the stages go by their signature element's semantic, component by component, since one register may pack two elements (`Layout.varying`).
  - `SV_Position` is the clip-space position on the way out and the fragment's coordinate on the way in.
  - `SV_IsFrontFace`, `SV_VertexID` and `SV_InstanceID` are the raster's.
  - A pixel shader's `SV_Target0` is the color. fxc writes its system value as 0, so it is known by name.
  - D3D's `constant` interpolation is a flat varying (`flatVaryings`).
- **Constant buffers** are words of the uniform binding (`Layout.cbuffer`). An immediate index reads its word, and a relative one loads at run time, clamped to the buffer. The shader's own immediate constant buffer is immediates, or a select chain for a relative index.
- **Instructions:**
  - float arithmetic and compares (all-ones or zero);
  - integer arithmetic, shifts, bit fields and compares;
  - `udiv`'s quotient and remainder (32 steps of long division; by zero, both all ones);
  - `imul`/`umul`'s high and low words;
  - conversions toward zero;
  - `movc`, `dp2`-`dp4`, `sincos`, the derivatives;
  - `if`, loops with (conditional) `break` and `continue`, `discard`.
- **Textures.**
  - `sample`, `sample_l`, `sample_b`, `sample_d`, `ld` and `resinfo` read a 2D texture through `texture.sig`.
  - A resource and sampler pair is one texture slot (`Layout.texture`).
  - A pixel shader with an implicit level of detail runs whole quads (`needsQuads`). Inside an `if` or a loop, where a quad's pixels may part, its derivatives are 0, as GLSL's are.
- **Not yet** (a log line, not a crash): early returns, `switch`, subroutines, indexable temps, other resource dimensions, multiple render targets, `SV_Depth`, the geometry, hull, domain and compute stages, and Shader Model 5.1's DXIL.

### Textures

- **Formats.** A texture's image is in one of the engine's formats. Draws write RGBA8, BGRA8, RG8 and R8. Draws only read the other sampling formats: f32, i32 and u32 with 1, 2 or 4 channels. `texfmt.sig` maps every upload GL ES 3.0 takes to them:
  - the sized formats (RGBA8, SRGB8_ALPHA8, RGB8, RGB565, RGBA4, RGB5_A1, R8, RG8, the 16F and 32F ones, and the 8-, 16- and 32-bit integer ones);
  - ES 2.0's unsized ones, LUMINANCE, ALPHA and LUMINANCE_ALPHA included;
  - `OES_texture_float` and `_half_float`, and BGRA.

  RGB is widened with alpha 1. The packed 16-bit formats are unpacked to bytes, half floats widened to f32, and 8- and 16-bit integers to 32 bits. LUMINANCE and ALPHA are R8 and RG8 with a swizzle. Unpack alignment, row length and skips work for any texel size, from client memory or an unpack buffer.
- **Levels.** A texture's image holds its mipmap chain in one buffer, level after level (`Engine.newImageChain`), so a draw binds one buffer a texture. The descriptor carries each level's offset.
  - `glTexStorage2D` makes the chain it asks for. `glTexImage2D` at a level past 0 grows a mutable texture's chain to the full one, copying in what it holds. The level is stored when level 0 is there, of its format, and the level's size is level 0's halved. Otherwise it is not stored, and a texture needing it is incomplete.
  - `glGenerateMipmap` is a GPU kernel, or the same kernel on the CPU. It builds each level from the one before, 2×2 texels averaged and rounded; an odd edge's last texel is taken twice. It takes RGBA8, BGRA8, RG8 and R8 storage, which covers what ES 3.0 lets filter and render. sRGB is averaged as stored.
  - **Completeness** follows ES 3.0 3.8.13. The base level (`TEXTURE_BASE_LEVEL`) must be there. With a mipmap filter, so must every level up to the last: the base level's log2 size or `TEXTURE_MAX_LEVEL`, and an immutable texture's last. An incomplete texture reads (0, 0, 0, 1). So does a one-level texture under the default minification filter, `NEAREST_MIPMAP_LINEAR`, as in Mesa.
- **Filtering** (ES 3.0 3.8.11). λ comes from the derivatives scaled to the base level's size, plus the bias, clamped to `TEXTURE_MIN_LOD`..`MAX_LOD`.
  - At or below c (0.5 when magnifying `LINEAR` and minifying `NEAREST_MIPMAP_*`, else 0), λ magnifies.
  - `*_MIPMAP_NEAREST` reads level base + ⌈λ + ½⌉ − 1. `*_MIPMAP_LINEAR` blends levels base + ⌊λ⌋ and the next by λ's fraction. Neither goes past the last level.
  - λ is computed only where it can matter: mipmaps, or different filters each way. A program's code is the same either way.
- **Sampler objects.** `glGenSamplers` and the rest, bound per unit. A bound sampler object's filters, wraps, LOD range and compare mode replace its unit's texture's.
- **In a draw.** Each sampler of the program (each element of a sampler array) is a texture slot, up to 16, read by both stages. The draw binds the slot's unit's texture image after each kernel's own buffers. It writes the slot's descriptor after the uniforms: size, row stride, format (texel bytes, kind, channels, sRGB), a swizzle, the wraps and the filter. The swizzle composes BGRA's byte order, the format's (LUMINANCE ...) and `TEXTURE_SWIZZLE_*`.
- **The read** (`texture.sig`) is one code for every format, so a program's code doesn't depend on what is bound to its samplers:
  - A texel is up to four aligned words, each clamped inside the image, so no read goes past it. Its channels are taken as the descriptor says, missing ones 0, 0, 0, 1.
  - Unorm bytes are multiplied by 1/255. sRGB is decoded before filtering.
  - Wraps are computed exactly in float: an approximate reciprocal, corrected. Bilinear filtering blends the four texels with exact operations; nearest takes the texel itself.
  - Integer samplers read their base level, nearest. A unit with no complete texture reads (0, 0, 0, 1).

  Every operation but sRGB's is one KIR defines bit for bit, so a sample is the same bytes on every GPU and on the CPU.
- **Render targets.** A texture is color-renderable when its internal format is (ES 3.0's table: RGBA8, RGB8, the 16-bit packed ones, R8, RG8, BGRA8, and the unsized RGBA and RGB) and it is stored as a format draws write. LUMINANCE and ALPHA aren't renderable, and sRGB isn't yet. `glReadPixels` takes RGBA, BGRA, and the framebuffer's own format: RED for R8, RG for RG8 (`IMPLEMENTATION_COLOR_READ_FORMAT`). `glCopyTex*Image2D` copies into a texture of the source's channels or fewer.
- **Not yet:** cube, 3D and array textures, depth textures and shadow comparisons, compressed formats, RGB10_A2, R11F_G11F_B10F and RGB9_E5, norm16, float and integer render targets. Every float sample reads four texels, nearest ones too, and loads four words a texel. A sampler's code specialized to its texture's format and filter is for later.

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

The library is `libgalaxy-gl.so`, with 58 `egl*` and 220 `gl*` entry points. It is packaged as `libEGL.so.1` and `libGLESv2.so.2`, both links to the one file. The dynamic linker loads a file once, whatever name finds it, so EGL and GL share their state.

Each context is current per thread. The current context is kept in a fixed table keyed by the thread pointer (`TPIDR_EL0` on AArch64, `%fs:0` on x86-64), so the library needs no thread-local storage and no C library.

**What it says of itself.** An app's stderr (on Galaxy, the kernel log) gets `galaxy-gl[pid]:` lines (`report.sig`), each kind a few times at most:
- the device it draws on, or why it has none;
- an entry point the app asked for that the driver lacks;
- a program that did not link, with its log's first line;
- a pipeline the GPU refuses: its draws then run on the CPU, and it isn't compiled again at every draw;
- a lost GPU;
- the first GL errors;
- what a check of the GPU against the CPU found (below).

**A lost GPU.** The driver says so as EXT_ and KHR_robustness do. Both are in `GL_EXTENSIONS`, because Firefox takes its feature "robustness" only from them. A context made with EGL's `LOSE_CONTEXT_ON_RESET`:
- answers `GL_RESET_NOTIFICATION_STRATEGY` with it;
- gives `UNKNOWN_CONTEXT_RESET` from `glGetGraphicsResetStatus` once;
- gives `CONTEXT_LOST` from `glGetError` once.

Firefox then rebuilds its compositor, finds no display (EGL refuses a context on a lost engine), and goes on in software. Meanwhile the engine draws on the CPU:
- KIR's interpreter has 16 MB of `.bss` scratch;
- images made after the loss come from a 512 MB pool of reserved address space, each page filled on first touch.

`glReadnPixels` and `glGetnUniform{f,i,ui}v` (with their EXT and KHR names) refuse a buffer too small. `GL_CONTEXT_ROBUST_ACCESS` is false: robust buffer access isn't promised, and isn't named.

**Checking the GPU against the CPU (`GALAXY_GL_CHECK`).** It's read from `/proc/self/environ`, since there's no C library to ask: `1` or `on` for ops of up to 128 x 128 pixels, a number for that many pixels. Galaxy sets it from `GPU.TXT`'s word `check`. Each kernel's first two runs small enough are done twice:
1. The work before is finished, and the rows the op writes are saved (a 64 MB reserved scratch).
2. The op runs on the GPU, and its result is set aside.
3. The rows are put back, the op runs on the CPU with the same kernels in KIR's interpreter, and the two are compared byte by byte.

A byte may be 2 apart (the GPU's reciprocals and roots aren't the CPU's to the last bit), and a few bytes past that are allowed.

- **When they agree:** a line says so.
- **When they don't:** a line names the op and its first differing pixel, with both values. For a draw, the GPU's vertex and triangle records are compared with the CPU's too, which names the kernel that went wrong first: the vertex kernel, the setup or bin kernel, or the tile kernel. The GPU is then lost: the CPU's result stands and the CPU draws on.

On the Surface, every KIR-compiled kernel failed on the real Adreno at first, while hand-written ir3 passed. This finds which op, and which kernel, at an app's first draws.

The library's panic handler prints one line and exits, as a failed assertion in a C driver does. It needs neither TLS nor a stack walk. EGL's tables, and the render node's, are filled at first use, so they take no room in the file.

As built (`sig build-lib -dynamic -target <arch>-linux-none -fPIC`), the library has no `DT_NEEDED` entries and no TLS segment. Its only undefined symbols are the weak `dlsym` and `dl_iterate_phdr`, which the dynamic linker binds from the program's C library. It is 1460 KB on aarch64 and 1511 KB on x86_64: the CPU fallback carries KIR's interpreter and the draw kernels' builders, and the GLSL compiler adds about 310 KB. Its tables (EGL's, the engine's kernel space, the compile scratch, the interpreter's scratch, the code generator's, the text pool, the programs) are bss, about 69 MB of address space, touched only as used.

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

**Stage 5d, textures:** the formats, uploads, reads and sampler objects above. Both stages read textures, so vertex texture fetch works too. There are 11 new GL entry points (sampler objects, `glGenerateMipmap`), 198 in all.

**Stage 5e:**
- binning: a bin kernel lists each 64×64 pixels' triangles, and tiles cull 64 at a time in shared memory;
- R8 and RG8 render targets: draws, clears, color masks, copies and reads;
- derivatives: quads with helper pixels, and 0 in control flow that is not uniform.

**Stage 5f, what WebRender asks:**
- WebRender's shaders: every variant a GLES device builds (46) compiles and links, and every draw kernel compiles for the Adreno (`test-gfxapi-webrender`);
- GLSL's division and square root as GPUs do them (above);
- the ir3 allocator's loop rule from SB0LTD/zpm#136 (a register lives through a loop only when the loop carries it): without it, six of WebRender's fragment kernels run out of registers;
- WebRender's GL calls past the draws: mapped buffers, sync objects and blits. There are 11 new GL entry points, 209 in all.

**Stage 5g, mipmaps:** levels stored in a chain, `glGenerateMipmap` on the GPU, texture completeness, the level of detail (implicit through quads, given, gradients, bias), nearest-mipmap and trilinear filtering, and `texelFetch` and `textureSize` by level.

**Not yet:**
- uniform blocks, transform feedback, queries;
- points and lines;
- clipping: a triangle with a vertex at w ≤ 0, or past a guard band of 24576 pixels, is dropped;
- stencil tests, several color attachments, depth-only drawing;
- half-float and packed attribute formats, divisors past 1, attribute arrays in client memory;
- framebuffer attachments and copies of texture levels past 0, other texture targets, the texture formats listed under Textures;
- multisampling;
- EGLImages of GL textures (`EGL_KHR_gl_texture_2D_image`) and dma-buf export (`EGL_MESA_image_dma_buf_export`), with `libgbm` (stage 7);
- multi-plane and YUV dma-bufs;
- native fences and dma-buf import on the PC: they wait for per-app RTX contexts;
- a Wayland connection of EGL's own, for `EGL_PLATFORM_WAYLAND_KHR` with `EGL_DEFAULT_DISPLAY`.

## Tests

```
sig build test-gfxapi
```

- `test-gfxapi-module`: the engine and the pool on the CPU; the driver's reports, each kind limited; float-to-unorm conversion (rounding to nearest even, as Mesa does); the render-node client against `node.Fake`, Galaxy's calls over the emulated Adreno, covering buffers, cache upkeep, import, export, a hang and a missing GPU.
- `test-gfxapi-tex`: textures sampled by a GLSL program, a quad a case, on the CPU, on `EmuDevice` and on the emulated Adreno (ir3). Each run gives the same bytes and the texels GL says. The cases:
  - reads: nearest, bilinear clamped at the edge, repeat, mirrored repeat;
  - formats: LUMINANCE and ALPHA, BGRA, RGB565 with a `TEXTURE_SWIZZLE`, an RGBA32F `texelFetch`, an RGBA32I integer texture;
  - `textureSize`, a unit with no texture, a sampler object's filter over its texture's;
  - a quad whose corners its vertex shader fetches from a float texture.

  The cases are drawn in two halves, each on a fresh device: the emulated Adreno's memory is 64 buffers, never freed.
- `test-gfxapi-mip`: mipmaps on the CPU, on `EmuDevice` and on the emulated Adreno (ir3), the same bytes and the texels GL says. It uses a texture of five levels, each one color, drawn on quads of 16, 8, 4, 2 and 1 pixels (the implicit LOD picks levels 0 to 4). The other cases:
  - `textureLod`, trilinear between two levels, `textureGrad`, a bias;
  - `texelFetch` and `textureSize` of a level, a base level of 1;
  - `glGenerateMipmap` of a checkerboard (gray);
  - a texture without the levels its filter needs (black);
  - an immutable texture's levels filled by `glTexSubImage2D`.

  Two halves, each on a fresh device.
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

  A second scene is larger than a bin: 256 half-transparent triangles all over a 200×136 target (their order shows), big ones across bins under a scissor box off the bins' grid, and a thin strip. Binned, unbinned, and with lists of 24 that run over, it gives the same bytes on the CPU. `EmuDevice` (lists that run over) and the emulated Adreno (binned) give them too.
- `test-gfxapi-targets`: R8 and RG8 targets on the CPU, on `EmuDevice` and on the emulated Adreno (ir3), the same bytes and the values GL says. An R8 texture is cleared, drawn into with additive blending, drawn into under a color mask that keeps its red, and given a corner copied from an RGBA8 framebuffer's red. It is read back as RED (its read format) and as RGBA. An RG8 texture is cleared, half drawn over, and read back as RG. An RG8 renderbuffer is complete and gives its sizes. A program samples both masks into an RGBA8 target.
- `test-gfxapi-xfer`: transfers on the CPU, on `EmuDevice` and on the emulated Adreno (ir3), the same bytes and the values GL says.
  - A texture uploaded through a mapped unpack buffer; rows rewritten through an unsynchronized map and an explicitly flushed one; a pack buffer mapped for reading.
  - Blits: 1:1, flipped and scaled 2×, a bilinear 2:1 downscale, under a scissor box, into BGRA8 and R8, depth and stencil together and depth alone.
  - Fences waited on and queried.
  - The errors GL gives for each.
- `test-gfxapi-webrender`: WebRender's shaders, read from a Firefox checkout's `gfx/wr/webrender/res` (`GFXAPI_WR_RES`; skipped without it, since Mozilla's sources stay out of zpm).
  - The 46 variants a GLES device builds are assembled as `webrender_build` assembles them (its defines, its `#include`s), then compiled and linked through GL's program objects.
  - Each program's vertex, setup and tile kernels are compiled for the Adreno's ir3. All must succeed.
  - sm_120 is tried and only reported. Its backend takes up to 4096 KIR instructions after expansions, and 45 of WebRender's kernels are larger. The PC comes with stage 10.
- `test-gfxapi-deriv`: a program with derivatives on the CPU, on `EmuDevice` and on the emulated Adreno (ir3), the same bytes and the values GL says. It draws four quads, one a mode:
  - steps of 1 across and up, the triangles' shared diagonal too, and a product's `fwidth`;
  - a circle's edge antialiased over a pixel with `fwidth`, as WebRender's clip shaders do;
  - a derivative under an `if` that splits quads (0), and one after it (1 again);
  - one after a `discard` that splits quads (0).

  Without the flow check, the CPU run traps on a shuffle from a lane that isn't running.
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

  The scenario covers clears with a scissor and a color mask, a top-down BGRA window, a texture upload with an unpack skip, a framebuffer object, a copy that flips and swaps, depth and stencil under a write mask, and a pack buffer. All three runs must give the same bytes. Further tests cover batching, a free deferred until its batch is done, and a GPU lost mid-batch (a reset told to a context made with `LOSE_CONTEXT_ON_RESET`).
- `test-gfxapi-draw`, the checks (`GALAXY_GL_CHECK`):
  - every op of its scene checked on `EmuDevice`: all the same, nothing lost;
  - a GPU that takes batches and does nothing: the first op that differs is caught, the GPU is lost, and the scene's bytes are the CPU's;
  - a GPU that skips each draw's tile kernel: the check says the vertex and setup kernels agree;
  - no room for a check: none is made.
- `libgles` robustness: the extensions, the strategy, a reset and `CONTEXT_LOST` told once, and the n-forms' size checks.

## Stages ahead

| # | Stage | Where |
|---|---|---|
| 3 | Done: the engine, the render-node client, the GLES core and the C ABI | zpm |
| 4a | Done: EGL 1.5, the Wayland platform, surfaceless and pbuffers, fence syncs, one `libgalaxy-gl.so` | zpm |
| 4b | Done: EGLImages and `EGL_EXT_image_dma_buf_import`, GL's `OES_EGL_image`; `EGL_ANDROID_native_fence_sync`; `zwp_linux_dmabuf_v1` v4 feedback | zpm + Galaxy |
| 5a | Done: draws. Vertex arrays, the three draw kernels (vertices, setup, tiles), exact coverage, depth, blending, culling, instancing; the same bytes on every GPU and the CPU | zpm |
| 5b | Done: the GLSL ES 1.00 and 3.00 front end (the preprocessor, parser, types and built-ins); shader and program objects, linking, uniforms and attributes by name | zpm |
| 5c | Done: GLSL to KIR, the vertex and fragment code draws run; the same bytes on the CPU and the emulated Adreno | zpm |
| 5d | Done: textures. GL ES 3.0's formats (R8, RG8, the float and integer ones, the legacy ones), sampled reads (nearest, bilinear, every wrap), `texelFetch`, sampler objects, in both stages; the same bytes on the CPU and the emulated Adreno | zpm |
| 5e | Done: triangles binned to tiles; render targets in R8 and RG8 (WebRender's masks); helper pixels for derivatives; the same bytes on the CPU and the emulated Adreno | zpm |
| 5f | Done: WebRender's shaders compiled and linked (all 46 GLES variants, every kernel compiling for the Adreno); GLSL's division and roots as GPUs do them; mapped buffers, sync objects and blits | zpm |
| 5g | Done: mipmaps. Levels in one chain, `glGenerateMipmap` on the GPU, completeness, implicit LOD through quads, `textureLod` and `textureGrad`, trilinear | zpm |
| 5h | Firefox's WebRender drawing on the Surface's GPU, and what that finds | zpm + Galaxy |
| 6 | Chromium through ANGLE on GLES | zpm |
| 7 | `libgbm.so.1` | zpm |
| 8 | Packaging: the libraries in Galaxy's root under Mesa's names; `mesa-*` provided by Galaxy; a Flatpak GL extension | Galaxy |
| 9 | A fixed-function Adreno backend (the 3D pipe), for speed | zpm |
| 10 | The PC: per-app RTX contexts in `nv_drm`, then the same driver on sm_120 | Galaxy + zpm |
| 11 | A Vulkan ICD (SPIR-V to KIR) | zpm |
