// @zpm/youtube/botguard — BotGuard PO Token Engine
//
// Pure Sig implementation of Google's BotGuard attestation system.
// Generates Proof-of-Origin tokens for YouTube stream access.
//
// Flow:
//   1. challenge.fetchChallenge() → VM script + program
//   2. jsvm.execute(script, program) → BG response token + minter
//   3. integrity.getToken(bg_response) → integrity token
//   4. minter.mint(integrity_token, video_id) → PO token
//
// After initial setup, minting is <100ms per video (cached minter).

pub const challenge = @import("challenge.sig");
pub const integrity = @import("integrity.sig");
pub const minter = @import("minter.sig");
pub const cache = @import("cache.sig");
pub const jsvm = @import("jsvm/root.sig");

// ── High-level API ──

/// Full state for a BotGuard session.
pub const Session = struct {
    initialized: bool,
    visitor_data: [128]u8,
    visitor_data_len: usize,
    integrity_token: [512]u8,
    integrity_token_len: usize,
    session_pot: [256]u8,
    session_pot_len: usize,
    minter_ready: bool,
    valid_until: i64, // unix timestamp

    pub fn init() Session {
        return .{
            .initialized = false,
            .visitor_data = undefined,
            .visitor_data_len = 0,
            .integrity_token = undefined,
            .integrity_token_len = 0,
            .session_pot = undefined,
            .session_pot_len = 0,
            .minter_ready = false,
            .valid_until = 0,
        };
    }
};

var session: Session = Session.init();

/// Initialize the BotGuard session. Must be called once before minting.
/// This is the expensive operation (~2-3 seconds first time, ~100ms cached).
pub fn initialize() bool {
    if (session.initialized and session.minter_ready) return true;

    // Try loading from cache first
    if (cache.loadSession(&session)) {
        session.initialized = true;
        return true;
    }

    // Full initialization: fetch challenge → run VM → get integrity token
    var bg_response: [1024]u8 = undefined;
    var bg_response_len: usize = 0;

    // Step 1: Fetch challenge
    var chal = challenge.Challenge.init();
    if (!challenge.fetch(&chal)) return false;

    // Step 2: Execute BotGuard VM
    if (!jsvm.execute(
        chal.script[0..chal.script_len],
        chal.program[0..chal.program_len],
        chal.global_name[0..chal.global_name_len],
        &bg_response,
        &bg_response_len,
    )) return false;

    // Step 3: Get integrity token
    if (!integrity.getToken(
        bg_response[0..bg_response_len],
        &session.integrity_token,
        &session.integrity_token_len,
    )) return false;

    session.minter_ready = true;
    session.initialized = true;

    // Cache the session
    cache.saveSession(&session);

    return true;
}

/// Mint a content-bound PO token for a specific video.
/// Returns the base64-encoded PO token length, or 0 on failure.
pub fn mintVideoToken(video_id: []const u8, out: *[256]u8) usize {
    if (!session.minter_ready) {
        if (!initialize()) return 0;
    }
    return minter.mintContentBound(
        session.integrity_token[0..session.integrity_token_len],
        video_id,
        out,
    );
}

/// Mint a session-bound PO token (for stream URLs).
/// Uses the visitor data as content binding.
pub fn mintSessionToken(out: *[256]u8) usize {
    if (!session.minter_ready) {
        if (!initialize()) return 0;
    }
    if (session.session_pot_len > 0) {
        // Return cached session token
        @memcpy(out[0..session.session_pot_len], session.session_pot[0..session.session_pot_len]);
        return session.session_pot_len;
    }
    const len = minter.mintSessionBound(
        session.integrity_token[0..session.integrity_token_len],
        session.visitor_data[0..session.visitor_data_len],
        out,
    );
    if (len > 0) {
        @memcpy(session.session_pot[0..len], out[0..len]);
        session.session_pot_len = len;
        cache.saveSession(&session);
    }
    return len;
}

/// Check if the session is ready (can mint tokens without re-initializing).
pub fn isReady() bool {
    return session.initialized and session.minter_ready;
}
