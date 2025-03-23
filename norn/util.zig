//! This file provides a miscellaneous utilities.

/// Round up the value to the given alignment.
pub inline fn roundup(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

/// Round down the value to the given alignment.
pub inline fn rounddown(value: usize, alignment: usize) usize {
    return value & ~(alignment - 1);
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

// =======================================

const testing = std.testing;

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
