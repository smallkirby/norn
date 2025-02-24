//! Generic typing utility.
//!
//! This file provides generic data structures and types.

/// Wrapper struct that allows setting values to the part of fields with an anonymous struct.
pub fn Partialable(Type: type) type {
    return packed struct {
        const Self = @This();

        comptime {
            if (@bitSizeOf(Type) != @bitSizeOf(Self)) {
                @compileError("Size mismatch");
            }
        }

        /// Inner type.
        pub const T = Type;
        /// Inner value.
        inner: T,

        /// Initialize the inner struct.
        pub fn new(value: T) Self {
            return .{ .inner = value };
        }

        /// Set the part of fields of the inner struct.
        pub fn set(self: *Self, partial: anytype) void {
            inline for (@typeInfo(@TypeOf(partial)).Struct.fields) |field| {
                @field(self.inner, field.name) = @field(partial, field.name);
            }
        }
    };
}

/// Doubly-linked list where head is embedded in the data structure itself.
///
/// This is based on Zig standard library's `std.DoublyLinkedList`,
/// but the head is embedded in the data structure
/// that is allocated and managed separately in the standard library.
///
/// - `T`    : Type of the data structure to be managed in the list.
/// - `field`: Field name of the head (`Head`) in the data structure.
pub fn InlineDoublyLinkedList(comptime T: type, comptime field: []const u8) type {
    return struct {
        const Self = @This();

        pub const Head = packed struct {
            next: ?*T = null,
            prev: ?*T = null,
        };

        first: ?*T = null,
        last: ?*T = null,
        len: usize = 0,

        pub fn insertAfter(list: *Self, after: *T, new: *T) void {
            const after_head: *Head = head(after);
            const new_head: *Head = head(new);

            new_head.prev = after;
            if (after_head.next) |next| {
                new_head.next = next;
                head(next).prev = new;
            } else {
                new_head.next = null;
                list.last = new;
            }
            after_head.next = new;

            list.len += 1;
        }

        pub fn insertBefore(list: *Self, before: *T, new: *T) void {
            const before_head = head(before);
            const new_head: *Head = head(new);

            new_head.next = before;
            if (before_head.prev) |prev| {
                new_head.prev = prev;
                head(prev).next = new;
            } else {
                new_head.prev = null;
                list.first = new;
            }
            before_head.prev = new;

            list.len += 1;
        }

        pub fn append(list: *Self, new: *T) void {
            if (list.last) |last| {
                list.insertAfter(last, new);
            } else {
                list.prepend(new);
            }
        }

        pub fn prepend(list: *Self, new: *T) void {
            const new_head: *Head = head(new);

            if (list.first) |first| {
                list.insertBefore(first, new);
            } else {
                list.first = new;
                list.last = new;
                list.len = 1;
                new_head.prev = null;
                new_head.next = null;
            }
        }

        pub fn remove(list: *Self, node: *T) void {
            const node_head: *Head = head(node);

            if (node_head.prev) |prev| {
                head(prev).next = node_head.next;
            } else {
                list.first = node_head.next;
            }
            if (node_head.next) |next| {
                head(next).prev = node_head.prev;
            } else {
                list.last = node_head.prev;
            }

            list.len -= 1;
        }

        pub fn pop(list: *Self) ?*T {
            const last = list.last orelse return null;
            list.remove(last);
            return last;
        }

        pub fn popFirst(list: *Self) ?*T {
            const first = list.first orelse return null;
            list.remove(first);
            return first;
        }

        pub fn isEmpty(list: *Self) bool {
            return list.len == 0;
        }

        inline fn head(node: *T) *Head {
            return &@field(node, field);
        }
    };
}

// =======================================

const testing = @import("std").testing;

const A = Partialable(packed struct(u64) {
    a: u8,
    b: u16,
    c: u32,
    d: u8,
});

test "Partialable" {
    var va = A.new(.{
        .a = 0x12,
        .b = 0x3456,
        .c = 0x789A_BCD0,
        .d = 0xAB,
    });
    try testing.expectEqual(va.inner, A.T{
        .a = 0x12,
        .b = 0x3456,
        .c = 0x789A_BCD0,
        .d = 0xAB,
    });

    va.set(.{
        .b = 0xDEAD,
        .c = 0x1234_5678,
    });
    try testing.expectEqual(va.inner, A.T{
        .a = 0x12,
        .b = 0xDEAD,
        .c = 0x1234_5678,
        .d = 0xAB,
    });
}

const SomeStructList = InlineDoublyLinkedList(SomeStruct, "list_head");

const SomeStruct = struct {
    a: u32,
    b: u16 = 0,
    list_head: SomeStructList.Head = .{},
    c: u64 = 0,

    pub fn new(a: u32) SomeStruct {
        return .{
            .a = a,
        };
    }
};

test "InlineDoublyLinkedList" {
    var list = SomeStructList{};

    var s1 = SomeStruct.new(1);
    var s2 = SomeStruct.new(2);
    var s3 = SomeStruct.new(3);
    var s4 = SomeStruct.new(4);
    var s5 = SomeStruct.new(5);

    try testing.expect(list.isEmpty());

    list.prepend(&s1);
    // s1
    try testing.expectEqual(1, list.len);
    try testing.expectEqual(&s1, list.first);
    try testing.expectEqual(&s1, list.last);
    try testing.expectEqual(null, s1.list_head.next);
    try testing.expectEqual(null, s1.list_head.prev);

    list.prepend(&s2);
    // s2 -> s1
    try testing.expectEqual(2, list.len);
    try testing.expectEqual(&s1, s2.list_head.next);
    try testing.expectEqual(null, s1.list_head.next);
    try testing.expectEqual(null, s2.list_head.prev);
    try testing.expectEqual(&s2, s1.list_head.prev);
    try testing.expectEqual(&s2, list.first);
    try testing.expectEqual(&s1, list.last);

    list.append(&s3);
    // s2 -> s1 -> s3
    try testing.expectEqual(3, list.len);
    try testing.expectEqual(&s1, s2.list_head.next);
    try testing.expectEqual(&s3, s1.list_head.next);
    try testing.expectEqual(null, s3.list_head.next);
    try testing.expectEqual(null, s2.list_head.prev);
    try testing.expectEqual(&s2, s1.list_head.prev);
    try testing.expectEqual(&s1, s3.list_head.prev);

    list.insertBefore(&s3, &s4);
    // s2 -> s1 -> s4 -> s3
    try testing.expectEqual(4, list.len);
    try testing.expectEqual(&s4, s1.list_head.next);
    try testing.expectEqual(&s3, s4.list_head.next);
    try testing.expectEqual(&s4, s3.list_head.prev);
    try testing.expectEqual(&s1, s4.list_head.prev);

    list.insertAfter(&s2, &s5);
    // s2 -> s5 -> s1 -> s4 -> s3
    try testing.expectEqual(5, list.len);
    try testing.expectEqual(&s5, s2.list_head.next);
    try testing.expectEqual(&s1, s5.list_head.next);
    try testing.expectEqual(&s5, s1.list_head.prev);
    try testing.expectEqual(&s2, s5.list_head.prev);

    list.remove(&s1);
    // s2 -> s5 -> s4 -> s3
    try testing.expectEqual(4, list.len);
    try testing.expectEqual(&s4, s5.list_head.next);
    try testing.expectEqual(&s5, s4.list_head.prev);

    const p1 = list.pop();
    // s2 -> s5 -> s4
    try testing.expectEqual(3, list.len);
    try testing.expectEqual(&s3, p1);
    try testing.expectEqual(null, s4.list_head.next);

    const p2 = list.popFirst();
    // s5 -> s4
    try testing.expectEqual(2, list.len);
    try testing.expectEqual(&s2, p2);
    try testing.expectEqual(null, s5.list_head.prev);

    const p3 = list.pop();
    const p4 = list.pop();
    try testing.expect(list.isEmpty());
    try testing.expectEqual(&s4, p3);
    try testing.expectEqual(&s5, p4);
    try testing.expectEqual(null, list.pop());
    try testing.expectEqual(null, list.popFirst());
}
