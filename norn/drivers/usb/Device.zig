const Self = @This();

/// State.
state: State,
/// Transfer Ring.
tr: ring.Ring,

/// Port index.
port_index: usb.PortIndex,
/// Slot ID.
slot_id: u8,
/// Port Register Set.
prs: PortRegisterSet.RegisterType,
/// Host Controller.
xhc: *Xhc,

/// Number of TRBs in a Transfer Ring.
const num_ents_in_tr = mem.size_4kib / @sizeOf(Trb);

/// Device state.
pub const State = enum {
    /// Port is connected.
    initialized,
    /// Waiting for the Slot ID to be assigned.
    waiting_slot,
    /// Waiting for the address to be assigned.
    waiting_address,
};

/// Create a new USB device.
pub fn new(
    xhc: *Xhc,
    port_index: usb.PortIndex,
    prs: PortRegisterSet.RegisterType,
) Self {
    return .{
        .state = .initialized,
        .tr = undefined,

        .port_index = port_index,
        .slot_id = undefined,
        .prs = prs,
        .xhc = xhc,
    };
}

/// Reset the port.
///
/// Blocks until the port reset is completed.
pub fn resetPort(self: *Self) UsbError!void {
    norn.rtt.expectEqual(.initialized, self.state);

    self.state = .waiting_slot;

    var portsc = self.prs.read(.portsc);
    portsc.pr = true;
    self.prs.write(.portsc, portsc);

    while (self.prs.read(.portsc).pr) {
        arch.relax();
    }
}

/// Request to assign the address to the device.
pub fn assignAddress(self: *Self, slot: u8) UsbError!void {
    norn.rtt.expectEqual(.waiting_slot, self.state);
    norn.rtt.expect(slot != 0);

    self.slot_id = slot;
    self.state = .waiting_address;

    // Allocate a Device Context region.
    const dc = try mem.page_allocator.allocPages(1, .normal);
    errdefer mem.page_allocator.freePages(dc);
    @memset(dc, 0);
    self.xhc.setDeviceContext(slot, dc.ptr);

    // Create Input Context.
    const ic_page = try mem.page_allocator.allocPages(1, .normal);
    const ic: *InputContext = @ptrCast(ic_page.ptr);
    errdefer mem.general_allocator.free(ic_page);
    @memset(ic_page, 0);

    // Configure Input Control Context (enable Slot Context and Endpoint 0).
    {
        const control = &ic.control;
        control.ac.a0 = true;
        control.ac.a1 = true;
    }
    // Configure Slot Context.
    {
        const slot_ctx = &ic.slot;
        slot_ctx.* = .{
            .root_hub_port = self.port_index + 1,
            .context_entries = 1, // Only the Default Control Endpoint is enabled for Slot Context initialization.
            .max_exit_latency = 0, // must be 0
            .addr = 0, // must be 0
            .intr_target = 0,
        };
    }
    // Configure EP0 (Default Control Pipe) Context.
    {
        const tr = try ring.Ring.new(num_ents_in_tr, mem.general_allocator);
        errdefer tr.deinit(mem.general_allocator);
        self.tr = tr;

        const ep0 = &ic.ep0;
        const speed = self.prs.read(.portsc).speed;
        ep0.* = .{
            .ep_type = .intr_out,
            .max_packet_size = speed.maxPacketSize(),
            .interval = 0,
            .cerr = 3,
            .trdp = undefined, // set later
            .dcs = 1,
        };
        ep0.setTrdp(&tr.trbs[0]);
    }

    // Request to assign the address.
    var cmd = trbs.AddressDeviceTrb.from(slot, ic_page.ptr);
    self.xhc.command_ring.push(Trb.from(&cmd));
    self.xhc.doorbells.notify(0);
}

// =============================================================
// Data structures
// =============================================================

/// Defines device configuration and state information that is passed to the xHC.
const InputContext = packed struct {
    control: InputControlContext,
    slot: SlotContext,
    ep0: EndpointContext,
    ep1out: EndpointContext,
    ep1in: EndpointContext,
    ep2out: EndpointContext,
    ep2in: EndpointContext,
    ep3out: EndpointContext,
    ep3in: EndpointContext,
    ep4out: EndpointContext,
    ep4in: EndpointContext,
    ep5out: EndpointContext,
    ep5in: EndpointContext,
    ep6out: EndpointContext,
    ep6in: EndpointContext,
    ep7out: EndpointContext,
    ep7in: EndpointContext,
    ep8out: EndpointContext,
    ep8in: EndpointContext,
    ep9out: EndpointContext,
    ep9in: EndpointContext,
    ep10out: EndpointContext,
    ep10in: EndpointContext,
    ep11out: EndpointContext,
    ep11in: EndpointContext,
    ep12out: EndpointContext,
    ep12in: EndpointContext,
    ep13out: EndpointContext,
    ep13in: EndpointContext,
    ep14out: EndpointContext,
    ep14in: EndpointContext,
    ep15out: EndpointContext,
    ep15in: EndpointContext,

    comptime {
        norn.comptimeAssert(
            @sizeOf(InputContext) == 0x420,
            "Invalid Input Context size: 0x{X}, expected 0x420",
            .{@sizeOf(InputContext)},
        );
    }
};

/// Defines information applied to a device as a whole.
const SlotContext = packed struct(u256) {
    /// Route String.
    ///
    /// Used by hubs to route packets to the correct downstream port.
    route: u20 = 0,
    /// Reserved.
    ///
    /// Previously used for Speed.
    _reserved1: u4 = 0,
    /// Reserved.
    _reserved2: u1 = 0,
    /// Multi-TT.
    ///
    /// Set to true if this is a High-speed hub that supports MTT and its interface has been enabled by the software.
    mtt: bool = false,
    /// Hub.
    ///
    /// Set to true if this is a USB hub.
    hub: bool = false,
    /// Context Entries.
    ///
    /// Identifies the index of the last valid Endpoint Context within this Slot Context.
    context_entries: u5,

    /// Max Exit Latency in microseconds.
    max_exit_latency: u16,
    /// Root Hub Port Number.
    ///
    /// Identifies the Root Hub Port Number used to access the device.
    root_hub_port: u8,
    /// Number of Ports.
    ///
    /// If `.hub` is true, indicates the number of downstream ports.
    num_ports: u8 = 0,

    /// Parent Hub Slot ID.
    ///
    /// Configured iff this device is Low-/Full-speed and connected through a High-speed hub.
    parent_slot: u8 = 0,
    /// Parent Port Number.
    ///
    /// Configured iff this device is Low-/Full-speed and connected through a High-speed hub.
    parent_port: u8 = 0,
    /// Configured iff this device is a High-speed hub.
    ttt: u2 = 0,
    /// Reserved.
    _reserved3: u4 = 0,
    /// Interrupt Target.
    ///
    /// Index of the interrupter that will receive Bandwidth Request Events and Device Notification Events generated by this slot.
    intr_target: u10 = 0,

    /// USB Device Address assigned by the xHC.
    addr: u8,
    /// Reserved.
    _reserved4: u19 = 0,
    /// Slot State. Updated by the xHC when a Device Slot transitions to a new state.
    slot_state: u5 = 0,

    /// Reserved.
    _reserved5: u32 = 0,
    /// Reserved.
    _reserved6: u32 = 0,
    /// Reserved.
    _reserved7: u32 = 0,
    /// Reserved.
    _reserved8: u32 = 0,
};

/// Defines information applied to a specific endpoint of a device.
const EndpointContext = packed struct(u256) {
    /// Endpoint State.
    ep_state: EndpointState = undefined,
    /// Reserved.
    _reserved1: u5 = 0,
    /// Mult.
    mult: u2 = 0,
    /// Max Primary Streams.
    max_pstream: u5 = 0,
    /// Linear Stream Array.
    lsa: u1 = 0,
    /// The period between consecutive requests to an endpoint in 125us increments.
    interval: u8 = 0,
    /// Max Endpoint Service Time Interval Payload High.
    max_esit_payload_hi: u8 = 0,

    /// Reserved.
    _reserved2: u1 = 0,
    /// Error Count.
    ///
    /// The number of consecutive USB Bus Errors allowed while executing a TD.
    cerr: u2 = 0,
    /// Endpoint Type.
    ep_type: EndpointType,
    /// Reserved.
    _reserved3: u1 = 0,
    /// Host Initiate Disable.
    hid: bool = false,
    /// Max Burst Size.
    max_burst_size: u8 = 0,
    /// Max Packet Size.
    ///
    /// Indicates the maximum packet size in bytes that this endpoint is capable of sending or receiving.
    max_packet_size: u16,

    /// Dequeue Cycle State.
    dcs: u1,
    /// Reserved.
    _reserved4: u3 = 0,
    /// High 60 bits of the Transfer Ring Dequeue Pointer.
    trdp: u60,

    /// Average TRB Length.
    ave_trb_len: u16 = 0,
    /// Max Endpoint Service Time Interval Payload Low.
    max_esit_payload_lo: u16 = 0,

    /// Reserved.
    _reserved5: u32 = 0,
    /// Reserved.
    _reserved6: u32 = 0,
    /// Reserved.
    _reserved7: u32 = 0,

    const EndpointState = enum(u3) {
        disabled = 0,
        running = 1,
        halted = 2,
        stopped = 3,
        err = 4,

        _,
    };

    const EndpointType = enum(u3) {
        invalid = 0,
        isoch_out = 1,
        isoch_in = 2,
        bulk_out = 3,
        intr_out = 4,
        control = 5,
        bulk_in = 6,
        intr_in = 7,
    };

    fn setTrdp(self: *EndpointContext, trdp: *const volatile Trb) void {
        self.trdp = @intCast(mem.virt2phys(trdp) >> 4);
    }
};

/// Consists of two groups of flags. Interpretation depends on the command.
const InputControlContext = packed struct(u256) {
    /// Reserved.
    _reserved1: u2 = 0,
    /// Drop Context Flags.
    ///
    /// Identifies which Device Context data should be disabled by the command.
    dc: DropContext,
    /// Add Context Flags.
    ///
    /// Identifies which Device Context data shall be evaluated and/or enabled by the command.
    ac: AddContext,
    /// Reserved.
    _reserved2: u32 = 0,
    /// Reserved.
    _reserved3: u32 = 0,
    /// Reserved.
    _reserved4: u32 = 0,
    /// Reserved.
    _reserved5: u32 = 0,
    /// Reserved.
    _reserved6: u32 = 0,
    /// Configuration Value.
    config: u8 = 0,
    /// Interface Number.
    interface: u8 = 0,
    /// Alternate Setting.
    alternate: u8 = 0,
    /// Reserved.
    _reserved7: u8 = 0,

    const DropContext = packed struct(u30) {
        d2: bool,
        d3: bool,
        d4: bool,
        d5: bool,
        d6: bool,
        d7: bool,
        d8: bool,
        d9: bool,
        d10: bool,
        d11: bool,
        d12: bool,
        d13: bool,
        d14: bool,
        d15: bool,
        d16: bool,
        d17: bool,
        d18: bool,
        d19: bool,
        d20: bool,
        d21: bool,
        d22: bool,
        d23: bool,
        d24: bool,
        d25: bool,
        d26: bool,
        d27: bool,
        d28: bool,
        d29: bool,
        d30: bool,
        d31: bool,
    };

    const AddContext = packed struct(u32) {
        a0: bool,
        a1: bool,
        a2: bool,
        a3: bool,
        a4: bool,
        a5: bool,
        a6: bool,
        a7: bool,
        a8: bool,
        a9: bool,
        a10: bool,
        a11: bool,
        a12: bool,
        a13: bool,
        a14: bool,
        a15: bool,
        a16: bool,
        a17: bool,
        a18: bool,
        a19: bool,
        a20: bool,
        a21: bool,
        a22: bool,
        a23: bool,
        a24: bool,
        a25: bool,
        a26: bool,
        a27: bool,
        a28: bool,
        a29: bool,
        a30: bool,
        a31: bool,
    };
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const usb = norn.drivers.usb;
const UsbError = usb.UsbError;

const regs = @import("regs.zig");
const ring = @import("ring.zig");
const trbs = @import("trbs.zig");
const PortRegisterSet = regs.PortRegisterSet;
const Trb = trbs.Trb;
const Xhc = @import("Xhc.zig");
