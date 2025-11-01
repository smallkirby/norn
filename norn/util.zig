//! This file provides a miscellaneous utilities.

/// Check if the given value is aligned to the given alignment.
pub fn isAligned(value: anytype, alignment: usize) bool {
    const v = switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => @as(usize, value),
        .pointer => @intFromPtr(value),
        else => value,
    };
    return (v & (alignment - 1)) == 0;
}

/// Round up the value to the given alignment.
///
/// If the type of `value` is a comptime integer, it's regarded as `usize`.
pub inline fn roundup(value: anytype, alignment: @TypeOf(value)) @TypeOf(value) {
    const T = if (@typeInfo(@TypeOf(value)) == .comptime_int) usize else @TypeOf(value);
    return (value + alignment - 1) & ~@as(T, alignment - 1);
}

/// Round down the value to the given alignment.
///
/// If the type of `value` is a comptime integer, it's regarded as `usize`.
pub inline fn rounddown(value: anytype, alignment: @TypeOf(value)) @TypeOf(value) {
    const T = if (@typeInfo(@TypeOf(value)) == .comptime_int) usize else @TypeOf(value);
    return value & ~@as(T, alignment - 1);
}

/// Returns true if the lhs pointer is larger than or equal to the rhs pointer.
pub inline fn ptrGte(lhs: anytype, rhs: @TypeOf(lhs)) bool {
    return @intFromPtr(lhs) >= @intFromPtr(rhs);
}

/// Returns true if the lhs pointer is larger than the rhs pointer.
pub inline fn ptrGt(lhs: anytype, rhs: @TypeOf(lhs)) bool {
    return @intFromPtr(lhs) > @intFromPtr(rhs);
}

/// Returns true if the lhs pointer is less than or equal to the rhs pointer.
pub fn ptrLte(lhs: anytype, rhs: @TypeOf(lhs)) bool {
    return @intFromPtr(lhs) <= @intFromPtr(rhs);
}

/// Returns true if the lhs pointer is less than the rhs pointer.
pub fn ptrLt(lhs: anytype, rhs: @TypeOf(lhs)) bool {
    return @intFromPtr(lhs) < @intFromPtr(rhs);
}

/// Get the length of a sentineled string.
///
/// Returned size does not include the sentinel.
pub fn lenSentineled(data: [*:0]const u8) usize {
    var size: usize = 0;
    while (data[size] != 0) : (size += 1) {}
    return size;
}

/// Convert a sentineled string to a slice.
pub fn sentineledToSlice(data: [*:0]const u8) [:0]const u8 {
    return data[0..lenSentineled(data) :0];
}

// =======================================

const testing = std.testing;

test "isAligned" {
    try testing.expect(isAligned(0, 4));
    try testing.expect(!isAligned(1, 4));
    try testing.expect(!isAligned(2, 4));
    try testing.expect(!isAligned(3, 4));
    try testing.expect(isAligned(4, 4));
    try testing.expect(!isAligned(5, 4));
    try testing.expect(isAligned(0x1000, 0x1000));
    try testing.expect(!isAligned(0x1001, 0x1000));
}

test "roundup" {
    try testing.expectEqual(0, roundup(0, 4));
    try testing.expectEqual(4, roundup(1, 4));
    try testing.expectEqual(4, roundup(2, 4));
    try testing.expectEqual(4, roundup(3, 4));
    try testing.expectEqual(4, roundup(4, 4));
    try testing.expectEqual(8, roundup(5, 4));
    try testing.expectEqual(0x2000, roundup(0x1120, 0x1000));
    try testing.expectEqual(0x2000, roundup(0x1FFF, 0x1000));
}

test "rounddown" {
    try testing.expectEqual(0, rounddown(0, 4));
    try testing.expectEqual(0, rounddown(1, 4));
    try testing.expectEqual(0, rounddown(2, 4));
    try testing.expectEqual(0, rounddown(3, 4));
    try testing.expectEqual(4, rounddown(4, 4));
    try testing.expectEqual(4, rounddown(5, 4));
    try testing.expectEqual(0x1000, rounddown(0x1120, 0x1000));
    try testing.expectEqual(0x1000, rounddown(0x1FFF, 0x1000));
}

test "ptrGte" {
    var a: u32 = 5;
    var b: u32 = 3;
    try testing.expectEqual(false, ptrGte(&a, &b));
    try testing.expectEqual(true, ptrGte(&a, &a));
    try testing.expectEqual(true, ptrGte(&b, &a));
}

test "ptrGt" {
    var a: u32 = 5;
    var b: u32 = 3;
    try testing.expectEqual(false, ptrGt(&a, &b));
    try testing.expectEqual(false, ptrGt(&a, &a));
    try testing.expectEqual(true, ptrGt(&b, &a));
}

test "ptrLte" {
    var a: u32 = 5;
    var b: u32 = 3;
    try testing.expectEqual(true, ptrLte(&a, &b));
    try testing.expectEqual(true, ptrLte(&a, &a));
    try testing.expectEqual(false, ptrLte(&b, &a));
}

test "ptrLt" {
    var a: u32 = 5;
    var b: u32 = 3;
    try testing.expectEqual(true, ptrLt(&a, &b));
    try testing.expectEqual(false, ptrLt(&a, &a));
    try testing.expectEqual(false, ptrLt(&b, &a));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const norn = @import("norn");
