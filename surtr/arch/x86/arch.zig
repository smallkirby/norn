pub const page = @import("page.zig");

/// Enable NX-bit.
pub fn enableNxBit() void {
    const efer_reg: *volatile u64 = @ptrFromInt(0xC000_0080);
    efer_reg.* = efer_reg.* | (1 << 11);
}

/// Halt the current CPU.
pub fn halt() void {
    asm volatile ("hlt");
}
