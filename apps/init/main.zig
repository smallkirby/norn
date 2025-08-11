pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main() noreturn {
    log.info("Hello, from userland!", .{});
    log.info("Address of main: 0x{X}", .{@intFromPtr(&main)});

    testSyscall() catch |err| {
        log.err("Failed to test syscall: {s}", .{@errorName(err)});
    };

    testDevNull() catch |err| {
        log.err("Failed to test /dev/null: {s}", .{@errorName(err)});
    };

    @panic("Reached end of main. panic");
}

// =============================================================
// Tests
// =============================================================

fn testSyscall() !void {
    // TODO
}

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

    const n = try file.read(buffer[0..]);
    log.info("Read {d} bytes from /dev/null.", .{n});
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
