pub const intr = @import("intr.zig");
pub const page = @import("page.zig");

const std = @import("std");
const log = std.log.scoped(.arch);

const norn = @import("norn");
const bits = norn.bits;

const am = @import("asm.zig");
const cpuid = @import("cpuid.zig");
const gdt = @import("gdt.zig");
const isr = @import("isr.zig");
const regs = @import("registers.zig");

const Msr = regs.Msr;

/// Pause a CPU for a short period of time.
pub fn relax() void {
    am.relax();
}

/// Disable external interrupts.
pub inline fn disableIrq() void {
    am.cli();
}

/// Enable external interrupts.
pub inline fn enableIrq() void {
    am.sti();
}

/// Check if external interrupts are enabled.
pub fn isIrqEnabled() bool {
    return am.readRflags().ie;
}

/// Initialize the GDT.
pub fn initGdt() void {
    gdt.init();
}

/// Halt the current CPU.
pub inline fn halt() void {
    am.hlt();
}

/// Read a data from an I/O port.
pub inline fn in(T: type, port: u16) T {
    return switch (T) {
        u8 => am.inb(port),
        u16 => am.inw(port),
        u32 => am.inl(port),
        else => @compileError("Unsupported type for asm in()"),
    };
}

/// Check if the current CPU is the BSP.
pub fn isCurrentBsp() bool {
    return bits.isset(am.rdmsr(.apic_base), 8);
}

/// Write a byte to an I/O port.
pub fn out(T: type, value: T, port: u16) void {
    return switch (T) {
        u8 => am.outb(value, port),
        u16 => am.outw(value, port),
        u32 => am.outl(value, port),
        else => @compileError("Unsupported type for asm out()"),
    };
}

/// Get the APIC ID of the BSP.
pub fn queryBspId() u8 {
    const leaf = cpuid.Leaf.version_info.query(null);
    return @truncate(leaf.ebx >> 24);
}

/// Get the local APIC address by reading the MSR.
pub fn getLocalApicAddress() u32 {
    return @truncate(am.rdmsr(.apic_base) & 0xFFFF_FFFF_FFFF_F000);
}

// ========================================

test {
    std.testing.refAllDeclsRecursive(@This());
}
