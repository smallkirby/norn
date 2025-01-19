const std = @import("std");
const Allocator = std.mem.Allocator;
const ComponentIterator = std.fs.path.ComponentIterator;

const norn = @import("norn");

const cpio = @import("fs/cpio.zig");
const vfs = @import("fs/vfs.zig");
const RamFs = @import("fs/RamFs.zig");

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
pub fn init(allocator: Allocator) Error!void {
    const rfs = try RamFs.init(allocator);
    root = rfs.root;
    cwd = rfs.root;
}

/// TODO: doc
pub const OpenFlags = struct {
    /// Create a regular file if it doesn't exist.
    create: bool = false,
};

/// TODO: doc
pub fn open(path: []const u8, flags: OpenFlags, allocator: Allocator) Error!*File {
    const dentry = if (try lookup(path)) |dent| dent else blk: {
        if (!flags.create) return Error.NotFound;
        // Try to create the file.
        const parent = try lookupParent(path) orelse return Error.NotFound;
        const basename = std.fs.path.basenamePosix(path);
        break :blk try parent.fs.createFile(parent, basename);
    };

    const file = try allocator.create(File);
    file.* = .{
        .dentry = dentry,
    };
    return file;
}

pub fn read(file: *File, buf: []u8) Error!usize {
    _ = file; // autofix
    _ = buf; // autofix
    norn.unimplemented("fs.read");
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

pub fn mkdir(path: []const u8) Error!void {
    _ = path; // autofix
    norn.unimplemented("fs.mkdir");
}

pub fn close(file: *File, allocator: Allocator) Error!void {
    allocator.destroy(file);
}

/// Lookup a dentry by path lexically.
fn lookup(path: []const u8) Error!?*vfs.Dentry {
    const parent = try lookupParent(path) orelse return null;
    const basename = std.fs.path.basenamePosix(path);
    return parent.fs.lookup(parent, basename);
}

/// Lookup the parent dentry of the given path.
///
/// If the parent dentry is not found, return null.
/// This function looks up lexically, so "/a/b/c/." returns "/a/b/c".
fn lookupParent(path: []const u8) Error!?*vfs.Dentry {
    var iter = try ComponentIterator(.posix, u8).init(path);

    // Decide the starting dentry.
    const is_absolute = blk: {
        if (iter.root()) |r| {
            break :blk std.mem.eql(u8, r, &[_]u8{separator});
        } else break :blk false;
    };
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
            if (try cur_dentry.fs.lookup(cur_dentry, component.name)) |next_dentry| {
                cur_dentry = next_dentry;
            } else {
                return null;
            }
        }
    }

    return cur_dentry.parent;
}

// ==============================

test {
    std.testing.refAllDeclsRecursive(@This());
}
