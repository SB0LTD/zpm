//! A bounded presentation transaction derived from one cognition result.
//! No rendering or actions execute here. Commands remain proposals until the
//! compositor claims a current button and submits it to the kernel arbiter.
const mem = @import("sig_mem");
const text_utils = @import("sig_text");
const testing = @import("sig_testing");

pub const MAX_BYTES = 1023;
pub const MAX_ACTIONS = 4;
pub const MAX_COMPONENTS = 32;
pub const LIFETIME_MS: u64 = 120_000;
pub const Error = error{ StaleTurn, Empty, Capacity, InvalidFormat, InvalidText };
pub const Lease = struct { turn: u64, now_epoch: u64 };
/// The exchange may deliver a cancellation result after a replacement request.
/// A zero ID is reserved for the explicit diagnostic transport, and only
/// matches another zero ID while that transport's request is active.
pub const RequestGate = struct {
    id: u64 = 0,
    active: bool = false,
    pub fn begin(self: *RequestGate, id: u64) void {
        self.* = .{ .id = id, .active = true };
    }
    pub fn cancel(self: *RequestGate) void {
        self.* = .{};
    }
    pub fn accepts(self: RequestGate, id: u64) bool {
        return self.active and self.id == id;
    }
};
pub const Action = struct {
    label: [64]u8 = @splat(0),
    label_len: u8 = 0,
    command: [128]u8 = @splat(0),
    command_len: u8 = 0,
    pub fn text(self: *const Action) []const u8 {
        return self.command[0..self.command_len];
    }
};

pub const Scene = struct {
    visual: [MAX_BYTES]u8 = @splat(0),
    visual_len: u16 = 0,
    spoken: [MAX_BYTES]u8 = @splat(0),
    spoken_len: u16 = 0,
    actions: [MAX_ACTIONS]Action = @splat(.{}),
    action_count: u8 = 0,
    component_count: u8 = 0,

    pub fn visualText(self: *const Scene) []const u8 {
        return self.visual[0..self.visual_len];
    }
    pub fn spokenText(self: *const Scene) []const u8 {
        return self.spoken[0..self.spoken_len];
    }

    fn append(self: *Scene, tag: []const u8, body: []const u8) Error!void {
        if (self.component_count == MAX_COMPONENTS or self.visual_len + tag.len + body.len + 2 > MAX_BYTES)
            return error.Capacity;
        const start: usize = self.visual_len;
        @memcpy(self.visual[start..][0..tag.len], tag);
        self.visual[start + tag.len] = ' ';
        @memcpy(self.visual[start + tag.len + 1 ..][0..body.len], body);
        self.visual[start + tag.len + body.len + 1] = '\n';
        self.visual_len += @intCast(tag.len + body.len + 2);
        self.component_count += 1;
    }
};

pub const Runtime = struct {
    turn: u64 = 0,
    now_epoch: u64 = 0,
    pending: bool = false,
    active: bool = false,
    expires_ms: u64 = 0,
    scene: Scene = .{},

    pub fn begin(self: *Runtime, now_epoch: u64) Lease {
        self.cancel();
        if (self.turn == ~@as(u64, 0)) return .{ .turn = 0, .now_epoch = 0 };
        self.now_epoch = now_epoch;
        self.pending = true;
        return .{ .turn = self.turn, .now_epoch = now_epoch };
    }

    pub fn commit(self: *Runtime, lease: Lease, now_ms: u64, response: []const u8) Error!void {
        if (!self.pending or lease.turn != self.turn or lease.now_epoch != self.now_epoch)
            return error.StaleTurn;
        const candidate = try parse(response);
        self.scene = candidate;
        self.pending = false;
        self.active = true;
        self.expires_ms = now_ms +| LIFETIME_MS;
    }

    /// Erase retained display text and executable proposals on every boundary.
    pub fn cancel(self: *Runtime) void {
        self.scene = .{};
        self.active = false;
        self.pending = false;
        self.expires_ms = 0;
        self.now_epoch = 0;
        self.turn +|= 1;
    }

    pub fn expire(self: *Runtime, now_ms: u64) bool {
        if (!self.active or now_ms < self.expires_ms) return false;
        self.cancel();
        return true;
    }

    /// Return a value, then invalidate all buttons before any external action.
    /// Old hit rectangles and double-clicks can never replay a command.
    pub fn claimAction(self: *Runtime, turn: u64, index: usize, now_ms: u64) ?Action {
        _ = self.expire(now_ms);
        if (!self.active or turn != self.turn or index >= self.scene.action_count) return null;
        const action = self.scene.actions[index];
        self.cancel();
        return action;
    }
};

pub fn parse(response: []const u8) Error!Scene {
    const source = text_utils.trim(response, " \r\n\t");
    if (source.len == 0) return error.Empty;
    if (source.len > 8192) return error.Capacity;
    if (!text_utils.utf8ValidateSlice(source)) return error.InvalidText;
    for (source) |byte| if ((byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') or byte == 0x7f)
        return error.InvalidText;

    var result: Scene = .{};
    var lines = text_utils.splitScalar(source, '\n');
    const first = text_utils.trim(lines.next().?, " \r\t");
    const structured = mem.eql(u8, first, "SB0UI/1");
    if (!structured) {
        if (mem.startsWith(u8, first, "SB0UI/")) return error.InvalidFormat;
        if (source.len > MAX_BYTES) return error.Capacity;
        @memcpy(result.spoken[0..source.len], source);
        result.spoken_len = @intCast(source.len);
        lines.reset();
        while (lines.next()) |raw| {
            const line = text_utils.trim(raw, " \r\t");
            if (line.len == 0) continue;
            if (mem.startsWith(u8, line, "# ")) {
                try result.append("TITLE", line[2..]);
            } else if (mem.startsWith(u8, line, "## ")) {
                try result.append("TITLE", line[3..]);
            } else if (mem.startsWith(u8, line, "- ") or mem.startsWith(u8, line, "* ")) {
                try result.append("LIST", line[2..]);
            } else {
                // A prose line beginning BTN or another DSL tag stays text.
                try result.append("TEXT", line);
            }
        }
        return result;
    }

    var ended = false;
    while (lines.next()) |raw| {
        const line = text_utils.trim(raw, " \r\t");
        if (line.len == 0) continue;
        if (ended) return error.InvalidFormat;
        if (mem.eql(u8, line, "END")) {
            ended = true;
            continue;
        }
        const space = mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidFormat;
        const tag = line[0..space];
        const body = text_utils.trim(line[space + 1 ..], " \t");
        if (body.len == 0) return error.InvalidFormat;
        if (mem.eql(u8, tag, "SAY")) {
            if (result.spoken_len != 0) return error.InvalidFormat;
            if (body.len > MAX_BYTES) return error.Capacity;
            @memcpy(result.spoken[0..body.len], body);
            result.spoken_len = @intCast(body.len);
        } else if (mem.eql(u8, tag, "BTN")) {
            if (result.action_count == MAX_ACTIONS) return error.Capacity;
            const separator = mem.indexOfScalar(u8, body, '|') orelse return error.InvalidFormat;
            const label = text_utils.trim(body[0..separator], " \t");
            const command = text_utils.trim(body[separator + 1 ..], " \t");
            if (label.len == 0 or command.len == 0) return error.InvalidFormat;
            if (label.len > 64 or command.len > 128) return error.Capacity;
            if (mem.indexOfScalar(u8, command, '|') != null) return error.InvalidFormat;
            const action = &result.actions[result.action_count];
            @memcpy(action.label[0..label.len], label);
            action.label_len = @intCast(label.len);
            @memcpy(action.command[0..command.len], command);
            action.command_len = @intCast(command.len);
            result.action_count += 1;
            try result.append("BTN", label);
        } else {
            var known = false;
            inline for (.{ "TITLE", "TEXT", "ROW", "STAT", "PICK", "LIST" }) |allowed|
                if (mem.eql(u8, tag, allowed)) {
                    known = true;
                };
            if (!known) return error.InvalidFormat;
            try result.append(tag, body);
        }
    }
    if (!ended or result.spoken_len == 0 or result.component_count == 0) return error.InvalidFormat;
    return result;
}

test "one model result produces native components and separate speech" {
    const scene = try parse("SB0UI/1\nSAY Your note is ready.\nTITLE Notes\nTEXT A short thought.\nBTN Open notes | open notes\nEND");
    try testing.expectEqualSlices(u8, "Your note is ready.", scene.spokenText());
    try testing.expectEqualSlices(u8, "TITLE Notes\nTEXT A short thought.\nBTN Open notes\n", scene.visualText());
    try testing.expectEqualSlices(u8, "open notes", scene.actions[0].text());
}

test "ordinary prose and Markdown do not grant actions" {
    const scene = try parse("# A plan\n- First step\nBTN erase | erase everything");
    try testing.expectEqual(@as(u8, 0), scene.action_count);
    try testing.expectEqualSlices(u8, "TITLE A plan\nLIST First step\nTEXT BTN erase | erase everything\n", scene.visualText());
}

test "supersession rejects stale results and buttons and erases content" {
    var runtime: Runtime = .{};
    const old = runtime.begin(4);
    const current = runtime.begin(7);
    try testing.expectError(error.StaleTurn, runtime.commit(old, 10, "Old answer"));
    try runtime.commit(current, 10, "SB0UI/1\nSAY Ready.\nBTN Open | open notes\nEND");
    try testing.expect(runtime.claimAction(old.turn, 0, 11) == null);
    const selected = runtime.claimAction(current.turn, 0, 11).?;
    try testing.expectEqualSlices(u8, "open notes", selected.text());
    try testing.expect(runtime.claimAction(current.turn, 0, 11) == null);
    for (runtime.scene.visual) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (runtime.scene.actions) |action| for (action.command) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "expiry rejects clicks at deadline and cancels pending completion" {
    var runtime: Runtime = .{};
    const lease = runtime.begin(1);
    try runtime.commit(lease, 100, "SB0UI/1\nSAY Ready.\nBTN Open | open notes\nEND");
    try testing.expect(!runtime.expire(100 + LIFETIME_MS - 1));
    try testing.expect(runtime.claimAction(lease.turn, 0, 100 + LIFETIME_MS) == null);
    const pending = runtime.begin(2);
    runtime.cancel();
    try testing.expectError(error.StaleTurn, runtime.commit(pending, 200, "Late result"));
}

test "malformed or oversized components fail atomically" {
    const invalid = [_][]const u8{
        "SB0UI/2\nSAY No\nEND",                         "SB0UI/1\nSAY OK\nBTN run\nEND",
        "SB0UI/1\nSAY OK\nTEXT hi",                     "SB0UI/1\nSAY OK\nJS dangerous\nEND",
        "SB0UI/1\nSAY OK\nTEXT hi\nEND\nTEXT smuggled", "SB0UI/1\nTEXT hi\nEND",
        "SB0UI/1\nSAY One\nSAY Two\nTEXT hi\nEND",      "SB0UI/1\nSAY OK\nBTN | run\nEND",
    };
    var runtime: Runtime = .{};
    const lease = runtime.begin(3);
    for (invalid) |input| {
        try testing.expectError(error.InvalidFormat, runtime.commit(lease, 0, input));
        try testing.expect(!runtime.active);
        try testing.expectEqual(@as(u16, 0), runtime.scene.visual_len);
    }
    const huge = [_]u8{'x'} ** 1024;
    try testing.expectError(error.Capacity, parse(&huge));
    try testing.expectError(error.InvalidText, parse("unsafe\x1b[2J"));
    try testing.expectError(error.InvalidText, parse("invalid\xff"));
}
