//! Norn.
//!
//! The operating system written from scratch in Zig.

pub const acpi = @import("acpi.zig");
pub const arch = @import("arch.zig");
pub const bits = @import("bits.zig");
pub const device = @import("device.zig");
pub const drivers = @import("drivers.zig");
pub const errno = @import("errno.zig");
pub const fs = @import("fs.zig");
pub const init = @import("init.zig");
pub const interrupt = @import("interrupt.zig");
pub const klog = @import("log.zig");
pub const loader = @import("loader.zig");
pub const mem = @import("mem.zig");
pub const mm = @import("mm.zig");
pub const mmio = @import("mmio.zig");
pub const pci = @import("pci.zig");
pub const pcpu = if (!is_test) @import("percpu.zig") else @import("percpu.zig").mock_for_testing;
pub const posix = @import("posix.zig");
pub const prctl = @import("prctl.zig");
pub const sched = @import("sched.zig");
pub const rtt = @import("rtt.zig");
pub const syscall = @import("syscall.zig");
pub const thread = @import("thread.zig");
pub const timer = @import("timer.zig");
pub const util = @import("util.zig");
pub usingnamespace @import("typing.zig");

/// Whether the module is built with runtime tests enabled.
pub const is_runtime_test = option.is_runtime_test;
/// Whether the module is built for `zig build test`.
pub const is_test = @import("builtin").is_test;
pub const LogFn = klog.LogFn;
pub const RbTree = @import("RbTree.zig").RbTree;
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
    @branchHint(.cold);

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
    if (is_runtime_test) {
        terminateQemu(3);
    }
    while (true) {
        _ = arch.disableIrq();
        arch.halt();
    }
}

/// Execute an undefined instruction.
pub inline fn trap() noreturn {
    arch.ud();
}

// =============================================================
// Test
// =============================================================

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// Assert at compile time.
pub fn comptimeAssert(cond: bool, comptime msg: []const u8, args: anytype) void {
    if (!cond) {
        @compileError(std.fmt.comptimePrint(msg, args));
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log;
const option = @import("option");
