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

/// Assemble a full Elementor document from a hybrid `content` array produced by
/// `hybrid_extractor_js`. The hybrid extractor already folds the page CSS and
/// JS into the content array as leading/trailing `html` widgets, so this is
/// exactly `wrap`: envelope + verbatim content array. Kept as a distinct name
/// so callers read intent (and so the two paths can diverge later without a
/// churny rename). Returns null if `buf` is too small.
pub fn wrapHybrid(buf: []u8, title: []const u8, content_json: []const u8) ?[]const u8 {
    return wrap(buf, title, content_json);
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

// ── Hybrid mode (editable AND faithful, no iframe) ───────────────────────
//
// The clone is pixel-perfect but one opaque block; the widget decomposition is
// editable but loses the site's CSS/JS. Hybrid keeps *both*: it emits real
// native Elementor widgets (heading / text-editor / button / image) and real
// Elementor containers, but each carries the source element's original CSS
// classes and id. The page's own CSS and JS are carried verbatim alongside, so
// the browser styles and animates those widgets exactly as the source did —
// no iframe, everything in one document, so scripts reach the widgets.
//
// The fidelity rules (learned from real pages):
//   • CSS is class-keyed on real sites, so putting the original class list on a
//     widget's wrapper (`_css_classes`) makes the original rules apply. IDs go
//     on `_element_id` so id-based JS/CSS still binds.
//   • Structural CSS (grid/flex like `.g4`, `.grid`, `.nav`) targets a
//     *container*, so bands and rows become native containers carrying the
//     original class — the layout rules then land on the flex/grid parent.
//   • Some nodes must NOT become editable native widgets:
//       – nodes whose text the page JS rewrites every frame (counters `.count`,
//         typewriters `#tw`) — editing would fight the animation;
//       – interactive / stateful markup (forms, <details> accordions, the
//         burger button + menu, elements with inline on* handlers);
//       – nodes whose inner structure carries meaning the widget vocabulary
//         can't hold (inline <span>/<br> inside a heading).
//     These are emitted VERBATIM as an `html` widget wrapping the node's
//     outerHTML, still inside a container that carries the original class — so
//     the original CSS and JS keep working on the untouched subtree, while the
//     block remains an individually reorderable Elementor element.
//
// `hybrid_extractor_js` evaluates in-page and returns a JSON *string*: the
// Elementor `content` array, ready to splice into the document envelope. The
// page's CSS is folded in as a LEADING `html` widget (`<style>…</style>`) and
// its executable JS as a TRAILING `html` widget (external `<script src>` +
// inline `<script>`), so styling applies to every widget and scripts run once
// the widget DOM exists. Because the return is already a content array,
// `wrapHybrid` is just `wrap` — no Sig-side JSON parsing.
pub const hybrid_extractor_js =
    \\(function(){
    \\  "use strict";
    \\  function abs(u){ try{ return new URL(u, location.href).href; }catch(e){ return u||""; } }
    \\  function px(v){ v=parseFloat(v); return isFinite(v)?Math.round(v):0; }
    \\  function directText(el){
    \\    var t=""; for(var i=0;i<el.childNodes.length;i++){var n=el.childNodes[i]; if(n.nodeType===3) t+=n.textContent;}
    \\    return t.replace(/\s+/g," ").trim();
    \\  }
    \\  function vis(el){
    \\    var s=getComputedStyle(el);
    \\    if(s.display==="none"||s.visibility==="hidden") return false;
    \\    return true;
    \\  }
    \\  function idOf(el){ return el.getAttribute("id")||""; }
    \\  var _id=0x30000000; function nid(){ _id=(_id+0x9e3779b1)>>>0; return _id.toString(16).slice(0,8); }
    \\
    \\  // ── Per-element inline styles → generated classes ────────────────────
    \\  // Elementor containers/widgets can't carry an arbitrary style="" attribute,
    \\  // but many source elements rely on inline style (transition-delay, custom
    \\  // properties like --c1/--c2, one-off margins). We hoist each distinct
    \\  // inline style into a generated `.u2e-sN` class appended to the folded CSS,
    \\  // and add that class to the node — so the exact inline style still applies.
    \\  var styleCss=""; var styleSeq=0; var styleMap={};
    \\  function inlineClass(el){
    \\    var s=el.getAttribute("style"); if(!s) return "";
    \\    s=s.trim(); if(!s) return "";
    \\    if(styleMap[s]) return styleMap[s];
    \\    var cn="u2e-s"+(styleSeq++);
    \\    styleMap[s]=cn;
    \\    styleCss+="."+cn+"{"+s+(s.charAt(s.length-1)===";"?"":";")+"}\n";
    \\    return cn;
    \\  }
    \\
    \\  // ── Elementor node builders ──────────────────────────────────────────
    \\  // Every builder stamps the source element's original classes + id + a
    \\  // generated inline-style class onto the Elementor node, so the folded CSS
    \\  // (which is class/id keyed) reapplies exactly.
    \\  // Stamp the source element's classes + id onto an Elementor node.
    \\  // IMPORTANT: the CSS-classes SETTING KEY DIFFERS BY ELEMENT TYPE.
    \\  //   • containers use  "css_classes"  (no underscore)
    \\  //   • widgets    use  "_css_classes" (with underscore)
    \\  // Using the wrong key makes Elementor silently drop the classes (which is
    \\  // exactly what flattened every source .hero/.card/.grid box). `isCon`
    \\  // selects the right key.
    \\  function hooks(st,el,isCon){
    \\    var c=(el.getAttribute("class")||"").replace(/\s+/g," ").trim();
    \\    var ic=inlineClass(el);
    \\    var all=(c+" "+ic).trim();
    \\    if(all) st[isCon?"css_classes":"_css_classes"]=all;
    \\    var id=idOf(el); if(id) st["_element_id"]=id;
    \\    return st;
    \\  }
    \\  // Capture a container's *computed* layout into a generated class, so its
    \\  // display/grid/flex geometry is reproduced exactly regardless of which
    \\  // source selector produced it — and regardless of Elementor's own .e-con
    \\  // defaults, which we override here at the element level.
    \\  // Capture a container's computed layout. CRITICAL: Elementor's own
    \\  // frontend CSS lays out a container via CUSTOM PROPERTIES with !important,
    \\  // e.g. `.e-con.e-flex{flex-direction:var(--flex-direction)!important}` and
    \\  // `--flex-direction:column` by default. A plain `flex-direction:row` (even
    \\  // !important) in our class LOSES to that. So we must drive Elementor's own
    \\  // vars — set --flex-direction/--justify-content/--align-items/--gap (flex)
    \\  // or --grid-* (grid) — AND also set the raw properties as a belt-and-braces
    \\  // fallback for non-Elementor rendering.
    \\  // Drive layout through Elementor's NATIVE container settings, not CSS.
    \\  // Elementor writes its flex/grid layout as INLINE custom-property styles on
    \\  // the container (from these settings) with !important — those beat any
    \\  // stylesheet, so the only way to win is to set the settings themselves.
    \\  // We read the source element's computed layout and translate it.
    \\  function applyLayout(st,el){
    \\    var s=getComputedStyle(el);
    \\    var d=s.display;
    \\    if(d==="grid"||d==="inline-grid"){
    \\      st["container_type"]="grid";
    \\      if(s.gridTemplateColumns&&s.gridTemplateColumns!=="none") st["grid_template_columns"]={"unit":"custom","size":"","sizes":[]}; // set raw below
    \\      // Elementor grid columns/rows accept a free-form string via *_custom
    \\      st["grid_gaps"]={"unit":"px","size":parseFloat(s.columnGap)||0,"column":String(parseFloat(s.columnGap)||0),"row":String(parseFloat(s.rowGap)||0),"unit":"px"};
    \\      // Raw grid template via a generated class fallback (Elementor's grid
    \\      // column control is a simple integer; real templates need the class).
    \\      return true;
    \\    }
    \\    if(d==="flex"||d==="inline-flex"){
    \\      st["container_type"]="flex";
    \\      var dir=s.flexDirection||"row";
    \\      st["flex_direction"]=dir;
    \\      if(s.justifyContent&&s.justifyContent!=="normal") st["flex_justify_content"]=s.justifyContent;
    \\      if(s.alignItems&&s.alignItems!=="normal"&&s.alignItems!=="normal") st["flex_align_items"]=s.alignItems;
    \\      if(s.flexWrap) st["flex_wrap"]=s.flexWrap;
    \\      var g=parseFloat(s.gap); if(isFinite(g)&&g>0) st["flex_gap"]={"unit":"px","size":g,"column":String(g),"row":String(g)};
    \\      return true;
    \\    }
    \\    return false;
    \\  }
    \\  // Belt-and-braces: also emit a generated class that forces display + the
    \\  // exact grid template / flex geometry, in case native settings under- or
    \\  // mis-translate (esp. grid templates, which Elementor's simple controls
    \\  // can't express). This class targets the container AND its boxed inner.
    \\  var layoutCss=""; var layoutSeq=0;
    \\  function layoutClass(el){
    \\    var s=getComputedStyle(el);
    \\    var d=s.display;
    \\    // A non-flex/grid source container still gets Elementor's default
    \\    // display:flex, which turns a plain block wrapper (e.g. .wrap) into a
    \\    // flex box and breaks margin:0 auto centering + normal text flow. Force
    \\    // the source's real block/inline display back.
    \\    if(d!=="flex"&&d!=="grid"&&d!=="inline-flex"&&d!=="inline-grid"){
    \\      var cn0="u2e-l"+(layoutSeq++);
    \\      layoutCss+="."+cn0+",."+cn0+">.e-con-inner{display:"+d+"!important;}\n";
    \\      return cn0;
    \\    }
    \\    var decl="display:"+d+"!important;";
    \\    if(d==="grid"||d==="inline-grid"){
    \\      if(s.gridTemplateColumns&&s.gridTemplateColumns!=="none") decl+="grid-template-columns:"+s.gridTemplateColumns+"!important;";
    \\      if(s.gridTemplateRows&&s.gridTemplateRows!=="none") decl+="grid-template-rows:"+s.gridTemplateRows+"!important;";
    \\      if(s.gridAutoFlow&&s.gridAutoFlow!=="row") decl+="grid-auto-flow:"+s.gridAutoFlow+"!important;";
    \\    } else {
    \\      decl+="flex-direction:"+s.flexDirection+"!important;flex-wrap:"+s.flexWrap+"!important;";
    \\      if(s.justifyContent&&s.justifyContent!=="normal") decl+="justify-content:"+s.justifyContent+"!important;";
    \\      if(s.alignItems&&s.alignItems!=="normal") decl+="align-items:"+s.alignItems+"!important;";
    \\    }
    \\    if(s.gap&&s.gap!=="normal") decl+="gap:"+s.gap+"!important;";
    \\    var cn="u2e-l"+(layoutSeq++);
    \\    layoutCss+="."+cn+",."+cn+">.e-con-inner{"+decl+"}\n";
    \\    return cn;
    \\  }
    \\  function container(el,children){
    \\    var st=hooks({},el,true);
    \\    applyLayout(st,el);
    \\    var lc=layoutClass(el);
    \\    if(lc){ st["css_classes"]=((st["css_classes"]||"")+" "+lc).trim(); }
    \\    // FULL width (not boxed): a boxed container injects a .e-con-inner
    \\    // wrapper that becomes the SOLE flex/grid child of .e-con — so a
    \\    // space-between nav or a gap'd .nav-links has only ONE item and can't
    \\    // space anything. A full container has NO inner wrapper: the real child
    \\    // widgets are direct children of .e-con, so the source flex/grid layout
    \\    // actually spaces them. Centering (.wrap margin:0 auto) still works
    \\    // because we force the source display and keep source margins.
    \\    st["content_width"]="full";
    \\    return {"id":nid(),"elType":"container","settings":st,"elements":children};
    \\  }
    \\  function heading(el,tag){
    \\    var t=tag||el.tagName.toLowerCase(); if(!/^h[1-6]$/.test(t)) t="h2";
    \\    // innerHTML keeps inline spans/br (e.g. the typewriter #tw markup) intact.
    \\    return {"id":nid(),"elType":"widget","widgetType":"heading",
    \\      "settings":hooks({"title":el.innerHTML,"header_size":t},el,false),"elements":[]};
    \\  }
    \\  function textw(el){
    \\    // text-editor keeps the element's own inner markup (inline formatting).
    \\    return {"id":nid(),"elType":"widget","widgetType":"text-editor",
    \\      "settings":hooks({"editor":"<"+el.tagName.toLowerCase()+">"+el.innerHTML+"</"+el.tagName.toLowerCase()+">"},el,false),"elements":[]};
    \\  }
    \\  function button(el){
    \\    var st=hooks({"text":(el.textContent||"").replace(/\s+/g," ").trim()},el,false);
    \\    var href=el.getAttribute("href"); if(href) st["link"]={"url":abs(href),"is_external":"","nofollow":""};
    \\    return {"id":nid(),"elType":"widget","widgetType":"button","settings":st,"elements":[]};
    \\  }
    \\  function image(el){
    \\    var r=el.getBoundingClientRect();
    \\    return {"id":nid(),"elType":"widget","widgetType":"image",
    \\      "settings":hooks({"image":{"url":abs(el.currentSrc||el.src),"id":""},
    \\        "width":{"unit":"px","size":px(r.width)},"height":{"unit":"px","size":px(r.height)}},el,false),"elements":[]};
    \\  }
    \\  function rawHtml(el){
    \\    // Last resort for a subtree the widget vocabulary can't hold (svg, form,
    \\    // <details>, script-driven text). Kept verbatim so its CSS+JS still work.
    \\    return {"id":nid(),"elType":"widget","widgetType":"html",
    \\      "settings":{"html":el.outerHTML},"elements":[]};
    \\  }
    \\
    \\  // ── Fate helpers ─────────────────────────────────────────────────────
    \\  // Nodes whose exact inner structure the widget model can't represent, or
    \\  // that the page JS mutates continuously, are kept verbatim (as html).
    \\  function mustStayVerbatim(el){
    \\    var tag=el.tagName.toLowerCase();
    \\    if(tag==="svg"||tag==="form"||tag==="details"||tag==="summary"||tag==="iframe"||tag==="video"||tag==="canvas"||tag==="table"||tag==="select"||tag==="textarea"||tag==="input"||tag==="ul"||tag==="ol") return true;
    \\    for(var i=0;i<el.attributes.length;i++){ if(/^on/i.test(el.attributes[i].name)) return true; }
    \\    if(el.classList && (el.classList.contains("count")||el.classList.contains("cur"))) return true;
    \\    var id=idOf(el); if(id && /^(tw|tw2|tw3|burger|mobileMenu|leadMsg)$/.test(id)) return true;
    \\    return false;
    \\  }
    \\  // Only inline-formatting children → the element can be ONE heading/text
    \\  // widget whose innerHTML preserves those inline children verbatim. We do
    \\  // NOT bail out when an inline child is JS-driven (e.g. the typewriter
    \\  // <span id="tw">): keeping it inside the heading's HTML preserves its id,
    \\  // so main.js still finds and animates it — and crucially the heading stays
    \\  // ONE line-flowing element instead of fragmenting into stacked blocks.
    \\  var INLINE={a:1,b:1,i:1,em:1,strong:1,u:1,span:1,br:1,small:1,sup:1,sub:1,mark:1,code:1,abbr:1,time:1,wbr:1,s:1};
    \\  function onlyInlineChildren(el){
    \\    for(var i=0;i<el.children.length;i++){
    \\      var c=el.children[i];
    \\      if(!INLINE[c.tagName.toLowerCase()]) return false;
    \\      if(!onlyInlineChildren(c)) return false;
    \\    }
    \\    return true;
    \\  }
    \\  function isButtonish(el){
    \\    var tag=el.tagName.toLowerCase();
    \\    if(tag==="button") return true;
    \\    if(tag==="a"){ var s=getComputedStyle(el); var hasBg=s.backgroundColor&&s.backgroundColor!=="rgba(0, 0, 0, 0)"&&s.backgroundColor!=="transparent"; var hasBorder=(parseFloat(s.borderTopWidth)||0)>0; var t=(el.textContent||"").trim(); return (hasBg||hasBorder)&&t.length>0&&t.length<40; }
    \\    return false;
    \\  }
    \\
    \\  // ── The recursive decomposition ──────────────────────────────────────
    \\  // Returns an array of Elementor nodes for `el`. Every element becomes a
    \\  // container (carrying its classes/id/inline-style) whose children are the
    \\  // recursively-built children; leaves bottom out at heading/text/button/
    \\  // image widgets. Only genuinely un-representable subtrees fall back to html.
    \\  var MAXDEPTH=14;
    \\  function build(el, depth){
    \\    if(el.nodeType!==1) return [];
    \\    if(!vis(el)) return [];
    \\    if(mustStayVerbatim(el)) return [rawHtml(el)];
    \\    var tag=el.tagName.toLowerCase();
    \\    if(tag==="img") return [image(el)];
    \\    if(tag==="br"||tag==="hr") return [rawHtml(el)];
    \\    if(isButtonish(el)) return [button(el)];
    \\
    \\    var hasElemChildren=el.children.length>0;
    \\    var text=directText(el);
    \\    var cs=getComputedStyle(el);
    \\    var isFlow=(cs.display==="flex"||cs.display==="grid"||cs.display==="inline-flex"||cs.display==="inline-grid");
    \\
    \\    // Leaf-ish: no element children, or only inline-formatting children →
    \\    // one text/heading widget that preserves the inner inline markup.
    \\    // BUT never collapse a flex/grid element: its children must stay separate
    \\    // Elementor items so the container's gap/justify/align actually spaces
    \\    // them (collapsing .nav-links into one text widget is what crammed the
    \\    // menu links together).
    \\    if((!hasElemChildren || (onlyInlineChildren(el) && !isFlow)) ){
    \\      if(!text && !hasElemChildren) {
    \\        // empty structural node (decorative) — keep as an empty container so
    \\        // its background/size CSS still paints (e.g. .divider, .glow, .faces).
    \\        return [container(el,[])];
    \\      }
    \\      if(/^h[1-6]$/.test(tag)) return [heading(el)];
    \\      var fw=parseInt(cs.fontWeight)||400; var fs=px(cs.fontSize);
    \\      // A short, bold/large inline run reads as a heading; else body text.
    \\      if((fs>=22||fw>=600) && text.length<120 && tag!=="p") return [heading(el,"h3")];
    \\      return [textw(el)];
    \\    }
    \\
    \\    if(depth>=MAXDEPTH) return [rawHtml(el)];
    \\
    \\    // Structural node → container with recursively-built children.
    \\    var kids=[];
    \\    for(var i=0;i<el.children.length;i++){
    \\      var parts=build(el.children[i], depth+1);
    \\      for(var j=0;j<parts.length;j++) kids.push(parts[j]);
    \\    }
    \\    // Some elements mix direct text WITH element children (e.g. an <a> that is
    \\    // "text <span>x</span>"). Preserve that leading/trailing text.
    \\    if(text){
    \\      // prepend a text widget carrying the element's own direct text run
    \\      kids.unshift({"id":nid(),"elType":"widget","widgetType":"text-editor",
    \\        "settings":{"editor":"<span>"+text.replace(/&/g,"&amp;").replace(/</g,"&lt;")+"</span>"},"elements":[]});
    \\    }
    \\    if(kids.length===0) return [container(el,[])];
    \\    return [container(el, kids)];
    \\  }
    \\
    \\  // ── Top-level bands ──────────────────────────────────────────────────
    \\  function bands(){
    \\    var explicit=document.querySelectorAll("body > *, body > header, body > footer, body > nav, body > section, main > *");
    \\    var seen=[]; var list=[];
    \\    var kids=document.body.children;
    \\    for(var c=0;c<kids.length;c++) list.push(kids[c]);
    \\    return list.filter(function(el){ var t=el.tagName.toLowerCase(); if(t==="script"||t==="style"||t==="noscript"||t==="link"||t==="template") return false; return vis(el); });
    \\  }
    \\  var content=[]; var bs=bands(); var MAXBANDS=80;
    \\  for(var i=0;i<bs.length && i<MAXBANDS;i++){
    \\    var parts=build(bs[i],1);
    \\    for(var k=0;k<parts.length;k++) content.push(parts[k]);
    \\  }
    \\
    \\  // ── Collect the page CSS (same-origin rules) and executable JS. ──────
    \\  var css="";
    \\  try{
    \\    var sheets=document.styleSheets;
    \\    for(var s=0;s<sheets.length;s++){ var rules=null; try{rules=sheets[s].cssRules;}catch(e){rules=null;} if(!rules) continue;
    \\      for(var r=0;r<rules.length;r++){ css+=rules[r].cssText+"\n"; } }
    \\  }catch(e){}
    \\  // Shim: neutralize Elementor's container/widget chrome so the ORIGINAL
    \\  // layout CSS governs. Elementor renders a container as
    \\  //   .e-con > .e-con-inner > children
    \\  // and wraps each widget in .elementor-widget > .elementor-widget-container.
    \\  // Making those wrappers `display:contents` lifts the real children up so
    \\  // the class we put on the container (e.g. .grid.g4) sees them directly.
    \\  // The shim ONLY makes Elementor's *wrapper* nodes transparent — it must
    \\  // NEVER touch the .e-con element's own display/padding/margin/background,
    \\  // because that element carries the source class (.hero/.card/.grid/.section)
    \\  // whose box + layout must survive verbatim. Concretely:
    \\  //   • .e-con-inner: the wrapper Elementor injects between a container and
    \\  //     its children. `display:contents` dissolves it so the container's own
    \\  //     class (e.g. .grid.g4) lays out the REAL children, not this wrapper.
    \\  //   • .elementor-widget + .elementor-widget-container: the two wrappers
    \\  //     around every leaf widget. `display:contents` dissolves them so the
    \\  //     source class we put on the widget applies to its actual tag, and the
    \\  //     widget adds no box/margin of its own.
    \\  //   • zero Elementor's default container padding/gap/width *custom
    \\  //     properties* (not the CSS props themselves) so they don't fight the
    \\  //     source; the source class re-supplies real values.
    \\  // Shim strategy (full-container model): dissolve EVERY Elementor wrapper
    \\  // with `display:contents` so the source element's OWN tag becomes the real
    \\  // box/flex-item/grid-item, styled+laid-out purely by the source CSS +
    \\  // our layout class. We must be thorough: a container is
    \\  //   .e-con > (.e-con-inner?) > .elementor-widget > .elementor-widget-container > <tag>
    \\  // and every wrapper in that chain except the class-carrying .e-con and the
    \\  // final <tag> must vanish from layout, or it becomes a stray full-width
    \\  // block that breaks flex rows (what stacked the nav links + made buttons
    \\  // full-width bars). We also zero Elementor's own spacing custom-props.
    \\  // Shim strategy: keep Elementor's container element(s) as the real
    \\  // flex/grid parent (we drive their layout via the vars in layoutClass),
    \\  // but dissolve the per-WIDGET wrappers so each source tag (<a>,<h_>,<p>,
    \\  // <img>) is itself the flex/grid ITEM — otherwise Elementor's full-width
    \\  // widget block wrappers become the items and everything stacks. We do NOT
    \\  // dissolve .e-con-inner (a boxed container lays out on it). We also zero
    \\  // Elementor's own spacing custom-props and strip its widget/button chrome.
    \\  // Shim strategy: the SOURCE class sits on the Elementor WIDGET WRAPPER
    \\  // (.elementor-widget-*). So that wrapper must be a REAL box (so .btn/.card
    \\  // paint on it) that SHRINKS to content (width:auto) and adds no Elementor
    \\  // chrome — then it behaves like the original element as a flex/grid item.
    \\  // We do NOT use display:contents on widgets (that left the source class
    \\  // with no box, flattening buttons). We dissolve only the INNER
    \\  // widget-container so the wrapper's box directly holds the content, and we
    \\  // strip Elementor's own heading/text/button styling so only source CSS shows.
    \\  var shim=
    \\    "\n/* u2e: widget wrapper = the real box (carries source class), shrink-to-content, no Elementor chrome */\n"+
    \\    ".elementor .elementor-widget{margin:0;padding:0;width:auto;max-width:100%;}\n"+
    \\    ".elementor .elementor-widget>.elementor-widget-container{display:contents;}\n"+
    \\    // zero Elementor's default container spacing custom-props (NOT the props themselves,
    \\    // so a source padding/gap still paints; only Elementor's own defaults die)
    \\    ".elementor .e-con{--padding-block-start:0px;--padding-block-end:0px;--padding-inline-start:0px;--padding-inline-end:0px;--container-widget-width:auto;--container-widget-flex-grow:0;min-height:0;}\n"+
    \\    ".elementor .elementor-element{--widgets-spacing:0px;--widgets-spacing-row:0px;--widgets-spacing-column:0px;}\n"+
    \\    // neutralize Elementor's own heading/text box styling so ONLY source CSS paints
    \\    ".elementor .elementor-heading-title{margin:0;font:inherit;color:inherit;letter-spacing:inherit;line-height:inherit;text-align:inherit;background:none;display:inline;}\n"+
    \\    ".elementor .elementor-widget-text-editor{color:inherit;font:inherit;line-height:inherit;}\n"+
    \\    ".elementor .elementor-widget-text-editor>*{margin:0;}\n"+
    \\    // button: strip ALL Elementor button chrome so the source .btn class (on the wrapper) alone styles it
    \\    ".elementor .elementor-widget-button .elementor-button{background:none;background-image:none;border:0;padding:0;margin:0;font:inherit;color:inherit;border-radius:inherit;fill:inherit;text-align:inherit;box-shadow:none;min-height:0;width:auto;display:contents;}\n"+
    \\    ".elementor .elementor-widget-button .elementor-button-content-wrapper,.elementor .elementor-widget-button .elementor-button-text{display:contents;}\n"+
    \\    ".elementor .elementor-widget-image img{width:auto;}\n";
    \\    // NOTE: each container also carries a generated `.u2e-lN` class that
    \\    // re-asserts its computed display/grid/flex/gap with !important, so the
    \\    // site's real layout wins over Elementor's `.e-con{display:flex}` default
    \\    // regardless of source selector. That CSS lives in `layoutCss` below.
    \\  var fullCss=css+styleCss+layoutCss+shim;
    \\  // Executable scripts only: skip type=application/ld+json and other data blocks.
    \\  var inlineJs="";
    \\  var srcs=[];
    \\  var scripts=document.querySelectorAll("script");
    \\  for(var sc=0;sc<scripts.length;sc++){
    \\    var t=(scripts[sc].getAttribute("type")||"").toLowerCase();
    \\    if(t && t!=="text/javascript" && t!=="module" && t!=="application/javascript") continue; // data block
    \\    if(scripts[sc].src){ srcs.push(abs(scripts[sc].src)); }
    \\    else { inlineJs+=scripts[sc].textContent+"\n;\n"; }
    \\  }
    \\  function htmlWidget(inner){
    \\    return {"id":nid(),"elType":"widget","widgetType":"html","settings":{"html":inner},"elements":[]};
    \\  }
    \\  var out=[];
    \\  if(fullCss){ out.push(htmlWidget("<style>\n"+fullCss+"\n</style>")); }
    \\  for(var b2=0;b2<content.length;b2++) out.push(content[b2]);
    \\  var jsBlock="";
    \\  for(var p=0;p<srcs.length;p++){ jsBlock+='<script src="'+srcs[p]+'"><\/script>\n'; }
    \\  if(inlineJs){ jsBlock+="<script>\n"+inlineJs+"\n<\/script>"; }
    \\  if(jsBlock){ out.push(htmlWidget(jsBlock)); }
    \\  return JSON.stringify(out);
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

test "hybrid_extractor_js is an IIFE returning a content array" {
    try testing.expect(hybrid_extractor_js.len > 100);
    try testing.expect(std.mem.startsWith(u8, hybrid_extractor_js, "(function(){"));
    // returns the content array (not a {css,js} object)
    try testing.expect(contains(hybrid_extractor_js, "return JSON.stringify(out)"));
    // carries original class/id onto widgets
    try testing.expect(contains(hybrid_extractor_js, "_css_classes"));
    try testing.expect(contains(hybrid_extractor_js, "_element_id"));
    // folds CSS as a leading <style> html widget and JS as trailing <script>
    try testing.expect(contains(hybrid_extractor_js, "<style>"));
    try testing.expect(contains(hybrid_extractor_js, "<script"));
    // keeps JS-animated / interactive nodes verbatim
    try testing.expect(contains(hybrid_extractor_js, "mustStayVerbatim"));
}

test "wrapHybrid wraps a hybrid content array into an envelope" {
    var buf: [512]u8 = undefined;
    const content =
        "[{\"id\":\"a\",\"elType\":\"widget\",\"widgetType\":\"html\",\"settings\":{\"html\":\"<style>.x{}</style>\"},\"elements\":[]}," ++
        "{\"id\":\"b\",\"elType\":\"widget\",\"widgetType\":\"heading\",\"settings\":{\"title\":\"Hi\",\"_css_classes\":\"h-l\"},\"elements\":[]}]";
    const out = wrapHybrid(&buf, "Hybrid", content).?;
    try testing.expect(contains(out, "\"version\":\"0.4\""));
    try testing.expect(contains(out, "\"title\":\"Hybrid\""));
    try testing.expect(contains(out, "\"_css_classes\":\"h-l\""));
    try testing.expect(contains(out, "<style>.x{}</style>"));
    try testing.expect(std.mem.endsWith(u8, out, "}"));
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
