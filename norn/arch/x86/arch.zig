pub const msi = @import("msi.zig");
pub const mp = @import("mp.zig");
pub const task = @import("task.zig");

pub const ApicTimer = apic.Timer;
pub const Context = regs.CpuContext;
pub const LocalApic = apic.LocalApic;

// Architecture-specific error type.
pub const ArchError = apic.ApicError || intr.IntrError || pg.PageError || syscall.Error;

/// Saved registers for system call handlers.
pub const SyscallContext = regs.CpuContext;

/// Initialize the architecture-specific components.
pub fn init() ArchError!void {
    const ie = disableIrq();
    defer if (ie) enableIrq();

    enableAvx();
}

/// Enable AVX instructions.
///
/// TODO: Save and restore the state of AVX registers on task switch.
fn enableAvx() void {
    // Check if AVX is supported
    const cpuid_res = cpuid.Leaf.version_info.query(0);
    const avx_supported = bits.isset(cpuid_res.ecx, 28);

    if (avx_supported) {
        var cr4 = am.readCr4();
        if (!cr4.osxsave) {
            cr4.osxsave = true;
            am.writeCr4(cr4);
        }

        var xcr0: regs.Xcr0 = @bitCast(am.xgetbv(0));
        xcr0.sse = true;
        xcr0.avx = true;
        am.xsetbv(0, @bitCast(xcr0));
    } else {
        log.warn("Failed to enable AVX instructions: not supported.", .{});
    }
}

/// Disable external interrupts.
pub fn disableIrq() bool {
    const ie = isIrqEnabled();
    am.cli();
    return ie;
}

/// Enable external interrupts.
pub inline fn enableIrq() void {
    am.sti();
}

/// Enable system calls.
pub const enableSyscall = syscall.init;

/// Get FS base address.
pub fn getFs() u64 {
    return asm volatile (
        \\rdfsbase %[fs]
        : [fs] "={rax}" (-> u64),
    );
}

/// Get frequency of TSC in Hz.
pub fn getTscFrequency() error{NotEnumerated}!u64 {
    const res = cpuid.Leaf.from(0x15).query(0);
    const nominal_core: u128 = res.ecx; // nominal core crystal clock frequency in Hz
    const numerator: u128 = res.ebx; // numerator of the TSC / core crystal clock ratio
    const denominator: u128 = res.eax; // dominator of the TSC / core crystal clock ratio

    if (numerator == 0 or denominator == 0) {
        return error.NotEnumerated;
    }

    if (nominal_core != 0) {
        return @intCast(nominal_core * numerator / denominator);
    } else {
        // Some processors do not report the core crystal clock frequency.
        const res2 = cpuid.Leaf.from(0x16).query(0);
        const base_freq: u128 = res2.eax; // base frequency in MHz
        return @intCast(base_freq * 1_000_000 * numerator / denominator);
    }
}

/// Get the local APIC.
pub fn getLocalApic() apic.LocalApic {
    const base = am.rdmsr(regs.MsrApicBase, .apic_base).getAddress();
    return apic.LocalApic.new(base);
}

/// Get the per-CPU base address.
pub fn getPerCpuBase() Virt {
    return asm volatile (
        \\rdfsbase %[base]
        : [base] "={rax}" (-> Phys),
        :
        : .{ .rax = true }
    );
}

/// Halt the current CPU.
pub inline fn halt() void {
    am.hlt();
}

/// Check if external interrupts are enabled.
pub fn isIrqEnabled() bool {
    return am.readRflags().ie;
}

/// Read a data from an I/O port.
pub inline fn in(T: type, port: u16) T {
    return switch (T) {
        u8 => am.inb(port),
        u16 => am.inw(port),
        u32 => am.inl(port),
        else => @compileError("Unsupported type for asm in()"),
    };
}

/// Read a byte from a MMIO address.
pub fn read8(addr: IoAddr) u8 {
    return asm volatile (
        \\mov (%[addr]), %[result]
        : [result] "=r" (-> u8),
        : [addr] "r" (addr._virt),
        : .{ .memory = true }
    );
}

/// Read a word from a MMIO address.
pub fn read16(addr: IoAddr) u16 {
    return asm volatile (
        \\mov (%[addr]), %[result]
        : [result] "=r" (-> u16),
        : [addr] "r" (addr._virt),
        : .{ .memory = true }
    );
}

/// Read a dword from a MMIO address.
pub fn read32(addr: IoAddr) u32 {
    return asm volatile (
        \\mov (%[addr]), %[result]
        : [result] "=r" (-> u32),
        : [addr] "r" (addr._virt),
        : .{ .memory = true }
    );
}

/// Read a qword from a MMIO address.
pub fn read64(addr: IoAddr) u64 {
    return asm volatile (
        \\mov (%[addr]), %[result]
        : [result] "=r" (-> u64),
        : [addr] "r" (addr._virt),
        : .{ .memory = true }
    );
}

/// Write a byte to a MMIO address.
pub fn write8(addr: IoAddr, value: u8) void {
    asm volatile (
        \\mov %[value], (%[addr])
        :
        : [value] "r" (value),
          [addr] "r" (addr._virt),
        : .{ .memory = true }
    );
}

/// Write a word to a MMIO address.
pub fn write16(addr: IoAddr, value: u16) void {
    asm volatile (
        \\mov %[value], (%[addr])
        :
        : [value] "r" (value),
          [addr] "r" (addr._virt),
        : .{ .memory = true }
    );
}

/// Write a dword to a MMIO address.
pub fn write32(addr: IoAddr, value: u32) void {
    asm volatile (
        \\mov %[value], (%[addr])
        :
        : [value] "r" (value),
          [addr] "r" (addr._virt),
        : .{ .memory = true }
    );
}

/// Write a qword to a MMIO address.
pub fn write64(addr: IoAddr, value: u64) void {
    asm volatile (
        \\mov %[value], (%[addr])
        :
        : [value] "r" (value),
          [addr] "r" (addr._virt),
        : .{ .memory = true }
    );
}

/// Initialize boot-time GDT.
pub fn initEarlyGdt() void {
    return gdt.init();
}

/// Setup GDT for the current CPU.
pub fn initGdtThisCpu(allocator: PageAllocator) PageAllocator.Error!void {
    return gdt.setupThisCpu(allocator);
}

/// Initialize interrupt and exception handling.
/// Note that this function does not enable interrupts.
pub fn initInterrupt() void {
    intr.init();
}

/// Initialize APIC.
pub fn initApic() !void {
    return apic.init();
}

/// Check if the current CPU is the BSP.
pub fn isCurrentBsp() bool {
    return am.rdmsr(regs.MsrApicBase, .apic_base).is_bsp;
}

/// Check if TSC is supported on this CPU.
pub fn isTscSupported() bool {
    const res = cpuid.Leaf.version_info.query(0);
    return bits.isset(res.edx, 4);
}

/// Write a byte to an I/O port.
pub fn out(T: type, value: anytype, port: u16) void {
    return switch (T) {
        u8 => am.outb(@bitCast(value), port),
        u16 => am.outw(@bitCast(value), port),
        u32 => am.outl(@bitCast(value), port),
        else => @compileError("Unsupported type for asm out()"),
    };
}

/// Get the APIC ID of the BSP.
pub fn queryBspId() u8 {
    const leaf = cpuid.Leaf.version_info.query(null);
    return @truncate(leaf.ebx >> 24);
}

/// Read TSC.
pub fn readTsc() u64 {
    return am.rdtsc();
}

/// Pause a CPU for a short period of time.
pub fn relax() void {
    am.relax();
}

/// Set FS base address.
pub fn setFs(base: u64) void {
    asm volatile (
        \\wrfsbase %[fs]
        :
        : [fs] "r" (base),
    );
}

/// Set the interrupt handler.
pub fn setInterruptHandler(vector: u8, handler: interrupt.Handler) error{AlreadyRegistered}!void {
    return intr.setHandler(vector, handler);
}

/// Set the per-CPU base address.
pub fn setPerCpuBase(base: Virt) void {
    // Check if fsgsbase is supported
    const cpuid_fsgsbase_bit = 1 << 0;
    const cpuid_res = cpuid.Leaf.ext_feature.query(0);
    const fsgsbase_supported = (cpuid_res.ebx & cpuid_fsgsbase_bit) != 0;
    if (!fsgsbase_supported) {
        @panic("FSGSBASE is not supported."); // TODO don't panic. should fallback to wrmsr.
    }

    // Enable fsgsbase if not enabled
    var cr4 = am.readCr4();
    if (!cr4.fsgsbase) {
        cr4.fsgsbase = true;
        am.writeCr4(cr4);
    }

    // Set the base address
    asm volatile (
        \\wrgsbase %[base]
        :
        : [base] "r" (base),
    );

    // Set to KERNEL_GS_BASE.
    am.wrmsr(.kernel_gs_base, base);
}

/// Execute an undefined instruction.
pub fn ud() noreturn {
    asm volatile ("ud2");
    unreachable;
}

/// Memory-related services.
pub const mem = struct {
    /// Page attribute.
    pub const Attribute = pg.Attribute;

    /// Reconstruct the page tables
    /// Caller MUST ensure that this function is called only once.
    pub fn bootReconstructPageTable(allocator: PageAllocator) pg.PageError!void {
        try pg.boot.reconstruct(allocator);
    }

    /// Change the page attribute.
    pub fn changeAttribute(cr3: Virt, vaddr: Virt, size: usize, attr: Attribute) ArchError!void {
        return pg.changeAttribute(cr3, vaddr, size, attr);
    }

    /// Convert VM flags to page attribute.
    pub fn convertVmFlagToAttribute(flags: norn.mm.VmFlags) Attribute {
        return pg.Attribute.fromVmFlags(flags);
    }

    /// Create a new root of page tables.
    /// Returns a virtual address of the root table (CR).
    pub fn createPageTables() ArchError!Virt {
        return pg.createPageTables();
    }

    /// Get the page attribute of a virtual address.
    pub fn getPageAttribute(cr3: Virt, vaddr: Virt) ?Attribute {
        return pg.getPageAttribute(cr3, vaddr);
    }

    /// Get the virtual address of the root table (CR3).
    pub fn getRootTable() Virt {
        return norn.mem.phys2virt(am.readCr3());
    }

    /// Maps a physical address to a virtual address.
    pub fn map(cr3: Virt, vaddr: Virt, paddr: Virt, size: usize, attr: Attribute) ArchError!void {
        return pg.map(cr3, vaddr, paddr, size, attr);
    }

    /// Unmaps a virtual address.
    pub fn unmap(cr3: Virt, vaddr: Virt, size: usize) ArchError!void {
        return pg.unmap(cr3, vaddr, size);
    }

    /// Set the root table (CR3).
    pub inline fn setPagetable(cr3: Virt) void {
        am.writeCr3(norn.mem.virt2phys(cr3));
    }

    /// Translate a virtual address to a physical address.
    pub fn translate(cr3: Virt, vaddr: Virt) ?Phys {
        return pg.translateWalk(cr3, vaddr);
    }
};

// ========================================

test {
    std.testing.refAllDeclsRecursive(@This());
}

// ========================================

const std = @import("std");
const log = std.log.scoped(.arch);

const norn = @import("norn");
const bits = norn.bits;
const interrupt = norn.interrupt;
const PageAllocator = norn.mem.PageAllocator;
const IoAddr = norn.mem.IoAddr;
const Phys = norn.mem.Phys;
const Virt = norn.mem.Virt;

const am = @import("asm.zig");
const apic = @import("apic.zig");
const cpuid = @import("cpuid.zig");
const gdt = @import("gdt.zig");
const intr = @import("intr.zig");
const isr = @import("isr.zig");
const pg = @import("page.zig");
const regs = @import("registers.zig");
const syscall = @import("syscall.zig");
