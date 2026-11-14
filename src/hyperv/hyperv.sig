//! Hyper-V guest support: VMBus and the synthetic devices a generation 2
//! Hyper-V machine offers in place of PCI hardware. Each part is its own
//! file, zero allocation and freestanding, with the guest's side of the
//! hypervisor supplied by the kernel that uses them.

pub const vmbus = @import("vmbus.sig");
pub const keyboard = @import("keyboard.sig");
pub const mouse = @import("mouse.sig");
pub const storage = @import("storage.sig");
pub const network = @import("network.sig");
