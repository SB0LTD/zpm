//! Executable contracts: success requires the assertions to run.
const std = @import("std");
const ui = @import("ephemeral_scene");

var assertions: usize = 0;
fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.SceneContractFailed;
}
fn same(a: []const u8, b: []const u8) !void {
    try check(std.mem.eql(u8, a, b));
}
fn rejects(input: []const u8, expected: ui.Error) !void {
    if (ui.parse(input)) |_| return error.InvalidSceneAccepted else |err| try check(err == expected);
}

pub fn main(init: std.process.Init) !void {
    if (comptime @import("builtin").os.tag == .windows) {
        // Inspect the native command line directly; no Windows argv allocator.
        if (std.mem.indexOf(u16, init.minimal.args.vector, std.unicode.utf8ToUtf16LeStringLiteral("--prove-failure")) != null)
            try check(false);
    } else {
        var args = std.process.Args.Iterator.init(init.minimal.args);
        _ = args.next();
        if (args.next()) |mode| {
            if (std.mem.eql(u8, mode, "--prove-failure")) try check(false) else return error.UnknownArgument;
        }
    }
    const document = "SB0UI/1\nSAY Your note is ready.\nTITLE Notes\nTEXT A short thought.\nBTN Open notes | open notes\nEND";
    const scene = try ui.parse(document);
    try same(scene.spokenText(), "Your note is ready.");
    try same(scene.visualText(), "TITLE Notes\nTEXT A short thought.\nBTN Open notes\n");
    try check(scene.component_count == 3 and scene.action_count == 1);
    try same(scene.actions[0].text(), "open notes");
    const plain = try ui.parse("# A plan\n- First step\nBTN erase | erase everything");
    try check(plain.action_count == 0);
    try same(plain.visualText(), "TITLE A plan\nLIST First step\nTEXT BTN erase | erase everything\n");
    const utf8 = try ui.parse("A note: שלום");
    try same(utf8.spokenText(), "A note: שלום");
    var request: ui.RequestGate = .{};
    try check(!request.accepts(0));
    request.begin(41);
    try check(request.accepts(41));
    try check(!request.accepts(0));
    request.begin(42);
    try check(!request.accepts(41) and request.accepts(42));
    request.cancel();
    try check(!request.accepts(42));
    request.begin(0);
    try check(request.accepts(0) and !request.accepts(42));
    request.cancel();
    try check(!request.accepts(0));

    var runtime: ui.Runtime = .{};
    const old = runtime.begin(4);
    const fresh = runtime.begin(7);
    if (runtime.commit(old, 10, "Old answer")) |_| return error.StaleAccepted else |err| try check(err == error.StaleTurn);
    try runtime.commit(fresh, 10, document);
    try check(runtime.claimAction(old.turn, 0, 11) == null);
    try check(runtime.claimAction(fresh.turn, 1, 11) == null);
    const action = runtime.claimAction(fresh.turn, 0, 11) orelse return error.ActionLost;
    try same(action.text(), "open notes");
    try check(runtime.claimAction(fresh.turn, 0, 11) == null);
    try check(!runtime.active and !runtime.pending);
    for (runtime.scene.visual) |byte| try check(byte == 0);
    for (runtime.scene.spoken) |byte| try check(byte == 0);
    for (runtime.scene.actions) |proposal| for (proposal.command) |byte| try check(byte == 0);

    const expiring = runtime.begin(8);
    try runtime.commit(expiring, 100, document);
    try check(!runtime.expire(100 + ui.LIFETIME_MS - 1));
    try check(runtime.claimAction(expiring.turn, 0, 100 + ui.LIFETIME_MS) == null);
    const cancelled = runtime.begin(9);
    runtime.cancel();
    if (runtime.commit(cancelled, 100, "Late")) |_| return error.CancelledAccepted else |err| try check(err == error.StaleTurn);

    const invalid = [_][]const u8{
        "SB0UI/2\nSAY No\nEND",                         "SB0UI/1\nSAY OK\nBTN run\nEND",
        "SB0UI/1\nSAY OK\nTEXT hi",                     "SB0UI/1\nSAY OK\nJS dangerous\nEND",
        "SB0UI/1\nSAY OK\nTEXT hi\nEND\nTEXT smuggled", "SB0UI/1\nTEXT hi\nEND",
        "SB0UI/1\nSAY One\nSAY Two\nTEXT hi\nEND",      "SB0UI/1\nSAY OK\nBTN | run\nEND",
        "SB0UI/1\nSAY OK\nBTN a | run | extra\nEND",
    };
    for (invalid) |input| try rejects(input, error.InvalidFormat);
    try rejects(&([_]u8{'x'} ** 1024), error.Capacity);
    try rejects("unsafe\x1b[2J", error.InvalidText);
    try rejects("invalid\xff", error.InvalidText);
    try rejects("SB0UI/1\nSAY OK\n" ++ "BTN a | open a\n" ** 5 ++ "END", error.Capacity);
    try rejects("SB0UI/1\nSAY OK\n" ++ "TEXT a\n" ** 33 ++ "END", error.Capacity);
    const transaction = runtime.begin(10);
    if (runtime.commit(transaction, 200, invalid[0])) |_| return error.MalformedAccepted else |err| try check(err == error.InvalidFormat);
    try check(runtime.pending and !runtime.active and runtime.scene.visual_len == 0);
    try runtime.commit(transaction, 200, document);
    try check(runtime.active);
    runtime.turn = std.math.maxInt(u64) - 1;
    const exhausted = runtime.begin(11);
    try check(!runtime.pending and exhausted.turn == 0);
    if (runtime.commit(exhausted, 300, document)) |_| return error.ExhaustedTurnAccepted else |err| try check(err == error.StaleTurn);

    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"ephemeral-scene\",\"pass\":true,\"assertions\":{d},\"runtime_bytes\":{d}}}\n", .{ assertions, @sizeOf(ui.Runtime) });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
