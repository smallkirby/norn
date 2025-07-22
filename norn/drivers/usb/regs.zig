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
