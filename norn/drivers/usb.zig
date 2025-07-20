pub const UsbError = error{
    /// Invalid device.
    InvalidDevice,
} || norn.pci.PciError || norn.mem.MemError;

/// Class code for USB host controller.
pub const class = pci.ClassCode{
    .base_class = 0x0C,
    .sub_class = 0x03,
    .interface = 0x30,
};

/// Host controller instance.
var xhc: Xhc = undefined;

/// Initialize USB driver.
pub fn init(pci_device: *pci.Device, allocator: Allocator) UsbError!void {
    xhc = try Xhc.new(pci_device, allocator);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const mem = norn.mem;
const pci = norn.pci;

const Xhc = @import("usb/Xhc.zig");
