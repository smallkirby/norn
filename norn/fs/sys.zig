//! Filesystem API for POSIX-compatible systems.
//!
//! All exported ABIs must be compatible POSIX system.
//! Names of syscalls must be same as Linux.

/// Convert FsError to syscall error type.
fn mapError(err: FsError) SysError {
    const E = FsError;
    const S = SysError;

    return switch (err) {
        E.AlreadyExists => S.Exist,
        E.BadFileDescriptor => S.BadFd,
        E.DescriptorFull => S.FdTooMany,
        E.InvalidArgument => S.InvalidArg,
        E.IsDirectory => S.IsDir,
        E.NotDirectory => S.NotDir,
        E.NotFound => S.NoEntry,
        E.OutOfMemory => S.NoMemory,
        E.Overflow => S.OutOfRange,
        E.Unimplemented => S.Unimplemented,
    };
}

/// Flags to indicate the open mode.
const OpenFlags = packed struct(i32) {
    read_only: bool,
    write_only: bool,
    read_write: bool,
    _reserved1: u3 = 0,
    create: bool,
    _reserved2: u25 = 0,

    /// Convert OpenFlags to fs.OpenFlags.
    pub fn toFsOpenFlags(flags: OpenFlags) fs.OpenFlags {
        return .{
            .mode = blk: {
                if (flags.read_only) {
                    break :blk .read_only;
                }
                if (flags.write_only) {
                    break :blk .write_only;
                }
                if (flags.read_write) {
                    break :blk .read_write;
                }
                break :blk .read_only;
            },
            .create = flags.create,
        };
    }
};

// =============================================================
// System calls
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
    /// File type (type-erased).
    type: u8 align(1),
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
    pub fn createCopy(inum: Inode.Number, ftype: FileType, name: []const u8, buf: []u8) void {
        const size = calcSize(name);
        norn.rtt.expectEqual(size, buf.len);

        // Copy fixed-size part.
        const dirent = Self{
            .inode_number = inum,
            .reclen = size,
            .type = @intFromEnum(ftype),
        };
        var cur: [*]u8 = buf.ptr;
        @memcpy(cur[0..struct_size], std.mem.asBytes(&dirent)[0..struct_size]);
        cur += struct_size;

        // Copy name part.
        @memcpy(cur[0..name.len], name);
        cur[name.len] = 0; // null-terminate
    }

    comptime {
        norn.comptimeAssert(
            19 == struct_size,
            "Size of DirEnt64 must be 19.",
            .{},
        );
    }
};

/// Get as much directory entries from the given directory.
///
/// - `fd: File descriptor that describes a directory from which entries are read.
/// - `dirp`: Pointer to buffer to which DirEnt64 is written.
/// - `count`: Size of `dirp` buffer in bytes.
///
/// On success, the number of bytes read is returned.
/// On end of directory, 0 is returned.
pub fn getdents64(fd: FileDescriptor, dirp: [*]u8, count: usize) SysError!i64 {
    const file = fs.getCurrentFdTable().get(fd) orelse return SysError.NoEntry;
    if (!file.path.dentry.inode.isDirectory()) {
        return SysError.NotDir;
    }

    const results = file.iterate(allocator) catch |err| {
        return mapError(err);
    };
    defer allocator.free(results);

    // All entries are already read.
    if (results.len <= file.offset) {
        return 0;
    }

    // Iterate entries and fill the user buffer.
    var consumed: usize = 0;
    const start: usize = @intCast(file.offset);
    for (results[start..]) |result| {
        const dirent_size = DirEnt64.calcSize(result.name);
        if (count - consumed < dirent_size) {
            break;
        }

        const ptr = dirp + consumed;
        DirEnt64.createCopy(
            result.inum,
            result.type,
            result.name,
            ptr[0..dirent_size],
        );
        consumed += dirent_size;
        file.offset += 1;
    }

    return @bitCast(consumed);
}

/// Change current working directory of the process.
///
/// - `pathname`: Pathname of the new working directory. Can be both relative and absolute.
///
/// Returns `0` on success.
pub fn chdir(pathname: [*:0]const u8) SysError!i64 {
    const path_str = util.sentineledToSlice(pathname);
    const resolved = fs.lookup(.cwd, path_str) orelse {
        return SysError.NoEntry;
    };
    if (!resolved.dentry.inode.isDirectory()) {
        return SysError.NotDir;
    }

    sched.getCurrentTask().fs.setCwd(resolved);
    return 0;
}

/// Get current working directory.
///
/// - `buf`: Buffer to receive the directory name.
/// - `size`: Size of the buffer.
///
/// Returns the number of bytes including null-terminator written to the buffer.
pub fn getcwd(buf: [*]allowzero u8, size: usize) SysError!i64 {
    if (@intFromPtr(buf) == 0) {
        return SysError.InvalidArg;
    }
    if (size == 0) {
        return SysError.InvalidArg;
    }

    const cwd = fs.getCwd().dentry.name;
    if (cwd.len + 1 > size) {
        return SysError.OutOfRange;
    }

    @memcpy(buf[0..cwd.len], cwd);
    buf[cwd.len] = 0; // null-terminate

    return 0;
}

/// Get file status.
///
/// - `fd`: File descriptor of the file to get status for.
/// - `buf`: Buffer to receive the file status information.
///
/// Returns `0` on success.
pub fn fstat(fd: FileDescriptor, buf: *fs.Stat) SysError!i64 {
    if (fs.getPathFromFd(fd)) |path| {
        buf.* = fs.stat(path.dentry.inode);
    } else return SysError.NoEntry;

    return 0;
}

/// Get file status.
///
/// - `fd`: File descriptor of the directory to search for the file.
/// - `pathname`: Pathname of the file to get status for.
/// - `buf`: Buffer to receive the file status information.
///
/// Returns `0` on success.
pub fn newfstatat(fd: FileDescriptor, pathname: [*:0]const u8, buf: *fs.Stat, _: u64) SysError!i64 {
    const path = fs.getPathFromFd(fd) orelse {
        return SysError.NoEntry;
    };

    buf.* = fs.statAt(
        path,
        util.sentineledToSlice(pathname),
    ) catch |err| return mapError(err);

    return 0;
}

/// Output information for statx.
const Statx = packed struct {
    /// Mask of bits indicating filled fields.
    mask: StatxMask,
    /// Block size for filesystem I/O.
    block_size: u32,
    /// Extra file attribute indicators.
    attributes: u64,
    //// Number of hard links.
    nlink: u32,
    /// UID of owner.
    uid: u32,
    /// GID of owner.
    gid: u32,
    /// File type and mode.
    mode: fs.Mode,
    /// Inode number.
    ino: u64,
    /// Total size in bytes.
    size: u64,
    /// Number of 512 bytes blocks allocated.
    blocks: u64,
    /// Mask to show what's supported in `attributes`.
    attributes_mask: u64,

    /// Last access time.
    atime: StatxTimespec,
    /// Creation time.
    btime: StatxTimespec,
    /// Last status change time.
    ctime: StatxTimespec,
    /// Last modification time.
    mtime: StatxTimespec,

    /// Major ID if the file represents a device.
    rdev_major: u32,
    /// Minor ID if the file represents a device.
    rdev_minor: u32,
    /// Major ID.
    major: u32,
    /// Minor ID.
    minor: u32,
    /// Mount ID.
    mnt_id: u64,
    /// Direct I/O alignment restriction.
    dio_mem_align: u32,
    /// Direct I/O alignment restriction.
    dio_offset_align: u32,
};

/// Timespec used in statx.
const StatxTimespec = packed struct(u128) {
    sec: u64,
    nsec: u32,
    _reserved: u32 = 0,
};

/// statx flags.
const StatxFlags = packed struct(u32) {
    /// Reserved.
    _reserved0: u12 = 0,
    /// AT_EMPTY_PATH. Allow empty path string.
    empty_path: bool,
    /// Reserved.
    _reserved1: u19 = 0,
};

/// Bitmask for statx to filter the output fields that the caller's interested in.
const StatxMask = packed struct(u32) {
    type: bool,
    mode: bool,
    nlink: bool,
    uid: bool,
    gid: bool,
    atime: bool,
    mtime: bool,
    ctime: bool,
    ino: bool,
    size: bool,
    blocks: bool,
    btime: bool,
    mnt_id: bool,
    dioalign: bool,
    _reserved: u18 = 0,
};

/// Get a extended file status.
///
/// - `dirfd`: File descriptor of a directory.
/// - `pathname`: Pathname of the file to get status for.
/// - `flags`
/// - `mask`: Bitmask to filter the output fields that the caller's interested in.
/// - `output`: Buffer to receive the file status information.
///
/// ### Target file search
///
/// If `pathname` is an absolute path, `dirfd` is not used.
/// If `pathname` is a relative path, `dirfd` is used as the base directory.
/// If `flags.empty_path` is set, `dirfd` is used as a target file.
///
/// ### Output
///
/// Caller can indicate which field they are interested in by setting the appropriate bits in the `mask`.
/// Norn may ignore the mask and return fields that are not requested, or may not return requested fields.
/// The returned field is indicated by `Statx.mask`.
///
/// NOTE that this function does not comply with the specification.
pub fn statx(
    dirfd: FileDescriptor,
    pathname: [*:0]const u8,
    flags: StatxFlags,
    mask: StatxMask,
    output: *align(1) Statx,
) SysError!i64 {
    const inode = blk: {
        if (flags.empty_path) {
            const file = fs.getFile(dirfd) orelse return SysError.BadFd;
            break :blk file.inode;
        }
        break :blk fs.openToGetInode(dirfd, util.sentineledToSlice(pathname)) catch |err| {
            return mapError(err);
        };
    };

    // Ignore requested mask. We always return below fields only.
    _ = mask;

    output.size = inode.size;
    output.mode = inode.mode;
    output.ino = inode.number;

    output.mask = std.mem.zeroInit(StatxMask, .{});
    output.mask.size = true;
    output.mask.mode = true;
    output.mask.ino = true;

    return 0;
}

/// Open a file relative to a directory file descriptor.
///
/// - `fd`: File descriptor of the directory to search for the file.
/// - `pathname`: Pathname of the file to open.
/// - `flags`: Flags to control the open behavior.
/// - `mode`: File mode to use if a new file is created.
///
/// Returns the file descriptor on success.
///
/// TODO: Use `flags`.
pub fn openat(fd: FileDescriptor, pathname: [*:0]const u8, flags: OpenFlags, mode: fs.Mode) SysError!i64 {
    const file = fs.openFileAt(
        fd,
        util.sentineledToSlice(pathname),
        flags.toFsOpenFlags(),
        mode,
    ) catch |err| return mapError(err);

    const new_fd = fs.putFile(file) catch |err| {
        // TODO: deinit file
        return mapError(err);
    };

    return @intFromEnum(new_fd);
}

/// Close a file descriptor.
///
/// Returns `0` on success.
pub fn close(fd: FileDescriptor) syscall.SysError!i64 {
    fs.closeFd(fd) catch |err| return mapError(err);
    return 0;
}

/// Read file from a file descriptor.
///
/// - `fd`: File descriptor to read from.
/// - `buf`: Buffer to store the read data.
/// - `size`: Number of bytes to read.
///
/// Returns the number of bytes read.
pub fn read(fd: FileDescriptor, buf: [*]u8, size: usize) SysError!i64 {
    const file = fs.getFile(fd) orelse {
        return SysError.BadFd;
    };
    const num_read = file.read(buf[0..size]) catch |err| {
        return mapError(err);
    };

    return @intCast(num_read);
}

/// Write bytes to file.
///
/// - `fd`: File descriptor to write to.
/// - `buf`: Buffer to store the written data.
/// - `size`: Number of bytes to write.
///
/// Returns the number of bytes written.
pub fn write(fd: FileDescriptor, buf: [*]const u8, count: usize) SysError!i64 {
    // TODO: Do not handle stdout and stderr here.
    // These descriptors should be associated with console descriptor.
    if (fd == .stdout or fd == .stderr) {
        norn.getSerial().writeString(buf[0..count]);
        return @intCast(count);
    }

    const buffer = buf[0..count];
    if (fs.getFile(fd)) |file| {
        const result = fs.write(file, buffer) catch |err| {
            return mapError(err);
        };
        return @intCast(result);
    } else {
        return SysError.BadFd;
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const fs = norn.fs;
const sched = norn.sched;
const syscall = norn.syscall;
const util = norn.util;
const allocator = norn.mem.general_allocator;

const File = fs.File;
const FileDescriptor = fs.FileDescriptor;
const FileType = fs.FileType;
const Dentry = fs.Dentry;
const Inode = fs.Inode;
const FsError = fs.FsError;
const SysError = syscall.SysError;
