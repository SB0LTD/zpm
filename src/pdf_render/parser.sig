// @zpm/pdf-render — PDF Structure Parser
// Parses PDF 1.4-1.7 files: header, xref, objects, streams.
// Provides random access to any object by number.
//
// PDF structure:
//   %PDF-1.7 header
//   Objects (N 0 obj ... endobj)
//   xref table (byte offsets of each object)
//   trailer (root catalog reference)
//
// This parser uses mmap'd file access — zero-copy, no heap.

pub const PdfDoc = struct {
    data: [*]const u8,
    size: usize,
    // Parsed xref entries: object number → byte offset
    xref: [4096]u32, // object byte offsets (max 4096 objects)
    xref_count: usize,
    // Root catalog object number
    root_obj: usize,
    // Pages array (object numbers of page objects)
    pages: [1024]u16, // max 1024 pages
    page_count: usize,
};

/// Parse a PDF file from memory-mapped data.
pub fn parse(data: [*]const u8, size: usize) ?PdfDoc {
    if (size < 20) return null;
    // Verify PDF header
    if (data[0] != '%' or data[1] != 'P' or data[2] != 'D' or data[3] != 'F') return null;

    var doc = PdfDoc{
        .data = data,
        .size = size,
        .xref = undefined,
        .xref_count = 0,
        .root_obj = 0,
        .pages = undefined,
        .page_count = 0,
    };

    // Find startxref (scan backwards from end)
    const xref_pos = findStartxref(data, size) orelse return null;

    // Parse xref table
    parseXref(data, size, xref_pos, &doc);

    // Find root catalog from trailer
    doc.root_obj = findTrailerRoot(data, size) orelse return null;

    // Parse page tree
    parsePages(data, size, &doc);

    return doc;
}

/// Get raw bytes of an object's content (between "obj" and "endobj")
pub fn getObjectData(doc: *const PdfDoc, obj_num: usize) ?[]const u8 {
    if (obj_num >= doc.xref_count) return null;
    const offset = doc.xref[obj_num];
    if (offset == 0) return null;

    // Skip "N 0 obj\n"
    var pos: usize = offset;
    while (pos < doc.size and doc.data[pos] != '\n') : (pos += 1) {}
    pos += 1; // skip newline after "obj"

    // Find "endobj"
    var end = pos;
    while (end + 6 < doc.size) : (end += 1) {
        if (doc.data[end] == 'e' and doc.data[end + 1] == 'n' and
            doc.data[end + 2] == 'd' and doc.data[end + 3] == 'o')
            break;
    }

    return doc.data[pos..end];
}

/// Get stream data from an object (content between "stream\n" and "\nendstream")
pub fn getStreamData(doc: *const PdfDoc, obj_num: usize) ?[]const u8 {
    const obj_data = getObjectData(doc, obj_num) orelse return null;

    // Find "stream\n"
    var i: usize = 0;
    while (i + 7 < obj_data.len) : (i += 1) {
        if (obj_data[i] == 's' and obj_data[i + 1] == 't' and obj_data[i + 2] == 'r' and
            obj_data[i + 3] == 'e' and obj_data[i + 4] == 'a' and obj_data[i + 5] == 'm')
        {
            i += 6;
            if (i < obj_data.len and obj_data[i] == '\r') i += 1;
            if (i < obj_data.len and obj_data[i] == '\n') i += 1;

            // Find "endstream"
            var end = i;
            while (end + 9 < obj_data.len) : (end += 1) {
                if (obj_data[end] == 'e' and obj_data[end + 1] == 'n' and
                    obj_data[end + 2] == 'd' and obj_data[end + 3] == 's')
                    break;
            }
            // Trim trailing newline before endstream
            if (end > i and obj_data[end - 1] == '\n') end -= 1;
            if (end > i and obj_data[end - 1] == '\r') end -= 1;

            return obj_data[i..end];
        }
    }
    return null;
}

// ── Internal helpers ──

fn findStartxref(data: [*]const u8, size: usize) ?usize {
    // Search backwards for "startxref"
    if (size < 20) return null;
    var i: usize = size - 20;
    while (i > 0) : (i -= 1) {
        if (data[i] == 's' and data[i + 1] == 't' and data[i + 2] == 'a' and
            data[i + 3] == 'r' and data[i + 4] == 't' and data[i + 5] == 'x')
        {
            // Parse the offset number after "startxref\n"
            var pos = i + 9; // skip "startxref"
            while (pos < size and (data[pos] == '\n' or data[pos] == '\r' or data[pos] == ' ')) : (pos += 1) {}
            return parseUint(data, pos, size);
        }
    }
    return null;
}

fn parseXref(data: [*]const u8, size: usize, xref_pos: usize, doc: *PdfDoc) void {
    // xref table format:
    // xref\n
    // 0 N\n
    // OOOOOOOOOO GGGGG f|n \n  (10 digits offset, 5 digits gen, flag)
    var pos = xref_pos;
    // Skip "xref\n"
    while (pos < size and data[pos] != '\n') : (pos += 1) {}
    pos += 1;
    // Read "first_obj count\n"
    const first_obj = parseUint(data, pos, size) orelse return;
    while (pos < size and data[pos] != ' ') : (pos += 1) {}
    pos += 1;
    const count = parseUint(data, pos, size) orelse return;
    while (pos < size and data[pos] != '\n') : (pos += 1) {}
    pos += 1;

    // Read entries
    var obj: usize = first_obj;
    var read: usize = 0;
    while (read < count and pos + 20 <= size) : (read += 1) {
        // Parse 10-digit offset
        const offset = parseUintFixed(data, pos, 10);
        // Check if 'n' (in-use) at position 17
        const flag = data[pos + 17];
        if (flag == 'n' and obj < 4096) {
            doc.xref[obj] = @intCast(offset);
            if (obj >= doc.xref_count) doc.xref_count = obj + 1;
        }
        pos += 20; // 10 + space + 5 + space + flag + space/newline
        obj += 1;
    }
}

fn findTrailerRoot(data: [*]const u8, size: usize) ?usize {
    // Find /Root N 0 R in trailer
    var i: usize = 0;
    while (i + 10 < size) : (i += 1) {
        if (data[i] == '/' and data[i + 1] == 'R' and data[i + 2] == 'o' and
            data[i + 3] == 'o' and data[i + 4] == 't')
        {
            // Skip "/Root " and parse object number
            var pos = i + 5;
            while (pos < size and data[pos] == ' ') : (pos += 1) {}
            return parseUint(data, pos, size);
        }
    }
    return null;
}

fn parsePages(data: [*]const u8, size: usize, doc: *PdfDoc) void {
    _ = data; _ = size;
    // Find /Kids array in the Pages object
    // Simple: scan all objects for /Type /Page entries
    var obj: usize = 1;
    while (obj < doc.xref_count) : (obj += 1) {
        const obj_data = getObjectData(doc, obj) orelse continue;
        if (containsStr(obj_data, "/Type /Page\n") or containsStr(obj_data, "/Type /Page ") or
            containsStr(obj_data, "/Type /Page>"))
        {
            if (doc.page_count < 1024) {
                doc.pages[doc.page_count] = @intCast(obj);
                doc.page_count += 1;
            }
        }
    }
}

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (haystack[i + j] != needle[j]) { match = false; break; }
        }
        if (match) return true;
    }
    return false;
}

fn parseUint(data: [*]const u8, start: usize, size: usize) ?usize {
    var pos = start;
    var val: usize = 0;
    var found = false;
    while (pos < size and data[pos] >= '0' and data[pos] <= '9') : (pos += 1) {
        val = val * 10 + (data[pos] - '0');
        found = true;
    }
    if (!found) return null;
    return val;
}

fn parseUintFixed(data: [*]const u8, pos: usize, digits: usize) usize {
    var val: usize = 0;
    var i: usize = 0;
    while (i < digits) : (i += 1) {
        val = val * 10 + (data[pos + i] - '0');
    }
    return val;
}
