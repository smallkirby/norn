const am = @import("asm.zig");

pub const page = @import("page.zig");

/// Enable NX-bit.
pub fn enableNxBit() void {
    const efer = am.rdmsr(u64, 0xC000_0080);
    am.wrmsr(0xC000_0080, efer | (1 << 11)); // EFER.NX
}

/// Halt the current CPU.
pub fn halt() void {
    asm volatile ("hlt");
}
