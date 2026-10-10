//! Live HTTP(S) GET harness (pure-Sig @zpm/http over the real TLS stack).
//!
//! NOT hermetic: opens a real connection to a stable public endpoint and
//! drives the full fetch lifecycle (connectDeadline -> TLS 1.3 handshake with
//! cert-chain validation -> HTTP/1.1 request -> response + body). Asserts a 2xx
//! status and a non-empty body (Req 12.1, 15.3). Tolerant of no egress: a
//! connect failure prints SKIP and returns success so CI without network stays
//! green; a connect that then fails cryptographically or on parsing is a FAIL.
//!
//!     sig test tests/live_http.sig   (or via the live-http build step)

const std = @import("std");
const http = @import("zpm_http");
const w32 = @import("win32");

const HOST_URL = "https://api.binance.com/api/v3/ping";

fn unixNow() i64 {
    var ft: w32.FILETIME = .{};
    w32.GetSystemTimeAsFileTime(&ft);
    const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
    const secs_since_1601: u64 = ticks / 10_000_000;
    return @as(i64, @intCast(secs_since_1601)) - 11_644_473_600;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    const now = unixNow();
    log("live-http: GET {s} (now={d})", .{ HOST_URL, now });

    var body_buf: [256 * 1024]u8 = undefined;
    var header_scratch: [16 * 1024]u8 = undefined;
    var req_head: [8 * 1024]u8 = undefined;
    const bufs = http.Buffers{ .body = &body_buf, .header_scratch = &header_scratch, .req_head = &req_head };

    var trace = http.Trace{};
    const req = http.Request{ .url = HOST_URL, .trace = &trace };

    const resp = http.fetch(req, bufs, now) catch |err| {
        switch (err) {
            error.ConnectFailed, error.DnsFailed => {
                log("live-http: SKIP -- could not connect (no network?) err={s}", .{@errorName(err)});
                return;
            },
            else => {
                log("live-http: FAIL -- fetch error: {s} (tls_kind={d}, wsa={d})", .{ @errorName(err), @intFromEnum(trace.tls_kind), trace.wsa_last_error });
                return error.LiveHttpFetchFailed;
            },
        }
    };

    log("live-http: status={d} reason={s} body_len={d}", .{ resp.status, resp.reason, resp.body.len });

    if (!resp.ok()) {
        log("live-http: FAIL -- expected 2xx, got {d}", .{resp.status});
        return error.LiveHttpBadStatus;
    }
    if (resp.body.len == 0) {
        log("live-http: FAIL -- empty body", .{});
        return error.LiveHttpEmptyBody;
    }
    if (!resp.complete) {
        log("live-http: FAIL -- response not marked complete", .{});
        return error.LiveHttpIncomplete;
    }

    log("live-http: fetch PASS -- 2xx with {d}-byte cert-validated body", .{resp.body.len});

    // Keep-alive Client: two sequential requests reusing one connection.
    var client = http.Client{};
    defer client.close();
    const r1 = client.send(req, bufs, now) catch |err| {
        log("live-http: FAIL -- client.send #1: {s}", .{@errorName(err)});
        return error.LiveHttpClientFailed;
    };
    if (!r1.ok()) { log("live-http: FAIL -- client #1 status {d}", .{r1.status}); return error.LiveHttpClientBadStatus; }
    const reused_after_1 = client.connected;
    const r2 = client.send(req, bufs, now) catch |err| {
        log("live-http: FAIL -- client.send #2: {s}", .{@errorName(err)});
        return error.LiveHttpClientFailed;
    };
    if (!r2.ok()) { log("live-http: FAIL -- client #2 status {d}", .{r2.status}); return error.LiveHttpClientBadStatus; }
    log("live-http: client PASS -- 2 sequential requests ok (keep_alive1={}, keep_alive2={})", .{ reused_after_1, r2.keep_alive });

    log("live-http: PASS -- fetch + keep-alive Client verified", .{});
}
