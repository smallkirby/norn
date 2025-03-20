/// Filesystem for ramfs.
const RamFs = Self;
const Self = @This();

/// Vtable for ramfs.
const vtable = vfs.Vtable{
    .createFile = createFile,
    .createDirectory = createDirectory,
    .lookup = lookup,
    .read = read,
    .write = write,
    .stat = stat,
};

/// Backing allocator.
allocator: Allocator,
/// Next inode number.
inum_next: usize = 0,
/// Root directory.
root: *Dentry,

/// Initiate ramfs creating root directory.
pub fn init(allocator: Allocator) Error!*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    // Create a root directory.
    const root_node = try Node.newDirectory(allocator);
    const root_inode = try Inode.new(0, root_node, allocator);
    const root_dentry = try Dentry.new(
        undefined,
        root_inode,
        undefined,
        "",
        allocator,
    );
    root_dentry.parent = root_dentry;

    self.* = .{
        .allocator = allocator,
        .root = root_dentry,
    };
    root_dentry.fs = self.filesystem();

    return self;
}

/// Get the filesystem interface.
pub fn filesystem(self: *Self) vfs.FileSystem {
    return .{
        .vtable = &vtable,
        .root = self.root,
        .ctx = self,
    };
}

/// Create a file in the given directory.
pub fn createFile(fs: *vfs.FileSystem, dir: *Dentry, name: []const u8) Error!*Dentry {
    const self: *Self = @alignCast(@ptrCast(fs.ctx));
    return self.createFileInternal(dir, name);
}

/// Create a directory in the given directory.
pub fn createDirectory(fs: *vfs.FileSystem, dir: *Dentry, name: []const u8) Error!*Dentry {
    const self: *Self = @alignCast(@ptrCast(fs.ctx));
    return self.createDirectoryInternal(dir, name);
}

/// Read data from the given inode.
pub fn read(fs: *vfs.FileSystem, inode: *Inode, buf: []u8, pos: usize) Error!usize {
    const self: *Self = @alignCast(@ptrCast(fs.ctx));
    return self.readInternal(inode, buf, pos);
}

/// Write data to the given inode.
pub fn write(fs: *vfs.FileSystem, inode: *Inode, data: []const u8, pos: usize) Error!usize {
    const self: *Self = @alignCast(@ptrCast(fs.ctx));
    return self.writeInternal(inode, data, pos);
}

/// Lookup a dentry with the given name in the given directory.
pub fn lookup(fs: *vfs.FileSystem, dir: *Dentry, name: []const u8) Error!?*Dentry {
    const self: *Self = @alignCast(@ptrCast(fs.ctx));
    return self.lookupInternal(dir, name);
}

pub fn stat(fs: *vfs.FileSystem, inode: *Inode) Error!vfs.Stat {
    _ = fs;

    return switch (getNode(inode).*) {
        .directory => norn.unimplemented("stat for directory"),
        .file => |f| .{
            .size = f.size,
        },
    };
}

/// Print the tree structure of the filesystem.
pub fn printTree(self: RamFs, log: anytype) void {
    var current_path: [4096]u8 = undefined;
    current_path[0] = 0;
    self.printTreeSub(log, self.root, current_path[0..current_path.len]);
}

/// Print children of the given directory recursively.
fn printTreeSub(self: RamFs, log: anytype, dir: *Dentry, current_path: []u8) void {

    // Prepend separator.
    const init_path_end = blk: {
        for (current_path, 0..) |c, i| {
            if (c == 0) break :blk i + 1;
        } else {
            break :blk current_path.len;
        }
    };
    current_path[init_path_end - 1] = '/';

    // Iterate over children of the directory.
    var cur = getNode(dir.inode).directory.children.first;
    while (cur) |entry| : (cur = entry.next) {
        const node = entry.data;
        const name_len = node.name.len;

        // Copy entry name
        std.mem.copyBackwards(u8, current_path[init_path_end..], node.name);
        current_path[init_path_end + name_len] = 0;

        // Print the entry.
        log("{s}", .{current_path[0 .. init_path_end + name_len]});

        // Recurse if the entry is a directory.
        switch (getNode(entry.data.inode).*) {
            .directory => self.printTreeSub(log, node, current_path),
            else => {},
        }
    }
}

fn createFileInternal(self: *Self, dir: *Dentry, name: []const u8) Error!*Dentry {
    // Create a new file node.
    const node = try Node.newFile(self.allocator);
    const inode = try Inode.new(
        self.assignInum(),
        node,
        self.allocator,
    );
    const dentry = try Dentry.new(
        self.filesystem(),
        inode,
        dir,
        try self.allocator.dupe(u8, name),
        self.allocator,
    );

    // Append the new dentry to the parent directory.
    const dir_node: *Node = getNode(dir.inode);
    try dir_node.directory.append(dentry, self.allocator);

    return dentry;
}

fn createDirectoryInternal(self: *Self, dir: *Dentry, name: []const u8) Error!*Dentry {
    // Create a new directory node.
    const node = try Node.newDirectory(self.allocator);
    const inode = try Inode.new(self.assignInum(), node, self.allocator);
    const dentry = try Dentry.new(
        self.filesystem(),
        inode,
        dir,
        try self.allocator.dupe(u8, name),
        self.allocator,
    );

    // Append the new dentry to the parent directory.
    const dir_node: *Node = @alignCast(@ptrCast(dir.inode.ctx));
    try dir_node.directory.append(dentry, self.allocator);

    return dentry;
}

fn readInternal(_: *Self, inode: *Inode, buf: []u8, pos: usize) Error!usize {
    const file = &getNode(inode).file;
    return file.read(buf, pos);
}

fn writeInternal(self: *Self, inode: *Inode, data: []const u8, pos: usize) Error!usize {
    const file = &getNode(inode).file;
    return file.write(data, pos, self.allocator);
}

fn lookupInternal(_: *Self, dir: *Dentry, name: []const u8) Error!?*Dentry {
    var child = getNode(dir.inode).directory.children.first;
    while (child) |c| : (child = c.next) {
        if (std.mem.eql(u8, c.data.name, name)) {
            return c.data;
        }
    }
    return null;
}

/// Assign a new unique inode number.
fn assignInum(self: *Self) u64 {
    const inum = self.inum_next;
    self.inum_next +%= 1;
    return inum;
}

/// Get the Node from the given inode.
inline fn getNode(inode: *Inode) *Node {
    return @alignCast(@ptrCast(inode.ctx));
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
    pub fn read(self: *File, buf: []u8, pos: usize) Error!usize {
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

// ==============================

const testing = std.testing;

var test_gpa = std.heap.GeneralPurposeAllocator(.{}){};

test "Create directories" {
    const allocator = test_gpa.allocator();
    const rfs = try RamFs.init(allocator);

    const dir1 = try rfs.createDirectoryInternal(rfs.root, "dir1");
    const dir2 = try rfs.createDirectoryInternal(dir1, "dir2");
    try testing.expectEqual(dir1, try rfs.lookupInternal(rfs.root, "dir1"));
    try testing.expectEqual(dir2, try rfs.lookupInternal(dir1, "dir2"));
    try testing.expectEqual(null, try rfs.lookupInternal(dir1, "dne"));
}

test "Create files" {
    const allocator = test_gpa.allocator();
    const rfs = try RamFs.init(allocator);

    const dir1 = try rfs.createDirectoryInternal(rfs.root, "dir1");
    const file1 = try rfs.createFileInternal(dir1, "file1");
    try testing.expectEqual(file1, try rfs.lookupInternal(dir1, "file1"));
}

test "Write to file" {
    const allocator = test_gpa.allocator();
    const rfs = try RamFs.init(allocator);
    const file1 = try rfs.createFileInternal(rfs.root, "file1");

    const s1 = "Hello, world!";
    const s2 = "Hello, world and beyond!";
    var len = try rfs.writeInternal(file1.inode, s1, 0);
    try testing.expectEqual(len, s1.len);
    try testing.expectEqualStrings(s1, getNode(file1.inode).file._data);
    len = try rfs.writeInternal(file1.inode, s2, 0);
    try testing.expectEqual(len, s2.len);
    try testing.expectEqualStrings(s2, getNode(file1.inode).file._data);
}

test "Read from file" {
    const allocator = test_gpa.allocator();
    const rfs = try RamFs.init(allocator);
    const file1 = try rfs.createFileInternal(rfs.root, "file1");

    const s1 = "Hello, world!";
    const s2 = "Hello, world and beyond!";
    var buf: [1024]u8 = undefined;
    var len: usize = undefined;

    _ = try rfs.writeInternal(file1.inode, s1, 0);
    len = try rfs.readInternal(file1.inode, buf[0..], 0);
    try testing.expectEqual(len, s1.len);
    try testing.expectEqualStrings(s1, buf[0..s1.len]);

    _ = try rfs.writeInternal(file1.inode, s2, 0);
    len = try rfs.readInternal(file1.inode, buf[0..], 0);
    try testing.expectEqual(len, s2.len);
    try testing.expectEqualStrings(s2, buf[0..s2.len]);
}

test "Operation via VFS" {
    const allocator = test_gpa.allocator();
    const rfs = try RamFs.init(allocator);
    var fs = rfs.filesystem();

    const root = fs.root;
    const dir1 = try fs.createDirectory(root, "dir1");
    const dir2 = try fs.createDirectory(dir1, "dir2");
    try testing.expectEqual(dir1, try fs.lookup(root, "dir1"));
    try testing.expectEqual(dir2, try fs.lookup(dir1, "dir2"));
}

// ==============================

const std = @import("std");
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

const norn = @import("norn");

const vfs = @import("vfs.zig");
const Error = vfs.Error;
const Dentry = vfs.Dentry;
const Inode = vfs.Inode;
const Vtable = vfs.Vtable;
