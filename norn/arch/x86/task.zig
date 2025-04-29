pub const TaskError = arch.ArchError || mem.MemError;

/// Current TSS.
///
/// Should be exported so that syscall entrypoint can access it.
pub export var current_tss: TaskStateSegment linksection(pcpu.section) = undefined;

/// Size in bytes of kernel stack.
const kernel_stack_size = 5 * mem.size_4kib;
/// Number of pages for kernel stack.
const kernel_stack_num_pages = kernel_stack_size / mem.size_4kib;

/// x64 version of architecture-specific task context.
const X64Context = struct {
    /// TSS
    tss: *TaskStateSegment,
};

/// Initial value of RFLAGS register for tasks.
const initial_rflags = std.mem.zeroInit(regs.Rflags, .{ .ie = true });

/// Stack frame for initial context switch.
///
/// This contains callee-saved registers, that are saved and restored by context switch.
const OrphanFrame = packed struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbx: u64,
    rbp: u64,
    rip: u64,
};

/// Arch-specific initialization of kernel thread.
pub fn setupNewTask(task: *Thread, ip: u64, args: ?*anyopaque) TaskError!void {
    // Init page table.
    task.mm.pgtbl = try arch.mem.createPageTables();

    // Init kernel stack.
    const stack = try mem.vm_allocator.allocate(kernel_stack_size + mem.size_4kib);
    errdefer mem.vm_allocator.free(stack);
    const stack_ptr = stack.ptr + stack.len;
    task.kernel_stack = stack;
    task.kernel_stack_ptr = stack_ptr;

    // Set a guard page for the kernel stack.
    try arch.mem.changeAttribute(
        arch.mem.getRootTable(),
        @intFromPtr(stack.ptr),
        mem.size_4kib,
        .read_only,
    );

    // Init TSS.
    const tss = try mem.general_allocator.create(TaskStateSegment);
    tss.* = TaskStateSegment{
        .rsp0 = @intFromPtr(task.kernel_stack.ptr), // TODO: fix the value
    };
    x64ctx(task).tss = tss;

    // Setup CPU context.
    // The context holds an entry point (R8) and arguments (R9) for kernel thread.
    // If the task has an user thread, this function additionally holds a user context.
    task.kernel_stack_ptr -= @sizeOf(CpuContext);
    {
        const cpu_context: *CpuContext = @alignCast(@ptrCast(task.kernel_stack_ptr));
        norn.rtt.expectEqual(0, @intFromPtr(cpu_context) % 16);

        // Zero clear.
        cpu_context.* = std.mem.zeroInit(CpuContext, .{});

        // Kernel thread entry and arguments.
        cpu_context.r8 = ip;
        cpu_context.r9 = @intFromPtr(args);

        // User context.
        cpu_context.rflags = @bitCast(initial_rflags);
    }

    // Setup orphan frame.
    task.kernel_stack_ptr -= @sizeOf(OrphanFrame);
    {
        const orphan_frame: *OrphanFrame = @alignCast(@ptrCast(task.kernel_stack_ptr));
        norn.rtt.expectEqual(0, @intFromPtr(orphan_frame) % 16);
        orphan_frame.* = OrphanFrame{
            .r12 = 0,
            .r13 = 0,
            .r14 = 0,
            .r15 = 0,
            .rbx = 0,
            .rbp = 0,
            .rip = @intFromPtr(&kernelThreadArchEntry),
        };
    }
}

/// Initialize the user CPU state.
pub fn setUserContext(task: *Thread, rip: u64, rsp: u64) void {
    const cpu_context = getCpuContextFromStack(task);
    cpu_context.rip = rip;
    cpu_context.rsp = rsp;
}

/// Convert arch-specific task context to x64 context.
inline fn x64ctx(task: *Thread) *X64Context {
    return @ptrCast(&task.arch_ctx);
}

/// Get CPU context from kernel stack.
///
/// This functions can be called only before the thread starts.
fn getCpuContextFromStack(task: *Thread) *CpuContext {
    const stack_bottom = @intFromPtr(task.kernel_stack.ptr) + kernel_stack_size;
    return @ptrFromInt(stack_bottom - @sizeOf(OrphanFrame) - @sizeOf(CpuContext));
}

// =============================================================
// Kernel thread entry point.
// =============================================================

/// Architecture-specific kernel thread entry.
///
/// All entry points of kernel threads are set to this function.
noinline fn kernelThreadArchEntry() noreturn {
    const task = sched.getCurrentTask();
    const cpu_context: *const CpuContext = @ptrFromInt(@intFromPtr(task.kernel_stack_ptr) + @sizeOf(OrphanFrame));

    asm volatile (
        \\movq %[args], %%rdi
        \\callq *%[entry]
        :
        : [args] "r" (cpu_context.r9),
          [entry] "r" (cpu_context.r8),
        : "memory"
    );

    unreachable; // TODO
}

// =============================================================
// Context switch functions.
// =============================================================

/// Switch to the initial task.
///
/// Different from switchTo(), this function is called only once.
/// No callee-saved registers are saved and restored.
pub const initialSwitchTo: *const fn (init: *Thread) callconv(.c) noreturn = @ptrCast(&initialSwitchToImpl);
noinline fn initialSwitchToImpl() callconv(.naked) noreturn {
    const sp_offset = @offsetOf(Thread, "kernel_stack_ptr");

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
    const sp_offset = @offsetOf(Thread, "kernel_stack_ptr");

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
    const rsp0 = @intFromPtr(next.kernel_stack_ptr); // TODO: Should not set this kernel stack.
    x64ctx(next).tss.rsp0 = rsp0;
    pcpu.ptr(&current_tss).rsp0 = rsp0;

    // Switch CR3.
    norn.arch.mem.setPagetable(next.mm.pgtbl);

    // Return to the caller of switchTo().
    return;
}

/// Enter userland.
pub noinline fn enterUser() noreturn {
    const task = sched.getCurrentTask();
    const cpu_context = getCpuContextFromStack(task);

    arch.disableIrq();

    asm volatile (
        \\movq %[ctx], %%rdi
        \\callq enterUserRestoreRegisters
        :
        : [ctx] "r" (cpu_context),
    );

    unreachable;
}

/// Restore CPU registers from CpuContext and enter user mode using SYSRETQ.
///
/// It's hidden but this function takes a pointer to CpuContext as an argument.
///
/// Caller-saved registers are cleared.
/// Other registers are copied from CPU context of the thread.
export fn enterUserRestoreRegisters() callconv(.naked) noreturn {
    // NOTE: Zig v0.14.0 does not support "%c" modifier for inline assembly.
    // For example, we want to write "%c[r15_offset](%%rax), (%%r15)" and ": [r15_offset] "i" (@offsetOf(CpuContext, "r15"))",
    // that's compiled to "movq 0(%%rax), %%r15" (not "movq $0(%%rax), %%r15"),
    // but that's not supported yet.
    // See https://github.com/ziglang/zig/issues/9477
    asm volatile (std.fmt.comptimePrint(
            \\movq %%rdi, %%rax
            // Callee-saved registers
            \\movq {[r15_offset]}(%%rax), %%r15
            \\movq {[r14_offset]}(%%rax), %%r14
            \\movq {[r13_offset]}(%%rax), %%r13
            \\movq {[r12_offset]}(%%rax), %%r12
            \\movq {[rbx_offset]}(%%rax), %%rbx
            \\movq {[rbp_offset]}(%%rax), %%rbp
            // Caller-saved registers
            \\xorq %%r11, %%r11
            \\xorq %%r10, %%r10
            \\xorq %%r9, %%r9
            \\xorq %%r8, %%r8
            \\xorq %%rdx, %%rdx
            \\xorq %%rsi, %%rsi
            \\xorq %%rdi, %%rdi
            // RFLAGS and RIP
            \\movq {[rflags_offset]}(%%rax), %%r11   # RFLAGS
            \\movq {[rip_offset]}(%%rax), %%rcx      # RIP
            // RSP
            \\movq {[rsp_offset]}(%%rax), %%rsp
            // SYSRET
            \\movq $0, %%rax
            \\swapgs
            \\sysretq
        ,
            .{
                .r15_offset = @offsetOf(CpuContext, "r15"),
                .r14_offset = @offsetOf(CpuContext, "r14"),
                .r13_offset = @offsetOf(CpuContext, "r13"),
                .r12_offset = @offsetOf(CpuContext, "r12"),
                .rbx_offset = @offsetOf(CpuContext, "rbx"),
                .rbp_offset = @offsetOf(CpuContext, "rbp"),

                .rflags_offset = @offsetOf(CpuContext, "rflags"),
                .rip_offset = @offsetOf(CpuContext, "rip"),

                .rsp_offset = @offsetOf(CpuContext, "rsp"),
            },
        ));
}

// =============================================================
// Ipmorts
// =============================================================

const std = @import("std");

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const pcpu = norn.pcpu;
const sched = norn.sched;
const Thread = norn.thread.Thread;

const gdt = @import("gdt.zig");
const isr = @import("isr.zig");
const regs = @import("registers.zig");
const syscall = @import("syscall.zig");
const CpuContext = regs.CpuContext;
const TaskStateSegment = gdt.TaskStateSegment;
