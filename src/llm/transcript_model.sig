// Storage-neutral local text generation for transcript annotation. Reuses the
// reference-checked native Qwen executor; no subprocess, driver or allocation.
const codec_mod = @import("qwen_text.sig");
const std = @import("std");
const executor = @import("qwen3_executor");
const binder = @import("qwen3_decoder_plan");
const prefixes = @import("prefix_cache.sig");
pub const PrefixEntry = prefixes.Entry;
pub const Limits = executor.Limits;
pub const Error = codec_mod.Error || executor.Error || binder.Error || prefixes.Error || error{ GenerationCapacity, InvalidCandidate };
pub const GenerateOptions = struct { empty_think: bool = false, max_tokens: u16 = 256, progress: executor.Progress = .{} };
/// A next-token logit is an uncalibrated model score, not a probability.
pub const TokenScore = struct { token: u32, logit: f32 };

pub fn Runtime(comptime limits: Limits) type {
    return struct {
        const Self = @This();
        codec: codec_mod.Codec,
        plan: binder.Plan,
        work: executor.WorkingSet(limits),
        kv: []u16,
        input_tokens: usize = 0,
        output_tokens: usize = 0,
        generated: [256]u32 = undefined,
        partial_output_bytes: usize = 0,
        score_prompt: [limits.context]u32 = undefined,
        score_prompt_len: usize = 0,
        scored_prefill_tokens: usize = 0,
        score_matrix_callback: ?executor.MatrixFn = null,
        score_matrix_context: ?*anyopaque = null,
        prefix_cache: ?prefixes.Cache = null,
        restored_prefix_tokens: usize = 0,

        pub fn prefixKvElements(self: *const Self, capacity: usize) Error!usize {
            if (capacity == 0 or capacity > limits.context) return error.ContextCapacity;
            return executor.requiredKvElements(self.plan, capacity);
        }

        /// All score calls are synchronous. After detaching, the caller may
        /// reuse snapshot buffers; the ordinary live prompt cache is retained.
        pub fn detachPrefixCache(self: *Self) void { self.prefix_cache = null; }

        /// Optional bounded snapshots avoid re-evaluating shared prefixes when
        /// callers alternate between primary and specialist prompts. Attach
        /// only exclusive caller storage; init/reconfiguration invalidates it.
        pub fn attachPrefixCache(self: *Self, entries: []PrefixEntry) Error!void {
            self.prefix_cache = try prefixes.Cache.init(entries, .{
                .layers = self.plan.layer_count, .heads = self.plan.kv_head_count,
                .head_size = self.plan.head_size, .context = limits.context,
            }, self.kv, &self.score_prompt);
        }

        /// Call when numerical configuration changes inside the same borrowed
        /// accelerator context. Pointer identity cannot detect such mutation.
        /// This does not free storage or alter model bytes.
        pub fn invalidateScoreCache(self: *Self) void {
            self.score_prompt_len = 0;
            self.score_matrix_callback = null;
            self.score_matrix_context = null;
            if (self.prefix_cache) |*cache| cache.invalidate();
        }

        pub fn init(self: *Self, bytes: []const u8, kv: []u16) Error!void {
            try self.codec.init(bytes);
            try binder.build(1024, &self.codec.model, &self.plan);
            if (self.codec.model.summary.context_length < limits.context) return error.ContextCapacity;
            if (self.plan.hidden_size > limits.hidden or self.plan.query_size > limits.query or
                self.plan.key_value_size > limits.key_value or self.plan.feed_forward_size > limits.feed_forward or
                self.plan.vocabulary_size > limits.vocabulary) return error.InvalidPlan;
            const needed = try executor.requiredKvElements(self.plan, limits.context);
            if (needed > kv.len) return error.KvCapacity;
            self.kv = kv[0..needed];
            self.work = .{};
            self.prefix_cache = null;
            self.invalidateScoreCache();
        }
        pub fn generate(self: *Self, system: []const u8, user: []const u8, out: []u8, options: GenerateOptions) Error!usize {
            self.invalidateScoreCache();
            self.partial_output_bytes = 0;
            self.output_tokens = 0;
            if (options.max_tokens == 0 or options.max_tokens > self.generated.len) return error.InvalidPlan;
            var prompt: [limits.context]u32 = undefined;
            const n = try self.codec.encodeChat(system, user, options.empty_think, &prompt);
            if (n == 0 or n + options.max_tokens > limits.context) return error.ContextCapacity;
            self.input_tokens = n;
            self.output_tokens = 0;
            errdefer self.partial_output_bytes = self.codec.decode(self.generated[0..self.output_tokens], out) catch 0;
            var selected: ?u32 = null;
            for (prompt[0..n], 0..) |token, pos| selected = try self.forward(token, pos, pos + 1 == n, options.progress);
            const end_turn = self.codec.vocabulary.lookup(self.codec.source(), "<|im_end|>") orelse return error.MissingSpecialToken;
            const end_text = self.codec.vocabulary.lookup(self.codec.source(), "<|endoftext|>") orelse return error.MissingSpecialToken;
            var pos = n;
            while (true) {
                const token = selected orelse return error.InvalidToken;
                if (token == end_turn or token == end_text) break;
                if (self.output_tokens == options.max_tokens) return error.GenerationCapacity;
                self.generated[self.output_tokens] = token;
                self.output_tokens += 1;
                selected = try self.forward(token, pos, true, options.progress);
                pos += 1;
            }
            return self.codec.decode(self.generated[0..self.output_tokens], out);
        }
        /// Score finite single-token answers from one shared prefill. The
        /// caller supplies labels, score storage and acceptance policy. No
        /// generated ranges, text repair or self-reported confidence is used.
        /// Consecutive calls reuse the exact common token prefix in caller KV;
        /// this is per-runtime, per-model state, never an unkeyed disk cache.
        pub fn scoreNext(self: *Self, system: []const u8, user: []const u8,
            choices: []const []const u8, scores: []TokenScore, options: GenerateOptions) Error!usize {
            self.scored_prefill_tokens = 0;
            self.restored_prefix_tokens = 0;
            self.input_tokens = 0; self.output_tokens = 0; self.partial_output_bytes = 0;
            if (choices.len == 0 or choices.len > scores.len) return error.InvalidCandidate;
            for (choices, 0..) |choice, i| {
                var ids: [2]u32 = undefined;
                const count = self.codec.encodeText(choice, &ids) catch return error.InvalidCandidate;
                if (count != 1) return error.InvalidCandidate;
                for (scores[0..i]) |previous| if (previous.token == ids[0]) return error.InvalidCandidate;
                scores[i] = .{ .token = ids[0], .logit = 0 };
            }
            var prompt: [limits.context]u32 = undefined;
            const n = try self.codec.encodeChat(system, user, options.empty_think, &prompt);
            if (n == 0 or n > limits.context) return error.ContextCapacity;
            self.input_tokens = n;
            // Cached logits must still honor per-request cancellation. A
            // backend change invalidates the numerical KV/logit cache even
            // when the chat token sequence is identical.
            try options.progress.report(.{ .stage = .request_begin, .layer = 0, .completed = 0, .total = @intCast(n) });
            const matrix_context = if (options.progress.matrix_callback != null)
                options.progress.matrix_context orelse options.progress.context else null;
            if (self.score_matrix_callback != options.progress.matrix_callback or self.score_matrix_context != matrix_context)
                self.invalidateScoreCache();
            self.input_tokens = n;
            self.output_tokens = 0;
            self.partial_output_bytes = 0;
            self.scored_prefill_tokens = 0;
            var common: usize = 0;
            while (common < @min(n, self.score_prompt_len) and prompt[common] == self.score_prompt[common]) : (common += 1) {}
            const identical = common == n and n == self.score_prompt_len;
            var prefix_key: [32]u8 = undefined;
            if (self.prefix_cache) |*cache| {
                std.crypto.hash.sha2.Sha256.hash(system, &prefix_key, .{});
                const restored = try cache.restore(&prefix_key, prompt[0..n], common);
                if (restored > common) self.restored_prefix_tokens = restored;
                common = restored;
            }
            // A shortened prompt needs its final logits recomputed even when
            // every remaining token belongs to the cached prefix.
            const begin = @min(common, n - 1);
            self.score_prompt_len = 0;
            errdefer self.score_prompt_len = 0;
            if (!identical) for (prompt[begin..n], begin..) |token, pos| {
                _ = try self.forward(token, pos, pos + 1 == n, options.progress);
                self.scored_prefill_tokens += 1;
            };
            for (scores[0..choices.len]) |*score| {
                if (score.token >= self.plan.vocabulary_size) return error.InvalidCandidate;
                score.logit = self.work.logits[score.token];
                if (!std.math.isFinite(score.logit)) return error.InvalidPlan;
            }
            @memcpy(self.score_prompt[0..n], prompt[0..n]);
            self.score_matrix_callback = options.progress.matrix_callback;
            self.score_matrix_context = matrix_context;
            self.score_prompt_len = n;
            if (self.prefix_cache) |*cache| try cache.store(&prefix_key, prompt[0..n]);
            return choices.len;
        }
        fn forward(self: *Self, token: u32, pos: usize, logits: bool, progress: executor.Progress) Error!?u32 {
            return executor.forward(1024, limits, self.codec.source(), &self.codec.model,
                &self.plan, &self.work, self.kv, limits.context, token, pos, logits, progress);
        }
    };
}
