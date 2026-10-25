//! Stable bottom-up merge sort over u32 index arrays (Layer 0, design §4.9).
//! The caller supplies the scratch array (at least items.len entries) from
//! its own workspace; nothing is allocated. `context.order(a, b)` returns
//! <0, 0 or >0 and may fail (the sort stops and `items` is left permuted
//! but complete). At most n * ceil(log2 n) comparisons are made.
const types = @import("types.sig");

/// Keep the best items.len handles in a max-heap. The caller's comparator
/// includes a stable ordinal when equal keys must retain scan order. Empty
/// storage accepts nothing; comparison errors leave only private scratch dirty.
pub fn offerTopK(items: []u32, used: *usize, candidate: u32, context: anytype) types.Error!void {
    if (items.len == 0) return;
    if (used.* < items.len) {
        var child = used.*;
        used.* += 1;
        items[child] = candidate;
        while (child != 0) {
            const parent = (child - 1) / 2;
            if (try context.order(items[child], items[parent]) <= 0) break;
            const swap = items[parent];
            items[parent] = items[child];
            items[child] = swap;
            child = parent;
        }
        return;
    }
    if (try context.order(candidate, items[0]) >= 0) return;
    items[0] = candidate;
    var parent: usize = 0;
    while (parent * 2 + 1 < items.len) {
        var child = parent * 2 + 1;
        if (child + 1 < items.len and try context.order(items[child + 1], items[child]) > 0) child += 1;
        if (try context.order(items[parent], items[child]) >= 0) break;
        const swap = items[parent];
        items[parent] = items[child];
        items[child] = swap;
        parent = child;
    }
}

/// Sorts `items`; returns the number of comparisons made.
pub fn mergeSort(items: []u32, scratch: []u32, context: anytype) types.Error!u64 {
    if (scratch.len < items.len) return error.WorkspaceCapacity;
    var comparisons: u64 = 0;
    var source: []u32 = items;
    var target: []u32 = scratch[0..items.len];
    var in_scratch = false;
    var width: usize = 1;
    while (width < items.len) : (width *= 2) {
        var start: usize = 0;
        while (start < items.len) : (start += 2 * width) {
            const middle = @min(start + width, items.len);
            const end = @min(start + 2 * width, items.len);
            var i = start;
            var j = middle;
            var k = start;
            while (i < middle and j < end) : (k += 1) {
                comparisons += 1;
                // Strictly-less from the right keeps equal keys in order.
                if ((context.order(source[j], source[i]) catch |err| {
                    if (in_scratch) @memcpy(items, source);
                    return err;
                }) < 0) {
                    target[k] = source[j];
                    j += 1;
                } else {
                    target[k] = source[i];
                    i += 1;
                }
            }
            while (i < middle) : (k += 1) {
                target[k] = source[i];
                i += 1;
            }
            while (j < end) : (k += 1) {
                target[k] = source[j];
                j += 1;
            }
        }
        const swap = source;
        source = target;
        target = swap;
        in_scratch = !in_scratch;
    }
    if (in_scratch) @memcpy(items, source);
    return comparisons;
}
