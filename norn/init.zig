const std = @import("std");
const log = std.log.scoped(.init);

const norn = @import("norn");
const sched = norn.sched;
const thread = norn.thread;

/// Initial task of Norn kernel with PID 1.
pub fn initialTask() noreturn {
    log.debug("Initial task started.", .{});

    const task = sched.getCurrentTask();

    // Switch CR3
    const pgtbl = task.pgtbl;
    norn.arch.mem.setPagetable(pgtbl);

    // Enter userland.
    debugEnterUser(task.user_stack_ptr.?, task.user_ip.?);

    {
        log.warn("Reached end of initial task.", .{});
        norn.terminateQemu(0);
        norn.unimplemented("initialTask() reached its end.");
    }
}

/// Initial userland task for debugging purposes.
/// TODO: debug-purpose only. Remove this.
pub export fn debugUserTask() noreturn {
    asm volatile (
        \\movq $0x12345678, %%rdi
        \\movq $0xDEADBEEF, %%rsi
        \\movq $0x87654321, %%rdx
        \\movq $0xCAFEBABE, %%r10
        \\movq $0x11223344, %%r8
    );

    while (true) {
        asm volatile (
            \\movq $0, %%rax
            \\syscall
        );
    }
}

/// Enter userland task with hardcoded context.
///
/// TODO: Debug-purpose only. Remove this.
fn debugEnterUser(sp: u64, ip: u64) callconv(.C) void {
    asm volatile (
        \\cli
        // SS (RPL = 3)
        \\movq %[ss], %%r8
        \\pushq %%r8
        // RSP
        \\movq %[rsp], %%r8
        \\pushq %%r8
        // RFLAGS
        \\movq $0x202, %%r8
        \\pushq %%r8
        // CS (RPL = 3)
        \\movq %[cs], %%r8
        \\pushq %%r8
        // RIP
        \\movq %[rip], %%r8
        \\pushq %%r8
        // Save current top of stack
        \\movq %%rsp, %%gs:(%[kernel_stack])
        // Clear registers
        \\movq $0, %%rax
        \\movq $0, %%rbx
        \\movq $0, %%rcx
        \\movq $0, %%rdx
        \\movq $0, %%rsi
        \\movq $0, %%rdi
        \\movq $0, %%rbp
        \\movq $0, %%r8
        \\movq $0, %%r9
        \\movq $0, %%r10
        \\movq $0, %%r11
        \\movq $0, %%r12
        \\movq $0, %%r13
        \\movq $0, %%r14
        \\movq $0, %%r15
        // IRETQ
        \\iretq
        :
        : [rip] "r" (ip),
          [rsp] "r" (sp),
          [kernel_stack] "{r11}" (&norn.arch.task.current_tss.rsp0),
          [cs] "i" (0x06 << 3 | 0b11),
          [ss] "i" (0x05 << 3 | 0b11),
    );
}
