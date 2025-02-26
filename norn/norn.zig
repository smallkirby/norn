//! Norn.
//!
//! The operating system written from scratch in Zig.

const std = @import("std");
const log = std.log;
const option = @import("option");
const is_test = @import("builtin").is_test;

pub const acpi = @import("acpi.zig");
pub const arch = @import("arch.zig");
pub const bits = @import("bits.zig");
pub const drivers = @import("drivers.zig");
pub const errno = @import("errno.zig");
pub const fs = @import("fs.zig");
pub const init = @import("init.zig");
pub const interrupt = @import("interrupt.zig");
pub const klog = @import("log.zig");
pub const mem = @import("mem.zig");
pub const pcpu = if (!is_test) @import("percpu.zig") else @import("percpu.zig").mock_for_testing;
pub const sched = @import("sched.zig");
pub const rtt = @import("rtt.zig");
pub const syscall = @import("syscall.zig");
pub const thread = @import("thread.zig");
pub const timer = @import("timer.zig");
pub const util = @import("util.zig");
pub usingnamespace @import("typing.zig");

/// Whether the module is built with runtime tests enabled.
pub const is_runtime_test = option.is_runtime_test;
pub const LogFn = klog.LogFn;
pub const Serial = @import("Serial.zig");
pub const SpinLock = @import("SpinLock.zig");

/// Version of Norn kernel.
pub const version = option.version;
/// Git SHA of Norn kernel.
pub const sha = option.sha;
/// Norn banner ascii art.
pub const banner = @import("banner.zig").banner;
/// Maximum number of supported CPUs.
pub const num_max_cpu = 256;

var serial = Serial{};

/// Print an unimplemented message and halt the CPU indefinitely.
///
/// - `msg`: Message to print.
pub fn unimplemented(comptime msg: []const u8) noreturn {
    @setCold(true);

    if (serial.isInited()) {
        serial.writeString("UNIMPLEMENTED: ");
        serial.writeString(msg);
        serial.writeString("\n");
    }

    endlessHalt();

    unreachable;
}

/// Get the kernel serial console.
///
/// If the serial has not been initialized, this function initializes it.
pub fn getSerial() *Serial {
    if (!serial.isInited()) {
        serial.init();
    }
    return &serial;
}

/// Terminate QEMU.
///
/// Available only for testing.
/// You MUST add `isa-debug-exit` device to use this feature.
///
/// - `status`: Exit status. The QEMU process exits with `status << 1`.
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

// =======================================

test {
    std.testing.refAllDeclsRecursive(@This());
}
