//! One unique, stable caller-owned OS region and its shared budget grant.
const pages=@import("page_region");
const budgets=@import("resource_budget");
pub const Error=pages.Error || budgets.Error || error{InvalidOwner,AlreadyReserved};
pub const Region=struct {
    memory:pages.Region=.{},
    ledger:?*budgets.Ledger=null,
    grant:?budgets.Token=null,
    owner:usize=0,
    /// Initialize at its final address. Live owners must not be copied/moved.
    /// The grant charges page-rounded bytes, including native page padding.
    pub fn reserve(self:*Region,ledger:*budgets.Ledger,bytes:usize) Error!void {
        if(self.owner!=0 or self.grant!=null or self.memory.bytes.len!=0) return error.AlreadyReserved;
        if(bytes==0) return error.InvalidCapacity;
        const page=pages.pageSize();if(page==0) return error.InvalidCapacity;
        const extra=@addWithOverflow(bytes,page-1);if(extra[1]!=0) return error.ArithmeticOverflow;
        const rounded=extra[0]/page*page;
        const token=try ledger.acquire(rounded);
        errdefer ledger.release(token) catch @panic("lost failed OS reservation grant");
        const memory=try pages.reserve(rounded);
        self.memory=memory;self.ledger=ledger;self.grant=token;self.owner=@intFromPtr(self);
    }
    pub fn close(self:*Region) Error!void {
        if(self.owner==0 and self.grant==null and self.memory.bytes.len==0) return;
        if(self.owner!=@intFromPtr(self) or self.grant==null or self.ledger==null) return error.InvalidOwner;
        // A failed OS release keeps ownership and its budget charge intact.
        try self.memory.tryClose();
        try self.ledger.?.release(self.grant.?);
        self.grant=null;self.ledger=null;self.owner=0;
    }
};
