//! Layer 5 desktop lifecycle: device polling, link supervision, input and composition.
const z = @import("zpm_slowwire");
const w32 = @import("win32");
const gl = @import("gl");
const Window = @import("window").Window;
const Font = @import("text").FontAtlas;
const prim = @import("primitives");
const Color = @import("color").Color;
const model_mod = @import("ui_model");
const Model = model_mod.Model;
const widgets = @import("ui_widgets");
const theme = @import("ui_theme");
const context = @import("context_projection");
const p = z.dynamixel2;
const wire = z.link;
const io = z.windows;
extern "user32" fn SetProcessDPIAware() callconv(.c) i32;
var client_width: i32 = 1440;
var client_height: i32 = 900;
var click_pending = false;
var click_x: i32 = 0;
var click_y: i32 = 0;
var close_clicked = false;
fn windowProc(hwnd: w32.HWND, msg: u32, wp: w32.WPARAM, lp: w32.LPARAM) callconv(.c) w32.LRESULT {
    if (msg == w32.WM_SIZE) {
        const bits: u32 = @truncate(@as(usize, @bitCast(lp)));
        client_width = @intCast(bits & 0xffff);
        client_height = @intCast((bits >> 16) & 0xffff);
        return 0;
    }
    if (msg == w32.WM_LBUTTONUP) {
        const bits: u32 = @truncate(@as(usize, @bitCast(lp)));
        click_x = @as(i16, @bitCast(@as(u16, @truncate(bits))));
        click_y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16))));
        click_pending = true;
        return 0;
    }
    if (msg == w32.WM_NCHITTEST) {
        var point: w32.POINT = .{};
        if (w32.GetCursorPos(&point) != 0 and w32.ScreenToClient(hwnd, &point) != 0 and point.y < 50) {
            if (point.x >= client_width - 58) return w32.HTCLIENT;
            return w32.HTCAPTION;
        }
    }
    if (msg == w32.WM_DESTROY) {
        w32.PostQuitMessage(0);
        return 0;
    }
    return w32.DefWindowProcW(hwnd, msg, wp, lp);
}
pub const App = struct {
    window: Window = undefined,
    font: Font = undefined,
    model: Model = .{},
    port: ?io.Handle = null,
    port_name: [16]u8 = @splat(0),
    port_len: u8 = 0,
    receiver: wire.Receiver = .{},
    seq: u16 = 0,
    opened_at: u32 = 0,
    retry_at: u32 = 0,
    sample_at: u32 = 0,
    heartbeat_at: u32 = 0,
    flash_at: u32 = 0,
    blink: bool = false,
    pub fn init(self: *App, port_name: []const u8) !void {
        // Keep OpenGL viewport, hit targets and Win32 client coordinates in the same pixel space.
        _ = SetProcessDPIAware();
        self.port_len = @intCast(@min(port_name.len, self.port_name.len));
        @memcpy(self.port_name[0..self.port_len], port_name[0..self.port_len]);
        try self.model.addSensor(.{ .id = 1, .source = 1, .kind = .digital, .name = name("Onboard LED"), .name_len = 11, .connected = true });
        try self.model.addSensor(.{ .id = 2, .source = 1, .kind = .analog_raw, .name = name("Internal reference"), .name_len = 18, .connected = true });
        try self.model.addSensor(.{ .id = 3, .source = 1, .kind = .capacitive_ticks, .name = name("Wire electrode"), .name_len = 14, .connected = true });
        try self.model.addWidget(.{ .id = 1, .kind = .summary, .source = 1 });
        try self.model.addWidget(.{ .id = 2, .kind = .timeseries, .source = 1, .sensor = 3 });
        try self.model.addWidget(.{ .id = 3, .kind = .metric, .source = 1, .sensor = 2 });
        try self.model.addWidget(.{ .id = 4, .kind = .camera, .source = 0 });
        try self.model.addWidget(.{ .id = 5, .kind = .actuator, .source = 1 });
        try self.model.addWidget(.{ .id = 6, .kind = .events, .source = 0 });
        self.model.pushEvent("SlowWire Studio ready; USB device discovery started", .info, 0);
        self.window = try Window.initWithConfig(w32.L("SlowWire Studio  /  GALAXY DEVICE WORKBENCH"), 1180, 744, &windowProc, 246, null);
        _ = w32.ShowWindow(self.window.hwnd, w32.SW_MAXIMIZE);
        self.font = Font.init(w32.L("Segoe UI"), 22);
        self.model.pushEvent("Single-wire capacitive electrode registered", .success, 0);
        self.model.pushEvent("Sensor and widget registry initialized (32 slots)", .success, 0);
    }
    fn name(comptime value: []const u8) [28]u8 {
        var out: [28]u8 = @splat(0);
        @memcpy(out[0..value.len], value);
        return out;
    }
    pub fn deinit(self: *App) void {
        if (self.port) |port| {
            if (self.model.connected) _ = self.send(port, .stop, "") catch {};
            io.close(port);
        }
        self.font.deinit();
        self.window.deinit();
    }
    fn send(self: *App, port: io.Handle, op: wire.Op, data: []const u8) !wire.Frame {
        self.seq +%= 1;
        var frame: wire.Frame = .{ .seq = self.seq, .op = op, .len = data.len };
        @memcpy(frame.payload[0..data.len], data);
        var encoded: wire.Encoded = .{};
        try wire.encode(&frame, &encoded);
        try io.write(port, encoded.slice());
        const begin = io.now();
        while (io.now() -% begin < 180) {
            var bytes: [64]u8 = undefined;
            const count = try io.read(port, &bytes);
            for (bytes[0..count]) |byte| {
                var reply: wire.Frame = .{};
                if (self.receiver.feed(byte, &reply) and reply.seq == self.seq and @backingInt(reply.op) == (@backingInt(op) | 0x80)) return reply;
            }
            io.sleep(1);
        }
        return error.Timeout;
    }
    fn ok(reply: wire.Frame) bool {
        return reply.len > 0 and reply.payload[0] == 0;
    }
    fn disconnected(self: *App, reason: []const u8) void {
        self.model.connected = false;
        self.model.cap_fresh = false;
        for (self.model.sensors[0..self.model.sensor_count]) |*sensor| {
            if (sensor.id == 3) sensor.fresh = false;
        }
        self.model.pushEvent(reason, .fault, io.now());
        if (self.port) |port| {
            io.close(port);
            self.port = null;
        }
        self.retry_at = io.now() + 2000;
    }
    fn pollDevice(self: *App, now: u32) void {
        if (!self.model.connected) {
            if (self.port == null and now >= self.retry_at) {
                self.port = io.serialBaud(self.port_name[0..self.port_len], 57600) catch null;
                if (self.port) |_| {
                    self.opened_at = now;
                    self.model.pushEvent("USB serial opened; waiting for Nano bootloader reset", .info, now);
                } else {
                    self.model.pushEvent("Waiting for SlowWire device on selected COM port", .warning, now);
                    self.retry_at = now + 2500;
                }
            }
            if (self.port) |port| if (now -% self.opened_at >= 2200) {
                const id = self.send(port, .identify, "") catch {
                    self.disconnected("SlowWire identify timed out; retrying USB link");
                    return;
                };
                if (!ok(id) or id.len != 9 or id.payload[2] != 0x1e or id.payload[3] != 0x95 or id.payload[4] != 0x0f or (p.get16(id.payload[5..7]) & 4) == 0 or id.payload[7] != 0) {
                    self.disconnected("Nano firmware missing capacitive sensor capability or expected board profile");
                    return;
                }
                self.model.connected = true;
                self.model.axes = id.payload[7];
                self.model.identity_len = 21;
                @memcpy(self.model.identity[0..21], "ATmega328P  /  SIG FW");
                self.model.pushEvent("ATmega328P identified; motor axes: 0", .success, now);
                self.sample_at = 0;
                self.heartbeat_at = 0;
            };
            return;
        }
        const port = self.port orelse return;
        if (now -% self.heartbeat_at >= 180) {
            const beat = self.send(port, .heartbeat, "") catch {
                self.disconnected("Heartbeat lost; reconnecting safely");
                return;
            };
            if (!ok(beat)) {
                self.disconnected("Controller rejected heartbeat");
                return;
            }
            self.heartbeat_at = now;
        }
        if (now -% self.sample_at >= 250) {
            const reply = self.send(port, .telemetry, "") catch {
                self.disconnected("Telemetry link lost");
                return;
            };
            if (!ok(reply) or reply.len != 16) {
                self.disconnected("Invalid telemetry frame");
                return;
            }
            const before = self.model.bad_crc;
            const faults = p.get32(reply.payload[12..16]);
            if (faults > before) self.model.pushEvent("Rejected malformed or corrupt device frame", .warning, now);
            self.model.revision = p.get32(reply.payload[1..5]);
            self.model.uptime_ms = p.get32(reply.payload[5..9]);
            self.model.led = reply.payload[9] == 1;
            self.model.adc_raw = p.get16(reply.payload[10..12]);
            self.model.bad_crc = faults;
            self.model.last_update = now;
            const cap = self.send(port, .capacitive_read, &.{0}) catch {
                self.model.cap_fresh = false;
                self.disconnected("Capacitive electrode read timed out");
                return;
            };
            if (!ok(cap) or cap.len != 6 or cap.payload[1] != 0 or cap.payload[2] != 1) {
                self.model.cap_fresh = false;
                self.disconnected("Nano returned an invalid capacitive sample");
                return;
            }
            self.model.cap_status = cap.payload[3];
            self.model.cap_ticks = p.get16(cap.payload[4..6]);
            self.model.cap_fresh = self.model.cap_status == 3;
            self.model.cap_sampled_ms = now;
            for (self.model.sensors[0..self.model.sensor_count]) |*sensor| {
                if (sensor.id == 3) {
                    sensor.value.raw = self.model.cap_ticks;
                    sensor.value.unit = @splat(0);
                    @memcpy(sensor.value.unit[0..5], "ticks");
                    sensor.value.unit_len = 5;
                    sensor.fresh = self.model.cap_fresh;
                    sensor.sampled_ms = now;
                    sensor.revision +%= 1;
                }
            }
            self.model.pushSample(self.model.cap_ticks);
            self.sample_at = now;
        }
    }
    fn toggle(self: *App, value: bool) void {
        if (!self.model.connected) {
            self.model.pushEvent("Connect a Nano before sending a control command", .warning, io.now());
            return;
        }
        const port = self.port orelse return;
        const revision: u64 = self.model.revision;
        const now: u64 = io.now();
        const refs = [_]context.Stamp{
            .{ .reference = .{ .source = 1, .revision = 1 }, .origin = .policy },
            .{ .reference = .{ .source = 2, .revision = revision }, .origin = .observation },
            .{ .reference = .{ .source = 3, .revision = 1 }, .origin = .owner },
            .{ .reference = .{ .source = 4, .revision = 1 }, .origin = .hypothesis },
        };
        const candidates = [_]context.Candidate{
            .{ .id = 1, .reference = refs[0].reference, .origin = .policy, .required = true, .full = "Only diagnostic LED enabled; zero motor axes", .relevance = 65535 },
            .{ .id = 2, .reference = refs[1].reference, .origin = .observation, .required = true, .expires = now + 250, .full = "Fresh CRC verified controller telemetry", .relevance = 65535 },
            .{ .id = 3, .reference = refs[2].reference, .origin = .owner, .required = true, .deps = .{ refs[0].reference, refs[1].reference, .{}, .{} }, .dep_count = 2, .full = if (value) "LED=1" else "LED=0", .relevance = 65535 },
            .{ .id = 4, .reference = refs[3].reference, .origin = .hypothesis, .full = "Arm motors", .relevance = 65535 },
        };
        var decisions: [4]context.Decision = undefined;
        var order: [4]usize = undefined;
        _ = context.compile(&candidates, &refs, .{ .now = now }, .{ .bytes = 256, .units = 256 }, .{}, &decisions, &order) catch {
            self.model.pushEvent("Adaptive context withheld command; state is stale", .fault, io.now());
            return;
        };
        if (decisions[2].form != .full or decisions[3].form != .omitted) {
            self.model.pushEvent("Adaptive context withheld unsafe command", .fault, io.now());
            return;
        }
        const applied = self.send(port, .board_io, &.{@intFromBool(value)}) catch {
            self.disconnected("Command transport failed");
            return;
        };
        if (!ok(applied)) {
            self.model.pushEvent("Controller rejected output command", .fault, io.now());
            return;
        }
        self.sample_at = 0;
        self.model.pushEvent(if (value) "LED output set high through adaptive context" else "LED output set low through adaptive context", .success, io.now());
    }
    fn click(self: *App, x: f32, y: f32) void {
        const width: f32 = @floatFromInt(client_width);
        const main_x: f32 = 274;
        if (x >= width - 58 and y < 50) {
            close_clicked = true;
            return;
        }
        const control_top = @max(475, @as(f32, @floatFromInt(client_height)) - 236);
        if (x >= main_x + 18 and x < main_x + 160 and y >= control_top + 30 and y < control_top + 84) {
            self.toggle(!self.model.led);
        } else if (x >= main_x + 166 and x < main_x + 304 and y >= control_top + 30 and y < control_top + 84) {
            self.toggle(false);
        } else if (x >= 24 and x < 250 and y >= 214 and y < 254 and !self.model.connected) {
            self.retry_at = 0;
            self.model.pushEvent("Manual USB reconnect requested", .info, io.now());
        }
    }
    pub fn run(self: *App) void {
        while (self.window.running and !close_clicked) {
            self.window.pollEvents();
            if (!self.window.running or close_clicked) break;
            const now = io.now();
            self.pollDevice(now);
            if (click_pending) {
                const x: f32 = @floatFromInt(click_x);
                const y: f32 = @floatFromInt(click_y);
                click_pending = false;
                self.click(x, y);
            }
            gl.glClearColor(0.015, 0.022, 0.046, 1);
            gl.glClear(gl.COLOR_BUFFER_BIT);
            const width = @max(client_width, 900);
            const height = @max(client_height, 620);
            gl.setupOrtho2D(client_width, client_height);
            gl.enableBlending();
            self.draw(@floatFromInt(width), @floatFromInt(height), now);
            self.window.swap();
            io.sleep(12);
        }
    }
    fn draw(self: *App, width: f32, height: f32, now: u32) void {
        const font = &self.font;
        const main_x: f32 = 274;
        const right_w: f32 = 292;
        const right_x = width - right_w - 24;
        const main_w = @max(390, right_x - main_x - 18);
        const cap_top = @max(596, height - 102);
        const chart_h = @max(240, cap_top - 361);
        const control_top = cap_top - 134;
        prim.gradientRect(0, height - 54, width, 54, theme.ink, theme.glass);
        prim.gradientRect(0, height - 3, width, 3, theme.cyan.withAlpha(0.16), theme.violet.withAlpha(0.85));
        widgets.text(font, height, "SLOWWIRE", 25, 17, 0.83, theme.text);
        widgets.text(font, height, "GALAXY DEVICE WORKBENCH", 118, 19, 0.60, theme.muted);
        widgets.text(font, height, "USB CONTROL  /  SENSORS  /  STREAMS", width * 0.5 - 127, 20, 0.59, theme.faint);
        widgets.pill(font, height, if (self.model.connected) "LIVE" else "SEARCHING", width - 244, 14, 94, if (self.model.connected) theme.mint else theme.amber);
        widgets.text(font, height, self.port_name[0..self.port_len], width - 136, 21, 0.64, theme.text);
        // Device and extensible sensor rail.
        widgets.panel(22, 76, 232, height - 144, height, theme.cyan);
        widgets.text(font, height, "DEVICE", 38, 94, 0.66, theme.muted);
        widgets.text(font, height, "NANO  /  ATMEGA328P", 38, 120, 0.71, theme.text);
        widgets.dot(42, 158, 4, height, if (self.model.connected) theme.mint else theme.amber);
        widgets.text(font, height, if (self.model.connected) "CONNECTED" else "WAITING FOR USB", 56, 150, 0.65, if (self.model.connected) theme.mint else theme.amber);
        widgets.text(font, height, "SW v1  ·  57600 8N1", 38, 178, 0.59, theme.faint);
        widgets.panel(32, 207, 212, 54, height, theme.cyan);
        widgets.text(font, height, if (self.model.connected) "RECONNECT" else "SCAN / RETRY USB", 47, 225, 0.64, theme.cyan);
        widgets.text(font, height, "DEVICE INPUTS", 38, 289, 0.64, theme.muted);
        widgets.dot(42, 328, 3, height, theme.mint);
        widgets.text(font, height, "Onboard LED", 56, 317, 0.69, theme.text);
        widgets.text(font, height, if (self.model.led) "HIGH" else "LOW", 180, 318, 0.59, if (self.model.led) theme.mint else theme.faint);
        widgets.dot(42, 363, 3, height, theme.cyan);
        widgets.text(font, height, "Wire electrode", 56, 352, 0.69, theme.text);
        widgets.text(font, height, "CAP", 180, 353, 0.59, theme.faint);
        prim.line(38, height - 391, 236, height - 391, 1, theme.stroke);
        widgets.text(font, height, "DISCOVERABLE TYPES", 38, 421, 0.58, theme.muted);
        widgets.pill(font, height, "CAMERA  ·  READY TO ADD", 36, 447, 181, theme.violet);
        widgets.pill(font, height, "SERVO  ·  NOT ATTACHED", 36, 480, 181, theme.amber);
        widgets.pill(font, height, "I2C / SPI / GPIO", 36, 513, 181, theme.cyan);
        widgets.text(font, height, "32 FIXED SENSOR SLOTS", 38, 563, 0.57, theme.faint);
        // Main live dashboard.
        widgets.text(font, height, "DEVICE TELEMETRY", main_x + 2, 79, 0.67, theme.muted);
        const metric_w = (main_w - 36) / 4;
        const uptime_value = self.model.uptime_ms / 1000;
        const uptime_text = numberText(uptime_value);
        const crc_text = numberText(self.model.bad_crc);
        if (self.model.hasWidget(.metric)) {
            widgets.metric(font, height, main_x, 105, metric_w, "BOARD", if (self.model.connected) "328P" else "--", "SIG", theme.cyan);
            widgets.metric(font, height, main_x + metric_w + 12, 105, metric_w, "UPTIME", uptime_text[0..digitCount(uptime_value)], "SEC", theme.violet);
            const cap_value: u32 = self.model.cap_ticks;
            const cap_text = numberText(cap_value);
            const cap_label: []const u8 = if (self.model.cap_status & 1 == 0) "A0 HIGH" else if (self.model.cap_status & 2 == 0) "OPEN" else cap_text[0..digitCount(cap_value)];
            widgets.metric(font, height, main_x + (metric_w + 12) * 2, 105, metric_w, "CAP TICKS", cap_label, "RELATIVE", if (self.model.cap_fresh) theme.cyan else theme.amber);
            widgets.metric(font, height, main_x + (metric_w + 12) * 3, 105, metric_w, "CRC REJECTS", crc_text[0..digitCount(self.model.bad_crc)], "FRAMES", if (self.model.bad_crc == 0) theme.mint else theme.amber);
        }
        if (self.model.hasWidget(.timeseries)) widgets.chart(font, &self.model, main_x, 213, main_w, chart_h, height);
        if (self.model.hasWidget(.actuator)) {
            widgets.panel(main_x, control_top, main_w, 120, height, if (self.model.led) theme.mint else theme.violet);
            widgets.text(font, height, "SAFE OUTPUT", main_x + 20, control_top + 15, 0.64, theme.muted);
            widgets.text(font, height, "ONBOARD LED", main_x + 20, control_top + 37, 0.83, theme.text);
            widgets.text(font, height, "Diagnostic output · no actuator axes", main_x + 20, control_top + 64, 0.59, theme.faint);
            button(font, height, "LED TOGGLE", main_x + 18, control_top + 30, 136, 46, if (self.model.led) theme.mint else theme.cyan, self.model.led);
            button(font, height, "ALL OFF", main_x + 165, control_top + 30, 136, 46, theme.rose, false);
            widgets.panel(main_x, cap_top, main_w, 87, height, theme.violet);
            widgets.text(font, height, "CAPABILITY GATE", main_x + 17, cap_top + 14, 0.60, theme.muted);
            widgets.text(font, height, "0 actuator axes", main_x + 18, cap_top + 41, 0.82, theme.rose);
            widgets.text(font, height, "ARM  /  JOG  /  RUN  DISABLED  ·  WAITING FOR FEEDBACK DEVICES", main_x + 153, cap_top + 48, 0.57, theme.faint);
        }
        // Right rail: context lineage and event receipts.
        widgets.panel(right_x, 76, right_w, 232, height, theme.violet);
        widgets.text(font, height, "ADAPTIVE CONTEXT", right_x + 16, 93, 0.68, theme.violet);
        widgets.text(font, height, "Selection gate", right_x + 16, 124, 0.76, theme.text);
        widgets.dot(right_x + 22, 163, 3, height, theme.mint);
        widgets.text(font, height, "Policy · LED only", right_x + 34, 152, 0.62, theme.text);
        widgets.dot(right_x + 22, 191, 3, height, theme.cyan);
        widgets.text(font, height, "Fresh serial observation", right_x + 34, 180, 0.62, theme.text);
        widgets.dot(right_x + 22, 219, 3, height, theme.violet);
        widgets.text(font, height, "Owner command + dependencies", right_x + 34, 208, 0.58, theme.text);
        widgets.dot(right_x + 22, 247, 3, height, theme.rose);
        widgets.text(font, height, "Untrusted motion hypothesis dropped", right_x + 34, 236, 0.54, theme.muted);
        widgets.text(font, height, "DEVICE ENFORCES RANGE + CRC", right_x + 16, 279, 0.54, theme.faint);
        widgets.panel(right_x, 324, right_w, 180, height, theme.amber);
        widgets.text(font, height, "LIVE DEVICE SCHEMA", right_x + 16, 342, 0.64, theme.amber);
        widgets.text(font, height, "USB serial", right_x + 17, 374, 0.63, theme.text);
        widgets.text(font, height, "COM LINK", right_x + 174, 374, 0.57, theme.cyan);
        widgets.text(font, height, "Signals", right_x + 17, 405, 0.63, theme.text);
        widgets.text(font, height, "3 / 32", right_x + 174, 405, 0.57, theme.muted);
        widgets.text(font, height, "Camera streams", right_x + 17, 436, 0.63, theme.text);
        widgets.text(font, height, "0 / 8", right_x + 174, 436, 0.57, theme.muted);
        widgets.text(font, height, "Actuator feedback", right_x + 17, 467, 0.63, theme.text);
        widgets.text(font, height, "NONE", right_x + 174, 467, 0.57, theme.rose);
        if (self.model.hasWidget(.events)) widgets.eventFeed(&self.font, &self.model, right_x, 520, right_w, @max(120, height - 535), height);
        // Bottom glass status rail.
        prim.gradientRect(0, 0, width, 39, theme.ink, theme.glass);
        widgets.dot(24, height - 19, 3, height, if (self.model.connected) theme.mint else theme.amber);
        widgets.text(font, height, if (self.model.connected) "LINK HEALTHY  ·  HEARTBEAT 180 MS" else "DEVICE OFFLINE  ·  RETRYING USB", 37, height - 26, 0.58, if (self.model.connected) theme.mint else theme.amber);
        widgets.text(font, height, "GAPLESS SAMPLE HISTORY", width * 0.5 - 90, height - 26, 0.57, theme.muted);
        const sample_value: u32 = @intCast(self.model.sample_count);
        const samples_text = numberText(sample_value);
        widgets.text(font, height, samples_text[0..digitCount(sample_value)], width * 0.5 + 94, height - 26, 0.58, theme.cyan);
        widgets.text(font, height, "SIG  ·  GALAXY CONTEXT  ·  NO DEVICE HEAP", width - 297, height - 26, 0.55, theme.faint);
        _ = now;
    }
};
fn button(font: *const Font, height: f32, label: []const u8, x: f32, top: f32, w: f32, h: f32, color: Color, active: bool) void {
    const y = height - top - h;
    prim.roundedRect(x, y, w, h, 5, color.withAlpha(if (active) 0.25 else 0.14));
    prim.roundedRectOutline(x, y, w, h, 5, 1, color.withAlpha(if (active) 0.85 else 0.5));
    _ = font.drawString(label, x + 24, y + h * 0.5 - 5, 0.65, color);
}
fn numberText(value: u32) [10]u8 {
    var output: [10]u8 = @splat(0);
    var current = value;
    var length: usize = 0;
    if (current == 0) {
        output[0] = '0';
        return output;
    }
    while (current > 0 and length < 10) : (current /= 10) {
        output[length] = @intCast('0' + current % 10);
        length += 1;
    }
    for (0..length / 2) |i| {
        const j = length - 1 - i;
        const swap = output[i];
        output[i] = output[j];
        output[j] = swap;
    }
    return output;
}
fn digitCount(value: u32) usize {
    var current = value;
    var count: usize = 1;
    while (current >= 10) : (current /= 10) count += 1;
    return count;
}
pub fn main() !void {
    const args = try io.Args.load();
    const port = if (args.count == 2) args.get(1) else "COM9";
    var app: App = .{};
    try app.init(port);
    defer app.deinit();
    app.run();
}
