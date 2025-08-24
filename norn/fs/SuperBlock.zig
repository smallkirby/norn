//! Instance of a filesystem.

const Self = @This();
const SuperBlock = Self;
const Error = fs.FsError;

/// Superblock operations.
pub const Ops = struct {};

/// Root directory of the tree.
///
/// It does not have a name and a parent.
root: *Dentry,
/// Superblock operations.
ops: Ops,
/// Arbitrary context pointer.
ctx: *anyopaque,

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const fs = norn.fs;

const Dentry = @import("Dentry.zig");
const Inode = @import("Inode.zig");
