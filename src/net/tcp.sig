//! TCP (RFC 9293) — zero allocation, fixed connection pool, freestanding.
//!
//! Built to carry long-lived TLS streams over real (lossy, reordering) links:
//! the sb0s Galaxy genie streams its answers over it. Features:
//!   - Active and passive open, all RFC 9293 states, RST validation (RFC 5961)
//!   - MSS, window scale and SACK-permitted options; SYN windows are never
//!     scaled and scaling is off unless both SYNs carry the option
//!   - Send/receive ring buffers; the advertised receive window is the free
//!     space, so the right edge never shrinks
//!   - Retransmission per RFC 6298 (Karn, exponential backoff, 200 ms floor)
//!     with go-back-N from SND.UNA
//!   - NewReno (RFC 5681/6582): slow start, congestion avoidance, fast
//!     retransmit on the 3rd duplicate ACK, fast recovery with partial-ACK
//!     retransmission
//!   - Out-of-order reassembly (one contiguous range) reported with an honest
//!     SACK block, immediate ACKs for gaps and duplicates
//!   - Delayed ACK (40 ms / every 2nd full segment)
//!   - Window updates when the application reads (SWS avoidance), zero-window
//!     probing
//!   - Graceful close: FIN after all queued data; FIN carried with data;
//!     short client-side TIME_WAIT
//!   - RFC 6528-style ISNs and randomized ephemeral ports from a caller seed
//!
//! Time is supplied by the caller in microseconds: tick(now_us, ...) runs the
//! timers and emits segments; processSegment() handles one inbound segment and
//! may return one immediate reply (ACK or RST). Packets produced here are
//! IPv4 + TCP (no link-layer header).

const checksum = @import("net_checksum");
const ipv4 = @import("net_ipv4");

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

pub const HEADER_MIN: usize = 20;
pub const HEADER_MAX: usize = 60; // With options
/// Connections at once, for every app and the kernel together. 32 ran out
/// in Galaxy with one Firefox window on a news site (81 connects refused in
/// a minute, then every other page and the assistant's searches failed): a
/// browser keeps several connections to each of a page's many hosts. Each
/// slot is static (RECV_BUF_SIZE + SEND_BUF_SIZE, 544 KiB): 128 is 68 MiB.
/// Handles are u8 and callers keep 0xff as "no slot", so at most 254.
pub const MAX_CONNECTIONS: usize = 128;
pub const RECV_BUF_SIZE: usize = 512 * 1024; // the window: at 64 KiB a download ran at ~2-3 MB/s (window / round trip)
pub const SEND_BUF_SIZE: usize = 32 * 1024;
pub const DEFAULT_MSS: u16 = 1460; // Ethernet MTU - IP(20) - TCP(20)
pub const MAX_WINDOW: u32 = 1073741824; // 1GB with scaling
/// Our window scale shift (the window field counts in 16-byte units).
const RCV_WSCALE: u8 = 4; // 65535 << 4 covers the 512 KiB window

// Timers (microseconds).
pub const INITIAL_RTO_US: u32 = 1_000_000; // RFC 6298 §2.1
pub const MIN_RTO_US: u32 = 200_000; // Linux's floor; RFC 6298's 1 s is too sluggish
pub const MAX_RTO_US: u32 = 60_000_000;
pub const DELAYED_ACK_US: u64 = 40_000;
pub const TIME_WAIT_US: u64 = 10_000_000; // short: we are a client with random ports
pub const PERSIST_MIN_US: u64 = 500_000;
const MAX_SYN_RETRIES: u8 = 6; // 1+2+4+8+16+32 s
const MAX_DATA_RETRIES: u8 = 12;
const MAX_BURST: usize = 64; // segments per connection per tick

// TCP flags
pub const FLAG_FIN: u8 = 0x01;
pub const FLAG_SYN: u8 = 0x02;
pub const FLAG_RST: u8 = 0x04;
pub const FLAG_PSH: u8 = 0x08;
pub const FLAG_ACK: u8 = 0x10;
pub const FLAG_URG: u8 = 0x20;
pub const FLAG_ECE: u8 = 0x40;
pub const FLAG_CWR: u8 = 0x80;

// TCP option kinds
const OPT_END: u8 = 0;
const OPT_NOP: u8 = 1;
const OPT_MSS: u8 = 2;
const OPT_WINDOW_SCALE: u8 = 3;
const OPT_SACK_PERMITTED: u8 = 4;
const OPT_SACK: u8 = 5;

// ══════════════════════════════════════════════════════════════════════════════
// State machine (RFC 9293 §3.3.2)
// ══════════════════════════════════════════════════════════════════════════════

pub const State = enum(u8) {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    closing,
    time_wait,
    close_wait,
    last_ack,
};

/// Why a connection reached CLOSED without a graceful exchange.
pub const CloseReason = enum(u8) { none, refused, reset, timeout };

// ══════════════════════════════════════════════════════════════════════════════
// Congestion Control (RFC 5681 NewReno)
// ══════════════════════════════════════════════════════════════════════════════

pub const CongestionState = struct {
    cwnd: u32, // Congestion window (bytes)
    ssthresh: u32, // Slow-start threshold
    recovery_point: u32, // SND.MAX when fast recovery was entered
    in_recovery: bool,
    dup_ack_count: u8,

    pub fn init(mss: u16) CongestionState {
        return .{
            .cwnd = @as(u32, mss) * 10, // RFC 6928: IW=10
            .ssthresh = MAX_WINDOW,
            .recovery_point = 0,
            .in_recovery = false,
            .dup_ack_count = 0,
        };
    }

    /// Grow the window on a new ACK (slow start or congestion avoidance).
    pub fn onAck(self: *CongestionState, bytes_acked: u32, mss: u16) void {
        if (self.in_recovery) return;
        if (self.cwnd < self.ssthresh) {
            self.cwnd += bytes_acked;
        } else {
            self.cwnd += @max(1, @as(u32, mss) * @as(u32, mss) / self.cwnd);
        }
        if (self.cwnd > MAX_WINDOW) self.cwnd = MAX_WINDOW;
    }

    /// Enter fast recovery on the 3rd duplicate ACK (RFC 5681 §3.2).
    pub fn enterFastRecovery(self: *CongestionState, flight_size: u32, snd_max: u32) void {
        self.ssthresh = @max(flight_size / 2, @as(u32, 2) * DEFAULT_MSS);
        self.cwnd = self.ssthresh + 3 * DEFAULT_MSS;
        self.recovery_point = snd_max;
        self.in_recovery = true;
        self.dup_ack_count = 0;
    }

    /// Inflate the window for each further duplicate ACK in recovery.
    pub fn onDupAckInRecovery(self: *CongestionState) void {
        self.cwnd += DEFAULT_MSS;
    }

    /// Leave fast recovery once the recovery point is acknowledged.
    pub fn exitRecovery(self: *CongestionState) void {
        self.cwnd = self.ssthresh;
        self.in_recovery = false;
        self.dup_ack_count = 0;
    }

    /// Collapse the window on a retransmission timeout (RFC 5681 §3.1).
    pub fn onTimeout(self: *CongestionState, mss: u16) void {
        self.ssthresh = @max(self.cwnd / 2, @as(u32, 2) * mss);
        self.cwnd = mss;
        self.in_recovery = false;
        self.dup_ack_count = 0;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// RTT Estimation (RFC 6298), microseconds
// ══════════════════════════════════════════════════════════════════════════════

pub const RttState = struct {
    srtt: u32, // Smoothed RTT (µs, scaled ×8)
    rttvar: u32, // RTT variance (µs, scaled ×4)
    rto: u32, // Retransmission timeout (µs)
    has_sample: bool,

    pub fn init() RttState {
        return .{ .srtt = 0, .rttvar = 0, .rto = INITIAL_RTO_US, .has_sample = false };
    }

    /// Fold in one RTT measurement (RFC 6298 §2).
    pub fn update(self: *RttState, rtt_us: u32) void {
        const r = @min(rtt_us, MAX_RTO_US);
        if (!self.has_sample) {
            self.srtt = r << 3;
            self.rttvar = r << 1;
            self.has_sample = true;
        } else {
            const s = self.srtt >> 3;
            const diff = if (s > r) s - r else r - s;
            self.rttvar = (self.rttvar * 3 + (diff << 2)) >> 2;
            self.srtt = (self.srtt * 7 + (r << 3)) >> 3;
        }
        // RTO = SRTT + max(G, 4·RTTVAR); rttvar is stored ×4 already.
        self.rto = (self.srtt >> 3) + @max(1000, self.rttvar);
        self.rto = @max(MIN_RTO_US, @min(self.rto, MAX_RTO_US));
    }

    /// Exponential backoff after a timeout (RFC 6298 §5.5).
    pub fn backoff(self: *RttState) void {
        self.rto = @min(self.rto *| 2, MAX_RTO_US);
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Connection
// ══════════════════════════════════════════════════════════════════════════════

pub const Connection = struct {
    state: State,
    active: bool,
    user_closed: bool, // close() was called; release the slot on reaching CLOSED
    accepted: bool, // passive side handed out by accept()
    listener: u8, // passive side: index of the LISTEN slot that spawned it
    reason: CloseReason,

    local_ip: [4]u8,
    local_port: u16,
    remote_ip: [4]u8,
    remote_port: u16,

    // Send sequence space. SND.MAX is the highest sequence number sent (it
    // stays put when a timeout rewinds SND.NXT for go-back-N).
    iss: u32,
    snd_una: u32,
    snd_nxt: u32,
    snd_max: u32,
    snd_wnd: u32,
    snd_wl1: u32,
    snd_wl2: u32,

    // Receive sequence space. rcv_adv is the right window edge last advertised.
    irs: u32,
    rcv_nxt: u32,
    rcv_adv: u32,

    // Options
    mss: u16,
    snd_wscale: u8,
    rcv_wscale: u8,
    sack_ok: bool,
    nagle: bool,

    // Send ring: snd_count bytes, the first at sequence number SND.UNA.
    snd_head: usize,
    snd_count: usize,
    fin_queued: bool, // close() called: FIN follows the queued data
    fin_sent: bool, // FIN is in flight (cleared by a go-back-N rewind)
    fin_acked: bool,
    fin_seq: u32, // sequence number of our FIN (valid once fin_seq_set)
    fin_seq_set: bool,

    // Receive ring: rcv_count readable bytes; out-of-order bytes live after
    // them at offset (ooo_start - RCV.NXT).
    rcv_head: usize,
    rcv_count: usize,
    ooo_valid: bool,
    ooo_start: u32,
    ooo_end: u32,
    fin_received: bool,

    cc: CongestionState,
    rtt: RttState,

    // Timers: absolute deadlines in µs, 0 = off.
    rto_deadline: u64,
    retries: u8,
    rtt_active: bool,
    rtt_seq: u32,
    rtt_start: u64,
    syn_time: u64,
    syn_retransmitted: bool,
    ack_now: bool,
    delack_deadline: u64,
    segs_unacked: u8,
    persist_deadline: u64,
    persist_backoff: u8,
    fast_rexmit: bool,
    time_wait_deadline: u64,
    backlog: u8,

    total_sent: u64,
    total_recv: u64,
    retransmits: u32,

    send_buf: [SEND_BUF_SIZE]u8,
    recv_buf: [RECV_BUF_SIZE]u8,

    /// Reset everything but the buffers (their contents are dead once the
    /// counters are zero; clearing 96 KB per connection would be waste).
    pub fn reset(self: *Connection) void {
        self.state = .closed;
        self.active = false;
        self.user_closed = false;
        self.accepted = false;
        self.listener = 0xFF;
        self.reason = .none;
        self.local_ip = .{ 0, 0, 0, 0 };
        self.local_port = 0;
        self.remote_ip = .{ 0, 0, 0, 0 };
        self.remote_port = 0;
        self.iss = 0;
        self.snd_una = 0;
        self.snd_nxt = 0;
        self.snd_max = 0;
        self.snd_wnd = 0;
        self.snd_wl1 = 0;
        self.snd_wl2 = 0;
        self.irs = 0;
        self.rcv_nxt = 0;
        self.rcv_adv = 0;
        self.mss = DEFAULT_MSS;
        self.snd_wscale = 0;
        self.rcv_wscale = 0;
        self.sack_ok = false;
        self.nagle = true;
        self.snd_head = 0;
        self.snd_count = 0;
        self.fin_queued = false;
        self.fin_sent = false;
        self.fin_acked = false;
        self.fin_seq = 0;
        self.fin_seq_set = false;
        self.rcv_head = 0;
        self.rcv_count = 0;
        self.ooo_valid = false;
        self.ooo_start = 0;
        self.ooo_end = 0;
        self.fin_received = false;
        self.cc = CongestionState.init(DEFAULT_MSS);
        self.rtt = RttState.init();
        self.rto_deadline = 0;
        self.retries = 0;
        self.rtt_active = false;
        self.rtt_seq = 0;
        self.rtt_start = 0;
        self.syn_time = 0;
        self.syn_retransmitted = false;
        self.ack_now = false;
        self.delack_deadline = 0;
        self.segs_unacked = 0;
        self.persist_deadline = 0;
        self.persist_backoff = 0;
        self.fast_rexmit = false;
        self.time_wait_deadline = 0;
        self.backlog = 0;
        self.total_sent = 0;
        self.total_recv = 0;
        self.retransmits = 0;
    }

    /// Effective send window: min(peer's receive window, congestion window).
    pub fn effectiveWindow(self: *const Connection) u32 {
        return @min(self.snd_wnd, self.cc.cwnd);
    }

    /// Bytes in flight (sent, not yet acknowledged).
    pub fn flightSize(self: *const Connection) u32 {
        return self.snd_nxt -% self.snd_una;
    }

    /// Room left in the effective window.
    pub fn availableWindow(self: *const Connection) u32 {
        const eff = self.effectiveWindow();
        const flight = self.flightSize();
        return if (flight >= eff) 0 else eff - flight;
    }

    pub fn readable(self: *const Connection) usize {
        return self.rcv_count;
    }

    pub fn writable(self: *const Connection) usize {
        return SEND_BUF_SIZE - self.snd_count;
    }

    /// RTO with exponential backoff for consecutive timeouts. The backoff is
    /// dropped as soon as new data is acknowledged (as Linux does): after a
    /// go-back-N rewind no fresh RTT sample may arrive for a long time, and a
    /// stuck 60 s RTO would stall the stream.
    fn rto(self: *const Connection) u64 {
        const shift: u6 = @intCast(@min(self.retries, 16));
        return @min(@as(u64, self.rtt.rto) << shift, MAX_RTO_US);
    }

    fn rcvFree(self: *const Connection) usize {
        return RECV_BUF_SIZE - self.rcv_count;
    }

    fn dataEnd(self: *const Connection) u32 {
        return self.snd_una +% @as(u32, @intCast(self.snd_count));
    }

    fn synchronized(self: *const Connection) bool {
        return switch (self.state) {
            .closed, .listen, .syn_sent, .syn_received => false,
            else => true,
        };
    }

    fn canSendData(self: *const Connection) bool {
        return switch (self.state) {
            .established, .close_wait, .fin_wait_1, .closing, .last_ack => true,
            else => false,
        };
    }

    fn canReceiveData(self: *const Connection) bool {
        return switch (self.state) {
            .established, .fin_wait_1, .fin_wait_2 => true,
            else => false,
        };
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Pool, clock, entropy
// ══════════════════════════════════════════════════════════════════════════════

var connections: [MAX_CONNECTIONS]Connection = undefined;
var pool_ready = false;
var clock_us: u64 = 0;
var isn_key: u64 = 0x9E37_79B9_7F4A_7C15;
var next_local_port: u16 = 49152;

fn pool() *[MAX_CONNECTIONS]Connection {
    if (!pool_ready) {
        for (&connections) |*c| c.reset();
        pool_ready = true;
    }
    return &connections;
}

fn conn(handle: u8) ?*Connection {
    if (handle >= MAX_CONNECTIONS) return null;
    const c = &pool()[handle];
    return if (c.active) c else null;
}

/// Mix caller entropy into ISN and ephemeral-port generation. Call once at
/// boot with a hardware/firmware seed; ISNs are then unpredictable (RFC 6528).
pub fn seed(entropy: u64) void {
    isn_key = mix64(isn_key ^ entropy);
    next_local_port = 49152 + @as(u16, @truncate(mix64(isn_key) % 16384));
}

/// Set the stack's clock (µs, monotonic). tick() sets it too.
pub fn setClock(now_us: u64) void {
    if (now_us > clock_us) clock_us = now_us;
}

fn mix64(x0: u64) u64 {
    var x = x0 +% 0x9E37_79B9_7F4A_7C15;
    x = (x ^ (x >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    x = (x ^ (x >> 27)) *% 0x94D0_49BB_1331_11EB;
    return x ^ (x >> 31);
}

fn generateISN(c: *const Connection) u32 {
    const tuple = (@as(u64, c.local_port) << 48) | (@as(u64, c.remote_port) << 32) |
        (@as(u64, c.remote_ip[0]) << 24) | (@as(u64, c.remote_ip[1]) << 16) |
        (@as(u64, c.remote_ip[2]) << 8) | c.remote_ip[3];
    // RFC 6528: ISN = M + F(4-tuple, secret), M a 4 µs clock.
    return @as(u32, @truncate(mix64(isn_key ^ tuple))) +% @as(u32, @truncate(clock_us >> 2));
}

fn allocPort(remote_ip: [4]u8, remote_port: u16) u16 {
    var tries: usize = 0;
    while (tries < 16384) : (tries += 1) {
        const port = next_local_port;
        next_local_port = if (next_local_port >= 65535) 49152 else next_local_port + 1;
        var used = false;
        for (pool()) |*c| {
            if (c.active and c.local_port == port and c.remote_port == remote_port and ipEqual(c.remote_ip, remote_ip)) used = true;
        }
        if (!used) return port;
    }
    return next_local_port;
}

fn allocConn() ?*Connection {
    for (pool()) |*c| {
        if (!c.active) return c;
    }
    return null;
}

fn connHandle(c: *const Connection) u8 {
    const base = @intFromPtr(&connections[0]);
    return @intCast((@intFromPtr(c) - base) / @sizeOf(Connection));
}

/// Connection reached CLOSED: free the slot if the user already closed it,
/// otherwise keep it (state .closed + reason) until close()/abort().
fn toClosed(c: *Connection, reason: CloseReason) void {
    if (c.user_closed) {
        c.reset();
        return;
    }
    c.state = .closed;
    c.reason = reason;
    c.rto_deadline = 0;
    c.delack_deadline = 0;
    c.persist_deadline = 0;
    c.ack_now = false;
}

// ══════════════════════════════════════════════════════════════════════════════
// Public API — open
// ══════════════════════════════════════════════════════════════════════════════

/// Active open. The SYN goes out on the next tick()/generatePacket().
/// Returns a handle, or null if the pool is full.
pub fn connect(local_ip: [4]u8, remote_ip: [4]u8, remote_port: u16) ?u8 {
    const c = allocConn() orelse return null;
    c.reset();
    c.active = true;
    c.state = .syn_sent;
    c.local_ip = local_ip;
    c.remote_ip = remote_ip;
    c.remote_port = remote_port;
    c.local_port = allocPort(remote_ip, remote_port);
    c.iss = generateISN(c);
    c.snd_una = c.iss;
    c.snd_nxt = c.iss;
    c.snd_max = c.iss;
    c.rcv_wscale = RCV_WSCALE;
    return connHandle(c);
}

/// Passive open. Returns the LISTEN handle, or null if the pool is full.
pub fn listen(local_ip: [4]u8, local_port: u16, backlog: u8) ?u8 {
    const c = allocConn() orelse return null;
    c.reset();
    c.active = true;
    c.state = .listen;
    c.local_ip = local_ip;
    c.local_port = local_port;
    c.backlog = @max(backlog, 1);
    return connHandle(c);
}

/// Take a connection spawned by a LISTEN socket (established ones first).
pub fn accept(listen_handle: u8) ?u8 {
    const l = conn(listen_handle) orelse return null;
    if (l.state != .listen) return null;
    var fallback: ?*Connection = null;
    for (pool()) |*c| {
        if (!c.active or c.accepted or c.listener != listen_handle) continue;
        if (c.state == .established or c.state == .close_wait) {
            c.accepted = true;
            return connHandle(c);
        }
        if (c.state == .syn_received and fallback == null) fallback = c;
    }
    if (fallback) |c| {
        c.accepted = true;
        return connHandle(c);
    }
    return null;
}

// ══════════════════════════════════════════════════════════════════════════════
// Public API — data
// ══════════════════════════════════════════════════════════════════════════════

/// Read in-order received data. Returns bytes read (0 = nothing yet, or EOF —
/// see eof()).
pub fn recv(handle: u8, buf: []u8) usize {
    const c = conn(handle) orelse return 0;
    const n = @min(buf.len, c.rcv_count);
    if (n == 0) return 0;
    ringRead(&c.recv_buf, c.rcv_head, buf[0..n]);
    c.rcv_head = (c.rcv_head + n) % RECV_BUF_SIZE;
    c.rcv_count -= n;
    // Window update when the right edge can move by a meaningful amount.
    if (c.synchronized() and !c.fin_received) {
        const edge = c.rcv_nxt +% advertisedWindow(c);
        const moved = edge -% c.rcv_adv;
        if (seqGt(edge, c.rcv_adv) and moved >= @min(@as(u32, RECV_BUF_SIZE / 2), 2 * @as(u32, c.mss))) {
            c.ack_now = true;
        }
    }
    return n;
}

/// recv without taking: the bytes stay queued (MSG_PEEK).
pub fn peek(handle: u8, buf: []u8) usize {
    const c = conn(handle) orelse return 0;
    const n = @min(buf.len, c.rcv_count);
    if (n == 0) return 0;
    ringRead(&c.recv_buf, c.rcv_head, buf[0..n]);
    return n;
}

/// Queue data for sending. Returns bytes accepted (limited by buffer space).
pub fn send(handle: u8, data: []const u8) usize {
    const c = conn(handle) orelse return 0;
    if (c.state != .established and c.state != .close_wait) return 0;
    if (c.fin_queued) return 0;
    const n = @min(data.len, SEND_BUF_SIZE - c.snd_count);
    if (n == 0) return 0;
    ringWrite(&c.send_buf, (c.snd_head + c.snd_count) % SEND_BUF_SIZE, data[0..n]);
    c.snd_count += n;
    return n;
}

// ══════════════════════════════════════════════════════════════════════════════
// Public API — control and status
// ══════════════════════════════════════════════════════════════════════════════

/// Graceful close: FIN after all queued data. The slot is released when the
/// close completes (or immediately if the connection is already dead).
pub fn close(handle: u8) void {
    const c = conn(handle) orelse return;
    c.user_closed = true;
    switch (c.state) {
        .closed, .listen, .syn_sent, .syn_received => c.reset(),
        .established => {
            c.fin_queued = true;
            c.state = .fin_wait_1;
        },
        .close_wait => {
            c.fin_queued = true;
            c.state = .last_ack;
        },
        else => {},
    }
}

/// Drop the connection immediately (the peer's next segment draws a RST).
pub fn abort(handle: u8) void {
    const c = conn(handle) orelse return;
    c.reset();
}

pub fn getState(handle: u8) State {
    const c = conn(handle) orelse return .closed;
    return c.state;
}

pub fn closeReason(handle: u8) CloseReason {
    const c = conn(handle) orelse return .none;
    return c.reason;
}

pub fn hasData(handle: u8) bool {
    const c = conn(handle) orelse return false;
    return c.rcv_count > 0;
}

/// Bytes received and not read yet.
pub fn pendingBytes(handle: u8) usize {
    const c = conn(handle) orelse return 0;
    return c.rcv_count;
}

/// True once the peer's FIN arrived and every byte before it was read.
pub fn eof(handle: u8) bool {
    const c = conn(handle) orelse return true;
    return (c.fin_received or c.state == .closed) and c.rcv_count == 0;
}

pub fn isClosed(handle: u8) bool {
    const c = conn(handle) orelse return true;
    return c.state == .closed;
}

pub fn localPort(handle: u8) u16 {
    const c = conn(handle) orelse return 0;
    return c.local_port;
}

pub fn writable(handle: u8) usize {
    const c = conn(handle) orelse return 0;
    return c.writable();
}

/// All queued data sent and acknowledged.
pub fn sendDrained(handle: u8) bool {
    const c = conn(handle) orelse return true;
    return c.snd_count == 0;
}

pub fn setNoDelay(handle: u8, no_delay: bool) void {
    const c = conn(handle) orelse return;
    c.nagle = !no_delay;
}

pub fn getStats(handle: u8) struct { sent: u64, recv: u64, retransmits: u32, rtt_us: u32 } {
    const c = conn(handle) orelse return .{ .sent = 0, .recv = 0, .retransmits = 0, .rtt_us = 0 };
    return .{
        .sent = c.total_sent,
        .recv = c.total_recv,
        .retransmits = c.retransmits,
        .rtt_us = if (c.rtt.has_sample) c.rtt.srtt >> 3 else 0,
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Output
// ══════════════════════════════════════════════════════════════════════════════

/// Produce the next segment this connection wants to send (SYN, data, FIN or
/// a pending ACK), or null. Returns the IPv4+TCP packet length.
pub fn generatePacket(handle: u8, pkt_buf: []u8) ?usize {
    const c = conn(handle) orelse return null;
    return output(c, pkt_buf);
}

/// Run every connection's timers and emit what is due, at time now_us.
/// sendFn receives complete IPv4+TCP packets.
pub fn tick(now_us: u64, pkt_buf: []u8, sendFn: *const fn ([]const u8) void) void {
    setClock(now_us);
    const now = clock_us;
    for (pool()) |*c| {
        if (!c.active) continue;
        switch (c.state) {
            .closed, .listen => continue,
            .time_wait => {
                if (now >= c.time_wait_deadline) {
                    toClosed(c, .none);
                    continue;
                }
            },
            else => {},
        }

        // Retransmission timeout.
        if (c.rto_deadline != 0 and now >= c.rto_deadline) {
            if (!onRetransmitTimeout(c, pkt_buf, sendFn)) continue;
        }

        // Fast retransmit / NewReno partial-ACK retransmit.
        if (c.fast_rexmit) {
            c.fast_rexmit = false;
            if (buildRetransmit(c, pkt_buf)) |len| sendFn(pkt_buf[0..len]);
        }

        // Zero-window probing: data waiting, window shut, nothing in flight.
        if (c.canSendData() and c.snd_wnd == 0 and c.snd_count > 0 and c.snd_una == c.snd_max) {
            if (c.persist_deadline == 0) {
                c.persist_deadline = now + @max(c.rto(), PERSIST_MIN_US);
            } else if (now >= c.persist_deadline) {
                if (buildProbe(c, pkt_buf)) |len| sendFn(pkt_buf[0..len]);
                if (c.persist_backoff < 7) c.persist_backoff += 1;
                const wait = @min(c.rto() << @as(u6, @intCast(c.persist_backoff)), MAX_RTO_US);
                c.persist_deadline = now + @max(wait, PERSIST_MIN_US);
            }
        } else {
            c.persist_deadline = 0;
            c.persist_backoff = 0;
        }

        // Delayed ACK.
        if (c.delack_deadline != 0 and now >= c.delack_deadline) {
            c.delack_deadline = 0;
            c.ack_now = true;
        }

        var burst: usize = 0;
        while (burst < MAX_BURST) : (burst += 1) {
            const len = output(c, pkt_buf) orelse break;
            sendFn(pkt_buf[0..len]);
        }
    }
}

/// Compatibility driver for callers without a clock: advances 1 ms per call.
pub fn tickAll(pkt_buf: []u8, sendFn: *const fn ([]const u8) void) void {
    tick(clock_us + 1000, pkt_buf, sendFn);
}

/// Returns false if the connection died.
fn onRetransmitTimeout(c: *Connection, pkt_buf: []u8, sendFn: *const fn ([]const u8) void) bool {
    const now = clock_us;
    const handshaking = c.state == .syn_sent or c.state == .syn_received;
    if (!handshaking and c.snd_una == c.snd_max) {
        c.rto_deadline = 0; // nothing outstanding
        return true;
    }
    c.retries += 1;
    if (c.retries > (if (handshaking) MAX_SYN_RETRIES else MAX_DATA_RETRIES)) {
        toClosed(c, .timeout);
        return false;
    }
    c.retransmits += 1;
    c.rtt_active = false; // Karn: no samples across a retransmission
    c.cc.onTimeout(c.mss);
    c.rto_deadline = now + c.rto();
    switch (c.state) {
        .syn_sent => {
            c.syn_retransmitted = true;
            if (buildControl(c, FLAG_SYN, c.iss, pkt_buf)) |len| sendFn(pkt_buf[0..len]);
        },
        .syn_received => {
            c.syn_retransmitted = true;
            if (buildControl(c, FLAG_SYN | FLAG_ACK, c.iss, pkt_buf)) |len| sendFn(pkt_buf[0..len]);
        },
        else => {
            // Go-back-N: resend from SND.UNA; output() refills the window
            // (which is now one segment) in tick's burst loop.
            c.snd_nxt = c.snd_una;
            if (c.fin_sent and !c.fin_acked) c.fin_sent = false;
        },
    }
    return true;
}

fn output(c: *Connection, buf: []u8) ?usize {
    const now = clock_us;
    switch (c.state) {
        .closed, .listen, .time_wait => {
            if (c.state == .time_wait and c.ack_now) return buildAck(c, buf);
            return null;
        },
        .syn_sent => {
            if (c.syn_time != 0) return null; // retransmission is timer-driven
            c.syn_time = now;
            c.snd_nxt = c.iss +% 1;
            c.snd_max = c.snd_nxt;
            c.rto_deadline = now + c.rto();
            return buildControl(c, FLAG_SYN, c.iss, buf);
        },
        .syn_received => {
            if (c.syn_time != 0) return if (c.ack_now) buildControl(c, FLAG_SYN | FLAG_ACK, c.iss, buf) else null;
            c.syn_time = now;
            c.rto_deadline = now + c.rto();
            return buildControl(c, FLAG_SYN | FLAG_ACK, c.iss, buf);
        },
        else => {},
    }

    if (c.canSendData()) {
        const data_end = c.dataEnd();
        if (seqLt(c.snd_nxt, data_end)) {
            const avail: u32 = data_end -% c.snd_nxt;
            const win = c.availableWindow();
            var len: u32 = @min(avail, @min(win, @as(u32, c.mss)));
            // Nagle (RFC 896): hold back a runt while data is in flight,
            // unless the window (not the data) is what limits the segment.
            if (len > 0 and c.nagle and len < c.mss and len == avail and c.snd_nxt != c.snd_una) len = 0;
            if (len > 0) {
                const first_send = seqGeq(c.snd_nxt, c.snd_max);
                const push = c.snd_nxt +% len == data_end;
                const r = buildData(c, c.snd_nxt, len, push, buf) orelse return null;
                if (first_send and !c.rtt_active) {
                    c.rtt_active = true;
                    c.rtt_seq = c.snd_nxt;
                    c.rtt_start = now;
                }
                c.snd_nxt +%= len;
                if (seqGt(c.snd_nxt, c.snd_max)) c.snd_max = c.snd_nxt;
                if (first_send) c.total_sent += len;
                if (c.rto_deadline == 0) c.rto_deadline = now + c.rto();
                return r;
            }
        }
        // FIN once every data byte has been sent.
        if (c.fin_queued and !c.fin_sent and !c.fin_acked and c.snd_nxt == data_end) {
            if (!c.fin_seq_set) {
                c.fin_seq = data_end; // send() refuses data after close()
                c.fin_seq_set = true;
            }
            c.fin_sent = true;
            c.snd_nxt = c.fin_seq +% 1;
            if (seqGt(c.snd_nxt, c.snd_max)) c.snd_max = c.snd_nxt;
            if (c.rto_deadline == 0) c.rto_deadline = now + c.rto();
            return buildControl(c, FLAG_FIN | FLAG_ACK, c.fin_seq, buf);
        }
    }

    if (c.ack_now) return buildAck(c, buf);
    return null;
}

// ══════════════════════════════════════════════════════════════════════════════
// Input (RFC 9293 §3.10.7)
// ══════════════════════════════════════════════════════════════════════════════

/// Process one inbound TCP segment (the IP payload, exactly the IP total
/// length minus the IP header). Updates state; may write an immediate reply
/// (ACK or RST) into reply_buf and return its length.
pub fn processSegment(
    tcp_data: []const u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    reply_buf: []u8,
) ?usize {
    if (tcp_data.len < HEADER_MIN or tcp_data.len > 0xFFFF) return null;
    const seg = parseHeader(tcp_data) orelse return null;

    var acc = checksum.pseudoHeaderSum(src_ip, dst_ip, ipv4.PROTO_TCP, @intCast(tcp_data.len));
    acc = checksum.combine(acc, checksum.sum(tcp_data));
    if (checksum.fold(acc) != 0) return null;

    if (findConn(dst_ip, seg.dst_port, src_ip, seg.src_port)) |c| {
        return processForConnection(c, &seg, tcp_data, reply_buf);
    }
    if (findListener(seg.dst_port, dst_ip)) |l| {
        return processForListener(l, &seg, tcp_data, src_ip, dst_ip, reply_buf);
    }
    if (seg.flags & FLAG_RST != 0) return null;
    return buildRstFor(&seg, tcp_data.len - seg.data_offset, src_ip, dst_ip, reply_buf);
}

fn processForConnection(c: *Connection, seg: *const Segment, tcp_data: []const u8, reply_buf: []u8) ?usize {
    const payload = tcp_data[seg.data_offset..];
    switch (c.state) {
        .syn_sent => return processSynSent(c, seg, tcp_data, reply_buf),
        .closed, .listen => return null,
        else => {},
    }

    // RST: accept only an exact hit on RCV.NXT (RFC 5961 §3.2); anything
    // else in the window draws a challenge ACK.
    if (seg.flags & FLAG_RST != 0) {
        if (seg.seq == c.rcv_nxt) {
            if (c.state == .syn_received and c.listener != 0xFF and !c.accepted) {
                c.reset(); // never surfaced to the user
            } else {
                toClosed(c, .reset);
            }
            return null;
        }
        if (inWindow(c, seg.seq)) return buildAck(c, reply_buf);
        return null;
    }

    // A SYN in a synchronized state: challenge ACK (RFC 5961 §4). In
    // SYN-RECEIVED a repeated SYN means our SYN-ACK was lost: resend it.
    if (seg.flags & FLAG_SYN != 0) {
        if (c.state == .syn_received) {
            if (seg.flags & FLAG_ACK == 0) return buildControl(c, FLAG_SYN | FLAG_ACK, c.iss, reply_buf);
        } else return buildAck(c, reply_buf);
    }

    const seg_len: u32 = @as(u32, @intCast(payload.len)) + @as(u32, @intFromBool(seg.flags & FLAG_FIN != 0));

    // Segments entirely before RCV.NXT (retransmissions of data we have):
    // re-ACK so a peer that lost our ACK can move on.
    if (seg_len > 0 and seqLeq(seg.seq +% seg_len, c.rcv_nxt)) {
        c.ack_now = true;
    }

    if (seg.flags & FLAG_ACK == 0) return flushAck(c, reply_buf);

    // SYN-RECEIVED: the ACK of our SYN completes the passive open.
    if (c.state == .syn_received) {
        if (seg.ack != c.iss +% 1) return buildRstFor(seg, payload.len, c.remote_ip, c.local_ip, reply_buf);
        c.snd_una = seg.ack;
        if (seqLt(c.snd_nxt, c.snd_una)) c.snd_nxt = c.snd_una;
        c.snd_wnd = @as(u32, seg.window) << @as(u5, @intCast(c.snd_wscale));
        c.snd_wl1 = seg.seq;
        c.snd_wl2 = seg.ack;
        c.state = .established;
        c.rto_deadline = 0;
        c.retries = 0;
        if (!c.syn_retransmitted and c.syn_time != 0) c.rtt.update(@intCast(@min(clock_us - c.syn_time, MAX_RTO_US)));
    } else {
        processAck(c, seg, payload.len);
    }
    if (!c.active) return null; // LAST-ACK completed

    // Data and FIN.
    if (c.canReceiveData() and seg_len > 0) receive(c, seg, payload);

    return flushAck(c, reply_buf);
}

fn flushAck(c: *Connection, reply_buf: []u8) ?usize {
    if (!c.ack_now) return null;
    return buildAck(c, reply_buf);
}

fn processSynSent(c: *Connection, seg: *const Segment, tcp_data: []const u8, reply_buf: []u8) ?usize {
    const has_ack = seg.flags & FLAG_ACK != 0;
    if (has_ack and seg.ack != c.iss +% 1) {
        if (seg.flags & FLAG_RST != 0) return null;
        return buildRstFor(seg, tcp_data.len - seg.data_offset, c.remote_ip, c.local_ip, reply_buf);
    }
    if (seg.flags & FLAG_RST != 0) {
        if (has_ack) toClosed(c, .refused);
        return null;
    }
    if (seg.flags & FLAG_SYN == 0) return null;

    c.irs = seg.seq;
    c.rcv_nxt = seg.seq +% 1;
    const peer = parseSynOptions(tcp_data, seg.data_offset);
    c.mss = @min(peer.mss, DEFAULT_MSS);
    if (peer.wscale) |ws| {
        c.snd_wscale = ws;
    } else {
        c.snd_wscale = 0;
        c.rcv_wscale = 0; // scaling needs both sides
    }
    c.sack_ok = peer.sack_ok;
    c.cc = CongestionState.init(c.mss);

    if (has_ack) {
        c.snd_una = seg.ack;
        c.snd_wnd = seg.window; // SYN windows are never scaled (RFC 7323 §2.2)
        c.snd_wl1 = seg.seq;
        c.snd_wl2 = seg.ack;
        c.state = .established;
        c.rto_deadline = 0;
        c.retries = 0;
        if (!c.syn_retransmitted and c.syn_time != 0) c.rtt.update(@intCast(@min(clock_us - c.syn_time, MAX_RTO_US)));
        c.ack_now = true;
        return buildAck(c, reply_buf);
    }
    // Simultaneous open.
    c.state = .syn_received;
    c.syn_time = 0; // output() sends the SYN-ACK
    c.snd_wnd = seg.window;
    return null;
}

fn processForListener(l: *Connection, seg: *const Segment, tcp_data: []const u8, src_ip: [4]u8, dst_ip: [4]u8, reply_buf: []u8) ?usize {
    if (seg.flags & FLAG_RST != 0) return null;
    if (seg.flags & FLAG_ACK != 0) return buildRstFor(seg, tcp_data.len - seg.data_offset, src_ip, dst_ip, reply_buf);
    if (seg.flags & FLAG_SYN == 0) return null;

    const lh = connHandle(l);
    var pending: usize = 0;
    for (pool()) |*p| {
        if (p.active and p.listener == lh and !p.accepted) pending += 1;
    }
    if (pending >= l.backlog) return null; // drop; the peer retries

    const c = allocConn() orelse return null;
    c.reset();
    c.active = true;
    c.state = .syn_received;
    c.listener = lh;
    c.local_ip = dst_ip;
    c.local_port = l.local_port;
    c.remote_ip = src_ip;
    c.remote_port = seg.src_port;
    c.irs = seg.seq;
    c.rcv_nxt = seg.seq +% 1;
    const peer = parseSynOptions(tcp_data, seg.data_offset);
    c.mss = @min(peer.mss, DEFAULT_MSS);
    if (peer.wscale) |ws| {
        c.snd_wscale = ws;
        c.rcv_wscale = RCV_WSCALE;
    }
    c.sack_ok = peer.sack_ok;
    c.cc = CongestionState.init(c.mss);
    c.iss = generateISN(c);
    c.snd_una = c.iss;
    c.snd_nxt = c.iss +% 1;
    c.snd_max = c.snd_nxt;
    c.snd_wnd = seg.window;
    c.syn_time = clock_us;
    c.rto_deadline = clock_us + c.rto();
    return buildControl(c, FLAG_SYN | FLAG_ACK, c.iss, reply_buf);
}

fn processAck(c: *Connection, seg: *const Segment, payload_len: usize) void {
    const now = clock_us;
    if (seqGt(seg.ack, c.snd_max)) {
        c.ack_now = true; // acks something we never sent
        return;
    }
    if (seqLt(seg.ack, c.snd_una)) return; // old

    const window = @as(u32, seg.window) << @as(u5, @intCast(c.snd_wscale));

    if (seqGt(seg.ack, c.snd_una)) {
        // New data acknowledged.
        var acked: u32 = seg.ack -% c.snd_una;
        c.snd_una = seg.ack;
        if (seqLt(c.snd_nxt, c.snd_una)) c.snd_nxt = c.snd_una;
        const data_acked: u32 = @min(acked, @as(u32, @intCast(c.snd_count)));
        c.snd_head = (c.snd_head + data_acked) % SEND_BUF_SIZE;
        c.snd_count -= data_acked;
        acked = data_acked;
        // Our FIN occupies fin_seq; it is acknowledged once SND.UNA passes it
        // (whether or not a rewind has since cleared fin_sent).
        if (c.fin_seq_set and seqGt(c.snd_una, c.fin_seq)) {
            c.fin_acked = true;
            c.fin_sent = false;
        }

        if (c.rtt_active and seqGt(seg.ack, c.rtt_seq)) {
            c.rtt_active = false;
            c.rtt.update(@intCast(@min(now - c.rtt_start, MAX_RTO_US)));
        }

        if (c.cc.in_recovery) {
            if (seqGeq(seg.ack, c.cc.recovery_point)) {
                c.cc.exitRecovery();
            } else {
                // Partial ACK (RFC 6582): the next hole is lost too.
                c.fast_rexmit = true;
                c.cc.cwnd -|= acked;
                c.cc.cwnd += c.mss;
            }
        } else {
            c.cc.onAck(acked, c.mss);
        }
        c.cc.dup_ack_count = 0;
        c.retries = 0;
        c.rto_deadline = if (c.snd_una == c.snd_max) 0 else now + c.rto();
        c.persist_backoff = 0;
    } else if (payload_len == 0 and seg.flags & FLAG_FIN == 0 and window == c.snd_wnd and c.snd_una != c.snd_max) {
        // Duplicate ACK (RFC 5681 §2).
        c.cc.dup_ack_count +|= 1;
        if (c.cc.dup_ack_count == 3 and !c.cc.in_recovery) {
            c.cc.enterFastRecovery(c.snd_max -% c.snd_una, c.snd_max);
            c.cc.dup_ack_count = 3;
            c.fast_rexmit = true;
            c.rtt_active = false;
        } else if (c.cc.in_recovery) {
            c.cc.onDupAckInRecovery();
        }
    }

    // Window update (RFC 9293 §3.10.7.4).
    if (seqLt(c.snd_wl1, seg.seq) or (c.snd_wl1 == seg.seq and seqLeq(c.snd_wl2, seg.ack))) {
        c.snd_wnd = window;
        c.snd_wl1 = seg.seq;
        c.snd_wl2 = seg.ack;
    }

    // Close-sequence transitions driven by the ACK of our FIN.
    if (c.fin_acked) {
        switch (c.state) {
            .fin_wait_1 => c.state = .fin_wait_2,
            .closing => enterTimeWait(c),
            .last_ack => toClosed(c, .none),
            else => {},
        }
    }
}

fn receive(c: *Connection, seg: *const Segment, payload_in: []const u8) void {
    const now = clock_us;
    var seq = seg.seq;
    var payload = payload_in;
    var fin = seg.flags & FLAG_FIN != 0;

    // Trim the part we already have.
    if (seqLt(seq, c.rcv_nxt)) {
        const dup: u32 = c.rcv_nxt -% seq;
        if (dup >= payload.len) {
            // Only (maybe) a FIN is new.
            if (fin and dup == payload.len) {
                payload = payload[payload.len..];
                seq = c.rcv_nxt;
            } else {
                c.ack_now = true;
                return;
            }
        } else {
            payload = payload[dup..];
            seq = c.rcv_nxt;
        }
    }

    const free = c.rcvFree();
    if (seq == c.rcv_nxt) {
        const take = @min(payload.len, free);
        if (take > 0) {
            ringWrite(&c.recv_buf, (c.rcv_head + c.rcv_count) % RECV_BUF_SIZE, payload[0..take]);
            c.rcv_count += take;
            c.rcv_nxt +%= @intCast(take);
            c.total_recv += take;
        }
        if (take < payload.len) {
            fin = false; // window overflow: the rest (and any FIN) comes again
            c.ack_now = true;
        }
        // Did this close the gap before our out-of-order range?
        if (c.ooo_valid and seqGeq(c.rcv_nxt, c.ooo_start)) {
            if (seqGt(c.ooo_end, c.rcv_nxt)) {
                const extra: u32 = c.ooo_end -% c.rcv_nxt;
                c.rcv_count += extra;
                c.total_recv += extra;
                c.rcv_nxt = c.ooo_end;
            }
            c.ooo_valid = false;
            c.ack_now = true; // RFC 5681 §4.2: ACK at once when a gap fills
        }
        if (fin and !c.ooo_valid) {
            c.rcv_nxt +%= 1;
            c.fin_received = true;
            c.ack_now = true;
            switch (c.state) {
                .established => c.state = .close_wait,
                .fin_wait_1 => if (c.fin_acked) enterTimeWait(c) else {
                    c.state = .closing;
                },
                .fin_wait_2 => enterTimeWait(c),
                else => {},
            }
        } else if (take > 0 and !c.ack_now) {
            c.segs_unacked += 1;
            if (c.segs_unacked >= 2 or seg.flags & FLAG_PSH != 0 and take < c.mss) {
                c.ack_now = true;
            } else if (c.delack_deadline == 0) {
                c.delack_deadline = now + DELAYED_ACK_US;
            }
        }
        return;
    }

    // Out of order: keep it if it fits and extends/starts our one range.
    c.ack_now = true; // duplicate ACK tells the sender about the hole
    if (payload.len == 0) return;
    const off: usize = seq -% c.rcv_nxt;
    if (off + payload.len > free) return;
    const end = seq +% @as(u32, @intCast(payload.len));
    if (c.ooo_valid) {
        const touches = seqLeq(seq, c.ooo_end) and seqGeq(end, c.ooo_start);
        if (!touches) {
            if (seqGt(seq, c.ooo_start)) return; // keep the range nearer RCV.NXT
            c.ooo_valid = false; // new range is nearer: replace
        }
    }
    ringWrite(&c.recv_buf, (c.rcv_head + c.rcv_count + off) % RECV_BUF_SIZE, payload);
    if (!c.ooo_valid) {
        c.ooo_valid = true;
        c.ooo_start = seq;
        c.ooo_end = end;
    } else {
        if (seqLt(seq, c.ooo_start)) c.ooo_start = seq;
        if (seqGt(end, c.ooo_end)) c.ooo_end = end;
    }
}

fn enterTimeWait(c: *Connection) void {
    c.state = .time_wait;
    c.time_wait_deadline = clock_us + TIME_WAIT_US;
    c.rto_deadline = 0;
}

fn inWindow(c: *const Connection, seq: u32) bool {
    const wnd: u32 = @max(@as(u32, @intCast(c.rcvFree())), 1);
    return seqBetween(c.rcv_nxt, seq, c.rcv_nxt +% wnd);
}

// ══════════════════════════════════════════════════════════════════════════════
// Segment building
// ══════════════════════════════════════════════════════════════════════════════

fn advertisedWindow(c: *const Connection) u32 {
    const free: u32 = @intCast(c.rcvFree());
    const field: u32 = @min(free >> @as(u5, @intCast(c.rcv_wscale)), 0xFFFF);
    return field << @as(u5, @intCast(c.rcv_wscale));
}

fn windowField(c: *Connection, syn: bool) u16 {
    const free: u32 = @intCast(c.rcvFree());
    if (syn) return @intCast(@min(free, 0xFFFF));
    const field: u32 = @min(free >> @as(u5, @intCast(c.rcv_wscale)), 0xFFFF);
    const edge = c.rcv_nxt +% (field << @as(u5, @intCast(c.rcv_wscale)));
    if (seqGt(edge, c.rcv_adv) or c.rcv_adv == 0) c.rcv_adv = edge;
    return @intCast(field);
}

/// Every segment that carries our ACK satisfies pending/delayed ACKs.
fn ackSent(c: *Connection) void {
    c.ack_now = false;
    c.delack_deadline = 0;
    c.segs_unacked = 0;
}

fn buildAck(c: *Connection, buf: []u8) ?usize {
    ackSent(c);
    var opts = OptionsBuffer{};
    if (c.sack_ok and c.ooo_valid) {
        opts.put(&.{ OPT_NOP, OPT_NOP, OPT_SACK, 10 });
        opts.put32(c.ooo_start);
        opts.put32(c.ooo_end);
    }
    return buildRawSegment(c.local_ip, c.remote_ip, c.local_port, c.remote_port, c.snd_nxt, c.rcv_nxt, FLAG_ACK, windowField(c, false), opts.slice(), &.{}, &.{}, buf);
}

fn buildControl(c: *Connection, flags: u8, seq: u32, buf: []u8) ?usize {
    const syn = flags & FLAG_SYN != 0;
    var opts = OptionsBuffer{};
    if (syn) {
        opts.put(&.{ OPT_MSS, 4, @intCast(DEFAULT_MSS >> 8), @intCast(DEFAULT_MSS & 0xFF) });
        // Offer scaling on an active open; on a passive open echo it only if
        // the peer offered (rcv_wscale was set from its SYN).
        if (c.state == .syn_sent or c.rcv_wscale != 0) opts.put(&.{ OPT_NOP, OPT_WINDOW_SCALE, 3, RCV_WSCALE });
        if (c.state == .syn_sent or c.sack_ok) opts.put(&.{ OPT_NOP, OPT_NOP, OPT_SACK_PERMITTED, 2 });
    }
    if (flags & FLAG_ACK != 0) ackSent(c);
    const ack = if (flags & FLAG_ACK != 0) c.rcv_nxt else 0;
    return buildRawSegment(c.local_ip, c.remote_ip, c.local_port, c.remote_port, seq, ack, flags, windowField(c, syn), opts.slice(), &.{}, &.{}, buf);
}

/// A data segment of `len` bytes starting at sequence number `seq`, copied
/// out of the send ring (which may wrap: up to two slices).
fn buildData(c: *Connection, seq: u32, len: u32, push: bool, buf: []u8) ?usize {
    const off: usize = seq -% c.snd_una;
    const start = (c.snd_head + off) % SEND_BUF_SIZE;
    const first = @min(@as(usize, len), SEND_BUF_SIZE - start);
    const a = c.send_buf[start..][0..first];
    const b = c.send_buf[0 .. @as(usize, len) - first];
    ackSent(c);
    const flags: u8 = FLAG_ACK | (if (push) FLAG_PSH else 0);
    return buildRawSegment(c.local_ip, c.remote_ip, c.local_port, c.remote_port, seq, c.rcv_nxt, flags, windowField(c, false), &.{}, a, b, buf);
}

fn buildRetransmit(c: *Connection, buf: []u8) ?usize {
    if (c.snd_una == c.snd_max) return null;
    c.retransmits += 1;
    c.rtt_active = false;
    if (c.rto_deadline == 0) c.rto_deadline = clock_us + c.rto();
    const outstanding_data: u32 = @min(c.snd_max -% c.snd_una, @as(u32, @intCast(c.snd_count)));
    if (outstanding_data > 0) {
        const len = @min(outstanding_data, @as(u32, c.mss));
        return buildData(c, c.snd_una, len, false, buf);
    }
    if (c.fin_seq_set and !c.fin_acked) return buildControl(c, FLAG_FIN | FLAG_ACK, c.fin_seq, buf);
    return null;
}

fn buildProbe(c: *Connection, buf: []u8) ?usize {
    if (c.snd_count == 0) return null;
    // One byte at SND.UNA; if the receiver takes it, it ACKs SND.UNA+1.
    if (seqLt(c.snd_max, c.snd_una +% 1)) c.snd_max = c.snd_una +% 1;
    return buildData(c, c.snd_una, 1, false, buf);
}

fn buildRstFor(seg: *const Segment, payload_len: usize, src_ip: [4]u8, dst_ip: [4]u8, buf: []u8) ?usize {
    // RFC 9293 §3.10.7.1: reply from the segment's destination.
    if (seg.flags & FLAG_ACK != 0) {
        return buildRawSegment(dst_ip, src_ip, seg.dst_port, seg.src_port, seg.ack, 0, FLAG_RST, 0, &.{}, &.{}, &.{}, buf);
    }
    var seg_len: u32 = @intCast(payload_len);
    if (seg.flags & FLAG_SYN != 0) seg_len += 1;
    if (seg.flags & FLAG_FIN != 0) seg_len += 1;
    return buildRawSegment(dst_ip, src_ip, seg.dst_port, seg.src_port, 0, seg.seq +% seg_len, FLAG_RST | FLAG_ACK, 0, &.{}, &.{}, &.{}, buf);
}

fn buildRawSegment(
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    options: []const u8,
    payload_a: []const u8,
    payload_b: []const u8,
    buf: []u8,
) ?usize {
    const opts_padded = (options.len + 3) & ~@as(usize, 3);
    const hdr_len = HEADER_MIN + opts_padded;
    const tcp_len = hdr_len + payload_a.len + payload_b.len;
    const total_len = ipv4.HEADER_SIZE + tcp_len;
    if (total_len > buf.len or tcp_len > 0xFFFF) return null;

    const t = buf[ipv4.HEADER_SIZE..];
    t[0] = @intCast(src_port >> 8);
    t[1] = @intCast(src_port & 0xFF);
    t[2] = @intCast(dst_port >> 8);
    t[3] = @intCast(dst_port & 0xFF);
    writeBe32(t, 4, seq);
    writeBe32(t, 8, ack);
    t[12] = @intCast((hdr_len / 4) << 4);
    t[13] = flags;
    t[14] = @intCast(window >> 8);
    t[15] = @intCast(window & 0xFF);
    t[16] = 0;
    t[17] = 0;
    t[18] = 0;
    t[19] = 0;
    if (options.len > 0) @memcpy(t[HEADER_MIN..][0..options.len], options);
    var i = HEADER_MIN + options.len;
    while (i < hdr_len) : (i += 1) t[i] = OPT_END;
    @memcpy(t[hdr_len..][0..payload_a.len], payload_a);
    @memcpy(t[hdr_len + payload_a.len ..][0..payload_b.len], payload_b);

    var acc = checksum.pseudoHeaderSum(src_ip, dst_ip, ipv4.PROTO_TCP, @intCast(tcp_len));
    acc = checksum.combine(acc, checksum.sum(t[0..tcp_len]));
    const cksum = checksum.fold(acc);
    t[16] = @intCast(cksum >> 8);
    t[17] = @intCast(cksum & 0xFF);

    _ = ipv4.writeHeader(buf, src_ip, dst_ip, ipv4.PROTO_TCP, @intCast(tcp_len)) orelse return null;
    return total_len;
}

const OptionsBuffer = struct {
    data: [40]u8 = undefined,
    len: usize = 0,

    fn put(self: *OptionsBuffer, bytes: []const u8) void {
        @memcpy(self.data[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn put32(self: *OptionsBuffer, v: u32) void {
        writeBe32(&self.data, self.len, v);
        self.len += 4;
    }
    fn slice(self: *const OptionsBuffer) []const u8 {
        return self.data[0..self.len];
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Parsing
// ══════════════════════════════════════════════════════════════════════════════

const Segment = struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    data_offset: usize, // bytes
    flags: u8,
    window: u16,
};

fn parseHeader(data: []const u8) ?Segment {
    if (data.len < HEADER_MIN) return null;
    const data_offset: usize = @as(usize, data[12] >> 4) * 4;
    if (data_offset < HEADER_MIN or data_offset > data.len) return null;
    return .{
        .src_port = @as(u16, data[0]) << 8 | data[1],
        .dst_port = @as(u16, data[2]) << 8 | data[3],
        .seq = readBe32(data, 4),
        .ack = readBe32(data, 8),
        .data_offset = data_offset,
        .flags = data[13],
        .window = @as(u16, data[14]) << 8 | data[15],
    };
}

const SynOptions = struct { mss: u16 = 536, wscale: ?u8 = null, sack_ok: bool = false };

fn parseSynOptions(tcp_data: []const u8, data_offset: usize) SynOptions {
    var out = SynOptions{};
    const opts = tcp_data[HEADER_MIN..data_offset];
    var i: usize = 0;
    while (i < opts.len) {
        const kind = opts[i];
        if (kind == OPT_END) break;
        if (kind == OPT_NOP) {
            i += 1;
            continue;
        }
        if (i + 1 >= opts.len) break;
        const len: usize = opts[i + 1];
        if (len < 2 or i + len > opts.len) break;
        switch (kind) {
            OPT_MSS => if (len == 4) {
                out.mss = @max(@as(u16, opts[i + 2]) << 8 | opts[i + 3], 536);
            },
            OPT_WINDOW_SCALE => if (len == 3) {
                out.wscale = @min(opts[i + 2], 14);
            },
            OPT_SACK_PERMITTED => out.sack_ok = true,
            else => {},
        }
        i += len;
    }
    return out;
}

fn findConn(local_ip: [4]u8, local_port: u16, remote_ip: [4]u8, remote_port: u16) ?*Connection {
    for (pool()) |*c| {
        if (c.active and c.state != .listen and c.local_port == local_port and
            c.remote_port == remote_port and ipEqual(c.remote_ip, remote_ip) and
            (ipEqual(c.local_ip, local_ip) or ipEqual(c.local_ip, .{ 0, 0, 0, 0 })))
        {
            return c;
        }
    }
    return null;
}

fn findListener(local_port: u16, local_ip: [4]u8) ?*Connection {
    for (pool()) |*c| {
        if (c.active and c.state == .listen and c.local_port == local_port and
            (ipEqual(c.local_ip, local_ip) or ipEqual(c.local_ip, .{ 0, 0, 0, 0 })))
        {
            return c;
        }
    }
    return null;
}

// ══════════════════════════════════════════════════════════════════════════════
// Rings, sequence arithmetic, helpers
// ══════════════════════════════════════════════════════════════════════════════

fn ringWrite(ring: []u8, start: usize, data: []const u8) void {
    const first = @min(data.len, ring.len - start);
    @memcpy(ring[start..][0..first], data[0..first]);
    @memcpy(ring[0 .. data.len - first], data[first..]);
}

fn ringRead(ring: []const u8, start: usize, out: []u8) void {
    const first = @min(out.len, ring.len - start);
    @memcpy(out[0..first], ring[start..][0..first]);
    @memcpy(out[first..], ring[0 .. out.len - first]);
}

/// a < b (modulo 2^32)
pub fn seqLt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

/// a <= b
pub fn seqLeq(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) <= 0;
}

/// a > b
pub fn seqGt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

/// a >= b
pub fn seqGeq(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

/// seq in [low, high) with wraparound.
pub fn seqBetween(low: u32, seq: u32, high: u32) bool {
    return seqGeq(seq, low) and seqLt(seq, high);
}

fn readBe32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) << 24 | @as(u32, data[offset + 1]) << 16 |
        @as(u32, data[offset + 2]) << 8 | data[offset + 3];
}

fn writeBe32(buf: []u8, offset: usize, val: u32) void {
    buf[offset] = @intCast(val >> 24);
    buf[offset + 1] = @intCast((val >> 16) & 0xFF);
    buf[offset + 2] = @intCast((val >> 8) & 0xFF);
    buf[offset + 3] = @intCast(val & 0xFF);
}

fn ipEqual(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests — two endpoints in one pool over a simulated wire
// ══════════════════════════════════════════════════════════════════════════════

const testing = @import("std").testing;

const CLIENT_IP = [4]u8{ 10, 0, 0, 1 };
const SERVER_IP = [4]u8{ 10, 0, 0, 2 };

/// A deterministic lossy link: every packet gets a delivery time; some are
/// dropped, duplicated or delayed (which reorders them).
const Wire = struct {
    const CAP = 4096;
    const Pkt = struct { at: u64, order: u64, len: u16, data: [1600]u8 };
    q: [CAP]Pkt = undefined,
    n: usize = 0,
    rng: u64 = 1,
    drop_pct: u64 = 0,
    dup_pct: u64 = 0,
    reorder_pct: u64 = 0,
    delay_us: u64 = 5_000,
    sent: usize = 0,
    dropped: usize = 0,
    order: u64 = 0,

    fn rand(self: *Wire) u64 {
        self.rng = mix64(self.rng);
        return self.rng;
    }

    fn push(self: *Wire, pkt: []const u8) void {
        self.sent += 1;
        if (self.rand() % 100 < self.drop_pct) {
            self.dropped += 1;
            return;
        }
        var copies: usize = if (self.rand() % 100 < self.dup_pct) 2 else 1;
        while (copies > 0) : (copies -= 1) {
            if (self.n == CAP) return;
            var at = clock_us + self.delay_us;
            if (self.rand() % 100 < self.reorder_pct) at += 1_000 + self.rand() % 20_000;
            self.q[self.n].at = at;
            self.q[self.n].order = self.order;
            self.order += 1;
            self.q[self.n].len = @intCast(pkt.len);
            @memcpy(self.q[self.n].data[0..pkt.len], pkt);
            self.n += 1;
        }
    }

    /// Deliver every packet due by `now` to the stack (earliest first).
    fn deliver(self: *Wire, now: u64) void {
        while (true) {
            var best: ?usize = null;
            for (self.q[0..self.n], 0..) |*p, i| {
                if (p.at > now) continue;
                if (best) |b| {
                    const q = &self.q[b];
                    if (p.at > q.at or (p.at == q.at and p.order > q.order)) continue;
                }
                best = i;
            }
            const i = best orelse return;
            var pkt: [1600]u8 = undefined;
            const len = self.q[i].len;
            @memcpy(pkt[0..len], self.q[i].data[0..len]);
            self.q[i] = self.q[self.n - 1];
            self.n -= 1;
            const src = pkt[12..16].*;
            const dst = pkt[16..20].*;
            var reply: [1600]u8 = undefined;
            if (processSegment(pkt[20..len], src, dst, &reply)) |rlen| self.push(reply[0..rlen]);
        }
    }
};

var wire = Wire{};

fn wireSend(pkt: []const u8) void {
    wire.push(pkt);
}

fn resetPool() void {
    for (pool()) |*c| c.reset();
    clock_us = 1_000_000;
    wire = Wire{};
    t_have_server = false;
}

fn pattern(i: usize, salt: u8) u8 {
    return @truncate((i *% 131) ^ (i >> 7) ^ salt);
}

/// Run the simulation until `done` or the deadline, 1 ms per step.
fn run(ms: usize, pkt_buf: []u8, comptime done: fn () bool) bool {
    var step: usize = 0;
    while (step < ms) : (step += 1) {
        const now = clock_us + 1000;
        tick(now, pkt_buf, wireSend);
        wire.deliver(now);
        if (done()) return true;
    }
    return false;
}

var t_client: u8 = 0;
var t_server: u8 = 0;
var t_listener: u8 = 0;

var t_have_server = false;

fn bothEstablished() bool {
    if (!t_have_server) {
        if (accept(t_listener)) |h| {
            t_server = h;
            t_have_server = true;
        }
    }
    return t_have_server and getState(t_client) == .established and getState(t_server) == .established;
}

fn openPair(pkt_buf: []u8) !void {
    t_listener = listen(SERVER_IP, 443, 4) orelse return error.Pool;
    t_client = connect(CLIENT_IP, SERVER_IP, 443) orelse return error.Pool;
    try testing.expect(run(60_000, pkt_buf, bothEstablished));
}

/// Pump `total` bytes each way through the pair and verify every byte.
fn transfer(total: usize, pkt_buf: []u8, max_ms: usize) !void {
    var c_sent: usize = 0;
    var s_sent: usize = 0;
    var c_got: usize = 0;
    var s_got: usize = 0;
    var chunk: [3000]u8 = undefined;
    var step: usize = 0;
    while (step < max_ms) : (step += 1) {
        // Producers
        while (c_sent < total) {
            var k: usize = 0;
            const want = @min(chunk.len, total - c_sent);
            while (k < want) : (k += 1) chunk[k] = pattern(c_sent + k, 0x5A);
            const n = send(t_client, chunk[0..want]);
            if (n == 0) break;
            c_sent += n;
        }
        while (s_sent < total) {
            var k: usize = 0;
            const want = @min(chunk.len, total - s_sent);
            while (k < want) : (k += 1) chunk[k] = pattern(s_sent + k, 0xA5);
            const n = send(t_server, chunk[0..want]);
            if (n == 0) break;
            s_sent += n;
        }
        const now = clock_us + 1000;
        tick(now, pkt_buf, wireSend);
        wire.deliver(now);
        // Consumers
        while (true) {
            const n = recv(t_server, &chunk);
            if (n == 0) break;
            for (chunk[0..n], 0..) |b, k| if (b != pattern(c_got + k, 0x5A)) return error.Corrupt;
            c_got += n;
        }
        while (true) {
            const n = recv(t_client, &chunk);
            if (n == 0) break;
            for (chunk[0..n], 0..) |b, k| if (b != pattern(s_got + k, 0xA5)) return error.Corrupt;
            s_got += n;
        }
        if (c_got == total and s_got == total) return;
    }
    return error.Stalled;
}

test "tcp: sequence arithmetic wraps" {
    try testing.expect(seqLt(0xFFFFFFFF, 1));
    try testing.expect(seqGt(1, 0xFFFFFFFF));
    try testing.expect(seqBetween(0xFFFFFFF0, 2, 5));
    try testing.expect(!seqBetween(10, 20, 20));
}

test "tcp: handshake, options and a clean transfer" {
    resetPool();
    var pkt: [1600]u8 = undefined;
    try openPair(&pkt);
    const c = &pool()[t_client];
    try testing.expectEqual(@as(u8, RCV_WSCALE), c.snd_wscale);
    try testing.expect(c.sack_ok);
    try testing.expectEqual(DEFAULT_MSS, c.mss);
    try transfer(300_000, &pkt, 20_000);
    try testing.expectEqual(@as(u32, 0), getStats(t_client).retransmits);
}

test "tcp: survives 10% loss, duplication and reordering" {
    resetPool();
    var pkt: [1600]u8 = undefined;
    wire.rng = 0xC0FFEE;
    try openPair(&pkt);
    wire.drop_pct = 10;
    wire.dup_pct = 3;
    wire.reorder_pct = 10;
    try transfer(400_000, &pkt, 600_000);
    try testing.expect(wire.dropped > 0);
    try testing.expect(getStats(t_client).retransmits + getStats(t_server).retransmits > 0);
}

test "tcp: graceful close both ways, FIN after queued data" {
    resetPool();
    var pkt: [1600]u8 = undefined;
    try openPair(&pkt);
    wire.drop_pct = 5;
    wire.rng = 77;
    const msg = "last words";
    try testing.expectEqual(msg.len, send(t_client, msg));
    close(t_client); // FIN must follow the data
    const S = struct {
        fn serverSawEof() bool {
            var b: [32]u8 = undefined;
            const n = recv(t_server, &b);
            if (n > 0) got += n;
            return eof(t_server);
        }
        var got: usize = 0;
    };
    S.got = 0;
    try testing.expect(run(60_000, &pkt, S.serverSawEof));
    try testing.expectEqual(msg.len, S.got);
    try testing.expectEqual(State.close_wait, getState(t_server));
    close(t_server);
    const Done = struct {
        fn bothGone() bool {
            return isClosed(t_server) and (getState(t_client) == .time_wait or isClosed(t_client));
        }
    };
    try testing.expect(run(60_000, &pkt, Done.bothGone));
    // TIME_WAIT expires and frees the client slot.
    const Gone = struct {
        fn clientFreed() bool {
            return !pool()[t_client].active;
        }
    };
    try testing.expect(run(20_000, &pkt, Gone.clientFreed));
}

test "tcp: connection refused and unreachable peer time out" {
    resetPool();
    var pkt: [1600]u8 = undefined;
    // No listener on 444: the SYN draws a RST.
    t_client = connect(CLIENT_IP, SERVER_IP, 444) orelse return error.Pool;
    const R = struct {
        fn closed() bool {
            return isClosed(t_client);
        }
    };
    try testing.expect(run(5_000, &pkt, R.closed));
    try testing.expectEqual(CloseReason.refused, closeReason(t_client));
    abort(t_client);
    // Every packet lost: SYN retries back off, then give up.
    wire.drop_pct = 100;
    t_client = connect(CLIENT_IP, SERVER_IP, 443) orelse return error.Pool;
    try testing.expect(run(200_000, &pkt, R.closed));
    try testing.expectEqual(CloseReason.timeout, closeReason(t_client));
    abort(t_client);
}

test "tcp: zero window stalls then resumes" {
    resetPool();
    var pkt: [1600]u8 = undefined;
    try openPair(&pkt);
    // Fill the server's receive buffer without reading it.
    var buf: [4096]u8 = @splat(0x42);
    var queued: usize = 0;
    var step: usize = 0;
    while (step < 5_000) : (step += 1) {
        queued += send(t_client, &buf);
        tick(clock_us + 1000, &pkt, wireSend);
        wire.deliver(clock_us);
    }
    try testing.expectEqual(RECV_BUF_SIZE, pool()[t_server].rcv_count);
    try testing.expectEqual(@as(u32, 0), pool()[t_client].snd_wnd);
    // Drain it; the window update (or a probe) restarts the flow.
    var drained: usize = 0;
    step = 0;
    while (step < 20_000 and drained < queued) : (step += 1) {
        drained += recv(t_server, &buf);
        tick(clock_us + 1000, &pkt, wireSend);
        wire.deliver(clock_us);
    }
    try testing.expectEqual(queued, drained);
}

test "tcp: congestion control and RTT estimator" {
    var cc = CongestionState.init(1460);
    const iw = cc.cwnd;
    cc.onAck(1460, 1460);
    try testing.expectEqual(iw + 1460, cc.cwnd);
    cc.enterFastRecovery(15000, 50000);
    try testing.expectEqual(@as(u32, 7500), cc.ssthresh);
    try testing.expect(cc.in_recovery);
    cc.onTimeout(1460);
    try testing.expectEqual(@as(u32, 1460), cc.cwnd);

    var rtt = RttState.init();
    rtt.update(20_000);
    try testing.expectEqual(MIN_RTO_US, rtt.rto); // 20 ms RTT → floor
    rtt.update(400_000);
    try testing.expect(rtt.rto > 400_000);
    rtt.rto = 50_000_000;
    rtt.backoff();
    try testing.expectEqual(MAX_RTO_US, rtt.rto);
}

// Carried over from zpm's earlier inline tests (edge values the tests above
// do not pin down).

test "tcp: sequence comparisons are consistent across the wrap" {
    try testing.expect(seqLt(0x80000000, 0x80000001));
    try testing.expect(!seqLt(5, 5));
    try testing.expect(!seqGt(5, 5));
    try testing.expect(seqBetween(10, 10, 20)); // inclusive left
    try testing.expect(seqBetween(0xFFFFFFF0, 0xFFFFFFF5, 0x00000005));
    const vals = [_]u32{ 0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF };
    for (vals) |a| {
        for (vals) |b| {
            if (a == b) {
                try testing.expect(!seqLt(a, b) and !seqGt(a, b));
                try testing.expect(seqLeq(a, b) and seqGeq(a, b));
            } else {
                try testing.expect(seqLt(a, b) != seqGt(a, b)); // exactly one
            }
        }
    }
}

test "tcp: timeout and fast-recovery window arithmetic" {
    var cc = CongestionState.init(1460);
    cc.cwnd = 50000;
    cc.onTimeout(1460);
    try testing.expectEqual(@as(u32, 1460), cc.cwnd);
    try testing.expectEqual(@as(u32, 25000), cc.ssthresh); // cwnd / 2

    cc = CongestionState.init(1460);
    cc.cwnd = 20000;
    cc.enterFastRecovery(15000, 50000);
    try testing.expectEqual(@as(u32, 7500 + 3 * 1460), cc.cwnd); // ssthresh + 3 MSS
    try testing.expectEqual(@as(u32, 50000), cc.recovery_point);

    var rtt = RttState.init();
    rtt.update(100_000);
    try testing.expect(rtt.has_sample);
    try testing.expectEqual(@as(u32, 100_000 << 3), rtt.srtt);
}

test "tcp: a browser's burst of connects fits; the slot after the last is refused" {
    resetPool();
    var handles: [MAX_CONNECTIONS]u8 = undefined;
    for (&handles, 0..) |*h, i| {
        h.* = connect(CLIENT_IP, SERVER_IP, @intCast(443 + (i % 8))) orelse return error.Pool;
        for (handles[0..i]) |o| {
            try testing.expect(o != h.*);
            try testing.expect(localPort(o) != localPort(h.*));
        }
    }
    try testing.expect(MAX_CONNECTIONS >= 128);
    try testing.expect(connect(CLIENT_IP, SERVER_IP, 443) == null);
    abort(handles[17]);
    try testing.expect(connect(CLIENT_IP, SERVER_IP, 443) != null);
    for (handles) |h| abort(h);
}

test "tcp: connect and listen allocate slots; abort frees them" {
    resetPool();
    const h = connect(CLIENT_IP, SERVER_IP, 80) orelse return error.Pool;
    try testing.expectEqual(State.syn_sent, getState(h));
    try testing.expect(localPort(h) >= 49152);
    abort(h);
    try testing.expectEqual(State.closed, getState(h));
    try testing.expect(!pool()[h].active);

    const l = listen(.{ 0, 0, 0, 0 }, 8080, 5) orelse return error.Pool;
    try testing.expectEqual(State.listen, getState(l));
    try testing.expect(accept(l) == null);
    abort(l);
    try testing.expectEqual(State.closed, getState(l));
}
