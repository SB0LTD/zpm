//! Live wss:// harness — the full pure-Sig market-data path end to end.
//!
//! DNS (getaddrinfo) → TCP (Winsock) → TLS 1.3 (X25519 + AES-128-GCM + X.509
//! chain validation) → WebSocket upgrade (RFC 6455) → a real trade frame from
//! Binance. This is the exact stack the app uses for exchange streams, so a
//! green run here means the migration target works before we touch sbtrade.
//!
//! Run manually:  sig build live-wss
//! Tolerant of no egress: a connect failure prints SKIP and returns success.
//! A connect that then fails to upgrade or decode is a real FAILURE.

const std = @import("std");
const wss = @import("wss");
const w32 = @import("win32");

const HOST = "stream.binance.com";
const PORT: u16 = 443;
const PATH = "/ws/btcusdt@trade";

fn unixNow() i64 {
    var ft: w32.FILETIME = .{};
    w32.GetSystemTimeAsFileTime(&ft);
    const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
    return @as(i64, @intCast(ticks / 10_000_000)) - 11_644_473_600;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    var recv: [65536]u8 = undefined;
    var scratch: [2048]u8 = undefined;

    log("live-wss: connecting wss://{s}{s}", .{ HOST, PATH });

    // WssClient must be PINNED — the layers hold internal pointers into it.
    var client: wss.WssClient = .{};
    client.connect(.{
        .host = HOST,
        .port = PORT,
        .path = PATH,
        .recv_buf = &recv,
        .scratch = &scratch,
        .now = unixNow(),
    }) catch |err| {
        if (err == error.ConnectFailed) {
            log("live-wss: SKIP — could not connect (no network?)", .{});
            return;
        }
        log("live-wss: FAIL — connect/upgrade error: {s}", .{@errorName(err)});
        return error.LiveWssConnectFailed;
    };
    defer client.close();
    log("live-wss: wss upgrade OK — WebSocket established over pure-Sig TLS", .{});

    // Binance pushes trade frames continuously; read a few and confirm they are
    // well-formed JSON trade events for BTCUSDT.
    var seen: usize = 0;
    while (seen < 3) {
        const msg = client.receiveMessage() catch |err| {
            log("live-wss: FAIL — receive error after {d} msgs: {s}", .{ seen, @errorName(err) });
            return error.LiveWssReceiveFailed;
        };
        seen += 1;
        const data = msg.data;
        const preview = data[0..@min(data.len, 80)];
        log("live-wss: msg {d}: {d} bytes: {s}", .{ seen, data.len, preview });

        // A Binance @trade event contains "\"e\":\"trade\"" and the symbol.
        if (!contains(data, "\"e\":\"trade\"")) {
            log("live-wss: FAIL — payload is not a trade event", .{});
            return error.LiveWssBadPayload;
        }
        if (!contains(data, "BTCUSDT")) {
            log("live-wss: FAIL — trade event missing expected symbol", .{});
            return error.LiveWssBadPayload;
        }
    }

    log("live-wss: PASS — {d} live BTCUSDT trade frames over pure-Sig wss verified", .{seen});
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
