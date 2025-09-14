//! Ring buffer.
//!
//! Users are responsible for synchronization.

const Self = @This();
const RingBuffer = Self;

pub const Error = error{
    /// Buffer is full.
    Full,
    /// Buffer is empty.
    Empty,
};

/// Buffer.
data: []u8,
/// Consumer index.
cp: usize,
/// Producer index.
pp: usize,

/// Create a new ring buffer with the given buffer.
pub fn init(buffer: []u8) Self {
    return .{
        .data = buffer,
        .cp = 0,
        .pp = 0,
    };
}

/// Consume data from the ring buffer into the given output buffer.
///
/// Returns the number of bytes consumed.
/// The return size can be less than `out.len` when the ring buffer has less data.
pub fn consume(self: *Self, out: []u8) Error!usize {
    const range_a, const range_b = self.consumableRange(out.len);

    @memcpy(
        out[0..range_a],
        self.data[self.cp .. self.cp + range_a],
    );
    @memcpy(
        out[range_a .. range_a + range_b],
        self.data[0..range_b],
    );
    self.cp = (self.cp + range_a + range_b) % self.data.len;

    return range_a + range_b;
}

/// Consume a single byte from the ring buffer.
pub fn consumeOne(self: *Self) Error!u8 {
    if (self.isEmpty()) {
        return Error.Empty;
    }

    const b = self.data[self.cp];
    self.cp = (self.cp + 1) % self.data.len;
    return b;
}

/// Produce data into the ring buffer.
///
/// When the ring buffer does not have enough space, return `Error.Full` without writing any data.
pub fn produce(self: *Self, data: []const u8) Error!usize {
    if (self.space() < data.len) {
        return Error.Full;
    }

    const first_end = @min(self.data.len, self.pp + data.len);
    const first_len = first_end - self.pp;
    @memcpy(
        self.data[self.pp..first_end],
        data[0..first_len],
    );
    const second_len = data.len - first_len;
    @memcpy(
        self.data[0..second_len],
        data[first_len..data.len],
    );
    self.pp = (self.pp + data.len) % self.data.len;

    return data.len;
}

/// Produce a single byte into the ring buffer.
pub fn produceOne(self: *Self, b: u8) Error!void {
    if (self.isFull()) {
        return Error.Full;
    }

    self.data[self.pp] = b;
    self.pp = (self.pp + 1) % self.data.len;
}

/// Check if the ring buffer is empty.
pub fn isEmpty(self: Self) bool {
    return self.cp == self.pp;
}

/// Check if the ring buffer is full.
pub fn isFull(self: Self) bool {
    return (self.pp + 1) % self.data.len == self.cp;
}

/// Get the length of consumable data in the ring buffer.
pub fn len(self: Self) usize {
    if (self.pp >= self.cp) {
        return self.pp - self.cp;
    } else {
        return (self.pp + self.data.len) - self.cp;
    }
}

/// Get the space available for producing data in the ring buffer.
pub fn space(self: Self) usize {
    return self.data.len - self.len();
}

/// Get the consumable ranges in the ring buffer.
///
/// When A and B is returned, the consumable range is [cp, cp + A) and [0, B).
fn consumableRange(self: Self, max: ?usize) struct { usize, usize } {
    var first: usize = 0;
    var second: usize = 0;
    const max_value = max orelse self.len();

    if (self.cp <= self.pp) {
        first = @min(self.pp - self.cp, max_value);
        second = 0;
    } else {
        first = @min(self.data.len - self.cp, max_value);
        if (first < max_value) {
            second = @min(self.pp, max_value - first);
        } else {
            second = 0;
        }
    }

    return .{ first, second };
}

// =============================================================
// Tests
// =============================================================

const std = @import("std");
const testing = std.testing;

test RingBuffer {
    var buf: [26]u8 = undefined;
    @memset(buf[0..], 0xAA);
    var out: [26]u8 = undefined;
    var rb = RingBuffer.init(buf[0..]);

    try testing.expectEqual(5, try rb.produce("ABCDE"));
    try testing.expectEqual(5, rb.len());
    try testing.expectEqual(26 - 5, rb.space());
    try testing.expectEqual(.{ 5, 0 }, rb.consumableRange(null));
    try testing.expectEqual(false, rb.isEmpty());
    try testing.expectEqual(false, rb.isFull());

    try testing.expectEqual(3, try rb.consume(out[0..3]));
    try testing.expectEqualStrings("ABC", out[0..3]);
    try testing.expectEqual(2, rb.len());
    try testing.expectEqual(26 - 2, rb.space());
    try testing.expectEqual(.{ 2, 0 }, rb.consumableRange(null));
    try testing.expectEqual(false, rb.isEmpty());
    try testing.expectEqual(false, rb.isFull());

    // Consume when producer is ahead of consumer.
    try testing.expectEqual(2, try rb.consume(out[0..10]));
    try testing.expectEqualStrings("DE", out[0..2]);
    try testing.expectEqual(0, rb.len());
    try testing.expectEqual(26, rb.space());
    try testing.expectEqual(.{ 0, 0 }, rb.consumableRange(null));
    try testing.expectEqual(true, rb.isEmpty());
    try testing.expectEqual(false, rb.isFull());

    // Producer is at the end of the buffer.
    try testing.expectEqual(26 - 5, try rb.produce("FGHIJKLMNOPQRSTUVWXYZ"));
    try testing.expectEqual(21, rb.len());
    try testing.expectEqual(5, rb.space());
    try testing.expectEqual(.{ 21, 0 }, rb.consumableRange(null));
    try testing.expectEqual(false, rb.isEmpty());
    try testing.expectEqual(false, rb.isFull());

    // Consume when producer is at the end of the buffer.
    try testing.expectEqual(3, try rb.consume(out[0..3]));
    try testing.expectEqualStrings("FGH", out[0..3]);
    try testing.expectEqual(18, rb.len());
    try testing.expectEqual(8, rb.space());
    try testing.expectEqual(.{ 18, 0 }, rb.consumableRange(null));
    try testing.expectEqual(false, rb.isEmpty());
    try testing.expectEqual(false, rb.isFull());

    // Producer is behind consumer.
    try testing.expectEqual(3, try rb.produce("abc"));
    try testing.expectEqual(21, rb.len());
    try testing.expectEqual(5, rb.space());
    try testing.expectEqual(.{ 18, 3 }, rb.consumableRange(null));
    try testing.expectEqual(false, rb.isEmpty());
    try testing.expectEqual(false, rb.isFull());

    // Consume when producer is behind consumer.
    try testing.expectEqual(10, try rb.consume(out[0..10]));
    try testing.expectEqualStrings("IJKLMNOPQR", out[0..10]);
    try testing.expectEqual(11, rb.len());
    try testing.expectEqual(15, rb.space());
    try testing.expectEqual(.{ 8, 3 }, rb.consumableRange(null));
    try testing.expectEqual(false, rb.isEmpty());
    try testing.expectEqual(false, rb.isFull());

    // Consume all.
    try testing.expectEqual(11, try rb.consume(out[0..26]));
    try testing.expectEqualStrings("STUVWXYZabc", out[0..11]);
    try testing.expectEqual(0, rb.len());
    try testing.expectEqual(26, rb.space());
    try testing.expectEqual(.{ 0, 0 }, rb.consumableRange(null));
    try testing.expectEqual(true, rb.isEmpty());
    try testing.expectEqual(false, rb.isFull());

    // Produce more than the buffer size.
    try testing.expectError(Error.Full, rb.produce("ABCDEFGHIJKLMNOPQRSTUVWXYZ!"));
}
