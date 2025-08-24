/// Timespec.
///
/// POSIX-compliant.
pub const TimeSpec = packed struct {
    /// Seconds.
    sec: u64,
    /// Nanoseconds.
    nsec: u64,
};
