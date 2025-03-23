pub const Error = errno.Error;

/// System call handler function signature.
pub const Handler = *const fn (*Context, u64, u64, u64, u64, u64, u64) Error!i64;
/// System call context.
pub const Context = arch.SyscallContext;

/// List of system calls.
pub const Syscall = enum(u64) {
    /// Output to debug log.
    dlog = 255,

    _,

    /// Get a corresponding system call handler.
    pub fn getHandler(self: Syscall) Handler {
        return switch (self) {
            .dlog => sysDebugLog,
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
    arg6: u64,
) Error!i64 {
    log.err("Unhandled syscall (nr={d})", .{ctx.spec2.orig_rax});
    log.err("  [1]={X:0>16} [2]={X:0>16} [3]={X:0>16}", .{ arg1, arg2, arg3 });
    log.err("  [4]={X:0>16} [5]={X:0>16} [6]={X:0>16}", .{ arg4, arg5, arg6 });

    // Print memory map of the current task.
    log.err("Memory map of the current task:", .{});
    const task = norn.sched.getCurrentTask();
    var node: ?*VmArea = task.mm.vm_areas.first;
    while (node) |area| : (node = area.list_head.next) {
        log.err(
            "  {X}-{X} {s}",
            .{ area.start, area.end, area.flags.toString() },
        );
    }

    // Print task information.
    log.err("Task Information:", .{});
    log.err("  PID: {d}, comm={s}", .{ task.tid, task.comm });
    log.err("  RIP: 0x{X:0>16}", .{ctx.rip});

    // Stack trace.
    var it = std.debug.StackIterator.init(null, ctx.rbp);
    var ix: usize = 0;
    log.err("=== Stack Trace =====================", .{});
    while (it.next()) |frame| : (ix += 1) {
        log.err("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }
    log.err("=====================================", .{});

    if (norn.is_runtime_test) {
        log.info("Reached unreachable unhandled syscall handler.", .{});
        norn.terminateQemu(0);
    }

    return Error.Unimplemented;
}

/// Syscall handler for `dlog`.
///
/// Print the given string to the debug log.
///
/// - `str`: Pointer to the null-terminated string.
/// - `size`: Size of the string.
fn sysDebugLog(_: *Context, str: u64, size: u64, _: u64, _: u64, _: u64, _: u64) Error!i64 {
    const s: []const u8 = @as([*]const u8, @ptrFromInt(str))[0..size];
    log.debug("{s}", .{s});
    return 0;
}

const std = @import("std");
const log = std.log.scoped(.syscall);

const norn = @import("norn");
const arch = norn.arch;
const errno = norn.errno;

const VmArea = norn.mm.VmArea;
const VmFlags = norn.mm.VmFlags;
