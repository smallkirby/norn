//! Bit manipulation utilities.
//!
//! This file provides a numeric utilities for bit manipulation.

/// Set the integer where only the nth bit is set.
///
/// - `T`   : Type of the integer.
/// - `nth` : The bit position to set.
pub fn tobit(T: type, nth: anytype) T {
    const val = switch (@typeInfo(@TypeOf(nth))) {
        .int, .comptime_int => nth,
        .@"enum" => @intFromEnum(nth),
        else => @compileError("setbit: invalid type"),
    };
    return @as(T, 1) << @intCast(val);
}

/// Check if the nth bit is set.
///
/// - `val` : The integer to check.
/// - `nth` : The bit position to check.
pub inline fn isset(val: anytype, nth: anytype) bool {
    const int_nth = switch (@typeInfo(@TypeOf(nth))) {
        .int, .comptime_int => nth,
        .@"enum" => @intFromEnum(nth),
        else => @compileError("isset: invalid type"),
    };
    return ((val >> @intCast(int_nth)) & 1) != 0;
}

/// Concatnate two values and returns new value with twice the bit width.
///
/// - `T` : Type of the output value.
/// - `a` : The first value. Becomes the upper half of the output.
/// - `b` : The second value. Must be the same type as `a`. Becomes the lower half of the output.
pub inline fn concat(T: type, a: anytype, b: @TypeOf(a)) T {
    const U = @TypeOf(a);
    const width_T = @typeInfo(T).int.bits;
    const width_U = switch (@typeInfo(U)) {
        .int => |t| t.bits,
        .comptime_int => width_T / 2,
        else => @compileError("concat: invalid type"),
    };
    if (width_T != width_U * 2) @compileError("concat: invalid type");
    return (@as(T, a) << width_U) | @as(T, b);
}

/// Concatnate arbitrary number of integers in the order of the arguments.
///
/// Numbers MUST NOT be comptime_int.
/// The width MUST be explicitly specified for each value.
///
/// - `T`   : Type of the output value.
/// - `args`: Arbitrary number of values to concatnate.
pub fn concatMany(T: type, args: anytype) T {
    const fields = std.meta.fields(@TypeOf(args));

    // Check if the total width of the args is equal to the output type.
    comptime {
        switch (@typeInfo(@TypeOf(args))) {
            .@"struct" => {},
            else => @compileError("concatMany: invalid type"),
        }

        var width = 0;
        for (fields) |field| {
            width += switch (@typeInfo(field.type)) {
                .int => |t| t.bits,
                else => @compileError("concatMany: invalid type of entry"),
            };
        }
        if (width != @typeInfo(T).int.bits) @compileError("concatMany: total width mismatch");
    }

    // Calculate the result.
    comptime var cur_width = 0;
    var result: T = 0;
    comptime var index = fields.len;
    inline while (index > 0) : (index -= 1) {
        const field = fields[index - 1];
        const val = @field(args, field.name);
        const val_width = switch (@typeInfo(field.type)) {
            .int => |t| t.bits,
            else => @compileError("concatMany: invalid type of entry"),
        };
        result |= @as(T, val) << cur_width;
        cur_width += val_width;
    }

    return result;
}

/// Set the nth bit in the integer.
///
/// - `T`  : Type of the integer.
/// - `val`: The integer to set nth bit.
/// - `nth`: The bit position to set.
pub inline fn set(T: type, val: T, comptime nth: anytype) T {
    return val | tobit(T, nth);
}

/// Unset the nth bit in the integer.
///
/// - `T`  : Type of the integer.
/// - `val`: The integer to unset nth bit.
/// - `nth`: The bit position to unset.
pub inline fn unset(T: type, val: T, comptime nth: anytype) T {
    return val & ~tobit(T, nth);
}

/// Embed a `value` into `n` at the specified `offset`.
///
/// - `n`: The original integer.
/// - `value`: The value to embed. Can be any type whose size is the power of two and smaller than or equal to 8 bytes.
/// - `offset`: The bit offset to embed the value.
pub fn embed(n: anytype, value: anytype, comptime offset: usize) @TypeOf(n) {
    const size_n = @bitSizeOf(@TypeOf(n));
    const size_value = @bitSizeOf(@TypeOf(value));

    if (size_value + offset > size_n) {
        @compileError(std.fmt.comptimePrint(
            "embed: offset out of range: {s}, {s}, {d}",
            .{ @typeName(@TypeOf(n)), @typeName(@TypeOf(value)), offset },
        ));
    }

    const N = @TypeOf(n);
    const V = @TypeOf(value);
    const RepN = RepInt(N);
    const RepV = RepInt(V);

    var result: RepN = @bitCast(n);
    const rep_value: RepV = @bitCast(value);

    result &= ~@as(RepN, std.math.maxInt(RepV) << offset);
    result |= @as(RepN, rep_value) << offset;
    return @bitCast(result);
}

/// Extract a value of type `T`  from `value` at the specified `offset`.
///
/// - `T`: The type of the value to extract.
/// - `value`: The value to extract from. Can be any type whose size is the power of two and smaller than or equal to 8 bytes.
/// - `offset`: The bit offset to extract the value.
pub fn extract(T: type, value: anytype, comptime offset: usize) T {
    const size_T = @bitSizeOf(T);
    const size_value = @bitSizeOf(@TypeOf(value));

    if (size_T + offset > size_value) {
        @compileError(std.fmt.comptimePrint(
            "extract: offset out of range: {s}, {s}, {d}",
            .{ @typeName(T), @typeName(@TypeOf(value)), offset },
        ));
    }

    const RepV = RepInt(@TypeOf(value));
    const RepT = RepInt(T);

    const rep_value: RepV = @bitCast(value);
    const t: RepT = @truncate(rep_value >> offset);
    return @bitCast(t);
}

/// Get the representative integer type.
fn RepInt(T: type) type {
    return switch (@sizeOf(T)) {
        1 => u8,
        2 => u16,
        4 => u32,
        8 => u64,
        else => @compileError(std.fmt.comptimePrint(
            "Invalid argument to RepInt: {s}",
            .{@typeName(T)},
        )),
    };
}

// =============================================================
// Tests
// =============================================================

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

test "embed" {
    const S = packed struct(u64) {
        a: u8,
        b: u8,
        c: u16,
        d: u32,
    };
    const s = S{ .a = 0x12, .b = 0x21, .c = 0x3456, .d = 0x789ABCDE };

    try testing.expectEqual(
        S{ .a = 0xFF, .b = 0x21, .c = 0x3456, .d = 0x789ABCDE },
        embed(s, @as(u8, 0xFF), 0),
    );
    try testing.expectEqual(
        S{ .a = 0x12, .b = 0xFF, .c = 0x3456, .d = 0x789ABCDE },
        embed(s, @as(u8, 0xFF), 8),
    );
    try testing.expectEqual(
        S{ .a = 0x12, .b = 0x21, .c = 0xFF, .d = 0x789ABCDE },
        embed(s, @as(u16, 0xFF), 16),
    );
    try testing.expectEqual(
        S{ .a = 0x12, .b = 0x21, .c = 0x3456, .d = 0xFFFFFFFF },
        embed(s, @as(u32, 0xFFFFFFFF), 32),
    );

    try testing.expectEqual(
        S{ .a = 0x12, .b = 0x21, .c = 0x3456, .d = 0x789A_FFFF },
        embed(s, @as(u16, 0xFFFF), 32),
    );
    try testing.expectEqual(
        S{ .a = 0x12, .b = 0x21, .c = 0x3456, .d = 0xFFFF_BCDE },
        embed(s, @as(u16, 0xFFFF), 48),
    );
    try testing.expectEqual(
        S{ .a = 0x12, .b = 0xFF, .c = 0xEEDD, .d = 0x789ABCCC },
        embed(s, @as(u32, 0xCCEEDDFF), 8),
    );
}

test "extract" {
    const S = packed struct(u64) {
        a: u8,
        b: u8,
        c: u16,
        d: u32,
    };
    const s = S{ .a = 0x12, .b = 0x21, .c = 0x3456, .d = 0x789ABCDE };

    try testing.expectEqual(@as(u8, 0x12), extract(u8, s, 0));
    try testing.expectEqual(@as(u8, 0x21), extract(u8, s, 8));
    try testing.expectEqual(@as(u16, 0x3456), extract(u16, s, 16));
    try testing.expectEqual(@as(u32, 0x789ABCDE), extract(u32, s, 32));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
