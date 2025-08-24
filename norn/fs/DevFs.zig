const Self = @This();
const DevFs = Self;
const Error = fs.FsError;

/// List type of character devices.
const CharDevList = std.AutoHashMap(device.Number, CharDevInfo);

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

const CharDevInfo = struct {
    /// inode.
    inode: *Inode,
    /// Character device.
    chardev: CharDev,
};

/// Memory allocator used by this FS.
allocator: Allocator,
/// Spin lock.
lock: SpinLock,
/// Super block.
sb: *SuperBlock,
/// Next inode number to allocate.
inum_next: Inode.Number = 0,

/// List of registered character devices.
char_devs: CharDevList,

// =============================================================
// Filesystem operations
// =============================================================

fn mount(_: ?*const anyopaque, allocator: Allocator) Error!*SuperBlock {
    const sb = try allocator.create(SuperBlock);
    errdefer allocator.destroy(sb);

    // Init self.
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .lock = SpinLock{},
        .char_devs = CharDevList.init(allocator),
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

fn iterate(file: *File, allocator: Allocator) Error![]File.IterResult {
    const self = getSelf(file.inode);
    const children = self.char_devs;
    const num_children = children.count();

    const results = try allocator.alloc(File.IterResult, num_children);
    errdefer allocator.free(results);

    var iter = children.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| : (i += 1) {
        const child = entry.value_ptr;
        results[i] = .{
            .name = child.chardev.name,
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
    _ = dir;
    _ = name;

    norn.unimplemented("DevFs.lookup");
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
pub fn registerCharDev(self: *Self, char: device.CharDev) Error!void {
    const inode = try self.createInode();
    inode.mode = .{ .type = .char };
    inode.devnum = char.type;
    inode.fops = char.fops;

    const info = CharDevInfo{
        .inode = inode,
        .chardev = char,
    };
    try self.char_devs.put(char.type, info);
}

// =============================================================
// Utilities
// =============================================================

/// Get self from inode.
inline fn getSelf(inode: *Inode) *Self {
    return @alignCast(@ptrCast(inode.ctx));
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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const device = norn.device;
const fs = norn.fs;
const CharDev = device.CharDev;
const SpinLock = norn.SpinLock;
const Mode = norn.fs.Mode;

const Dentry = @import("Dentry.zig");
const File = @import("File.zig");
const FileSystem = @import("FileSystem.zig");
const Inode = @import("Inode.zig");
const SuperBlock = @import("SuperBlock.zig");
