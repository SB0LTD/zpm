// Source metadata — unified interface for source capabilities
// Layer 1: Sources
//
// Every data source exposes its available symbols, intervals, display name,
// and connection status through this struct. The UI reads only from here —
// it never imports source-specific modules.
//
// Sources populate this struct however they want: Binance fetches from REST,
// Demo hardcodes a small set, a future CSV source might list available files.
//
// Symbols are stored in normalized form with separate base/quote assets.
// Each source converts from its native format during metadata population.
// Intervals are stored in canonical form: 1m, 5m, 15m, 30m, 1h, 4h, 1d, 1w.

/// Max trading pairs any source can expose
pub const MAX_SYMBOLS = 2048;
/// Max length of a single symbol string
pub const MAX_SYM_LEN = 20;
/// Max length of a base or quote asset name
pub const MAX_ASSET_LEN = 12;
/// Max intervals any source can expose
pub const MAX_INTERVALS = 32;
/// Max length of a single interval string
pub const MAX_INTERVAL_LEN = 4;

pub const SourceMetadata = struct {
    // ── Symbols ──
    symbols: [MAX_SYMBOLS][MAX_SYM_LEN]u8 = undefined,
    sym_lens: [MAX_SYMBOLS]u8 = [_]u8{0} ** MAX_SYMBOLS,
    base_assets: [MAX_SYMBOLS][MAX_ASSET_LEN]u8 = undefined,
    base_lens: [MAX_SYMBOLS]u8 = [_]u8{0} ** MAX_SYMBOLS,
    quote_assets: [MAX_SYMBOLS][MAX_ASSET_LEN]u8 = undefined,
    quote_lens: [MAX_SYMBOLS]u8 = [_]u8{0} ** MAX_SYMBOLS,
    symbol_count: u32 = 0,

    // ── Intervals ──
    intervals: [MAX_INTERVALS][MAX_INTERVAL_LEN]u8 = undefined,
    interval_lens: [MAX_INTERVALS]u8 = [_]u8{0} ** MAX_INTERVALS,
    interval_count: u32 = 0,

    // ── Status ──
    connected: u32 = 0, // atomic: 1 = connected
    ready: u32 = 0, // atomic: 1 = metadata loaded
    loading: u32 = 0, // atomic: 1 = fetch in progress

    // ── Display ──
    name_buf: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,

    /// Get the source display name
    pub fn displayName(self: *const SourceMetadata) []const u8 {
        if (self.name_len == 0) return "unknown";
        return self.name_buf[0..self.name_len];
    }

    /// Set the source display name
    pub fn setName(self: *SourceMetadata, name: []const u8) void {
        const n = @min(name.len, 32);
        @memcpy(self.name_buf[0..n], name[0..n]);
        self.name_len = @intCast(n);
    }

    /// Get symbol string at index
    pub fn getSymbol(self: *const SourceMetadata, idx: usize) []const u8 {
        if (idx >= self.symbol_count) return "";
        return self.symbols[idx][0..self.sym_lens[idx]];
    }

    /// Get base asset at index
    pub fn getBase(self: *const SourceMetadata, idx: usize) []const u8 {
        if (idx >= self.symbol_count) return "";
        return self.base_assets[idx][0..self.base_lens[idx]];
    }

    /// Get quote asset at index
    pub fn getQuote(self: *const SourceMetadata, idx: usize) []const u8 {
        if (idx >= self.symbol_count) return "";
        return self.quote_assets[idx][0..self.quote_lens[idx]];
    }

    /// Add a symbol with base/quote assets. The canonical symbol name is
    /// constructed from base+quote (uppercase, no separator), ignoring
    /// whatever native format the source uses. Returns false if full.
    pub fn addSymbolPair(self: *SourceMetadata, _: []const u8, base: []const u8, quote: []const u8) bool {
        if (self.symbol_count >= MAX_SYMBOLS) return false;
        if (base.len > MAX_ASSET_LEN or quote.len > MAX_ASSET_LEN) return false;
        const canon_len = base.len + quote.len;
        if (canon_len > MAX_SYM_LEN) return false;
        const idx = self.symbol_count;
        // Build canonical: uppercase base + uppercase quote
        for (base, 0..) |c, i| {
            self.symbols[idx][i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        for (quote, 0..) |c, i| {
            self.symbols[idx][base.len + i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        self.sym_lens[idx] = @intCast(canon_len);
        // Store base/quote as uppercase
        for (base, 0..) |c, i| {
            self.base_assets[idx][i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        self.base_lens[idx] = @intCast(base.len);
        for (quote, 0..) |c, i| {
            self.quote_assets[idx][i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        self.quote_lens[idx] = @intCast(quote.len);
        self.symbol_count += 1;
        return true;
    }

    /// Add a symbol (legacy, no base/quote). Returns false if full.
    pub fn addSymbol(self: *SourceMetadata, sym: []const u8) bool {
        return self.addSymbolPair(sym, "", "");
    }

    /// Get interval string at index
    pub fn getInterval(self: *const SourceMetadata, idx: usize) []const u8 {
        if (idx >= self.interval_count) return "";
        return self.intervals[idx][0..self.interval_lens[idx]];
    }

    /// Add an interval to the list. Returns false if full.
    pub fn addInterval(self: *SourceMetadata, iv: []const u8) bool {
        if (self.interval_count >= MAX_INTERVALS or iv.len > MAX_INTERVAL_LEN) return false;
        const idx = self.interval_count;
        @memcpy(self.intervals[idx][0..iv.len], iv);
        self.interval_lens[idx] = @intCast(iv.len);
        self.interval_count += 1;
        return true;
    }

    /// Find index of a symbol (case-insensitive). Returns 0 if not found.
    pub fn findSymbol(self: *const SourceMetadata, name: []const u8) usize {
        for (0..self.symbol_count) |i| {
            const sym = self.getSymbol(i);
            if (sym.len == name.len and eqlIgnoreCase(sym, name)) return i;
        }
        return 0;
    }

    /// Find index of an interval. Returns 0 if not found.
    pub fn findInterval(self: *const SourceMetadata, val: []const u8) usize {
        for (0..self.interval_count) |i| {
            const iv = self.getInterval(i);
            if (iv.len == val.len and eqlBytes(iv, val)) return i;
        }
        return 0;
    }

    /// Get base/quote for the current symbol by name lookup
    pub fn findPairAssets(self: *const SourceMetadata, name: []const u8) struct { base: []const u8, quote: []const u8 } {
        const idx = self.findSymbol(name);
        return .{ .base = self.getBase(idx), .quote = self.getQuote(idx) };
    }

    /// Whether metadata is loaded and has content
    pub fn isReady(self: *const SourceMetadata) bool {
        return @atomicLoad(u32, &self.ready, .acquire) == 1;
    }

    /// Whether metadata is currently being fetched
    pub fn isLoading(self: *const SourceMetadata) bool {
        return @atomicLoad(u32, &self.loading, .acquire) == 1;
    }

    /// Whether the source is connected
    pub fn isConnected(self: *const SourceMetadata) bool {
        return @atomicLoad(u32, &self.connected, .acquire) == 1;
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
