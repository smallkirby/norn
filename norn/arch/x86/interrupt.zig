//! Interrupt handling for x86_64 architecture.
//!
//! This module manages entries in IDT and interrupt handlers.

/// Interrupt Descriptor Table.
///
/// Shared among all CPUs.
var idt: Idt = undefined;

/// Maximum number of gates in the IDT.
pub const max_num_gates = 256;

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
    norn.interrupt.call(context.spec1.vector, context);
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

/// Protected-Mode Exceptions.
///
/// cf. SDM Vol.3A Table 6.1
pub const Exception = enum(usize) {
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
