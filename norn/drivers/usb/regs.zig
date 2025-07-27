/// Interrupt Register Set in the xHC's Runtime Registers.
///
/// An Interrupter manages events and their notification to the host.
pub const InterrupterRegisterSet = packed struct(u256) {
    pub const RegisterType = Register(InterrupterRegisterSet, .dword);

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
    erdp: Erdp,

    pub const Erdp = packed struct(u64) {
        /// Dequeue ERST Segment Index. May be used by xHC.
        desi: u3,
        /// EHB. RW1C.
        ehb: u1,
        /// High 60 bits of current Event Ring Dequeue Pointer.
        erdp: u60,

        pub inline fn addr(self: Erdp) Phys {
            return @as(u64, self.erdp) << 4;
        }

        pub inline fn set(self: *Erdp, ptr: Phys) void {
            self.erdp = @intCast(ptr >> 4);
        }
    };

    /// Create a reader / writer for the Interrupter Register Set.
    pub inline fn get(addr: IoAddr) RegisterType {
        return RegisterType.new(addr);
    }
};

/// Interrupter Management Register (IMAN) that allows system software to enable, disable, and detect xHC interrupts.
pub const InterrupterManagementRegister = packed struct(u32) {
    /// Interrupt Pending (IP). RW1C.
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
    /// Connect Status Change. RW1CS.
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

/// Doorbell Register (DB).
//
/// xHC presents an array of up to 256 32-bit registers in MMIO space and are indexed by Device Slot ID.
//
/// Doobell 0 is dedicated to the Host Controller.
//
/// Doobell 1-255 are referred to as the Device Context Doorbell.
/// There's a 1:1 mapping of Device Context DB to Device Slots.
//
/// Software writes to DB to notify the xHC that there's new TRB in the Command Ring or Transfer Ring.
/// No need to clear DBs.
/// Returns no information on read.
pub const DoorBell = packed struct(u32) {
    /// DB Target.
    /// Target of the doorbell reference.
    target: u8,
    /// Reserved.
    _reserved1: u8 = 0,
    /// DB Stream ID.
    stream_id: u16 = 0,
};

// =============================================================
// Imports
// =============================================================

const norn = @import("norn");
const Phys = norn.mem.Phys;
const Register = norn.mmio.Register;
const IoAddr = norn.mem.IoAddr;
