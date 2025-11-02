/// x64 CPU context.
pub const CpuContext = packed struct {
    // Callee-saved registers.
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,

    // Caller-saved registers.
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rax: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,

    // Context-specific data.
    spec1: SpecData1 = .zero,
    spec2: SpecData2 = .zero,

    // Interrupt frame.
    rip: u64,
    cs: u64,
    rflags: u64,
    // Available only when interrupt is called from user mode.
    rsp: u64,
    ss: u64,

    const SpecData1 = packed union {
        /// Interrupt vector on interrupt.
        vector: u64,
        /// Unused.
        unused: u64,

        const zero = SpecData1{ .unused = 0 };
    };

    const SpecData2 = packed union {
        /// Original RAX on syscall.
        orig_rax: u64,
        /// Error code on interrupt.
        error_code: u64,
        /// Unused.
        unused: u64,

        const zero = SpecData2{ .unused = 0 };
    };

    comptime {
        norn.comptimeAssert(@bitSizeOf(SpecData1) == 64, "Invalid size of SpecData1", .{@bitSizeOf(SpecData1)});
        norn.comptimeAssert(@bitSizeOf(SpecData2) == 64, "Invalid size of SpecData2", .{@bitSizeOf(SpecData2)});
        norn.comptimeAssert(@sizeOf(@This()) % 0x10 == 0, "Invalid size of CpuContext", .{@sizeOf(@This())});
        norn.comptimeAssert(@sizeOf(@This()) == 0xB0, "Invalid size of CpuContext", .{@sizeOf(@This())});
    }

    /// Check if the interrupt is called from user mode.
    pub inline fn isFromUserMode(self: CpuContext) bool {
        return (self.cs & 0b11) == 0b11; // Check RPL
    }
};

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
    _reserved3: u8 = 0,
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

/// XCR0 register.
pub const Xcr0 = packed struct(u64) {
    /// X87. Must be set.
    x87: bool = true,
    /// SSE. If set, the XSAVE feature set can be used to manage MXCSR and the XMM registers.
    sse: bool,
    /// AVX. If set, AVX instructions can be executed and the XSAVE feature set can be used to manage the upper halves of the YMM registers.
    avx: bool,
    /// BNDREG. If set, MPX instructions can be executed.
    bndreg: bool,
    /// BNDCSR. If set, MPX instructions can be executed.
    bndcsr: bool,
    /// If set, AVX-512 instructions can be executed and the XSAVE feature set can be used to manage the opmask registers k0-k7.
    opmask: bool,
    /// If set, AVX-512 instructions can be executed and the XSAVE feature set can be used to manage the lower ZMM registers.
    zmm_hi256: bool,
    /// If set, AVX-512 instructions can be executed and the XSAVE feature set can be used to manage the upper ZMM registers.
    hi16_zmm: bool,
    /// Reserved.
    _reserved1: u1 = 0,
    /// If true, the XSAVE feature set can be used to manage the PKRU register.
    pkru: bool,
    /// Reserved.
    _reserved2: u7 = 0,
    /// If set, and if TILEDATA is set, AMX instructions can be executed.
    tilecfg: bool,
    /// If set, and if TILECFG is set, AMX instructions can be executed.
    tiledata: bool,
    /// Reserved.
    _reserved3: u45 = 0,
};

/// Address of Model-Specific Registers.
pub const Msr = enum(u64) {
    /// IA32_APIC_BASE.
    apic_base = 0x1B,

    /// IA32_EFER
    efer = 0xC000_0080,
    /// IA32_STAR.
    star = 0xC000_0081,
    /// IA32_LSTAR.
    lstar = 0xC000_0082,
    /// IA32_CSTAR.
    cstar = 0xC000_0083,
    /// IA32_FMASK
    fmask = 0xC000_0084,

    /// IA32_KERNEL_GS_BASE.
    kernel_gs_base = 0xC000_0102,

    _,
};

/// IA32_APIC_BASE MSR
pub const MsrApicBase = packed struct(u64) {
    /// Reserved.
    _reserved1: u8,
    /// Whether the processor is the BSP.
    is_bsp: bool,
    /// Reserved.
    _reserved2: u2,
    /// APIC global enable.
    enable: bool,
    /// APIC base physical address
    base: u20,
    /// Reserved.
    _reserved3: u32 = 0,

    /// Set the physical base of the local APIC.
    /// Note that this function does not set the value to the MSR.
    pub fn setAddress(self: *MsrApicBase, phys: Phys) void {
        self.base = @intCast(phys >> 12);
    }

    /// Get the physical base of the local APIC.
    pub fn getAddress(self: MsrApicBase) Phys {
        return @as(Phys, self.base) << 12;
    }

    /// Get the physical base of the I/O APIC.
    pub fn getIoApicAddress(self: MsrApicBase) Phys {
        return @as(Phys, 0xFEC0_0000) | ((self.base & 0xFF) << 12);
    }
};

/// IA32_EFER MSR
pub const MsrEfer = packed struct(u64) {
    /// SYSCALL / SYSRET enable.
    sce: bool,
    /// Reserved.
    _reserved1: u7 = 0,
    /// Long mode enable.
    lme: bool,
    /// Reserved.
    _reserved2: u1 = 0,
    /// Long mode active.
    lma: bool,
    /// Execute Disable Bit Enable.
    nxe: bool,
    /// Reserved.
    _reserved3: u52 = 0,
};

/// IA32_STAR MSR
pub const MsrFmask = packed struct(u64) {
    /// SYSCALL EFLAGS mask.
    ///
    /// RFLAGS is set to the logical-AND of the current value and the complement of this mask.
    flags: Rflags,
};

/// IA32_LSTAR MSR
pub const MsrLstar = packed struct(u64) {
    /// Target RIP for SYSCALL.
    rip: u64,
};

/// IA32_STAR MSR
pub const MsrStar = packed struct(u64) {
    /// Reserved.
    _reserved: u32 = 0,
    /// Target CS selector for SYSCALL.
    /// SS is computed by adding 8 to the value.
    syscall_cs_ss: u16,
    /// Target CS selector for SYSRET.
    /// SS is computed by subtracting 8 from the value.
    sysret_cs_ss: u16,
};

const norn = @import("norn");
const mem = norn.mem;

const Phys = mem.Phys;
