//! Native System Program allocation for empty PDAs, including prefunded addresses.
const cpi = @import("solana_cpi");
const le = @import("solana_le");
const input = @import("solana_entrypoint_input");
const errors = @import("solana_program_error");
pub const SYSTEM_ID: [32]u8 = @splat(0);
pub const Request = struct {
    payer: *const input.AccountInfo,
    target: *const input.AccountInfo,
    system: *const input.AccountInfo,
    owner: *const [32]u8,
    size: usize,
    minimum: u64,
    signer: cpi.SignerSeeds,
};
fn same(a: *align(1) const [32]u8, b: *align(1) const [32]u8) bool {
    for (a.*, b.*) |x, y| if (x != y) return false;
    return true;
}
fn isSystem(key: *align(1) const [32]u8) bool {
    for (key.*) |byte| if (byte != 0) return false;
    return true;
}
pub fn API(comptime Invoke: type) type {
    return struct {
        noinline fn call(request: *const Request, data: []const u8, single: bool) u64 {
            var metas: [2]cpi.Meta = .{
                .{ .key = request.payer.key, .writable = true, .signer = true },
                .{ .key = request.target.key, .writable = true, .signer = true },
            };
            var infos: [3]cpi.Account = .{ cpi.account(request.payer), cpi.account(request.target), cpi.account(request.system) };
            var system_id: [32]u8 = @splat(0);
            const instruction: cpi.Instruction = .{
                .program = &system_id,
                .accounts = if (single) metas[1..].ptr else &metas,
                .accounts_len = if (single) 1 else 2,
                .data = data.ptr,
                .data_len = data.len,
            };
            // Refresh the target length from the loader's canonical length word.
            // Account data immediately follows that LE u64 in the aligned VM ABI.
            infos[1].data_len = request.target.data_length.?.*;
            return Invoke.invoke(&instruction, &infos, &.{request.signer}) catch return errors.builtin(.invalid_argument);
        }
        pub noinline fn create(request: *const Request) u64 {
            if (request.size > input.MAX_PERMITTED_DATA_INCREASE or request.target.data_length == null) return errors.builtin(.invalid_argument);
            if (!request.payer.is_signer) return errors.builtin(.missing_required_signature);
            if (!request.payer.is_writable or !request.target.is_writable) return errors.builtin(.invalid_argument);
            if (request.target.is_executable or request.target.is_duplicate or !isSystem(request.target.owner) or request.target.data.len != 0 or request.target.data_length.?.* != 0) return errors.builtin(.account_already_initialized);
            if (!request.system.is_executable or !isSystem(request.system.key) or same(request.payer.key, request.target.key)) return errors.builtin(.incorrect_program_id);
            const deficit = request.minimum -| request.target.lamports.*;
            if (request.payer.lamports.* < deficit) return errors.builtin(.insufficient_funds);
            var data: [52]u8 = @splat(0);
            if (request.target.lamports.* == 0) {
                le.putLe(u64, data[4..12], request.minimum);
                le.putLe(u64, data[12..20], @intCast(request.size));
                @memcpy(data[20..52], request.owner);
                return call(request, &data, false);
            }
            if (request.target.lamports.* < request.minimum) {
                le.putLe(u32, data[0..4], 2); // Transfer.
                le.putLe(u64, data[4..12], request.minimum - request.target.lamports.*);
                const status = call(request, data[0..12], false);
                if (status != 0) return status;
            }
            le.putLe(u32, data[0..4], 8); // Allocate.
            le.putLe(u64, data[4..12], @intCast(request.size));
            const status = call(request, data[0..12], true);
            if (status != 0) return status;
            le.putLe(u32, data[0..4], 1); // Assign.
            @memcpy(data[4..36], request.owner);
            return call(request, data[0..36], true);
        }
    };
}
pub const Runtime = API(cpi.Runtime);
