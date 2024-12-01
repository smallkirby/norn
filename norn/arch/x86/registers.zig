pub const Rflags = packed struct(u64) {
    /// Carry flag.
    cf: bool,
    /// Reserved. Must be 1.
    _reservedO: u1 = 1,
    /// Parity flag.
    pf: bool,
    /// Reserved. Must be 0.
    _reserved1: u1 = 0,
    /// Auxiliary carry flag.
    af: bool,
    /// Reserved. Must be 0.
    _reserved2: u1 = 0,
    /// Zero flag.
    zf: bool,
    /// Sign flag.
    sf: bool,
    /// Trap flag.
    tf: bool,
    /// Interrupt enable flag.
    ie: bool,
    /// Direction flag.
    df: bool,
    /// Overflow flag.
    of: bool,
    /// IOPL (I/O privilege level).
    iopl: u2,
    /// Nested task flag.
    nt: bool,
    /// Reserved. Must be 0.
    md: u1 = 0,
    /// Resume flag.
    rf: bool,
    /// Virtual 8086 mode flag.
    vm: bool,
    // Alignment check.
    ac: bool,
    /// Virtual interrupt flag.
    vif: bool,
    /// Virtual interrupt pending.
    vip: bool,
    /// CPUID support.
    id: bool,
    /// Reserved.
    _reserved3: u8,
    /// Reserved.
    aes: bool,
    /// Alternate instruction set enabled.
    ai: bool,
    /// Reserved. Must be 0.
    _reserved4: u32 = 0,
};
