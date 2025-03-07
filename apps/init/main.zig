export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\.L1:
        \\jmp .L1
    );
}
