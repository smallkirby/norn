pub const intr = @import("intr.zig");
pub const page = @import("page.zig");

const std = @import("std");
const log = std.log.scoped(.arch);

const norn = @import("norn");

const am = @import("asm.zig");
const gdt = @import("gdt.zig");
const isr = @import("isr.zig");

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

/// Read a byte from an I/O port.
pub fn inb(port: u16) u8 {
    return am.inb(port);
}

/// Write a byte to an I/O port.
pub fn outb(value: u8, port: u16) void {
    am.outb(value, port);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
