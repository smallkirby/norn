pub usingnamespace switch (builtin.target.cpu.arch) {
    .x86_64 => x64,
    else => @compileError("Unsupported architecture."),
};

const x64 = struct {
    /// prctl operations.
    const Operation = enum(u64) {
        /// Set the value of the FS segment register.
        set_gs = 0x1001,
        /// Set the value of the FS segment register.
        set_fs = 0x1002,
        /// Get the value of the FS segment register.
        get_fs = 0x1003,
        /// Get the value of the GS segment register.
        get_gs = 0x1004,
        /// Get the activity state of the CPUID.
        get_cpuid = 0x1011,
        /// Enable or disable CPUID.
        set_cpuid = 0x1012,
        _,
    };

    /// Syscall handler for `arch_prctl`.
    pub fn sysArchPrctl(
        _: *syscall.Context,
        arg1: u64,
        arg2: u64,
        _: u64,
        _: u64,
        _: u64,
        _: u64,
    ) syscall.Error!i64 {
        const op: Operation = @enumFromInt(arg1);

        return switch (op) {
            .get_fs => @bitCast(arch.getFs()),
            .set_fs => blk: {
                arch.setFs(arg2);
                break :blk 0;
            },
            // TODO: implement
            .set_cpuid => 0,
            // unsupported operation
            else => blk: {
                log.warn("Unsupported operation: 0x{X}", .{arg1});
                break :blk error.Inval;
            },
        };
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.prctl);

const norn = @import("norn");
const arch = norn.arch;
const syscall = norn.syscall;
