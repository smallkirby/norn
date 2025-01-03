/// Interrupt vector table defined by Norn.
pub const VectorTable = enum(u8) {
    /// Spurious interrupt.
    spurious = 0xFF,
};
