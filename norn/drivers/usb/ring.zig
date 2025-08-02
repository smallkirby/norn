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
        @memset(@as([*]u8, @ptrCast(trbs_buffer.ptr))[0..mem.size_4kib], 0);

        return .{
            .trbs = trbs_buffer,
        };
    }

    /// Enqueue a TRB to the Ring.
    ///
    /// CRB of the TRB is properly set.
    /// TRB is copied, so the argument can be located in the stack.
    pub fn push(self: *Ring, trb: *Trb) *const Trb {
        // Copy the TRB to the tail of the Ring.
        const ret = self.copyToTail(trb);

        // Increment cursor.
        self.index += 1;
        if (self.index == self.trbs.len - 1) {
            self.rotate();
        }

        return ret;
    }

    /// Copy a TRB to the tail of the Ring pointed to by the index.
    fn copyToTail(self: *Ring, trb: *Trb) *const Trb {
        // Set the cycle bit.
        trb.cycle = self.pcs;

        // Copy the TRB.
        self.trbs[self.index] = trb.*;

        return @volatileCast(@ptrCast(&self.trbs[self.index]));
    }

    /// Push a Link TRB and reset the cursor.
    fn rotate(self: *Ring) void {
        norn.rtt.expect(self.index == self.trbs.len - 1);
        var link = trbs.LinkTrb.new(self.trbs);
        _ = self.copyToTail(@ptrCast(&link));
        self.pcs +%= 1;
        self.index = 0;
    }

    /// Deinitialize the Ring and free the backing memory.
    pub fn deinit(self: *Ring, allocator: Allocator) void {
        allocator.free(self.trbs);
        self.trbs = undefined;
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

    /// Initialize and set the Event Ring to the primary interrupter.
    pub fn init(self: *EventRing) void {
        // Initialize ERST entries.
        norn.rtt.expectEqual(self.erst.len, self.trbs.len / num_trbs_per_segment);
        for (self.erst, 0..) |*erst_entry, i| {
            erst_entry.* = ErstEntry.from(self.trbs[i * num_trbs_per_segment .. (i + 1) * num_trbs_per_segment]);
        }

        // Set the Event Ring Segment Table.
        // ERSTBA must be set after ERSTSZ.
        self.interrupter.write(.erstsz, @as(u32, @intCast(self.erst.len)));
        self.interrupter.write(.erstba, mem.virt2phys(self.erst.ptr));
        var erdp = self.interrupter.read(.erdp);
        erdp.set(mem.virt2phys(self.trbs.ptr));
        self.interrupter.write(.erdp, erdp);

        // Set the PCS to 1.
        self.pcs = 1;
    }

    /// Check if more than one event is queued in the Event Ring.
    pub fn hasEvent(self: *const EventRing) bool {
        return self.poke().cycle == self.pcs;
    }

    /// Get the TRB pointed to by the Interrupter's dequeue pointer.
    pub fn poke(self: *const EventRing) *volatile Trb {
        const erdp = self.interrupter.read(.erdp);
        return @ptrFromInt(mem.phys2virt(erdp.addr()));
    }

    /// Get the event TRB if it exists and increment the dequeue pointer.
    pub fn next(self: *EventRing) ?*volatile Trb {
        var erdp = self.interrupter.read(.erdp);
        const trb: *volatile Trb = @ptrFromInt(mem.phys2virt(erdp.addr()));
        if (trb.cycle != self.pcs) {
            return null;
        }

        var next_trb: *volatile Trb = @ptrFromInt(@intFromPtr(trb) + @sizeOf(Trb));
        if (util.ptrGt(trb, &self.trbs[self.trbs.len - 1])) {
            next_trb = &self.trbs[0];
        }
        erdp.set(mem.virt2phys(next_trb));
        self.interrupter.write(.erdp, erdp);

        return trb;
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
    _reserved: u48 = 0,

    pub fn from(ring: []volatile Trb) ErstEntry {
        return .{
            .ring_segment_base_addr = mem.virt2phys(ring.ptr),
            .size = @intCast(ring.len),
        };
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.usb);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const mem = norn.mem;
const util = norn.util;
const IoAddr = mem.IoAddr;
const Register = norn.mmio.Register;

const trbs = @import("trbs.zig");
const regs = @import("regs.zig");
const Trb = trbs.Trb;
