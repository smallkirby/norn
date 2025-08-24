//! Represents a open file entry.

const Self = @This();
const File = Self;
const Error = fs.FsError;

pub const Ops = struct {
    /// Iterate over all files in this directory inode.
    ///
    /// This function allocates a memory using the given allocator,
    /// then stores file entries in the allocated buffer.
    /// Caller must free the allocated buffer.
    iterate: *const fn (self: *File, allocator: Allocator) Error![]IterResult,
    /// Read data from the file at position `pos` to `buf`.
    ///
    /// Return the number of bytes read.
    read: *const fn (self: *File, buf: []u8, pos: fs.Offset) Error!usize,
    /// Write `data` to the file at position `pos`.
    ///
    /// Return the number of bytes written.
    write: *const fn (self: *File, data: []const u8, pos: fs.Offset) Error!usize,
};

/// Context used in `iterate` operation.
pub const IterResult = struct {
    /// Name of the dentry.
    name: []const u8,
    /// inode number.
    inum: Inode.Number,
    /// File type.
    type: fs.FileType,
};

/// Path of the file.
path: fs.Path,
/// inode this file is associated with.
inode: *Inode,
/// File offset.
offset: fs.Offset,
/// File operations.
ops: Ops,
/// Arbitrary context.
ctx: ?*anyopaque,
/// Memory allocator.
allocator: Allocator,

/// Create a new file instance.
///
/// Variable entry is zero initialized.
pub fn new(path: fs.Path, allocator: Allocator) Error!*File {
    const file = try allocator.create(File);
    file.* = std.mem.zeroInit(File, .{
        .path = path,
        .inode = path.dentry.inode,
        .ops = path.dentry.inode.fops,
        .allocator = allocator,
    });
    return file;
}

/// Deinitialize the file instance.
pub fn deinit(self: *Self) void {
    self.allocator.destroy(self);
}

/// Read data from the file into the buffer.
pub fn read(self: *Self, buf: []u8) Error!usize {
    if (self.inode.isDirectory()) return Error.IsDirectory;

    const num_read = try self.ops.read(
        self,
        buf,
        self.offset,
    );
    self.offset += @intCast(num_read);

    return num_read;
}

/// Get children of the directory.
pub fn iterate(self: *Self, allocator: Allocator) Error![]IterResult {
    if (!self.inode.isDirectory()) return Error.IsDirectory;

    return try self.ops.iterate(self, allocator);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const fs = norn.fs;

const Dentry = @import("Dentry.zig");
const Inode = @import("Inode.zig");
const Mount = @import("Mount.zig");
