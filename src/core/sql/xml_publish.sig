//! SQL/XML publishing (Layer 0), after xml.c (B11 wave 4, types-ext lane):
//! name escaping (map_sql_identifier_to_xml_name), text escaping
//! (escape_xml), attribute values, XMLPI / XMLCOMMENT checks and XMLROOT's
//! declaration. Output goes to a caller-owned byte buffer; overflow is
//! TextCapacity (54000).
const types = @import("types.sig");
const xml = @import("xml.sig");
const Error = types.Error;

pub const Out = struct {
    bytes: []u8,
    len: usize = 0,

    pub fn add(self: *Out, data: []const u8) Error!void {
        if (data.len > self.bytes.len - self.len) return error.TextCapacity;
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn byte(self: *Out, c: u8) Error!void {
        if (self.len == self.bytes.len) return error.TextCapacity;
        self.bytes[self.len] = c;
        self.len += 1;
    }

    pub fn slice(self: *const Out) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn nameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':' or c >= 0x80;
}

fn nameChar(c: u8) bool {
    return nameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + value - 10;
}

/// map_sql_identifier_to_xml_name (fully escaped, not escaping a leading
/// "xml"): characters that are not name characters become _xHHHH_, as
/// does ':' and a '_' that starts "_x".
pub fn name(identifier: []const u8, out: *Out) Error!void {
    var index: usize = 0;
    while (index < identifier.len) {
        const c = identifier[index];
        var length: usize = 1;
        var code: u32 = c;
        if (c >= 0xc0) {
            length = if (c >= 0xf0) 4 else if (c >= 0xe0) 3 else 2;
            if (index + length > identifier.len) length = identifier.len - index;
            code = c & (@as(u8, 0xff) >> @intCast(length + 1));
            for (identifier[index + 1 .. index + length]) |next| code = code << 6 | (next & 0x3f);
        }
        const escape_x = c == '_' and index + 1 < identifier.len and identifier[index + 1] == 'x';
        const legal = if (index == 0) nameStart(c) else nameChar(c);
        if (c == ':' or escape_x or !legal or (c >= 0x80 and false)) {
            try out.add("_x");
            var digits: [8]u8 = undefined;
            var count: usize = 0;
            var rest = code;
            while (rest != 0 or count < 4) : (rest >>= 4) {
                digits[count] = hexDigit(@intCast(rest & 15));
                count += 1;
            }
            while (count > 0) {
                count -= 1;
                try out.byte(digits[count]);
            }
            try out.byte('_');
        } else try out.add(identifier[index .. index + length]);
        index += length;
    }
}

/// escape_xml: & < > and carriage return.
pub fn text(value: []const u8, out: *Out) Error!void {
    for (value) |c| switch (c) {
        '&' => try out.add("&amp;"),
        '<' => try out.add("&lt;"),
        '>' => try out.add("&gt;"),
        '\r' => try out.add("&#x0d;"),
        else => try out.byte(c),
    };
}

/// An attribute value as libxml2 writes it: & < " escaped (and > as in
/// escape_xml's mapping of the value), CR/LF/TAB as character references.
pub fn attribute(value: []const u8, out: *Out) Error!void {
    for (value) |c| switch (c) {
        '&' => try out.add("&amp;"),
        '<' => try out.add("&lt;"),
        '>' => try out.add("&gt;"),
        '"' => try out.add("&quot;"),
        '\r' => try out.add("&#13;"),
        '\n' => try out.add("&#10;"),
        '\t' => try out.add("&#9;"),
        else => try out.byte(c),
    };
}

/// XMLPI target and content checks (2200T): the target may not be "xml"
/// in any case and the content may not contain "?>"; leading spaces of
/// the content are dropped.
pub fn processingInstruction(target: []const u8, content: ?[]const u8, out: *Out) Error!void {
    if (types.keyword(target, "xml")) return error.InvalidXmlProcessingInstruction;
    if (content) |body| {
        for (0..body.len -| 1) |index| if (body[index] == '?' and body[index + 1] == '>') return error.InvalidXmlProcessingInstruction;
    }
    try out.add("<?");
    try name(target, out);
    if (content) |body| {
        var start: usize = 0;
        while (start < body.len and body[start] == ' ') start += 1;
        if (start < body.len) {
            try out.byte(' ');
            try out.add(body[start..]);
        }
    }
    try out.add("?>");
}

/// XMLCOMMENT (2200S for "--" or a trailing '-').
pub fn comment(body: []const u8, out: *Out) Error!void {
    for (0..body.len -| 1) |index| if (body[index] == '-' and body[index + 1] == '-') return error.InvalidXmlComment;
    if (body.len != 0 and body[body.len - 1] == '-') return error.InvalidXmlComment;
    try out.add("<!--");
    try out.add(body);
    try out.add("-->");
}

/// XMLROOT: replaces any declaration; it is printed only when it says
/// more than version 1.0 (no standalone), like xml_out.
pub fn root(value: []const u8, version: ?[]const u8, standalone: ?bool, out: *Out) Error!void {
    var body = value;
    if (xml.declaration(value)) |declared| body = value[declared.len..];
    while (body.len != 0 and (body[0] == '\n' or body[0] == ' ' or body[0] == '\t' or body[0] == '\r') and xml.declaration(value) != null) body = body[1..];
    const plain = standalone == null and (version == null or types.same(version.?, "1.0"));
    if (!plain) {
        try out.add("<?xml version=\"");
        try out.add(version orelse "1.0");
        try out.byte('"');
        if (standalone) |yes| {
            try out.add(if (yes) " standalone=\"yes\"" else " standalone=\"no\"");
        }
        try out.add("?>");
    }
    try out.add(body);
}
