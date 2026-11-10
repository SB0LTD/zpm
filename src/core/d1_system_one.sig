//! @zpm/d1 — Liquid AI's d1 decision models ("System One") on the LFM3 text
//! backbone, in pure Sig and allocation-free: LiquidAI/d1-2B (LFM Open
//! License v1.0) from its GGUF (`lfm3`, `lfm3.decision.type = lfm3-d1`).
//!
//! A decision is one forward pass that stops at answer slots: nothing is
//! decoded. The prompt is d1's own (the GGUF's `systemone` template and
//! LiquidAI's `prompt.py`):
//!
//!   <|startoftext|><|im_start|>user\n{state}\n\n\nQUESTION:\n{question}
//!   <|im_end|>\n<|im_start|>assistant\n<think></think>
//!
//! and each question's answer is read at its last token (`</think>`) as a
//! softmax over its options' tokens only: `yes`/`no` (noul), option codes
//! A..Z then AA, AB.. (choice: d1's code scheme 2), digits (score). Every
//! option scores its best form (`A` or ` A`); the scores go through the
//! checkpoint's temperature (`lfm3.decision.temperature.*`, 1.337 for d1-2B)
//! before the softmax. The log-softmax over the whole vocabulary that the
//! reference takes first cancels in that softmax, so only the options' rows
//! of the output matrix are multiplied.
//!
//! Several questions share one pass (d1's `set` attention, trained up to 16
//! after one state): `[state][q1]..[qN]`, each later question opened by
//! `QUESTION:\n`. On the full-attention layers the state reads every token
//! and every token reads the state, a question reads itself and never
//! another (executor.Sees); sliding-window and convolution layers stay
//! causal over the packed sequence. `set_size` 1 gives each question its own
//! pass, exactly as llama.cpp's `/v1/systemone` reads it.
//!
//! The request and answer JSON are `/v1/systemone`'s (llama.cpp, the Liquid
//! API): `{"state": text|object|null, "questions": {name: {"type":
//! "noul"|"choice"|"score", "instructions": text, "criteria": ...}}}`. An
//! object state is written as Python's `json.dumps(state, indent=2,
//! ensure_ascii=False)` writes it, as the model was trained.
//!
//! Typed answers (text, number, date, box, multiple choice) and media are
//! not read here: the agent's questions are the three option types.

const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const quantized = @import("quantized_linear");
const json = @import("json_pull");

/// The most questions one pass packs after its state (d1-2B trained 16).
pub const MAX_SET: usize = 16;
/// The most questions one request asks.
pub const MAX_QUESTIONS: usize = 64;
/// The most options one question offers (255 targets and "none").
pub const MAX_OPTIONS: usize = 256;
/// Forms an option is read in (`yes`, `Yes`, `YES`; `A`, ` A`).
pub const MAX_FORMS: usize = 3;
/// The prompt text of one pass, before tokenizing.
pub const MAX_TEXT: usize = 96 * 1024;
/// d1-2B's calibration (calibration.json `default`), when a file has none.
pub const DEFAULT_TEMPERATURE: f32 = 1.3373984;

pub const Error = executor.Error || error{
    NoQuestions,
    TooManyQuestions,
    TooManyOptions,
    NoOptions,
    TextCapacity,
    TokenCapacity,
    NoSingleTokenCode,
    TokenizerFailed,
    InvalidRequest,
    UnsupportedQuestion,
    /// A Runner did not finish the pass (its GPU refused it, hung or
    /// faulted): nothing was answered; the CPU's engine still can.
    EngineFailed,
};

/// Where a pass runs when not on the CPU's executor: a GPU (lfm3_any's
/// forwardSees and residualRows behind two functions, so this file knows
/// of no GPU). The readout (output norm, the options' logits, the
/// temperature) stays here, on the CPU, either way.
pub const Runner = struct {
    context: *anyopaque,
    /// One pass of `tokens` from position 0 under `sees`.
    run: *const fn (context: *anyopaque, tokens: []const u32, sees: *const executor.Sees) error{EngineFailed}!void,
    /// The final residual rows of `positions`, one after another in `out`.
    rows: *const fn (context: *anyopaque, positions: []const u32, out: []f32) error{EngineFailed}!void,
};

/// A Runner over a GPU backend and its cache: `B` is lfm3_any's Backend
/// (forwardSees, residualRows), `C` its Cache (the executor's as `cpu`).
pub fn GpuRunner(comptime B: type, comptime C: type) type {
    return struct {
        backend: *B,
        cache: *C,
        /// The backend's error when a pass failed, for the caller's log.
        failed: ?anyerror = null,

        pub fn runner(self: *@This()) Runner {
            return .{ .context = self, .run = &run, .rows = &rows };
        }

        fn run(context: *anyopaque, tokens: []const u32, sees: *const executor.Sees) error{EngineFailed}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            // (every pass starts the context over: nothing of the last one
            // is kept, on either side)
            self.cache.cpu.reset();
            self.cache.kv_on_cpu = false;
            self.backend.forwardSees(self.cache, tokens, sees) catch |e| {
                self.failed = e;
                return error.EngineFailed;
            };
        }

        fn rows(context: *anyopaque, positions: []const u32, out: []f32) error{EngineFailed}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.backend.residualRows(self.cache, positions, out) catch |e| {
                self.failed = e;
                return error.EngineFailed;
            };
        }
    };
}

pub const Kind = enum {
    noul,
    choice,
    score,

    pub fn word(self: Kind) []const u8 {
        return switch (self) {
            .noul => "noul",
            .choice => "choice",
            .score => "score",
        };
    }
};

/// A choice's option (`criteria` key and description), a score's level
/// (`key` its text), a noul's `true`/`false` criterion.
pub const Option = struct { key: []const u8, description: ?[]const u8 = null };

pub const Question = struct {
    name: []const u8 = "",
    kind: Kind,
    instructions: []const u8,
    options: []const Option = &.{},
};

pub const Answer = struct {
    /// noul: P(yes), P(no). choice: one per option. score: one per level.
    probabilities: [MAX_OPTIONS]f32 = undefined,
    count: u16 = 0,
    best: u16 = 0,

    pub fn confidence(self: *const Answer) f32 {
        return if (self.count == 0) 0 else self.probabilities[self.best];
    }

    pub fn yes(self: *const Answer) f32 {
        return if (self.count == 0) 0 else self.probabilities[0];
    }

    /// A score's median level: the first whose cumulative share reaches half.
    pub fn median(self: *const Answer) u16 {
        var total: f32 = 0;
        for (self.probabilities[0..self.count], 0..) |p, i| {
            total += p;
            if (total >= 0.5) return @intCast(i);
        }
        return if (self.count == 0) 0 else self.count - 1;
    }

    /// The best option other than those `masked` says no to (cycle masking:
    /// an agent's next-best choice). Null when every option is masked.
    pub fn bestUnmasked(self: *const Answer, masked: []const bool) ?u16 {
        var best: ?u16 = null;
        for (self.probabilities[0..self.count], 0..) |p, i| {
            if (i < masked.len and masked[i]) continue;
            if (best == null or p > self.probabilities[best.?]) best = @intCast(i);
        }
        return best;
    }
};

pub const Usage = struct { input_tokens: usize = 0, passes: usize = 0 };

/// What the engine reads tokens through: `encode(text, out) !usize` with the
/// special tokens of the markup recognised, and `special(text) usize`, the
/// length of a special token's string at the start of `text` (0 for none),
/// so the caller's text never turns into markup (d1's `plain`).
pub fn checkTokenizer(comptime T: type) void {
    if (!@hasDecl(T, "encode") or !@hasDecl(T, "special")) @compileError("a d1 tokenizer has encode and special");
}

/// The model one engine runs: the GGUF, its plan and packed weights.
pub fn Model(comptime tensor_capacity: usize) type {
    return struct {
        source: gguf.Source,
        index: *const gguf.Index(tensor_capacity),
        plan: *const lfm3.Plan,
        weights: *const executor.PackedWeights(tensor_capacity),
        /// noul, choice, score temperatures.
        temperature: [3]f32 = .{ DEFAULT_TEMPERATURE, DEFAULT_TEMPERATURE, DEFAULT_TEMPERATURE },

        /// The checkpoint's own temperatures (`lfm3.decision.temperature.*`).
        pub fn readTemperatures(self: *@This()) void {
            const keys = [3][]const u8{ "lfm3.decision.temperature.noul", "lfm3.decision.temperature.choice", "lfm3.decision.temperature.score" };
            for (keys, 0..) |key, i| {
                const value = gguf.metadataNumber(self.source, key) catch null;
                if (value) |v| {
                    if (v > 0.01 and v < 100) self.temperature[i] = @floatCast(v);
                }
            }
        }
    };
}

/// Caller-owned storage of one engine: the prompt, its tokens and groups,
/// and the readout rows. `limits.batch` bounds one pass's tokens.
pub fn Scratch(comptime limits: executor.Limits) type {
    return struct {
        text: [MAX_TEXT]u8 = undefined,
        ids: [limits.batch]u32 = undefined,
        group: [limits.batch]u8 = undefined,
        piece: [limits.batch]u32 = undefined,
        normed: [limits.hidden]f32 = undefined,
        row: [limits.hidden]f32 = undefined,
        /// A Runner's residual rows, a question each.
        rows: [MAX_SET * limits.hidden]f32 = undefined,
        forms: [MAX_OPTIONS][MAX_FORMS]u32 = undefined,
        form_count: [MAX_OPTIONS]u8 = undefined,
        used: [MAX_OPTIONS]u32 = undefined,
    };
}

// ── The prompt ──────────────────────────────────────────────────────────────

pub const BOS = "<|startoftext|>";
pub const USER = "<|im_start|>user\n";
pub const HEADER = "QUESTION:\n";
pub const ANSWER = "<|im_end|>\n<|im_start|>assistant\n<think></think>";
const ZWSP = "\u{200b}";

const Text = struct {
    buf: []u8,
    len: usize = 0,
    over: bool = false,

    fn put(self: *Text, s: []const u8) void {
        if (self.len + s.len > self.buf.len) {
            self.over = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn byte(self: *Text, c: u8) void {
        self.put(&[1]u8{c});
    }

    fn number(self: *Text, value: usize) void {
        var digits: [20]u8 = undefined;
        var n: usize = 0;
        var v = value;
        while (true) {
            digits[n] = @intCast('0' + v % 10);
            n += 1;
            v /= 10;
            if (v == 0) break;
        }
        while (n > 0) {
            n -= 1;
            self.byte(digits[n]);
        }
    }

    /// The caller's text, with every special token's string broken after its
    /// first character by a zero-width space: it reads the same and never
    /// becomes markup (d1's `plain`).
    fn plain(self: *Text, tokenizer: anytype, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            self.byte(s[i]);
            if (tokenizer.special(s[i..]) > 1) self.put(ZWSP);
        }
    }

    /// A key as an option's text: underscores read as spaces.
    fn spaced(self: *Text, tokenizer: anytype, s: []const u8) void {
        var start: usize = 0;
        for (s, 0..) |c, i| {
            if (c != '_') continue;
            self.plain(tokenizer, s[start..i]);
            self.byte(' ');
            start = i + 1;
        }
        self.plain(tokenizer, s[start..]);
    }
};

/// The option codes of `count` options (d1's `option_codes`, scheme 2): the
/// labels themselves when every one is a single letter, else A..Z, then AA,
/// AB.. ZZ. `out` gets the code's text.
pub fn optionCode(labels: []const Option, position: usize, out: *[4]u8) []const u8 {
    var letters = labels.len > 0;
    for (labels) |o| {
        const k = trimmed(o.key);
        if (k.len != 1 or !isAlpha(k[0])) letters = false;
    }
    if (letters) {
        const k = trimmed(labels[position].key);
        out[0] = k[0];
        return out[0..1];
    }
    if (position < 26) {
        out[0] = @intCast('A' + position);
        return out[0..1];
    }
    const rest = position - 26;
    out[0] = @intCast('A' + (rest / 26) % 26);
    out[1] = @intCast('A' + rest % 26);
    return out[0..2];
}

/// d1's fallback codes (`_FALLBACK_POOL`) for a code the tokenizer splits:
/// A..Z, 00..99, a..z, #0..#199, then AA..ZZ.
pub fn fallbackCode(position: usize, out: *[4]u8) ?[]const u8 {
    var p = position;
    if (p < 26) {
        out[0] = @intCast('A' + p);
        return out[0..1];
    }
    p -= 26;
    if (p < 100) {
        out[0] = @intCast('0' + p / 10);
        out[1] = @intCast('0' + p % 10);
        return out[0..2];
    }
    p -= 100;
    if (p < 26) {
        out[0] = @intCast('a' + p);
        return out[0..1];
    }
    p -= 26;
    if (p < 200) {
        out[0] = '#';
        if (p < 10) {
            out[1] = @intCast('0' + p);
            return out[0..2];
        }
        if (p < 100) {
            out[1] = @intCast('0' + p / 10);
            out[2] = @intCast('0' + p % 10);
            return out[0..3];
        }
        out[1] = @intCast('0' + p / 100);
        out[2] = @intCast('0' + (p / 10) % 10);
        out[3] = @intCast('0' + p % 10);
        return out[0..4];
    }
    p -= 200;
    if (p < 26 * 26) {
        out[0] = @intCast('A' + p / 26);
        out[1] = @intCast('A' + p % 26);
        return out[0..2];
    }
    return null;
}

fn trimmed(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\n')) b -= 1;
    return s[a..b];
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// The question's own text after the state (the template's body): its
/// instructions, its options with their codes, the reply line.
fn questionBody(text: *Text, tokenizer: anytype, q: *const Question, codes: []const [4]u8, code_len: []const u8) void {
    text.plain(tokenizer, q.instructions);
    switch (q.kind) {
        .choice => {
            text.put("\n\nOptions:\n");
            for (q.options, 0..) |o, i| {
                if (i > 0) text.byte('\n');
                text.put(codes[i][0..code_len[i]]);
                text.byte(' ');
                if (o.description) |d| {
                    if (d.len > 0) text.plain(tokenizer, d) else text.spaced(tokenizer, o.key);
                } else text.spaced(tokenizer, o.key);
            }
            text.put("\n\nReply with the option code only.");
        },
        .noul => {
            if (q.options.len > 0) {
                // (true first, as prompt.py writes them: Yes, then No)
                for ([2][]const u8{ "true", "false" }) |want| {
                    text.put(if (eql(want, "true")) "\nYes: " else "\nNo: ");
                    var said: ?[]const u8 = null;
                    for (q.options) |o| {
                        if (eql(o.key, want)) said = o.description;
                    }
                    if (said) |d| text.plain(tokenizer, d) else text.put("None");
                }
            }
            text.put("\n\nReply with yes or no only.");
        },
        .score => {
            text.put("\n\n");
            for (q.options, 0..) |o, i| {
                text.number(i);
                text.byte(' ');
                text.plain(tokenizer, o.key);
                text.byte('\n');
            }
            text.put("\nReply with a single digit 0-");
            text.number(q.options.len - 1);
            text.put(" only.");
        },
    }
    text.put(ANSWER);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Write the state block: text as it is, an object as Python's
/// `json.dumps(indent=2, ensure_ascii=False)`.
fn stateBlock(text: *Text, tokenizer: anytype, state: State) void {
    switch (state) {
        .none => {},
        .text => |s| text.plain(tokenizer, s),
        .json => |raw| {
            var pretty: [MAX_TEXT / 2]u8 = undefined;
            const n = prettyJson(raw, &pretty) orelse {
                text.over = true;
                return;
            };
            text.plain(tokenizer, pretty[0..n]);
        },
    }
}

pub const State = union(enum) {
    none,
    text: []const u8,
    /// The raw JSON of an object or array state.
    json: []const u8,
};

// ── One request ─────────────────────────────────────────────────────────────

/// Answer `questions` about `state`, `set_size` questions a pass (1 to
/// MAX_SET). Each answer's probabilities follow its question's options.
pub fn ask(
    comptime tensor_capacity: usize,
    comptime limits: executor.Limits,
    model: *const Model(tensor_capacity),
    tokenizer: anytype,
    work: *executor.Workspace(limits),
    cache: *executor.Cache,
    scratch: *Scratch(limits),
    state: State,
    questions: []const Question,
    set_size: usize,
    answers: []Answer,
    parallel: executor.Parallel,
) Error!Usage {
    return askOn(tensor_capacity, limits, model, tokenizer, work, cache, scratch, state, questions, set_size, answers, parallel, null);
}

/// `ask`, its passes on `runner` when there is one (`work`, `cache` and
/// `parallel` are then not used).
pub fn askOn(
    comptime tensor_capacity: usize,
    comptime limits: executor.Limits,
    model: *const Model(tensor_capacity),
    tokenizer: anytype,
    work: *executor.Workspace(limits),
    cache: *executor.Cache,
    scratch: *Scratch(limits),
    state: State,
    questions: []const Question,
    set_size: usize,
    answers: []Answer,
    parallel: executor.Parallel,
    runner: ?*const Runner,
) Error!Usage {
    if (questions.len == 0) return error.NoQuestions;
    if (questions.len > answers.len or questions.len > MAX_QUESTIONS) return error.TooManyQuestions;
    for (questions) |*q| {
        if (q.options.len > MAX_OPTIONS) return error.TooManyOptions;
        if (q.kind == .choice and q.options.len == 0) return error.NoOptions;
        if (q.kind == .score and (q.options.len < 2 or q.options.len > 10)) return error.UnsupportedQuestion;
    }
    const step = @max(1, @min(set_size, MAX_SET));
    var usage = Usage{};
    var first: usize = 0;
    while (first < questions.len) : (first += step) {
        const set = questions[first..@min(questions.len, first + step)];
        usage.input_tokens += try pass(tensor_capacity, limits, model, tokenizer, work, cache, scratch, state, set, answers[first..][0..set.len], parallel, runner);
        usage.passes += 1;
    }
    return usage;
}

/// One pass: `set` packed after `state`, read at each question's slot.
fn pass(
    comptime tensor_capacity: usize,
    comptime limits: executor.Limits,
    model: *const Model(tensor_capacity),
    tokenizer: anytype,
    work: *executor.Workspace(limits),
    cache: *executor.Cache,
    scratch: *Scratch(limits),
    state: State,
    set: []const Question,
    answers: []Answer,
    parallel: executor.Parallel,
    runner: ?*const Runner,
) Error!usize {
    var codes: [MAX_SET][MAX_OPTIONS][4]u8 = undefined;
    var code_len: [MAX_SET][MAX_OPTIONS]u8 = undefined;
    var slots: [MAX_SET]usize = undefined;
    var count: usize = 0;
    var state_len: usize = 0;
    for (set, 0..) |*q, k| {
        try choiceCodes(q, tokenizer, &codes[k], &code_len[k]);
        var text = Text{ .buf = &scratch.text };
        if (k == 0) {
            text.put(BOS);
            text.put(USER);
            if (state != .none) {
                stateBlock(&text, tokenizer, state);
                text.put("\n\n\n");
                text.put(HEADER);
            }
        } else if (state != .none) text.put(HEADER);
        const body_start = text.len;
        questionBody(&text, tokenizer, q, codes[k][0..q.options.len], code_len[k][0..q.options.len]);
        if (text.over) return error.TextCapacity;
        const room = scratch.ids[count..];
        const n = tokenizer.encode(text.buf[0..text.len], room) catch return error.TokenCapacity;
        if (n == 0) return error.TokenizerFailed;
        if (k == 0) {
            // The first question tokenizes with its state, as a lone prompt
            // does; the state is the prompt's tokens before its suffix's.
            const own = tokenizer.encode(text.buf[body_start..text.len], &scratch.piece) catch return error.TokenCapacity;
            if (own >= n) return error.TokenizerFailed;
            state_len = n - own;
            @memset(scratch.group[0..state_len], 0);
            @memset(scratch.group[state_len..n], 1);
        } else {
            @memset(scratch.group[count..][0..n], @intCast(k + 1));
        }
        count += n;
        slots[k] = count - 1;
    }
    const sees = executor.Sees{ .state = state_len, .group = scratch.group[0..count] };
    const hidden: usize = model.plan.hidden_size;
    if (runner) |r| {
        var positions: [MAX_SET]u32 = undefined;
        for (slots[0..set.len], positions[0..set.len]) |slot, *at| at.* = @intCast(slot);
        try r.run(r.context, scratch.ids[0..count], &sees);
        try r.rows(r.context, positions[0..set.len], scratch.rows[0 .. set.len * hidden]);
    } else {
        cache.reset();
        _ = try executor.forwardSees(tensor_capacity, limits, model.source, model.index, model.plan, model.weights, work, cache, scratch.ids[0..count], .none, &sees, parallel);
    }
    for (set, 0..) |*q, k| {
        const residual: []const f32 = if (runner != null) scratch.rows[k * hidden ..][0..hidden] else work.hidden[slots[k] * hidden ..][0..hidden];
        try readSlot(tensor_capacity, limits, model, tokenizer, residual, scratch, q, codes[k][0..q.options.len], code_len[k][0..q.options.len], &answers[k]);
    }
    return count;
}

/// The codes a choice's options are written with: d1's scheme, each a
/// single token not taken by an earlier option, else the next free one of
/// the fallback pool.
fn choiceCodes(q: *const Question, tokenizer: anytype, codes: *[MAX_OPTIONS][4]u8, code_len: *[MAX_OPTIONS]u8) Error!void {
    if (q.kind != .choice) return;
    var taken: [MAX_OPTIONS]u32 = undefined;
    var ids: [8]u32 = undefined;
    var pool: usize = 0;
    for (q.options, 0..) |_, i| {
        var buf: [4]u8 = undefined;
        const code = optionCode(q.options, i, &buf);
        var chosen: ?[]const u8 = null;
        if (singleToken(tokenizer, code, &ids)) |id| {
            if (!contains(taken[0..i], id)) {
                taken[i] = id;
                chosen = code;
            }
        }
        if (chosen == null) {
            while (fallbackCode(pool, &buf)) |alt| {
                pool += 1;
                if (singleToken(tokenizer, alt, &ids)) |id| {
                    if (!contains(taken[0..i], id)) {
                        taken[i] = id;
                        chosen = alt;
                        break;
                    }
                }
            }
        }
        const c = chosen orelse return error.NoSingleTokenCode;
        @memcpy(codes[i][0..c.len], c);
        code_len[i] = @intCast(c.len);
    }
}

fn contains(list: []const u32, id: u32) bool {
    for (list) |x| if (x == id) return true;
    return false;
}

fn singleToken(tokenizer: anytype, text: []const u8, ids: *[8]u32) ?u32 {
    const n = tokenizer.encode(text, ids) catch return null;
    return if (n == 1) ids[0] else null;
}

/// The answer at one slot: its final `residual` through the output norm,
/// each option's best form's logit, the temperature, the softmax.
fn readSlot(
    comptime tensor_capacity: usize,
    comptime limits: executor.Limits,
    model: *const Model(tensor_capacity),
    tokenizer: anytype,
    residual: []const f32,
    scratch: *Scratch(limits),
    q: *const Question,
    codes: []const [4]u8,
    code_len: []const u8,
    answer: *Answer,
) Error!void {
    const plan = model.plan;
    const hidden: usize = plan.hidden_size;
    const norm = try vector(model.source, model.index, plan.output_norm, hidden);
    rmsNorm(residual, norm, scratch.normed[0..hidden], plan.rms_norm_epsilon);
    const output = try matrix(model.source, model.index, plan.output);
    if (output.columns != hidden) return error.InvalidPlan;

    const option_count: usize = switch (q.kind) {
        .noul => 2,
        .choice, .score => q.options.len,
    };
    var ids: [8]u32 = undefined;
    var scores: [MAX_OPTIONS]f32 = undefined;
    for (0..option_count) |i| {
        // This option's forms: single tokens, distinct.
        var forms: [MAX_FORMS]u32 = undefined;
        var n: usize = 0;
        switch (q.kind) {
            .noul => {
                const words = if (i == 0) [3][]const u8{ "yes", "Yes", "YES" } else [3][]const u8{ "no", "No", "NO" };
                for (words) |w| {
                    if (singleToken(tokenizer, w, &ids)) |id| {
                        if (!contains(forms[0..n], id)) {
                            forms[n] = id;
                            n += 1;
                        }
                    }
                }
            },
            .score => {
                const digit = [1]u8{@intCast('0' + i)};
                if (singleToken(tokenizer, &digit, &ids)) |id| {
                    forms[0] = id;
                    n = 1;
                }
            },
            .choice => {
                const code = codes[i][0..code_len[i]];
                if (singleToken(tokenizer, code, &ids)) |id| {
                    forms[0] = id;
                    n = 1;
                }
                var spaced: [5]u8 = undefined;
                spaced[0] = ' ';
                @memcpy(spaced[1..][0..code.len], code);
                if (singleToken(tokenizer, spaced[0 .. code.len + 1], &ids)) |id| {
                    if (!contains(forms[0..n], id)) {
                        forms[n] = id;
                        n += 1;
                    }
                }
            },
        }
        if (n == 0) return error.NoSingleTokenCode;
        var best: f32 = -3.0e38;
        for (forms[0..n]) |token| {
            if (token >= output.rows) return error.InvalidToken;
            const row = output.bytes[@as(usize, token) * output.row_bytes ..][0..output.row_bytes];
            switch (output.ggml_type) {
                12 => try quantized.dequantizeQ4K(scratch.row[0..hidden], row),
                else => try quantized.dequantizeQ6K(scratch.row[0..hidden], row),
            }
            var dot: f32 = 0;
            for (scratch.row[0..hidden], scratch.normed[0..hidden]) |a, b| dot += a * b;
            best = @max(best, dot);
        }
        scores[i] = best;
    }
    const temperature = model.temperature[@intFromEnum(q.kind)];
    var maximum: f32 = -3.0e38;
    for (scores[0..option_count]) |*s| {
        s.* /= temperature;
        maximum = @max(maximum, s.*);
    }
    var total: f64 = 0;
    for (scores[0..option_count]) |s| total += @exp(@as(f64, s - maximum));
    answer.count = @intCast(option_count);
    answer.best = 0;
    for (scores[0..option_count], 0..) |s, i| {
        answer.probabilities[i] = @floatCast(@exp(@as(f64, s - maximum)) / total);
        if (answer.probabilities[i] > answer.probabilities[answer.best]) answer.best = @intCast(i);
    }
}

fn rmsNorm(input: []const f32, weight: []const f32, output: []f32, epsilon: f32) void {
    var sum: f64 = 0;
    for (input) |x| sum += @as(f64, x) * x;
    const scale: f32 = @floatCast(1.0 / @sqrt(sum / @as(f64, @floatFromInt(input.len)) + epsilon));
    for (input, weight, output) |x, w, *o| o.* = x * scale * w;
}

const MatrixView = struct { bytes: []const u8, row_bytes: usize, ggml_type: u32, rows: usize, columns: usize };

fn matrix(source: gguf.Source, index: anytype, reference: lfm3.TensorRef) Error!MatrixView {
    if (!reference.present()) return error.InvalidPlan;
    const tensor = &index.tensors[reference.index];
    if (tensor.dimension_count != 2 or (tensor.ggml_type != 12 and tensor.ggml_type != 14)) return error.InvalidPlan;
    const rows: usize = @intCast(tensor.dimensions[1]);
    const columns: usize = @intCast(tensor.dimensions[0]);
    if (columns % quantized.QK_K != 0) return error.InvalidPlan;
    const block_bytes: usize = if (tensor.ggml_type == 12) quantized.Q4_K_BLOCK_BYTES else quantized.Q6_K_BLOCK_BYTES;
    const row_bytes = (columns / quantized.QK_K) * block_bytes;
    if (rows * row_bytes != tensor.byte_size) return error.InvalidPlan;
    const bytes = source.view(tensor.file_offset, @intCast(tensor.byte_size), 1) orelse return error.StorageNotMapped;
    return .{ .bytes = bytes, .row_bytes = row_bytes, .ggml_type = tensor.ggml_type, .rows = rows, .columns = columns };
}

fn vector(source: gguf.Source, index: anytype, reference: lfm3.TensorRef, elements: usize) Error![]const f32 {
    if (!reference.present()) return error.InvalidPlan;
    const tensor = &index.tensors[reference.index];
    if (tensor.ggml_type != 0 or tensor.byte_size != elements * 4) return error.InvalidPlan;
    const bytes = source.view(tensor.file_offset, @intCast(tensor.byte_size), @alignOf(f32)) orelse return error.StorageNotMapped;
    const values: [*]const f32 = @ptrCast(@alignCast(bytes.ptr));
    return values[0..elements];
}

// ── JSON: the request and the answers (`/v1/systemone`) ────────────────────

/// A parsed request: slices into `body` and into the request's own storage.
pub const Request = struct {
    state: State = .none,
    questions: [MAX_QUESTIONS]Question = undefined,
    question_count: usize = 0,
    options: [MAX_QUESTIONS * 32]Option = undefined,
    option_count: usize = 0,
    /// Unescaped strings.
    strings: [64 * 1024]u8 = undefined,
    strings_len: usize = 0,
    /// `set_size` when the request names one (0: the server's default).
    set_size: usize = 0,

    pub fn list(self: *const Request) []const Question {
        return self.questions[0..self.question_count];
    }

    fn keep(self: *Request, raw: []const u8) ?[]const u8 {
        const out = json.unescape(raw, self.strings[self.strings_len..]) orelse return null;
        self.strings_len += out.len;
        return out;
    }
};

/// Read `{"state": ..., "questions": {...}, "set_size": n}` into `out`.
pub fn parseRequest(body: []const u8, out: *Request) Error!void {
    out.* = .{ .questions = undefined, .options = undefined, .strings = undefined };
    var r = json.Reader.init(body);
    if (r.next().kind != .begin_object) return error.InvalidRequest;
    while (true) {
        const k = r.next();
        if (k.kind == .end_object) break;
        if (k.kind != .string) return error.InvalidRequest;
        const key = r.str(k);
        const v = r.next();
        if (eql(key, "state")) {
            switch (v.kind) {
                .null_ => out.state = .none,
                .string => out.state = .{ .text = out.keep(r.str(v)) orelse return error.InvalidRequest },
                .begin_object, .begin_array => out.state = .{ .json = r.raw(v) orelse return error.InvalidRequest },
                else => out.state = .{ .json = r.raw(v) orelse return error.InvalidRequest },
            }
        } else if (eql(key, "questions")) {
            if (v.kind != .begin_object) return error.InvalidRequest;
            try parseQuestions(&r, out);
        } else if (eql(key, "set_size")) {
            if (v.kind != .number) return error.InvalidRequest;
            out.set_size = parseCount(r.str(v)) orelse return error.InvalidRequest;
        } else {
            _ = r.skip(v) orelse return error.InvalidRequest;
        }
    }
    if (out.question_count == 0) return error.NoQuestions;
}

fn parseCount(s: []const u8) ?usize {
    var n: usize = 0;
    if (s.len == 0) return null;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > 1_000_000) return null;
    }
    return n;
}

fn parseQuestions(r: *json.Reader, out: *Request) Error!void {
    while (true) {
        const name_token = r.next();
        if (name_token.kind == .end_object) return;
        if (name_token.kind != .string) return error.InvalidRequest;
        if (out.question_count == MAX_QUESTIONS) return error.TooManyQuestions;
        const name = out.keep(r.str(name_token)) orelse return error.InvalidRequest;
        if (r.next().kind != .begin_object) return error.InvalidRequest;
        var q = Question{ .name = name, .kind = .choice, .instructions = "" };
        var kind_seen = false;
        const first_option = out.option_count;
        while (true) {
            const k = r.next();
            if (k.kind == .end_object) break;
            if (k.kind != .string) return error.InvalidRequest;
            const key = r.str(k);
            const v = r.next();
            if (eql(key, "type")) {
                if (v.kind != .string) return error.InvalidRequest;
                const t = r.str(v);
                q.kind = if (eql(t, "noul")) .noul else if (eql(t, "choice")) .choice else if (eql(t, "score")) .score else return error.UnsupportedQuestion;
                kind_seen = true;
            } else if (eql(key, "instructions")) {
                if (v.kind != .string) return error.InvalidRequest;
                q.instructions = out.keep(r.str(v)) orelse return error.InvalidRequest;
            } else if (eql(key, "criteria")) {
                if (v.kind == .begin_object) {
                    while (true) {
                        const ok = r.next();
                        if (ok.kind == .end_object) break;
                        if (ok.kind != .string) return error.InvalidRequest;
                        const ov = r.next();
                        if (out.option_count == out.options.len) return error.TooManyOptions;
                        const okey = out.keep(r.str(ok)) orelse return error.InvalidRequest;
                        const desc: ?[]const u8 = switch (ov.kind) {
                            .string => out.keep(r.str(ov)) orelse return error.InvalidRequest,
                            .null_ => null,
                            else => r.raw(ov) orelse return error.InvalidRequest,
                        };
                        out.options[out.option_count] = .{ .key = okey, .description = desc };
                        out.option_count += 1;
                    }
                } else if (v.kind == .begin_array) {
                    while (true) {
                        const item = r.next();
                        if (item.kind == .end_array) break;
                        if (item.kind != .string) return error.InvalidRequest;
                        if (out.option_count == out.options.len) return error.TooManyOptions;
                        out.options[out.option_count] = .{ .key = out.keep(r.str(item)) orelse return error.InvalidRequest };
                        out.option_count += 1;
                    }
                } else if (v.kind != .null_) return error.InvalidRequest;
            } else {
                _ = r.skip(v) orelse return error.InvalidRequest;
            }
        }
        if (!kind_seen or q.instructions.len == 0) return error.InvalidRequest;
        q.options = out.options[first_option..out.option_count];
        if (q.kind == .choice and q.options.len == 0) return error.NoOptions;
        out.questions[out.question_count] = q;
        out.question_count += 1;
    }
}

/// `{"answers": {name: ...}, "usage": {...}}`: a noul's P(yes); a choice's
/// option, its probabilities and confidence; a score's median level.
pub fn writeAnswers(questions: []const Question, answers: []const Answer, usage: Usage, out: []u8) ?[]const u8 {
    var w = json.Writer.init(out);
    w.beginObject();
    w.key("answers");
    w.beginObject();
    for (questions, answers[0..questions.len]) |*q, *a| {
        w.key(q.name);
        w.beginObject();
        w.field("type", q.kind.word());
        switch (q.kind) {
            .noul => {
                w.key("noul");
                writeProbability(&w, a.yes());
            },
            .choice => {
                w.field("choice", q.options[a.best].key);
                w.key("probabilities");
                w.beginObject();
                for (q.options, 0..) |o, i| {
                    w.key(o.key);
                    writeProbability(&w, a.probabilities[i]);
                }
                w.endObject();
                w.key("confidence");
                writeProbability(&w, a.confidence());
            },
            .score => {
                const m = a.median();
                w.key("score");
                w.int(m);
                w.field("level", q.options[m].key);
                w.key("probabilities");
                w.beginArray();
                for (a.probabilities[0..a.count]) |p| writeProbability(&w, p);
                w.endArray();
                w.key("confidence");
                writeProbability(&w, a.probabilities[m]);
            },
        }
        w.endObject();
    }
    w.endObject();
    w.key("usage");
    w.beginObject();
    w.key("input_tokens");
    w.int(@intCast(usage.input_tokens));
    w.key("output_tokens");
    w.int(0);
    w.key("passes");
    w.int(@intCast(usage.passes));
    w.endObject();
    w.endObject();
    return if (w.overflow) null else w.bytes();
}

/// A probability as JSON with six decimals.
fn writeProbability(w: *json.Writer, p: f32) void {
    var buf: [16]u8 = undefined;
    const clamped: f64 = if (p != p) 0 else @max(0, @min(1, @as(f64, p)));
    const micro: u64 = @intFromFloat(@round(clamped * 1_000_000));
    buf[0] = @intCast('0' + micro / 1_000_000);
    buf[1] = '.';
    var rest = micro % 1_000_000;
    var i: usize = 7;
    while (i > 1) : (i -= 1) {
        buf[i] = @intCast('0' + rest % 10);
        rest /= 10;
    }
    w.raw(buf[0..8]);
}

// ── An object state as Python's json.dumps(indent=2, ensure_ascii=False) ──

/// Re-indent the raw JSON value `raw` into `out`; its length, or null when
/// it does not fit or is not JSON.
pub fn prettyJson(raw: []const u8, out: []u8) ?usize {
    var r = json.Reader.init(raw);
    var text = Text{ .buf = out };
    const first = r.next();
    if (!prettyValue(&r, first, &text, 0)) return null;
    return if (text.over) null else text.len;
}

fn indent(text: *Text, depth: usize) void {
    text.byte('\n');
    for (0..depth * 2) |_| text.byte(' ');
}

fn prettyValue(r: *json.Reader, t: json.Token, text: *Text, depth: usize) bool {
    switch (t.kind) {
        .begin_object, .begin_array => {
            const object = t.kind == .begin_object;
            const closing: json.Kind = if (object) .end_object else .end_array;
            var item = r.next();
            if (item.kind == closing) {
                text.put(if (object) "{}" else "[]");
                return true;
            }
            text.byte(if (object) '{' else '[');
            var n: usize = 0;
            while (item.kind != closing) : (n += 1) {
                if (item.kind == .end or item.kind == .err) return false;
                if (n > 0) text.byte(',');
                indent(text, depth + 1);
                if (object) {
                    if (item.kind != .string) return false;
                    if (!pythonString(r.str(item), text)) return false;
                    text.put(": ");
                    item = r.next();
                }
                if (!prettyValue(r, item, text, depth + 1)) return false;
                item = r.next();
            }
            indent(text, depth);
            text.byte(if (object) '}' else ']');
            return true;
        },
        .string => return pythonString(r.str(t), text),
        .number => text.put(r.str(t)),
        .true_ => text.put("true"),
        .false_ => text.put("false"),
        .null_ => text.put("null"),
        else => return false,
    }
    return true;
}

/// A JSON string's raw text as Python writes it: unescaped, then escaped
/// again (`\"`, `\\`, `\n`, `\r`, `\t`, `\b`, `\f`, other controls as
/// `\u00XX`; everything else, `/` and UTF-8 included, as it is).
fn pythonString(raw: []const u8, text: *Text) bool {
    var plainbuf: [8192]u8 = undefined;
    const s = json.unescape(raw, &plainbuf) orelse return false;
    text.byte('"');
    for (s) |c| {
        switch (c) {
            '"' => text.put("\\\""),
            '\\' => text.put("\\\\"),
            '\n' => text.put("\\n"),
            '\r' => text.put("\\r"),
            '\t' => text.put("\\t"),
            0x08 => text.put("\\b"),
            0x0c => text.put("\\f"),
            0...0x07, 0x0b, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                text.put("\\u00");
                text.byte(hex[c >> 4]);
                text.byte(hex[c & 0xf]);
            },
            else => text.byte(c),
        }
    }
    text.byte('"');
    return true;
}

// ── Tests (no model: the prompt, the codes, the JSON) ──────────────────────

const testing = struct {
    fn expect(ok: bool) !void {
        if (!ok) return error.TestUnexpectedResult;
    }
    fn expectEqual(a: []const u8, b: []const u8) !void {
        if (!eql(a, b)) return error.TestUnexpectedResult;
    }
};

/// A stand-in tokenizer: one token per byte, `<|...|>` and `<think>` markup
/// one token each.
const ByteTokenizer = struct {
    fn special(_: ByteTokenizer, s: []const u8) usize {
        const marks = [_][]const u8{ "<|startoftext|>", "<|im_start|>", "<|im_end|>", "<think>", "</think>" };
        for (marks) |m| if (s.len >= m.len and eql(s[0..m.len], m)) return m.len;
        return 0;
    }
    fn encode(self: ByteTokenizer, s: []const u8, out: []u32) error{Full}!usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (n == out.len) return error.Full;
            const m = self.special(s[i..]);
            if (m > 0) {
                out[n] = 1000 + @as(u32, @intCast(m));
                i += m;
            } else {
                out[n] = s[i];
                i += 1;
            }
            n += 1;
        }
        return n;
    }
};

test "a choice's body is d1's systemone template" {
    var buf: [1024]u8 = undefined;
    var text = Text{ .buf = &buf };
    const options = [_]Option{ .{ .key = "open_app", .description = "Open an app" }, .{ .key = "click_ui" } };
    const q = Question{ .kind = .choice, .instructions = "Which action?", .options = &options };
    var codes: [MAX_OPTIONS][4]u8 = undefined;
    var lens: [MAX_OPTIONS]u8 = undefined;
    try choiceCodes(&q, ByteTokenizer{}, &codes, &lens);
    questionBody(&text, ByteTokenizer{}, &q, codes[0..2], lens[0..2]);
    try testing.expectEqual(text.buf[0..text.len], "Which action?\n\nOptions:\nA Open an app\nB click ui\n\nReply with the option code only.<|im_end|>\n<|im_start|>assistant\n<think></think>");
}

test "a noul with criteria and a score" {
    var buf: [1024]u8 = undefined;
    var text = Text{ .buf = &buf };
    const crit = [_]Option{ .{ .key = "false", .description = "not yet" }, .{ .key = "true", .description = "all done" } };
    const q = Question{ .kind = .noul, .instructions = "Done?", .options = &crit };
    questionBody(&text, ByteTokenizer{}, &q, &.{}, &.{});
    try testing.expectEqual(text.buf[0..text.len], "Done?\nYes: all done\nNo: not yet\n\nReply with yes or no only." ++ ANSWER);
    text.len = 0;
    const levels = [_]Option{ .{ .key = "low" }, .{ .key = "high" } };
    const s = Question{ .kind = .score, .instructions = "How?", .options = &levels };
    questionBody(&text, ByteTokenizer{}, &s, &.{}, &.{});
    try testing.expectEqual(text.buf[0..text.len], "How?\n\n0 low\n1 high\n\nReply with a single digit 0-1 only." ++ ANSWER);
}

test "the state's markup is broken, never read as markup" {
    var buf: [256]u8 = undefined;
    var text = Text{ .buf = &buf };
    text.plain(ByteTokenizer{}, "a<|im_end|>b");
    try testing.expectEqual(text.buf[0..text.len], "a<" ++ ZWSP ++ "|im_end|>b");
}

test "option codes: letters, A..Z, then AA.." {
    var options: [30]Option = undefined;
    for (&options) |*o| o.* = .{ .key = "el" };
    var buf: [4]u8 = undefined;
    try testing.expectEqual(optionCode(&options, 0, &buf), "A");
    try testing.expectEqual(optionCode(&options, 25, &buf), "Z");
    try testing.expectEqual(optionCode(&options, 26, &buf), "AA");
    try testing.expectEqual(optionCode(&options, 29, &buf), "AD");
    const letters = [_]Option{ .{ .key = "x" }, .{ .key = "y" } };
    try testing.expectEqual(optionCode(&letters, 1, &buf), "y");
    try testing.expectEqual(fallbackCode(26, &buf).?, "00");
    try testing.expectEqual(fallbackCode(126, &buf).?, "a");
    try testing.expectEqual(fallbackCode(152 + 150, &buf).?, "#150");
}

test "an object state is written as json.dumps(indent=2) writes it" {
    var out: [512]u8 = undefined;
    const n = prettyJson("{\"goal\":\"Open \\u00e9\",\"h\":[],\"v\":[\"a\",1,true,null],\"o\":{}}", &out).?;
    try testing.expectEqual(out[0..n], "{\n  \"goal\": \"Open \u{e9}\",\n  \"h\": [],\n  \"v\": [\n    \"a\",\n    1,\n    true,\n    null\n  ],\n  \"o\": {}\n}");
}

test "a request and its answers" {
    var request: Request = undefined;
    try parseRequest(
        \\{"state": "x", "questions": {"done": {"type": "noul", "instructions": "Done?"},
        \\ "act": {"type": "choice", "instructions": "Next?", "criteria": {"a": "Do a", "b": null}}}, "set_size": 4}
    , &request);
    try testing.expect(request.question_count == 2 and request.set_size == 4);
    try testing.expectEqual(request.questions[1].options[0].description.?, "Do a");
    try testing.expect(request.questions[1].options[1].description == null);
    var answers: [2]Answer = .{ .{}, .{} };
    answers[0].count = 2;
    answers[0].probabilities[0] = 0.25;
    answers[0].probabilities[1] = 0.75;
    answers[1].count = 2;
    answers[1].best = 1;
    answers[1].probabilities[0] = 0.1;
    answers[1].probabilities[1] = 0.9;
    var out: [512]u8 = undefined;
    const written = writeAnswers(request.list(), &answers, .{ .input_tokens = 10, .passes = 1 }, &out).?;
    try testing.expectEqual(written, "{\"answers\":{\"done\":{\"type\":\"noul\",\"noul\":0.250000},\"act\":{\"type\":\"choice\",\"choice\":\"b\",\"probabilities\":{\"a\":0.100000,\"b\":0.900000},\"confidence\":0.900000}},\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"passes\":1}}");
}

test "the next-best unmasked option" {
    var a = Answer{ .count = 3, .best = 1 };
    a.probabilities[0] = 0.2;
    a.probabilities[1] = 0.7;
    a.probabilities[2] = 0.1;
    const masked = [_]bool{ false, true, false };
    try testing.expect(a.bestUnmasked(&masked).? == 0);
}
