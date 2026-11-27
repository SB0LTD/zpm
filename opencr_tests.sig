comptime {
    _ = @import("src/platform/opencr/io.sig");
    _ = @import("src/platform/opencr/can.sig");
    _ = @import("src/platform/opencr/rtc.sig");
    _ = @import("src/platform/opencr/flash.sig");
    _ = @import("src/platform/opencr/usb_host.sig");
    _ = @import("src/core/device/opencr_imu.sig");
    _ = @import("src/platform/opencr/diagnostics.sig");
}
