// ui_detect — pure color-signature element detection.
// Layer 0: Core. No platform deps, no I/O, no allocation.
//
// General-purpose building block for visual UI automation and image analysis:
// given an RGBA pixel buffer and a target color (with tolerance), find the
// largest connected-ish region of matching pixels and report its bounding box
// and centroid. Callers decide what to do with the result.
//
// The algorithm is a single-pass row-scan accumulator: for every pixel within
// the color tolerance we grow a bounding box and count hits, then require the
// hit count to meet a minimum area and fill ratio. This is intentionally simple
// and allocation-free (O(width*height) time, O(1) space) so it runs in a tight
// daemon loop without a heap.

/// An 8-bit RGB target with a per-channel tolerance.
pub const ColorSignature = struct {
    r: u8,
    g: u8,
    b: u8,
    /// Max absolute per-channel difference for a pixel to count as a match.
    tolerance: u8 = 24,

    pub fn matches(self: ColorSignature, r: u8, g: u8, b: u8) bool {
        return absDiff(self.r, r) <= self.tolerance and
            absDiff(self.g, g) <= self.tolerance and
            absDiff(self.b, b) <= self.tolerance;
    }
};

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// Constraints a candidate region must satisfy to be reported as a match.
pub const DetectParams = struct {
    signature: ColorSignature,
    /// Minimum number of matching pixels for the region to be considered real.
    min_area: u32 = 400,
    /// Minimum fraction (0..1000 per-mille) of the bounding box that must be
    /// matching pixels — filters out sparse noise scattered across the image.
    min_fill_permille: u32 = 500,
};

pub const Match = struct {
    found: bool = false,
    /// Centroid of matching pixels (buffer-local coordinates, top-left origin).
    center_x: u32 = 0,
    center_y: u32 = 0,
    /// Bounding box of matching pixels.
    min_x: u32 = 0,
    min_y: u32 = 0,
    max_x: u32 = 0,
    max_y: u32 = 0,
    /// Number of matching pixels.
    area: u32 = 0,
};

/// Scan a tightly-packed RGBA buffer (`width*height*4` bytes, row-major,
/// top-left origin) for the configured color signature.
///
/// Returns the centroid + bounding box of all matching pixels when the region
/// satisfies `min_area` and `min_fill_permille`, otherwise `found = false`.
pub fn detect(pixels: []const u8, width: u32, height: u32, params: DetectParams) Match {
    if (width == 0 or height == 0) return .{};
    if (pixels.len < @as(usize, width) * @as(usize, height) * 4) return .{};

    var count: u32 = 0;
    var sum_x: u64 = 0;
    var sum_y: u64 = 0;
    var min_x: u32 = width;
    var min_y: u32 = height;
    var max_x: u32 = 0;
    var max_y: u32 = 0;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        const row_base: usize = @as(usize, y) * @as(usize, width) * 4;
        while (x < width) : (x += 1) {
            const i = row_base + @as(usize, x) * 4;
            const r = pixels[i];
            const g = pixels[i + 1];
            const b = pixels[i + 2];
            if (params.signature.matches(r, g, b)) {
                count += 1;
                sum_x += x;
                sum_y += y;
                if (x < min_x) min_x = x;
                if (y < min_y) min_y = y;
                if (x > max_x) max_x = x;
                if (y > max_y) max_y = y;
            }
        }
    }

    if (count < params.min_area) return .{};

    const bbox_w = max_x - min_x + 1;
    const bbox_h = max_y - min_y + 1;
    const bbox_area: u64 = @as(u64, bbox_w) * @as(u64, bbox_h);
    if (bbox_area == 0) return .{};

    // fill ratio in per-mille = count * 1000 / bbox_area
    const fill_permille: u64 = (@as(u64, count) * 1000) / bbox_area;
    if (fill_permille < params.min_fill_permille) return .{};

    return .{
        .found = true,
        .center_x = @intCast(sum_x / count),
        .center_y = @intCast(sum_y / count),
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
        .area = count,
    };
}

// ── Multi-region detection ─────────────────────────────────────────
//
// `detect` above merges every matching pixel into one bounding box — it answers
// "where is the target color, as a whole". `detectAll` instead separates the
// matching pixels into distinct connected regions (4-connectivity) and reports
// each region that satisfies `min_area` / `min_fill_permille` independently.
// This is what you want when the same signature can appear more than once on
// screen (e.g. several identical buttons) and you must act on each.
//
// Allocation-free by contract: the caller supplies a `labels` scratch buffer of
// exactly `width*height` u32 entries (used as both a visited-map and an
// explicit flood-fill stack), and an `out` slice that bounds how many regions
// are returned. Time is O(width*height); auxiliary space is the caller's
// scratch. Regions are returned largest-area first (simple selection so callers
// can take the top-k meaningfully without sorting themselves).

/// Scratch size (in u32 entries) that `detectAll` needs for a `width*height`
/// image: one visited-map entry plus one flood-fill-stack slot per pixel.
pub fn scratchLen(width: u32, height: u32) usize {
    return 2 * @as(usize, width) * @as(usize, height);
}

/// Detect every distinct connected region (4-connectivity) matching
/// `params.signature`, returning each that satisfies `min_area` /
/// `min_fill_permille` independently. Regions are written to `out` ranked
/// largest-area first, so callers can meaningfully take the top-k.
///
/// `scratch` MUST have at least `scratchLen(width, height)` entries — the first
/// `width*height` are the visited map, the remainder an explicit DFS stack.
/// Heap-free and O(width*height): each pixel is visited and pushed at most once.
/// Returns the number of qualifying regions written to `out` (capped at
/// `out.len`); returns 0 if `scratch` is too small.
pub fn detectAll(
    pixels: []const u8,
    width: u32,
    height: u32,
    params: DetectParams,
    scratch: []u32,
    out: []Match,
) usize {
    if (width == 0 or height == 0 or out.len == 0) return 0;
    const npix: usize = @as(usize, width) * @as(usize, height);
    if (pixels.len < npix * 4) return 0;
    if (scratch.len < 2 * npix) return 0;

    const visited = scratch[0..npix]; // 0 = unvisited, 1 = visited
    const stack = scratch[npix .. 2 * npix]; // explicit DFS stack of pixel indices

    var i: usize = 0;
    while (i < npix) : (i += 1) visited[i] = 0;

    var found: usize = 0;

    var start: usize = 0;
    while (start < npix) : (start += 1) {
        if (visited[start] != 0) continue;
        if (!matchAt(pixels, start, params.signature)) {
            visited[start] = 1;
            continue;
        }

        var region = regionFloodFill(pixels, width, height, params.signature, start, visited, stack);

        if (region.match.area >= params.min_area) {
            const bbox_w = region.max_x - region.min_x + 1;
            const bbox_h = region.max_y - region.min_y + 1;
            const bbox_area: u64 = @as(u64, bbox_w) * @as(u64, bbox_h);
            if (bbox_area != 0) {
                const fill_permille: u64 = (@as(u64, region.match.area) * 1000) / bbox_area;
                if (fill_permille >= params.min_fill_permille) {
                    region.match.found = true;
                    insertRankedByArea(out, &found, region.match);
                }
            }
        }
    }

    return found;
}

const RegionResult = struct { match: Match, min_x: u32, min_y: u32, max_x: u32, max_y: u32 };

/// Iterative 4-connected flood fill from `start` using an explicit `stack` of
/// pixel indices (no recursion, no heap). Every matching pixel reachable from
/// `start` is marked visited(1); the region's area, bounding box, and centroid
/// are accumulated. O(region size); each pixel is pushed at most once.
fn regionFloodFill(
    pixels: []const u8,
    width: u32,
    height: u32,
    sig: ColorSignature,
    start: usize,
    visited: []u32,
    stack: []u32,
) RegionResult {
    var count: u32 = 0;
    var sum_x: u64 = 0;
    var sum_y: u64 = 0;
    var min_x: u32 = width;
    var min_y: u32 = height;
    var max_x: u32 = 0;
    var max_y: u32 = 0;

    var sp: usize = 0;
    visited[start] = 1;
    stack[sp] = @intCast(start);
    sp += 1;

    while (sp > 0) {
        sp -= 1;
        const idx: usize = stack[sp];
        const x: u32 = @intCast(idx % width);
        const y: u32 = @intCast(idx / width);

        count += 1;
        sum_x += x;
        sum_y += y;
        if (x < min_x) min_x = x;
        if (y < min_y) min_y = y;
        if (x > max_x) max_x = x;
        if (y > max_y) max_y = y;

        if (x > 0) sp = pushIfMatch(pixels, sig, idx - 1, visited, stack, sp);
        if (x + 1 < width) sp = pushIfMatch(pixels, sig, idx + 1, visited, stack, sp);
        if (y > 0) sp = pushIfMatch(pixels, sig, idx - width, visited, stack, sp);
        if (y + 1 < height) sp = pushIfMatch(pixels, sig, idx + width, visited, stack, sp);
    }

    var m: Match = .{};
    m.center_x = @intCast(sum_x / count);
    m.center_y = @intCast(sum_y / count);
    m.min_x = min_x;
    m.min_y = min_y;
    m.max_x = max_x;
    m.max_y = max_y;
    m.area = count;
    return .{ .match = m, .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

/// If `idx` is unvisited: mark it visited, and if it matches push it. Returns
/// the new stack pointer. Non-matches are marked visited so they are skipped
/// forever (labels them 1) without being pushed.
fn pushIfMatch(pixels: []const u8, sig: ColorSignature, idx: usize, visited: []u32, stack: []u32, sp: usize) usize {
    if (visited[idx] != 0) return sp;
    visited[idx] = 1;
    if (!matchAt(pixels, idx, sig)) return sp;
    stack[sp] = @intCast(idx);
    return sp + 1;
}

/// Whether the pixel at flat index `idx` matches the signature.
fn matchAt(pixels: []const u8, idx: usize, sig: ColorSignature) bool {
    const p = idx * 4;
    return sig.matches(pixels[p], pixels[p + 1], pixels[p + 2]);
}

/// Insert `m` into `out[0..*n]` keeping it sorted by descending area, capped at
/// `out.len`. Keeps the top-k largest regions when more than `out.len` qualify.
fn insertRankedByArea(out: []Match, n: *usize, m: Match) void {
    // Find insertion position.
    var pos: usize = 0;
    while (pos < n.* and out[pos].area >= m.area) : (pos += 1) {}
    if (pos >= out.len) return; // smaller than everything we already keep

    // Shift down (drop the last if full).
    var end: usize = if (n.* < out.len) n.* else out.len - 1;
    while (end > pos) : (end -= 1) out[end] = out[end - 1];
    out[pos] = m;
    if (n.* < out.len) n.* += 1;
}

// ── Template matching ──────────────────────────────────────────────
//
// Color-signature detection answers "where is this color". Template matching
// answers "where is this little picture" — it slides a small grayscale template
// over the image and reports the best-correlating location. It is robust to
// uniform brightness/contrast shifts because it uses the zero-mean normalized
// cross-correlation (NCC) score in [-1, 1], where 1 is a perfect match.
//
// Layer 0 and allocation-free: the template is a caller-provided grayscale
// buffer; no buffers are allocated. Cost is O(img_w*img_h*tpl_w*tpl_h) in the
// naive form used here — fine for the small templates (icons, glyphs, cursors)
// this is meant for. Callers cap template size accordingly.

pub const Template = struct {
    /// Row-major grayscale samples, `w*h` bytes.
    pixels: []const u8,
    w: u32,
    h: u32,
};

pub const TemplateMatch = struct {
    found: bool = false,
    /// Top-left of the best match in image coordinates.
    x: u32 = 0,
    y: u32 = 0,
    /// Center of the matched template region (convenience for clicking).
    center_x: u32 = 0,
    center_y: u32 = 0,
    /// NCC score in [-1000, 1000] (per-mille of the [-1,1] correlation).
    score_permille: i32 = 0,
};

/// Convert one RGBA pixel to a luma byte (BT.601 luma, integer).
fn lumaAt(pixels: []const u8, idx: usize) u8 {
    const p = idx * 4;
    const r: u32 = pixels[p];
    const g: u32 = pixels[p + 1];
    const b: u32 = pixels[p + 2];
    return @intCast((r * 77 + g * 150 + b * 29) >> 8);
}

/// Slide `tpl` over the RGBA `pixels` image and return the best NCC location.
/// `min_score_permille` gates the result (e.g. 700 ≈ 0.70 correlation). Returns
/// `found = false` if nothing clears the threshold or inputs are degenerate.
pub fn matchTemplate(
    pixels: []const u8,
    width: u32,
    height: u32,
    tpl: Template,
    min_score_permille: i32,
) TemplateMatch {
    if (width == 0 or height == 0 or tpl.w == 0 or tpl.h == 0) return .{};
    if (tpl.w > width or tpl.h > height) return .{};
    if (pixels.len < @as(usize, width) * @as(usize, height) * 4) return .{};
    if (tpl.pixels.len < @as(usize, tpl.w) * @as(usize, tpl.h)) return .{};

    const tn: u32 = tpl.w * tpl.h;

    // Precompute template mean and variance-sum (constant across positions).
    var tsum: u64 = 0;
    {
        var i: u32 = 0;
        while (i < tn) : (i += 1) tsum += tpl.pixels[i];
    }
    const tmean: i64 = @intCast(tsum / tn);
    var tvar: i64 = 0;
    {
        var i: u32 = 0;
        while (i < tn) : (i += 1) {
            const d: i64 = @as(i64, tpl.pixels[i]) - tmean;
            tvar += d * d;
        }
    }
    if (tvar == 0) return .{}; // flat template — NCC undefined

    var best_score: i32 = -1001;
    var best_x: u32 = 0;
    var best_y: u32 = 0;

    var oy: u32 = 0;
    while (oy + tpl.h <= height) : (oy += 1) {
        var ox: u32 = 0;
        while (ox + tpl.w <= width) : (ox += 1) {
            // Window mean.
            var wsum: u64 = 0;
            var ty: u32 = 0;
            while (ty < tpl.h) : (ty += 1) {
                const irow: usize = @as(usize, oy + ty) * @as(usize, width) + ox;
                var tx: u32 = 0;
                while (tx < tpl.w) : (tx += 1) wsum += lumaAt(pixels, irow + tx);
            }
            const wmean: i64 = @intCast(wsum / tn);

            // Correlation numerator and window variance.
            var num: i64 = 0;
            var wvar: i64 = 0;
            ty = 0;
            while (ty < tpl.h) : (ty += 1) {
                const irow: usize = @as(usize, oy + ty) * @as(usize, width) + ox;
                const trow: usize = @as(usize, ty) * @as(usize, tpl.w);
                var tx: u32 = 0;
                while (tx < tpl.w) : (tx += 1) {
                    const iv: i64 = @as(i64, lumaAt(pixels, irow + tx)) - wmean;
                    const tv: i64 = @as(i64, tpl.pixels[trow + tx]) - tmean;
                    num += iv * tv;
                    wvar += iv * iv;
                }
            }
            if (wvar == 0) continue; // flat window

            // NCC = num / sqrt(tvar * wvar). Scale to per-mille without floats.
            const denom = isqrt(@as(u64, @intCast(tvar)) * @as(u64, @intCast(wvar)));
            if (denom == 0) continue;
            const score: i32 = @intCast(@divTrunc(num * 1000, @as(i64, @intCast(denom))));
            if (score > best_score) {
                best_score = score;
                best_x = ox;
                best_y = oy;
            }
        }
    }

    if (best_score < min_score_permille) return .{};
    return .{
        .found = true,
        .x = best_x,
        .y = best_y,
        .center_x = best_x + tpl.w / 2,
        .center_y = best_y + tpl.h / 2,
        .score_permille = best_score,
    };
}

/// Integer square root (floor), heap-free.
fn isqrt(n: u64) u64 {
    if (n == 0) return 0;
    var x: u64 = n;
    var y: u64 = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}

// ── Fast multi-location template matching ──────────────────────────
//
// `matchTemplate` above is correct but O(img · tpl) with the window mean and
// variance recomputed at every position — far too slow to run over a full
// screen capture in a tight loop. `matchTemplateAll` fixes both problems and
// additionally returns *every* place the template appears (not just the best),
// which is what "click all matching buttons" needs.
//
// Two speedups, both allocation-free (caller passes scratch):
//   1. Integral images. A summed-area table of luma and of luma² makes each
//      window's sum and sum-of-squares an O(1) lookup instead of an O(tpl)
//      loop — so window mean and variance cost nothing per position.
//   2. Coarse-to-fine. The correlation numerator still needs one pass over the
//      template, so we evaluate it only on a strided grid first, then refine
//      ±stride around the strong coarse hits at full resolution.
// Overlapping detections of the same button are collapsed by non-maximum
// suppression so each physical element yields a single click target.

/// Number of i64 scratch entries `matchTemplateAll` needs for a `width*height`
/// image: two integral images, each (width+1)*(height+1).
pub fn templateScratchLen(width: u32, height: u32) usize {
    const iw: usize = @as(usize, width) + 1;
    const ih: usize = @as(usize, height) + 1;
    return 2 * iw * ih;
}

/// Find every location where `tpl` matches at or above `min_score_permille`.
/// Results are written to `out` ranked by descending score, de-duplicated by
/// non-maximum suppression (one hit per physical match). `scratch` must have at
/// least `templateScratchLen(width, height)` i64 entries. Returns the count.
///
/// Allocation-free and fast: integral-image window stats + a strided coarse
/// search refined around candidates.
pub fn matchTemplateAll(
    pixels: []const u8,
    width: u32,
    height: u32,
    tpl: Template,
    min_score_permille: i32,
    scratch: []i64,
    out: []TemplateMatch,
) usize {
    if (width == 0 or height == 0 or tpl.w == 0 or tpl.h == 0 or out.len == 0) return 0;
    if (tpl.w > width or tpl.h > height) return 0;
    if (pixels.len < @as(usize, width) * @as(usize, height) * 4) return 0;
    if (tpl.pixels.len < @as(usize, tpl.w) * @as(usize, tpl.h)) return 0;
    if (scratch.len < templateScratchLen(width, height)) return 0;

    const iw: usize = @as(usize, width) + 1;
    const ih: usize = @as(usize, height) + 1;
    const sat = scratch[0 .. iw * ih]; // Σ luma
    const sat2 = scratch[iw * ih .. 2 * iw * ih]; // Σ luma²

    buildIntegrals(pixels, width, height, sat, sat2, iw);

    const tn: u32 = tpl.w * tpl.h;
    // Template mean and variance-sum (constant across positions).
    var tsum: i64 = 0;
    {
        var i: u32 = 0;
        while (i < tn) : (i += 1) tsum += tpl.pixels[i];
    }
    const tmean: i64 = @divTrunc(tsum, tn);
    var tvar: i64 = 0;
    {
        var i: u32 = 0;
        while (i < tn) : (i += 1) {
            const d: i64 = @as(i64, tpl.pixels[i]) - tmean;
            tvar += d * d;
        }
    }
    if (tvar == 0) return 0; // flat template — NCC undefined

    // Coarse stride: about a quarter of the smaller template dimension, min 1.
    const min_dim = @min(tpl.w, tpl.h);
    const stride: u32 = @max(min_dim / 4, 1);

    var found: usize = 0;

    const max_oy = height - tpl.h;
    const max_ox = width - tpl.w;

    var oy: u32 = 0;
    while (oy <= max_oy) : (oy += stride) {
        var ox: u32 = 0;
        while (ox <= max_ox) : (ox += stride) {
            const coarse = scoreAt(pixels, width, tpl, tmean, tvar, sat, sat2, iw, ox, oy);
            // Only bother refining coarse hits that are already in the ballpark.
            if (coarse < min_score_permille - 150) continue;

            // Refine: search ±stride around the coarse position at full res.
            var best: i32 = coarse;
            var bx: u32 = ox;
            var by: u32 = oy;
            const ry0 = if (oy >= stride) oy - stride else 0;
            const ry1 = @min(oy + stride, max_oy);
            const rx0 = if (ox >= stride) ox - stride else 0;
            const rx1 = @min(ox + stride, max_ox);
            var ry = ry0;
            while (ry <= ry1) : (ry += 1) {
                var rx = rx0;
                while (rx <= rx1) : (rx += 1) {
                    const s = scoreAt(pixels, width, tpl, tmean, tvar, sat, sat2, iw, rx, ry);
                    if (s > best) {
                        best = s;
                        bx = rx;
                        by = ry;
                    }
                }
            }

            if (best < min_score_permille) continue;

            // Non-maximum suppression: skip if this refined hit overlaps an
            // already-accepted match by more than half a template.
            if (overlapsExisting(out[0..found], bx, by, tpl.w, tpl.h)) continue;

            insertRankedByScore(out, &found, .{
                .found = true,
                .x = bx,
                .y = by,
                .center_x = bx + tpl.w / 2,
                .center_y = by + tpl.h / 2,
                .score_permille = best,
            });
        }
    }

    return found;
}

/// Build summed-area tables of luma and luma² over the RGBA image.
/// `sat`/`sat2` are (width+1)*(height+1); row/col 0 are zero padding so window
/// sums are a 4-point lookup with no bounds special-casing.
fn buildIntegrals(pixels: []const u8, width: u32, height: u32, sat: []i64, sat2: []i64, iw: usize) void {
    // Zero the top padding row.
    var c: usize = 0;
    while (c < iw) : (c += 1) {
        sat[c] = 0;
        sat2[c] = 0;
    }
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_out = (@as(usize, y) + 1) * iw;
        const row_prev = @as(usize, y) * iw;
        sat[row_out] = 0; // left padding column
        sat2[row_out] = 0;
        var row_sum: i64 = 0;
        var row_sum2: i64 = 0;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const l: i64 = lumaAt(pixels, @as(usize, y) * @as(usize, width) + x);
            row_sum += l;
            row_sum2 += l * l;
            const o = row_out + x + 1;
            sat[o] = sat[row_prev + x + 1] + row_sum;
            sat2[o] = sat2[row_prev + x + 1] + row_sum2;
        }
    }
}

/// O(1) rectangle sum from a summed-area table at (ox,oy) size (tw,th).
fn rectSum(sat: []i64, iw: usize, ox: u32, oy: u32, tw: u32, th: u32) i64 {
    const x0: usize = ox;
    const y0: usize = oy;
    const x1: usize = ox + tw;
    const y1: usize = oy + th;
    return sat[y1 * iw + x1] - sat[y0 * iw + x1] - sat[y1 * iw + x0] + sat[y0 * iw + x0];
}

/// NCC score (per-mille) of the template against the window at (ox,oy). Uses
/// the integral images for the window mean/variance (O(1)) and one template
/// pass for the correlation numerator.
fn scoreAt(
    pixels: []const u8,
    width: u32,
    tpl: Template,
    tmean: i64,
    tvar: i64,
    sat: []i64,
    sat2: []i64,
    iw: usize,
    ox: u32,
    oy: u32,
) i32 {
    const tn: i64 = @intCast(tpl.w * tpl.h);
    const wsum = rectSum(sat, iw, ox, oy, tpl.w, tpl.h);
    const wsum2 = rectSum(sat2, iw, ox, oy, tpl.w, tpl.h);
    // Window variance-sum = Σx² - (Σx)²/n.
    const wvar: i64 = wsum2 - @divTrunc(wsum * wsum, tn);
    if (wvar <= 0) return -1001;
    const wmean: i64 = @divTrunc(wsum, tn);

    // Correlation numerator: Σ (I-wmean)(T-tmean).
    var num: i64 = 0;
    var ty: u32 = 0;
    while (ty < tpl.h) : (ty += 1) {
        const irow: usize = @as(usize, oy + ty) * @as(usize, width) + ox;
        const trow: usize = @as(usize, ty) * @as(usize, tpl.w);
        var tx: u32 = 0;
        while (tx < tpl.w) : (tx += 1) {
            const iv: i64 = @as(i64, lumaAt(pixels, irow + tx)) - wmean;
            const tv: i64 = @as(i64, tpl.pixels[trow + tx]) - tmean;
            num += iv * tv;
        }
    }

    const denom = isqrt(@as(u64, @intCast(tvar)) * @as(u64, @intCast(wvar)));
    if (denom == 0) return -1001;
    var score: i64 = @divTrunc(num * 1000, @as(i64, @intCast(denom)));
    // NCC is mathematically bounded to [-1,1]; integer-mean truncation in the
    // per-pixel numerator vs. the exact integral-image variance can push the
    // ratio slightly past ±1000 (badly so for near-flat templates where denom
    // is tiny). Clamp to keep scores valid and comparable to min_score_permille.
    if (score > 1000) score = 1000;
    if (score < -1000) score = -1000;
    return @intCast(score);
}

/// True if (x,y) is within half a template of any already-accepted match.
fn overlapsExisting(existing: []const TemplateMatch, x: u32, y: u32, tw: u32, th: u32) bool {
    const hx = tw / 2;
    const hy = th / 2;
    for (existing) |e| {
        const dx = if (e.x > x) e.x - x else x - e.x;
        const dy = if (e.y > y) e.y - y else y - e.y;
        if (dx <= hx and dy <= hy) return true;
    }
    return false;
}

/// Insert into `out[0..*n]` sorted by descending score, capped at out.len.
fn insertRankedByScore(out: []TemplateMatch, n: *usize, m: TemplateMatch) void {
    var pos: usize = 0;
    while (pos < n.* and out[pos].score_permille >= m.score_permille) : (pos += 1) {}
    if (pos >= out.len) return;
    var end: usize = if (n.* < out.len) n.* else out.len - 1;
    while (end > pos) : (end -= 1) out[end] = out[end - 1];
    out[pos] = m;
    if (n.* < out.len) n.* += 1;
}

// ── Edge-based chamfer shape matching ──────────────────────────────
//
// NCC template matching keys on a region's raw texture, which fails for a
// solid-fill UI button: its flat interior has almost no variance, so NCC
// saturates against any similarly-flat region (a purple button and a purple
// code panel score alike). Color matching fails the same way — every purple
// thing matches.
//
// What actually makes a button that button is its SHAPE: a rounded rectangle of
// a specific size with specific glyph edges ("Allow") inside. Chamfer matching
// scores that shape directly and ignores fill color and brightness:
//
//   1. Sobel gradient magnitude on both template and window, thresholded to a
//      binary EDGE map (button border + text strokes survive; flat fills do
//      not).
//   2. A distance transform of the window edge map: every pixel holds the
//      (approx) distance to the nearest window edge.
//   3. Slide the template's edge points over the window; the score is the mean
//      distance from each template edge to the nearest window edge. When the
//      button's outline+text line up, that mean is near zero.
//
// This is discriminative (random UI regions lack the button's edge structure),
// robust to color/brightness/anti-aliasing (edges survive rendering variation),
// and integer-only / allocation-free (caller provides scratch). Scale is not a
// concern here because the template is cropped from a capture at the same
// physical resolution the window is captured at.

/// Scratch (u16 entries) that chamfer matching needs for a `width*height`
/// window: an edge map and a distance-transform buffer, one entry per pixel.
pub fn chamferScratchLen(width: u32, height: u32) usize {
    return 2 * @as(usize, width) * @as(usize, height);
}

/// A template prepared for chamfer matching: its dimensions plus the list of
/// edge-point offsets (x,y within the template). Built once by `prepareTemplate`
/// from a grayscale template; the caller owns the `points` storage.
pub const EdgeTemplate = struct {
    w: u32,
    h: u32,
    points: []const EdgePoint,
};
pub const EdgePoint = struct { x: u16, y: u16 };

/// Sobel gradient magnitude at (x,y) in a grayscale-sampled image, where
/// `lumaFn(idx)` yields the 0..255 luma of pixel index idx. Interior pixels
/// only (caller guards the border).
fn sobelMagRGBA(pixels: []const u8, width: u32, x: u32, y: u32) u32 {
    const i = @as(usize, y) * @as(usize, width) + x;
    const tl: i32 = lumaAt(pixels, i - width - 1);
    const tc: i32 = lumaAt(pixels, i - width);
    const tr: i32 = lumaAt(pixels, i - width + 1);
    const ml: i32 = lumaAt(pixels, i - 1);
    const mr: i32 = lumaAt(pixels, i + 1);
    const bl: i32 = lumaAt(pixels, i + width - 1);
    const bc: i32 = lumaAt(pixels, i + width);
    const br: i32 = lumaAt(pixels, i + width + 1);
    const gx = (tr + 2 * mr + br) - (tl + 2 * ml + bl);
    const gy = (bl + 2 * bc + br) - (tl + 2 * tc + tr);
    const ax: u32 = @intCast(if (gx < 0) -gx else gx);
    const ay: u32 = @intCast(if (gy < 0) -gy else gy);
    return ax + ay; // L1 approximation of the gradient magnitude
}

/// Extract the template's edge points (Sobel magnitude >= edge_threshold) into
/// `out_points`. Returns the number of edge points found (capped at
/// out_points.len). The template `pixels` are RGBA (width*height*4).
pub fn prepareTemplate(
    pixels: []const u8,
    width: u32,
    height: u32,
    edge_threshold: u32,
    out_points: []EdgePoint,
) usize {
    if (width < 3 or height < 3) return 0;
    if (pixels.len < @as(usize, width) * @as(usize, height) * 4) return 0;
    var count: usize = 0;
    var y: u32 = 1;
    while (y < height - 1 and count < out_points.len) : (y += 1) {
        var x: u32 = 1;
        while (x < width - 1 and count < out_points.len) : (x += 1) {
            if (sobelMagRGBA(pixels, width, x, y) >= edge_threshold) {
                out_points[count] = .{ .x = @intCast(x), .y = @intCast(y) };
                count += 1;
            }
        }
    }
    return count;
}

const DIST_MAX: u16 = 0xffff;
// Chamfer 3-4 distance weights: orthogonal step = 3, diagonal step = 4 (an
// integer approximation of 1 : sqrt(2), scaled ×3).
const DIST_ORTH: u16 = 3;
const DIST_DIAG: u16 = 4;

/// Build a binary edge map of the window (Sobel >= threshold) then its two-pass
/// chamfer distance transform, both into `scratch`. Returns the distance-
/// transform slice (values are 3× the pixel distance to the nearest edge).
fn buildDistanceTransform(pixels: []const u8, width: u32, height: u32, edge_threshold: u32, scratch: []u16) []u16 {
    const npix: usize = @as(usize, width) * @as(usize, height);
    const dist = scratch[0..npix];

    // Seed: 0 at edges, DIST_MAX elsewhere. Border pixels (no full 3x3) are
    // treated as non-edges.
    var i: usize = 0;
    while (i < npix) : (i += 1) dist[i] = DIST_MAX;
    var y: u32 = 1;
    while (y < height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < width - 1) : (x += 1) {
            if (sobelMagRGBA(pixels, width, x, y) >= edge_threshold) dist[@as(usize, y) * width + x] = 0;
        }
    }

    // Forward pass (top-left -> bottom-right).
    y = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = @as(usize, y) * width + x;
            var d = dist[idx];
            if (x > 0) d = minU16(d, satAdd(dist[idx - 1], DIST_ORTH));
            if (y > 0) d = minU16(d, satAdd(dist[idx - width], DIST_ORTH));
            if (x > 0 and y > 0) d = minU16(d, satAdd(dist[idx - width - 1], DIST_DIAG));
            if (x + 1 < width and y > 0) d = minU16(d, satAdd(dist[idx - width + 1], DIST_DIAG));
            dist[idx] = d;
        }
    }
    // Backward pass (bottom-right -> top-left).
    y = height;
    while (y > 0) {
        y -= 1;
        var x: u32 = width;
        while (x > 0) {
            x -= 1;
            const idx = @as(usize, y) * width + x;
            var d = dist[idx];
            if (x + 1 < width) d = minU16(d, satAdd(dist[idx + 1], DIST_ORTH));
            if (y + 1 < height) d = minU16(d, satAdd(dist[idx + width], DIST_ORTH));
            if (x + 1 < width and y + 1 < height) d = minU16(d, satAdd(dist[idx + width + 1], DIST_DIAG));
            if (x > 0 and y + 1 < height) d = minU16(d, satAdd(dist[idx + width - 1], DIST_DIAG));
            dist[idx] = d;
        }
    }
    return dist;
}

fn minU16(a: u16, b: u16) u16 {
    return if (a < b) a else b;
}
fn satAdd(a: u16, b: u16) u16 {
    const s: u32 = @as(u32, a) + b;
    return if (s >= DIST_MAX) DIST_MAX else @intCast(s);
}

/// Mean chamfer distance (×3, per the 3-4 metric) of the template's edge points
/// placed at window offset (ox,oy). Lower = better shape alignment.
fn chamferScoreAt(dist: []const u16, width: u32, tpl: EdgeTemplate, ox: u32, oy: u32) u32 {
    if (tpl.points.len == 0) return DIST_MAX;
    var sum: u64 = 0;
    for (tpl.points) |p| {
        const wx = ox + p.x;
        const wy = oy + p.y;
        sum += dist[@as(usize, wy) * width + wx];
    }
    return @intCast(sum / tpl.points.len);
}

/// Find every window location whose shape matches the edge template with a mean
/// chamfer distance at or below what `min_confidence_permille` implies. Results
/// are ranked best-first and de-duplicated by non-maximum suppression.
///
/// `scratch` needs `chamferScratchLen(width,height)` u16 entries. Confidence is
/// reported in `score_permille` (1000 = perfect shape alignment); it is derived
/// from the mean edge distance so it is directly comparable across windows.
pub fn matchEdgeTemplateAll(
    pixels: []const u8,
    width: u32,
    height: u32,
    tpl: EdgeTemplate,
    edge_threshold: u32,
    min_confidence_permille: i32,
    scratch: []u16,
    out: []TemplateMatch,
) usize {
    if (width == 0 or height == 0 or tpl.w == 0 or tpl.h == 0 or out.len == 0) return 0;
    if (tpl.w > width or tpl.h > height or tpl.points.len == 0) return 0;
    if (pixels.len < @as(usize, width) * @as(usize, height) * 4) return 0;
    if (scratch.len < chamferScratchLen(width, height)) return 0;

    const npix: usize = @as(usize, width) * @as(usize, height);
    const dist = buildDistanceTransform(pixels, width, height, edge_threshold, scratch[0..npix]);

    const max_ox = width - tpl.w;
    const max_oy = height - tpl.h;
    const min_dim = @min(tpl.w, tpl.h);
    const stride: u32 = @max(min_dim / 4, 1);

    var found: usize = 0;

    var oy: u32 = 0;
    while (oy <= max_oy) : (oy += stride) {
        var ox: u32 = 0;
        while (ox <= max_ox) : (ox += stride) {
            const coarse = chamferScoreAt(dist, width, tpl, ox, oy);
            const coarse_conf = distanceToConfidence(coarse);
            if (coarse_conf < min_confidence_permille - 200) continue;

            // Refine ±stride at full resolution to find the local best.
            var best_dist: u32 = coarse;
            var bx: u32 = ox;
            var by: u32 = oy;
            const ry0 = if (oy >= stride) oy - stride else 0;
            const ry1 = @min(oy + stride, max_oy);
            const rx0 = if (ox >= stride) ox - stride else 0;
            const rx1 = @min(ox + stride, max_ox);
            var ry = ry0;
            while (ry <= ry1) : (ry += 1) {
                var rx = rx0;
                while (rx <= rx1) : (rx += 1) {
                    const d = chamferScoreAt(dist, width, tpl, rx, ry);
                    if (d < best_dist) {
                        best_dist = d;
                        bx = rx;
                        by = ry;
                    }
                }
            }

            const conf = distanceToConfidence(best_dist);
            if (conf < min_confidence_permille) continue;
            if (overlapsExisting(out[0..found], bx, by, tpl.w, tpl.h)) continue;

            insertRankedByScore(out, &found, .{
                .found = true,
                .x = bx,
                .y = by,
                .center_x = bx + tpl.w / 2,
                .center_y = by + tpl.h / 2,
                .score_permille = conf,
            });
        }
    }
    return found;
}

/// Map a mean chamfer distance (×3 units) to a 0..1000 confidence. A mean
/// distance of 0 (every template edge lands exactly on a window edge) = 1000;
/// confidence falls off linearly and hits 0 at a mean distance of ~10 px
/// (30 in ×3 units). Chosen so a well-aligned button scores high while a
/// coincidental partial overlap does not.
fn distanceToConfidence(mean_dist_x3: u32) i32 {
    const zero_at: u32 = 30; // ×3 units == 10px mean distance
    if (mean_dist_x3 >= zero_at) return 0;
    return @intCast(1000 - (mean_dist_x3 * 1000) / zero_at);
}

// ── Tests ──────────────────────────────────────────────────────────

const std = @import("std");

fn setPixel(buf: []u8, width: u32, x: u32, y: u32, r: u8, g: u8, b: u8) void {
    const i = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
    buf[i] = r;
    buf[i + 1] = g;
    buf[i + 2] = b;
    buf[i + 3] = 255;
}

test "empty buffer yields no match" {
    const m = detect(&.{}, 0, 0, .{ .signature = .{ .r = 128, .g = 100, .b = 220 } });
    try std.testing.expect(!m.found);
}

test "solid purple block is detected with correct centroid" {
    const w: u32 = 40;
    const h: u32 = 20;
    var buf: [w * h * 4]u8 = @splat(0);
    // Fill a 10x8 purple rectangle at (15,6)..(24,13).
    var y: u32 = 6;
    while (y <= 13) : (y += 1) {
        var x: u32 = 15;
        while (x <= 24) : (x += 1) setPixel(&buf, w, x, y, 124, 92, 219);
    }
    const m = detect(&buf, w, h, .{
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 20 },
        .min_area = 50,
        .min_fill_permille = 800,
    });
    try std.testing.expect(m.found);
    // centroid of 15..24 = 19.5 -> 19 (integer), 6..13 = 9.5 -> 9
    try std.testing.expectEqual(@as(u32, 19), m.center_x);
    try std.testing.expectEqual(@as(u32, 9), m.center_y);
    try std.testing.expectEqual(@as(u32, 80), m.area);
}

test "color outside tolerance is rejected" {
    const w: u32 = 16;
    const h: u32 = 16;
    var buf: [w * h * 4]u8 = @splat(0);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) setPixel(&buf, w, x, y, 10, 200, 10); // green
    }
    const m = detect(&buf, w, h, .{
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 20 },
        .min_area = 10,
    });
    try std.testing.expect(!m.found);
}

test "sparse scattered matches fail the fill ratio" {
    const w: u32 = 32;
    const h: u32 = 32;
    var buf: [w * h * 4]u8 = @splat(0);
    // Two far-apart purple pixels: large bbox, tiny fill.
    setPixel(&buf, w, 1, 1, 124, 92, 219);
    setPixel(&buf, w, 30, 30, 124, 92, 219);
    const m = detect(&buf, w, h, .{
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 20 },
        .min_area = 2,
        .min_fill_permille = 500,
    });
    try std.testing.expect(!m.found);
}

fn fillRect(buf: []u8, width: u32, x0: u32, y0: u32, x1: u32, y1: u32, r: u8, g: u8, b: u8) void {
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) setPixel(buf, width, x, y, r, g, b);
    }
}

test "detectAll separates two identical purple blocks" {
    const w: u32 = 64;
    const h: u32 = 32;
    var buf: [w * h * 4]u8 = @splat(0);
    // Two 8x8 purple blocks, well separated.
    fillRect(&buf, w, 4, 4, 11, 11, 124, 92, 219); // area 64, center (7,7)
    fillRect(&buf, w, 40, 20, 51, 27, 124, 92, 219); // area 96, center (45,23)

    var scratch: [scratchLen(w, h)]u32 = undefined;
    var out: [8]Match = undefined;
    const n = detectAll(&buf, w, h, .{
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 20 },
        .min_area = 32,
        .min_fill_permille = 800,
    }, &scratch, &out);

    try std.testing.expectEqual(@as(usize, 2), n);
    // Ranked largest-area first: the 12x8 block (96) before the 8x8 (64).
    try std.testing.expectEqual(@as(u32, 96), out[0].area);
    try std.testing.expectEqual(@as(u32, 45), out[0].center_x);
    try std.testing.expectEqual(@as(u32, 23), out[0].center_y);
    try std.testing.expectEqual(@as(u32, 64), out[1].area);
    try std.testing.expectEqual(@as(u32, 7), out[1].center_x);
    try std.testing.expectEqual(@as(u32, 7), out[1].center_y);
}

test "detectAll caps output at out.len keeping largest regions" {
    const w: u32 = 48;
    const h: u32 = 16;
    var buf: [w * h * 4]u8 = @splat(0);
    // Three blocks of increasing size.
    fillRect(&buf, w, 0, 0, 2, 2, 124, 92, 219); // 9
    fillRect(&buf, w, 10, 0, 14, 4, 124, 92, 219); // 25
    fillRect(&buf, w, 20, 0, 26, 6, 124, 92, 219); // 49

    var scratch: [scratchLen(w, h)]u32 = undefined;
    var out: [2]Match = undefined; // only room for the top 2
    const n = detectAll(&buf, w, h, .{
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 20 },
        .min_area = 4,
        .min_fill_permille = 800,
    }, &scratch, &out);

    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 49), out[0].area);
    try std.testing.expectEqual(@as(u32, 25), out[1].area);
}

test "detectAll respects min_area" {
    const w: u32 = 32;
    const h: u32 = 16;
    var buf: [w * h * 4]u8 = @splat(0);
    fillRect(&buf, w, 2, 2, 3, 3, 124, 92, 219); // area 4 only

    var scratch: [scratchLen(w, h)]u32 = undefined;
    var out: [4]Match = undefined;
    const n = detectAll(&buf, w, h, .{
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 20 },
        .min_area = 16,
        .min_fill_permille = 500,
    }, &scratch, &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

fn setGray(buf: []u8, width: u32, x: u32, y: u32, v: u8) void {
    setPixel(buf, width, x, y, v, v, v);
}

test "matchTemplate finds an exact 3x3 pattern" {
    const w: u32 = 16;
    const h: u32 = 16;
    var buf: [w * h * 4]u8 = @splat(0);
    // Background mid-gray so windows have variance.
    fillRect(&buf, w, 0, 0, w - 1, h - 1, 40, 40, 40);
    // Stamp a bright 3x3 cross-ish block at (9,5).
    const tpl_px = [_]u8{ 10, 200, 10, 200, 250, 200, 10, 200, 10 };
    var ty: u32 = 0;
    while (ty < 3) : (ty += 1) {
        var tx: u32 = 0;
        while (tx < 3) : (tx += 1) setGray(&buf, w, 9 + tx, 5 + ty, tpl_px[ty * 3 + tx]);
    }

    const tpl = Template{ .pixels = &tpl_px, .w = 3, .h = 3 };
    const m = matchTemplate(&buf, w, h, tpl, 900);
    try std.testing.expect(m.found);
    try std.testing.expectEqual(@as(u32, 9), m.x);
    try std.testing.expectEqual(@as(u32, 5), m.y);
    try std.testing.expectEqual(@as(u32, 10), m.center_x); // 9 + 3/2
    try std.testing.expectEqual(@as(u32, 6), m.center_y); // 5 + 3/2
    try std.testing.expect(m.score_permille >= 900);
}

test "matchTemplate is brightness-shift invariant (NCC)" {
    const w: u32 = 12;
    const h: u32 = 12;
    var buf: [w * h * 4]u8 = @splat(0);
    fillRect(&buf, w, 0, 0, w - 1, h - 1, 20, 20, 20);
    // Place a pattern that is the template plus a uniform +60 brightness.
    const base = [_]u8{ 0, 100, 0, 100, 150, 100, 0, 100, 0 };
    var ty: u32 = 0;
    while (ty < 3) : (ty += 1) {
        var tx: u32 = 0;
        while (tx < 3) : (tx += 1) setGray(&buf, w, 4 + tx, 4 + ty, base[ty * 3 + tx] + 60);
    }
    const tpl = Template{ .pixels = &base, .w = 3, .h = 3 };
    const m = matchTemplate(&buf, w, h, tpl, 950);
    // NCC ignores the uniform offset, so this still scores ~1.0.
    try std.testing.expect(m.found);
    try std.testing.expectEqual(@as(u32, 4), m.x);
    try std.testing.expectEqual(@as(u32, 4), m.y);
}

test "matchTemplate rejects when below threshold" {
    const w: u32 = 12;
    const h: u32 = 12;
    var buf: [w * h * 4]u8 = @splat(0);
    // Random-ish gradient, no correlation to the template.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) setGray(&buf, w, x, y, @intCast((x * 7 + y * 13) & 0xff));
    }
    const tpl_px = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255, 0 };
    const tpl = Template{ .pixels = &tpl_px, .w = 3, .h = 3 };
    const m = matchTemplate(&buf, w, h, tpl, 950);
    try std.testing.expect(!m.found);
}

test "isqrt is floor of the square root" {
    try std.testing.expectEqual(@as(u64, 0), isqrt(0));
    try std.testing.expectEqual(@as(u64, 1), isqrt(1));
    try std.testing.expectEqual(@as(u64, 3), isqrt(15));
    try std.testing.expectEqual(@as(u64, 4), isqrt(16));
    try std.testing.expectEqual(@as(u64, 100), isqrt(10000));
}

test "matchTemplateAll finds a single match at the right place" {
    const w: u32 = 40;
    const h: u32 = 40;
    var buf: [w * h * 4]u8 = @splat(0);
    fillRect(&buf, w, 0, 0, w - 1, h - 1, 30, 30, 30);
    // 6x6 bright block at (20,14).
    const ts: u32 = 6;
    var tpx: [ts * ts]u8 = undefined;
    var ty: u32 = 0;
    while (ty < ts) : (ty += 1) {
        var tx: u32 = 0;
        while (tx < ts) : (tx += 1) {
            const v: u8 = if ((tx + ty) % 2 == 0) 230 else 90;
            tpx[ty * ts + tx] = v;
            setGray(&buf, w, 20 + tx, 14 + ty, v);
        }
    }
    const tpl = Template{ .pixels = &tpx, .w = ts, .h = ts };
    var scratch: [templateScratchLen(w, h)]i64 = undefined;
    var out: [8]TemplateMatch = undefined;
    const n = matchTemplateAll(&buf, w, h, tpl, 850, &scratch, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 20), out[0].x);
    try std.testing.expectEqual(@as(u32, 14), out[0].y);
    try std.testing.expect(out[0].score_permille >= 850);
}

test "matchTemplateAll finds multiple copies and suppresses duplicates" {
    const w: u32 = 80;
    const h: u32 = 30;
    var buf: [w * h * 4]u8 = @splat(0);
    fillRect(&buf, w, 0, 0, w - 1, h - 1, 25, 25, 25);
    const ts: u32 = 6;
    var tpx: [ts * ts]u8 = undefined;
    {
        var ty: u32 = 0;
        while (ty < ts) : (ty += 1) {
            var tx: u32 = 0;
            while (tx < ts) : (tx += 1) tpx[ty * ts + tx] = if ((tx * ty) % 3 == 0) 240 else 70;
        }
    }
    // Stamp the same pattern at three separated spots.
    const spots = [_][2]u32{ .{ 4, 12 }, .{ 36, 8 }, .{ 66, 16 } };
    for (spots) |s| {
        var ty: u32 = 0;
        while (ty < ts) : (ty += 1) {
            var tx: u32 = 0;
            while (tx < ts) : (tx += 1) setGray(&buf, w, s[0] + tx, s[1] + ty, tpx[ty * ts + tx]);
        }
    }
    const tpl = Template{ .pixels = &tpx, .w = ts, .h = ts };
    var scratch: [templateScratchLen(w, h)]i64 = undefined;
    var out: [16]TemplateMatch = undefined;
    const n = matchTemplateAll(&buf, w, h, tpl, 850, &scratch, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    // Every reported hit clears the threshold.
    var i: usize = 0;
    while (i < n) : (i += 1) try std.testing.expect(out[i].score_permille >= 850);
}

test "matchTemplateAll agrees with naive matchTemplate on best location" {
    const w: u32 = 50;
    const h: u32 = 50;
    var buf: [w * h * 4]u8 = @splat(0);
    // A textured background so there is real variance everywhere.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) setGray(&buf, w, x, y, @intCast((x * 5 + y * 3) & 0x7f));
    }
    const ts: u32 = 8;
    var tpx: [ts * ts]u8 = undefined;
    var ty: u32 = 0;
    while (ty < ts) : (ty += 1) {
        var tx: u32 = 0;
        while (tx < ts) : (tx += 1) {
            const v: u8 = @intCast(200 - (tx * 10 + ty * 5) % 150);
            tpx[ty * ts + tx] = v;
            setGray(&buf, w, 28 + tx, 33 + ty, v);
        }
    }
    const tpl = Template{ .pixels = &tpx, .w = ts, .h = ts };
    const naive = matchTemplate(&buf, w, h, tpl, 800);
    var scratch: [templateScratchLen(w, h)]i64 = undefined;
    var out: [8]TemplateMatch = undefined;
    const n = matchTemplateAll(&buf, w, h, tpl, 800, &scratch, &out);
    try std.testing.expect(naive.found);
    try std.testing.expect(n >= 1);
    // Fast path's top hit matches the naive best location.
    try std.testing.expectEqual(naive.x, out[0].x);
    try std.testing.expectEqual(naive.y, out[0].y);
}

fn drawRectOutline(buf: []u8, width: u32, x0: u32, y0: u32, x1: u32, y1: u32, v: u8) void {
    var x = x0;
    while (x <= x1) : (x += 1) {
        setGray(buf, width, x, y0, v);
        setGray(buf, width, x, y1, v);
    }
    var y = y0;
    while (y <= y1) : (y += 1) {
        setGray(buf, width, x0, y, v);
        setGray(buf, width, x1, y, v);
    }
}

test "chamfer matches a rectangle-outline shape at the right place" {
    const w: u32 = 80;
    const h: u32 = 60;
    var buf: [w * h * 4]u8 = @splat(0);
    // Mid-gray background (no edges), plus one bright 20x12 rectangle outline
    // at (40,30)..(59,41). A solid-fill blob elsewhere must NOT match the shape.
    fillRect(&buf, w, 0, 0, w - 1, h - 1, 60, 60, 60);
    drawRectOutline(&buf, w, 40, 30, 59, 41, 230);
    // A few scattered bright dots elsewhere (sparse noise, not a matching shape).
    setGray(&buf, w, 8, 8, 220);
    setGray(&buf, w, 15, 20, 220);
    setGray(&buf, w, 22, 10, 220);

    // Build the template: the same 20x12 rectangle outline on gray.
    const tw: u32 = 20;
    const th: u32 = 12;
    var tbuf: [tw * th * 4]u8 = @splat(0);
    fillRect(&tbuf, tw, 0, 0, tw - 1, th - 1, 60, 60, 60);
    drawRectOutline(&tbuf, tw, 0, 0, tw - 1, th - 1, 230);

    var pts: [256]EdgePoint = undefined;
    const np = prepareTemplate(&tbuf, tw, th, 200, &pts);
    try std.testing.expect(np > 0);
    const etpl = EdgeTemplate{ .w = tw, .h = th, .points = pts[0..np] };

    var scratch: [chamferScratchLen(w, h)]u16 = undefined;
    var out: [8]TemplateMatch = undefined;
    const n = matchEdgeTemplateAll(&buf, w, h, etpl, 200, 800, &scratch, &out);
    try std.testing.expect(n >= 1);
    // Best match localizes to the outline near (40,30). Chamfer localization is
    // approximate (the distance transform makes nearby offsets score similarly),
    // which is fine for clicking a button — accept within a few px.
    try std.testing.expect(out[0].x + 8 >= 40 and out[0].x <= 48);
    try std.testing.expect(out[0].y + 8 >= 30 and out[0].y <= 38);
    try std.testing.expect(out[0].score_permille >= 800);
}

test "chamfer rejects when the shape is absent" {
    const w: u32 = 60;
    const h: u32 = 40;
    var buf: [w * h * 4]u8 = @splat(0);
    fillRect(&buf, w, 0, 0, w - 1, h - 1, 50, 50, 50); // flat, no edges

    const tw: u32 = 16;
    const th: u32 = 10;
    var tbuf: [tw * th * 4]u8 = @splat(0);
    fillRect(&tbuf, tw, 0, 0, tw - 1, th - 1, 50, 50, 50);
    drawRectOutline(&tbuf, tw, 0, 0, tw - 1, th - 1, 240);
    var pts: [256]EdgePoint = undefined;
    const np = prepareTemplate(&tbuf, tw, th, 200, &pts);
    const etpl = EdgeTemplate{ .w = tw, .h = th, .points = pts[0..np] };

    var scratch: [chamferScratchLen(w, h)]u16 = undefined;
    var out: [4]TemplateMatch = undefined;
    const n = matchEdgeTemplateAll(&buf, w, h, etpl, 200, 700, &scratch, &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "distanceToConfidence maps 0->1000 and far->0" {
    try std.testing.expectEqual(@as(i32, 1000), distanceToConfidence(0));
    try std.testing.expectEqual(@as(i32, 0), distanceToConfidence(30));
    try std.testing.expectEqual(@as(i32, 0), distanceToConfidence(100));
    try std.testing.expect(distanceToConfidence(3) > 850); // ~1px mean
}
