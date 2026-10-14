//! Layer 0 PDA preimages. Curve validation is injected, never replaced by guessing.
//! On-chain consumers should use the runtime's PDA syscall until pure curve support lands.
const sha = @import("sha256");
pub const MAX_SEEDS = 16;
pub const MAX_SEED_LEN = 32;
pub const PDA_MARKER = "ProgramDerivedAddress";
pub const Error = error{ TooManySeeds, SeedTooLong, NoViableBump };
fn validate(seeds: []const []const u8) Error!void {
    // The bump itself occupies the final seed slot.
    if (seeds.len >= MAX_SEEDS) return error.TooManySeeds;
    for (seeds) |seed| if (seed.len > MAX_SEED_LEN) return error.SeedTooLong;
}
pub fn deriveWithBump(seeds: []const []const u8, bump: u8, program: *const [32]u8) Error![32]u8 {
    try validate(seeds);
    var state = sha.Sha256.init();
    for (seeds) |seed| state.update(seed);
    state.update(&.{bump});
    state.update(program);
    state.update(PDA_MARKER);
    return state.final();
}
pub fn findProgramAddress(seeds: []const []const u8, program: *const [32]u8, on_curve: *const fn (*const [32]u8) bool, output: *[32]u8) Error!u8 {
    try validate(seeds);
    var candidate: u16 = 255;
    while (true) {
        const address = try deriveWithBump(seeds, @intCast(candidate), program);
        if (!on_curve(&address)) {
            output.* = address;
            return @intCast(candidate);
        }
        if (candidate == 0) return error.NoViableBump;
        candidate -= 1;
    }
}
