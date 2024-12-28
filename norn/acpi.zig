//! https://uefi.org/htmlspecs/ACPI_Spec_6_4_html/05_ACPI_Software_Programming_Model/ACPI_Software_Programming_Model.html

const std = @import("std");
const atomic = std.atomic;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const SpinLock = norn.SpinLock;

const Error = error{
    /// Failed to validate SDT.
    InvalidTable,
    /// Failed to allocate memory.
    OutOfMemory,
    /// Specified value exceeds the limit.
    ValueOutOfRange,
};

/// XSDT.
var xsdt: *Xsdt = undefined;
/// MADT.
var madt: *Madt = undefined;
/// FADT.
var fadt: *Fadt = undefined;
/// PM Timer.
var pm_timer: PmTimer = undefined;

/// Whether the ACPI is initialized.
var initialized = atomic.Value(bool).init(false);
/// Lock for the ACPI.
var lock = SpinLock{};

/// System information.
/// Once the ACPI is initialized, this must be immutable.
var system_info: SystemInfo = undefined;

/// Root System Description Pointer version 2.0.
/// This structure is used to locate the XSDT (RSDT).
const Rsdp = extern struct {
    /// Signature. Must be "RSD PTR ".
    signature: [8]u8,
    /// Checksum of the first 20 bytes.
    checksum: u8,
    /// OEM ID.
    oem_id: [6]u8,
    /// Revision.
    /// 0 for ACPI 1.0 and 2 for ACPI 2.0. Must be 2.
    revision: u8,
    /// Physical address of the RSDT.
    rsdt_address: u32,

    /// Length of the table in bytes.
    length: u32,
    /// Physical address of the XSDT.
    xsdt_address: u64,
    /// Checksum of the entire RSDP.
    extended_checksum: u8,
    /// Reserved.
    _reserved: [3]u8,

    __end_marker: void,

    const size_rsdp_v1 = @offsetOf(Rsdp, "length");
    const size_rsdp_v2 = @offsetOf(Rsdp, "__end_marker");
    comptime {
        if (size_rsdp_v1 != 20 or size_rsdp_v2 != 36) {
            @compileError("Invalid Rsdp size");
        }
    }

    /// Check if the RSDP is valid and has expected values..
    fn validate(self: *align(1) Rsdp) Error!void {
        if (!std.mem.eql(u8, &self.signature, "RSD PTR ")) {
            return Error.InvalidTable;
        }
        if (self.revision != 2) {
            return Error.InvalidTable;
        }
        if (checksum(std.mem.asBytes(self)[0..size_rsdp_v1]) != 0) {
            return Error.InvalidTable;
        }
        if (checksum(std.mem.asBytes(self)[0..size_rsdp_v2]) != 0) {
            return Error.InvalidTable;
        }
    }
};

/// 64-bit System Description Table.
/// This table contains pointers to all the other ACPI tables.
const Xsdt = extern struct {
    /// ACPI table header.
    /// The signature must be "XSDT".
    header: SdtHeader,
    /// Pointers to the other ACPI tables.
    sdts: void,

    /// Get the SDT with the specified signature.
    fn find(self: *Xsdt, signature: []const u8) ?*anyopaque {
        for (0..self.size()) |i| {
            const sdt = self.get(i);
            if (std.mem.eql(u8, &sdt.signature, signature)) {
                return sdt;
            }
        }
        return null;
    }

    /// Get the SDT at the specified index.
    fn get(self: *Xsdt, index: usize) *SdtHeader {
        // NOTE: The pointers can be aligned to 4 bytes, not 8 bytes.
        const ents_start: u64 = @intFromPtr(&self.sdts);
        const first: *u32 = @ptrFromInt(ents_start + index * @sizeOf(*u64));
        const second: *u32 = @ptrFromInt(ents_start + index * @sizeOf(*u64) + 4);
        const ptr = (@as(u64, second.*) << 32) + first.*;
        return @ptrFromInt(mem.phys2virt(ptr));
    }

    /// Number of SDTs.
    fn size(self: *Xsdt) usize {
        return (self.header.length - @sizeOf(SdtHeader)) / @sizeOf(*u64);
    }
};

/// Multiple APIC Description Table.
const Madt = extern struct {
    /// ACPI table header.
    /// The signature must be "APIC".
    header: SdtHeader,
    /// Physical address at which each processor can access its local APIC.
    local_apic_address: u32,
    /// Multiple APIC flags.
    flags: u32,
    /// List of variable length records that describe the interrupt devices.
    records: void,

    const EntryType = enum(u8) {
        /// Processor Local APIC.
        local_apic = 0,
        /// I/O APIC.
        io_apic = 1,
        /// I/O APIC Interrupt Source Override.
        io_apic_src_override = 2,
        /// I/O APIC NMI Source.
        io_apic_nmi_src = 3,
        /// Local APIC NMI Source.
        local_apic_nmi_src = 4,
        /// Local APIC Address Override.
        local_apic_address_override = 5,
        /// Processor Local x2APIC.
        local_x2apic = 9,
    };

    const Entry = union(EntryType) {
        const Header = packed struct {
            /// Entry type.
            entry_type: EntryType,
            /// Length of the entry.
            length: u8,
        };

        local_apic: *align(1) packed struct {
            /// Common header.
            header: Header,
            /// ACPI Processor ID.
            acpi_proc_id: u8,
            /// APIC ID.
            apic_id: u8,
            /// Flags.
            flags: u32,
        },
        io_apic: *align(1) packed struct {
            /// Common header.
            header: Header,
            /// I/O APIC ID.
            io_apic_id: u8,
            /// Reserved.
            _reserved: u8,
            /// I/O APIC address.
            io_apic_address: u32,
            /// Global system interrupt base.
            gsi_base: u32,
        },
        io_apic_src_override: *align(1) packed struct {
            /// Common header.
            header: Header,
            /// Bus source.
            bus: u8,
            /// IRQ source.
            irq: u8,
            /// Global system interrupt.
            gsi: u32,
            /// Flags.
            flags: u16,
        },
        io_apic_nmi_src: *align(1) packed struct {
            /// Common header.
            header: Header,
            /// Flags.
            flags: u16,
            /// Global system interrupt.
            gsi: u32,
        },
        local_apic_nmi_src: *align(1) packed struct {
            /// Common header.
            header: Header,
            /// ACPI Processor ID.
            acpi_proc_id: u8,
            /// Flags.
            flags: u16,
            /// Local APIC LINT number.
            lint: u8,
        },
        local_apic_address_override: *align(1) packed struct {
            /// Common header.
            header: Header,
            /// Reserved.
            _reserved: u16,
            /// Local APIC address.
            local_apic_address: u64,
        },
        local_x2apic: *align(1) packed struct {
            /// Common header.
            header: Header,
            /// Reserved.
            _reserved: u16,
            /// APIC ID.
            apic_id: u32,
            /// Flags.
            flags: u32,
            /// ACPI Processor UID.
            acpi_proc_uid: u32,
        },
    };

    /// Iterator for the MADT entries.
    const Iterator = struct {
        _madt: *Madt,
        _offset: usize = @offsetOf(Madt, "records"),

        /// Get the next entry if available.
        pub fn next(self: *Iterator) ?Entry {
            if (self._offset >= self._madt.header.length) {
                return null;
            }

            const header: *Entry.Header = @ptrFromInt(@intFromPtr(self._madt) + self._offset);
            self._offset += header.length;

            return switch (header.entry_type) {
                .local_apic => .{ .local_apic = @alignCast(@ptrCast(header)) },
                .io_apic => .{ .io_apic = @alignCast(@ptrCast(header)) },
                .io_apic_src_override => .{ .io_apic_src_override = @alignCast(@ptrCast(header)) },
                .io_apic_nmi_src => .{ .io_apic_nmi_src = @alignCast(@ptrCast(header)) },
                .local_apic_nmi_src => .{ .local_apic_nmi_src = @alignCast(@ptrCast(header)) },
                .local_apic_address_override => .{ .local_apic_address_override = @alignCast(@ptrCast(header)) },
                .local_x2apic => .{ .local_x2apic = @alignCast(@ptrCast(header)) },
            };
        }
    };

    /// Get an iterator for the MADT entries.
    pub fn iter(self: *Madt) Iterator {
        return Iterator{
            ._madt = self,
        };
    }
};

/// Fixed ACPI Description Table.
/// It defines various fixed hardware ACPI information vital.
pub const Fadt = extern struct {
    /// ACPI table header.
    /// The signature must be "FACP".
    header: SdtHeader,
    /// Physical address of the FACS.
    fw_ctrl: u32,
    /// Physical address of the DSDT.
    dsdt: u32,
    /// Reserved.
    _reserved1: u8,
    /// Preferred power management profile.
    pref_pm_profile: u8,
    /// System vector the SCI interrupt is wired to in 8259 mode.
    sci_int: u16,
    /// System port address of the SMI command port.
    smi_cmd: u32,
    /// Value to write to SMI_CMD to disable SMI ownership of the ACPI HW registers.
    acpi_enable: u8,
    /// Value to write to SMI_CMD to re-enable SMI ownership of the ACPI HW registers.
    acpi_disable: u8,
    /// Value to write to SMI_CMD to enter the S4BIOS state.
    s4bios_req: u8,
    /// If non-zero, value OSPM writes to SMI_CMD to assume processor performance state control responsibility.
    pstate_cnt: u8,
    /// System port address of the PM1a Event Register Block.
    pm1a_evt_blk: u32,
    /// System port address of the PM1b Event Register Block.
    pm1b_evt_blk: u32,
    /// System port address of the PM1a Control Register Block.
    pm1a_cnt_blk: u32,
    /// System port address of the PM1b Control Register Block.
    pm1b_cnt_blk: u32,
    /// System port address of the PM2 Control Register Block.
    pm2_cnt_blk: u32,
    /// System port address of the PM Timer Control Register Block.
    pm_tmr_blk: u32,
    /// System port address of the General-Purpose Event 0 Register Block.
    gpe0_blk: u32,
    /// System port address of the General-Purpose Event 1 Register Block.
    gpe1_blk: u32,
    /// Number of bytes decoded by PM1a Event Register Block.
    pm1_evt_len: u8,
    /// Number of bytes decoded by PM1b Event Register Block.
    pm1_cnt_len: u8,
    /// Number of bytes decoded by PM2 Control Register Block.
    pm2_cnt_len: u8,
    /// Number of bytes decoded by PM Timer Control Register Block.
    /// If the PM Timer is supported, the value must be 4.
    /// Otherwise, the value must be 0.
    pm_tmr_len: u8,
    /// Number of bytes decoded by General-Purpose Event 0 Register Block.
    gpe0_blk_len: u8,
    /// Number of bytes decoded by General-Purpose Event 1 Register Block.
    gpe1_blk_len: u8,
    /// Offset within the ACPI general-purpose event model.
    gpe1_base: u8,
    /// If non-zero, value OSPM writes to SMI_CMD to indicate OS support for the _CST object and C States Changed notification.
    cst_cnt: u8,
    /// Worst-case HW latency in microseconds to enter/exit C2 state.
    p_lvl2_lat: u16,
    /// Worst-case HW latency in microseconds to enter/exit C3 state.
    p_lvl3_lat: u16,
    /// (Maitained for ACPI 1.0 processor compatibility)
    flush_size: u16,
    /// (Maitained for ACPI 1.0 processor compatibility)
    flush_stride: u16,
    /// Zero-based index of where the processor's duty cycle setting is within the processor's P_CNT register.
    duty_offset: u8,
    /// Bit width of the processor's duty cycle setting value in the P_CNT register.
    duty_width: u8,
    /// RTC CMOS RAM index to the day-of-month alarm value.
    day_alarm: u8,
    /// RTC CMOS RAM index to the month of year alarm value.
    mon_alarm: u8,
    /// RTC CMOS RAM index to the century of data value.
    century: u8,
    /// IA-PC Boot Architecture Flags.
    iapc_boot_arch: u16 align(1),
    /// Reserved.
    _reserved2: u8,
    /// Fixed feature flags.
    flags: Flags,
    /// Address of the reset register represented in Generic Address Structure format.
    reset_reg: Gas,
    /// Value to write to the reset register to reset the system.
    reset_value: u8,
    /// ARM Boot Architecture Flags.
    arm_boot_arch: u16 align(1),
    /// Minor version of this FADT.
    fadt_minor_version: u8,
    /// Extended physical address of the FACS.
    x_fw_ctrl: u64 align(1),
    /// Extended physical address of the DSDT.
    x_dsdt: u64 align(1),
    /// Extended address of the PM1a Event Register Block.
    x_pm1a_evt_blk: Gas,
    /// Extended address of the PM1b Event Register Block.
    x_pm1b_evt_blk: Gas,
    /// Extended address of the PM1a Control Register Block.
    x_pm1a_cnt_blk: Gas,
    /// Extended address of the PM1b Control Register Block.
    x_pm1b_cnt_blk: Gas,
    /// Extended address of the PM2 Control Register Block.
    x_pm2_cnt_blk: Gas,
    /// Extended address of the PM Timer Control Register Block.
    x_pm_tmr_blk: Gas,
    /// Extended address of the General-Purpose Event 0 Register Block.
    x_gpe0_blk: Gas,
    /// Extended address of the General-Purpose Event 1 Register Block.
    x_gpe1_blk: Gas,
    /// Address of the Sleep register in Generic Address Structure format.
    sleep_control_reg: Gas,
    /// Address of the Sleep status register in Generic Address Structure format.
    sleep_status_reg: Gas,
    /// 64-bit identifier of hypervisor vendor.
    hv_id: u64 align(1),

    comptime {
        if (@bitOffsetOf(Fadt, "flags") != 112 * 8) {
            @compileLog(@bitOffsetOf(Fadt, "flags"));
            @compileError("Invalid FADT offset");
        }
        if (@bitSizeOf(Fadt) != 276 * 8) {
            @compileLog(@bitSizeOf(Fadt));
            @compileError("Invalid FADT size");
        }
    }

    const Flags = packed struct(u32) {
        /// Processor properly implements a functional equivalent to the WBINVD IA-32 instruction.
        wbinvd: bool,
        /// If set, indicates that HW flushes all caches on the WBINVD instruction and maintains memory coherency.
        wbinvd_flush: bool,
        /// C1 power state is supported on all processors.
        proc_c1: bool,
        /// If set, C2 power state is configured to work on UP and MP system.
        p_lvl2_up: bool,
        /// If unset, power button is handled as a fixed feature programming model.
        /// If set, power button is handled as a control method device.
        pwr_button: bool,
        /// If unset, sleep button is handled as a fixed feature programming model.
        /// If set, sleep button is handled as a control method device.
        slp_button: bool,
        /// If set, RTC wake status is not supported in fixed register space.
        fix_rtc: bool,
        /// RTC alarm function can wake the system from the S4 state.
        rtc_s4: bool,
        /// If unset, TMR_VAL is 24-bit, otherwise 32-bit.
        tmr_val_ext: bool,
        /// If unset, system cannot support docking.
        dck_cap: bool,
        /// If set, system supports system reset via the FADT RESET_REG.
        reset_reg_sup: bool,
        /// System Type Attribute.
        sealed_case: bool,
        /// System Type Attribute.
        headless: bool,
        /// If set, OSPM that a processor native instruction must be executed after writing the SLP_TYPx register.
        cpu_sw_slp: bool,
        /// If set, platform supports the PCIEXP_WAKE_STS bit in the PM1 Status register.0
        pci_exp_wake: bool,
        /// If set, OSPM should use a platform-provided timer to drive any monotonically non-decreasing counters.
        use_platform_clock: bool,
        /// If set, contents of RTC_STS flag is valid when waking the system from S4.
        s4_rtc_sts_valid: bool,
        /// If set, platform is compatible with remote power-on.
        remote_power_on_capable: bool,
        /// If set, all local APICs must be configured for the cluster destination model when delivering interrupts in logical mode.
        force_apic_cluster_model: bool,
        /// If set, all local xAPICs must be configured for physical destination mode.
        force_apic_phys_dest_mode: bool,
        /// If set, Hardware-Reduced ACPI is implemented.
        hw_reduced_acpi: bool,
        /// If set, platform is able to achieve power saving in S0.
        low_power_s0_idle_capable: bool,
        /// Reserved.
        _reserved: u10,
    };
};

/// Common header for all ACPI tables (except RSDP).
const SdtHeader = extern struct {
    /// Signature.
    signature: [4]u8,
    /// Length of the table in bytes.
    length: u32,
    /// Revision.
    revision: u8,
    /// Checksum of the entire table.
    checksum: u8,
    /// OEM ID.
    oem_id: [6]u8,
    /// OEM table ID.
    oem_table_id: [8]u8,
    /// OEM revision.
    oem_revision: u32,
    /// Creator ID.
    creator_id: u32,
    /// Creator revision.
    creator_revision: u32,

    /// Check if the SDT is valid.
    fn validate(self: *SdtHeader, signature: []const u8) Error!void {
        if (!std.mem.eql(u8, &self.signature, signature)) {
            return Error.InvalidTable;
        }
        const bytes: [*]u8 = @ptrCast(self);
        if (checksum(bytes[0..self.length]) != 0) {
            return Error.InvalidTable;
        }
    }
};

/// Generic Address Structure.
/// It provides the platform with a robust means to describe register locations.
const Gas = extern struct {
    /// The address space where the data structure/register exists.
    addr_space_id: SpaceId,
    /// Size in bits of the given register.
    bit_width: u8,
    /// Bit offset of the given register at the given address.
    bit_offset: u8,
    /// Access size unless otherwise defined by the Address Space ID.
    access_size: AccessSize align(1),
    /// 64bit address of the data structure or register in the given address space.
    address: u64 align(1),

    comptime {
        if (@bitSizeOf(Gas) != 96) {
            @compileError("Invalid Gas size");
        }
    }

    /// Address Space ID.
    const SpaceId = enum(u8) {
        /// System Memory space.
        system_memory = 0x00,
        /// System I/O space.
        system_io = 0x01,
        /// PCI Configuration space.
        pci_config = 0x02,
        /// Embedded Controller.
        embedded_controller = 0x03,
        /// SMBus.
        smbus = 0x04,
        /// SystemCMOS.
        system_cmos = 0x05,
        /// PciBarTarget.
        pci_bar_target = 0x06,
        /// IPMI.
        ipmi = 0x07,
        /// General PurposeIO.
        general_purpose_io = 0x08,
        /// GenericSerialBus.
        generic_serial_bus = 0x09,
        /// Platform Communications Channel.
        pcc = 0x0A,
        /// Functional Fixed Hardware.
        functional_fixed_hw = 0x7F,
        /// Reserved or OEM defined.
        _,
    };
    /// Access size.
    const AccessSize = enum(u8) {
        undefined = 0,
        byte = 1,
        word = 2,
        dword = 3,
        qword = 4,
    };
};

/// System information that can be obtained from ACPI.
const SystemInfo = struct {
    /// Number of CPUS in the system.
    num_cpus: usize,
    /// Physical address of the local APIC.
    local_apic_address: u32,
    /// List of local APIC IDs.
    local_apic_ids: ArrayList(u8),
};

/// ACPI Power Management Timer.
/// cf. ACPI spec v6.4. 4.8.3. Power Management Timer
const PmTimer = struct {
    const freq = 3_579_545; // 3.579545 MHz

    /// Maximum value of the PM Timer counter.
    mask: u64,
    /// I/O port of the PM Timer.
    port: u16,

    /// Instantiate a new PM Timer from the given FADT.
    fn new(arg_fadt: *Fadt) PmTimer {
        return .{
            .mask = if (arg_fadt.flags.tmr_val_ext) 0xFFFF_FFFF else 0x00FF_FFFF,
            .port = @intCast(arg_fadt.pm_tmr_blk),
        };
    }

    /// Busy-wait for the specified number of microseconds.
    fn spinForUsec(self: PmTimer, comptime usec: u64) Error!void {
        const num_required_ticks = usec * freq / 1_000_000;
        if (num_required_ticks >= self.mask) return Error.ValueOutOfRange;

        const start = self.readCounter();
        const end = (start + num_required_ticks) & self.mask;

        // Wait until the counter reaches 0.
        if (end < start) {
            while (self.readCounter() >= start) {
                atomic.spinLoopHint();
            }
        }
        // Wait until the counter reaches the specified value.
        while (self.readCounter() < end) {
            atomic.spinLoopHint();
        }
    }

    /// Read the PM Timer counter.
    inline fn readCounter(self: PmTimer) u32 {
        return arch.in(u32, self.port);
    }
};

/// Get the system information.
pub fn getSystemInfo() SystemInfo {
    norn.rtt.expectEqual(true, initialized.load(.acquire));
    return system_info;
}

/// Initialize the ACPI.
pub fn init(rsdp_phys: *anyopaque, allocator: Allocator) Error!void {
    norn.rtt.expect(norn.mem.isPgtblInitialized());

    const mask = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(mask);

    // Find XSDT structure.
    const rsdp: *align(1) Rsdp = @ptrFromInt(mem.phys2virt(rsdp_phys));
    try rsdp.validate();
    xsdt = @ptrFromInt(mem.phys2virt(rsdp.xsdt_address));
    try xsdt.header.validate("XSDT");

    // Find MADT structure.
    madt = @alignCast(@ptrCast(xsdt.find("APIC") orelse return Error.InvalidTable));
    try madt.header.validate("APIC");
    if (norn.is_runtime_test) {
        // Check the validity of sizes.
        var madt_iter = madt.iter();
        while (madt_iter.next() != null) {}
        norn.rtt.expectEqual(madt.header.length, madt_iter._offset);

        // Check if the local APIC address is same as one in MSR,
        // because the base address in the MADT can be overridden.
        norn.rtt.expectEqual(true, arch.isCurrentBsp());
        norn.rtt.expectEqual(arch.getLocalApicAddress(), madt.local_apic_address);
    }

    // Get system information.
    system_info = .{
        .num_cpus = 0,
        .local_apic_address = madt.local_apic_address,
        .local_apic_ids = ArrayList(u8).init(allocator),
    };

    var madt_iter = madt.iter();
    var madt_ent = madt_iter.next();
    while (madt_ent != null) : (madt_ent = madt_iter.next()) {
        switch (madt_ent.?) {
            .local_apic => |v| {
                system_info.num_cpus += 1;
                try system_info.local_apic_ids.append(v.apic_id);
            },
            else => {},
        }
    }

    // Find FADT structure.
    fadt = @alignCast(@ptrCast(xsdt.find("FACP") orelse return Error.InvalidTable));
    try fadt.header.validate("FACP");

    // Initialize PM Timer.
    pm_timer = PmTimer.new(fadt);

    // Mark as initialized.
    initialized.store(true, .release);
}

/// Busy-wait for the specified number of microseconds using ACPI PM Timer.
pub fn spinForUsec(comptime usec: u64) Error!void {
    norn.rtt.expectEqual(true, initialized.load(.acquire));
    return pm_timer.spinForUsec(usec);
}

/// Calculate the checksum of a SDP table.
fn checksum(data: []u8) u8 {
    var sum: u8 = 0;
    for (data) |byte| {
        sum +%= byte;
    }
    return sum;
}
