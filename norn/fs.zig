// =============================================================
// Error.
// =============================================================

/// FS Error.
pub const FsError = error{
    /// File already exists.
    AlreadyExists,
    /// The file descriptor is invalid.
    BadFileDscriptor,
    /// No available file descriptor in pool.
    DescriptorFull,
    /// Invalid argument.
    InvalidArgument,
    /// Operation for regular file only is called on a non-regular file.
    IsDirectory,
    /// Operation for directory only is called on a non-directory.
    NotDirectory,
    /// File not found.
    NotFound,
    /// Failed to allocate memory.
    OutOfMemory,
    /// Calculation result overflowed or underflowed.
    Overflow,
};

/// Convert FsError to syscall error type.
fn syscallError(err: FsError) SysError {
    const E = FsError;
    const S = SysError;
    return switch (err) {
        E.AlreadyExists => S.Exist,
        E.BadFileDscriptor => S.BadFd,
        E.DescriptorFull => S.FdTooMany,
        E.InvalidArgument => S.InvalidArg,
        E.IsDirectory => S.IsDir,
        E.NotDirectory => S.NotDir,
        E.NotFound => S.NoEntry,
        E.OutOfMemory => S.NoMemory,
        E.Overflow => S.OutOfRange,
    };
}

// =============================================================
// Constants.
// =============================================================

pub const Stat = vfs.Stat;

/// Path separator.
pub const separator = '/';

/// Maximum path length.
pub const path_max = 4096;

/// Describes an open file.
pub const FileDescriptor = enum(i32) {
    /// Standard input.
    stdin = 0,
    /// Standard output.
    stdout = 1,
    /// Standard error.
    stderr = 2,

    /// Current working directory.
    cwd = -100,

    _,

    /// Check if the file descriptor is a special descriptor.
    pub fn isSpecial(self: FileDescriptor) bool {
        return switch (self) {
            .stdin, .stdout, .stderr, .cwd => true,
            else => false,
        };
    }

    /// Get a backing integer.
    pub inline fn value(self: FileDescriptor) i32 {
        return @intFromEnum(self);
    }
};

/// Filesystem associated with a thread.
pub const ThreadFs = struct {
    const Self = @This();

    /// Root directory.
    root: *vfs.Dentry,
    /// Current working directory.
    cwd: *vfs.Dentry,
    /// File descriptor table.
    fdtable: FdTable,

    /// Instantiate a new thread filesystem.
    pub fn new(root: *vfs.Dentry, cwd: *vfs.Dentry) Self {
        return .{
            .cwd = root,
            .root = cwd,
            .fdtable = FdTable.new(),
        };
    }

    /// Set root directory.
    pub fn setRoot(self: *Self, dentry: *Dentry) void {
        self.root = dentry;
    }

    /// Set CWD.
    pub fn setCwd(self: *Self, dentry: *Dentry) void {
        self.cwd = dentry;
    }
};

/// File descriptor table.
const FdTable = struct {
    const Self = @This();
    const FdMap = std.AutoHashMap(FileDescriptor, *File);

    /// Mapping of file descriptors to file instances.
    _map: FdMap,
    /// Next fd to be used.
    _next_fd: FileDescriptor = @enumFromInt(3),

    /// Insntantiate a new file descriptor table.
    pub fn new() Self {
        return .{
            ._map = FdMap.init(allocator),
        };
    }

    /// Deinitialize and free the resources.
    pub fn deinit(self: *Self) void {
        self._map.deinit();
    }

    /// Add a file to the file descriptor table.
    pub fn put(self: *Self, file: *File) FsError!FileDescriptor {
        // TODO: should lock?
        const fd = self._next_fd;
        self._next_fd = @enumFromInt(@intFromEnum(fd) + 1);
        self._map.put(fd, file) catch return FsError.DescriptorFull;
        return fd;
    }

    /// Delete a file descriptor and close an associated file.
    pub fn remove(self: *Self, fd: FileDescriptor) ?void {
        const file = self.get(fd) orelse return null;
        file.deinit();
        norn.rtt.expectEqual(true, self._map.remove(fd));
    }

    /// Get the i-node corresponding to the file descriptor.
    pub fn getDentry(self: *Self, fd: FileDescriptor) ?*Dentry {
        if (fd == .cwd) {
            return sched.getCurrentTask().fs.cwd;
        } else {
            const result = self._map.get(fd);
            return if (result) |r| r.dentry else null;
        }
    }

    /// Get a file instance corresponding to the file descriptor.
    pub fn get(self: *Self, fd: FileDescriptor) ?*File {
        const result = self._map.get(fd);
        return if (result) |r| r else null;
    }
};

/// Open mode.
pub const OpenMode = enum {
    /// Open the file in read-only mode.
    read_only,
    /// Open the file in write-only mode.
    write_only,
    /// Open the file in read/write mode.
    read_write,
};

/// Flags for opening a file.
pub const OpenFlags = struct {
    const Self = @This();

    /// Mode to open the file.
    mode: OpenMode = .read_only,
    /// Create a new file if it does not exist.
    create: bool = false,

    /// Read write mode. Create a new file if it does not exist.
    pub const create_rw = Self{
        .mode = .read_write,
        .create = true,
    };

    /// Create flags from POSIX open flags.
    pub fn fromPosix(pflags: posix.fs.OpenFlags) OpenFlags {
        return .{
            .mode = blk: {
                if (pflags.read_only) {
                    break :blk .read_only;
                }
                if (pflags.write_only) {
                    break :blk .write_only;
                }
                if (pflags.read_write) {
                    break :blk .read_write;
                }
                break :blk .read_only;
            },
            .create = pflags.create,
        };
    }
};

/// Device major and minor numbers.
pub const DevType = vfs.DevType;
/// i-node.
pub const Inode = vfs.Inode;

/// File operations.
pub const Fops = vfs.File.Vtable;

/// Initialize filesystem.
pub fn init() FsError!void {
    norn.rtt.expectEqual(0, sched.getCurrentTask().tid);

    // Init VFS system.
    try vfs.init(allocator);

    // Set root and CWD.
    sched.getCurrentTask().fs.setRoot(vfs.getRoot());
    sched.getCurrentTask().fs.setCwd(vfs.getRoot());
}

/// Load initramfs cpio image and mount ramfs.
///
/// - `initimg`: Initramfs image. Caller can free this memory after this function returns.
pub fn loadInitImage(initimg: []const u8) (FsError || cpio.Error)!void {
    // Init ramfs.
    const ramfs = try RamFs.from(initimg, allocator);

    // Mount ramfs on root directory.
    try vfs.mount(ramfs.fs, "/", allocator);
}

/// Get the dentry from the file descriptor.
pub fn getDentryFromFd(fd: FileDescriptor) ?*vfs.Dentry {
    return sched.getCurrentTask().fs.fdtable.getDentry(fd);
}

// =============================================================
// System call handlers.
// =============================================================

/// Linux-compatible linux_dirent64 structure.
///
/// This structure has variable length described by `reclen` field.
const DirEnt64 = extern struct {
    const Self = @This();

    /// Inode number.
    inode_number: u64,
    /// Filesystem-specific value.
    spec: u64 = 0,
    /// Size of this structure.
    reclen: u16,
    /// File type.
    type: vfs.FileType align(1),
    /// Filename starts here.
    __name_start: void = undefined,

    const struct_size = @offsetOf(Self, "__name_start");
    const ReclenType = @FieldType(DirEnt64, "reclen");

    /// Calculate the entire structure size that has the specified name.
    ///
    /// - `name`: Name of the file. Must NOT be null-terminated.
    pub fn calcSize(name: []const u8) ReclenType {
        norn.rtt.expect(0 != name[name.len - 1]);
        return @intCast(struct_size + name.len + 1); // +1 for null-termination.
    }

    /// Create a new DirEnt64 instance with the given name in the buffer.
    pub fn createCopy(dentry: *const Dentry, buf: []u8) void {
        const name = dentry.name;
        const size = calcSize(name);
        norn.rtt.expectEqual(size, buf.len);

        // Copy fixed-size part.
        const dirent = Self{
            .inode_number = dentry.inode.number,
            .reclen = size,
            .type = dentry.inode.mode.type,
        };
        var cur: [*]u8 = buf.ptr;
        @memcpy(cur[0..struct_size], std.mem.asBytes(&dirent)[0..struct_size]);
        cur += struct_size;

        // Copy name part.
        @memcpy(cur[0..name.len], name);
        cur[name.len] = 0; // null-terminate
    }

    comptime {
        norn.comptimeAssert(19 == struct_size, "Size of DirEnt64 must be 19.", .{});
    }
};

/// Get the file descriptor table of the current task.
inline fn getCurrentFdTable() *FdTable {
    return &sched.getCurrentTask().fs.fdtable;
}

/// Change current working directory of the process.
pub fn sysChdir(pathname: [*:0]const u8) SysError!i64 {
    const path = util.sentineledToSlice(pathname);
    if (lookup(.cwd, path)) |dentry| {
        if (dentry.inode.mode.type != .directory) {
            return SysError.NotDir;
        }

        sched.getCurrentTask().fs.cwd = dentry;
    } else return SysError.NoEntry;

    return 0;
}

/// Get current working directory.
pub fn sysGetCwd(buf: [*]allowzero u8, size: usize) SysError!i64 {
    if (@intFromPtr(buf) == 0) {
        return SysError.InvalidArg;
    }
    if (size == 0) {
        return SysError.InvalidArg;
    }

    const cwd = sched.getCurrentTask().fs.cwd.name;
    if (cwd.len + 1 > size) {
        return SysError.OutOfRange;
    }

    @memcpy(buf[0..cwd.len], cwd);
    buf[cwd.len] = 0; // null-terminate

    return 0;
}

/// Get as much directory entries from the given directory.
///
/// - `fd: File descriptor that describes a directory from which entries are read.
/// - `dirp`: Pointer to buffer to which DirEnt64 is written.
/// - `count`: Size of `dirp` buffer in bytes.
///
/// On success, the number of bytes read is returned.
/// On end of directory, 0 is returned.
pub fn sysGetDents64(fd: FileDescriptor, dirp: [*]u8, count: usize) SysError!i64 {
    const file = getCurrentFdTable().get(fd) orelse return SysError.NoEntry;
    if (file.dentry.inode.mode.type != .directory) {
        return SysError.NotDir;
    }

    var consumed: usize = 0;

    const children = file.iterate() catch |err| return syscallError(err);

    // All entries are already read.
    if (children.len <= file.pos) {
        return 0;
    }

    // Iterate entries and fill the user buffer.
    const start = file.pos;
    for (children[start..]) |child| {
        const dirent_size = DirEnt64.calcSize(child.name);
        if (count - consumed < dirent_size) {
            break;
        }

        const ptr = dirp + consumed;
        DirEnt64.createCopy(child, ptr[0..dirent_size]);
        consumed += dirent_size;
        file.pos += 1;
    }

    return @bitCast(consumed);
}

/// Syscall handler for `fstat`.
pub fn sysFstat(fd: FileDescriptor, buf: *Stat) SysError!i64 {
    if (getCurrentFdTable().get(fd)) |f| {
        buf.* = stat(f) catch return SysError.NoEntry;
    } else return SysError.NoEntry;

    return 0;
}

/// Syscall handler for `newfstatat`.
///
/// TODO: Use flags argument.
pub fn sysNewFstatAt(fd: FileDescriptor, pathname: [*:0]const u8, buf: *Stat, _: u64) SysError!i64 {
    if (getDentryFromFd(fd)) |dent| {
        buf.* = statAt(
            dent,
            util.sentineledToSlice(pathname),
        ) catch return SysError.NoEntry;
    } else return SysError.NoEntry;

    return 0;
}

/// Syscall handler for `close`.
pub fn sysClose(fd: FileDescriptor) syscall.SysError!i64 {
    getCurrentFdTable().remove(fd) orelse return SysError.BadFd;
    return 0;
}

/// Syscall handler for `openat`.
pub fn sysOpenAt(fd: FileDescriptor, pathname: [*:0]const u8, flags: posix.fs.OpenFlags, mode: vfs.Mode) SysError!i64 {
    const file = openFileAt(
        fd,
        util.sentineledToSlice(pathname),
        OpenFlags.fromPosix(flags),
        mode,
    ) catch |err| return syscallError(err);

    const result = getCurrentFdTable().put(file) catch |err| return syscallError(err);
    return @intFromEnum(result);
}

/// Syscall handler for `read`.
///
/// Currently, only supports reading from stdin (fd=0).
pub fn sysRead(fd: FileDescriptor, buf: [*]u8, size: usize) SysError!i64 {
    const file = getCurrentFdTable().get(fd) orelse return SysError.BadFd;
    const num_read = file.read(buf[0..size]) catch |err| return syscallError(err);
    return @bitCast(num_read);
}

// =============================================================
// File operations.
// =============================================================

/// Open a file by path.
///
/// This function tries to open a file by the given path.
/// Returns a file instance if the file is found or created.
///
/// Note that this function does not add the file to the descriptor table.
pub fn openFile(path: []const u8, flags: OpenFlags, mode: ?Mode) FsError!*File {
    return openFileAt(.cwd, path, flags, mode);
}

/// Open a file by path.
///
/// This function tries to open a file by the given path.
/// Returns a file instance if the file is found or created.
///
/// Note that this function does NOT add the file to the descriptor table.
pub fn openFileAt(fd: FileDescriptor, pathname: []const u8, flags: OpenFlags, mode: ?vfs.Mode) FsError!*File {
    const current = norn.sched.getCurrentTask();
    const is_absolute = std.fs.path.isAbsolutePosix(pathname);
    const origin = getDentryFromFd(fd) orelse blk: {
        if (!is_absolute) return FsError.BadFileDscriptor else break :blk current.fs.cwd;
    };

    // Get a dentry from the path.
    const dentry = if (lookup(.{ .dir = origin }, pathname)) |dent| dent else blk: {
        if (!flags.create) return FsError.NotFound;

        // Try to create the file.
        const mode_using: Mode = mode orelse .anybody_rw;
        const parent = kernelLookupParent(.origin_cwd, pathname) orelse return FsError.NotFound;
        const basename = vfs.basename(pathname);
        break :blk try parent.createFile(basename, mode_using);
    };

    // Create a file instance.
    return try File.new(vfs.followDown(dentry), allocator);
}

/// TODO: doc
pub fn write(file: *File, buf: []const u8) FsError!usize {
    _ = file; // autofix
    _ = buf; // autofix
    norn.unimplemented("fs.write");
}

/// Get a file status information of the given file.
pub fn stat(file: *File) FsError!Stat {
    return try vfs.followDown(file.dentry).inode.stat();
}

/// Get a file status information of the given path.
///
/// The given `dir` is the directory to start the lookup if the path is not absolute.
pub fn statAt(dir: *vfs.Dentry, path: []const u8) FsError!Stat {
    const dent = lookup(
        .{ .dir = dir },
        path,
    ) orelse return FsError.NotFound;
    return try vfs.followDown(dent).inode.stat();
}

/// Create a new directory.
pub fn createDirectory(path: []const u8, mode: Mode) FsError!*Dentry {
    const parent = kernelLookupParent(.cwd, path) orelse return FsError.NotFound;
    return vfs.followDown(parent).createDirectory(vfs.basename(path), mode);
}

/// Create a new directory at the given path.
pub fn createDirectoryAt(dir: *const Dentry, name: []const u8, mode: Mode) FsError!*Dentry {
    if (mode.type != .directory) {
        return FsError.InvalidArgument;
    }
    return vfs.followDown(dir).createDirectory(name, mode);
}

/// Mount a filesystem on the given path.
pub fn mount(path: []const u8, fs: *vfs.FileSystem) FsError!void {
    return vfs.mount(fs, path, allocator);
}

/// TODO: doc
pub fn close(file: *File) void {
    allocator.destroy(file);
}

/// The origin of the lookup path.
const LookupOrigin = union(Tag) {
    /// Lookup path from CWD.
    cwd: void,
    /// Lookup path from the given directory.
    dir: *vfs.Dentry,

    const Tag = enum {
        /// Lookup path from CWD.
        cwd,
        /// Lookup path from the given directory.
        dir,
    };

    pub const origin_cwd = LookupOrigin{ .cwd = {} };
};

/// Lookup a dentry by path.
///
/// This function searches for a file in the given directory.
/// This function can take a path string with more than one level of depth.
///
/// If it encounters a component that does not exist, the search stops and returns null.
/// For example, `dne/..` will fail if `dne` does not exist.
pub fn lookup(origin: LookupOrigin, path: []const u8) ?*vfs.Dentry {
    const dir = switch (origin) {
        .cwd => sched.getCurrentTask().fs.cwd,
        .dir => |d| d,
    };

    const result = vfs.resolvePath(dir, path) catch return null;
    return result.result;
}

/// Lookup a parent of the given path lexically.
fn kernelLookupParent(origin: LookupOrigin, path: []const u8) ?*vfs.Dentry {
    const dir = switch (origin) {
        .cwd => sched.getCurrentTask().fs.cwd,
        .dir => |d| d,
    };

    const result = vfs.resolvePath(dir, path) catch return null;
    return result.parent;
}

// =============================================================
// Tests
// =============================================================

test {
    std.testing.refAllDeclsRecursive(@This());
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.fs);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ComponentIterator = std.fs.path.ComponentIterator;

const norn = @import("norn");
const bits = norn.bits;
const posix = norn.posix;
const sched = norn.sched;
const syscall = norn.syscall;
const util = norn.util;
const SysError = syscall.SysError;

const cpio = @import("fs/cpio.zig");
const RamFs = @import("fs/RamFs.zig");
const vfs = @import("fs/vfs.zig");
const Dentry = vfs.Dentry;
const File = vfs.File;
const Mode = vfs.Mode;

const allocator = norn.mem.general_allocator;
