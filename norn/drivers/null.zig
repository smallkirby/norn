const null_dev = CharDev{
    .name = "null",
    .type = .{ .major = 1, .minor = 3 },
    .fops = fops,
};

const fops = fs.File.Ops{
    .iterate = iterate,
    .read = read,
    .write = write,
};

comptime {
    device.staticRegisterDevice(init, "null");
}

/// Module init function.
fn init() callconv(.c) void {
    device.registerCharDev(null_dev) catch |err| {
        std.log.err("Failed to register null device: {s}", .{@errorName(err)});
    };
}

// =============================================================
// File operations
// =============================================================

fn iterate(file: *fs.File, allocator: Allocator) fs.FsError![]fs.File.IterResult {
    _ = file;
    _ = allocator;

    norn.unimplemented("null.iterate");
}

/// Empty read operation.
fn read(_: *fs.File, _: []u8, _: fs.Offset) fs.FsError!usize {
    return 0;
}

/// Empty write operation.
fn write(_: *fs.File, buffer: []const u8, _: fs.Offset) fs.FsError!usize {
    return buffer.len;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const fs = norn.fs;
const device = norn.device;
const CharDev = device.CharDev;
