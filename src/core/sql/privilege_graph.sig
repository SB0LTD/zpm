//! Owner-rooted privilege graphs. All storage is owned by the caller.
pub const Edge = struct {
    grantor: u32,
    grantee: u32,
    flags: u32,
    options: u32,
    original: ?usize = null,
};

pub const Graph = struct {
    pub const Step = struct { index: usize, flags: u32 };
    pub const State = struct { available: u32 = 0, emitted: u32 = 0 };
    edges: []Edge,
    len: usize = 0,
    owner: u32,
    privileges: u32,

    pub fn add(self: *Graph, edge: Edge) void {
        self.edges[self.len] = edge;
        self.len += 1;
    }

    pub fn find(self: Graph, grantor: u32, grantee: u32) ?usize {
        for (self.edges[0..self.len], 0..) |edge, i| {
            if (edge.grantor == grantor and edge.grantee == grantee and edge.flags != 0) return i;
        }
        return null;
    }

    pub fn start(self: Graph, states: []State) void {
        for (self.edges[0..self.len], states[0..self.len]) |edge, *state| {
            state.* = .{ .available = if (edge.grantor == self.owner) self.privileges else 0 };
        }
    }

    fn propagate(self: Graph, states: []State, grantee: u32, options: u32) void {
        if (options == 0 or grantee == self.owner) return;
        for (self.edges[0..self.len], states[0..self.len]) |edge, *state| {
            if (edge.grantor == grantee) state.available |= options;
        }
    }

    /// Each option propagates at most once per edge. A disconnected loop
    /// cannot retain options. Excluding a grantee detects circular grants.
    pub fn support(self: Graph, states: []State, excluded_grantee: ?u32) void {
        self.start(states);
        var changed = true;
        while (changed) {
            changed = false;
            for (self.edges[0..self.len], states[0..self.len]) |edge, *state| {
                if (edge.grantee == excluded_grantee) continue;
                const options = edge.options & state.available & ~state.emitted;
                if (options == 0) continue;
                state.emitted |= options;
                self.propagate(states, edge.grantee, options);
                changed = true;
            }
        }
    }

    pub fn supportedOptions(self: Graph, role: u32, states: []const State) u32 {
        if (role == self.owner) return self.privileges;
        var flags: u32 = 0;
        for (self.edges[0..self.len], states[0..self.len]) |edge, state| {
            if (edge.grantee == role) flags |= state.emitted;
        }
        return flags;
    }

    /// Transfer either endpoint with the owner and coalesce matching entries.
    /// The owner-to-self entry is stored in the object metadata.
    pub fn changeOwner(self: *Graph, owner: u32) struct { flags: u32, options: u32 } {
        var owner_flags: u32 = 0;
        var owner_options: u32 = 0;
        for (self.edges[0..self.len], 0..) |*edge, index| {
            if (edge.grantor == self.owner) edge.grantor = owner;
            if (edge.grantee == self.owner) edge.grantee = owner;
            if (edge.grantor == owner and edge.grantee == owner) {
                owner_flags |= edge.flags;
                owner_options |= edge.options;
                edge.flags = 0;
                edge.options = 0;
            } else {
                var earlier = self.*;
                earlier.len = index;
                if (earlier.find(edge.grantor, edge.grantee)) |duplicate| {
                    self.edges[duplicate].flags |= edge.flags;
                    self.edges[duplicate].options |= edge.options;
                    edge.flags = 0;
                    edge.options = 0;
                }
            }
        }
        self.owner = owner;
        return .{ .flags = owner_flags, .options = owner_options };
    }

    /// Pick a grant whose grantor has already been emitted. pg_dump replays
    /// entries in ACL array order. If both rights cannot be emitted together,
    /// split the item by privilege so independently rooted chains can progress.
    pub fn next(self: Graph, states: []State) ?Step {
        var first: ?Step = null;
        for (self.edges[0..self.len], states[0..self.len], 0..) |edge, state, index| {
            const pending = edge.flags & ~state.emitted;
            if (pending == 0) continue;
            const ready = pending & state.available;
            if (ready == pending) {
                first = .{ .index = index, .flags = ready };
                break;
            }
            if (ready != 0 and first == null) first = .{ .index = index, .flags = ready };
        }
        if (first) |step| {
            const edge = self.edges[step.index];
            states[step.index].emitted |= step.flags;
            self.propagate(states, edge.grantee, edge.options & step.flags);
        }
        return first;
    }
};
