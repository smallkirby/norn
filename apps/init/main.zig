export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\.L1:
        \\jmp .L1
    );
}
