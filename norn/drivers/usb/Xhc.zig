const UsbError = usb.UsbError;

const Self = @This();

/// xHC PCI device.
pci_device: *pci.Device,
/// I/O base address of the xHC.
iobase: mem.IoAddr,
/// Capability registers.
capability_regs: Register(CapabilityRegisters, .dword),
/// Operational registers.
operational_regs: Register(OperationalRegisters, .dword),
/// Runtime registers.
runtime_regs: Register(RuntimeRegisters, .dword),

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

    log.debug("xHC MMIO base         @ 0x{X:0>16}", .{iobase._virt});
    log.debug("Capability Registers  @ 0x{X:0>16}", .{capability_regs._iobase._virt});
    log.debug("Operational Registers @ 0x{X:0>16}", .{operational_regs._iobase._virt});
    log.debug("Runtime Registers     @ 0x{X:0>16}", .{runtime_regs._iobase._virt});

    return .{
        .pci_device = pci_device,
        .iobase = iobase,
        .capability_regs = capability_regs,
        .operational_regs = operational_regs,
        .runtime_regs = runtime_regs,
    };
}

/// Reset the host controller.
pub fn reset(self: *Self) UsbError!void {
    // Check if xHC is halted.
    norn.rtt.expect(self.operational_regs.read(.usbsts).hch);

    // Start reset.
    var command = self.operational_regs.read(.usbcmd);
    command.rs = true;
    self.operational_regs.write(.usbcmd, command);

    // Wait until the reset is complete.
    while (self.operational_regs.read(.usbcmd).hc_rst) {
        arch.relax();
    }

    // Wait until the controller is ready.
    while (self.operational_regs.read(.usbsts).cnr) {
        arch.relax();
    }

    log.debug("Reset xHC completed", .{});
}

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
    crcr: u64,
    /// Reserved.
    _reserved2: u128,
    /// Device Context Base Address Array Pointer.
    dcbaap: u64,
    /// Configure.
    config: ConfigureRegister,
};

const PortRegisterSet = packed struct(u128) {
    /// Port Status and Control.
    portsc: PortStatusControlRegister,
    /// Port Power Management Status and Control.
    portpmsc: u32,
    /// Port Link Info.
    portli: u32,
    /// Port Hardware LPM Control.
    porthlpmc: u32,
};

/// PORTSC.
///
/// Can be used to determine how many ports need to be serviced.
const PortStatusControlRegister = packed struct(u32) {
    /// Current Connect Status.
    ccs: bool,
    /// Port Enabled/Disabled.
    ped: bool,
    /// Reserved.
    _reserved1: u1,
    /// Over-current Active.
    oca: bool,
    /// Port Reset.
    pr: bool,
    /// Port Link State.
    pls: u4,
    /// Port Power.
    pp: bool,
    /// Port Speed.
    speed: PortSpeed,
    /// Port Indicator Control.
    pic: u2,
    /// Port Link State Write Strobe.
    lws: bool,
    /// Connect Status Change.
    /// This bit is RW1CS (Sticky-Write-1-to-clear status).
    /// Writing 1 to this bit clears the status, and 0 has no effect.
    csc: bool,
    /// Port Enabled/Disabled Change.
    pec: bool,
    /// Warm Port Reset Change.
    wrc: bool,
    /// Over-current Change.
    occ: bool,
    /// Port Reset Change.
    prc: bool,
    /// Port Link State Change.
    plc: bool,
    /// Port Config Error Change.
    cec: bool,
    /// Cold Attach Status.
    cas: bool,
    /// Wake on Connect Enable.
    wce: bool,
    /// Wake on Disconnect Enable.
    wde: bool,
    /// Wake on Over-current Enable.
    woe: bool,
    /// Reserved.
    _reserved2: u2,
    /// Device Removable.
    dr: bool,
    /// Warm Port Reset.
    wpr: bool,
};

const PortSpeed = enum(u4) {
    invalid = 0,
    full = 1,
    low = 2,
    high = 3,
    super = 4,
    super_plus = 5,
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
};

/// xHC Doorbell Register.
const DoorbellRegister = packed struct(u32) {
    /// Doorbell Target.
    db_target: u8,
    /// Reserved.
    _reserved: u8 = 0,
    /// Doorbell Stream ID.
    db_stream_id: u16,
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

/// Interrupt Register Set in the xHC's Runtime Registers.
///
/// An Interrupter manages events and their notification to the host.
/// Multiple interrupters can be used to distribute the load of event processing.
/// But we use only one interrupter (primaly interrupter) in this implementation.
const InterrupterRegisterSet = packed struct(u256) {
    /// Interrupter Management Register.
    iman: InterrupterManagementRegister,
    /// Interrupter Moderation Register.
    imod: InterrupterModerationRegister,

    /// Event Ring Segment Table Size Register.
    erstsz: u32,
    /// Reserved.
    _reserved: u32,
    /// Event Ring Segment Table Base Address Register.
    erstba: u64,
    /// Event Ring Dequeue Pointer Register.
    /// 4 LSBs are used as DESI and EHB.
    erdp: u64,
};

/// Interrupter Management Register (IMAN) that allows system software to enable, disable, and detect xHC interrupts.
const InterrupterManagementRegister = packed struct(u32) {
    /// Interrupt Pending (IP)
    ip: bool,
    /// Interrupt Enable (IE)
    ie: bool,
    /// Reserved.
    _reserved: u30,
};

/// Interrupter Moderation Register (IMOD) that controls the moderation feature of an Interrupter.
const InterrupterModerationRegister = packed struct(u32) {
    /// Interrupter Moderation Interval, in 250ns increments (IMODI).
    imodi: u16,
    /// Reserved.
    _reserved: u16,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.usb);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const arch = norn.arch;
const bits = norn.bits;
const mem = norn.mem;
const pci = norn.pci;
const usb = norn.drivers.usb;
const Phys = mem.Phys;
const Register = norn.mmio.Register;
