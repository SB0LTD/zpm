// Retry policy: classification, backoff, and Retry-After honoring.
//
// Pure decision logic -- no I/O. The fetch/Client.send loop calls:
//   shouldRetryError / shouldRetryStatus -> is this outcome retriable?
//   backoffMs                            -> how long to wait before attempt N
//   retryAfterMs                         -> honor a Retry-After header (caps backoff)
// bounded by the request total deadline (checked by the caller against the clock).

const std = @import("std");
const errors = @import("errors.sig");

pub const Error = errors.Error;
pub const Method = errors.Method;

pub const RetryPolicy = struct {
    /// Max retry attempts after the first try (0 disables retries).
    max: u8 = 3,
    /// Base backoff in ms; grows exponentially base * 2^(attempt-1).
    base_ms: u32 = 250,
    /// Cap on a single backoff delay.
    max_backoff_ms: u32 = 10_000,
    /// Opt-in: also retry HTTP 408/429/5xx (off by default).
    retry_http_errors: bool = false,
};

/// Idempotent methods are safe to retry without caller opt-in.
pub fn idempotent(m: Method) bool {
    return switch (m) {
        .GET, .HEAD, .PUT, .DELETE, .OPTIONS => true,
        .POST, .PATCH => false,
    };
}

/// Is a transport-level error retriable? ConnectFailed/TlsFailed/Timeout and
/// a premature close before any status byte are transient; others are not.
pub fn shouldRetryError(e: Error) bool {
    return switch (e) {
        Error.ConnectFailed, Error.TlsFailed, Error.Timeout, Error.PrematureClose, Error.DnsFailed, Error.RecvFailed, Error.SendFailed => true,
        else => false,
    };
}

/// Is an HTTP status retriable, given the policy opt-in? 408/429 and 5xx only.
pub fn shouldRetryStatus(policy: RetryPolicy, status: u16) bool {
    if (!policy.retry_http_errors) return false;
    if (status == 408 or status == 429) return true;
    return status >= 500 and status < 600;
}

/// Whether this method may be retried under the policy. Non-idempotent methods
/// require explicit opt-in to avoid duplicate side effects (Req 6.3).
pub fn methodRetriable(m: Method, retry_non_idempotent: bool) bool {
    return idempotent(m) or retry_non_idempotent;
}

/// Exponential backoff for a given attempt (1-based), capped at max_backoff_ms.
/// attempt 1 -> base, 2 -> base*2, 3 -> base*4, ...
pub fn backoffMs(policy: RetryPolicy, attempt: u8) u32 {
    if (attempt == 0) return 0;
    var delay: u64 = policy.base_ms;
    var i: u8 = 1;
    while (i < attempt) : (i += 1) {
        delay *= 2;
        if (delay >= policy.max_backoff_ms) return policy.max_backoff_ms;
    }
    if (delay > policy.max_backoff_ms) return policy.max_backoff_ms;
    return @intCast(delay);
}

/// Parse a Retry-After header value (delta-seconds form only; HTTP-date is
/// treated as not-understood -> null, caller falls back to backoff). Returns ms.
pub fn retryAfterMs(value: []const u8) ?u32 {
    var v = value;
    // trim leading/trailing spaces
    var a: usize = 0;
    var b: usize = v.len;
    while (a < b and (v[a] == ' ' or v[a] == '\t')) : (a += 1) {}
    while (b > a and (v[b - 1] == ' ' or v[b - 1] == '\t')) : (b -= 1) {}
    v = v[a..b];
    if (v.len == 0) return null;
    var secs: u64 = 0;
    for (v) |ch| {
        if (ch < '0' or ch > '9') return null; // HTTP-date or junk
        secs = secs * 10 + @as(u64, ch - '0');
        if (secs > 86_400) secs = 86_400; // clamp to a day
    }
    return @intCast(secs * 1000);
}

/// Decide the delay before the next attempt: honor Retry-After for 429/503 if
/// present and parseable, else exponential backoff. Result is capped by
/// `remaining_ms` (the time left in the total deadline); returns null if no
/// time remains to retry.
pub fn nextDelayMs(policy: RetryPolicy, attempt: u8, status: u16, retry_after: ?[]const u8, remaining_ms: u32) ?u32 {
    if (remaining_ms == 0) return null;
    var delay = backoffMs(policy, attempt);
    if ((status == 429 or status == 503)) {
        if (retry_after) |ra| {
            if (retryAfterMs(ra)) |ms| delay = ms;
        }
    }
    if (delay > remaining_ms) return null; // would blow the deadline
    return delay;
}

// Tests (inline, std.testing) -- retry policy
const testing = std.testing;

test "retry: transient errors are retriable" {
    try testing.expect(shouldRetryError(Error.ConnectFailed));
    try testing.expect(shouldRetryError(Error.TlsFailed));
    try testing.expect(shouldRetryError(Error.Timeout));
    try testing.expect(shouldRetryError(Error.PrematureClose));
    try testing.expect(!shouldRetryError(Error.BadResponse));
    try testing.expect(!shouldRetryError(Error.InvalidUrl));
}

test "retry: HTTP status only when opted in" {
    const off = RetryPolicy{};
    try testing.expect(!shouldRetryStatus(off, 503));
    const on = RetryPolicy{ .retry_http_errors = true };
    try testing.expect(shouldRetryStatus(on, 408));
    try testing.expect(shouldRetryStatus(on, 429));
    try testing.expect(shouldRetryStatus(on, 500));
    try testing.expect(shouldRetryStatus(on, 503));
    try testing.expect(!shouldRetryStatus(on, 404));
    try testing.expect(!shouldRetryStatus(on, 200));
}

test "retry: POST not retried by default, opt-in enables" {
    try testing.expect(!methodRetriable(.POST, false));
    try testing.expect(!methodRetriable(.PATCH, false));
    try testing.expect(methodRetriable(.POST, true));
    try testing.expect(methodRetriable(.GET, false));
    try testing.expect(methodRetriable(.HEAD, false));
    try testing.expect(methodRetriable(.PUT, false));
}

test "retry: exponential backoff with cap" {
    const p = RetryPolicy{ .base_ms = 100, .max_backoff_ms = 1000 };
    try testing.expectEqual(@as(u32, 0), backoffMs(p, 0));
    try testing.expectEqual(@as(u32, 100), backoffMs(p, 1));
    try testing.expectEqual(@as(u32, 200), backoffMs(p, 2));
    try testing.expectEqual(@as(u32, 400), backoffMs(p, 3));
    try testing.expectEqual(@as(u32, 800), backoffMs(p, 4));
    try testing.expectEqual(@as(u32, 1000), backoffMs(p, 5)); // capped
    try testing.expectEqual(@as(u32, 1000), backoffMs(p, 9)); // still capped
}

test "retry: Retry-After delta-seconds parsed" {
    try testing.expectEqual(@as(u32, 5000), retryAfterMs("5").?);
    try testing.expectEqual(@as(u32, 120000), retryAfterMs("  120  ").?);
    try testing.expect(retryAfterMs("Wed, 21 Oct 2015 07:28:00 GMT") == null);
    try testing.expect(retryAfterMs("") == null);
}

test "retry: Retry-After overrides backoff for 503" {
    const p = RetryPolicy{ .base_ms = 100 };
    const d = nextDelayMs(p, 1, 503, "2", 60_000).?;
    try testing.expectEqual(@as(u32, 2000), d); // honored, not 100
}

test "retry: backoff used when no Retry-After" {
    const p = RetryPolicy{ .base_ms = 100 };
    const d = nextDelayMs(p, 2, 500, null, 60_000).?;
    try testing.expectEqual(@as(u32, 200), d);
}

test "retry: total deadline stops retry" {
    const p = RetryPolicy{ .base_ms = 1000 };
    // Only 500ms left but backoff wants 1000 -> no retry.
    try testing.expect(nextDelayMs(p, 1, 500, null, 500) == null);
    // No time left at all.
    try testing.expect(nextDelayMs(p, 1, 500, null, 0) == null);
}
