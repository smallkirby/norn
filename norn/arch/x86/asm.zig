const std = @import("std");

const regs = @import("registers.zig");
const Msr = regs.Msr;

const norn = @import("norn");
const bits = norn.bits;

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

pub inline fn lidt(idtr: u64) void {
    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (idtr),
    );
}

pub inline fn loadCr3(cr3: u64) void {
    asm volatile (
        \\mov %[cr3], %%cr3
        :
        : [cr3] "r" (cr3),
    );
}

pub inline fn loadCr4(cr4: anytype) void {
    asm volatile (
        \\mov %[cr4], %%cr4
        :
        : [cr4] "r" (@as(u64, @bitCast(cr4))),
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

pub inline fn readCr0() regs.Cr0 {
    var cr0: u64 = undefined;
    asm volatile (
        \\mov %%cr0, %[cr0]
        : [cr0] "=r" (cr0),
    );
    return @bitCast(cr0);
}

pub inline fn readCr2() regs.Cr2 {
    var cr2: u64 = undefined;
    asm volatile (
        \\mov %%cr2, %[cr2]
        : [cr2] "=r" (cr2),
    );
    return cr2;
}

pub inline fn readCr3() u64 {
    return asm volatile (
        \\mov %%cr3, %[cr3]
        : [cr3] "=r" (-> u64),
    );
}

pub inline fn readCr4() regs.Cr4 {
    var cr4: u64 = undefined;
    asm volatile (
        \\mov %%cr4, %[cr4]
        : [cr4] "=r" (cr4),
    );
    return @bitCast(cr4);
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

pub inline fn rdmsr(T: type, comptime msr: Msr) T {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\rdmsr
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [msr] "{ecx}" (@intFromEnum(msr)),
        : "eax", "edx", "ecx"
    );

    const value = bits.concat(u64, edx, eax);
    return switch (@typeInfo(T)) {
        .Int, .ComptimeInt => value,
        .Struct => @bitCast(value),
        else => @compileError("rdmsr: invalid type"),
    };
}

pub inline fn sti() void {
    asm volatile ("sti");
}
