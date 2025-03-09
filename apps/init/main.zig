export fn _start() callconv(.naked) noreturn {
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
