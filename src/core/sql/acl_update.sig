//! PostgreSQL's ACL update rules over a caller-owned, ordered entry list
//! (privileges lane, B11 wave 5): acl.c aclupdate, recursive_revoke,
//! check_circularity, aclmask and aclmask_direct, aclchk.c
//! merge_acl_with_grant, select_best_grantor and restrict_and_check_grant.
//!
//! An ACL is the entry array of one object (a table, a column, a
//! sequence, a schema or a type) in display order. A privilege mode is
//! PostgreSQL's AclMode: privilege bits in the low word, their grant
//! options in the high word. Nothing allocates and nothing recurses: a
//! cascading revoke runs as a bounded worklist (one item per grantee), and
//! the circularity check works on a second caller-owned list.
//!
//! The membership oracle `ctx` answers `privilegesOf(role, other) bool`
//! (has_privs_of_role: a superuser, or `role` inherits `other`).
const types = @import("types.sig");
const Error = types.Error;

pub const public_role: u32 = 0;

pub const Entry = struct {
    grantee: u32 = 0,
    grantor: u32 = 0,
    privileges: u32 = 0,
    options: u32 = 0,
    /// ACL position of a stored entry (0: appended by this change).
    ordinal: u32 = 0,
    /// The caller's handle of the stored row the entry came from.
    origin: ?usize = null,

    fn mode(self: Entry) u64 {
        return combine(self.privileges, self.options);
    }
};

pub fn combine(privileges: u32, options: u32) u64 {
    return @as(u64, privileges) | (@as(u64, options) << 32);
}

pub fn optionsOf(mode: u64) u32 {
    return @truncate(mode >> 32);
}

pub fn privilegesOf(mode: u64) u32 {
    return @truncate(mode);
}

const option_bits: u64 = 0xffff_ffff_0000_0000;

pub const Acl = struct {
    items: []Entry,
    len: usize = 0,

    pub fn entries(self: *const Acl) []const Entry {
        return self.items[0..self.len];
    }

    pub fn find(self: *const Acl, grantee: u32, grantor: u32) ?usize {
        for (self.items[0..self.len], 0..) |entry, index| {
            if (entry.grantee == grantee and entry.grantor == grantor) return index;
        }
        return null;
    }

    /// Appends an entry (54000 TableCapacity beyond the caller's list).
    pub fn append(self: *Acl, entry: Entry) Error!usize {
        if (self.len == self.items.len) return error.TableCapacity;
        self.items[self.len] = entry;
        self.len += 1;
        return self.len - 1;
    }

    fn remove(self: *Acl, index: usize) void {
        var at = index;
        while (at + 1 < self.len) : (at += 1) self.items[at] = self.items[at + 1];
        self.len -= 1;
    }

    pub fn copyFrom(self: *Acl, other: *const Acl) Error!void {
        if (other.len > self.items.len) return error.TableCapacity;
        @memcpy(self.items[0..other.len], other.items[0..other.len]);
        self.len = other.len;
    }
};

fn satisfied(result: u64, mask: u64, all: bool) bool {
    return if (all) result == mask else result != 0;
}

/// aclmask: the bits of `mask` `role` holds in `acl`, directly, through
/// PUBLIC or through an inherited role. An owner (or a role with the
/// owner's privileges) implicitly holds every grant option.
pub fn aclmask(acl: *const Acl, ctx: anytype, role: u32, owner: u32, mask: u64, all: bool) u64 {
    var result: u64 = 0;
    if (mask & option_bits != 0 and ctx.privilegesOf(role, owner)) {
        result = mask & option_bits;
        if (satisfied(result, mask, all)) return result;
    }
    for (acl.entries()) |entry| {
        if (entry.grantee != public_role and entry.grantee != role) continue;
        result |= entry.mode() & mask;
        if (satisfied(result, mask, all)) return result;
    }
    const remaining = mask & ~result;
    for (acl.entries()) |entry| {
        if (entry.grantee == public_role or entry.grantee == role) continue;
        if (entry.mode() & remaining == 0 or !ctx.privilegesOf(role, entry.grantee)) continue;
        result |= entry.mode() & mask;
        if (satisfied(result, mask, all)) return result;
    }
    return result;
}

/// aclmask_direct: grants to `role` itself only (not PUBLIC, no roles).
pub fn aclmaskDirect(acl: *const Acl, role: u32, owner: u32, mask: u64, all: bool) u64 {
    var result: u64 = 0;
    if (mask & option_bits != 0 and role == owner) {
        result = mask & option_bits;
        if (satisfied(result, mask, all)) return result;
    }
    for (acl.entries()) |entry| {
        if (entry.grantee != role) continue;
        result |= entry.mode() & mask;
        if (satisfied(result, mask, all)) return result;
    }
    return result;
}

pub const Behavior = enum { restrict, cascade };

/// Grantees whose grant options a revoke reduced, waiting for
/// recursive_revoke (merged per grantee, so bounded by the ACL length).
pub const Pending = struct { grantee: u32 = 0, privileges: u32 = 0 };

pub const Scratch = struct {
    /// A second ACL for check_circularity.
    copy: Acl,
    pending: []Pending,
};

fn push(pending: []Pending, count: *usize, grantee: u32, privileges: u32) Error!void {
    for (pending[0..count.*]) |*item| if (item.grantee == grantee) {
        item.privileges |= privileges;
        return;
    };
    if (count.* == pending.len) return error.TableCapacity;
    pending[count.*] = .{ .grantee = grantee, .privileges = privileges };
    count.* += 1;
}

/// aclupdate with ACL_MODECHG_DEL, then recursive_revoke for every grantee
/// that lost grant options (2BP01 under RESTRICT when dependents exist).
pub fn revokeItem(acl: *Acl, ctx: anytype, item: Entry, owner: u32, behavior: Behavior, pending: []Pending) Error!void {
    var count: usize = 0;
    try removeRights(acl, item, pending, &count);
    while (count != 0) {
        count -= 1;
        const grantee = pending[count].grantee;
        var revoke = pending[count].privileges;
        // The owner can never truly lose grant options.
        if (grantee == owner) continue;
        // The grantee may still hold the options through another grantor.
        const still = aclmask(acl, ctx, grantee, owner, combine(0, revoke), true);
        revoke &= ~optionsOf(still);
        if (revoke == 0) continue;
        var index: usize = 0;
        while (index < acl.len) {
            const entry = acl.items[index];
            if (entry.grantor != grantee or entry.privileges & revoke == 0) {
                index += 1;
                continue;
            }
            if (behavior == .restrict) return error.DependentObjects;
            const before = acl.len;
            try removeRights(acl, .{ .grantee = entry.grantee, .grantor = grantee, .privileges = revoke, .options = revoke }, pending, &count);
            if (acl.len == before) index += 1;
        }
    }
}

fn removeRights(acl: *Acl, item: Entry, pending: []Pending, count: *usize) Error!void {
    const index = acl.find(item.grantee, item.grantor) orelse return;
    const entry = &acl.items[index];
    const old_options = entry.options;
    entry.privileges &= ~item.privileges;
    entry.options &= ~item.options;
    // Grant options never outlive their privilege.
    entry.options &= entry.privileges;
    const lost = old_options & ~entry.options;
    const grantee = entry.grantee;
    if (entry.privileges == 0) acl.remove(index);
    if (lost != 0 and grantee != public_role) try push(pending, count, grantee, lost);
}

/// aclupdate with ACL_MODECHG_ADD: check_circularity first when grant
/// options are added (0LP01), then modify the (grantee, grantor) entry in
/// place or append it.
pub fn grantItem(acl: *Acl, ctx: anytype, item: Entry, owner: u32, scratch: *Scratch) Error!void {
    if (item.options != 0) try checkCircularity(acl, ctx, item, owner, scratch);
    const index = acl.find(item.grantee, item.grantor) orelse blk: {
        if (item.privileges == 0) return;
        break :blk try acl.append(.{ .grantee = item.grantee, .grantor = item.grantor });
    };
    acl.items[index].privileges |= item.privileges;
    acl.items[index].options |= item.options;
}

/// check_circularity: without every grant option the grantee holds (and
/// what depends on them), the grantor must still hold the options it
/// grants; otherwise they would come back to their own grantor.
fn checkCircularity(acl: *const Acl, ctx: anytype, item: Entry, owner: u32, scratch: *Scratch) Error!void {
    if (item.grantor == owner) return;
    const copy = &scratch.copy;
    try copy.copyFrom(acl);
    var index: usize = 0;
    while (index < copy.len) {
        const entry = copy.items[index];
        if (entry.grantee != item.grantee or entry.options == 0) {
            index += 1;
            continue;
        }
        // Zap ordinary privileges too, as PostgreSQL does.
        try revokeItem(copy, ctx, entry, owner, .cascade, scratch.pending);
        index = 0;
    }
    const held = optionsOf(aclmask(copy, ctx, item.grantor, owner, combine(0, item.options), true));
    if (item.options & ~held != 0) return error.InvalidGrantOperation;
}

/// merge_acl_with_grant for one grantee: GRANT adds the privileges (and
/// their options WITH GRANT OPTION); REVOKE removes both, or only the
/// options for REVOKE GRANT OPTION FOR. Grant options go to roles only.
pub fn mergeGrant(acl: *Acl, ctx: anytype, is_grant: bool, grant_option: bool, behavior: Behavior, grantee: u32, privileges: u32, grantor: u32, owner: u32, scratch: *Scratch) Error!void {
    if (is_grant and grant_option and grantee == public_role) return error.InvalidGrantOperation;
    const item: Entry = .{
        .grantee = grantee,
        .grantor = grantor,
        .privileges = if (is_grant or !grant_option) privileges else 0,
        .options = if (!is_grant or grant_option) privileges else 0,
    };
    if (is_grant) return grantItem(acl, ctx, item, owner, scratch);
    return revokeItem(acl, ctx, item, owner, behavior, scratch.pending);
}

pub const Grantor = struct { role: u32, options: u32 };

/// select_best_grantor: the owner (also for superusers), else the first
/// role in `roles` (the current role, then every role it inherits) holding
/// every needed grant option directly, else the one holding the most.
pub fn selectBestGrantor(acl: *const Acl, roles: []const u32, privileges: u32, owner: u32, superuser: bool) Grantor {
    const role = roles[0];
    if (role == owner or superuser) return .{ .role = owner, .options = privileges };
    var best: Grantor = .{ .role = role, .options = 0 };
    var rights: u32 = 0;
    for (roles) |candidate| {
        const held = optionsOf(aclmaskDirect(acl, candidate, owner, combine(0, privileges), true));
        if (held == privileges) return .{ .role = candidate, .options = held };
        if (held != 0 and @popCount(held) > rights) {
            best = .{ .role = candidate, .options = held };
            rights = @popCount(held);
        }
    }
    return best;
}

pub const Warning = enum { none, none_granted, not_all_granted, none_revoked, not_all_revoked };

pub const Restricted = struct { privileges: u32, warning: Warning };

/// restrict_and_check_grant: without any grant option, a grantor that holds
/// no privilege on the object at all fails (42501); otherwise the change is
/// restricted to the options held, with the standard warnings.
pub fn restrictAndCheck(is_grant: bool, available: u32, all_privileges: bool, privileges: u32, grantor_holds_any: bool) Error!Restricted {
    if (available == 0 and !grantor_holds_any) return error.InsufficientPrivilege;
    const granted = privileges & available;
    var warning: Warning = .none;
    if (is_grant) {
        if (granted == 0) {
            warning = .none_granted;
        } else if (!all_privileges and granted != privileges) warning = .not_all_granted;
    } else {
        if (granted == 0) {
            warning = .none_revoked;
        } else if (!all_privileges and granted != privileges) warning = .not_all_revoked;
    }
    return .{ .privileges = granted, .warning = warning };
}
