const std = @import("std");

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const pcpu = norn.pcpu;
const Thread = norn.thread.Thread;

const gdt = @import("gdt.zig");
const isr = @import("isr.zig");
const regs = @import("registers.zig");
const syscall = @import("syscall.zig");
const CpuContext = isr.Context;
const TaskStateSegment = gdt.TaskStateSegment;

pub const Error = mem.Error || arch.Error;

/// Current TSS.
pub var current_tss: TaskStateSegment linksection(pcpu.section) = undefined;

/// Size in bytes of kernel stack.
const kernel_stack_size = 2 * mem.size_4kib;
/// Number of pages for kernel stack.
const kernel_stack_num_pages = kernel_stack_size / mem.size_4kib;

/// x64 version of architecture-specific task context.
const X64Context = struct {
    /// TSS
    tss: *TaskStateSegment,
};

/// Initial value of RFLAGS register for tasks.
const initial_rflags: regs.Rflags = .{
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

/// TODO: doc
pub fn setupNewTask(task: *Thread) Error!void {
    // Init page table.
    task.pgtbl = try arch.mem.createPageTables();

    // Init kernel stack.
    const stack = try mem.page_allocator.allocPages(kernel_stack_num_pages, .normal);
    errdefer mem.page_allocator.freePages(stack);
    const stack_ptr = stack.ptr + stack.len;
    task.stack = stack;
    task.stack_ptr = stack_ptr;

    // Init TSS.
    const tss = try mem.general_allocator.create(TaskStateSegment);
    tss.* = TaskStateSegment{
        .rsp0 = @intFromPtr(task.stack.ptr),
    };
    x64ctx(task).tss = tss;
}

/// Convert arch-specific task context to x64 context.
inline fn x64ctx(task: *Thread) *X64Context {
    return @ptrCast(&task.arch_ctx);
}

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
pub const initialSwitchTo: *const fn (init: *Thread) callconv(.c) noreturn = @ptrCast(&initialSwitchToImpl);
noinline fn initialSwitchToImpl() callconv(.naked) noreturn {
    const sp_offset = @offsetOf(Thread, "stack_ptr");

    asm volatile (std.fmt.comptimePrint(
            \\
            // Switch to the initial task's stack.
            \\movq {d}(%%rdi), %%rsp
            // Move initial task address to RSI for switchToInternal().
            \\movq %%rdi, %%rsi
            // Restore callee-saved registers.
            \\popq %%r15
            \\popq %%r14
            \\popq %%r13
            \\popq %%r12
            \\popq %%rbx
            \\popq %%rbp
            \\
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
pub const switchTo: *const fn (prev: *Thread, next: *Thread) callconv(.c) void = @ptrCast(&switchToImpl);
noinline fn switchToImpl() callconv(.naked) void {
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
export fn switchToInternal(_: *Thread, next: *Thread) callconv(.c) void {
    // Restore TSS.RSP0.
    const rsp0 = @intFromPtr(next.stack_ptr);
    x64ctx(next).tss.rsp0 = rsp0;
    pcpu.thisCpuVar(&current_tss).rsp0 = rsp0;

    // Return to the caller of switchTo().
    return;
}
