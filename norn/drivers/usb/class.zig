//! USB Class Driver.
//!
//! This module manages different USB class drivers and handles device classification
//! and initialization based on interface descriptors.

/// USB Class codes.
///
/// Refer to https://www.usb.org/defined-class-codes
pub const Class = enum(u8) {
    /// Class code should be determined from the Interface Descriptor.
    per_interface = 0x00,
    /// Audio.
    audio = 0x01,
    /// Communications and CDC Control..
    cdc = 0x02,
    /// HID.
    hid = 0x03,
    /// Physical.
    physical = 0x05,
    /// Image.
    image = 0x06,
    /// Printer.
    printer = 0x07,
    /// Mass Storage.
    mass_storage = 0x08,
    /// Hub.
    hub = 0x09,
    /// CDC-Data.
    cdc_data = 0x0A,
    /// Smart Card.
    smart_card = 0x0B,
    /// Content Security.
    content_security = 0x0D,
    /// Video.
    video = 0x0E,
    /// Personal Healthcare.
    personal_healthcare = 0x0F,
    /// Audio/Video Devices.
    audio_video = 0x10,
    /// Billboard Device Class.
    billboard = 0x11,
    /// USB Type-C Bridge Class.
    usb_c_bridge = 0x12,

    _,
};

/// USB class driver.
///
/// Each class driver must implement the callbacks listed in this struct.
///
/// This struct can be passed by-val.
pub const ClassDriver = union(enum) {
    hid: *Hid,

    /// Called when a Transfer Event TRB is received for Data TRB.
    pub fn onDataTransferComplete(
        self: ClassDriver,
        event: *const trbs.TransferEventTrb,
        issuer: *const trbs.DataTrb,
    ) UsbError!void {
        switch (self) {
            inline else => |c| try c.onDataTransferComplete(event, issuer),
        }
    }

    /// Called when a Transfer Event TRB is received for Status TRB.
    pub fn onStatusTransferComplete(
        self: ClassDriver,
        event: *const trbs.TransferEventTrb,
        issuer: *const trbs.StatusTrb,
    ) UsbError!void {
        switch (self) {
            inline else => |c| try c.onStatusTransferComplete(event, issuer),
        }
    }

    /// Called when a Transfer Event TRB is received for Normal TRB.
    pub fn onNormalTransferComplete(self: ClassDriver, data: []const u8) UsbError!void {
        switch (self) {
            inline else => |c| try c.onNormalTransferComplete(data),
        }
    }

    /// TODO: `Device` class should this operation.
    pub fn setTransferRing(self: *ClassDriver, ring: rings.Ring) void {
        switch (self) {
            inline else => |c| c.tr = ring,
        }
    }
};

/// Initialize appropriate class driver for the given USB interface
///
/// When this function is called, xHC is not configured for the endpoint yet.
/// Class drivers' `init()` function should NOT perform any operations that require the endpoint to be configured.
pub fn init(
    device: *Device,
    interface: *const Device.Interface,
    tr: rings.Ring,
    allocator: Allocator,
) UsbError!?ClassDriver {
    const class_code: Class = @enumFromInt(interface.desc.class);

    switch (class_code) {
        .hid => {
            const hid_driver = try Hid.init(
                device,
                interface,
                tr,
                allocator,
            );
            return ClassDriver{ .hid = hid_driver };
        },
        else => {
            return null;
        },
    }
}

/// Configure a class driver.
///
/// This function is called after the xHC has been configured for the endpoint.
pub fn configure(driver: ClassDriver) UsbError!void {
    switch (driver) {
        inline else => |c| try c.configure(),
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.usb_class);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const usb = norn.drivers.usb;
const UsbError = usb.UsbError;

const Device = @import("Device.zig");
const Hid = @import("class/Hid.zig");
const rings = @import("ring.zig");
const trbs = @import("trbs.zig");
