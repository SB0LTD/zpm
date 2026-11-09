const std = @import("std");

pub const OUTPUT = 0x92E0;
pub const SYNCHRONOUS = 0x8242;
pub const ANY = 0x1100;
pub const API = 0x8246;
pub const THIRD_PARTY = 0x8249;
pub const APPLICATION = 0x824A;
pub const ERROR = 0x824C;
pub const HIGH = 0x9146;
pub const NOTIFICATION = 0x826B;
pub const MAX_TEXT = 256;
pub const MAX_MESSAGES = 32;
pub const MAX_GROUP_DEPTH = 64;
pub const MAX_LABEL_LENGTH = 256;

pub const Label = struct {
    len: u8 = 0,
    bytes: [MAX_LABEL_LENGTH - 1]u8 = undefined,

    pub fn set(l: *Label, text: []const u8) void {
        l.len = @intCast(text.len);
        @memcpy(l.bytes[0..text.len], text);
    }

    pub fn get(l: *const Label, size: i32, length: ?*i32, text: ?[*]u8) void {
        var n: usize = l.len;
        if (text) |p| {
            n = @min(n, @as(usize, @intCast(@max(size - 1, 0))));
            if (size > 0) {
                @memcpy(p[0..n], l.bytes[0..n]);
                p[n] = 0;
            }
        }
        if (length) |out| out.* = @intCast(n);
    }
};
pub const Callback = *const fn (u32, u32, u32, u32, i32, [*:0]const u8, ?*const anyopaque) callconv(.c) void;

pub fn source(v: u32) bool {
    return v >= 0x8246 and v <= 0x824B;
}

pub fn msgType(v: u32) bool {
    return (v >= 0x824C and v <= 0x8251) or (v >= 0x8268 and v <= 0x826A);
}

pub fn severity(v: u32) bool {
    return (v >= 0x9146 and v <= 0x9148) or v == NOTIFICATION;
}

const Rule = struct {
    source: u32,
    kind: u32,
    severity: u32,
    id: ?u32 = null,
    enabled: bool,
};

const Message = struct {
    source: u32,
    kind: u32,
    id: u32,
    severity: u32,
    len: usize,
    text: [MAX_TEXT]u8,
};

const Group = struct {
    source: u32,
    id: u32,
    rules_len: usize,
    len: usize,
    label: [MAX_TEXT]u8,
};

pub const Output = struct {
    enabled: bool = false,
    synchronous: bool = false,
    callback: ?Callback = null,
    user: ?*const anyopaque = null,
    in_callback: bool = false,
    rules: [64]Rule = undefined,
    rules_len: usize = 0,
    groups: [MAX_GROUP_DEPTH - 1]Group = undefined,
    group_len: usize = 0,
    messages: [MAX_MESSAGES]Message = undefined,
    head: usize = 0,
    len: usize = 0,

    pub fn control(d: *Output, src: u32, kind: u32, sev: u32, ids: []const u32, on: bool) bool {
        if (@max(ids.len, 1) > d.rules.len - d.rules_len) return false;
        if (ids.len == 0) {
            d.rules[d.rules_len] = .{ .source = src, .kind = kind, .severity = sev, .enabled = on };
            d.rules_len += 1;
        } else {
            for (ids) |id| {
                d.rules[d.rules_len] = .{ .source = src, .kind = kind, .severity = sev, .id = id, .enabled = on };
                d.rules_len += 1;
            }
        }
        return true;
    }

    pub fn emit(d: *Output, src: u32, kind: u32, id: u32, sev: u32, text: []const u8) void {
        if (!d.enabled or d.in_callback) return;
        var on = sev != 0x9148;
        var i = d.rules_len;
        while (i != 0) {
            i -= 1;
            const r = d.rules[i];
            if ((r.source == ANY or r.source == src) and (r.kind == ANY or r.kind == kind) and
                (r.severity == ANY or r.severity == sev) and (r.id == null or r.id.? == id))
            {
                on = r.enabled;
                break;
            }
        }
        if (!on) return;
        var message: Message = .{
            .source = src, .kind = kind, .id = id, .severity = sev,
            .len = @min(text.len, MAX_TEXT - 1), .text = undefined,
        };
        @memcpy(message.text[0..message.len], text[0..message.len]);
        message.text[message.len] = 0;
        if (d.callback) |cb| {
            d.in_callback = true;
            defer d.in_callback = false;
            cb(src, kind, id, sev, @intCast(message.len), @ptrCast(&message.text), d.user);
        } else if (d.len < MAX_MESSAGES) {
            d.messages[(d.head + d.len) % MAX_MESSAGES] = message;
            d.len += 1;
        }
    }

    pub fn push(d: *Output, src: u32, id: u32, text: []const u8) bool {
        if (d.group_len == d.groups.len) return false;
        const group = &d.groups[d.group_len];
        group.* = .{ .source = src, .id = id, .rules_len = d.rules_len, .len = text.len, .label = undefined };
        @memcpy(group.label[0..text.len], text);
        d.group_len += 1;
        d.emit(src, 0x8269, id, NOTIFICATION, text);
        return true;
    }

    pub fn pop(d: *Output) bool {
        if (d.group_len == 0) return false;
        d.group_len -= 1;
        const group = d.groups[d.group_len];
        d.rules_len = group.rules_len;
        d.emit(group.source, 0x826A, group.id, NOTIFICATION, group.label[0..group.len]);
        return true;
    }

    pub fn nextLength(d: *const Output) usize {
        return if (d.len == 0) 0 else d.messages[d.head].len + 1;
    }

    pub fn read(d: *Output, count: usize, bytes: usize, sources: ?[*]u32, types: ?[*]u32, ids: ?[*]u32, severities: ?[*]u32, lengths: ?[*]i32, text: ?[*]u8) u32 {
        var n: usize = 0;
        var at: usize = 0;
        while (n < count and d.len > 0) : (n += 1) {
            const m = &d.messages[d.head];
            const size = m.len + 1;
            if (text) |p| {
                if (size > bytes - at) break;
                @memcpy(p[at..][0..size], m.text[0..size]);
                at += size;
            }
            if (sources) |p| p[n] = m.source;
            if (types) |p| p[n] = m.kind;
            if (ids) |p| p[n] = m.id;
            if (severities) |p| p[n] = m.severity;
            if (lengths) |p| p[n] = @intCast(size);
            d.head = (d.head + 1) % MAX_MESSAGES;
            d.len -= 1;
        }
        return @intCast(n);
    }
};
