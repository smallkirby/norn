//! This file defines structures shared among Surtr and Norn.

const uefi = @import("std").os.uefi;

pub const magic: usize = 0xDEADBEEF_CAFEBABE;

/// Boot information.
/// This struct is passed from the bootloader to the kernel.
///
/// This structure is located at Surtr stack (.boot_services_data).
///
/// Norn must deep-copy this data structure before .boot_services_data and .loader_data is freed.
pub const BootInfo = extern struct {
    /// Magic number to check if the boot info is valid.
    magic: usize = magic,
    /// Memory map provided by UEFI.
    ///
    /// Located at .boot_services_data.
    memory_map: MemoryMap,
    /// RSDP.
    rsdp: *anyopaque,
    /// Virtual address where per-CPU data is loaded.
    percpu_base: u64,
    /// Information about initramfs.
    ///
    /// Located at .loader_data.
    initramfs: InitramfsInfo,
    /// Norn command line arguments.
    ///
    /// Located at .boot_services_data.
    cmdline: [*:0]allowzero const u8,
};

/// Information about initramfs.
pub const InitramfsInfo = extern struct {
    /// Size of initramfs.
    size: usize,
    /// Physical address where initramfs is loaded.
    addr: u64,
};

/// Memory map provided by UEFI.
pub const MemoryMap = extern struct {
    /// Total buffer size prepared to store the memory map.
    buffer_size: usize,
    /// Memory descriptors.
    descriptors: [*]uefi.tables.MemoryDescriptor,
    /// Total memory map size.
    map_size: usize,
    /// Map key used to check if the memory map has been changed.
    map_key: uefi.tables.MemoryMapKey,
    /// Size in bytes of each memory descriptor.
    descriptor_size: usize,
    /// UEFI memory descriptor version.
    descriptor_version: u32,

    /// Deep copy the internal buffers using the given allocator.
    ///
    /// This function does not free the old buffers.
    pub fn deepCopy(self: *MemoryMap, allocator: Allocator) (Allocator.Error || error{InvalidData})!void {
        const buffer = try allocator.alloc(u8, self.buffer_size);
        errdefer allocator.free(buffer);
        if (buffer.len != self.buffer_size) {
            return error.InvalidData;
        }

        const new_descriptors: [*]uefi.tables.MemoryDescriptor = @ptrCast(@alignCast(buffer.ptr));
        const new_descriptors_bytes: [*]u8 = @ptrCast(new_descriptors);
        const descriptors_bytes: [*]u8 = @ptrCast(self.descriptors);
        @memcpy(
            new_descriptors_bytes[0..self.map_size],
            descriptors_bytes[0..self.map_size],
        );

        self.descriptors = new_descriptors;
    }

    /// Get the internal buffer.
    ///
    /// Caller can free this buffer.
    pub fn getInternalBuffer(self: *MemoryMap, phys2virt: *const fn (anytype) u64) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(phys2virt(self.descriptors));
        return ptr[0..self.buffer_size];
    }
};

/// Memory descriptor iterator.
pub const MemoryDescriptorIterator = struct {
    const Self = @This();
    const Md = uefi.tables.MemoryDescriptor;

    descriptors: [*]Md,
    current: *Md,
    descriptor_size: usize,
    total_size: usize,

    pub fn new(map: MemoryMap) Self {
        return Self{
            .descriptors = map.descriptors,
            .current = @ptrCast(map.descriptors),
            .descriptor_size = map.descriptor_size,
            .total_size = map.map_size,
        };
    }

    pub fn next(self: *Self) ?*Md {
        const ret = self.peek() orelse return null;
        self.current = @ptrFromInt(@intFromPtr(self.current) + self.descriptor_size);
        return ret;
    }

    pub fn peek(self: *Self) ?*Md {
        if (@intFromPtr(self.current) >= @intFromPtr(self.descriptors) + self.total_size) {
            return null;
        }
        return self.current;
    }
};

/// Memory type with Surtr / Norn -specific extensions.
///
/// This enum type extends uefi.tables.MemoryType.
pub const MemoryType = blk: {
    const extended_types = [_][:0]const u8{
        // Reserved by Norn.
        //
        // Cannot be used even after exiting boot services.
        "norn_reserved",
    };
    // 0x7000_0000 ~ 0x7FFF_FFFF are reserved by OEM.
    // 0x8000_0000 ~ 0xFFFF_FFFF are reserved by UEFI OS loaders.
    const extended_start_ix: u32 = 0x8000_0000 + 1;

    const original_types = std.meta.fields(uefi.tables.MemoryType);
    const fields_len = original_types.len + extended_types.len;
    var enumFields: [fields_len]std.builtin.Type.EnumField = undefined;

    for (original_types, 0..) |field, i| {
        enumFields[i] = field;
    }
    for (extended_types, 0..) |name, i| {
        enumFields[original_types.len + i] = .{
            .name = name,
            .value = @as(u32, extended_start_ix + i),
        };
    }

    break :blk @Type(.{
        .@"enum" = .{
            .tag_type = u32,
            .fields = &enumFields,
            .decls = &.{},
            .is_exhaustive = false,
        },
    });
};

/// Convert a extended memory type to UEFI memory type.
pub inline fn toUefiMemoryType(mtype: MemoryType) uefi.tables.MemoryType {
    return @enumFromInt(@intFromEnum(mtype));
}

/// Convert a UEFI memory type to a Surtr / Norn -specific extended memory type.
pub inline fn toExtendedMemoryType(mtype: uefi.tables.MemoryType) MemoryType {
    return @enumFromInt(@intFromEnum(mtype));
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

test {
    testing.refAllDecls(@import("param.zig"));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
