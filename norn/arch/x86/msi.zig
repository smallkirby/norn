/// MSI Message Address Register.
///
/// The default setting delivers the interrupt to the processor specified by the Destination ID.
pub const Address = packed struct(u32) {
    const Self = @This();

    /// Don't care.
    _dontcare: u2 = 0,
    /// Destination mode.
    /// Ignored if RH is 0.
    dm: DestinationMode = .physical,
    /// Redirection hint indication.
    /// If set, the message is directed to the processor with the lowest interrupt priority.
    rh: bool = false,
    /// Reserved.
    _reserved: u8 = 0,
    /// Destination ID.
    dest: u8,
    /// Fixed value.
    _fixed: u12 = 0xFEE,

    /// Hints that the Destination ID should be interpreted as logical or physical APIC ID.
    const DestinationMode = enum((u1)) {
        physical = 0,
        logical = 1,
    };

    /// Get a integer value of the address.
    pub inline fn value(self: Self) u32 {
        return @bitCast(self);
    }

    /// Create a new Message Address that delivers the interrupt to the processor specified by `dest`.
    pub fn new(dest: u8) Self {
        return .{
            .dest = dest,
        };
    }
};

/// MSI Message Data Register.
pub const Data = packed struct(u16) {
    const Self = @This();

    /// Interrupt vector.
    vector: u8,
    /// How the interrupt receipt is handled.
    dm: DeliveryMode = .fixed,
    /// Reserved.
    _reserved1: u3 = 0,
    ///
    level: Level = .assert,
    /// Signal type.
    tm: TriggerMode = .level,

    const DeliveryMode = enum(u3) {
        /// Deliver the signal to all the agent listed in the destination.
        fixed = 0b000,
        /// Deliver the signal to the processor with the lowest interrupt priority.
        lowest = 0b001,
        ///
        smi = 0b010,
        /// Reserved.
        _reserved1 = 0b011,
        /// Deliver the signal to all the agents listed in the destination. Vector is ignored.
        nmi = 0b100,
        /// Deliver the signal to all the agents listed in the destination. Vector is ignored.
        init = 0b101,
        /// Reserved.
        _reserved2 = 0b110,
        /// Deliver the signal to the INTR signal of all agents in the destination (as if originated from old PIC).
        external = 0b111,
    };

    const Level = enum(u1) {
        deassert = 0,
        assert = 1,
    };

    const TriggerMode = enum(u1) {
        edge = 0,
        level = 1,
    };

    /// Create a new Data that delivers the specified interrupt vector.
    pub fn new(vector: u8) Self {
        return .{
            .vector = vector,
        };
    }
};
