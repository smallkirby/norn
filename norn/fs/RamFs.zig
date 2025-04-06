//! Implementation of a simple in-memory filesystem.

const RamFs = Self;
const Self = @This();

/// Backing allocator.
allocator: Allocator,
/// Next inode number.
inum_next: usize = 0,
/// Root directory.
root: *Dentry,
/// Spin lock.
lock: SpinLock = SpinLock{},

/// Dentry operations.
const dentry_vtable = Dentry.Vtable{
    .createFile = createFile,
    .createDirectory = createDirectory,
};

/// Inode operations.
const inode_vtable = Inode.Vtable{
    .iterate = iterate,
    .lookup = lookup,
    .read = read,
    .write = write,
    .stat = stat,
};

/// Default file mode.
const default_file_mode: Mode = .anybody_full;
/// Default UID.
const default_uid: Uid = 0; // TODO
/// Default GID.
const default_gid: Gid = 0; // TODO

/// Initialize ramfs creating root directory.
pub fn init(allocator: Allocator) Error!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = std.mem.zeroInit(Self, .{
        .allocator = allocator,
        .root = undefined,
    });

    // Create a root directory.
    const root_node = try Node.newDirectory(allocator);
    const root_inode = try self.createInode(
        .directory,
        self.assignInum(),
        default_file_mode,
        root_node,
    );
    const root_dentry = try self.createDentry(
        root_inode,
        undefined,
        "",
    );
    root_dentry.parent = root_dentry;

    // Initialize myself.
    self.root = root_dentry;
    root_dentry.fs = self.filesystem();

    return self;
}

/// Get the filesystem interface.
pub fn filesystem(self: *Self) vfs.FileSystem {
    return .{
        .root = self.root,
        .ctx = self,
    };
}

/// Actual file or directory entity.
/// This struct is put in the inode's context.
const Node = union(enum) {
    /// File node.
    file: File,
    /// Directory node.
    directory: Directory,

    /// Create a new file node.
    pub fn newFile(allocator: Allocator) Error!*Node {
        const node = try allocator.create(Node);
        node.* = .{ .file = File{} };
        return node;
    }

    /// Create a new directory node.
    pub fn newDirectory(allocator: Allocator) Error!*Node {
        const node = try allocator.create(Node);
        node.* = .{ .directory = Directory.new() };
        return node;
    }
};

/// File node.
const File = struct {
    /// Backing data.
    _data: []u8 = &.{},
    /// Size of the file.
    /// This value can be different from data.len, that represents an in-memory capacity.
    size: usize = 0,

    /// Check if the the file has enough buffer to store `capacity` bytes.
    fn hasCapacity(self: *File, capacity: usize) bool {
        return self._data.len >= capacity;
    }

    /// Resize the file.
    fn resize(self: *File, new_size: usize, allocator: Allocator) Error!void {
        // We don't shrink the file.
        if (new_size <= self.size) return;
        // If the file has enough capacity, just update the size.
        if (new_size <= self._data.len) {
            self.size = new_size;
            return;
        }

        // Reallocate buffer and copy old data.
        const new_data = try allocator.alloc(u8, new_size);
        errdefer allocator.free(new_data);
        @memcpy(new_data[0..self.size], self._data);
        allocator.free(self._data);

        // Update information.
        self._data = new_data;
        self.size = new_size;
    }

    /// Read data from the file.
    fn read(self: *File, buf: []u8, pos: usize) Error!usize {
        const end = if (pos + buf.len > self.size) self.size else buf.len;
        const len = end - pos;
        @memcpy(buf[0..len], self._data[pos..end]);
        return len;
    }

    /// Write data to the file.
    /// If the file doesn't have enough capacity, resize it.
    fn write(self: *File, data: []const u8, pos: usize, allocator: Allocator) Error!usize {
        const end = pos + data.len;
        if (!self.hasCapacity(end)) {
            try self.resize(end, allocator);
        }
        if (self.size < end) {
            self.size = end;
        }
        @memcpy(self._data[pos..end], data);

        return data.len;
    }
};

/// Directory node.
const Directory = struct {
    const Children = DoublyLinkedList(*Dentry);
    const Child = Children.Node;

    /// List of children.
    children: Children,

    /// Create a new directory node.
    pub fn new() Directory {
        return .{
            .children = Children{},
        };
    }

    /// Append a dentry to the directory.
    fn append(self: *Directory, dentry: *Dentry, allocator: Allocator) Error!void {
        const new_child = try allocator.create(Child);
        new_child.data = dentry;
        self.children.append(new_child);
    }
};

/// Create a file in the given directory.
fn createFile(dir: *Dentry, name: []const u8, mode: Mode) Error!*Dentry {
    const self: *Self = @alignCast(@ptrCast(dir.fs.ctx));

    // Create a new file node.
    const node = try Node.newFile(self.allocator);
    const inode = try self.createInode(
        .file,
        self.assignInum(),
        mode,
        node,
    );
    const dentry = try self.createDentry(
        inode,
        dir,
        name,
    );

    // Append the new dentry to the parent directory.
    const dir_node: *Node = getNode(dir.inode);
    try dir_node.directory.append(dentry, self.allocator);

    return dentry;
}

/// Create a directory in the given directory.
fn createDirectory(dir: *Dentry, name: []const u8, mode: Mode) Error!*Dentry {
    const self: *Self = @alignCast(@ptrCast(dir.fs.ctx));

    // Create a new directory node.
    const node = try Node.newDirectory(self.allocator);
    const inode = try self.createInode(
        .directory,
        self.assignInum(),
        mode,
        node,
    );
    const dentry = try self.createDentry(inode, dir, name);

    // Append the new dentry to the parent directory.
    const dir_node: *Node = @alignCast(@ptrCast(dir.inode.ctx));
    try dir_node.directory.append(dentry, self.allocator);

    return dentry;
}

/// Iterate over children of the given directory.
fn iterate(inode: *Inode, allocator: Allocator) Error![]*const Dentry {
    const dir = getNode(inode).directory;
    const num_children = dir.children.len;

    const entries = try allocator.alloc(*const Dentry, num_children);
    errdefer allocator.free(entries);

    var child = dir.children.first;
    var i: usize = 0;
    while (child) |c| : ({
        child = c.next;
        i += 1;
    }) {
        entries[i] = c.data;
    }

    return entries;
}

/// Read data from the given inode.
fn read(inode: *Inode, buf: []u8, pos: usize) Error!usize {
    const file = &getNode(inode).file;
    return file.read(buf, pos);
}

/// Write data to the given inode.
fn write(inode: *Inode, data: []const u8, pos: usize) Error!usize {
    const self: *Self = @alignCast(@ptrCast(inode.fs.ctx));
    const file = &getNode(inode).file;
    const ret = file.write(data, pos, self.allocator);

    inode.size = file.size;
    return ret;
}

/// Lookup a dentry with the given name in the given directory.
fn lookup(dir: *Inode, name: []const u8) Error!?*Dentry {
    var child = getNode(dir).directory.children.first;
    while (child) |c| : (child = c.next) {
        if (std.mem.eql(u8, c.data.name, name)) {
            return c.data;
        }
    }
    return null;
}

/// Get a file stat information.
pub fn stat(inode: *Inode) Error!vfs.Stat {
    return switch (getNode(inode).*) {
        .directory => |_| .{
            .dev = .zero, // TODO
            .inode = inode.number,
            .num_links = 1,
            .mode = 0o777, // TODO
            .uid = inode.uid,
            .gid = inode.gid,
            .rdev = .zero,
            .size = 0, // TODO
            .block_size = 0, // TODO
            .num_blocks = 0, // TODO
            .access_time = 0, // TODO
            .access_time_nsec = 0, // TODO
            .modify_time = 0, // TODO
            .modify_time_nsec = 0, // TODO
            .change_time = 0, // TODO
            .change_time_nsec = 0, // TODO
        },
        .file => |f| .{
            .dev = .zero, // TODO
            .inode = inode.number,
            .num_links = 1,
            .mode = 0o777, // TODO
            .uid = inode.uid,
            .gid = inode.gid,
            .rdev = .zero,
            .size = f.size,
            .block_size = 0, // TODO
            .num_blocks = 0, // TODO
            .access_time = 0, // TODO
            .access_time_nsec = 0, // TODO
            .modify_time = 0, // TODO
            .modify_time_nsec = 0, // TODO
            .change_time = 0, // TODO
            .change_time_nsec = 0, // TODO
        },
    };
}

/// Atomically assigns a new unique inode number.
fn assignInum(self: *Self) u64 {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    const inum = self.inum_next;
    self.inum_next +%= 1;
    return inum;
}

/// Get the Node from the given inode.
inline fn getNode(inode: *Inode) *Node {
    return @alignCast(@ptrCast(inode.ctx));
}

/// Create a new VFS inode.
fn createInode(
    self: *Self,
    inode_type: InodeType,
    inum: usize,
    mode: Mode,
    ctx: *anyopaque,
) Error!*Inode {
    const inode = try self.allocator.create(Inode);
    inode.* = .{
        .fs = self.filesystem(),
        .number = inum,
        .inode_type = inode_type,
        .mode = mode,
        .uid = default_uid,
        .gid = default_gid,
        .size = 0,
        .ops = &inode_vtable,
        .ctx = ctx,
    };
    return inode;
}

/// Create a new VFS dentry.
fn createDentry(
    self: *Self,
    inode: *Inode,
    parent: *Dentry,
    name: []const u8,
) Error!*Dentry {
    const dentry = try self.allocator.create(Dentry);
    dentry.* = .{
        .fs = self.filesystem(),
        .inode = inode,
        .parent = parent,
        .name = try self.allocator.dupe(u8, name),
        .ops = &dentry_vtable,
    };

    return dentry;
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

var test_gpa = std.heap.GeneralPurposeAllocator(.{}){};

test "Create directories" {
    const allocator = test_gpa.allocator();
    const rfs = try RamFs.init(allocator);
    const root = rfs.root;

    const dir1 = try root.createDirectory("dir1", .anybody_full);
    const dir2 = try dir1.createDirectory("dir2", .anybody_full);
    try testing.expectEqual(dir1, try root.inode.lookup("dir1"));
    try testing.expectEqual(dir2, try dir1.inode.lookup("dir2"));
    try testing.expectEqual(null, try root.inode.lookup("dne"));
}

test "Create files" {
    const allocator = test_gpa.allocator();
    const rfs = try RamFs.init(allocator);
    const root = rfs.root;

    const dir1 = try root.createDirectory("dir1", .anybody_full);
    const file1 = try dir1.createFile("file1", .anybody_full);
    try testing.expectEqual(file1, try dir1.inode.lookup("file1"));
}

test "Write to file" {
    const allocator = test_gpa.allocator();
    const rfs = try RamFs.init(allocator);
    const root = rfs.root;
    const file1 = try root.createFile("file1", .anybody_full);

    const s1 = "Hello, world!";
    const s2 = "Hello, world and beyond!";
    var len = try file1.inode.write(s1, 0);
    try testing.expectEqual(len, s1.len);
    try testing.expectEqualStrings(s1, getNode(file1.inode).file._data);
    len = try file1.inode.write(s2, 0);
    try testing.expectEqual(len, s2.len);
    try testing.expectEqualStrings(s2, getNode(file1.inode).file._data);
}

test "Read from file" {
    const allocator = test_gpa.allocator();
    const rfs = try RamFs.init(allocator);
    const root = rfs.root;
    const file1 = try root.createFile("file1", .anybody_full);

    const s1 = "Hello, world!";
    const s2 = "Hello, world and beyond!";
    var buf: [1024]u8 = undefined;
    var len: usize = undefined;

    _ = try file1.inode.write(s1, 0);
    len = try file1.inode.read(buf[0..], 0);
    try testing.expectEqual(len, s1.len);
    try testing.expectEqualStrings(s1, buf[0..s1.len]);

    _ = try file1.inode.write(s2, 0);
    len = try file1.inode.read(buf[0..], 0);
    try testing.expectEqual(len, s2.len);
    try testing.expectEqualStrings(s2, buf[0..s2.len]);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

const norn = @import("norn");
const SpinLock = norn.SpinLock;

const vfs = @import("vfs.zig");
const Error = vfs.Error;
const Dentry = vfs.Dentry;
const Inode = vfs.Inode;
const InodeType = vfs.InodeType;
const Uid = vfs.Uid;
const Gid = vfs.Gid;
const Mode = vfs.Mode;
