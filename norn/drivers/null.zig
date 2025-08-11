const null_dev = CharDev{
    .name = "null",
    .type = .{ .major = 1, .minor = 3 },
    .fops = &fops,
};

const fops = fs.Fops{
    .read = read,
    .write = write,
};

/// Module init function.
fn init() callconv(.c) void {
    device.registerCharDev(null_dev) catch |err| {
        std.log.err("Failed to register null device: {s}", .{@errorName(err)});
    };
}

/// Empty read operation.
fn read(_: *fs.Inode, _: []u8, _: usize) fs.FsError!usize {
    return 0;
}

/// Empty write operation.
fn write(_: *fs.Inode, _: []const u8, _: usize) fs.FsError!usize {
    return 0;
}

comptime {
    device.staticRegisterDevice(init, "/dev/null");
}

// =============================================================
// Imports
// =============================================================
const std = @import("std");

const norn = @import("norn");
const fs = norn.fs;
const device = norn.device;
const CharDev = device.CharDev;
