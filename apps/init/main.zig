pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main() noreturn {
    log.info("Hello, from userland!", .{});
    log.info("Address of main: 0x{X}", .{@intFromPtr(&main)});

    testDevNull() catch |err| {
        log.err("Failed to test /dev/null: {s}", .{@errorName(err)});
    };
    testDevZero() catch |err| {
        log.err("Failed to test /dev/zero: {s}", .{@errorName(err)});
    };

    @panic("Reached end of main. panic");
}

// =============================================================
// Tests
// =============================================================

/// Test /dev/null behavior.
fn testDevNull() !void {
    var buffer: [64]u8 = undefined;

    const flags = std.fs.File.OpenFlags{
        .mode = .read_write,
    };
    const file = try std.fs.openFileAbsolute(
        "/dev/null",
        flags,
    );
    defer file.close();

    // Test read.
    const n_read = try file.read(buffer[0..]);
    try testing.expectEqual(0, n_read);

    // Test write.
    const data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const n_write = try file.write(data[0..]);
    try testing.expectEqual(data.len, n_write);

    // Open again.
    const file2 = try std.fs.openFileAbsolute(
        "/dev/null",
        flags,
    );
    defer file2.close();

    const n_read2 = try file2.read(buffer[0..]);
    try testing.expectEqual(0, n_read2);
}

/// Test /dev/zero behavior.
fn testDevZero() !void {
    var buffer: [64]u8 = undefined;

    const flags = std.fs.File.OpenFlags{
        .mode = .read_write,
    };
    const file = try std.fs.openFileAbsolute(
        "/dev/zero",
        flags,
    );
    defer file.close();

    // Test read.
    const n_read = try file.read(buffer[0..]);
    try testing.expectEqual(buffer.len, n_read);
    for (buffer) |c| {
        try testing.expectEqual(0, c);
    }

    // Test write.
    const data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const n_write = try file.write(data[0..]);
    try testing.expectEqual(data.len, n_write);

    // Open /dev/null at the same time.
    try testDevNull();
}

// =============================================================
// Panic
// =============================================================

pub fn panic(msg: []const u8, _: ?*builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);

    log.err("PANIC: {s}", .{msg});

    std.posix.exit(99);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = std.builtin;
const log = std.log.scoped(.user);
const testing = std.testing;
