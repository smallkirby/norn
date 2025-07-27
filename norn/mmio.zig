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
        return @bitSizeOf(self.utype());
    }

    /// Get the byte width of the access width.
    pub inline fn byteWidth(comptime self: Width) u8 {
        return @sizeOf(self.utype());
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

            var raw_data: [@sizeOf(FT)]u8 = undefined;
            comptime var remain: usize = @bitSizeOf(FT);
            comptime var i: usize = 0;
            inline while (remain > 0) : ({
                remain -|= width.bitWidth();
                i += 1;
            }) {
                const field_offset_i = field_offset + (i * width.byteWidth());
                const access_offset = util.rounddown(field_offset_i, width.byteWidth());
                const offset_diff = field_offset_i - access_offset;

                const PartialType = if (@bitSizeOf(FT) >= width.bitWidth()) U else FT;
                const value = reader(self._iobase.add(access_offset));
                const value_partial = bits.extract(
                    PartialType,
                    value,
                    offset_diff * @bitSizeOf(u8),
                );

                const data_offset = i * width.byteWidth();
                const length = @sizeOf(PartialType);
                @memcpy(
                    raw_data[data_offset .. data_offset + length],
                    std.mem.asBytes(&value_partial)[0..length],
                );
            }

            return @bitCast(raw_data);
        }

        /// Write a field to the MMIO register.
        ///
        /// The operation is ensured to be ordered.
        pub fn write(self: *const Self, comptime field: Fields, value: @FieldType(T, @tagName(field))) void {
            const FT = @FieldType(T, @tagName(field));
            const field_offset = @offsetOf(T, @tagName(field));

            comptime var remain: usize = @bitSizeOf(FT);
            comptime var i: usize = 0;
            inline while (remain > 0) : ({
                remain -|= width.bitWidth();
                i += 1;
            }) {
                const field_offset_i = field_offset + (i * width.byteWidth());
                const access_offset = util.rounddown(field_offset_i, width.byteWidth());
                const offset_diff = field_offset_i - access_offset;

                const current_value = reader(self._iobase.add(access_offset));
                const new_value_partial = bits.extract(
                    if (@bitSizeOf(FT) >= width.bitWidth()) U else FT,
                    value,
                    i * width.bitWidth(),
                );
                const new_value = bits.embed(
                    current_value,
                    new_value_partial,
                    offset_diff * @bitSizeOf(u8),
                );
                writer(self._iobase.add(access_offset), new_value);
            }
        }

        /// Write all fields of the MMIO register.
        pub fn set(self: *const Self, value: T) void {
            writer(self._iobase, @bitCast(value));
        }
    };
}

// =============================================================
// Tests
// =============================================================

/// Run runtime tests.
pub fn performRtt() void {
    const rtt = norn.rtt;

    const page1 = norn.mem.page_allocator.allocPages(1, .normal) catch unreachable;
    const page2 = norn.mem.page_allocator.allocPages(1, .normal) catch unreachable;
    defer norn.mem.page_allocator.freePages(page1);
    defer norn.mem.page_allocator.freePages(page2);

    const S1 = packed struct {
        a: u8,
        b: u8,
        c: u16,
        d: u32,
        e: u64,
    };
    const E = packed struct(u32) { e1: u32 };
    const F = packed struct(u32) { f1: u16, f2: u16 };
    const G = packed struct(u64) { g1: u16, g2: u16, g3: u32 };
    const S2 = packed struct {
        e: E,
        f: F,
        g: G,
    };
    const R1d = Register(S1, .dword);
    const R1q = Register(S1, .qword);
    const R2d = Register(S2, .dword);
    const R2q = Register(S2, .qword);

    const s1: *S1 = @ptrCast(page1.ptr);
    const s2: *S2 = @ptrCast(page2.ptr);
    const iobase1: IoAddr = @bitCast(@intFromPtr(page1.ptr));
    const iobase2: IoAddr = @bitCast(@intFromPtr(page2.ptr));
    const r1d = R1d.new(iobase1);
    const r1q = R1q.new(iobase1);
    const r2d = R2d.new(iobase2);
    const r2q = R2q.new(iobase2);

    // Initialize the register.
    {
        s1.* = .{
            .a = 0x12,
            .b = 0x21,
            .c = 0x3456,
            .d = 0x789ABCDE,
            .e = 0xFEDCBA9876543210,
        };
        s2.* = .{
            .e = .{ .e1 = 0x12345678 },
            .f = .{ .f1 = 0x9ABC, .f2 = 0xDEF0 },
            .g = .{ .g1 = 0x1234, .g2 = 0x5678, .g3 = 0x9ABCDEF0 },
        };
    }

    // Reads
    {
        // DWORD
        rtt.expectEqual(0x12, r1d.read(.a));
        rtt.expectEqual(0x21, r1d.read(.b));
        rtt.expectEqual(0x3456, r1d.read(.c));
        rtt.expectEqual(0x789ABCDE, r1d.read(.d));
        rtt.expectEqual(0xFEDCBA9876543210, r1d.read(.e));

        rtt.expectEqual(E{ .e1 = 0x12345678 }, r2d.read(.e));
        rtt.expectEqual(F{ .f1 = 0x9ABC, .f2 = 0xDEF0 }, r2d.read(.f));
        rtt.expectEqual(G{ .g1 = 0x1234, .g2 = 0x5678, .g3 = 0x9ABCDEF0 }, r2d.read(.g));

        // QWORD
        rtt.expectEqual(0x12, r1q.read(.a));
        rtt.expectEqual(0x21, r1d.read(.b));
        rtt.expectEqual(0x3456, r1q.read(.c));
        rtt.expectEqual(0x789ABCDE, r1q.read(.d));
        rtt.expectEqual(0xFEDCBA9876543210, r1q.read(.e));

        rtt.expectEqual(E{ .e1 = 0x12345678 }, r2q.read(.e));
        rtt.expectEqual(F{ .f1 = 0x9ABC, .f2 = 0xDEF0 }, r2q.read(.f));
        rtt.expectEqual(G{ .g1 = 0x1234, .g2 = 0x5678, .g3 = 0x9ABCDEF0 }, r2q.read(.g));
    }

    // Writes
    {
        // DWORD
        r1d.write(.a, 0xF1);
        rtt.expectEqual(0xF1, r1d.read(.a));
        r1d.write(.b, 0xF2);
        rtt.expectEqual(0xF2, r1d.read(.b));
        r1d.write(.c, 0xF345);
        rtt.expectEqual(0xF345, r1d.read(.c));
        r1d.write(.d, 0xF789ABCD);
        rtt.expectEqual(0xF789ABCD, r1d.read(.d));
        r1d.write(.e, 0xF0F1F2F3F4F5F6F7);
        rtt.expectEqual(0xF0F1F2F3F4F5F6F7, r1d.read(.e));

        r2d.write(.e, E{ .e1 = 0xF1234567 });
        rtt.expectEqual(E{ .e1 = 0xF1234567 }, r2d.read(.e));
        r2d.write(.f, F{ .f1 = 0xF9AB, .f2 = 0xFDEF });
        rtt.expectEqual(F{ .f1 = 0xF9AB, .f2 = 0xFDEF }, r2d.read(.f));
        r2d.write(.g, G{ .g1 = 0xF123, .g2 = 0xF567, .g3 = 0xF9ABCDEF });
        rtt.expectEqual(G{ .g1 = 0xF123, .g2 = 0xF567, .g3 = 0xF9ABCDEF }, r2d.read(.g));

        // QWORD
        r1q.write(.a, 0xF1);
        rtt.expectEqual(0xF1, r1q.read(.a));
        r1q.write(.b, 0xF2);
        rtt.expectEqual(0xF2, r1q.read(.b));
        r1q.write(.c, 0xF345);
        rtt.expectEqual(0xF345, r1q.read(.c));
        r1q.write(.d, 0xF789ABCD);
        rtt.expectEqual(0xF789ABCD, r1q.read(.d));
        r1q.write(.e, 0xF0F1F2F3F4F5F6F7);
        rtt.expectEqual(0xF0F1F2F3F4F5F6F7, r1q.read(.e));

        r2q.write(.e, E{ .e1 = 0xF1234567 });
        rtt.expectEqual(E{ .e1 = 0xF1234567 }, r2q.read(.e));
        r2q.write(.f, F{ .f1 = 0xF9AB, .f2 = 0xFDEF });
        rtt.expectEqual(F{ .f1 = 0xF9AB, .f2 = 0xFDEF }, r2q.read(.f));
        r2q.write(.g, G{ .g1 = 0xF123, .g2 = 0xF567, .g3 = 0xF9ABCDEF });
        rtt.expectEqual(G{ .g1 = 0xF123, .g2 = 0xF567, .g3 = 0xF9ABCDEF }, r2q.read(.g));
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const bits = norn.bits;
const util = norn.util;
const IoAddr = norn.mem.IoAddr;
