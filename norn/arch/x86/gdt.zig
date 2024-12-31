const std = @import("std");
const norn = @import("norn");

const am = @import("asm.zig");

const Phys = norn.mem.Phys;

/// Maximum number of GDT entries.
const max_num_gdt = 0x10;

/// Global Descriptor Table.
var gdt: [max_num_gdt]SegmentDescriptor align(16) = [_]SegmentDescriptor{
    SegmentDescriptor.newNull(),
} ** max_num_gdt;
/// GDT Register.
var gdtr = GdtRegister{
    .limit = @sizeOf(@TypeOf(gdt)) - 1,
    // TODO: BUG: Zig v0.13.0. https://github.com/ziglang/zig/issues/17856
    // .base = &gdt,
    // This initialization invokes LLVM error.
    // As a workaround, we make `gdtr` mutable and initialize it in `init()`.
    .base = undefined,
};

/// Index of the kernel data segment.
pub const kernel_ds_index: u16 = 0x01;
/// Index of the kernel code segment.
pub const kernel_cs_index: u16 = 0x02;
/// Index of the kernel TSS.
pub const kernel_tss_index: u16 = 0x03;

/// Initialize the GDT.
pub fn init() void {
    // Init GDT.
    gdtr.base = &gdt;

    gdt[kernel_cs_index] = SegmentDescriptor.new(
        0,
        std.math.maxInt(u20),
        .{ .app = .{
            .wr = false,
            .dc = false,
            .code = true,
        } },
        .app,
        0,
        .kbyte,
    );
    gdt[kernel_ds_index] = SegmentDescriptor.new(
        0,
        std.math.maxInt(u20),
        .{ .app = .{
            .wr = true,
            .dc = false,
            .code = false,
        } },
        .app,
        0,
        .kbyte,
    );

    am.lgdt(@intFromPtr(&gdtr));

    // Changing the entries in the GDT, or setting GDTR
    // does not automatically update the hidden(shadow) part.
    // To flush the changes, we need to set segment registers.
    loadKernelDs();
    loadKernelCs();

    testGdtEntries();
}

/// Set the TSS.
pub fn setTss(tss: Phys) void {
    norn.rtt.expectEqual(0, tss >> 32);

    gdt[kernel_tss_index] = SegmentDescriptor.new(
        @truncate(tss), // assuming physical address
        std.math.maxInt(u20),
        .{ .system = .tss_available },
        .system,
        0,
        .kbyte,
    );
    loadKernelTss();
}

/// Load the kernel data segment selector.
/// This function flushes the changes of DS in the GDT.
fn loadKernelDs() void {
    asm volatile (
        \\mov %[kernel_ds], %di
        \\mov %%di, %%ds
        \\mov %%di, %%es
        \\mov %%di, %%fs
        \\mov %%di, %%gs
        \\mov %%di, %%ss
        :
        : [kernel_ds] "n" (@as(u16, @bitCast(SegmentSelector{
            .rpl = 0,
            .index = kernel_ds_index,
          }))),
        : "di"
    );
}

/// Load the kernel code segment selector.
/// This function flushes the changes of CS in the GDT.
/// CS cannot be loaded directly by MOV, so we use far-return.
fn loadKernelCs() void {
    asm volatile (
        \\
        // Push CS
        \\mov %[kernel_cs], %%rax
        \\push %%rax
        // Push RIP
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\
        :
        : [kernel_cs] "n" (@as(u16, @bitCast(SegmentSelector{
            .rpl = 0,
            .index = kernel_cs_index,
          }))),
        : "rax"
    );
}

/// Load the kernel TSS selector to TR.
fn loadKernelTss() void {
    asm volatile (
        \\mov %[kernel_tss], %%di
        \\ltr %%di
        :
        : [kernel_tss] "n" (@as(u16, @bitCast(SegmentSelector{
            .rpl = 0,
            .index = kernel_tss_index,
          }))),
        : "di"
    );
}

/// Segment Descriptor Entry.
/// SDM Vol.3A 3.4.5
pub const SegmentDescriptor = packed struct(u64) {
    /// Lower 16 bits of the segment limit.
    limit_low: u16,
    /// Lower 24 bits of the base address.
    base_low: u24,

    /// Type.
    type: AccessType,
    /// Descriptor type.
    desc_type: DescriptorType,
    /// Descriptor Privilege Level.
    dpl: u2,
    /// Segment present.
    present: bool = true,

    /// Upper 4 bits of the segment limit.
    limit_high: u4,
    /// Available for use by system software.
    avl: u1 = 0,
    /// 64-bit code segment.
    /// If set to true, the code segment contains native 64-bit code.
    /// If set to false, the code segment contains code executed in compatibility mode.
    /// For data segments, this bit must be cleared to 0.
    long: bool,
    /// Size flag.
    db: u1,
    /// Granularity.
    /// If set to .Byte, the segment limit is interpreted in byte units.
    /// Otherwise, the limit is interpreted in 4-KByte units.
    /// This field is ignored in 64-bit mode.
    granularity: Granularity,
    /// Upper 8 bits of the base address.
    base_high: u8,

    /// Descriptor Type.
    pub const DescriptorType = enum(u1) {
        /// System Descriptor.
        /// It includes LDT, TSS, call-gate, interrupt-gate, trap-gate, and task-gate.
        system = 0,
        /// Application Descriptor (code or data segment).
        app = 1,
    };

    /// Access type.
    pub const AccessType = packed union {
        app: App,
        system: System,

        /// Access type for application descriptor.
        pub const App = packed struct(u4) {
            /// Segment is accessed since the last clear.
            accessed: bool = false,
            /// For data segment, writable.
            /// For code segment, readable.
            wr: bool,
            /// For data segment, expand-down when set, otherwise expand-up.
            /// For code segment, conforming when set, otherwise nonconforming.
            /// A transfer into a nonconforming code segment at a different privilege level (including from higer level)
            /// cause #GP unless gate or task gate is used.
            dc: bool,
            /// Code segment if set, otherwise data segment.
            code: bool,
        };

        /// Access type for system descriptor.
        pub const System = enum(u4) {
            ldt = 0b0011,
            tss_available = 0b1001,
            tss_busy = 0b1011,
            call_gate = 0b1100,
            interrupt_gate = 0b1110,
            trap_gate = 0b1111,
        };
    };

    /// Granularity of the descriptor.
    pub const Granularity = enum(u1) {
        byte = 0,
        kbyte = 1,
    };

    /// Create a null segment selector.
    pub fn newNull() SegmentDescriptor {
        return @bitCast(@as(u64, 0));
    }

    /// Create a new segment descriptor.
    pub fn new(
        base: u32,
        limit: u20,
        typ: AccessType,
        desc_type: DescriptorType,
        dpl: u2,
        granularity: Granularity,
    ) SegmentDescriptor {
        return SegmentDescriptor{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .type = typ,
            .desc_type = desc_type,
            .dpl = dpl,
            .present = true,
            .limit_high = @truncate(limit >> 16),
            .avl = 0,
            .long = if (typ.app.code) true else false,
            .db = if (typ.app.code) 0 else 1,
            .granularity = granularity,
            .base_high = @truncate(base >> 24),
        };
    }
};

/// Segment selector.
pub const SegmentSelector = packed struct(u16) {
    /// Requested Privilege Level.
    rpl: u2,
    /// Table Indicator.
    ti: TableIndicator = .gdt,
    /// Index.
    index: u13,

    const TableIndicator = enum(u1) {
        gdt = 0,
        ldt = 1,
    };

    pub fn from(val: anytype) SegmentSelector {
        return @bitCast(@as(u16, @truncate(val)));
    }
};

/// GDTR.
const GdtRegister = packed struct {
    limit: u16,
    base: *[max_num_gdt]SegmentDescriptor,
};

/// Task State Segment.
/// cf. SDM Vol.3A Figure 8-11.
pub const TaskStateSegment = packed struct {
    /// Reserved.
    _reserved1: u32 = 0,
    /// RSP0.
    rsp0: u64 = 0,
    /// RSP1.
    rsp1: u64 = 0,
    /// RSP2.
    rsp2: u64 = 0,
    /// Reserved.
    _reserved2: u64 = 0,
    /// IST1 (Interrupt Stack Table).
    ist1: u64 = 0,
    /// IST2.
    ist2: u64 = 0,
    /// IST3.
    ist3: u64 = 0,
    /// IST4.
    ist4: u64 = 0,
    /// IST5.
    ist5: u64 = 0,
    /// IST6.
    ist6: u64 = 0,
    /// IST7.
    ist7: u64 = 0,
    /// Reserved.
    _reserved3: u64 = 0,
    /// Reserved.
    _reserved4: u16 = 0,
    /// I/O Map Base Address: Offset to the I/O permission bitmap from the TSS base.
    iomap_base: u16 = 0,
};

// =======================================

const rtt = norn.rtt;

fn testGdtEntries() void {
    if (norn.is_runtime_test) {
        const bits = norn.bits;
        const accessed_bit = 40;

        const expected_ds = bits.unset(u64, 0x00CF93000000FFFF, accessed_bit);
        const expected_cs = bits.unset(u64, 0x00AF99000000FFFF, accessed_bit);
        rtt.expectEqual(
            expected_ds,
            bits.unset(u64, @bitCast(gdt[kernel_ds_index]), accessed_bit),
        );
        rtt.expectEqual(
            expected_cs,
            bits.unset(u64, @bitCast(gdt[kernel_cs_index]), accessed_bit),
        );
    }
}
