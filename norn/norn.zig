pub const acpi = @import("acpi.zig");
pub const arch = @import("arch.zig");
pub const bits = @import("bits.zig");
pub const drivers = @import("drivers.zig");
pub const interrupt = @import("interrupt.zig");
pub const klog = @import("log.zig");
pub const mem = @import("mem.zig");
pub const pcpu = if (!is_test) @import("percpu.zig") else @import("percpu.zig").mock_for_testing;
pub const sched = @import("sched.zig");
pub const rtt = @import("rtt.zig");
pub const thread = @import("thread.zig");
pub usingnamespace @import("typing.zig");

pub const is_runtime_test = @import("option").is_runtime_test;
pub const LogFn = klog.LogFn;
pub const Serial = @import("Serial.zig");
pub const SpinLock = @import("SpinLock.zig");

const std = @import("std");
const log = std.log;
const is_test = @import("builtin").is_test;

/// Maximum number of supported CPUs.
pub const num_max_cpu = 256;

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

/// Terminate QEMU.
/// Available only for testing.
pub fn terminateQemu(status: u8) void {
    if (is_runtime_test) {
        arch.out(u8, status, 0xF0);
    }
}

/// Halt the CPU indefinitely.
pub fn endlessHalt() noreturn {
    while (true) {
        arch.disableIrq();
        arch.halt();
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
