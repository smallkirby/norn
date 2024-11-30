pub const arch = @import("arch.zig");
pub const bits = @import("bits.zig");
pub const drivers = @import("drivers.zig");
pub const klog = @import("log.zig");

pub const Serial = @import("Serial.zig");
pub const SpinLock = @import("SpinLock.zig");

const std = @import("std");
const log = std.log;

var serial = Serial{};

/// Print an unimplemented message and halt the CPU.
pub fn unimplemented(comptime msg: []const u8) noreturn {
    @setCold(true);

    if (serial.isInited()) {
        serial.writeString("UNIMPLEMENTED: ");
        serial.writeString(msg);
        serial.writeString("\n");
    }
    while (true) {
        arch.disableIrq();
        arch.halt();
    }

    unreachable;
}

/// Get the kernel serial console.
/// If the serial has not been initialized, it is initialized.
pub fn getSerial() *Serial {
    if (!serial.isInited()) {
        serial.init();
    }
    return &serial;
}
