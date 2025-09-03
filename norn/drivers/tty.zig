const tty_dev = CharDev{
    .name = "tty",
    .type = .{ .major = 5, .minor = 0 },
    .fops = fops,
};

const fops = fs.File.Ops{
    .iterate = iterate,
    .read = read,
    .write = write,
};

comptime {
    device.staticRegisterDevice(init, "tty");
}

/// Module init function.
fn init() callconv(.c) void {
    device.registerCharDev(tty_dev) catch |err| {
        std.log.err("Failed to register TTY device: {s}", .{@errorName(err)});
    };
}

fn iterate(file: *fs.File, allocator: Allocator) fs.FsError![]fs.File.IterResult {
    _ = file;
    _ = allocator;

    norn.unimplemented("tty.iterate");
}

/// TODO: not implemented.
fn read(_: *fs.File, _: []u8, _: fs.Offset) fs.FsError!usize {
    norn.unimplemented("tty.read");
}

/// Write to serial console.
fn write(_: *fs.File, buffer: []const u8, _: fs.Offset) fs.FsError!usize {
    norn.getSerial().writeString(buffer);

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
