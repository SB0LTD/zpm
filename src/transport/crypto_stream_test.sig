// CRYPTO stream reassembly tests
//
// Comprehensive tests for the standalone crypto_stream module covering:
// - Basic receive/readable/consume operations
// - Out-of-order fragment reassembly
// - Overlapping and duplicate fragment handling
// - Buffer overflow protection
// - Multi-message delivery patterns
// - Real-world Chrome ClientHello fragmentation patterns
// - Range set limits and merge behavior
//
// Run: zig test src/transport/crypto_stream_test.sig  (from zpm/)

const std = @import("std");
const testing = std.testing;
const crypto_stream = @import("crypto_stream");
const CryptoStream = crypto_stream.CryptoStream;

// ── Test 1: init produces empty stream ──

test "init produces empty stream" {
    const cs = CryptoStream.init();
    try testing.expectEqual(@as(u16, 0), cs.readable());
    try testing.expectEqual(@as(u8, 0), cs.range_count);
    try testing.expectEqual(@as(u64, 0), cs.read_offset);
}

// ── Test 2: single fragment at offset 0 ──

test "single fragment at offset 0" {
    var cs = CryptoStream.init();
    var data: [100]u8 = undefined;
    for (0..100) |i| {
        data[i] = @intCast(i & 0xFF);
    }
    const result = cs.receive(0, &data);
    try testing.expectEqual(crypto_stream.ReceiveResult.ok, result);
    try testing.expectEqual(@as(u16, 100), cs.readable());
    try testing.expectEqual(@as(u8, 1), cs.range_count);
    try testing.expectEqual(@as(u16, 0), cs.ranges[0].start);
    try testing.expectEqual(@as(u16, 100), cs.ranges[0].end);
}

// ── Test 3: single fragment at non-zero offset ──

test "single fragment at non-zero offset" {
    var cs = CryptoStream.init();
    var data: [50]u8 = undefined;
    for (0..50) |i| {
        data[i] = @intCast(i & 0xFF);
    }
    const result = cs.receive(50, &data);
    try testing.expectEqual(crypto_stream.ReceiveResult.ok, result);
    // Gap at [0, 50) means nothing is readable from front
    try testing.expectEqual(@as(u16, 0), cs.readable());
    try testing.expectEqual(@as(u8, 1), cs.range_count);
    try testing.expectEqual(@as(u16, 50), cs.ranges[0].start);
    try testing.expectEqual(@as(u16, 100), cs.ranges[0].end);
}

// ── Test 4: two contiguous fragments in order ──

test "two contiguous fragments in order" {
    var cs = CryptoStream.init();
    var data1: [50]u8 = undefined;
    var data2: [50]u8 = undefined;
    for (0..50) |i| {
        data1[i] = @intCast(i & 0xFF);
        data2[i] = @intCast((i + 50) & 0xFF);
    }
    _ = cs.receive(0, &data1);
    _ = cs.receive(50, &data2);
    try testing.expectEqual(@as(u16, 100), cs.readable());
    try testing.expectEqual(@as(u8, 1), cs.range_count);
    try testing.expectEqual(@as(u16, 0), cs.ranges[0].start);
    try testing.expectEqual(@as(u16, 100), cs.ranges[0].end);
}

// ── Test 5: two contiguous fragments reverse order ──

test "two contiguous fragments reverse order" {
    var cs = CryptoStream.init();
    var data1: [50]u8 = undefined;
    var data2: [50]u8 = undefined;
    for (0..50) |i| {
        data1[i] = @intCast((i + 50) & 0xFF);
        data2[i] = @intCast(i & 0xFF);
    }
    _ = cs.receive(50, &data1); // [50, 100) first
    _ = cs.receive(0, &data2);  // [0, 50) second
    try testing.expectEqual(@as(u16, 100), cs.readable());
    try testing.expectEqual(@as(u8, 1), cs.range_count);
}

// ── Test 6: three fragments with gap ──

test "three fragments with gap" {
    var cs = CryptoStream.init();
    var d1: [30]u8 = undefined;
    var d2: [30]u8 = undefined;
    var d3: [30]u8 = undefined;
    for (0..30) |i| {
        d1[i] = @intCast(i & 0xFF);
        d2[i] = @intCast((i + 60) & 0xFF);
        d3[i] = @intCast((i + 30) & 0xFF);
    }

    _ = cs.receive(0, &d1);   // [0, 30)
    _ = cs.receive(60, &d2);  // [60, 90)
    // At this point: ranges = [0,30), [60,90). readable = 30 (gap at 30-60)
    try testing.expectEqual(@as(u16, 30), cs.readable());
    try testing.expectEqual(@as(u8, 2), cs.range_count);

    _ = cs.receive(30, &d3);  // [30, 60) fills the gap
    try testing.expectEqual(@as(u16, 90), cs.readable());
    try testing.expectEqual(@as(u8, 1), cs.range_count);
}

// ── Test 7: duplicate fragment ignored ──

test "duplicate fragment ignored" {
    var cs = CryptoStream.init();
    var data: [100]u8 = undefined;
    for (0..100) |i| {
        data[i] = @intCast(i & 0xFF);
    }
    const r1 = cs.receive(0, &data);
    try testing.expectEqual(crypto_stream.ReceiveResult.ok, r1);
    try testing.expectEqual(@as(u8, 1), cs.range_count);

    // Receive the exact same data again
    const r2 = cs.receive(0, &data);
    try testing.expectEqual(crypto_stream.ReceiveResult.duplicate, r2);
    // Ranges unchanged
    try testing.expectEqual(@as(u8, 1), cs.range_count);
    try testing.expectEqual(@as(u16, 100), cs.readable());
}

// ── Test 8: overlapping fragments merged ──

test "overlapping fragments merged" {
    var cs = CryptoStream.init();
    var data1: [60]u8 = undefined;
    var data2: [60]u8 = undefined;
    for (0..60) |i| {
        data1[i] = @intCast(i & 0xFF);
        data2[i] = @intCast((i + 40) & 0xFF);
    }
    _ = cs.receive(0, &data1);   // [0, 60)
    _ = cs.receive(40, &data2);  // [40, 100) — overlaps [0,60) by 20 bytes
    try testing.expectEqual(@as(u16, 100), cs.readable());
    try testing.expectEqual(@as(u8, 1), cs.range_count);
    try testing.expectEqual(@as(u16, 0), cs.ranges[0].start);
    try testing.expectEqual(@as(u16, 100), cs.ranges[0].end);
}

// ── Test 9: consume advances read pointer ──

test "consume advances read pointer" {
    var cs = CryptoStream.init();
    var data: [100]u8 = undefined;
    for (0..100) |i| {
        data[i] = @intCast(i & 0xFF);
    }
    _ = cs.receive(0, &data);
    try testing.expectEqual(@as(u16, 100), cs.readable());

    cs.consume(50);
    try testing.expectEqual(@as(u64, 50), cs.read_offset);
    try testing.expectEqual(@as(u16, 50), cs.readable());

    // Verify shifted data is correct
    var out: [50]u8 = undefined;
    const read_len = cs.read(&out);
    try testing.expectEqual(@as(u16, 50), read_len);
    // After consume(50), buf[0] should be original data[50]
    for (0..50) |i| {
        try testing.expectEqual(@as(u8, @intCast((i + 50) & 0xFF)), out[i]);
    }
}

// ── Test 10: multi-message delivery ──

test "multi-message delivery" {
    var cs = CryptoStream.init();
    // Receive 200 bytes starting at offset 0
    var data1: [200]u8 = undefined;
    for (0..200) |i| {
        data1[i] = @intCast(i & 0xFF);
    }
    _ = cs.receive(0, &data1);
    try testing.expectEqual(@as(u16, 200), cs.readable());

    // Consume first 100 bytes (first message delivered)
    cs.consume(100);
    try testing.expectEqual(@as(u64, 100), cs.read_offset);
    try testing.expectEqual(@as(u16, 100), cs.readable());

    // Receive 50 more bytes at absolute offset 200 (buffer-relative = 200 - 100 = 100)
    var data2: [50]u8 = undefined;
    for (0..50) |i| {
        data2[i] = @intCast((i + 200) & 0xFF);
    }
    _ = cs.receive(200, &data2);
    // Now we have [0, 150) buffer-relative = contiguous from front
    try testing.expectEqual(@as(u16, 150), cs.readable());
}

// ── Test 11: overflow rejected ──

test "overflow rejected" {
    var cs = CryptoStream.init();
    // Fragment that would exceed buffer: offset 16000 + 500 bytes > 16384
    var data: [500]u8 = undefined;
    @memset(&data, 0xAB);
    const result = cs.receive(16000, &data);
    try testing.expectEqual(crypto_stream.ReceiveResult.overflow, result);
    // Nothing should be recorded
    try testing.expectEqual(@as(u8, 0), cs.range_count);
    try testing.expectEqual(@as(u16, 0), cs.readable());
}

// ── Test 12: Chrome 6-fragment ClientHello pattern ──

test "Chrome 6-fragment ClientHello pattern" {
    var cs = CryptoStream.init();

    // Chrome splits ClientHello into 6 fragments. Simulate receiving in REVERSE order.
    const frags = [_]struct { start: u16, end: u16 }{
        .{ .start = 283, .end = 285 },
        .{ .start = 131, .end = 283 },
        .{ .start = 129, .end = 131 },
        .{ .start = 120, .end = 129 },
        .{ .start = 73, .end = 120 },
        .{ .start = 0, .end = 73 },
    };

    for (frags) |frag| {
        const len = frag.end - frag.start;
        var data: [285]u8 = undefined;
        // Fill with recognizable pattern
        for (0..len) |i| {
            data[i] = @intCast((frag.start + @as(u16, @intCast(i))) & 0xFF);
        }
        const result = cs.receive(frag.start, data[0..len]);
        try testing.expectEqual(crypto_stream.ReceiveResult.ok, result);
    }

    // All fragments received — should be fully contiguous
    try testing.expectEqual(@as(u16, 285), cs.readable());
    try testing.expectEqual(@as(u8, 1), cs.range_count);

    // Verify data integrity
    var out: [285]u8 = undefined;
    const read_len = cs.read(&out);
    try testing.expectEqual(@as(u16, 285), read_len);
    for (0..285) |i| {
        try testing.expectEqual(@as(u8, @intCast(i & 0xFF)), out[i]);
    }
}

// ── Test 13: max range entries ──

test "max range entries" {
    var cs = CryptoStream.init();

    // Fill all 32 range slots with non-contiguous fragments (gaps between them)
    // Each fragment is 10 bytes with a 10-byte gap: [0,10), [20,30), [40,50), ...
    var i: u8 = 0;
    while (i < crypto_stream.max_ranges) : (i += 1) {
        const offset: u16 = @as(u16, i) * 20;
        var data: [10]u8 = undefined;
        @memset(&data, i);
        _ = cs.receive(offset, &data);
    }
    try testing.expectEqual(crypto_stream.max_ranges, cs.range_count);

    // Now fill all the gaps — should merge everything into 1 range
    i = 0;
    while (i < crypto_stream.max_ranges) : (i += 1) {
        const offset: u16 = @as(u16, i) * 20 + 10;
        var data: [10]u8 = undefined;
        @memset(&data, i + 100);
        _ = cs.receive(offset, &data);
    }
    // All 32 ranges should merge into 1 contiguous range
    try testing.expectEqual(@as(u8, 1), cs.range_count);
    const expected_end: u16 = @as(u16, crypto_stream.max_ranges) * 20;
    try testing.expectEqual(expected_end, cs.readable());
}

// ── Test 14: large fragment 4096 bytes ──

test "large fragment 4096 bytes" {
    var cs = CryptoStream.init();
    var data: [4096]u8 = undefined;
    for (0..4096) |i| {
        data[i] = @intCast(i & 0xFF);
    }
    const result = cs.receive(0, &data);
    try testing.expectEqual(crypto_stream.ReceiveResult.ok, result);
    try testing.expectEqual(@as(u16, 4096), cs.readable());
    try testing.expectEqual(@as(u8, 1), cs.range_count);
}

// ── Test 15: read copies correct data ──

test "read copies correct data" {
    var cs = CryptoStream.init();
    var data: [256]u8 = undefined;
    for (0..256) |i| {
        data[i] = @intCast(i & 0xFF);
    }
    _ = cs.receive(0, &data);

    // Read into a smaller buffer
    var out: [128]u8 = undefined;
    const read_len = cs.read(&out);
    try testing.expectEqual(@as(u16, 128), read_len);
    for (0..128) |i| {
        try testing.expectEqual(@as(u8, @intCast(i & 0xFF)), out[i]);
    }

    // Read into a larger buffer — should only get readable() bytes
    var big_out: [512]u8 = undefined;
    const big_read = cs.read(&big_out);
    try testing.expectEqual(@as(u16, 256), big_read);
    for (0..256) |i| {
        try testing.expectEqual(@as(u8, @intCast(i & 0xFF)), big_out[i]);
    }
}
