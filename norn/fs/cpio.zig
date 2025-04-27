pub const Error = std.fmt.ParseIntError;

/// Iterator over the CPIO entries.
pub const CpioIterator = struct {
    /// Pointer to the backing data.
    _data: []const u8,
    /// Current position in the backing data.
    _cur: *const NewAsciiCpio,
    /// End of the backing data.
    _end: *const void,

    /// Create a new CPIO iterator.
    pub fn new(data: []const u8) CpioIterator {
        return .{
            ._data = data,
            ._cur = NewAsciiCpio.from(data.ptr),
            ._end = @ptrCast(data.ptr + data.len),
        };
    }

    /// Get the next CPIO entry.
    pub fn next(self: *CpioIterator) Error!?*const NewAsciiCpio {
        const cur = self._cur;
        if (@intFromPtr(cur) >= @intFromPtr(self._end)) {
            return null;
        }
        if (std.mem.eql(u8, try cur.getPath(), NewAsciiCpio.trailer_name)) {
            return null;
        }

        self._cur = try cur.getNext();
        return cur;
    }
};

/// New ASCII CPIO archive.
const NewAsciiCpio = extern struct {
    const Self = @This();

    /// Signature for newc archives (that doesn't have a checksum).
    const newc_signature = "070701";
    /// Signature for crc archives (that has a checksum).
    const crc_signature = "070702";
    /// Trailing empty file name.
    const trailer_name: [:0]const u8 = "TRAILER!!!";
    /// Alignment for the path and data entry.
    const alignment = 4;

    /// Signature. Must be "070701" (newc) or "070702" (crc).
    signature: [6]u8,
    /// Inode number.
    inode: [8]u8,
    /// Mode.
    mode: [8]u8,
    /// UID.
    uid: [8]u8,
    /// GID.
    gid: [8]u8,
    /// Number of links.
    nlink: [8]u8,
    /// Modification time.
    mtime: [8]u8,
    /// File size.
    file_size: [8]u8,
    /// Device major number.
    dev_major: [8]u8,
    /// Device minor number.
    dev_minor: [8]u8,
    /// Block or character device major number.
    sdev_major: [8]u8,
    /// Block or character device minor number.
    sdev_minor: [8]u8,
    /// Size of path string including null terminator.
    path_size: [8]u8,
    /// Checksum.
    /// Must be 0 for newc archives.
    checksum: [8]u8,
    /// Start of path string.
    __path: void,

    comptime {
        if (@bitOffsetOf(NewAsciiCpio, "__path") != 110 * @bitSizeOf(u8)) {
            @compileError("NewAsciiCpio: __path must be at offset 110");
        }
    }

    /// Create an instance of CPIO from a pointer to the backing data.
    fn from(data: [*]const u8) *const NewAsciiCpio {
        if (@intFromPtr(data) % alignment != 0) {
            @panic("NewAsciiCpio: Data address must be aligned to 4 bytes");
        }
        return @ptrCast(data);
    }

    /// Check if the CPIO is valid.
    pub fn isValid(self: *const Self) Error!bool {
        const is_newc = std.mem.eql(u8, &self.signature, "070701");
        const is_crc = std.mem.eql(u8, &self.signature, "070702");
        const crc_valid = is_newc or try self.getChecksum() == 0;
        return (is_newc or is_crc) and crc_valid;
    }

    pub fn getInode(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.inode, 16);
    }

    pub fn getMode(self: *const Self) Error!Mode {
        const value = try std.fmt.parseInt(u32, &self.mode, 16);
        return @bitCast(value);
    }

    pub fn getUid(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.uid, 16);
    }

    pub fn getGid(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.gid, 16);
    }

    pub fn getNlink(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.nlink, 16);
    }

    pub fn getMtime(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.mtime, 16);
    }

    pub fn getFilesize(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.file_size, 16);
    }

    pub fn getDevMajor(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.dev_major, 16);
    }

    pub fn getDevMinor(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.dev_minor, 16);
    }

    pub fn getSdevMajor(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.sdev_major, 16);
    }

    pub fn getSdevMinor(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.sdev_minor, 16);
    }

    pub fn getPathSize(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.path_size, 16);
    }

    fn getChecksum(self: *const Self) Error!u64 {
        return try std.fmt.parseInt(u64, &self.checksum, 16);
    }

    pub fn getPath(self: *const Self) Error![:0]const u8 {
        const ptr: [*]const u8 = @ptrCast(&self.__path);
        return ptr[0 .. try self.getPathSize() - 1 :0];
    }

    pub fn getData(self: *const Self) Error![]const u8 {
        const path_end: u64 = @intFromPtr(&self.__path) + try self.getPathSize();
        const data_start: [*]u8 = @ptrFromInt(util.roundup(path_end, alignment));
        return data_start[0..try self.getFilesize()];
    }

    fn getNext(self: *const Self) Error!*const Self {
        const data = try self.getData();
        const data_end = @intFromPtr(data.ptr) + data.len;
        const next_start = util.roundup(data_end, alignment);
        return @ptrFromInt(next_start);
    }
};

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

fn getTestCpio() ![]align(4) const u8 {
    const test_cpio = @embedFile("../tests/assets/test.cpio");
    const duped = try testing.allocator.alignedAlloc(u8, 4, test_cpio.len);
    @memcpy(duped, test_cpio);
    return duped;
}

test "isValid" {
    const cpio_data = try getTestCpio();
    const cpio = NewAsciiCpio.from(cpio_data.ptr);
    defer testing.allocator.free(cpio_data);

    try testing.expect(try cpio.isValid());
}

test "Read first entry" {
    const cpio_data = try getTestCpio();
    const cpio = NewAsciiCpio.from(cpio_data.ptr);
    defer testing.allocator.free(cpio_data);

    try testing.expect(try cpio.isValid());

    try testing.expectEqual(46638358, try cpio.getInode());
    try testing.expectEqual(Mode.fromPosixMode(0o40775), try cpio.getMode());
    try testing.expectEqual(0, try cpio.getUid());
    try testing.expectEqual(1000, try cpio.getGid());
    try testing.expectEqual(3, try cpio.getNlink());
    try testing.expectEqual(1737199656, try cpio.getMtime());
    try testing.expectEqual(0, try cpio.getFilesize());
    try testing.expectEqual(259, try cpio.getDevMajor());
    try testing.expectEqual(2, try cpio.getDevMinor());
    try testing.expectEqual(0, try cpio.getSdevMajor());
    try testing.expectEqual(0, try cpio.getSdevMinor());
    try testing.expectEqual(2, try cpio.getPathSize());
    try testing.expectEqual(0, try cpio.getChecksum());
    try testing.expectEqualStrings(".", try cpio.getPath());
    try testing.expectEqual(0, (try cpio.getData()).len);
}

test "Iterator: read all entries" {
    const cpio_data = try getTestCpio();
    defer testing.allocator.free(cpio_data);

    var count: usize = 0;
    var iter = CpioIterator.new(cpio_data);
    var cur = try iter.next();
    while (cur) |cpio| : (cur = try iter.next()) {
        switch (count) {
            0 => {
                // Already tested in the previous test.
                {
                    try testing.expectEqual(46638358, try cpio.getInode());
                    try testing.expectEqual(Mode.fromPosixMode(0o40775), try cpio.getMode());
                    try testing.expectEqual(0, try cpio.getUid());
                    try testing.expectEqual(1000, try cpio.getGid());
                    try testing.expectEqual(3, try cpio.getNlink());
                    try testing.expectEqual(1737199656, try cpio.getMtime());
                    try testing.expectEqual(0, try cpio.getFilesize());
                    try testing.expectEqual(259, try cpio.getDevMajor());
                    try testing.expectEqual(2, try cpio.getDevMinor());
                    try testing.expectEqual(0, try cpio.getSdevMajor());
                    try testing.expectEqual(0, try cpio.getSdevMinor());
                    try testing.expectEqual(2, try cpio.getPathSize());
                    try testing.expectEqual(0, try cpio.getChecksum());
                    try testing.expectEqualStrings(".", try cpio.getPath());
                    try testing.expectEqual(0, (try cpio.getData()).len);
                }
            },
            1 => {
                const diff = @intFromPtr(cpio) - @intFromPtr(cpio_data.ptr);
                try testing.expectEqual(0x70, diff);

                try testing.expectEqual(46638360, try cpio.getInode());
                try testing.expectEqual(Mode.fromPosixMode(0o40775), try cpio.getMode());
                try testing.expectEqual(0, try cpio.getUid());
                try testing.expectEqual(1000, try cpio.getGid());
                try testing.expectEqual(2, try cpio.getNlink());
                try testing.expectEqual(1737199656, try cpio.getMtime());
                try testing.expectEqual(0, try cpio.getFilesize());
                try testing.expectEqual(259, try cpio.getDevMajor());
                try testing.expectEqual(2, try cpio.getDevMinor());
                try testing.expectEqual(0, try cpio.getSdevMajor());
                try testing.expectEqual(0, try cpio.getSdevMinor());
                try testing.expectEqual(5, try cpio.getPathSize());
                try testing.expectEqual(0, try cpio.getChecksum());
                try testing.expectEqualStrings("dir1", try cpio.getPath());
                try testing.expectEqual(0, (try cpio.getData()).len);
            },
            2 => {
                const diff = @intFromPtr(cpio) - @intFromPtr(cpio_data.ptr);
                try testing.expectEqual(0xE4, diff);

                try testing.expectEqual(46631722, try cpio.getInode());
                try testing.expectEqual(Mode.fromPosixMode(0o100664), try cpio.getMode());
                try testing.expectEqual(0, try cpio.getUid());
                try testing.expectEqual(1000, try cpio.getGid());
                try testing.expectEqual(1, try cpio.getNlink());
                try testing.expectEqual(1737199644, try cpio.getMtime());
                try testing.expectEqual(6, try cpio.getFilesize());
                try testing.expectEqual(259, try cpio.getDevMajor());
                try testing.expectEqual(2, try cpio.getDevMinor());
                try testing.expectEqual(0, try cpio.getSdevMajor());
                try testing.expectEqual(0, try cpio.getSdevMinor());
                try testing.expectEqual(10, try cpio.getPathSize());
                try testing.expectEqual(0, try cpio.getChecksum());
                try testing.expectEqualStrings("hello.txt", try cpio.getPath());
                try testing.expectEqualStrings("hello\n", try cpio.getData());
            },
            else => {
                const diff = @intFromPtr(cpio) - @intFromPtr(cpio_data.ptr);
                try testing.expectEqual(cpio_data.len, diff);
                return error.Unreachable;
            },
        }

        count += 1;
    }
    try testing.expectEqual(count, 3);

    // Check the trailer.
    const cpio = iter._cur;
    try testing.expectEqual(0, try cpio.getInode());
    try testing.expectEqual(Mode.fromPosixMode(0), try cpio.getMode());
    try testing.expectEqual(0, try cpio.getUid());
    try testing.expectEqual(0, try cpio.getGid());
    try testing.expectEqual(1, try cpio.getNlink());
    try testing.expectEqual(0, try cpio.getMtime());
    try testing.expectEqual(0, try cpio.getFilesize());
    try testing.expectEqual(0, try cpio.getDevMajor());
    try testing.expectEqual(0, try cpio.getDevMinor());
    try testing.expectEqual(0, try cpio.getSdevMajor());
    try testing.expectEqual(0, try cpio.getSdevMinor());
    try testing.expectEqual(11, try cpio.getPathSize());
    try testing.expectEqual(0, try cpio.getChecksum());
    try testing.expectEqualStrings(NewAsciiCpio.trailer_name, try cpio.getPath());
    try testing.expectEqual(0, (try cpio.getData()).len);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const util = norn.util;

const vfs = @import("vfs.zig");
const Mode = vfs.Mode;
