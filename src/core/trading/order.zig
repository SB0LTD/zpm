// Order types — pure data, no I/O
// Layer 0: Foundation

pub const MAX_ORDERS = 64;
pub const MAX_OPEN_ORDERS = 32;

pub const OrderSide = enum(u8) { buy = 0, sell = 1, long = 2, short = 3 };

pub const OrderType = enum(u8) {
    market,
    limit,
    stop_market,
    stop_limit,
    take_profit_market,
    take_profit_limit,
    trailing_stop,
};

pub const OrderStatus = enum(u8) {
    pending,
    open,
    partial,
    filled,
    cancelled,
    rejected,
    expired,
};

pub const TimeInForce = enum(u8) {
    gtc,
    ioc,
    fok,
    gtx,
};

pub const Order = struct {
    id: [32]u8 = [_]u8{0} ** 32,
    id_len: u8 = 0,
    client_id: [32]u8 = [_]u8{0} ** 32,
    client_id_len: u8 = 0,
    symbol: [20]u8 = [_]u8{0} ** 20,
    symbol_len: u8 = 0,
    side: OrderSide = .buy,
    order_type: OrderType = .limit,
    status: OrderStatus = .pending,
    tif: TimeInForce = .gtc,
    price: f64 = 0,
    stop_price: f64 = 0,
    qty: f64 = 0,
    filled_qty: f64 = 0,
    avg_fill_price: f64 = 0,
    reduce_only: bool = false,
    post_only: bool = false,
    timestamp: i64 = 0,

    pub fn idSlice(self: *const Order) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn symbolSlice(self: *const Order) []const u8 {
        return self.symbol[0..self.symbol_len];
    }
    pub fn setId(self: *Order, s: []const u8) void {
        const n = @min(s.len, 32);
        @memcpy(self.id[0..n], s[0..n]);
        self.id_len = @intCast(n);
    }
    pub fn setSymbol(self: *Order, s: []const u8) void {
        const n = @min(s.len, 20);
        @memcpy(self.symbol[0..n], s[0..n]);
        self.symbol_len = @intCast(n);
    }
    pub fn remainingQty(self: *const Order) f64 {
        return self.qty - self.filled_qty;
    }
    pub fn isActive(self: *const Order) bool {
        return self.status == .open or self.status == .partial or self.status == .pending;
    }
};

/// Open orders snapshot — pure data, no I/O. Lives in core so platform layer can reference it.
pub const OrderInfo = struct {
    orders: [MAX_OPEN_ORDERS]Order = [_]Order{.{}} ** MAX_OPEN_ORDERS,
    count: u32 = 0,
    ready: u32 = 0,
    loading: u32 = 0,
    error_code: u32 = 0,

    pub fn isReady(self: *const OrderInfo) bool {
        return @atomicLoad(u32, &self.ready, .acquire) == 1;
    }
};

/// Pending order request — filled by UI, consumed by source thread
pub const OrderRequest = struct {
    symbol: [20]u8 = [_]u8{0} ** 20,
    symbol_len: u8 = 0,
    side: OrderSide = .buy,
    order_type: OrderType = .limit,
    tif: TimeInForce = .gtc,
    price: f64 = 0,
    stop_price: f64 = 0,
    qty: f64 = 0,
    reduce_only: bool = false,
    post_only: bool = false,
    tp_price: f64 = 0, // take profit (0 = none)
    sl_price: f64 = 0, // stop loss (0 = none)
    leverage: f64 = 0, // 0 = don't change

    pub fn symbolSlice(self: *const OrderRequest) []const u8 {
        return self.symbol[0..self.symbol_len];
    }
    pub fn setSymbol(self: *OrderRequest, s: []const u8) void {
        const n = @min(s.len, 20);
        @memcpy(self.symbol[0..n], s[0..n]);
        self.symbol_len = @intCast(n);
    }
};

/// Cancel request — order ID to cancel
pub const CancelRequest = struct {
    order_id: [32]u8 = [_]u8{0} ** 32,
    order_id_len: u8 = 0,
    symbol: [20]u8 = [_]u8{0} ** 20,
    symbol_len: u8 = 0,

    pub fn idSlice(self: *const CancelRequest) []const u8 {
        return self.order_id[0..self.order_id_len];
    }
    pub fn symbolSlice(self: *const CancelRequest) []const u8 {
        return self.symbol[0..self.symbol_len];
    }
};
