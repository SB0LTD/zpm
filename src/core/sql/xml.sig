//! XML well-formedness (Layer 0), standing in for the libxml2 checks of
//! PostgreSQL's xml.c: xml_in and XMLPARSE(CONTENT) accept well-formed
//! content (any mix of character data, elements, references, CDATA,
//! comments and processing instructions, after an optional XML
//! declaration); XMLPARSE(DOCUMENT) needs a document (an optional XML
//! declaration, comments, PIs and a DOCTYPE, then exactly one root
//! element). Invalid content is 2200N and an invalid document 2200M.
//! Only the five predefined entities and character references are known;
//! elements nest at most 256 deep (libxml2's default limit).
//!
//! xml_out drops an XML declaration that says nothing beyond version 1.0
//! (and its following newline), as print_xml_decl does.
const types = @import("types.sig");

pub const max_depth: usize = 256;

pub const Declaration = struct {
    /// Bytes of the declaration (0 when there is none).
    len: usize = 0,
    version: []const u8 = "1.0",
    version_default: bool = true,
    standalone: ?bool = null,
};

const Parser = struct {
    text: []const u8,
    at: usize = 0,

    fn end(self: *const Parser) bool {
        return self.at >= self.text.len;
    }

    fn startsWith(self: *const Parser, prefix: []const u8) bool {
        return self.text.len - self.at >= prefix.len and types.same(self.text[self.at..][0..prefix.len], prefix);
    }

    fn space(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn skipSpace(self: *Parser) bool {
        const start = self.at;
        while (!self.end() and space(self.text[self.at])) self.at += 1;
        return self.at != start;
    }

    fn nameStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':' or c >= 0x80;
    }

    fn nameChar(c: u8) bool {
        return nameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
    }

    /// A legal XML character byte (control characters other than tab,
    /// newline and carriage return are not).
    fn charByte(c: u8) bool {
        return c >= 0x20 or c == '\t' or c == '\n' or c == '\r';
    }

    fn name(self: *Parser) ?[]const u8 {
        if (self.end() or !nameStart(self.text[self.at])) return null;
        const start = self.at;
        while (!self.end() and nameChar(self.text[self.at])) self.at += 1;
        return self.text[start..self.at];
    }

    /// `&name;` (predefined) or `&#d;` / `&#xh;` naming a legal character.
    fn reference(self: *Parser) bool {
        self.at += 1;
        if (!self.end() and self.text[self.at] == '#') {
            self.at += 1;
            var hex = false;
            if (!self.end() and self.text[self.at] == 'x') {
                hex = true;
                self.at += 1;
            }
            var value: u32 = 0;
            var digits: usize = 0;
            while (!self.end() and self.text[self.at] != ';') : (self.at += 1) {
                const c = self.text[self.at];
                const digit: u32 = if (c >= '0' and c <= '9') c - '0' else if (hex and c >= 'a' and c <= 'f') c - 'a' + 10 else if (hex and c >= 'A' and c <= 'F') c - 'A' + 10 else return false;
                value = value * (if (hex) @as(u32, 16) else 10) + digit;
                if (value > 0x10ffff) return false;
                digits += 1;
            }
            if (self.end() or digits == 0) return false;
            self.at += 1;
            const legal = value == 0x9 or value == 0xa or value == 0xd or (value >= 0x20 and value <= 0xd7ff) or (value >= 0xe000 and value <= 0xfffd) or value >= 0x10000;
            return legal;
        }
        const entity = self.name() orelse return false;
        if (self.end() or self.text[self.at] != ';') return false;
        self.at += 1;
        for ([_][]const u8{ "lt", "gt", "amp", "apos", "quot" }) |known| if (types.same(entity, known)) return true;
        return false;
    }

    /// `<!--` ... `-->` with no `--` inside.
    fn comment(self: *Parser) bool {
        self.at += 4;
        while (!self.end()) {
            if (self.startsWith("--")) {
                if (!self.startsWith("-->")) return false;
                self.at += 3;
                return true;
            }
            if (!charByte(self.text[self.at])) return false;
            self.at += 1;
        }
        return false;
    }

    /// `<?target ...?>`; the target may not be `xml` (any case).
    fn instruction(self: *Parser) bool {
        self.at += 2;
        const target = self.name() orelse return false;
        if (target.len == 3 and types.keyword(target, "xml")) return false;
        if (!self.startsWith("?>") and !self.skipSpace()) return false;
        while (!self.end()) {
            if (self.startsWith("?>")) {
                self.at += 2;
                return true;
            }
            if (!charByte(self.text[self.at])) return false;
            self.at += 1;
        }
        return false;
    }

    fn cdata(self: *Parser) bool {
        self.at += 9;
        while (!self.end()) {
            if (self.startsWith("]]>")) {
                self.at += 3;
                return true;
            }
            if (!charByte(self.text[self.at])) return false;
            self.at += 1;
        }
        return false;
    }

    /// Attributes and the end of a start tag; true for `/>`.
    fn startTag(self: *Parser) ?bool {
        var names: [32][]const u8 = undefined;
        var count: usize = 0;
        while (true) {
            const spaced = self.skipSpace();
            if (self.startsWith("/>")) {
                self.at += 2;
                return true;
            }
            if (self.startsWith(">")) {
                self.at += 1;
                return false;
            }
            if (!spaced) return null;
            const attribute = self.name() orelse return null;
            for (names[0..@min(count, names.len)]) |seen| if (types.same(seen, attribute)) return null;
            if (count < names.len) names[count] = attribute;
            count += 1;
            _ = self.skipSpace();
            if (self.end() or self.text[self.at] != '=') return null;
            self.at += 1;
            _ = self.skipSpace();
            if (self.end() or (self.text[self.at] != '"' and self.text[self.at] != '\'')) return null;
            const quote = self.text[self.at];
            self.at += 1;
            while (true) {
                if (self.end()) return null;
                const c = self.text[self.at];
                if (c == quote) break;
                if (c == '<' or !charByte(c)) return null;
                if (c == '&') {
                    if (!self.reference()) return null;
                    continue;
                }
                self.at += 1;
            }
            self.at += 1;
        }
    }

    /// Content until the end of the text (top level, `elements` counting
    /// root elements) or until the end tag of the innermost open element.
    fn content(self: *Parser, top_level: bool, elements: *usize) bool {
        var stack: [max_depth][]const u8 = undefined;
        var depth: usize = 0;
        while (!self.end()) {
            const c = self.text[self.at];
            if (c == '<') {
                if (self.startsWith("<!--")) {
                    if (!self.comment()) return false;
                } else if (self.startsWith("<![CDATA[")) {
                    if (depth == 0 and !top_level) return false;
                    if (!self.cdata()) return false;
                } else if (self.startsWith("<?")) {
                    if (!self.instruction()) return false;
                } else if (self.startsWith("</")) {
                    if (depth == 0) return false;
                    self.at += 2;
                    const closing = self.name() orelse return false;
                    if (!types.same(closing, stack[depth - 1])) return false;
                    _ = self.skipSpace();
                    if (self.end() or self.text[self.at] != '>') return false;
                    self.at += 1;
                    depth -= 1;
                } else {
                    self.at += 1;
                    const element = self.name() orelse return false;
                    const empty = self.startTag() orelse return false;
                    if (depth == 0) elements.* += 1;
                    if (!empty) {
                        if (depth == max_depth) return false;
                        stack[depth] = element;
                        depth += 1;
                    }
                }
                continue;
            }
            if (c == '&') {
                if (depth == 0 and !top_level) return false;
                if (!self.reference()) return false;
                continue;
            }
            if (!charByte(c)) return false;
            if (c == ']' and self.startsWith("]]>")) return false;
            // Character data outside the root element of a document must
            // be whitespace (the caller passes top_level false then).
            if (depth == 0 and !top_level and !space(c)) return false;
            self.at += 1;
        }
        return depth == 0;
    }

    /// `<!DOCTYPE name ... >`, skipping an internal subset.
    fn doctype(self: *Parser) bool {
        self.at += 9;
        if (!self.skipSpace()) return false;
        _ = self.name() orelse return false;
        var bracket = false;
        while (!self.end()) {
            const c = self.text[self.at];
            if (c == '"' or c == '\'') {
                self.at += 1;
                while (!self.end() and self.text[self.at] != c) self.at += 1;
                if (self.end()) return false;
            } else if (c == '[') {
                bracket = true;
            } else if (c == ']') {
                bracket = false;
            } else if (c == '>' and !bracket) {
                self.at += 1;
                return true;
            }
            self.at += 1;
        }
        return false;
    }
};

/// The XML declaration at the start of `text` (parse_xml_decl): its length,
/// whether its version is the default and its standalone value. null when
/// a declaration is present but malformed.
pub fn declaration(text: []const u8) ?Declaration {
    var parser: Parser = .{ .text = text };
    if (!parser.startsWith("<?xml") or (text.len > 5 and Parser.nameChar(text[5]))) return .{};
    parser.at = 5;
    var out: Declaration = .{};
    var seen_version = false;
    while (true) {
        const spaced = parser.skipSpace();
        if (parser.startsWith("?>")) {
            parser.at += 2;
            out.len = parser.at;
            return if (seen_version) out else null;
        }
        if (!spaced) return null;
        const key = parser.name() orelse return null;
        _ = parser.skipSpace();
        if (parser.end() or parser.text[parser.at] != '=') return null;
        parser.at += 1;
        _ = parser.skipSpace();
        if (parser.end() or (parser.text[parser.at] != '"' and parser.text[parser.at] != '\'')) return null;
        const quote = parser.text[parser.at];
        parser.at += 1;
        const start = parser.at;
        while (!parser.end() and parser.text[parser.at] != quote) parser.at += 1;
        if (parser.end()) return null;
        const value = text[start..parser.at];
        parser.at += 1;
        if (types.same(key, "version")) {
            if (seen_version or value.len == 0) return null;
            seen_version = true;
            out.version_default = types.same(value, "1.0");
            out.version = value;
        } else if (types.same(key, "encoding")) {
            if (!seen_version or value.len == 0) return null;
        } else if (types.same(key, "standalone")) {
            if (!seen_version) return null;
            if (types.same(value, "yes")) out.standalone = true else if (types.same(value, "no")) out.standalone = false else return null;
        } else return null;
    }
}

/// Well-formed content (xmloption CONTENT).
pub fn validContent(text: []const u8) bool {
    const decl = declaration(text) orelse return false;
    var parser: Parser = .{ .text = text, .at = decl.len };
    // Content with a DOCTYPE is parsed as a document (PostgreSQL 16+).
    var probe = parser;
    while (true) {
        _ = probe.skipSpace();
        if (probe.startsWith("<!--")) {
            if (!probe.comment()) break;
            continue;
        }
        if (probe.startsWith("<?") and !probe.startsWith("<?xml")) {
            if (!probe.instruction()) break;
            continue;
        }
        break;
    }
    if (probe.startsWith("<!DOCTYPE")) return validDocument(text);
    var elements: usize = 0;
    return parser.content(true, &elements);
}

/// A well-formed document (XMLPARSE DOCUMENT, xmloption DOCUMENT).
pub fn validDocument(text: []const u8) bool {
    const decl = declaration(text) orelse return false;
    var parser: Parser = .{ .text = text, .at = decl.len };
    var doctype_seen = false;
    while (true) {
        _ = parser.skipSpace();
        if (parser.startsWith("<!--")) {
            if (!parser.comment()) return false;
        } else if (parser.startsWith("<?")) {
            if (!parser.instruction()) return false;
        } else if (parser.startsWith("<!DOCTYPE")) {
            if (doctype_seen or !parser.doctype()) return false;
            doctype_seen = true;
        } else break;
    }
    if (parser.end() or parser.text[parser.at] != '<') return false;
    var elements: usize = 0;
    if (!parser.content(false, &elements)) return false;
    return elements == 1;
}

/// xml_out into `buffer` (at least text.len + 64 bytes): the declaration
/// as print_xml_decl rebuilds it, or none (and the newline after the
/// original one) when it says nothing beyond version 1.0.
pub fn output(text: []const u8, buffer: []u8) []const u8 {
    const decl = declaration(text) orelse Declaration{};
    var at: usize = 0;
    var skip = decl.len;
    if (decl.len != 0 and (!decl.version_default or decl.standalone != null)) {
        const standalone: []const u8 = if (decl.standalone) |yes| (if (yes) " standalone=\"yes\"" else " standalone=\"no\"") else "";
        for ([_][]const u8{ "<?xml version=\"", decl.version, "\"", standalone, "?>" }) |part| {
            @memcpy(buffer[at..][0..part.len], part);
            at += part.len;
        }
    } else if (skip != 0 and skip < text.len and text[skip] == '\n') skip += 1;
    @memcpy(buffer[at..][0 .. text.len - skip], text[skip..]);
    return buffer[0 .. at + text.len - skip];
}
