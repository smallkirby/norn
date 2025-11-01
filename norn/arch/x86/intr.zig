//! Interrupt handling for x86_64 architecture.
//!
//! This module manages entries in IDT and interrupt handlers.

pub const IntrError = error{
    /// Handler is already registered for the vector.
    AlreadyRegistered,
};

/// Interrupt Descriptor Table.
///
/// Shared among all CPUs.
var idt: Idt = undefined;

/// Interrupt handlers.
var handlers: [max_num_gates]Handler = [_]Handler{unhandledHandler} ** max_num_gates;

/// Maximum number of gates in the IDT.
const max_num_gates = 256;

/// Index within IST array for each exception.
const IstIndex = enum(u3) {
    double_fault = 1,
};

/// Initialize the IDT.
pub fn globalInit() void {
    idt.init();

    // Set IST for #DF and #PF.
    idt.setIstack(.df, .double_fault);
    idt.setIstack(.pf, .double_fault);

    // Load to IDTR.
    idt.load();
}

/// Dispatches the interrupt to the appropriate handler.
///
/// Called from the ISR stub.
pub fn dispatch(context: *Context) void {
    handlers[context.spec1.vector](context);
}

/// Set an interrupt handler for the given vector.
///
/// Fails if a handler is already registered for the vector.
pub fn setHandler(vector: u8, handler: Handler) IntrError!void {
    if (handlers[vector] != unhandledHandler) {
        return IntrError.AlreadyRegistered;
    }
    handlers[vector] = handler;
}

/// Interrupt Descriptor Table (IDT).
const Idt = extern struct {
    const Self = @This();

    /// Alignment of the IDT.
    const idt_align = mem.size_4kib;

    /// IDT entries.
    _data: [max_num_gates]GateDesc align(idt_align),

    /// Initialize the IDT by setting all entries to ISR stubs.
    pub fn init(self: *Self) void {
        rtt.expect(util.isAligned(self, idt_align));

        // Zero-clear the IDT.
        @memset(self._data[0..], @bitCast(@as(u128, 0)));

        // Set ISR stubs for all gates.
        inline for (0..max_num_gates) |i| {
            self.initEntry(i);
        }
    }

    /// Set a gate descriptor at the given index.
    fn initEntry(self: *Self, comptime index: usize) void {
        rtt.expect(index < max_num_gates);

        const gate = GateDesc.new(
            @intFromPtr(&isr.generateIsr(index)),
            .kernel_cs,
            .interrupt_gate,
            0,
        );

        self._data[index] = gate;
    }

    /// Set the interrupt stack for the given exception.
    pub fn setIstack(self: *Self, index: Exception, ist_index: IstIndex) void {
        self._data[@intFromEnum(index)].ist = @intFromEnum(ist_index);
    }

    /// Load this IDT into the IDTR.
    pub fn load(self: *Self) void {
        am.lidt(@intFromPtr(&IdtRegister{
            .limit = @sizeOf(@TypeOf(self._data)) - 1,
            .base = &self._data,
        }));
    }
};

/// 64 bit Mode Gate descriptor.
pub const GateDesc = packed struct(u128) {
    /// Lower 16 bits of the offset to the ISR.
    offset_low: u16,
    /// Segment Selector that must point to a valid code segment in the GDT.
    seg_selector: u16,
    /// Interrupt Stack Table.
    /// If set to 0, the processor does not switch stacks.
    ist: u3 = 0,
    /// Reserved.
    _reserved1: u5 = 0,
    /// Gate Type.
    gate_type: Type,
    /// Reserved.
    _reserved2: u1 = 0,
    /// Descriptor Privilege Level is the required CPL to call the ISR via the INT inst.
    /// Hardware interrupts ignore this field.
    dpl: u2,
    /// Present flag. Must be 1.
    present: bool = true,
    /// Middle 16 bits of the offset to the ISR.
    offset_middle: u16,
    /// Higher 32 bits of the offset to the ISR.
    offset_high: u32,
    /// Reserved.
    _reserved3: u32 = 0,

    /// Type of gate descriptor.
    const Type = enum(u4) {
        call_gate = 0b1100,
        interrupt_gate = 0b1110,
        trap_gate = 0b1111,

        _,
    };

    pub fn new(
        offset: u64,
        index: gdt.SegIndex,
        gate_type: Type,
        dpl: u2,
    ) GateDesc {
        return GateDesc{
            .offset_low = @truncate(offset),
            .seg_selector = @intFromEnum(index) << 3,
            .gate_type = gate_type,
            .dpl = dpl,
            .offset_middle = @truncate(offset >> 16),
            .offset_high = @truncate(offset >> 32),
        };
    }

    /// Get the offset.
    pub fn getOffset(self: GateDesc) u64 {
        return @as(u64, self.offset_high) << 32 | @as(u64, self.offset_middle) << 16 | @as(u64, self.offset_low);
    }
};

/// IDT Register.
const IdtRegister = packed struct {
    limit: u16,
    base: *[max_num_gates]GateDesc,
};

fn unhandledHandler(context: *Context) void {
    @branchHint(.cold);

    var writer = norn.UnsafeWriter.new();

    const exception: Exception = @enumFromInt(context.spec1.vector);
    writer.log("============ Oops! ===================", .{});
    const cpuid = norn.arch.getLocalApic().id();
    writer.log("Core#{d:0>2}: Unhandled interrupt: {s} ({})", .{
        cpuid,
        exception.name(),
        context.spec1.vector,
    });
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

    // Check if it's a kernel stack overflow.
    if (norn.pcpu.isThisCpuInitialized(cpuid) and norn.sched.isInitialized()) {
        const current = norn.sched.getCurrentTask();
        const kstack = current.kernel_stack;
        const kstack_guard_start = @intFromPtr(kstack.ptr);
        if (kstack_guard_start <= context.rsp and context.rsp < (kstack_guard_start + norn.mem.size_4kib)) {
            writer.log("", .{});
            writer.log("!!! This might be a kernel stack overflow !!!", .{});
        }
    }

    // Print the stack trace.
    writer.log("", .{});
    var it = std.debug.StackIterator.init(null, context.rbp);
    var ix: usize = 0;
    writer.log("=== Stack Trace =====================", .{});
    while (it.next()) |frame| : (ix += 1) {
        writer.log("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }

    writer.log("=====================================", .{});
    writer.log("Halting...", .{});
    norn.endlessHalt();
}

/// Protected-Mode Exceptions.
///
/// cf. SDM Vol.3A Table 6.1
const Exception = enum(usize) {
    pub const num_reserved_exceptions = 32;

    de = 0,
    db = 1,
    nmi = 2,
    bp = 3,
    of = 4,
    br = 5,
    ud = 6,
    nm = 7,
    df = 8,
    co = 9,
    ts = 10,
    np = 11,
    ss = 12,
    gp = 13,
    pf = 14,
    mf = 16,
    ac = 17,
    mc = 18,
    xm = 19,
    ve = 20,
    cp = 21,

    _,

    /// Get the name of an exception.
    pub fn name(self: Exception) []const u8 {
        return switch (self) {
            .de => "#DE: Divide by zero",
            .db => "#DB: Debug",
            .nmi => "NMI: Non-maskable interrupt",
            .bp => "#BP: Breakpoint",
            .of => "#OF: Overflow",
            .br => "#BR: Bound range exceeded",
            .ud => "#UD: Invalid opcode",
            .nm => "#NM: Device not available",
            .df => "#DF: Double fault",
            .co => "Coprocessor segment overrun",
            .ts => "#TS: Invalid TSS",
            .np => "#NP: Segment not present",
            .ss => "#SS: Stack-segment fault",
            .gp => "#GP: General protection fault",
            .pf => "#PF: Page fault",
            .mf => "#MF: Floating-point exception",
            .ac => "#AC: Alignment check",
            .mc => "#MC: Machine check",
            .xm => "#XM: SIMD exception",
            .ve => "#VE: Virtualization exception",
            .cp => "#CP: Control protection exception",
            _ => "Unknown exception",
        };
    }
};

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

test {
    testing.refAllDeclsRecursive(@This());
}

test "IDT size" {
    try testing.expectEqual(4096, @sizeOf(@TypeOf(idt)));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.intr);

const norn = @import("norn");
const mem = norn.mem;
const interrupt = norn.interrupt;
const rtt = norn.rtt;
const util = norn.util;

const am = @import("asm.zig");
const arch = @import("arch.zig");
const gdt = @import("gdt.zig");
const isr = @import("isr.zig");
const regs = @import("registers.zig");

const Context = regs.CpuContext;
const Handler = interrupt.Handler;
