const norn = @import("norn");
const acpi = norn.acpi;
const mem = norn.mem;
const Partialable = norn.Partialable;
const Phys = mem.Phys;
const VectorTable = norn.interrupt.VectorTable;

const am = @import("asm.zig");
const arch = @import("arch.zig");
const cpuid = @import("cpuid.zig");
const pic = @import("pic.zig");
const regs = @import("registers.zig");

pub const Error = error{
    /// APIC is not on the chip.
    ApicNotAvailable,
};

/// Local APIC interface.
pub const LocalApic = struct {
    const Self = LocalApic;

    /// Offset of local APIC registers
    /// cf. SDM Vol.3A  Table 11-1. Local APIC Register Address Map.
    const Register = enum(u32) {
        /// Local APIC ID
        id = 0x20,
        /// Local APIC version
        version = 0x30,
        /// Task Priority
        tpr = 0x80,
        /// Arbitration Priority
        apr = 0x90,
        /// Processor Priority
        ppr = 0xA0,
        /// EOI
        eoi = 0xB0,
        /// SVR
        svr = 0xF0,
        /// Interrupt Command, low 32 bits
        icr_low = 0x300,
        /// Interrupt Command, high 32 bits
        icr_high = 0x310,
        /// Error Status
        esr = 0x280,
        /// LVT Timer Register
        lvt_timer = 0x320,
        /// Initial Count Register
        initial_count = 0x380,
        /// Current Count Register
        current_count = 0x390,
        /// Divide Configuration Register
        dcr_timer = 0x3E0,
    };

    /// Virtual address of the local APIC base
    _base: *void,

    /// Spurious-Intrrupt Vector Register.
    pub const Svr = packed struct(u32) {
        /// Spurious Vector.
        /// Determines the vector number to be delivered when the local APIC generates a spurious vector.
        vector: u8,
        /// APIC Software Enable/Disable.
        /// If set, the local APIC is enabled.
        apic_enabled: bool,
        /// Focus Processor Checking.
        /// If set, focus processor checking is disabled when using the lowest-priority delivery mode.
        focus_checking: bool,
        /// Reserved.
        _reserved1: u2,
        /// EOI-Broadcast Suppression.
        /// If set, EOI messages are not broadcasted to the I/O APICs.
        eoi_no_broadcast: bool,
        /// Reserved.
        _reserved2: u19,
    };

    /// Instantiate an interface to access the local APIC.
    pub fn new(base: Phys) Self {
        return .{ ._base = @ptrFromInt(mem.phys2virt(base)) };
    }

    /// Read a value from the local APIC register.
    pub fn read(self: Self, T: type, reg: Register) T {
        const ptr: *volatile T = @ptrFromInt(@intFromPtr(self._base) + @intFromEnum(reg));
        return ptr.*;
    }

    /// Write a value to a register of the local APIC.
    pub fn write(self: Self, T: type, reg: Register, value: anytype) void {
        const ptr: *volatile T = @ptrFromInt(@intFromPtr(self._base) + @intFromEnum(reg));
        ptr.* = switch (@typeInfo(@TypeOf(value))) {
            .ComptimeInt => @as(T, value),
            .Int => value,
            .Struct => @as(T, @bitCast(value)),
            else => @compileError("Invalid type"),
        };
    }

    /// Get the local APIC ID.
    pub fn id(self: Self) u8 {
        const n: u32 = self.read(u32, .id);
        return @truncate(n >> 24);
    }
};

/// Low 32-bits of Interrupt Command Register of Local APIC.
pub const IcrLow = Partialable(packed struct(u32) {
    /// Vector number of the interrupt being sent.
    vector: u8,

    /// Delivery Mode. Type of IPI to be sent.
    delivery_mode: DeliveryMode,
    /// Destination Mode. Selects either physical or logical destination mode.
    dest_mode: DestinationMode,
    /// Delivery Status. Indicates the IPI delivery status.
    delivery_status: DeliveryStatus,
    /// Reserved.
    _reserved1: u1 = 0,
    /// Level.
    level: Level,
    /// Trigger Mode. Selects the trigger mode when using the INIT level de-assert delivery mode.
    /// Ignored for all other delivery modes.
    trigger_mode: TriggerMode,

    /// Reserved.
    _reserved2: u2 = 0,
    /// Destination Shorthand. Selects the destination of the IPI.
    dest_shorthand: DestinationShorthand,
    /// Reserved.
    _reserved3: u12 = 0,

    const DeliveryMode = enum(u3) {
        fixed = 0b000,
        lowest_priority = 0b001,
        smi = 0b010,
        nmi = 0b100,
        init = 0b101,
        startup = 0b110,
    };
    const DestinationMode = enum(u1) {
        physical = 0,
        logical = 1,
    };
    const Level = enum(u1) {
        deassert = 0,
        assert = 1,
    };
    const TriggerMode = enum(u1) {
        edge = 0,
        level = 1,
    };
    const DestinationShorthand = enum(u2) {
        //// Destination is specified by the dest field.
        no_shorthand = 0,
        /// The issuing APIC is the one and only destination.
        self = 1,
        /// The IPI is sent to all processors in the system.
        all_including_self = 2,
        /// The IPI is sent to all processors except the issuing processor.
        all_excluding_self = 3,
    };
});

/// High 32-bits of Interrupt Command Register.
pub const IcrHigh = Partialable(packed struct(u32) {
    /// Reserved.
    _reserved1: u24 = 0,
    /// Destination. Target processor(s).
    dest: u8,
});

/// Local APIC Timer.
pub const Timer = struct {
    /// Local Vector Table for Local APIC Timer.
    const Lvt = packed struct(u32) {
        /// Interrupt vector number.
        vector: u8,
        /// Reserved.
        _reserved1: u4 = 0,
        /// Delivery status.
        delivery_status: DeliveryStatus = .pending,
        /// Reserved.
        _reserved2: u3 = 0,
        /// Interrupt mask.
        mask: bool = false,
        /// Timer mode.
        mode: Mode,
        /// Reserved.
        _reserved3: u13 = 0,
    };

    /// Timer mode.
    const Mode = enum(u2) {
        /// One-shot mode using a count-down value.
        oneshot = 0b00,
        /// Periodic mode using a count-down value.
        periodic = 0b01,
        /// TSC-Deadline mode using absolute target value in IA32_TSC_DEADLINE MSR.
        tsc_deadline = 0b10,
        /// Reserved.
        _reserved = 0b11,
    };

    /// Divide Configuration Register.
    const Dcr = packed struct(u32) {
        /// Frequency of the timer is core crystal clock frequency divided by this value.
        divide: Divide,
        /// Reserved
        _reserved: u28 = 0,

        /// Divide configuration.
        const Divide = enum(u4) {
            by_2 = 0b0000,
            by_4 = 0b0001,
            by_8 = 0b0010,
            by_16 = 0b0011,
            by_32 = 0b1000,
            by_64 = 0b1001,
            by_128 = 0b1010,
            by_1 = 0b1011,
        };

        pub fn value(self: Dcr) u64 {
            return switch (self.divide) {
                .by_2 => 2,
                .by_4 => 4,
                .by_8 => 8,
                .by_16 => 16,
                .by_32 => 32,
                .by_64 => 64,
                .by_128 => 128,
                .by_1 => 1,
            };
        }
    };

    /// Measure the frequency of the local APIC timer using ACPI PM timer.
    /// The unit of the return value is Hz.
    pub fn measureFreq() u64 {
        const lapic = LocalApic.new(arch.getLocalApicAddress());

        // Set divider to 8 to reduce the frequency and avoid overflow.
        const divider = Dcr{ .divide = .by_8 };
        lapic.write(Dcr, .dcr_timer, divider);

        // Set initial count.
        const initial = 0xFFFF_FFFF;
        setInitialCount(lapic, initial);

        // Start timer
        const lvt = Lvt{
            .vector = @intFromEnum(VectorTable.spurious),
            .mask = false,
            .mode = .oneshot,
        };
        lapic.write(Lvt, .lvt_timer, lvt);

        // Sleep for 100ms.
        const acpi_us = 100 * 1000;
        acpi.spinForUsec(acpi_us) catch @panic("Unexpected failure in Timer.measureFreq()");

        // Get the current count.
        const current = getCurrentCount(lapic);

        return (@as(u64, initial - current) * divider.value()) * (1_000_000 / acpi_us);
    }

    /// Set the initial count of the timer.
    inline fn setInitialCount(lapic: LocalApic, count: u32) void {
        lapic.write(u32, .initial_count, count);
    }

    /// Get the current count of the timer.
    inline fn getCurrentCount(lapic: LocalApic) u32 {
        return lapic.read(u32, .current_count);
    }
};

/// Delivery status of the interrupt.
const DeliveryStatus = enum(u1) {
    /// Idle.
    /// Indicates that there're no activity for this source, or the previous interrupt was delivered and accepted.
    idle = 0,
    /// Send Pending.
    /// Indicates that the previous interrupt was delivered but not yet accepted.
    pending = 1,
};

/// Init the local APIC on this core.
/// This function disables the old PIC, then enables the local APIC.
pub fn init() Error!void {
    // Check if APIC is available.
    const is_available = cpuid.Leaf.from(1).query(null).edx & 0b0010_0000_0000 != 0;
    if (!is_available) return Error.ApicNotAvailable;

    // Disable old PIC.
    pic.initDisabled();

    // Set the APIC base again.
    var apic_addr = am.rdmsr(regs.MsrApicBase, .apic_base);
    apic_addr.enable = true;
    am.wrmsr(.apic_base, apic_addr);

    // Enable the local APIC.
    const lapic = LocalApic.new(apic_addr.getAddress());
    var svr = lapic.read(LocalApic.Svr, .svr);
    svr.vector = comptime @intFromEnum(VectorTable.spurious);
    svr.apic_enabled = true;
    lapic.write(LocalApic.Svr, .svr, svr);
}
