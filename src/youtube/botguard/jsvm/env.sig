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
const Value = values.Value;

// ── Install all environment stubs ──

/// Call after builtins.installGlobals().
pub fn installEnvironment(global: u16) void {
    installNavigator(global);
    installWindow(global);
    installDocument(global);
    installScreen(global);
    installLocation(global);
    installPerformance(global);
    installCrypto(global);
    installIntl(global);
    installMisc(global);
}

fn installNavigator(global: u16) void {
    const nav = objects.createObject();
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

    objects.setProperty(global, values.internString("navigator"), Value.object(nav));
}

fn installWindow(global: u16) void {
    // window === global (self-reference)
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
}

fn installDocument(global: u16) void {
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
    setPropStr(doc, "cookie", "");

    // document.documentElement
    const html = objects.createObject();
    setPropStr(html, "lang", "en");
    objects.setProperty(doc, values.internString("documentElement"), Value.object(html));

    // document.body (stub)
    const body = objects.createObject();
    objects.setProperty(doc, values.internString("body"), Value.object(body));

    // document.head
    objects.setProperty(doc, values.internString("head"), Value.object(objects.createObject()));

    // Stub methods that return empty elements
    const stub_func = objects.createFunction(builtins.N_SET_TIMEOUT); // returns 0/undefined
    objects.setProperty(doc, values.internString("createElement"), Value.function(stub_func));
    objects.setProperty(doc, values.internString("getElementById"), Value.function(stub_func));
    objects.setProperty(doc, values.internString("querySelector"), Value.function(stub_func));
    objects.setProperty(doc, values.internString("querySelectorAll"), Value.function(stub_func));
    objects.setProperty(doc, values.internString("getElementsByTagName"), Value.function(stub_func));
    objects.setProperty(doc, values.internString("addEventListener"), Value.function(stub_func));

    objects.setProperty(global, values.internString("document"), Value.object(doc));
}

fn installScreen(global: u16) void {
    const screen = objects.createObject();
    setPropNum(screen, "width", 1920);
    setPropNum(screen, "height", 1080);
    setPropNum(screen, "availWidth", 1920);
    setPropNum(screen, "availHeight", 1040);
    setPropNum(screen, "colorDepth", 24);
    setPropNum(screen, "pixelDepth", 24);
    objects.setProperty(global, values.internString("screen"), Value.object(screen));
}

fn installLocation(global: u16) void {
    const loc = objects.createObject();
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
}

fn installPerformance(global: u16) void {
    const perf = objects.createObject();
    // performance.now() — stub returns incrementing value
    const now_func = objects.createFunction(builtins.N_DATE_NOW);
    objects.setProperty(perf, values.internString("now"), Value.function(now_func));

    // performance.timing (deprecated but BG might check)
    const timing = objects.createObject();
    setPropNum(timing, "navigationStart", 1703980800000);
    setPropNum(timing, "loadEventEnd", 1703980801500);
    objects.setProperty(perf, values.internString("timing"), Value.object(timing));

    objects.setProperty(global, values.internString("performance"), Value.object(perf));
}

fn installCrypto(global: u16) void {
    const crypto_obj = objects.createObject();
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

fn installIntl(global: u16) void {
    const intl = objects.createObject();
    // Intl.DateTimeFormat().resolvedOptions().timeZone
    const dtf_func = objects.createFunction(builtins.N_SET_TIMEOUT); // constructor stub
    objects.setProperty(intl, values.internString("DateTimeFormat"), Value.function(dtf_func));
    objects.setProperty(global, values.internString("Intl"), Value.object(intl));
}

fn installMisc(global: u16) void {
    // Error constructors
    const error_func = objects.createFunction(builtins.N_SET_TIMEOUT);
    objects.setProperty(global, values.internString("Error"), Value.function(error_func));
    objects.setProperty(global, values.internString("TypeError"), Value.function(error_func));
    objects.setProperty(global, values.internString("ReferenceError"), Value.function(error_func));
    objects.setProperty(global, values.internString("SyntaxError"), Value.function(error_func));
    objects.setProperty(global, values.internString("RangeError"), Value.function(error_func));

    // Map, Set, WeakMap, WeakSet (stubs)
    objects.setProperty(global, values.internString("Map"), Value.function(objects.createFunction(builtins.N_SET_TIMEOUT)));
    objects.setProperty(global, values.internString("Set"), Value.function(objects.createFunction(builtins.N_SET_TIMEOUT)));
    objects.setProperty(global, values.internString("WeakMap"), Value.function(objects.createFunction(builtins.N_SET_TIMEOUT)));
    objects.setProperty(global, values.internString("WeakSet"), Value.function(objects.createFunction(builtins.N_SET_TIMEOUT)));

    // RegExp constructor
    objects.setProperty(global, values.internString("RegExp"), Value.function(objects.createFunction(builtins.N_SET_TIMEOUT)));

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

fn setPropStr(obj: u16, name: []const u8, val: []const u8) void {
    objects.setProperty(obj, values.internString(name), Value.string(values.internString(val)));
}

fn setPropNum(obj: u16, name: []const u8, val: f64) void {
    objects.setProperty(obj, values.internString(name), Value.number(val));
}

fn setPropBool(obj: u16, name: []const u8, val: bool) void {
    objects.setProperty(obj, values.internString(name), if (val) Value.TRUE else Value.FALSE);
}
