const std = @import("std");

fn syscall(nr: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) i64 {
    return asm volatile (
        \\movq %[nr], %%rax
        \\movq %[arg1], %%rdi
        \\movq %[arg2], %%rsi
        \\movq %[arg3], %%rdx
        \\movq %[arg4], %%r10
        \\syscall
        \\movq %%rax, %[ret]
        : [ret] "=r" (-> i64),
        : [nr] "r" (nr),
          [arg1] "r" (arg1),
          [arg2] "r" (arg2),
          [arg3] "r" (arg3),
          [arg4] "r" (arg4),
        : "rax", "rdi", "rsi", "rdx", "r10"
    );
}

fn dlog(comptime str: []const u8) void {
    const nr_dlog = 0xFF;
    _ = syscall(
        nr_dlog,
        @intFromPtr(str.ptr),
        str.len,
        0,
        0,
    );
}

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\jmp main
    );
}

export fn main() noreturn {
    dlog("Hello, from userland!");

    while (true) {
        _ = syscall(std.math.maxInt(u64), 0, 1, 2, 3);
    }

    unreachable;
}
