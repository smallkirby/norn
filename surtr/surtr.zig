//! This file defines structures shared among Surtr and Norn.

const uefi = @import("std").os.uefi;

pub const magic: usize = 0xDEADBEEF_CAFEBABE;

/// Boot information.
/// This struct is passed from the bootloader to the kernel.
pub const BootInfo = extern struct {
    /// Magic number to check if the boot info is valid.
    magic: usize = magic,
    /// Memory map provided by UEFI.
    memory_map: MemoryMap,
    /// RSDP.
    rsdp: *anyopaque,
    /// Virtual address where per-CPU data is loaded.
    percpu_base: u64,
    /// Information about initramfs.
    initramfs: InitramfsInfo,
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
    map_key: usize,
    /// Size in bytes of each memory descriptor.
    descriptor_size: usize,
    /// UEFI memory descriptor version.
    descriptor_version: u32,
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
        if (@intFromPtr(self.current) >= @intFromPtr(self.descriptors) + self.total_size) {
            return null;
        }
        const md = self.current;
        self.current = @ptrFromInt(@intFromPtr(self.current) + self.descriptor_size);
        return md;
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
    const extended_start_ix: u32 = 0x8000_0000;

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
const std = @import("std");
const testing = std.testing;

test {
    testing.refAllDecls(@import("param.zig"));
}
