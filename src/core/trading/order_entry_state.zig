// Order entry form state — pure UI state, no I/O
// Layer 0: Foundation

const order_mod = @import("order.zig");
pub const OrderType = order_mod.OrderType;
pub const OrderSide = order_mod.OrderSide;
pub const TimeInForce = order_mod.TimeInForce;

/// Which text field is currently being edited
pub const EditField = enum {
    none,
    price,
    qty,
    stop_price,
    tp_price,
    sl_price,
};

/// Describes what the current source + market combination supports.
/// Set once when the display slot changes; draw/hit code queries this.
pub const OrderEntryCaps = struct {
    /// Available order types (indices into OrderType). Max 7 tabs.
    order_types: [7]OrderType = .{ .market, .limit, .stop_market, .stop_limit, .take_profit_market, .take_profit_limit, .trailing_stop },
    order_type_count: u8 = 7,

    has_leverage: bool = true,
    max_leverage: f64 = 125,
    has_reduce_only: bool = true,
    has_post_only: bool = true,
    has_tp_sl: bool = true,

    /// Spot defaults — no leverage, no reduce-only, limited order types
    pub fn spot() OrderEntryCaps {
        return .{
            .order_types = .{ .market, .limit, .stop_limit, .stop_limit, .stop_limit, .stop_limit, .stop_limit },
            .order_type_count = 3,
            .has_leverage = false,
            .max_leverage = 1,
            .has_reduce_only = false,
            .has_post_only = true,
            .has_tp_sl = false,
        };
    }

    /// Binance USD-M / COIN-M futures — full feature set
    pub fn binanceFutures() OrderEntryCaps {
        return .{
            .order_types = .{ .market, .limit, .stop_market, .stop_limit, .take_profit_market, .take_profit_limit, .trailing_stop },
            .order_type_count = 7,
            .has_leverage = true,
            .max_leverage = 125,
            .has_reduce_only = true,
            .has_post_only = true,
            .has_tp_sl = true,
        };
    }

    /// KuCoin futures — similar to Binance but no trailing stop
    pub fn kucoinFutures() OrderEntryCaps {
        return .{
            .order_types = .{ .market, .limit, .stop_market, .stop_limit, .take_profit_market, .take_profit_limit, .take_profit_limit },
            .order_type_count = 6,
            .has_leverage = true,
            .max_leverage = 100,
            .has_reduce_only = true,
            .has_post_only = true,
            .has_tp_sl = true,
        };
    }

    pub fn availableTypes(self: *const OrderEntryCaps) []const OrderType {
        return self.order_types[0..self.order_type_count];
    }

    pub fn hasOrderType(self: *const OrderEntryCaps, ot: OrderType) bool {
        for (self.availableTypes()) |t| {
            if (t == ot) return true;
        }
        return false;
    }
};

pub const OrderEntryState = struct {
    // Form selections
    side: OrderSide = .buy,
    order_type: OrderType = .limit,
    tif: TimeInForce = .gtc,
    reduce_only: bool = false,
    post_only: bool = false,

    // Source + market capabilities
    caps: OrderEntryCaps = OrderEntryCaps.binanceFutures(),

    // Text input buffers (ASCII, null-terminated)
    price_buf: [24]u8 = [_]u8{0} ** 24,
    price_len: u8 = 0,
    qty_buf: [24]u8 = [_]u8{0} ** 24,
    qty_len: u8 = 0,
    stop_buf: [24]u8 = [_]u8{0} ** 24,
    stop_len: u8 = 0,
    tp_buf: [24]u8 = [_]u8{0} ** 24,
    tp_len: u8 = 0,
    sl_buf: [24]u8 = [_]u8{0} ** 24,
    sl_len: u8 = 0,

    // Leverage (1–125)
    leverage: f64 = 10,

    // Which field is focused
    editing: EditField = .none,

    // Animation state (updated each frame by app)
    anim_time: f64 = 0,
    focus_time: f64 = 0, // time when current field was focused (for transition)

    // Submission state
    submitting: bool = false,
    last_error: [64]u8 = [_]u8{0} ** 64,
    last_error_len: u8 = 0,
    last_ok: bool = false,

    pub fn priceSlice(self: *const OrderEntryState) []const u8 {
        return self.price_buf[0..self.price_len];
    }
    pub fn qtySlice(self: *const OrderEntryState) []const u8 {
        return self.qty_buf[0..self.qty_len];
    }
    pub fn stopSlice(self: *const OrderEntryState) []const u8 {
        return self.stop_buf[0..self.stop_len];
    }
    pub fn tpSlice(self: *const OrderEntryState) []const u8 {
        return self.tp_buf[0..self.tp_len];
    }
    pub fn slSlice(self: *const OrderEntryState) []const u8 {
        return self.sl_buf[0..self.sl_len];
    }

    pub fn typeChar(self: *OrderEntryState, ch: u8) void {
        switch (self.editing) {
            .price => appendChar(&self.price_buf, &self.price_len, ch),
            .qty => appendChar(&self.qty_buf, &self.qty_len, ch),
            .stop_price => appendChar(&self.stop_buf, &self.stop_len, ch),
            .tp_price => appendChar(&self.tp_buf, &self.tp_len, ch),
            .sl_price => appendChar(&self.sl_buf, &self.sl_len, ch),
            .none => {},
        }
    }

    pub fn backspace(self: *OrderEntryState) void {
        switch (self.editing) {
            .price => if (self.price_len > 0) {
                self.price_len -= 1;
            },
            .qty => if (self.qty_len > 0) {
                self.qty_len -= 1;
            },
            .stop_price => if (self.stop_len > 0) {
                self.stop_len -= 1;
            },
            .tp_price => if (self.tp_len > 0) {
                self.tp_len -= 1;
            },
            .sl_price => if (self.sl_len > 0) {
                self.sl_len -= 1;
            },
            .none => {},
        }
    }

    /// Parse price field to f64 (0 if empty/invalid)
    pub fn parsePrice(self: *const OrderEntryState) f64 {
        return parseF64(self.priceSlice());
    }
    pub fn parseQty(self: *const OrderEntryState) f64 {
        return parseF64(self.qtySlice());
    }
    pub fn parseStop(self: *const OrderEntryState) f64 {
        return parseF64(self.stopSlice());
    }
    pub fn parseTp(self: *const OrderEntryState) f64 {
        return parseF64(self.tpSlice());
    }
    pub fn parseSl(self: *const OrderEntryState) f64 {
        return parseF64(self.slSlice());
    }

    /// True if the current order type requires a price field
    pub fn needsPrice(self: *const OrderEntryState) bool {
        return self.order_type == .limit or
            self.order_type == .stop_limit or
            self.order_type == .take_profit_limit;
    }

    /// True if the current order type requires a stop/trigger price
    pub fn needsStop(self: *const OrderEntryState) bool {
        return self.order_type == .stop_market or
            self.order_type == .stop_limit or
            self.order_type == .take_profit_market or
            self.order_type == .take_profit_limit or
            self.order_type == .trailing_stop;
    }

    /// True if TP/SL fields should be shown (caps + not a TP/SL order type itself)
    pub fn needsTpSl(self: *const OrderEntryState) bool {
        if (!self.caps.has_tp_sl) return false;
        // Don't show TP/SL fields when the order type IS a TP or SL
        return self.order_type != .take_profit_market and
            self.order_type != .take_profit_limit;
    }

    pub fn needsLeverage(self: *const OrderEntryState) bool {
        return self.caps.has_leverage;
    }

    pub fn needsReduceOnly(self: *const OrderEntryState) bool {
        return self.caps.has_reduce_only;
    }

    pub fn needsPostOnly(self: *const OrderEntryState) bool {
        return self.caps.has_post_only and
            (self.order_type == .limit or self.order_type == .stop_limit or self.order_type == .take_profit_limit);
    }

    /// Clamp order_type to one that's valid for current caps
    pub fn clampOrderType(self: *OrderEntryState) void {
        if (!self.caps.hasOrderType(self.order_type)) {
            self.order_type = self.caps.order_types[0];
        }
    }

    /// Set the focused field, recording the transition time for animation
    pub fn setEditing(self: *OrderEntryState, field: EditField) void {
        if (self.editing != field) {
            self.focus_time = self.anim_time;
        }
        self.editing = field;
    }

    pub fn setError(self: *OrderEntryState, msg: []const u8) void {
        const n = @min(msg.len, 64);
        @memcpy(self.last_error[0..n], msg[0..n]);
        self.last_error_len = @intCast(n);
        self.last_ok = false;
    }

    pub fn clearStatus(self: *OrderEntryState) void {
        self.last_error_len = 0;
        self.last_ok = false;
        self.submitting = false;
    }

    /// Set a field's entire value at once (for MCP / programmatic input).
    pub fn setFieldValue(self: *OrderEntryState, field: EditField, data: []const u8) void {
        const n = @min(data.len, 23);
        switch (field) {
            .price => {
                @memcpy(self.price_buf[0..n], data[0..n]);
                self.price_len = @intCast(n);
            },
            .qty => {
                @memcpy(self.qty_buf[0..n], data[0..n]);
                self.qty_len = @intCast(n);
            },
            .stop_price => {
                @memcpy(self.stop_buf[0..n], data[0..n]);
                self.stop_len = @intCast(n);
            },
            .tp_price => {
                @memcpy(self.tp_buf[0..n], data[0..n]);
                self.tp_len = @intCast(n);
            },
            .sl_price => {
                @memcpy(self.sl_buf[0..n], data[0..n]);
                self.sl_len = @intCast(n);
            },
            .none => {},
        }
    }
};

fn appendChar(buf: *[24]u8, len: *u8, ch: u8) void {
    // Only allow digits, dot, minus
    if (ch != '.' and ch != '-' and (ch < '0' or ch > '9')) return;
    if (len.* >= 23) return;
    buf[len.*] = ch;
    len.* += 1;
}

fn parseF64(s: []const u8) f64 {
    if (s.len == 0) return 0;
    var result: f64 = 0;
    var frac: f64 = 0;
    var in_frac = false;
    var frac_div: f64 = 1;
    var neg = false;
    var i: usize = 0;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '.') {
            in_frac = true;
        } else if (c >= '0' and c <= '9') {
            const d: f64 = @floatFromInt(c - '0');
            if (in_frac) {
                frac_div *= 10;
                frac += d / frac_div;
            } else {
                result = result * 10 + d;
            }
        }
    }
    result += frac;
    return if (neg) -result else result;
}
