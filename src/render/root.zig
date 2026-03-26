// Render module root — re-exports all render subsystems
// Layer 2: Render
//
// Uses module imports (not relative @import) for subsystems that are
// also exposed as granular modules, avoiding "file exists in multiple modules".

pub const color = @import("color");
pub const primitives = @import("primitives");
pub const text = @import("text");
pub const icon = @import("icon");
