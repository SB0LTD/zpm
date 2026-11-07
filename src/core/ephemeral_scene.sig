//! A bounded presentation transaction derived from one cognition result.
//! No rendering or actions execute here. Commands remain proposals until the
//! compositor claims a current button and submits it to the kernel arbiter.
//!
//! Buttons come in two kinds. `BTN label | request` sends its request as the
//! owner's words. `ACT label | app_action {json}` is bound to one app action
//! with its arguments: pressed, the kernel runs exactly that action through
//! its policy gate, with no model in between to reinterpret it. `VIEW
//! app:view` embeds a piece an app declares (its manifest's `view=`).
const mem = @import("sig_mem");
const text_utils = @import("sig_text");
const testing = @import("sig_testing");

pub const MAX_BYTES = 1023;
pub const MAX_ACTIONS = 4;
pub const MAX_VIEWS = 4;
pub const MAX_COMPONENTS = 32;
/// A BTN's request; an ACT's action name and arguments together.
pub const MAX_REQUEST = 128;
pub const MAX_BOUND = 255;
pub const MAX_TOOL = 64;
pub const LIFETIME_MS: u64 = 120_000;
/// What a press on an ACT button sends the brain, before its action and
/// arguments. No BTN request may start with it, so words can never pass
/// for a bound action.
pub const ACT_PREFIX = "galaxy-act ";
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
pub const ActionKind = enum(u8) { request, act };

pub const Action = struct {
    label: [64]u8 = @splat(0),
    label_len: u8 = 0,
    /// A BTN's request, or an ACT's "app_action" or "app_action {json}".
    command: [MAX_BOUND]u8 = @splat(0),
    command_len: u8 = 0,
    kind: ActionKind = .request,
    pub fn text(self: *const Action) []const u8 {
        return self.command[0..self.command_len];
    }
    /// An ACT's action name (empty for a BTN).
    pub fn tool(self: *const Action) []const u8 {
        if (self.kind != .act) return "";
        const t = self.text();
        return t[0 .. mem.indexOfScalar(u8, t, ' ') orelse t.len];
    }
    /// An ACT's arguments, a JSON object ("{}" when it has none).
    pub fn args(self: *const Action) []const u8 {
        if (self.kind != .act) return "{}";
        const t = self.text();
        const space = mem.indexOfScalar(u8, t, ' ') orelse return "{}";
        return t[space + 1 ..];
    }
    /// What a press sends the brain: a BTN's request as it is, an ACT's
    /// bound action after ACT_PREFIX (empty when `buf` is too small).
    pub fn request(self: *const Action, buf: []u8) []const u8 {
        if (self.kind == .request) return self.text();
        const n = ACT_PREFIX.len + @as(usize, self.command_len);
        if (n > buf.len) return "";
        @memcpy(buf[0..ACT_PREFIX.len], ACT_PREFIX);
        @memcpy(buf[ACT_PREFIX.len..n], self.text());
        return buf[0..n];
    }
};

/// A VIEW: an app's piece by the app's name and the view's.
pub const View = struct {
    app: [32]u8 = @splat(0),
    app_len: u8 = 0,
    name: [32]u8 = @splat(0),
    name_len: u8 = 0,
    pub fn appName(self: *const View) []const u8 {
        return self.app[0..self.app_len];
    }
    pub fn viewName(self: *const View) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Scene = struct {
    visual: [MAX_BYTES]u8 = @splat(0),
    visual_len: u16 = 0,
    spoken: [MAX_BYTES]u8 = @splat(0),
    spoken_len: u16 = 0,
    actions: [MAX_ACTIONS]Action = @splat(.{}),
    action_count: u8 = 0,
    views: [MAX_VIEWS]View = @splat(.{}),
    view_count: u8 = 0,
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

/// A byte of an action's or a view's name.
fn nameByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// One whole JSON object, by its shape: braces and brackets balanced
/// outside strings, every string closed, nothing after the last brace. Its
/// values are checked again against the action's declared params when the
/// button is pressed.
fn jsonObject(s: []const u8) bool {
    if (s.len < 2 or s[0] != '{') return false;
    // (one bit per open level: set for an object, clear for an array)
    var objects: u64 = 0;
    var depth: u7 = 0;
    var in_string = false;
    var escaped = false;
    for (s, 0..) |c, i| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                if (depth == 64) return false;
                const bit = @as(u64, 1) << @intCast(depth);
                objects = if (c == '{') objects | bit else objects & ~bit;
                depth += 1;
            },
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
                const was_object = objects & (@as(u64, 1) << @intCast(depth)) != 0;
                if (was_object != (c == '}')) return false;
                if (depth == 0 and i + 1 != s.len) return false;
            },
            else => {},
        }
    }
    return depth == 0 and !in_string;
}

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
            if (label.len > 64 or command.len > MAX_REQUEST) return error.Capacity;
            if (mem.indexOfScalar(u8, command, '|') != null) return error.InvalidFormat;
            // (words are words: only an ACT line binds an action)
            if (mem.startsWith(u8, command, ACT_PREFIX)) return error.InvalidFormat;
            const action = &result.actions[result.action_count];
            @memcpy(action.label[0..label.len], label);
            action.label_len = @intCast(label.len);
            @memcpy(action.command[0..command.len], command);
            action.command_len = @intCast(command.len);
            result.action_count += 1;
            try result.append("BTN", label);
        } else if (mem.eql(u8, tag, "ACT")) {
            if (result.action_count == MAX_ACTIONS) return error.Capacity;
            const separator = mem.indexOfScalar(u8, body, '|') orelse return error.InvalidFormat;
            const label = text_utils.trim(body[0..separator], " \t");
            const bound = text_utils.trim(body[separator + 1 ..], " \t");
            if (label.len == 0 or bound.len == 0) return error.InvalidFormat;
            // The action's name (letters, digits, '_'), then its arguments
            // as one JSON object, or nothing.
            var name_len: usize = 0;
            while (name_len < bound.len and nameByte(bound[name_len])) name_len += 1;
            if (name_len == 0) return error.InvalidFormat;
            const args = text_utils.trim(bound[name_len..], " \t");
            if (args.len > 0 and !jsonObject(args)) return error.InvalidFormat;
            if (label.len > 64 or name_len > MAX_TOOL or name_len + 1 + args.len > MAX_BOUND) return error.Capacity;
            const action = &result.actions[result.action_count];
            @memcpy(action.label[0..label.len], label);
            action.label_len = @intCast(label.len);
            @memcpy(action.command[0..name_len], bound[0..name_len]);
            var n = name_len;
            if (args.len > 0) {
                action.command[n] = ' ';
                @memcpy(action.command[n + 1 ..][0..args.len], args);
                n += 1 + args.len;
            }
            action.command_len = @intCast(n);
            action.kind = .act;
            result.action_count += 1;
            try result.append("ACT", label);
        } else if (mem.eql(u8, tag, "VIEW")) {
            if (result.view_count == MAX_VIEWS) return error.Capacity;
            // app:view (an app's name has no ':' or '|'; a view's is a name)
            const colon = mem.indexOfScalar(u8, body, ':') orelse return error.InvalidFormat;
            const app = text_utils.trim(body[0..colon], " \t");
            const name = text_utils.trim(body[colon + 1 ..], " \t");
            if (app.len == 0 or name.len == 0 or mem.indexOfScalar(u8, app, '|') != null) return error.InvalidFormat;
            for (name) |c| if (!nameByte(c)) return error.InvalidFormat;
            if (app.len > 32 or name.len > 32) return error.Capacity;
            const view = &result.views[result.view_count];
            @memcpy(view.app[0..app.len], app);
            view.app_len = @intCast(app.len);
            @memcpy(view.name[0..name.len], name);
            view.name_len = @intCast(name.len);
            result.view_count += 1;
            var vb: [65]u8 = undefined;
            @memcpy(vb[0..app.len], app);
            vb[app.len] = ':';
            @memcpy(vb[app.len + 1 ..][0..name.len], name);
            try result.append("VIEW", vb[0 .. app.len + 1 + name.len]);
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

test "ACT binds a button to an app action and VIEW embeds a piece" {
    const scene = try parse("SB0UI/1\nSAY Here is your music.\nTITLE Music\nVIEW Galaxy Player : now_playing\nACT Play jazz | galaxy_player_play {\"playlist\":\"jazz | blues\"}\nACT Pause | galaxy_player_pause\nBTN Something else | play something calmer\nEND");
    try testing.expectEqual(@as(u8, 3), scene.action_count);
    const play = &scene.actions[0];
    try testing.expect(play.kind == .act);
    try testing.expectEqualSlices(u8, "Play jazz", play.label[0..play.label_len]);
    try testing.expectEqualSlices(u8, "galaxy_player_play", play.tool());
    try testing.expectEqualSlices(u8, "{\"playlist\":\"jazz | blues\"}", play.args());
    try testing.expectEqualSlices(u8, "galaxy_player_pause", scene.actions[1].tool());
    try testing.expectEqualSlices(u8, "{}", scene.actions[1].args());
    // A press sends the bound action after the prefix; a BTN its words.
    var buf: [ACT_PREFIX.len + MAX_BOUND]u8 = undefined;
    try testing.expectEqualSlices(u8, "galaxy-act galaxy_player_pause", scene.actions[1].request(&buf));
    try testing.expectEqualSlices(u8, "play something calmer", scene.actions[2].request(&buf));
    try testing.expect(scene.actions[2].kind == .request);
    try testing.expectEqualSlices(u8, "", scene.actions[2].tool());
    try testing.expectEqual(@as(u8, 1), scene.view_count);
    try testing.expectEqualSlices(u8, "Galaxy Player", scene.views[0].appName());
    try testing.expectEqualSlices(u8, "now_playing", scene.views[0].viewName());
    try testing.expectEqualSlices(u8, "TITLE Music\nVIEW Galaxy Player:now_playing\nACT Play jazz\nACT Pause\nBTN Something else\n", scene.visualText());
}

test "ACT and VIEW reject anything but a name and one JSON object" {
    const invalid = [_][]const u8{
        "SB0UI/1\nSAY OK\nACT Play | \nEND",                          "SB0UI/1\nSAY OK\nACT | galaxy_player_play\nEND",
        "SB0UI/1\nSAY OK\nACT Play | rm -rf /\nEND",                   "SB0UI/1\nSAY OK\nACT Play | notes_add {\"text\":\"x\"\nEND",
        "SB0UI/1\nSAY OK\nACT Play | notes_add {\"text\":\"x\"} {}\nEND", "SB0UI/1\nSAY OK\nACT Play | notes_add [1]\nEND",
        "SB0UI/1\nSAY OK\nACT Play | notes_add {\"a\":[1}]\nEND",       "SB0UI/1\nSAY OK\nACT Play | notes-add\nEND",
        "SB0UI/1\nSAY OK\nVIEW now_playing\nEND",                      "SB0UI/1\nSAY OK\nVIEW Player:now playing\nEND",
        "SB0UI/1\nSAY OK\nVIEW :now_playing\nEND",                     "SB0UI/1\nSAY OK\nBTN Sneak | galaxy-act notes_clear\nEND",
    };
    for (invalid) |input| try testing.expectError(error.InvalidFormat, parse(input));
    const long_args = "SB0UI/1\nSAY OK\nACT Add | notes_add {\"text\":\"" ++ "x" ** 250 ++ "\"}\nEND";
    try testing.expectError(error.Capacity, parse(long_args));
    // In plain prose an ACT line is only text.
    const prose = try parse("ACT Wipe | notes_clear");
    try testing.expectEqual(@as(u8, 0), prose.action_count);
    // A claimed ACT is single use, like a BTN.
    var runtime: Runtime = .{};
    const lease = runtime.begin(1);
    try runtime.commit(lease, 0, "SB0UI/1\nSAY Ready.\nACT Clear | notes_clear\nEND");
    try testing.expectEqualSlices(u8, "notes_clear", runtime.claimAction(lease.turn, 0, 1).?.tool());
    try testing.expect(runtime.claimAction(lease.turn, 0, 1) == null);
}
