/// Open flags.
pub const OpenFlags = packed struct(i32) {
    read_only: bool,
    write_only: bool,
    read_write: bool,
    _reserved1: u3 = 0,
    create: bool,
    _reserved2: u25 = 0,
};
