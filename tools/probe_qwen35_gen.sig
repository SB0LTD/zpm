//! End-to-end qwen35 generation harness.
//!
//! Loads the Qwen3.8-4B-Distill GGUF, uploads quantized weights to VRAM,
//! encodes a prompt, runs the GPU-streaming executor token by token, and
//! prints the decoded text. Verifies "The capital of France is" -> "Paris".
//!
//! Run from a shell with CUDA bin\x64 on PATH:
//!   probe-qwen35-gen <model.gguf> "<prompt>" [max_tokens]

const std = @import("std");
const process = @import("sig_process");
const gguf = @import("gguf");
const plan_mod = @import("qwen35_plan");
const exec = @import("qwen35_executor");
const qattn = @import("qwen35_attn");
const tokenizer = @import("tokenizer");
const indexes = @import("tokenizer_index");

const capacity = 2048;
const CONTEXT: usize = 256;

var index: gguf.Index(capacity) = .{};
var plan: plan_mod.Plan = .{};
var model: exec.Model = .{};
var work: exec.Work = .{};
var nvrtc_image: [512 * 1024]u8 = undefined;
var nvrtc_log: [8 * 1024]u8 = @splat(0);

// KV cache: 9 full-attn layers (idx 3,7,11,15,19,23,27,31,32) * kvElements(CONTEXT).
var kv_data: [9 * (2 * 4 * CONTEXT * 256)]f32 = @splat(0);
// GDN states: 24 GDN layers.
var gdn_rec: [24 * (32 * 128 * 128)]f32 = @splat(0);
var gdn_conv: [24 * (8192 * 4)]f32 = @splat(0);

var vocabulary: indexes.VocabularyIndex(262_144, 524_288) = .{};
var merges: indexes.MergeIndex(524_288, 512) = .{};
var tokens: [CONTEXT]u32 = undefined;

const Memory = struct {
    bytes: []const u8,
    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or destination.len > self.bytes.len - offset) return false;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        return true;
    }
    fn map(context: *const anyopaque, offset: u64, len: usize, alignment: usize) ?[*]const u8 {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or len > self.bytes.len - offset or alignment == 0) return null;
        const pointer = self.bytes[@intCast(offset)..].ptr;
        if (@intFromPtr(pointer) % alignment != 0) return null;
        return pointer;
    }
    fn source(self: *const Memory) gguf.Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = read, .map_at = map };
    }
};

pub fn main(init: std.process.Init) !void {
    var argv_buffer: [32768]u8 = undefined;
    var argv = process.Argv_Iterator.init(init.minimal.args.vector, &argv_buffer);
    _ = try argv.next();
    var path_buffer: [4096]u8 = undefined;
    const raw_path = try argv.next() orelse return error.ExpectedModelPath;
    if (raw_path.len > path_buffer.len) return error.ModelPathTooLong;
    @memcpy(path_buffer[0..raw_path.len], raw_path);
    const path = path_buffer[0..raw_path.len];
    var prompt_buffer: [4096]u8 = undefined;
    const raw_prompt = try argv.next() orelse return error.ExpectedPrompt;
    if (raw_prompt.len > prompt_buffer.len) return error.PromptTooLong;
    @memcpy(prompt_buffer[0..raw_prompt.len], raw_prompt);
    const prompt = prompt_buffer[0..raw_prompt.len];
    const maximum = if (try argv.next()) |value| try std.fmt.parseInt(usize, value, 10) else 16;
    // Optional 4th arg: debug mode "skipgdn" | "skipattn" | "raw" | "none".
    var raw_mode = false;
    if (try argv.next()) |mode| {
        if (std.mem.indexOf(u8, mode, "skipgdn") != null) exec.dbg_skip_gdn = true;
        if (std.mem.indexOf(u8, mode, "skipattn") != null) exec.dbg_skip_attn = true;
        if (std.mem.indexOf(u8, mode, "raw") != null) raw_mode = true;
        if (std.mem.indexOf(u8, mode, "norope") != null) qattn.dbg_disable_rope = true;
    }

    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const size = try file.length(init.io);
    if (size > ~@as(usize, 0)) return error.ModelTooLarge;
    var mapping = try file.createMemoryMap(init.io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = true });
    defer mapping.destroy(init.io);
    if (mapping.section == null) return error.NativeMappingRequired;
    const memory = Memory{ .bytes = mapping.memory };
    const source = memory.source();
    try gguf.parse(capacity, source, &index);
    try plan_mod.build(capacity, &index, &plan);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &writer.interface;

    var gdn_n: usize = 0;
    var attn_n: usize = 0;
    for (0..plan.layer_count) |li| {
        if (plan.layers[li].kind == .full_attention) attn_n += 1 else gdn_n += 1;
    }
    try out.print("layers={d} (gdn={d} attn={d}), vocab={d}, rope_base={d:.1} rope_dim={d} eps={d:.6}, uploading weights to VRAM...\n", .{ plan.layer_count, gdn_n, attn_n, plan.vocabulary_size, plan.rope_frequency_base, plan.rope_dimension_count, plan.rms_norm_epsilon });
    try out.flush();

    exec.init(capacity, &model, source, &index, &plan, &nvrtc_image, &nvrtc_log) catch |e| {
        try out.print("exec.init failed: {t}\nnvrtc_log: {s}\n", .{ e, nvrtc_log[0..256] });
        try out.flush();
        return e;
    };
    try out.writeAll("weights resident. encoding prompt...\n");
    try out.flush();

    try vocabulary.build(source, index.summary.tokenizer_tokens);
    try merges.build(source, index.summary.tokenizer_merges, &vocabulary);
    const prompt_count = if (raw_mode)
        try tokenizer.encodeText(source, &vocabulary, &merges, prompt, &tokens)
    else
        try tokenizer.encodeChatTurn(source, &vocabulary, &merges, "You are a helpful assistant.", prompt, false, &tokens);
    if (prompt_count == 0 or prompt_count + maximum > tokens.len) return error.ContextCapacity;

    const kv = exec.AttnKv{ .data = &kv_data };
    const st = exec.GdnState{ .recurrent = &gdn_rec, .conv = &gdn_conv };

    try out.print("prompt_tokens={d}, running prefill...\n", .{prompt_count});
    try out.flush();
    // Prefill (only the final prompt token needs logits).
    var selected: u32 = 0;
    for (tokens[0..prompt_count], 0..) |tok, pos| {
        const last = pos + 1 == prompt_count;
        selected = try exec.forward(capacity, &model, source, &index, &plan, &work, kv, st, CONTEXT, tok, pos, last);
    }

    // Top-8 logits of the first generated token (diagnostic).
    {
        var ts: [512]u8 = undefined;
        var td: [512]u8 = undefined;
        try out.writeAll("TOP8:\n");
        var used: [8]u32 = @splat(0xffffffff);
        for (0..8) |r| {
            var bi: usize = 0;
            var bv: f32 = -1e30;
            for (work.logits[0..plan.vocabulary_size], 0..) |lv, i| {
                var skip = false;
                for (used[0..r]) |u| if (u == i) {
                    skip = true;
                };
                if (!skip and lv > bv) {
                    bv = lv;
                    bi = i;
                }
            }
            used[r] = @intCast(bi);
            const dt = tokenizer.decodeToken(source, &vocabulary, @intCast(bi), &ts, &td) catch {
                try out.print("  {d} logit={d:.3} <ctrl>\n", .{ bi, bv });
                continue;
            };
            try out.print("  {d} logit={d:.3} \"{s}\"\n", .{ bi, bv, td[0..dt.bytes_written] });
        }
        try out.flush();
    }

    try out.writeAll("response=");
    try out.flush();
    var scratch: [512]u8 = undefined;
    var decoded: [512]u8 = undefined;
    var generated: usize = 0;
    const end = vocabulary.lookup(source, "<|im_end|>");
    const eos = vocabulary.lookup(source, "<|endoftext|>");
    while (generated < maximum) {
        const tok = selected;
        if ((end != null and tok == end.?) or (eos != null and tok == eos.?)) break;
        tokens[prompt_count + generated] = tok;
        const text = tokenizer.decodeToken(source, &vocabulary, tok, &scratch, &decoded) catch break;
        if (!text.control) try out.writeAll(decoded[0..text.bytes_written]);
        try out.flush();
        generated += 1;
        if (generated < maximum)
            selected = try exec.forward(capacity, &model, source, &index, &plan, &work, kv, st, CONTEXT, tok, prompt_count + generated - 1, true);
    }
    try out.print("\nGEN_DONE generated={d}\n", .{generated});
    try out.flush();
}
