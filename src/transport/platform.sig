// Platform-conditional import for the transport layer.
// On Linux: uses linux_platform.sig (syscalls, std.crypto)
// On Windows: uses win32.sig (Winsock2, BCrypt, SChannel)

const builtin = @import("builtin");

pub usingnamespace if (builtin.os.tag == .linux)
    @import("linux_platform")
else
    @import("win32");
