//! cf. SDM Vol.3A 5.8.8

pub const Error = error{
    /// The operation is not supported.
    NotSupported,
};

/// Setup and enable system calls for this CPU.
pub fn init() Error!void {
    // Check iF SYSCALL and SYSRET instructions are supported.
    const ext_feat = cpuid.Leaf.ext_proc_signature.query(null);
    const is_supported = bits.isset(ext_feat.edx, 11);
    if (!is_supported) return Error.NotSupported;

    // Set MSRs.
    const lstar = regs.MsrLstar{ .rip = @intFromPtr(&syscallEntry) };
    am.wrmsr(.lstar, lstar);
    const star = regs.MsrStar{
        .syscall_cs_ss = @bitCast(gdt.SegmentSelector{
            .index = gdt.kernel_cs_index,
            .rpl = 0, // RPL is ignored by HW.
        }),
        .sysret_cs_ss = @bitCast(gdt.SegmentSelector{
            .index = gdt.user_cs32_index,
            .rpl = 3,
        }),
    };
    am.wrmsr(.star, star);
    const fmask = regs.MsrFmask{ .flags = 0x200 }; // IE
    am.wrmsr(.fmask, fmask); // syscall does not clear RFLAGS.

    // Enable SYSCALL/SYSRET instructions.
    var efer = am.rdmsr(regs.MsrEfer, .efer);
    efer.sce = true;
    am.wrmsr(.efer, efer);
}

/// Dispatch system call.
export fn dispatchSyscall(nr: u64, ctx: *CpuContext) callconv(.c) i64 {
    asm volatile (
        \\mov %[kernel_ds], %dx
        \\mov %%dx, %%ds
        :
        : [kernel_ds] "n" (@as(u16, @bitCast(gdt.SegmentSelector{
            .rpl = 0,
            .index = gdt.kernel_ds_index,
          }))),
    );

    const ret = Syscall.from(nr).invoke(
        ctx,
        ctx.rdi,
        ctx.rsi,
        ctx.rdx,
        ctx.r10,
        ctx.r8,
        ctx.r9,
    ) catch |err| -@intFromEnum(errno.convertToErrno(err));

    asm volatile (
        \\mov %[user_ds], %dx
        \\mov %%dx, %%ds
        :
        : [user_ds] "n" (@as(u16, @bitCast(gdt.SegmentSelector{
            .rpl = 3,
            .index = gdt.user_ds_index,
          }))),
    );

    return ret;
}

/// SYSCALL entry point.
export fn syscallEntry() callconv(.naked) void {
    // SYSCALL sets below registers.
    //  R11: RFLAGS
    //  RCX: RIP
    //
    // On entry, interrupts are disabled since IA32_FMASK masks IF bit.
    asm volatile (
        \\
        // NOTE: Norn kernel shares the same page tables with user (no KPTI).
        // So we don't have to switch CR3 here.

        // SYSCALL does not save RSP, so we need to save it here.
        \\swapgs
        \\movq %%rsp, %%gs:(%[user_stack])
        // Switch to kernel stack
        \\movq %%gs:(%[kernel_stack]), %%rsp

        // TODO: Re-enable interrupts if necessary.

        // Construct context
        \\pushq %[ss]                   # ss
        \\pushq %%gs:(%[user_stack])    # sp
        \\pushq %%r11                   # rflags
        \\pushq %[cs]                   # cs
        \\pushq %%rcx                   # rip
        \\pushq %%rax                   # orig_rax
        \\pushq $0                      # unused
        \\pushq %%rdi                   # rdi
        \\pushq %%rsi                   # rsi
        \\pushq %%rdx                   # rdx
        \\pushq %%rcx                   # rcx
        \\pushq $-1                     # rax
        \\pushq %%r8                    # r8
        \\pushq %%r9                    # r9
        \\pushq %%r10                   # r10
        \\pushq %%r11                   # r11

        // Skip caller-saved registers (rbp, rbx, and r12-r15)
        \\sub $(6*8), %%rsp
        \\
        // Prepare arguments
        \\movq %%rax, %%rdi
        \\movq %%rsp, %%rsi

        // Align stack to 16 bytes.
        \\pushq %%rsp
        \\pushq (%%rsp)
        \\andq $-0x10, %%rsp

        // Save XMM registers
        // TODO: Don't use SSE registers in Norn.
        \\subq $(16*8), %%rsp
        \\movdqu %%xmm0, (%%rsp)
        \\movdqu %%xmm1, 16(%%rsp)
        \\movdqu %%xmm2, 32(%%rsp)
        \\movdqu %%xmm3, 48(%%rsp)
        \\movdqu %%xmm4, 64(%%rsp)
        \\movdqu %%xmm5, 80(%%rsp)
        \\movdqu %%xmm6, 96(%%rsp)
        \\movdqu %%xmm7, 112(%%rsp)

        // Dispatch syscall
        \\callq dispatchSyscall

        // Resoter XMM registers
        // TODO: Don't use SSE registers in Norn.
        \\movdqu (%%rsp), %%xmm0
        \\movdqu 16(%%rsp), %%xmm1
        \\movdqu 32(%%rsp), %%xmm2
        \\movdqu 48(%%rsp), %%xmm3
        \\movdqu 64(%%rsp), %%xmm4
        \\movdqu 80(%%rsp), %%xmm5
        \\movdqu 96(%%rsp), %%xmm6
        \\movdqu 112(%%rsp), %%xmm7
        \\addq $(16*8), %%rsp

        // Restore the stack.
        \\movq 8(%%rsp), %%rsp

        // Restore context
        \\add  $(6*8), %%rsp
        \\popq %%r11                    # r11
        \\popq %%r10                    # r10
        \\popq %%r9                     # r9
        \\popq %%r8                     # r8
        \\add  $8, %%rsp                # rax
        \\popq %%rcx                    # rcx
        \\popq %%rdx                    # rdx
        \\popq %%rsi                    # rsi
        \\popq %%rdi                    # rdi
        \\add  $0x10, %%rsp             # orig_rax & unused
        \\popq %%rcx                    # rip
        \\add  $8, %%rsp                # cs
        \\popq %%r11                    # rflags

        // TODO: Disable interrupts.

        // Restore user stack.
        \\movq %%gs:(%[user_stack]), %%rsp

        // Return to user.
        \\swapgs
        \\sysretq
        :
        : [ss] "i" (gdt.SegmentSelector{ .index = gdt.user_ds_index, .rpl = 3 }),
          [cs] "i" (gdt.SegmentSelector{ .index = gdt.user_cs_index, .rpl = 3 }),
          [user_stack] "{r9}" (&task.current_tss.rsp1), // We can use caller-saved register here
          [kernel_stack] "{r11}" (&task.current_tss.rsp0),
    );
}

const std = @import("std");

const norn = @import("norn");
const bits = norn.bits;
const errno = norn.errno;
const pcpu = norn.pcpu;
const Syscall = norn.syscall.Syscall;

const am = @import("asm.zig");
const cpuid = @import("cpuid.zig");
const gdt = @import("gdt.zig");
const regs = @import("registers.zig");
const task = @import("task.zig");
const CpuContext = regs.CpuContext;
