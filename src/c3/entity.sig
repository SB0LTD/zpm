//! Fixed-capacity account/profile/coupon wire shapes for C³ login entities.
//! Schemas only: service mutations must authenticate the wallet owner and
//! encrypt profile data before persistence.
pub const ENTITY_SCHEMA_VERSION: u16 = 1;
pub const MAX_WALLETS_PER_ENTITY: usize = 8;
pub const MAX_COUPONS_PER_ENTITY: usize = 32;
pub const MAX_PROFILE_BYTES: usize = 4096;

pub const Wallet = struct {
    address: [32]u8,
    linked_at: u64,
    revoked_at: u64 = 0,
};

pub const LoginEntity = struct {
    id: [32]u8,
    owner: [32]u8,
    created_at: u64,
    revision: u64 = 0,
    wallets: [MAX_WALLETS_PER_ENTITY]Wallet = @splat(.{ .address = @splat(0), .linked_at = 0 }),
    wallet_count: usize = 0,
    profile_ciphertext: [MAX_PROFILE_BYTES]u8 = @splat(0),
    profile_ciphertext_len: usize = 0,
    profile_digest: [32]u8 = @splat(0),
};

pub const Coupon = struct {
    id: [32]u8,
    issuer: [32]u8,
    offer_digest: [32]u8,
    issued_at: u64,
    expires_at: u64,
    redeemed_at: u64 = 0,
    redemption_receipt: [32]u8 = @splat(0),
};

pub const CouponBook = struct {
    entries: [MAX_COUPONS_PER_ENTITY]Coupon = @splat(.{
        .id = @splat(0), .issuer = @splat(0), .offer_digest = @splat(0),
        .issued_at = 0, .expires_at = 0,
    }),
    count: usize = 0,
};

test "new login entity starts owner-bound with empty private state" {
    const testing = @import("sig_testing");
    const entity = LoginEntity{
        .id = @splat(1),
        .owner = @splat(2),
        .created_at = 10,
    };
    try testing.expectEqual(@as(usize, 0), entity.wallet_count);
    try testing.expectEqual(@as(usize, 0), entity.profile_ciphertext_len);
    try testing.expectEqual(@as(u64, 0), entity.revision);
}
