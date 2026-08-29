// SB0 native image format (SB0X userspace + SB0K kernel) — canonical encoder.
//
// Layer 1: Platform (binary container format)
//
// This is the SINGLE SOURCE OF TRUTH for the SB0 native image byte layout.
// It is pure computation over caller-provided byte buffers: no allocator, no
// platform I/O, no compiler internals. Both the zero-alloc compiler
// (compiler/backend/linker.sig) and the production compiler's self-hosted SB0
// linker backend (sig/src/link/Sb0.sig) target this exact layout, and the
// production compiler keeps a bootstrap-safe mirror validated byte-for-byte
// against the constants and encoders defined here.
//
// Container shapes (all integers little-endian):
//
//   SB0X — bounded userspace image
//     64-byte fixed header, then N fixed 40-byte segment descriptors, then the
//     segment payloads. Derived from the classic SB0S SB0X loader shape.
//
//   SB0K — privileged kernel image
//     64-byte fixed header immediately followed by already-relocated reset code.
//
// See sig/compiler/SB0_ABI_TARGET.md for the ABI contract these images satisfy.

// ── SB0X (userspace) constants ──

pub const SB0X_MAGIC = [4]u8{ 'S', 'B', '0', 'X' };
pub const SB0X_FORMAT_VERSION: u8 = 1;
pub const SB0X_ABI_VERSION: u16 = 1;
pub const SB0X_HEADER_SIZE: usize = 64;
pub const SB0X_SEGMENT_SIZE: usize = 40;
pub const SB0X_MAX_SEGMENTS: usize = 8;

/// Default runtime stack size baked into the image when the caller does not
/// override it.
pub const SB0X_DEFAULT_STACK_SIZE: u64 = 64 * 1024;

/// Page granularity used for mem-size rounding in the bounded loader.
pub const SB0X_PAGE_SIZE: u64 = 4096;

/// Segment permission flags (bitfield, matches the classic loader contract).
pub const SEG_READ: u32 = 0b001;
pub const SEG_WRITE: u32 = 0b010;
pub const SEG_EXEC: u32 = 0b100;
pub const SEG_RX: u32 = SEG_READ | SEG_EXEC;
pub const SEG_RW: u32 = SEG_READ | SEG_WRITE;
pub const SEG_RO: u32 = SEG_READ;

// ── SB0K (kernel) constants ──

pub const SB0K_MAGIC = [4]u8{ 'S', 'B', '0', 'K' };
pub const SB0K_FORMAT_VERSION: u16 = 1;
pub const SB0K_HEADER_SIZE: usize = 64;
pub const SB0K_BOOT_ABI_VERSION: u16 = 1;
pub const SB0K_FLAG_FIXED_LAYOUT: u32 = 1;

// ── Little-endian byte writers ──

pub fn writeU16LE(buf: []u8, val: u16) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
}

pub fn writeU32LE(buf: []u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

pub fn writeU64LE(buf: []u8, val: u64) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
    buf[4] = @truncate(val >> 32);
    buf[5] = @truncate(val >> 40);
    buf[6] = @truncate(val >> 48);
    buf[7] = @truncate(val >> 56);
}

pub fn readU16LE(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

pub fn readU32LE(buf: []const u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

pub fn readU64LE(buf: []const u8) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) v |= @as(u64, buf[i]) << @intCast(i * 8);
    return v;
}

/// Round `value` up to the next multiple of `alignment` (power-of-two).
pub fn alignForward(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

// ── SB0X header / segment descriptors ──

/// Logical view of the 64-byte SB0X header. Field order and offsets match the
/// on-disk layout produced by `encodeHeader`.
pub const Sb0xHeader = struct {
    format_version: u8 = SB0X_FORMAT_VERSION,
    flags: u8 = 0,
    abi_version: u16 = SB0X_ABI_VERSION,
    /// Entry offset within segment 0's virtual address space.
    entry_offset: u64 = 0,
    segment_count: u16 = 0,
    tls_template_offset: u32 = 0,
    tls_template_size: u32 = 0,
    tls_bss_size: u32 = 0,
    /// Total virtual image size (page-rounded).
    image_size: u64 = 0,
    stack_size: u64 = SB0X_DEFAULT_STACK_SIZE,
};

/// Logical view of a 40-byte SB0X segment descriptor.
pub const Sb0xSegment = struct {
    file_offset: u64 = 0,
    vaddr_offset: u64 = 0,
    file_size: u64 = 0,
    mem_size: u64 = 0,
    flags: u32 = SEG_RX,
};

/// Encode the 64-byte SB0X header into `out` (must be >= 64 bytes).
/// Layout:
///   0x00 magic "SB0X"
///   0x04 format_version (u8)
///   0x05 flags (u8)
///   0x06 abi_version (u16)
///   0x08 entry_offset (u64)
///   0x10 segment_count (u16)
///   0x12 reserved (u16)
///   0x14 tls_template_offset (u32)
///   0x18 tls_template_size (u32)
///   0x1c tls_bss_size (u32)
///   0x20 image_size (u64)
///   0x28 stack_size (u64)
///   0x30..0x40 reserved (16 bytes)
pub fn encodeHeader(out: []u8, hdr: Sb0xHeader) usize {
    if (out.len < SB0X_HEADER_SIZE) return 0;
    var i: usize = 0;
    while (i < SB0X_HEADER_SIZE) : (i += 1) out[i] = 0;

    out[0] = SB0X_MAGIC[0];
    out[1] = SB0X_MAGIC[1];
    out[2] = SB0X_MAGIC[2];
    out[3] = SB0X_MAGIC[3];
    out[4] = hdr.format_version;
    out[5] = hdr.flags;
    writeU16LE(out[6..], hdr.abi_version);
    writeU64LE(out[8..], hdr.entry_offset);
    writeU16LE(out[16..], hdr.segment_count);
    writeU16LE(out[18..], 0); // reserved
    writeU32LE(out[20..], hdr.tls_template_offset);
    writeU32LE(out[24..], hdr.tls_template_size);
    writeU32LE(out[28..], hdr.tls_bss_size);
    writeU64LE(out[32..], hdr.image_size);
    writeU64LE(out[40..], hdr.stack_size);
    // 0x30..0x40 already zeroed.
    return SB0X_HEADER_SIZE;
}

/// Encode a 40-byte SB0X segment descriptor into `out` (must be >= 40 bytes).
/// Layout:
///   0x00 file_offset (u64)
///   0x08 vaddr_offset (u64)
///   0x10 file_size (u64)
///   0x18 mem_size (u64)
///   0x20 flags (u32)
///   0x24 reserved (u32)
pub fn encodeSegment(out: []u8, seg: Sb0xSegment) usize {
    if (out.len < SB0X_SEGMENT_SIZE) return 0;
    writeU64LE(out[0..], seg.file_offset);
    writeU64LE(out[8..], seg.vaddr_offset);
    writeU64LE(out[16..], seg.file_size);
    writeU64LE(out[24..], seg.mem_size);
    writeU32LE(out[32..], seg.flags);
    writeU32LE(out[36..], 0); // reserved
    return SB0X_SEGMENT_SIZE;
}

/// Compute the file offset where segment payloads begin, given a segment count.
pub fn payloadOffset(segment_count: usize) usize {
    return SB0X_HEADER_SIZE + segment_count * SB0X_SEGMENT_SIZE;
}

/// Emit a single-RX-segment SB0X executable image containing `code` into `out`.
/// This is the common bounded case: one read+execute text segment whose entry
/// point is `entry_offset` within the segment. Returns bytes written, or 0 if
/// `out` is too small or `code` is empty.
pub fn encodeFlatExecutable(out: []u8, code: []const u8, entry_offset: u64) usize {
    if (code.len == 0) return 0;
    const meta = payloadOffset(1);
    const total = meta + code.len;
    if (out.len < total) return 0;

    _ = encodeHeader(out, .{
        .entry_offset = entry_offset,
        .segment_count = 1,
        .image_size = alignForward(@intCast(total), SB0X_PAGE_SIZE),
    });
    _ = encodeSegment(out[SB0X_HEADER_SIZE..], .{
        .file_offset = @intCast(meta),
        .vaddr_offset = 0,
        .file_size = @intCast(code.len),
        .mem_size = alignForward(@intCast(code.len), SB0X_PAGE_SIZE),
        .flags = SEG_RX,
    });
    var i: usize = 0;
    while (i < code.len) : (i += 1) out[meta + i] = code[i];
    return total;
}

// ── SB0K kernel header ──

/// Logical view of the 64-byte SB0K kernel header.
pub const Sb0kHeader = struct {
    format_version: u16 = SB0K_FORMAT_VERSION,
    boot_abi_version: u16 = SB0K_BOOT_ABI_VERSION,
    abi_revision: u16 = 0,
    flags: u32 = SB0K_FLAG_FIXED_LAYOUT,
    entry_offset: u64 = 0,
    total_image_bytes: u64 = 0,
    relocation_offset: u64 = 0,
    relocation_count: u32 = 0,
    relocation_entry_bytes: u32 = 0,
    build_identity: u64 = 0,
    preferred_physical_base: u64 = 0,
};

/// Encode the 64-byte SB0K header into `out` (must be >= 64 bytes).
/// Layout per SB0_ABI_TARGET.md:
///   0x00 magic "SB0K"
///   0x04 format version (u16)
///   0x06 header bytes (u16)
///   0x08 boot ABI version (u16)
///   0x0a ABI revision (u16)
///   0x0c flags (u32)
///   0x10 entry offset (u64)
///   0x18 total image bytes (u64)
///   0x20 relocation offset (u64)
///   0x28 relocation count (u32)
///   0x2c relocation entry bytes (u32)
///   0x30 build identity (u64)
///   0x38 preferred physical base (u64)
pub fn encodeKernelHeader(out: []u8, hdr: Sb0kHeader) usize {
    if (out.len < SB0K_HEADER_SIZE) return 0;
    var i: usize = 0;
    while (i < SB0K_HEADER_SIZE) : (i += 1) out[i] = 0;

    out[0] = SB0K_MAGIC[0];
    out[1] = SB0K_MAGIC[1];
    out[2] = SB0K_MAGIC[2];
    out[3] = SB0K_MAGIC[3];
    writeU16LE(out[4..], hdr.format_version);
    writeU16LE(out[6..], @intCast(SB0K_HEADER_SIZE));
    writeU16LE(out[8..], hdr.boot_abi_version);
    writeU16LE(out[10..], hdr.abi_revision);
    writeU32LE(out[12..], hdr.flags);
    writeU64LE(out[16..], hdr.entry_offset);
    writeU64LE(out[24..], hdr.total_image_bytes);
    writeU64LE(out[32..], hdr.relocation_offset);
    writeU32LE(out[40..], hdr.relocation_count);
    writeU32LE(out[44..], hdr.relocation_entry_bytes);
    writeU64LE(out[48..], hdr.build_identity);
    writeU64LE(out[56..], hdr.preferred_physical_base);
    return SB0K_HEADER_SIZE;
}

/// Emit a complete SB0K kernel image: 64-byte header + already-relocated reset
/// code. Returns bytes written, or 0 if `out` is too small or `code` is empty.
pub fn encodeKernelImage(
    out: []u8,
    reset_code: []const u8,
    build_identity: u64,
    preferred_physical_base: u64,
) usize {
    if (reset_code.len == 0) return 0;
    const total = SB0K_HEADER_SIZE + reset_code.len;
    if (out.len < total) return 0;

    _ = encodeKernelHeader(out, .{
        .entry_offset = 0,
        .total_image_bytes = @intCast(total),
        .build_identity = build_identity,
        .preferred_physical_base = preferred_physical_base,
    });
    var i: usize = 0;
    while (i < reset_code.len) : (i += 1) out[SB0K_HEADER_SIZE + i] = reset_code[i];
    return total;
}

// ── Validation helpers (loader-side) ──

/// Returns true if `buf` starts with a well-formed SB0X header.
pub fn isSb0x(buf: []const u8) bool {
    if (buf.len < SB0X_HEADER_SIZE) return false;
    return buf[0] == 'S' and buf[1] == 'B' and buf[2] == '0' and buf[3] == 'X' and
        buf[4] == SB0X_FORMAT_VERSION;
}

/// Returns true if `buf` starts with a well-formed SB0K header.
pub fn isSb0k(buf: []const u8) bool {
    if (buf.len < SB0K_HEADER_SIZE) return false;
    return buf[0] == 'S' and buf[1] == 'B' and buf[2] == '0' and buf[3] == 'K' and
        readU16LE(buf[4..]) == SB0K_FORMAT_VERSION;
}

/// A foreign container magic must never be mistaken for an SB0 image.
pub fn isForeignContainer(buf: []const u8) bool {
    if (buf.len < 4) return false;
    // ELF
    if (buf[0] == 0x7f and buf[1] == 'E' and buf[2] == 'L' and buf[3] == 'F') return true;
    // PE/COFF (MZ)
    if (buf[0] == 'M' and buf[1] == 'Z') return true;
    // Mach-O (0xFEEDFACF little-endian)
    if (buf[0] == 0xcf and buf[1] == 0xfa and buf[2] == 0xed and buf[3] == 0xfe) return true;
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "SB0X flat executable has correct magic, header and segment" {
    const code = [_]u8{ 0xC0, 0x03, 0x5F, 0xD6 }; // aarch64 ret
    var buf: [256]u8 = undefined;
    const n = encodeFlatExecutable(&buf, &code, 0);
    try testing.expect(n == payloadOffset(1) + code.len);
    try testing.expect(isSb0x(&buf));
    try testing.expect(!isForeignContainer(&buf));

    // segment_count == 1
    try testing.expect(readU16LE(buf[16..]) == 1);
    // segment 0 descriptor: file_offset == meta, flags == RX
    const seg = buf[SB0X_HEADER_SIZE..];
    try testing.expect(readU64LE(seg[0..]) == payloadOffset(1));
    try testing.expect(readU32LE(seg[32..]) == SEG_RX);
    // code copied at payload offset
    try testing.expect(buf[payloadOffset(1)] == 0xC0);
}

test "SB0X encodeFlatExecutable rejects empty and too-small buffers" {
    var buf: [8]u8 = undefined;
    const code = [_]u8{ 0xC0, 0x03, 0x5F, 0xD6 };
    try testing.expect(encodeFlatExecutable(&buf, &code, 0) == 0); // too small
    var big: [256]u8 = undefined;
    try testing.expect(encodeFlatExecutable(&big, &.{}, 0) == 0); // empty code
}

test "SB0K kernel image has correct magic and header fields" {
    const reset = [_]u8{ 0x5f, 0x20, 0x03, 0xd5, 0xff, 0xff, 0xff, 0x17 };
    var buf: [128]u8 = undefined;
    const n = encodeKernelImage(&buf, &reset, 0x0102_0304_0506_0708, 0x8000_0000);
    try testing.expect(n == SB0K_HEADER_SIZE + reset.len);
    try testing.expect(isSb0k(&buf));
    try testing.expect(readU16LE(buf[6..]) == SB0K_HEADER_SIZE); // header bytes
    try testing.expect(readU32LE(buf[12..]) == SB0K_FLAG_FIXED_LAYOUT);
    try testing.expect(readU64LE(buf[24..]) == n); // total image bytes
    try testing.expect(readU64LE(buf[48..]) == 0x0102_0304_0506_0708);
    try testing.expect(readU64LE(buf[56..]) == 0x8000_0000);
    // reset code copied after header
    try testing.expect(buf[SB0K_HEADER_SIZE] == 0x5f);
}

test "SB0 images never collide with foreign container magics" {
    const code = [_]u8{ 0xC0, 0x03, 0x5F, 0xD6 };
    var buf: [256]u8 = undefined;
    _ = encodeFlatExecutable(&buf, &code, 0);
    try testing.expect(!isForeignContainer(&buf));

    var kbuf: [128]u8 = undefined;
    _ = encodeKernelImage(&kbuf, &code, 0, 0);
    try testing.expect(!isForeignContainer(&kbuf));
}

test "alignForward rounds to page boundaries" {
    try testing.expect(alignForward(1, SB0X_PAGE_SIZE) == SB0X_PAGE_SIZE);
    try testing.expect(alignForward(SB0X_PAGE_SIZE, SB0X_PAGE_SIZE) == SB0X_PAGE_SIZE);
    try testing.expect(alignForward(SB0X_PAGE_SIZE + 1, SB0X_PAGE_SIZE) == 2 * SB0X_PAGE_SIZE);
}
