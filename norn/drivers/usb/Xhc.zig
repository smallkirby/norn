const UsbError = usb.UsbError;

const Self = @This();

/// xHC PCI device.
pci_device: *pci.Device,
/// I/O base address of the xHC.
iomem: mem.IoAddr,

/// Instantiate a new xHC from the given PCI device.
pub fn new(pci_device: *pci.Device, allocator: Allocator) UsbError!Self {
    if (pci_device.class != usb.class) {
        return UsbError.InvalidDevice;
    }

    // Read base address.
    const bar1 = try pci_device.readBar(0);
    const bar2 = try pci_device.readBar(1);
    const specialized_bar1 = bar1.specialize();

    if (specialized_bar1 != .mmio) {
        return UsbError.InvalidDevice;
    }
    if (specialized_bar1.mmio.type != .map64) {
        return UsbError.InvalidDevice;
    }
    const mmio_base_addr: Phys = bits.concat(Phys, bar2._data, bar1._data & ~@as(u32, 0xF));

    // Request a memory resource for the xHC.
    const name = std.fmt.allocPrint(
        allocator,
        "PCI Bus {X:0>4}:{X:0>2}:{X:0>2}",
        .{ pci_device.bus, pci_device.device, pci_device.function },
    ) catch unreachable;
    try mem.resource.requestResource(
        name,
        mmio_base_addr,
        mem.size_1gib,
        .pci,
        allocator,
    );

    // Map the base address.
    const iomem = try mem.vm_allocator.iomap(mmio_base_addr, mem.size_4kib);

    return .{
        .pci_device = pci_device,
        .iomem = iomem,
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.usb);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const bits = norn.bits;
const mem = norn.mem;
const pci = norn.pci;
const usb = norn.drivers.usb;
const Phys = mem.Phys;
