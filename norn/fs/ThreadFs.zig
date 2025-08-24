//! Filesystem information associated with a thread.

const Self = @This();

/// Root directory.
root: Path,
/// Current working directory.
cwd: Path,
/// File descriptor table.
fdtable: FdTable,
/// Memory allocator.
allocator: Allocator,

/// Instantiate a new thread filesystem.
pub fn new(root: Path, cwd: Path, allocator: Allocator) Self {
    return .{
        .cwd = cwd,
        .root = root,
        .fdtable = FdTable.new(allocator),
        .allocator = allocator,
    };
}

/// Set root directory.
pub fn setRoot(self: *Self, path: Path) void {
    self.root = path;
}

/// Set CWD.
pub fn setCwd(self: *Self, path: Path) void {
    self.cwd = path;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const Path = norn.fs.Path;
const FdTable = @import("FdTable.zig");
