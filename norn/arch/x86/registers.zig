const norn = @import("norn");

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

/// CR0 register.
pub const Cr0 = packed struct(u64) {
    /// Protected mode enable.
    pe: bool,
    /// Monitor co-processor.
    mp: bool,
    /// Emulation.
    em: bool,
    /// Task switched.
    ts: bool,
    /// Extension type.
    et: bool,
    /// Numeric error.
    ne: bool,
    /// Reserved.
    _reserved1: u10 = 0,
    /// Write protect.
    wp: bool,
    /// Reserved.
    _reserved2: u1 = 0,
    /// Alignment mask.
    am: bool,
    /// Reserved.
    _reserved3: u10 = 0,
    /// Not-Write Through.
    nw: bool,
    /// Cache disable.
    cd: bool,
    /// Paging.
    pg: bool,
    /// Reserved.
    _reserved4: u32 = 0,
};

/// CR2 register. It contains VA of the last page fault.
pub const Cr2 = norn.mem.Virt;

/// CR4 register.
pub const Cr4 = packed struct(u64) {
    /// Virtual-8086 mode extensions.
    vme: bool,
    /// Protected mode virtual interrupts.
    pvi: bool,
    /// Time stamp disable.
    tsd: bool,
    /// Debugging extensions.
    de: bool,
    /// Page size extension.
    pse: bool,
    /// Physical address extension. If unset, 32-bit paging.
    pae: bool,
    /// Machine check exception.
    mce: bool,
    /// Page global enable.
    pge: bool,
    /// Performance monitoring counter enable.
    pce: bool,
    /// Operating system support for FXSAVE and FXRSTOR instructions.
    osfxsr: bool,
    /// Operating system support for unmasked SIMD floating-point exceptions.
    osxmmexcpt: bool,
    /// Virtual machine extensions.
    umip: bool,
    /// 57-bit linear addresses. If set, CPU uses 5-level paging.
    la57: bool = false,
    /// Virtual machine extensions enable.
    vmxe: bool,
    /// Safer mode extensions enable.
    smxe: bool,
    /// Reserved.
    _reserved2: u1 = 0,
    /// Enables the instructions RDFSBASE, RDGSBASE, WRFSBASE, and WRGSBASE.
    fsgsbase: bool,
    /// PCID enable.
    pcide: bool,
    /// XSAVE and processor extended states enable.
    osxsave: bool,
    /// Reserved.
    _reserved3: u1 = 0,
    /// Supervisor mode execution protection enable.
    smep: bool,
    /// Supervisor mode access protection enable.
    smap: bool,
    /// Protection key enable.
    pke: bool,
    /// Control-flow Enforcement Technology enable.
    cet: bool,
    /// Protection keys for supervisor-mode pages enable.
    pks: bool,
    /// Reserved.
    _reserved4: u39 = 0,
};
