pub const serial8250 = @import("drivers/serial8250.zig");
pub const tty = @import("drivers/tty.zig");
pub const usb = @import("drivers/usb.zig");

comptime {
    // Register driver's init calls
    _ = @import("drivers/null.zig");
    _ = @import("drivers/zero.zig");
    _ = @import("drivers/tty.zig");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const norn = @import("norn");
