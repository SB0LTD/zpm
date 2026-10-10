// @zpm/pdf-render — PDF text extraction.
//
// Recovers the readable text of a PDF: for each page it decompresses the
// content stream (FlateDecode via @zpm inflate) and pulls the strings out of
// the text-showing operators — `(...) Tj`, `[...] TJ`, and `'`/`"`. PDF string
// escapes (\n \t \( \) \\ and octal \ddd) are decoded, and layout operators
// that imply whitespace (BT/ET, T*, Td/TD, and the TJ kerning-gap numbers)
// become spaces or line breaks so words don't run together.
//
// This is deliberately a structural text extractor, not a full text-layout
// engine: it does not map glyph codes through custom font CMaps, so it targets
// the common case of PDFs whose content streams show WinAnsi/ASCII text. Those
// are the PDFs a reader (or a text-to-speech pipeline) actually wants to read.
//
//   const pdf = @import("pdf_render");
//   const doc = pdf.parser.parse(data.ptr, data.len) orelse return;
//   var scratch: [1 << 20]u8 = undefined;   // per-page inflate scratch
//   var out: [1 << 20]u8 = undefined;       // extracted text
//   const text = pdf.text.extract(&doc, &scratch, &out);

const parser = @import("parser.sig");
const inflate = @import("inflate");

pub const PdfDoc = parser.PdfDoc;

/// Extract the readable text of every page into `out`, in page order, with a
/// blank line between pages. `scratch` is working space for FlateDecode of one
/// page's content stream (size it to your largest expected page stream). The
/// returned slice aliases `out`. Text that overflows `out` is truncated.
pub fn extract(doc: *const PdfDoc, scratch: []u8, out: []u8) []const u8 {
    var w = Writer{ .buf = out };
    var page: usize = 0;
    while (page < doc.page_count) : (page += 1) {
        const page_obj = doc.pages[page];
        const started = w.len;
        if (w.len != 0) w.pushParagraph();
        // A page's content is one or more streams referenced by `/Contents`.
        // Resolve each referenced object, decode its stream, and extract text.
        // Fall back to the page object's own stream for the rare inline case.
        const page_data = parser.getObjectData(doc, page_obj) orelse continue;
        var found_content = false;
        var it = ContentRefs{ .data = page_data };
        while (it.next()) |content_obj| {
            const stream = parser.getStreamData(doc, content_obj) orelse continue;
            const content = decodeStream(stream, scratch);
            if (content.len == 0) continue;
            extractFromContent(content, &w);
            found_content = true;
        }
        if (!found_content) {
            if (parser.getStreamData(doc, page_obj)) |stream| {
                const content = decodeStream(stream, scratch);
                if (content.len != 0) extractFromContent(content, &w);
            }
        }
        // If this page produced nothing, roll back the paragraph break.
        if (w.len == started + 2) w.len = started;
    }
    return w.slice();
}

/// Iterate the object numbers a page's `/Contents` entry references — either a
/// single indirect ref `/Contents N 0 R` or an array `/Contents [a 0 R b 0 R]`.
const ContentRefs = struct {
    data: []const u8,
    started: bool = false,
    pos: usize = 0,
    end: usize = 0,

    fn next(self: *ContentRefs) ?usize {
        if (!self.started) {
            self.started = true;
            const key = findKey(self.data, "/Contents");
            if (key == null) return null;
            var p = key.?;
            // Skip whitespace after the key.
            while (p < self.data.len and isWs(self.data[p])) p += 1;
            if (p < self.data.len and self.data[p] == '[') {
                // Array of refs: scan until ']'.
                self.pos = p + 1;
                self.end = p + 1;
                while (self.end < self.data.len and self.data[self.end] != ']') self.end += 1;
            } else {
                // Single ref: bound the scan to the rest of the dict line-ish.
                self.pos = p;
                self.end = @min(self.data.len, p + 64);
            }
        }
        // Parse the next "N 0 R" object number in [pos, end).
        while (self.pos < self.end) {
            // Find a digit run.
            while (self.pos < self.end and !(self.data[self.pos] >= '0' and self.data[self.pos] <= '9')) self.pos += 1;
            if (self.pos >= self.end) return null;
            var num: usize = 0;
            const start = self.pos;
            while (self.pos < self.end and self.data[self.pos] >= '0' and self.data[self.pos] <= '9') : (self.pos += 1) {
                num = num * 10 + (self.data[self.pos] - '0');
            }
            // Expect " <gen> R" to confirm it's an indirect reference.
            var q = self.pos;
            while (q < self.end and isWs(self.data[q])) q += 1;
            // generation number
            while (q < self.end and self.data[q] >= '0' and self.data[q] <= '9') q += 1;
            while (q < self.end and isWs(self.data[q])) q += 1;
            if (q < self.end and self.data[q] == 'R') {
                self.pos = q + 1;
                return num;
            }
            // Not a ref; keep scanning from just past this digit run.
            if (self.pos == start) self.pos += 1;
        }
        return null;
    }
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0 or c == 0x0c;
}

/// Return the index just past `key` in `data`, or null if not present.
fn findKey(data: []const u8, key: []const u8) ?usize {
    if (key.len > data.len) return null;
    var i: usize = 0;
    while (i + key.len <= data.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < key.len) : (j += 1) {
            if (data[i + j] != key[j]) { match = false; break; }
        }
        if (match) return i + key.len;
    }
    return null;
}

/// Extract text from a single already-decompressed content stream. Exposed for
/// callers that manage their own page iteration or already hold raw content.
pub fn extractFromContent(content: []const u8, w: *Writer) void {
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '(') {
            i = emitLiteralString(content, i + 1, w);
        } else if (c == '[') {
            // A TJ array: strings interleaved with numeric kerning gaps. Large
            // negative gaps mean an inter-word space in most producers.
            i = emitArray(content, i + 1, w);
        } else if (c == 'T' and i + 1 < content.len) {
            // Text-positioning operators that imply new lines / spacing.
            // T*, Td, TD, Tm all move the text cursor — between two shown
            // strings that reliably marks at least a word (often line) break,
            // so glued runs like "ContentsAcknowledgments" get separated.
            const n = content[i + 1];
            if (n == '*') { // T*  — next line
                w.pushSpace();
                i += 2;
                continue;
            }
            if (n == 'd' or n == 'D' or n == 'm') { // Td / TD / Tm — move
                w.pushWordBreak();
                i += 2;
                continue;
            }
            i += 1;
        } else if (c == '\'' or c == '"') {
            // ' and " show a string on a new line.
            w.pushSpace();
            i += 1;
        } else {
            i += 1;
        }
    }
}

/// Decompress a content stream if it looks FlateDecoded (zlib-wrapped), else
/// return it unchanged. PDF streams are commonly zlib (0x78 ...) DEFLATE.
fn decodeStream(stream: []const u8, scratch: []u8) []const u8 {
    if (!looksZlib(stream)) return stream;
    // Strip the 2-byte zlib header; inflate consumes raw DEFLATE.
    const raw = stream[2..];
    var state = inflate.Inflate.init();
    const result = state.decompress(raw, scratch) catch return &.{};
    return scratch[0..result.out_produced];
}

fn looksZlib(s: []const u8) bool {
    if (s.len < 2) return false;
    // zlib: CMF/FLG where CMF low nibble = 8 (deflate) and (CMF*256+FLG)%31==0.
    if (s[0] & 0x0f != 8) return false;
    const check = (@as(u16, s[0]) << 8) | s[1];
    return check % 31 == 0;
}

// ── Text-operator scanning ──

/// Emit a PDF literal string `( ... )` beginning at `start` (just past '('),
/// decoding escapes and honoring nested balanced parens. Returns the index
/// just past the closing ')'.
fn emitLiteralString(content: []const u8, start: usize, w: *Writer) usize {
    var i = start;
    var depth: usize = 1;
    while (i < content.len) {
        const c = content[i];
        if (c == '\\') {
            i += 1;
            if (i >= content.len) break;
            const e = content[i];
            switch (e) {
                'n' => w.pushChar('\n'),
                'r' => w.pushChar('\n'),
                't' => w.pushChar(' '),
                'b', 'f' => {},
                '(' => w.pushChar('('),
                ')' => w.pushChar(')'),
                '\\' => w.pushChar('\\'),
                '0'...'7' => {
                    // Octal escape: up to 3 digits.
                    var val: u32 = e - '0';
                    var digits: usize = 1;
                    while (digits < 3 and i + 1 < content.len and
                        content[i + 1] >= '0' and content[i + 1] <= '7') : (digits += 1)
                    {
                        i += 1;
                        val = val * 8 + (content[i] - '0');
                    }
                    w.pushChar(@truncate(val));
                },
                '\n' => {}, // line continuation
                else => w.pushChar(e),
            }
            i += 1;
            continue;
        }
        if (c == '(') {
            depth += 1;
            w.pushChar('(');
            i += 1;
            continue;
        }
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return i + 1;
            w.pushChar(')');
            i += 1;
            continue;
        }
        w.pushChar(c);
        i += 1;
    }
    return i;
}

/// Emit a TJ array `[ (str) num (str) ... ]` starting just past '['. Numeric
/// gaps below a threshold insert a space (word break). Returns index past ']'.
fn emitArray(content: []const u8, start: usize, w: *Writer) usize {
    var i = start;
    while (i < content.len) {
        const c = content[i];
        if (c == ']') return i + 1;
        if (c == '(') {
            i = emitLiteralString(content, i + 1, w);
            continue;
        }
        if (c == '-' or (c >= '0' and c <= '9')) {
            // Parse a kerning number; a large negative advance is a space.
            const neg = c == '-';
            var j = if (neg) i + 1 else i;
            var val: u32 = 0;
            while (j < content.len and content[j] >= '0' and content[j] <= '9') : (j += 1) {
                val = val * 10 + (content[j] - '0');
            }
            // Skip a fractional part if present.
            if (j < content.len and content[j] == '.') {
                j += 1;
                while (j < content.len and content[j] >= '0' and content[j] <= '9') : (j += 1) {}
            }
            if (neg and val >= 100) w.pushWordBreak();
            i = j;
            continue;
        }
        i += 1;
    }
    return i;
}

// ── Bounded text sink ──

/// A fixed-capacity text accumulator that also normalizes whitespace as it goes
/// so extracted text is one clean stream of words, spaces, and newlines.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn slice(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn pushChar(self: *Writer, c: u8) void {
        // Collapse control bytes (other than newline) to a single space.
        if (c == '\n') {
            self.pushSpace();
            return;
        }
        if (c < 0x20 or c == 0x7f) {
            self.pushWordBreak();
            return;
        }
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    /// Insert a single space unless the last byte is already whitespace.
    pub fn pushWordBreak(self: *Writer) void {
        if (self.len == 0) return;
        const last = self.buf[self.len - 1];
        if (last == ' ' or last == '\n') return;
        if (self.len < self.buf.len) {
            self.buf[self.len] = ' ';
            self.len += 1;
        }
    }

    /// A newline (end of a text line). Collapses runs of blank lines.
    pub fn pushSpace(self: *Writer) void {
        if (self.len == 0) return;
        const last = self.buf[self.len - 1];
        if (last == '\n') return;
        if (self.len < self.buf.len) {
            self.buf[self.len] = '\n';
            self.len += 1;
        }
    }

    /// A paragraph break between pages: a blank line.
    pub fn pushParagraph(self: *Writer) void {
        self.pushSpace();
        if (self.len < self.buf.len) {
            self.buf[self.len] = '\n';
            self.len += 1;
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const std = @import("std");

test "extractFromContent pulls a simple Tj string" {
    const content = "BT /F1 12 Tf (Hello world) Tj ET";
    var out: [128]u8 = undefined;
    var w = Writer{ .buf = &out };
    extractFromContent(content, &w);
    try std.testing.expectEqualStrings("Hello world", w.slice());
}

test "TJ array joins strings and inserts word breaks on large negative kerns" {
    const content = "[(Hel)-50(lo)-400(there)] TJ";
    var out: [128]u8 = undefined;
    var w = Writer{ .buf = &out };
    extractFromContent(content, &w);
    // -50 is small (stays joined), -400 is a word break.
    try std.testing.expectEqualStrings("Hello there", w.slice());
}

test "escapes are decoded: octal, parens, tab, newline" {
    const content = "(a\\(b\\)\\tc\\135d) Tj";
    var out: [128]u8 = undefined;
    var w = Writer{ .buf = &out };
    extractFromContent(content, &w);
    // \135 is octal for ']' (0o135 = 93).
    try std.testing.expectEqualStrings("a(b) c]d", w.slice());
}

test "T* and quote operators add line/space separation" {
    // T* opens a new line before "line two"; the trailing ' opens one more
    // line for a (here absent) next string, so a trailing newline is expected.
    const content = "(line one) Tj T* (line two) '";
    var out: [128]u8 = undefined;
    var w = Writer{ .buf = &out };
    extractFromContent(content, &w);
    try std.testing.expectEqualStrings("line one\nline two\n", w.slice());
}

test "writer bounds output and never overflows" {
    var out: [4]u8 = undefined;
    var w = Writer{ .buf = &out };
    extractFromContent("(abcdefghij) Tj", &w);
    try std.testing.expectEqual(@as(usize, 4), w.slice().len);
    try std.testing.expectEqualStrings("abcd", w.slice());
}

test "zlib detection" {
    try std.testing.expect(looksZlib(&.{ 0x78, 0x9c }));
    try std.testing.expect(!looksZlib(&.{ 'B', 'T' }));
    try std.testing.expect(!looksZlib(&.{0x78}));
}

test "ContentRefs resolves a single indirect reference" {
    var it = ContentRefs{ .data = "<</Type/Page/Contents 5 0 R/MediaBox[0 0 612 792]>>" };
    try std.testing.expectEqual(@as(?usize, 5), it.next());
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "ContentRefs resolves an array of references" {
    var it = ContentRefs{ .data = "<</Type/Page/Contents[10 0 R 11 0 R 12 0 R]>>" };
    try std.testing.expectEqual(@as(?usize, 10), it.next());
    try std.testing.expectEqual(@as(?usize, 11), it.next());
    try std.testing.expectEqual(@as(?usize, 12), it.next());
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "ContentRefs returns nothing when there is no /Contents" {
    var it = ContentRefs{ .data = "<</Type/Page/MediaBox[0 0 612 792]>>" };
    try std.testing.expectEqual(@as(?usize, null), it.next());
}
