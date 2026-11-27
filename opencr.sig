//! First-class OpenCR 1.0 BSP. Fixed-capacity full-Sig register drivers, no HAL/RTOS.
pub const board = @import("src/platform/opencr/board.sig");
pub const uart = @import("src/platform/opencr/uart.sig");
pub const usb = @import("src/platform/opencr/usb_device.sig");
pub const usb_host = @import("src/platform/opencr/usb_host.sig");
pub const io = @import("src/platform/opencr/io.sig");
pub const spi = @import("src/platform/opencr/spi.sig");
pub const i2c = @import("src/platform/opencr/i2c.sig");
pub const can = @import("src/platform/opencr/can.sig");
pub const rtc = @import("src/platform/opencr/rtc.sig");
pub const flash = @import("src/platform/opencr/flash.sig");
pub const imu = @import("src/core/device/opencr_imu.sig");
pub const diagnostics = @import("src/platform/opencr/diagnostics.sig");
