const Self = @This();

/// Port number.
port_number: usize,
/// Port Register Set.
prs: PortRegisterSet.RegisterType,

/// Create a new USB device.
pub fn new(port_number: usize, prs: PortRegisterSet.RegisterType) Self {
    return .{
        .port_number = port_number,
        .prs = prs,
    };
}

/// Reset the port.
///
/// Blocks until the port reset is completed.
pub fn resetPort(self: *Self) UsbError!void {
    var portsc = self.prs.read(.portsc);
    portsc.pr = true;
    portsc.csc = true;
    self.prs.write(.portsc, portsc);

    while (self.prs.read(.portsc).pr) {
        arch.relax();
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const arch = norn.arch;
const usb = norn.drivers.usb;
const UsbError = usb.UsbError;

const regs = @import("regs.zig");
const PortRegisterSet = regs.PortRegisterSet;
