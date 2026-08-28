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
    bg_response: *[1024]u8,
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

    // Phase 6: After script execution, call the BotGuard entry point.
    // BG exposes a global function via `global_name`. We need to:
    //   1. Get the global object
    //   2. Look up global_name on it
    //   3. Call it with the program_data
    //   4. Extract the response token from the callback

    // Look up the BG entry point on the global object
    const global = vm.getGlobal();
    const entry_name_idx = values.internString(global_name);
    const entry_val = objects.getProperty(global, entry_name_idx);

    if (entry_val.tag != .function and entry_val.tag != .object) {
        // BotGuard VM didn't expose the expected global — script ran but no entry point
        // This means our JS execution completed but BG's internal VM didn't set up correctly
        // Still a partial success for testing
        _ = result;
        _ = program_data;
        return false;
    }

    // For now: the full BG callback invocation requires deeper VM re-entry
    // which will be implemented once the basic execution is proven correct.
    // The response token comes from BG's internal callback mechanism.
    _ = bg_response;
    return false;
}

/// Call the minter function (after VM execution established it).
/// `integrity_token`: base64 integrity token
/// `content_binding`: video ID or visitor data
/// `out`: raw minted token bytes
/// Returns number of bytes written.
pub fn callMinter(
    integrity_token: []const u8,
    content_binding: []const u8,
    out: *[192]u8,
) usize {
    _ = integrity_token;
    _ = content_binding;
    _ = out;

    // TODO: Call the stored minter callback from the VM state
    return 0;
}
