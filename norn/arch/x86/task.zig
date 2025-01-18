const std = @import("std");

const norn = @import("norn");
const Thread = norn.thread.Thread;

const gdt = @import("gdt.zig");
const isr = @import("isr.zig");
const regs = @import("registers.zig");

/// Initial value of RFLAGS register for tasks.
const initial_rip: regs.Rflags = .{
    .cf = false,
    .pf = false,
    .af = false,
    .zf = false,
    .sf = false,
    .tf = false,
    .ie = true,
    .df = false,
    .of = false,
    .iopl = 0,
    .nt = false,
    .rf = false,
    .vm = false,
    .ac = false,
    .vif = false,
    .vip = false,
    .id = false,
    .aes = false,
    .ai = false,
};

/// Callee-saved registers saved and restored by context switch.
const ContextStackFrame = packed struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbx: u64,
    rbp: u64,
    rip: u64,
};

/// Set up the initial stack frame for an orphaned task.
/// Returns the pointer to the stack frame.
pub fn initOrphanFrame(rsp: [*]u8, ip: u64) [*]u8 {
    const new_rsp = @intFromPtr(rsp) - @sizeOf(ContextStackFrame);
    const context: *ContextStackFrame = @ptrFromInt(new_rsp);
    context.* = ContextStackFrame{
        .r15 = 0,
        .r14 = 0,
        .r13 = 0,
        .r12 = 0,
        .rbx = 0,
        .rbp = 0,
        .rip = ip,
    };

    return @ptrCast(context);
}

/// Switch to the initial task.
///
/// Different from switchTo(), this function is called only once.
/// No callee-saved registers are saved and restored.
pub const initialSwitchTo: *const fn (init: *Thread) callconv(.C) noreturn = @ptrCast(&initialSwitchToImpl);
noinline fn initialSwitchToImpl() callconv(.Naked) noreturn {
    const sp_offset = @offsetOf(Thread, "stack_ptr");

    asm volatile (std.fmt.comptimePrint(
            \\
            // Switch to the next task's stack.
            \\movq {d}(%%rdi), %%rsp
            // Restore callee-saved registers.
            \\popq %%r15
            \\popq %%r14
            \\popq %%r13
            \\popq %%r12
            \\popq %%rbx
            \\popq %%rbp
            \\jmp switchToInternal
        , .{sp_offset}));
}

/// Switch to the next task.
///
/// Callee-saved registers of the previous task are saved, then the stack is switched to the next task.
/// The next task's stack has the saved callee-saved registers and RIP.
/// This function returns to the address the next task's stack pointer points to.
/// That is normally the caller of this function.
/// But it would be the crafted address if the next task is an orphaned task.
///
/// We cast the function pointer to call it in C convention though actually it must be naked.
pub const switchTo: *const fn (prev: *Thread, next: *Thread) callconv(.C) void = @ptrCast(&switchToImpl);
noinline fn switchToImpl() callconv(.Naked) void {
    const sp_offset = @offsetOf(Thread, "stack_ptr");

    asm volatile (std.fmt.comptimePrint(
            \\
            // Save callee-saved registers.
            \\pushq %%rbp
            \\pushq %%rbx
            \\pushq %%r12
            \\pushq %%r13
            \\pushq %%r14
            \\pushq %%r15
            // Switch to the next task's stack.
            \\movq %%rsp, {d}(%%rdi)
            \\movq {d}(%%rsi), %%rsp
            // Restore callee-saved registers.
            \\popq %%r15
            \\popq %%r14
            \\popq %%r13
            \\popq %%r12
            \\popq %%rbx
            \\popq %%rbp
            // We don't "call" here to leave the return address on the top of stack.
            // switchToInternal() returns to the caller of this function
            // (or any other function the stack pointer points to).
            \\jmp switchToInternal
        , .{ sp_offset, sp_offset }));
}

/// Context switch continued from switchTo().
///
/// On this function, stack is already switched to the next task's.
/// Callee-saved registers are already saved and restored, so we don't care about them.
///
/// This function returns to the caller of switchTo().
export fn switchToInternal(_: *Thread, _: *Thread) callconv(.C) void {
    // TODO Save and restore other context including segment registers.
}
