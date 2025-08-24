const Self = @This();
const RamFs = Self;
const Error = fs.FsError;

/// Option passed to initialize ramfs.
pub const InitOption = struct {
    /// CPIO archive image.
    image: []const u8,
};

pub const ramfs_fs = FileSystem{
    .name = "ramfs",
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

/// Spin lock.
lock: SpinLock,
/// Memory allocator.
allocator: Allocator,

/// Super block.
sb: *SuperBlock,
/// Next inode number to allocate.
inum_next: Inode.Number,

// =============================================================
// Filesystem operations
// =============================================================

fn mount(data: ?*const anyopaque, allocator: Allocator) Error!*SuperBlock {
    const sb = try allocator.create(SuperBlock);
    errdefer allocator.destroy(sb);

    // Init self.
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .lock = .{},
        .allocator = allocator,
        .sb = sb,
        .inum_next = 0,
    };

    // Init root dentry.
    const root_inode = try self.createInode();
    root_inode.mode = .{
        .other = .rx,
        .group = .rwx,
        .user = .rwx,
        .flags = .none,
        .type = .dir,
    };
    const root_dentry = try self.createDentry(root_inode);

    // Init super block.
    sb.* = .{
        .root = root_dentry,
        .ops = sb_ops,
        .ctx = self,
    };

    // Init internal root directory.
    const root_dir = try Node.newDir("", root_inode, allocator);
    root_inode.ctx = root_dir;

    // If the initramfs image is provided, load it into the filesystem.
    if (data) |ptr| {
        const option: *const InitOption = @alignCast(@ptrCast(ptr));
        boot.loadCpioImage(self, option.image) catch |err| return switch (err) {
            error.Overflow, error.InvalidCharacter => Error.InvalidArgument,
            else => @errorCast(err),
        };
    }

    return sb;
}

/// TODO: implement
fn unmount() Error!void {
    norn.unimplemented("RamFs.unmount");
}

// =============================================================
// File operations
// =============================================================

fn iterate(file: *File, allocator: Allocator) Error![]File.IterResult {
    const dir = &getNode(file.inode).dir;
    const children = dir.children;
    const num_children = children.len;

    const results = try allocator.alloc(File.IterResult, num_children);
    errdefer allocator.free(results);

    var cur = children.first;
    var i: usize = 0;
    while (cur) |child| : ({
        cur = child.next;
        i += 1;
    }) {
        const child_node = getNode(child.data);
        const name = child_node.getName();
        results[i] = .{
            .name = name,
            .inum = child.data.number,
            .type = child.data.mode.type,
        };
    }

    return results;
}

fn read(file: *File, buf: []u8, pos: fs.Offset) Error!usize {
    const file_node = &getNode(file.inode).file;
    return file_node.read(buf, @intCast(pos));
}

fn write(file: *File, data: []const u8, pos: fs.Offset) Error!usize {
    _ = file;
    _ = data;
    _ = pos;

    norn.unimplemented("RamFs.write");
}

// =============================================================
// inode operations
// =============================================================

fn lookup(dir: *Inode, name: []const u8) Error!?*Inode {
    const node = getNode(dir);
    return node.dir.getChild(name);
}

fn create(dir: *Inode, name: []const u8, mode: Mode) Error!*Inode {
    const self = getSelf(dir);
    const dir_node = &getNode(dir).dir;

    const inode = try self.createInode();
    errdefer self.allocator.destroy(inode);
    inode.mode = mode;

    const node = switch (mode.type) {
        .regular => try Node.newFile(
            dir_node,
            name,
            inode,
            self.allocator,
        ),
        .dir => try Node.newDir(
            name,
            inode,
            self.allocator,
        ),
        else => return Error.InvalidArgument,
    };
    inode.ctx = @ptrCast(node);

    try dir_node.append(inode, self.allocator);

    return inode;
}

// =============================================================
// Internal utilities
// =============================================================

/// ramfs-specific inode data.
const Node = union(enum) {
    file: FileNode,
    dir: DirNode,

    /// Create a new file node.
    pub fn newFile(parent: *DirNode, name: []const u8, inode: *Inode, allocator: Allocator) Error!*Node {
        const node = try allocator.create(Node);
        node.* = .{ .file = try FileNode.new(
            parent,
            name,
            inode,
            allocator,
        ) };

        return node;
    }

    /// Create a new directory node.
    pub fn newDir(name: []const u8, inode: *Inode, allocator: Allocator) Error!*Node {
        const node = try allocator.create(Node);
        node.* = .{ .dir = try DirNode.new(
            name,
            inode,
            allocator,
        ) };

        return node;
    }

    /// Get the name of the node.
    pub fn getName(self: *Node) []const u8 {
        return switch (self.*) {
            .file => |*f| f.name,
            .dir => |*d| d.name,
        };
    }
};

/// File node.
const FileNode = struct {
    /// Backing data.
    _data: []u8 = &.{},
    /// Parent directory.
    parent: *DirNode,
    /// File name.
    name: []const u8,
    /// inode.
    inode: *Inode,

    /// Create a new file node.
    fn new(parent: *DirNode, name: []const u8, inode: *Inode, allocator: Allocator) Error!FileNode {
        return .{
            .parent = parent,
            .name = try allocator.dupe(u8, name),
            .inode = inode,
        };
    }

    /// Check if the the file has enough buffer to store `capacity` bytes.
    fn hasCapacity(self: *FileNode, capacity: usize) bool {
        return self._data.len >= capacity;
    }

    /// Resize the file.
    fn resize(self: *FileNode, new_size: usize, allocator: Allocator) Error!void {
        // We don't shrink the file.
        if (new_size <= self.inode.size) return;
        // If the file has enough capacity, just update the size.
        if (new_size <= self._data.len) {
            self.inode.size = new_size;
            return;
        }

        // Reallocate buffer and copy old data.
        const new_data = try allocator.alloc(u8, new_size);
        errdefer allocator.free(new_data);
        @memcpy(new_data[0..self.inode.size], self._data);
        allocator.free(self._data);

        // Update information.
        self._data = new_data;
        self.inode.size = new_size;
    }

    /// Read data from the file.
    fn read(self: *FileNode, buf: []u8, pos: usize) Error!usize {
        const end = if (pos + buf.len > self.inode.size) self.inode.size else buf.len;
        const len = end - pos;
        @memcpy(buf[0..len], self._data[pos..end]);

        return len;
    }

    /// Write data to the file.
    ///
    /// If the file doesn't have enough capacity, resize it.
    fn write(self: *FileNode, data: []const u8, pos: usize, allocator: Allocator) Error!usize {
        const end = pos + data.len;
        if (!self.hasCapacity(end)) {
            try self.resize(end, allocator);
        }
        if (self.inode.size < end) {
            self.inode.size = end;
        }
        @memcpy(self._data[pos..end], data);

        return data.len;
    }
};

/// Directory node.
const DirNode = struct {
    const Children = DoublyLinkedList(*Inode);
    const Child = Children.Node;

    /// List of children.
    children: Children,
    /// File name.
    name: []const u8,
    /// inode.
    inode: *Inode,

    /// Create a new directory node.
    pub fn new(name: []const u8, inode: *Inode, allocator: Allocator) Error!DirNode {
        return .{
            .children = Children{},
            .name = try allocator.dupe(u8, name),
            .inode = inode,
        };
    }

    /// Append a dentry to the directory.
    fn append(self: *DirNode, inode: *Inode, allocator: Allocator) Error!void {
        const new_child = try allocator.create(Child);
        new_child.data = inode;
        self.children.append(new_child);
        self.inode.size += 1;
    }

    /// Get a child file named `name`.
    fn getChild(self: *const DirNode, name: []const u8) ?*Inode {
        var current = self.children.first;
        while (current) |child| : (current = child.next) {
            const node = getNode(child.data);
            const node_name = node.getName();
            if (std.mem.eql(u8, name, node_name)) {
                return child.data;
            }
        } else {
            return null;
        }
    }
};

/// Get Self from a context pointer.
inline fn getSelf(inode: *Inode) *Self {
    return @alignCast(@ptrCast(inode.sb.ctx));
}

/// Get a ramfs-specific node from an inode.
inline fn getNode(inode: *Inode) *Node {
    return @alignCast(@ptrCast(inode.ctx.?));
}

/// Create a new inode.
///
/// All variable entries are zero initialized.
fn createInode(self: *Self) Error!*Inode {
    self.lock.lock();
    defer self.lock.unlock();

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

/// Boot time services.
///
/// These functions should NOT be called after the boot process.
///
/// These functions are exceptional in that they spawn `Dentry` by themselves. Usually, it is a duty of VFS.
const boot = struct {
    /// Create a new file in the given directory with the specified name and mode.
    fn createFile(self: *Self, parent: *Inode, name: []const u8, mode: Mode) Error!*Inode {
        const inode = try self.createInode();
        inode.mode = mode;

        const parent_node = &getNode(parent).dir;
        const node = try Node.newFile(
            parent_node,
            name,
            inode,
            self.allocator,
        );
        errdefer self.allocator.destroy(node);
        inode.ctx = @ptrCast(node);

        try parent_node.append(inode, self.allocator);

        return inode;
    }

    /// Create a new directory in the given directory with the specified name and mode.
    fn createDirectory(self: *Self, parent: *Inode, name: []const u8, mode: Mode) Error!*Inode {
        const inode = try self.createInode();
        inode.mode = mode;

        const parent_node = &getNode(parent).dir;
        const node = try Node.newDir(name, inode, self.allocator);
        errdefer self.allocator.destroy(node);
        inode.ctx = @ptrCast(node);

        try parent_node.append(inode, self.allocator);

        return inode;
    }

    /// Parse a CPIO archive image to create files in the filesystem.
    fn loadCpioImage(self: *Self, data: []const u8) (Error || cpio.Error)!void {
        var iter = cpio.CpioIterator.new(data);
        while (try iter.next()) |entry| {
            const path = try entry.getPath();
            const basename = fs.basename(path);
            const mode = try entry.getMode();
            if (shouldIgnore(basename)) continue;

            const parent = getParent(self, path) orelse {
                return Error.InvalidArgument;
            };

            switch (mode.type) {
                // Create a file, then copy data from the archive.
                .regular => {
                    const new = try createFile(
                        self,
                        parent,
                        basename,
                        mode,
                    );
                    const filedata = try entry.getData();
                    const written = try getNode(new).file.write(
                        filedata,
                        0,
                        self.allocator,
                    );
                    norn.rtt.expectEqual(filedata.len, written);
                },

                // Create a directory.
                .dir => {
                    _ = try createDirectory(
                        self,
                        parent,
                        basename,
                        mode,
                    );
                },

                // Unknown file type.
                else => @panic("Unexpected file type in CPIO"),
            }
        }
    }

    /// Get the parent directory.
    ///
    /// `path` can be both absolute and relative.
    /// In either case, it's regarded as relative to the root directory.
    fn getParent(self: *Self, path: []const u8) ?*Inode {
        var parent = self.sb.root.inode;
        var iter = std.fs.path.componentIterator(path) catch return null;

        while (iter.next()) |component| {
            const parent_dir = getNode(parent).dir;
            const name = component.name;
            if (parent_dir.getChild(name)) |child| {
                parent = child;
            } else if (iter.peekNext() == null) {
                return parent;
            } else {
                return null;
            }
        } else {
            return parent;
        }
    }
};

/// Check if the entry should be ignored.
fn shouldIgnore(basename: []const u8) bool {
    return std.mem.eql(u8, basename, ".") or
        std.mem.eql(u8, basename, "..");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

const norn = @import("norn");
const cpio = norn.cpio;
const fs = norn.fs;
const Mode = fs.Mode;
const SpinLock = norn.SpinLock;

const Dentry = @import("Dentry.zig");
const Inode = @import("Inode.zig");
const File = @import("File.zig");
const SuperBlock = @import("SuperBlock.zig");
const FileSystem = @import("FileSystem.zig");
