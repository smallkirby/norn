const std = @import("std");
const log = std.log.scoped(.syscall);

const norn = @import("norn");
const arch = norn.arch;
const errno = norn.errno;

const Context = arch.SyscallContext;
const Error = errno.Error;

/// System call handler function signature.
pub const Handler = *const fn (*Context, u64, u64, u64, u64, u64) Error!i64;

/// List of system calls.
pub const Syscall = enum(u64) {
    _,

    /// Get a corresponding system call handler.
    pub fn getHandler(self: Syscall) Handler {
        return switch (self) {
            _ => unhandledSyscallHandler,
        };
    }

    /// Create a system call enum from a syscall number.
    pub inline fn from(nr: u64) Syscall {
        return @enumFromInt(nr);
    }
};

/// Handler for unhandled system calls.
fn unhandledSyscallHandler(
    ctx: *Context,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
) Error!i64 {
    log.err("Unhandled syscall (nr={d})", .{ctx.orig_rax});
    log.err("  [0]={X:0>16} [1]={X:0>16}", .{ arg1, arg2 });
    log.err("  [2]={X:0>16} [3]={X:0>16} [4]={X:0>16}", .{ arg3, arg4, arg5 });

    if (norn.is_runtime_test) {
        log.info("Reached unreachable unhandled syscall handler.", .{});
        norn.terminateQemu(0);
    }

    return Error.Unimplemented;
}
