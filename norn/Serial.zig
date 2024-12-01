const std = @import("std");
const atomic = std.atomic;

const norn = @import("norn");
const arch = norn.arch;
const serial8250 = norn.drivers.serial8250;
const SpinLock = norn.SpinLock;

const Self = @This();

const WriteFn = *const fn (u8) void;
const ReadFn = *const fn () ?u8;

/// Spin lock for the serial console.
lock: SpinLock = SpinLock{},
/// Whether the serial console has been initialized.
inited: atomic.Value(bool) = atomic.Value(bool).init(false),
/// Pointer to the writer function.
_write_fn: WriteFn = undefined,
/// Pointer to the reader function.
_read_fn: ReadFn = undefined,

/// Write a single byte to the serial console.
pub fn write(self: *Self, c: u8) void {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    self._write_fn(c);
}

fn writeNoLock(self: *Self, c: u8) void {
    self._write_fn(c);
}

/// Write a string to the serial console.
pub fn writeString(self: *Self, s: []const u8) void {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    for (s) |c| {
        self.writeNoLock(c);
    }
}

/// Try to read a character from the serial console.
/// Returns null if no character is available in Rx-buffer.
pub fn tryRead(_: *Self) ?u8 {
    norn.unimplemented("Serial tryRead()");
}

/// Initialize the serial console.
/// You MUST call this function before using the serial console.
pub fn init(self: *Self) void {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    const functions = serial8250.initSerial(.com1, 115200);
    self._write_fn = functions.write;
    self._read_fn = functions.read;

    self.inited.store(true, .release);
}

/// Check if the serial has been initialized.
pub fn isInited(self: Self) bool {
    return self.inited.load(.acquire);
}
