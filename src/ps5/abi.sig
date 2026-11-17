//! @zpm/ps5 abi — the system call ABI a PlayStation 5 program speaks, as
//! data: what a kernel needs to answer the calls natively, and what a
//! libkernel written in Sig needs to make them.
//!
//! The PS5's kernel descends from FreeBSD 11, and a program's side of it is
//! FreeBSD's amd64 convention:
//!
//!   - `syscall`, the number in rax, arguments in rdi, rsi, rdx, r10, r8, r9;
//!   - the result in rax (and rdx for the few calls with two);
//!   - an error is the carry flag set and a positive errno in rax: never
//!     Linux's negative number;
//!   - rcx and r11 are lost (the instruction itself takes them).
//!
//! The numbers up to 531 are FreeBSD 11's (sys/kern/syscalls.master); Sony's
//! own start at 532. The structures are FreeBSD 11's amd64 layouts (before
//! its 64-bit inode change: a `struct stat` is 120 bytes).
//!
//! The conversions here go to Linux's values (open flags, mmap flags, clock
//! ids, errno), because the kernels this runs on answer the calls with the
//! services that already answer Linux programs: a call is renumbered and
//! its flags reworded once, at the boundary, and runs natively from there.
//!
//! Sources: FreeBSD 11.0's sources (BSD licence) for the convention, the
//! base numbers and the structures; Sony's numbers as two independent open
//! reimplementations of the kernel list them (RPCSX and fpPS4, which agree
//! from 99 to 676; read as documentation only).
//! Allocation-free: plain values.

const std = @import("std");

// ── Numbers ─────────────────────────────────────────────────────────────────

pub const Sys = struct {
    pub const syscall = 0; // the indirect call: the number is the first argument
    pub const exit = 1;
    pub const read = 3;
    pub const write = 4;
    pub const open = 5;
    pub const close = 6;
    pub const unlink = 10;
    pub const chdir = 12;
    pub const getpid = 20;
    pub const getuid = 24;
    pub const geteuid = 25;
    pub const recvfrom = 29;
    pub const accept = 30;
    pub const getpeername = 31;
    pub const getsockname = 32;
    pub const access = 33;
    pub const kill = 37;
    pub const getppid = 39;
    pub const dup = 41;
    pub const getegid = 43;
    pub const getgid = 47;
    pub const ioctl = 54;
    pub const munmap = 73;
    pub const mprotect = 74;
    pub const madvise = 75;
    pub const dup2 = 90;
    pub const fcntl = 92;
    pub const select = 93;
    pub const fsync = 95;
    pub const socket = 97;
    pub const connect = 98;
    pub const netcontrol = 99;
    pub const netabort = 101; // Sony's, in FreeBSD's range
    pub const netgetsockinfo = 102; // Sony's, in FreeBSD's range
    pub const bind = 104;
    pub const setsockopt = 105;
    pub const listen = 106;
    pub const socketex = 113; // Sony's, in FreeBSD's range
    pub const socketclose = 114; // Sony's, in FreeBSD's range
    pub const gettimeofday = 116;
    pub const getrusage = 117;
    pub const getsockopt = 118;
    pub const readv = 120;
    pub const writev = 121;
    pub const netgetiflist = 125; // Sony's, in FreeBSD's range
    pub const rename = 128;
    pub const sendto = 133;
    pub const shutdown = 134;
    pub const mkdir = 136;
    pub const rmdir = 137;
    pub const kqueueex = 141; // Sony's, in FreeBSD's range
    pub const sysarch = 165;
    pub const stat = 188;
    pub const fstat = 189;
    pub const lstat = 190;
    pub const getrlimit = 194;
    pub const getdirentries = 196;
    pub const __syscall = 198; // indirect, with a 64-bit number
    pub const __sysctl = 202;
    pub const poll = 209;
    pub const clock_gettime = 232;
    pub const clock_getres = 234;
    pub const nanosleep = 240;
    pub const getdents = 272;
    pub const sched_yield = 331;
    pub const sigprocmask = 340;
    pub const kqueue = 362;
    pub const kevent = 363;
    pub const mtypeprotect = 379; // Sony's, in FreeBSD's range
    pub const sigaction = 416;
    pub const sigreturn = 417;
    pub const thr_exit = 431;
    pub const thr_self = 432;
    pub const thr_kill = 433;
    pub const _umtx_op = 454;
    pub const thr_new = 455;
    pub const thr_set_name = 464;
    pub const rtprio_thread = 466;
    pub const pread = 475;
    pub const pwrite = 476;
    pub const mmap = 477;
    pub const lseek = 478;
    pub const truncate = 479;
    pub const ftruncate = 480;
    pub const cpuset_getaffinity = 487;
    pub const cpuset_setaffinity = 488;
    pub const openat = 499;
    // Sony's own (the PS4's, kept on the PS5).
    pub const regmgr_call = 532;
    pub const jitshm_create = 533;
    pub const jitshm_alias = 534;
    pub const dl_get_list = 535;
    pub const dl_get_info = 536;
    pub const dl_notify_event = 537;
    pub const evf_create = 538;
    pub const evf_delete = 539;
    pub const evf_open = 540;
    pub const evf_close = 541;
    pub const evf_wait = 542;
    pub const evf_trywait = 543;
    pub const evf_set = 544;
    pub const evf_clear = 545;
    pub const evf_cancel = 546;
    pub const query_memory_protection = 547;
    pub const batch_map = 548;
    pub const osem_create = 549;
    pub const osem_delete = 550;
    pub const osem_open = 551;
    pub const osem_close = 552;
    pub const osem_wait = 553;
    pub const osem_trywait = 554;
    pub const osem_post = 555;
    pub const osem_cancel = 556;
    pub const namedobj_create = 557;
    pub const namedobj_delete = 558;
    pub const set_vm_container = 559;
    pub const debug_init = 560;
    pub const suspend_process = 561;
    pub const resume_process = 562;
    pub const opmc_enable = 563;
    pub const opmc_disable = 564;
    pub const opmc_set_ctl = 565;
    pub const opmc_set_ctr = 566;
    pub const opmc_get_ctr = 567;
    pub const budget_create = 568;
    pub const budget_delete = 569;
    pub const budget_get = 570;
    pub const budget_set = 571;
    pub const virtual_query = 572;
    pub const mdbg_call = 573;
    pub const obs_sblock_create = 574;
    pub const obs_sblock_delete = 575;
    pub const obs_sblock_enter = 576;
    pub const obs_sblock_exit = 577;
    pub const obs_sblock_xenter = 578;
    pub const obs_sblock_xexit = 579;
    pub const obs_eport_create = 580;
    pub const obs_eport_delete = 581;
    pub const obs_eport_trigger = 582;
    pub const obs_eport_open = 583;
    pub const obs_eport_close = 584;
    pub const is_in_sandbox = 585;
    pub const dmem_container = 586;
    pub const get_authinfo = 587;
    pub const mname = 588;
    pub const dynlib_dlopen = 589;
    pub const dynlib_dlclose = 590;
    pub const dynlib_dlsym = 591;
    pub const dynlib_get_list = 592;
    pub const dynlib_get_info = 593;
    pub const dynlib_load_prx = 594;
    pub const dynlib_unload_prx = 595;
    pub const dynlib_do_copy_relocations = 596;
    pub const dynlib_prepare_dlclose = 597;
    pub const dynlib_get_proc_param = 598;
    pub const dynlib_process_needed_and_relocate = 599;
    pub const sandbox_path = 600;
    pub const mdbg_service = 601;
    pub const randomized_path = 602;
    pub const rdup = 603;
    pub const dl_get_metadata = 604;
    pub const workaround8849 = 605;
    pub const is_development_mode = 606;
    pub const get_self_auth_info = 607;
    pub const dynlib_get_info_ex = 608;
    pub const budget_getid = 609;
    pub const budget_get_ptype = 610;
    pub const get_paging_stats_of_all_threads = 611;
    pub const get_proc_type_info = 612;
    pub const get_resident_count = 613;
    pub const prepare_to_suspend_process = 614;
    pub const get_resident_fmem_count = 615;
    pub const thr_get_name = 616;
    pub const set_gpo = 617;
    pub const get_paging_stats_of_all_objects = 618;
    pub const test_debug_rwmem = 619;
    pub const free_stack = 620;
    pub const suspend_system = 621;
    pub const ipmimgr_call = 622;
    pub const get_gpo = 623;
    pub const get_vm_map_timestamp = 624;
    pub const opmc_set_hw = 625;
    pub const opmc_get_hw = 626;
    pub const get_cpu_usage_all = 627;
    pub const mmap_dmem = 628;
    pub const physhm_open = 629;
    pub const physhm_unlink = 630;
    pub const resume_internal_hdd = 631;
    pub const thr_suspend_ucontext = 632;
    pub const thr_resume_ucontext = 633;
    pub const thr_get_ucontext = 634;
    pub const thr_set_ucontext = 635;
    pub const set_timezone_info = 636;
    pub const set_phys_fmem_limit = 637;
    pub const utc_to_localtime = 638;
    pub const localtime_to_utc = 639;
    pub const set_uevt = 640;
    pub const get_cpu_usage_proc = 641;
    pub const get_map_statistics = 642;
    pub const set_chicken_switches = 643;
    pub const extend_page_table_pool = 644;
    pub const extend_page_table_pool2 = 645;
    pub const get_kernel_mem_statistics = 646;
    pub const get_sdk_compiled_version = 647;
    pub const app_state_change = 648;
    pub const dynlib_get_obj_member = 649;
    pub const budget_get_ptype_of_budget = 650;
    pub const prepare_to_resume_process = 651;
    pub const process_terminate = 652;
    pub const blockpool_open = 653;
    pub const blockpool_map = 654;
    pub const blockpool_unmap = 655;
    pub const dynlib_get_info_for_libdbg = 656;
    pub const blockpool_batch = 657;
    pub const fdatasync = 658;
    pub const dynlib_get_list2 = 659;
    pub const dynlib_get_info2 = 660;
    pub const aio_submit = 661;
    pub const aio_multi_delete = 662;
    pub const aio_multi_wait = 663;
    pub const aio_multi_poll = 664;
    pub const aio_get_data = 665;
    pub const aio_multi_cancel = 666;
    pub const get_bio_usage_all = 667;
    pub const aio_create = 668;
    pub const aio_submit_cmd = 669;
    pub const aio_init = 670;
    pub const get_page_table_stats = 671;
    pub const dynlib_get_list_for_libdbg = 672;
    pub const blockpool_move = 673;
    pub const virtual_query_all = 674;
    pub const reserve_2mb_page = 675;
    pub const cpumode_yield = 676;
    // The PS5's: FreeBSD 11's own calls from 532 up moved here, then new ones
    // (one source for these: RPCSX's table).
    pub const wait6 = 677;
    pub const cap_rights_limit = 678;
    pub const cap_ioctls_limit = 679;
    pub const cap_ioctls_get = 680;
    pub const cap_fcntls_limit = 681;
    pub const cap_fcntls_get = 682;
    pub const bindat = 683;
    pub const connectat = 684;
    pub const chflagsat = 685;
    pub const accept4 = 686;
    pub const pipe2 = 687;
    pub const aio_mlock = 688;
    pub const procctl = 689;
    pub const ppoll = 690;
    pub const futimens = 691;
    pub const utimensat = 692;
    pub const numa_getaffinity = 693;
    pub const numa_setaffinity = 694;
    pub const apr_submit = 700;
    pub const apr_resolve = 701;
    pub const apr_stat = 702;
    pub const apr_wait = 703;
    pub const apr_ctrl = 704;
    pub const get_phys_page_size = 705;
    pub const begin_app_mount = 706;
    pub const end_app_mount = 707;
    pub const fsc2h_ctrl = 708;
    pub const streamwrite = 709;
    pub const app_save = 710;
    pub const app_restore = 711;
    pub const saved_app_delete = 712;
    pub const get_ppr_sdk_compiled_version = 713;
    pub const notify_app_event = 714;
    pub const ioreq = 715;
    pub const openintr = 716;
    pub const dl_get_info_2 = 717;
    pub const acinfo_add = 718;
    pub const acinfo_delete = 719;
    pub const acinfo_get_all_for_coredump = 720;
    pub const ampr_ctrl_debug = 721;
    pub const workspace_ctrl = 722;
};

/// One past the highest number a table of calls needs a slot for.
pub const SYS_MAX = 768;

/// A call's name (for a trace, or to say which call a kernel lacks): the
/// declarations of `Sys`, indexed by number.
pub fn sysName(nr: u64) ?[]const u8 {
    if (nr >= SYS_MAX) return null;
    const n = names[nr];
    return if (n.len == 0) null else n;
}

const names: [SYS_MAX][]const u8 = blk: {
    var t = [_][]const u8{""} ** SYS_MAX;
    for (std.meta.declarations(Sys)) |d| t[@field(Sys, d)] = d;
    break :blk t;
};

// ── Errors ──────────────────────────────────────────────────────────────────

/// FreeBSD's errno values (the ones that differ from Linux's are the reason
/// this table exists: 1 to 34 agree but for 11).
pub const E = struct {
    pub const PERM = 1;
    pub const NOENT = 2;
    pub const SRCH = 3;
    pub const INTR = 4;
    pub const IO = 5;
    pub const NXIO = 6;
    pub const @"2BIG" = 7;
    pub const NOEXEC = 8;
    pub const BADF = 9;
    pub const CHILD = 10;
    pub const DEADLK = 11;
    pub const NOMEM = 12;
    pub const ACCES = 13;
    pub const FAULT = 14;
    pub const BUSY = 16;
    pub const EXIST = 17;
    pub const NODEV = 19;
    pub const NOTDIR = 20;
    pub const ISDIR = 21;
    pub const INVAL = 22;
    pub const MFILE = 24;
    pub const NOTTY = 25;
    pub const FBIG = 27;
    pub const NOSPC = 28;
    pub const SPIPE = 29;
    pub const ROFS = 30;
    pub const PIPE = 32;
    pub const DOM = 33;
    pub const RANGE = 34;
    pub const AGAIN = 35;
    pub const INPROGRESS = 36;
    pub const ALREADY = 37;
    pub const NOTSOCK = 38;
    pub const DESTADDRREQ = 39;
    pub const MSGSIZE = 40;
    pub const PROTOTYPE = 41;
    pub const NOPROTOOPT = 42;
    pub const PROTONOSUPPORT = 43;
    pub const SOCKTNOSUPPORT = 44;
    pub const OPNOTSUPP = 45;
    pub const PFNOSUPPORT = 46;
    pub const AFNOSUPPORT = 47;
    pub const ADDRINUSE = 48;
    pub const ADDRNOTAVAIL = 49;
    pub const NETDOWN = 50;
    pub const NETUNREACH = 51;
    pub const NETRESET = 52;
    pub const CONNABORTED = 53;
    pub const CONNRESET = 54;
    pub const NOBUFS = 55;
    pub const ISCONN = 56;
    pub const NOTCONN = 57;
    pub const SHUTDOWN = 58;
    pub const TOOMANYREFS = 59;
    pub const TIMEDOUT = 60;
    pub const CONNREFUSED = 61;
    pub const LOOP = 62;
    pub const NAMETOOLONG = 63;
    pub const HOSTDOWN = 64;
    pub const HOSTUNREACH = 65;
    pub const NOTEMPTY = 66;
    pub const USERS = 68;
    pub const DQUOT = 69;
    pub const STALE = 70;
    pub const NOLCK = 77;
    pub const NOSYS = 78;
    pub const IDRM = 82;
    pub const NOMSG = 83;
    pub const OVERFLOW = 84;
    pub const CANCELED = 85;
    pub const ILSEQ = 86;
    pub const NOATTR = 87;
    pub const BADMSG = 89;
    pub const MULTIHOP = 90;
    pub const NOLINK = 91;
    pub const PROTO = 92;
    pub const NOTRECOVERABLE = 95;
    pub const OWNERDEAD = 96;
};

/// libkernel's `sceKernel*` functions return an errno as this plus it.
pub const SCE_KERNEL_ERROR_BASE: u32 = 0x8002_0000;

/// A Linux errno (positive) as FreeBSD's. One Linux has that FreeBSD lacks
/// becomes the nearest FreeBSD says in its place.
pub fn errnoFromLinux(e: u64) u32 {
    if (e < from_linux.len) return from_linux[e];
    return E.INVAL;
}

const from_linux: [134]u8 = blk: {
    var t: [134]u8 = undefined;
    for (&t, 0..) |*v, i| v.* = if (i <= 34) i else E.INVAL;
    const pairs = [_][2]u8{
        .{ 11, E.AGAIN },        .{ 35, E.DEADLK },       .{ 36, E.NAMETOOLONG },
        .{ 37, E.NOLCK },        .{ 38, E.NOSYS },        .{ 39, E.NOTEMPTY },
        .{ 40, E.LOOP },         .{ 42, E.NOMSG },        .{ 43, E.IDRM },
        .{ 61, E.NOATTR },       .{ 62, E.TIMEDOUT },     .{ 67, E.NOLINK },
        .{ 71, E.PROTO },        .{ 72, E.MULTIHOP },     .{ 74, E.BADMSG },
        .{ 75, E.OVERFLOW },     .{ 84, E.ILSEQ },        .{ 87, E.USERS },
        .{ 88, E.NOTSOCK },      .{ 89, E.DESTADDRREQ },  .{ 90, E.MSGSIZE },
        .{ 91, E.PROTOTYPE },    .{ 92, E.NOPROTOOPT },   .{ 93, E.PROTONOSUPPORT },
        .{ 94, E.SOCKTNOSUPPORT }, .{ 95, E.OPNOTSUPP },  .{ 96, E.PFNOSUPPORT },
        .{ 97, E.AFNOSUPPORT },  .{ 98, E.ADDRINUSE },    .{ 99, E.ADDRNOTAVAIL },
        .{ 100, E.NETDOWN },     .{ 101, E.NETUNREACH },  .{ 102, E.NETRESET },
        .{ 103, E.CONNABORTED }, .{ 104, E.CONNRESET },   .{ 105, E.NOBUFS },
        .{ 106, E.ISCONN },      .{ 107, E.NOTCONN },     .{ 108, E.SHUTDOWN },
        .{ 109, E.TOOMANYREFS }, .{ 110, E.TIMEDOUT },    .{ 111, E.CONNREFUSED },
        .{ 112, E.HOSTDOWN },    .{ 113, E.HOSTUNREACH }, .{ 114, E.ALREADY },
        .{ 115, E.INPROGRESS },  .{ 116, E.STALE },       .{ 122, E.DQUOT },
        .{ 125, E.CANCELED },    .{ 130, E.OWNERDEAD },   .{ 131, E.NOTRECOVERABLE },
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

/// What a kernel puts in a program's registers at the end of a call that
/// its Linux-shaped service answered with `v` (a result, or a negative
/// errno): rax, and whether the carry flag is set.
pub const Result = struct { rax: u64, carry: bool };

pub fn resultFromLinux(v: u64) Result {
    const s: i64 = @bitCast(v);
    if (s < 0 and s >= -4095) return .{ .rax = errnoFromLinux(@intCast(-s)), .carry = true };
    return .{ .rax = v, .carry = false };
}

// ── Flags ───────────────────────────────────────────────────────────────────

/// Which Linux the values go to: the flag numbers differ between Linux's
/// x86-64 and its generic (AArch64) tables in a few places.
pub const Linux = enum { x86_64, generic };

/// open(2) flags.
pub const O = struct {
    pub const ACCMODE = 0x3;
    pub const NONBLOCK = 0x4;
    pub const APPEND = 0x8;
    pub const SYNC = 0x80;
    pub const NOFOLLOW = 0x100;
    pub const CREAT = 0x200;
    pub const TRUNC = 0x400;
    pub const EXCL = 0x800;
    pub const NOCTTY = 0x8000;
    pub const DIRECT = 0x1_0000;
    pub const DIRECTORY = 0x2_0000;
    pub const CLOEXEC = 0x10_0000;
};

pub fn openFlagsToLinux(comptime linux: Linux, f: u64) u64 {
    const directory: u64 = if (linux == .x86_64) 0o200000 else 0o40000;
    const nofollow: u64 = if (linux == .x86_64) 0o400000 else 0o100000;
    const direct: u64 = if (linux == .x86_64) 0o40000 else 0o200000;
    var o: u64 = f & O.ACCMODE;
    if (f & O.NONBLOCK != 0) o |= 0o4000;
    if (f & O.APPEND != 0) o |= 0o2000;
    if (f & O.SYNC != 0) o |= 0o4010000;
    if (f & O.NOFOLLOW != 0) o |= nofollow;
    if (f & O.CREAT != 0) o |= 0o100;
    if (f & O.TRUNC != 0) o |= 0o1000;
    if (f & O.EXCL != 0) o |= 0o200;
    if (f & O.NOCTTY != 0) o |= 0o400;
    if (f & O.DIRECT != 0) o |= direct;
    if (f & O.DIRECTORY != 0) o |= directory;
    if (f & O.CLOEXEC != 0) o |= 0o2000000;
    return o;
}

/// mmap(2): the protection bits agree with Linux's (read 1, write 2,
/// execute 4); Sony adds two for the GPU's view of the same pages.
pub const PROT = struct {
    pub const READ = 0x1;
    pub const WRITE = 0x2;
    pub const EXEC = 0x4;
    pub const GPU_READ = 0x10;
    pub const GPU_WRITE = 0x20;
    pub const CPU_MASK = 0x7;
};

pub const MAP = struct {
    pub const SHARED = 0x1;
    pub const PRIVATE = 0x2;
    pub const FIXED = 0x10;
    pub const NORESERVE = 0x40;
    /// Sony: with FIXED, fail where something is mapped already.
    pub const NO_OVERWRITE = 0x80;
    /// Sony: reserve the addresses, map nothing.
    pub const VOID = 0x100;
    pub const STACK = 0x400;
    pub const ANON = 0x1000;
    /// FreeBSD's own spelling of NO_OVERWRITE.
    pub const EXCL = 0x4000;
    pub const ALIGN_SHIFT = 24;
};

/// A FreeBSD mmap request in Linux's words. `alignment` (a power of two, or
/// 0) is what the caller asked the address to be aligned to, which Linux's
/// mmap has no word for: the caller of this maps more and trims.
pub const Mmap = struct {
    flags: u64,
    prot: u64,
    alignment: u64,
    /// Addresses only (Sony's MAP_VOID): no page is ever to arrive.
    reserve: bool,
    /// The GPU is to see the pages too (read, write).
    gpu: [2]bool,
};

pub fn mmapToLinux(prot: u64, flags: u64) Mmap {
    var o: u64 = flags & (MAP.SHARED | MAP.PRIVATE);
    const no_overwrite = flags & (MAP.NO_OVERWRITE | MAP.EXCL) != 0;
    if (flags & MAP.FIXED != 0) o |= if (no_overwrite) 0x10_0000 else 0x10; // MAP_FIXED_NOREPLACE, MAP_FIXED
    if (flags & (MAP.ANON | MAP.VOID) != 0) o |= 0x20;
    if (flags & MAP.STACK != 0) o |= 0x2_0000;
    if (flags & (MAP.NORESERVE | MAP.VOID) != 0) o |= 0x4000;
    if (o & 3 == 0) o |= MAP.PRIVATE; // (FreeBSD lets an anonymous mapping name neither)
    // The alignment field (eight bits): log2 of the alignment, or 1 for "a
    // large page's" (MAP_ALIGNED_SUPER: 2 MiB on x86-64).
    const n: u8 = @truncate(flags >> MAP.ALIGN_SHIFT);
    const alignment: u64 = if (n == 1) 2 << 20 else if (n >= 12 and n < 48) @as(u64, 1) << @intCast(n) else 0;
    const reserve = flags & MAP.VOID != 0;
    return .{
        .flags = o,
        .prot = if (reserve) 0 else prot & PROT.CPU_MASK,
        .alignment = alignment,
        .reserve = reserve,
        .gpu = .{ prot & PROT.GPU_READ != 0, prot & PROT.GPU_WRITE != 0 },
    };
}

/// The granule the PS5's kernel maps a program's memory in: lengths round
/// up to it, and addresses it chooses are multiples of it.
pub const PAGE: u64 = 0x4000;

/// clock_gettime(2) ids.
pub const CLOCK = struct {
    pub const REALTIME = 0;
    pub const VIRTUAL = 1;
    pub const PROF = 2;
    pub const MONOTONIC = 4;
    pub const UPTIME = 5;
    pub const UPTIME_PRECISE = 7;
    pub const UPTIME_FAST = 8;
    pub const REALTIME_PRECISE = 9;
    pub const REALTIME_FAST = 10;
    pub const MONOTONIC_PRECISE = 11;
    pub const MONOTONIC_FAST = 12;
    pub const SECOND = 13;
    pub const THREAD_CPUTIME_ID = 14;
    pub const PROCESS_CPUTIME_ID = 15;
    // Sony's network clocks (they read as the wall clock here).
    pub const EXT_NETWORK = 16;
    pub const EXT_DEBUG_NETWORK = 17;
    pub const EXT_AD_NETWORK = 18;
    pub const EXT_RAW_NETWORK = 19;
};

/// The Linux clock that answers a FreeBSD one, or null for no such clock.
pub fn clockToLinux(id: u64) ?u64 {
    return switch (id) {
        CLOCK.REALTIME, CLOCK.REALTIME_PRECISE, CLOCK.EXT_NETWORK, CLOCK.EXT_DEBUG_NETWORK, CLOCK.EXT_AD_NETWORK, CLOCK.EXT_RAW_NETWORK => 0,
        CLOCK.REALTIME_FAST, CLOCK.SECOND => 5, // CLOCK_REALTIME_COARSE
        CLOCK.MONOTONIC, CLOCK.MONOTONIC_PRECISE, CLOCK.UPTIME, CLOCK.UPTIME_PRECISE => 1,
        CLOCK.MONOTONIC_FAST, CLOCK.UPTIME_FAST => 6, // CLOCK_MONOTONIC_COARSE
        CLOCK.VIRTUAL, CLOCK.PROF, CLOCK.PROCESS_CPUTIME_ID => 2,
        CLOCK.THREAD_CPUTIME_ID => 3,
        else => null,
    };
}

// ── Structures ──────────────────────────────────────────────────────────────

pub const Timespec = extern struct { sec: i64 = 0, nsec: i64 = 0 };

/// `struct stat` (FreeBSD 11, amd64; SceKernelStat is the same).
pub const Stat = extern struct {
    dev: u32 = 0,
    ino: u32 = 0,
    mode: u16 = 0,
    nlink: u16 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    rdev: u32 = 0,
    atim: Timespec = .{},
    mtim: Timespec = .{},
    ctim: Timespec = .{},
    size: i64 = 0,
    blocks: i64 = 0,
    blksize: u32 = 0,
    flags: u32 = 0,
    gen: u32 = 0,
    lspare: i32 = 0,
    birthtim: Timespec = .{},
};

/// Linux's generic (AArch64) `struct stat`, the 128 bytes a kernel that
/// answers Linux programs builds, as FreeBSD's.
pub fn statFromLinuxGeneric(st: *const [128]u8) Stat {
    const r = struct {
        fn int(comptime T: type, b: *const [128]u8, comptime off: usize) T {
            return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
        }
    }.int;
    return .{
        .dev = @truncate(r(u64, st, 0)),
        .ino = @truncate(r(u64, st, 8)),
        .mode = @truncate(r(u32, st, 16)),
        .nlink = @truncate(r(u32, st, 20)),
        .uid = r(u32, st, 24),
        .gid = r(u32, st, 28),
        .rdev = @truncate(r(u64, st, 32)),
        .size = r(i64, st, 48),
        .blksize = @bitCast(r(i32, st, 56)),
        .blocks = r(i64, st, 64),
        .atim = .{ .sec = r(i64, st, 72), .nsec = r(i64, st, 80) },
        .mtim = .{ .sec = r(i64, st, 88), .nsec = r(i64, st, 96) },
        .ctim = .{ .sec = r(i64, st, 104), .nsec = r(i64, st, 112) },
        .birthtim = .{ .sec = r(i64, st, 104), .nsec = r(i64, st, 112) },
    };
}

/// A directory entry's fixed part (`struct dirent`, FreeBSD 11): the name
/// follows, NUL-terminated, the whole padded to 4 bytes.
pub const DirentHead = extern struct {
    fileno: u32,
    reclen: u16,
    type: u8,
    namlen: u8,
};

/// Bytes a directory entry with a name this long takes.
pub fn direntLen(name_len: usize) usize {
    return (@sizeOf(DirentHead) + name_len + 1 + 3) & ~@as(usize, 3);
}

/// Writes one entry at the start of `buf`; the bytes used, or null when it
/// does not fit (or the name is longer than a dirent can say).
pub fn writeDirent(buf: []u8, fileno: u32, d_type: u8, name: []const u8) ?usize {
    if (name.len > 255) return null;
    const n = direntLen(name.len);
    if (buf.len < n) return null;
    const head = DirentHead{ .fileno = fileno, .reclen = @intCast(n), .type = d_type, .namlen = @intCast(name.len) };
    @memcpy(buf[0..@sizeOf(DirentHead)], std.mem.asBytes(&head));
    @memcpy(buf[@sizeOf(DirentHead)..][0..name.len], name);
    @memset(buf[@sizeOf(DirentHead) + name.len .. n], 0);
    return n;
}

/// thr_new(2)'s argument.
pub const ThrParam = extern struct {
    start_func: u64,
    arg: u64,
    stack_base: u64,
    stack_size: u64,
    tls_base: u64,
    tls_size: u64,
    /// Where the new thread's id goes, in the child's and the parent's
    /// memory (the same memory; two chances to learn it).
    child_tid: u64,
    parent_tid: u64,
    flags: i32,
    _pad: i32 = 0,
    rtp: u64,
    /// Sony: the thread's name (a string in the caller's memory), or 0.
    name: u64 = 0,
    spare: [2]u64 = .{ 0, 0 },

    /// The stack pointer a new thread starts with: the top, 16-aligned, less
    /// a slot, as if `start_func` had been called.
    pub fn initialSp(p: *const ThrParam) u64 {
        return ((p.stack_base +% p.stack_size) & ~@as(u64, 15)) -% 8;
    }
};

/// The first thread id FreeBSD gives (ids below are process ids).
pub const FIRST_TID: u32 = 100_001;

/// _umtx_op(2) operations.
pub const UMTX = struct {
    pub const WAIT = 2; // while *(long *)obj == val
    pub const WAKE = 3;
    pub const MUTEX_TRYLOCK = 4;
    pub const MUTEX_LOCK = 5;
    pub const MUTEX_UNLOCK = 6;
    pub const CV_WAIT = 8;
    pub const CV_SIGNAL = 9;
    pub const CV_BROADCAST = 10;
    pub const WAIT_UINT = 11; // while *(u32 *)obj == val
    pub const RW_RDLOCK = 12;
    pub const RW_WRLOCK = 13;
    pub const RW_UNLOCK = 14;
    pub const WAIT_UINT_PRIVATE = 15;
    pub const WAKE_PRIVATE = 16;
    pub const MUTEX_WAIT = 17;
    pub const SEM_WAIT = 19;
    pub const SEM_WAKE = 20;
    pub const NWAKE_PRIVATE = 21;
    pub const MUTEX_WAKE2 = 22;
    pub const SEM2_WAIT = 23;
    pub const SEM2_WAKE = 24;
};

/// A wait's timeout as _umtx_op takes it (`uaddr` says how many bytes
/// `uaddr2` points at: a bare timespec is relative).
pub const UmtxTime = extern struct {
    timeout: Timespec,
    flags: u32, // 1: absolute
    clockid: u32,

    pub const ABSTIME = 1;
};

/// sysarch(2) operations: the thread's FS and GS bases (a pointer to the
/// value is the argument).
pub const ARCH = struct {
    pub const GET_FSBASE = 128;
    pub const SET_FSBASE = 129;
    pub const GET_GSBASE = 130;
    pub const SET_GSBASE = 131;
};

/// __sysctl(2) names a program's start-up asks.
pub const CTL = struct {
    pub const KERN = 1;
    pub const HW = 6;
    pub const KERN_OSTYPE = 1;
    pub const KERN_OSRELEASE = 2;
    pub const KERN_PROC = 14;
    pub const KERN_USRSTACK = 33;
    pub const KERN_ARND = 37;
    pub const HW_NCPU = 3;
    pub const HW_PAGESIZE = 7;
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "the structures have FreeBSD 11's sizes" {
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(Stat));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(Stat, "size"));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(Stat, "birthtim"));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(ThrParam));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(ThrParam, "rtp"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(UmtxTime));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(DirentHead));
}

test "calls have names" {
    try std.testing.expectEqualStrings("write", sysName(4).?);
    try std.testing.expectEqualStrings("thr_new", sysName(455).?);
    try std.testing.expectEqualStrings("dynlib_load_prx", sysName(594).?);
    try std.testing.expectEqual(@as(?[]const u8, null), sysName(2)); // (fork: not a call a game makes)
    try std.testing.expectEqual(@as(?[]const u8, null), sysName(100_000));
}

test "errors: Linux's numbers become FreeBSD's, with the carry flag" {
    try std.testing.expectEqual(@as(u32, E.NOENT), errnoFromLinux(2));
    try std.testing.expectEqual(@as(u32, E.AGAIN), errnoFromLinux(11));
    try std.testing.expectEqual(@as(u32, E.DEADLK), errnoFromLinux(35));
    try std.testing.expectEqual(@as(u32, E.NOSYS), errnoFromLinux(38));
    try std.testing.expectEqual(@as(u32, E.TIMEDOUT), errnoFromLinux(110));
    try std.testing.expectEqual(@as(u32, E.INVAL), errnoFromLinux(4000));
    const ok = resultFromLinux(0x7fff_1234_5000);
    try std.testing.expect(!ok.carry and ok.rax == 0x7fff_1234_5000);
    const err = resultFromLinux(@bitCast(@as(i64, -110)));
    try std.testing.expect(err.carry and err.rax == E.TIMEDOUT);
    // (a high address is not an error: only -4095..-1 are)
    const high = resultFromLinux(0xffff_8000_0000_0000);
    try std.testing.expect(!high.carry);
}

test "open flags go to each Linux's values" {
    const f = O.CREAT | O.TRUNC | 1 | O.DIRECTORY | O.CLOEXEC;
    try std.testing.expectEqual(@as(u64, 0o100 | 0o1000 | 1 | 0o200000 | 0o2000000), openFlagsToLinux(.x86_64, f));
    try std.testing.expectEqual(@as(u64, 0o100 | 0o1000 | 1 | 0o40000 | 0o2000000), openFlagsToLinux(.generic, f));
}

test "mmap: anonymous, fixed without overwriting, reserved, aligned" {
    const anon = mmapToLinux(3, MAP.ANON | MAP.PRIVATE);
    try std.testing.expectEqual(@as(u64, 0x22), anon.flags);
    try std.testing.expectEqual(@as(u64, 3), anon.prot);
    const fixed = mmapToLinux(3, MAP.ANON | MAP.FIXED | MAP.NO_OVERWRITE);
    try std.testing.expectEqual(@as(u64, 0x10_0000 | 0x20 | 2), fixed.flags);
    const void_ = mmapToLinux(3 | PROT.GPU_READ, MAP.VOID | MAP.SHARED);
    try std.testing.expect(void_.reserve and void_.prot == 0 and void_.gpu[0] and !void_.gpu[1]);
    const aligned = mmapToLinux(3, MAP.ANON | (21 << MAP.ALIGN_SHIFT));
    try std.testing.expectEqual(@as(u64, 2 << 20), aligned.alignment);
    // (MAP_ALIGNED_SUPER, and a field no alignment can be)
    try std.testing.expectEqual(@as(u64, 2 << 20), mmapToLinux(3, MAP.ANON | (1 << MAP.ALIGN_SHIFT)).alignment);
    try std.testing.expectEqual(@as(u64, 0), mmapToLinux(3, MAP.ANON | (200 << MAP.ALIGN_SHIFT)).alignment);
}

test "a directory entry is laid out as FreeBSD's" {
    var b: [32]u8 = [_]u8{0xaa} ** 32;
    const n = writeDirent(&b, 7, 8, "eboot.bin").?;
    try std.testing.expectEqual(@as(usize, 20), n); // 8 + 9 + 1, padded to 4
    try std.testing.expectEqual(@as(u16, 20), std.mem.readInt(u16, b[4..6], .little));
    try std.testing.expectEqual(@as(u8, 9), b[7]);
    try std.testing.expectEqualStrings("eboot.bin", b[8..17]);
    try std.testing.expectEqual(@as(u8, 0), b[17]);
    try std.testing.expectEqual(@as(?usize, null), writeDirent(b[0..8], 7, 8, "x"));
}

test "a Linux stat becomes FreeBSD's" {
    var l = [_]u8{0} ** 128;
    std.mem.writeInt(u64, l[8..16], 42, .little); // st_ino
    std.mem.writeInt(u32, l[16..20], 0o100644, .little); // st_mode
    std.mem.writeInt(u32, l[20..24], 1, .little); // st_nlink
    std.mem.writeInt(i64, l[48..56], 123_456_789_012, .little); // st_size
    std.mem.writeInt(i64, l[88..96], 1_700_000_000, .little); // st_mtim.sec
    const s = statFromLinuxGeneric(&l);
    try std.testing.expectEqual(@as(u32, 42), s.ino);
    try std.testing.expectEqual(@as(u16, 0o100644), s.mode);
    try std.testing.expectEqual(@as(i64, 123_456_789_012), s.size);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), s.mtim.sec);
    const b = std.mem.asBytes(&s);
    try std.testing.expectEqual(@as(u16, 0o100644), std.mem.readInt(u16, b[8..10], .little));
    try std.testing.expectEqual(@as(i64, 123_456_789_012), std.mem.readInt(i64, b[72..80], .little));
}

test "a new thread's stack pointer" {
    const p = ThrParam{ .start_func = 0, .arg = 0, .stack_base = 0x10000, .stack_size = 0x8004, .tls_base = 0, .tls_size = 0, .child_tid = 0, .parent_tid = 0, .flags = 0, .rtp = 0 };
    try std.testing.expectEqual(@as(u64, 0x18000 - 8), p.initialSp());
}
