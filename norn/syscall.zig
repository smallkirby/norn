pub const Error = errno.Error;

/// System call handler function signature.
pub const Handler = *const fn (*Context, u64, u64, u64, u64, u64, u64) Error!i64;
/// System call context.
pub const Context = arch.SyscallContext;

/// List of system calls.
pub const Syscall = enum(u64) {
    /// Write to a file descriptor.
    write = 1,
    /// Change data segment size.
    brk = 12,
    /// Not supported.
    arch_prctl = 158,
    /// Set pointer to thread ID.
    set_tid_address = 218,
    /// Get or set list of robust futexes.
    set_robust_list = 273,
    /// Output to debug log.
    /// TODO: change the NR.
    dlog = 255,
    /// Read value of a symbolic link.
    readlinkat = 267,
    /// Get and set resource limits.
    prlimit = 302,
    /// Restartable sequences.
    rseq = 334,

    _,

    /// Maximum number of system calls + 1.
    const nr_max = 512;

    /// System call table.
    const syscall_table: [nr_max]Handler = blk: {
        var table: [nr_max]Handler = undefined;

        const sys_unhandled = sys(unhandledSyscallHandler);
        for (0..nr_max) |i| {
            table[i] = sys_unhandled;
        }

        for (std.enums.values(Syscall)) |e| {
            table[@intFromEnum(e)] = switch (e) {
                .write => sys(sysWrite),
                .brk => sys(norn.mm.sysBrk),
                .arch_prctl => sys(norn.prctl.sysArchPrctl),
                .set_tid_address => sys(ignoredSyscallHandler),
                .set_robust_list => sys(ignoredSyscallHandler),
                .dlog => sys(sysDebugLog),
                .readlinkat => sys(ignoredSyscallHandler),
                .prlimit => sys(ignoredSyscallHandler),
                .rseq => sys(ignoredSyscallHandler),
                else => {},
            };
        }

        break :blk table;
    };

    /// Get a corresponding system call handler.
    pub fn invoke(
        self: Syscall,
        ctx: *Context,
        arg1: u64,
        arg2: u64,
        arg3: u64,
        arg4: u64,
        arg5: u64,
        arg6: u64,
    ) Error!i64 {
        if (@intFromEnum(self) >= nr_max) {
            return Error.Inval;
        }
        return syscall_table[@intFromEnum(self)](ctx, arg1, arg2, arg3, arg4, arg5, arg6);
    }

    /// Create a system call enum from a syscall number.
    pub inline fn from(nr: u64) Syscall {
        return @enumFromInt(nr);
    }
};

/// Syscall wrapper.
///
/// This function converts an syscall handler function to have the fixed signature `Handler`.
fn sys(comptime handler: anytype) Handler {
    const S = struct {
        fn f0(ctx: *Context, _: u64, _: u64, _: u64, _: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx);
        }
        fn f1(ctx: *Context, arg1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx, arg1);
        }
        fn f2(ctx: *Context, arg1: u64, arg2: u64, _: u64, _: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx, arg1, arg2);
        }
        fn f3(ctx: *Context, arg1: u64, arg2: u64, arg3: u64, _: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx, arg1, arg2, arg3);
        }
        fn f4(ctx: *Context, arg1: u64, arg2: u64, arg3: u64, arg4: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx, arg1, arg2, arg3, arg4);
        }
        fn f5(ctx: *Context, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, _: u64) Error!i64 {
            return handler(ctx, arg1, arg2, arg3, arg4, arg5);
        }
        fn f6(ctx: *Context, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) Error!i64 {
            return handler(ctx, arg1, arg2, arg3, arg4, arg5, arg6);
        }
    };

    const func = @typeInfo(@TypeOf(handler)).@"fn";
    return switch (func.params.len) {
        1 => return S.f0,
        2 => return S.f1,
        3 => return S.f2,
        4 => return S.f3,
        5 => return S.f4,
        6 => return S.f5,
        7 => return S.f6,
        else => @compileError("Wrapper: Invalid number of parameters"),
    };
}

// =============================================================
// Handlers.
// =============================================================

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
    log.err("  RIP    : 0x{X:0>16}", .{ctx.rip});
    log.err("  RFLAGS : 0x{X:0>16}", .{ctx.rflags});
    log.err("  RAX    : 0x{X:0>16}", .{ctx.rax});
    log.err("  RBX    : 0x{X:0>16}", .{ctx.rbx});
    log.err("  RCX    : 0x{X:0>16}", .{ctx.rcx});
    log.err("  RDX    : 0x{X:0>16}", .{ctx.rdx});
    log.err("  RSI    : 0x{X:0>16}", .{ctx.rsi});
    log.err("  RDI    : 0x{X:0>16}", .{ctx.rdi});
    log.err("  RBP    : 0x{X:0>16}", .{ctx.rbp});
    log.err("  R8     : 0x{X:0>16}", .{ctx.r8});
    log.err("  R9     : 0x{X:0>16}", .{ctx.r9});
    log.err("  R10    : 0x{X:0>16}", .{ctx.r10});
    log.err("  R11    : 0x{X:0>16}", .{ctx.r11});
    log.err("  R12    : 0x{X:0>16}", .{ctx.r12});
    log.err("  R13    : 0x{X:0>16}", .{ctx.r13});
    log.err("  R14    : 0x{X:0>16}", .{ctx.r14});
    log.err("  R15    : 0x{X:0>16}", .{ctx.r15});
    log.err("  CS     : 0x{X:0>4}", .{ctx.cs});
    if (ctx.isFromUserMode()) {
        log.err("  SS     : 0x{X:0>4}", .{ctx.ss});
        log.err("  RSP    : 0x{X:0>16}", .{ctx.rsp});
    }

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

/// Handler for ignored syscalls.
fn ignoredSyscallHandler(ctx: *Context) Error!i64 {
    log.warn("Syscall nr={d} is ignored.", .{ctx.spec2.orig_rax});
    log.warn("  RIP    : 0x{X:0>16}", .{ctx.rip});
    log.warn("  RFLAGS : 0x{X:0>16}", .{ctx.rflags});
    log.warn("  RAX    : 0x{X:0>16}", .{ctx.rax});
    log.warn("  RBX    : 0x{X:0>16}", .{ctx.rbx});
    log.warn("  RCX    : 0x{X:0>16}", .{ctx.rcx});
    log.warn("  RDX    : 0x{X:0>16}", .{ctx.rdx});
    log.warn("  RSI    : 0x{X:0>16}", .{ctx.rsi});
    log.warn("  RDI    : 0x{X:0>16}", .{ctx.rdi});
    log.warn("  RBP    : 0x{X:0>16}", .{ctx.rbp});
    log.warn("  R8     : 0x{X:0>16}", .{ctx.r8});
    log.warn("  R9     : 0x{X:0>16}", .{ctx.r9});
    log.warn("  R10    : 0x{X:0>16}", .{ctx.r10});
    log.warn("  R11    : 0x{X:0>16}", .{ctx.r11});
    log.warn("  R12    : 0x{X:0>16}", .{ctx.r12});
    log.warn("  R13    : 0x{X:0>16}", .{ctx.r13});
    log.warn("  R14    : 0x{X:0>16}", .{ctx.r14});
    log.warn("  R15    : 0x{X:0>16}", .{ctx.r15});
    log.warn("  CS     : 0x{X:0>4}", .{ctx.cs});
    if (ctx.isFromUserMode()) {
        log.warn("  SS     : 0x{X:0>4}", .{ctx.ss});
        log.warn("  RSP    : 0x{X:0>16}", .{ctx.rsp});
    }
    return error.Unimplemented;
}

/// Syscall handler for `write`.
///
/// Currently, only supports writing to stdout (fd=1) and stderr (fd=2).
/// These outputs are printed to the debug log.
fn sysWrite(_: *Context, fd: u64, buf: u64, count: u64) Error!i64 {
    if (fd != 1 and fd != 2) {
        norn.unimplemented("sysWrite(): fd other than 1 or 2.");
    }

    // Print to the serial log.
    const msg: [*]const u8 = @ptrFromInt(buf);
    norn.getSerial().writeString(msg[0..count]);

    return @bitCast(count);
}

/// Syscall handler for `dlog`.
///
/// Print the given string to the debug log.
///
/// - `str`: Pointer to the null-terminated string.
/// - `size`: Size of the string.
fn sysDebugLog(_: *Context, str: u64, size: u64) Error!i64 {
    const s: []const u8 = @as([*]const u8, @ptrFromInt(str))[0..size];
    log.debug("{s}", .{s});
    return 0;
}

// =============================================================
// Imports.
// =============================================================

const std = @import("std");
const log = std.log.scoped(.syscall);

const norn = @import("norn");
const arch = norn.arch;
const errno = norn.errno;

const VmArea = norn.mm.VmArea;
const VmFlags = norn.mm.VmFlags;
