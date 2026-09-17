//! Live TLS 1.3 handshake harness (pure-Sig stack, real network).
//!
//! This is NOT a hermetic unit test — it opens a real TCP connection to a
//! public exchange endpoint and drives a full TLS 1.3 handshake through the
//! pure-Sig stack (X25519 + AES-128-GCM + X.509 chain validation against the
//! embedded CA bundle). It then sends a WebSocket upgrade request over the
//! established Conn and confirms the server replies `HTTP/1.1 101`, which
//! proves application-data encryption works in both directions.
//!
//! Because it needs the network, it is run manually / opportunistically:
//!     sig test tests/live_tls_handshake.sig   (or via the live build step)
//! It is intentionally tolerant of a dead network: a connect failure prints a
//! SKIP and returns success, so CI without egress never goes red. A handshake
//! that connects but then fails cryptographically is a real FAILURE.

const std = @import("std");
const tlsc = @import("tls_client");
const w32 = @import("win32");

const HOST = "stream.binance.com";
const PORT: u16 = 9443;
const WS_PATH = "/ws/btcusdt@trade";

/// Windows FILETIME (100-ns ticks since 1601-01-01) → Unix seconds.
fn unixNow() i64 {
    var ft: w32.FILETIME = .{};
    w32.GetSystemTimeAsFileTime(&ft);
    const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
    // 11644473600 seconds between 1601-01-01 and 1970-01-01; 1 tick = 100ns.
    const secs_since_1601: u64 = ticks / 10_000_000;
    return @as(i64, @intCast(secs_since_1601)) - 11_644_473_600;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    // 1. Seed real entropy so the X25519 client key + ClientHello.random are
    //    unpredictable (forward secrecy). Without this the stack uses fixed
    //    dev bytes, which a real server will still accept but is not secure.
    tlsc.fillEntropy();

    const now = unixNow();
    log("live-tls: connecting to {s}:{d} (now={d})", .{ HOST, PORT, now });

    // 2. Open the TCP socket. A connect failure is treated as SKIP (no egress).
    var sock = tlsc.connectHost(HOST, PORT) catch {
        log("live-tls: SKIP — could not open TCP connection (no network?)", .{});
        return;
    };
    defer sock.close();
    log("live-tls: TCP connected, starting TLS 1.3 handshake", .{});

    // 3. Full TLS 1.3 handshake: ClientHello → ServerHello → EE → Certificate
    //    → CertificateVerify → Finished, with chain validation to the CA bundle.
    var conn = tlsc.handshake(sock.transport(), HOST, now) catch |err| {
        log("live-tls: FAIL — handshake error: {s}", .{@errorName(err)});
        return error.LiveTlsHandshakeFailed;
    };
    defer conn.close();
    log("live-tls: handshake OK — TLS 1.3 session established", .{});

    // 4. Exercise app-data write: send a WebSocket upgrade request.
    var req: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&req,
        "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n", .{ WS_PATH, HOST }) catch return error.LiveTlsBufferTooSmall;
    conn.write(request) catch |err| {
        log("live-tls: FAIL — encrypted write error: {s}", .{@errorName(err)});
        return error.LiveTlsWriteFailed;
    };
    log("live-tls: sent {d}-byte WebSocket upgrade over TLS", .{request.len});

    // 5. Exercise app-data read + decrypt: read the HTTP response.
    var resp: [1024]u8 = undefined;
    const n = conn.read(&resp) catch |err| {
        log("live-tls: FAIL — encrypted read error: {s}", .{@errorName(err)});
        return error.LiveTlsReadFailed;
    };
    if (n == 0) {
        log("live-tls: FAIL — server closed with no data", .{});
        return error.LiveTlsNoResponse;
    }
    const head = resp[0..@min(n, 32)];
    log("live-tls: received {d} decrypted bytes, first line: {s}", .{ n, firstLine(resp[0..n]) });

    // 6. A successful WebSocket upgrade is HTTP 101. Anything else (e.g. a 4xx)
    //    still proves the crypto works, but we assert 101 for the real path.
    if (!startsWith(resp[0..n], "HTTP/1.1 101")) {
        log("live-tls: WARN — expected HTTP/1.1 101, got: {s}", .{head});
        // The crypto round-trip succeeded (we decrypted a real response), which
        // is what this harness validates. Treat a non-101 status as a soft
        // failure so it is visible without masking a genuine crypto success.
        return error.LiveTlsUnexpectedStatus;
    }

    log("live-tls: PASS — TLS 1.3 + WebSocket upgrade round-trip verified", .{});
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

fn firstLine(buf: []const u8) []const u8 {
    for (buf, 0..) |c, i| {
        if (c == '\r' or c == '\n') return buf[0..i];
    }
    return buf;
}
