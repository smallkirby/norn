/// Data type for function number.
const FunctionNumber = u3;
/// Data type for device number.
const DeviceNumber = u5;
/// Data type for bus number.
const BusNumber = u8;
/// Data type for register offset.
const RegisterOffset = u8;

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
const ConfigurationSpace = struct {
    const Self = @This();

    _bus: BusNumber,
    _device: DeviceNumber,
    _function: FunctionNumber,

    /// I/O address of CONFIG_ADDRESS.
    const config_address = 0xCF8;
    /// I/O address of CONFIG_DATA.
    const config_data = 0xCFC;
    /// Alignment for register offsets to ensure 32-bit access.
    const register_align = @as(RegisterOffset, 0b11);

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
    pub fn read(self: Self, comptime field: std.meta.FieldEnum(PredefinedHeader)) PredefinedHeader.typeOf(field) {
        // Since all reads must be 32-bit aligned, we need to read the whole DWORD.
        const exact_offset = PredefinedHeader.offsetOf(field);
        const aligned_offset = exact_offset & ~register_align;
        const T = PredefinedHeader.typeOf(field);

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
        return self.read(.vendor_id) != PredefinedHeader.invalid_vendor_id;
    }
};

/// Pre-defined header in the PCI configuration space.
///
/// The first 16 bytes of the PCI configuration space.
/// The layout of this header is same for all types of PCI devices.
const PredefinedHeader = packed struct {
    const Self = @This();

    comptime {
        norn.comptimeAssert(@sizeOf(Self) == 0x10, "Invalid size of PredefinedHeader: 0x{X}", .{@sizeOf(Self)});
    }

    /// Manufacturer of the device.
    vendor_id: u16,
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

    /// Invalid Vendor ID.
    const invalid_vendor_id = 0xFFFF;

    const HeaderTypeField = packed struct(u8) {
        /// Header layout.
        layout: HeaderLayout,
        /// If true, the device is a multi-function device.
        is_multi_function: bool,
    };

    const HeaderLayout = enum(u7) {
        /// Standard header.
        standard = 0x00,
        /// PCI-to-PCI bridge.
        bridge = 0x01,
        /// CardBus bridge.
        cardbus_bridge = 0x02,

        _,
    };

    const ClassCode = packed struct(u24) {
        /// Register-level programming interface.
        interface: u8,
        /// Specific device type.
        sub_class: u8,
        /// Broad category of the device.
        base_class: u8,
    };

    /// Get a register offset for a field in the predefined header.
    inline fn offsetOf(comptime field: std.meta.FieldEnum(Self)) RegisterOffset {
        return @offsetOf(Self, std.meta.fieldInfo(Self, field).name);
    }

    /// Get a type of a field in the predefined header.
    inline fn typeOf(comptime field: std.meta.FieldEnum(Self)) type {
        return std.meta.fieldInfo(Self, field).type;
    }
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
            const dev = ConfigurationSpace.new(bus, device, 0);
            if (!dev.isValid()) return;
            printFunction(bus, device, 0);

            if (!dev.isSingleFunction()) {
                for (1..std.math.maxInt(FunctionNumber)) |function| {
                    const func = ConfigurationSpace.new(
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
            const func = ConfigurationSpace.new(bus, device, function);
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
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.pci);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const arch = norn.arch;
const rtt = norn.rtt;
