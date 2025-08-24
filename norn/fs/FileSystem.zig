const Self = @This();
const FileSystem = Self;
const Error = fs.FsError;

/// Name of the filesystem.
///
/// Used to look up corresponding drivers.
name: []const u8,
/// Mount a filesystem.
///
/// - data: The opaque pointer to the data necessary to initialize the filesystem.
/// - allocator: Memory allocator that the FS can use for general-purposes.
///
/// Returns a inode of the root directory.
mount: *const fn (data: ?*const anyopaque, allocator: Allocator) Error!*SuperBlock,
/// Unmount a filesystem
unmount: *const fn () Error!void,

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const fs = norn.fs;

const Inode = @import("Inode.zig");
const Dentry = @import("Dentry.zig");
const SuperBlock = @import("SuperBlock.zig");
