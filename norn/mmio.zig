/// Access width for MMIO registers.
pub const Width = enum(u8) {
    byte = 1,
    word = 2,
    dword = 4,
    qword = 8,

    /// Get the corresponding unsigned integer type for the access width.
    pub fn utype(comptime self: Width) type {
        return switch (self) {
            .qword => u64,
            .dword => u32,
            .word => u16,
            .byte => u8,
        };
    }

    /// Get the bit width of the access width.
    pub inline fn bitWidth(comptime self: Width) usize {
        return @sizeOf(self.utype());
    }

    /// Get the byte width of the access width.
    pub inline fn byteWidth(comptime self: Width) u8 {
        return @as(u8, self.bitWidth());
    }
};

/// MMIO register with access width restrictions.
pub fn Register(comptime T: type, comptime width: Width) type {
    return struct {
        const Self = @This();
        const U = width.utype();

        const Fields = std.meta.FieldEnum(T);

        const reader = switch (width) {
            .byte => IoAddr.read8,
            .word => IoAddr.read16,
            .dword => IoAddr.read32,
            .qword => IoAddr.read64,
        };
        const writer = switch (width) {
            .byte => IoAddr.write8,
            .word => IoAddr.write16,
            .dword => IoAddr.write32,
            .qword => IoAddr.write64,
        };

        /// Base MMIO address.
        _iobase: IoAddr,

        /// Create a new MMIO register.
        pub fn new(iobase: IoAddr) Self {
            return .{
                ._iobase = iobase,
            };
        }

        /// Read a field from the MMIO register.
        ///
        /// The operation is ensured to be ordered.
        pub fn read(self: *const Self, comptime field: Fields) @FieldType(T, @tagName(field)) {
            const FT = @FieldType(T, @tagName(field));
            const field_offset = @offsetOf(T, @tagName(field));
            const access_offset = util.rounddown(field_offset, width.byteWidth());
            const offset_diff = field_offset - access_offset;

            const value = reader(self._iobase.add(access_offset));
            return bits.extract(FT, value, offset_diff * @bitSizeOf(u8));
        }

        /// Write a field to the MMIO register.
        ///
        /// The operation is ensured to be ordered.
        pub fn write(self: *const Self, comptime field: Fields, value: @FieldType(T, @tagName(field))) void {
            const field_offset = @offsetOf(T, @tagName(field));
            const access_offset = util.rounddown(field_offset, width.byteWidth());
            const offset_diff = field_offset - access_offset;

            const current_value = reader(self._iobase.add(access_offset));
            const new_value = bits.embed(current_value, value, offset_diff * @bitSizeOf(u8));
            writer(self._iobase.add(access_offset), new_value);
        }
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const bits = norn.bits;
const util = norn.util;
const IoAddr = norn.mem.IoAddr;
