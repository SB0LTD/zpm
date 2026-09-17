// dom_import — turn a live page's rendered DOM into an Elementor template.
// Layer 0: Core (pure computation; the browser transport lives in `cdp`).
//
// A flat screenshot loses the very things that make a page look like itself:
// the real words, the real images, and the exact CSS. The reliable way to get
// those is to read the *rendered* document from a real browser. This module
// owns two halves of that:
//
//   1. `extractor_js` — the canonical JavaScript that runs *inside* the page
//      (via CDP `Runtime.evaluate`). It walks the visual box tree and returns a
//      JSON string: the Elementor `content` array, built from computed styles,
//      geometry, text runs, and resolved image URLs. Doing the mapping in-page
//      is what makes it faithful — the browser has already done layout, font
//      resolution, and cascade for us.
//
//   2. `wrap` — assembles that content array into a complete, importable
//      Elementor document envelope
//      (`{"version","title","type":"page","content":[...]}`). Pure string
//      assembly into a caller buffer; no heap.
//
// Keeping the extractor here (not buried in a CLI tool) means every consumer —
// url2elementor today, a server or GUI tomorrow — shares one faithful mapping.

const std = @import("std");

/// Assemble a full Elementor template document from a `content` array that the
/// in-page `extractor_js` produced. `content_json` must be a JSON array text
/// (e.g. `[{...container...}]`). Returns the document slice inside `buf`.
///
/// Returns null if the buffer is too small.
pub fn wrap(buf: []u8, title: []const u8, content_json: []const u8) ?[]const u8 {
    var b = Writer{ .buf = buf };
    b.raw("{\"version\":\"0.4\",\"title\":\"");
    b.escaped(title);
    b.raw("\",\"type\":\"page\",\"content\":");
    // The extractor already emits a JSON array; splice it in verbatim. If it is
    // empty or malformed we still emit a valid (empty) document.
    if (looksLikeArray(content_json)) {
        b.raw(content_json);
    } else {
        b.raw("[]");
    }
    b.raw("}");
    if (b.overflow) return null;
    return b.slice();
}

fn looksLikeArray(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\n' or s[i] == '\r' or s[i] == '\t')) : (i += 1) {}
    return i < s.len and s[i] == '[';
}

/// The in-page extractor. It is evaluated in the target page and must evaluate
/// to a JSON *string* (CDP `returnByValue`) containing the Elementor content
/// array. It is written as an IIFE returning `JSON.stringify(content)`.
///
/// Design notes (why it produces what it does):
///   • It walks top-level "section" bands (direct, visible children of body /
///     main wrappers) and turns each into an Elementor container, preserving
///     the page's vertical order and each band's background color.
///   • Within a band it collects leaf visual elements — headings, text,
///     images, buttons/links styled as buttons — reading each one's computed
///     color, font-size, font-weight, text-align, and geometry, and the real
///     text or image URL. That is what makes the reconstruction match the
///     source rather than a placeholder.
///   • Elements sitting side by side (similar top, different left) are grouped
///     into a `flex_direction:row` container so multi-column rows survive.
///   • It resolves image URLs to absolute form and captures CSS background
///     images as image widgets too.
///   • Everything is clamped/bounded so a huge page can't produce unbounded
///     output; deeply nested trees are flattened to Elementor's container +
///     widget model.
pub const extractor_js =
    \\(function(){
    \\  "use strict";
    \\  var MAXW = 1440;
    \\  function px(v){ v=parseFloat(v); return isFinite(v)?Math.round(v):0; }
    \\  function rgbToHex(c){
    \\    if(!c) return "";
    \\    var m=c.match(/rgba?\(([^)]+)\)/); if(!m) return "";
    \\    var p=m[1].split(",").map(function(x){return parseFloat(x);});
    \\    if(p.length>=4 && p[3]===0) return ""; // fully transparent
    \\    function h(n){ n=Math.max(0,Math.min(255,Math.round(n))); var s=n.toString(16); return s.length<2?"0"+s:s; }
    \\    return "#"+h(p[0])+h(p[1])+h(p[2]);
    \\  }
    \\  function vis(el){
    \\    var s=getComputedStyle(el);
    \\    if(s.display==="none"||s.visibility==="hidden"||parseFloat(s.opacity)===0) return false;
    \\    var r=el.getBoundingClientRect();
    \\    if(r.width<2||r.height<2) return false;
    \\    return true;
    \\  }
    \\  function directText(el){
    \\    var t="";
    \\    for(var i=0;i<el.childNodes.length;i++){var n=el.childNodes[i]; if(n.nodeType===3) t+=n.textContent;}
    \\    return t.replace(/\s+/g," ").trim();
    \\  }
    \\  function allText(el){ return (el.innerText||el.textContent||"").replace(/\s+/g," ").trim(); }
    \\  function abs(u){ try{ return new URL(u, location.href).href; }catch(e){ return u||""; } }
    \\  function bgImage(s){
    \\    var b=s.backgroundImage; if(!b||b==="none") return "";
    \\    var m=b.match(/url\(["']?([^"')]+)["']?\)/); return m?abs(m[1]):"";
    \\  }
    \\  function svgDataUri(el){
    \\    try{
    \\      var clone=el.cloneNode(true);
    \\      if(!clone.getAttribute("xmlns")) clone.setAttribute("xmlns","http://www.w3.org/2000/svg");
    \\      var xml=new XMLSerializer().serializeToString(clone);
    \\      if(xml.length>60000) return ""; // keep the template bounded
    \\      return "data:image/svg+xml;base64,"+btoa(unescape(encodeURIComponent(xml)));
    \\    }catch(e){ return ""; }
    \\  }
    \\  function align(s){ var a=s.textAlign; if(a==="center")return"center"; if(a==="right"||a==="end")return"right"; return "left"; }
    \\  function heading(text,size,color,weight,al){
    \\    var lvl = size>=44?"h1": size>=34?"h2": size>=26?"h3": size>=21?"h4": size>=17?"h5":"h6";
    \\    var st={"title":text,"header_size":lvl,"align":al,"typography_typography":"custom",
    \\            "typography_font_size":{"unit":"px","size":size,"sizes":[]}};
    \\    if(color) st["title_color"]=color;
    \\    if(weight) st["typography_font_weight"]=String(weight);
    \\    return {"id":nid(),"elType":"widget","widgetType":"heading","settings":st,"elements":[]};
    \\  }
    \\  function para(text,size,color,al){
    \\    var st={"editor":"<p>"+esc(text)+"</p>","align":al,"typography_typography":"custom",
    \\            "typography_font_size":{"unit":"px","size":size,"sizes":[]}};
    \\    if(color) st["text_color"]=color;
    \\    return {"id":nid(),"elType":"widget","widgetType":"text-editor","settings":st,"elements":[]};
    \\  }
    \\  function button(text,color,bg,al){
    \\    var st={"text":text,"align":al};
    \\    if(color) st["button_text_color"]=color;
    \\    if(bg) st["background_color"]=bg;
    \\    return {"id":nid(),"elType":"widget","widgetType":"button","settings":st,"elements":[]};
    \\  }
    \\  function image(url,w,h){
    \\    var st={"image":{"url":url,"id":""}};
    \\    if(w) st["width"]={"unit":"px","size":w};
    \\    if(h) st["height"]={"unit":"px","size":h};
    \\    return {"id":nid(),"elType":"widget","widgetType":"image","settings":st,"elements":[]};
    \\  }
    \\  function container(bg,dir,children,al){
    \\    var st={};
    \\    if(bg){ st["background_background"]="classic"; st["background_color"]=bg; }
    \\    if(dir==="row"){ st["flex_direction"]="row"; }
    \\    if(al){ st["flex_align_items"]=al; }
    \\    return {"id":nid(),"elType":"container","settings":st,"elements":children};
    \\  }
    \\  var _id=0x20000000; function nid(){ _id=(_id+0x9e3779b1)>>>0; return _id.toString(16).slice(0,8); }
    \\  function esc(t){ return (t||"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;"); }
    \\  function isButtonish(el,s){
    \\    var tag=el.tagName.toLowerCase();
    \\    if(tag==="button") return true;
    \\    if(tag==="a"){
    \\      var bg=rgbToHex(s.backgroundColor);
    \\      var br=parseFloat(s.borderRadius)||0;
    \\      var hasBg = bg && bg!=="#ffffff";
    \\      var hasBorder = (parseFloat(s.borderTopWidth)||0)>0;
    \\      if((hasBg||hasBorder) && (br>=0) && allText(el).length<40) return true;
    \\    }
    \\    return false;
    \\  }
    \\  // Collect the leaf visual widgets under a band, in document order.
    \\  function widgetsIn(band){
    \\    var out=[];
    \\    var seen=new Set();
    \\    var all=band.querySelectorAll("h1,h2,h3,h4,h5,h6,p,img,button,a,li,span,blockquote,div,section,figure,svg");
    \\    for(var i=0;i<all.length;i++){
    \\      var el=all[i];
    \\      if(!vis(el)) continue;
    \\      // skip if an ancestor we already emitted contains it
    \\      var skip=false, a=el.parentElement;
    \\      while(a && a!==band){ if(seen.has(a)){skip=true;break;} a=a.parentElement; }
    \\      if(skip) continue;
    \\      var s=getComputedStyle(el);
    \\      var tag=el.tagName.toLowerCase();
    \\      var r=el.getBoundingClientRect();
    \\      if(tag==="img"){
    \\        out.push({node:el, rect:r, w:image(abs(el.currentSrc||el.src), px(r.width), px(r.height))});
    \\        seen.add(el); continue;
    \\      }
    \\      // Inline SVG icons (common on modern sites) — serialize to a data URI
    \\      // so they survive as a real image widget rather than being dropped.
    \\      if(tag==="svg"){
    \\        var du=svgDataUri(el);
    \\        if(du){ out.push({node:el, rect:r, w:image(du, px(r.width), px(r.height))}); seen.add(el); continue; }
    \\      }
    \\      // Any element carrying a CSS background-image becomes an image widget
    \\      // (hero art, logos, and icon tiles on SPA sites are drawn this way).
    \\      var bimg=bgImage(s);
    \\      if(bimg && r.width>=24 && r.height>=24){
    \\        out.push({node:el, rect:r, w:image(bimg, px(r.width), px(r.height))});
    \\        seen.add(el); continue;
    \\      }
    \\      if(isButtonish(el,s)){
    \\        var t=allText(el); if(!t) continue;
    \\        out.push({node:el, rect:r, w:button(t, rgbToHex(s.color), rgbToHex(s.backgroundColor), align(s))});
    \\        seen.add(el); continue;
    \\      }
    \\      if(/^h[1-6]$/.test(tag)){
    \\        var t2=allText(el); if(!t2) continue;
    \\        out.push({node:el, rect:r, w:heading(t2, px(s.fontSize), rgbToHex(s.color), s.fontWeight, align(s))});
    \\        seen.add(el); continue;
    \\      }
    \\      // paragraphs / text: only take the direct text to avoid duplicating children
    \\      var dt=directText(el);
    \\      if(dt && dt.length>1){
    \\        var fs=px(s.fontSize);
    \\        var fw=parseInt(s.fontWeight)||400;
    \\        if(fs>=22 || fw>=600){
    \\          out.push({node:el, rect:r, w:heading(dt, fs, rgbToHex(s.color), s.fontWeight, align(s))});
    \\        } else {
    \\          out.push({node:el, rect:r, w:para(dt, fs, rgbToHex(s.color), align(s))});
    \\        }
    \\        seen.add(el);
    \\      }
    \\    }
    \\    return out;
    \\  }
    \\  // Group widgets that sit on the same visual row into row containers.
    \\  function rowsOf(items){
    \\    items.sort(function(x,y){ return (x.rect.top-y.rect.top)||(x.rect.left-y.rect.left); });
    \\    var rows=[], cur=[], curTop=null;
    \\    for(var i=0;i<items.length;i++){
    \\      var it=items[i];
    \\      if(curTop===null || Math.abs(it.rect.top-curTop)<=Math.max(24,it.rect.height*0.6)){
    \\        cur.push(it); if(curTop===null) curTop=it.rect.top;
    \\      } else { rows.push(cur); cur=[it]; curTop=it.rect.top; }
    \\    }
    \\    if(cur.length) rows.push(cur);
    \\    var children=[];
    \\    for(var r=0;r<rows.length;r++){
    \\      var row=rows[r];
    \\      if(row.length===1){ children.push(row[0].w); }
    \\      else {
    \\        row.sort(function(x,y){return x.rect.left-y.rect.left;});
    \\        var kids=row.map(function(z){return z.w;});
    \\        children.push(container("","row",kids,"center"));
    \\      }
    \\    }
    \\    return children;
    \\  }
    \\  // Choose the top-level bands: prefer <section>/<header>/<footer>, else the
    \\  // direct children of the main content wrapper.
    \\  function bands(){
    \\    var explicit=document.querySelectorAll("body section, body header, body footer, main > *");
    \\    var list=[];
    \\    if(explicit.length>=2){ for(var i=0;i<explicit.length;i++) list.push(explicit[i]); }
    \\    else {
    \\      var root=document.querySelector("main")||document.body;
    \\      for(var c=0;c<root.children.length;c++) list.push(root.children[c]);
    \\    }
    \\    // keep only visible, reasonably tall bands, in order
    \\    return list.filter(function(el){ if(!vis(el)) return false; var r=el.getBoundingClientRect(); return r.height>=24; });
    \\  }
    \\  var content=[];
    \\  var bs=bands();
    \\  var MAXBANDS=40;
    \\  for(var i=0;i<bs.length && i<MAXBANDS;i++){
    \\    var band=bs[i];
    \\    var s=getComputedStyle(band);
    \\    var bg=rgbToHex(s.backgroundColor);
    \\    var items=widgetsIn(band);
    \\    if(items.length===0){
    \\      var bi=bgImage(s);
    \\      if(bi){ content.push(container(bg,"column",[image(bi,MAXW,px(band.getBoundingClientRect().height))],"")); }
    \\      continue;
    \\    }
    \\    var kids=rowsOf(items);
    \\    content.push(container(bg,"column",kids,""));
    \\  }
    \\  return JSON.stringify(content);
    \\})()
;

// ── Clone mode (pixel-perfect) ───────────────────────────────────────────
//
// The widget decomposition above rebuilds a page out of Elementor's widget
// vocabulary — good for an *editable* template, but it necessarily drops the
// site's own CSS and JS, so it can never be pixel-identical or animated. When
// the goal is instead "render exactly like the source, animations and all", the
// only faithful representation is the original document itself.
//
// `clone_extractor_js` serializes the live, fully-rendered page into one
// self-contained HTML string:
//   • injects a <base href> so every relative URL (CSS, JS, fonts, images)
//     resolves against the original origin — no rewriting, no CORS fetches,
//     and external assets keep loading exactly as they do on the real site;
//   • inlines the CSS it can read (same-origin styleSheets) as <style> blocks
//     so first paint is styled even before late requests finish;
//   • KEEPS <script> tags (inline + external) so the page's JavaScript — and
//     therefore its interactions and JS-driven animations — runs;
//   • returns the whole thing as a JSON string.
//
// `wrapHtmlWidget` then wraps that document in a single full-width Elementor
// HTML widget. Because Elementor sanitizes raw <script> out of widget HTML, the
// document is delivered inside an <iframe srcdoc="..."> — an iframe runs its
// own scripts, so CSS + JS + animations all execute, isolated from WordPress.
pub const clone_extractor_js =
    \\(function(){
    \\  "use strict";
    \\  // Absolute base so relative asset URLs resolve to the origin server.
    \\  var baseHref = location.href;
    \\  // Clone the live document so we can mutate without disturbing the page.
    \\  var doc = document.documentElement.cloneNode(true);
    \\  // Drop any existing <base>, then inject ours at the top of <head>.
    \\  var head = doc.querySelector("head") || doc;
    \\  var olds = head.querySelectorAll("base"); for (var i=0;i<olds.length;i++) olds[i].remove();
    \\  var base=document.createElement("base"); base.setAttribute("href", baseHref);
    \\  if (head.firstChild) head.insertBefore(base, head.firstChild); else head.appendChild(base);
    \\  // Inline readable same-origin stylesheets so styling survives even if a
    \\  // sheet 404s inside the iframe. Cross-origin sheets stay as <link> and
    \\  // load via the base href.
    \\  try {
    \\    var sheets=document.styleSheets;
    \\    var css="";
    \\    for (var s=0;s<sheets.length;s++){
    \\      var rules=null; try{ rules=sheets[s].cssRules; }catch(e){ rules=null; }
    \\      if(!rules) continue;
    \\      for (var r=0;r<rules.length;r++){ css+=rules[r].cssText+"\n"; }
    \\    }
    \\    if(css.length>0 && css.length<2000000){
    \\      var st=document.createElement("style");
    \\      st.setAttribute("data-u2e-inlined","1");
    \\      st.textContent=css; head.appendChild(st);
    \\    }
    \\  } catch(e){}
    \\  var html="<!doctype html>"+doc.outerHTML;
    \\  return html;
    \\})()
;

/// Build a complete Elementor document whose single page contains one
/// full-width HTML widget that renders `page_html` verbatim inside an
/// `<iframe srcdoc>`. This is the pixel-perfect path: the browser inside the
/// iframe runs the original CSS and JS, so the result looks and behaves like
/// the source (animations included). `page_html` is the captured document from
/// `clone_extractor_js`.
///
/// Layout: a zero-padding, full-width container holding an `html` widget. The
/// widget markup is a 100vw/100vh seamless iframe using the `srcdoc`
/// attribute; the captured page is HTML-attribute-escaped into it.
pub fn wrapHtmlWidget(buf: []u8, title: []const u8, page_html: []const u8) ?[]const u8 {
    var b = Writer{ .buf = buf };
    b.raw("{\"version\":\"0.4\",\"title\":\"");
    b.escaped(title);
    b.raw("\",\"type\":\"page\",\"content\":[");

    // Full-bleed container.
    b.raw("{\"id\":\"c1000001\",\"elType\":\"container\",\"settings\":{" ++
        "\"content_width\":\"full\",\"width\":{\"unit\":\"%\",\"size\":100}," ++
        "\"padding\":{\"unit\":\"px\",\"top\":\"0\",\"right\":\"0\",\"bottom\":\"0\",\"left\":\"0\",\"isLinked\":true}" ++
        "},\"elements\":[");

    // The html widget. settings.html is a JSON string; inside it we build the
    // iframe whose srcdoc holds the captured page (HTML-attribute-escaped).
    b.raw("{\"id\":\"w1000002\",\"elType\":\"widget\",\"widgetType\":\"html\",\"settings\":{\"html\":\"");
    // widget markup: an iframe with the page in srcdoc. Everything here is
    // written through JSON string escaping (jsonEscaped), and the srcdoc value
    // additionally needs HTML-attribute escaping for quotes — we escape '"' as
    // &quot; at the HTML level, then JSON-escape the whole markup.
    // Build the markup piecewise.
    b.escaped("<iframe title=\"clone\" style=\"display:block;width:100%;height:100vh;border:0;margin:0;\" sandbox=\"allow-scripts allow-same-origin allow-popups allow-forms\" srcdoc=\"");
    // srcdoc value: HTML-attribute-escape the captured page, then JSON-escape.
    b.htmlAttrEscapedJson(page_html);
    b.escaped("\"></iframe>");
    b.raw("\"},\"elements\":[]}");

    b.raw("]}]}");
    if (b.overflow) return null;
    return b.slice();
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "wrap produces a valid envelope around a content array" {
    var buf: [256]u8 = undefined;
    const out = wrap(&buf, "My Page", "[{\"elType\":\"container\"}]").?;
    try testing.expect(std.mem.startsWith(u8, out, "{\"version\":\"0.4\""));
    try testing.expect(contains(out, "\"title\":\"My Page\""));
    try testing.expect(contains(out, "\"type\":\"page\""));
    try testing.expect(contains(out, "\"content\":[{\"elType\":\"container\"}]"));
    try testing.expect(std.mem.endsWith(u8, out, "}"));
}

test "wrap falls back to empty content when input is not an array" {
    var buf: [128]u8 = undefined;
    const out = wrap(&buf, "T", "not json").?;
    try testing.expect(contains(out, "\"content\":[]"));
}

test "wrap escapes the title" {
    var buf: [128]u8 = undefined;
    const out = wrap(&buf, "a\"b", "[]").?;
    try testing.expect(contains(out, "\"title\":\"a\\\"b\""));
}

test "wrap reports overflow as null" {
    var buf: [8]u8 = undefined;
    try testing.expect(wrap(&buf, "long title here", "[]") == null);
}

test "extractor_js is a non-empty IIFE returning a stringify" {
    try testing.expect(extractor_js.len > 100);
    try testing.expect(contains(extractor_js, "JSON.stringify(content)"));
    try testing.expect(std.mem.startsWith(u8, extractor_js, "(function(){"));
}

test "clone_extractor_js injects a base and keeps scripts" {
    try testing.expect(clone_extractor_js.len > 100);
    try testing.expect(std.mem.startsWith(u8, clone_extractor_js, "(function(){"));
    try testing.expect(contains(clone_extractor_js, "base"));
    try testing.expect(contains(clone_extractor_js, "doc.outerHTML"));
}

test "wrapHtmlWidget builds an iframe-srcdoc html widget" {
    var buf: [4096]u8 = undefined;
    const page = "<!doctype html><html><body><h1>Hi \"world\" & <b>x</b></body></html>";
    const out = wrapHtmlWidget(&buf, "Clone", page).?;
    // envelope
    try testing.expect(contains(out, "\"version\":\"0.4\""));
    try testing.expect(contains(out, "\"title\":\"Clone\""));
    try testing.expect(contains(out, "\"widgetType\":\"html\""));
    // the iframe + srcdoc are present, and the page's quotes/angle-brackets are
    // HTML-attribute-escaped inside srcdoc (so &quot; / &lt; appear, not raw).
    try testing.expect(contains(out, "<iframe"));
    try testing.expect(contains(out, "srcdoc="));
    try testing.expect(contains(out, "&quot;world&quot;"));
    try testing.expect(contains(out, "&lt;b&gt;"));
    try testing.expect(std.mem.endsWith(u8, out, "}"));
}

test "wrapHtmlWidget reports overflow as null" {
    var buf: [16]u8 = undefined;
    try testing.expect(wrapHtmlWidget(&buf, "T", "<html></html>") == null);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── small no-alloc JSON writer (mirrors document.sig's escaping) ──

const Writer = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    fn raw(self: *Writer, s: []const u8) void {
        for (s) |c| self.byte(c);
    }
    fn escaped(self: *Writer, s: []const u8) void {
        for (s) |c| switch (c) {
            '"' => self.raw("\\\""),
            '\\' => self.raw("\\\\"),
            '\n' => self.raw("\\n"),
            '\r' => self.raw("\\r"),
            '\t' => self.raw("\\t"),
            else => self.byte(c),
        };
    }
    /// Write `s` HTML-attribute-escaped (so it is safe as an iframe `srcdoc`
    /// value) AND JSON-string-escaped (so it is safe inside settings.html).
    /// The HTML entities emitted are pure ASCII, so JSON escaping of them is a
    /// no-op; only the original bytes need the double treatment.
    fn htmlAttrEscapedJson(self: *Writer, s: []const u8) void {
        for (s) |c| switch (c) {
            // HTML-attribute escapes first (these bytes never need JSON escaping).
            '&' => self.raw("&amp;"),
            '"' => self.raw("&quot;"),
            '\'' => self.raw("&#39;"),
            '<' => self.raw("&lt;"),
            '>' => self.raw("&gt;"),
            // JSON escapes for characters that would break the JSON string.
            '\\' => self.raw("\\\\"),
            '\n' => self.raw("\\n"),
            '\r' => self.raw("\\r"),
            '\t' => self.raw("\\t"),
            else => self.byte(c),
        };
    }
    fn byte(self: *Writer, c: u8) void {
        if (self.len >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.len] = c;
        self.len += 1;
    }
    fn slice(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};
