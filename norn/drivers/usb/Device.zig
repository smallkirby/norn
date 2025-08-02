const Self = @This();

/// Size in bytes of the work buffer used for transfers.
///
/// Data less than this size can be transferred without further allocations.
const work_buffer_size = mem.size_4kib;
/// Number of TRBs in a Transfer Ring.
const num_ents_in_tr = mem.size_4kib / @sizeOf(Trb);

/// List type of interfaces.
const InterfaceList = std.ArrayList(Interface);

/// State.
state: State,
/// Transfer Ring.
tr: ring.Ring,
/// Device descriptor.
device_desc: DeviceDescriptor = undefined,
/// Configuration descriptor.
config_desc: ConfigurationDescriptor = undefined,
/// List of interfaces belonging to the device.
interfaces: InterfaceList,

/// Port index.
port_index: usb.PortIndex,
/// Slot ID.
slot_id: u8,
/// Port Register Set.
prs: PortRegisterSet.RegisterType,
/// Host Controller.
xhc: *Xhc,

/// Work buffer that can be used for transfers.
buffer: []u8,

/// Device state.
pub const State = enum {
    /// Port is connected.
    initialized,
    /// Waiting for the Slot ID to be assigned.
    waiting_slot,
    /// Waiting for the address to be assigned.
    waiting_address,
    /// Address has been assigned and device is waiting for the device descriptor.
    waiting_device_desc,
    /// Waiting for the configuration descriptor.
    waiting_config_desc,
    /// Waiting for the configuration to be set.
    waiting_config_set,
    /// Initialization complete.
    complete,
};

/// Interface belonging to the device.
pub const Interface = struct {
    /// Interface descriptor.
    desc: InterfaceDescriptor,
    /// Type-erased class descriptor.
    class: *const DescriptorHeader,
    /// Endpoint descriptor.
    endpoint: EndpointDescriptor,
};

/// Create a new USB device.
pub fn new(
    xhc: *Xhc,
    port_index: usb.PortIndex,
    prs: PortRegisterSet.RegisterType,
) UsbError!Self {
    return .{
        .state = .initialized,
        .tr = undefined,
        .interfaces = InterfaceList.init(mem.general_allocator),

        .port_index = port_index,
        .slot_id = undefined,
        .prs = prs,
        .xhc = xhc,

        .buffer = try general_allocator.alloc(u8, work_buffer_size),
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
    // TODO: free somewhere
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
    _ = self.xhc.command_ring.push(Trb.from(&cmd));
    self.xhc.doorbells.notifyCommand();
}

/// Called when the address has been successfully assigned to the device.
pub fn onAddressAssigned(self: *Self) UsbError!void {
    norn.rtt.expectEqual(.waiting_address, self.state);

    self.state = .waiting_device_desc;

    log.info("Address assigned to slot#{d}.", .{self.slot_id});

    try self.getDeviceDescriptor();
}

/// Called when Configure Endpoint command has been completed.
pub fn onEndpointConfigured(self: *Self) UsbError!void {
    norn.rtt.expectEqual(.waiting_config_set, self.state);

    self.state = .complete;
}

/// Handles transfer events.
pub fn onTransferEvent(self: *Self, event: *const volatile trbs.TransferEventTrb) UsbError!void {
    const issuer: *const trbs.Trb = @ptrFromInt(mem.phys2virt(event.trb));
    switch (issuer.type) {
        .data => try self.onDataTransfer(event, @ptrCast(issuer)),
        .status => try self.onStatusTransfer(event, @ptrCast(issuer)),
        else => log.warn(
            "Unhandled TRB type that generated Transfer Event: {d}",
            .{@intFromEnum(issuer.type)},
        ),
    }
}

/// Request the device descriptor from the device.
fn getDeviceDescriptor(self: *Self) UsbError!void {
    norn.rtt.expectEqual(.waiting_device_desc, self.state);

    log.debug("Requesting device descriptor from slot#{d}.", .{self.slot_id});

    self.clearWorkBuffer();

    // Setup GET_DESCRIPTOR request for device descriptor
    const Value = packed struct(u16) {
        /// Descriptor number.
        desc_index: u8,
        /// Type of descriptor.
        desc_type: DescriptorType,
    };
    const request_type = SetupData.RequestType{
        .recipient = .device,
        .type = .standard,
        .direction = .in,
    };
    const setup_data = SetupData{
        .request_type = request_type,
        .request = .get_descriptor,
        .value = @bitCast(Value{
            .desc_index = 0,
            .desc_type = .device,
        }),
        .index = 0,
        .length = work_buffer_size,
    };
    try self.controlTransferIn(setup_data);
}

/// Request a configuration descriptor from the device.
fn getConfigurationDescriptor(self: *Self, config_index: u8) UsbError!void {
    norn.rtt.expectEqual(.waiting_config_desc, self.state);

    log.debug("Requesting configuration descriptor#{d} from slot#{d}.", .{ config_index, self.slot_id });

    self.clearWorkBuffer();

    // Setup GET_DESCRIPTOR request for configuration descriptor
    const Value = packed struct(u16) {
        /// Configuration index.
        desc_index: u8,
        /// Type of descriptor.
        desc_type: DescriptorType,
    };
    const request_type = SetupData.RequestType{
        .recipient = .device,
        .type = .standard,
        .direction = .in,
    };
    const setup_data = SetupData{
        .request_type = request_type,
        .request = .get_descriptor,
        .value = @bitCast(Value{
            .desc_index = config_index,
            .desc_type = .configuration,
        }),
        .index = 0,
        .length = work_buffer_size,
    };
    try self.controlTransferIn(setup_data);
}

/// Parse and record the configuration descriptor.
fn consumeConfigurationDescriptor(self: *Self, config_desc: *const ConfigurationDescriptor) UsbError!void {
    norn.rtt.expectEqual(.configuration, config_desc.type);
    norn.rtt.expectEqual(0, self.interfaces.items.len);
    self.config_desc = config_desc.*;

    const ParseState = enum {
        interface,
        class,
        endpoint,
    };

    // Iterate through all descriptors in the configuration descriptor.
    //
    // NOTE: interfaces that have multiple endpoints are not supported yet.
    var left = config_desc.total_length - config_desc.length;
    var cur: *align(1) const DescriptorHeader = @ptrFromInt(@intFromPtr(config_desc) + config_desc.length);
    var state: ParseState = .interface;
    var interface: Interface = undefined;
    while (left > 0) {
        norn.rtt.expect(cur.length != 0);

        switch (cur.type) {
            // Interface descriptor.
            .interface => {
                norn.rtt.expectEqual(.interface, state);
                const desc: *align(1) const InterfaceDescriptor = @alignCast(@ptrCast(cur));
                interface.desc = desc.*;
                state = .class;
            },
            // Class-specific descriptor.
            .hid => {
                norn.rtt.expectEqual(.class, state);
                const desc_buf = try general_allocator.alloc(u8, cur.length);
                errdefer general_allocator.free(desc_buf);
                @memcpy(desc_buf, @as([*]const u8, @ptrCast(cur))[0..cur.length]);
                interface.class = @alignCast(@ptrCast(desc_buf.ptr));
                state = .endpoint;
            },
            // Endpoint descriptor.
            .endpoint => {
                norn.rtt.expectEqual(.endpoint, state);
                const desc: *align(1) const EndpointDescriptor = @alignCast(@ptrCast(cur));
                interface.endpoint = desc.*;
                state = .interface;

                try self.interfaces.append(interface);
                interface = undefined;
            },
            // Unexpected descriptor.
            // This includes multiple endpoint descriptors for the same interface (not supported).
            else => log.warn(
                "Unexpected descriptor type {d} in configuration descriptor (length={d}).",
                .{ @intFromEnum(cur.type), cur.length },
            ),
        }

        left -= cur.length;
        cur = @ptrFromInt(@intFromPtr(cur) + cur.length);
    }

    log.debug("{d} interfaces found in configuration descriptor.", .{self.interfaces.items.len});
}

/// Issues Set Configuration device request to the device.
fn setConfiguration(self: *Self, config: u8) UsbError!void {
    norn.rtt.expectEqual(.waiting_config_set, self.state);

    log.debug("Setting configuration#{d} for slot#{d}.", .{ config, self.slot_id });

    // Setup SET_CONFIGURATION request
    const request_type = SetupData.RequestType{
        .recipient = .device,
        .type = .standard,
        .direction = .out,
    };
    const setup_data = SetupData{
        .request_type = request_type,
        .request = .set_configuration,
        .value = config,
        .index = 0,
        .length = 0,
    };
    try self.controlTransferOut(setup_data, 0);
}

/// Issues Configure Endpoint command to notify the xHC of the endpoint configuration.
///
/// xHC does not know which configuration has been selected for the device.
/// So we have to notify the selected setting to the xHC by this function.
fn configureEndpoint(self: *Self) UsbError!void {
    // Create and clear the Input Context.
    const ic_page = try mem.page_allocator.allocPages(1, .normal);
    const ic: *InputContext = @ptrCast(ic_page.ptr);
    errdefer mem.general_allocator.free(ic_page);
    @memset(ic_page, 0);
    ic.control.ac.a0 = true;

    // Copy slot context.
    const dc = self.getDeviceContext();
    ic.slot = dc.slot;

    // Set Add Context Flags and configure all endpoints.
    for (self.interfaces.items) |interface| {
        const dci = interface.endpoint.address.dci();
        const ep = interface.endpoint;
        ic.control.ac.set(dci);

        const epctx = ic.at(dci);
        epctx.max_packet_size = ep.max_packet_size;
        epctx.max_burst_size = 0;
        epctx.dcs = 1;
        epctx.interval = ep.interval;
        epctx.max_pstream = 0;
        epctx.mult = 0;
        epctx.cerr = 3;
        epctx.ep_type = switch (ep.address.direction) {
            .out => switch (ep.attributes.transfer_type) {
                .control => .control,
                .isochronous => .isoch_out,
                .bulk => .bulk_out,
                .interrupt => .intr_out,
            },
            .in => switch (ep.attributes.transfer_type) {
                .control => .control,
                .isochronous => .isoch_in,
                .bulk => .bulk_in,
                .interrupt => .intr_in,
            },
        };
    }

    // Issue Configure Endpoint command.
    var cmd = trbs.ConfigureEndpointTrb.from(self.slot_id, ic_page.ptr);
    _ = self.xhc.command_ring.push(Trb.from(&cmd));
    self.xhc.doorbells.notifyCommand();
}

// =============================================================
// Transfer event handlers
// =============================================================

/// Called when a Transfer Event TRB is received for Data TRB of control transfer.
fn onDataTransfer(self: *Self, event: *const volatile trbs.TransferEventTrb, issuer: *const trbs.DataTrb) UsbError!void {
    const code = event.code;

    switch (self.state) {
        // Device descriptor is provided.
        .waiting_device_desc => {
            if (code != .short_packet) {
                log.warn("GET_DESCRIPTOR control transfer failed: code={s}", .{@tagName(code)});
                return;
            }
            // Buffer size specified by SetupData and Data TRB is larger than the descriptor size.
            norn.rtt.expectEqual(self.bufferPhysAddr(), issuer.data_buffer);

            const device_desc: *const DeviceDescriptor = @alignCast(@ptrCast(self.buffer.ptr));
            self.device_desc = device_desc.*;

            // Transition to waiting for configuration descriptor
            self.state = .waiting_config_desc;
            try self.getConfigurationDescriptor(0);
        },
        // Configuration descriptor is provided.
        .waiting_config_desc => {
            if (code != .short_packet) {
                log.warn("GET_DESCRIPTOR (config) control transfer failed: code={s}", .{@tagName(code)});
                return;
            }
            // Buffer size specified by SetupData and Data TRB is larger than the descriptor size.
            norn.rtt.expectEqual(self.bufferPhysAddr(), issuer.data_buffer);

            // Parse descriptors.
            const config_desc: *const ConfigurationDescriptor = @alignCast(@ptrCast(self.buffer.ptr));
            try self.consumeConfigurationDescriptor(config_desc);

            // Select configuration.
            self.state = .waiting_config_set;
            try self.setConfiguration(config_desc.config_value);
        },
        // Unexpected state.
        else => {
            log.warn("Unexpected transfer event for control transfer while state is {s}", .{@tagName(self.state)});
        },
    }
}

/// Called when a Transfer Event TRB is received for Status TRB of control transfer.
fn onStatusTransfer(self: *Self, event: *const volatile trbs.TransferEventTrb, issuer: *const trbs.StatusTrb) UsbError!void {
    _ = issuer;
    const code = event.code;

    switch (self.state) {
        // Setting is selected.
        .waiting_config_set => {
            if (code != .success) {
                log.warn("SET_CONFIGURATION control transfer failed: code={s}", .{@tagName(code)});
                return;
            }

            // Notify the xHC of the selected configuration.
            try self.configureEndpoint();
        },
        // Unexpected state.
        else => {
            log.warn("Unexpected transfer event for control transfer while state is {s}", .{@tagName(self.state)});
        },
    }
}

// =============================================================
// Utilities
// =============================================================

/// Perform a control transfer in the device-to-host direction on endpoint 0 (Default Control Pipe).
///
/// If it requires data input, they're stored in the work buffer.
///
/// TODO: support transfer to other than control endpoint.
fn controlTransferIn(self: *Self, data: SetupData) UsbError!void {
    // Setup Stage
    var setup_trb = trbs.SetupTrb{
        .request_type = @bitCast(data.request_type),
        .request = @intFromEnum(data.request),
        .value = data.value,
        .index = data.index,
        .length = data.length,
        .cycle = undefined,
        .ioc = false,
        .trt = .in,
        .idt = true,
        .intr_target = 0, // TODO
    };
    _ = self.tr.push(Trb.from(&setup_trb));

    // Data Stage
    var data_trb = trbs.DataTrb{
        .data_buffer = self.bufferPhysAddr(),
        .transfer_length = work_buffer_size,
        .td_size = 0,
        .cycle = undefined,
        .ent = false,
        .isp = false,
        .ns = false,
        .chain = false,
        .ioc = true,
        .idt = false,
        .direction = .in,
        .intr_target = 0, // TODO
    };
    _ = self.tr.push(Trb.from(&data_trb));

    // Status Stage
    var status_trb = trbs.StatusTrb{
        .cycle = undefined,
        .ent = false,
        .chain = false,
        .ioc = false,
        .direction = .out,
        .intr_target = 0, // TODO
    };
    _ = self.tr.push(Trb.from(&status_trb));

    // Ring the doorbell for this slot
    const ep0_dci = calcDci(0, .in);
    self.xhc.doorbells.notifyEndpoint(self.slot_id, ep0_dci);
}

/// Perform a control transfer in the host-to-device direction on endpoint 0 (Default Control Pipe).
///
/// If it requires data output, the data is taken from the work buffer.
/// Caller must fulfill the work buffer with the data before calling this function.
///
/// TODO: support transfer to other than control endpoint.
fn controlTransferOut(self: *Self, data: SetupData, length: usize) UsbError!void {
    // Setup Stage
    var setup_trb = trbs.SetupTrb{
        .request_type = @bitCast(data.request_type),
        .request = @intFromEnum(data.request),
        .value = data.value,
        .index = data.index,
        .length = data.length,
        .cycle = undefined,
        .ioc = false,
        .trt = if (length == 0) .no_data else .out,
        .idt = true,
        .intr_target = 0, // TODO
    };
    _ = self.tr.push(Trb.from(&setup_trb));

    // Data Stage
    if (length != 0) {
        var data_trb = trbs.DataTrb{
            .data_buffer = self.bufferPhysAddr(),
            .transfer_length = data.length,
            .td_size = 0,
            .cycle = undefined,
            .ent = false,
            .isp = false,
            .ns = false,
            .chain = false,
            .ioc = true,
            .idt = false,
            .direction = .out,
            .intr_target = 0, // TODO
        };
        _ = self.tr.push(Trb.from(&data_trb));
    }

    // Status Stage
    var status_trb = trbs.StatusTrb{
        .cycle = undefined,
        .ent = false,
        .chain = false,
        .ioc = length == 0,
        .direction = .out,
        .intr_target = 0, // TODO
    };
    _ = self.tr.push(Trb.from(&status_trb));

    // Ring the doorbell for this slot
    const ep0_dci = calcDci(0, .in);
    self.xhc.doorbells.notifyEndpoint(self.slot_id, ep0_dci);
}

/// Get the device context for this device.
///
/// Note that the region is owned by the xHC and we should not modify it directly.
fn getDeviceContext(self: *const Self) *const DeviceContext {
    const virt = self.xhc.getDeviceContext(self.slot_id);
    return @ptrFromInt(virt);
}

/// Clear the work buffer.
inline fn clearWorkBuffer(self: *Self) void {
    @memset(self.buffer, 0);
}

/// Get the physical address of the work buffer.
inline fn bufferPhysAddr(self: *const Self) u64 {
    return mem.virt2phys(self.buffer.ptr);
}

/// Calculate the Device Context Index (DCI).
inline fn calcDci(ep: u4, direction: RequestDirection) u5 {
    return (@as(u5, ep) << 1) + @as(u5, @intFromEnum(direction));
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

    inline fn at(self: *InputContext, dci: u5) *EndpointContext {
        return switch (dci) {
            0 => unreachable,
            1 => &self.ep0,
            2 => &self.ep1out,
            3 => &self.ep1in,
            4 => &self.ep2out,
            5 => &self.ep2in,
            6 => &self.ep3out,
            7 => &self.ep3in,
            8 => &self.ep4out,
            9 => &self.ep4in,
            10 => &self.ep5out,
            11 => &self.ep5in,
            12 => &self.ep6out,
            13 => &self.ep6in,
            14 => &self.ep7out,
            15 => &self.ep7in,
            16 => &self.ep8out,
            17 => &self.ep8in,
            18 => &self.ep9out,
            19 => &self.ep9in,
            20 => &self.ep10out,
            21 => &self.ep10in,
            22 => &self.ep11out,
            23 => &self.ep11in,
            24 => &self.ep12out,
            25 => &self.ep12in,
            26 => &self.ep13out,
            27 => &self.ep13in,
            28 => &self.ep14out,
            29 => &self.ep14in,
            30 => &self.ep15out,
            31 => &self.ep15in,
        };
    }
};

/// Device context.
///
/// This region is set to DCBAA and owned by the xHC.
const DeviceContext = packed struct {
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

        inline fn set(self: *AddContext, n: u5) void {
            switch (n) {
                0 => self.a0 = true,
                1 => self.a1 = true,
                2 => self.a2 = true,
                3 => self.a3 = true,
                4 => self.a4 = true,
                5 => self.a5 = true,
                6 => self.a6 = true,
                7 => self.a7 = true,
                8 => self.a8 = true,
                9 => self.a9 = true,
                10 => self.a10 = true,
                11 => self.a11 = true,
                12 => self.a12 = true,
                13 => self.a13 = true,
                14 => self.a14 = true,
                15 => self.a15 = true,
                16 => self.a16 = true,
                17 => self.a17 = true,
                18 => self.a18 = true,
                19 => self.a19 = true,
                20 => self.a20 = true,
                21 => self.a21 = true,
                22 => self.a22 = true,
                23 => self.a23 = true,
                24 => self.a24 = true,
                25 => self.a25 = true,
                26 => self.a26 = true,
                27 => self.a27 = true,
                28 => self.a28 = true,
                29 => self.a29 = true,
                30 => self.a30 = true,
                31 => self.a31 = true,
            }
        }
    };
};

/// Contents of the Setup Stage TRB.
const SetupData = packed struct(u64) {
    /// bmRequestType.
    ///
    /// Identifies the characteristics of the request.
    request_type: RequestType,
    /// bRequest.
    ///
    /// Specifies the particular request.
    request: Request,
    /// wValue.
    ///
    /// Varying by request type.
    value: u16,
    /// wIndex.
    ///
    /// Varying by request type.
    index: u16,
    /// wLength.
    ///
    /// Specifies the length of the data transferred during the second stage of the control transfer.
    length: u16,

    const RequestType = packed struct(u8) {
        recipient: Recipient,
        type: Type,
        direction: RequestDirection,
    };

    const Type = enum(u2) {
        /// Standard
        standard = 0,
        /// Class
        class = 1,
        /// Vendor
        vendor = 2,
        /// Reserved
        reserved = 3,
    };

    const Recipient = enum(u5) {
        /// Device
        device = 0,
        /// Interface
        interface = 1,
        /// Endpoint
        endpoint = 2,
        /// Other
        other = 3,
        /// Vendor specific
        vendor = 31,
        /// Reserved.
        _,
    };

    const Request = enum(u8) {
        get_status = 0,
        clear_feature = 1,
        set_feature = 3,
        set_address = 5,
        get_descriptor = 6,
        set_descriptor = 7,
        get_configuration = 8,
        set_configuration = 9,
        get_interface = 10,
        set_interface = 11,
        synch_frame = 12,
        _,
    };
};

const RequestDirection = enum(u1) {
    /// Host-to-device.
    out = 0,
    /// Device-to-host.
    in = 1,
};

/// List of Descriptor Types.
const DescriptorType = enum(u8) {
    // Standard descriptor types.
    device = 1,
    configuration = 2,
    string = 3,
    interface = 4,
    endpoint = 5,
    interface_power = 8,
    otg = 9,
    debug = 10,
    interface_association = 11,
    bos = 15,
    device_cap = 16,

    // Class-specific descriptor types.
    hid = 33,
    hid_report = 34,

    _,
};

/// Common header for all USB descriptors.
const DescriptorHeader = packed struct(u16) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType,
};

/// General information about a device.
const DeviceDescriptor = packed struct(u144) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType = .device,
    /// USB Specification Release Number in Binary-Coded Decimal (BCD) format.
    usb_spec: u16,
    /// Class code.
    class: u8,
    /// Subclass code.
    subclass: u8,
    /// Protocol code.
    protocol: u8,
    /// Maximum packet size for endpoint 0 (default control pipe).
    max_packet_size: u8,
    /// Vendor ID.
    vendor: u16,
    /// Product ID.
    product: u16,
    /// Device release number in BCD format.
    device: u16,
    /// Index of string descriptor describing the manufacturer.
    manufacture_index: u8,
    /// Index of string descriptor describing the product.
    product_index: u8,
    /// Index of string descriptor describing the serial number.
    serial_index: u8,
    /// Number of possible configurations.
    num_configs: u8,
};

/// Describes a specific device configuration.
const ConfigurationDescriptor = packed struct(u72) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType = .configuration,
    /// Total length of this configuration including all interfaces, endpoints, and class descriptors.
    total_length: u16,
    /// Number of interfaces supported by this configuration.
    num_interfaces: u8,
    /// Value used by the Set Configuration request to select this configuration.
    config_value: u8,
    /// Index of string descriptor describing this configuration.
    config_index: u8,
    /// Configuration characteristics.
    attributes: u8,
    /// Maximum power consumption from the bus (in 2mA units).
    max_power: u8,
};

/// Describes a specific interface within a configuration.
///
/// Endpoint descriptors for this interface follow the interface descriptor.
/// Always part of a configuration descriptor.
const InterfaceDescriptor = packed struct(u72) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType = .interface,
    /// Interface number.
    interface_number: u8,
    /// Value used to select this alternate setting for this interface.
    alternate_setting: u8,
    /// Number of endpoints used by this interface (excluding endpoint 0).
    num_endpoints: u8,
    /// Class code.
    class: u8,
    /// Subclass code.
    subclass: u8,
    /// Protocol code.
    protocol: u8,
    /// Index of string descriptor describing this interface.
    interface_index: u8,
};

/// Information required by the host to determine the bandwidth requirements of an endpoint.
///
/// Always part of a configuration descriptor.
const EndpointDescriptor = packed struct(u56) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType = .endpoint,
    /// Endpoint address.
    address: Address,
    /// Attributes of the endpoint.
    attributes: Attribute,
    /// Maximum packet size for this endpoint.
    max_packet_size: u16,
    /// Interval for polling the endpoint (in milliseconds).
    interval: u8,

    const Attribute = packed struct(u8) {
        /// Transfer type.
        transfer_type: TransferType,
        /// Reserved.
        _reserved1: u2 = 0,
        /// Usage type.
        usage_type: UsageType,
        /// Reserved.
        _reserved2: u2 = 0,
    };

    const TransferType = enum(u2) {
        /// Control transfer.
        control = 0,
        /// Isochronous transfer.
        isochronous = 1,
        /// Bulk transfer.
        bulk = 2,
        /// Interrupt transfer.
        interrupt = 3,
    };

    const UsageType = enum(u2) {
        /// Periodic
        periodic = 0,
        /// Notification
        notification = 1,

        _,
    };

    const Address = packed struct(u8) {
        /// Endpoint number.
        ep: u4,
        /// Reserved.
        _reserved1: u3 = 0,
        /// Direction. Ignored for control endpoints.
        direction: RequestDirection,

        inline fn dci(self: Address) u5 {
            return (@as(u5, self.ep) << 1) + @as(u5, @intFromEnum(self.direction));
        }
    };
};

/// Descriptor specific to HID class devices.
const HidDescriptor = packed struct(u72) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType = .hid,
    /// HID Class Specification release number in BCD format.
    hid_spec: u16,
    /// Country code of the localized hardware.
    country_code: u8,
    /// The number of class descriptors.
    num_descriptors: u8,
    /// Type of class descriptor.
    class_descriptor_type: u8,
    /// Total size of the Report descriptor in bytes.
    report_length: u16,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.usb);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const general_allocator = norn.mem.general_allocator;
const usb = norn.drivers.usb;
const UsbError = usb.UsbError;

const regs = @import("regs.zig");
const ring = @import("ring.zig");
const trbs = @import("trbs.zig");
const PortRegisterSet = regs.PortRegisterSet;
const Trb = trbs.Trb;
const Xhc = @import("Xhc.zig");

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

test "DCI" {
    try testing.expectEqual(0, calcDci(0, .out));
    try testing.expectEqual(1, calcDci(0, .in));
    try testing.expectEqual(2, calcDci(1, .out));
    try testing.expectEqual(3, calcDci(1, .in));
    try testing.expectEqual(4, calcDci(2, .out));
}
