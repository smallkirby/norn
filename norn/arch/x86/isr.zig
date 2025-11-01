//! LICENSE NOTICE
//!
//! The impletentation is heavily inspired by https://github.com/AndreaOrru/zen
//! Original LICENSE follows:
//!
//! BSD 3-Clause License
//!
//! Copyright (c) 2017, Andrea Orru
//! All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//! * Redistributions of source code must retain the above copyright notice, this
//!   list of conditions and the following disclaimer.
//!
//! * Redistributions in binary form must reproduce the above copyright notice,
//!   this list of conditions and the following disclaimer in the documentation
//!   and/or other materials provided with the distribution.
//!
//! * Neither the name of the copyright holder nor the names of its
//!   contributors may be used to endorse or promote products derived from
//!   this software without specific prior written permission.
//!
//! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//!
//!

/// ISR signature.
pub const Isr = fn () callconv(.naked) void;

/// Zig entry point of the interrupt handler.
export fn intrZigEntry(ctx: *CpuContext) callconv(.c) void {
    intr.dispatch(ctx);
}

/// Get ISR function for the given vector.
pub fn generateIsr(comptime vector: usize) Isr {
    return struct {
        fn handler() callconv(.naked) void {
            // Clear the interrupt flag.
            asm volatile (
                \\cli
            );

            // If the interrupt does not provide an error code, push a dummy one.
            if (vector != 8 and !(vector >= 10 and vector <= 14) and vector != 17) {
                asm volatile (
                    \\pushq $0
                );
            }

            // Push the vector.
            asm volatile (
                \\pushq %[vector]
                :
                : [vector] "n" (vector),
            );
            // Jump to the common ISR.
            asm volatile (
                \\jmp isrCommon
            );
        }
    }.handler;
}

/// Common stub for all ISR, that all the ISRs will use.
/// This function assumes that `Context` is saved at the top of the stack except for general-purpose registers.
export fn isrCommon() callconv(.naked) void {
    // Save the general-purpose registers.
    asm volatile (
        \\pushq %%rdi
        \\pushq %%rsi
        \\pushq %%rdx
        \\pushq %%rcx
        \\pushq %%rax
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%rbx
        \\pushq %%rbp
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
    );

    // Push the context and call the handler.
    asm volatile (
        \\pushq %%rsp
        \\popq %%rdi
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

        // Call the dispatcher.
        \\call intrZigEntry

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
    );

    // Remove general-purpose registers, error code, and vector from the stack.
    asm volatile (
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%rbp
        \\popq %%rbx
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rax
        \\popq %%rcx
        \\popq %%rdx
        \\popq %%rsi
        \\popq %%rdi
        \\add   $0x10, %%rsp
        \\iretq
    );
}

const std = @import("std");
const log = std.log.scoped(.isr);

const intr = @import("interrupt.zig");
const regs = @import("registers.zig");
const CpuContext = regs.CpuContext;
