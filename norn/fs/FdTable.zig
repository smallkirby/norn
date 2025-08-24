//! File descriptor table.
//!
//! Each thread has its own file descriptor table to manage open files.

const Self = @This();
const FdMap = std.AutoHashMap(FileDescriptor, *File);

/// Mapping of file descriptors to file instances.
_map: FdMap,
/// Next fd to be used.
_next_fd: FileDescriptor,
/// Spin lock.
_lock: SpinLock,

/// Insntantiate a new file descriptor table.
pub fn new(allocator: Allocator) Self {
    // TODO: open stdin, stdout, and stderr.
    return .{
        ._map = FdMap.init(allocator),
        ._next_fd = @enumFromInt(3),
        ._lock = SpinLock{},
    };
}

/// Deinitialize and free the resources.
pub fn deinit(self: *Self) void {
    self._map.deinit();
}

/// Add a file to the file descriptor table.
pub fn put(self: *Self, file: *File) FsError!FileDescriptor {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    const fd = self._next_fd;
    self._next_fd = @enumFromInt(@intFromEnum(fd) + 1);
    self._map.put(fd, file) catch return FsError.DescriptorFull;

    return fd;
}

/// Delete a file descriptor and close an associated file.
pub fn remove(self: *Self, fd: FileDescriptor) FsError!void {
    // TODO: check if there're no references.

    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    const file = self.get(fd) orelse return FsError.NotFound;
    file.deinit();

    norn.rtt.expect(self._map.remove(fd));
}

/// Get a path corresponding to the file descriptor.
///
/// This function accepts a special descriptor: CWD.
pub fn getPath(self: *Self, fd: FileDescriptor) ?Path {
    if (fd == .cwd) {
        return fs.getCwd();
    } else {
        const result = self._map.get(fd);
        return if (result) |r| r.path else null;
    }
}

/// Get a file instance corresponding to the file descriptor.
pub fn get(self: *Self, fd: FileDescriptor) ?*File {
    const result = self._map.get(fd);
    return if (result) |r| r else null;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const fs = norn.fs;
const SpinLock = norn.SpinLock;

const File = fs.File;
const FileDescriptor = fs.FileDescriptor;
const Path = fs.Path;
const FsError = fs.FsError;
