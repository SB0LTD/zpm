//! @zpm/ps5gfx — a PS5 game's draws, drawn.
//!
//! `ps5` loads a game and answers its libraries; its graphics driver
//! (ps5.agcdriver) reads the game's command buffers, keeps the GPU's
//! registers, and hands each draw to a renderer. This module is to be
//! that renderer, on zpm's own 3D engine (gfxapi): the same engine on a
//! PC's GPU, a phone's, or the CPU.
//!
//! So far:
//! - state: a draw's registers read as targets, viewport, scissor,
//!   depth, blending, and where the shaders and their words are.
//!
//! Not yet: the shaders' machine code recompiled, and anything drawn.
//!
//! Allocation-free.

pub const state = @import("state.sig");

test {
    _ = state;
}
