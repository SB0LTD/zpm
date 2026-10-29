//! Solana aligned loader ABI. Bounded parser with caller-owned account descriptors.
//! Never exposes realloc padding. Views borrow input; duplicates alias original fields.
//! No account mutation occurs while parsing. Reallocation is deliberately unsupported.
const le = @import("solana_le");
pub const MAX_ACCOUNTS = 64;
pub const MAX_PERMITTED_DATA_INCREASE = 10240;
pub const Pubkey = [32]u8;
pub const Error = error{ Truncated, MalformedInput, NonCanonical, TooManyAccounts };
pub const AccountInfo = struct {
    key: *align(1) const Pubkey,
    owner: *align(1) const Pubkey,
    lamports: *align(1) u64,
    data: []u8,
    /// Canonical loader length word; used to refresh CPI-grown data views.
    data_length: ?*align(1) const u64 = null,
    is_signer: bool,
    is_writable: bool,
    is_executable: bool,
    is_duplicate: bool = false,
    dup_index: u8 = 255,
};
pub const Input = struct {
    accounts: []AccountInfo,
    instruction_data: []const u8,
    program_id: *align(1) const Pubkey,
    consumed: usize,
};
const Cursor = struct {
    buffer: []u8,
    position: usize = 0,
    fn take(self: *Cursor, count: usize) Error![]u8 {
        if (count > self.buffer.len - self.position) return error.Truncated;
        const start = self.position;
        self.position += count;
        return self.buffer[start..self.position];
    }
    fn length(self: *Cursor) Error!usize {
        const value = le.getLe(u64, try self.take(8));
        if (value > self.buffer.len - self.position) return error.Truncated;
        return @intCast(value);
    }
};
/// Accounts are written to storage only after each record validates. On error its
/// contents are unspecified; input bytes are unchanged. `consumed` excludes trailing
/// bytes, so a caller requiring an exact envelope can compare it to buffer.len.
pub fn parseInto(buffer: []u8, storage: []AccountInfo) Error!Input {
    var cursor: Cursor = .{ .buffer = buffer };
    const count = le.getLe(u64, try cursor.take(8));
    if (count > MAX_ACCOUNTS or count > storage.len) return error.TooManyAccounts;
    const account_count: usize = @intCast(count);
    for (0..account_count) |i| {
        const start = cursor.position;
        const marker = (try cursor.take(1))[0];
        if (marker != 255) {
            _ = try cursor.take(7);
            if (marker >= i) return error.MalformedInput;
            storage[i] = storage[marker];
            storage[i].is_duplicate = true;
            storage[i].dup_index = marker;
            continue;
        }
        _ = try cursor.take(87);
        const header = buffer[start..][0..88];
        if (header[1] > 1 or header[2] > 1 or header[3] > 1) return error.NonCanonical;
        const data_length = le.getLe(u64, header[80..88]);
        if (data_length > buffer.len - cursor.position) return error.Truncated;
        const data = try cursor.take(@intCast(data_length));
        _ = try cursor.take(MAX_PERMITTED_DATA_INCREASE);
        _ = try cursor.take((8 - cursor.position % 8) % 8);
        _ = try cursor.take(8); // rent_epoch is retained in the wire ABI, ignored here.
        storage[i] = .{ .key = @ptrCast(header[8..40].ptr), .owner = @ptrCast(header[40..72].ptr), .lamports = @ptrCast(header[72..80].ptr), .data = data, .data_length = @ptrCast(header[80..88].ptr), .is_signer = header[1] == 1, .is_writable = header[2] == 1, .is_executable = header[3] == 1 };
    }
    const instruction_length = try cursor.length();
    const instruction = try cursor.take(instruction_length);
    const program = try cursor.take(32);
    return .{ .accounts = storage[0..account_count], .instruction_data = instruction, .program_id = @ptrCast(program.ptr), .consumed = cursor.position };
}
