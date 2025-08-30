pub const PciError = error{
    /// Data is corrupted or invalid.
    InvalidData,
    /// Device not found.
    NotFound,
    /// Operation not supported.
    NotSupported,
    /// Memory allocation failed.
    OutOfMemory,
};

/// Type for a list of PCI devices.
const DeviceList = std.array_list.Managed(*Device); // TODO: make it unmanaged
/// List of devices.
var devices: DeviceList = undefined;

/// Data type for function number.
const FunctionNumber = u3;
/// Data type for device number.
const DeviceNumber = u5;
/// Data type for bus number.
const BusNumber = u8;
/// Data type for register offset.
const RegisterOffset = u8;

/// Data type for vendor ID.
const VendorId = u16;

/// Address of PCI configuration space for a specific function.
const ConfigAddress = packed struct(u32) {
    /// Register offset.
    register: RegisterOffset,
    /// Function number.
    function: FunctionNumber,
    /// Device number.
    device: DeviceNumber,
    /// Bus number.
    bus: BusNumber,
    /// Reserved.
    _reserved: u7 = 0,
    /// Enable bit.
    enable: bool = true,
};

/// Reader and writer for PCI configuration space.
///
/// This struct does not hold any data.
fn ConfigurationSpaceGenerator(layout: ?Header.Layout) type {
    return struct {
        const Self = @This();
        const HeaderType = HeaderGenerator(layout);

        _bus: BusNumber,
        _device: DeviceNumber,
        _function: FunctionNumber,

        /// I/O address of CONFIG_ADDRESS.
        const config_address = 0xCF8;
        /// I/O address of CONFIG_DATA.
        const config_data = 0xCFC;
        /// Alignment for register offsets to ensure 32-bit access.
        const register_align = @as(RegisterOffset, 0b11);
        /// Access width in bytes.
        const access_width = @sizeOf(u32);

        /// Invalid Vendor ID.
        const invalid_vendor_id: VendorId = 0xFFFF;

        /// Create a reader and writer for the PCI configuration space.
        pub fn new(bus: BusNumber, device: DeviceNumber, function: FunctionNumber) Self {
            return Self{
                ._bus = bus,
                ._device = device,
                ._function = function,
            };
        }

        /// Read a value from the PCI configuration space at the given offset.
        pub fn readAt(self: Self, T: type, offset: RegisterOffset) T {
            const access_offset = util.rounddown(offset, access_width);
            const offset_diff = offset - access_offset;

            var raw_data: [util.roundup(@sizeOf(T), access_width) + access_width]u8 = undefined;
            comptime var i: RegisterOffset = 0;
            inline while (i < raw_data.len / access_width) : (i += 1) {
                const current_offset = access_offset + i * access_width;
                setConfigAddress(.{
                    .register = current_offset,
                    .function = self._function,
                    .device = self._device,
                    .bus = self._bus,
                });

                const value = arch.in(u32, config_data);
                const raw_data_offset = i * access_width;
                @memcpy(
                    raw_data[raw_data_offset .. raw_data_offset + access_width],
                    std.mem.asBytes(&value)[0..],
                );
            }

            return std.mem.bytesToValue(
                T,
                raw_data[offset_diff .. offset_diff + @sizeOf(T)],
            );
        }

        /// Read a value of the given field from the PCI configuration space.
        ///
        /// This function uses a configuration space access mechanism #1 (PIO access).
        /// This function is responsible for correctly aligning an access offset and a size.
        pub fn read(self: Self, comptime field: HeaderType.FieldEnum) HeaderType.typeOf(field) {
            return self.readAt(HeaderType.typeOf(field), HeaderType.offsetOf(field));
        }

        /// Write a value to the PCI configuration space at the given offset.
        pub fn writeAt(self: Self, value: anytype, offset: RegisterOffset) void {
            const T = @TypeOf(value);

            const data = std.mem.asBytes(&value);
            var data_offset: RegisterOffset = 0;
            var remain: usize = @sizeOf(T);
            while (remain > 0) {
                const current_offset = offset + data_offset;
                const access_offset = util.rounddown(current_offset, access_width);
                const offset_diff = current_offset - access_offset;
                const data_size = @min(remain, access_width - offset_diff);
                var current_data: [4]u8 = undefined;

                setConfigAddress(.{
                    .register = access_offset,
                    .function = self._function,
                    .device = self._device,
                    .bus = self._bus,
                });

                if (offset_diff != 0 or remain < access_width) {
                    const data_read = arch.in(u32, config_data);
                    @memcpy(
                        current_data[0..access_width],
                        std.mem.asBytes(&data_read)[0..access_width],
                    );
                }
                @memcpy(
                    current_data[offset_diff .. offset_diff + data_size],
                    data[data_offset .. data_offset + data_size],
                );
                arch.out(
                    u32,
                    @as(u32, @bitCast(current_data)),
                    config_data,
                );

                data_offset += data_size;
                remain -= data_size;
            }
        }

        /// Write a value to the given field of the PCI configuration space.
        ///
        /// This function uses a configuration space access mechanism #1 (PIO access).
        /// This function is responsible for correctly aligning an access offset and a size.
        ///
        /// TODO: Use writeAt().
        pub fn write(self: Self, comptime field: HeaderType.FieldEnum, value: HeaderType.typeOf(field)) void {
            // Since all writes must be 32-bit aligned, we need to write the whole DWORD.
            const exact_offset = HeaderType.offsetOf(field);
            const aligned_offset = exact_offset & ~register_align;
            const diff_bitoffset = (exact_offset - aligned_offset) * 8;
            const T = HeaderType.typeOf(field);
            const mask: u32 = switch (@bitSizeOf(T)) {
                8 => 0xFF,
                16 => 0xFFFF,
                32 => 0xFFFFFFFF,
                else => @compileError("Unsupported type size for PCI configuration space write"),
            };
            const value_int: u32 = switch (@bitSizeOf(T)) {
                8 => @as(u8, @bitCast(value)),
                16 => @as(u16, @bitCast(value)),
                32 => @as(u32, @bitCast(value)),
                else => @compileError("Unsupported type size for PCI configuration space write"),
            };

            // Configure CONFIG_ADDRESS register.
            setConfigAddress(.{
                .register = aligned_offset,
                .function = self._function,
                .device = self._device,
                .bus = self._bus,
            });

            // Write the value.
            const original = arch.in(u32, config_data);
            arch.out(
                u32,
                (original & ~(mask << diff_bitoffset)) | (value_int << diff_bitoffset),
                config_data,
            );
        }

        /// Check if the device is a single-function device.
        pub fn isSingleFunction(self: Self) bool {
            const header_type = self.read(.header_type);
            return header_type.is_multi_function == false;
        }

        /// Check if the device exists.
        pub fn isValid(self: Self) bool {
            return self.read(.vendor_id) != invalid_vendor_id;
        }

        /// Set the CONFIG_ADDRESS register.
        fn setConfigAddress(addr: ConfigAddress) void {
            rtt.expectEqual(0, addr.register & register_align);
            arch.out(u32, addr, config_address);
        }
    };
}

/// Specialized PCI configuration space reader and writer for any layout.
const ConfigurationSpaceAny = ConfigurationSpaceGenerator(null);
/// Specialized PCI configuration space reader and writer for the layout type 0x0.
const ConfigurationSpace0 = ConfigurationSpaceGenerator(.standard);
/// Specialized PCI configuration space reader and writer for the layout type 0x1.
const ConfigurationSpace1 = ConfigurationSpaceGenerator(.bridge);

/// Union of configuration spaces.
const ConfigurationSpace = union(Header.Layout) {
    standard: ConfigurationSpace0,
    bridge: ConfigurationSpace1,
    cardbus_bridge: ConfigurationSpaceAny,

    pub fn readAt(self: ConfigurationSpace, T: type, offset: RegisterOffset) T {
        return switch (self) {
            inline else => |c| c.readAt(T, offset),
        };
    }

    pub fn writeAt(self: ConfigurationSpace, value: anytype, offset: RegisterOffset) void {
        switch (self) {
            inline else => |c| c.writeAt(value, offset),
        }
    }

    /// Read the configuration space to instantiate the appropriate configuration space reader/writer.
    fn specialize(bus: BusNumber, device: DeviceNumber, function: FunctionNumber) PciError!ConfigurationSpace {
        const config = ConfigurationSpaceAny.new(bus, device, function);
        if (!config.isValid()) {
            return error.NotFound;
        }

        return switch (config.read(.header_type).layout) {
            .standard => .{ .standard = ConfigurationSpace0.new(bus, device, function) },
            .bridge => .{ .bridge = ConfigurationSpace1.new(bus, device, function) },
            else => @panic("Unsupported PCI configuration space layout"),
        };
    }
};

/// Utility to generate a PCI configuration space header data type,
/// that can handle both predefined and type-specific headers.
fn HeaderGenerator(layout: ?Header.Layout) type {
    return struct {
        /// Type of the predefined header.
        const P = Header.Predefined;
        /// Type of the type-specific header.
        const C = if (layout) |l| switch (l) {
            .standard => Header.TypeSpecific0,
            .bridge => Header.TypeSpecific1,
            else => @compileError("Unsupported header layout"),
        } else struct {};

        const p_fields = std.meta.fields(P);
        const c_fields = std.meta.fields(C);
        const c_start_idx = p_fields.len;

        /// Merged FieldEnum for the predefined and type-specific headers.
        const FieldEnum = blk: {
            const field_len = p_fields.len + c_fields.len;
            var enumFields: [field_len]std.builtin.Type.EnumField = undefined;

            for (p_fields, 0..) |f, i| {
                enumFields[i] = .{
                    .name = f.name ++ "",
                    .value = i,
                };
            }
            for (c_fields, p_fields.len..) |f, i| {
                enumFields[i] = .{
                    .name = f.name ++ "",
                    .value = i,
                };
            }

            break :blk @Type(.{
                .@"enum" = .{
                    .tag_type = std.math.IntFittingRange(0, field_len - 1),
                    .fields = &enumFields,
                    .decls = &.{},
                    .is_exhaustive = true,
                },
            });
        };

        /// Check if the field is in the predefined header.
        inline fn isInPredefinedHeader(comptime field: FieldEnum) bool {
            return @intFromEnum(field) < c_start_idx;
        }

        /// Get a register offset for a field in the header.
        inline fn offsetOf(comptime field: FieldEnum) RegisterOffset {
            if (isInPredefinedHeader(field)) {
                return @offsetOf(P, @tagName(field));
            } else {
                return @offsetOf(C, @tagName(field)) + @sizeOf(P);
            }
        }

        /// Get a type of a field in the header.
        inline fn typeOf(comptime field: FieldEnum) type {
            if (isInPredefinedHeader(field)) {
                return @FieldType(P, @tagName(field));
            } else {
                return @FieldType(C, @tagName(field));
            }
        }
    };
}

/// Namespace for PCI configuration space header types.
const Header = struct {
    /// PCI configuration space header type.
    const Layout = enum(u7) {
        /// Standard header.
        standard = 0x00,
        /// PCI-to-PCI bridge.
        bridge = 0x01,
        /// CardBus bridge.
        cardbus_bridge = 0x02,

        _,
    };

    /// Pre-defined header in the PCI configuration space.
    ///
    /// The first 16 bytes of the PCI configuration space.
    /// The layout of this header is same for all types of PCI devices.
    ///
    /// This struct is not intended to be instantiated.
    const Predefined = packed struct {
        const Self = @This();

        comptime {
            norn.comptimeAssert(@sizeOf(Self) == 0x10, "Invalid size of PredefinedHeader: 0x{X}", .{@sizeOf(Self)});
        }

        /// Manufacturer of the device.
        vendor_id: VendorId,
        /// Particular device ID.
        device_id: u16,
        /// Command register.
        command: Command,
        /// Status register.
        status: Status,
        /// Device specific revision ID.
        revision_id: u8,
        /// Read-only register that identifies the device class.
        class_code: ClassCode,
        /// System cacheline size in units of DWORDs.
        cacheline_size: u8,
        /// The value of Latency Timer for this PCI bus master in units of PCI bus clocks.
        latency_timer: u8,
        /// Layout identifier for the second part of the predefined header (starting at 0x10).
        header_type: HeaderTypeField,
        /// Built-in self test.
        bist: u8,

        const HeaderTypeField = packed struct(u8) {
            /// Header layout.
            layout: Header.Layout,
            /// If true, the device is a multi-function device.
            is_multi_function: bool,
        };
    };

    /// PCI configuration space header type 0x0 (standard).
    const TypeSpecific0 = packed struct {
        /// Base address register #0
        bar0: Bar,
        /// Base address register #1
        bar1: Bar,
        /// Base address register #2
        bar2: Bar,
        /// Base address register #3
        bar3: Bar,
        /// Base address register #4
        bar4: Bar,
        /// Base address register #5
        bar5: Bar,
        /// Cardbus CIS pointer.
        cardbus_cis: u32,
        /// Subsystem vendor ID.
        subsystem_vendor_id: VendorId,
        /// Subsystem ID.
        subsystem_id: u16,
        /// Expansion ROM base address.
        exrom_base_address: u32,
        /// Capabilities pointer.
        cap_pointer: u8,
        /// Reserved.
        _reserved1: u24 = 0,
        /// Reserved.
        _reserved2: u32 = 0,
        /// Interrupt line.
        interrupt_line: u8,
        /// Interrupt PIN.
        interrupt_pin: u8,
        /// Min grant.
        min_grant: u8,
        /// Max latency.
        max_latency: u8,
    };

    /// PCI configuration space header type 0x1 (PCI-to-PCI bridge).
    const TypeSpecific1 = packed struct {
        /// Base address register #0
        bar0: Bar,
        /// Base address register #1
        bar1: Bar,
        /// Primary bus number.
        primary_bus_number: BusNumber,
        /// Secondary bus number.
        secondary_bus_number: BusNumber,
        /// Subordinate bus number.
        subordinate_bus_number: BusNumber,
        /// Secondary latency timer.
        secondary_latency_timer: u8,
        /// I/O base.
        io_base: u8,
        /// I/O limit.
        io_limit: u8,
        /// secondary status.
        secondary_status: Status,
        /// Memory base.
        memory_base: u16,
        /// Memory limit.
        memory_limit: u16,
        /// Prefetchable memory base.
        prefetchable_memory_base: u16,
        /// Prefetchable memory limit.
        prefetchable_memory_limit: u16,
        /// Prefetchable base address upper 32 bits.
        prefetchable_base_upper32: u32,
        /// Prefetchable limit upper 32 bits.
        prefetchable_limit_upper32: u32,
        /// I/O base upper 16 bits.
        io_base_upper16: u16,
        /// I/O limit upper 16 bits.
        io_limit_upper16: u16,
        /// Capabilities pointer.
        cap_pointer: u8,
        /// Reserved.
        _reserved1: u24 = 0,
        /// Expansion ROM base address.
        exp_rom_base_address: u32,
        /// Interrupt line.
        interrupt_line: u8,
        /// Interrupt pin.
        interrupt_pin: u8,
        /// Bridge control.
        bridge_control: u16,
    };
};

/// Identify the generic function of the device.
pub const ClassCode = packed struct(u24) {
    /// Register-level programming interface.
    interface: u8,
    /// Specific device type.
    sub_class: u8,
    /// Broad category of the device.
    base_class: u8,
};

/// Command register to control PCI device.
const Command = packed struct(u16) {
    /// If true, the device responds to I/O space accesses.
    io_space: bool,
    /// If true, the device responds to memory space accesses.
    memory_space: bool,
    /// If true, the device is allowed to act as a bus master.
    bus_master: bool,
    /// If true, the device is allowed to monitor special cycle operations.
    special_cycle: bool,
    /// Enable bit for using the Memory Write and Invalidate command.
    mwrite_invalidate: bool,
    /// If true, the VGA compatible device is allowed to do palette snooping.
    palette_snoop: bool,
    /// If true, the device must take its normal action when a parity error is detected.
    /// If false, the device sets its Detected Parity Error status bit when an error is detected.
    parity_error_response: bool,
    /// Hardwired to zero.
    zero: u1 = 0,
    /// If true, enables the SERR# driver.
    serr: bool,
    /// If true, the master is allowed to generate fast back-to-back transactions to different agents.
    /// If false, it is allowed only to the same agent.
    fast_bb: bool,
    /// If true, disable the device/function from asserting INTx#.
    interrupt_disable: bool,
    /// Reserved.
    _reserved: u5 = 0,
};

/// Status register that records status information for PCI bus related events.
///
/// Reads behave normally.
/// Writes cannot set bits, but can clear them.
const Status = packed struct(u16) {
    /// Reserved.
    _reserved1: u3,
    /// State of the interrupt in the device/function. Read-only.
    interrupt_status: bool,
    /// If true, it indicates the value at offset 0x34 is a pointer to a linked list of New Capabilities. Read-only.
    capabilities: bool,
    /// If true, the device is capable of running at 66 MHz. Otherwise, 33 MHz.
    capable_66mhz: bool,
    /// Reserved.
    _reserved2: u1 = 0,
    /// If true, the target is capable of accepting fast back-to-back transactions.
    capable_fast_bb: bool,
    /// Set when three conditions are met.
    /// Implemented only by bus masters.
    master_parity_error: bool,
    /// Timing of DEVSEL#.
    devsel_timing: u2,
    /// Set when the target device terminates a transaction with a Target-Abort.
    signaled_target_abort: bool,
    /// Set when the master device terminates a transaction with a Target-Abort.
    received_target_abort: bool,
    /// Set when the master device terminates a transaction with a Master-Abort.
    received_master_abort: bool,
    /// Set when the device asserts SERR#.
    signaled_system_error: bool,
    /// Set when the device detects a parity error.
    signaled_parity_error: bool,
};

/// Base address register.
const Bar = packed struct(u32) {
    /// Raw data of the BAR.
    _data: u32,

    /// Used to get the required memory size.
    const all_set_bar: Bar = .{
        ._data = 0xFFFF_FFFF,
    };

    /// Types of BARs.
    const BarType = enum(u1) {
        /// Memory space base address register.
        mmio = 0,
        /// I/O space base address register.
        pio = 1,
    };

    /// Union of BAR.
    const Union = union(BarType) {
        mmio: MmioBar,
        pio: PioBar,
    };

    /// Memory space base address register
    const MmioBar = packed struct(u32) {
        /// Always 0 for memory space BAR.
        _bar_type: u1 = 0,
        /// Size of BAR and memory space.
        type: SpaceType,
        /// If true, the memory has no side effects when read.
        prefetchable: bool,
        /// 16-byte aligned base address.
        base: u28,

        const SpaceType = enum(u2) {
            /// BAR is 32-bits wide. The memory can be mapped anywhere in the 32bit memory space.
            map32 = 0b00,
            /// BAR is 64-bits wide. The memory can be mapped anywhere in the 64bit memory space.
            map64 = 0b10,

            _,
        };
    };

    /// I/O space base address register
    const PioBar = packed struct(u32) {
        /// Always 1 for I/O space BAR.
        _bar_type: u1 = 1,
        /// Reserved.
        _reserved: u1 = 0,
        /// 4-byte aligned base address.
        base: u30,
    };

    /// Specialize the BAR to a specific type based on the data.
    pub fn specialize(self: Bar) Union {
        return switch (@as(u1, @truncate(self._data))) {
            0 => .{ .mmio = @bitCast(self._data) },
            1 => .{ .pio = @bitCast(self._data) },
        };
    }
};

/// Capability ID.
const CapabilityId = enum(u8) {
    /// MSI
    msi = 5,
    /// MSI-X
    msix = 17,

    _,
};

/// Entries of capability list.
///
/// The structure is type-specific.
const CapabilityHeader = packed struct(u16) {
    /// Capability ID.
    id: CapabilityId,
    /// Offset from the configuration space to the next capability.
    next: RegisterOffset,

    // Type-specific data follows...

    /// Iterator for capabilities list.
    const Iterator = struct {
        /// Configuration space of the device.
        _config: ConfigurationSpace,
        /// Offset to the current capability.
        /// 0 means the iterator is at the end.
        _current: RegisterOffset,

        fn new(config: ConfigurationSpace) PciError!Iterator {
            const cap_pointer = switch (config) {
                inline .standard, .bridge => |c| c.read(.cap_pointer),
                else => return PciError.NotSupported,
            };
            return .{
                ._config = config,
                ._current = cap_pointer,
            };
        }

        fn poke(self: *const Iterator) ?CapabilityHeader {
            if (self._current == 0) return null;
            return self._config.readAt(CapabilityHeader, self._current);
        }

        fn next(self: *Iterator) ?CapabilityHeader {
            if (self._current == 0) return null;

            const cap = self._config.readAt(CapabilityHeader, self._current);
            self._current = cap.next;
            return cap;
        }

        fn current(self: *const Iterator) RegisterOffset {
            return self._current;
        }
    };
};

/// PCI device.
pub const Device = struct {
    const Self = @This();

    /// Bus number of the device.
    bus: BusNumber,
    /// Device number of the device.
    device: DeviceNumber,
    /// Function number of the device.
    function: FunctionNumber,

    /// Class code.
    class: ClassCode,
    /// Configuration space.
    config: ConfigurationSpace,

    /// Create a new PCI device.
    pub fn new(bus: BusNumber, device: DeviceNumber, function: FunctionNumber) PciError!Self {
        const config = ConfigurationSpaceAny.new(bus, device, function);
        return .{
            .bus = bus,
            .device = device,
            .function = function,
            .class = config.read(.class_code),
            .config = try ConfigurationSpace.specialize(bus, device, function),
        };
    }

    /// Read n-th BAR of the device.
    ///
    /// Returns an error when the device's configuration space does not have the BAR.
    pub fn readBar(self: Self, comptime n: u3) PciError!Bar {
        switch (self.config) {
            .standard => |c| {
                return c.read(switch (n) {
                    0 => .bar0,
                    1 => .bar1,
                    2 => .bar2,
                    3 => .bar3,
                    4 => .bar4,
                    5 => .bar5,
                    else => PciError.NotSupported,
                });
            },
            else => {
                return PciError.NotSupported;
            },
        }
    }

    /// Setup MSI.
    pub fn initMsi(self: *Self, dest: u8, vector: u8) PciError!void {
        var cap_iter = try CapabilityHeader.Iterator.new(self.config);
        const msi_offset = blk: {
            while (cap_iter.poke()) |cap| : (_ = cap_iter.next()) {
                if (cap.id == .msi) {
                    break :blk cap_iter.current();
                }
            } else {
                return PciError.NotFound;
            }
        };

        // Enable MSI.
        const control_offset = msi_offset + @offsetOf(MsiCapability, "control");
        var control = self.config.readAt(MsiCapability.MessageControl, control_offset);
        norn.rtt.expectEqual(0, control._reserved);
        if (!control.address64_capable) {
            log.err("Expected 64-bit MSI address capability, but the device does not support it.", .{});
            return PciError.NotSupported;
        }

        control.enable = true;
        control.multi_enable = 0;
        self.config.writeAt(control, control_offset);

        // Set address and data.
        const addr_offset = msi_offset + @offsetOf(MsiCapability, "addr");
        const data_offset = msi_offset + @offsetOf(MsiCapability, "data");
        const addr = arch.msi.Address.new(dest);
        const data = arch.msi.Data.new(vector);
        self.config.writeAt(addr, addr_offset);
        self.config.writeAt(data, data_offset);
    }
};

const MsiCapability = packed struct {
    /// Capability list header.
    header: CapabilityHeader,
    /// Message control.
    control: MessageControl,
    /// Message address register.
    addr: arch.msi.Address,
    /// Reserved.
    _reserved: u32 = 0,
    /// Message data register.
    data: arch.msi.Data,

    const MessageControl = packed struct(u16) {
        /// MSI Enable.
        enable: bool,
        /// Number of vectors that the device requests. Read-only.
        multi_capable: u3,
        /// Number of vectors to enable.
        multi_enable: u3,
        /// 64 bit address capable. Read-only.
        address64_capable: bool,
        /// Per-vector mask is supported. Read-only.
        per_vector_capable: bool,
        /// Reserved.
        _reserved: u7 = 0,
    };
};

/// Initialize the PCI subsystem.
pub fn init(allocator: Allocator) PciError!void {
    // Initialize the device list.
    devices = DeviceList.init(allocator);

    // Register all PCI devices.
    try registerAllDevices(allocator);
}

/// Enumerate all PCI devices and register them.
fn registerAllDevices(allocator: Allocator) PciError!void {
    const S = struct {
        fn enumerateBus(bus: BusNumber, alc: Allocator) PciError!void {
            for (0..std.math.maxInt(DeviceNumber)) |i| {
                try enumerateDevice(bus, @intCast(i), alc);
            }
        }

        fn enumerateDevice(bus: BusNumber, device: DeviceNumber, alc: Allocator) PciError!void {
            const dev = ConfigurationSpaceAny.new(bus, device, 0);
            if (!dev.isValid()) return;

            try registerFunction(bus, device, 0, alc);

            if (!dev.isSingleFunction()) {
                for (1..std.math.maxInt(FunctionNumber)) |function| {
                    const func = ConfigurationSpaceAny.new(
                        bus,
                        device,
                        @intCast(function),
                    );
                    if (!func.isValid()) continue;

                    try registerFunction(bus, device, @intCast(function), alc);
                }
            }
        }

        fn registerFunction(bus: BusNumber, device: DeviceNumber, function: FunctionNumber, alc: Allocator) PciError!void {
            const pci_device = try alc.create(Device);
            errdefer alc.destroy(pci_device);

            pci_device.* = try Device.new(bus, device, function);

            try devices.append(pci_device);
        }
    };

    try S.enumerateBus(0, allocator);
}

/// Find a registered PCI device by its class code.
pub fn findDevice(class: ClassCode) ?*Device {
    for (devices.items) |dev| {
        if (dev.class == class) {
            return dev;
        }
    } else {
        return null;
    }
}

// =============================================================
// Debug
// =============================================================

/// Enumerate all PCI devices and print their information.
///
/// This function is used for debugging purposes.
pub fn debugPrintAllDevices() void {
    const S = struct {
        fn enumerateBus(bus: BusNumber) void {
            for (0..std.math.maxInt(DeviceNumber)) |i| {
                enumerateDevice(bus, @intCast(i));
            }
        }

        fn enumerateDevice(bus: BusNumber, device: DeviceNumber) void {
            const dev = ConfigurationSpaceAny.new(bus, device, 0);
            if (!dev.isValid()) return;
            printFunction(bus, device, 0);

            if (!dev.isSingleFunction()) {
                for (1..std.math.maxInt(FunctionNumber)) |function| {
                    const func = ConfigurationSpaceAny.new(
                        bus,
                        device,
                        @intCast(function),
                    );
                    if (!func.isValid()) continue;
                    printFunction(bus, device, @intCast(function));
                }
            }
        }

        fn printFunction(bus: BusNumber, device: DeviceNumber, function: FunctionNumber) void {
            const func = ConfigurationSpaceAny.new(bus, device, function);
            const class: ClassCode = @bitCast(func.read(.class_code));
            log.info("{X:0>2}:{X:0>2}.{X:0>1} - {X:0>4}:{X:0>4} {X:0>2}:{X:0>2}:{X:0>2} (layout: {s})", .{
                bus,
                device,
                function,
                func.read(.vendor_id),
                func.read(.device_id),
                class.base_class,
                class.sub_class,
                class.interface,
                @tagName(func.read(.header_type).layout),
            });
        }
    };

    S.enumerateBus(0);
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

test "Configuration space layout" {
    const CA = ConfigurationSpaceAny;
    const C0 = ConfigurationSpace0;
    const C1 = ConfigurationSpace1;

    // offsetOf
    try testing.expectEqual(0, CA.HeaderType.offsetOf(.vendor_id));
    try testing.expectEqual(0xF, CA.HeaderType.offsetOf(.bist));

    try testing.expectEqual(0, C0.HeaderType.offsetOf(.vendor_id));
    try testing.expectEqual(0xF, C0.HeaderType.offsetOf(.bist));
    try testing.expectEqual(0x10, C0.HeaderType.offsetOf(.bar0));
    try testing.expectEqual(0x24, C0.HeaderType.offsetOf(.bar5));
    try testing.expectEqual(0x3F, C0.HeaderType.offsetOf(.max_latency));

    try testing.expectEqual(0, C1.HeaderType.offsetOf(.vendor_id));
    try testing.expectEqual(0xF, C1.HeaderType.offsetOf(.bist));
    try testing.expectEqual(0x10, C1.HeaderType.offsetOf(.bar0));
    try testing.expectEqual(0x24, C1.HeaderType.offsetOf(.prefetchable_memory_base));
    try testing.expectEqual(0x3E, C1.HeaderType.offsetOf(.bridge_control));

    // typeOf
    try testing.expectEqual(VendorId, CA.HeaderType.typeOf(.vendor_id));

    try testing.expectEqual(VendorId, C0.HeaderType.typeOf(.vendor_id));
    try testing.expectEqual(Bar, C0.HeaderType.typeOf(.bar5));

    try testing.expectEqual(VendorId, C1.HeaderType.typeOf(.vendor_id));
    try testing.expectEqual(u16, C1.HeaderType.typeOf(.prefetchable_memory_base));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.pci);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const arch = norn.arch;
const rtt = norn.rtt;
const util = norn.util;
