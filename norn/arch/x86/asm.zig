const std = @import("std");

const regs = @import("registers.zig");

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn hlt() void {
    asm volatile ("hlt");
}

pub inline fn inb(port: u16) u8 {
    return asm volatile (
        \\inb %[port], %[ret]
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile (
        \\inw %[port], %[ret]
        : [ret] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub inline fn inl(port: u16) u32 {
    return asm volatile (
        \\inl %[port], %[ret]
        : [ret] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub inline fn lgdt(gdtr: u64) void {
    asm volatile (
        \\lgdt (%[gdtr])
        :
        : [gdtr] "r" (gdtr),
    );
}

pub inline fn outb(value: u8, port: u16) void {
    asm volatile (
        \\outb %[value], %[port]
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn outw(value: u16, port: u16) void {
    asm volatile (
        \\outw %[value], %[port]
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn outl(value: u32, port: u16) void {
    asm volatile (
        \\outl %[value], %[port]
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn readRflags() regs.Rflags {
    return @bitCast(asm volatile (
        \\pushfq
        \\pop %[rflags]
        : [rflags] "=r" (-> u64),
    ));
}

/// Pause the CPU for a short period of time.
pub inline fn relax() void {
    asm volatile ("rep; nop");
}

pub inline fn sti() void {
    asm volatile ("sti");
}
