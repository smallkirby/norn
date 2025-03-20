//! This file provides a miscellaneous utilities.

/// Round up the value to the given alignment.
pub inline fn roundup(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

/// Round down the value to the given alignment.
pub inline fn rounddown(value: usize, alignment: usize) usize {
    return value & ~(alignment - 1);
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

// =======================================

const std = @import("std");
