//! @zpm/vk — Galaxy's Vulkan driver (the module root).
//!
//! `icd.sig` is the driver: every entry point, over zpm's GPU-neutral layer
//! (src/gpu) and its SPIR-V front end (src/spirv). `abi.sig` is Vulkan's C
//! types. `libgalaxy_vk.sig` is the shared library's root (the loader's
//! ICD entry points, the machine's GPU through Galaxy's render node).
//! PLAN.md says what comes next.

pub const abi = @import("abi.sig");
pub const icd = @import("icd.sig");
pub const format = @import("format.sig");

test {
    _ = icd;
    _ = format;
}
