//! This function provides a POSIX errno value and corresponding error set.

/// Error set corresponding to POSIX errno.
///
/// Field names do not necessarily match errno to make them more understandable.
/// The order of definitions has no significance.
pub const Error = error{
    /// Operation not permitted.
    OpPermission,
    /// No such file or directory.
    NoEntry,
    /// No such process.
    NoProcess,
    /// Interrupted system call.
    Interrupted,
    /// I/O error.
    Io,
    /// No such device or address.
    NoAddr,
    /// Argument list too long.
    TooBig,
    /// Exec format error.
    ExecFormat,
    /// Bad file number.
    BadFd,
    /// No child processes.
    NoChild,
    /// Try again.
    Again,
    /// Out of memory.
    NoMemory,
    /// Permission denied.
    Access,
    /// Bad address.
    Fault,
    /// Block device required.
    NotBlock,
    /// Device or resource busy.
    Busy,
    /// File exists.
    Exist,
    /// Cross-device link.
    CrossDevice,
    /// No such device.
    NoDevice,
    /// Not a directory.
    NotDir,
    /// Is a directory.
    IsDir,
    /// Invalid argument.
    InvalidArg,
    /// File table overflow for this process.
    FdTooMany,
    /// Too many open files in entire system.
    FileTooMany,
    /// Not a typewriter.
    NotTty,
    /// Text file busy.
    TextBusy,
    /// File too large.
    FileLarge,
    /// No space left on device.
    NoSpace,
    /// Illegal seek.
    IllegalSeek,
    /// Read-only file system.
    RoFs,
    /// Too many links.
    LinkTooMany,
    /// Broken pipe.
    BrokenPipe,
    /// Math argument out of domain of func.
    Dom,
    /// Math result not representable.
    OutOfRange,

    /// Function not implemented.
    Unimplemented,
};

/// Error conditions.
///
/// Compatible with POSIX errno.
/// Values must match POSIX errno.
/// Field names should match POSIX errno as closey as possible unlike `Error`.
pub const Errno = enum(i64) {
    /// Operation not permitted.
    perm = 1,
    /// No such file or directory.
    noent = 2,
    /// No such process.
    srch = 3,
    /// Interrupted system call.
    intr = 4,
    /// I/O error.
    io = 5,
    /// No such device or address.
    nxio = 6,
    /// Argument list too long.
    @"2big" = 7,
    /// Exec format error.
    noexec = 8,
    /// Bad file number.
    badf = 9,
    /// No child processes.
    child = 10,
    /// Try again.
    again = 11,
    /// Out of memory.
    nomem = 12,
    /// Permission denied.
    access = 13,
    /// Bad address.
    fault = 14,
    /// Block device required.
    notblk = 15,
    /// Device or resource busy.
    busy = 16,
    /// File exists.
    exist = 17,
    /// Cross-device link.
    xdev = 18,
    /// No such device.
    nodev = 19,
    /// Not a directory.
    notdir = 20,
    /// Is a directory.
    isdir = 21,
    /// Invalid argument.
    inval = 22,
    /// File table overflow.
    nfile = 23,
    /// Too many open files.
    mfile = 24,
    /// Not a typewriter.
    notty = 25,
    /// Text file busy.
    txtbsy = 26,
    /// File too large.
    fbig = 27,
    /// No space left on device.
    nospc = 28,
    /// Illegal seek.
    spipe = 29,
    /// Read-only file system.
    rofs = 30,
    /// Too many links.
    mlink = 31,
    /// Broken pipe.
    pipe = 32,
    /// Math argument out of domain of func.
    dom = 33,
    /// Math result not representable.
    range = 34,

    /// Unimplemented.
    unimplemented = 99,

    _,

    /// Get a message for the errno.
    pub fn message(self: Errno) []const u8 {
        return switch (self) {
            .perm => "Operation not permitted",
            .noent => "No such file or directory",
            .srch => "No such process",
            .intr => "Interrupted system call",
            .io => "I/O error",
            .nxio => "No such device or address",
            .@"2big" => "Argument list too long",
            .noexec => "Exec format error",
            .badf => "Bad file number",
            .child => "No child processes",
            .again => "Try again",
            .nomem => "Out ofmemory",
            .access => "Permission denied",
            .fault => "Bad address",
            .notblk => "Block device required",
            .busy => "Device or resource busy",
            .exist => "File exists",
            .xdev => "Cross-device link",
            .nodev => "No such device",
            .notdir => "Not a directory",
            .isdir => "Is a directory",
            .inval => "Invalid argument",
            .nfile => "File table overflow",
            .mfile => "Too many open files",
            .notty => "Not a typewriter",
            .txtbsy => "Text file busy",
            .fbig => "File too large",
            .nospc => "No space left on device",
            .spipe => "Illegal seek",
            .rofs => "Read-only file system",
            .mlink => "Too many links",
            .pipe => "Broken pipe",
            .dom => "Math argument out of domain of func",
            .range => "Math result not representable",
            .unimplemented => "Unimplemented",
            _ => "Unknown error",
        };
    }
};

/// Convert `Error` error set  to `Errno` integer.
pub fn convertToErrno(err: Error) Errno {
    return switch (err) {
        Error.OpPermission => .perm,
        Error.NoEntry => .noent,
        Error.NoProcess => .srch,
        Error.Interrupted => .intr,
        Error.Io => .io,
        Error.NoAddr => .nxio,
        Error.TooBig => .@"2big",
        Error.ExecFormat => .noexec,
        Error.BadFd => .badf,
        Error.NoChild => .child,
        Error.Again => .again,
        Error.NoMemory => .nomem,
        Error.Access => .access,
        Error.Fault => .fault,
        Error.NotBlock => .notblk,
        Error.Busy => .busy,
        Error.Exist => .exist,
        Error.CrossDevice => .xdev,
        Error.NoDevice => .nodev,
        Error.NotDir => .notdir,
        Error.IsDir => .isdir,
        Error.InvalidArg => .inval,
        Error.FdTooMany => .nfile,
        Error.FileTooMany => .mfile,
        Error.NotTty => .notty,
        Error.TextBusy => .txtbsy,
        Error.FileLarge => .fbig,
        Error.NoSpace => .nospc,
        Error.IllegalSeek => .spipe,
        Error.RoFs => .rofs,
        Error.LinkTooMany => .mlink,
        Error.BrokenPipe => .pipe,
        Error.Dom => .dom,
        Error.OutOfRange => .range,
        Error.Unimplemented => .unimplemented,
    };
}
