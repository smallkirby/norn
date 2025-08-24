//! inode.
//!
//! Represents a file information other than its name.

const Self = @This();
const Inode = Self;
const Error = fs.FsError;

/// inode operations.
pub const Ops = struct {
    /// Lookup an inode by its name.
    ///
    /// - `dir`: Directory inode to look up.
    /// - `name`: Name of the file to look up.
    ///
    /// Returns an inode that is associated with the found file.
    lookup: *const fn (dir: *Inode, name: []const u8) Error!?*Inode,

    /// Create a new file.
    ///
    /// - `dir`: Directory inode to create the file in.
    /// - `name`: Name of the file to create.
    /// - `mode`: Mode of the file to create.
    ///
    /// Returns an inode that is associated with the created file.
    create: *const fn (dir: *Inode, name: []const u8, mode: Mode) Error!*Inode,
};

/// inode number type.
pub const Number = u64;

/// Inode number.
///
/// Unique in a filesystem.
number: Number,
/// File mode.
mode: Mode,
/// User ID.
uid: Uid,
/// Group ID.
gid: Gid,
/// File size.
size: usize,
/// Device number (for character/block devices).
devnum: device.Number = .zero,

/// Last access time.
access_time: TimeSpec,
/// Time of last modification.
modify_time: TimeSpec,
/// Time of last status change (including content change).
change_time: TimeSpec,

/// Operations for this inode.
ops: Ops,
/// Operations for a file associated with this inode.
fops: File.Ops,
/// Super block.
sb: *SuperBlock,
/// Arbitrary context.
ctx: ?*anyopaque,

/// Create a file.
///
/// Returns the inode of the created file, that is not associated with any dentry.
pub fn createFile(self: *Self, name: []const u8, mode: Mode) Error!*Inode {
    if (!self.isDirectory()) {
        return Error.InvalidArgument;
    }

    return self.ops.create(self, name, mode);
}

/// Create a directory.
///
/// Returns the inode of the created file, that is not associated with any dentry.
pub fn createDirectory(self: *Self, name: []const u8, mode: Mode) Error!*Inode {
    if (!self.isDirectory()) {
        return Error.InvalidArgument;
    }

    return self.ops.create(self, name, mode);
}

/// Check if this inode represents a directory.
pub fn isDirectory(self: *Self) bool {
    return self.mode.type == .dir;
}

/// Check if this inode represents a regular file.
pub fn isRegular(self: *Self) bool {
    return self.mode.type == .regular;
}

/// Lookup an inode by its name.
pub fn lookup(self: *Self, name: []const u8) Error!?*Inode {
    if (!self.isDirectory()) return Error.IsDirectory;

    return self.ops.lookup(self, name);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const device = norn.device;
const fs = norn.fs;
const Uid = norn.Uid;
const Gid = norn.Gid;
const Mode = fs.Mode;
const TimeSpec = norn.time.TimeSpec;

const Dentry = @import("Dentry.zig");
const File = @import("File.zig");
const SuperBlock = @import("SuperBlock.zig");
