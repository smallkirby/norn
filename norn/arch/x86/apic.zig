const norn = @import("norn");
const mem = norn.mem;

const Partialable = norn.Partialable;

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
        /// Interrupt Command, low 32 bits
        icr_low = 0x300,
        /// Interrupt Command, high 32 bits
        icr_high = 0x310,
        /// Error Status
        esr = 0x280,
    };

    /// Virtual address of the local APIC base
    _base: *void,

    /// Instantiate an interface to access the local APIC.
    pub fn new(base: u32) Self {
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
};

/// Low 32-bits of Interrupt Command Register.
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
    const DeliveryStatus = enum(u1) {
        idle = 0,
        pending = 1,
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
