pub const devnull = @import("drivers/null.zig");
pub const serial8250 = @import("drivers/serial8250.zig");
pub const usb = @import("drivers/usb.zig");

comptime {
    // Register driver's init calls
    _ = devnull;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const norn = @import("norn");
