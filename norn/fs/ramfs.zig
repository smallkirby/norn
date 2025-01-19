const std = @import("std");
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

const vfs = @import("vfs.zig");
const Dentry = vfs.Dentry;
const Inode = vfs.Inode;
const Vtable = vfs.Vtable;

const Error = vfs.Error;

/// Filesystem for ramfs.
pub const RamFs = struct {
    const Self = @This();
    const vtable = vfs.Vtable{
        .createDirectory = createDirectory,
        .lookup = lookup,
        .read = read,
        .write = write,
    };

    /// Backing allocator.
    allocator: Allocator,
    /// Filesystem interface.
    fs: *vfs.FileSystem,
    /// Next inode number.
    inum_next: usize = 0,

    /// Initiate ramfs creating root directory.
    pub fn init(allocator: Allocator) Error!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Create a filesystem interface.
        const fs = try allocator.create(vfs.FileSystem);
        fs.* = .{
            .vtable = &vtable,
            .root = undefined,
            .ctx = self,
        };

        // Create a root directory.
        const root_node = try Node.newDirectory(allocator);
        const root_inode = try Inode.new(0, root_node, allocator);
        const dentry = try Dentry.new(
            fs,
            root_inode,
            undefined,
            "",
            allocator,
        );
        dentry.parent = dentry;
        fs.root = dentry;

        self.* = .{
            .allocator = allocator,
            .fs = fs,
        };

        return self;
    }

    /// Create a file in the given directory.
    pub fn createFile(fs: *vfs.FileSystem, dir: *Dentry, name: [:0]const u8) Error!*Dentry {
        const self: *Self = @alignCast(@ptrCast(fs.ctx));

        // Create a new file node.
        const node = try Node.newFile(self.allocator);
        const inode = try Inode.new(self.assignInum(), node, self.allocator);
        const dentry = try Dentry.new(
            self.fs,
            inode,
            dir,
            name,
            self.allocator,
        );

        // Append the new dentry to the parent directory.
        const dir_node: *Node = getNode(dir.inode);
        try dir_node.directory.append(dentry, self.allocator);

        return dentry;
    }

    /// Create a directory in the given directory.
    pub fn createDirectory(fs: *vfs.FileSystem, dir: *Dentry, name: []const u8) Error!*Dentry {
        const self: *Self = @alignCast(@ptrCast(fs.ctx));

        // Create a new directory node.
        const node = try Node.newDirectory(self.allocator);
        const inode = try Inode.new(self.assignInum(), node, self.allocator);
        const dentry = try Dentry.new(
            self.fs,
            inode,
            dir,
            name,
            self.allocator,
        );

        // Append the new dentry to the parent directory.
        const dir_node: *Node = @alignCast(@ptrCast(dir.inode.ctx));
        try dir_node.directory.append(dentry, self.allocator);

        return dentry;
    }

    /// Read data from the given inode.
    pub fn read(_: *vfs.FileSystem, inode: *Inode, buf: []u8, pos: usize) Error!usize {
        const file = &getNode(inode).file;
        return file.read(buf, pos);
    }

    /// Write data to the given inode.
    pub fn write(fs: *vfs.FileSystem, inode: *Inode, data: []const u8, pos: usize) Error!usize {
        const self: *Self = @alignCast(@ptrCast(fs.ctx));
        const file = &getNode(inode).file;
        return file.write(data, pos, self.allocator);
    }

    /// Assign a new unique inode number.
    fn assignInum(self: *Self) u64 {
        const inum = self.inum_next;
        self.inum_next +%= 1;
        return inum;
    }
};

/// Get the Node from the given inode.
fn getNode(inode: *Inode) *Node {
    return @alignCast(@ptrCast(inode.ctx));
}

/// Lookup a dentry with the given name in the given directory.
pub fn lookup(_: *vfs.FileSystem, dir: *Dentry, name: []const u8) Error!?*Dentry {
    var child = getNode(dir.inode).directory.children.first;
    while (child) |c| : (child = c.next) {
        if (std.mem.eql(u8, c.data.name, name)) {
            return c.data;
        }
    }
    return null;
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

test {
    testing.refAllDeclsRecursive(@This());
}

test "Create directories" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const rfs = try RamFs.init(allocator);

    const dir1 = try RamFs.createDirectory(rfs.fs, rfs.fs.root, "dir1");
    const dir2 = try RamFs.createDirectory(rfs.fs, dir1, "dir2");
    try testing.expectEqual(dir1, try lookup(rfs.fs, rfs.fs.root, "dir1"));
    try testing.expectEqual(dir2, try lookup(rfs.fs, dir1, "dir2"));
    try testing.expectEqual(null, try lookup(rfs.fs, dir1, "dne"));
}

test "Create files" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const rfs = try RamFs.init(allocator);

    const dir1 = try RamFs.createDirectory(rfs.fs, rfs.fs.root, "dir1");
    const file1 = try RamFs.createFile(rfs.fs, dir1, "file1");
    try testing.expectEqual(file1, try lookup(rfs.fs, dir1, "file1"));
}

test "Write to file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const rfs = try RamFs.init(allocator);
    const file1 = try RamFs.createFile(rfs.fs, rfs.fs.root, "file1");

    const s1 = "Hello, world!";
    const s2 = "Hello, world and beyond!";
    var len = try RamFs.write(rfs.fs, file1.inode, s1, 0);
    try testing.expectEqual(len, s1.len);
    try testing.expectEqualStrings(s1, getNode(file1.inode).file._data);
    len = try RamFs.write(rfs.fs, file1.inode, s2, 0);
    try testing.expectEqual(len, s2.len);
    try testing.expectEqualStrings(s2, getNode(file1.inode).file._data);
}

test "Read from file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const rfs = try RamFs.init(allocator);
    const file1 = try RamFs.createFile(rfs.fs, rfs.fs.root, "file1");

    const s1 = "Hello, world!";
    const s2 = "Hello, world and beyond!";
    var buf: [1024]u8 = undefined;
    var len: usize = undefined;

    _ = try RamFs.write(rfs.fs, file1.inode, s1, 0);
    len = try RamFs.read(rfs.fs, file1.inode, buf[0..], 0);
    try testing.expectEqual(len, s1.len);
    try testing.expectEqualStrings(s1, buf[0..s1.len]);

    _ = try RamFs.write(rfs.fs, file1.inode, s2, 0);
    len = try RamFs.read(rfs.fs, file1.inode, buf[0..], 0);
    try testing.expectEqual(len, s2.len);
    try testing.expectEqualStrings(s2, buf[0..s2.len]);
}

test "Operation via VFS" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const rfs = try RamFs.init(allocator);
    const fs = rfs.fs;

    const root = fs.root;
    const dir1 = try fs.createDirectory(root, "dir1");
    const dir2 = try fs.createDirectory(dir1, "dir2");
    try testing.expectEqual(dir1, try fs.lookup(root, "dir1"));
    try testing.expectEqual(dir2, try fs.lookup(dir1, "dir2"));
}
