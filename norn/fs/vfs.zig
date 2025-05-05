/// VFS error.
pub const VfsError = error{
    /// File already exists.
    AlreadyExists,
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
};

/// Spin lock.
var lock: norn.SpinLock = .{};

/// Device type.
pub const DevType = packed struct(u64) {
    minor: u32,
    major: u32,

    pub const zero: DevType = .{ .minor = 0, .major = 0 };
};

/// Stat information.
pub const Stat = extern struct {
    /// Device ID of device containing the file.
    dev: DevType,
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
    rdev: DevType,
    /// Size of the file.
    size: usize,
    /// Preferred block size for file system I/O.
    block_size: usize,
    /// Number of blocks allocated for this object.
    num_blocks: usize,

    /// Time of last access.
    access_time: u64,
    access_time_nsec: u64,
    /// Time of last modification.
    modify_time: u64,
    modify_time_nsec: u64,
    /// Time of last status change.
    change_time: u64,
    change_time_nsec: u64,

    /// Reserved.
    _reserved1: u64 = 0,
    _reserved2: u64 = 0,
    _reserved3: u64 = 0,
};

/// Virtual filesystem.
pub const FileSystem = struct {
    /// Root directory of this filesystem.
    root: *Dentry,
    /// Backing filesystem instance.
    ctx: *anyopaque,
    /// Directory this mount point is mounted on.
    mounted_to: *Dentry,
};

/// Dentry that connects an inode with its name.
pub const Dentry = struct {
    const Self = @This();

    /// Filesystem this dentry belongs to.
    fs: *FileSystem,
    /// Inode this dentry points to.
    inode: *Inode,
    /// Parent directory.
    /// If there's no parent, it points to itself.
    parent: *Dentry,
    /// Name of this dentry.
    name: []const u8,
    /// Operations for this dentry.
    ops: *const Vtable,
    /// If null, this dentry is not a mount point.
    /// If not null, the filesystem to which this dentry is mounted.
    mounted_by: ?*FileSystem = null,

    /// Dentry operations.
    pub const Vtable = struct {
        /// Create a directory named `name` in this directory inode.
        ///
        /// If the directory is created successfully, return the dentry.
        createDirectory: *const fn (self: *Dentry, name: []const u8, mode: Mode) VfsError!*Dentry,
        /// Create a file named `name` in this directory inode.
        ///
        /// If the file is created successfully, return the dentry.
        createFile: *const fn (self: *Dentry, name: []const u8, mode: Mode) VfsError!*Dentry,
    };

    /// Create a directory named `name` in this directory inode.
    pub fn createDirectory(self: *Self, name: []const u8, mode: Mode) VfsError!*Dentry {
        const inode = self.inode;
        if (inode.inode_type != InodeType.directory) return VfsError.NotDirectory;

        return self.ops.createDirectory(self, name, mode);
    }

    /// Create a file named `name` in this directory inode.
    pub fn createFile(self: *Self, name: []const u8, mode: Mode) VfsError!*Dentry {
        const inode = self.inode;
        if (inode.inode_type != InodeType.directory) return VfsError.NotDirectory;

        return self.ops.createFile(self, name, mode);
    }
};

/// Inode type.
pub const InodeType = enum {
    /// Regular file
    file,
    /// Directory
    directory,
};

/// User ID.
pub const Uid = u32;
/// Group ID.
pub const Gid = u32;

/// Access permission for each access type.
pub const Permission = packed struct(u3) {
    read: bool,
    write: bool,
    exec: bool,

    pub const full = Permission{
        .read = true,
        .write = true,
        .exec = true,
    };

    pub const rwx = Permission{
        .read = true,
        .write = true,
        .exec = true,
    };

    pub const rw = Permission{
        .read = true,
        .write = true,
        .exec = false,
    };

    pub const ro = Permission{
        .read = true,
        .write = false,
        .exec = false,
    };
};

/// File type.
pub const FileType = enum(u8) {
    /// Unknown file type.
    unknown = 0o00,
    /// Named pipes or FIFOs.
    fifo = 0o01,
    /// Character special devices.
    cdev = 0o02,
    /// Directories.
    directory = 0o04,
    /// Block special files.
    block = 0o06,
    /// Regular files.
    regular = 0o10,
    /// Symbolic links.
    symlink = 0o12,
    /// Sockets.
    socket = 0o14,

    _,
};

/// File mode.
///
/// This struct is compatible with POSIX file mode.
pub const Mode = packed struct(u32) {
    /// Other permission.
    other: Permission,
    /// Group permission.
    group: Permission,
    /// User permission.
    user: Permission,
    /// Sticky bit.
    sticky: bool = false,
    /// SGID bit.
    sgid: bool = false,
    /// SUID bit.
    suid: bool = false,
    /// File type.
    type: FileType = .regular,
    /// Reserved.
    _reserved: u12 = 0,

    pub const anybody_full = Mode{
        .user = .full,
        .group = .full,
        .other = .full,
    };

    pub const anybody_rw = Mode{
        .user = .{ .read = true, .write = true, .exec = false },
        .group = .{ .read = true, .write = true, .exec = false },
        .other = .{ .read = true, .write = true, .exec = false },
    };

    /// Get a mode from POSIX mode integer.
    pub fn fromPosixMode(mode: u32) Mode {
        return @bitCast(mode);
    }

    pub fn toString(self: Mode) [9]u8 {
        var buf: [9]u8 = undefined;
        buf[0] = if (self.user.read) 'r' else '-';
        buf[1] = if (self.user.write) 'w' else '-';
        buf[2] = if (self.user.exec) 'x' else '-';
        buf[3] = if (self.group.read) 'r' else '-';
        buf[4] = if (self.group.write) 'w' else '-';
        buf[5] = if (self.group.exec) 'x' else '-';
        buf[6] = if (self.other.read) 'r' else '-';
        buf[7] = if (self.other.write) 'w' else '-';
        buf[8] = if (self.other.exec) 'x' else '-';
        return buf;
    }
};

/// Seek mode.
pub const SeekMode = enum(u32) {
    /// Seek from the beginning of the file.
    set,
    /// Seek from the current position.
    current,
    /// Seek from the end of the file.
    end,

    _,
};

/// Inode.
pub const Inode = struct {
    const Self = @This();

    /// Filesystem this inode belongs to.
    fs: *FileSystem,
    /// Inode number.
    number: u64,
    /// Inode type.
    inode_type: InodeType,
    /// File mode.
    mode: Mode,
    /// User ID.
    uid: Uid,
    /// Group ID.
    gid: Gid,
    /// File size.
    size: usize,
    /// Operations for this inode.
    inode_ops: *const Vtable,
    /// Operations for a file.
    file_ops: *const File.Vtable,
    /// Context of this inode.
    ctx: *anyopaque,

    /// Inode operations.
    pub const Vtable = struct {
        /// Find a file named `name` in this directory inode.
        ///
        /// If the file is found, return the dentry.
        /// If the file is not found, return null.
        lookup: *const fn (self: *Inode, name: []const u8) VfsError!?*Dentry,
        /// Get stat information of this inode.
        stat: *const fn (inode: *Inode) VfsError!Stat,
    };

    /// Lookup a file named `name` in this directory inode.
    ///
    /// This function searches only in the given directory, and does not search more than one level of depth.
    pub fn lookup(self: *Self, name: []const u8) VfsError!?*Dentry {
        if (self.inode_type != InodeType.directory) return VfsError.NotDirectory;
        return self.inode_ops.lookup(self, name);
    }

    /// Get stat information of this inode.
    pub fn stat(self: *Self) VfsError!Stat {
        return self.inode_ops.stat(self);
    }
};

/// File instance.
pub const File = struct {
    const Self = @This();

    /// Offset within the file.
    pos: usize = 0,
    /// Dentry of the file.
    dentry: *Dentry,
    /// Operations.
    vtable: *const Vtable,
    /// Allocator.
    allocator: Allocator,

    /// File operations.
    pub const Vtable = struct {
        /// Iterate over all files in this directory inode.
        ///
        /// Caller must free the returned slice.
        iterate: *const fn (self: *Inode, allocator: Allocator) VfsError![]*Dentry,
        /// Read data from this inode from position `pos` to `buf`.
        ///
        /// Return the number of bytes read.
        read: *const fn (inode: *Inode, buf: []u8, pos: usize) VfsError!usize,
        /// Write data to this inode from position `pos` with `data`.
        ///
        /// Return the number of bytes written.
        write: *const fn (inode: *Inode, data: []const u8, pos: usize) VfsError!usize,
    };

    /// Allocate a new file instance.
    pub fn new(dentry: *Dentry, allocator: Allocator) VfsError!*Self {
        const file = try allocator.create(File);
        file.* = .{
            .dentry = dentry,
            .vtable = dentry.inode.file_ops,
            .allocator = allocator,
        };

        return file;
    }

    /// Deinitialize this file instance.
    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Iterate over all files in this directory inode.
    pub fn iterate(self: *Self) VfsError![]*Dentry {
        if (self.dentry.inode.inode_type != InodeType.directory) {
            return VfsError.IsDirectory;
        }
        return self.vtable.iterate(
            self.dentry.inode,
            self.allocator,
        );
    }

    /// Read data from this inode.
    pub fn read(self: *Self, buf: []u8) VfsError!usize {
        if (self.dentry.inode.inode_type == InodeType.directory) {
            return VfsError.IsDirectory;
        }
        const num_read = try self.vtable.read(
            self.dentry.inode,
            buf,
            self.pos,
        );
        self.pos += num_read;
        return num_read;
    }

    /// Reposition file offset.
    ///
    /// This functions allows the file offset to be set beyond the end of the file.
    pub fn seek(file: *File, offset: usize, whence: SeekMode) VfsError!usize {
        file.pos = switch (whence) {
            .current => std.math.add(usize, file.pos, offset) catch return VfsError.Overflow,
            .set => offset,
            .end => std.math.sub(usize, file.dentry.inode.size, offset) catch return VfsError.Overflow,
            else => return VfsError.InvalidArgument,
        };
        return file.pos;
    }

    /// Write data to this inode.
    pub fn write(self: *Self, data: []const u8, pos: usize) VfsError!usize {
        if (self.dentry.inode.inode_type == InodeType.directory) {
            return VfsError.IsDirectory;
        }
        return self.vtable.write(self.dentry.inode, data, pos);
    }
};

/// Dentry of root directory.
///
/// This variable is undefined until the filesystem is initialized
var root_dentry: *Dentry = undefined;
/// Whether the VFS system is initialized.
var root_mounted: bool = false;

const MountList = std.DoublyLinkedList(*FileSystem);
const MountListNode = MountList.Node;
/// List of mounted filesystems.
var mount_list: MountList = .{};

/// Initialize VFS system.
pub fn init(allocator: Allocator) VfsError!void {
    // Initialize the root directory entry.
    const root = try allocator.create(Dentry);
    root.* = .{
        .fs = undefined,
        .inode = try allocator.create(Inode),
        .parent = root,
        .name = undefined,
        .ops = undefined,
        .mounted_by = null,
    };
    root.inode.inode_type = .directory;

    root_dentry = root;
}

/// Get the root directory entry.
pub fn getRoot() *Dentry {
    return root_dentry;
}

/// Mount the filesystem on the given path.
///
/// `entry_point` must be absolute path.
pub fn mount(fs: *FileSystem, entry_point: []const u8, allocator: Allocator) VfsError!void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    if (!isAbsolutePath(entry_point)) {
        return VfsError.InvalidArgument;
    }

    // Get the directory on which the filesystem is being mounted.
    const mp_dentry = blk: {
        if (!root_mounted) {
            if (std.mem.eql(u8, entry_point, "/")) {
                break :blk root_dentry;
            } else return VfsError.NotFound;
        } else {
            const result = try resolvePath(root_dentry, entry_point);
            if (result.result) |dentry| break :blk dentry else return VfsError.NotFound;
        }
    };
    if (mp_dentry.inode.inode_type != .directory) {
        return VfsError.NotDirectory;
    }
    if (mp_dentry.mounted_by != null) {
        return VfsError.AlreadyExists;
    }

    // TODO: check if the directory is empty.

    // Register the mount.
    const new_mount = try allocator.create(MountListNode);
    new_mount.data = fs;
    mount_list.append(new_mount);

    mp_dentry.mounted_by = fs;
    root_mounted = true;
}

/// Result of path resolution.
const PathResult = struct {
    /// Resolved dentry.
    /// Null if the path is not found.
    result: ?*Dentry,
    /// Second-to-last path component.
    /// Null if the component is not found.
    ///
    /// Note that this dentry is not necessarily the parent of the resolved dentry.
    /// If this is null, result is also null.
    parent: ?*Dentry,
};

/// Resolve the path string.
///
/// - origin: The dentry to start the search from. Ignored if the path is absolute.
/// - path: The path string to resolve.
pub fn resolvePath(origin: *Dentry, path: []const u8) VfsError!PathResult {
    var result = PathResult{
        .result = null,
        .parent = origin,
    };

    var iter = std.fs.path.ComponentIterator(.posix, u8).init(path) catch {
        return result;
    };
    var entry = follow(blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk root_dentry;
        } else {
            break :blk origin;
        }
    });

    while (iter.next()) |component| {
        if (std.mem.eql(u8, component.name, ".")) {
            continue;
        } else if (std.mem.eql(u8, component.name, "..")) {
            entry = followDotDot(entry);
            continue;
        }

        if (entry.mounted_by) |mp| {
            // Switch mount namespace.
            entry = mp.root;
        }
        const lookup_result = entry.inode.lookup(component.name) catch {
            return result;
        };
        if (lookup_result) |next| {
            if (iter.peekNext() != null) result.parent = next;
            entry = next;
        } else {
            return result;
        }
    }

    result.result = entry;
    return result;
}

/// Check if the path is absolute.
pub fn isAbsolutePath(path: []const u8) bool {
    return std.fs.path.isAbsolute(path);
}

/// Get a basename of the path.
pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// If the directory is a mount point, return the root of the filesystem.
/// Otherwise, return the dentry itself.
pub fn follow(dent: *Dentry) *Dentry {
    return if (dent.mounted_by) |mp| mp.root else dent;
}

/// Get a parent of dentry.
///
/// If the dentry is a mount point, follow the tree of the original dentry.
fn followDotDot(dent: *const Dentry) *Dentry {
    if (dent.mounted_by) |mp| {
        return if (mp.mounted_to == root_dentry) dent.parent else mp.mounted_to;
    } else {
        return dent.parent;
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const mem = norn.mem;
