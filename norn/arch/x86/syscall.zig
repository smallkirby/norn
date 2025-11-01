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
        .syscall_cs_ss = @bitCast(gdt.SegSel{
            .index = .kernel_cs,
            .rpl = 0, // RPL is ignored by HW.
        }),
        .sysret_cs_ss = @bitCast(gdt.SegSel{
            .index = .user_cs32,
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
        : [kernel_ds] "n" (@as(u16, @bitCast(gdt.SegSel{
            .rpl = 0,
            .index = .kernel_ds,
          }))),
    );

    const ret = syscall.invoke(
        syscall.from(nr),
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
        : [user_ds] "n" (@as(u16, @bitCast(gdt.SegSel{
            .rpl = 3,
            .index = .user_ds,
          }))),
    );

    return ret;
}

/// SYSCALL entry point.
///
/// On entry, interrupts are disabled since IA32_FMASK masks IF bit.
///
/// Register usage:
///   RAX: syscall number
///   RDI: arg1
///   RSI: arg2
///   RDX: arg3
///   R10: arg4
///   R8:  arg5
///   R9:  arg6
///   RSP: user stack pointer
///   R11: RFLAGS
///   RCX: RIP
///   RBX: callee-saved
///   RBP: callee-saved
///   R12: callee-saved
///   R13: callee-saved
///   R14: callee-saved
///   R15: callee-saved
///
/// Therefore, no registers are usable before saving them.
export fn syscallEntry() callconv(.naked) void {
    // NOTE: Zig v0.14.0 does not support "%c" modifier for inline assembly.
    // That's why we use comptimePrint() instead.
    // See https://github.com/ziglang/zig/issues/9477
    asm volatile (std.fmt.comptimePrint(
            \\
            // NOTE: Norn kernel shares the same page tables with user (no KPTI).
            // So we don't have to switch CR3 here.

            // SYSCALL does not save RSP, so we need to save it here.
            \\swapgs
            \\movq %%rsp, %%gs:(current_tss + {[user_stack_offset]})
            // Switch to kernel stack
            \\movq %%gs:(current_tss + {[kernel_stack_offset]}), %%rsp

            // TODO: Re-enable interrupts if necessary.

            // Construct context
            \\pushq %[ss]                   # ss
            \\pushq %%gs:(current_tss + {[user_stack_offset]}) # sp
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
            \\pushq %%rbx                   # rbx
            \\pushq %%rbp                   # rbp
            \\pushq %%r12                   # r12
            \\pushq %%r13                   # r13
            \\pushq %%r14                   # r14
            \\pushq %%r15                   # r15

            // Clear registers.
            \\xorq %%rsi, %%rsi
            \\xorq %%rdx, %%rdx
            \\xorq %%rcx, %%rcx
            \\xorq %%r8, %%r8
            \\xorq %%r9, %%r9
            \\xorq %%r10, %%r10
            \\xorq %%r11, %%r11
            \\xorq %%r12, %%r12
            \\xorq %%r13, %%r13
            \\xorq %%r14, %%r14
            \\xorq %%r15, %%r15
            \\xorq %%rbp, %%rbp

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
            \\popq %%r15                    # r15
            \\popq %%r14                    # r14
            \\popq %%r13                    # r13
            \\popq %%r12                    # r12
            \\popq %%rbp                    # rbp
            \\popq %%rbx                    # rbx
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
            \\movq %%gs:(current_tss + {[user_stack_offset]}), %%rsp

            // Return to user.
            \\swapgs
            \\sysretq
        , .{
            .user_stack_offset = @offsetOf(gdt.Tss, "rsp1"),
            .kernel_stack_offset = @offsetOf(gdt.Tss, "rsp0"),
        })
        :
        : [ss] "i" (gdt.SegSel{ .index = .user_ds, .rpl = 3 }),
          [cs] "i" (gdt.SegSel{ .index = .user_cs, .rpl = 3 }),
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const bits = norn.bits;
const errno = norn.errno;
const pcpu = norn.pcpu;
const syscall = norn.syscall;

const am = @import("asm.zig");
const cpuid = @import("cpuid.zig");
const gdt = @import("gdt.zig");
const regs = @import("registers.zig");
const task = @import("task.zig");
const CpuContext = regs.CpuContext;
