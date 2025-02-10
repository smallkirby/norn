const std = @import("std");
const log = std.log.scoped(.init);

const norn = @import("norn");
const sched = norn.sched;
const thread = norn.thread;

/// Initial task of Norn kernel with PID 1.
pub fn initialTask() noreturn {
    log.debug("Initial task started.", .{});

    asm volatile (
        \\jmp debugEnterUser
    );

    {
        log.warn("Reached end of initial task.", .{});
        norn.terminateQemu(0);
        norn.unimplemented("initialTask() reached its end.");
    }
}

/// Initial userland task for debugging purposes.
export fn debugUserTask() noreturn {
    while (true) {
        asm volatile (
            \\nop
            \\movq $0, %%rax
            \\syscall
        );
    }
}

/// Enter userland task with hardcoded context.
///
/// TODO: Debug-purpose only. Remove this.
export fn debugEnterUser() callconv(.Naked) void {
    asm volatile (
        \\cli
        // SS (RPL = 3)
        \\movq $(4 << 3 + 3), %%rdi
        \\pushq %%rdi
        // RSP
        \\movq %%rsp, %%rdi
        \\pushq %%rdi
        // RFLAGS
        \\movq $0x02, %%rdi
        \\pushq %%rdi
        // CS (RPL = 3)
        \\movq $(3 << 3 + 3), %%rdi
        \\pushq %%rdi
        // RIP
        \\movq %[rip], %%rdi
        \\pushq %%rdi
        // IRETQ
        \\iretq
        :
        : [rip] "r" (&debugUserTask),
    );
}
