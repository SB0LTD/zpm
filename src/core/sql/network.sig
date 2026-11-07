//! Network address types (Layer 0), after network.c, inet_net_pton.c,
//! inet_cidr_ntop.c and mac.c: inet, cidr and macaddr.
//!
//! inet/cidr values hold the family (IPv4 or IPv6), the netmask length and
//! 16 address bytes; `cidr` marks a cidr value, which prints its netmask
//! length always, while inet omits a full-length one. cidr input must
//! have no bits set right of the mask (22P02), and abbreviated IPv4
//! networks take the classful default length. Ordering is network_cmp:
//! IPv4 before IPv6, then the common prefix, then the netmask length, then
//! the whole address; inet and cidr values compare alike.
//! macaddr holds six bytes, accepts the seven formats of macaddr_in and
//! prints lower-case colon-separated hex; it compares bytewise.
const types = @import("types.sig");
const Error = types.Error;

pub const Inet = struct {
    /// 4 or 6.
    family: u8 = 4,
    bits: u8 = 32,
    cidr: bool = false,
    address: [16]u8 = @splat(0),

    pub fn maxBits(self: *const Inet) u8 {
        return if (self.family == 4) 32 else 128;
    }

    fn size(self: *const Inet) usize {
        return if (self.family == 4) 4 else 16;
    }
};

pub const Mac = [6]u8;

fn digitValue(c: u8) ?u8 {
    return if (c >= '0' and c <= '9') c - '0' else null;
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// inet_net_pton_ipv4 (inet) and inet_cidr_pton_ipv4 (cidr, decimal form).
fn parseIpv4(input: []const u8, cidr: bool, out: *Inet) Error!void {
    var at: usize = 0;
    var octets: usize = 0;
    while (true) {
        if (at == input.len or digitValue(input[at]) == null) return error.InvalidTextRepresentation;
        var value: u32 = 0;
        while (at < input.len and digitValue(input[at]) != null) : (at += 1) {
            value = value * 10 + input[at] - '0';
            if (value > 255) return error.InvalidTextRepresentation;
        }
        if (octets == 4) return error.InvalidTextRepresentation;
        out.address[octets] = @intCast(value);
        octets += 1;
        if (at == input.len or input[at] == '/') break;
        if (input[at] != '.') return error.InvalidTextRepresentation;
        at += 1;
    }
    var bits: i32 = -1;
    if (at < input.len) {
        at += 1;
        if (at == input.len) return error.InvalidTextRepresentation;
        bits = 0;
        while (at < input.len) : (at += 1) {
            const digit = digitValue(input[at]) orelse return error.InvalidTextRepresentation;
            bits = bits * 10 + digit;
            if (bits > 32) return error.InvalidTextRepresentation;
        }
    }
    const written: i32 = @intCast(octets * 8);
    if (bits == -1) {
        if (!cidr) {
            if (octets != 4) return error.InvalidTextRepresentation;
            bits = 32;
        } else {
            // The classful default width, widened to the given octets.
            const first = out.address[0];
            bits = if (first >= 240) 32 else if (first >= 224) 8 else if (first >= 192) 24 else if (first >= 128) 16 else 8;
            if (bits < written) bits = written;
            if (bits == 8 and first == 224) bits = 4;
        }
    } else if (!cidr and @divTrunc(bits, 8) > @as(i32, @intCast(octets))) return error.InvalidTextRepresentation;
    out.family = 4;
    out.bits = @intCast(bits);
}

/// inet_net_pton_ipv6 / inet_cidr_pton_ipv6: hex groups with one `::`, an
/// optional trailing dotted IPv4 part and an optional /bits (0..128).
fn parseIpv6(input: []const u8, out: *Inet) Error!void {
    var text = input;
    var bits: i32 = 128;
    if (std_index(text, '/')) |slash| {
        const suffix = text[slash + 1 ..];
        if (suffix.len == 0 or suffix.len > 3) return error.InvalidTextRepresentation;
        bits = 0;
        for (suffix) |c| bits = bits * 10 + (digitValue(c) orelse return error.InvalidTextRepresentation);
        if (bits > 128) return error.InvalidTextRepresentation;
        text = text[0..slash];
    }
    var words: [8]u16 = @splat(0);
    var count: usize = 0;
    var gap: ?usize = null;
    var at: usize = 0;
    if (text.len >= 2 and text[0] == ':' and text[1] == ':') {
        gap = 0;
        at = 2;
    } else if (text.len != 0 and text[0] == ':') return error.InvalidTextRepresentation;
    while (at < text.len) {
        // An embedded IPv4 address ends the text.
        var dotted = false;
        var scan = at;
        while (scan < text.len and text[scan] != ':') : (scan += 1) if (text[scan] == '.') {
            dotted = true;
        };
        if (dotted) {
            if (scan != text.len or count > 6) return error.InvalidTextRepresentation;
            var v4: Inet = .{};
            try parseIpv4(text[at..], false, &v4);
            if (v4.bits != 32) return error.InvalidTextRepresentation;
            words[count] = @as(u16, v4.address[0]) << 8 | v4.address[1];
            words[count + 1] = @as(u16, v4.address[2]) << 8 | v4.address[3];
            count += 2;
            at = text.len;
            break;
        }
        var value: u32 = 0;
        var digits: usize = 0;
        while (at < text.len and text[at] != ':') : (at += 1) {
            value = value * 16 + (hexValue(text[at]) orelse return error.InvalidTextRepresentation);
            digits += 1;
            if (digits > 4) return error.InvalidTextRepresentation;
        }
        if (digits == 0 or count == 8) return error.InvalidTextRepresentation;
        words[count] = @intCast(value);
        count += 1;
        if (at == text.len) break;
        at += 1;
        if (at < text.len and text[at] == ':') {
            if (gap != null) return error.InvalidTextRepresentation;
            gap = count;
            at += 1;
        } else if (at == text.len) return error.InvalidTextRepresentation;
    }
    var full: [8]u16 = @splat(0);
    if (gap) |position| {
        if (count > 7) return error.InvalidTextRepresentation;
        for (0..position) |index| full[index] = words[index];
        const tail = count - position;
        for (0..tail) |index| full[8 - tail + index] = words[position + index];
    } else {
        if (count != 8) return error.InvalidTextRepresentation;
        full = words;
    }
    for (full, 0..) |word, index| {
        out.address[index * 2] = @intCast(word >> 8);
        out.address[index * 2 + 1] = @truncate(word);
    }
    out.family = 6;
    out.bits = @intCast(bits);
}

fn std_index(text: []const u8, byte: u8) ?usize {
    for (text, 0..) |c, index| if (c == byte) return index;
    return null;
}

/// addressOK: no bits set right of the mask.
pub fn maskClean(value: *const Inet) bool {
    var bit: usize = value.bits;
    while (bit < @as(usize, value.size()) * 8) : (bit += 1) {
        if (value.address[bit / 8] & (@as(u8, 0x80) >> @intCast(bit % 8)) != 0) return false;
    }
    return true;
}

/// network_in for inet (`cidr` false) or cidr.
pub fn parse(input: []const u8, cidr: bool) Error!Inet {
    var out: Inet = .{ .cidr = cidr };
    if (std_index(input, ':') != null) try parseIpv6(input, &out) else try parseIpv4(input, cidr, &out);
    if (cidr and !maskClean(&out)) return error.InvalidTextRepresentation;
    return out;
}

const Out = struct {
    buffer: []u8,
    len: usize = 0,
    fn byte(self: *Out, c: u8) void {
        self.buffer[self.len] = c;
        self.len += 1;
    }
    fn decimal(self: *Out, value: u32) void {
        var digits: [10]u8 = undefined;
        var index: usize = digits.len;
        var rest = value;
        while (true) {
            index -= 1;
            digits[index] = @intCast('0' + rest % 10);
            rest /= 10;
            if (rest == 0) break;
        }
        for (digits[index..]) |c| self.byte(c);
    }
    fn hex(self: *Out, value: u16) void {
        const alphabet = "0123456789abcdef";
        var started = false;
        for (0..4) |index| {
            const shift: u4 = @intCast(12 - index * 4);
            const nibble: u4 = @truncate(value >> shift);
            if (nibble != 0 or started or index == 3) {
                self.byte(alphabet[nibble]);
                started = true;
            }
        }
    }
};

fn ipv4Text(out: *Out, bytes: []const u8) void {
    for (bytes[0..4], 0..) |octet, index| {
        if (index != 0) out.byte('.');
        out.decimal(octet);
    }
}

/// The address with or without its netmask length (at most 49 bytes).
/// `masked`: always print /bits (cidr output, text(inet)); otherwise only
/// when it is not the full length (inet output).
pub fn format(value: *const Inet, masked: bool, buffer: []u8) []const u8 {
    var out: Out = .{ .buffer = buffer };
    if (value.family == 4) {
        ipv4Text(&out, &value.address);
    } else {
        var words: [8]u16 = undefined;
        for (0..8) |index| words[index] = @as(u16, value.address[index * 2]) << 8 | value.address[index * 2 + 1];
        // The longest run (two or more) of zero words becomes `::`.
        var best_base: ?usize = null;
        var best_len: usize = 0;
        var index: usize = 0;
        while (index < 8) {
            if (words[index] != 0) {
                index += 1;
                continue;
            }
            var end = index;
            while (end < 8 and words[end] == 0) end += 1;
            if (end - index >= 2 and end - index > best_len) {
                best_base = index;
                best_len = end - index;
            }
            index = end;
        }
        index = 0;
        while (index < 8) {
            if (best_base) |base| if (index >= base and index < base + best_len) {
                if (index == base) out.byte(':');
                index += 1;
                continue;
            };
            if (index != 0) out.byte(':');
            // An encapsulated IPv4 address (::a.b.c.d or ::ffff:a.b.c.d).
            if (index == 6 and best_base == @as(?usize, 0) and (best_len == 6 or (best_len == 5 and words[5] == 0xffff))) {
                ipv4Text(&out, value.address[12..16]);
                break;
            }
            out.hex(words[index]);
            index += 1;
        }
        if (best_base) |base| if (base + best_len == 8) out.byte(':');
    }
    if (masked or value.bits != value.maxBits()) {
        out.byte('/');
        out.decimal(value.bits);
    }
    return buffer[0..out.len];
}

/// bitncmp over the first `bits` bits.
fn prefixOrder(a: []const u8, b: []const u8, bits: usize) i8 {
    const whole = bits / 8;
    for (0..whole) |index| if (a[index] != b[index]) return if (a[index] < b[index]) -1 else 1;
    const rest = bits % 8;
    if (rest != 0) {
        const mask: u8 = @truncate(@as(u16, 0xff00) >> @intCast(rest));
        const x = a[whole] & mask;
        const y = b[whole] & mask;
        if (x != y) return if (x < y) -1 else 1;
    }
    return 0;
}

/// network_cmp_internal.
pub fn compare(a: *const Inet, b: *const Inet) i8 {
    if (a.family != b.family) return if (a.family < b.family) -1 else 1;
    const order = prefixOrder(&a.address, &b.address, @min(a.bits, b.bits));
    if (order != 0) return order;
    if (a.bits != b.bits) return if (a.bits < b.bits) -1 else 1;
    return prefixOrder(&a.address, &b.address, a.maxBits());
}

/// << (strictly within), <<= (within or equal) and && (either contains).
pub fn within(a: *const Inet, b: *const Inet, or_equal: bool) bool {
    if (a.family != b.family) return false;
    if (if (or_equal) a.bits < b.bits else a.bits <= b.bits) return false;
    return prefixOrder(&a.address, &b.address, b.bits) == 0;
}

pub fn overlaps(a: *const Inet, b: *const Inet) bool {
    if (a.family != b.family) return false;
    return prefixOrder(&a.address, &b.address, @min(a.bits, b.bits)) == 0;
}

/// network(): the address with the host bits cleared, as cidr.
pub fn network(value: *const Inet) Inet {
    var out = value.*;
    out.cidr = true;
    var bit: usize = value.bits;
    while (bit < @as(usize, value.size()) * 8) : (bit += 1) out.address[bit / 8] &= ~(@as(u8, 0x80) >> @intCast(bit % 8));
    return out;
}

/// broadcast(): the host bits set (inet, same netmask length).
pub fn broadcast(value: *const Inet) Inet {
    var out = value.*;
    out.cidr = false;
    var bit: usize = value.bits;
    while (bit < @as(usize, value.size()) * 8) : (bit += 1) out.address[bit / 8] |= @as(u8, 0x80) >> @intCast(bit % 8);
    return out;
}

/// netmask(): the mask as an inet with the full length.
pub fn netmask(value: *const Inet) Inet {
    var out: Inet = .{ .family = value.family, .bits = value.maxBits() };
    for (0..value.bits) |bit| out.address[bit / 8] |= @as(u8, 0x80) >> @intCast(bit % 8);
    return out;
}

// ---- macaddr -------------------------------------------------------------------

fn space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// macaddr_in: xx:xx:xx:xx:xx:xx, xx-xx-xx-xx-xx-xx, xxxxxx:xxxxxx,
/// xxxxxx-xxxxxx, xxxx.xxxx.xxxx, xxxx-xxxx-xxxx and xxxxxxxxxxxx.
pub fn parseMac(input: []const u8) Error!Mac {
    var text = input;
    while (text.len != 0 and space(text[0])) text = text[1..];
    while (text.len != 0 and space(text[text.len - 1])) text = text[0 .. text.len - 1];
    // Group widths in hex digits for each accepted layout.
    const layouts = [_]struct { widths: []const u8, separator: u8 }{
        .{ .widths = &.{ 2, 2, 2, 2, 2, 2 }, .separator = ':' },
        .{ .widths = &.{ 2, 2, 2, 2, 2, 2 }, .separator = '-' },
        .{ .widths = &.{ 6, 6 }, .separator = ':' },
        .{ .widths = &.{ 6, 6 }, .separator = '-' },
        .{ .widths = &.{ 4, 4, 4 }, .separator = '.' },
        .{ .widths = &.{ 4, 4, 4 }, .separator = '-' },
        .{ .widths = &.{12}, .separator = 0 },
    };
    for (layouts) |layout| {
        var digits: [12]u8 = undefined;
        var count: usize = 0;
        var at: usize = 0;
        var ok = true;
        for (layout.widths, 0..) |width, group| {
            if (group != 0) {
                if (at == text.len or text[at] != layout.separator) {
                    ok = false;
                    break;
                }
                at += 1;
            }
            if (text.len - at < width) {
                ok = false;
                break;
            }
            for (text[at..][0..width]) |c| {
                digits[count] = hexValue(c) orelse {
                    ok = false;
                    break;
                };
                count += 1;
            }
            if (!ok) break;
            at += width;
        }
        if (!ok or at != text.len or count != 12) continue;
        var out: Mac = undefined;
        for (0..6) |index| out[index] = digits[index * 2] << 4 | digits[index * 2 + 1];
        return out;
    }
    return error.InvalidTextRepresentation;
}

pub fn formatMac(value: *const Mac, buffer: []u8) []const u8 {
    const alphabet = "0123456789abcdef";
    var at: usize = 0;
    for (value, 0..) |byte, index| {
        if (index != 0) {
            buffer[at] = ':';
            at += 1;
        }
        buffer[at] = alphabet[byte >> 4];
        buffer[at + 1] = alphabet[byte & 15];
        at += 2;
    }
    return buffer[0..at];
}
