//! @zpm/lsp — reusable, allocator-free Language Server Protocol building blocks.
//!
//! A coarse re-export of the LSP modules so consumers can import one package and
//! reach framing, JSON emission, the document store, position math, the Sig
//! declaration scanner, the request dispatcher, and the shared transport loop.
//! Every submodule is pure (no allocator, no runtime std I/O), so the same code
//! runs on hosted OSes and on bare-metal / SB0-native targets.

pub const message = @import("message");
pub const jwrite = @import("jwrite");
pub const document = @import("document");
pub const position = @import("position");
pub const symbols = @import("symbols");
pub const server = @import("server");
pub const loop = @import("loop");

test {
    _ = message;
    _ = jwrite;
    _ = document;
    _ = position;
    _ = symbols;
    _ = server;
    _ = loop;
}
