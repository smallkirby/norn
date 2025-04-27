/// VFS error.
pub const Error = error{
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
        lookup: *const fn (self: *Inode, name: []const u8) Error!?*Dentry,
        /// Get stat information of this inode.
        stat: *const fn (inode: *Inode) Error!Stat,
    };

    /// Lookup a file named `name` in this directory inode.
    ///
    /// This function searches only in the given directory, and does not search more than one level of depth.
    pub fn lookup(self: *Self, name: []const u8) Error!?*Dentry {
        if (self.inode_type != InodeType.directory) return Error.NotDirectory;
        return self.inode_ops.lookup(self, name);
    }

    /// Get stat information of this inode.
    pub fn stat(self: *Self) Error!Stat {
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
        iterate: *const fn (self: *Inode, allocator: Allocator) Error![]*Dentry,
        /// Read data from this inode from position `pos` to `buf`.
        ///
        /// Return the number of bytes read.
        read: *const fn (inode: *Inode, buf: []u8, pos: usize) Error!usize,
        /// Write data to this inode from position `pos` with `data`.
        ///
        /// Return the number of bytes written.
        write: *const fn (inode: *Inode, data: []const u8, pos: usize) Error!usize,
    };

    /// Allocate a new file instance.
    pub fn new(dentry: *Dentry, allocator: Allocator) Error!*Self {
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
    pub fn iterate(self: *Self) Error![]*Dentry {
        if (self.dentry.inode.inode_type != InodeType.directory) {
            return Error.IsDirectory;
        }
        return self.vtable.iterate(
            self.dentry.inode,
            self.allocator,
        );
    }

    /// Read data from this inode.
    pub fn read(self: *Self, buf: []u8) Error!usize {
        if (self.dentry.inode.inode_type == InodeType.directory) {
            return Error.IsDirectory;
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
    pub fn seek(file: *File, offset: usize, whence: SeekMode) Error!usize {
        file.pos = switch (whence) {
            .current => std.math.add(usize, file.pos, offset) catch return Error.Overflow,
            .set => offset,
            .end => std.math.sub(usize, file.dentry.inode.size, offset) catch return Error.Overflow,
            else => return Error.InvalidArgument,
        };
        return file.pos;
    }

    /// Write data to this inode.
    pub fn write(self: *Self, data: []const u8, pos: usize) Error!usize {
        if (self.dentry.inode.inode_type == InodeType.directory) {
            return Error.IsDirectory;
        }
        return self.vtable.write(self.dentry.inode, data, pos);
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const mem = norn.mem;
