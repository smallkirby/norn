/// Wrapper struct that allows partial write of fields with an anonymous struct.
pub fn Partialable(Type: type) type {
    return packed struct {
        const Self = @This();

        comptime {
            if (@bitSizeOf(Type) != @bitSizeOf(Self)) {
                @compileError("Size mismatch");
            }
        }

        /// Inner type.
        pub const T = Type;
        /// Inner value.
        inner: T,

        /// Initialize the inner struct.
        pub fn new(value: T) Self {
            return .{ .inner = value };
        }

        /// Set the part of fields of the inner struct.
        pub fn set(self: *Self, partial: anytype) void {
            inline for (@typeInfo(@TypeOf(partial)).Struct.fields) |field| {
                @field(self.inner, field.name) = @field(partial, field.name);
            }
        }
    };
}

// =======================================

const testing = @import("std").testing;

const A = Partialable(packed struct(u64) {
    a: u8,
    b: u16,
    c: u32,
    d: u8,
});

test "Partialable" {
    var va = A.new(.{
        .a = 0x12,
        .b = 0x3456,
        .c = 0x789A_BCD0,
        .d = 0xAB,
    });
    try testing.expectEqual(va.inner, A.T{
        .a = 0x12,
        .b = 0x3456,
        .c = 0x789A_BCD0,
        .d = 0xAB,
    });

    va.set(.{
        .b = 0xDEAD,
        .c = 0x1234_5678,
    });
    try testing.expectEqual(va.inner, A.T{
        .a = 0x12,
        .b = 0xDEAD,
        .c = 0x1234_5678,
        .d = 0xAB,
    });
}
