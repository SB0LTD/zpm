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
//! - draw: those values in the engine's terms (its window counts rows
//!   from the bottom, its blend factors are linear forms).
//! - target: the pictures a game draws into, kept as the engine's images
//!   by the address a game names them by, and read back for the display.
//! - render: the renderer itself. A draw from the driver's queue is read,
//!   converted and handed to the engine; what it cannot carry out is left
//!   out and said. `render.install` puts it in place.
//!
//! Not yet: the shaders' machine code recompiled (`render.shade` is
//! where that plugs in), so no game's draw is drawn.
//!
//! Allocation-free.

pub const state = @import("state.sig");
pub const draw = @import("draw.sig");
pub const target = @import("target.sig");
pub const render = @import("render.sig");

test {
    _ = state;
    _ = draw;
    _ = target;
    _ = render;
}
