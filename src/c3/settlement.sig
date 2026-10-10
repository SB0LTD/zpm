//! Fixed-capacity, idempotent prototype ledger. Production escrow is on-chain.
const testing = @import("sig_testing");

pub const MAX_CERTIFICATES: usize = 128;
pub const MAX_INTERFACES: usize = 16;
pub const Error = error{InvalidInput, AlreadySettled, LedgerFull, ValueExceeded};

pub const Certificate = struct {
    id: [32]u8,
    lower_bounds: [MAX_INTERFACES]u64,
    interface_count: usize,
};
pub const Receipt = struct { paid: [MAX_INTERFACES]u64 = @splat(0), count: usize = 0, total: u64 = 0 };

pub const Ledger = struct {
    escrow_remaining: u64,
    project_value_ceiling: u64,
    value_settled: u64 = 0,
    certificate_ids: [MAX_CERTIFICATES][32]u8 = @splat(@splat(0)),
    certificate_count: usize = 0,

    pub fn settle(self: *Ledger, certificate: Certificate) Error!Receipt {
        if (certificate.interface_count == 0 or certificate.interface_count > MAX_INTERFACES) return error.InvalidInput;
        for (self.certificate_ids[0..self.certificate_count]) |id|
            if (equalId(id, certificate.id)) return error.AlreadySettled;
        if (self.certificate_count == MAX_CERTIFICATES) return error.LedgerFull;
        var receipt = Receipt{ .count = certificate.interface_count };
        for (certificate.lower_bounds[0..certificate.interface_count], 0..) |bound, i| {
            const remaining_value = self.project_value_ceiling -| self.value_settled;
            const payment = @min(bound, @min(self.escrow_remaining, remaining_value));
            receipt.paid[i] = payment;
            receipt.total += payment;
            self.escrow_remaining -= payment;
            self.value_settled += payment;
        }
        self.certificate_ids[self.certificate_count] = certificate.id;
        self.certificate_count += 1;
        return receipt;
    }
};

fn equalId(a: [32]u8, b: [32]u8) bool {
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

test "settlement caps payment by escrow and project value" {
    var ledger = Ledger{ .escrow_remaining = 100, .project_value_ceiling = 70 };
    const c = Certificate{ .id = @splat(1), .lower_bounds = .{ 50, 40 } ++ @as([14]u64, @splat(0)), .interface_count = 2 };
    const receipt = try ledger.settle(c);
    try testing.expectEqual(@as(u64, 70), receipt.total);
    try testing.expectEqual(@as(u64, 30), ledger.escrow_remaining);
}

test "settlement certificates are idempotent" {
    var ledger = Ledger{ .escrow_remaining = 100, .project_value_ceiling = 100 };
    const c = Certificate{ .id = @splat(7), .lower_bounds = .{ 20 } ++ @as([15]u64, @splat(0)), .interface_count = 1 };
    _ = try ledger.settle(c);
    try testing.expectError(error.AlreadySettled, ledger.settle(c));
    try testing.expectEqual(@as(u64, 20), ledger.value_settled);
}
