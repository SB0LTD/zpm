// @zpm/youtube/botguard/jsvm — Minimal JavaScript Interpreter
//
// A subset ES2020 interpreter sufficient to execute Google's BotGuard VM.
// Architecture: Lexer → Parser → Compiler → Stack-based bytecode VM.
//
// This is NOT a general-purpose JS engine. It implements exactly what BotGuard needs:
//   - All value types (number, string, bool, null, undefined, object, array, function)
//   - Closures, prototype chains, getters/setters
//   - Typed arrays (Uint8Array, ArrayBuffer)
//   - Built-in functions (Math, JSON, Array.prototype, String.prototype)
//   - Browser environment stubs (navigator, window, document)
//   - Regex (basic)
//   - try/catch/finally
//   - Promises (basic)
//
// Memory: ~3MB total (fixed-size pools, no heap allocator)
// Performance: Execute 500KB minified JS in < 3 seconds

pub const lexer = @import("lexer.sig");
pub const parser = @import("parser.sig");
pub const compiler = @import("compiler.sig");
pub const vm = @import("vm.sig");
pub const values = @import("values.sig");
pub const objects = @import("objects.sig");
pub const builtins = @import("builtins.sig");
pub const env = @import("env.sig");
pub const regexp = @import("regexp.sig");

// ── Public API ──

/// Execute a BotGuard script with a program, return the BG response token.
/// `script`: the BotGuard VM JavaScript source (~500KB)
/// `program_data`: base64 bytecode program to pass to the VM
/// `global_name`: name of the VM global object after script execution
/// `bg_response`: output buffer for the BotGuard response token
/// `bg_response_len`: receives the response length
/// Returns true on success.
pub fn execute(
    script: []const u8,
    program_data: []const u8,
    global_name: []const u8,
    bg_response: *[65536]u8,
    bg_response_len: *usize,
) bool {
    bg_response_len.* = 0;

    // Phase 1: Initialize value system
    values.reset();

    // Phase 2: Tokenize
    const n_tokens = lexer.tokenize(script);
    if (n_tokens == 0) return false;

    // Phase 3: Parse
    const root = parser.parse(n_tokens);
    if (root == parser.NULL_NODE or parser.hasError()) return false;

    // Phase 4: Compile
    const bc_len = compiler.compile(root);
    if (bc_len == 0 or compiler.hasError()) return false;

    // Phase 5: Execute VM (this installs builtins + env internally)
    const result = vm.execute();
    if (vm.hasError()) return false;

    _ = result;

    // Phase 6: Invoke the BotGuard entry point to obtain the response token.
    //
    // Protocol (matches LuanRT/BgUtils BotGuardClient):
    //   syncSnapshotFn = trayride.a(program, vmSetupCallback, true, undefined,
    //                               vmTelemetry, [[],[]], undefined, false, loggerFns)[0]
    //   vmSetupCallback is invoked synchronously by the VM with
    //     (asyncSnapshotFunction, shutdownFunction, passEventFunction, checkCameraFunction)
    //   response = asyncSnapshotFunction(callback, [contentBinding, ...])
    const global = vm.getGlobal();
    const trayride = objects.getProperty(global, values.internString(global_name));
    if (trayride.tag != .object and trayride.tag != .function) { bg_fail_stage = 1; return false; }

    // trayride.a — the BotGuard initialization function.
    const bg_obj: u32 = trayride.data.obj_idx;
    const init_fn = objects.getProperty(bg_obj, values.internString("a"));
    if (init_fn.tag != .function) { bg_fail_stage = 2; return false; }

    builtins.bgResetCallbackState();

    // Build arguments for a(...).
    const program_val = values.Value.string(values.internString(program_data));
    const vm_setup_cb = vm.makeNativeFunction(builtins.N_BG_VM_SETUP);
    const telemetry_cb = vm.makeNativeFunction(builtins.N_BG_TELEMETRY);

    // [[], []] — two empty arrays inside an outer array (reserve capacity so
    // the VM can accumulate signals into them without corrupting the pool).
    const inner_a_i = objects.createArrayWithCapacity(16);
    const inner_b_i = objects.createArrayWithCapacity(16);
    const inner_a = values.Value.object(inner_a_i);
    const inner_b = values.Value.object(inner_b_i);
    const pair_idx = objects.createArray(2);
    objects.setArrayElement(pair_idx, 0, inner_a);
    objects.setArrayElement(pair_idx, 1, inner_b);
    const pair_val = values.Value.object(pair_idx);

    // loggerFunctions: array of 5 no-op native callbacks.
    const logger_arr = objects.createArray(5);
    var li: u32 = 0;
    while (li < 5) : (li += 1) {
        objects.setArrayElement(logger_arr, li, vm.makeNativeFunction(builtins.N_BG_LOGGER));
    }
    const logger_val = values.Value.object(logger_arr);

    const init_args = [_]values.Value{
        program_val,
        vm_setup_cb,
        values.Value.TRUE,
        values.Value.UNDEFINED, // userInteractionElement
        telemetry_cb,
        pair_val, // [[], []]
        values.Value.UNDEFINED,
        values.Value.FALSE,
        logger_val, // loggerFunctions
    };
    // a(...) returns [snapshotFunction, lifecycleFunction]. The snapshot
    // function is return[0]; it takes ONE array argument
    // E = [contentBinding, signedTimestamp, webPoSignalOutput, skipPrivacyBuffer]
    // (passed by reference — the VM writes getMinter into webPoSignalOutput[0])
    // and returns the botguardResponse string.
    vm.dbgCallrecReset();
    vm.dbgNativeIdsReset();
    vm.dbg_atob_lookups = 0;
    vm.dbg_callrec_on = true;
    vm.dbg_lastW_tag = 255;
    vm.dbg_lastW_reads = 0;
    vm.dbg_lastW_str_len = 0;
    vm.dbgResetFirstThrow();
    vm.dbg_referr_captured = false; // capture the FIRST ReferenceError during a()
    const a_ret = vm.callExportedN(init_fn, trayride, init_args[0..]);
    dbg_a_throwex = @intCast(vm.dbgThrowEx()[2]);
    vm.dbg_callrec_on = false;
    dbg_a_calls = vm.dbgCalls()[0];
    // Stash any ReferenceError seen DURING a() for diagnostics (snapshot reset
    // will clear the shared capture).
    if (vm.dbg_referr_captured) {
        const k = @min(vm.dbgReferrName().len, dbg_aphase_referr_name.len);
        @memcpy(dbg_aphase_referr_name[0..k], vm.dbgReferrName()[0..k]);
        dbg_aphase_referr_name_len = k;
        const rr = vm.dbgReferr();
        dbg_aphase_referr_func = rr[0];
        dbg_aphase_referr_ip = rr[1];
    }
    if (vm.hasError()) { bg_fail_stage = 3; return false; }
    vm.drainTasks();
    if (vm.hasError()) { bg_fail_stage = 3; return false; }

    // a_ret is [snapshotFn, lifecycleFn] when present. But the async snapshot
    // delivered via vmSetupCallback is the primary path, so a missing/invalid
    // a_ret[0] is only fatal if the async snapshot is ALSO unavailable.
    var snapshot_fn = values.Value.UNDEFINED;
    dbg_aret_tag = @intFromEnum(a_ret.tag);
    if (a_ret.tag == .object or a_ret.tag == .array) {
        dbg_aret_len = objects.arrayLength(a_ret.data.obj_idx);
        snapshot_fn = objects.getArrayElement(a_ret.data.obj_idx, 0);
        dbg_aret_elem0_tag = @intFromEnum(snapshot_fn.tag);
    }
    if (snapshot_fn.tag != .function and builtins.bg_async_snapshot_fn.tag != .function) {
        bg_fail_stage = 5;
        return false;
    }

    // webPoSignalOutput: the VM fills index 0 with getMinter. Reserve capacity
    // so the VM can grow it after other allocations without corrupting the pool.
    const webpo_arr = objects.createArrayWithCapacity(16);
    bg_webpo_signal = values.Value.object(webpo_arr);
    objects.dbg_webpo_target = webpo_arr; // track any writes to webPoSignalOutput

    // Build E = [contentBinding, signedTimestamp, webPoSignalOutput, skipPrivacyBuffer].
    // contentBinding must be a STRING (the snapshot reads its .length). Passing
    // undefined caused `undefined.length` TypeErrors -> error response. A short
    // placeholder is fine for obtaining the minter; the real content binding is
    // supplied later at mint time.
    // Match the reference exactly: BgUtils calls `snapshot({ webPoSignalOutput })`,
    // i.e. E = [undefined, undefined, webPoSignalOutput, undefined]. Only index 2
    // (webPoSignalOutput) is provided; contentBinding/signedTimestamp/
    // skipPrivacyBuffer are undefined. The minter is obtained from
    // webPoSignalOutput[0] regardless of contentBinding (the real content binding
    // is supplied later at mint time).
    const e_arr = objects.createArray(4);
    objects.setArrayElement(e_arr, 0, values.Value.UNDEFINED); // contentBinding
    objects.setArrayElement(e_arr, 1, values.Value.UNDEFINED); // signedTimestamp
    objects.setArrayElement(e_arr, 2, bg_webpo_signal); // webPoSignalOutput
    objects.setArrayElement(e_arr, 3, values.Value.UNDEFINED); // skipPrivacyBuffer

    var resp = values.Value.UNDEFINED;

    // Prefer the ASYNC snapshot function delivered via vmSetupCallback, called as
    //   asyncSnapshotFunction(responseCallback, E)
    // Only the async path populates webPoSignalOutput[0] with getMinter.
    const async_snap = builtins.bg_async_snapshot_fn;
    if (async_snap.tag == .function) {
        const result_cb = vm.makeNativeFunction(builtins.N_BG_SNAPSHOT_RESULT);
        const async_args = [_]values.Value{ result_cb, values.Value.object(e_arr) };
        vm.dbg_referr_captured = false; // isolate ReferenceErrors DURING the snapshot
        vm.dbgCallrecReset();
        vm.dbgNativeIdsReset();
        vm.dbg_callrec_on = true;
        const async_ret = vm.callExportedN(async_snap, values.Value.UNDEFINED, async_args[0..]);
        vm.dbg_callrec_on = false;
        if (vm.hasError()) { bg_fail_stage = 6; return false; }
        vm.drainTasks();
        if (vm.hasError()) { bg_fail_stage = 6; return false; }
        dbg_async_ret_tag = @intFromEnum(async_ret.tag);
        if (builtins.bg_snapshot_result_called and builtins.bg_snapshot_response.tag == .string) {
            resp = builtins.bg_snapshot_response;
            dbg_async_via = 1;
        } else if (async_ret.tag == .string) {
            resp = async_ret;
            dbg_async_via = 2;
        }
    }

    // The synchronous snapshot (a_ret[0]) runs qR->W.pm->hj and returns the
    // botguardResponse string directly (matches BgUtils snapshotSynchronous).
    if (resp.tag != .string and snapshot_fn.tag == .function) {
        const snap_args = [_]values.Value{values.Value.object(e_arr)};
        const calls_before = vm.dbgCalls()[0];
        vm.dbgCallrecReset();
        vm.dbg_callrec_on = true;
        const throwex_before = vm.dbgThrowEx()[2];
        const snap_ret = vm.callExportedN(snapshot_fn, values.Value.UNDEFINED, snap_args[0..]);
        vm.dbg_callrec_on = false;
        dbg_snap_throwex = @intCast(vm.dbgThrowEx()[2] -% throwex_before);
        dbg_snap_calls = vm.dbgCalls()[0] -% calls_before;
        dbg_snap_ret_tag = @intFromEnum(snap_ret.tag);
        if (vm.hasError()) { bg_fail_stage = 6; return false; }
        vm.drainTasks();
        if (vm.hasError()) { bg_fail_stage = 6; return false; }
        resp = snap_ret;
        if (resp.tag != .string and builtins.bg_snapshot_result_called and builtins.bg_snapshot_response.tag == .string) {
            resp = builtins.bg_snapshot_response;
        }
    }
    if (resp.tag != .string) { bg_fail_stage = 8; return false; }
    const resp_str = values.getString(resp.data.str_idx);
    if (resp_str.len == 0 or resp_str.len > bg_response.len) { bg_fail_stage = 9; return false; }
    @memcpy(bg_response[0..resp_str.len], resp_str);
    bg_response_len.* = resp_str.len;
    bg_fail_stage = 0;
    return true;
}

/// Debug: which Phase-6 stage the last execute() stopped at (0 = success).
// Diagnostic stage codes for the last execute()/mint (0 = success).
pub var bg_fail_stage: u32 = 0;
pub var bg_mint_fail_stage: u32 = 0;
// Diagnostics: user-call counts for a() and the snapshot, plus a_ret shape and
// the snapshot's return tag.
pub var dbg_a_calls: u32 = 0;
pub var dbg_snap_calls: u32 = 0;
pub var dbg_aret_len: u32 = 0;
pub var dbg_aret_tag: u8 = 255;
pub var dbg_aret_elem0_tag: u8 = 255;
pub var dbg_aphase_referr_name: [32]u8 = undefined;
pub var dbg_aphase_referr_name_len: usize = 0;
pub var dbg_aphase_referr_func: u32 = 0xFFFFFFFF;
pub var dbg_aphase_referr_ip: u32 = 0;
pub fn dbgAphaseReferrName() []const u8 { return dbg_aphase_referr_name[0..dbg_aphase_referr_name_len]; }
pub var dbg_snap_ret_tag: u8 = 255;
pub var dbg_snap_throwex: u32 = 0;
pub var dbg_a_throwex: u32 = 0;
pub var dbg_async_ret_tag: u8 = 255;
pub var dbg_async_via: u8 = 0;

// The webPoSignalOutput array populated by the VM during snapshot();
// webPoSignalOutput[0] is the getMinter function. Set by execute()'s Phase 6.
pub var bg_webpo_signal: values.Value = values.Value.UNDEFINED;


/// Mint a PO token from the VM's minter chain (WebPoMinter protocol):
///   getMinter = webPoSignalOutput[0]
///   mintCallback = getMinter(integrityTokenBytes)
///   result = mintCallback(contentBindingBytes)   // Uint8Array
/// `integrity_bytes`: the decoded (from base64) integrity token bytes.
/// `content_binding`: e.g. video id / visitor data (UTF-8 bytes).
/// `out`: receives the raw PO token bytes; returns the length (0 on failure).
/// Must be called after execute() succeeded (bg_webpo_signal populated).
pub fn mintPoToken(integrity_bytes: []const u8, content_binding: []const u8, out: []u8) usize {
    bg_mint_fail_stage = 0;
    if (bg_webpo_signal.tag != .object and bg_webpo_signal.tag != .array) { bg_mint_fail_stage = 1; return 0; }
    const webpo_idx: u32 = bg_webpo_signal.data.obj_idx;

    // getMinter = webPoSignalOutput[0].
    const get_minter = objects.getArrayElement(webpo_idx, 0);
    if (get_minter.tag != .function) { bg_mint_fail_stage = 2; return 0; }

    // Build a JS array of the integrity token bytes.
    const int_arr = objects.createArray(@intCast(integrity_bytes.len));
    for (integrity_bytes, 0..) |b, i| {
        objects.setArrayElement(int_arr, @intCast(i), values.Value.number(@floatFromInt(b)));
    }
    const int_args = [_]values.Value{values.Value.object(int_arr)};
    const mint_cb = vm.callExportedN(get_minter, values.Value.UNDEFINED, int_args[0..]);
    vm.drainTasks();
    if (vm.hasError()) { bg_mint_fail_stage = 3; return 0; }
    if (mint_cb.tag != .function) { bg_mint_fail_stage = 4; return 0; }

    // Build a JS array of the content-binding bytes.
    const cb_arr = objects.createArray(@intCast(content_binding.len));
    for (content_binding, 0..) |b, i| {
        objects.setArrayElement(cb_arr, @intCast(i), values.Value.number(@floatFromInt(b)));
    }
    const cb_args = [_]values.Value{values.Value.object(cb_arr)};
    const result = vm.callExportedN(mint_cb, values.Value.UNDEFINED, cb_args[0..]);
    vm.drainTasks();
    if (vm.hasError()) { bg_mint_fail_stage = 5; return 0; }
    if (result.tag != .object and result.tag != .array) { bg_mint_fail_stage = 6; return 0; }

    // Copy the resulting byte array into `out`.
    const res_idx: u32 = result.data.obj_idx;
    const n = objects.arrayLength(res_idx);
    if (n == 0 or n > out.len) { bg_mint_fail_stage = 7; return 0; }
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const el = objects.getArrayElement(res_idx, i);
        out[i] = if (el.tag == .number) @intFromFloat(@mod(el.data.number, 256)) else 0;
    }
    return n;
}




/// DEBUG SELF-TEST: run a small JS `src` as a top-level program and return the
/// numeric value of global `var_name` afterwards (NaN-boxed sentinel -999999 on
/// any failure). Used to unit-test VM semantics (e.g. sibling-closure shared
/// mutable capture) in isolation from the BotGuard flow.
pub fn dbgEvalGlobalNumber(src: []const u8, var_name: []const u8) f64 {
    values.reset();
    const n_tokens = lexer.tokenize(src);
    if (n_tokens == 0) return -999999;
    const root = parser.parse(n_tokens);
    if (root == parser.NULL_NODE or parser.hasError()) return -999998;
    const bc_len = compiler.compile(root);
    if (bc_len == 0 or compiler.hasError()) return -999997;
    _ = vm.execute();
    if (vm.hasError()) return -999996;
    const g = vm.getGlobal();
    const v = objects.getProperty(g, values.internString(var_name));
    if (v.tag == .number) return v.data.number;
    if (v.tag == .boolean) return if (v.data.boolean != 0) 1 else 0;
    if (v.tag == .string) return -888888; // string result sentinel
    if (v.tag == .undefined) return -777777;
    return -666666;
}