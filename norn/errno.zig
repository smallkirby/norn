/// Error conditions.
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
    nomem = 10,
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
            .nomem => "No child processes",
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

/// Error type corresponding to `Errno`.
pub const Error = error{
    Perm,
    Noent,
    Srch,
    Intr,
    Io,
    Nxio,
    TooBig,
    Noexec,
    Badf,
    Nomem,
    Access,
    Fault,
    NotBlk,
    Busy,
    Exist,
    Xdev,
    Nodev,
    NotDir,
    IsDir,
    Inval,
    Nfile,
    Mfile,
    NotTy,
    TxtBsy,
    Fbig,
    Nospc,
    Spipe,
    Rofs,
    Mlink,
    Pipe,
    Dom,
    Range,

    Unimplemented,
};

/// Convert `Error` to `Errno`.
pub fn convertToErrno(err: Error) Errno {
    return switch (err) {
        Error.Perm => .perm,
        Error.Noent => .noent,
        Error.Srch => .srch,
        Error.Intr => .intr,
        Error.Io => .io,
        Error.Nxio => .nxio,
        Error.TooBig => .@"2big",
        Error.Noexec => .noexec,
        Error.Badf => .badf,
        Error.Nomem => .nomem,
        Error.Access => .access,
        Error.Fault => .fault,
        Error.NotBlk => .notblk,
        Error.Busy => .busy,
        Error.Exist => .exist,
        Error.Xdev => .xdev,
        Error.Nodev => .nodev,
        Error.NotDir => .notdir,
        Error.IsDir => .isdir,
        Error.Inval => .inval,
        Error.Nfile => .nfile,
        Error.Mfile => .mfile,
        Error.NotTy => .notty,
        Error.TxtBsy => .txtbsy,
        Error.Fbig => .fbig,
        Error.Nospc => .nospc,
        Error.Spipe => .spipe,
        Error.Rofs => .rofs,
        Error.Mlink => .mlink,
        Error.Pipe => .pipe,
        Error.Dom => .dom,
        Error.Range => .range,
        Error.Unimplemented => .unimplemented,
    };
}
