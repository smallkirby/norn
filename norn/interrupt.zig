const norn = @import("norn");
const arch = norn.arch;

/// Interrupt vector table defined by Norn.
pub const VectorTable = enum(u8) {
    /// Spurious interrupt.
    spurious = 0xFF,
};

/// Context for interrupt handlers.
pub const Context = arch.InterruptContext;

/// Saved registers on interrupt entry.
pub const Registers = arch.InterruptRegisters;

/// Interrupt handler function signature.
pub const Handler = *const fn (*Context) void;
