const std = @import("std");
const uefi = std.os.uefi;
const stdlog = std.log;
const option = @import("option");

const Sto = uefi.protocol.SimpleTextOutput;

const LogError = error{};

const writer_vtable = std.Io.Writer.VTable{
    .drain = drain,
};

var writer = std.Io.Writer{
    .vtable = &writer_vtable,
    .buffer = &.{},
};

/// Default log options.
/// You can override std_options in your main file.
pub const default_log_options = std.Options{
    .log_level = switch (option.log_level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    },
    .logFn = log,
};

var con_out: *Sto = undefined;

/// Initialize bootloader log.
pub fn init(out: *Sto) void {
    con_out = out;
}

fn drain(_: *std.Io.Writer, data: []const []const u8, _: usize) LogError!usize {
    var written: usize = 0;
    for (data) |bytes| {
        for (bytes) |b| {
            _ = con_out.outputString(&[_:0]u16{b}) catch unreachable;
        }
        written += bytes.len;
    }
    return written;
}

fn log(
    comptime level: stdlog.Level,
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
    const scope_str = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    writer.print(
        level_str ++ " " ++ scope_str ++ fmt ++ "\r\n",
        args,
    ) catch unreachable;
}
