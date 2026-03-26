// SettingsState — UI state for the settings panel
// Layer 1: Sources
//
// Pure data + logic, no rendering. Extracted from widgets/settings.zig
// so that platform/input.zig (Layer 1) can embed it in AppState without
// a cross-layer import.

const Config = @import("../config.zig").Config;
const ConfigStr = @import("../config.zig").ConfigStr;
const MAX_SUBS = @import("../config.zig").MAX_SUBS;
const SourceMetadata = @import("../metadata.zig").SourceMetadata;

pub const FIELD_COUNT = 5;

/// Max filtered results shown in the symbol dropdown
const MAX_FILTERED = 32;

/// Editing state for the settings panel
pub const SettingsState = struct {
    open: bool = false,
    selected: usize = 0,
    editing: bool = false,

    // Display slot index (cycles through active subscriptions)
    display_idx: usize = 0,
    sub_count: usize = 0,

    // Editable copies of the display subscription's values
    symbol: ConfigStr = ConfigStr.init("BTCUSDT"),
    symbol_idx: usize = 0,
    timeframe_idx: usize = 0,
    history: usize = 500,
    opacity: u8 = 230,

    // Slot labels for display cycling: "binance BTCUSDT 1m", etc.
    slot_labels: [MAX_SUBS][48]u8 = undefined,
    slot_label_lens: [MAX_SUBS]u8 = [_]u8{0} ** MAX_SUBS,

    // Pointer to display slot's metadata (set by app.zig)
    metadata: ?*SourceMetadata = null,

    // Text input cursor for text/number fields
    input_buf: [64]u8 = [_]u8{0} ** 64,
    input_len: usize = 0,

    // Symbol filter state
    filter_buf: [20]u8 = [_]u8{0} ** 20,
    filter_len: usize = 0,
    filter_results: [MAX_FILTERED]u16 = [_]u16{0} ** MAX_FILTERED,
    filter_count: usize = 0,
    filter_cursor: usize = 0,
    filter_active: bool = false,

    pub fn filterType(self: *SettingsState, ch: u8) void {
        if (!self.hasMetadata()) return;
        if (self.filter_len >= 20) return;
        self.filter_buf[self.filter_len] = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
        self.filter_len += 1;
        self.filter_active = true;
        self.rebuildFilter();
    }

    pub fn filterBackspace(self: *SettingsState) void {
        if (self.filter_len > 0) {
            self.filter_len -= 1;
            if (self.filter_len == 0) {
                self.filter_active = false;
                self.filter_count = 0;
            } else {
                self.rebuildFilter();
            }
        }
    }

    fn rebuildFilter(self: *SettingsState) void {
        const meta = self.metadata orelse return;
        const needle = self.filter_buf[0..self.filter_len];
        self.filter_count = 0;
        self.filter_cursor = 0;
        for (0..meta.symbol_count) |i| {
            if (self.filter_count >= MAX_FILTERED) break;
            const sym = meta.getSymbol(i);
            if (containsIgnoreCase(sym, needle)) {
                self.filter_results[self.filter_count] = @intCast(i);
                self.filter_count += 1;
            }
        }
    }

    pub fn filterConfirm(self: *SettingsState) void {
        if (self.filter_active and self.filter_count > 0) {
            self.symbol_idx = self.filter_results[self.filter_cursor];
            const meta = self.metadata.?;
            self.symbol.set(meta.getSymbol(self.symbol_idx));
        }
        self.filterClear();
    }

    pub fn filterClear(self: *SettingsState) void {
        self.filter_active = false;
        self.filter_len = 0;
        self.filter_count = 0;
        self.filter_cursor = 0;
    }

    pub fn hasMetadata(self: *const SettingsState) bool {
        const meta = self.metadata orelse return false;
        return meta.isReady() and meta.symbol_count > 0;
    }

    pub fn isMetadataLoading(self: *const SettingsState) bool {
        const meta = self.metadata orelse return false;
        return meta.isLoading();
    }

    pub fn intervalCount(self: *const SettingsState) usize {
        const meta = self.metadata orelse return 0;
        if (meta.isReady() and meta.interval_count > 0) return meta.interval_count;
        return 0;
    }

    pub fn getTimeframe(self: *const SettingsState, idx: usize) []const u8 {
        const meta = self.metadata orelse return "1m";
        if (meta.isReady() and idx < meta.interval_count) return meta.getInterval(idx);
        return "1m";
    }

    pub fn getSymbolDisplay(self: *const SettingsState) []const u8 {
        if (self.hasMetadata()) return self.metadata.?.getSymbol(self.symbol_idx);
        return self.symbol.slice();
    }

    pub fn getSlotLabel(self: *const SettingsState, idx: usize) []const u8 {
        if (idx >= self.sub_count) return "---";
        const len = self.slot_label_lens[idx];
        if (len == 0) return "---";
        return self.slot_labels[idx][0..len];
    }

    pub fn buildSlotLabels(self: *SettingsState, cfg: *const Config) void {
        self.sub_count = cfg.sub_count;
        for (0..cfg.sub_count) |i| {
            const sub = &cfg.subs[i];
            var buf = &self.slot_labels[i];
            var pos: usize = 0;
            const src = sub.source.slice();
            const sym = sub.symbol.slice();
            const tf = sub.timeframe.slice();
            for (src) |c| {
                if (pos >= 47) break;
                buf[pos] = c;
                pos += 1;
            }
            if (pos < 47) {
                buf[pos] = ' ';
                pos += 1;
            }
            for (sym) |c| {
                if (pos >= 47) break;
                buf[pos] = c;
                pos += 1;
            }
            if (pos < 47) {
                buf[pos] = ' ';
                pos += 1;
            }
            for (tf) |c| {
                if (pos >= 47) break;
                buf[pos] = c;
                pos += 1;
            }
            self.slot_label_lens[i] = @intCast(pos);
        }
    }

    pub fn loadFrom(self: *SettingsState, cfg: *const Config) void {
        self.display_idx = cfg.display_idx;
        self.sub_count = cfg.sub_count;
        self.buildSlotLabels(cfg);
        const sub = cfg.displaySub();
        self.symbol = sub.symbol;
        self.history = sub.history;
        self.opacity = cfg.window_opacity;
        self.syncFromMetadata(sub.timeframe.slice());
    }

    pub fn syncFromMetadata(self: *SettingsState, timeframe_hint: []const u8) void {
        if (self.hasMetadata()) {
            const meta = self.metadata.?;
            self.symbol_idx = meta.findSymbol(self.symbol.slice());
            self.timeframe_idx = meta.findInterval(timeframe_hint);
        }
    }

    pub fn applyTo(self: *const SettingsState, cfg: *Config) void {
        cfg.display_idx = self.display_idx;
        if (cfg.sub_count > 0) {
            const idx = @min(self.display_idx, cfg.sub_count - 1);
            var sub = &cfg.subs[idx];
            if (self.hasMetadata()) {
                const meta = self.metadata.?;
                sub.symbol.set(meta.getSymbol(self.symbol_idx));
            } else {
                sub.symbol = self.symbol;
            }
            sub.timeframe.set(self.getTimeframe(self.timeframe_idx));
            sub.history = self.history;
        }
        cfg.window_opacity = self.opacity;
    }

    pub fn beginEdit(self: *SettingsState) void {
        self.editing = true;
        switch (self.selected) {
            1 => {
                if (self.hasMetadata()) {
                    self.editing = false;
                    return;
                }
                const s = self.symbol.slice();
                @memcpy(self.input_buf[0..s.len], s);
                self.input_len = s.len;
            },
            3 => self.input_len = formatUsize(self.history, &self.input_buf),
            4 => self.input_len = formatUsize(self.opacity, &self.input_buf),
            else => self.editing = false,
        }
    }

    pub fn commitEdit(self: *SettingsState) void {
        if (!self.editing) return;
        self.editing = false;
        const val = self.input_buf[0..self.input_len];
        switch (self.selected) {
            1 => self.symbol.set(val),
            3 => self.history = parseUsize(val, 500),
            4 => {
                const v = parseUsize(val, 230);
                self.opacity = if (v > 255) 255 else @intCast(v);
            },
            else => {},
        }
    }

    pub fn typeChar(self: *SettingsState, ch: u8) void {
        if (!self.editing) return;
        if (self.input_len < 63) {
            self.input_buf[self.input_len] = ch;
            self.input_len += 1;
        }
    }

    pub fn backspace(self: *SettingsState) void {
        if (!self.editing) return;
        if (self.input_len > 0) self.input_len -= 1;
    }

    pub fn cycleField(self: *SettingsState, dir: i32) void {
        switch (self.selected) {
            0 => {
                if (self.sub_count == 0) return;
                if (dir > 0) {
                    self.display_idx = (self.display_idx + 1) % self.sub_count;
                } else {
                    self.display_idx = if (self.display_idx == 0) self.sub_count - 1 else self.display_idx - 1;
                }
            },
            1 => {
                if (self.hasMetadata()) {
                    if (self.filter_active and self.filter_count > 0) {
                        if (dir > 0) {
                            self.filter_cursor = (self.filter_cursor + 1) % self.filter_count;
                        } else {
                            self.filter_cursor = if (self.filter_cursor == 0) self.filter_count - 1 else self.filter_cursor - 1;
                        }
                        self.symbol_idx = self.filter_results[self.filter_cursor];
                        self.symbol.set(self.metadata.?.getSymbol(self.symbol_idx));
                    } else {
                        const meta = self.metadata.?;
                        const count = meta.symbol_count;
                        if (count == 0) return;
                        if (dir > 0) {
                            self.symbol_idx = (self.symbol_idx + 1) % count;
                        } else {
                            self.symbol_idx = if (self.symbol_idx == 0) count - 1 else self.symbol_idx - 1;
                        }
                        self.symbol.set(meta.getSymbol(self.symbol_idx));
                    }
                }
            },
            2 => {
                const count = self.intervalCount();
                if (count == 0) return;
                if (dir > 0) {
                    self.timeframe_idx = (self.timeframe_idx + 1) % count;
                } else {
                    self.timeframe_idx = if (self.timeframe_idx == 0) count - 1 else self.timeframe_idx - 1;
                }
            },
            else => {},
        }
    }
};

fn formatUsize(val: usize, buf: []u8) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = val;
    var tmp: [20]u8 = undefined;
    var tl: usize = 0;
    while (v > 0) : (v /= 10) {
        tmp[tl] = @intCast(v % 10 + '0');
        tl += 1;
    }
    var pos: usize = 0;
    var ri = tl;
    while (ri > 0) : (ri -= 1) {
        buf[pos] = tmp[ri - 1];
        pos += 1;
    }
    return pos;
}

fn parseUsize(s: []const u8, default: usize) usize {
    if (s.len == 0) return default;
    var result: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        result = result * 10 + (c - '0');
    }
    return if (result == 0) default else result;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        var match = true;
        for (0..needle.len) |j| {
            const a = if (haystack[i + j] >= 'a' and haystack[i + j] <= 'z') haystack[i + j] - 32 else haystack[i + j];
            const b = if (needle[j] >= 'a' and needle[j] <= 'z') needle[j] - 32 else needle[j];
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
