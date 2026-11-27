//! Native, allocation-free Whisper inference with caller-owned model/work/KV.
//! Model loading, audio decoding and output publication belong to the caller.
//! The first implementation uses deterministic greedy decoding; beam search
//! and temperature fallback are not silently implied by this API.
const std = @import("std");
pub const model = @import("model.sig");
pub const tokenizer = @import("tokenizer.sig");
pub const encoder = @import("encoder.sig");
pub const decoder = @import("decoder.sig");
pub const kernels = @import("kernels.sig");
pub const decoding = @import("decoding.sig");
pub const mel = @import("../asr/mel.sig");
pub const Error = decoder.Error || decoding.Error || mel.Error || error{ UnsupportedFrontend, TokenCapacity };

pub const Options = struct {
    language: []const u8 = "he",
    policy: decoding.Options = .{},
    max_tokens: usize = 440,
    no_speech_threshold: f32 = 0.6,
    log_probability_threshold: f32 = -1,
    previous_tokens: []const u32 = &.{},
    token_scores: ?[]f32 = null,
};
pub const Finish = enum { end_of_text, token_limit, context_limit, no_speech };
pub const Result = struct {
    tokens: []const u32,
    finish: Finish,
    no_speech_probability: f32,
    average_log_probability: f32,
    assembly: decoding.Assembly,
};
pub const Workspace = struct {
    encoder: encoder.Workspace,
    decoder: decoder.Workspace,
    mel_work: mel.Workspace = .{},
    frame_mel: []f32,
    channel_mel: []f32,

    pub fn requiredFloats(h: model.HParams) Error!usize {
        try validateFrontend(h);
        return try encoder.Workspace.requiredFloats(h) +
            try decoder.Workspace.requiredFloats(h) + @as(usize, h.n_audio_ctx) * 4 * h.n_mels;
    }
    pub fn init(storage: []f32, h: model.HParams) Error!Workspace {
        const required = try requiredFloats(h);
        if (storage.len < required) return error.Capacity;
        const ec = try encoder.Workspace.requiredFloats(h);
        const dc = try decoder.Workspace.requiredFloats(h);
        const mc = @as(usize, h.n_audio_ctx) * 2 * h.n_mels;
        return .{ .encoder = try encoder.Workspace.init(storage[0..ec], h),
            .decoder = try decoder.Workspace.init(storage[ec..][0..dc], h),
            .frame_mel = storage[ec + dc..][0..mc],
            .channel_mel = storage[ec + dc + mc..][0..mc] };
    }
};
pub const Session = struct {
    weights: *const model.Model,
    encoder: encoder.Encoder,
    decoder: decoder.Decoder,
    special: tokenizer.Special,
    space: ?u32,
    suppressed: [512]u32 = undefined,
    suppressed_count: usize = 0,
    /// Set before inference for progress/profiling. The callback receives a
    /// stage name and completed token count; no global or hidden I/O is used.
    progress: ?*const fn ([]const u8, usize) void = null,

    pub fn init(weights: *const model.Model) Error!Session {
        try validateFrontend(weights.hparams);
        var self: Session = .{
            .weights = weights, .encoder = try encoder.Encoder.init(weights),
            .decoder = try decoder.Decoder.init(weights),
            .special = try tokenizer.special(weights.hparams.n_vocab), .space = null,
        };
        for (weights.vocabulary, 0..) |v, id| {
            if (std.mem.eql(u8, v.bytes, " ")) self.space = @intCast(id);
            // Empty lexical tokens make no progress and can otherwise consume
            // an entire context without representing speech.
            if (v.bytes.len == 0) {
                if (self.suppressed_count == self.suppressed.len) return error.Capacity;
                self.suppressed[self.suppressed_count] = @intCast(id);
                self.suppressed_count += 1;
            }
        }
        return self;
    }

    /// audio is mono normalized float PCM at exactly 16 kHz, at most 30 s.
    /// Returned slices borrow tokens/text/segments and workspace. A nonterminal
    /// finish reason preserves partial evidence and must not be called success
    /// by a full-recording orchestrator. No model text is post-edited here.
    pub fn transcribeWindow(self: *Session, audio: []const f32, work: *Workspace,
        engine: *kernels.Engine, tokens: []u32, text: []u8,
        segments: []decoding.Segment, options: Options) Error!Result
    {
        if (options.max_tokens == 0 or tokens.len < options.max_tokens) return error.TokenCapacity;
        var prefix: [4]u32 = undefined;
        const prefix_len = try tokenizer.transcriptionPrompt(self.special.n_vocab, options.language, options.policy.timestamps, &prefix);
        if (options.token_scores) |scores| if (scores.len < options.max_tokens) return error.TokenCapacity;
        for (options.previous_tokens) |id| if (id >= self.special.eot) return error.InvalidToken;
        if (!std.math.isFinite(options.no_speech_threshold) or options.no_speech_threshold < 0 or
            options.no_speech_threshold > 1 or !std.math.isFinite(options.log_probability_threshold)) return error.Shape;
        if (self.progress) |notify| notify("mel", 0);
        try mel.computeZeroPadded(audio, self.weights.hparams.n_audio_ctx * 2, work.frame_mel, &work.mel_work);
        const frames = @as(usize, self.weights.hparams.n_audio_ctx) * 2;
        for (0..frames) |frame| for (0..128) |channel| {
            work.channel_mel[channel * frames + frame] = work.frame_mel[frame * 128 + channel];
        };
        if (self.progress) |notify| notify("encoder", 0);
        const encoded = try self.encoder.encode(work.channel_mel, &work.encoder, engine);
        if (self.progress) |notify| notify("cross_kv", 0);
        try self.decoder.prepare(encoded, &work.decoder, engine);
        if (self.progress) |notify| notify("prefill", 0);
        var initial: [228]u32 = undefined;
        var initial_len: usize = 0;
        if (options.previous_tokens.len > 0) {
            initial[0] = self.special.previous;
            const count = @min(options.previous_tokens.len, @min(224, self.weights.hparams.n_text_ctx / 2 - 1));
            @memcpy(initial[1..][0..count], options.previous_tokens[options.previous_tokens.len - count..]);
            initial_len = count + 1;
        }
        initial[initial_len] = prefix[0]; initial_len += 1;
        var logits = try self.decoder.prefill(initial[0..initial_len], &work.decoder, engine);
        const no_speech = try decoding.probability(logits, self.special.no_speech);
        for (prefix[1..prefix_len], 1..) |id, i|
            if (try self.decoder.step(id, i + 1 == prefix_len, &work.decoder, engine)) |values| { logits = values; };
        var count: usize = 0;
        var log_probability: f32 = 0;
        var finish: Finish = .token_limit;
        const duration: u32 = @intCast((audio.len * 1000 + 15999) / 16000);
        var policy = options.policy;
        policy.max_timestamp_ms = @min(policy.max_timestamp_ms, duration);
        if (self.progress) |notify| notify("decoder", 0);
        while (count < options.max_tokens) {
            const choice = try decoding.choose(@constCast(logits), self.special, tokens[0..count],
                policy, self.suppressed[0..self.suppressed_count], self.space);
            tokens[count] = choice.id;
            count += 1;
            log_probability += choice.log_probability;
            if (options.token_scores) |scores| scores[count - 1] = choice.log_probability;
            if (self.progress) |notify| notify("decoder", count);
            if (choice.id == self.special.eot) { finish = .end_of_text; break; }
            if (count == options.max_tokens) break;
            if (self.decoder.position == self.weights.hparams.n_text_ctx) { finish = .context_limit; break; }
            logits = (try self.decoder.step(choice.id, true, &work.decoder, engine)).?;
        }
        const average = log_probability / @as(f32, @floatFromInt(count));
        if (no_speech > options.no_speech_threshold and average < options.log_probability_threshold) finish = .no_speech;
        const assembled = try decoding.assemble(self.weights, tokens[0..count], duration, text, segments);
        return .{ .tokens = tokens[0..count], .finish = finish, .no_speech_probability = no_speech,
            .average_log_probability = average, .assembly = assembled };
    }
};

fn validateFrontend(h: model.HParams) Error!void {
    if (h.n_mels != 128 or h.n_audio_ctx != 1500 or h.n_text_ctx < 4) return error.UnsupportedFrontend;
}
