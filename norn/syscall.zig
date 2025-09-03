/// POSIX-compatible error set.
pub const SysError = errno.Error;

/// List of system calls.
///
/// NOTE that the entries are used only at compile time
/// to define a system call enum type
/// and to construct a syscall table that is referenced to invoke a syscall handler.
const sys_entries = [_]SysEntry{
    // =============================================================
    // POSIX syscalls.
    // =============================================================
    // Read from a file descriptor.
    .new("read", 0, .normal(fs.sys.read)),
    // Write to a file descriptor.
    .new("write", 1, .normal(fs.sys.write)),
    // Close the file.
    .new("close", 3, .normal(fs.sys.close)),
    // Get file status.
    .new("fstat", 5, .normal(fs.sys.fstat)),
    // Set protection on a region of memory.
    .new("mprotect", 10, .normal(mm.sysMemoryProtect)),
    // Change data segment size.
    .new("brk", 12, .normal(norn.mm.sysBrk)),
    // Change a signal action.
    .new("rt_sigaction", 13, .debug(noop)),
    // Change a signal action.
    .new("rt_sigprocmask", 14, .debug(unsupported)),
    // Control device.
    .new("ioctl", 16, .normal(sysIoctl)),
    // Write data into multiple buffers.
    .new("writev", 20, .normal(sysWriteVec)),
    // Get process ID.
    .new("getpid", 39, .normal(sysGetPid)),
    // Get name and information about current kernel.
    .new("uname", 63, .debug(unsupported)),
    // Get current working directory.
    .new("getcwd", 79, .normal(fs.sys.getcwd)),
    // Change working directory.
    .new("chdir", 80, .normal(fs.sys.chdir)),
    // Get user identity.
    .new("arch_prctl", 158, .normal(norn.prctl.sysArchPrctl)),
    // Get user identity.
    .new("getuid", 102, .normal(sysGetUid)),
    // Set user identity.
    .new("setuid", 105, .debug(unsupported)),
    // Get effective user ID.
    .new("geteuid", 107, .debug(unsupported)),
    // Get parent process ID.
    .new("getppid", 110, .debug(unsupported)),
    // Get thread ID.
    .new("gettid", 186, .debug(noop)),
    // Get time in seconds.
    .new("time", 201, .debug(unsupported)),
    // Get directory entries
    .new("getdents64", 217, .normal(fs.sys.getdents64)),
    // Set pointer to thread ID.
    .new("set_tid_address", 218, .debug(unsupported)),
    // Retrieve the time of of the specified clock.
    .new("clock_gettime", 222, .debug(unsupported)),
    // Exit all threads in a process.
    .new("exit_group", 231, .normal(sysExitGroup)),
    // Open and possibly create a file.
    .new("openat", 257, .normal(fs.sys.openat)),
    // Get file status.
    .new("newfstatat", 262, .normal(fs.sys.newfstatat)),
    // Read value of a symbolic link.
    .new("readlinkat", 267, .debug(unsupported)),
    // Get or set list of robust futexes.
    .new("set_robust_list", 273, .debug(unsupported)),
    // Get and set resource limits.
    .new("prlimit", 302, .debug(unsupported)),
    // Obtain a series of random bytes.
    .new("getrandom", 318, .normal(sysGetRandom)),
    // Get extended file status.
    .new("statx", 332, .normal(fs.sys.statx)),
    // Restartable sequences.
    .new("rseq", 334, .debug(unsupported)),

    // =============================================================
    // Norn-specific syscalls
    // =============================================================
    // Output to debug log.
    .new("dlog", 500, .normal(sysDebugLog)),
};

/// Number of system calls.
const num_syscall = 512;
/// Number of system calls.
const norn_syscall_start = 500;
/// Maximum syscall number.
const max_syscall = num_syscall - 1;

/// System call descriptor.
const SysEntry = struct {
    /// Syscall name.
    name: [:0]const u8,
    /// System call number.
    nr: u64,
    /// System call handler.
    handler: SyscallHandler,

    fn new(comptime name: [:0]const u8, comptime nr: u64, comptime handler: SyscallHandler) SysEntry {
        return SysEntry{
            .name = name,
            .nr = nr,
            .handler = handler,
        };
    }
};

/// Table of system calls.
///
/// This table is referenced at runtime to invoke a system call handler.
/// The key value corresponds to a syscall number.
const syscall_table: [num_syscall]SyscallHandler = blk: {
    var table: [num_syscall]SyscallHandler = undefined;

    // Init all handlers as unhandled.
    const sysUnhandledSyscallHandler = SyscallHandler.debug(unhandle);
    for (0..num_syscall) |i| {
        table[i] = sysUnhandledSyscallHandler;
    }

    // Iterate over syscall enum and assign a corresponding handler.
    for (std.enums.values(Syscall)) |s| {
        @setEvalBranchQuota(2000);

        const nr = @intFromEnum(s);
        table[nr] = for (sys_entries) |entry| {
            if (entry.nr == nr) break entry.handler;
        } else @compileError(std.fmt.comptimePrint("Syscall {s} not found", .{@typeName(s)}));
    }

    break :blk table;
};

/// System call enum.
///
/// This enum is constructed at compile time referring to the syscall entries.
const Syscall = blk: {
    var fields: [sys_entries.len]std.builtin.Type.EnumField = undefined;
    for (sys_entries, 0..) |entry, i| {
        fields[i] = .{ .name = entry.name, .value = entry.nr };
    }
    break :blk @Type(.{
        .@"enum" = .{
            .tag_type = u64,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = false,
        },
    });
};

/// Call a system call handler corresponding to the given syscall number.
pub fn invoke(self: Syscall, ctx: *const Context, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) SysError!i64 {
    if (@intFromEnum(self) >= num_syscall) {
        return SysError.InvalidArg;
    }
    if (option.debug_syscall) {
        if (std.enums.tagName(Syscall, self)) |tag| {
            log.debug("syscall: {s}", .{tag});
        } else {
            log.debug("syscall: nr={d}", .{@intFromEnum(self)});
        }
        log.debug("  arg1=0x{X:0>16}, arg2=0x{X:0>16}, arg3=0x{X:0>16}", .{ arg1, arg2, arg3 });
        log.debug("  arg4=0x{X:0>16}, arg5=0x{X:0>16}, arg6=0x{X:0>16}", .{ arg4, arg5, arg6 });
    }

    const ret = switch (syscall_table[@intFromEnum(self)]) {
        ._normal => |f| f(arg1, arg2, arg3, arg4, arg5, arg6),
        ._debug => |f| f(ctx, arg1, arg2, arg3, arg4, arg5, arg6),
    };

    if (option.debug_syscall) {
        if (ret) |value| {
            log.debug("  -> 0x{X}", .{value});
        } else |err| {
            log.debug("  -> {s}", .{@errorName(err)});
        }
    }
    return ret;
}

/// Get a syscall enum from the given nr.
pub fn from(nr: u64) Syscall {
    return @enumFromInt(nr);
}

/// System call handler union.
const SyscallHandler = union(HandlerKind) {
    /// Normal system call handler.
    _normal: NormalHandler,
    /// Debug-purpose system call handler that can take a CPU context.
    _debug: DebugHandler,

    /// Type of syscall handler.
    const HandlerKind = enum {
        _normal,
        _debug,
    };

    /// System call handler function signature.
    const NormalHandler = *const fn (u64, u64, u64, u64, u64, u64) SysError!i64;
    /// Debug-purpose system call handler function signature.
    const DebugHandler = *const fn (*const Context, u64, u64, u64, u64, u64, u64) SysError!i64;

    /// Create a syscall handler.
    fn normal(comptime handler: anytype) SyscallHandler {
        return SyscallHandler{ ._normal = sys(handler) };
    }

    /// Create a debug-purpose syscall handler.
    fn debug(comptime handler: DebugHandler) SyscallHandler {
        return SyscallHandler{ ._debug = handler };
    }

    /// Generate a wrapper function for the syscall handler.
    ///
    /// This function converts an syscall handler function to have the fixed signature `NormalHandler`.
    fn sys(comptime handler: anytype) NormalHandler {
        const func = @typeInfo(@TypeOf(handler)).@"fn";

        const S = struct {
            inline fn ArgType(comptime i: usize) type {
                return func.params[i].type orelse @compileError("sys(): Invalid parameter type");
            }

            fn f0(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) SysError!i64 {
                return handler();
            }
            fn f1(arg1: u64, _: u64, _: u64, _: u64, _: u64, _: u64) SysError!i64 {
                return handler(convert(ArgType(0), arg1));
            }
            fn f2(arg1: u64, arg2: u64, _: u64, _: u64, _: u64, _: u64) SysError!i64 {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2));
            }
            fn f3(arg1: u64, arg2: u64, arg3: u64, _: u64, _: u64, _: u64) SysError!i64 {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2), convert(ArgType(2), arg3));
            }
            fn f4(arg1: u64, arg2: u64, arg3: u64, arg4: u64, _: u64, _: u64) SysError!i64 {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2), convert(ArgType(2), arg3), convert(ArgType(3), arg4));
            }
            fn f5(arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, _: u64) SysError!i64 {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2), convert(ArgType(2), arg3), convert(ArgType(3), arg4), convert(ArgType(4), arg5));
            }
            fn f6(arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) SysError!i64 {
                return handler(convert(ArgType(0), arg1), convert(ArgType(1), arg2), convert(ArgType(2), arg3), convert(ArgType(3), arg4), convert(ArgType(4), arg5), convert(ArgType(5), arg6));
            }
        };

        return switch (func.params.len) {
            0 => return S.f0,
            1 => return S.f1,
            2 => return S.f2,
            3 => return S.f3,
            4 => return S.f4,
            5 => return S.f5,
            6 => return S.f6,
            else => @compileError("Wrapper: Invalid number of parameters"),
        };
    }

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
            .@"enum" => |t| switch (@bitSizeOf(t.tag_type)) {
                8 => @enumFromInt(@as(t.tag_type, @bitCast(@as(u8, @truncate(arg))))),
                16 => @enumFromInt(@as(t.tag_type, @bitCast(@as(u16, @truncate(arg))))),
                32 => @enumFromInt(@as(t.tag_type, @bitCast(@as(u32, @truncate(arg))))),
                64 => @enumFromInt(@as(t.tag_type, @bitCast(@as(u64, @truncate(arg))))),
                else => @compileError("convert(): Invalid enum size"),
            },
            .@"struct" => switch (@bitSizeOf(T)) {
                8 => @bitCast(@as(u8, @truncate(arg))),
                16 => @bitCast(@as(u16, @truncate(arg))),
                32 => @bitCast(@as(u32, @truncate(arg))),
                64 => @bitCast(@as(u64, @truncate(arg))),
                else => @compileError("convert(): Invalid struct size"),
            },
            else => @compileError(std.fmt.comptimePrint("convert(): Invalid type: {s}", .{@typeName(T)})),
        };
    }
};

// =============================================================
// Misc Handlers
// =============================================================

/// Handler for unhandled system calls.
fn unhandle(ctx: *const Context, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) SysError!i64 {
    log.err("Unhandled syscall (nr={d})", .{ctx.spec2.orig_rax});
    log.err("  [1]={X:0>16} [2]={X:0>16} [3]={X:0>16}", .{ arg1, arg2, arg3 });
    log.err("  [4]={X:0>16} [5]={X:0>16} [6]={X:0>16}", .{ arg4, arg5, arg6 });

    debugPrintContext(ctx);

    if (norn.is_runtime_test) {
        log.info("", .{});
        log.info("Reached unreachable unhandled syscall handler.", .{});
        norn.terminateQemu(0);
    }

    return SysError.Unimplemented;
}

/// Handler for unsupported / unimplemented syscalls.
fn unsupported(ctx: *const Context, _: u64, _: u64, _: u64, _: u64, _: u64, _: u64) SysError!i64 {
    log.debug(
        "Unsupported syscall: {s}",
        .{@tagName(@as(Syscall, @enumFromInt(ctx.spec2.orig_rax)))},
    );

    return SysError.Unimplemented;
}

/// Handler for ignored syscalls.
///
/// This handler just returns 0 without any action.
fn noop(ctx: *const Context, _: u64, _: u64, _: u64, _: u64, _: u64, _: u64) SysError!i64 {
    log.debug(
        "Ignored syscall: {s}",
        .{@tagName(@as(Syscall, @enumFromInt(ctx.spec2.orig_rax)))},
    );

    return 0;
}

fn debugPrintContext(ctx: *const Context) void {
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
    log.err("  PID: {d}, comm={s}", .{ task.tid, task.comm orelse "" });
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
    log.err("=== Stack Trace =====================", .{});
    var it = std.debug.StackIterator.init(null, ctx.rbp);
    defer it.deinit();

    var ix: usize = 0;
    if (norn.mem.accessOk(ctx.rbp)) {
        while (it.next()) |frame| : (ix += 1) {
            log.err("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
        }
    } else {
        log.err("Stack frame is not accessible.", .{});
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

/// Syscall handler for `getpid.
fn sysGetPid() SysError!i64 {
    return @bitCast(norn.sched.getCurrentTask().tid);
}

/// Syscall handler for `getrandom`.
///
/// Fill the buffer with random bytes.
/// Note that this function does not provide cryptographically secure random bytes.
fn sysGetRandom(buf: [*]u8, size: usize, flags: GetRandomFlags) SysError!i64 {
    if (flags._reserved != 0) return SysError.InvalidArg;

    const time = norn.timer.getTimestamp();
    var prng = std.Random.DefaultPrng.init(time);
    const rand = prng.random();

    rand.bytes(buf[0..size]);

    return @bitCast(size);
}

/// Command for `ioctl`.
const IoctlCommand = enum(u64) {
    _,
};

/// Syscall handler for `ioctl`.
fn sysIoctl(fd: fs.FileDescriptor, cmd: IoctlCommand) SysError!i64 {
    if (!fd.isSpecial()) {
        norn.unimplemented("sysIoctl(): fd other than 1 or 2.");
    }

    switch (cmd) {
        _ => {
            log.warn("Unsupported ioctl command: {X:0>16}", .{cmd});
            return SysError.Unimplemented;
        },
    }
}

const IoVec = packed struct {
    /// Pointer to the buffer.
    buf: [*]const u8,
    /// Size of the buffer.
    len: usize,
};

fn sysWriteVec(fd: u64, iov: [*]align(8) const IoVec, count: usize) SysError!i64 {
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

/// Syscall handler for `exit_group`.
/// TODO: implement
fn sysExitGroup(status: i32) SysError!i64 {
    log.debug("exit_group(): status={d}", .{status});

    if (norn.is_runtime_test) {
        norn.terminateQemu(0);
    }
    norn.unimplemented("sysExitGroup()");
}

/// Syscall handler for `getuid`.
fn sysGetUid() SysError!i64 {
    const current = norn.sched.getCurrentTask();
    return @intCast(current.cred.uid);
}

/// Syscall handler for `dlog`.
///
/// Print the given string to the debug log.
///
/// - `str`: Pointer to the null-terminated string.
/// - `size`: Size of the string.
fn sysDebugLog(str: [*]const u8, size: usize) SysError!i64 {
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
const mm = norn.mm;
const sched = norn.sched;
const util = norn.util;

const Context = arch.Context;
const VmArea = norn.mm.VmArea;
const VmFlags = norn.mm.VmFlags;
