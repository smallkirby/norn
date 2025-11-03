pub const IntrError = error{
    AlreadyRegistered,
};

/// Interrupt handlers.
var handlers: [arch.max_num_interrupts]Handler =
    [_]Handler{unhandledHandler} ** arch.max_num_interrupts;

/// Interrupt vector table defined by Norn.
///
/// Vector 0x00-0x1F are reserved by CPU.
pub const Vector = enum(u8) {
    /// Timer interrupt.
    timer = 0x20,
    /// xHC interrupt.
    usb = 0x21,
    /// UART.
    serial = 0x22,
    /// Spurious interrupt.
    spurious = arch.max_num_interrupts - 1,
};

/// Context for interrupt handlers.
pub const Context = arch.Context;

/// Interrupt handler function signature.
pub const Handler = *const fn (*Context) void;

/// Initialize the interrupt subsystem globally.
pub fn globalInit() IntrError!void {
    try setHandler(.spurious, spuriousInterruptHandler);
}

/// Set an interrupt handler for the given vector.
///
/// Fails if a handler is already registered for the vector.
pub fn setHandler(vector: Vector, handler: Handler) IntrError!void {
    if (handlers[@intFromEnum(vector)] != unhandledHandler) {
        return IntrError.AlreadyRegistered;
    }
    handlers[@intFromEnum(vector)] = handler;
}

/// Call the registered interrupt handler for the given vector.
pub fn call(vector: u64, context: *Context) void {
    const current = norn.sched.getCurrentTask();
    const in_irq = current.flags.in_irq.load(.acquire);
    current.flags.in_irq.store(true, .release);
    defer current.flags.in_irq.store(in_irq, .release);

    // Call corresponding handler.
    handlers[vector](context);

    // Schedule if needed.
    if (!in_irq and isIrq(vector) and norn.sched.needReschedule()) {
        norn.sched.disablePreemption();
        norn.arch.enableIrq();
        norn.sched.schedule();
        _ = arch.disableIrq();
        norn.sched.enablePreemption();
    }
}

/// Check if the given vector is an IRQ.
fn isIrq(vector: u64) bool {
    return 0x20 <= vector; // TODO: arch-specific
}

/// Interrupt handler for spurious interrupts.
fn spuriousInterruptHandler(_: *norn.interrupt.Context) void {
    std.log.scoped(.spurious).warn("Detected a spurious interrupt.", .{});
    arch.getLocalApic().eoi();
}

/// Default handlers for unhandled interrupts.
fn unhandledHandler(context: *Context) void {
    @branchHint(.cold);

    switch (@import("builtin").target.cpu.arch) {
        .x86_64 => x64UnhandledHandler(context),
        else => @compileError("Unsupported architecture."),
    }
}

// =============================================================
// Arch-specific unhandled interrupt handlers
// =============================================================

/// x64-specific unhandled interrupt handler.
fn x64UnhandledHandler(context: *Context) void {
    @branchHint(.cold);

    const am = @import("arch/x86/asm.zig");
    const intr = @import("arch/x86/interrupt.zig");
    const Exception = intr.Exception;

    var writer = norn.UnsafeWriter.new();

    const exception: Exception = @enumFromInt(context.spec1.vector);
    writer.log("============ Oops! ===================", .{});
    const cpuid = norn.arch.getLocalApic().id();
    writer.log("Core#{d:0>2}: Unhandled interrupt: {s} ({})", .{
        cpuid,
        exception.name(),
        context.spec1.vector,
    });

    {
        writer.log("Error Code : 0x{X}", .{context.spec2.error_code});
        writer.log("RIP        : 0x{X:0>16}", .{context.rip});
        writer.log("RFLAGS     : 0x{X:0>16}", .{context.rflags});
        writer.log("RAX        : 0x{X:0>16}", .{context.rax});
        writer.log("RBX        : 0x{X:0>16}", .{context.rbx});
        writer.log("RCX        : 0x{X:0>16}", .{context.rcx});
        writer.log("RDX        : 0x{X:0>16}", .{context.rdx});
        writer.log("RSI        : 0x{X:0>16}", .{context.rsi});
        writer.log("RDI        : 0x{X:0>16}", .{context.rdi});
        writer.log("RBP        : 0x{X:0>16}", .{context.rbp});
        writer.log("R8         : 0x{X:0>16}", .{context.r8});
        writer.log("R9         : 0x{X:0>16}", .{context.r9});
        writer.log("R10        : 0x{X:0>16}", .{context.r10});
        writer.log("R11        : 0x{X:0>16}", .{context.r11});
        writer.log("R12        : 0x{X:0>16}", .{context.r12});
        writer.log("R13        : 0x{X:0>16}", .{context.r13});
        writer.log("R14        : 0x{X:0>16}", .{context.r14});
        writer.log("R15        : 0x{X:0>16}", .{context.r15});
        writer.log("CS         : 0x{X:0>4}", .{context.cs});
        if (context.isFromUserMode()) {
            writer.log("SS         : 0x{X:0>4}", .{context.ss});
            writer.log("RSP        : 0x{X:0>16}", .{context.rsp});
        }

        const cr0: u64 = @bitCast(am.readCr0());
        const cr2: u64 = @bitCast(am.readCr2());
        const cr3: u64 = @bitCast(am.readCr3());
        const cr4: u64 = @bitCast(am.readCr4());
        writer.log("CR0        : 0x{X:0>16}", .{cr0});
        writer.log("CR2        : 0x{X:0>16}", .{cr2});
        writer.log("CR3        : 0x{X:0>16}", .{cr3});
        writer.log("CR4        : 0x{X:0>16}", .{cr4});
    }

    if (norn.pcpu.isThisCpuInitialized(cpuid) and context.isFromUserMode()) {
        writer.log("Memory map of the current task:", .{});
        const task = norn.sched.getCurrentTask();
        var node: ?*norn.mm.VmArea = task.mm.vm_areas.first;
        while (node) |area| : (node = area.list_head.next) {
            writer.log(
                "  {X}-{X} {s}",
                .{ area.start, area.end, area.flags.toString() },
            );
        }
    }

    // Print thread information.
    if (norn.pcpu.isThisCpuInitialized(cpuid) and norn.sched.isInitialized()) {
        const current = norn.sched.getCurrentTask();

        writer.log("", .{});
        writer.log("=== Task Information =====================", .{});
        writer.log("TID    : {d}", .{current.tid});
        writer.log("Name   : {s}", .{current.name});
        writer.log("Kstack : 0x{X:0>8}-0x{X:0>8}", .{ @intFromPtr(current.kstack.ptr), current.kstackBottom() });
    }

    // Check if it's a kernel stack overflow.
    if (norn.pcpu.isThisCpuInitialized(cpuid) and norn.sched.isInitialized()) {
        const current = norn.sched.getCurrentTask();
        const kstack = current.kstack;
        const kstack_guard_start = @intFromPtr(kstack.ptr);
        if (kstack_guard_start <= context.rsp and context.rsp < (kstack_guard_start + norn.mem.size_4kib)) {
            writer.log("", .{});
            writer.log("!!! This might be a kernel stack overflow !!!", .{});
        }
    }

    // Print the stack trace.
    {
        writer.log("", .{});
        var it = std.debug.StackIterator.init(null, context.rbp);
        var ix: usize = 0;
        writer.log("=== Stack Trace =====================", .{});
        while (it.next()) |frame| : (ix += 1) {
            writer.log("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
        }
    }

    writer.log("=====================================", .{});
    writer.log("Halting...", .{});
    norn.endlessHalt();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const arch = norn.arch;
