/// VFS error.
pub const Error = error{
    /// Failed to allocate memory.
    OutOfMemory,
    /// Operation for directory only is called on a non-directory.
    NotDirectory,
    /// Operation for regular file only is called on a non-regular file.
    IsDirectory,
};

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
    mode: u32,
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
};

/// Dentry that connects an inode with its name.
pub const Dentry = struct {
    const Self = @This();

    /// Filesystem this dentry belongs to.
    fs: FileSystem,
    /// Inode this dentry points to.
    inode: *Inode,
    /// Parent directory.
    /// If there's no parent, it points to itself.
    parent: *Dentry,
    /// Name of this dentry.
    name: []const u8,
    /// Operations for this dentry.
    ops: *const Vtable,

    /// Dentry operations.
    pub const Vtable = struct {
        /// Create a directory named `name` in this directory inode.
        ///
        /// If the directory is created successfully, return the dentry.
        createDirectory: *const fn (self: *Dentry, name: []const u8, mode: Mode) Error!*Dentry,
        /// Create a file named `name` in this directory inode.
        ///
        /// If the file is created successfully, return the dentry.
        createFile: *const fn (self: *Dentry, name: []const u8, mode: Mode) Error!*Dentry,
    };

    /// Create a directory named `name` in this directory inode.
    pub fn createDirectory(self: *Self, name: []const u8, mode: Mode) Error!*Dentry {
        const inode = self.inode;
        if (inode.inode_type != InodeType.directory) return Error.NotDirectory;

        return self.ops.createDirectory(self, name, mode);
    }

    /// Create a file named `name` in this directory inode.
    pub fn createFile(self: *Self, name: []const u8, mode: Mode) Error!*Dentry {
        const inode = self.inode;
        if (inode.inode_type != InodeType.directory) return Error.NotDirectory;

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

/// File mode.
///
/// This struct is compatible with POSIX file mode.
pub const Mode = packed struct(i32) {
    /// Other permission.
    other: Permission,
    /// Group permission.
    group: Permission,
    /// User permission.
    user: Permission,
    /// Reserved.
    _reserved1: i3 = 0,
    /// Reserved.
    _reserved2: i3 = 0,
    /// Reserved.
    _reserved3: i1 = 0,
    /// Directory flag.
    directory: bool = false,
    /// Reserved.
    _reserved4: i15 = 0,

    /// Access permission for each access type.
    const Permission = packed struct(u3) {
        read: bool,
        write: bool,
        exec: bool,

        pub const full = Permission{
            .read = true,
            .write = true,
            .exec = true,
        };
    };

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

/// Inode.
pub const Inode = struct {
    const Self = @This();

    /// Filesystem this inode belongs to.
    fs: FileSystem,
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
    ops: *const Vtable,
    /// Context of this inode.
    ctx: *anyopaque,

    /// Inode operations.
    pub const Vtable = struct {
        /// Iterate over all files in this directory inode.
        ///
        /// Caller must free the returned slice.
        iterate: *const fn (self: *Inode, allocator: Allocator) Error![]*const Dentry,
        /// Find a file named `name` in this directory inode.
        ///
        /// If the file is found, return the dentry.
        /// If the file is not found, return null.
        lookup: *const fn (self: *Inode, name: []const u8) Error!?*Dentry,
        /// Read data from this inode from position `pos` to `buf`.
        ///
        /// Return the number of bytes read.
        read: *const fn (inode: *Inode, buf: []u8, pos: usize) Error!usize,
        /// Get stat information of this inode.
        stat: *const fn (inode: *Inode) Error!Stat,
        /// Write data to this inode from position `pos` with `data`.
        ///
        /// Return the number of bytes written.
        write: *const fn (inode: *Inode, data: []const u8, pos: usize) Error!usize,
    };

    /// Iterate over all files in this directory inode.
    pub fn iterate(self: *Self, allocator: Allocator) Error![]*const Dentry {
        if (self.inode_type != InodeType.directory) return Error.NotDirectory;
        return self.ops.iterate(self, allocator);
    }

    /// Lookup a file named `name` in this directory inode.
    ///
    /// This function searches only in the given directory, and does not search more than one level of depth.
    pub fn lookup(self: *Self, name: []const u8) Error!?*Dentry {
        if (self.inode_type != InodeType.directory) return Error.NotDirectory;
        return self.ops.lookup(self, name);
    }

    /// Read data from this inode.
    pub fn read(self: *Self, buf: []u8, pos: usize) Error!usize {
        if (self.inode_type == InodeType.directory) return Error.IsDirectory;
        return self.ops.read(self, buf, pos);
    }

    /// Get stat information of this inode.
    pub fn stat(self: *Self) Error!Stat {
        return self.ops.stat(self);
    }

    /// Write data to this inode.
    pub fn write(self: *Self, data: []const u8, pos: usize) Error!usize {
        if (self.inode_type == InodeType.directory) return Error.IsDirectory;
        return self.ops.write(self, data, pos);
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const mem = norn.mem;
