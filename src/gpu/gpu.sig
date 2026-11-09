//! @zpm/gpu — GPU compute on any GPU, in pure Sig.
//!
//! A kernel is written once in KIR (kir.sig), built at run time into
//! caller-owned storage, and compiled per GPU by a backend (kir_ir3 for
//! the Adreno, kir_sm120 for the RTX; the interpreter runs KIR itself).
//! A Device (device.sig) is any GPU: buffers by kind over unified or
//! discrete memory, programs, ordered dispatches under one fence.
//! EmuDevice (emu_device.sig) is the reference device, on kir_interp.
//!
//! No C, Mesa, CUDA, Vulkan or vendor user space at build or run time;
//! allocation-free throughout. docs/GPU.md has the memory model, the
//! exactness rules and how to add a GPU.

pub const kir = @import("kir.sig");
pub const device = @import("device.sig");
pub const interp = @import("kir_interp.sig");
pub const emu_device = @import("emu_device.sig");
/// The RTX as a Device (Galaxy's driver or the emulated RTX), running kir_sm120.
pub const nvidia_device = @import("nvidia_device.sig");
/// Rectangles through a GPU's graphics pipeline: the types, the Renderer
/// every GPU's pipeline is called through, the CPU reference and the
/// self-test's cases.
pub const draw = @import("draw.sig");

// KIR
pub const Ty = kir.Ty;
pub const V = kir.V;
pub const Arg = kir.Arg;
pub const Op = kir.Op;
pub const Inst = kir.Inst;
pub const Kernel = kir.Kernel;
pub const Storage = kir.Storage;
pub const Mem = kir.Mem;
pub const r = kir.r;
pub const u = kir.u;
pub const f = kir.f;
pub const i = kir.i;

// Devices
pub const Vendor = device.Vendor;
pub const Target = device.Target;
pub const MemoryModel = device.MemoryModel;
pub const Caps = device.Caps;
pub const Kind = device.Kind;
pub const Buffer = device.Buffer;
/// A Buffer over memory someone else mapped for the GPU (Kind.external).
pub const external = device.external;
pub const Hazards = device.Hazards;
pub const Binary = device.Binary;
pub const Program = device.Program;
pub const Dispatch = device.Dispatch;
pub const Error = device.Error;
pub const Fence = device.Fence;
pub const Device = device.Device;
pub const Work = device.Work;
pub const compile = device.compile;
/// compile with only the listed targets' backends linked (kernel images).
pub const compileFor = device.compileFor;
pub const all_targets = device.all_targets;
pub const interp_caps = device.interp_caps;

pub const EmuDevice = emu_device.EmuDevice;

// The Adreno: KIR to ir3, and the Adreno (or its emulator) as a Device.
pub const kir_ir3 = @import("kir_ir3.sig");
pub const adreno_device = @import("adreno_device.sig");

/// The self-test: KIR on a real Device against the interpreter, case by
/// case, logged line by line (the first boot on a GPU names any op it gets
/// wrong).
pub const selftest = @import("selftest.sig");
// AMD GCN 4 (gfx803, Polaris): KIR to gcn3 words, and the emulated GPU as a Device.
pub const kir_gcn4 = @import("kir_gcn4.sig");
pub const amd_device = @import("amd_device.sig");

test {
    _ = kir;
    _ = device;
    _ = interp;
    _ = emu_device;
    _ = kir_ir3;
    _ = adreno_device;
    _ = kir_gcn4;
    _ = amd_device;
    _ = draw;
}
