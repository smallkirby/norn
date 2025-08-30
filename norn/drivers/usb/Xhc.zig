//! USB host controller driver.
//!
//! Limitations:
//! - Supports only one Interrupter (primary).
//!
//! References:
//! - eXtensible Host Controller Interface for Universal Serial Bus (xHCI). May 2019. Revision 1.2. Intel Corporation.
//! - Universal Serial Bus 3.2 Specification. June 2022. Revision 1.1. USB 3.0 Promoter Group.

const UsbError = usb.UsbError;

const Self = @This();

/// Type of list of USB devices.
const DeviceList = std.array_list.Managed(*Device); // TODO: make it unmanaged

/// xHC PCI device.
pci_device: *const pci.Device,
/// I/O base address of the xHC MMIO registers.
iobase: mem.IoAddr,

/// Capability registers.
///
/// Specifies the limits and capabilities of the host controller implementation.
/// All Capability Registers are read-only.
capability_regs: Register(CapabilityRegisters, .dword),
/// Operational registers.
///
/// Specifies host controller configuration and runtime modifiable state.
operational_regs: Register(OperationalRegisters, .dword),
/// Runtime registers.
///
/// Just an extension of the Operational Registers.
runtime_regs: Register(RuntimeRegisters, .dword),
/// Doorbell Registers array.
///
/// Software can "ring" the doorbell to make xHC issue Transfer Event TRBs.
doorbells: DoorBellArray,

/// Command Ring.
///
/// Only one Command Ring exists per xHC instance.
command_ring: ring.Ring = undefined,
/// Event Ring.
///
/// Used to receive events from the xHC.
event_ring: ring.EventRing = undefined,

/// DCBAA.
///
/// Device Context pointed to by DCBAA entry is owned by the xHC.
/// Software must not modify them.
dcbaa: Dcbaa,

/// USB devices connected to the xHC.
devices: DeviceList,

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
    const map_size = mem.size_2mib;
    const name = std.fmt.allocPrint(
        allocator,
        "PCI Bus {X:0>4}:{X:0>2}:{X:0>2}",
        .{ pci_device.bus, pci_device.device, pci_device.function },
    ) catch unreachable;
    try mem.resource.requestResource(
        name,
        mmio_base_addr,
        map_size,
        .pci,
        allocator,
    );

    // Map the base address.
    const iobase = try mem.vm_allocator.iomap(mmio_base_addr, map_size);
    const capability_regs = @FieldType(Self, "capability_regs").new(iobase.add(0));
    const operational_regs = @FieldType(Self, "operational_regs").new(iobase.add(capability_regs.read(.cap_length)));
    const rts_off = capability_regs.read(.rtsoff) & ~@as(u64, 0b11111);
    const runtime_regs = @FieldType(Self, "runtime_regs").new(iobase.add(rts_off));
    const db_base = iobase.add(capability_regs.read(.dboff));
    const doorbells = DoorBellArray.new(db_base);

    {
        const cap_regs = capability_regs;
        log.debug("xHC MMIO base         @ 0x{X:0>16}", .{iobase._virt});
        log.debug("Capability Registers  @ 0x{X:0>16}", .{capability_regs._iobase._virt});
        log.debug("Operational Registers @ 0x{X:0>16}", .{operational_regs._iobase._virt});
        log.debug("Runtime Registers     @ 0x{X:0>16}", .{runtime_regs._iobase._virt});
        log.debug("Doorbells             @ 0x{X:0>16}", .{db_base._virt});
        log.debug("xHC Capability Registers:", .{});
        log.debug("  HCI Version : {X:0>4}", .{cap_regs.read(.hci_version)});
        log.debug("  Max Slots   : {d}", .{cap_regs.read(.hcs_params1).maxslots});
        log.debug("  Max Ports   : {d}", .{cap_regs.read(.hcs_params1).maxports});

        norn.rtt.expectEqual(0x0100, cap_regs.read(.hci_version));
    }

    // Init DCBAA.
    const dcbaa = try Dcbaa.init();

    return .{
        .pci_device = pci_device,
        .iobase = iobase,
        .capability_regs = capability_regs,
        .operational_regs = operational_regs,
        .runtime_regs = runtime_regs,
        .doorbells = doorbells,
        .dcbaa = dcbaa,
        .devices = DeviceList.init(allocator),
    };
}

/// Reset the host controller.
pub fn reset(self: *Self) UsbError!void {
    // Check if xHC is halted.
    norn.rtt.expect(self.operational_regs.read(.usbsts).hch);

    // Stop xHC.
    var command = self.operational_regs.read(.usbcmd);
    command.inte = false;
    command.hsee = false;
    command.ewe = false;
    self.operational_regs.write(.usbcmd, command);

    // Wait until the xHC stops.
    while (!self.operational_regs.read(.usbsts).hch) {
        arch.relax();
    }

    // Reset xHC.
    command = self.operational_regs.read(.usbcmd);
    command.hc_rst = true;
    self.operational_regs.write(.usbcmd, command);

    // Wait until the reset is complete.
    while (self.operational_regs.read(.usbcmd).hc_rst) {
        arch.relax();
    }

    // Wait until the controller is ready.
    while (self.operational_regs.read(.usbsts).cnr) {
        arch.relax();
    }
}

/// Setup necessary internal structures.
pub fn setup(self: *Self) UsbError!void {
    try self.initRings();
    try self.enableInterrupt();
    self.operational_regs.write(.dcbaap, self.dcbaa.dcbaap());

    {
        const irs0 = self.getIrsAt(0);
        log.debug("xHC Primary Interrupter Register Set:", .{});
        log.debug("  ERSTSZ: 0x{X}", .{irs0.read(.erstsz)});
        log.debug("  ERSTBA: 0x{X}", .{irs0.read(.erstba)});
        log.debug("  ERDP  : 0x{X}", .{@as(u64, @bitCast(irs0.read(.erdp)))});

        norn.rtt.expectEqual(0, irs0.read(.erdp).addr() % mem.size_4kib);
    }
}

/// Start running the xHC.
pub fn run(self: *Self) void {
    var usbcmd = self.operational_regs.read(.usbcmd);
    usbcmd.rs = true;
    self.operational_regs.write(.usbcmd, usbcmd);

    while (self.operational_regs.read(.usbsts).hch) {
        arch.relax();
    }
}

/// Scan all ports and register connected devices.
pub fn registerDevices(self: *Self, allocator: Allocator) UsbError!void {
    const max_ports = self.capability_regs.read(.hcs_params1).maxports;

    // Scan all ports.
    for (0..max_ports) |n| {
        const prs = regs.PortRegisterSet.getAt(self.operational_regs._iobase, n);
        const portsc = prs.read(.portsc);
        if (!portsc.ccs) {
            continue;
        }

        const device = try allocator.create(Device);
        errdefer allocator.destroy(device);
        device.* = try Device.new(self, @intCast(n), prs);

        try self.devices.append(device);
        errdefer _ = self.devices.pop();

        try device.resetPort();
    }
}

/// Get the number of connected devices.
pub fn getNumberOfDevices(self: *Self) usize {
    return self.devices.items.len;
}

/// Check if there is an event in the event ring.
pub fn hasEvent(self: *const Self) bool {
    return self.event_ring.hasEvent();
}

/// Set the Device Context in DCBAA entry of the given slot index.
pub fn setDeviceContext(self: *const Self, slot: u8, region: *const anyopaque) void {
    self.dcbaa.set(slot, @intFromPtr(region));
}

/// Get the Device Context of the given slot index.
pub fn getDeviceContext(self: *const Self, slot: u8) Virt {
    return self.dcbaa.at(slot).?;
}

/// Initialize Command Ring and Event Ring.
fn initRings(self: *Self) UsbError!void {
    const num_trbs_per_ring = mem.size_4kib / @sizeOf(Trb);

    // Init Command Ring.
    const command_ring = try ring.Ring.new(
        num_trbs_per_ring,
        general_allocator,
    );
    self.command_ring = command_ring;
    self.operational_regs.write(
        .crcr,
        OperationalRegisters.CommandRingControl.new(command_ring),
    );

    // Init Event Ring for the primary Interrupter.
    const irs0 = self.getIrsAt(0);
    const event_ring = try ring.EventRing.new(
        irs0._iobase,
        general_allocator,
    );
    self.event_ring = event_ring;
    self.event_ring.init();
}

/// Enable the xHC interrupt (primary Interrupter only).
fn enableInterrupt(self: *Self) UsbError!void {
    const irs0 = self.getIrsAt(0);

    var imod = irs0.read(.imod);
    imod.imodi = 4000; // 250 * 4000 ns == 1ms
    irs0.write(.imod, imod);

    var iman = irs0.read(.iman);
    iman.ie = true; // Enable interrupt
    iman.ip = true; // Clear Interrupt pending
    irs0.write(.iman, iman);

    var usbcmd = self.operational_regs.read(.usbcmd);
    usbcmd.inte = true; // Enable interrupt
    self.operational_regs.write(.usbcmd, usbcmd);
}

/// Get IRS of the given index.
fn getIrsAt(self: *const Self, comptime index: usize) regs.InterrupterRegisterSet.RegisterType {
    // Supports only the primary interrupter.
    norn.rtt.expectEqual(0, index);

    return RuntimeRegisters.getIrsAt(
        self.runtime_regs._iobase,
        index,
    );
}

/// Get the port number from the port index.
fn portNumber(index: usb.PortIndex) usb.PortNumber {
    return index + 1;
}

/// Find a device by its port index.
fn findDeviceByPort(self: *const Self, port_number: usb.PortNumber) ?*Device {
    for (self.devices.items) |device| {
        if (portNumber(device.port_index) == port_number) {
            return device;
        }
    }
    return null;
}

/// Find a device by its slot ID.
fn findDeviceBySlot(self: *const Self, slot_id: u8) ?*Device {
    for (self.devices.items) |device| {
        if (device.slot_id == slot_id) {
            return device;
        }
    }
    return null;
}

/// Find a device by its state.
///
/// If multiple devices are in the same state, the first one found is returned.
fn findDeviceByState(self: *const Self, state: Device.State) ?*Device {
    for (self.devices.items) |device| {
        if (device.state == state) {
            return device;
        }
    }
    return null;
}

// =============================================================
// Event handlers
// =============================================================

/// Handles pending events in the Event Ring.
///
/// Dispatches the event to the appropriate handler based on the event type.
pub fn handleEvent(self: *Self) UsbError!void {
    while (self.event_ring.next()) |e| {
        const event: *const Trb = @volatileCast(e);
        switch (event.type) {
            .port_status_change => try self.handlePortStatusChange(@ptrCast(event)),
            .transfer_event => try self.handleTransfer(@ptrCast(event)),
            .command_completion => try self.handleCommandCompletion(@ptrCast(event)),
            else => log.err("Unhandled event type: {d}", .{@intFromEnum(event.type)}),
        }
    }
}

/// Handles Transfer Event.
fn handleTransfer(self: *Self, event: *const trbs.TransferEventTrb) UsbError!void {
    const slot_id = event.slot_id;

    // Find the device by slot ID.
    const device = self.findDeviceBySlot(slot_id) orelse {
        log.err("Transfer Event for not registered slot#{d}", .{slot_id});
        return UsbError.NotFound;
    };

    // Handle the transfer.
    try device.onTransferEvent(event);
}

/// Handles Command Completion Event.
///
/// This dispatches the command completion event to the appropriate handler based on the command type.
fn handleCommandCompletion(self: *Self, event: *const trbs.CommandCompletionTrb) UsbError!void {
    const command_trb = event.commandTrb();
    const command_type = command_trb.type;
    const slot_id = event.slot_id;

    switch (command_type) {
        // Slot ID is assigned.
        .enable_slot => {
            const device = self.findDeviceByState(.waiting_slot) orelse {
                log.err("Enable Slot Command completed, but no device is waiting for it.", .{});
                return UsbError.NotFound;
            };
            log.debug("Port#{d}, Slot#{d}: Enable Slot Command completed.", .{ portNumber(device.port_index), slot_id });
            norn.rtt.expectEqual(.success, event.code);

            try device.assignAddress(slot_id);
        },

        // Address is assigned.
        .address_device => {
            log.debug("Slot#{d}: Address Device Command completed.", .{slot_id});
            norn.rtt.expectEqual(.success, event.code);

            const device = self.findDeviceByState(.waiting_address) orelse {
                log.err("Address Device Command completed, but no device is waiting for it.", .{});
                return UsbError.NotFound;
            };

            try device.onAddressAssigned();
        },

        // Endpoint is configured.
        .configure_endpoint => {
            log.debug("Slot#{d}: Configure Endpoint Command completed.", .{slot_id});
            norn.rtt.expectEqual(.success, event.code);

            const device = self.findDeviceBySlot(slot_id) orelse {
                log.err("Address Device Command completed, but no device is waiting for it.", .{});
                return UsbError.NotFound;
            };

            try device.onEndpointConfigured();
        },

        // Unhandled command completions.
        else => {
            log.err("Unhandled command completion type: {d}", .{@intFromEnum(command_type)});
        },
    }
}

/// Handle Port Status Change Event.
fn handlePortStatusChange(self: *Self, event: *const volatile trbs.PortStatusChange) UsbError!void {
    _ = self.findDeviceByPort(event.port) orelse {
        log.warn("Port#{d} is not registered, but its status has changed.", .{event.port});
        return UsbError.NotFound;
    };
    log.debug("Port#{d}: Status changed.", .{event.port});
    norn.rtt.expectEqual(.success, event.code);

    var enable_slot = trbs.EnableSlotTrb{ .cycle = undefined };
    _ = self.command_ring.push(Trb.from(&enable_slot));

    self.doorbells.notifyCommand();
}

// =============================================================
// Data structures
// =============================================================

/// Device Context Base Address Array.
const Dcbaa = struct {
    /// Pointer to DCBAA.
    _raw: *RawDcbaa,

    const RawDcbaa = extern struct {
        /// Pointers to device contexts.
        entries: [std.math.maxInt(@FieldType(StructuralParameters1, "maxports"))]Phys,

        comptime {
            norn.comptimeAssert(
                @sizeOf(@This()) == 2040,
                "Invalid DCBAA size: {d}",
                .{@sizeOf(@This())},
            );
        }
    };

    /// Get the physical address of the DCBAA.
    pub fn dcbaap(self: *const Dcbaa) Phys {
        return mem.virt2phys(self._raw);
    }

    /// Initialize DCBAA at the given memory.
    pub fn init() mem.MemError!Dcbaa {
        const page = try page_allocator.allocPages(1, .normal);
        const raw: *RawDcbaa = @ptrCast(page.ptr);
        const storage: [*]u8 = @ptrCast(raw);

        @memset(storage[0..@sizeOf(RawDcbaa)], 0);

        return .{
            ._raw = raw,
        };
    }

    /// Deinitialize DCBAA.
    pub fn deinit(self: *Dcbaa) void {
        const ptr: [*]const u8 = @ptrCast(self._raw);
        page_allocator.freePages(ptr[0..mem.size_4kib]);
    }

    /// Set the Device Context for the given slot index.
    pub fn set(self: *const Dcbaa, slot: u8, context: Virt) void {
        self._raw.entries[slot] = mem.virt2phys(context);
    }

    /// Get the pointer to the Device Context of the given slot index.
    pub fn at(self: *const Dcbaa, slot: u8) ?Virt {
        const ret = self._raw.entries[slot];
        return if (ret == 0) null else mem.phys2virt(ret);
    }
};

// =============================================================
// Registers
// =============================================================

/// xHCI Capability Registers.
const CapabilityRegisters = packed struct {
    /// Offset from register base to the Operational Register Space.
    cap_length: u8,
    /// Reserved
    _reserved: u8,
    /// BCD encoding of the xHCI spec revision number supported by this HC.
    hci_version: u16,
    /// HC Structural Parameters 1.
    hcs_params1: StructuralParameters1,
    /// HC Structural Parameters 2.
    hcs_params2: u32,
    /// HC Structural Parameters 3.
    hcs_params3: u32,
    /// HC Capability Parameters 1.
    hcc_params1: CapabilityParameters1,
    /// Doorbell Array Offset.
    dboff: u32,
    /// Runtime Register Space Offset.
    rtsoff: u32,
    /// HC Capability Parameters 2.
    hcc_params2: u32,
};

/// xHC Operational Registers.
///
/// Port Register Set continues at offset 0x400, but we don't declare them here.
const OperationalRegisters = packed struct {
    /// USB Command.
    usbcmd: CommandRegister,
    /// USB Status.
    usbsts: StatusRegister,
    /// Page Size.
    pagesize: u32,
    /// Reserved.
    _reserved1: u64,
    /// Device Notification Control.
    dnctrl: u32,
    /// Command Ring Control,
    crcr: CommandRingControl,
    /// Reserved.
    _reserved2: u128,
    /// Device Context Base Address Array Pointer.
    dcbaap: u64,
    /// Configure.
    config: ConfigureRegister,

    const CommandRingControl = packed struct(u64) {
        /// Ring Cycle State.
        /// Indicates the xHC Consumer Cycle State (CCS).
        /// Write is ignored if CRR is set.
        rcs: u1,
        /// Command Stop.
        /// Writing 1 shall stop the operation of the Command Ring after the completion of the currently executing command.
        cs: bool,
        /// Command Abort.
        /// Writing 1 shall immediately terminate the currently executing command.
        ca: bool,
        /// Command Ring Running. (read-only)
        crr: bool,
        /// Reserved.
        _reserved1: u2 = 0,
        /// Pointer to the Command Ring.
        command_ring: u58,

        pub fn new(command_ring: ring.Ring) CommandRingControl {
            return .{
                .rcs = command_ring.pcs,
                .cs = false,
                .ca = false,
                .crr = false,
                .command_ring = @intCast(mem.virt2phys(command_ring.trbs.ptr) >> 6),
            };
        }
    };
};

/// USB Command Register. (USBCMD)
const CommandRegister = packed struct(u32) {
    /// Run/Stop.
    /// When set to 1, the xHC proceeds with execution of the schedule.
    /// When set to 0, the xHC completes the current transaction and halts.
    rs: bool,
    /// Host Controller Reset.
    hc_rst: bool,
    /// Interrupt Enable.
    inte: bool,
    /// Host System Error Enable,
    hsee: bool,
    /// Reserved
    _reserved1: u3,
    /// Light Host Controller Reset.
    lhcrst: bool,
    /// Controller Save State.
    css: bool,
    /// Controller Restore State.
    crs: bool,
    /// Enable Wrap Event.
    ewe: bool,
    /// Enable U3 MFINDEX Stop.
    u3s: bool,
    /// Reserved.
    _reserved2: bool,
    /// CEM Enable.
    cme: bool,
    /// Extended TBC Enable.
    ete: bool,
    /// Extended TBC TRB Status Enable.
    tsc_en: bool,
    /// VTIO Enable.
    vtioe: bool,
    /// Reserved.
    _reserved3: u15,
};

/// USB Status Register. (USBSTS)
const StatusRegister = packed struct(u32) {
    /// HCHalted.
    hch: bool,
    /// Reserved.
    _reserved1: u1,
    /// Host System Error.
    hse: bool,
    /// Event Interrupt.
    eint: bool,
    /// Port Change Detect.
    pcd: bool,
    /// Reserved.
    _reserved2: u3,
    /// Save State Status.
    sss: bool,
    /// Restore State Status.
    rss: bool,
    /// Save/Restore Error.
    sre: bool,
    /// Controller Not Ready.
    cnr: bool,
    /// Host Controller Error.
    hce: bool,
    /// Reserved.
    _reserved3: u19,
};

/// Runtime xHC configuration register. (CONFIG)
const ConfigureRegister = packed struct(u32) {
    /// Number of Device Slots Enabled.
    max_slots_en: u8,
    /// U3 Entry Enable.
    u3e: bool,
    /// Configuration Information Enable.
    cie: bool,
    /// Reserved.
    _reserved: u22,
};

/// xHC Runtime Registers.
///
/// 1024 entries of Interrupter Register Set continues after this, but we don't declare them here.
const RuntimeRegisters = packed struct(u256) {
    /// MFINDEX
    mfindex: u32,
    /// Reserved.
    _reserved: u224,

    /// Get the offset in bytes of Interrupter Register Set at the given index.
    pub fn irsOffset(comptime index: usize) usize {
        comptime {
            norn.comptimeAssert(
                index < 1024,
                "Invalid Interrupter Register Set index: {d}",
                .{index},
            );
        }

        return @sizeOf(RuntimeRegisters) + (index * @sizeOf(regs.InterrupterRegisterSet));
    }

    /// Get the Interrupter Register Set at the given index.
    pub fn getIrsAt(runtime_base: IoAddr, comptime index: usize) regs.InterrupterRegisterSet.RegisterType {
        return regs.InterrupterRegisterSet.get(
            runtime_base.add(irsOffset(index)),
        );
    }
};

/// Array of DB Registers.
const DoorBellArray = struct {
    const RegisterType = Register(regs.DoorBell, .dword);

    /// Base address of DB registers array.
    _base: IoAddr,

    fn new(base: IoAddr) DoorBellArray {
        return .{ ._base = base };
    }

    /// Get the DB Register at the given index.
    pub fn at(self: *const DoorBellArray, index: usize) RegisterType {
        return RegisterType.new(self._base.add(index * @sizeOf(regs.DoorBell)));
    }

    /// Notify the xHC of a command being pushed to the Command Ring.
    pub fn notifyCommand(self: *const DoorBellArray) void {
        const db = self.at(0);
        db.set(regs.DoorBell{ .target = 0 });
    }

    /// Notify the specified endpoint, of the device specified by the slot ID, of a new TRB in the Transfer Ring.
    pub fn notifyEndpoint(self: *const DoorBellArray, slot: u8, dci: u5) void {
        const db = self.at(slot);
        db.set(regs.DoorBell{ .target = dci });
    }
};

/// HCSPARAMS1
const StructuralParameters1 = packed struct(u32) {
    /// Number of device slots.
    maxslots: u8,
    /// Number of interrupters.
    maxintrs: u11,
    /// Reserved.
    _reserved: u5,
    /// Number of ports.
    maxports: u8,
};

/// HCCPARAMS1
const CapabilityParameters1 = packed struct(u32) {
    /// Unimplemented
    _unimplemented: u16,
    /// xHCI Extended Capabilities Pointer.
    xecp: u16,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.usb);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const trbs = @import("trbs.zig");
const regs = @import("regs.zig");
const ring = @import("ring.zig");
const Device = @import("Device.zig");

const norn = @import("norn");
const arch = norn.arch;
const bits = norn.bits;
const mem = norn.mem;
const pci = norn.pci;
const usb = norn.drivers.usb;
const IoAddr = mem.IoAddr;
const Virt = mem.Virt;
const Phys = mem.Phys;
const Register = norn.mmio.Register;
const Trb = trbs.Trb;

const general_allocator = norn.mem.general_allocator;
const page_allocator = norn.mem.page_allocator;
