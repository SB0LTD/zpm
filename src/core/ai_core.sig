//! @zpm/ai-core — portable, allocation-free AI runtime primitives.
//!
//! This package owns no files, threads, accelerators, or heap. Model formats,
//! kernels, and OS runtimes receive caller-provided storage and a device
//! interface. The same code therefore runs in hosted tools and freestanding
//! SB0 without compatibility shims.

pub const CapacityError = error{
    InvalidAlignment,
    CapacityExhausted,
    ArithmeticOverflow,
    InvalidShape,
    InvalidStorage,
    InvalidHandle,
    StaleHandle,
    ReferenceOverflow,
    SharedPage,
    InvalidResource,
    InvalidScenario,
};

pub const Arena = struct {
    storage: []u8,
    used: usize = 0,
    high_water: usize = 0,

    pub fn init(storage: []u8) Arena { return .{ .storage = storage }; }
    pub fn mark(self: *const Arena) usize { return self.used; }
    pub fn rewind(self: *Arena, checkpoint: usize) void { if (checkpoint <= self.used) self.used = checkpoint; }
    pub fn remaining(self: *const Arena) usize { return self.storage.len - self.used; }

    pub fn allocate(self: *Arena, size: usize, alignment: usize) CapacityError![]u8 {
        if (alignment == 0 or (alignment & (alignment - 1)) != 0) return error.InvalidAlignment;
        const base = @intFromPtr(self.storage.ptr);
        const current = base +% self.used;
        if (current < base) return error.ArithmeticOverflow;
        const added = current +% (alignment - 1);
        if (added < current) return error.ArithmeticOverflow;
        const aligned = added & ~(alignment - 1);
        const start = aligned - base;
        const end = start +% size;
        if (end < start) return error.ArithmeticOverflow;
        if (end > self.storage.len) return error.CapacityExhausted;
        self.used = end;
        self.high_water = @max(self.high_water, end);
        return self.storage[start..end];
    }
};

pub const DType = enum(u8) {
    f32,
    f16,
    bf16,
    q8_0,
    q4_k,
    q6_k,

    pub fn blockElements(self: DType) usize { return switch (self) { .f32, .f16, .bf16 => 1, .q8_0 => 32, .q4_k, .q6_k => 256 }; }
    pub fn blockBytes(self: DType) usize { return switch (self) { .f32 => 4, .f16, .bf16 => 2, .q8_0 => 34, .q4_k => 144, .q6_k => 210 }; }
};

pub const Shape = struct {
    rank: u8,
    dims: [4]usize = @splat(1),

    pub fn elements(self: Shape) CapacityError!usize {
        if (self.rank == 0 or self.rank > self.dims.len) return error.InvalidShape;
        var result: usize = 1;
        for (self.dims[0..self.rank]) |dimension| {
            if (dimension == 0) return error.InvalidShape;
            const next = result *% dimension;
            if (next / dimension != result) return error.ArithmeticOverflow;
            result = next;
        }
        return result;
    }
};

pub const TensorView = struct {
    bytes: []const u8,
    dtype: DType,
    shape: Shape,

    pub fn validate(self: TensorView) CapacityError!void {
        const required = try storageBytes(self.dtype, try self.shape.elements());
        if (self.bytes.len < required) return error.InvalidStorage;
    }
};

pub fn storageBytes(dtype: DType, elements: usize) CapacityError!usize {
    const blocks = (elements +% (dtype.blockElements() - 1)) / dtype.blockElements();
    if (blocks == 0 and elements != 0) return error.ArithmeticOverflow;
    const bytes = blocks *% dtype.blockBytes();
    if (blocks != 0 and bytes / blocks != dtype.blockBytes()) return error.ArithmeticOverflow;
    return bytes;
}

pub const JobKind = enum(u8) { audio_encode, vision_encode, embedding, prefill, decode, memory_update, tts };
pub const Priority = enum(u8) { safety, interactive, ambient, background };
pub const ScratchClass = enum(u8) { tiny, audio, token, vision, synthesis };

pub const JobInput = struct {
    kind: JobKind,
    priority: Priority,
    deadline_tick: u64,
    budget_ticks: u64,
    maximum_tokens: u32 = 0,
    scratch: ScratchClass,
    adapter_id: u16 = 0,
    capability: u32,
    cancellation_token: u32,
    payload_id: u64,
};

pub const Job = struct {
    id: u64 = 0,
    input: JobInput = .{
        .kind = .audio_encode,
        .priority = .safety,
        .deadline_tick = 0,
        .budget_ticks = 0,
        .scratch = .tiny,
        .capability = 0,
        .cancellation_token = 0,
        .payload_id = 0,
    },
};

pub const SchedulerStats = struct { submitted: u64 = 0, completed: u64 = 0, cancelled: u64 = 0, rejected: u64 = 0 };

pub fn Scheduler(comptime capacity: usize) type {
    if (capacity == 0) @compileError("scheduler capacity must be non-zero");
    return struct {
        const Self = @This();
        const Slot = struct { active: bool = false, job: Job = .{} };
        slots: [capacity]Slot = @splat(.{}),
        count: usize = 0,
        next_id: u64 = 0,
        stats: SchedulerStats = .{},

        pub fn staticBytes() usize { return @sizeOf(Self); }

        pub fn submit(self: *Self, input: JobInput) CapacityError!u64 {
            if (self.count == capacity) { self.stats.rejected +|= 1; return error.CapacityExhausted; }
            for (&self.slots) |*slot| if (!slot.active) {
                if (self.next_id == 0) self.next_id = 1;
                const id = self.next_id;
                self.next_id +%= 1;
                if (self.next_id == 0) self.next_id = 1;
                slot.* = .{ .active = true, .job = .{ .id = id, .input = input } };
                self.count += 1;
                self.stats.submitted +|= 1;
                return id;
            };
            unreachable;
        }

        /// Strict priority bands, then earliest deadline, then monotonic ID.
        /// A zero deadline is treated as infinity.
        pub fn takeNext(self: *Self) ?Job {
            var selected: ?usize = null;
            for (self.slots, 0..) |slot, index| {
                if (!slot.active) continue;
                if (selected == null or jobLess(slot.job, self.slots[selected.?].job)) selected = index;
            }
            const index = selected orelse return null;
            const job = self.slots[index].job;
            self.slots[index].active = false;
            self.count -= 1;
            self.stats.completed +|= 1;
            return job;
        }

        pub fn cancel(self: *Self, token: u32) usize {
            if (token == 0) return 0;
            var removed: usize = 0;
            for (&self.slots) |*slot| if (slot.active and slot.job.input.cancellation_token == token) {
                slot.active = false;
                self.count -= 1;
                removed += 1;
            };
            self.stats.cancelled +|= removed;
            return removed;
        }
    };
}

fn jobLess(left: Job, right: Job) bool {
    if (@intFromEnum(left.input.priority) != @intFromEnum(right.input.priority))
        return @intFromEnum(left.input.priority) < @intFromEnum(right.input.priority);
    const left_deadline = if (left.input.deadline_tick == 0) ~@as(u64, 0) else left.input.deadline_tick;
    const right_deadline = if (right.input.deadline_tick == 0) ~@as(u64, 0) else right.input.deadline_tick;
    return left_deadline < right_deadline or (left_deadline == right_deadline and left.id < right.id);
}

pub const MatvecRequest = struct {
    output: []f32,
    weights: TensorView,
    input: []const f32,
    rows: usize,
    columns: usize,
};
pub const BackendError = error{ Unsupported, InvalidRequest, DeviceFailure, DeadlineExceeded };
pub const MatvecFn = *const fn (context: *anyopaque, request: MatvecRequest) BackendError!void;
pub const SupportsFn = *const fn (context: *const anyopaque, dtype: DType) bool;

pub const DeviceBackend = struct {
    context: *anyopaque,
    matvec_fn: MatvecFn,
    supports_fn: SupportsFn,

    pub fn matvec(self: DeviceBackend, request: MatvecRequest) BackendError!void {
        if (request.rows == 0 or request.columns == 0 or request.output.len < request.rows or
            request.input.len < request.columns) return error.InvalidRequest;
        try request.weights.validate();
        if (!self.supports_fn(self.context, request.weights.dtype)) return error.Unsupported;
        return self.matvec_fn(self.context, request);
    }
};

pub const PageHandle = packed struct(u32) {
    index: u16 = 0xffff,
    generation: u16 = 0,
    pub fn valid(self: PageHandle) bool { return self.index != 0xffff and self.generation != 0; }
};

pub fn PagePool(comptime page_count: usize, comptime page_bytes: usize) type {
    if (page_count == 0 or page_count > 0xfffe) @compileError("invalid page count");
    if (page_bytes == 0) @compileError("page size must be non-zero");
    return struct {
        const Self = @This();
        pub const Meta = struct {
            used: bool = false,
            generation: u16 = 0,
            references: u16 = 0,
            used_bytes: u32 = 0,
            prefix_digest: [16]u8 = @splat(0),
        };
        pages: [page_count][page_bytes]u8 = @splat(@splat(0)),
        metadata: [page_count]Meta = @splat(.{}),
        active_pages: usize = 0,
        high_water_pages: usize = 0,

        pub fn staticBytes() usize { return @sizeOf(Self); }

        pub fn allocate(self: *Self) CapacityError!PageHandle {
            for (&self.metadata, 0..) |*meta, index| if (!meta.used) {
                if (meta.generation == 0) meta.generation = 1;
                meta.used = true;
                meta.references = 1;
                meta.used_bytes = 0;
                meta.prefix_digest = @splat(0);
                @memset(&self.pages[index], 0);
                self.active_pages += 1;
                self.high_water_pages = @max(self.high_water_pages, self.active_pages);
                return .{ .index = @intCast(index), .generation = meta.generation };
            };
            return error.CapacityExhausted;
        }

        pub fn retain(self: *Self, handle: PageHandle) CapacityError!void {
            const meta = try self.resolve(handle);
            if (meta.references == 0xffff) return error.ReferenceOverflow;
            meta.references += 1;
        }

        pub fn release(self: *Self, handle: PageHandle) CapacityError!void {
            const meta = try self.resolve(handle);
            meta.references -= 1;
            if (meta.references == 0) {
                meta.used = false;
                meta.used_bytes = 0;
                meta.prefix_digest = @splat(0);
                meta.generation +%= 1;
                if (meta.generation == 0) meta.generation = 1;
                self.active_pages -= 1;
            }
        }

        pub fn readable(self: *const Self, handle: PageHandle) CapacityError![]const u8 {
            const index = try self.resolveIndex(handle);
            return self.pages[index][0..self.metadata[index].used_bytes];
        }

        pub fn writable(self: *Self, handle: PageHandle) CapacityError![]u8 {
            const meta = try self.resolve(handle);
            if (meta.references != 1) return error.SharedPage;
            return &self.pages[handle.index];
        }

        pub fn setUsed(self: *Self, handle: PageHandle, used: usize, digest: [16]u8) CapacityError!void {
            if (used > page_bytes) return error.InvalidStorage;
            const meta = try self.resolve(handle);
            if (meta.references != 1) return error.SharedPage;
            meta.used_bytes = @intCast(used);
            meta.prefix_digest = digest;
        }

        /// Return an exclusively writable page, copying only live bytes when
        /// the input is shared. The old reference is released atomically after
        /// the new page has been fully initialized.
        pub fn ensureUnique(self: *Self, handle: PageHandle) CapacityError!PageHandle {
            const old_index = try self.resolveIndex(handle);
            if (self.metadata[old_index].references == 1) return handle;
            const replacement = try self.allocate();
            const used = self.metadata[old_index].used_bytes;
            @memcpy(self.pages[replacement.index][0..used], self.pages[old_index][0..used]);
            self.metadata[replacement.index].used_bytes = used;
            self.metadata[replacement.index].prefix_digest = self.metadata[old_index].prefix_digest;
            try self.release(handle);
            return replacement;
        }

        fn resolve(self: *Self, handle: PageHandle) CapacityError!*Meta {
            const index = try self.resolveIndex(handle);
            return &self.metadata[index];
        }
        fn resolveIndex(self: *const Self, handle: PageHandle) CapacityError!usize {
            if (!handle.valid() or handle.index >= page_count) return error.InvalidHandle;
            const meta = &self.metadata[handle.index];
            if (!meta.used or meta.generation != handle.generation) return error.StaleHandle;
            return handle.index;
        }
    };
}

/// A resource is either resident for the full runtime or live only in the
/// declared execution phases. Equal non-zero identities describe the same
/// immutable storage and are counted once, which makes backbone/projector
/// sharing explicit instead of relying on optimistic accounting.
pub const PhaseMask = u16;
pub const Resource = struct {
    identity: [16]u8,
    bytes: u64,
    phases: PhaseMask = 0,
    resident: bool = false,
};

pub const CapacityResult = struct {
    admissible: bool,
    peak_bytes: u64,
    peak_scenario: usize,
    capacity_bytes: u64,
};

/// Fixed-capacity worst-case memory planner.
///
/// A scenario is a bitset of phases that may overlap (for example ambient +
/// ASR + TTS during barge-in). For scenario `s`, exact accounted memory is:
///
///   base + sum(unique resident resources)
///        + sum(unique transient resources r where r.phases & s != 0)
///
/// Evaluating every declared overlap scenario therefore proves admission for
/// that scenario set; it makes no independence assumption between modalities.
pub fn CapacityPlanner(comptime resource_capacity: usize, comptime scenario_capacity: usize) type {
    if (resource_capacity == 0 or scenario_capacity == 0)
        @compileError("capacity planner dimensions must be non-zero");
    return struct {
        const Self = @This();
        resources: [resource_capacity]Resource = undefined,
        scenarios: [scenario_capacity]PhaseMask = @splat(0),
        resource_count: usize = 0,
        scenario_count: usize = 0,
        capacity_bytes: u64,
        base_bytes: u64,

        pub fn init(capacity_bytes: u64, base_bytes: u64) CapacityError!Self {
            if (capacity_bytes == 0 or base_bytes > capacity_bytes) return error.InvalidResource;
            return .{ .capacity_bytes = capacity_bytes, .base_bytes = base_bytes };
        }

        pub fn addResource(self: *Self, resource: Resource) CapacityError!void {
            if (resource.bytes == 0 or identityZero(resource.identity) or
                (!resource.resident and resource.phases == 0)) return error.InvalidResource;
            for (self.resources[0..self.resource_count]) |existing| {
                if (!identityEqual(existing.identity, resource.identity)) continue;
                if (existing.bytes != resource.bytes or existing.resident != resource.resident or
                    existing.phases != resource.phases) return error.InvalidResource;
                // An identical declaration is idempotent and remains one map.
                return;
            }
            if (self.resource_count == resource_capacity) return error.CapacityExhausted;
            self.resources[self.resource_count] = resource;
            self.resource_count += 1;
        }

        pub fn addScenario(self: *Self, phases: PhaseMask) CapacityError!void {
            if (phases == 0) return error.InvalidScenario;
            for (self.scenarios[0..self.scenario_count]) |existing|
                if (existing == phases) return;
            if (self.scenario_count == scenario_capacity) return error.CapacityExhausted;
            self.scenarios[self.scenario_count] = phases;
            self.scenario_count += 1;
        }

        pub fn evaluate(self: *const Self) CapacityError!CapacityResult {
            if (self.scenario_count == 0) return error.InvalidScenario;
            var peak = self.base_bytes;
            var peak_scenario: usize = 0;
            for (self.scenarios[0..self.scenario_count], 0..) |scenario, scenario_index| {
                var total = self.base_bytes;
                for (self.resources[0..self.resource_count]) |resource| {
                    if (!resource.resident and resource.phases & scenario == 0) continue;
                    total = try checkedAddU64(total, resource.bytes);
                }
                if (total > peak) {
                    peak = total;
                    peak_scenario = scenario_index;
                }
            }
            return .{
                .admissible = peak <= self.capacity_bytes,
                .peak_bytes = peak,
                .peak_scenario = peak_scenario,
                .capacity_bytes = self.capacity_bytes,
            };
        }
    };
}

fn checkedAddU64(left: u64, right: u64) CapacityError!u64 {
    const result = left +% right;
    if (result < left) return error.ArithmeticOverflow;
    return result;
}

fn identityZero(identity: [16]u8) bool {
    for (identity) |byte| if (byte != 0) return false;
    return true;
}

fn identityEqual(left: [16]u8, right: [16]u8) bool {
    for (left, right) |a, b| if (a != b) return false;
    return true;
}


test "arena alignment capacity and rewind are exact" {
    var storage: [64]u8 = undefined;
    var arena = Arena.init(&storage);
    _ = try arena.allocate(3, 1);
    const checkpoint = arena.mark();
    const aligned = try arena.allocate(8, 16);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) & 0xf);
    if (!(arena.used >= 11 and arena.used <= 24)) return error.TestUnexpectedResult;
    arena.rewind(checkpoint);
    if (arena.used != 3) return error.TestUnexpectedResult;
    if (!(arena.high_water >= 11 and arena.high_water <= 24)) return error.TestUnexpectedResult;
    try testing.expectError(error.InvalidAlignment, arena.allocate(1, 3));
}

test "tensor storage is checked for dense and blocked formats" {
    try testing.expectEqual(@as(usize, 64), try storageBytes(.f32, 16));
    try testing.expectEqual(@as(usize, 34), try storageBytes(.q8_0, 31));
    try testing.expectEqual(@as(usize, 288), try storageBytes(.q4_k, 257));
    try testing.expectEqual(@as(usize, 420), try storageBytes(.q6_k, 257));
    const ten = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const too_short = TensorView{ .bytes = &ten, .dtype = .f32, .shape = .{ .rank = 2, .dims = .{ 2, 2, 1, 1 } } };
    try testing.expectError(error.InvalidStorage, too_short.validate());
}

fn testJob(priority: Priority, deadline: u64, token: u32) JobInput {
    return .{ .kind = .decode, .priority = priority, .deadline_tick = deadline, .budget_ticks = 10, .scratch = .token, .capability = 1, .cancellation_token = token, .payload_id = deadline };
}

test "scheduler is priority-banded EDF with deterministic ties" {
    var scheduler = Scheduler(4){};
    const first = try scheduler.submit(testJob(.interactive, 20, 1));
    const second = try scheduler.submit(testJob(.interactive, 10, 2));
    const safety = try scheduler.submit(testJob(.safety, 100, 3));
    try testing.expectEqual(safety, scheduler.takeNext().?.id);
    try testing.expectEqual(second, scheduler.takeNext().?.id);
    try testing.expectEqual(first, scheduler.takeNext().?.id);
}

test "scheduler cancellation is bounded and token scoped" {
    var scheduler = Scheduler(3){};
    _ = try scheduler.submit(testJob(.ambient, 1, 7));
    _ = try scheduler.submit(testJob(.ambient, 2, 7));
    _ = try scheduler.submit(testJob(.ambient, 3, 8));
    try testing.expectEqual(@as(usize, 2), scheduler.cancel(7));
    if (scheduler.count != 1) return error.TestUnexpectedResult;
}

test "page sharing uses copy on write and rejects stale handles" {
    var pool = PagePool(3, 16){};
    const original = try pool.allocate();
    const bytes = try pool.writable(original);
    bytes[0..4].* = .{ 1, 2, 3, 4 };
    try pool.setUsed(original, 4, @splat(9));
    try pool.retain(original);
    try testing.expectError(error.SharedPage, pool.writable(original));
    const branch = try pool.ensureUnique(original);
    if (!(branch.index != original.index)) return error.TestUnexpectedResult;
    (try pool.writable(branch))[0] = 8;
    try testing.expectEqual(@as(u8, 1), (try pool.readable(original))[0]);
    try testing.expectEqual(@as(u8, 8), (try pool.readable(branch))[0]);
    try pool.release(original);
    try testing.expectError(error.StaleHandle, pool.readable(original));
}

fn testResource(id: u8, bytes: u64, phases: PhaseMask, resident: bool) Resource {
    var identity: [16]u8 = @splat(0);
    identity[0] = id;
    return .{ .identity = identity, .bytes = bytes, .phases = phases, .resident = resident };
}

test "capacity planner proves declared full-duplex peak and deduplicates weights" {
    const ambient: PhaseMask = 1 << 0;
    const asr: PhaseMask = 1 << 1;
    const decode: PhaseMask = 1 << 2;
    const tts: PhaseMask = 1 << 3;
    var planner = try CapacityPlanner(8, 4).init(4_000, 400);
    try planner.addResource(testResource(1, 1_000, 0, true));
    try planner.addResource(testResource(1, 1_000, 0, true));
    try planner.addResource(testResource(2, 100, ambient, false));
    try planner.addResource(testResource(3, 600, asr, false));
    try planner.addResource(testResource(4, 700, decode, false));
    try planner.addResource(testResource(5, 500, tts, false));
    try planner.addScenario(ambient | decode);
    try planner.addScenario(ambient | asr | tts);
    const result = try planner.evaluate();
    if (!(result.admissible)) return error.TestUnexpectedResult;
    if (result.peak_bytes != 2_600) return error.TestUnexpectedResult;
    if (result.peak_scenario != 1) return error.TestUnexpectedResult;
}

test "capacity planner rejects unproved or inconsistent declarations" {
    var planner = try CapacityPlanner(2, 1).init(1_000, 100);
    try testing.expectError(error.InvalidScenario, planner.evaluate());
    try testing.expectError(error.InvalidResource, planner.addResource(testResource(1, 10, 0, false)));
    try planner.addResource(testResource(1, 100, 0, true));
    try testing.expectError(error.InvalidResource, planner.addResource(testResource(1, 101, 0, true)));
    try planner.addScenario(1);
    try testing.expect((try planner.evaluate()).admissible);
}
