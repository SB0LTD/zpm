//! Fixed-capacity device, sensor, widget and event state for the SlowWire workbench.
pub const max_sensors = 32;
pub const sample_capacity = 120;
pub const event_capacity = 32;
pub const event_width = 84;
pub const SensorKind = enum(u8) { digital, analog_raw, capacitive_ticks, voltage_mv, temperature_milli_c, position_ticks, force_mn, camera_frame, unknown };
pub const EventLevel = enum(u8) { info, success, warning, fault };
pub const Value = struct { raw: i64 = 0, scale: i32 = 1, unit: [12]u8 = @splat(0), unit_len: u8 = 0 };
pub const Sensor = struct { id: u16 = 0, source: u16 = 0, kind: SensorKind = .unknown, name: [28]u8 = @splat(0), name_len: u8 = 0, value: Value = .{}, connected: bool = false, fresh: bool = false, revision: u32 = 0, sampled_ms: u32 = 0 };
pub const WidgetKind = enum(u8) { summary, metric, timeseries, device, camera, actuator, events, custom };
pub const Widget = struct { id: u16, kind: WidgetKind, source: u16 = 0, sensor: u16 = 0, visible: bool = true };
pub const Event = struct { text: [event_width]u8 = @splat(0), len: u8 = 0, at_ms: u32 = 0, level: EventLevel = .info };
pub const Model = struct {
    sensors: [max_sensors]Sensor = undefined,
    sensor_count: usize = 0,
    widgets: [max_sensors]Widget = undefined,
    widget_count: usize = 0,
    samples: [sample_capacity]u16 = @splat(0),
    sample_head: usize = 0,
    sample_count: usize = 0,
    events: [event_capacity]Event = @splat(.{}),
    event_head: usize = 0,
    event_count: usize = 0,
    connected: bool = false,
    identity: [48]u8 = @splat(0),
    identity_len: u8 = 0,
    uptime_ms: u32 = 0,
    revision: u32 = 0,
    bad_crc: u32 = 0,
    adc_raw: u16 = 0,
    cap_ticks: u16 = 0,
    cap_fresh: bool = false,
    cap_sampled_ms: u32 = 0,
    cap_status: u8 = 0,
    led: bool = false,
    axes: u8 = 0,
    last_update: u32 = 0,
    pub fn addSensor(self: *Model, item: Sensor) error{Capacity}!void {
        if (self.sensor_count == self.sensors.len or item.id == 0) return error.Capacity;
        for (self.sensors[0..self.sensor_count]) |old| if (old.id == item.id) return error.Capacity;
        self.sensors[self.sensor_count] = item;
        self.sensor_count += 1;
    }
    pub fn addWidget(self: *Model, widget: Widget) error{Capacity}!void {
        if (self.widget_count == self.widgets.len or widget.id == 0) return error.Capacity;
        for (self.widgets[0..self.widget_count]) |old| if (old.id == widget.id) return error.Capacity;
        self.widgets[self.widget_count] = widget;
        self.widget_count += 1;
    }
    pub fn hasWidget(self: *const Model, kind: WidgetKind) bool {
        for (self.widgets[0..self.widget_count]) |widget| if (widget.visible and widget.kind == kind) return true;
        return false;
    }
    pub fn pushSample(self: *Model, value: u16) void {
        self.samples[self.sample_head] = value;
        self.sample_head = (self.sample_head + 1) % self.samples.len;
        self.sample_count = @min(self.sample_count + 1, self.samples.len);
    }
    pub fn pushEvent(self: *Model, text: []const u8, level: EventLevel, at_ms: u32) void {
        const count = @min(text.len, event_width);
        var entry: Event = .{ .len = @intCast(count), .at_ms = at_ms, .level = level };
        @memcpy(entry.text[0..count], text[0..count]);
        self.events[self.event_head] = entry;
        self.event_head = (self.event_head + 1) % self.events.len;
        self.event_count = @min(self.event_count + 1, self.events.len);
    }
    pub fn eventAt(self: *const Model, index: usize) *const Event {
        const oldest = (self.event_head + self.events.len - self.event_count) % self.events.len;
        return &self.events[(oldest + index) % self.events.len];
    }
    pub fn sample(self: *const Model, index: usize) u16 {
        const oldest = (self.sample_head + self.samples.len - self.sample_count) % self.samples.len;
        return self.samples[(oldest + index) % self.samples.len];
    }
};
test "fixed sensor registry rejects duplicate identities and keeps recent sensor history" {
    var model: Model = .{};
    try model.addSensor(.{ .id = 1, .kind = .analog_raw });
    try model.addSensor(.{ .id = 2, .kind = .camera_frame });
    try @import("std").testing.expectError(error.Capacity, model.addSensor(.{ .id = 1 }));
    for (0..sample_capacity + 8) |i| model.pushSample(@intCast(i));
    try @import("std").testing.expect(model.sample_count == sample_capacity and model.sample(0) == 8 and model.sample(sample_capacity - 1) == 127);
}
