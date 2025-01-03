pub const mp = @import("mp.zig");

pub const ApicTimer = apic.Timer;
pub const InterruptContext = isr.Context;
pub const InterruptRegisters = isr.Registers;

const std = @import("std");
const log = std.log.scoped(.arch);

const norn = @import("norn");
const bits = norn.bits;
const mem = norn.mem;
const interrupt = norn.interrupt;
const PageAllocator = mem.PageAllocator;
const Phys = mem.Phys;

const am = @import("asm.zig");
const apic = @import("apic.zig");
const cpuid = @import("cpuid.zig");
const gdt = @import("gdt.zig");
const intr = @import("intr.zig");
const isr = @import("isr.zig");
const pg = @import("page.zig");
const regs = @import("registers.zig");

const Msr = regs.Msr;

pub const Error = apic.Error || intr.Error;

/// Reconstruct the page tables
/// This function MUST be called only once.
pub fn bootReconstructPageTable(allocator: PageAllocator) pg.PageError!void {
    try pg.boot.reconstruct(allocator);
}

/// Disable external interrupts.
pub inline fn disableIrq() void {
    am.cli();
}

/// Enable external interrupts.
pub inline fn enableIrq() void {
    am.sti();
}

/// Get the local APIC address by reading the MSR.
pub fn getLocalApicAddress() Phys {
    return am.rdmsr(regs.MsrApicBase, .apic_base).getAddress();
}

/// Halt the current CPU.
pub inline fn halt() void {
    am.hlt();
}

/// Check if external interrupts are enabled.
pub fn isIrqEnabled() bool {
    return am.readRflags().ie;
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

/// Initialize the GDT.
pub fn initGdt() void {
    gdt.init();
}

/// Initialize interrupt and exception handling.
/// Note that this function does not enable interrupts.
pub fn initInterrupt() void {
    intr.init();
}

/// Initialize APIC.
pub fn initApic() !void {
    return apic.init();
}

/// Check if the current CPU is the BSP.
pub fn isCurrentBsp() bool {
    return am.rdmsr(regs.MsrApicBase, .apic_base).is_bsp;
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

/// Pause a CPU for a short period of time.
pub fn relax() void {
    am.relax();
}

/// Set the interrupt handler.
pub fn setInterruptHandler(vector: u8, handler: interrupt.Handler) Error!void {
    return intr.setHandler(vector, handler);
}

// ========================================

test {
    std.testing.refAllDeclsRecursive(@This());
}
