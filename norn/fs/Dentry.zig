//! Directory entry.
//!
//! Associates an inode with its file name to represent the hierarchical structure of the tree.
//!
//! This structure should be kept away from FS drivers as possible.

const Self = @This();
const Dentry = Self;
const Error = fs.FsError;

/// inode this dentry belongs to.
inode: *Inode,
/// Parent directory.
///
/// Null if this is a root directory.
parent: ?*Dentry,
/// File name.
name: []const u8,

/// Manages dentry caching.
pub const Store = struct {
    /// Hash map that uses both parent and name as key.
    const DcacheMap = std.HashMap(Key, *Dentry, Context, 80);

    /// Key of the hash map.
    const Key = struct {
        parent: *Dentry,
        name: []const u8,
    };

    const Context = struct {
        pub fn hash(_: Context, key: Key) u64 {
            const dentry_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&key.parent));
            const name_hash = std.hash.Wyhash.hash(0, key.name);
            const combined = norn.bits.concat(u128, dentry_hash, name_hash);
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&combined));
        }
        pub fn eql(_: Context, a: Key, b: Key) bool {
            return a.parent == b.parent and std.mem.eql(u8, a.name, b.name);
        }
    };

    _map: DcacheMap,

    /// Create a new dentry store.
    pub fn new(allocator: Allocator) Store {
        return .{
            ._map = DcacheMap.init(allocator),
        };
    }

    /// Lookup a dentry by parent and name.
    pub fn lookup(self: *Store, parent: *Dentry, name: []const u8) ?*Dentry {
        return self._map.get(.{ .parent = parent, .name = name });
    }

    /// Put the dentry to the cache.
    pub fn put(self: *Store, entry: *Dentry) FsError!void {
        try self._map.put(
            .{
                .parent = entry.parent orelse entry,
                .name = entry.name,
            },
            entry,
        );
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const fs = norn.fs;
const FsError = fs.FsError;
const InlineDoublyLinkedList = norn.InlineDoublyLinkedList;

const Inode = @import("Inode.zig");
