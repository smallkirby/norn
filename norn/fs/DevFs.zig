const DevFs = Self;
const Self = @This();

pub const DevFsError = error{
    /// Memory allocation error.
    OutOfMemory,
} || vfs.VfsError;

/// Memory allocator used by this FS.
allocator: Allocator,
/// VFS filesystem interface.
fs: *vfs.FileSystem,
/// Directory this FS is mounted on.
root: *Dentry,
/// Spin lock.
lock: SpinLock = .{},

const dentry_vtable = Dentry.Vtable{
    .createFile = createFile,
    .createDirectory = createDirectory,
};

const inode_vtable = Inode.Vtable{
    .lookup = lookup,
    .stat = stat,
};

const file_vtable = vfs.File.Vtable{
    .iterate = iterate,
    .read = read,
    .write = write,
};

/// Create a new DevFs instance.
pub fn new(allocator: Allocator) DevFsError!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const fs = try allocator.create(vfs.FileSystem);
    errdefer allocator.destroy(fs);
    self.* = DevFs{
        .allocator = allocator,
        .root = undefined, // TODO
        .lock = SpinLock{},
        .fs = fs,
    };
    fs.* = .{
        .name = "devfs",
        .root = undefined, // TODO
        .ctx = self,
        .mounted_to = undefined,
    };

    const root_inode = try self.createInode(.directory, .{
        .other = .rx,
        .group = .rx,
        .user = .rwx,
        .type = .directory,
    });
    const root_dentry = try self.createDentry(
        root_inode,
        undefined,
        "",
    );
    root_dentry.parent = root_dentry;
    self.root = root_dentry;
    fs.root = root_dentry;

    return self;
}

/// Get a VFS filesystem interface.
pub fn filesystem(self: *Self) *vfs.FileSystem {
    return self.fs;
}

// =============================================================
// dentry operations.
// =============================================================

fn createDentry(self: *Self, inode: *Inode, parent: *Dentry, name: []const u8) DevFsError!*Dentry {
    const dentry = try self.allocator.create(Dentry);
    errdefer self.allocator.destroy(dentry);
    dentry.* = .{
        .fs = self.fs,
        .inode = inode,
        .parent = parent,
        .name = try self.allocator.dupe(u8, name),
        .ops = &dentry_vtable,
    };

    return dentry;
}

fn createFile(_: *Dentry, _: []const u8, _: Mode) VfsError!*Dentry {
    norn.unimplemented("DevFs: createFile()");
}

fn createDirectory(_: *Dentry, _: []const u8, _: Mode) VfsError!*Dentry {
    norn.unimplemented("DevFs: createDirectory()");
}

// =============================================================
// inode operations.
// =============================================================

var next_inum: usize = 1;

/// Assign an inode number to a new inode.
fn assignInum(self: *Self) usize {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    const inum = next_inum;
    next_inum +%= 1;
    return inum;
}

fn createInode(self: *Self, itype: vfs.InodeType, mode: vfs.Mode) DevFsError!*Inode {
    const inode = try self.allocator.create(Inode);
    errdefer self.allocator.destroy(inode);
    inode.* = Inode{
        .fs = self.fs,
        .number = assignInum(self),
        .inode_type = itype,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .mode = mode,
        .inode_ops = &inode_vtable,
        .file_ops = &file_vtable,
        .ctx = self,
    };
    return inode;
}

fn stat(inode: *Inode) VfsError!vfs.Stat {
    const self = inodeContext(inode);
    if (inode == self.root.inode) {
        return .{
            .dev = .zero, // TODO
            .inode = inode.number,
            .num_links = 1,
            .mode = inode.mode,
            .uid = inode.uid,
            .gid = inode.gid,
            .rdev = .zero,
            .size = 0,
            .block_size = 0,
            .num_blocks = 0,
            .access_time = 0,
            .access_time_nsec = 0,
            .modify_time = 0,
            .modify_time_nsec = 0,
            .change_time = 0,
            .change_time_nsec = 0,
        };
    }
    norn.unimplemented("DevFs: stat()");
}

fn iterate(_: *Inode, _: Allocator) VfsError![]*Dentry {
    return &.{}; // TODO
}

fn lookup(_: *Inode, _: []const u8) VfsError!?*Dentry {
    return null; // TODO
}

fn read(_: *Inode, _: []u8, _: usize) VfsError!usize {
    norn.unimplemented("DevFs: read()");
}

fn write(_: *Inode, _: []const u8, _: usize) VfsError!usize {
    norn.unimplemented("DevFs: write()");
}

// =============================================================
// Utilities
// =============================================================

inline fn inodeContext(inode: *Inode) *Self {
    return @alignCast(@ptrCast(inode.fs.ctx));
}

inline fn dentryContext(dentry: *Dentry) *Self {
    return @alignCast(@ptrCast(dentry.fs.ctx));
}

// =============================================================
// Imports
// =============================================================
const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const SpinLock = norn.SpinLock;

const vfs = @import("vfs.zig");
const Dentry = vfs.Dentry;
const Inode = vfs.Inode;
const Mode = vfs.Mode;
const VfsError = vfs.VfsError;
