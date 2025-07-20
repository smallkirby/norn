pub const devnull = @import("drivers/null.zig");
pub const serial8250 = @import("drivers/serial8250.zig");
pub const usb = @import("drivers/usb.zig");

// TODO: Is there a better way to evaluate comptime registration of init functions?
comptime {
    const evaluate = std.testing.refAllDecls;

    if (!norn.is_test) {
        evaluate(devnull);
        evaluate(serial8250);
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const norn = @import("norn");
