// Layer 1 — Stream management and flow control.
//
// Manages bidirectional and unidirectional QUIC streams with per-stream
// and connection-level flow control per RFC 9000 §2-4.
// Uses fixed-size ring buffers for reassembly. Pure state machine — no I/O.
// Zero allocator usage.
//
// Memory layout: The StreamManager struct is kept small (~200 bytes) by
// storing the stream array externally. The caller provides a pointer to
// a StreamArray (which is ~8MB due to 64 × 2 × 64KB ring buffers).
// This avoids blowing the compiler's stack during type analysis.

const packet = @import("packet");
const Frame = packet.Frame;

/// Maximum concurrent streams tracked.
pub const max_concurrent_streams: u16 = 64;

/// Per-stream ring buffer size (64KB).
pub const stream_buf_size: u32 = 65536;

const max_u64 = @as(u64, 0xFFFFFFFFFFFFFFFF);

/// Stream lifecycle states per RFC 9000 §3.
pub const StreamState = enum(u8) {
    idle,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
    reset,
};

/// Fixed-size circular buffer for stream data.
///
/// Uses a single-byte gap to distinguish full from empty:
///   available = (write_pos - read_pos) mod buf_size
///   freeSpace = buf_size - 1 - available
pub const RingBuffer = struct {
    buf: [stream_buf_size]u8,
    read_pos: u32,
    write_pos: u32,
    contiguous_end: u32,

    pub fn initInPlace(self: *RingBuffer) void {
        self.read_pos = 0;
        self.write_pos = 0;
        self.contiguous_end = 0;
    }

    /// Bytes available for reading.
    pub fn available(self: *const RingBuffer) u32 {
        if (self.write_pos >= self.read_pos) {
            return self.write_pos - self.read_pos;
        }
        return stream_buf_size - self.read_pos + self.write_pos;
    }

    /// Bytes available for writing (leave 1 byte gap).
    pub fn freeSpace(self: *const RingBuffer) u32 {
        return stream_buf_size - 1 - self.available();
    }

    /// Write data into the ring buffer. Returns bytes actually written.
    pub fn write(self: *RingBuffer, data: []const u8) u32 {
        const free = self.freeSpace();
        const to_write: u32 = @intCast(@min(data.len, free));
        if (to_write == 0) return 0;

        const first_chunk = @min(to_write, stream_buf_size - self.write_pos);
        @memcpy(self.buf[self.write_pos..][0..first_chunk], data[0..first_chunk]);

        if (to_write > first_chunk) {
            const second_chunk = to_write - first_chunk;
            @memcpy(self.buf[0..second_chunk], data[first_chunk..][0..second_chunk]);
        }

        self.write_pos = (self.write_pos + to_write) % stream_buf_size;
        self.contiguous_end = self.write_pos;
        return to_write;
    }

    /// Read data from the ring buffer into out. Returns bytes actually read.
    pub fn read(self: *RingBuffer, out: []u8) u32 {
        const avail = self.available();
        const to_read: u32 = @intCast(@min(out.len, avail));
        if (to_read == 0) return 0;

        const first_chunk = @min(to_read, stream_buf_size - self.read_pos);
        @memcpy(out[0..first_chunk], self.buf[self.read_pos..][0..first_chunk]);

        if (to_read > first_chunk) {
            const second_chunk = to_read - first_chunk;
            @memcpy(out[first_chunk..][0..second_chunk], self.buf[0..second_chunk]);
        }

        self.read_pos = (self.read_pos + to_read) % stream_buf_size;
        return to_read;
    }
};

/// A single QUIC stream with send/receive buffers and flow control.
pub const Stream = struct {
    id: u64,
    state: StreamState,

    // Receive side
    recv_buf: RingBuffer,
    recv_offset: u64,
    recv_fin_offset: u64,
    recv_window: u64,

    // Send side
    send_buf: RingBuffer,
    send_offset: u64,
    send_acked: u64,
    send_fin: bool,
    send_window: u64,

    // Flow control
    max_data_local: u64,
    max_data_remote: u64,

    pub fn initInPlace(self: *Stream, id: u64) void {
        self.id = id;
        self.state = .idle;
        self.recv_buf.initInPlace();
        self.recv_offset = 0;
        self.recv_fin_offset = max_u64;
        self.recv_window = stream_buf_size;
        self.send_buf.initInPlace();
        self.send_offset = 0;
        self.send_acked = 0;
        self.send_fin = false;
        self.send_window = stream_buf_size;
        self.max_data_local = stream_buf_size;
        self.max_data_remote = stream_buf_size;
    }
};

/// The stream storage array type. ~8MB — must be allocated externally
/// (module-level static, or embedded in a larger connection struct).
pub const StreamArray = [max_concurrent_streams]Stream;

/// Manages all streams for a QUIC connection, including connection-level flow control.
/// The stream storage is external (pointed to by `streams`) to keep this struct small.
pub const StreamManager = struct {
    streams: *StreamArray,
    stream_count: u16,

    // Connection-level flow control
    conn_recv_offset: u64,
    conn_recv_window: u64,
    conn_send_offset: u64,
    conn_send_max: u64,

    // Stream limits
    max_bidi_streams: u64,
    max_uni_streams: u64,
    open_bidi_count: u16,
    open_uni_count: u16,

    // Role: false = client, true = server
    is_server: bool,

    // Next stream ID sequence counters
    next_bidi_seq: u64,
    next_uni_seq: u64,

    /// Initialize the manager. Caller must provide a pointer to a StreamArray.
    pub fn init(self: *StreamManager, storage: *StreamArray, is_server: bool) void {
        self.streams = storage;
        self.stream_count = 0;
        self.conn_recv_offset = 0;
        self.conn_recv_window = 1048576; // 1MB default
        self.conn_send_offset = 0;
        self.conn_send_max = 1048576;
        self.max_bidi_streams = max_concurrent_streams;
        self.max_uni_streams = max_concurrent_streams;
        self.open_bidi_count = 0;
        self.open_uni_count = 0;
        self.is_server = is_server;
        self.next_bidi_seq = 0;
        self.next_uni_seq = 0;
        for (0..max_concurrent_streams) |i| {
            self.streams[i].initInPlace(0);
        }
    }

    // ── Stream lifecycle (11.2) ──

    /// Allocate a new stream. Returns stream ID or null if limit reached.
    /// Stream IDs per RFC 9000 §2.1:
    ///   Client bidi: 0,4,8,...  Server bidi: 1,5,9,...
    ///   Client uni:  2,6,10,... Server uni:  3,7,11,...
    pub fn openStream(self: *StreamManager, bidi: bool) ?u64 {
        if (self.stream_count >= max_concurrent_streams) return null;

        if (bidi) {
            if (self.open_bidi_count >= self.max_bidi_streams) return null;
        } else {
            if (self.open_uni_count >= self.max_uni_streams) return null;
        }

        const initiator_bit: u64 = if (self.is_server) 1 else 0;
        const dir_bit: u64 = if (bidi) 0 else 2;
        const seq = if (bidi) self.next_bidi_seq else self.next_uni_seq;
        const stream_id = seq * 4 + dir_bit + initiator_bit;

        if (bidi) {
            self.next_bidi_seq += 1;
            self.open_bidi_count += 1;
        } else {
            self.next_uni_seq += 1;
            self.open_uni_count += 1;
        }

        const idx: usize = @intCast(self.stream_count);
        self.streams[idx].initInPlace(stream_id);
        self.streams[idx].state = .open;
        self.stream_count += 1;

        return stream_id;
    }

    /// Look up a stream by ID. Linear scan (64 entries is small enough).
    pub fn getStream(self: *StreamManager, stream_id: u64) ?*Stream {
        for (0..self.stream_count) |i| {
            if (self.streams[i].id == stream_id) {
                return &self.streams[i];
            }
        }
        return null;
    }

    /// Close the local send side of a stream (half-close).
    pub fn closeStream(self: *StreamManager, stream_id: u64) void {
        if (self.getStream(stream_id)) |s| {
            switch (s.state) {
                .open => {
                    s.state = .half_closed_local;
                    s.send_fin = true;
                },
                .half_closed_remote => {
                    s.state = .closed;
                    s.send_fin = true;
                },
                else => {},
            }
        }
    }

    /// Implicitly create a stream for an incoming frame if it doesn't exist.
    fn getOrCreateStream(self: *StreamManager, stream_id: u64) ?*Stream {
        if (self.getStream(stream_id)) |s| return s;
        if (self.stream_count >= max_concurrent_streams) return null;

        const is_bidi = (stream_id & 0x02) == 0;
        if (is_bidi) {
            if (self.open_bidi_count >= self.max_bidi_streams) return null;
            self.open_bidi_count += 1;
        } else {
            if (self.open_uni_count >= self.max_uni_streams) return null;
            self.open_uni_count += 1;
        }

        const idx: usize = @intCast(self.stream_count);
        self.streams[idx].initInPlace(stream_id);
        self.streams[idx].state = .open;
        self.stream_count += 1;
        return &self.streams[idx];
    }

    // ── Stream data write (11.3) ──

    /// Write data into a stream's send buffer, respecting flow control.
    pub fn writeToStream(self: *StreamManager, stream_id: u64, data: []const u8) u32 {
        const s = self.getStream(stream_id) orelse return 0;

        switch (s.state) {
            .open, .half_closed_remote => {},
            else => return 0,
        }

        // Stream-level flow control
        const stream_allowed = if (s.max_data_remote > s.send_offset)
            s.max_data_remote - s.send_offset
        else
            0;

        // Connection-level flow control
        const conn_allowed = if (self.conn_send_max > self.conn_send_offset)
            self.conn_send_max - self.conn_send_offset
        else
            0;

        const flow_limit: u32 = @intCast(@min(@min(stream_allowed, conn_allowed), data.len));
        if (flow_limit == 0) return 0;

        const written = s.send_buf.write(data[0..flow_limit]);
        s.send_offset += written;
        self.conn_send_offset += written;
        return written;
    }

    // ── Stream data receive (11.4) ──

    /// Handle an incoming STREAM frame (metadata path).
    pub fn onStreamFrame(self: *StreamManager, frame: Frame) void {
        const sf = switch (frame) {
            .stream => |v| v,
            else => return,
        };

        const s = self.getOrCreateStream(sf.stream_id) orelse return;

        switch (s.state) {
            .open, .half_closed_local => {},
            .idle => s.state = .open,
            else => return,
        }

        if (sf.offset == s.recv_offset and sf.data_len > 0) {
            s.recv_offset += sf.data_len;
            self.conn_recv_offset += sf.data_len;
        }

        if (sf.fin) {
            s.recv_fin_offset = sf.offset + sf.data_len;
            if (s.recv_offset >= s.recv_fin_offset) {
                switch (s.state) {
                    .open => s.state = .half_closed_remote,
                    .half_closed_local => s.state = .closed,
                    else => {},
                }
            }
        }
    }

    /// Feed actual stream data bytes.
    pub fn onStreamData(self: *StreamManager, stream_id: u64, offset: u64, data: []const u8, fin: bool) void {
        const s = self.getOrCreateStream(stream_id) orelse return;

        switch (s.state) {
            .open, .half_closed_local => {},
            .idle => s.state = .open,
            else => return,
        }

        if (offset == s.recv_offset and data.len > 0) {
            const written = s.recv_buf.write(data);
            s.recv_offset += written;
            self.conn_recv_offset += written;
        }

        if (fin) {
            s.recv_fin_offset = offset + data.len;
            if (s.recv_offset >= s.recv_fin_offset) {
                switch (s.state) {
                    .open => s.state = .half_closed_remote,
                    .half_closed_local => s.state = .closed,
                    else => {},
                }
            }
        }
    }

    /// Read contiguous data from a stream's receive buffer.
    pub fn readFromStream(self: *StreamManager, stream_id: u64, out: []u8) u32 {
        const s = self.getStream(stream_id) orelse return 0;
        const bytes_read = s.recv_buf.read(out);

        if (bytes_read > 0) {
            s.max_data_local += bytes_read;
        }

        // Check if stream is fully consumed after FIN
        if (s.recv_fin_offset != max_u64 and s.recv_buf.available() == 0) {
            switch (s.state) {
                .half_closed_remote => s.state = .closed,
                else => {},
            }
        }

        return bytes_read;
    }

    // ── Flow control (11.5) ──

    /// Check if we should send MAX_DATA (connection-level).
    pub fn shouldSendMaxData(self: *const StreamManager) bool {
        return self.conn_recv_offset > self.conn_recv_window / 2;
    }

    /// Handle incoming MAX_DATA frame.
    pub fn onMaxData(self: *StreamManager, max: u64) void {
        if (max > self.conn_send_max) {
            self.conn_send_max = max;
        }
    }

    /// Handle incoming MAX_STREAM_DATA frame.
    pub fn onMaxStreamData(self: *StreamManager, stream_id: u64, max: u64) void {
        if (self.getStream(stream_id)) |s| {
            if (max > s.max_data_remote) {
                s.max_data_remote = max;
                s.send_window = max;
            }
        }
    }

    /// Handle incoming MAX_STREAMS_BIDI frame.
    pub fn onMaxStreamsBidi(self: *StreamManager, max: u64) void {
        if (max > self.max_bidi_streams) {
            self.max_bidi_streams = max;
        }
    }

    /// Handle incoming MAX_STREAMS_UNI frame.
    pub fn onMaxStreamsUni(self: *StreamManager, max: u64) void {
        if (max > self.max_uni_streams) {
            self.max_uni_streams = max;
        }
    }

    // ── RESET_STREAM handling (11.6) ──

    /// Handle RESET_STREAM: discard recv data, transition to reset state.
    pub fn onResetStream(self: *StreamManager, stream_id: u64, error_code: u64) void {
        _ = error_code;
        const s = self.getStream(stream_id) orelse return;
        s.recv_buf.read_pos = 0;
        s.recv_buf.write_pos = 0;
        s.recv_buf.contiguous_end = 0;
        s.state = .reset;
    }

    /// Handle RESET_STREAM with final_size for proper flow control accounting.
    pub fn onResetStreamWithSize(self: *StreamManager, stream_id: u64, error_code: u64, final_size: u64) void {
        _ = error_code;
        const s = self.getStream(stream_id) orelse return;

        if (final_size > s.recv_offset) {
            const delta = final_size - s.recv_offset;
            self.conn_recv_offset += delta;
            s.recv_offset = final_size;
        }

        s.recv_buf.read_pos = 0;
        s.recv_buf.write_pos = 0;
        s.recv_buf.contiguous_end = 0;
        s.state = .reset;
    }
};

// ── Tests ──

const testing = @import("std").testing;

// Module-level test buffers for RingBuffer tests (avoids 64KB stack locals).
var test_big_buf: [stream_buf_size]u8 = undefined;
var test_big_out: [stream_buf_size]u8 = undefined;
var test_rb: RingBuffer = undefined;

// StreamManager test state — module-level static because StreamArray is ~8MB.
var test_sm: StreamManager = undefined;
var test_storage: StreamArray = undefined;

fn initTestRb() *RingBuffer {
    test_rb.initInPlace();
    return &test_rb;
}

fn initTestSm() *StreamManager {
    test_sm.init(&test_storage, false);
    return &test_sm;
}

fn initTestSmServer() *StreamManager {
    test_sm.init(&test_storage, true);
    return &test_sm;
}

// ── 11.8: RingBuffer tests ──

test "RingBuffer: write then read matches" {
    const rb = initTestRb();
    const data = "hello QUIC streams";
    const written = rb.write(data);
    try testing.expectEqual(@as(u32, data.len), written);
    try testing.expectEqual(@as(u32, data.len), rb.available());

    var out: [64]u8 = undefined;
    const read_n = rb.read(&out);
    try testing.expectEqual(@as(u32, data.len), read_n);
    try testing.expectEqualSlices(u8, data, out[0..read_n]);
}

test "RingBuffer: wrap-around write and read" {
    const rb = initTestRb();
    @memset(&test_big_buf, 0xAA);
    const fill_len: u32 = stream_buf_size - 2;
    const w1 = rb.write(test_big_buf[0..fill_len]);
    try testing.expectEqual(fill_len, w1);

    const discard_len: u32 = stream_buf_size - 100;
    _ = rb.read(test_big_out[0..discard_len]);

    var wrap_data: [150]u8 = undefined;
    for (&wrap_data, 0..) |*b, i| b.* = @truncate(i);
    const w2 = rb.write(&wrap_data);
    try testing.expect(w2 > 0);

    var out: [150]u8 = undefined;
    var old: [98]u8 = undefined;
    _ = rb.read(&old);
    const r2 = rb.read(&out);
    try testing.expectEqual(w2, r2);
    try testing.expectEqualSlices(u8, wrap_data[0..r2], out[0..r2]);
}

test "RingBuffer: full buffer returns 0 on write" {
    const rb = initTestRb();
    @memset(&test_big_buf, 0xBB);
    const fill_len: u32 = stream_buf_size - 1;
    const w1 = rb.write(test_big_buf[0..fill_len]);
    try testing.expectEqual(fill_len, w1);
    try testing.expectEqual(@as(u32, 0), rb.freeSpace());
    try testing.expectEqual(@as(u32, 0), rb.write("x"));
}

test "RingBuffer: empty buffer returns 0 on read" {
    const rb = initTestRb();
    var out: [16]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), rb.read(&out));
    try testing.expectEqual(@as(u32, 0), rb.available());
}

test "RingBuffer: available + freeSpace == buf_size - 1" {
    const rb = initTestRb();
    try testing.expectEqual(@as(u32, stream_buf_size - 1), rb.available() + rb.freeSpace());
    _ = rb.write("some data here!!");
    try testing.expectEqual(@as(u32, stream_buf_size - 1), rb.available() + rb.freeSpace());
    var out: [8]u8 = undefined;
    _ = rb.read(&out);
    try testing.expectEqual(@as(u32, stream_buf_size - 1), rb.available() + rb.freeSpace());
}

// ── 11.9: Stream lifecycle tests ──

test "openStream returns sequential client bidi IDs" {
    const sm = initTestSm();
    try testing.expectEqual(@as(u64, 0), sm.openStream(true).?);
    try testing.expectEqual(@as(u64, 4), sm.openStream(true).?);
    try testing.expectEqual(@as(u64, 8), sm.openStream(true).?);
}

test "openStream returns sequential server bidi IDs" {
    const sm = initTestSmServer();
    try testing.expectEqual(@as(u64, 1), sm.openStream(true).?);
    try testing.expectEqual(@as(u64, 5), sm.openStream(true).?);
}

test "openStream returns sequential client uni IDs" {
    const sm = initTestSm();
    try testing.expectEqual(@as(u64, 2), sm.openStream(false).?);
    try testing.expectEqual(@as(u64, 6), sm.openStream(false).?);
}

test "openStream returns null when max_streams reached" {
    const sm = initTestSm();
    sm.max_bidi_streams = 2;
    _ = sm.openStream(true);
    _ = sm.openStream(true);
    try testing.expectEqual(@as(?u64, null), sm.openStream(true));
}

test "openStream returns null when array full" {
    const sm = initTestSm();
    var i: u16 = 0;
    while (i < max_concurrent_streams) : (i += 1) {
        try testing.expect(sm.openStream(true) != null);
    }
    try testing.expectEqual(@as(?u64, null), sm.openStream(true));
}

test "getStream returns correct stream after open" {
    const sm = initTestSm();
    const id = sm.openStream(true).?;
    const s = sm.getStream(id).?;
    try testing.expectEqual(id, s.id);
    try testing.expectEqual(StreamState.open, s.state);
}

test "getStream returns null for unknown ID" {
    const sm = initTestSm();
    try testing.expectEqual(@as(?*Stream, null), sm.getStream(999));
}

test "closeStream transitions open to half_closed_local" {
    const sm = initTestSm();
    const id = sm.openStream(true).?;
    sm.closeStream(id);
    const s = sm.getStream(id).?;
    try testing.expectEqual(StreamState.half_closed_local, s.state);
    try testing.expect(s.send_fin);
}

test "closeStream transitions half_closed_remote to closed" {
    const sm = initTestSm();
    const id = sm.openStream(true).?;
    sm.getStream(id).?.state = .half_closed_remote;
    sm.closeStream(id);
    try testing.expectEqual(StreamState.closed, sm.getStream(id).?.state);
}

test "implicit stream creation on incoming frame" {
    const sm = initTestSm();
    sm.onStreamData(1, 0, "hello", false);
    const s = sm.getStream(1).?;
    try testing.expectEqual(@as(u64, 1), s.id);
    try testing.expectEqual(StreamState.open, s.state);
}
