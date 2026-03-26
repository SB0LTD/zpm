// Platform module root — re-exports all platform subsystems
// Layer 1: Platform
//
// Uses module imports (not relative @import) for subsystems that are
// also exposed as granular modules, avoiding "file exists in multiple modules".

pub const win32 = @import("win32");
pub const gl = @import("gl");
pub const window = @import("window");
pub const input = @import("input");
pub const timer = @import("timer");
pub const thread = @import("threading");
pub const http = @import("http");
pub const crypto = @import("crypto");
pub const file = @import("file_io");
pub const seqlock = @import("seqlock");
pub const screenshot = @import("screenshot");
pub const log = @import("logging");
pub const png = @import("png");
pub const mcp = @import("mcp");
