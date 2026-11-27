//! ZPM SlowWire package facade. All storage fixed-capacity; platform stays Layer 1.
pub const dynamixel2 = @import("src/core/device/dynamixel2.sig");
pub const xl330 = @import("src/core/device/xl330.sig");
pub const link = @import("src/core/device/slowwire_link.sig");
pub const fixture = @import("src/core/device/slowwire.sig");
pub const cdc = @import("src/core/device/usb_cdc.sig");
pub const rp2040 = struct {
    pub const board = @import("src/platform/rp2040/board.sig");
    pub const uart = @import("src/platform/rp2040/uart.sig");
    pub const usb = @import("src/platform/rp2040/usb_device.sig");
};
pub const windows = @import("src/platform/windows/slowwire_io.sig");
pub const uf2 = @import("src/core/device/uf2.sig");
pub const service = @import("src/core/device/slowwire_service.sig");
pub const u2d2 = @import("src/platform/windows/u2d2.sig");
pub const opencr = @import("opencr.sig");
pub const nano = @import("src/platform/avr/nano.sig");
pub const samd21 = struct {
    pub const board = @import("src/platform/samd21/board.sig");
    pub const uart = @import("src/platform/samd21/uart.sig");
    pub const usb = @import("src/platform/samd21/usb_device.sig");
};
