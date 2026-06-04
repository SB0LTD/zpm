// CRYPTO stream reassembly module (RFC 9000 §19.6)
//
// Production-grade out-of-order reassembly for QUIC CRYPTO frames.
// Extracted from conn.sig inline implementation and upgraded:
//   - 16KB buffer (handles large Certificate messages and post-quantum ClientHellos)
//   - 32-entry range set (handles heavily fragmented streams)
//   - Zero allocation (all fixed-size embedded arrays)
//
// Design follows Google quiche QuicStreamSequencerBuffer and Go net/quic
// cryptoStream patterns: flat buffer for random-write at any offset, sorted
// interval range set for tracking received bytes, contiguous frontier for
// determining deliverable data.

pub const buf_size: u16 = 16384; // 16KB — large Certificate + post-quantum ClientHello
pub const max_ranges: u8 = 32;  // handles heavily fragmented streams

pub const Range = struct {
    start: u16 = 0,
    end: u16 = 0, // [start, end) exclusive
};

pub const ReceiveResult = enum(u8) {
    ok,        // fragment accepted
    duplicate, // already received (ignore)
    overflow,  // exceeds buffer capacity
};

pub const CryptoStream = struct {
    buf: [buf_size]u8,
    ranges: [max_ranges]Range,
    range_count: u8,
    read_offset: u64, // total bytes already delivered (for multi-message)

    /// Initialize a new empty CryptoStream.
    pub fn init() CryptoStream {
        return .{
            .buf = @as([buf_size]u8, @splat(0)),
            .ranges = @as([max_ranges]Range, @splat(Range{})),
            .range_count = 0,
            .read_offset = 0,
        };
    }

    /// Receive a CRYPTO fragment at the given absolute offset.
    /// Data is placed into the reassembly buffer relative to read_offset.
    /// Returns .ok if accepted, .duplicate if already covered, .overflow if it
    /// would exceed buffer capacity.
    pub fn receive(self: *CryptoStream, offset: u64, data: []const u8) ReceiveResult {
        if (data.len == 0) return .ok;

        // Compute buffer-relative position
        // If offset < read_offset, part or all of this fragment is already consumed.
        if (offset + data.len <= self.read_offset) return .duplicate;

        // Trim already-consumed prefix if the fragment partially overlaps read_offset
        var effective_data = data;
        var effective_offset = offset;
        if (effective_offset < self.read_offset) {
            const skip: usize = @intCast(self.read_offset - effective_offset);
            effective_data = data[skip..];
            effective_offset = self.read_offset;
        }

        // Buffer-relative start and end
        const buf_start_u64 = effective_offset - self.read_offset;
        const buf_end_u64 = buf_start_u64 + effective_data.len;

        // Overflow check
        if (buf_end_u64 > buf_size) return .overflow;

        const buf_start: u16 = @intCast(buf_start_u64);
        const buf_end: u16 = @intCast(buf_end_u64);

        // Check for full duplicate (entire range already covered by existing ranges)
        if (self.isFullyCovered(buf_start, buf_end)) return .duplicate;

        // Copy fragment data into buffer at the correct position
        @memcpy(self.buf[buf_start..buf_end], effective_data);

        // Insert [buf_start, buf_end) into the sorted range set with merge
        self.insertRange(buf_start, buf_end);

        return .ok;
    }

    /// Returns how many contiguous bytes are available from the front of the buffer.
    /// This is the "contiguous frontier" — bytes that can be delivered in order.
    pub fn readable(self: *const CryptoStream) u16 {
        if (self.range_count == 0) return 0;
        if (self.ranges[0].start == 0) return self.ranges[0].end;
        return 0;
    }

    /// Copy up to out.len readable bytes into `out`. Does not advance the read pointer.
    /// Returns the number of bytes actually copied.
    pub fn read(self: *const CryptoStream, out: []u8) u16 {
        const avail = self.readable();
        const copy_len: u16 = @intCast(@min(avail, @as(u16, @intCast(@min(out.len, buf_size)))));
        if (copy_len > 0) {
            @memcpy(out[0..copy_len], self.buf[0..copy_len]);
        }
        return copy_len;
    }

    /// Advance the read pointer by `amount` bytes:
    /// 1. Shifts buffer contents left by amount
    /// 2. Adjusts all ranges (subtract amount, remove fully-consumed ranges)
    /// 3. Updates read_offset += amount
    pub fn consume(self: *CryptoStream, amount: u16) void {
        if (amount == 0) return;

        const avail = self.readable();
        // Clamp to what's actually readable to prevent corruption
        const consume_amt: u16 = @min(amount, avail);
        if (consume_amt == 0) return;

        // Shift buffer contents left
        const remaining: u16 = buf_size - consume_amt;
        if (remaining > 0) {
            // Use a forward copy since src > dst (no overlap issue for left shift)
            var i: u16 = 0;
            while (i < remaining) : (i += 1) {
                self.buf[i] = self.buf[i + consume_amt];
            }
        }
        // Zero out the vacated tail (optional but clean for security)
        var j: u16 = remaining;
        while (j < buf_size) : (j += 1) {
            self.buf[j] = 0;
        }

        // Adjust ranges: subtract consume_amt, remove fully-consumed ranges
        var write: u8 = 0;
        var rd: u8 = 0;
        while (rd < self.range_count) : (rd += 1) {
            if (self.ranges[rd].end <= consume_amt) {
                // Range fully consumed — skip it
                continue;
            }
            self.ranges[write] = .{
                .start = if (self.ranges[rd].start >= consume_amt) self.ranges[rd].start - consume_amt else 0,
                .end = self.ranges[rd].end - consume_amt,
            };
            write += 1;
        }
        self.range_count = write;

        // Advance read_offset
        self.read_offset += consume_amt;
    }

    // ── Internal: Range set management ──

    /// Insert [start, end) into the sorted range set, merging overlapping/adjacent ranges.
    /// This is the core of the reassembly algorithm (same pattern as quiche/quinn).
    fn insertRange(self: *CryptoStream, start: u16, end_val: u16) void {
        const count = self.range_count;

        // Find insertion point (ranges are sorted by start)
        var insert_at: u8 = count;
        {
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (start <= self.ranges[i].end) {
                    insert_at = i;
                    break;
                }
            }
        }

        // Determine merge bounds
        var new_start = start;
        var new_end = end_val;
        var merge_start: u8 = insert_at;
        var merge_end: u8 = insert_at;

        // Extend left: merge with previous range if adjacent/overlapping
        if (insert_at > 0 and self.ranges[insert_at - 1].end >= start) {
            merge_start = insert_at - 1;
            new_start = @min(new_start, self.ranges[merge_start].start);
            new_end = @max(new_end, self.ranges[merge_start].end);
        }

        // Extend right: merge with subsequent ranges if overlapping/adjacent
        merge_end = merge_start;
        {
            var i: u8 = merge_start;
            while (i < count) : (i += 1) {
                if (self.ranges[i].start > new_end) break;
                new_end = @max(new_end, self.ranges[i].end);
                merge_end = i + 1;
            }
        }

        // Replace ranges[merge_start..merge_end] with single merged range
        self.ranges[merge_start] = .{ .start = new_start, .end = new_end };

        // Calculate how many ranges were consumed by merge
        const merged_count = merge_end - merge_start;
        if (merged_count > 1) {
            // Shift remaining ranges down to fill gap
            const removed = merged_count - 1;
            var j: u8 = merge_start + 1;
            while (j + removed < count) : (j += 1) {
                self.ranges[j] = self.ranges[j + removed];
            }
            self.range_count = count - removed;
        } else if (merge_end == merge_start) {
            // No existing range was merged — this is a brand new insertion
            if (count >= max_ranges) return; // range set full, drop fragment tracking

            // Shift ranges right to make room at insert_at
            if (count > 0) {
                var k: u8 = count;
                while (k > insert_at) : (k -= 1) {
                    self.ranges[k] = self.ranges[k - 1];
                }
            }
            self.ranges[insert_at] = .{ .start = new_start, .end = new_end };
            self.range_count = count + 1;
        }
        // else: merged_count == 1 means we overwrote exactly one existing range in place
    }

    /// Check if the range [start, end) is fully covered by existing ranges.
    fn isFullyCovered(self: *const CryptoStream, start: u16, end_val: u16) bool {
        var i: u8 = 0;
        while (i < self.range_count) : (i += 1) {
            if (self.ranges[i].start <= start and self.ranges[i].end >= end_val) {
                return true;
            }
        }
        return false;
    }
};
