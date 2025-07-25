pub const UsbError = error{
    /// Invalid device.
    InvalidDevice,
    /// Requested resource is already registered.
    AlreadyRegistered,
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
    norn.rtt.expect(arch.isCurrentBsp());
    norn.rtt.expect(arch.isIrqEnabled());

    // Register interrupt handler.
    try arch.setInterruptHandler(
        @intFromEnum(VectorTable.usb),
        interruptHandler,
    );

    // Setup MSI.
    const lapic = arch.getLocalApic();
    const lapic_id = lapic.id();
    try pci_device.initMsi(lapic_id, @intFromEnum(VectorTable.usb));
    log.debug("Initialized MSI for core#{d}.", .{lapic_id});

    xhc = try Xhc.new(pci_device, allocator);
    try xhc.reset();
    log.debug("Reset xHC completed.", .{});

    try xhc.setup();
    log.debug("xHC setup completed.", .{});

    xhc.run();
    log.debug("xHC has started running.", .{});

    try xhc.registerDevices(allocator);
    log.info("{d} devices registered.", .{xhc.getNumberOfDevices()});
}

/// Interrupt handler for xHC.
fn interruptHandler(_: *norn.interrupt.Context) void {
    log.err("TODO: xHC interrupt is not implemented yet.", .{});
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.usb);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const pci = norn.pci;
const VectorTable = norn.interrupt.VectorTable;

const Xhc = @import("usb/Xhc.zig");
