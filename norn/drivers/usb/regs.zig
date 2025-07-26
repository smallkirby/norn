/// Interrupt Register Set in the xHC's Runtime Registers.
///
/// An Interrupter manages events and their notification to the host.
pub const InterrupterRegisterSet = packed struct(u256) {
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
pub const InterrupterManagementRegister = packed struct(u32) {
    /// Interrupt Pending (IP)
    ip: bool,
    /// Interrupt Enable (IE)
    ie: bool,
    /// Reserved.
    _reserved: u30,
};

/// Interrupter Moderation Register (IMOD) that controls the moderation feature of an Interrupter.
pub const InterrupterModerationRegister = packed struct(u32) {
    /// Interrupter Moderation Interval, in 250ns increments (IMODI).
    imodi: u16,
    /// Reserved.
    _reserved: u16,
};

/// PORTSC.
///
/// Can be used to determine how many ports need to be serviced.
const PortStatusControlRegister = packed struct(u32) {
    /// MMIO register type.
    const RegisterType = Register(PortStatusControlRegister, .dword);
    /// Offset from the Port Register Set base.
    const address_base = 0x0;

    /// Current Connect Status.
    /// If true, the port is connected to a device.
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

/// Set of registers associated with a USB port.
pub const PortRegisterSet = packed struct(u128) {
    /// MMIO register type.
    pub const RegisterType = Register(PortRegisterSet, .dword);
    /// Offset from the Operational Registers base.
    const address_base = 0x400;

    /// Port Status and Control.
    portsc: PortStatusControlRegister,
    /// Port Power Management Status and Control.
    portpmsc: u32,
    /// Port Link Info.
    portli: u32,
    /// Port Hardware LPM Control.
    porthlpmc: u32,

    /// Get the Port Register Set of the given port number.
    pub inline fn getAt(
        operational_base: IoAddr,
        port_number: usize,
    ) RegisterType {
        return RegisterType.new(operational_base.add(address_base + port_number * 0x10));
    }
};

const PortSpeed = enum(u4) {
    invalid = 0,
    full = 1,
    low = 2,
    high = 3,
    super = 4,
    super_plus = 5,
};

// =============================================================
// Imports
// =============================================================

const norn = @import("norn");
const Register = norn.mmio.Register;
const IoAddr = norn.mem.IoAddr;
