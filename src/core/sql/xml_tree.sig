//! XML documents as bounded node trees (Layer 0, B11 wave 5 xml lane) for
//! XPath (xpath.sig), XMLTABLE and XMLSERIALIZE ... INDENT: the tree libxml2
//! 2.9 builds for PostgreSQL 18, and its serializations.
//!
//! The caller validates the text first (xml.validDocument / validContent:
//! the same well-formedness xml_in checks); `parse` then builds nodes into
//! caller-owned storage. Like libxml2 it normalizes line ends, decodes
//! references, normalizes attribute whitespace, merges character data into
//! one text node per run, keeps CDATA sections, comments and processing
//! instructions as nodes, and resolves namespace prefixes. Namespace errors
//! (an undeclared prefix, an empty prefixed namespace, the reserved xml and
//! xmlns prefixes, duplicate expanded attribute names) are libxml2 errors of
//! the namespace domain: XPath (strict) rejects the document, xml_in (well
//! formedness only) does not, so they are recorded in `namespace_error`.
//!
//! Nodes are numbered in document order (a document node first; an
//! element's namespace declarations and attributes follow it, then its
//! children), so node indices order node sets. Namespace-axis nodes are
//! materialized on demand (`namespaces`) after the parsed nodes. Every
//! node, decoded value and namespace-axis node takes storage; going over
//! is ProgramLimitExceeded (54000). Building is iterative (parent links,
//! no recursion); depth is bounded by the validator (256, libxml2's limit).
const types = @import("types.sig");
const xml = @import("xml.sig");
const Error = types.Error;

/// The well-formedness checks that run before parse (xml.sig).
pub const validator = xml;

pub const none: u32 = 0xffff_ffff;
pub const xml_namespace_uri = "http://www.w3.org/XML/1998/namespace";

pub const Kind = enum(u8) {
    document,
    element,
    attribute,
    text,
    cdata,
    comment,
    pi,
    /// A namespace-axis node (parent: its element; name: the prefix, empty
    /// for the default namespace; value: the URI).
    namespace,
    /// A namespace declaration (xmlns / xmlns:p attribute) of an element;
    /// not part of the XPath tree.
    decl,
};

/// Bytes of the source text, or of the tree's decoded-value buffer.
pub const Span = struct {
    start: u32 = 0,
    len: u32 = 0,
    decoded: bool = false,
};

pub const Node = struct {
    kind: Kind = .text,
    /// A processing instruction with data (`<?t ?>` has empty data,
    /// `<?t?>` none), a namespace node of the implicit xml prefix, an
    /// element under xml:space="preserve".
    flag: bool = false,
    parent: u32 = none,
    first: u32 = none,
    last: u32 = none,
    next: u32 = none,
    prev: u32 = none,
    /// Element: first attribute and first namespace declaration.
    attrs: u32 = none,
    decls: u32 = none,
    /// Element / attribute: the declaration that binds its namespace
    /// (none: no namespace); namespace node: the declaration it shows.
    ns: u32 = none,
    /// Element: first materialized namespace-axis node (none: not yet).
    ns_nodes: u32 = none,
    /// Qualified name (element, attribute, PI target, declaration prefix).
    name: Span = .{},
    prefix_len: u32 = 0,
    value: Span = .{},
};

pub const Mode = enum { document, content };

pub const Tree = struct {
    source: []const u8,
    nodes: []Node,
    count: u32 = 0,
    text: []u8,
    text_len: usize = 0,
    namespace_error: bool = false,
    control: ?*types.ExecutionControl = null,
    /// The DOCTYPE (raw text; len 0: none) and how many document children
    /// precede it. XPath does not see it; document dumps write it.
    doctype: Span = .{},
    doctype_at: u32 = 0,

    pub fn bytes(self: *const Tree, span: Span) []const u8 {
        const base = if (span.decoded) self.text[0..self.text_len] else self.source;
        return base[span.start..][0..span.len];
    }

    pub fn node(self: *const Tree, index: u32) *const Node {
        return &self.nodes[index];
    }

    pub fn qname(self: *const Tree, index: u32) []const u8 {
        return self.bytes(self.nodes[index].name);
    }

    /// The local part of a qualified name.
    pub fn localName(self: *const Tree, index: u32) []const u8 {
        const n = &self.nodes[index];
        const full = self.bytes(n.name);
        if (n.kind == .namespace or n.kind == .decl) return full;
        return if (n.prefix_len == 0) full else full[n.prefix_len + 1 ..];
    }

    pub fn prefix(self: *const Tree, index: u32) []const u8 {
        const n = &self.nodes[index];
        return self.bytes(n.name)[0..n.prefix_len];
    }

    /// The namespace URI of an element or attribute ("" for none).
    pub fn namespaceUri(self: *const Tree, index: u32) []const u8 {
        const n = &self.nodes[index];
        if (n.ns == none) return "";
        return self.bytes(self.nodes[n.ns].value);
    }

    pub fn add(self: *Tree, value: Node) Error!u32 {
        if (self.count >= self.nodes.len) return error.ProgramLimitExceeded;
        const index = self.count;
        self.nodes[index] = value;
        self.count += 1;
        if (self.control) |control| try control.checkpoint();
        return index;
    }

    fn reserve(self: *Tree, length: usize) Error![]u8 {
        if (length > self.text.len - self.text_len) return error.ProgramLimitExceeded;
        return self.text[self.text_len..][0..length];
    }

    fn commit(self: *Tree, length: usize) Span {
        const span: Span = .{ .start = @intCast(self.text_len), .len = @intCast(length), .decoded = true };
        self.text_len += length;
        return span;
    }

    pub fn putText(self: *Tree, data: []const u8) Error!Span {
        const out = try self.reserve(data.len);
        @memcpy(out, data);
        return self.commit(data.len);
    }

    fn append(self: *Tree, parent: u32, child: u32) void {
        const p = &self.nodes[parent];
        self.nodes[child].parent = parent;
        if (p.last == none) {
            p.first = child;
        } else {
            self.nodes[p.last].next = child;
            self.nodes[child].prev = p.last;
        }
        p.last = child;
    }

    /// The declaration binding `prefix_text` ("" for the default namespace)
    /// in scope at element `from`, or none.
    pub fn lookup(self: *const Tree, from: u32, prefix_text: []const u8) u32 {
        var element = from;
        while (element != none and self.nodes[element].kind == .element) : (element = self.nodes[element].parent) {
            var decl = self.nodes[element].decls;
            while (decl != none) : (decl = self.nodes[decl].next) {
                if (types.same(self.bytes(self.nodes[decl].name), prefix_text)) return decl;
            }
        }
        return none;
    }

    /// The string-value of a node (xmlXPathCastNodeToString /
    /// xmlNodeGetContent): the text and CDATA descendants of an element or
    /// the document, the value of anything else.
    pub fn stringValue(self: *const Tree, index: u32, out: *Out) Error!void {
        const n = &self.nodes[index];
        switch (n.kind) {
            .element, .document => {
                var at = n.first;
                while (at != none) {
                    const current = &self.nodes[at];
                    if (current.kind == .text or current.kind == .cdata) try out.add(self.bytes(current.value));
                    if (current.kind == .element and current.first != none) {
                        at = current.first;
                        continue;
                    }
                    at = self.following(at, index);
                }
            },
            else => try out.add(self.bytes(n.value)),
        }
    }

    /// The next node in document order after `at`'s subtree, not leaving
    /// `root`'s subtree (none at its end).
    pub fn following(self: *const Tree, at_in: u32, root: u32) u32 {
        var at = at_in;
        while (at != root and at != none) {
            if (self.nodes[at].next != none) return self.nodes[at].next;
            at = self.nodes[at].parent;
        }
        return none;
    }
};

/// A caller-owned output buffer (overflow is ProgramLimitExceeded, 54000).
pub const Out = struct {
    bytes: []u8,
    len: usize = 0,

    pub fn add(self: *Out, data: []const u8) Error!void {
        if (data.len > self.bytes.len - self.len) return error.ProgramLimitExceeded;
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn byte(self: *Out, c: u8) Error!void {
        if (self.len == self.bytes.len) return error.ProgramLimitExceeded;
        self.bytes[self.len] = c;
        self.len += 1;
    }

    pub fn slice(self: *const Out) []const u8 {
        return self.bytes[0..self.len];
    }
};

// ---- parsing ---------------------------------------------------------------

fn space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn nameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':' or c >= 0x80;
}

fn nameChar(c: u8) bool {
    return nameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
}

fn startsWith(text: []const u8, at: usize, prefix_text: []const u8) bool {
    return text.len - at >= prefix_text.len and types.same(text[at..][0..prefix_text.len], prefix_text);
}

fn utf8(code: u32, out: []u8) usize {
    if (code < 0x80) {
        out[0] = @intCast(code);
        return 1;
    }
    if (code < 0x800) {
        out[0] = @intCast(0xc0 | (code >> 6));
        out[1] = @intCast(0x80 | (code & 0x3f));
        return 2;
    }
    if (code < 0x10000) {
        out[0] = @intCast(0xe0 | (code >> 12));
        out[1] = @intCast(0x80 | ((code >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (code & 0x3f));
        return 3;
    }
    out[0] = @intCast(0xf0 | (code >> 18));
    out[1] = @intCast(0x80 | ((code >> 12) & 0x3f));
    out[2] = @intCast(0x80 | ((code >> 6) & 0x3f));
    out[3] = @intCast(0x80 | (code & 0x3f));
    return 4;
}

/// Decodes `&...;` at `at.*` (validated input) into `out`; returns the
/// byte count written.
fn reference(text: []const u8, at: *usize, out: []u8) Error!usize {
    var index = at.* + 1;
    if (index < text.len and text[index] == '#') {
        index += 1;
        var hex = false;
        if (index < text.len and text[index] == 'x') {
            hex = true;
            index += 1;
        }
        var code: u32 = 0;
        while (index < text.len and text[index] != ';') : (index += 1) {
            const c = text[index];
            const digit: u32 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return error.InvalidXmlDocument;
            code = code * (if (hex) @as(u32, 16) else 10) + digit;
            if (code > 0x10ffff) return error.InvalidXmlDocument;
        }
        if (index >= text.len) return error.InvalidXmlDocument;
        at.* = index + 1;
        return utf8(code, out);
    }
    const start = index;
    while (index < text.len and text[index] != ';') index += 1;
    if (index >= text.len) return error.InvalidXmlDocument;
    const entity = text[start..index];
    at.* = index + 1;
    const replacement: u8 = if (types.same(entity, "lt")) '<' else if (types.same(entity, "gt")) '>' else if (types.same(entity, "amp")) '&' else if (types.same(entity, "apos")) '\'' else if (types.same(entity, "quot")) '"' else return error.InvalidXmlDocument;
    out[0] = replacement;
    return 1;
}

const Builder = struct {
    tree: *Tree,
    text: []const u8,
    at: usize,
    keep_blanks: bool,
    replace_entities: bool,
    mode: Mode,
    /// The element being filled (the document node at the top level).
    current: u32 = 0,

    fn end(self: *const Builder) bool {
        return self.at >= self.text.len;
    }

    fn skipSpace(self: *Builder) void {
        while (!self.end() and space(self.text[self.at])) self.at += 1;
    }

    fn name(self: *Builder) Error!Span {
        const start = self.at;
        if (self.end() or !nameStart(self.text[self.at])) return error.InvalidXmlDocument;
        while (!self.end() and nameChar(self.text[self.at])) self.at += 1;
        return .{ .start = @intCast(start), .len = @intCast(self.at - start) };
    }

    /// A raw run [start, stop) as a value: line ends normalized (CRLF and
    /// CR become LF), references decoded when `references`, literal white
    /// space as spaces when `attribute`. Unchanged runs stay in the source.
    fn value(self: *Builder, start: usize, stop: usize, references: bool, attribute: bool, raw_amp: bool) Error!Span {
        const raw = self.text[start..stop];
        var plain = true;
        for (raw) |c| {
            if (c == '\r' or (references and c == '&') or (attribute and (c == '\n' or c == '\t'))) plain = false;
        }
        if (plain) return .{ .start = @intCast(start), .len = @intCast(stop - start) };
        const out = try self.tree.reserve(raw.len);
        var written: usize = 0;
        var index: usize = 0;
        while (index < raw.len) {
            const c = raw[index];
            if (c == '\r') {
                out[written] = if (attribute) ' ' else '\n';
                written += 1;
                index += 1;
                if (index < raw.len and raw[index] == '\n') index += 1;
                continue;
            }
            if (references and c == '&') {
                var at = start + index;
                var scratch: [4]u8 = undefined;
                const length = try reference(self.text, &at, &scratch);
                if (raw_amp and length == 1 and scratch[0] == '&') {
                    // "&#38;" is five bytes, no longer than any reference to '&'.
                    @memcpy(out[written..][0..5], "&#38;");
                    written += 5;
                } else {
                    @memcpy(out[written..][0..length], scratch[0..length]);
                    written += length;
                }
                index = at - start;
                continue;
            }
            out[written] = if (attribute and (c == '\n' or c == '\t')) ' ' else c;
            written += 1;
            index += 1;
        }
        return self.tree.commit(written);
    }

    fn child(self: *Builder, kind: Kind, value_span: Span) Error!u32 {
        const index = try self.tree.add(.{ .kind = kind, .value = value_span });
        self.tree.append(self.current, index);
        return index;
    }

    fn comment(self: *Builder) Error!void {
        const start = self.at + 4;
        var stop = start;
        while (stop + 3 <= self.text.len and !startsWith(self.text, stop, "-->")) stop += 1;
        if (stop + 3 > self.text.len) return error.InvalidXmlDocument;
        self.at = stop + 3;
        // Comments outside the root element of a document are its children too.
        _ = try self.child(.comment, try self.value(start, stop, false, false, false));
    }

    fn instruction(self: *Builder) Error!void {
        self.at += 2;
        const target = try self.name();
        var data_start = self.at;
        var has_data = false;
        if (!startsWith(self.text, self.at, "?>")) {
            self.skipSpace();
            data_start = self.at;
            has_data = true;
        }
        var stop = data_start;
        while (stop + 2 <= self.text.len and !startsWith(self.text, stop, "?>")) stop += 1;
        if (stop + 2 > self.text.len) return error.InvalidXmlDocument;
        self.at = stop + 2;
        const index = try self.child(.pi, try self.value(data_start, stop, false, false, false));
        self.tree.nodes[index].name = target;
        self.tree.nodes[index].flag = has_data;
    }

    fn cdata(self: *Builder) Error!void {
        const start = self.at + 9;
        var stop = start;
        while (stop + 3 <= self.text.len and !startsWith(self.text, stop, "]]>")) stop += 1;
        if (stop + 3 > self.text.len) return error.InvalidXmlDocument;
        self.at = stop + 3;
        // An empty section makes no node.
        if (stop == start) return;
        _ = try self.child(.cdata, try self.value(start, stop, false, false, false));
    }

    fn doctype(self: *Builder) Error!void {
        const start = self.at;
        defer {
            self.tree.doctype = .{ .start = @intCast(start), .len = @intCast(self.at - start) };
            var children: u32 = 0;
            var child_at = self.tree.nodes[0].first;
            while (child_at != none) : (child_at = self.tree.nodes[child_at].next) children += 1;
            self.tree.doctype_at = children;
        }
        self.at += 9;
        var bracket = false;
        while (!self.end()) {
            const c = self.text[self.at];
            if (c == '"' or c == '\'') {
                self.at += 1;
                while (!self.end() and self.text[self.at] != c) self.at += 1;
            } else if (c == '[') {
                bracket = true;
            } else if (c == ']') {
                bracket = false;
            } else if (c == '>' and !bracket) {
                self.at += 1;
                return;
            }
            self.at += 1;
        }
        return error.InvalidXmlDocument;
    }

    /// libxml2's areBlanks heuristic (XML_PARSE_NOBLANKS, no DTD): a run of
    /// literal white space directly before '<' is dropped unless its
    /// element has text, or it is the only content before an end tag.
    fn ignorable(self: *const Builder, stop: usize) bool {
        if (self.keep_blanks or self.tree.nodes[self.current].flag) return false;
        if (stop >= self.text.len or self.text[stop] != '<') return false;
        const parent = &self.tree.nodes[self.current];
        if (parent.first == none and startsWith(self.text, stop, "</")) return false;
        if (parent.last != none and self.tree.nodes[parent.last].kind == .text) return false;
        if (parent.first != none and self.tree.nodes[parent.first].kind == .text) return false;
        return true;
    }

    fn characters(self: *Builder) Error!void {
        const start = self.at;
        var blank = true;
        while (!self.end() and self.text[self.at] != '<') : (self.at += 1) {
            const c = self.text[self.at];
            if (!space(c)) blank = false;
        }
        // Outside the root element of a document only white space appears;
        // libxml2 keeps none of it.
        if (self.current == 0 and self.mode == .document) return;
        if (blank and self.ignorable(self.at)) return;
        _ = try self.child(.text, try self.value(start, self.at, true, false, false));
    }

    /// The start tag at self.at (after '<'). Returns true for `/>`.
    fn startTag(self: *Builder) Error!bool {
        const tree = self.tree;
        const element = try tree.add(.{ .kind = .element, .name = try self.name() });
        tree.append(self.current, element);
        var last_attr: u32 = none;
        var last_decl: u32 = none;
        var empty = false;
        var preserve: ?bool = null;
        while (true) {
            self.skipSpace();
            if (startsWith(self.text, self.at, "/>")) {
                self.at += 2;
                empty = true;
                break;
            }
            if (startsWith(self.text, self.at, ">")) {
                self.at += 1;
                break;
            }
            const attribute_name = try self.name();
            self.skipSpace();
            if (self.end() or self.text[self.at] != '=') return error.InvalidXmlDocument;
            self.at += 1;
            self.skipSpace();
            if (self.end()) return error.InvalidXmlDocument;
            const quote = self.text[self.at];
            self.at += 1;
            const start = self.at;
            while (!self.end() and self.text[self.at] != quote) self.at += 1;
            if (self.end()) return error.InvalidXmlDocument;
            const stop = self.at;
            self.at += 1;
            const qualified = tree.bytes(attribute_name);
            const declaration = types.same(qualified, "xmlns") or startsWith(qualified, 0, "xmlns:");
            // Without entity replacement libxml2 keeps '&' of a namespace
            // URI as "&#38;" (the raw attribute value).
            const value_span = try self.value(start, stop, true, true, declaration and !self.replace_entities);
            if (declaration) {
                // A namespace declaration: its name is the prefix.
                const prefix_span: Span = if (qualified.len == 5) .{ .start = attribute_name.start, .len = 0 } else .{ .start = attribute_name.start + 6, .len = attribute_name.len - 6 };
                const prefix_text = tree.bytes(prefix_span);
                const uri = tree.bytes(value_span);
                const xml_uri = types.same(uri, xml_namespace_uri);
                if (uri.len != 0 and !validUri(uri)) tree.namespace_error = true;
                if (types.same(prefix_text, "xml")) {
                    // Never kept as a declaration; the wrong URI is an error.
                    if (!xml_uri) tree.namespace_error = true;
                    continue;
                }
                if (xml_uri or types.same(uri, "http://www.w3.org/2000/xmlns/") or types.same(prefix_text, "xmlns")) {
                    tree.namespace_error = true;
                    continue;
                }
                if (prefix_text.len != 0 and uri.len == 0) {
                    tree.namespace_error = true;
                    continue;
                }
                const decl = try tree.add(.{ .kind = .decl, .parent = element, .name = prefix_span, .value = value_span });
                if (last_decl == none) tree.nodes[element].decls = decl else tree.nodes[last_decl].next = decl;
                last_decl = decl;
                continue;
            }
            var colon: u32 = 0;
            for (qualified, 0..) |c, index| if (c == ':') {
                colon = @intCast(index);
                break;
            };
            const attribute = try tree.add(.{ .kind = .attribute, .parent = element, .name = attribute_name, .prefix_len = colon, .value = value_span });
            if (last_attr == none) tree.nodes[element].attrs = attribute else {
                tree.nodes[last_attr].next = attribute;
                tree.nodes[attribute].prev = last_attr;
            }
            last_attr = attribute;
            if (types.same(qualified, "xml:space")) {
                const setting = tree.bytes(value_span);
                if (types.same(setting, "preserve")) preserve = true else if (types.same(setting, "default")) preserve = false;
            }
        }
        // Namespaces: the element's prefix (or the default namespace), then
        // each prefixed attribute's.
        const qualified = tree.bytes(tree.nodes[element].name);
        var colon: u32 = 0;
        for (qualified, 0..) |c, index| if (c == ':') {
            colon = @intCast(index);
            break;
        };
        tree.nodes[element].prefix_len = colon;
        tree.nodes[element].ns = try self.resolve(element, qualified[0..colon], colon != 0);
        var attribute = tree.nodes[element].attrs;
        while (attribute != none) : (attribute = tree.nodes[attribute].next) {
            const n = &tree.nodes[attribute];
            if (n.prefix_len != 0) n.ns = try self.resolve(element, tree.bytes(n.name)[0..n.prefix_len], true);
            // Duplicate expanded names (same local name and URI).
            var earlier = tree.nodes[element].attrs;
            while (earlier != attribute) : (earlier = tree.nodes[earlier].next) {
                if (tree.nodes[earlier].ns == tree.nodes[attribute].ns and tree.nodes[attribute].ns != none and
                    types.same(tree.localName(earlier), tree.localName(attribute))) tree.namespace_error = true;
                if (tree.nodes[attribute].ns != none and tree.nodes[earlier].ns != none and tree.nodes[earlier].ns != tree.nodes[attribute].ns and
                    types.same(tree.namespaceUri(earlier), tree.namespaceUri(attribute)) and types.same(tree.localName(earlier), tree.localName(attribute))) tree.namespace_error = true;
            }
        }
        // xml:space: set by the attribute, else inherited.
        tree.nodes[element].flag = preserve orelse (self.current != 0 and tree.nodes[self.current].flag);
        if (!empty) self.current = element;
        return empty;
    }

    /// The declaration binding a prefix at an element ("xml" is implicit;
    /// an undeclared prefix is a namespace error). Unprefixed elements take
    /// the default namespace (an empty URI undeclares it).
    fn resolve(self: *Builder, element: u32, prefix_text: []const u8, prefixed: bool) Error!u32 {
        const tree = self.tree;
        if (prefixed and types.same(prefix_text, "xml")) return try self.xmlDeclaration();
        const found = tree.lookup(element, prefix_text);
        if (found == none) {
            if (prefixed) tree.namespace_error = true;
            return none;
        }
        if (!prefixed and tree.nodes[found].value.len == 0) return none;
        return found;
    }

    /// The implicit declaration of the xml prefix (one per tree).
    fn xmlDeclaration(self: *Builder) Error!u32 {
        const tree = self.tree;
        for (tree.nodes[0..tree.count], 0..) |*n, index| {
            if (n.kind == .decl and n.parent == none) return @intCast(index);
        }
        const prefix_span = try tree.putText("xml");
        const uri = try tree.putText(xml_namespace_uri);
        return tree.add(.{ .kind = .decl, .parent = none, .name = prefix_span, .value = uri });
    }

    fn endTag(self: *Builder) Error!void {
        self.at += 2;
        _ = try self.name();
        self.skipSpace();
        if (self.end() or self.text[self.at] != '>') return error.InvalidXmlDocument;
        self.at += 1;
        if (self.current == 0) return error.InvalidXmlDocument;
        self.current = self.tree.nodes[self.current].parent;
    }

    fn run(self: *Builder) Error!void {
        while (!self.end()) {
            if (self.text[self.at] != '<') {
                try self.characters();
                continue;
            }
            if (startsWith(self.text, self.at, "<!--")) {
                try self.comment();
            } else if (startsWith(self.text, self.at, "<![CDATA[")) {
                try self.cdata();
            } else if (startsWith(self.text, self.at, "<!DOCTYPE")) {
                try self.doctype();
            } else if (startsWith(self.text, self.at, "<?")) {
                try self.instruction();
            } else if (startsWith(self.text, self.at, "</")) {
                try self.endTag();
            } else {
                self.at += 1;
                _ = try self.startTag();
            }
        }
        if (self.current != 0) return error.InvalidXmlDocument;
    }
};

/// An upper bound of the nodes parse and the namespace axis create for
/// `text`: every '<' (a node or an end tag), every '=' (an attribute or a
/// declaration), every character run after '>', the document and the xml
/// declaration, plus one namespace node per element and in-scope
/// declaration (the xml namespace and each xmlns).
pub fn nodeBound(text: []const u8) usize {
    var markup: usize = 0;
    var equals: usize = 0;
    var runs: usize = 1;
    var declarations: usize = 0;
    for (text, 0..) |c, index| {
        switch (c) {
            '<' => markup += 1,
            '=' => equals += 1,
            '>' => if (index + 1 < text.len and text[index + 1] != '<') {
                runs += 1;
            },
            'x' => if (index + 5 <= text.len and types.same(text[index..][0..5], "xmlns")) {
                declarations += 1;
            },
            else => {},
        }
    }
    return markup + equals + runs + 2 + markup * (declarations + 1);
}

pub const Options = struct {
    mode: Mode = .document,
    /// false: libxml2's XML_PARSE_NOBLANKS heuristic.
    keep_blanks: bool = true,
    /// XML_PARSE_NOENT (xml_parse); XPath and XMLTABLE parse without it.
    replace_entities: bool = false,
};

/// Builds the tree of `tree.source` (a validated document or content; any
/// XML declaration is skipped).
pub fn parse(tree: *Tree, options: Options) Error!void {
    tree.count = 0;
    tree.text_len = 0;
    tree.namespace_error = false;
    tree.doctype = .{};
    const decl = xml.declaration(tree.source) orelse return error.InvalidXmlDocument;
    _ = try tree.add(.{ .kind = .document });
    var builder: Builder = .{ .tree = tree, .text = tree.source, .at = decl.len, .keep_blanks = options.keep_blanks, .replace_entities = options.replace_entities, .mode = options.mode };
    try builder.run();
}

// ---- namespace URIs (libxml2's xmlParseURI, RFC 3986) ------------------------

fn alpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn hexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

const Uri = struct {
    text: []const u8,
    at: usize = 0,

    fn cur(self: *const Uri) u8 {
        return if (self.at < self.text.len) self.text[self.at] else 0;
    }

    fn unreserved(self: *const Uri) bool {
        const c = self.cur();
        return alpha(c) or (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
    }

    fn subDelim(self: *const Uri) bool {
        return switch (self.cur()) {
            '!', '$', '&', 39, '(', ')', '*', '+', ',', ';', '=' => true,
            else => false,
        };
    }

    fn pct(self: *const Uri) bool {
        return self.cur() == '%' and self.at + 2 < self.text.len and hexDigit(self.text[self.at + 1]) and hexDigit(self.text[self.at + 2]);
    }

    fn pchar(self: *const Uri) bool {
        return self.unreserved() or self.pct() or self.subDelim() or self.cur() == ':' or self.cur() == '@';
    }

    fn advance(self: *Uri) void {
        self.at += if (self.cur() == '%') 3 else 1;
    }

    /// xmlParse3986Segment: `forbid` stops it; an empty one is an error
    /// unless `empty`.
    fn segment(self: *Uri, forbid: u8, empty: bool) bool {
        if (!self.pchar()) return empty;
        while (self.pchar() and self.cur() != forbid) self.advance();
        return true;
    }

    fn pathAbEmpty(self: *Uri) bool {
        while (self.cur() == '/') {
            self.at += 1;
            if (!self.segment(0, true)) return false;
        }
        return true;
    }

    fn pathAbsolute(self: *Uri) bool {
        if (self.cur() != '/') return false;
        self.at += 1;
        if (self.segment(0, false)) {
            while (self.cur() == '/') {
                self.at += 1;
                if (!self.segment(0, true)) return false;
            }
        }
        return true;
    }

    fn pathRest(self: *Uri, forbid: u8) bool {
        if (!self.segment(forbid, false)) return false;
        while (self.cur() == '/') {
            self.at += 1;
            if (!self.segment(0, true)) return false;
        }
        return true;
    }

    fn authority(self: *Uri) bool {
        const start = self.at;
        while (self.unreserved() or self.pct() or self.subDelim() or self.cur() == ':') self.advance();
        if (self.cur() == '@') self.at += 1 else self.at = start;
        if (self.cur() == '[') {
            self.at += 1;
            while (self.at < self.text.len and self.cur() != ']') self.at += 1;
            if (self.cur() != ']') return false;
            self.at += 1;
        } else {
            while (self.unreserved() or self.pct() or self.subDelim()) self.advance();
        }
        if (self.cur() == ':') {
            self.at += 1;
            if (!(self.cur() >= '0' and self.cur() <= '9')) return false;
            while (self.cur() >= '0' and self.cur() <= '9') self.at += 1;
        }
        return true;
    }

    fn tail(self: *Uri) bool {
        if (self.cur() == '?') {
            self.at += 1;
            while (self.pchar() or self.cur() == '/' or self.cur() == '?') self.advance();
        }
        if (self.cur() == '#') {
            self.at += 1;
            while (self.pchar() or self.cur() == '/' or self.cur() == '?') self.advance();
        }
        return self.at == self.text.len;
    }

    fn absolute(self: *Uri) bool {
        if (!alpha(self.cur())) return false;
        self.at += 1;
        while (alpha(self.cur()) or (self.cur() >= '0' and self.cur() <= '9') or self.cur() == '+' or self.cur() == '-' or self.cur() == '.') self.at += 1;
        if (self.cur() != ':') return false;
        self.at += 1;
        if (self.cur() == '/' and self.at + 1 < self.text.len and self.text[self.at + 1] == '/') {
            self.at += 2;
            if (!self.authority() or !self.pathAbEmpty()) return false;
        } else if (self.cur() == '/') {
            if (!self.pathAbsolute()) return false;
        } else if (self.pchar()) {
            if (!self.pathRest(0)) return false;
        }
        return self.tail();
    }

    fn relative(self: *Uri) bool {
        if (self.cur() == '/' and self.at + 1 < self.text.len and self.text[self.at + 1] == '/') {
            self.at += 2;
            if (!self.authority() or !self.pathAbEmpty()) return false;
        } else if (self.cur() == '/') {
            if (!self.pathAbsolute()) return false;
        } else if (self.pchar()) {
            if (!self.pathRest(':')) return false;
        }
        return self.tail();
    }
};

/// A URI reference libxml2's xmlParseURI accepts.
pub fn validUri(text: []const u8) bool {
    var absolute: Uri = .{ .text = text };
    if (absolute.absolute()) return true;
    var relative: Uri = .{ .text = text };
    return relative.relative();
}

// ---- namespace axis ---------------------------------------------------------

/// The namespace-axis nodes of element `element`, materialized once (as
/// libxml2's xmlXPathNextNamespace returns them): the xml namespace, then
/// the in-scope declarations (nearest first per prefix, xmlns="" omitted)
/// in reverse of xmlGetNsList order. Returns the first one.
pub fn namespaces(tree: *Tree, element: u32) Error!u32 {
    if (tree.nodes[element].ns_nodes != none) return tree.nodes[element].ns_nodes;
    // xmlGetNsList: from the element up, each element's declarations in
    // order, skipping prefixes already seen.
    var list: [64]u32 = undefined;
    var count: usize = 0;
    var at = element;
    while (at != none and tree.nodes[at].kind == .element) : (at = tree.nodes[at].parent) {
        var decl = tree.nodes[at].decls;
        while (decl != none) : (decl = tree.nodes[decl].next) {
            const prefix_text = tree.bytes(tree.nodes[decl].name);
            var seen = false;
            for (list[0..count]) |earlier| seen = seen or types.same(tree.bytes(tree.nodes[earlier].name), prefix_text);
            if (seen) continue;
            if (count == list.len) return error.ProgramLimitExceeded;
            list[count] = decl;
            count += 1;
        }
    }
    const xml_prefix = try tree.putText("xml");
    const xml_uri = try tree.putText(xml_namespace_uri);
    const first = try tree.add(.{ .kind = .namespace, .flag = true, .parent = element, .name = xml_prefix, .value = xml_uri });
    var previous = first;
    var index = count;
    while (index > 0) {
        index -= 1;
        const decl = list[index];
        const ns_node = try tree.add(.{ .kind = .namespace, .parent = element, .name = tree.nodes[decl].name, .value = tree.nodes[decl].value, .ns = decl });
        tree.nodes[previous].next = ns_node;
        previous = ns_node;
    }
    tree.nodes[element].ns_nodes = first;
    return first;
}

/// Document order of two nodes (namespace nodes follow their element and
/// precede its attributes; attributes precede its children).
pub fn order(tree: *const Tree, a: u32, b: u32) i8 {
    if (a == b) return 0;
    const ka = key(tree, a);
    const kb = key(tree, b);
    if (ka[0] != kb[0]) return if (ka[0] < kb[0]) -1 else 1;
    if (ka[1] != kb[1]) return if (ka[1] < kb[1]) -1 else 1;
    if (ka[2] != kb[2]) return if (ka[2] < kb[2]) -1 else 1;
    return 0;
}

fn key(tree: *const Tree, index: u32) [3]u32 {
    const n = &tree.nodes[index];
    return switch (n.kind) {
        .namespace => .{ n.parent, 1, index },
        .attribute => .{ n.parent, 2, index },
        else => .{ index, 0, 0 },
    };
}

// ---- serialization ----------------------------------------------------------

/// PostgreSQL's escape_xml: & < > and carriage return.
pub fn escapeText(data: []const u8, out: *Out) Error!void {
    for (data) |c| switch (c) {
        '&' => try out.add("&amp;"),
        '<' => try out.add("&lt;"),
        '>' => try out.add("&gt;"),
        '\r' => try out.add("&#x0d;"),
        else => try out.byte(c),
    };
}

const hex_digits = "0123456789ABCDEF";

/// xmlSerializeHexCharRef: &#xHH; with no leading zeros.
fn hexReference(code: u32, out: *Out) Error!void {
    try out.add("&#x");
    var digits: [8]u8 = undefined;
    var count: usize = 0;
    var rest = code;
    while (true) {
        digits[count] = hex_digits[rest & 15];
        count += 1;
        rest >>= 4;
        if (rest == 0) break;
    }
    while (count > 0) {
        count -= 1;
        try out.byte(digits[count]);
    }
    try out.byte(';');
}

/// Decodes one UTF-8 sequence at data[index] (validated text), returning its
/// code point and length.
fn decode(data: []const u8, index: usize) struct { code: u32, len: usize } {
    const c = data[index];
    if (c < 0xc0) return .{ .code = c, .len = 1 };
    const length: usize = if (c >= 0xf0) 4 else if (c >= 0xe0) 3 else 2;
    if (index + length > data.len) return .{ .code = c, .len = 1 };
    var code: u32 = c & (@as(u8, 0x7f) >> @intCast(length));
    for (data[index + 1 .. index + length]) |next| code = code << 6 | (next & 0x3f);
    return .{ .code = code, .len = length };
}

/// Text content: xmlEscapeContent (< > & and CR) or, when `entities`,
/// xmlEscapeEntities (also non-ASCII and other control characters as
/// hexadecimal character references).
fn escapeContent(data: []const u8, entities: bool, out: *Out) Error!void {
    var index: usize = 0;
    while (index < data.len) {
        const c = data[index];
        switch (c) {
            '<' => try out.add("&lt;"),
            '>' => try out.add("&gt;"),
            '&' => try out.add("&amp;"),
            '\r' => if (entities) try hexReference(13, out) else try out.add("&#13;"),
            else => {
                if (entities and (c >= 0x80 or (c < 0x20 and c != '\n' and c != '\t'))) {
                    const char = decode(data, index);
                    try hexReference(char.code, out);
                    index += char.len;
                    continue;
                }
                try out.byte(c);
            },
        }
        index += 1;
    }
}

/// xmlBufAttrSerializeTxtContent: an attribute value; non-ASCII becomes a
/// character reference when the node has no document encoding.
fn escapeAttribute(data: []const u8, references: bool, out: *Out) Error!void {
    var index: usize = 0;
    while (index < data.len) {
        const c = data[index];
        switch (c) {
            '\n' => try out.add("&#10;"),
            '\r' => try out.add("&#13;"),
            '\t' => try out.add("&#9;"),
            '"' => try out.add("&quot;"),
            '<' => try out.add("&lt;"),
            '>' => try out.add("&gt;"),
            '&' => try out.add("&amp;"),
            else => {
                if (references and c >= 0x80 and index + 1 < data.len) {
                    const char = decode(data, index);
                    try hexReference(char.code, out);
                    index += char.len;
                    continue;
                }
                try out.byte(c);
            },
        }
        index += 1;
    }
}

/// How a serialization escapes and indents.
pub const Style = struct {
    /// Attribute values: non-ASCII as character references (a node copy
    /// without a document, as xpath() dumps it).
    attribute_references: bool = false,
    /// Text: xmlEscapeEntities (an XMLSERIALIZE ... INDENT save context
    /// without an encoding) instead of xmlEscapeContent.
    text_entities: bool = false,
    /// XML_SAVE_FORMAT: indent element-only content by two spaces a level.
    format: bool = false,
};

fn declsOut(tree: *const Tree, element: u32, out: *Out) Error!void {
    var decl = tree.nodes[element].decls;
    while (decl != none) : (decl = tree.nodes[decl].next) {
        const prefix_text = tree.bytes(tree.nodes[decl].name);
        if (types.same(prefix_text, "xml")) continue;
        try declOut(prefix_text, tree.bytes(tree.nodes[decl].value), out);
    }
}

fn declOut(prefix_text: []const u8, uri: []const u8, out: *Out) Error!void {
    try out.add(if (prefix_text.len == 0) " xmlns" else " xmlns:");
    try out.add(prefix_text);
    try quoted(uri, out);
}

/// `=` and the value quoted (a namespace declaration's URI).
fn quoted(data: []const u8, out: *Out) Error!void {
    try out.byte('=');
    try quotedValue(data, out);
}

/// xmlBufWriteQuotedString: double quotes unless the value contains one.
fn quotedValue(data: []const u8, out: *Out) Error!void {
    var has_double = false;
    var has_single = false;
    for (data) |c| {
        if (c == '"') has_double = true;
        if (c == '\'') has_single = true;
    }
    if (has_double and has_single) {
        try out.byte('"');
        for (data) |c| if (c == '"') try out.add("&quot;") else try out.byte(c);
        try out.byte('"');
    } else if (has_double) {
        try out.byte('\'');
        try out.add(data);
        try out.byte('\'');
    } else {
        try out.byte('"');
        try out.add(data);
        try out.byte('"');
    }
}

/// xmlDtdDumpOutput of the DOCTYPE: the name, an external ID (PUBLIC
/// "pub" "sys" or SYSTEM "sys", quoted again) and the internal subset's
/// declarations one per line (white space runs collapsed).
fn doctypeOut(tree: *const Tree, out: *Out) Error!void {
    const raw = tree.bytes(tree.doctype);
    var at: usize = 9;
    const skip = struct {
        fn run(text: []const u8, index: *usize) void {
            while (index.* < text.len and space(text[index.*])) index.* += 1;
        }
    }.run;
    skip(raw, &at);
    const name_start = at;
    while (at < raw.len and nameChar(raw[at])) at += 1;
    try out.add("<!DOCTYPE ");
    try out.add(raw[name_start..at]);
    skip(raw, &at);
    var literals: [2][]const u8 = .{ "", "" };
    var public = false;
    var external = false;
    if (startsWith(raw, at, "PUBLIC") or startsWith(raw, at, "SYSTEM")) {
        public = raw[at] == 'P';
        external = true;
        at += 6;
        for (0..@as(usize, if (public) 2 else 1)) |index| {
            skip(raw, &at);
            if (at >= raw.len) break;
            const quote = raw[at];
            at += 1;
            const start = at;
            while (at < raw.len and raw[at] != quote) at += 1;
            literals[index] = raw[start..@min(at, raw.len)];
            at += 1;
        }
        skip(raw, &at);
    }
    if (external) {
        try out.add(if (public) " PUBLIC " else " SYSTEM ");
        try quotedValue(literals[0], out);
        if (public) {
            try out.byte(' ');
            try quotedValue(literals[1], out);
        }
    }
    if (at < raw.len and raw[at] == '[') {
        at += 1;
        var any = false;
        var index = at;
        while (index < raw.len and raw[index] != ']') {
            if (raw[index] != '<') {
                index += 1;
                continue;
            }
            // One markup declaration (quoted strings may hold '>').
            if (!any) try out.add(" [\n");
            any = true;
            var previous_space = false;
            var quote: u8 = 0;
            while (index < raw.len) : (index += 1) {
                const c = raw[index];
                if (quote != 0) {
                    try out.byte(c);
                    if (c == quote) quote = 0;
                    continue;
                }
                if (c == '"' or c == '\'') quote = c;
                if (space(c)) {
                    previous_space = true;
                    continue;
                }
                if (previous_space and c != '>') try out.byte(' ');
                previous_space = false;
                try out.byte(c);
                if (c == '>') {
                    index += 1;
                    break;
                }
            }
            try out.byte('\n');
        }
        if (any) {
            try out.add("]>");
            return;
        }
    }
    try out.byte('>');
}

/// The namespace declarations xmlCopyNode adds to the root of a copied
/// element: bindings used inside the subtree but declared outside it, in
/// the order the copy meets them.
const Added = struct {
    decls: [32]u32 = undefined,
    count: usize = 0,

    fn note(self: *Added, tree: *const Tree, root: u32, user: u32) Error!void {
        const decl = tree.nodes[user].ns;
        if (decl == none) return;
        const owner = tree.nodes[decl].parent;
        // The implicit xml prefix is never written.
        if (owner == none) return;
        // Declared inside the copied subtree?
        var at = if (tree.nodes[user].kind == .attribute) tree.nodes[user].parent else user;
        while (at != none) : (at = tree.nodes[at].parent) {
            if (at == owner) return;
            if (at == root) break;
        }
        const prefix_text = tree.bytes(tree.nodes[decl].name);
        for (self.decls[0..self.count]) |earlier| if (types.same(tree.bytes(tree.nodes[earlier].name), prefix_text)) return;
        if (self.count == self.decls.len) return error.ProgramLimitExceeded;
        self.decls[self.count] = decl;
        self.count += 1;
    }
};

fn startTag(tree: *const Tree, element: u32, added: ?*const Added, style: Style, out: *Out) Error!void {
    try out.byte('<');
    try out.add(tree.qname(element));
    try declsOut(tree, element, out);
    if (added) |extra| for (extra.decls[0..extra.count]) |decl| try declOut(tree.bytes(tree.nodes[decl].name), tree.bytes(tree.nodes[decl].value), out);
    var attribute = tree.nodes[element].attrs;
    while (attribute != none) : (attribute = tree.nodes[attribute].next) {
        try out.byte(' ');
        try out.add(tree.qname(attribute));
        try out.add("=\"");
        try escapeAttribute(tree.bytes(tree.nodes[attribute].value), style.attribute_references, out);
        try out.byte('"');
    }
}

fn indent(level: usize, out: *Out) Error!void {
    // xmlSaveCtxt: MAX_INDENT 60 characters of "  ".
    for (0..@min(level, 30)) |_| try out.add("  ");
}

/// Serializes node `root` and its subtree as libxml2's
/// xmlNodeDumpOutputInternal does (iteratively). `added` lists namespace
/// declarations to write on the root element.
fn dump(tree: *const Tree, root: u32, added: ?*const Added, style: Style, out: *Out) Error!void {
    var format = style.format;
    var unformatted: u32 = none;
    var level: usize = 0;
    var cur = root;
    while (true) {
        if (tree.control) |control| try control.checkpoint();
        const n = &tree.nodes[cur];
        var descend = false;
        switch (n.kind) {
            .element => {
                if (cur != root and format) try indent(level, out);
                try startTag(tree, cur, if (cur == root) added else null, style, out);
                if (n.first == none) {
                    try out.add("/>");
                } else {
                    if (format) {
                        var child_at = n.first;
                        while (child_at != none) : (child_at = tree.nodes[child_at].next) {
                            const kind = tree.nodes[child_at].kind;
                            if (kind == .text or kind == .cdata) {
                                format = false;
                                unformatted = cur;
                                break;
                            }
                        }
                    }
                    try out.byte('>');
                    if (format) try out.byte('\n');
                    level += 1;
                    descend = true;
                }
            },
            .text => try escapeContent(tree.bytes(n.value), style.text_entities, out),
            .cdata => {
                const content = tree.bytes(n.value);
                if (content.len == 0) {
                    try out.add("<![CDATA[]]>");
                } else {
                    try out.add("<![CDATA[");
                    try out.add(content);
                    try out.add("]]>");
                }
            },
            .comment => {
                if (cur != root and format) try indent(level, out);
                try out.add("<!--");
                try out.add(tree.bytes(n.value));
                try out.add("-->");
            },
            .pi => {
                if (cur != root and format) try indent(level, out);
                try out.add("<?");
                try out.add(tree.qname(cur));
                if (n.flag) {
                    try out.byte(' ');
                    try out.add(tree.bytes(n.value));
                }
                try out.add("?>");
            },
            .document, .attribute, .namespace, .decl => {},
        }
        if (descend) {
            cur = n.first;
            continue;
        }
        while (true) {
            if (cur == root) return;
            if (format) try out.byte('\n');
            if (tree.nodes[cur].next != none) {
                cur = tree.nodes[cur].next;
                break;
            }
            cur = tree.nodes[cur].parent;
            if (level > 0) level -= 1;
            if (format) try indent(level, out);
            try out.add("</");
            try out.add(tree.qname(cur));
            try out.byte('>');
            if (cur == unformatted) {
                format = style.format;
                unformatted = none;
            }
        }
    }
}

/// xml_xmlnodetoxmltype for nodes other than attributes, text and
/// namespaces: xmlNodeDump of xmlCopyNode(node) (the copy carries the
/// namespace declarations its subtree needs; a document copy is written
/// with an XML declaration and a newline after each child).
pub fn dumpCopy(tree: *const Tree, index: u32, out: *Out) Error!void {
    const style: Style = .{ .attribute_references = true };
    const n = &tree.nodes[index];
    if (n.kind == .document) {
        // The document copy is dumped with the context's encoding set, so
        // its attribute values keep non-ASCII characters.
        try out.add("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        var child_at = n.first;
        var position: u32 = 0;
        while (true) : (position += 1) {
            if (tree.doctype.len != 0 and position == tree.doctype_at) {
                try doctypeOut(tree, out);
                try out.byte('\n');
            }
            if (child_at == none) break;
            try dump(tree, child_at, null, .{}, out);
            try out.byte('\n');
            child_at = tree.nodes[child_at].next;
        }
        return;
    }
    if (n.kind != .element) return dump(tree, index, null, style, out);
    var added: Added = .{};
    var at = index;
    while (at != none) {
        if (tree.nodes[at].kind == .element) {
            try added.note(tree, index, at);
            var attribute = tree.nodes[at].attrs;
            while (attribute != none) : (attribute = tree.nodes[attribute].next) try added.note(tree, index, attribute);
            if (tree.nodes[at].first != none) {
                at = tree.nodes[at].first;
                continue;
            }
        }
        at = tree.following(at, index);
    }
    try dump(tree, index, &added, style, out);
}

/// XMLSERIALIZE ... INDENT (xmltotext_with_options): a document is saved
/// with xmlSaveDoc (an XML declaration only when the input had one, with
/// encoding "UTF-8"; trailing newlines removed), content node by node with
/// newlines between nodes that are not text.
pub fn indented(tree: *const Tree, mode: Mode, declared: bool, version: []const u8, standalone: ?bool, out: *Out) Error!void {
    const doc = &tree.nodes[0];
    var style: Style = .{ .format = true, .text_entities = true };
    if (mode == .document) {
        if (declared) {
            // xmlDocContentDumpOutput writes the declaration and, with it,
            // drops the entity escaping of non-ASCII text.
            style.text_entities = false;
            try out.add("<?xml version=\"");
            try out.add(version);
            try out.add("\" encoding=\"UTF-8\"");
            if (standalone) |yes| try out.add(if (yes) " standalone=\"yes\"" else " standalone=\"no\"");
            try out.add("?>\n");
        }
        var child_at = doc.first;
        var position: u32 = 0;
        while (true) : (position += 1) {
            if (tree.doctype.len != 0 and position == tree.doctype_at) {
                try doctypeOut(tree, out);
                try out.byte('\n');
            }
            if (child_at == none) break;
            try dump(tree, child_at, null, style, out);
            try out.byte('\n');
            child_at = tree.nodes[child_at].next;
        }
        while (out.len > 0 and (out.bytes[out.len - 1] == '\n' or out.bytes[out.len - 1] == '\r')) out.len -= 1;
        return;
    }
    var child_at = doc.first;
    while (child_at != none) : (child_at = tree.nodes[child_at].next) {
        const kind = tree.nodes[child_at].kind;
        if (kind != .text and tree.nodes[child_at].prev != none) try escapeContent("\n", true, out);
        try dump(tree, child_at, null, style, out);
    }
}
