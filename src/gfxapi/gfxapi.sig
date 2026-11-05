//! @zpm/gfxapi — Galaxy's GPU driver for apps, in pure Sig: OpenGL ES and
//! EGL (then Vulkan) under the names and interfaces apps find Mesa's by,
//! over zpm's GPU-neutral layer (KIR, compiled to ir3 for the Adreno and
//! sm_120 for the RTX; gpu.Device). No C, no Mesa, no allocator.
//!
//! - engine: images in GPU memory, filled and copied by KIR kernels,
//!   batched, with the same work on the CPU when there is no GPU;
//! - gles: OpenGL ES 3.0's objects and state;
//! - glenum: GL's enum values;
//! - node: Galaxy's render node ('G' calls, G_IMPORT, PRIME) as a
//!   gpu.Device;
//! - egl: EGL 1.5: displays, configs, contexts, surfaces, swaps, syncs;
//! - wayland: EGL's Wayland platform (dma-buf frames to the compositor);
//! - thread: what EGL and GL keep per thread;
//! - dl: the host program's functions found by name;
//! - libgalaxy_gl.sig and libgles.sig (the shared library's root, not
//!   imported here): the C entry points.
//!
//! docs/GFXAPI.md has the plan and what each stage brings.

pub const engine = @import("engine.sig");
pub const gles = @import("gles.sig");
pub const glenum = @import("glenum.sig");
pub const node = @import("node.sig");
pub const egl = @import("egl.sig");
pub const wayland = @import("wayland.sig");
pub const thread = @import("thread.sig");
pub const dl = @import("dl.sig");
pub const host = @import("host.sig");

test {
    _ = engine;
    _ = gles;
    _ = node;
    _ = thread;
    _ = dl;
}
