// @zpm/youtube/botguard/jsvm/env — Browser Environment Stubs
//
// Provides fake browser globals that BotGuard fingerprints.
// Must return plausible Chrome-on-Windows values to pass BG's checks.
//
// Stubs: navigator, window, document, screen, location, history,
//        performance, crypto, Intl, localStorage

const values = @import("values.sig");
const objects = @import("objects.sig");
const builtins = @import("builtins.sig");
const browser_metadata = @import("browser_metadata.sig");
const Value = values.Value;

// ── Install all environment stubs ──

/// Call after builtins.installGlobals().
pub var dbg_no_document: bool = false;
var navigator_proto: u32 = objects.NULL_OBJ;

pub fn installEnvironment(global: u32) void {
    // Record the global for builtins that need a realm reference (e.g. a created
    // iframe's contentWindow, which BotGuard reads to obtain a pristine String).
    builtins.g_global_obj = global;
    builtins.dom_element_proto = objects.NULL_OBJ;
    builtins.dom_style_proto = objects.NULL_OBJ;
    objects.setProperty(global, values.internString("DeviceOrientationEvent"), Value.function(objects.createFunction(builtins.N_DOM_ORIENTATION_EVENT)));
    installNavigator(global);
    installWindow(global);
    const chrome = objects.createObject();
    setNativeMethod(chrome, "loadTimes", builtins.N_OBJ_CREATE);
    setNativeMethod(chrome, "csi", builtins.N_OBJ_CREATE);
    objects.setProperty(chrome, values.internString("app"), Value.object(objects.createObject()));
    objects.setProperty(global, values.internString("chrome"), Value.object(chrome));
    if (!dbg_no_document) installDocument(global);
    installScreen(global);
    installLocation(global);
    installPerformance(global);
    installCrypto(global);
    installIntl(global);
    installMisc(global);
    browser_metadata.installMissing(global, &browser_metadata.window_fields, builtins.N_DOM_NOOP);
    const navigator_ctor = objects.getProperty(global, values.internString("Navigator"));
    if (navigator_ctor.tag == .function and navigator_proto != objects.NULL_OBJ) {
        objects.setProperty(navigator_ctor.data.func_idx, values.internString("prototype"), Value.object(navigator_proto));
        objects.setEnumerable(navigator_ctor.data.func_idx, values.internString("prototype"), false);
        objects.setProperty(navigator_proto, values.internString("constructor"), navigator_ctor);
        objects.setEnumerable(navigator_proto, values.internString("constructor"), false);
    }
    for (browser_metadata.window_fields) |field| {
        if (field.kind != .function or field.name.len == 0 or field.name[0] < 'A' or field.name[0] > 'Z') continue;
        const value = objects.getProperty(global, values.internString(field.name));
        if (value.tag != .function or objects.hasOwnProperty(value.data.func_idx, values.internString("prototype"))) continue;
        const native_id = objects.closureFuncId(value.data.func_idx);
        if (native_id != builtins.N_DOM_NOOP and native_id != builtins.N_DOM_IMAGE and native_id != builtins.N_DOM_ORIENTATION_EVENT) continue;
        const proto = objects.createObject();
        objects.setObjectPrototype(proto, builtins.dom_element_proto);
        objects.setProperty(proto, values.internString("constructor"), value);
        objects.setEnumerable(proto, values.internString("constructor"), false);
        if (values.internString(field.name) == values.internString("SVGRect")) {
            for ([_][]const u8{ "x", "y", "width", "height" }) |name|
                objects.setProperty(proto, values.internString(name), Value.number(0));
        }
        if (values.internString(field.name) == values.internString("DeviceOrientationEvent")) {
            for ([_][]const u8{ "alpha", "beta", "gamma" }) |name|
                objects.setProperty(proto, values.internString(name), Value.NULL);
            objects.setProperty(proto, values.internString("absolute"), Value.FALSE);
        }
        objects.setProperty(value.data.func_idx, values.internString("prototype"), Value.object(proto));
        objects.setEnumerable(value.data.func_idx, values.internString("prototype"), false);
    }
}

fn installNavigator(global: u32) void {
    const nav = objects.createObject();
    navigator_proto = nav;
    setPropStr(nav, "userAgent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36");
    setPropStr(nav, "platform", "Win32");
    setPropStr(nav, "language", "en-US");
    setPropStr(nav, "vendor", "Google Inc.");
    setPropStr(nav, "appName", "Netscape");
    setPropStr(nav, "appVersion", "5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36");
    setPropStr(nav, "product", "Gecko");
    setPropStr(nav, "productSub", "20030107");
    setPropNum(nav, "hardwareConcurrency", 8);
    setPropNum(nav, "deviceMemory", 8);
    setPropNum(nav, "maxTouchPoints", 0);
    setPropBool(nav, "cookieEnabled", true);
    setPropBool(nav, "onLine", true);
    setPropBool(nav, "pdfViewerEnabled", true);
    setPropBool(nav, "webdriver", false);

    // navigator.languages = ["en-US", "en"]
    const langs = objects.createArray(2);
    objects.setArrayElement(langs, 0, Value.string(values.internString("en-US")));
    objects.setArrayElement(langs, 1, Value.string(values.internString("en")));
    objects.setProperty(nav, values.internString("languages"), Value.object(langs));

    // navigator.connection (stub)
    const conn = objects.createObject();
    setPropStr(conn, "effectiveType", "4g");
    setPropNum(conn, "downlink", 10);
    setPropNum(conn, "rtt", 50);
    objects.setProperty(nav, values.internString("connection"), Value.object(conn));

    // navigator.plugins (empty array-like)
    const plugins = objects.createArray(0);
    objects.setProperty(nav, values.internString("plugins"), Value.object(plugins));

    // navigator.mimeTypes (empty)
    objects.setProperty(nav, values.internString("mimeTypes"), Value.object(objects.createArray(0)));

    objects.dbgMarkEnvObject(nav);
    objects.dbgMarkEnvObject(conn);
    const instance = objects.createObject();
    objects.setObjectPrototype(instance, nav);
    objects.setProperty(global, values.internString("navigator"), Value.object(instance));
}

fn installWindow(global: u32) void {
    // window === global (self-reference)
    objects.dbgMarkEnvObject(global);
    objects.setProperty(global, values.internString("window"), Value.object(global));
    objects.setProperty(global, values.internString("self"), Value.object(global));
    objects.setProperty(global, values.internString("globalThis"), Value.object(global));
    objects.setProperty(global, values.internString("top"), Value.object(global));
    objects.setProperty(global, values.internString("parent"), Value.object(global));
    objects.setProperty(global, values.internString("frames"), Value.object(global));

    setPropNum(global, "innerWidth", 1920);
    setPropNum(global, "innerHeight", 1080);
    setPropNum(global, "outerWidth", 1920);
    setPropNum(global, "outerHeight", 1080);
    setPropNum(global, "screenX", 0);
    setPropNum(global, "screenY", 0);
    setPropNum(global, "pageXOffset", 0);
    setPropNum(global, "pageYOffset", 0);
    setPropNum(global, "scrollX", 0);
    setPropNum(global, "scrollY", 0);
    setPropNum(global, "devicePixelRatio", 1);

    // requestAnimationFrame stub
    const raf_func = objects.createFunction(builtins.N_SET_TIMEOUT);
    objects.setProperty(global, values.internString("requestAnimationFrame"), Value.function(raf_func));
    objects.setProperty(global, values.internString("cancelAnimationFrame"), Value.function(objects.createFunction(builtins.N_CLEAR_TIMEOUT)));

    // Event registration + idle/immediate scheduling. BotGuard probes for these
    // on window during fingerprinting; undefined there aborts feature collection.
    setNativeMethod(global, "addEventListener", builtins.N_DOM_NOOP);
    setNativeMethod(global, "removeEventListener", builtins.N_DOM_NOOP);
    setNativeMethod(global, "dispatchEvent", builtins.N_DOM_NOOP);
    setNativeMethod(global, "requestIdleCallback", builtins.N_SET_TIMEOUT);
    setNativeMethod(global, "cancelIdleCallback", builtins.N_CLEAR_TIMEOUT);
    setNativeMethod(global, "setImmediate", builtins.N_SET_TIMEOUT);
    setNativeMethod(global, "clearImmediate", builtins.N_CLEAR_TIMEOUT);
    setNativeMethod(global, "queueMicrotask", builtins.N_SET_TIMEOUT);
    setNativeMethod(global, "matchMedia", builtins.N_DOM_NOOP);
    setNativeMethod(global, "getComputedStyle", builtins.N_DOM_NOOP);

    // window.trustedTypes (Chrome Trusted Types API). BotGuard checks for its
    // presence; provide an object with createPolicy returning a passthrough.
    const tt = objects.createObject();
    setNativeMethod(tt, "createPolicy", builtins.N_TT_CREATE_POLICY);
    setNativeMethod(tt, "isHTML", builtins.N_DOM_NOOP);
    setNativeMethod(tt, "isScript", builtins.N_DOM_NOOP);
    objects.setProperty(global, values.internString("trustedTypes"), Value.object(tt));
}

fn installDocument(global: u32) void {
    const doc = objects.createObject();
    setPropStr(doc, "visibilityState", "visible");
    setPropBool(doc, "hidden", false);
    setPropStr(doc, "readyState", "complete");
    setPropStr(doc, "characterSet", "UTF-8");
    setPropStr(doc, "charset", "UTF-8");
    setPropStr(doc, "contentType", "text/html");
    setPropStr(doc, "compatMode", "CSS1Compat");
    setPropStr(doc, "designMode", "off");
    setPropStr(doc, "dir", "");
    setPropStr(doc, "domain", "www.youtube.com");
    setPropStr(doc, "referrer", "");
    setPropStr(doc, "title", "YouTube");
    setPropStr(doc, "URL", "https://www.youtube.com/");
    objects.setProperty(doc, values.internString("defaultView"), Value.object(global));
    setPropStr(doc, "cookie", "");

    // document.documentElement — a real element node (BotGuard walks
    // appendChild/removeChild/style when attaching probe elements).
    const html = objects.createObject();
    setPropStr(html, "lang", "en");
    makeNodeApi(html);
    objects.setProperty(doc, values.internString("documentElement"), Value.object(html));

    // document.body — real element node with the child/listener API.
    const body = objects.createObject();
    makeNodeApi(body);
    objects.setProperty(doc, values.internString("body"), Value.object(body));

    // document.head — real element node.
    const head = objects.createObject();
    makeNodeApi(head);
    objects.setProperty(doc, values.internString("head"), Value.object(head));

    // document-level DOM APIs BotGuard may call.
    setNativeMethod(doc, "createElementNS", builtins.N_DOM_CREATE_ELEMENT);
    setNativeMethod(doc, "createTextNode", builtins.N_DOM_CREATE_ELEMENT);
    setNativeMethod(doc, "createComment", builtins.N_DOM_CREATE_ELEMENT);
    setNativeMethod(doc, "createDocumentFragment", builtins.N_DOM_CREATE_ELEMENT);
    // document.createEvent(type) -> a generic event-like object. BotGuard's live
    // interpreter probes `document.createEvent('...')` then reads/inits it; a
    // missing method made the result undefined → "Cannot read properties of
    // undefined" cascades that inflate the snapshot payload. Returning the generic
    // element object (which carries the common method surface) keeps those probes
    // on the happy path, same rationale as createElement/createTextNode.
    setNativeMethod(doc, "createEvent", builtins.N_DOM_CREATE_ELEMENT);
    objects.setProperty(global, values.internString("Image"), Value.function(objects.createFunction(builtins.N_DOM_IMAGE)));
    const element_proto = objects.createObject();
    makeNodeApi(element_proto);
    browser_metadata.installMissing(element_proto, &browser_metadata.element_fields, builtins.N_DOM_NOOP);
    builtins.dom_element_proto = element_proto;
    objects.setObjectPrototype(html, element_proto);
    objects.setObjectPrototype(body, element_proto);
    objects.setObjectPrototype(head, element_proto);
    const element_ctor = objects.createFunction(builtins.N_DOM_CREATE_ELEMENT);
    objects.setProperty(element_ctor, values.internString("prototype"), Value.object(element_proto));
    objects.setProperty(element_proto, values.internString("constructor"), Value.function(element_ctor));
    objects.setProperty(global, values.internString("Element"), Value.function(element_ctor));
    for ([_][]const u8{ "HTMLElement", "HTMLTableCaptionElement", "SVGElement", "SVGSVGElement" }) |name| {
        const ctor = objects.createFunction(builtins.N_DOM_CREATE_ELEMENT);
        objects.setProperty(ctor, values.internString("prototype"), Value.object(element_proto));
        objects.setProperty(global, values.internString(name), Value.function(ctor));
    }
    const navigator = objects.getProperty(global, values.internString("navigator"));
    if (navigator.tag == .object) {
        const ctor = objects.createFunction(builtins.N_DOM_NOOP);
        objects.setProperty(ctor, values.internString("prototype"), navigator);
        objects.setProperty(global, values.internString("Navigator"), Value.function(ctor));
    }
    const media_proto = objects.createObject();
    setNativeMethod(media_proto, "canPlayType", builtins.N_DOM_EMPTY_STRING);
    const media_ctor = objects.createFunction(builtins.N_DOM_CREATE_ELEMENT);
    objects.setProperty(media_ctor, values.internString("prototype"), Value.object(media_proto));
    objects.setProperty(global, values.internString("HTMLMediaElement"), Value.function(media_ctor));
    const anchor_proto = objects.createObject();
    objects.setGetterProperty(anchor_proto, values.internString("href"), Value.function(objects.createFunction(builtins.N_DOM_EMPTY_STRING)));
    const anchor_ctor = objects.createFunction(builtins.N_DOM_CREATE_ELEMENT);
    objects.setProperty(anchor_ctor, values.internString("prototype"), Value.object(anchor_proto));
    objects.setProperty(global, values.internString("HTMLAnchorElement"), Value.function(anchor_ctor));

    // createElement returns a generic element object (with style/getContext/etc)
    // so BotGuard's canvas/DOM feature paths run instead of hitting undefined.
    objects.setProperty(doc, values.internString("createElement"), Value.function(objects.createFunction(builtins.N_DOM_CREATE_ELEMENT)));
    // Element-returning lookups: return null (JS) rather than 0.
    const null_func = objects.createFunction(builtins.N_DOM_NOOP);
    objects.setProperty(doc, values.internString("getElementById"), Value.function(null_func));
    objects.setProperty(doc, values.internString("querySelector"), Value.function(null_func));
    // Collection-returning lookups must return an ARRAY ([]), not undefined —
    // BotGuard does `document.getElementsByTagName(...).length`, and undefined
    // there throws TypeError, poisoning the snapshot into an error response.
    const empty_arr_func = objects.createFunction(builtins.N_DOM_EMPTY_ARRAY);
    objects.setProperty(doc, values.internString("querySelectorAll"), Value.function(empty_arr_func));
    objects.setProperty(doc, values.internString("getElementsByTagName"), Value.function(empty_arr_func));
    objects.setProperty(doc, values.internString("getElementsByClassName"), Value.function(empty_arr_func));
    objects.setProperty(doc, values.internString("getElementsByName"), Value.function(empty_arr_func));
    objects.setProperty(doc, values.internString("addEventListener"), Value.function(null_func));
    objects.setProperty(doc, values.internString("removeEventListener"), Value.function(null_func));

    objects.dbgMarkEnvObject(doc);
    objects.dbgMarkEnvObject(html);
    objects.dbgMarkEnvObject(body);
    objects.dbgMarkEnvObject(head);
    objects.setProperty(global, values.internString("document"), Value.object(doc));
}

fn installScreen(global: u32) void {
    const screen = objects.createObject();
    objects.dbgMarkEnvObject(screen);
    setPropNum(screen, "width", 1920);
    setPropNum(screen, "height", 1080);
    setPropNum(screen, "availWidth", 1920);
    setPropNum(screen, "availHeight", 1040);
    setPropNum(screen, "colorDepth", 24);
    setPropNum(screen, "pixelDepth", 24);
    objects.setProperty(global, values.internString("screen"), Value.object(screen));
}

fn installLocation(global: u32) void {
    const loc = objects.createObject();
    objects.dbgMarkEnvObject(loc);
    setPropStr(loc, "href", "https://www.youtube.com/");
    setPropStr(loc, "origin", "https://www.youtube.com");
    setPropStr(loc, "protocol", "https:");
    setPropStr(loc, "host", "www.youtube.com");
    setPropStr(loc, "hostname", "www.youtube.com");
    setPropStr(loc, "port", "");
    setPropStr(loc, "pathname", "/");
    setPropStr(loc, "search", "");
    setPropStr(loc, "hash", "");
    objects.setProperty(global, values.internString("location"), Value.object(loc));
    const document = objects.getProperty(global, values.internString("document"));
    if (document.tag == .object) objects.setProperty(document.data.obj_idx, values.internString("location"), Value.object(loc));
}

fn installPerformance(global: u32) void {
    const perf = objects.createObject();
    objects.dbgMarkEnvObject(perf);
    // performance.now() — SMALL monotonic ms (relative to load), NOT Date epoch.
    // BotGuard's clock is `wM + performance.now()`; using Date.now here blew up
    // the timing budget and broke live challenges. See builtins.perfNow.
    const now_func = objects.createFunction(builtins.N_PERF_NOW);
    objects.setProperty(perf, values.internString("now"), Value.function(now_func));

    // performance.timeOrigin — ms since epoch at navigation start. BotGuard
    // reads this as the base for its monotonic clock (timeOrigin + now()).
    setPropNum(perf, "timeOrigin", 1703980800000);

    // Additional Performance API surface BotGuard may probe.
    setNativeMethod(perf, "mark", builtins.N_DOM_NOOP);
    setNativeMethod(perf, "measure", builtins.N_DOM_NOOP);
    setNativeMethod(perf, "getEntriesByType", builtins.N_DOM_EMPTY_ARRAY);
    setNativeMethod(perf, "getEntriesByName", builtins.N_DOM_EMPTY_ARRAY);
    setNativeMethod(perf, "clearMarks", builtins.N_DOM_NOOP);
    setNativeMethod(perf, "clearMeasures", builtins.N_DOM_NOOP);

    // performance.timing (deprecated but BG might check)
    const timing = objects.createObject();
    setPropNum(timing, "navigationStart", 1703980800000);
    setPropNum(timing, "loadEventEnd", 1703980801500);
    objects.setProperty(perf, values.internString("timing"), Value.object(timing));

    objects.setProperty(global, values.internString("performance"), Value.object(perf));
}

fn installCrypto(global: u32) void {
    const crypto_obj = objects.createObject();
    objects.dbgMarkEnvObject(crypto_obj);
    const random_func = objects.createFunction(builtins.N_CRYPTO_RANDOM);
    objects.setProperty(crypto_obj, values.internString("getRandomValues"), Value.function(random_func));

    // crypto.subtle (stub — BG uses it for hashing)
    const subtle = objects.createObject();
    const stub_func = objects.createFunction(builtins.N_PROMISE_RESOLVE);
    objects.setProperty(subtle, values.internString("digest"), Value.function(stub_func));
    objects.setProperty(subtle, values.internString("importKey"), Value.function(stub_func));
    objects.setProperty(subtle, values.internString("sign"), Value.function(stub_func));
    objects.setProperty(crypto_obj, values.internString("subtle"), Value.object(subtle));

    objects.setProperty(global, values.internString("crypto"), Value.object(crypto_obj));
}

fn installIntl(global: u32) void {
    const intl = objects.createObject();
    // Intl.DateTimeFormat().resolvedOptions().timeZone
    const dtf_func = objects.createFunction(builtins.N_SET_TIMEOUT); // constructor stub
    objects.setProperty(intl, values.internString("DateTimeFormat"), Value.function(dtf_func));
    objects.setProperty(global, values.internString("Intl"), Value.object(intl));
}

fn installMisc(global: u32) void {
    // NOTE: Error/TypeError/ReferenceError are installed as PROPER constructors
    // in builtins.installGlobals (they build { name, message } objects with a
    // working toString). Do NOT overwrite them here. Provide only the extra
    // error subclasses BotGuard may reference, aliased to the real Error ctor.
    const real_error = objects.getProperty(global, values.internString("Error"));
    if (real_error.tag == .function) {
        objects.setProperty(global, values.internString("SyntaxError"), real_error);
        objects.setProperty(global, values.internString("RangeError"), real_error);
    }

    // Map, Set, WeakMap, WeakSet (stubs)
    objects.setProperty(global, values.internString("Map"), Value.function(objects.createFunction(builtins.N_SET_TIMEOUT)));
    objects.setProperty(global, values.internString("Set"), Value.function(objects.createFunction(builtins.N_SET_TIMEOUT)));
    objects.setProperty(global, values.internString("WeakMap"), Value.function(objects.createFunction(builtins.N_SET_TIMEOUT)));
    objects.setProperty(global, values.internString("WeakSet"), Value.function(objects.createFunction(builtins.N_SET_TIMEOUT)));

    // RegExp is installed by builtins with its own matcher and prototype.

    // localStorage / sessionStorage (stub)
    const storage = objects.createObject();
    const stub_func = objects.createFunction(builtins.N_SET_TIMEOUT);
    objects.setProperty(storage, values.internString("getItem"), Value.function(stub_func));
    objects.setProperty(storage, values.internString("setItem"), Value.function(stub_func));
    objects.setProperty(storage, values.internString("removeItem"), Value.function(stub_func));
    objects.setProperty(global, values.internString("localStorage"), Value.object(storage));
    objects.setProperty(global, values.internString("sessionStorage"), Value.object(storage));

    // history
    const hist = objects.createObject();
    setPropNum(hist, "length", 1);
    objects.setProperty(global, values.internString("history"), Value.object(hist));
}

// ── Property helpers ──

fn setPropStr(obj: u32, name: []const u8, val: []const u8) void {
    objects.setProperty(obj, values.internString(name), Value.string(values.internString(val)));
}

fn setPropNum(obj: u32, name: []const u8, val: f64) void {
    objects.setProperty(obj, values.internString(name), Value.number(val));
}

fn setPropBool(obj: u32, name: []const u8, val: bool) void {
    objects.setProperty(obj, values.internString(name), if (val) Value.TRUE else Value.FALSE);
}

/// Install a native (no-op) method by native-builtin id on an object.
fn setNativeMethod(obj: u32, name: []const u8, native_id: u16) void {
    builtins.installNativeMethod(obj, name, native_id);
}

/// Give a plain DOM-node object the child/listener/style API BotGuard walks
/// when it attaches probe elements (document.body.appendChild(canvas), etc.).
/// Mirrors builtins.makeDomElement so body/documentElement are real elements.
fn makeNodeApi(el: u32) void {
    const style = builtins.makeDomStyle();
    objects.setProperty(el, values.internString("style"), Value.object(style));
    setNativeMethod(el, "appendChild", builtins.N_DOM_NOOP);
    setNativeMethod(el, "removeChild", builtins.N_DOM_NOOP);
    setNativeMethod(el, "replaceChild", builtins.N_DOM_REPLACE_CHILD);
    setNativeMethod(el, "lookupNamespaceURI", builtins.N_DOM_LOOKUP_NAMESPACE);
    objects.setProperty(el, values.internString("namespaceURI"), Value.string(values.internString("http://www.w3.org/1999/xhtml")));
    setNativeMethod(el, "insertBefore", builtins.N_DOM_NOOP);
    setNativeMethod(el, "setAttribute", builtins.N_DOM_NOOP);
    setNativeMethod(el, "getAttribute", builtins.N_DOM_NOOP);
    setNativeMethod(el, "removeAttribute", builtins.N_DOM_NOOP);
    setNativeMethod(el, "hasAttribute", builtins.N_DOM_FALSE);
    setNativeMethod(el, "matches", builtins.N_DOM_FALSE);
    setNativeMethod(el, "click", builtins.N_DOM_NOOP);
    setNativeMethod(el, "getBoundingClientRect", builtins.N_DOM_RECT);
    setNativeMethod(el, "addEventListener", builtins.N_DOM_NOOP);
    setNativeMethod(el, "removeEventListener", builtins.N_DOM_NOOP);
    setNativeMethod(el, "contains", builtins.N_DOM_NOOP);
    setNativeMethod(el, "querySelector", builtins.N_DOM_NOOP);
    setNativeMethod(el, "getElementsByTagName", builtins.N_DOM_EMPTY_ARRAY);
}
