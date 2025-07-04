pub const IntrError = error{
    /// Handler is already registered for the vector.
    AlreadyRegistered,
};

/// Maximum number of gates in the IDT.
pub const max_num_gates = 256;
/// Interrupt Descriptor Table.
var idt: [max_num_gates]GateDescriptor align(mem.page_size) = [_]GateDescriptor{std.mem.zeroes(GateDescriptor)} ** max_num_gates;
/// IDT Register.
var idtr = IdtRegister{
    .limit = @sizeOf(@TypeOf(idt)) - 1,
    .base = &idt,
};

/// Norn provides 3 ISTs (IST1~3).
const num_ists = 3;

/// Index of IST for #DF.
const df_ist_index = 1;

/// Interrupt handlers.
var handlers: [max_num_gates]Handler = [_]Handler{unhandledHandler} ** max_num_gates;

/// Initialize the IDT.
pub fn init() void {
    // Set ISR stubs for all gates.
    inline for (0..max_num_gates) |i| {
        const gate = GateDescriptor.new(
            @intFromPtr(&isr.generateIsr(i)),
            gdt.kernel_cs_index << 3,
            .interrupt_gate,
            0,
        );
        setGate(i, gate);
    }

    // Set IST for #DF and #PF.
    idt[@intFromEnum(Exception.double_fault)].ist = df_ist_index;
    idt[@intFromEnum(Exception.page_fault)].ist = df_ist_index;

    // Load IDTR.
    idtr.base = &idt;
    loadKernelIdt();
}

/// Load the IDT.
///
/// Caller must ensure that the IDT is initialized.
pub fn loadKernelIdt() void {
    am.lidt(@intFromPtr(&idtr));
}

/// Set a gate descriptor in the IDT.
fn setGate(
    index: usize,
    gate: GateDescriptor,
) void {
    idt[index] = gate;
}

/// Dispatches the interrupt to the appropriate handler.
///
/// Called from the ISR stub.
pub fn dispatch(context: *Context) void {
    handlers[context.spec1.vector](context);
}

/// Set an interrupt handler for the given vector.
pub fn setHandler(vector: u8, handler: Handler) IntrError!void {
    if (handlers[vector] != unhandledHandler) {
        return IntrError.AlreadyRegistered;
    }
    handlers[vector] = handler;
}

fn unhandledHandler(context: *Context) void {
    @branchHint(.cold);

    const exception: Exception = @enumFromInt(context.spec1.vector);
    log.err("============ Oops! ===================", .{});
    const cpuid = norn.arch.getLocalApic().id();
    log.err("Core#{d:0>2}: Unhandled interrupt: {s} ({})", .{
        cpuid,
        exception.name(),
        context.spec1.vector,
    });
    log.err("Error Code: 0x{X}", .{context.spec2.error_code});
    log.err("RIP    : 0x{X:0>16}", .{context.rip});
    log.err("RFLAGS : 0x{X:0>16}", .{context.rflags});
    log.err("RAX    : 0x{X:0>16}", .{context.rax});
    log.err("RBX    : 0x{X:0>16}", .{context.rbx});
    log.err("RCX    : 0x{X:0>16}", .{context.rcx});
    log.err("RDX    : 0x{X:0>16}", .{context.rdx});
    log.err("RSI    : 0x{X:0>16}", .{context.rsi});
    log.err("RDI    : 0x{X:0>16}", .{context.rdi});
    log.err("RBP    : 0x{X:0>16}", .{context.rbp});
    log.err("R8     : 0x{X:0>16}", .{context.r8});
    log.err("R9     : 0x{X:0>16}", .{context.r9});
    log.err("R10    : 0x{X:0>16}", .{context.r10});
    log.err("R11    : 0x{X:0>16}", .{context.r11});
    log.err("R12    : 0x{X:0>16}", .{context.r12});
    log.err("R13    : 0x{X:0>16}", .{context.r13});
    log.err("R14    : 0x{X:0>16}", .{context.r14});
    log.err("R15    : 0x{X:0>16}", .{context.r15});
    log.err("CS     : 0x{X:0>4}", .{context.cs});
    if (context.isFromUserMode()) {
        log.err("SS     : 0x{X:0>4}", .{context.ss});
        log.err("RSP    : 0x{X:0>16}", .{context.rsp});
    }

    const cr0: u64 = @bitCast(am.readCr0());
    const cr2: u64 = @bitCast(am.readCr2());
    const cr3: u64 = @bitCast(am.readCr3());
    const cr4: u64 = @bitCast(am.readCr4());
    log.err("CR0    : 0x{X:0>16}", .{cr0});
    log.err("CR2    : 0x{X:0>16}", .{cr2});
    log.err("CR3    : 0x{X:0>16}", .{cr3});
    log.err("CR4    : 0x{X:0>16}", .{cr4});

    if (norn.pcpu.isThisCpuInitialized(cpuid) and context.isFromUserMode()) {
        log.err("Memory map of the current task:", .{});
        const task = norn.sched.getCurrentTask();
        var node: ?*norn.mm.VmArea = task.mm.vm_areas.first;
        while (node) |area| : (node = area.list_head.next) {
            log.err(
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
            log.err("", .{});
            log.err("!!! This might be a kernel stack overflow !!!", .{});
        }
    }

    // Print the stack trace.
    log.err("", .{});
    var it = std.debug.StackIterator.init(null, context.rbp);
    var ix: usize = 0;
    log.err("=== Stack Trace =====================", .{});
    while (it.next()) |frame| : (ix += 1) {
        log.err("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }

    log.err("=====================================", .{});
    log.err("Halting...", .{});
    norn.endlessHalt();
}

/// Protected-Mode Exceptions.
/// cf. SDM Vol.3A Table 6.1
const Exception = enum(usize) {
    pub const num_reserved_exceptions = 32;

    divide_by_zero = 0,
    debug = 1,
    nmi = 2,
    breakpoint = 3,
    overflow = 4,
    bound_range_exceeded = 5,
    invalid_opcode = 6,
    device_not_available = 7,
    double_fault = 8,
    coprocessor_segment_overrun = 9,
    invalid_tss = 10,
    segment_not_present = 11,
    stack_segment_fault = 12,
    general_protection_fault = 13,
    page_fault = 14,
    floating_point_exception = 16,
    alignment_check = 17,
    machine_check = 18,
    simd_exception = 19,
    virtualization_exception = 20,
    control_protection_exception = 21,

    _,

    /// Get the name of an exception.
    pub inline fn name(self: Exception) []const u8 {
        return switch (self) {
            .divide_by_zero => "#DE: Divide by zero",
            .debug => "#DB: Debug",
            .nmi => "NMI: Non-maskable interrupt",
            .breakpoint => "#BP: Breakpoint",
            .overflow => "#OF: Overflow",
            .bound_range_exceeded => "#BR: Bound range exceeded",
            .invalid_opcode => "#UD: Invalid opcode",
            .device_not_available => "#NM: Device not available",
            .double_fault => "#DF: Double fault",
            .coprocessor_segment_overrun => "Coprocessor segment overrun",
            .invalid_tss => "#TS: Invalid TSS",
            .segment_not_present => "#NP: Segment not present",
            .stack_segment_fault => "#SS: Stack-segment fault",
            .general_protection_fault => "#GP: General protection fault",
            .page_fault => "#PF: Page fault",
            .floating_point_exception => "#MF: Floating-point exception",
            .alignment_check => "#AC: Alignment check",
            .machine_check => "#MC: Machine check",
            .simd_exception => "#XM: SIMD exception",
            .virtualization_exception => "#VE: Virtualization exception",
            .control_protection_exception => "#CP: Control protection exception",
            _ => "Unknown exception",
        };
    }
};

/// 64bit-Mode Gate descriptor.
pub const GateDescriptor = packed struct(u128) {
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
        seg_selector: u16,
        gate_type: Type,
        dpl: u2,
    ) GateDescriptor {
        return GateDescriptor{
            .offset_low = @truncate(offset),
            .seg_selector = seg_selector,
            .gate_type = gate_type,
            .dpl = dpl,
            .offset_middle = @truncate(offset >> 16),
            .offset_high = @truncate(offset >> 32),
        };
    }

    /// Get the offset.
    pub fn getOffset(self: GateDescriptor) u64 {
        return @as(u64, self.offset_high) << 32 | @as(u64, self.offset_middle) << 16 | @as(u64, self.offset_low);
    }
};

/// IDT Register.
const IdtRegister = packed struct {
    limit: u16,
    base: *[max_num_gates]GateDescriptor,
};

// ====================================================

const testing = std.testing;

test {
    testing.refAllDeclsRecursive(@This());
}

test "IDT size" {
    try testing.expectEqual(4096, @sizeOf(@TypeOf(idt)));
}

// ====================================================

const std = @import("std");
const log = std.log.scoped(.intr);

const norn = @import("norn");
const mem = norn.mem;
const interrupt = norn.interrupt;

const am = @import("asm.zig");
const arch = @import("arch.zig");
const gdt = @import("gdt.zig");
const isr = @import("isr.zig");
const regs = @import("registers.zig");

const Context = regs.CpuContext;
const Handler = interrupt.Handler;
