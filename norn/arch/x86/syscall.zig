//! cf. SDM Vol.3A 5.8.8

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

pub const Error = error{
    /// The operation is not supported.
    NotSupported,
};

/// Register context for x86-64 syscall.
pub const Registers = packed struct {
    // Callee-saved registers.
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,

    // Caller-saved registers.
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rax: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,

    // Special registers.
    orig_rax: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
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
    const fmask = regs.MsrFmask{ .flags = 0 };
    am.wrmsr(.fmask, fmask); // syscall does not clear RFLAGS.

    // Enable SYSCALL/SYSRET instructions.
    var efer = am.rdmsr(regs.MsrEfer, .efer);
    efer.sce = true;
    am.wrmsr(.efer, efer);
}

/// Dispatch system call.
export fn dispatchSyscall(nr: u64, ctx: *Registers) callconv(.C) i64 {
    asm volatile (
        \\mov %[kernel_ds], %dx
        \\mov %%dx, %%ds
        :
        : [kernel_ds] "n" (@as(u16, @bitCast(gdt.SegmentSelector{
            .rpl = 0,
            .index = gdt.kernel_ds_index,
          }))),
    );

    const ret = Syscall.from(nr).getHandler()(
        ctx,
        ctx.rdi,
        ctx.rsi,
        ctx.rdx,
        ctx.r10,
        ctx.r8,
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
export fn syscallEntry() callconv(.Naked) void {
    // SYSCALL sets below registers.
    //  R11: RFLAGS
    //  RCX: RIP
    asm volatile (
        \\
        // NOTE: Norn kernel shares the same page tables with user (no KPTI).
        // So we don't have to switch CR3 here.

        // SYSCALL does not save RSP, so we need to save it here.
        \\swapgs
        \\movq %%rsp, %%gs:(%[user_stack])
        // Switch to kernel stack
        \\movq %%gs:(%[kernel_stack]), %%rsp

        // Construct context
        \\pushq %[ss]                   # ss
        \\pushq %%gs:(%[user_stack])    # sp
        \\pushq %%r11                   # rflags
        \\pushq %[cs]                   # cs
        \\pushq %%rcx                   # rip
        \\pushq %%rax                   # orig_rax
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

        // Dispatch syscall
        \\callq dispatchSyscall

        // Restore the stack.
        \\movq 8(%%rsp), %%rsp

        // Restore context
        \\add  $(6*8), %%rsp
        \\popq %%r11                    # r11
        \\popq %%r10                    # r10
        \\popq %%r9                     # r9
        \\popq %%r8                     # r8
        \\popq %%rax                    # rax
        \\popq %%rcx                    # rcx
        \\popq %%rdx                    # rdx
        \\popq %%rsi                    # rsi
        \\popq %%rdi                    # rdi
        \\add  $8, %%rsp                # orig_rax
        \\popq %%rcx                    # rip
        \\add  $8, %%rsp                # cs
        \\popq %%r11                    # rflags

        // Restore user stack.
        \\movq %%gs:(%[user_stack]), %%rsp

        // Return to user.
        \\swapgs
        \\sysretq
        :
        : [ss] "i" (gdt.SegmentSelector{ .index = gdt.user_ds_index, .rpl = 3 }),
          [cs] "i" (gdt.SegmentSelector{ .index = gdt.user_cs_index, .rpl = 3 }),
          [user_stack] "{r9}" (&task.current_tss.rsp1), // We can use caller-saved register here
          [kernel_stack] "{r10}" (&task.current_tss.rsp0),
    );
}
