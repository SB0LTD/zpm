// @zpm/youtube/nsig — execute the original player's throttle transform in Sig.
const cipher = @import("cipher.sig");
const player_transform = @import("player_transform.sig");

pub const MAX_NSIG_LEN: usize = 256;

/// Returns zero for unsupported source, VM failure, a player failure sentinel,
/// or output overflow. The input is never silently truncated.
/// Player preparation replaces the shared BotGuard VM, so callers must copy
/// their minted token before applying URL transforms.
pub fn transform(n_param: []const u8, out: *[MAX_NSIG_LEN]u8) usize {
    if (n_param.len == 0 or n_param.len > MAX_NSIG_LEN) return 0;
    const source = cipher.getPlayerJs();
    if (source.len == 0 or !player_transform.prepare(source, cipher.playerGeneration())) return 0;
    return player_transform.transformN(n_param, out);
}
