//! speechbench: LFM3-Audio speaking a line on the real GPU behind /dev/dxg
//! (WSL), its weights in VRAM the CPU has no view of (Adapter.gpu_only: as
//! the forwarded RTX in Galaxy's VM), against the CPU, frame by frame.
//!
//! galaxy-think's speech loop, twice in lock step from the same seed: the
//! CPU's (the executor's row kernels, gen.Speaker.frame) and the GPU's
//! (lfm3_any's backbone, lfm3_any_audio's depthformer through frameOn).
//! Each frame prints the hidden states' worst difference, the GPU
//! depthformer's against the CPU's on the GPU's own hidden state, and
//! whether the codes agree. Each side's speech goes to a WAV (the CPU's
//! codec), so the two can be heard.
//!
//!   speechbench <voice.gguf> <voice-mmproj.gguf> <text> [out-prefix]
//!
//! SB_SEED=n the sampler's seed (default 4242, galaxy-think's first try);
//! SB_VOICE=male; SB_FRAMES=n the most frames (default 160); SB_SPLIT=n the
//! GPU reads the prompt as galaxy-think's readPrompt does, n tokens at most
//! and a new piece at each <|im_start|>; SB_CODEC=gpu the GPU side's speech
//! through lfm3_any_codec, between its frames, as galaxy-think does.

const std = @import("std");
const linux = std.os.linux;
const dxg = @import("dxg");
const gpu = @import("gpu");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const any = @import("lfm3_any");
const any_audio = @import("lfm3_any_audio");
const any_codec = @import("lfm3_any_codec");
const gen = @import("lfm3_audio_gen");
const tokenizer = @import("lfm3_tokenizer");
const indexes = @import("tokenizer_index");

fn out(comptime fmt: []const u8, args: anytype) void {
    var b: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn mapMemory(bytes: usize) []align(4096) u8 {
    const m: isize = @bitCast(linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0));
    if (m < 0) {
        out("speechbench: no memory ({d} bytes)\n", .{bytes});
        linux.exit(2);
    }
    const p: [*]align(4096) u8 = @ptrFromInt(@as(usize, @intCast(m)));
    return p[0..bytes];
}

fn mapFile(path: [*:0]const u8) []const u8 {
    const fd: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) {
        out("speechbench: cannot open {s}\n", .{std.mem.span(path)});
        linux.exit(2);
    }
    const end: isize = @bitCast(linux.lseek(@intCast(fd), 0, linux.SEEK.END));
    if (end <= 0) linux.exit(2);
    const size: usize = @intCast(end);
    const m: isize = @bitCast(linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE, .POPULATE = true }, @intCast(fd), 0));
    if (m < 0) linux.exit(2);
    const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(m)));
    return p[0..size];
}

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

fn env(environ: anytype, comptime name: []const u8) ?[]const u8 {
    for (environ) |e| {
        const kv = std.mem.span(e orelse continue);
        if (std.mem.startsWith(u8, kv, name ++ "=")) return kv[name.len + 1 ..];
    }
    return null;
}

const CAP = 512;
const AUDIO_CAP = 1024;
const LIMITS = blk: {
    var l = executor.lfm3_audio_2b_limits;
    l.batch = 16;
    l.context = 512;
    break :blk l;
};
const SL = gen.lfm3_audio_limits;
const Backend = any.Backend(CAP);

var g: dxg.Gpu = .{};
var ch: dxg.Channel = .{};
var sys: dxg.DxgDevice = undefined;
var vram: dxg.VramDevice = undefined;
var adapter: gpu.nvidia_device.Adapter = .{};
var work: any.Work = .{};
var index: gguf.Index(CAP) = .{};
var plan: lfm3.Plan = .{};
var audio_index: gguf.Index(AUDIO_CAP) = .{};
var speech_plan: gen.Plan = .{};
var cpu_work: executor.Workspace(LIMITS) = .{};
const unpacked: executor.PackedWeights(CAP) = .{};
var vocabulary: indexes.VocabularyIndex(160_000, 262_144) = .{};
var merges: indexes.MergeIndex(524_288, 512) = .{};
var specials: tokenizer.SpecialTokens = .{};
var tokens: [LIMITS.context]u32 = undefined;
var depth_cpu: gen.DepthWorkspace(SL) = .{};
var depth_check: gen.DepthWorkspace(SL) = .{};
var codec_work: gen.CodecWorkspace(SL) = .{};
var codec_states: [2]gen.CodecState(SL) = .{ .{}, .{} };
var hidden: [2][SL.backbone]f32 = undefined;
var rows: [2][SL.backbone]f32 = undefined;
var scratch: [gen.CODEBOOKS * SL.backbone]f32 = undefined;
var pcm_frame: [8192]f32 = undefined;
const MAX_SAMPLES = 24_000 * 30;
var pcm: [2][MAX_SAMPLES]i16 = undefined;
var pcm_n: [2]usize = .{ 0, 0 };

/// The GPU's depthformer, each call checked against the CPU's on the same
/// input (the GPU's hidden state, the GPU side's codes so far).
const Checked = struct {
    dev: *any_audio.Depth(AUDIO_CAP),
    src: gguf.Source,
    worst: f32 = 0,

    pub fn projectState(self: *Checked, h: []const f32) !void {
        try gen.projectState(AUDIO_CAP, SL, self.src, &audio_index, &speech_plan, &depth_check, h, .{});
        try self.dev.projectState(h);
    }

    pub fn codePass(self: *Checked, codes: *const [gen.CODEBOOKS]i32) ![]const f32 {
        try gen.codePass(AUDIO_CAP, SL, self.src, &audio_index, &speech_plan, &depth_check, codes, .{});
        const got = try self.dev.codePass(codes);
        const n = gen.CODEBOOKS * speech_plan.vocabulary;
        var scale: f32 = 0;
        var diff: f32 = 0;
        for (depth_check.logits[0..n], got[0..n]) |a, b| {
            scale = @max(scale, @abs(a));
            diff = @max(diff, @abs(a - b));
        }
        self.worst = @max(self.worst, diff / @max(scale, 1e-6));
        return got;
    }
};

fn keep(side: usize, codes: *const [gen.CODEBOOKS]i32, src: gguf.Source) void {
    const n = gen.decode(AUDIO_CAP, SL, src, &audio_index, &speech_plan, &codec_states[side], &codec_work, codes, &pcm_frame, .{}) catch |e| {
        out("decode: {s}\n", .{@errorName(e)});
        return;
    };
    put(side, pcm_frame[0..n]);
}

fn put(side: usize, samples: []const f32) void {
    for (samples) |s| {
        if (pcm_n[side] == MAX_SAMPLES) return;
        pcm[side][pcm_n[side]] = @intFromFloat(std.math.clamp(s, -1.0, 1.0) * 32767.0);
        pcm_n[side] += 1;
    }
}

fn writeWav(path: [*:0]const u8, samples: []const i16) void {
    const fd: isize = @bitCast(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644));
    if (fd < 0) return out("cannot write {s}\n", .{std.mem.span(path)});
    defer _ = linux.close(@intCast(fd));
    const bytes: u32 = @intCast(samples.len * 2);
    var h: [44]u8 = undefined;
    @memcpy(h[0..4], "RIFF");
    std.mem.writeInt(u32, h[4..8], 36 + bytes, .little);
    @memcpy(h[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, h[16..20], 16, .little);
    std.mem.writeInt(u16, h[20..22], 1, .little);
    std.mem.writeInt(u16, h[22..24], 1, .little);
    std.mem.writeInt(u32, h[24..28], gen.SAMPLE_RATE, .little);
    std.mem.writeInt(u32, h[28..32], gen.SAMPLE_RATE * 2, .little);
    std.mem.writeInt(u16, h[32..34], 2, .little);
    std.mem.writeInt(u16, h[34..36], 16, .little);
    @memcpy(h[36..40], "data");
    std.mem.writeInt(u32, h[40..44], bytes, .little);
    _ = linux.write(@intCast(fd), &h, h.len);
    const raw = std.mem.sliceAsBytes(samples);
    _ = linux.write(@intCast(fd), raw.ptr, raw.len);
}

fn worstOf(a: []const f32, b: []const f32) f32 {
    var scale: f32 = 0;
    var diff: f32 = 0;
    for (a, b) |x, y| {
        scale = @max(scale, @abs(x));
        diff = @max(diff, @abs(x - y));
    }
    return diff / @max(scale, 1e-6);
}

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    const environ = init.minimal.environ.block.slice;
    if (argv.len < 4) {
        out("usage: speechbench <voice.gguf> <voice-mmproj.gguf> <text> [out-prefix]\n", .{});
        linux.exit(2);
    }
    const memory = Memory{ .bytes = mapFile(argv[1]) };
    const src = memory.source();
    const audio_memory = Memory{ .bytes = mapFile(argv[2]) };
    const asrc = audio_memory.source();
    const text = std.mem.span(argv[3]);
    const prefix: []const u8 = if (argv.len > 4) std.mem.span(argv[4]) else "speech";
    const seed = std.fmt.parseInt(u32, env(environ, "SB_SEED") orelse "4242", 10) catch 4242;
    const voice = env(environ, "SB_VOICE") orelse "female";
    const max_frames = std.fmt.parseInt(usize, env(environ, "SB_FRAMES") orelse "160", 10) catch 160;

    gguf.parse(CAP, src, &index) catch |e| return fail("gguf", e);
    lfm3.build(CAP, src, &index, &plan) catch |e| return fail("plan", e);
    vocabulary.build(src, index.summary.tokenizer_tokens) catch |e| return fail("vocabulary", e);
    merges.build(src, index.summary.tokenizer_merges, &vocabulary) catch |e| return fail("merges", e);
    specials.build(src, index.summary.tokenizer_token_types, &vocabulary) catch |e| return fail("specials", e);
    gguf.parse(AUDIO_CAP, asrc, &audio_index) catch |e| return fail("mmproj gguf", e);
    gen.build(AUDIO_CAP, asrc, &audio_index, &speech_plan) catch |e| return fail("speech plan", e);

    var prompt_buf: [4096]u8 = undefined;
    const prompt_text = std.fmt.bufPrint(&prompt_buf, "<|startoftext|><|im_start|>system\nPerform TTS in American English using a {s} voice.<|im_end|>\n" ++
        "<|im_start|>user\n{s}<|im_end|>\n<|im_start|>assistant\n<|audio_start|>", .{ voice, text }) catch linux.exit(2);
    const count = tokenizer.encode(src, &vocabulary, &merges, &specials, prompt_text, true, &tokens) catch |e| return fail("encode", e);
    out("prompt: {d} tokens; seed {d}; {s} voice\n", .{ count, seed, voice });

    const ring = mapMemory(dxg.gpu.RING_BYTES);
    g.open(.{ .name = "zpm-speechbench" }) catch |e| return fail("open", e);
    ch.open(&g, ring, .{ .name = "zpm-speechbench" }) catch |e| return fail("channel", e);
    sys.init(&g, &ch, mapMemory(512 << 20));
    vram.init(&g, &ch);
    const d = gpu.nvidia_device.over(&adapter, sys.device(), sys.device(), gpu.nvidia_device.rtx5070(8 << 30));
    adapter.gpu_only = vram.device();

    const split = std.fmt.parseInt(usize, env(environ, "SB_SPLIT") orelse "0", 10) catch 0;
    const im_start = vocabulary.lookup(src, "<|im_start|>") orelse return fail("tokens", error.MissingToken);
    var b = Backend.init(d, &plan, &index, src, .{ .import = false, .clock = nowNs, .max_batch = 64 }, &work) catch |e| return fail("backend init", e);
    var depth = any_audio.Depth(AUDIO_CAP).init(d, &speech_plan, &audio_index, asrc, .{ .import = false }, &work) catch |e| return fail("depth init", e);
    var checked = Checked{ .dev = &depth, .src = asrc };
    var codec_gpu: ?any_codec.Codec(AUDIO_CAP) = null;
    if (std.mem.eql(u8, env(environ, "SB_CODEC") orelse "", "gpu")) {
        codec_gpu = any_codec.Codec(AUDIO_CAP).init(d, &speech_plan, &audio_index, asrc, .{ .import = false }, &work) catch |e| return fail("codec init", e);
        codec_gpu.?.reset(SL, &codec_states[1]);
        out("the GPU side's codec on the GPU\n", .{});
    }
    out("set up\n", .{});

    var gc = b.newCache(LIMITS.context) catch |e| return fail("cache", e);
    const kv = mapMemory((executor.requiredKvElements(&plan, LIMITS.context) catch linux.exit(1)) * 2);
    const conv = mapMemory((executor.requiredConvElements(&plan) catch linux.exit(1)) * 4);
    var cc = executor.Cache{
        .kv = @as([*]u16, @ptrCast(kv.ptr))[0 .. kv.len / 2],
        .conv = @as([*]f32, @ptrCast(@alignCast(conv.ptr)))[0 .. conv.len / 4],
        .context = LIMITS.context,
    };
    cc.reset();

    // The prompt: the CPU's in its batches (16 at most), the GPU's whole.
    const p = tokens[0..count];
    var at: usize = 0;
    while (at + LIMITS.batch < p.len) : (at += LIMITS.batch) {
        _ = executor.forwardInput(CAP, LIMITS, src, &index, &plan, &unpacked, &cpu_work, &cc, .{ .tokens = p[at .. at + LIMITS.batch] }, .none, .{}) catch |e| return fail("cpu prompt", e);
    }
    _ = executor.forwardInput(CAP, LIMITS, src, &index, &plan, &unpacked, &cpu_work, &cc, .{ .tokens = p[at..] }, .hidden, .{}) catch |e| return fail("cpu prompt", e);
    @memcpy(&hidden[0], cpu_work.normalized[0..plan.hidden_size]);
    if (split == 0) {
        _ = b.forward(&gc, .{ .tokens = p }, .hidden) catch |e| return fail("gpu prompt", e);
    } else {
        var from: usize = 0;
        var pieces: usize = 0;
        while (from < p.len) {
            var end = @min(p.len, from + split);
            for (p[from + 1 .. end], from + 1..) |t, i| if (t == im_start) {
                end = i;
                break;
            };
            _ = b.forward(&gc, .{ .tokens = p[from..end] }, if (end == p.len) .hidden else .none) catch |e| return fail("gpu prompt", e);
            pieces += 1;
            from = end;
        }
        out("the GPU read the prompt in {d} pieces\n", .{pieces});
    }
    @memcpy(&hidden[1], b.hidden()[0..plan.hidden_size]);

    const sampling = gen.modelSampling(&speech_plan, seed);
    var speakers = [2]gen.Speaker(SL){ gen.Speaker(SL).init(sampling), gen.Speaker(SL).init(sampling) };
    var ended = [2]bool{ false, false };
    var frames = [2]usize{ 0, 0 };
    var parted: ?usize = null;
    var f: usize = 0;
    while (f < max_frames and !(ended[0] and ended[1])) : (f += 1) {
        const hd = worstOf(&hidden[0], &hidden[1]);
        var made: [2]gen.Frame = undefined;
        if (!ended[0]) {
            made[0] = speakers[0].frame(AUDIO_CAP, asrc, &audio_index, &speech_plan, &depth_cpu, &hidden[0], .{}) catch |e| return fail("cpu frame", e);
        }
        checked.worst = 0;
        if (!ended[1]) {
            made[1] = speakers[1].frameOn(&checked, &speech_plan, &hidden[1]) catch |e| return fail("gpu frame", e);
        }
        const same = !ended[0] and !ended[1] and std.mem.eql(i32, &made[0].codes, &made[1].codes) and made[0].end == made[1].end;
        if (!same and parted == null) parted = f;
        out("frame {d:3}: hidden within {e}, depth (GPU vs CPU on the GPU's state) within {e}, codes {s}{s}{s}\n", .{
            f,                                                   hd, checked.worst,
            if (same) "the same" else "DIFFER",
            if (!ended[0] and made[0].end) ", CPU ends" else "", if (!ended[1] and made[1].end) ", GPU ends" else "",
        });
        for (0..2) |side| {
            if (ended[side]) continue;
            if (made[side].end) {
                ended[side] = true;
                const tail = gen.finish(SL, &codec_states[side], &pcm_frame) catch 0;
                put(side, pcm_frame[0..tail]);
                continue;
            }
            frames[side] += 1;
            if (side == 1 and codec_gpu != null) {
                const n = codec_gpu.?.decode(SL, &codec_states[1], &made[1].codes, &pcm_frame) catch |e| return fail("gpu codec", e);
                put(1, pcm_frame[0..n]);
            } else keep(side, &made[side].codes, asrc);
            gen.feedback(AUDIO_CAP, asrc, &audio_index, &speech_plan, &made[side].codes, &rows[side], &scratch) catch |e| return fail("feedback", e);
        }
        if (!ended[0]) {
            _ = executor.forwardInput(CAP, LIMITS, src, &index, &plan, &unpacked, &cpu_work, &cc, .{ .embeddings = &rows[0] }, .hidden, .{}) catch |e| return fail("cpu step", e);
            @memcpy(&hidden[0], cpu_work.normalized[0..plan.hidden_size]);
        }
        if (!ended[1]) {
            _ = b.forward(&gc, .{ .embeddings = &rows[1] }, .hidden) catch |e| return fail("gpu step", e);
            @memcpy(&hidden[1], b.hidden()[0..plan.hidden_size]);
        }
    }
    if (parted) |k| out("the codes part at frame {d}\n", .{k}) else out("the codes agree on every frame\n", .{});
    out("frames: the CPU {d}, the GPU {d}\n", .{ frames[0], frames[1] });
    var name: [512]u8 = undefined;
    const names = [2][]const u8{ "cpu", "gpu" };
    for (0..2) |side| {
        const path = std.fmt.bufPrint(name[0 .. name.len - 1], "{s}-{s}.wav", .{ prefix, names[side] }) catch continue;
        name[path.len] = 0;
        writeWav(@ptrCast(path.ptr), pcm[side][0..pcm_n[side]]);
        out("wrote {s} ({d} ms)\n", .{ path, pcm_n[side] * 1000 / gen.SAMPLE_RATE });
    }
}

fn fail(what: []const u8, e: anyerror) void {
    out("{s}: {s}\n", .{ what, @errorName(e) });
    linux.exit(1);
}
