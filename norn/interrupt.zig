/// Interrupt vector table defined by Norn.
pub const VectorTable = enum(u8) {
    /// Timer interrupt.
    timer = 0x20,
    /// Spurious interrupt.
    spurious = 0xFF,
};

/// Context for interrupt handlers.
pub const Context = arch.InterruptContext;

/// Interrupt handler function signature.
pub const Handler = *const fn (*Context) void;

// =============================================================
// Imports
// =============================================================

const norn = @import("norn");
const arch = norn.arch;
