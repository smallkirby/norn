const std = @import("std");
const log = std.log.scoped(.rtt);

const norn = @import("norn");
const Serial = norn.Serial;

const WriterError = error{};
const Writer = std.io.Writer(
    void,
    WriterError,
    write,
);

var serial: *Serial = undefined;
const writer = Writer{ .context = {} };

fn write(_: void, bytes: []const u8) WriterError!usize {
    serial.writeString(bytes);
    return bytes.len;
}

// ====================================================

/// Init runtime testing framework.
pub fn initRtt() void {
    @setCold(true);
    onlyForTest();
    serial = norn.getSerial();
}

pub fn rttExpect(condition: bool) void {
    @setCold(true);
    onlyForTest();

    if (!condition) {
        log.err("RTT expectation failed at 0x{X:0>16}", .{callerInfo()});
        failure();
    }
}

pub fn rttExpectEqual(expected: anytype, actual: anytype) void {
    @setCold(true);
    onlyForTest();

    expectEqual(expected, actual) catch {
        log.err("RTT expectation failed at 0x{X:0>16}", .{callerInfo()});
        failure();
    };
}

// ====================================================

pub inline fn expectEqual(expected: anytype, actual: anytype) !void {
    const T = @TypeOf(expected, actual);
    return expectEqualInner(T, expected, actual);
}

fn expectEqualInner(comptime T: type, expected: T, actual: T) !void {
    switch (@typeInfo(@TypeOf(actual))) {
        .NoReturn,
        .Opaque,
        .Frame,
        .AnyFrame,
        => @compileError("value of type " ++ @typeName(@TypeOf(actual)) ++ " encountered"),

        .Undefined,
        .Null,
        .Void,
        => return,

        .Type => {
            if (actual != expected) {
                log.err("expected type {s}, found type {s}", .{ @typeName(expected), @typeName(actual) });
                return error.TestExpectedEqual;
            }
        },

        .Bool,
        .Int,
        .Float,
        .ComptimeFloat,
        .ComptimeInt,
        .EnumLiteral,
        .Enum,
        .Fn,
        .ErrorSet,
        => {
            if (actual != expected) {
                log.err("expected {}, found {}", .{ expected, actual });
                return error.TestExpectedEqual;
            }
        },

        .Pointer => |pointer| {
            switch (pointer.size) {
                .One, .Many, .C => {
                    if (actual != expected) {
                        log.err("expected {*}, found {*}", .{ expected, actual });
                        return error.TestExpectedEqual;
                    }
                },
                .Slice => {
                    if (actual.ptr != expected.ptr) {
                        log.err("expected slice ptr {*}, found {*}", .{ expected.ptr, actual.ptr });
                        return error.TestExpectedEqual;
                    }
                    if (actual.len != expected.len) {
                        log.err("expected slice len {}, found {}", .{ expected.len, actual.len });
                        return error.TestExpectedEqual;
                    }
                },
            }
        },

        .Array => |array| try expectEqualSlices(array.child, &expected, &actual),

        .Vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                if (!std.meta.eql(expected[i], actual[i])) {
                    log.err("index {} incorrect. expected {}, found {}", .{
                        i, expected[i], actual[i],
                    });
                    return error.TestExpectedEqual;
                }
            }
        },

        .Struct => |structType| {
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
            }
        },

        .Union => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("Unable to compare untagged union values");
            }

            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);

            try expectEqual(expectedTag, actualTag);

            // we only reach this loop if the tags are equal
            inline for (std.meta.fields(@TypeOf(actual))) |fld| {
                if (std.mem.eql(u8, fld.name, @tagName(actualTag))) {
                    try expectEqual(@field(expected, fld.name), @field(actual, fld.name));
                    return;
                }
            }

            // we iterate over *all* union fields
            // => we should never get here as the loop above is
            //    including all possible values.
            unreachable;
        },

        .Optional => {
            if (expected) |expected_payload| {
                if (actual) |actual_payload| {
                    try expectEqual(expected_payload, actual_payload);
                } else {
                    log.err("expected {any}, found null", .{expected_payload});
                    return error.TestExpectedEqual;
                }
            } else {
                if (actual) |actual_payload| {
                    log.err("expected null, found {any}", .{actual_payload});
                    return error.TestExpectedEqual;
                }
            }
        },

        .ErrorUnion => {
            if (expected) |expected_payload| {
                if (actual) |actual_payload| {
                    try expectEqual(expected_payload, actual_payload);
                } else |actual_err| {
                    log.err("expected {any}, found {}", .{ expected_payload, actual_err });
                    return error.TestExpectedEqual;
                }
            } else |expected_err| {
                if (actual) |actual_payload| {
                    log.err("expected {}, found {any}", .{ expected_err, actual_payload });
                    return error.TestExpectedEqual;
                } else |actual_err| {
                    try expectEqual(expected_err, actual_err);
                }
            }
        },
    }
}

fn SliceDiffer(comptime T: type) type {
    return struct {
        start_index: usize,
        expected: []const T,
        actual: []const T,
        ttyconf: std.io.tty.Config,

        const Self = @This();

        pub fn write(self: Self) !void {
            for (self.expected, 0..) |value, i| {
                const full_index = self.start_index + i;
                if (@typeInfo(T) == .Pointer) {
                    try writer.print("[{}]{*}: {any}", .{ full_index, value, value });
                } else {
                    try writer.print("[{}]: {any}", .{ full_index, value });
                }
            }
        }
    };
}

pub fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
    if (expected.ptr == actual.ptr and expected.len == actual.len) {
        return;
    }
    const diff_index: usize = diff_index: {
        const shortest = @min(expected.len, actual.len);
        var index: usize = 0;
        while (index < shortest) : (index += 1) {
            if (!std.meta.eql(actual[index], expected[index])) break :diff_index index;
        }
        break :diff_index if (expected.len == actual.len) return else shortest;
    };

    log.err("slices differ. first difference occurs at index {d} (0x{X})", .{ diff_index, diff_index });

    // TODO: Should this be configurable by the caller?
    const max_lines: usize = 16;
    const max_window_size: usize = if (T == u8) max_lines * 16 else max_lines;

    // log.err a maximum of max_window_size items of each input, starting just before the
    // first difference to give a bit of context.
    var window_start: usize = 0;
    if (@max(actual.len, expected.len) > max_window_size) {
        const alignment = if (T == u8) 16 else 2;
        window_start = std.mem.alignBackward(usize, diff_index - @min(diff_index, alignment), alignment);
    }
    const expected_window = expected[window_start..@min(expected.len, window_start + max_window_size)];
    const expected_truncated = window_start + expected_window.len < expected.len;
    const actual_window = actual[window_start..@min(actual.len, window_start + max_window_size)];
    const actual_truncated = window_start + actual_window.len < actual.len;

    const ttyconf = std.io.tty.detectConfig(writer);
    var differ = if (T == u8) BytesDiffer{
        .expected = expected_window,
        .actual = actual_window,
        .ttyconf = ttyconf,
    } else SliceDiffer(T){
        .start_index = window_start,
        .expected = expected_window,
        .actual = actual_window,
        .ttyconf = ttyconf,
    };

    // log.err indexes as hex for slices of u8 since it's more likely to be binary data where
    // that is usually useful.
    const index_fmt = if (T == u8) "0x{X}" else "{}";

    log.err("\n============ expected this output: =============  len: {} (0x{X})\n", .{ expected.len, expected.len });
    if (window_start > 0) {
        if (T == u8) {
            log.err("... truncated, start index: " ++ index_fmt ++ " ...", .{window_start});
        } else {
            log.err("... truncated ...", .{});
        }
    }
    differ.write(writer) catch {};
    if (expected_truncated) {
        const end_offset = window_start + expected_window.len;
        const num_missing_items = expected.len - (window_start + expected_window.len);
        if (T == u8) {
            log.err("... truncated, indexes [" ++ index_fmt ++ "..] not shown, remaining bytes: " ++ index_fmt ++ " ...", .{ end_offset, num_missing_items });
        } else {
            log.err("... truncated, remaining items: " ++ index_fmt ++ " ...", .{num_missing_items});
        }
    }

    // now reverse expected/actual and log.err again
    differ.expected = actual_window;
    differ.actual = expected_window;
    log.err("\n============= instead found this: ==============  len: {} (0x{X})\n", .{ actual.len, actual.len });
    if (window_start > 0) {
        if (T == u8) {
            log.err("... truncated, start index: " ++ index_fmt ++ " ...", .{window_start});
        } else {
            log.err("... truncated ...", .{});
        }
    }
    differ.write(writer) catch {};
    if (actual_truncated) {
        const end_offset = window_start + actual_window.len;
        const num_missing_items = actual.len - (window_start + actual_window.len);
        if (T == u8) {
            log.err("... truncated, indexes [" ++ index_fmt ++ "..] not shown, remaining bytes: " ++ index_fmt ++ " ...", .{ end_offset, num_missing_items });
        } else {
            log.err("... truncated, remaining items: " ++ index_fmt ++ " ...", .{num_missing_items});
        }
    }
    log.err("\n================================================\n", .{});

    return error.TestExpectedEqual;
}

const BytesDiffer = struct {
    expected: []const u8,
    actual: []const u8,
    ttyconf: std.io.tty.Config,

    pub fn write(self: BytesDiffer) !void {
        var expected_iterator = std.mem.window(u8, self.expected, 16, 16);
        var row: usize = 0;
        while (expected_iterator.next()) |chunk| {
            // to avoid having to calculate diffs twice per chunk
            var diffs: std.bit_set.IntegerBitSet(16) = .{ .mask = 0 };
            for (chunk, 0..) |byte, col| {
                const absolute_byte_index = col + row * 16;
                const diff = if (absolute_byte_index < self.actual.len) self.actual[absolute_byte_index] != byte else true;
                if (diff) diffs.set(col);
                try self.writeDiff("{X:0>2} ", .{byte});
                if (col == 7) try writer.writeByte(' ');
            }
            try writer.writeByte(' ');
            if (chunk.len < 16) {
                var missing_columns = (16 - chunk.len) * 3;
                if (chunk.len < 8) missing_columns += 1;
                try writer.writeByteNTimes(' ', missing_columns);
            }
            for (chunk) |
                byte,
            | {
                if (std.ascii.isPrint(byte)) {
                    try self.writeDiff("{c}", .{byte});
                } else {
                    // TODO: remove this `if` when https://github.com/ziglang/zig/issues/7600 is fixed
                    if (self.ttyconf == .windows_api) {
                        try self.writeDiff(".", .{});
                        continue;
                    }

                    // Let's print some common control codes as graphical Unicode symbols.
                    // We don't want to do this for all control codes because most control codes apart from
                    // the ones that Zig has escape sequences for are likely not very useful to print as symbols.
                    switch (byte) {
                        '\n' => try self.writeDiff("␊", .{}),
                        '\r' => try self.writeDiff("␍", .{}),
                        '\t' => try self.writeDiff("␉", .{}),
                        else => try self.writeDiff(".", .{}),
                    }
                }
            }
            try writer.writeByte('\n');
            row += 1;
        }
    }
};

// ====================================================

/// Get the address of the caller.
inline fn callerInfo() usize {
    return @returnAddress();
}

/// Mark a function as available only for runtime tests.
/// When it can be called when runtime tests are disabled, it will raise a compile error.
inline fn onlyForTest() void {
    if (!norn.is_runtime_test) {
        @compileError("This function is available only for runtime tests.");
    }
}

fn failure() noreturn {
    @setCold(true);

    // Terminate QEMU if isa-debug-exit device is available.
    norn.terminateQemu(1);
    // Otherwise, halt the CPU.
    norn.endlessHalt();
}