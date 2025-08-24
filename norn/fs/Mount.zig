//! Mount information.
//!
//! This struct represents a mounted filesystem and its associated information.

const Self = @This();
const Mount = Self;
const Error = fs.FsError;

/// Root dentry of the mounted tree.
///
/// Unlike `root` of `SuperBlock`, this root dentry may have a name and a parent.
///
/// When `/dev/sda1` is mounted to `/mnt/hoge`,
/// `root` of the `Mount` is `/` of the sda1 filesystem (same with `SuperBlock.root`).
///
/// When `/home/user` is bind-mounted to `/mnt/hoge`,
/// `root` of the `Mount` is `/home/user` while `SuperBlock.root` is `/` of the root filesystem.
root: *Dentry,
/// Parent mount.
///
/// Null if this mount is the root mount.
parent: ?*Mount,
/// Super block of this mount.
sb: *SuperBlock,
/// Dentry of a directory to which this mount is attached.
mntpoint: *Dentry,

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const fs = norn.fs;

const Dentry = @import("Dentry.zig");
const SuperBlock = @import("SuperBlock.zig");
