//! @zpm/agent-runtime — bounded process, authority, and PlanIR primitives.
//!
//! Model output is data, never executable authority.  Plans contain typed
//! operation IDs and resource handles only; capability leases are narrowed,
//! expiring, use-bounded, and cascade-revocable without heap allocation.

const math = @import("sig_math");
const mem = @import("sig_mem");
const testing = @import("sig_testing");

pub const Error = error{
    CapacityExhausted,
    InvalidHandle,
    StaleHandle,
    InvalidTransition,
    InvalidProcess,
    CheckpointTooLarge,
    InvalidLease,
    LeaseExpired,
    LeaseExhausted,
    LeaseRevoked,
    AuthorityDenied,
    DelegationTooDeep,
    RightsExpansion,
    InvalidPlan,
    InvalidOperation,
    InvalidDependency,
    DependencyCycle,
    BudgetExceeded,
    RiskDenied,
    MissingCompensation,
    InvalidArgument,
};

pub const Handle = packed struct(u32) {
    index: u16,
    generation: u16,
};

pub const Resource = struct {
    kind: u16,
    id: u32,

    pub fn eql(left: Resource, right: Resource) bool {
        return left.kind == right.kind and left.id == right.id;
    }
};

pub const DataClass = enum(u8) {
    public,
    personal,
    sensitive,
    secret,
};

pub const Rights = struct {
    operations: u64,
    maximum_data_class: DataClass,
};

pub const LeaseRequest = struct {
    subject: u64,
    resource: Resource,
    rights: Rights,
};

pub const LeaseSpec = struct {
    subject: u64,
    resource: Resource,
    rights: Rights,
    expires_tick: u64,
    uses: u32,
};

pub const AuthorityReceipt = struct {
    ancestors_checked: u8 = 0,
    root_epoch: u32 = 0,
    uses_remaining: u32 = 0,
};

const no_parent = math.maxInt(u16);

pub fn CapabilityTable(comptime capacity: usize, comptime maximum_depth: u8) type {
    if (capacity == 0 or capacity > math.maxInt(u16)) @compileError("invalid capability capacity");
    if (maximum_depth == 0) @compileError("capability delegation depth must be non-zero");

    return struct {
        const Self = @This();
        const Lease = struct {
            subject: u64 = 0,
            resource: Resource = .{ .kind = 0, .id = 0 },
            rights: Rights = .{ .operations = 0, .maximum_data_class = .public },
            expires_tick: u64 = 0,
            uses_remaining: u32 = 0,
            parent_index: u16 = 0,
            parent_generation: u16 = 0,
            root_index: u16 = 0,
            root_generation: u16 = 0,
            captured_root_epoch: u32 = 0,
            depth: u8 = 0,
        };
        const Slot = struct {
            occupied: bool = false,
            // Zero is the cold `.bss` representation. `reserve` activates both
            // sentinels before a handle can become visible.
            generation: u16 = 0,
            revocation_epoch: u32 = 0,
            lease: Lease = .{},
        };

        slots: [capacity]Slot = @splat(.{}),
        active_count: usize = 0,

        pub fn staticBytes() usize {
            return @sizeOf(Self);
        }

        pub fn count(self: *const Self) usize {
            return self.active_count;
        }

        pub fn mintRoot(self: *Self, spec: LeaseSpec) Error!Handle {
            try validateSpec(spec);
            const index = try self.reserve();
            const slot = &self.slots[index];
            const handle = Handle{ .index = @intCast(index), .generation = slot.generation };
            slot.lease = .{
                .subject = spec.subject,
                .resource = spec.resource,
                .rights = spec.rights,
                .expires_tick = spec.expires_tick,
                .uses_remaining = spec.uses,
                .parent_index = no_parent,
                .root_index = handle.index,
                .root_generation = handle.generation,
                .captured_root_epoch = slot.revocation_epoch,
            };
            return handle;
        }

        pub fn delegate(self: *Self, parent: Handle, spec: LeaseSpec, now_tick: u64) Error!Handle {
            try validateSpec(spec);
            _ = try self.validateInternal(parent, null, now_tick);
            const parent_slot = try self.slotConst(parent);
            const parent_lease = parent_slot.lease;
            if (parent_lease.depth >= maximum_depth) return error.DelegationTooDeep;
            if (!spec.resource.eql(parent_lease.resource) or
                (spec.rights.operations & ~parent_lease.rights.operations) != 0 or
                @intFromEnum(spec.rights.maximum_data_class) > @intFromEnum(parent_lease.rights.maximum_data_class) or
                spec.expires_tick > parent_lease.expires_tick or spec.uses > parent_lease.uses_remaining)
                return error.RightsExpansion;

            const index = try self.reserve();
            const slot = &self.slots[index];
            slot.lease = .{
                .subject = spec.subject,
                .resource = spec.resource,
                .rights = spec.rights,
                .expires_tick = spec.expires_tick,
                .uses_remaining = spec.uses,
                .parent_index = parent.index,
                .parent_generation = parent.generation,
                .root_index = parent_lease.root_index,
                .root_generation = parent_lease.root_generation,
                .captured_root_epoch = parent_lease.captured_root_epoch,
                .depth = parent_lease.depth + 1,
            };
            return .{ .index = @intCast(index), .generation = slot.generation };
        }

        pub fn validate(self: *const Self, handle: Handle, request: LeaseRequest, now_tick: u64) Error!AuthorityReceipt {
            return self.validateInternal(handle, request, now_tick);
        }

        /// Validation completes before the use is consumed, so denial is
        /// fail-atomic and cannot drain authority.
        pub fn consume(self: *Self, handle: Handle, request: LeaseRequest, now_tick: u64) Error!AuthorityReceipt {
            var receipt = try self.validateInternal(handle, request, now_tick);
            const slot = try self.slotMutable(handle);
            slot.lease.uses_remaining -= 1;
            receipt.uses_remaining = slot.lease.uses_remaining;
            return receipt;
        }

        /// One bounded write invalidates the root and every descendant.  No
        /// descendant scan is required; validation compares the captured epoch.
        pub fn revokeRoot(self: *Self, root: Handle) Error!void {
            const slot = try self.slotMutable(root);
            if (slot.lease.depth != 0 or slot.lease.root_index != root.index) return error.InvalidLease;
            slot.revocation_epoch +%= 1;
            if (slot.revocation_epoch == 0) slot.revocation_epoch = 1;
        }

        pub fn close(self: *Self, handle: Handle) Error!void {
            const slot = try self.slotMutable(handle);
            slot.occupied = false;
            slot.lease = .{};
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            self.active_count -= 1;
        }

        fn reserve(self: *Self) Error!usize {
            if (self.active_count == capacity) return error.CapacityExhausted;
            for (&self.slots, 0..) |*slot, index| if (!slot.occupied) {
                if (slot.generation == 0) slot.generation = 1;
                if (slot.revocation_epoch == 0) slot.revocation_epoch = 1;
                slot.occupied = true;
                self.active_count += 1;
                return index;
            };
            return error.CapacityExhausted;
        }

        fn slotMutable(self: *Self, handle: Handle) Error!*Slot {
            if (handle.index >= capacity) return error.InvalidHandle;
            const candidate = &self.slots[handle.index];
            if (!candidate.occupied or candidate.generation != handle.generation) return error.StaleHandle;
            return candidate;
        }

        fn slotConst(self: *const Self, handle: Handle) Error!*const Slot {
            if (handle.index >= capacity) return error.InvalidHandle;
            const candidate = &self.slots[handle.index];
            if (!candidate.occupied or candidate.generation != handle.generation) return error.StaleHandle;
            return candidate;
        }

        fn validateInternal(self: *const Self, handle: Handle, request: ?LeaseRequest, now_tick: u64) Error!AuthorityReceipt {
            const leaf = try self.slotConst(handle);
            const lease = leaf.lease;
            if (lease.root_index >= capacity) return error.InvalidLease;
            const root = &self.slots[lease.root_index];
            if (!root.occupied or root.generation != lease.root_generation) return error.LeaseRevoked;
            if (root.revocation_epoch != lease.captured_root_epoch) return error.LeaseRevoked;
            if (now_tick > lease.expires_tick) return error.LeaseExpired;
            if (lease.uses_remaining == 0) return error.LeaseExhausted;
            if (request) |requested| {
                if (requested.subject != lease.subject or !requested.resource.eql(lease.resource) or
                    (requested.rights.operations & ~lease.rights.operations) != 0 or
                    @intFromEnum(requested.rights.maximum_data_class) > @intFromEnum(lease.rights.maximum_data_class))
                    return error.AuthorityDenied;
            }

            var receipt = AuthorityReceipt{ .root_epoch = root.revocation_epoch, .uses_remaining = lease.uses_remaining };
            var current_index = handle.index;
            var current_generation = handle.generation;
            var remaining: u8 = maximum_depth + 1;
            while (true) {
                if (remaining == 0) return error.InvalidLease;
                remaining -= 1;
                const current = try self.slotConst(.{ .index = current_index, .generation = current_generation });
                if (now_tick > current.lease.expires_tick or current.lease.uses_remaining == 0)
                    return if (current.lease.uses_remaining == 0) error.LeaseExhausted else error.LeaseExpired;
                receipt.ancestors_checked +|= 1;
                if (current.lease.parent_index == no_parent) break;
                current_index = current.lease.parent_index;
                current_generation = current.lease.parent_generation;
            }
            return receipt;
        }

        fn validateSpec(spec: LeaseSpec) Error!void {
            if (spec.subject == 0 or spec.resource.kind == 0 or spec.resource.id == 0 or
                spec.rights.operations == 0 or spec.expires_tick == 0 or spec.uses == 0)
                return error.InvalidLease;
        }
    };
}

pub const ProcessState = enum(u8) {
    planned,
    admitted,
    running,
    waiting,
    completed,
    failed,
    cancelled,
};

pub const ProcessView = struct {
    id: u64,
    state: ProcessState,
    plan_digest: [16]u8,
    snapshot_epoch: u64,
    transitions: u32,
    checkpoint_length: usize,
};

pub fn ProcessTable(comptime capacity: usize, comptime checkpoint_capacity: usize) type {
    if (capacity == 0 or capacity > math.maxInt(u16)) @compileError("invalid process capacity");
    return struct {
        const Self = @This();
        const Slot = struct {
            occupied: bool = false,
            generation: u16 = 0,
            id: u64 = 0,
            state: ProcessState = .planned,
            plan_digest: [16]u8 = @splat(0),
            snapshot_epoch: u64 = 0,
            transitions: u32 = 0,
            checkpoint: [checkpoint_capacity]u8 = @splat(0),
            checkpoint_length: usize = 0,
        };

        slots: [capacity]Slot = @splat(.{}),
        next_id: u64 = 0,
        active_count: usize = 0,

        pub fn staticBytes() usize { return @sizeOf(Self); }

        pub fn create(self: *Self, plan_digest: [16]u8, snapshot_epoch: u64) Error!Handle {
            if (snapshot_epoch == 0 or allZero(&plan_digest)) return error.InvalidProcess;
            if (self.active_count == capacity) return error.CapacityExhausted;
            for (&self.slots, 0..) |*slot, index| if (!slot.occupied) {
                if (slot.generation == 0) slot.generation = 1;
                if (self.next_id == 0) self.next_id = 1;
                const generation = slot.generation;
                const id = self.next_id;
                self.next_id +%= 1;
                if (self.next_id == 0) self.next_id = 1;
                slot.* = .{
                    .occupied = true,
                    .generation = generation,
                    .id = id,
                    .plan_digest = plan_digest,
                    .snapshot_epoch = snapshot_epoch,
                };
                self.active_count += 1;
                return .{ .index = @intCast(index), .generation = generation };
            };
            return error.CapacityExhausted;
        }

        pub fn view(self: *const Self, handle: Handle) Error!ProcessView {
            const slot = try self.slotConst(handle);
            return .{
                .id = slot.id,
                .state = slot.state,
                .plan_digest = slot.plan_digest,
                .snapshot_epoch = slot.snapshot_epoch,
                .transitions = slot.transitions,
                .checkpoint_length = slot.checkpoint_length,
            };
        }

        pub fn admit(self: *Self, handle: Handle) Error!void { try self.transition(handle, .admitted); }
        pub fn start(self: *Self, handle: Handle) Error!void { try self.transition(handle, .running); }
        pub fn wait(self: *Self, handle: Handle) Error!void { try self.transition(handle, .waiting); }
        pub fn resumeRunning(self: *Self, handle: Handle) Error!void { try self.transition(handle, .running); }
        pub fn complete(self: *Self, handle: Handle) Error!void { try self.transition(handle, .completed); }
        pub fn fail(self: *Self, handle: Handle) Error!void { try self.transition(handle, .failed); }

        pub fn cancel(self: *Self, handle: Handle) Error!void {
            const slot = try self.slotMutable(handle);
            if (terminal(slot.state)) return error.InvalidTransition;
            slot.state = .cancelled;
            slot.transitions +|= 1;
        }

        pub fn checkpoint(self: *Self, handle: Handle, bytes: []const u8, snapshot_epoch: u64) Error!void {
            if (bytes.len > checkpoint_capacity) return error.CheckpointTooLarge;
            const slot = try self.slotMutable(handle);
            if (slot.state != .running and slot.state != .waiting) return error.InvalidTransition;
            @memset(&slot.checkpoint, 0);
            @memcpy(slot.checkpoint[0..bytes.len], bytes);
            slot.checkpoint_length = bytes.len;
            slot.snapshot_epoch = snapshot_epoch;
        }

        pub fn recover(self: *Self, handle: Handle, output: []u8) Error!usize {
            const slot = try self.slotMutable(handle);
            if (slot.state != .waiting) return error.InvalidTransition;
            if (output.len < slot.checkpoint_length) return error.CheckpointTooLarge;
            @memcpy(output[0..slot.checkpoint_length], slot.checkpoint[0..slot.checkpoint_length]);
            slot.state = .running;
            slot.transitions +|= 1;
            return slot.checkpoint_length;
        }

        pub fn release(self: *Self, handle: Handle) Error!void {
            const slot = try self.slotMutable(handle);
            if (!terminal(slot.state)) return error.InvalidTransition;
            const next_generation = if (slot.generation == math.maxInt(u16)) 1 else slot.generation + 1;
            slot.* = .{ .generation = next_generation };
            self.active_count -= 1;
        }

        fn transition(self: *Self, handle: Handle, next: ProcessState) Error!void {
            const slot = try self.slotMutable(handle);
            const valid = switch (slot.state) {
                .planned => next == .admitted or next == .failed,
                .admitted => next == .running or next == .failed,
                .running => next == .waiting or next == .completed or next == .failed,
                .waiting => next == .running or next == .failed,
                .completed, .failed, .cancelled => false,
            };
            if (!valid) return error.InvalidTransition;
            slot.state = next;
            slot.transitions +|= 1;
        }

        fn slotMutable(self: *Self, handle: Handle) Error!*Slot {
            if (handle.index >= capacity) return error.InvalidHandle;
            const slot_value = &self.slots[handle.index];
            if (!slot_value.occupied or slot_value.generation != handle.generation) return error.StaleHandle;
            return slot_value;
        }

        fn slotConst(self: *const Self, handle: Handle) Error!*const Slot {
            if (handle.index >= capacity) return error.InvalidHandle;
            const slot_value = &self.slots[handle.index];
            if (!slot_value.occupied or slot_value.generation != handle.generation) return error.StaleHandle;
            return slot_value;
        }
    };
}

fn terminal(state: ProcessState) bool {
    return state == .completed or state == .failed or state == .cancelled;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

pub const Risk = enum(u8) { read_only, reversible, consequential, critical };

pub const OperationSchema = struct {
    id: u8,
    resource_kind: u16,
    maximum_risk: Risk,
    maximum_argument_bytes: u8,
    requires_compensation: bool = false,
};

pub fn OperationRegistry(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 64) @compileError("operation registry capacity must be 1..64");
    return struct {
        const Self = @This();
        entries: [capacity]OperationSchema = @splat(.{ .id = 0, .resource_kind = 0, .maximum_risk = .read_only, .maximum_argument_bytes = 0 }),
        count: usize = 0,

        pub fn register(self: *Self, schema: OperationSchema) Error!void {
            if (schema.id == 0 or schema.id >= 64 or schema.resource_kind == 0) return error.InvalidOperation;
            for (self.entries[0..self.count]) |entry| if (entry.id == schema.id) return error.InvalidOperation;
            if (self.count == capacity) return error.CapacityExhausted;
            self.entries[self.count] = schema;
            self.count += 1;
        }

        pub fn find(self: *const Self, id: u8) ?OperationSchema {
            for (self.entries[0..self.count]) |entry| if (entry.id == id) return entry;
            return null;
        }
    };
}

pub const PlanNode = struct {
    operation_id: u8 = 0,
    resource: Resource = .{ .kind = 0, .id = 0 },
    lease: Handle = .{ .index = 0, .generation = 0 },
    dependencies: u64 = 0,
    arguments: [64]u8 = @splat(0),
    argument_length: u8 = 0,
    precondition_digest: [16]u8 = @splat(0),
    postcondition_digest: [16]u8 = @splat(0),
    evidence_id: u64 = 0,
    estimated_cost: u32 = 0,
    timeout_ticks: u32 = 0,
    retry_limit: u8 = 0,
    risk: Risk = .read_only,
    reversible: bool = false,
    compensation_node: u8 = math.maxInt(u8),
};

pub const PlanReceipt = struct {
    nodes: usize = 0,
    edges: usize = 0,
    estimated_cost: u64 = 0,
    critical_path_cost: u64 = 0,
    maximum_parallel_width: usize = 0,
};

pub fn Plan(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 64) @compileError("plan capacity must be 1..64");
    return struct {
        const Self = @This();
        // Inactive slots use an all-zero representation; `count` is the sole
        // visibility boundary, so the public PlanNode compensation sentinel
        // does not need to be materialized in cold storage.
        nodes: [capacity]PlanNode = @splat(.{ .compensation_node = 0 }),
        count: usize = 0,
        sealed: bool = false,

        pub fn staticBytes() usize { return @sizeOf(Self); }

        pub fn add(self: *Self, node: PlanNode) Error!u8 {
            if (self.sealed or self.count == capacity) return error.CapacityExhausted;
            if (node.operation_id == 0 or node.resource.kind == 0 or node.resource.id == 0 or
                node.argument_length > node.arguments.len or node.estimated_cost == 0 or node.timeout_ticks == 0)
                return error.InvalidPlan;
            self.nodes[self.count] = node;
            const index: u8 = @intCast(self.count);
            self.count += 1;
            return index;
        }

        pub fn seal(self: *Self) void { self.sealed = true; }

        pub fn validate(self: *const Self, registry: anytype, cost_budget: u64) Error!PlanReceipt {
            if (self.count == 0) return error.InvalidPlan;
            const valid_mask: u64 = if (self.count == 64) math.maxInt(u64) else (@as(u64, 1) << @intCast(self.count)) - 1;
            var receipt = PlanReceipt{ .nodes = self.count };
            var indegree: [capacity]u8 = @splat(0);
            var longest: [capacity]u64 = @splat(0);
            var processed: [capacity]bool = @splat(false);

            for (self.nodes[0..self.count], 0..) |node, index| {
                if ((node.dependencies & ~valid_mask) != 0 or (node.dependencies & (@as(u64, 1) << @intCast(index))) != 0)
                    return error.InvalidDependency;
                const schema = registry.find(node.operation_id) orelse return error.InvalidOperation;
                if (schema.resource_kind != node.resource.kind or node.argument_length > schema.maximum_argument_bytes)
                    return error.InvalidArgument;
                if (@intFromEnum(node.risk) > @intFromEnum(schema.maximum_risk)) return error.RiskDenied;
                if ((schema.requires_compensation or @intFromEnum(node.risk) >= @intFromEnum(Risk.consequential)) and
                    (!node.reversible or node.compensation_node == math.maxInt(u8)))
                    return error.MissingCompensation;
                if (node.compensation_node != math.maxInt(u8) and
                    (node.compensation_node >= self.count or node.compensation_node == index))
                    return error.InvalidPlan;
                indegree[index] = @intCast(@popCount(node.dependencies));
                receipt.edges += indegree[index];
                receipt.estimated_cost +|= node.estimated_cost;
                if (receipt.estimated_cost > cost_budget) return error.BudgetExceeded;
            }

            var completed: usize = 0;
            while (completed < self.count) {
                var width: usize = 0;
                for (0..self.count) |index| {
                    if (!processed[index] and indegree[index] == 0) width += 1;
                }
                if (width == 0) return error.DependencyCycle;
                receipt.maximum_parallel_width = @max(receipt.maximum_parallel_width, width);

                // Process one deterministic topological wave.
                var wave: [capacity]bool = @splat(false);
                for (0..self.count) |index| {
                    if (!processed[index] and indegree[index] == 0) wave[index] = true;
                }
                for (0..self.count) |index| if (wave[index]) {
                    var predecessor_cost: u64 = 0;
                    var dependencies = self.nodes[index].dependencies;
                    while (dependencies != 0) {
                        const dependency: usize = @intCast(@ctz(dependencies));
                        predecessor_cost = @max(predecessor_cost, longest[dependency]);
                        dependencies &= dependencies - 1;
                    }
                    longest[index] = predecessor_cost +| self.nodes[index].estimated_cost;
                    receipt.critical_path_cost = @max(receipt.critical_path_cost, longest[index]);
                    processed[index] = true;
                    completed += 1;
                };
                for (0..self.count) |index| if (!processed[index]) {
                    for (0..self.count) |finished| {
                        if (wave[finished] and
                            (self.nodes[index].dependencies & (@as(u64, 1) << @intCast(finished))) != 0)
                            indegree[index] -= 1;
                    }
                };
            }
            return receipt;
        }

        pub fn validateAuthority(self: *const Self, capabilities: anytype, subject: u64, now_tick: u64) Error!usize {
            var ancestors_checked: usize = 0;
            for (self.nodes[0..self.count]) |node| {
                const operation_bit = @as(u64, 1) << @intCast(node.operation_id);
                const receipt = try capabilities.validate(node.lease, .{
                    .subject = subject,
                    .resource = node.resource,
                    .rights = .{ .operations = operation_bit, .maximum_data_class = .public },
                }, now_tick);
                ancestors_checked += receipt.ancestors_checked;
            }
            return ancestors_checked;
        }
    };
}



fn digest(seed: u8) [16]u8 { return @splat(seed); }

test "capability delegation only narrows and root revocation is constant-write" {
    const Table = CapabilityTable(4, 3);
    var table = Table{};
    const resource = Resource{ .kind = 7, .id = 42 };
    const root = try table.mintRoot(.{
        .subject = 1, .resource = resource,
        .rights = .{ .operations = 0b1110, .maximum_data_class = .sensitive },
        .expires_tick = 100, .uses = 10,
    });
    const child = try table.delegate(root, .{
        .subject = 2, .resource = resource,
        .rights = .{ .operations = 0b0010, .maximum_data_class = .personal },
        .expires_tick = 80, .uses = 2,
    }, 1);
    try testing.expectError(error.RightsExpansion, table.delegate(child, .{
        .subject = 3, .resource = resource,
        .rights = .{ .operations = 0b0110, .maximum_data_class = .personal },
        .expires_tick = 70, .uses = 1,
    }, 2));
    const receipt = try table.consume(child, .{
        .subject = 2, .resource = resource,
        .rights = .{ .operations = 0b0010, .maximum_data_class = .personal },
    }, 3);
    if (receipt.uses_remaining != 1) return error.TestUnexpectedResult;
    try table.revokeRoot(root);
    try testing.expectError(error.LeaseRevoked, table.validate(child, .{
        .subject = 2, .resource = resource,
        .rights = .{ .operations = 0b0010, .maximum_data_class = .public },
    }, 4));
}

test "process lifecycle checkpoints and rejects stale handles" {
    const Processes = ProcessTable(1, 8);
    var processes = Processes{};
    const handle = try processes.create(digest(1), 1);
    try processes.admit(handle);
    try processes.start(handle);
    const bytes = [_]u8{ 1, 2, 3 };
    try processes.checkpoint(handle, &bytes, 2);
    try processes.wait(handle);
    var restored: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try processes.recover(handle, &restored));
    if (!mem.eql(u8, &bytes, restored[0..3])) return error.TestUnexpectedResult;
    try processes.complete(handle);
    try processes.release(handle);
    try testing.expectError(error.StaleHandle, processes.view(handle));
}

fn makeNode(operation_id: u8, resource: Resource, lease: Handle, cost: u32, risk: Risk) PlanNode {
    return .{
        .operation_id = operation_id,
        .resource = resource,
        .lease = lease,
        .estimated_cost = cost,
        .timeout_ticks = 10,
        .risk = risk,
        .reversible = risk == .read_only or risk == .reversible,
    };
}

test "PlanIR proves DAG cost, critical path, width, and authority" {
    const Registry = OperationRegistry(4);
    const Capabilities = CapabilityTable(4, 3);
    const TestPlan = Plan(4);
    var registry = Registry{};
    try registry.register(.{ .id = 1, .resource_kind = 9, .maximum_risk = .reversible, .maximum_argument_bytes = 8 });
    var capabilities = Capabilities{};
    const resource = Resource{ .kind = 9, .id = 1 };
    const lease = try capabilities.mintRoot(.{
        .subject = 77, .resource = resource,
        .rights = .{ .operations = @as(u64, 1) << 1, .maximum_data_class = .public },
        .expires_tick = 100, .uses = 3,
    });
    var plan = TestPlan{};
    _ = try plan.add(makeNode(1, resource, lease, 5, .read_only));
    _ = try plan.add(makeNode(1, resource, lease, 7, .reversible));
    var third = makeNode(1, resource, lease, 11, .read_only);
    third.dependencies = 0b11;
    _ = try plan.add(third);
    plan.seal();
    const receipt = try plan.validate(&registry, 30);
    if (receipt.nodes != 3) return error.TestUnexpectedResult;
    if (receipt.edges != 2) return error.TestUnexpectedResult;
    if (receipt.estimated_cost != 23) return error.TestUnexpectedResult;
    if (receipt.critical_path_cost != 18) return error.TestUnexpectedResult;
    if (receipt.maximum_parallel_width != 2) return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), try plan.validateAuthority(&capabilities, 77, 1));
}

test "PlanIR rejects cycles, cost overflow, and unregistered operations" {
    const Registry = OperationRegistry(1);
    const TestPlan = Plan(2);
    var registry = Registry{};
    try registry.register(.{ .id = 1, .resource_kind = 1, .maximum_risk = .read_only, .maximum_argument_bytes = 0 });
    const resource = Resource{ .kind = 1, .id = 1 };
    var plan = TestPlan{};
    var first = makeNode(1, resource, .{ .index = 0, .generation = 1 }, 10, .read_only);
    first.dependencies = 0b10;
    _ = try plan.add(first);
    var second = makeNode(1, resource, .{ .index = 0, .generation = 1 }, 10, .read_only);
    second.dependencies = 0b01;
    _ = try plan.add(second);
    try testing.expectError(error.DependencyCycle, plan.validate(&registry, 100));
    var costly = TestPlan{};
    _ = try costly.add(makeNode(1, resource, .{ .index = 0, .generation = 1 }, 10, .read_only));
    try testing.expectError(error.BudgetExceeded, costly.validate(&registry, 9));
}
