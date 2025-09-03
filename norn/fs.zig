/// FS Error.
pub const FsError = error{
    /// File already exists.
    AlreadyExists,
    /// The file descriptor is invalid.
    BadFileDescriptor,
    /// No available file descriptor in pool.
    DescriptorFull,
    /// Invalid argument.
    InvalidArgument,
    /// Operation for regular file only is called on a non-regular file.
    IsDirectory,
    /// Operation for directory only is called on a non-directory.
    NotDirectory,
    /// File not found.
    NotFound,
    /// Failed to allocate memory.
    OutOfMemory,
    /// Calculation result overflowed or underflowed.
    Overflow,
    /// Not implemented or not supported.
    Unimplemented,
};

pub const sys = @import("fs/sys.zig");
pub const Dentry = @import("fs/Dentry.zig");
pub const Inode = @import("fs/Inode.zig");
pub const File = @import("fs/File.zig");
pub const FileSystem = @import("fs/FileSystem.zig");
pub const Mount = @import("fs/Mount.zig");
pub const ThreadFs = @import("fs/ThreadFs.zig");
pub const DevFs = @import("fs/DevFs.zig");

/// Path separator.
pub const separator = '/';
/// Maximum path length.
pub const path_max = 4096;

/// Offset type.
pub const Offset = i64;

/// Describes an open file.
pub const FileDescriptor = enum(i32) {
    /// Standard input.
    stdin = 0,
    /// Standard output.
    stdout = 1,
    /// Standard error.
    stderr = 2,

    /// Current working directory.
    cwd = -100,

    _,

    /// Check if the file descriptor is a special descriptor.
    pub fn isSpecial(self: FileDescriptor) bool {
        return switch (self) {
            .stdin, .stdout, .stderr, .cwd => true,
            else => false,
        };
    }

    /// Get a backing integer.
    pub inline fn value(self: FileDescriptor) i32 {
        return @intFromEnum(self);
    }
};

/// File information including file type, access permission, and other special bits.
///
/// POSIX-compatible.
pub const Mode = packed struct(u32) {
    /// Access permission for others.
    other: Permission = .rwx,
    /// Access permission for a group.
    group: Permission = .rwx,
    /// Access permission for a user.
    user: Permission = .rwx,
    /// Special flags.
    flags: Flags = .none,
    /// File type.
    type: FileType,
    /// Reserved.
    _reserved: u16 = 0,

    pub const Flags = packed struct(u3) {
        /// Sticky bit.
        sticky: bool,
        /// Set Group ID.
        sgid: bool,
        /// Set User ID.
        suid: bool,

        pub const none = Flags{ .sticky = false, .sgid = false, .suid = false };
    };

    /// Convert u32 into `Mode`.
    pub fn from(mode: u32) Mode {
        return @bitCast(mode);
    }
};

/// Unique file path.
///
/// The pair of dentry and mount information can uniquely identify a file in a system.
pub const Path = struct {
    /// Dentry of the path.
    dentry: *Dentry,
    /// Mount information that the dentry is associated with.
    mount: *Mount,
};

/// Stat information.
///
/// POSIX-compatible.
pub const Stat = packed struct {
    /// Device ID of device containing the file.
    devnum: device.Number,
    /// File serial number.
    inode: u64,
    /// Number of hard links.
    num_links: u64,

    /// File mode.
    mode: Mode,
    /// User ID of the file.
    uid: u32,
    /// Group ID of the file.
    gid: u32,
    /// Reserved.
    _reserved0: u32 = 0,

    /// Device ID (if the file is a special file).
    rdev: device.Number,
    /// Size of the file.
    size: usize,
    /// Preferred block size for file system I/O.
    block_size: usize,
    /// Number of blocks allocated for this object.
    num_blocks: usize,

    /// Time of last access.
    access_time: TimeSpec,
    /// Time of last modification.
    modify_time: TimeSpec,
    /// Time of last status change (including content change).
    change_time: TimeSpec,

    /// Reserved.
    _reserved1: u64 = 0,
    /// Reserved.
    _reserved2: u64 = 0,
    /// Reserved.
    _reserved3: u64 = 0,

    comptime {
        norn.comptimeAssert(
            @bitSizeOf(Stat) == 144 * 8,
            "Stat size is incorrect: {d} (bit: {d})",
            .{ @sizeOf(Stat), @bitSizeOf(Stat) },
        );
    }
};

/// Open mode.
pub const OpenMode = enum {
    /// Open the file in read-only mode.
    read_only,
    /// Open the file in write-only mode.
    write_only,
    /// Open the file in read/write mode.
    read_write,
};

/// Flags for opening a file.
pub const OpenFlags = struct {
    const Self = @This();

    /// Mode to open the file.
    mode: OpenMode = .read_only,
    /// Create a new file if it does not exist.
    create: bool = false,

    /// Read write mode. Create a new file if it does not exist.
    pub const create_rw = Self{
        .mode = .read_write,
        .create = true,
    };
};

/// Access permission for a single target.
pub const Permission = packed struct(u3) {
    read: bool,
    write: bool,
    exec: bool,

    pub const ro = Permission{ .read = true, .write = false, .exec = false };
    pub const rw = Permission{ .read = true, .write = true, .exec = false };
    pub const rx = Permission{ .read = true, .write = false, .exec = true };
    pub const rwx = Permission{ .read = true, .write = true, .exec = true };
};

/// File type.
///
/// POSIX-compatible.
pub const FileType = enum(u4) {
    /// Named pipe or FIFO.
    fifo = 1,
    /// Character special device.
    char = 2,
    /// Directory.
    dir = 4,
    /// Block special device.
    blk = 6,
    /// Regular file.
    regular = 8,
    /// Symbolic link.
    symlink = 10,
    /// Socket.
    socket = 12,

    _,
};

/// The origin of the path lookup.
pub const LookupOrigin = union(enum) {
    /// Lookup path from CWD.
    cwd: void,
    /// Lookup path from the given directory.
    path: Path,

    pub const origin_cwd = LookupOrigin{ .cwd = {} };
};

// =============================================================
// Global variables
// =============================================================

/// Hash map type to associate the path of a mount point with its mount structure.
const MountHashTable = std.AutoHashMap(Path, *Mount);
/// All mount points.
var mount_table: MountHashTable = .init(allocator);
/// Dentry cache.
var dentry_cache = Dentry.Store.new(allocator);

/// Registered filesystem types.
const registered_fs_types = [_]FileSystem{
    DevFs.devfs_fs,
    RamFs.ramfs_fs,
};

// =============================================================
// Functions
// =============================================================

/// Initialize filesystem by loading the initramfs image.
///
/// This function sets the root and CWD of the current task to the initialized FS.
/// Caller can free the `initimg` memory after this function returns.
pub fn init(initimg: []const u8) FsError!void {
    norn.rtt.expectEqual(0, sched.getCurrentTask().tid);

    const fs_type = findFilesystem("ramfs") orelse {
        @panic("Failed to find 'ramfs' to initialize a filesystem.");
    };
    const init_option = RamFs.InitOption{
        .image = initimg,
    };
    const root_sb = try fs_type.mount(
        @ptrCast(&init_option),
        allocator,
    );

    const mount = try allocator.create(Mount);
    errdefer allocator.destroy(mount);
    mount.* = .{
        .root = root_sb.root,
        .parent = null,
        .mntpoint = root_sb.root,
        .sb = root_sb,
    };

    const path = Path{ .dentry = root_sb.root, .mount = mount };
    try mount_table.put(path, mount);
    try dentry_cache.put(root_sb.root);

    // Set root and CWD.
    sched.getCurrentTask().fs.setRoot(path);
    sched.getCurrentTask().fs.setCwd(path);
}

/// Open a file by path.
///
/// This function tries to open a file by the given path.
/// Returns a file instance if the file is found or created.
///
/// Note that this function does not add the file to the descriptor table.
pub fn openFile(path: []const u8, flags: OpenFlags, mode: ?Mode) FsError!*File {
    return openFileAt(.cwd, path, flags, mode);
}

/// Open a file by path.
///
/// This function tries to open a file by the given path.
/// Returns a file instance if the file is found or created.
///
/// Note that this function does NOT add the file to the descriptor table.
pub fn openFileAt(fd: FileDescriptor, pathname: []const u8, flags: OpenFlags, mode: ?Mode) FsError!*File {
    const origin = blk: {
        if (isAbsolutePath(pathname)) {
            break :blk getCwd();
        } else {
            break :blk getPathFromFd(fd) orelse return FsError.BadFileDescriptor;
        }
    };

    // Get a dentry from the path.
    const path = if (lookup(.{ .path = origin }, pathname)) |path| path else blk: {
        // Try to create the file.
        if (!flags.create) {
            return FsError.NotFound;
        }
        if (mode == null) {
            return FsError.InvalidArgument;
        }

        const resolve_result = try resolvePath(origin, pathname);
        if (resolve_result.parent == null) {
            return FsError.NotFound;
        }

        const new = try create(
            resolve_result.parent.?,
            basename(pathname),
            mode.?,
        );
        try dentry_cache.put(new);

        const path = Path{ .dentry = new, .mount = origin.mount };
        break :blk path;
    };

    // Create a file instance.
    return try File.new(mntdown(path), allocator);
}

/// Close the open file.
pub fn close(file: *File) void {
    file.deinit();
}

/// Create a file in the given directory.
///
/// - `dir`: The directory to create the file in.
/// - `name`: The name of the file.
/// - `mode`: The mode of the file.
///
/// Returns the created dentry or an error.
/// Created file is not open.
pub fn create(dir: Path, name: []const u8, mode: Mode) FsError!*Dentry {
    const inode = switch (dir.dentry.inode.mode.type) {
        .regular => try dir.dentry.inode.createFile(name, mode),
        .dir => try dir.dentry.inode.createDirectory(name, mode),
        else => return FsError.Unimplemented,
    };

    const dentry = try allocator.create(Dentry);
    errdefer allocator.destroy(dentry);
    dentry.* = .{
        .inode = inode,
        .name = name,
        .parent = dir.dentry,
    };

    return dentry;
}

/// TODO: implement
pub fn write(file: *File, buf: []const u8) FsError!usize {
    _ = file;
    _ = buf;
    norn.unimplemented("fs.write");
}

/// Get a file status information of the given file.
pub fn stat(inode: *Inode) Stat {
    return Stat{
        .devnum = inode.devnum,
        .inode = inode.number,
        .num_links = 1, // TODO
        .mode = inode.mode,
        .uid = inode.uid,
        .gid = inode.gid,
        .rdev = .zero, // TODO
        .size = inode.size,
        .block_size = 0, // TODO
        .num_blocks = 0, // TODO
        .access_time = inode.access_time,
        .modify_time = inode.modify_time,
        .change_time = inode.change_time,
    };
}

/// Get a file status information of the given path.
///
/// The given `dir` is the directory to start the lookup if the path is not absolute.
pub fn statAt(dir: Path, path: []const u8) FsError!Stat {
    const resolved = try resolvePath(dir, path);
    if (resolved.path) |p| {
        return stat(p.dentry.inode);
    } else {
        return FsError.NotFound;
    }
}

/// Lookup a file by path.
///
/// This function searches the given directory for a file.
/// This function can take a path string with more than one level of depth.
///
/// If it encounters a component that does not exist, the search stops and returns null.
/// For example, `dne/..` will fail if `dne` does not exist.
pub fn lookup(origin: LookupOrigin, path: []const u8) ?Path {
    const dir = switch (origin) {
        .cwd => getCwd(),
        .path => |p| p,
    };

    const result = resolvePath(dir, path) catch return null;
    return result.path;
}

/// Mount a filesystem to a directory.
///
/// - `to`: Path to the mount point.
/// - `name`: Name of the filesystem type.
/// - `data`: Optional data to pass to the filesystem.
pub fn mountTo(to: Path, name: []const u8, data: ?*anyopaque) FsError!Path {
    const fs_type = findFilesystem(name) orelse return FsError.NotFound;
    const root_sb = try fs_type.mount(data, allocator);

    const mount = try allocator.create(Mount);
    errdefer allocator.destroy(mount);
    mount.* = .{
        .root = root_sb.root,
        .parent = to.mount,
        .mntpoint = to.dentry,
        .sb = root_sb,
    };

    try mount_table.put(to, mount);
    try dentry_cache.put(root_sb.root);

    return Path{ .dentry = root_sb.root, .mount = mount };
}

/// Check if the path is absolute.
pub fn isAbsolutePath(path: []const u8) bool {
    return std.fs.path.isAbsolute(path);
}

/// Get the dentry from the file descriptor.
pub fn getPathFromFd(fd: FileDescriptor) ?Path {
    return getCurrentFdTable().getPath(fd);
}

/// Get the file from the file descriptor.
pub fn getFile(fd: FileDescriptor) ?*File {
    return getCurrentFdTable().get(fd);
}

/// Put the file into the file descriptor table.
pub fn putFile(file: *File) FsError!FileDescriptor {
    return try getCurrentFdTable().put(file);
}

/// Close the file descriptor.
///
/// If there's no reference to the open file, this function also closes the file.
///
/// TODO: Check if there're no references to the file.
pub fn closeFd(fd: FileDescriptor) FsError!void {
    return getCurrentFdTable().remove(fd);
}

/// Get the file descriptor table of the current task.
pub fn getCurrentFdTable() *FdTable {
    return &sched.getCurrentTask().fs.fdtable;
}

/// Get current working directory of the current task.
pub fn getCwd() Path {
    return sched.getCurrentTask().fs.cwd;
}

/// Get root directory of the current task.
pub fn getRoot() Path {
    return sched.getCurrentTask().fs.root;
}

/// Get a basename of the path.
pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

// =============================================================
// Utility
// =============================================================

/// Get the registered filesystem type.
fn findFilesystem(name: []const u8) ?FileSystem {
    for (registered_fs_types) |fs| {
        if (std.mem.eql(u8, fs.name, name)) {
            return fs;
        }
    } else {
        return null;
    }
}

/// Follows the mount chain downwards.
///
/// If the directory is a mount point, return the root of the mounted filesystem.
/// Otherwise, return the given path itself.
fn mntdown(path: Path) Path {
    if (mount_table.get(path)) |mount| {
        return Path{
            .dentry = mount.root,
            .mount = mount,
        };
    } else {
        return path;
    }
}

/// Follows the mount chain upwards.
///
/// If the directory is mounted to parent filesystem, return the dentry of the parent FS.
/// Otherwise, return the dentry itself.
fn mntup(path: Path) Path {
    if (path.dentry.parent) |_| {
        return path;
    } else {
        return Path{
            .dentry = path.mount.mntpoint,
            .mount = path.mount.parent orelse path.mount, // orelse is root directory
        };
    }
}

/// Result of path resolution.
const PathResult = struct {
    /// Resolved dentry.
    ///
    /// Null if the path is not found.
    path: ?Path,
    /// Second-to-last path component.
    ///
    /// null if the component is not found.
    ///
    /// Note that this dentry is not necessarily the parent of the resolved dentry.
    /// If this is null, result is also null.
    parent: ?Path,
};

/// Resolve the path string.
///
/// - origin: The dentry to start the search from. Ignored if the path is absolute.
/// - path: The path string to resolve.
fn resolvePath(origin: Path, path: []const u8) FsError!PathResult {
    var result = PathResult{
        .path = null,
        .parent = origin,
    };

    var iter = ComponentIterator(.posix, u8).init(path) catch {
        return result;
    };
    var entry = if (isAbsolutePath(path)) getRoot() else origin;

    while (iter.next()) |component| {
        if (std.mem.eql(u8, component.name, ".")) {
            continue;
        }
        if (std.mem.eql(u8, component.name, "..")) {
            entry = followDotDot(entry);
            continue;
        }

        entry = mntdown(entry);
        const lookup_result = dlookup(entry.dentry, component.name) catch {
            // Error during lookup.
            return result;
        };
        if (lookup_result) |next| {
            const next_path = Path{
                .dentry = next,
                .mount = entry.mount,
            };
            // Child found.
            if (iter.peekNext() != null) result.parent = next_path;
            entry = next_path;
        } else {
            // Not found.
            return result;
        }
    }

    result.path = entry;
    return result;
}

/// Lookup a child dentry by name in the given parent directory.
///
/// If the child is cached, return it immediately.
/// If not, perform a lookup and create a new dentry.
fn dlookup(parent: *Dentry, name: []const u8) FsError!?*Dentry {
    if (dentry_cache.lookup(parent, name)) |entry| {
        return entry;
    } else {
        const inode = try parent.inode.lookup(name) orelse return null;

        // TODO: create a function to create a new dentry
        const dentry = try allocator.create(Dentry);
        dentry.* = .{
            .name = try allocator.dupe(u8, name),
            .parent = parent,
            .inode = inode,
        };
        try dentry_cache.put(dentry);

        return dentry;
    }
}

/// Get a parent of the given path.
///
/// If the path is a mount point, follow the tree of the original dentry.
fn followDotDot(path: Path) Path {
    const resolved = mntup(path);
    return Path{
        .dentry = resolved.dentry.parent orelse resolved.dentry,
        .mount = resolved.mount,
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.fs);
const Allocator = std.mem.Allocator;
const ComponentIterator = std.fs.path.ComponentIterator;

const norn = @import("norn");
const cpio = norn.cpio;
const device = norn.device;
const sched = norn.sched;
const syscall = norn.syscall;
const util = norn.util;
const TimeSpec = norn.time.TimeSpec;

const FdTable = @import("fs/FdTable.zig");
const RamFs = @import("fs/RamFs.zig");

const allocator = norn.mem.general_allocator;
