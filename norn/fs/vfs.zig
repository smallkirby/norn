const std = @import("std");
const Allocator = std.mem.Allocator;

/// VFS error.
pub const Error = error{
    /// Failed to allocate memory.
    OutOfMemory,
};

/// Stat information.
pub const Stat = struct {
    /// Size of the file.
    size: usize,
};

/// VFS operations.
pub const Vtable = struct {
    read: *const fn (self: *FileSystem, inode: *Inode, buf: []u8, pos: usize) Error!usize,
    write: *const fn (self: *FileSystem, inode: *Inode, data: []const u8, pos: usize) Error!usize,
    lookup: *const fn (self: *FileSystem, dentry: *Dentry, name: []const u8) Error!?*Dentry,
    createFile: *const fn (self: *FileSystem, dentry: *Dentry, name: []const u8) Error!*Dentry,
    createDirectory: *const fn (self: *FileSystem, dentry: *Dentry, name: []const u8) Error!*Dentry,
    stat: *const fn (self: *FileSystem, inode: *Inode) Error!Stat,
};

/// Virtual filesystem.
pub const FileSystem = struct {
    /// Root directory of this filesystem.
    root: *Dentry,
    /// VFS operations.
    vtable: *const Vtable,
    /// Backing filesystem instance.
    ctx: *anyopaque,

    /// Create a file.
    pub fn createFile(self: *FileSystem, dentry: *Dentry, name: []const u8) Error!*Dentry {
        return self.vtable.createFile(self, dentry, name);
    }

    /// Create a directory.
    pub fn createDirectory(self: *FileSystem, dentry: *Dentry, name: []const u8) Error!*Dentry {
        return self.vtable.createDirectory(self, dentry, name);
    }

    /// Lookup a directory entry.
    pub fn lookup(self: *FileSystem, dentry: *Dentry, name: []const u8) Error!?*Dentry {
        return self.vtable.lookup(self, dentry, name);
    }

    /// TODO: doc
    pub fn read(self: *FileSystem, inode: *Inode, buf: []u8, pos: usize) Error!usize {
        return self.vtable.read(self, inode, buf, pos);
    }

    /// TODO: doc
    pub fn stat(self: *FileSystem, inode: *Inode) Error!Stat {
        return self.vtable.stat(self, inode);
    }
};

/// Dentry that connects an inode with its name.
pub const Dentry = struct {
    /// Filesystem this dentry belongs to.
    fs: FileSystem,
    /// Inode this dentry points to.
    inode: *Inode,
    /// Parent directory.
    /// If there's no parent, it points to itself.
    parent: *Dentry,
    /// Name of this dentry.
    name: []const u8,

    /// Create a new dentry.
    pub fn new(
        fs: FileSystem,
        inode: *Inode,
        parent: *Dentry,
        name: []const u8,
        allocator: Allocator,
    ) Error!*Dentry {
        const dentry = try allocator.create(Dentry);
        dentry.* = .{
            .fs = fs,
            .inode = inode,
            .parent = parent,
            .name = name,
        };
        return dentry;
    }
};

/// Inode.
pub const Inode = struct {
    /// Inode number.
    number: u64,
    /// Context of this inode.
    ctx: *anyopaque,

    /// Create a new inode.
    pub fn new(number: u64, ctx: *anyopaque, allocator: Allocator) Error!*Inode {
        const inode = try allocator.create(Inode);
        inode.* = .{
            .number = number,
            .ctx = ctx,
        };
        return inode;
    }
};
