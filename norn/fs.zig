const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");

const cpio = @import("fs/cpio.zig");
const vfs = @import("fs/vfs.zig");
const RamFs = @import("fs/RamFs.zig");

/// FS Error.
pub const Error = error{} || vfs.Error;

/// Path separator.
pub const separator = '/';

/// File instance.
pub const File = struct {
    /// Offset within the file.
    pos: usize,
    /// Dentry of the file.
    dentry: *vfs.Dentry,
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

pub fn open(path: []const u8) Error!*File {
    _ = path; // autofix
    norn.unimplemented("fs.open");
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
    var iter = try std.fs.path.ComponentIterator(.posix, u8).init(path);
    const is_absolute = if (iter.root()) |r| std.mem.eql(u8, r, &[_]u8{separator}) else false;
    var cur = if (is_absolute) root else cwd;

    var iter_cur = iter.next();
    while (iter_cur) |component| : (iter_cur = iter.next()) {
        if (std.mem.eql(u8, component.name, ".")) {
            continue;
        } else if (std.mem.eql(u8, component.name, "..")) {
            cur = cur.parent;
        } else {
            if (try cur.fs.lookup(cur, component.name)) |next| {
                cur = next;
            } else {
                // TODO: check if it's the last component
                _ = try cur.fs.createDirectory(cur, component.name);
            }
        }
    }
}

pub fn close(file: *File) Error!void {
    _ = file; // autofix
    norn.unimplemented("fs.close");
}

// ==============================

test {
    std.testing.refAllDeclsRecursive(@This());
}
