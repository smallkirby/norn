/// VFS error.
pub const Error = error{
    /// Failed to allocate memory.
    OutOfMemory,
    /// Invalid operation on the inode.
    InvalidOperation,
};

/// Stat information.
pub const Stat = struct {
    /// Size of the file.
    size: usize,
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
        /// Create a file named `name` in this directory inode.
        ///
        /// If the file is created successfully, return the dentry.
        createFile: *const fn (self: *Dentry, name: []const u8) Error!*Dentry,
        /// Create a directory named `name` in this directory inode.
        ///
        /// If the directory is created successfully, return the dentry.
        createDirectory: *const fn (self: *Dentry, name: []const u8) Error!*Dentry,
    };

    /// Create a file named `name` in this directory inode.
    pub fn createFile(self: *Self, name: []const u8) Error!*Dentry {
        const inode = self.inode;
        if (inode.inode_type != InodeType.directory) return Error.InvalidOperation;

        return self.ops.createFile(self, name);
    }

    /// Create a directory named `name` in this directory inode.
    pub fn createDirectory(self: *Self, name: []const u8) Error!*Dentry {
        const inode = self.inode;
        if (inode.inode_type != InodeType.directory) return Error.InvalidOperation;

        return self.ops.createDirectory(self, name);
    }
};

/// Inode type.
pub const InodeType = enum {
    /// File
    file,
    /// Directory
    directory,
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
    /// Operations for this inode.
    ops: *const Vtable,
    /// Context of this inode.
    ctx: *anyopaque,

    /// Inode operations.
    pub const Vtable = struct {
        /// Find a file named `name` in this directory inode.
        ///
        /// If the file is found, return the dentry.
        /// If the file is not found, return null.
        lookup: *const fn (self: *Inode, name: []const u8) Error!?*Dentry,
        /// TODO: doc
        read: *const fn (inode: *Inode, buf: []u8, pos: usize) Error!usize,
        /// TODO: doc
        write: *const fn (inode: *Inode, data: []const u8, pos: usize) Error!usize,
        /// TODO: doc
        stat: *const fn (inode: *Inode) Error!Stat,
    };

    /// Lookup a file named `name` in this directory inode.
    pub fn lookup(self: *Self, name: []const u8) Error!?*Dentry {
        if (self.inode_type != InodeType.directory) return Error.InvalidOperation;
        return self.ops.lookup(self, name);
    }

    /// Read data from this inode.
    pub fn read(self: *Self, buf: []u8, pos: usize) Error!usize {
        return self.ops.read(self, buf, pos);
    }

    /// Get stat information of this inode.
    pub fn stat(self: *Self) Error!Stat {
        return self.ops.stat(self);
    }

    /// Write data to this inode.
    pub fn write(self: *Self, data: []const u8, pos: usize) Error!usize {
        return self.ops.write(self, data, pos);
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const mem = norn.mem;

const allocator = mem.general_allocator;
