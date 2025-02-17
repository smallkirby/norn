const std = @import("std");

/// Set the integer where only the nth bit is set.
pub fn tobit(T: type, nth: anytype) T {
    const val = switch (@typeInfo(@TypeOf(nth))) {
        .Int, .ComptimeInt => nth,
        .Enum => @intFromEnum(nth),
        else => @compileError("setbit: invalid type"),
    };
    return @as(T, 1) << @intCast(val);
}

/// Check if the nth bit is set.
pub inline fn isset(val: anytype, nth: anytype) bool {
    const int_nth = switch (@typeInfo(@TypeOf(nth))) {
        .Int, .ComptimeInt => nth,
        .Enum => @intFromEnum(nth),
        else => @compileError("isset: invalid type"),
    };
    return ((val >> @intCast(int_nth)) & 1) != 0;
}

/// Concatnate two values and returns new value with twice the bit width.
pub inline fn concat(T: type, a: anytype, b: @TypeOf(a)) T {
    const U = @TypeOf(a);
    const width_T = @typeInfo(T).Int.bits;
    const width_U = switch (@typeInfo(U)) {
        .Int => |t| t.bits,
        .ComptimeInt => width_T / 2,
        else => @compileError("concat: invalid type"),
    };
    if (width_T != width_U * 2) @compileError("concat: invalid type");
    return (@as(T, a) << width_U) | @as(T, b);
}

/// Concatnate arbitrary number of integers in the order of the arguments.
///
/// Numbers must not be comptime_int. The width must be explicitly specified.
pub fn concatMany(T: type, args: anytype) T {
    const fields = std.meta.fields(@TypeOf(args));

    // Check if the total width of the args is equal to the output type.
    comptime {
        switch (@typeInfo(@TypeOf(args))) {
            .Struct => {},
            else => @compileError("concatMany: invalid type"),
        }

        var width = 0;
        for (fields) |field| {
            width += switch (@typeInfo(field.type)) {
                .Int => |t| t.bits,
                else => @compileError("concatMany: invalid type of entry"),
            };
        }
        if (width != @typeInfo(T).Int.bits) @compileError("concatMany: total width mismatch");
    }

    // Calculate the result.
    comptime var cur_width = 0;
    var result: T = 0;
    comptime var index = fields.len;
    inline while (index > 0) : (index -= 1) {
        const field = fields[index - 1];
        const val = @field(args, field.name);
        const val_width = switch (@typeInfo(field.type)) {
            .Int => |t| t.bits,
            else => @compileError("concatMany: invalid type of entry"),
        };
        result |= @as(T, val) << cur_width;
        cur_width += val_width;
    }

    return result;
}

/// Set the nth bit in the integer.
pub inline fn set(T: type, val: T, comptime nth: anytype) T {
    return val | tobit(T, nth);
}

/// Unset the nth bit in the integer.
pub inline fn unset(T: type, val: T, comptime nth: anytype) T {
    return val & ~tobit(T, nth);
}

const testing = std.testing;

test "tobit" {
    try testing.expectEqual(0b0000_0001, tobit(u8, 0));
    try testing.expectEqual(0b0001_0000, tobit(u8, 4));
    try testing.expectEqual(0b1000_0000, tobit(u8, 7));
}

test "isset" {
    try testing.expectEqual(true, isset(0b10, 1));
    try testing.expectEqual(false, isset(0b10, 0));
    try testing.expectEqual(true, isset(0b1000_0000, 7));
    try testing.expectEqual(false, isset(0b1000_0000, 99));
}

test "concat" {
    try testing.expectEqual(0b10, concat(u2, @as(u1, 1), @as(u1, 0)));
    try testing.expectEqual(0x1234, concat(u16, 0x12, 0x34));
}

test "concatMany" {
    try testing.expectEqual(0b1_1_0, concatMany(u3, .{
        @as(u1, 1),
        @as(u1, 1),
        @as(u1, 0),
    }));
    try testing.expectEqual(0x1111_2222_3333_4444_5555_6666_7777_8888, concatMany(u128, .{
        @as(u32, 0x1111_2222),
        @as(u64, 0x3333_4444_5555_6666),
        @as(u32, 0x7777_8888),
    }));
}

test "set" {
    try testing.expectEqual(0b0000_0010, set(u8, 0, 1));
    try testing.expectEqual(0b0001_0000, set(u8, 0, 4));
    try testing.expectEqual(0b1000_0000, set(u8, 0, 7));
}

test "unset" {
    try testing.expectEqual(0b0000_0000, unset(u8, 0b0000_0001, 0));
    try testing.expectEqual(0b0000_0000, unset(u8, 0b0001_0000, 4));
    try testing.expectEqual(0b0000_0000, unset(u8, 0b1000_0000, 7));
}
