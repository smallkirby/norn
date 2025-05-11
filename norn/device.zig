//! You can register a module's init function by:
//!
//! ```zig
//! comptime {
//!    staticRegisterDevice(fn1, "fn1");
//! }
//! ```
//!
//! For device major and minor numbers, see https://www.kernel.org/doc/Documentation/admin-guide/devices.txt .

pub const DeviceError = error{
    /// File operation failed.
    FileOperationFailed,
} || DevFs.DevFsError || fs.FsError;

/// Signature of init functions.
const ModuleInit = *const fn () callconv(.c) void;
/// Start address of the init functions array.
extern const __module_init_start: *void;
/// End address of the init functions array.
extern const __module_init_end: *void;
/// Section name where array of pointers to init functions is placed.
const init_section = ".module.init";

/// Initialize the module system.
pub fn init() DeviceError!void {
    // Call registered init functions.
    const array_len = (@intFromPtr(&__module_init_end) - @intFromPtr(&__module_init_start)) / @sizeOf(ModuleInit);
    const initcalls_ptr: [*]const ModuleInit = @alignCast(@ptrCast(&__module_init_start));
    log.debug("Calling {} module init functions", .{array_len});
    for (initcalls_ptr[0..array_len]) |initcall| {
        initcall();
    }

    // Create /dev directory.
    _ = try fs.createDirectory("/dev", .{
        .other = .rx,
        .group = .rx,
        .user = .rwx,
        .type = .directory,
    });
    const devfs = try DevFs.new(allocator);
    try fs.mount("/dev", devfs.filesystem());
}

/// Register a init function for module.
///
/// NOTE: `name` is just to prevent name collision.
/// If we can achieve a global comptime counter, it'd be preferable.
pub fn staticRegisterDevice(comptime f: ModuleInit, name: []const u8) void {
    if (!norn.is_test) {
        @export(&f, .{
            .name = std.fmt.comptimePrint("initcall_{s}", .{name}),
            .linkage = .strong,
            .section = init_section,
            .visibility = .default,
        });
    }
}

// =============================================================
// Test
// =============================================================

comptime {
    if (norn.is_test) {
        @export(&.{}, .{ .name = "__module_init_start" });
        @export(&.{}, .{ .name = "__module_init_end" });
    }
}

// =============================================================
// Imports
// =============================================================
const std = @import("std");
const log = std.log.scoped(.device);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const fs = norn.fs;
const allocator = norn.mem.general_allocator;

const DevFs = @import("fs/DevFs.zig");
