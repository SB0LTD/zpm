// Runtime configuration — parsed from config.json
// Layer 0: Foundation — pure data + parsing, no I/O
//
// Fixed-size config struct parsed from JSON using core/json.zig helpers.
// No allocator needed — all strings stored in fixed buffers.
//
// Config format:
//   "subscriptions": [ { "source": "binance", "symbol": "BTCUSDT", "timeframe": "1m", "history": 500 }, ... ]
//   "display": 0
//   "sources": { "binance": { "api_key": "...", ... }, "kucoin": { ... } }
//   "window": { "width": 1280, "height": 720, "opacity": 230 }

const json = @import("json");
const ct = @import("config_types.zig");

// Re-export types so callers can still use @import("config.zig").ConfigStr etc.
pub const ConfigStr = ct.ConfigStr;
pub const SourceCreds = ct.SourceCreds;
pub const Subscription = ct.Subscription;
pub const MarketType = ct.MarketType;
pub const MAX_SUBS = ct.MAX_SUBS;

pub const Config = struct {
    /// Known source type indices for credential storage
    pub const SOURCE_BINANCE: usize = 0;
    pub const SOURCE_KUCOIN: usize = 1;
    pub const SOURCE_COUNT: usize = 2;

    // Subscriptions — each is an independent (source, symbol, timeframe) stream
    subs: [MAX_SUBS]Subscription = [_]Subscription{.{}} ** MAX_SUBS,
    sub_count: usize = 0,

    // Which subscription the chart displays
    display_idx: usize = 0,

    // Per-source credential storage
    creds: [SOURCE_COUNT]SourceCreds = [_]SourceCreds{.{}} ** SOURCE_COUNT,

    // window
    window_width: i32 = 1280,
    window_height: i32 = 720,
    window_opacity: u8 = 230,

    // logging — "err", "warn", "info", "debug", "trace" (empty = use CLI flag)
    log_level: ConfigStr = .{},

    /// Get the display subscription (or a default if none configured)
    pub fn displaySub(self: *const Config) *const Subscription {
        if (self.sub_count == 0) return &DEFAULT_SUB;
        const idx = @min(self.display_idx, self.sub_count - 1);
        return &self.subs[idx];
    }

    /// Resolve which creds index matches a source type name
    pub fn credsIndex(source_type: []const u8) ?usize {
        if (source_type.len == 7 and eqlBytes(source_type, "binance")) return SOURCE_BINANCE;
        if (source_type.len == 6 and eqlBytes(source_type, "kucoin")) return SOURCE_KUCOIN;
        return null;
    }

    /// Parse a JSON config buffer into a Config struct.
    pub fn parse(text: []const u8) Config {
        var cfg = Config{};

        // Parse subscriptions array
        if (findArray(text, "\"subscriptions\"")) |arr| {
            cfg.sub_count = 0;
            var pos: usize = 0;
            while (cfg.sub_count < MAX_SUBS) {
                // Find next '{' in the array
                while (pos < arr.len and arr[pos] != '{') : (pos += 1) {}
                if (pos >= arr.len) break;
                // Find matching '}'
                const obj_start = pos;
                var depth: usize = 0;
                while (pos < arr.len) : (pos += 1) {
                    if (arr[pos] == '{') depth += 1;
                    if (arr[pos] == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            pos += 1;
                            break;
                        }
                    }
                }
                const obj = arr[obj_start..pos];
                var sub = Subscription{};
                if (json.getString(obj, "\"source\"")) |v| sub.source.set(v);
                if (json.getString(obj, "\"symbol\"")) |v| sub.symbol.set(v);
                if (json.getString(obj, "\"timeframe\"")) |v| sub.timeframe.set(v);
                if (json.getInt(obj, "\"history\"")) |v| sub.history = @intCast(v);
                if (json.getString(obj, "\"market\"")) |v| {
                    sub.market = ct.MarketType.fromString(v);
                } else if (json.getBool(obj, "\"futures\"")) {
                    sub.market = .linear; // backward compat
                }
                cfg.subs[cfg.sub_count] = sub;
                cfg.sub_count += 1;
            }
        }

        // Parse display index
        if (json.getInt(text, "\"display\"")) |v| {
            cfg.display_idx = @intCast(v);
        }

        // Parse per-source credentials: "sources": { "binance": {...}, "kucoin": {...} }
        if (json.findObject(text, "\"sources\"")) |sources_obj| {
            if (json.findObject(sources_obj, "\"binance\"")) |b| {
                if (json.getString(b, "\"api_key\"")) |v| cfg.creds[SOURCE_BINANCE].api_key.set(v);
                if (json.getString(b, "\"api_secret\"")) |v| cfg.creds[SOURCE_BINANCE].api_secret.set(v);
            }
            if (json.findObject(sources_obj, "\"kucoin\"")) |k| {
                if (json.getString(k, "\"api_key\"")) |v| cfg.creds[SOURCE_KUCOIN].api_key.set(v);
                if (json.getString(k, "\"api_secret\"")) |v| cfg.creds[SOURCE_KUCOIN].api_secret.set(v);
                if (json.getString(k, "\"api_passphrase\"")) |v| cfg.creds[SOURCE_KUCOIN].api_passphrase.set(v);
            }
        }

        // Parse "window" object
        if (json.findObject(text, "\"window\"")) |win| {
            if (json.getInt(win, "\"width\"")) |v| cfg.window_width = @intCast(v);
            if (json.getInt(win, "\"height\"")) |v| cfg.window_height = @intCast(v);
            if (json.getInt(win, "\"opacity\"")) |v| cfg.window_opacity = @intCast(v);
        }

        // Parse log level
        if (json.getString(text, "\"log_level\"")) |v| cfg.log_level.set(v);

        // If no subscriptions defined, create a default binance one
        if (cfg.sub_count == 0) {
            cfg.subs[0] = .{};
            cfg.sub_count = 1;
        }

        return cfg;
    }
    /// Serialize config to JSON into the provided buffer. Returns the used slice.
    pub fn serialize(self: *const Config, buf: *[8192]u8) []const u8 {
        var pos: usize = 0;

        pos = appendSlice(buf, pos, "{\n  \"subscriptions\": [\n");
        for (0..self.sub_count) |i| {
            const sub = &self.subs[i];
            pos = appendSlice(buf, pos, "    { \"source\": \"");
            pos = appendSlice(buf, pos, sub.source.slice());
            pos = appendSlice(buf, pos, "\", \"symbol\": \"");
            pos = appendSlice(buf, pos, sub.symbol.slice());
            pos = appendSlice(buf, pos, "\", \"timeframe\": \"");
            pos = appendSlice(buf, pos, sub.timeframe.slice());
            pos = appendSlice(buf, pos, "\", \"history\": ");
            pos = appendNum(buf, pos, sub.history);
            if (sub.market != .spot) {
                pos = appendSlice(buf, pos, ", \"market\": \"");
                pos = appendSlice(buf, pos, sub.market.label());
                pos = appendSlice(buf, pos, "\"");
            }
            pos = appendSlice(buf, pos, " }");
            if (i + 1 < self.sub_count) {
                pos = appendSlice(buf, pos, ",\n");
            } else {
                pos = appendSlice(buf, pos, "\n");
            }
        }
        pos = appendSlice(buf, pos, "  ],\n  \"display\": ");
        pos = appendNum(buf, pos, self.display_idx);
        pos = appendSlice(buf, pos, ",\n  \"sources\": {\n");

        const b = &self.creds[SOURCE_BINANCE];
        if (b.api_key.len > 0) {
            pos = appendSlice(buf, pos, "    \"binance\": {\n      \"api_key\": \"");
            pos = appendSlice(buf, pos, b.api_key.slice());
            pos = appendSlice(buf, pos, "\",\n      \"api_secret\": \"");
            pos = appendSlice(buf, pos, b.api_secret.slice());
            pos = appendSlice(buf, pos, "\"\n    }");
            const k = &self.creds[SOURCE_KUCOIN];
            if (k.api_key.len > 0) {
                pos = appendSlice(buf, pos, ",\n");
            } else {
                pos = appendSlice(buf, pos, "\n");
            }
        }

        const k = &self.creds[SOURCE_KUCOIN];
        if (k.api_key.len > 0) {
            pos = appendSlice(buf, pos, "    \"kucoin\": {\n      \"api_key\": \"");
            pos = appendSlice(buf, pos, k.api_key.slice());
            pos = appendSlice(buf, pos, "\",\n      \"api_secret\": \"");
            pos = appendSlice(buf, pos, k.api_secret.slice());
            pos = appendSlice(buf, pos, "\",\n      \"api_passphrase\": \"");
            pos = appendSlice(buf, pos, k.api_passphrase.slice());
            pos = appendSlice(buf, pos, "\"\n    }\n");
        }

        pos = appendSlice(buf, pos, "  },\n  \"window\": {\n    \"width\": ");
        pos = appendNum(buf, pos, @intCast(self.window_width));
        pos = appendSlice(buf, pos, ",\n    \"height\": ");
        pos = appendNum(buf, pos, @intCast(self.window_height));
        pos = appendSlice(buf, pos, ",\n    \"opacity\": ");
        pos = appendNum(buf, pos, self.window_opacity);
        pos = appendSlice(buf, pos, "\n  }\n}\n");

        return buf[0..pos];
    }
};

const DEFAULT_SUB = Subscription{};

fn appendSlice(buf: *[8192]u8, pos: usize, s: []const u8) usize {
    if (pos + s.len > 8192) return pos;
    @memcpy(buf[pos .. pos + s.len], s);
    return pos + s.len;
}

fn appendNum(buf: *[8192]u8, pos: usize, val: usize) usize {
    if (val == 0) {
        buf[pos] = '0';
        return pos + 1;
    }
    var v = val;
    var tmp: [20]u8 = undefined;
    var tl: usize = 0;
    while (v > 0) : (v /= 10) {
        tmp[tl] = @intCast(v % 10 + '0');
        tl += 1;
    }
    var p = pos;
    var ri = tl;
    while (ri > 0) : (ri -= 1) {
        buf[p] = tmp[ri - 1];
        p += 1;
    }
    return p;
}

/// Find a JSON array value for a key. Returns the content between [ and ].
fn findArray(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = json.findKey(data, key) orelse return null;
    var i = pos;
    while (i < data.len and data[i] != '[') : (i += 1) {}
    if (i >= data.len) return null;
    const start = i;
    var depth: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '[') depth += 1;
        if (data[i] == ']') {
            depth -= 1;
            if (depth == 0) return data[start .. i + 1];
        }
    }
    return null;
}

fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
