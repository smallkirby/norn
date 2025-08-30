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
} || fs.FsError;

/// Device number type.
pub const Number = packed struct(u64) {
    /// Minor number.
    minor: u20,
    /// Major number.
    major: u44,

    pub const zero = Number{ .minor = 0, .major = 0 };
};

/// Signature of init functions.
const ModuleInit = *const fn () callconv(.c) void;
/// Start address of the init functions array.
extern const __module_init_start: *void;
/// End address of the init functions array.
extern const __module_init_end: *void;
/// Section name where array of pointers to init functions is placed.
const init_section = ".module.init";

/// Instance of DevFs.
var devfs: *DevFs = undefined;

/// Initialize the module system.
pub fn init() DeviceError!void {
    // Open "/dev".
    const open_flags = fs.OpenFlags{
        .mode = .read_write,
        .create = true,
    };
    const open_mode = fs.Mode{ .type = .dir };
    const dev_file = try fs.openFile("/dev", open_flags, open_mode);

    // Mount devfs on "/dev".
    const devfs_path = try fs.mountTo(dev_file.path, "devfs", null);
    // TODO: should not do this outside DevFs impl.
    devfs = @ptrCast(@alignCast(devfs_path.dentry.inode.sb.ctx));

    // Call registered init functions.
    const array_len = (@intFromPtr(&__module_init_end) - @intFromPtr(&__module_init_start)) / @sizeOf(ModuleInit);
    const initcalls_ptr: [*]const ModuleInit = @ptrCast(@alignCast(&__module_init_start));
    log.debug("Calling {} module init functions", .{array_len});
    for (initcalls_ptr[0..array_len]) |initcall| {
        initcall();
    }
}

/// Register a init function for module.
///
/// Init function is ensured to be called after `/dev` is created.
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

/// Character device.
pub const CharDev = struct {
    /// Device name.
    name: []const u8,
    /// Device major and minor numbers.
    type: Number,
    /// File operations.
    fops: fs.File.Ops,
};

// Register a character device.
pub fn registerCharDev(dev: CharDev) fs.FsError!void {
    try devfs.registerCharDev(dev);
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
const DevFs = norn.fs.DevFs;

const allocator = norn.mem.general_allocator;
