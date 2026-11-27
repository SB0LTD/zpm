comptime {
    _ = @import("src/core/device/dynamixel2.sig");
    _ = @import("src/core/device/xl330.sig");
    _ = @import("src/core/device/slowwire_link.sig");
}
comptime {
    _ = @import("src/core/device/slowwire.sig");
}
comptime {
    _ = @import("src/core/device/usb_cdc.sig");
}
comptime {
    _ = @import("src/core/device/uf2.sig");
}
comptime {
    _ = @import("src/core/device/slowwire_service.sig");
}
