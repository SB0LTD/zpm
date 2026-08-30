//! Shared LSP transport loop — Layer 0/1 (generic over the byte pipe).
//!
//! The read/frame/dispatch/respond cycle, factored out so every platform runs
//! the *same* server over whatever byte pipe it has. Generic over an I/O
//! backend; never allocates — the caller owns all buffers.
//!
//! An I/O backend is any value with:
//!   - `read(self, buf: []u8) IoErr!usize` — fill up to buf.len bytes; 0 = EOF
//!   - `writeAll(self, bytes: []const u8) IoErr!void`
//!
//! Hosted builds pass a Win32/POSIX stdio backend; a bare-metal or SB0-native
//! build passes a UART or channel-syscall backend. Same protocol code either way.

const message = @import("message");
const server_mod = @import("server");

pub const INBOUND_CAP = 512 * 1024;
pub const OUTBOUND_CAP = 512 * 1024;
pub const CHUNK_CAP = 64 * 1024;

/// The buffers a `run` call needs. Large — place in static storage, not stack.
pub const Buffers = struct {
    inbound: [INBOUND_CAP]u8 = undefined,
    outbound: [OUTBOUND_CAP]u8 = undefined,
    chunk: [CHUNK_CAP]u8 = undefined,
};

/// Run the LSP session to completion (until `exit` or EOF). Generic over the
/// I/O backend `io` (a pointer to any value exposing `read`/`writeAll`).
pub fn run(io: anytype, srv: *server_mod.Server, bufs: *Buffers) void {
    var filled: usize = 0;
    while (true) {
        while (true) {
            const frame = message.readFrame(bufs.inbound[0..filled]) catch |err| switch (err) {
                error.Incomplete => break,
                error.MissingContentLength, error.Malformed => {
                    filled = 0;
                    break;
                },
            };
            const msg = message.parse(frame.body);
            const result = srv.handle(msg, &bufs.outbound);
            switch (result.outcome) {
                .respond => sendFramed(io, result.body),
                .none => {},
                .exit => return,
            }
            const remaining = filled - frame.consumed;
            if (remaining > 0) {
                copyForwards(bufs.inbound[0..remaining], bufs.inbound[frame.consumed..filled]);
            }
            filled = remaining;
        }
        const n = io.read(&bufs.chunk) catch return;
        if (n == 0) return;
        if (filled + n > INBOUND_CAP) {
            filled = 0;
            continue;
        }
        @memcpy(bufs.inbound[filled .. filled + n], bufs.chunk[0..n]);
        filled += n;
    }
}

/// Frame a response body with its Content-Length header and write both.
pub fn sendFramed(io: anytype, body: []const u8) void {
    if (body.len == 0) return;
    var header_buf: [64]u8 = undefined;
    const header = message.writeHeader(&header_buf, body.len) catch return;
    io.writeAll(header) catch return;
    io.writeAll(body) catch return;
}

/// Overlap-safe forward copy (no std dependency for freestanding builds).
fn copyForwards(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    while (i < src.len) : (i += 1) dst[i] = src[i];
}
