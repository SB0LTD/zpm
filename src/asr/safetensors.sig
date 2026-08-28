// @zpm/asr — Safetensors Weight Loader
// Parses safetensors binary format and maps BF16 tensor data.
//
// Format:
//   [8 bytes] header_size (u64 LE)
//   [header_size bytes] JSON header (tensor metadata)
//   [remainder] raw tensor data
//
// JSON header maps tensor names to {dtype, shape, data_offsets: [start, end]}
// BF16 tensors are converted to f32 on-the-fly during access.
//
// This module memory-maps the file and provides pointer access to tensors.
// Zero heap allocations for the mapping itself.

// ── BF16 → F32 conversion ──
pub fn bf16ToF32(bf16_val: u16) f32 {
    // BF16 is just the upper 16 bits of F32
    const bits: u32 = @as(u32, bf16_val) << 16;
    return @bitCast(bits);
}

/// Convert a buffer of BF16 values to F32 in-place (into a separate output buffer)
pub fn convertBf16ToF32(src: [*]const u16, dst: [*]f32, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        dst[i] = bf16ToF32(src[i]);
    }
}

// ── Safetensors file layout ──
pub const SafetensorsFile = struct {
    // Memory-mapped file base pointer
    base: [*]const u8,
    file_size: usize,
    // Header
    header_size: u64,
    data_offset: usize, // where tensor data starts (8 + header_size)

    /// Parse header and return the SafetensorsFile handle.
    /// base must point to the mmap'd file content.
    pub fn init(base: [*]const u8, file_size: usize) ?SafetensorsFile {
        if (file_size < 8) return null;
        // Read header size (little-endian u64)
        const hs = @as(u64, base[0]) |
            (@as(u64, base[1]) << 8) |
            (@as(u64, base[2]) << 16) |
            (@as(u64, base[3]) << 24) |
            (@as(u64, base[4]) << 32) |
            (@as(u64, base[5]) << 40) |
            (@as(u64, base[6]) << 48) |
            (@as(u64, base[7]) << 56);

        const data_start = 8 + @as(usize, @intCast(hs));
        if (data_start > file_size) return null;

        return .{
            .base = base,
            .file_size = file_size,
            .header_size = hs,
            .data_offset = data_start,
        };
    }

    /// Get raw pointer to tensor data at a given byte offset within the data section.
    /// Returns BF16 data as u16 pointer.
    pub fn tensorDataBf16(self: *const SafetensorsFile, offset: usize, count: usize) ?[*]const u16 {
        const byte_offset = self.data_offset + offset;
        if (byte_offset + count * 2 > self.file_size) return null;
        return @ptrCast(@alignCast(self.base + byte_offset));
    }

    /// Get the JSON header as a string slice
    pub fn headerJson(self: *const SafetensorsFile) []const u8 {
        return self.base[8 .. 8 + @as(usize, @intCast(self.header_size))];
    }
};

// ── Tensor lookup (simplified) ──
// In a full implementation, we'd parse the JSON header to find tensor offsets.
// For now, we provide the structure and a manual offset table approach
// (the offsets can be pre-computed from the JSON once and hardcoded or
// computed at load time with a minimal JSON scanner).

pub const TensorInfo = struct {
    name: []const u8,
    offset: usize, // byte offset within data section
    size: usize, // number of elements (not bytes)
    shape: [4]usize, // up to 4 dimensions
    n_dims: u8,
};

/// Find a tensor by name in a list of TensorInfo entries.
pub fn findTensor(infos: []const TensorInfo, name: []const u8) ?*const TensorInfo {
    for (infos) |*info| {
        if (eqlStr(info.name, name)) return info;
    }
    return null;
}

fn eqlStr(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
