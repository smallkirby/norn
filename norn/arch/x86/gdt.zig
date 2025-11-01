/// GDT is initialized and differentiated for this CPU.
var initialized: bool linksection(pcpu.section) = false;

/// Boot-time variables.
const early = struct {
    /// Boot-time GDT.
    var gdt: Gdt align(aligns.gdt) = undefined;

    /// Boot-time TSS.
    ///
    /// This provides only IST1.
    /// This does not provide RSPx.
    var tss: Tss align(aligns.tss) = undefined;

    /// Boot-time interrupt stack.
    var istack: Istack align(aligns.ist) = [_]u8{0} ** @sizeOf(Istack);
};

/// Alignments required.
const aligns = struct {
    const gdt = mem.size_4kib;
    const tss = mem.size_4kib;
    const ist = mem.size_4kib;
};

/// Size in bytes of interrupt stack.
const istack_size = 2 * mem.size_4kib;
/// Interrupt stack type.
const Istack = [istack_size]u8;

/// Segment descriptor index in GDT.
///
/// The ordering is enforced by hardware.
pub const SegIndex = enum(u13) {
    /// Null segment.
    null = 0,
    /// Kernel 32-bit code segment.
    ///
    /// Not used in Norn.
    kernel_cs32 = 0x01,
    /// Kernel code segment.
    kernel_cs = 0x02,
    /// Kernel data segment.
    kernel_ds = 0x03,
    /// User 32-bit code segment.
    user_cs32 = 0x04,
    /// User data segment.
    user_ds = 0x05,
    /// User code segment.
    user_cs = 0x06,
    /// Kernel TSS.
    ///
    /// TSS descriptor occupies two entries.
    kernel_tss = 0x08,
};

/// Segment selector.
pub const SegSel = packed struct(u16) {
    /// Requested Privilege Level.
    rpl: u2,
    /// Table Indicator.
    ti: TableIndicator = .gdt,
    /// Index.
    index: SegIndex,

    const TableIndicator = enum(u1) {
        gdt = 0,
        ldt = 1,
    };

    pub fn from(val: anytype) SegSel {
        return @bitCast(@as(u16, @truncate(val)));
    }
};

/// Initialize boot-time GDT and TSS.
pub fn globalInit() void {
    // Load GDTR.
    early.gdt.init();
    early.gdt.load();

    // Load TR.
    early.tss.init();
    early.tss.setIst(1, @intFromPtr(&early.istack) + @sizeOf(Istack));
    early.tss.load(&early.gdt);

    // Testing
    tests.gdtEntries();
    tests.earlyTssDesc(@intFromPtr(&early.tss));
    tests.earlyTss();
}

/// Differentiate a GDT for this CPU.
///
/// Copies the majority of the boot-time GDT,
/// Then, allocates and sets up a new TSS that has its own IST1-3 and RSP0.
pub fn localInit(allocator: PageAllocator) PageAllocator.Error!void {
    const ie = norn.arch.disableIrq();
    defer if (ie) norn.arch.enableIrq();

    if (pcpu.get(&initialized) and norn.is_runtime_test) {
        @panic("GDT is being initialized twice.");
    }

    // Allocate a page for GDT.
    const page = try allocator.allocPages(1, .normal);
    errdefer allocator.freePages(page);

    // Construct GDT entries.
    const gdt = Gdt.from(page.ptr);
    gdt.init();

    // Create TSS.
    const tss_page = try allocator.allocPages(1, .normal);
    errdefer allocator.freePages(tss_page);

    const tss = Tss.from(tss_page.ptr);
    tss.init();

    // Set RSP0
    const rps0_page_num = istack_size / mem.size_4kib;
    const rsp0 = try allocator.allocPages(rps0_page_num, .normal);
    errdefer allocator.freePages(rsp0);
    tss.setRsp(0, @intFromPtr(rsp0.ptr) + @sizeOf(Istack));

    // Set IST1 ~ IST3.
    for (0..3) |i| {
        const ist_page_num = istack_size / mem.size_4kib;
        const ist = try allocator.allocPages(ist_page_num, .normal);
        errdefer allocator.freePages(ist);
        @memset(ist[0..@sizeOf(Istack)], 0);

        tss.setIst(i + 1, @intFromPtr(ist.ptr) + @sizeOf(Istack));
    }

    // Load GDTR and segment selectors.
    gdt.load();
    tss.load(gdt);

    // Mark as initialized.
    pcpu.set(&initialized, true);
}

/// Load kernel segment selectors.
fn loadKernelGdt(gdtr: Gdtr) void {
    am.lgdt(@intFromPtr(&gdtr));

    // Changing the entries in the GDT, or setting GDTR
    // does not automatically update the hidden(shadow) part.
    // To flush the changes, we need to set segment registers.
    loadKernelDs();
    loadKernelCs();
}

/// Get GDTR of the current CPU.
fn getKernelGdt() Gdtr {
    return @bitCast(am.sgdt());
}

/// Load the kernel data segment selector.
///
/// This function flushes the changes of DS in the GDT.
fn loadKernelDs() void {
    asm volatile (
        \\mov %[kernel_ds], %di
        \\mov %%di, %%ds
        \\mov %%di, %%es
        \\mov %%di, %%ss
        :
        : [kernel_ds] "n" (@as(u16, @bitCast(SegSel{
            .rpl = 0,
            .index = .kernel_ds,
          }))),
        : .{ .di = true });
}

/// Load the kernel code segment selector.
///
/// This flushes the change of CS in the GDT.
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
        : [kernel_cs] "n" (@as(u16, @bitCast(SegSel{
            .rpl = 0,
            .index = .kernel_cs,
          }))),
        : .{ .rax = true });
}

/// Load the kernel TSS selector to TR.
fn loadKernelTss() void {
    asm volatile (
        \\mov %[kernel_tss], %%di
        \\ltr %%di
        :
        : [kernel_tss] "n" (@as(u16, @bitCast(SegSel{
            .rpl = 0,
            .index = .kernel_tss,
          }))),
        : .{ .di = true });
}

/// Segment Descriptor Entry.
///
/// ref: SDM Vol.3A 3.4.5
pub const SegDesc = packed struct(u64) {
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
    ///
    /// If set to true, the code segment contains native 64-bit code.
    /// If set to false, the code segment contains code executed in compatibility mode.
    /// For data segments, this bit must be cleared to 0.
    long: bool,
    /// Size flag.
    db: u1,
    /// Granularity.
    ///
    /// If set to .Byte, the segment limit is interpreted in byte units.
    /// Otherwise, the limit is interpreted in 4-KByte units.
    /// This field is ignored in 64-bit mode.
    granularity: Granularity,
    /// Upper 8 bits of the base address.
    base_high: u8,

    /// Empty segment descriptor.
    pub const empty: SegDesc = @bitCast(@as(u64, 0));

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
            /// A transfer into a nonconforming code segment at a different privilege level (including from higher level)
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
    pub fn newNull() SegDesc {
        return @bitCast(@as(u64, 0));
    }

    /// Create a new segment descriptor.
    pub fn new(
        base: u32,
        limit: u20,
        @"type": AccessType,
        desc_type: DescriptorType,
        dpl: u2,
        granularity: Granularity,
    ) SegDesc {
        return SegDesc{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .type = @"type",
            .desc_type = desc_type,
            .dpl = dpl,
            .present = true,
            .limit_high = @truncate(limit >> 16),
            .avl = 0,
            .long = if (@"type".app.code) true else false,
            .db = if (@"type".app.code) 0 else 1,
            .granularity = granularity,
            .base_high = @truncate(base >> 24),
        };
    }
};

/// TSS Descriptor in 64-bit mode.
///
/// Note that the descriptor is 16 bytes long and occupies two GDT entries.
///
/// cf. SDM Vol.3A Figure 8-4.
const TssDesc = packed struct(u128) {
    /// Lower 16 bits of the segment limit.
    limit_low: u16,
    /// Lower 24 bits of the base address.
    base_low: u24,

    /// Type: TSS.
    type: u4 = @intFromEnum(SegDesc.AccessType.System.tss_available),
    /// Descriptor type: System.
    desc_type: SegDesc.DescriptorType = .system,
    /// Descriptor Privilege Level.
    dpl: u2 = 0,
    /// Present.
    present: bool = true,

    /// Upper 4 bits of the segment limit.
    limit_high: u4,
    /// Available for use by system software.
    avl: u1 = 0,
    /// Reserved.
    long: bool = true,
    /// Size flag.
    db: u1 = 0,
    /// Granularity.
    granularity: SegDesc.Granularity = .kbyte,
    /// Upper 40 bits of the base address.
    base_high: u40,
    /// Reserved.
    _reserved: u32 = 0,

    /// Create a new 64-bit TSS descriptor.
    pub fn new(tss: Virt) TssDesc {
        return TssDesc{
            .limit_low = std.math.maxInt(u16),
            .base_low = @truncate(tss),
            .limit_high = std.math.maxInt(u4),
            .base_high = @truncate(tss >> 24),
        };
    }
};

/// Global descriptor table.
const Gdt = extern struct {
    const Self = @This();

    /// Descriptor table type.
    const DescriptorTable = [num_gdt]SegDesc;

    /// Maximum number of GDT entries.
    const num_gdt = 0x10;

    /// Segment descriptor table.
    _data: DescriptorTable,

    /// Cast a given pointer to a GDT.
    pub fn from(ptr: anytype) *Gdt {
        const self: *Self = @ptrCast(@alignCast(ptr));

        rtt.expect(util.isAligned(self, aligns.gdt));

        return self;
    }

    /// Initialize this GDT with default values.
    pub fn init(self: *Self) void {
        rtt.expect(util.isAligned(self, aligns.gdt));

        // Set empty descriptors.
        @memset(self._data[0..], .empty);

        // Set pre-defined descriptors.
        self.set(.null, null_descriptor);
        self.set(.kernel_ds, kernel_ds);
        self.set(.kernel_cs, kernel_cs);
        self.set(.user_ds, user_ds);
        self.set(.user_cs, user_cs);
    }

    /// Set a segment descriptor at the given index.
    pub fn set(self: *Self, index: SegIndex, desc: SegDesc) void {
        self._data[@intFromEnum(index)] = desc;
    }

    /// Get a copy of segment descriptor at the given index.
    pub fn get(self: *Self, index: SegIndex) SegDesc {
        return self._data[@intFromEnum(index)];
    }

    /// Get a copy of TSS descriptor at the given index.
    pub fn getTss(self: *Self, index: SegIndex) TssDesc {
        const desc: *TssDesc = @ptrCast(@alignCast(&self._data[@intFromEnum(index)]));
        return desc.*;
    }

    /// Set a TSS descriptor at the given index.
    pub fn setTss(self: *Self, index: SegIndex, tss: TssDesc) void {
        const to: *TssDesc = @ptrCast(@alignCast(&self._data[@intFromEnum(index)]));
        to.* = tss;
    }

    /// Load this GDT into GDTR.
    pub fn load(self: *Self) void {
        loadKernelGdt(.{
            .limit = @sizeOf(DescriptorTable) - 1,
            .base = &self._data,
        });
    }

    /// Null segment descriptor.
    const null_descriptor = SegDesc.newNull();

    /// Kernel data segment descriptor.
    const kernel_ds = SegDesc.new(
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

    /// Kernel code segment descriptor.
    const kernel_cs = SegDesc.new(
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

    /// User data segment descriptor.
    const user_ds = SegDesc.new(
        0,
        std.math.maxInt(u20),
        .{ .app = .{
            .wr = true,
            .dc = false,
            .code = false,
        } },
        .app,
        3,
        .kbyte,
    );

    /// User code segment descriptor.
    const user_cs = SegDesc.new(
        0,
        std.math.maxInt(u20),
        .{ .app = .{
            .wr = false,
            .dc = false,
            .code = true,
        } },
        .app,
        3,
        .kbyte,
    );

    comptime {
        norn.comptimeAssert(
            @sizeOf(DescriptorTable) <= mem.size_4kib,
            "GDT is too large: {d} bytes",
            .{@sizeOf(DescriptorTable)},
        );
        norn.comptimeAssert(
            @sizeOf(DescriptorTable) == @sizeOf(Gdt),
            "Invalid size of GDT: {d} bytes",
            .{@sizeOf(Gdt)},
        );
    }
};

/// GDTR.
const Gdtr = packed struct(u80) {
    limit: u16,
    base: *Gdt.DescriptorTable,
};

/// Task State Segment.
///
/// This structure should be exported (e.g. Used by syscall entry point).
///
/// cf. SDM Vol.3A Figure 8-11.
pub const Tss = extern struct {
    const Self = @This();

    /// Reserved.
    _reserved1: u32 align(1) = 0,
    /// RSP0.
    ///
    /// This field is used to store kernel stack pointer for privilege level change from ring-3 to ring-0.
    rsp0: u64 align(1) = 0,
    /// RSP1.
    ///
    /// This field is used to store user stack pointer.
    rsp1: u64 align(1) = 0,
    /// RSP2.
    ///
    /// This field is not used.
    rsp2: u64 align(1) = 0,
    /// Reserved.
    _reserved2: u64 align(1) = 0,
    /// IST1 (Interrupt Stack Table).
    ist1: u64 align(1) = 0,
    /// IST2.
    ist2: u64 align(1) = 0,
    /// IST3.
    ist3: u64 align(1) = 0,
    /// IST4.
    ist4: u64 align(1) = 0,
    /// IST5.
    ist5: u64 align(1) = 0,
    /// IST6.
    ist6: u64 align(1) = 0,
    /// IST7.
    ist7: u64 align(1) = 0,
    /// Reserved.
    _reserved3: u64 align(1) = 0,
    /// Reserved.
    _reserved4: u16 align(1) = 0,
    /// I/O Map Base Address: Offset to the I/O permission bitmap from the TSS base.
    iomap_base: u16 align(1) = 0,

    comptime {
        norn.comptimeAssert(
            @sizeOf(Tss) == 104,
            "Invalid size of TaskStateSegment: {d}",
            .{@sizeOf(Tss)},
        );
    }

    /// Cast a given pointer to a TSS.
    pub fn from(ptr: anytype) *Tss {
        const self: *Self = @ptrCast(@alignCast(ptr));

        rtt.expect(util.isAligned(self, aligns.tss));

        return self;
    }

    /// Initialize this TSS with default values.
    pub fn init(self: *Self) void {
        rtt.expect(util.isAligned(self, aligns.tss));

        self.* = .{};
    }

    /// Set IST<n> to the given address.
    pub fn setIst(self: *Self, index: usize, addr: Virt) void {
        rtt.expect(0 < index and index <= 7);
        rtt.expect(util.isAligned(addr, 0x10));

        switch (index) {
            1 => self.ist1 = addr,
            2 => self.ist2 = addr,
            3 => self.ist3 = addr,
            4 => self.ist4 = addr,
            5 => self.ist5 = addr,
            6 => self.ist6 = addr,
            7 => self.ist7 = addr,
            else => unreachable,
        }
    }

    /// Set RSP<n> to the given address.
    pub fn setRsp(self: *Self, index: usize, addr: Virt) void {
        rtt.expect(0 <= index and index <= 2);
        rtt.expect(util.isAligned(addr, 0x10));

        switch (index) {
            0 => self.rsp0 = addr,
            1 => self.rsp1 = addr,
            2 => self.rsp2 = addr,
            else => unreachable,
        }
    }

    /// Set this TSS into GDT and load TR.
    pub fn load(self: *const Self, gdt: *Gdt) void {
        const tss_desc = TssDesc.new(@intFromPtr(self));
        gdt.setTss(.kernel_tss, tss_desc);

        loadKernelTss();
    }
};

// =============================================================
// Tests
// =============================================================

const tests = struct {
    fn gdtEntries() void {
        if (norn.is_runtime_test) {
            const bits = norn.bits;
            const accessed_bit = 40;

            // GDT entries for kernel.
            const expected_kernel_ds = bits.unset(u64, 0x00_CF_93_000000_FFFF, accessed_bit);
            const expected_kernel_cs = bits.unset(u64, 0x00_AF_99_000000_FFFF, accessed_bit);
            rtt.expectEqual(
                expected_kernel_ds,
                bits.unset(u64, @bitCast(early.gdt.get(.kernel_ds)), accessed_bit),
            );
            rtt.expectEqual(
                expected_kernel_cs,
                bits.unset(u64, @bitCast(early.gdt.get(.kernel_cs)), accessed_bit),
            );

            // GDT entries for user.
            const expected_user_ds = bits.unset(u64, 0x00_CF_F3_000000_FFFF, accessed_bit);
            const expected_user_cs = bits.unset(u64, 0x00_AF_F9_000000_FFFF, accessed_bit);
            rtt.expectEqual(
                expected_user_ds,
                bits.unset(u64, @bitCast(early.gdt.get(.user_ds)), accessed_bit),
            );
            rtt.expectEqual(
                expected_user_cs,
                bits.unset(u64, @bitCast(early.gdt.get(.user_cs)), accessed_bit),
            );
        }
    }

    fn earlyTssDesc(base: Virt) void {
        if (norn.is_runtime_test) {
            const bits = norn.bits;

            const base_low: u24 = @truncate(base >> 0);
            const base_med: u8 = @truncate(base >> 24);
            const base_high: u32 = @truncate(base >> 32);

            const expected_tss_low = bits.concatMany(u64, .{
                base_med, // base med
                @as(u16, 0xAF_8B), // other fields
                base_low, // base low
                @as(u16, 0xFFFF), // limit
            });
            const expected_tss_high = bits.concatMany(u64, .{
                @as(u32, 0), // reserved
                base_high, // base high
            });

            const tss = early.gdt.getTss(.kernel_tss);
            const tss_low: u64 = @truncate(@as(u128, @bitCast(tss)));
            const tss_high: u64 = @truncate(@as(u128, @bitCast(tss)) >> 64);
            rtt.expectEqual(expected_tss_low, tss_low);
            rtt.expectEqual(expected_tss_high, tss_high);
        }
    }

    fn earlyTss() void {
        if (norn.is_runtime_test) {
            // Check if IST1 is set correctly.
            const tss_ptr: *u64 = @ptrCast(&early.tss);
            const tss_ist1_low_ptr: *u32 = @ptrFromInt(@intFromPtr(tss_ptr) + 0x24);
            const tss_ist1_high_ptr: *u32 = @ptrFromInt(@intFromPtr(tss_ptr) + 0x28);
            const tss_ist1 = norn.bits.concat(u64, tss_ist1_high_ptr.*, tss_ist1_low_ptr.*);
            rtt.expectEqual(@intFromPtr(&early.istack) + @sizeOf(Istack), tss_ist1);

            // Check if TR is set correctly.
            const tr: SegSel = @bitCast(asm volatile (
                \\str %[tr]
                : [tr] "={ax}" (-> u16),
                :
                : .{ .rax = true }));
            rtt.expectEqual(SegSel{
                .index = .kernel_tss,
                .ti = .gdt,
                .rpl = 0,
            }, tr);
        }
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const mem = norn.mem;
const pcpu = norn.pcpu;
const rtt = norn.rtt;
const util = norn.util;

const am = @import("asm.zig");

const PageAllocator = mem.PageAllocator;
const Phys = mem.Phys;
const Virt = mem.Virt;
