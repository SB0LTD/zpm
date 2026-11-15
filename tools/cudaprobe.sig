//! cudaprobe: the smallest piece of real GPU work through NVIDIA's own
//! driver (libcuda, WSL: /usr/lib/wsl/lib), for dxgtrace to watch: a
//! context, 1 MiB of GPU memory, a fill (cuMemsetD32), a copy back, a
//! check. Each step prints a line, so a trace can be cut at each step.
//!
//!   sig build-exe -target x86_64-linux-gnu -lc -OReleaseSafe
//!     tools/cudaprobe.sig --name cudaprobe
//!   DXGTRACE_OUT=cuda.dxgt LD_PRELOAD=./libdxgtrace.so ./cudaprobe

const std = @import("std");

extern "c" fn dlopen(name: [*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
extern "c" fn fflush(f: ?*anyopaque) c_int;

const RTLD_NOW = 2;
const N = 1 << 18; // dwords (1 MiB)
var host: [N]u32 = undefined;

fn sym(lib: ?*anyopaque, comptime T: type, name: [*:0]const u8) T {
    const p = dlsym(lib, name) orelse {
        _ = printf("cudaprobe: no %s\n", name);
        std.process.exit(2);
    };
    return @ptrCast(p);
}

/// dxgtrace's marker, when the probe runs under it: a note after each
/// step, so the ioctls before it are that step's.
var mark: ?*const fn ([*:0]const u8) callconv(.c) void = null;

fn step(name: [*:0]const u8, rc: c_int) void {
    if (mark) |m| m(name);
    _ = printf("cudaprobe: %s -> %d\n", name, rc);
    _ = fflush(null);
    if (rc != 0) std.process.exit(1);
}

pub fn main() void {
    const lib = dlopen("libcuda.so.1", RTLD_NOW) orelse dlopen("/usr/lib/wsl/lib/libcuda.so.1", RTLD_NOW) orelse {
        _ = printf("cudaprobe: no libcuda\n");
        std.process.exit(2);
    };
    const cuInit = sym(lib, *const fn (c_uint) callconv(.c) c_int, "cuInit");
    const cuDeviceGet = sym(lib, *const fn (*c_int, c_int) callconv(.c) c_int, "cuDeviceGet");
    const cuCtxCreate = sym(lib, *const fn (*usize, c_uint, c_int) callconv(.c) c_int, "cuCtxCreate_v2");
    const cuMemAlloc = sym(lib, *const fn (*u64, usize) callconv(.c) c_int, "cuMemAlloc_v2");
    const cuMemsetD32 = sym(lib, *const fn (u64, c_uint, usize) callconv(.c) c_int, "cuMemsetD32_v2");
    const cuCtxSynchronize = sym(lib, *const fn () callconv(.c) c_int, "cuCtxSynchronize");
    const cuMemcpyDtoH = sym(lib, *const fn (*anyopaque, u64, usize) callconv(.c) c_int, "cuMemcpyDtoH_v2");

    mark = @ptrCast(dlsym(null, "dxgtrace_mark"));
    if (mark) |m| m("start");
    step("cuInit", cuInit(0));
    var dev: c_int = 0;
    step("cuDeviceGet", cuDeviceGet(&dev, 0));
    var ctx: usize = 0;
    step("cuCtxCreate", cuCtxCreate(&ctx, 0, dev));
    var mem: u64 = 0;
    step("cuMemAlloc", cuMemAlloc(&mem, N * 4));
    _ = printf("cudaprobe: memory at 0x%llx\n", mem);
    step("cuMemsetD32", cuMemsetD32(mem, 0x5a5a1234, N));
    step("cuCtxSynchronize", cuCtxSynchronize());
    step("cuMemcpyDtoH", cuMemcpyDtoH(&host, mem, N * 4));
    var bad: usize = 0;
    for (host) |v| bad += @intFromBool(v != 0x5a5a1234);
    _ = printf("cudaprobe: %zu of %d dwords wrong\n", bad, @as(c_int, N));
    std.process.exit(if (bad == 0) 0 else 3);
}
