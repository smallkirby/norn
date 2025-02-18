pub const mp = @import("mp.zig");
pub const task = @import("task.zig");

pub const ApicTimer = apic.Timer;
pub const InterruptContext = isr.Context;
pub const InterruptRegisters = isr.Registers;
pub const LocalApic = apic.LocalApic;
const Msr = regs.Msr;

const std = @import("std");
const log = std.log.scoped(.arch);

const norn = @import("norn");
const bits = norn.bits;
const mem = norn.mem;
const interrupt = norn.interrupt;
const PageAllocator = mem.PageAllocator;
const Phys = mem.Phys;
const Virt = mem.Virt;

const am = @import("asm.zig");
const apic = @import("apic.zig");
const cpuid = @import("cpuid.zig");
const gdt = @import("gdt.zig");
const intr = @import("intr.zig");
const isr = @import("isr.zig");
const pg = @import("page.zig");
const regs = @import("registers.zig");
const syscall = @import("syscall.zig");

// Architecture-specific error type.
pub const Error = apic.Error || intr.Error || apic.Error || syscall.Error;

/// Saved registers for system call handlers.
pub const SyscallContext = syscall.Registers;

/// Reconstruct the page tables
/// This function MUST be called only once.
pub fn bootReconstructPageTable(allocator: PageAllocator) pg.PageError!void {
    try pg.boot.reconstruct(allocator);
}

/// Disable external interrupts.
pub inline fn disableIrq() void {
    am.cli();
}

/// Enable external interrupts.
pub inline fn enableIrq() void {
    am.sti();
}

/// Enable system calls.
pub const enableSyscall = syscall.init;

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
        : "rax"
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

/// Write a byte to an I/O port.
pub fn out(T: type, value: T, port: u16) void {
    return switch (T) {
        u8 => am.outb(value, port),
        u16 => am.outw(value, port),
        u32 => am.outl(value, port),
        else => @compileError("Unsupported type for asm out()"),
    };
}

/// Get the APIC ID of the BSP.
pub fn queryBspId() u8 {
    const leaf = cpuid.Leaf.version_info.query(null);
    return @truncate(leaf.ebx >> 24);
}

/// Pause a CPU for a short period of time.
pub fn relax() void {
    am.relax();
}

/// Set the interrupt handler.
pub fn setInterruptHandler(vector: u8, handler: interrupt.Handler) Error!void {
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

// ========================================

test {
    std.testing.refAllDeclsRecursive(@This());
}
