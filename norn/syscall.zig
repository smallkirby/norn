pub const Error = errno.Error;

/// System call handler function signature.
pub const Handler = *const fn (*Context, u64, u64, u64, u64, u64, u64) Error!i64;
/// System call context.
pub const Context = arch.SyscallContext;

/// List of system calls.
///
/// Syscalls less than `norn_syscall_start` comply with x86-64 Linux kernel.
/// Syscalls greater than or equal to `norn_syscall_start` are specific to Norn.
pub const Syscall = enum(u64) {
    /// Read from a file descriptor.
    read = 0,
    /// Write to a file descriptor.
    write = 1,
    /// Set protection on a region of memory.
    mprotect = 10,
    /// Change data segment size.
    brk = 12,
    /// Control device.
    ioctl = 16,
    /// Write data into multiple buffers.
    writev = 20,
    /// Not supported.
    arch_prctl = 158,
    /// Get user identity.
    getuid = 102,
    /// Set user identity.
    setuid = 105,
    /// Set pointer to thread ID.
    set_tid_address = 218,
    /// Retrieve the time of of the specified clock.
    clock_gettime = 222,
    /// Exit all threads in a process.
    exit_group = 231,
    /// Get file status.
    newfstatat = 262,
    /// Read value of a symbolic link.
    readlinkat = 267,
    /// Get or set list of robust futexes.
    set_robust_list = 273,
    /// Get and set resource limits.
    prlimit = 302,
    /// Obtain a series of random bytes.
    getrandom = 318,
    /// Restartable sequences.
    rseq = 334,

    /// Output to debug log.
    dlog = norn_syscall_start,

    _,

    // Check if the syscall number is valid.
    comptime {
        for (std.enums.values(Syscall)) |e| {
            if (@intFromEnum(e) >= num_syscall) {
                @compileError(std.fmt.comptimePrint("Invalid syscall number: {d}", .{@intFromEnum(e)}));
            }
        }
    }

    /// Number of system calls.
    const num_syscall = 512;
    /// Number of system calls.
    const norn_syscall_start = 500;
    /// Maximum syscall number.
    const max_syscall = num_syscall - 1;

    /// System call table.
    const syscall_table: [num_syscall]Handler = blk: {
        var table: [num_syscall]Handler = undefined;

        const sys_unhandled = sys(unhandledSyscallHandler);
        for (0..num_syscall) |i| {
            table[i] = sys_unhandled;
        }

        for (std.enums.values(Syscall)) |e| {
            table[@intFromEnum(e)] = switch (e) {
                .read => sys(sysRead),
                .write => sys(sysWrite),
                .mprotect => sys(sysMemoryProtect),
                .brk => sys(norn.mm.sysBrk),
                .ioctl => sys(sysIoctl),
                .writev => sys(sysWriteVec),
                .arch_prctl => sys(norn.prctl.sysArchPrctl),
                .getuid => sys(sysGetUid),
                .set_tid_address => sys(ignoredSyscallHandler),
                .set_robust_list => sys(ignoredSyscallHandler),
                .exit_group => sys(sysExitGroup),
                .newfstatat => sys(sysNewFstatAt),
                .dlog => sys(sysDebugLog),
                .readlinkat => sys(ignoredSyscallHandler),
                .prlimit => sys(ignoredSyscallHandler),
                .rseq => sys(ignoredSyscallHandler),
                .getrandom => sys(sysGetRandom),
                else => sys(unhandledSyscallHandler),
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
        if (@intFromEnum(self) >= num_syscall) {
            return Error.Inval;
        }
        return syscall_table[@intFromEnum(self)](ctx, arg1, arg2, arg3, arg4, arg5, arg6);
    }

    /// Create a system call enum from a syscall number.
    pub inline fn from(nr: u64) Syscall {
        return @enumFromInt(nr);
    }
};

/// Convert a syscall argument to the expected type.
fn convert(comptime T: type, arg: u64) T {
    return switch (@typeInfo(T)) {
        .pointer => @ptrFromInt(arg),
        .int => switch (@bitSizeOf(T)) {
            8 => @bitCast(@as(u8, @truncate(arg))),
            16 => @bitCast(@as(u16, @truncate(arg))),
            32 => @bitCast(@as(u32, @truncate(arg))),
            64 => @bitCast(@as(u64, @truncate(arg))),
            else => @compileError("convert(): Invalid integer size"),
        },
        .@"enum" => @enumFromInt(arg),
        .@"struct" => @bitCast(arg),
        else => @compileError(std.fmt.comptimePrint("convert(): Invalid type: {s}", .{@typeName(T)})),
    };
}

/// Syscall wrapper.
///
/// This function converts an syscall handler function to have the fixed signature `Handler`.
fn sys(comptime handler: anytype) Handler {
    const func = @typeInfo(@TypeOf(handler)).@"fn";

    const S = struct {
        inline fn ArgType(comptime i: usize) type {
            return func.params[i].type orelse @compileError("sys(): Invalid parameter type");
        }

        fn f0(ctx: *Context, _: u64, _: u64, _: u64, _: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx);
        }
        fn f1(ctx: *Context, arg1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx, convert(ArgType(1), arg1));
        }
        fn f2(ctx: *Context, arg1: u64, arg2: u64, _: u64, _: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx, convert(ArgType(1), arg1), convert(ArgType(2), arg2));
        }
        fn f3(ctx: *Context, arg1: u64, arg2: u64, arg3: u64, _: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx, convert(ArgType(1), arg1), convert(ArgType(2), arg2), convert(ArgType(3), arg3));
        }
        fn f4(ctx: *Context, arg1: u64, arg2: u64, arg3: u64, arg4: u64, _: u64, _: u64) Error!i64 {
            return handler(ctx, convert(ArgType(1), arg1), convert(ArgType(2), arg2), convert(ArgType(3), arg3), convert(ArgType(4), arg4));
        }
        fn f5(ctx: *Context, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, _: u64) Error!i64 {
            return handler(ctx, convert(ArgType(1), arg1), convert(ArgType(2), arg2), convert(ArgType(3), arg3), convert(ArgType(4), arg4), convert(ArgType(5), arg5));
        }
        fn f6(ctx: *Context, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) Error!i64 {
            return handler(ctx, convert(ArgType(1), arg1), convert(ArgType(2), arg2), convert(ArgType(3), arg3), convert(ArgType(4), arg4), convert(ArgType(5), arg5), convert(ArgType(6), arg6));
        }
    };

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
// Misc Handlers
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

    if (option.debug_syscall) {
        debugPrintContext(ctx);
    }

    if (norn.is_runtime_test) {
        log.info("", .{});
        log.info("Reached unreachable unhandled syscall handler.", .{});
        norn.terminateQemu(0);
    }

    return Error.Unimplemented;
}

/// Handler for ignored syscalls.
fn ignoredSyscallHandler(ctx: *Context) Error!i64 {
    if (option.debug_syscall) {
        debugPrintContext(ctx);
    }

    return error.Unimplemented;
}

fn debugPrintContext(ctx: *Context) void {
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
}

// =============================================================
// Temporary syscall handlers.
// =============================================================

/// Flags for `getrandom` syscall.
const GetRandomFlags = packed struct(u64) {
    /// Don't block if no data is available.
    non_block: bool,
    /// No effect.
    random: bool,

    /// Reserved.
    _reserved: u62,
};

/// Syscall handler for `getrandom`.
///
/// Fill the buffer with random bytes.
/// Note that this function does not provide cryptographically secure random bytes.
fn sysGetRandom(_: *Context, buf: [*]u8, size: usize, flags: GetRandomFlags) Error!i64 {
    if (flags._reserved != 0) return Error.Inval;

    const time = norn.timer.getTimestamp();
    var prng = std.Random.DefaultPrng.init(time);
    const rand = prng.random();

    rand.bytes(buf[0..size]);

    return @bitCast(size);
}

/// Syscall handler for `read`.
///
/// Currently, only supports reading from stdin (fd=0).
fn sysRead(_: *Context, fd: u64, buf: [*]u8, size: usize) Error!i64 {
    if (fd != 0) {
        norn.unimplemented("sysRead(): fd other than 0.");
    }

    log.debug(
        "sysRead(): fd={d} buf={X:0>16} size={X:0>16}",
        .{ fd, @intFromPtr(buf), size },
    );
    norn.unimplemented("sysRead()");
}

/// Syscall handler for `write`.
///
/// Currently, only supports writing to stdout (fd=1) and stderr (fd=2).
/// These outputs are printed to the debug log.
fn sysWrite(_: *Context, fd: u64, buf: [*]const u8, count: usize) Error!i64 {
    if (fd != 1 and fd != 2) {
        norn.unimplemented("sysWrite(): fd other than 1 or 2.");
    }

    // Print to the serial log.
    norn.getSerial().writeString(buf[0..count]);

    return @bitCast(count);
}

/// Command for `ioctl`.
const IoctlCommand = enum(u64) {
    _,
};

/// Special file descriptor for CWD.
const fd_cwd: i32 = -100;

/// Syscall handler for `newfstatat`.
fn sysNewFstatAt(_: *Context, fd: i32, pathname: [*:0]const u8, buf: *fs.Stat, _: u64) Error!i64 {
    if (fd != 0 and fd != 1 and fd != 2 and fd != fd_cwd) {
        norn.unimplemented("sysNewFstatAt(): fd other than 1 or 2.");
    }

    if (fs.getDentryFromFd(fd)) |dent| {
        const stat = fs.statAt(
            dent,
            util.sentineledToSlice(pathname),
        ) catch return Error.Noent;
        buf.* = stat;
    } else return Error.Noent;

    return 0;
}

/// Syscall handler for `ioctl`.
fn sysIoctl(_: *Context, fd: u64, cmd: IoctlCommand) Error!i64 {
    if (fd != 0 and fd != 1 and fd != 2) {
        norn.unimplemented("sysIoctl(): fd other than 1 or 2.");
    }

    switch (cmd) {
        _ => {
            log.warn("Unsupported ioctl command: {X:0>16}", .{cmd});
            return Error.Unimplemented;
        },
    }
}

const IoVec = packed struct {
    /// Pointer to the buffer.
    buf: [*]const u8,
    /// Size of the buffer.
    len: usize,
};

fn sysWriteVec(_: *Context, fd: u64, iov: [*]const IoVec, count: usize) Error!i64 {
    if (fd != 1 and fd != 2) {
        norn.unimplemented("sysWriteVec(): fd other than 1 or 2.");
    }

    var sum: usize = 0;
    for (iov[0..count]) |vec| {
        if (vec.len == 0) continue;
        norn.getSerial().writeString(vec.buf[0..vec.len]);
        sum += vec.len;
    }

    return @bitCast(sum);
}

// TODO: implement
fn sysMemoryProtect(_: *Context, addr: u64, len: u64, prot: u64) Error!i64 {
    log.warn("mprotect(): addr={X:0>16} len={X:0>16} prot={X:0>16}", .{ addr, len, prot });
    log.warn("ignoring mprotect syscall", .{});
    return 0;
}

/// Syscall handler for `exit_group`.
/// TODO: implement
fn sysExitGroup(_: *Context, status: i32) Error!i64 {
    log.debug("exit_group(): status={d}", .{status});
    norn.unimplemented("sysExitGroup()");
}

/// Syscall handler for `getuid`.
fn sysGetUid(_: *Context) Error!i64 {
    const current = norn.sched.getCurrentTask();
    return @intCast(current.cred.uid);
}

/// Syscall handler for `dlog`.
///
/// Print the given string to the debug log.
///
/// - `str`: Pointer to the null-terminated string.
/// - `size`: Size of the string.
fn sysDebugLog(_: *Context, str: [*]const u8, size: usize) Error!i64 {
    log.debug("{s}", .{str[0..size]});
    return 0;
}

// =============================================================
// Imports.
// =============================================================

const option = @import("option");
const std = @import("std");
const log = std.log.scoped(.syscall);

const norn = @import("norn");
const arch = norn.arch;
const errno = norn.errno;
const fs = norn.fs;
const sched = norn.sched;
const util = norn.util;

const VmArea = norn.mm.VmArea;
const VmFlags = norn.mm.VmFlags;
