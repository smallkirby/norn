/// Ring that can be used both for Command Ring and Transfer Ring.
///
/// Command Ring is used by software to pass device and HC related command to the xHC.
/// Transfer Ring is used by software to schedule work items for a single USB Endpoint.
pub const Ring = struct {
    /// Buffers for TRB.
    trbs: []volatile Trb,
    /// Producer Cycle State.
    pcs: u1 = 1,
    /// Next index to write to.
    index: usize = 0,

    /// Initialize a new Ring.
    pub fn new(comptime size: usize, allocator: Allocator) mem.MemError!Ring {
        const trbs_buffer = try allocator.alignedAlloc(
            Trb,
            mem.size_4kib,
            size,
        );

        return .{
            .trbs = trbs_buffer,
        };
    }

    /// Enqueue a TRB to the Ring.
    ///
    /// CRB of the TRB is properly set.
    /// TRB is copied, so the argument can be located in the stack.
    pub fn push(self: *Ring, trb: *Trb) void {
        // Copy the TRB to the tail of the Ring.
        self.copyToTail(trb);

        // Increment cursor.
        self.index += 1;
        if (self.index == self.trbs.len - 1) {
            self.rotate();
        }
    }

    /// Copy a TRB to the tail of the Ring pointed to by the index.
    fn copyToTail(self: *Ring, trb: *Trb) void {
        // Set the cycle bit.
        trb.cycle = self.pcs;

        // Copy the TRB.
        self.trbs[self.index] = trb.*;
    }

    /// Push a Link TRB and reset the cursor.
    fn rotate(self: *Ring) void {
        norn.rtt.expect(self.index == self.trbs.len - 1);
        var link = trbs.LinkTrb.new(self.trbs);
        self.copyToTail(@ptrCast(&link));
        self.pcs +%= 1;
        self.index = 0;
    }
};

/// Event Ring that is used by the xHC to pass command completion and async events to software.
pub const EventRing = struct {
    /// Number of Event Ring Segment.
    const num_ers = 1;
    /// Number of TRBs per Event Ring Segment.
    const num_trbs_per_segment = mem.size_4kib / @sizeOf(Trb);
    /// MMIO register type for Interrupter Register Set.
    const InterrupterRegister = Register(regs.InterrupterRegisterSet, .dword);

    comptime {
        norn.comptimeAssert(num_ers == 1, "Invalid number of Event Ring Segment", .{});
    }

    /// Buffers for TRB.
    trbs: []volatile Trb,
    /// Producer Cycle State.
    pcs: u1 = 1,
    /// Event Ring Segment Table.
    erst: []ErstEntry,
    /// MMIO address of the Interrupter Register Set this Event Ring is associated with.
    interrupter: InterrupterRegister,

    /// Initialize a new Event Ring.
    pub fn new(interrupter: IoAddr, allocator: Allocator) mem.MemError!EventRing {
        const trbs_buffer = try allocator.alignedAlloc(
            Trb,
            mem.size_4kib,
            num_trbs_per_segment,
        );
        const erst = try allocator.alignedAlloc(
            ErstEntry,
            16,
            num_ers,
        );

        return .{
            .trbs = trbs_buffer,
            .erst = erst,
            .interrupter = InterrupterRegister.new(interrupter),
        };
    }

    /// Check if more than one event is queued in the Event Ring.
    pub fn hasEvent(self: *EventRing) bool {
        return self.front().cycle == self.pcs;
    }

    /// Get the TRB pointed to by the Interrupter's dequeue pointer.
    pub fn front(self: *EventRing) *volatile Trb {
        const erdp = self.interrupter.read(.erdp);
        return @ptrFromInt(erdp & ~@as(u64, 0b1111));
    }

    /// Pop the front TRB.
    pub fn pop(self: *EventRing) void {
        // Intcement ERDP
        const erdp = self.interrupter.read(.erdp);
        var p: *volatile Trb = @ptrFromInt((erdp & ~@as(u64, 0b1111)) + @sizeOf(Trb));
        const begin: *volatile Trb = @ptrFromInt(self.erst[0].ring_segment_base_addr);
        const end: *volatile Trb = @ptrFromInt(self.erst[0].ring_segment_base_addr + self.erst[0].size * @sizeOf(Trb));
        if (p == end) {
            p = begin;
            self.pcs +%= 1;
        }

        // Set ERDP
        self.interrupter.erdp =
            (@intFromPtr(p) & ~@as(u64, 0b1111)) | (self.interrupter.erdp & @as(u64, 0b1111));
    }
};

/// Entry in ERST (Event Ring Segment Table).
///
/// ERST is used to define multi-segment Event Rings,
/// which enables runtime expansion and shrinking of the Event Ring.
pub const ErstEntry = packed struct(u128) {
    /// Base address of the Event Ring Segment.
    ring_segment_base_addr: u64,
    /// Number of TRBs in the Event Ring Segment.
    size: u16,
    /// Reserved.
    _reserved: u48,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.usb);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const mem = norn.mem;
const IoAddr = mem.IoAddr;
const Register = norn.mmio.Register;

const trbs = @import("trbs.zig");
const regs = @import("regs.zig");
const Trb = trbs.Trb;
