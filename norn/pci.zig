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

        /// Read a value of the given field from the PCI configuration space.
        ///
        /// This function uses a configuration space access mechanism #1 (PIO access).
        /// This function is responsible for correctly aligning an access offset and a size.
        pub fn read(self: Self, comptime field: HeaderType.FieldEnum) HeaderType.typeOf(field) {
            // Since all reads must be 32-bit aligned, we need to read the whole DWORD.
            const exact_offset = HeaderType.offsetOf(field);
            const aligned_offset = exact_offset & ~register_align;
            const T = HeaderType.typeOf(field);

            // Configure CONFIG_ADDRESS register.
            rtt.expectEqual(0, aligned_offset & register_align);
            const addr = ConfigAddress{
                .register = aligned_offset,
                .function = self._function,
                .device = self._device,
                .bus = self._bus,
            };
            arch.out(u32, addr, config_address);

            // Read a value and extract the required bits.
            const result = arch.in(u32, config_data);
            const shifted_result = result >> ((exact_offset - aligned_offset) * 8);
            const truncated_result = switch (@bitSizeOf(T)) {
                8 => @as(u8, @truncate(shifted_result)),
                16 => @as(u16, @truncate(shifted_result)),
                32 => @as(u32, @truncate(shifted_result)),
                else => @compileError("Unsupported type size for PCI configuration space read"),
            };
            return @bitCast(truncated_result);
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
    };
}

/// Specialized PCI configuration space reader and writer for any layout.
const ConfigurationSpaceAny = ConfigurationSpaceGenerator(null);
/// Specialized PCI configuration space reader and writer for the layout type 0x0.
const ConfigurationSpace0 = ConfigurationSpaceGenerator(.standard);
/// Specialized PCI configuration space reader and writer for the layout type 0x1.
const ConfigurationSpace1 = ConfigurationSpaceGenerator(.bridge);

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
        bar0: u32,
        /// Base address register #1
        bar1: u32,
        /// Base address register #2
        bar2: u32,
        /// Base address register #3
        bar3: u32,
        /// Base address register #4
        bar4: u32,
        /// Base address register #5
        bar5: u32,
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
        bar0: u32,
        /// Base address register #1
        bar1: u32,
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
const ClassCode = packed struct(u24) {
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
            log.info("{X:0>2}:{X:0>2}.{X:0>1} - 0x{X:0>4}:0x{X:0>4} (layout: {s})", .{
                bus,
                device,
                function,
                func.read(.vendor_id),
                func.read(.device_id),
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
    try testing.expectEqual(u32, C0.HeaderType.typeOf(.bar5));

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
