/// FS Error.
pub const Error = error{
    /// File not found.
    NotFound,
    /// File already exists.
    AlreadyExists,
    /// Invalid argument.
    InvalidArgument,
} || vfs.Error;

pub const Stat = vfs.Stat;

/// Path separator.
pub const separator = '/';

/// File instance.
pub const File = struct {
    /// Offset within the file.
    pos: usize = 0,
    /// Dentry of the file.
    dentry: *vfs.Dentry,

    /// Create a new file instance.
    pub fn new(inode: *vfs.Inode) File {
        return .{
            .inode = inode,
        };
    }
};

/// TODO: doc
const FileDescriptor = i32;

/// Filesystem associated with a thread.
pub const ThreadFs = struct {
    const Self = @This();

    /// Root directory.
    root: *vfs.Dentry,
    /// Current working directory.
    cwd: *vfs.Dentry,
    /// File descriptor table.
    fdtable: FdTable,

    /// Instantiate a new thread filesystem.
    pub fn new(root: *vfs.Dentry, cwd: *vfs.Dentry) Self {
        return .{
            .cwd = root,
            .root = cwd,
            .fdtable = FdTable.new(),
        };
    }
};

/// File descriptor table.
const FdTable = struct {
    const Self = @This();
    const FdMap = std.AutoHashMap(FileDescriptor, *File);

    /// Special file descriptor for CWD.
    const fd_cwd = -100;

    /// Mapping of file descriptors to file instances.
    _map: FdMap,

    /// Insntantiate a new file descriptor table.
    pub fn new() Self {
        return .{
            ._map = FdMap.init(allocator),
        };
    }

    /// Deinitialize and free the resources.
    pub fn deinit(self: *Self) void {
        self._map.deinit();
    }

    /// Get the i-node corresponding to the file descriptor.
    pub fn getDentry(self: *Self, fd: FileDescriptor) ?*Dentry {
        if (fd == fd_cwd) {
            return sched.getCurrentTask().fs.cwd;
        } else {
            const result = self._map.get(fd);
            return if (result) |r| r.dentry else null;
        }
    }
};

/// Seek mode.
pub const SeekMode = enum {
    /// Seek from the beginning of the file.
    Set,
    /// Seek from the current position.
    Current,
    /// Seek from the end of the file.
    End,
};

var ramfs: *RamFs = undefined;

/// Initialize filesystem.
pub fn init() Error!void {
    ramfs = try RamFs.init(allocator);
}

/// Load initramfs cpio image and create entries.
///
/// - `initimg`: Initramfs image. Caller can free this memory after this function returns.
pub fn loadInitImage(initimg: []const u8) (Error || cpio.Error)!void {
    var iter = cpio.CpioIterator.new(initimg);
    var cur = try iter.next();

    // Iterate over entries in the CPIO archive.
    while (cur) |c| : (cur = try iter.next()) {
        const path = try c.getPath();
        const basename = std.fs.path.basenamePosix(path);
        const posix_mode = try c.getMode();
        const mode = Mode.fromPosixMode(@truncate(posix_mode));

        if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) {
            continue;
        }

        // Check if the target file already exists.
        if (lookup(.{ .dir = ramfs.root }, path) != null) {
            log.warn("File already exists: {s}", .{path});
            continue;
        }
        // Check if the parent directory exists.
        const parent = kerneLookupParent(.{ .dir = ramfs.root }, path) orelse {
            log.warn("Parent directory not found: {s}", .{path});
            continue;
        };

        // Create the file or directory.
        if (bits.isset(posix_mode, 14)) {
            _ = try parent.createDirectory(basename, mode);
        } else {
            const dentry = try parent.createFile(basename, mode);
            _ = try dentry.inode.write(try c.getData(), 0);
        }
    }

    // Set root and cwd.
    const current = sched.getCurrentTask();
    current.fs.root = ramfs.root;
    current.fs.cwd = ramfs.root;

    // Debug print the loaded file tree.
    log.debug("=== Initial FS ======================", .{});
    printDirectoryTree(ramfs.root) catch |err| {
        log.err("Failed to print directory tree: {s}", .{@errorName(err)});
    };
    log.debug("=====================================", .{});
}

/// Get the dentry from the file descriptor.
pub fn getDentryFromFd(fd: FileDescriptor) ?*vfs.Dentry {
    return sched.getCurrentTask().fs.fdtable.getDentry(fd);
}

pub const OpenMode = enum {
    /// Open the file in read-only mode.
    read_only,
    /// Open the file in write-only mode.
    read_write,
};

/// TODO: doc
pub const OpenFlags = struct {
    const Self = @This();

    /// Mode to open the file.
    mode: OpenMode = .read_only,
    /// Create a new file if it does not exist.
    create: bool = false,

    pub const create_rw = Self{
        .mode = .read_write,
        .create = true,
    };
};

/// TODO: doc
pub fn open(path: []const u8, flags: OpenFlags, mode: ?Mode) Error!*File {
    // TODO: use mode

    const dentry = if (lookup(.origin_cwd, path)) |dent| dent else blk: {
        if (!flags.create) return Error.NotFound;
        if (mode) |m| {
            // Try to create the file.
            const parent = kerneLookupParent(.origin_cwd, path) orelse return Error.NotFound;
            const basename = std.fs.path.basenamePosix(path);
            break :blk try parent.createFile(basename, m);
        } else {
            // TODO: use default mode.
            return Error.InvalidArgument;
        }
    };

    const file = try allocator.create(File);
    file.* = .{
        .dentry = dentry,
    };
    return file;
}

pub fn read(file: *File, buf: []u8) Error!usize {
    const bytesRead = try file.dentry.inode.read(buf, file.pos);
    file.pos += bytesRead;
    return bytesRead;
}

pub fn write(file: *File, buf: []const u8) Error!usize {
    _ = file; // autofix
    _ = buf; // autofix
    norn.unimplemented("fs.write");
}

pub fn seek(file: *File, offset: usize, whence: SeekMode) Error!usize {
    _ = file; // autofix
    _ = offset; // autofix
    _ = whence; // autofix
    norn.unimplemented("fs.seek");
}

pub fn stat(file: *File) Error!Stat {
    return try file.dentry.inode.stat();
}

pub fn statAt(dir: *vfs.Dentry, path: []const u8) Error!Stat {
    const dent = lookup(.{ .dir = dir }, path) orelse return Error.NotFound;
    return try dent.inode.stat();
}

pub fn mkdir(path: []const u8) Error!void {
    _ = path; // autofix
    norn.unimplemented("fs.mkdir");
}

pub fn close(file: *File) void {
    allocator.destroy(file);
}

/// The origin of the lookup path.
const LookupOrigin = union(Tag) {
    /// Lookup path from CWD.
    cwd: void,
    /// Lookup path from the given directory.
    dir: *vfs.Dentry,

    const Tag = enum {
        /// Lookup path from CWD.
        cwd,
        /// Lookup path from the given directory.
        dir,
    };

    pub const origin_cwd = LookupOrigin{ .cwd = {} };
};

/// Lookup a dentry by path.
///
/// This function searches for a file in the given directory.
/// This function can take a path string with more than one level of depth.
///
/// If it encounters a component that does not exist, the search stops and returns null.
/// For example, `dne/..` will fail if `dne` does not exist.
pub fn lookup(origin: LookupOrigin, path: []const u8) ?*vfs.Dentry {
    // Calculate the origin dentry to start the lookup.
    var iter = ComponentIterator(.posix, u8).init(path) catch {
        return null;
    };
    const is_absolute = std.fs.path.isAbsolutePosix(path);
    var dent = blk: {
        if (is_absolute) {
            break :blk sched.getCurrentTask().fs.root;
        } else break :blk switch (origin) {
            .cwd => sched.getCurrentTask().fs.cwd,
            .dir => |d| d,
        };
    };

    // Iterate over the components of the path.
    var next = iter.next();
    while (next) |component| : (next = iter.next()) {
        if (std.mem.eql(u8, component.name, ".")) {
            continue;
        } else if (std.mem.eql(u8, component.name, "..")) {
            dent = dent.parent;
        } else {
            const result = dent.inode.lookup(component.name) catch return null;
            if (result) |next_dentry| {
                dent = next_dentry;
            } else {
                return null;
            }
        }
    }

    return dent;
}

/// Lookup a parent of the given path lexically.
fn kerneLookupParent(origin: LookupOrigin, path: []const u8) ?*vfs.Dentry {
    // Calculate the origin dentry to start the lookup.
    var iter = ComponentIterator(.posix, u8).init(path) catch {
        return null;
    };
    const is_absolute = std.fs.path.isAbsolutePosix(path);
    var dent = blk: {
        if (is_absolute) {
            break :blk sched.getCurrentTask().fs.root;
        } else break :blk switch (origin) {
            .cwd => sched.getCurrentTask().fs.cwd,
            .dir => |d| d,
        };
    };

    // Iterate over the components of the path.
    var next = iter.next();
    while (next) |component| : (next = iter.next()) {
        if (std.mem.eql(u8, component.name, ".")) {
            continue;
        } else if (std.mem.eql(u8, component.name, "..")) {
            dent = dent.parent;
        } else {
            const result = dent.inode.lookup(component.name) catch return null;
            if (result) |next_dentry| {
                dent = next_dentry;
            } else if (iter.peekNext() == null) {
                return dent;
            } else {
                return null;
            }
        }
    } else {
        return dent.parent;
    }
}

// =============================================================
// Debug
// =============================================================

/// Print the directory tree.
fn printDirectoryTree(root: *vfs.Dentry) Error!void {
    var current_path = std.mem.zeroes([4096]u8);
    try printDirectoryTreeSub(root, current_path[0..current_path.len]);
}

fn printDirectoryTreeSub(dir: *const Dentry, current_path: []u8) Error!void {
    const parent_end_pos = blk: {
        for (current_path, 0..) |c, i| {
            if (c == 0) break :blk i;
        } else {
            break :blk current_path.len;
        }
    };
    current_path[parent_end_pos] = separator;

    const children = try dir.inode.iterate(allocator);
    for (children) |child| {
        // Copy entry name.
        const len = parent_end_pos + 1 + child.name.len;
        std.mem.copyBackwards(u8, current_path[parent_end_pos + 1 ..], child.name);
        current_path[len] = 0;

        // Print the entry.
        log.debug(
            "{[perm]s}  {[uid]d: <4} {[gid]d: <4} {[size]d: >8} {[name]s}",
            .{
                .perm = child.inode.mode.toString(),
                .uid = child.inode.uid,
                .gid = child.inode.gid,
                .size = child.inode.size,
                .name = current_path[0..len],
            },
        );

        // Recurse if the entry is a directory.
        if (child.inode.inode_type == .directory) {
            try printDirectoryTreeSub(child, current_path);
        }
    }
}

// =============================================================
// Tests
// =============================================================

test {
    std.testing.refAllDeclsRecursive(@This());
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.fs);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ComponentIterator = std.fs.path.ComponentIterator;

const norn = @import("norn");
const bits = norn.bits;
const sched = norn.sched;

const cpio = @import("fs/cpio.zig");
const RamFs = @import("fs/RamFs.zig");
const vfs = @import("fs/vfs.zig");
const Dentry = vfs.Dentry;
const Mode = vfs.Mode;

const allocator = norn.mem.general_allocator;
