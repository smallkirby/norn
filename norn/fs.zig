/// FS Error.
pub const Error = error{
    /// File not found.
    NotFound,
    /// File already exists.
    AlreadyExists,
} || vfs.Error;

/// Path separator.
pub const separator = '/';

/// File instance.
pub const File = struct {
    /// Offset within the file.
    pos: usize = 0,
    /// Dentry of the file.
    dentry: *vfs.Dentry,

    /// Create a new file instance.
    pub fn new(dentry: *vfs.Dentry) File {
        return .{
            .dentry = dentry,
        };
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

/// Root directory.
/// TODO: Make this per-thread.
var root: *vfs.Dentry = undefined;
/// Current working directory.
/// TODO: Make this per-thread.
var cwd: *vfs.Dentry = undefined;

/// Initialize filesystem.
pub fn init() Error!void {
    const rfs = try RamFs.init(allocator);
    root = rfs.root;
    cwd = rfs.root;
}

/// Load initramfs image and create entries.
///
/// - `initimg`: Initramfs image. Caller can free this memory after this function returns.
pub fn loadInitImage(initimg: []const u8) (Error || cpio.Error)!void {
    var iter = cpio.CpioIterator.new(initimg);
    var cur = try iter.next();

    // Iterate over entries in the CPIO archive.
    while (cur) |c| : (cur = try iter.next()) {
        const path = try c.getPath();
        const basename = std.fs.path.basenamePosix(path);
        const mode = try c.getMode();

        if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) {
            continue;
        }

        // Check if the target file already exists.
        if (try lookup(path) != null) {
            log.warn("File already exists: {s}", .{path});
            continue;
        }
        // Check if the parent directory exists.
        const parent = try lookupParent(path) orelse {
            log.warn("Parent directory not found: {s}", .{path});
            continue;
        };

        // Create the file or directory.
        if (bits.isset(mode, 14)) {
            _ = try parent.createDirectory(basename);
        } else {
            const dentry = try parent.createFile(basename);
            _ = try dentry.inode.write(try c.getData(), 0);
        }
    }

    // Debug print the loaded file tree.
    const ramfs: *RamFs = @alignCast(@ptrCast(root.fs.ctx));
    log.debug("=== Directory Tree ==================", .{});
    ramfs.printTree(log.debug);
    log.debug("=====================================", .{});
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
pub fn open(path: []const u8, flags: OpenFlags) Error!*File {
    // TODO: use mode

    const dentry = if (try lookup(path)) |dent| dent else blk: {
        if (!flags.create) return Error.NotFound;
        // Try to create the file.
        const parent = try lookupParent(path) orelse return Error.NotFound;
        const basename = std.fs.path.basenamePosix(path);
        break :blk try parent.createFile(basename);
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

pub fn mkdir(path: []const u8) Error!void {
    _ = path; // autofix
    norn.unimplemented("fs.mkdir");
}

pub fn close(file: *File) void {
    allocator.destroy(file);
}

/// Lookup a dentry by path lexically.
fn lookup(path: []const u8) Error!?*vfs.Dentry {
    const parent = try lookupParent(path) orelse return null;
    const basename = std.fs.path.basenamePosix(path);
    return parent.inode.lookup(basename);
}

/// Lookup the parent dentry of the given path.
///
/// If the parent dentry is not found, return null.
/// This function looks up lexically, so "/a/b/c/." returns "/a/b/c".
fn lookupParent(path: []const u8) Error!?*vfs.Dentry {
    var iter = try ComponentIterator(.posix, u8).init(path);

    // Decide the starting dentry.
    const is_absolute = std.fs.path.isAbsolutePosix(path);
    var cur_dentry = if (is_absolute) root else cwd;

    // Iterate over the components lexically.
    var next = iter.next();
    while (next) |component| : (next = iter.next()) {
        // If the next component is null, we've reached the last component (child of the parent).
        if (iter.peekNext() == null) break;

        if (std.mem.eql(u8, component.name, ".")) {
            // ".": Just skip.
            continue;
        } else if (std.mem.eql(u8, component.name, "..")) {
            // "..": Move to parent directory.
            cur_dentry = cur_dentry.parent;
        } else {
            // Lookup the component.
            if (try cur_dentry.inode.lookup(component.name)) |next_dentry| {
                cur_dentry = next_dentry;
            } else {
                return null;
            }
        }
    }

    return cur_dentry;
}

// ==============================

test {
    std.testing.refAllDeclsRecursive(@This());
}

// ==============================

const std = @import("std");
const log = std.log.scoped(.fs);
const Allocator = std.mem.Allocator;
const ComponentIterator = std.fs.path.ComponentIterator;

const norn = @import("norn");
const bits = norn.bits;

const cpio = @import("fs/cpio.zig");
const RamFs = @import("fs/RamFs.zig");
const vfs = @import("fs/vfs.zig");
const Stat = vfs.Stat;

const allocator = norn.mem.general_allocator;
