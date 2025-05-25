//! Surtr bootloader parameters.
//!
//! Parameter file is passed to Surtr bootloader to configure the boot process.
//! The file is located at `/efi/boot/bootparams`.
//! To update the file, you can run `zig build update-bootparams` command.
//!
//! The file format is a simple key-value pair similar to dotenv file.
//! Unlike dotenv, a parameter cannot be quoted.
//!
//! Example:
//!
//! ```txt
//! # Comment Line
//! SURTR_CMDLINE=quiet splash
//! ```

pub const ParseError = error{
    /// The file contains an invalid line.
    InvalidFormat,
    /// Unknown key found.
    UnrecognizedKey,
    /// Memory allocation failed.
    OutOfMemory,
};

/// Boot parameters for Surtr bootloader.
///
/// Parameters are passed by text file `/efi/boot/bootparams`.
pub const SurtrParams = struct {
    /// Command line arguments for the kernel.
    cmdline: ?[]const u8 = null,
};

/// Parser for `bootparams` file.
///
/// The format is a simple key-value pair similar to dotenv file.
/// Unlike dotenv, a parameter cannot be qupted.
pub const Parser = struct {
    /// Memory allocator used to allocate memory for internal use and for the parameters.
    allocator: Allocator,
    /// Parameter file data.
    data: []const u8,
    /// Parsed parameters.
    params: SurtrParams,

    const comment_char = '#';

    /// Creates a new parser with the given data and allocator.
    pub fn new(data: []const u8, allocator: Allocator) Parser {
        return Parser{
            .allocator = allocator,
            .data = data,
            .params = .{},
        };
    }

    /// Parse the parameter data and constructs parameters.
    ///
    /// You can free the parameter data after this call.
    /// Strings in the result parameters are newly allocated and owned by the caller.
    /// You have to free them using the provided allocator.
    pub fn parse(self: *Parser) ParseError!SurtrParams {
        errdefer {
            if (self.params.cmdline) |p| self.allocator.free(p);
        }

        var line_iter = std.mem.splitAny(u8, self.data, "\r\n");
        while (line_iter.next()) |line| {
            try self.parseLine(line);
        }

        return self.params;
    }

    fn parseLine(self: *Parser, line: []const u8) ParseError!void {
        const trimmed_line = std.mem.trim(u8, line, " ");

        if (trimmed_line.len == 0) return;
        if (trimmed_line[0] == comment_char) return;

        const eq_index = std.mem.indexOf(
            u8,
            trimmed_line,
            "=",
        ) orelse return ParseError.InvalidFormat;
        if (eq_index == 1) return ParseError.InvalidFormat;

        const key = trimmed_line[0..eq_index];
        const value: []const u8 = if (eq_index != trimmed_line.len - 1) trimmed_line[eq_index + 1 ..] else "";

        try self.setParam(key, value);
    }

    fn setParam(self: *Parser, key: []const u8, value: []const u8) ParseError!void {
        if (std.mem.eql(u8, key, "SURTR_CMDLINE")) {
            self.params.cmdline = try self.allocator.dupe(u8, value);
            return;
        }

        return ParseError.UnrecognizedKey;
    }
};

// =============================================================
// Imports
// =============================================================
const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================
// Tests
// =============================================================
const testing = std.testing;

fn parserExpect(data: []const u8, expected: anytype) !void {
    const allocator = std.testing.allocator;

    var parser = Parser.new(data, allocator);
    const param = try parser.parse();

    defer inline for (std.meta.fields(@TypeOf(param))) |field| {
        const value = @field(param, field.name);
        switch (@typeInfo(field.type)) {
            .optional => |oinfo| if (value != null) switch (@typeInfo(oinfo.child)) {
                .pointer => allocator.free(@field(param, field.name).?),
                else => {},
            },
            else => {},
        }
    };

    inline for (@typeInfo(@TypeOf(expected)).@"struct".fields) |field| {
        const name = field.name;
        const value = @field(expected, name);
        switch (@typeInfo(field.type)) {
            .pointer => try testing.expectEqualStrings(value, @field(param, name).?),
            else => try testing.expectEqual(value, @field(param, name)),
        }
    }
}

fn parserExpectError(data: []const u8, expected: anyerror) !void {
    const allocator = std.testing.allocator;

    var parser = Parser.new(data, allocator);
    try testing.expectError(expected, parser.parse());
}

test "Parser" {
    try parserExpect(
        "",
        .{},
    );

    try parserExpect(
        \\# This is a comment
        \\
        \\# This is another comment
        \\
        \\ # Comment with leading space
    ,
        .{},
    );

    try parserExpect(
        \\SURTR_CMDLINE=
    ,
        .{ .cmdline = "" },
    );

    try parserExpect(
        \\SURTR_CMDLINE=quiet
    ,
        .{ .cmdline = "quiet" },
    );

    try parserExpect(
        \\# Parameter with spaces without quoted
        \\SURTR_CMDLINE=quiet splash
    ,
        .{ .cmdline = "quiet splash" },
    );

    try parserExpect(
        \\# Quoted string
        \\SURTR_CMDLINE="quiet splash"
    ,
        .{ .cmdline = "\"quiet splash\"" },
    );

    try parserExpect(
        \\# Quoted string
        \\SURTR_CMDLINE=init=/sbin/init quiet splash
    ,
        .{ .cmdline = "init=/sbin/init quiet splash" },
    );

    try parserExpectError(
        \\invalid line
    ,
        ParseError.InvalidFormat,
    );

    try parserExpectError(
        \\\=value
    ,
        ParseError.InvalidFormat,
    );

    try parserExpectError(
        \\SURTR_CMDLINE=quiet splash
        \\#This is a comment
        \\unknown_key=value
    ,
        ParseError.UnrecognizedKey,
    );
}
