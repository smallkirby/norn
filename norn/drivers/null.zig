/// Module init function.
fn init() callconv(.c) void {}

comptime {
    device.staticRegisterDevice(init, "/dev/null");
}

// =============================================================
// Imports
// =============================================================
const std = @import("std");

const norn = @import("norn");
const device = norn.device;
