const App = @import("ui_app").App;
pub fn main() !void {
    var app: App = .{};
    try app.init("COM9");
    defer app.deinit();
    app.run();
}
