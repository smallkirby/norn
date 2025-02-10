//! cf. SDM Vol.3A 5.8.8

const std = @import("std");

const norn = @import("norn");
const bits = norn.bits;
const pcpu = norn.pcpu;

const am = @import("asm.zig");
const cpuid = @import("cpuid.zig");
const gdt = @import("gdt.zig");
const regs = @import("registers.zig");

/// RSP value when SYSCALL is called.
var rsp_syscall: u64 linksection(pcpu.section) = undefined;

pub const Error = error{
    /// The operation is not supported.
    NotSupported,
};

/// Register context for x86-64 syscall.
const Registers = packed struct {
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
            .rpl = 0,
        }),
        .sysret_cs_ss = @bitCast(gdt.SegmentSelector{
            .index = gdt.user_cs_index,
            .rpl = 3,
        }),
    };
    am.wrmsr(.star, star);
    const fmask = regs.MsrFmask{ .flags = std.math.maxInt(u32) };
    am.wrmsr(.fmask, fmask); // TODO: should mask IE?

    // Enable SYSCALL/SYSRET instructions.
    var efer = am.rdmsr(regs.MsrEfer, .efer);
    efer.sce = true;
    am.wrmsr(.efer, efer);
}

/// Dispatch system call.
export fn dispatchSyscall(nr: u64, _: *Registers) callconv(.C) u64 {
    std.log.debug("syscall nr={d}", .{nr});

    return 0;
}

/// SYSCALL entry point.
export fn syscallEntry() callconv(.Naked) void {
    // SYSCALL sets below registers.
    //  R11: RFLAGS
    //  RCX: RIP
    asm volatile (
        \\cli
        // SYSCALL does not save RSP, so we need to save it here.
        \\swapgs
        \\movq %%rsp, %%gs:(%[rsp_syscall])
        // Switch to kernel stack
        // TODO: restore stack pointer here
        // TODO: Switch CR3 here.

        // Construct context
        \\pushq %[ss]                   # ss
        \\pushq %%gs:(%[rsp_syscall])   # sp
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
        \\movq %%rax, %%rdi

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

        // Return to user mode
        \\popq %%rcx                    # rip
        \\add  $8, %%rsp                # cs
        \\popq %%r11                    # rflags
        \\swapgs
        \\sysretq
        :
        : [ss] "i" (gdt.SegmentSelector{ .index = gdt.user_ds_index, .rpl = 3 }),
          [cs] "i" (gdt.SegmentSelector{ .index = gdt.user_cs_index, .rpl = 3 }),
          [rsp_syscall] "{r12}" (&rsp_syscall), // We can use caller-saved register here
    );
}
