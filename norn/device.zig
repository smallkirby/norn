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

/// Character device.
pub const CharDev = struct {
    /// Device name.
    name: []const u8,
    /// Device major and minor numbers.
    type: Number,
    /// File operations.
    fops: fs.File.Ops,
};

/// DevFs filesystem type.
pub const devfs_fs = DevFs.devfs_fs;

/// Signature of init functions.
const ModuleInit = *const fn () callconv(.c) void;
/// Start address of the init functions array.
extern const __module_init_start: *void;
/// End address of the init functions array.
extern const __module_init_end: *void;
/// Section name where array of pointers to init functions is placed.
const init_section = ".module.init";

/// List type of character devices.
const CharDevList = std.AutoHashMap(Number, CharDevNode);

/// Pair of character device and its inode.
const CharDevNode = struct {
    /// inode.
    inode: *Inode,
    /// Character device.
    dev: CharDev,
};

/// Instance of DevFs.
var devfs: *DevFs = undefined;
/// List of character devices.
var char_devs: CharDevList = .init(allocator);

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
    devfs = DevFs.getDevfs(devfs_path);

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

/// Register a character device.
pub fn registerCharDev(dev: CharDev) fs.FsError!void {
    try devfs.registerCharDev(dev);
}

/// Device filesystem.
const DevFs = struct {
    const Self = @This();
    const DevFs = Self;
    const Error = fs.FsError;

    pub const devfs_fs = FileSystem{
        .name = "devfs",
        .mount = mount,
        .unmount = unmount,
    };

    const sb_ops = SuperBlock.Ops{};

    const file_ops = File.Ops{
        .iterate = iterate,
        .read = read,
        .write = write,
    };

    const inode_ops = Inode.Ops{
        .lookup = lookup,
        .create = create,
    };

    /// Memory allocator used by this FS.
    allocator: Allocator,
    /// Spin lock.
    lock: SpinLock,
    /// Super block.
    sb: *SuperBlock,
    /// Next inode number to allocate.
    inum_next: Inode.Number = 0,

    // =============================================================
    // Filesystem operations
    // =============================================================

    fn mount(_: ?*const anyopaque, alc: Allocator) Error!*SuperBlock {
        const sb = try alc.create(SuperBlock);
        errdefer alc.destroy(sb);

        // Init self.
        const self = try alc.create(Self);
        errdefer alc.destroy(self);
        self.* = .{
            .allocator = alc,
            .lock = SpinLock{},
            .sb = sb,
        };

        // Init root dentry.
        const root_inode = try self.createInode();
        root_inode.mode = .{
            .other = .rx,
            .group = .rx,
            .user = .rwx,
            .flags = .none,
            .type = .dir,
        };
        const root_dentry = try self.createDentry(root_inode);

        // Init superblock.
        sb.* = .{
            .root = root_dentry,
            .ops = sb_ops,
            .ctx = @ptrCast(self),
        };

        return sb;
    }

    fn unmount() Error!void {
        norn.unimplemented("DevFs.unmount");
    }

    // =============================================================
    // File operations
    // =============================================================

    fn iterate(file: *File, alc: Allocator) Error![]File.IterResult {
        if (file.inode != devfs.sb.root.inode) {
            return &.{};
        }
        const children = char_devs;
        const num_children = children.count();

        const results = try alc.alloc(File.IterResult, num_children);
        errdefer alc.free(results);

        var iter = children.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            const child = entry.value_ptr;
            results[i] = .{
                .name = child.dev.name,
                .inum = child.inode.number,
                .type = child.inode.mode.type,
            };
        }

        return results;
    }

    fn read(file: *File, buf: []u8, pos: fs.Offset) Error!usize {
        _ = file;
        _ = buf;
        _ = pos;

        norn.unimplemented("DevFs.read()");
    }

    fn write(file: *File, buf: []const u8, pos: fs.Offset) Error!usize {
        _ = file;
        _ = buf;
        _ = pos;

        norn.unimplemented("DevFs.write()");
    }

    // =============================================================
    // Inode operations
    // =============================================================

    fn lookup(dir: *Inode, name: []const u8) Error!?*Inode {
        if (dir != devfs.sb.root.inode) {
            return Error.InvalidArgument;
        }

        var iter = char_devs.iterator();
        while (iter.next()) |dev| {
            const char = dev.value_ptr;
            if (std.mem.eql(u8, char.dev.name, name)) {
                return char.inode;
            }
        } else {
            return null;
        }
    }

    fn create(dir: *Inode, name: []const u8, mode: Mode) Error!*Inode {
        _ = dir;
        _ = name;
        _ = mode;

        norn.unimplemented("RamFs.create");
    }

    // =============================================================
    // API
    // =============================================================

    /// TODO: rename
    /// TODO: refactor
    pub fn registerCharDev(self: *Self, char: CharDev) Error!void {
        const inode = try self.createInode();
        inode.mode = .{ .type = .char };
        inode.devnum = char.type;
        inode.fops = char.fops;

        const info = CharDevNode{
            .inode = inode,
            .dev = char,
        };
        try char_devs.put(char.type, info);
        self.sb.root.inode.size += 1;
    }

    /// Get DevFs instance from a given path.
    ///
    /// Given `path` must belong to a DevFs, otherwise the return value is undefined.
    pub inline fn getDevfs(path: fs.Path) *Self {
        return @ptrCast(@alignCast(path.dentry.inode.sb.ctx));
    }

    // =============================================================
    // Utilities
    // =============================================================

    /// Get self from inode.
    inline fn getSelf(inode: *Inode) *Self {
        return @ptrCast(@alignCast(inode.ctx));
    }

    /// Create a new inode.
    ///
    /// All variable entries are zero initialized.
    fn createInode(self: *Self) Error!*Inode {
        const ie = self.lock.lockDisableIrq();
        defer self.lock.unlockRestoreIrq(ie);

        const inum = self.inum_next;
        self.inum_next += 1;

        const inode = try self.allocator.create(Inode);
        errdefer self.allocator.destroy(inode);
        inode.* = std.mem.zeroInit(Inode, .{
            .number = inum,
            .ops = inode_ops,
            .fops = file_ops,
            .sb = self.sb,
        });
        return inode;
    }

    /// Create a new dentry for the given inode.
    ///
    /// All variable entries are zero initialized.
    fn createDentry(self: *Self, inode: *Inode) Error!*Dentry {
        const dentry = try self.allocator.create(Dentry);
        errdefer self.allocator.destroy(dentry);

        dentry.* = std.mem.zeroInit(Dentry, .{
            .inode = inode,
        });

        return dentry;
    }
};

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
const SpinLock = norn.SpinLock;
const Dentry = fs.Dentry;
const File = fs.File;
const FileSystem = fs.FileSystem;
const Inode = fs.Inode;
const Mode = fs.Mode;
const SuperBlock = fs.SuperBlock;

const allocator = norn.mem.general_allocator;
