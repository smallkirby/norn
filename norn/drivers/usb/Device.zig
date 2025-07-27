const Self = @This();

/// State.
state: State,
/// Port index.
port_index: usb.PortIndex,
/// Port Register Set.
prs: PortRegisterSet.RegisterType,
/// Host Controller.
xhc: *Xhc,

/// Device state.
pub const State = enum {
    /// Port is connected.
    initialized,
    /// Waiting for the Slot ID to be assigned.
    waiting_slot,
};

/// Create a new USB device.
pub fn new(
    xhc: *Xhc,
    port_index: usb.PortIndex,
    prs: PortRegisterSet.RegisterType,
) Self {
    return .{
        .state = .initialized,
        .xhc = xhc,
        .port_index = port_index,
        .prs = prs,
    };
}

/// Reset the port.
///
/// Blocks until the port reset is completed.
pub fn resetPort(self: *Self) UsbError!void {
    self.state = .waiting_slot;

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
const Xhc = @import("Xhc.zig");
