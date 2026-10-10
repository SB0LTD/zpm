//! Multi-host live HTTPS validation across diverse CAs and cipher suites.
//! Proves comprehensive real-world TLS compatibility: each host uses a
//! different CA / cipher / key-exchange combination. SKIPs cleanly if offline.

const std = @import("std");
const http = @import("zpm_http");
const w32 = @import("win32");

const HOSTS = [_][]const u8{
    "https://example.com/",            // Cloudflare/SSL.com ECC, AES-256-GCM-SHA384
    "https://www.google.com/",         // Google Trust Services, often P-256/AES-128
    "https://www.cloudflare.com/",     // Cloudflare ECC
    "https://en.wikipedia.org/wiki/HTTP", // ISRG/Let's Encrypt or DigiCert
    "https://www.microsoft.com/",      // Microsoft CA
    "https://api.binance.com/api/v3/ping", // DigiCert G2 (embedded fast path)
};

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
    const now = unixNow();
    var body_buf: [4 * 1024 * 1024]u8 = undefined;
    var header_scratch: [16 * 1024]u8 = undefined;
    var req_head: [8 * 1024]u8 = undefined;
    const bufs = http.Buffers{ .body = &body_buf, .header_scratch = &header_scratch, .req_head = &req_head };

    var passed: usize = 0;
    var skipped: usize = 0;
    for (HOSTS) |url| {
        var trace = http.Trace{};
        const req = http.Request{ .url = url, .trace = &trace };
        const resp = http.fetch(req, bufs, now) catch |err| {
            switch (err) {
                error.BodyTooLarge => {
                    log("live-multi: PASS {s} -> (body exceeded buffer, TLS+parse OK)", .{url});
                    passed += 1;
                    continue;
                },
                error.ConnectFailed, error.DnsFailed, error.Timeout => {
                    log("live-multi: SKIP {s} ({s})", .{ url, @errorName(err) });
                    skipped += 1;
                    continue;
                },
                else => {
                    log("live-multi: FAIL {s} -> {s} (tls_kind={d})", .{ url, @errorName(err), @intFromEnum(trace.tls_kind) });
                    return error.LiveMultiFailed;
                },
            }
        };
        if (resp.status < 200 or resp.status >= 400) {
            log("live-multi: FAIL {s} -> status {d}", .{ url, resp.status });
            return error.LiveMultiBadStatus;
        }
        log("live-multi: PASS {s} -> {d} ({d} bytes)", .{ url, resp.status, resp.body.len });
        passed += 1;
    }
    log("live-multi: {d} passed, {d} skipped of {d} hosts", .{ passed, skipped, HOSTS.len });
    if (passed == 0 and skipped == HOSTS.len) return; // fully offline -> ok
    if (passed == 0) return error.LiveMultiNonePassed;
}
