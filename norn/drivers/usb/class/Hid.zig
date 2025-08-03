//! HID (Human Interface Device) class driver for USB devices.
//!
//! This driver handles HID devices such as keyboards, mice, and other input/output devices.
//! It supports the HID boot protocol for basic keyboard functionality.
//!
//! See "Device Class Definition for Human Interface Devices (HID) Version 1.11" (hereafter "the spec") for details.

const Self = @This();

/// Interface class code for HID devices.
const class_hid = 0x03;

/// Interface subclass for non-boot protocol devices.
const subclass_report = 0x00;
/// Interface subclass for boot protocol devices.
const subclass_boot = 0x01;

/// Interface subclass for boot protocol keyboards.
const protocol_keyboard = 0x01;
/// Interface subclass for boot protocol mice.
const protocol_mouse = 0x02;

/// Size in bytes of the work buffer.
const work_buffer_size = mem.size_4kib;

/// USB Device.
device: *Device,
/// Interface descriptor
interface: *const Device.Interface,
/// Transfer ring for interrupt endpoint
tr: ring.Ring,

/// Interface instance.
instance: Instance,
/// State of the HID device.
state: State = .waiting_protocol_set,

/// Work buffer for DMA.
buffer: []u8,

/// State of the HID device that tracks initialization progress.
const State = enum {
    /// Waiting for the protocol to be set.
    waiting_protocol_set,
    /// Initialization completed.
    initialized,
};

/// HID class-specific requests.
///
/// Refer to the spec Chapter 7 "Requests".
const Request = enum(u8) {
    /// Allows the host to receive a report via the Control Pipe.
    get_report = 0x01,
    /// Reads the current idle rate for a particular Input report.
    get_idle = 0x02,
    /// Reads which protocol is currently active.
    get_protocol = 0x03,
    /// Allows the host to send a report to the device.
    set_report = 0x09,
    /// Silences a particular report on the Interrupt In pipe until a new event occurs or the specified amount of time passes.
    set_idle = 0x0A,
    /// Switches between the boot protocol and the report protocol.
    set_protocol = 0x0B,
    _,
};

/// HID boot protocol types.
const Protocol = enum(u8) {
    /// Boot protocol.
    boot = 0,
    /// Non-boot protocol.
    report = 1,
};

/// Type of HID device.
const DeviceType = enum {
    /// Keyboard.
    keyboard,
    /// Mouse.
    mouse,
    /// Other HID device.
    other,
};

/// Interface instance.
const Instance = union(DeviceType) {
    keyboard: Keyboard,
    mouse: void,
    other: void,
};

/// Initialize a HID device from an interface
pub fn init(
    device: *Device,
    interface: *const Device.Interface,
    tr: ring.Ring,
    allocator: Allocator,
) UsbError!*Self {
    const device_type = detectDeviceType(interface);
    const buffer = try allocator.alignedAlloc(u8, work_buffer_size, mem.size_4kib);

    const instance = switch (device_type) {
        .keyboard => blk: {
            log.info("HID Keyboard detected - Interface {d}, Endpoint {d}, {X:0>2}:{X:0>2}:{X:0>2}", .{
                interface.desc.interface_number,
                interface.endpoint.address.ep,
                interface.desc.class,
                interface.desc.subclass,
                interface.desc.protocol,
            });
            break :blk Instance{ .keyboard = Keyboard{} };
        },
        .mouse => blk: {
            log.info("HID Mouse detected - Interface {d}, Endpoint {d}", .{
                interface.desc.interface_number,
                interface.endpoint.address.ep,
            });
            break :blk Instance{ .mouse = {} };
        },
        .other => blk: {
            log.info("HID Device detected - Interface {d}, Class {d}/Sub {d}/Proto {d}", .{
                interface.desc.interface_number,
                interface.desc.class,
                interface.desc.subclass,
                interface.desc.protocol,
            });
            break :blk Instance{ .other = {} };
        },
    };

    const self = try allocator.create(Self);
    self.* = Self{
        .interface = interface,
        .device = device,
        .tr = tr,
        .instance = instance,
        .buffer = buffer,
    };

    return self;
}

/// Configure the HID device for operation.
pub fn configure(self: *Self) UsbError!void {
    // Set boot protocol if this is a boot interface device
    // (by default, the device comes up in non-boot mode).
    const subclass = self.interface.desc.subclass;
    if (subclass == subclass_boot) {
        try self.changeProtocol(.boot);
    } else {
        self.state = .initialized;
        try self.requestData();
    }
}

/// Set the transfer ring this HID device should use.
///
/// TODO: `Device` class should this operation.
pub fn setTransferRing(self: *Self, tr: ring.Ring) void {
    self.tr = tr;
}

/// Set the HID protocol.
fn changeProtocol(self: *Self, protocol: Protocol) UsbError!void {
    const request_type = Device.SetupData.RequestType{
        .recipient = .interface,
        .type = .class,
        .direction = .out,
    };

    const setup_data = Device.SetupData{
        .request_type = request_type,
        .request = @enumFromInt(@intFromEnum(Request.set_protocol)),
        .value = @intFromEnum(protocol),
        .index = self.interface.desc.interface_index,
        .length = 0,
    };

    try self.device.controlTransferOut(setup_data, 0);
}

/// Notify the Interrupt In endpoint that it can start sending data.
fn requestData(self: *Self) UsbError!void {
    var trb = trbs.NormalTrb{
        .data_buffer = mem.virt2phys(self.buffer.ptr),
        .length = work_buffer_size,
        .td_size = 0,
        .ioc = true,
        .isp = true,
        .cycle = undefined,
        .ent = false,
        .ns = false,
        .bei = false,
        .chain = false,
        .idt = false,
        .intr_target = 0, // TODO
    };
    _ = self.tr.push(trbs.Trb.from(&trb));

    self.device.xhc.doorbells.notifyEndpoint(
        self.device.slot_id,
        self.interface.endpoint.address.dci(),
    );
}

/// Handle data input from Interrupt In endpoint.
fn handleInterruptTransfer(self: *Self, data: []const u8) void {
    switch (self.instance) {
        .keyboard => self.handleKeyboardInput(data),
        .mouse => log.debug("Received mouse input data: {} bytes", .{data.len}),
        .other => log.debug("Received HID input data: {} bytes", .{data.len}),
    }

    // Request more data from the Interrupt In endpoint
    self.requestData() catch |err| {
        log.err("Failed to request more data: {s}", .{@errorName(err)});
    };
}

// =============================================================
// Keyboard
// =============================================================

/// Keyboard with boot protocol.
const Keyboard = struct {
    /// Last received input report
    last_report: BootReport = std.mem.zeroes(BootReport),

    /// Boot keyboard input report format.
    const BootReport = packed struct(u64) {
        /// Modifier keys.
        modifiers: Modifiers,
        /// Reserved.
        reserved: u8,
        // Up to 6 simultaneously pressed keys
        key0: u8,
        key1: u8,
        key2: u8,
        key3: u8,
        key4: u8,
        key5: u8,

        const Modifiers = packed struct(u8) {
            left_ctrl: bool,
            left_shift: bool,
            left_alt: bool,
            left_gui: bool,
            right_ctrl: bool,
            right_shift: bool,
            right_alt: bool,
            right_gui: bool,
        };

        /// Create a BootReport from raw data.
        fn from(data: []const u8) ?*const BootReport {
            if (data.len < @sizeOf(BootReport)) return null;
            return @ptrCast(@alignCast(data.ptr));
        }

        /// Get keys as an array for easier iteration
        fn keys(self: *const BootReport) [6]u8 {
            return .{ self.key0, self.key1, self.key2, self.key3, self.key4, self.key5 };
        }

        /// Check if a key is in the report.
        fn contains(self: BootReport, key: u8) bool {
            for (self.keys()) |k| {
                if (k == key) return true;
            } else {
                return false;
            }
        }
    };

    /// Convert USB HID key code to ASCII character (basic mapping)
    fn codeToChar(key_code: u8) u8 {
        return switch (key_code) {
            0x04...0x1D => key_code - 0x04 + 'a', // a-z
            0x1E...0x27 => key_code - 0x1E + '1', // 1-9, 0
            0x2C => ' ', // Space
            0x28 => '\n', // Enter
            0x29 => 0x1B, // Escape
            0x2A => 0x08, // Backspace
            0x2B => '\t', // Tab
            else => '?', // Unknown / Special key
        };
    }
};

/// Process keyboard input data.
fn handleKeyboardInput(self: *Self, data: []const u8) void {
    const report = Keyboard.BootReport.from(data) orelse {
        log.warn("Invalid keyboard input report size: {d}", .{data.len});
        return;
    };
    const keyboard = &self.instance.keyboard;

    // Detect key changes by comparing with last report
    const last_report = &keyboard.last_report;

    // Check for new key presses
    for (report.keys()) |key| {
        if (key != 0 and !last_report.contains(key)) {
            self.handleKeyEvent(key, true); // Key pressed
        }
    }
    // Check for key releases
    for (last_report.keys()) |key| {
        if (key != 0 and !report.contains(key)) {
            self.handleKeyEvent(key, false); // Key released
        }
    }

    // Update last report
    keyboard.last_report = report.*;
}

/// Handle individual key events.
fn handleKeyEvent(self: *Self, key: u8, pressed: bool) void {
    _ = self;

    // TODO: implement callback
    const action = if (pressed) "pressed" else "released";
    log.info("Key {s}: 0x{X:0>2} ({})", .{ action, key, Keyboard.codeToChar(key) });
}

// =============================================================
// Callbacks
// =============================================================

/// Called when a Transfer Event TRB is received for Data TRB.
pub fn onDataTransferComplete(
    self: *Self,
    event: *const trbs.TransferEventTrb,
    issuer: *const trbs.DataTrb,
) UsbError!void {
    _ = event;
    _ = issuer;

    switch (self.state) {
        // Unexpected state.
        else => {
            log.warn("Unexpected data transfer complete while state is {s}", .{@tagName(self.state)});
        },
    }
}

/// Called when a Transfer Event TRB is received for Status TRB.
pub fn onStatusTransferComplete(
    self: *Self,
    event: *const trbs.TransferEventTrb,
    issuer: *const trbs.StatusTrb,
) UsbError!void {
    _ = issuer;
    switch (self.state) {
        // Protocol has been set, ready to receive data.
        .waiting_protocol_set => {
            norn.rtt.expectEqual(.success, event.code);

            self.state = .initialized;
            try self.requestData();
        },
        // Unexpected state.
        else => {
            log.warn("Unexpected status transfer complete while state is {s}", .{@tagName(self.state)});
        },
    }
}

/// Called when a Transfer Event TRB is received for Normal TRB.
pub fn onNormalTransferComplete(self: *Self, data: []const u8) UsbError!void {
    switch (self.state) {
        // Input data received, process it.
        .initialized => self.handleInterruptTransfer(data),
        // Unexpected state.
        else => {
            log.warn("Received normal transfer while state is {s}", .{@tagName(self.state)});
        },
    }
}

// =============================================================
// Utilities
// =============================================================

/// Detect what type of HID device this is based on interface descriptor
fn detectDeviceType(interface: *const Device.Interface) DeviceType {
    // Check if this is a boot interface device
    if (interface.desc.subclass == subclass_boot) {
        return switch (interface.desc.protocol) {
            protocol_keyboard => .keyboard,
            protocol_mouse => .mouse,
            else => .other,
        };
    }

    // For non-boot devices, we'd need to parse HID descriptors.
    // For now, assume it's a generic HID device.
    return .other;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.@"usb.hid");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const usb = norn.drivers.usb;
const mem = norn.mem;
const UsbError = usb.UsbError;

const ring = @import("../ring.zig");
const Device = @import("../Device.zig");
const trbs = @import("../trbs.zig");
