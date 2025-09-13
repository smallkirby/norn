pub const ParseError = error{
    /// The file contains an invalid line.
    InvalidFormat,
    /// Unknown key found.
    UnrecognizedKey,
    /// Duplicated key found.
    DuplicatedKey,
    /// Memory allocation failed.
    OutOfMemory,
};

/// Norn command line arguments.
pub const Cmdline = struct {
    /// Initial command line string.
    init: ?[]const []const u8 = null,
};

/// Command line argument parser.
pub const Parser = struct {
    allocator: Allocator,
    data: []const u8,

    _cmdline: Cmdline,
    _state: State = .{},

    const State = struct {
        phase: Phase = .waiting_key,
        p: [*]const u8 = undefined,
        in_quote: bool = false,
        in_dquote: bool = false,
        key_start: [*]const u8 = undefined,
        key_end: [*]const u8 = undefined,
        value_start: [*]const u8 = undefined,
        value_end: [*]const u8 = undefined,
        start_by_quote: bool = false,
        start_by_dquote: bool = false,

        fn reset(self: *State) void {
            const p = self.p;
            self.* = .{};
            self.p = p;
        }
    };

    const Phase = enum {
        waiting_key,
        reading_key,
        waiting_value,
        reading_value,
    };

    /// Initialize a new parser.
    pub fn new(data: []const u8, allocator: Allocator) Parser {
        return .{
            .data = data,
            .allocator = allocator,
            ._cmdline = Cmdline{},
        };
    }

    /// Parse to construct a Norn command line arguments.
    pub fn parse(self: *Parser) ParseError!Cmdline {
        const state = &self._state;
        state.p = self.data.ptr;
        const end = state.p + self.data.len;

        while (@intFromPtr(state.p) < @intFromPtr(end)) : (state.p += 1) {
            switch (state.phase) {
                .waiting_key => if (state.p[0] != ' ') {
                    state.key_start = state.p;
                    state.phase = .reading_key;
                },
                .reading_key => if (state.p[0] == '=') {
                    state.key_end = state.p;
                    state.phase = .waiting_value;
                },
                .waiting_value => switch (state.p[0]) {
                    '\'' => {
                        state.in_quote = true;
                        state.start_by_quote = true;
                        state.value_start = state.p + 1;
                        state.phase = .reading_value;
                    },
                    '"' => {
                        state.in_dquote = true;
                        state.start_by_dquote = true;
                        state.value_start = state.p + 1;
                        state.phase = .reading_value;
                    },
                    else => {
                        state.value_start = state.p;
                        state.phase = .reading_value;
                    },
                },
                .reading_value => switch (state.p[0]) {
                    '\'' => {
                        state.in_quote = !state.in_quote;
                        if (!state.in_quote and state.start_by_quote) {
                            state.value_end = state.p;
                            try self.process();
                            self._state.reset();
                        }
                    },
                    '"' => {
                        state.in_dquote = !state.in_dquote;
                        if (!state.in_dquote and state.start_by_dquote) {
                            state.value_end = state.p;
                            try self.process();
                            self._state.reset();
                        }
                    },
                    ' ' => if (!state.in_quote and !state.in_dquote) {
                        state.value_end = state.p;
                        try self.process();
                        self._state.reset();
                    },
                    else => {},
                },
            }
        }
        // Handle empty value.
        if (self._state.phase == .waiting_value) {
            self._state.value_start = self._state.p;
            self._state.value_end = self._state.p;
            try self.process();
            self._state.reset();
        }
        // Handle the last key-value pair.
        if (self._state.phase == .reading_value) {
            if (self._state.start_by_quote or self._state.start_by_dquote) {
                return ParseError.InvalidFormat;
            }
            state.value_end = self._state.p;
            try self.process();
            self._state.reset();
        }
        // Unexpected end of data.
        if (state.phase != .waiting_key) {
            return ParseError.InvalidFormat;
        }

        return self._cmdline;
    }

    fn process(self: *Parser) ParseError!void {
        const state = &self._state;
        if (!util.ptrLte(state.key_start, state.key_end)) {
            return ParseError.InvalidFormat;
        }
        if (!util.ptrLte(state.value_start, state.value_end)) {
            return ParseError.InvalidFormat;
        }
        const key = try self.allocator.dupe(u8, state.key_start[0 .. state.key_end - state.key_start]);
        const value = try self.allocator.dupe(u8, state.value_start[0 .. state.value_end - state.value_start]);
        try self.assign(key, value);
    }

    fn assign(self: *Parser, key: []const u8, value: []const u8) ParseError!void {
        if (std.mem.eql(u8, key, "init")) {
            if (self._cmdline.init != null) {
                return ParseError.DuplicatedKey;
            }

            var iter = std.mem.tokenizeAny(u8, value, " ");
            var tokens = std.array_list.Aligned([]const u8, null).empty;
            errdefer tokens.deinit(self.allocator);
            while (iter.next()) |token| {
                try tokens.append(self.allocator, token);
            }

            self._cmdline.init = tokens.items;
        } else {
            return ParseError.UnrecognizedKey;
        }
    }
};

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

fn parseExpect(data: []const u8, expected: anytype) !void {
    const allocator = std.heap.page_allocator;
    var parser = Parser.new(data, allocator);
    const cmdline = try parser.parse();

    inline for (@typeInfo(@TypeOf(expected)).@"struct".fields) |field| {
        const name = field.name;
        const value = @field(expected, name);
        switch (@typeInfo(field.type)) {
            .pointer => try testing.expectEqualDeep(value, @field(cmdline, name).?),
            else => try testing.expectEqual(value, @field(cmdline, name)),
        }
    }
}

fn parseExpectError(data: []const u8, expected: anyerror) !void {
    const allocator = std.heap.page_allocator;
    var parser = Parser.new(data, allocator);
    try testing.expectError(expected, parser.parse());
}

test Parser {
    try parseExpect(
        "init=/bin/busybox",
        .{ .init = &[_][]const u8{"/bin/busybox"} },
    );
    try parseExpect(
        "  init=/bin/busybox  ",
        .{ .init = &[_][]const u8{"/bin/busybox"} },
    );
    try parseExpect(
        "   ",
        .{ .init = null },
    );
    try parseExpect(
        "init=\"/bin/busybox sh -c /root\"",
        .{ .init = &[_][]const u8{ "/bin/busybox", "sh", "-c", "/root" } },
    );
    try parseExpect(
        "init='/bin/busybox sh -c /root'",
        .{ .init = &[_][]const u8{ "/bin/busybox", "sh", "-c", "/root" } },
    );
    try parseExpect(
        "init='/bin/busybox echo \"new\"'",
        .{ .init = &[_][]const u8{ "/bin/busybox", "echo", "\"new\"" } },
    );
    try parseExpect(
        "init=",
        .{ .init = &[_][]const u8{} },
    );

    try parseExpectError(
        "init='/bin/busybox",
        ParseError.InvalidFormat,
    );
    try parseExpectError(
        "init=\"/bin/busybox",
        ParseError.InvalidFormat,
    );
    try parseExpectError(
        "unknown=foo",
        ParseError.UnrecognizedKey,
    );
    try parseExpectError(
        "init=foo init=bar",
        ParseError.DuplicatedKey,
    );
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const util = norn.util;
