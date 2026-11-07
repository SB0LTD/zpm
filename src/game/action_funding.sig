//! Layer 0 sponsor reservation arithmetic. Settled reserves, never estimated ad income.
//! Host serializes reservations and verifies receipts, expiry and transaction identity.
pub const Error = error{ InvalidQuote, Overflow, Unfunded, Expired, AlreadyConsumed, FeeExceeded };
pub const Quote = struct { fee_cap: u64, margin: u64, expires_slot: u64 };
pub const Reservation = struct { quote: Quote, active: bool = true };
pub const Pool = struct { available: u64 = 0, reserved: u64 = 0, spent: u64 = 0, profit: u64 = 0 };
pub fn total(quote: Quote) Error!u64 {
    if (quote.fee_cap == 0) return error.InvalidQuote;
    if (quote.margin > 0xffffffffffffffff - quote.fee_cap) return error.Overflow;
    return quote.fee_cap + quote.margin;
}
pub fn reserve(pool: *Pool, quote: Quote, slot: u64) Error!Reservation {
    if (slot >= quote.expires_slot) return error.Expired;
    const amount = try total(quote);
    if (amount > pool.available) return error.Unfunded;
    if (pool.reserved > 0xffffffffffffffff - amount) return error.Overflow;
    pool.available -= amount;
    pool.reserved += amount;
    return .{ .quote = quote };
}
/// Settlement also applies to a failed transaction: Solana still charges its fee.
/// Expiry prevents submission; already-submitted transactions may settle after expiry.
pub fn settle(pool: *Pool, reservation: *Reservation, fee: u64) Error!void {
    if (!reservation.active) return error.AlreadyConsumed;
    if (fee > reservation.quote.fee_cap) return error.FeeExceeded;
    const amount = try total(reservation.quote);
    if (pool.reserved < amount) return error.Unfunded;
    const refund = reservation.quote.fee_cap - fee;
    if (pool.spent > 0xffffffffffffffff - fee or pool.profit > 0xffffffffffffffff - reservation.quote.margin or pool.available > 0xffffffffffffffff - refund) return error.Overflow;
    pool.reserved -= amount;
    pool.available += refund;
    pool.spent += fee;
    pool.profit += reservation.quote.margin;
    reservation.active = false;
}
/// Host must establish no transaction was submitted before cancellation/refund.
pub fn cancel(pool: *Pool, reservation: *Reservation) Error!void {
    if (!reservation.active) return error.AlreadyConsumed;
    const amount = try total(reservation.quote);
    if (pool.reserved < amount) return error.Unfunded;
    if (pool.available > 0xffffffffffffffff - amount) return error.Overflow;
    pool.reserved -= amount;
    pool.available += amount;
    reservation.active = false;
}
pub const State = enum { idle, choice, watching, awaiting_verification, ready, submitted };
/// Optional capped martingale-shaped offer schedule: 1, 2, 4, ... ads.
/// It is a disclosure/quote policy, not a revenue guarantee or permission to autoplay.
pub const RetrySchedule = struct {
    ads: u8 = 1,
    limit: u8 = 8,
    pub fn retry(self: *RetrySchedule) bool {
        if (self.ads == 0 or self.ads >= self.limit) return false;
        self.ads = @intCast(@min(@as(u16,self.ads)*2, self.limit));
        return true;
    }
    pub fn reset(self: *RetrySchedule) void { self.ads = 1; }
};
/// Per-action consent gate. No SDK callback can authorize sponsorship on its own.
pub const Gate = struct {
    state: State = .idle,
    pub fn begin(self: *Gate) bool {
        if (self.state != .idle) return false;
        self.state = .choice;
        return true;
    }
    pub fn watch(self: *Gate) bool {
        if (self.state != .choice) return false;
        self.state = .watching;
        return true;
    }
    pub fn completed(self: *Gate) bool {
        if (self.state != .watching) return false;
        self.state = .awaiting_verification;
        return true;
    }
    // Only host-verified, action-bound sponsorship may call this method.
    pub fn verified(self: *Gate) bool {
        if (self.state != .awaiting_verification) return false;
        self.state = .ready;
        return true;
    }
    pub fn pay(self: *Gate) bool {
        if (self.state != .choice) return false;
        self.state = .ready;
        return true;
    }
    pub fn submit(self: *Gate) bool {
        if (self.state != .ready) return false;
        self.state = .submitted;
        return true;
    }
    pub fn dismiss(self: *Gate) bool {
        if (self.state == .submitted) return false;
        self.state = .idle;
        return true;
    }
    pub fn resolved(self: *Gate) bool {
        if (self.state != .submitted) return false;
        self.state = .idle;
        return true;
    }
};
