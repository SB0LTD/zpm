// Core error, trace, and enum types for the pure-Sig HTTP client.
//
// Every public entry point (fetch, Client.send) surfaces failures as this
// single flat `Error` set. `TlsFailKind` disambiguates the TlsFailed case
// (certificate rejection vs. protocol vs. transport) without a second error
// set, and `Trace` is an optional, allocation-free timing/diagnostic record
// the caller may opt into by passing a pointer.

const std = @import("std");

pub const Error = error{
    InvalidUrl,
    InvalidHeader,
    DnsFailed,
    ConnectFailed,
    TlsFailed, // see TlsFailKind for cert vs transport
    Timeout,
    SendFailed,
    RecvFailed,
    PrematureClose, // socket/TLS closed before a full response
    BadResponse, // malformed status line / headers / chunk framing
    BodyTooLarge, // response exceeds caller buffer
    BufferTooSmall, // scratch/header buffer too small
    TooManyRedirects,
    RetryExhausted,
};

/// Disambiguates a TlsFailed error. `.none` when the failure was not TLS.
pub const TlsFailKind = enum(u8) { none, cert_invalid, protocol, transport };

/// Optional structured trace. Off unless the caller passes a *Trace to the
/// request; purely a diagnostic record, filled in as the request progresses.
/// Allocation-free value type.
pub const Trace = struct {
    dns_ms: u32 = 0,
    connect_ms: u32 = 0,
    tls_ms: u32 = 0,
    first_byte_ms: u32 = 0,
    total_ms: u32 = 0,
    attempts: u8 = 0,
    redirects: u8 = 0,
    wsa_last_error: i32 = 0,
    tls_kind: TlsFailKind = .none,
};

/// HTTP request methods supported by the client.
pub const Method = enum { GET, POST, PUT, DELETE, HEAD, PATCH, OPTIONS };

/// URL scheme. The client speaks plaintext http and TLS https.
pub const Scheme = enum { http, https };

// Tests (inline, std.testing)
const testing = std.testing;

test "Method enum has all seven verbs" {
    try testing.expectEqual(@as(usize, 7), @typeInfo(Method).@"enum".field_names.len);
}

test "Scheme has http and https" {
    try testing.expectEqual(@as(usize, 2), @typeInfo(Scheme).@"enum".field_names.len);
}

test "TlsFailKind defaults to none and is one byte" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(TlsFailKind));
    const t: Trace = .{};
    try testing.expectEqual(TlsFailKind.none, t.tls_kind);
}

test "Trace zero-initializes all counters" {
    const t: Trace = .{};
    try testing.expectEqual(@as(u32, 0), t.total_ms);
    try testing.expectEqual(@as(u8, 0), t.attempts);
    try testing.expectEqual(@as(u8, 0), t.redirects);
    try testing.expectEqual(@as(i32, 0), t.wsa_last_error);
}

test "Error set is usable as a value" {
    const e: Error = error.Timeout;
    try testing.expect(e == Error.Timeout);
}
