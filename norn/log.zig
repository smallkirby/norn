/// Logger function type
pub const LogFn = *const fn (comptime format: []const u8, args: anytype) void;

/// Log level.
/// Can be configured by compile-time options. See build.zig.
pub const log_level = switch (option.log_level) {
    .debug => .debug,
    .info => .info,
    .warn => .warn,
    .err => .err,
};

const LogError = error{};

const writer_vtable = std.Io.Writer.VTable{
    .drain = drain,
};

var writer = std.Io.Writer{
    .vtable = &writer_vtable,
    .buffer = &.{},
};

/// Serial console for logging.
var serial: *Serial = undefined;

/// Initialize the logger with the given serial console.
/// You MUST call this function before using the logger.
pub fn init() void {
    serial = norn.getSerial();
}

fn drain(_: *std.Io.Writer, data: []const []const u8, _: usize) LogError!usize {
    var written: usize = 0;
    for (data) |bytes| {
        serial.writeString(bytes);
        written += bytes.len;
    }
    return written;
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const level_str = comptime switch (level) {
        .debug => "[DEBUG]",
        .info => "[INFO ]",
        .warn => "[WARN ]",
        .err => "[ERROR]",
    };

    const scope_str = if (@tagName(scope).len <= 8) b: {
        break :b std.fmt.comptimePrint(
            "{s: <8}| ",
            .{@tagName(scope)},
        );
    } else b: {
        break :b std.fmt.comptimePrint(
            "{s: <7}-| ",
            .{@tagName(scope)[0..7]},
        );
    };

    writer.print(
        level_str ++ " " ++ scope_str ++ fmt ++ "\n",
        args,
    ) catch {};
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const io = std.io;
const option = @import("option");

const norn = @import("norn");
const Serial = norn.Serial;
