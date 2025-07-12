/// Red-black tree.
///
/// The node is intrusively embedded in the struct `T`.
///
/// - `T`: The type of the tree elements. The node is embedded in this type.
/// - `node_field`: The name of the field in `T` that stores the Node struct.
/// - `cmp`: A comparison function that takes two pointers to `T` and returns an ordering.
/// - `cmpByKey`: A comparison function that takes a key and a pointer to `T` and returns an ordering.
///
/// `cmp` function is used to sort the elements in the tree.
/// `cmpByKey` function is used only when you want to find an element by a key.
pub fn RbTree(T: type, node_field: []const u8, comptime cmp: anytype, comptime cmpByKey: anytype) type {
    return struct {
        const Self = @This();

        const Color = enum {
            red,
            black,
        };

        /// Red-black tree node.
        ///
        /// This node is intrusively embedded in the type `T` as the field `node_field`.
        pub const Node = struct {
            /// Parent node.
            parent: ?*Node = null,
            /// Color of this node.
            color: Color = .red,
            /// Left child node.
            left: ?*Node = null,
            /// Right child node.
            right: ?*Node = null,

            /// New node with initial values.
            pub const init = Node{};

            /// Get the struct `T` that this node belongs to.
            pub inline fn container(self: *Node) *T {
                return @fieldParentPtr(node_field, self);
            }
        };

        /// Root node of the tree.
        root: ?*Node = null,

        inline fn getRbNode(t: *T) *Node {
            return &@field(t, node_field);
        }

        /// Insert a new element into the tree.
        pub fn insert(self: *Self, new: *T) void {
            const new_node = Self.getRbNode(new);
            new_node.* = .{};

            var y: ?*Node = null;
            var x: ?*Node = self.root;

            while (x) |node| {
                y = node;
                x = switch (cmp(new_node.container(), node.container())) {
                    .lt => node.left,
                    else => node.right,
                };
            }
            new_node.parent = y;

            if (y) |node| {
                switch (cmp(new_node.container(), node.container())) {
                    .lt => node.left = new_node,
                    else => node.right = new_node,
                }
            } else {
                self.root = new_node;
            }

            self.insertFixup(new_node);
        }

        /// Find the node with the smallest key that is greater than or equal to the given key.
        pub fn lowerBound(self: *Self, key: anytype) ?*Node {
            if (@typeInfo(@TypeOf(cmpByKey)) == .null) {
                @compileError("cmpByKey must be provided for lowerBound()");
            }

            var current = self.root;
            var result: ?*Node = null;

            while (current) |node| {
                switch (cmpByKey(key, node.container())) {
                    .eq => {
                        return node;
                    },
                    .lt => {
                        result = node;
                        current = node.left;
                    },
                    .gt => {
                        current = node.right;
                    },
                }
            }

            return result;
        }

        fn insertFixup(self: *Self, new: *Node) void {
            var current = new;

            while (current.parent) |p| {
                var parent = p;
                if (parent.color == .black) break;
                const grandparent = parent.parent.?; // Grandparent is guaranteed to exist since it is red.

                if (parent == grandparent.left) {
                    // When the parent is a left child of the grandparent.

                    const uncle = grandparent.right;
                    if (uncle != null and uncle.?.color == .red) {
                        // Case 1: Uncle is red.
                        // Change colors of parent, uncle, and grandparent.
                        // Then, restart from grandparent.
                        const u = uncle.?;
                        parent.color = .black;
                        u.color = .black;
                        grandparent.color = .red;
                        current = grandparent;
                    } else {
                        if (current == parent.right) {
                            // Case 2: current node is a right child.
                            // Rotate left around parent.
                            self.rotateLeft(parent);
                            const tmp = current;
                            current = parent;
                            parent = tmp;
                        }
                        // Case 3: current node is a left child.
                        // Rotate right around grandparent.
                        self.rotateRight(grandparent);
                        parent.color = .black;
                        grandparent.color = .red;
                    }
                } else {
                    // When the parent is a right child of the grandparent.

                    const uncle = grandparent.left;
                    if (uncle != null and uncle.?.color == .red) {
                        const u = uncle.?;
                        parent.color = .black;
                        u.color = .black;
                        grandparent.color = .red;
                        current = grandparent;
                    } else {
                        if (current == parent.left) {
                            self.rotateRight(parent);
                            const tmp = current;
                            current = parent;
                            parent = tmp;
                        }
                        self.rotateLeft(grandparent);
                        parent.color = .black;
                        grandparent.color = .red;
                    }
                }
            }

            self.root.?.color = .black; // Ensure the root is always black.
        }

        fn rotateLeft(self: *Self, x: *Node) void {
            const y = x.right.?;

            x.right = y.left;
            if (y.left) |l| l.parent = x;

            y.parent = x.parent;
            if (x.parent) |p| {
                if (x == p.left) {
                    p.left = y;
                } else {
                    p.right = y;
                }
            } else {
                self.root = y;
            }

            y.left = x;
            x.parent = y;
        }

        fn rotateRight(self: *Self, x: *Node) void {
            const y = x.left.?;

            x.left = y.right;
            if (y.right) |r| r.parent = x;

            y.parent = x.parent;
            if (x.parent) |p| {
                if (x == p.right) {
                    p.right = y;
                } else {
                    p.left = y;
                }
            } else {
                self.root = y;
            }

            y.right = x;
            x.parent = y;
        }
    };
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

fn testCompare(a: *const TestStruct, b: *const TestStruct) std.math.Order {
    if (a.a < b.a) return .lt;
    if (a.a > b.a) return .gt;
    return .eq;
}

fn testCompareByKey(key: u32, t: *const TestStruct) std.math.Order {
    if (key < t.a) return .lt;
    if (key > t.a) return .gt;
    return .eq;
}

const TestRbTree = RbTree(TestStruct, "rb", testCompare, testCompareByKey);
const TestStruct = struct {
    a: u32,
    rb: TestRbTree.Node,
};

fn testCompareWithOneCmp(a: *const TestStructWithOneCmp, b: *const TestStructWithOneCmp) std.math.Order {
    if (a.a < b.a) return .lt;
    if (a.a > b.a) return .gt;
    return .eq;
}

const TestRbTreeWithOneCmp = RbTree(TestStructWithOneCmp, "rb", testCompareWithOneCmp, null);
const TestStructWithOneCmp = struct {
    a: u32,
    rb: TestRbTreeWithOneCmp.Node,
};

test "RbTree - basic tests" {
    var s1 = TestStruct{
        .a = 1,
        .rb = .init,
    };
    var s2 = TestStruct{
        .a = 2,
        .rb = .init,
    };
    var s3 = TestStruct{
        .a = 3,
        .rb = .init,
    };
    var s4 = TestStruct{
        .a = 4,
        .rb = .init,
    };
    var s5 = TestStruct{
        .a = 5,
        .rb = .init,
    };

    var sw1 = TestStructWithOneCmp{
        .a = 1,
        .rb = .init,
    };
    var sw2 = TestStructWithOneCmp{
        .a = 2,
        .rb = .init,
    };
    var sw3 = TestStructWithOneCmp{
        .a = 3,
        .rb = .init,
    };
    var sw4 = TestStructWithOneCmp{
        .a = 4,
        .rb = .init,
    };
    var sw5 = TestStructWithOneCmp{
        .a = 5,
        .rb = .init,
    };

    // =============================================================
    // Can access the container from the node.
    try testing.expectEqual(&s1, s1.rb.container());
    try testing.expectEqual(&s2, s2.rb.container());

    // =============================================================
    // Tree is constructed as expected.
    //   2
    //  / \
    // 1   3
    {
        var tree = TestRbTree{};
        tree.insert(&s1);
        tree.insert(&s2);
        tree.insert(&s3);
        try testing.expectEqual(&s2.rb, tree.root);
        try testing.expectEqual(&s1.rb, tree.root.?.left);
        try testing.expectEqual(&s3.rb, tree.root.?.right);
    }
    //   2
    //  / \
    // 1   3
    {
        var tree = TestRbTree{};
        tree.insert(&s3);
        tree.insert(&s1);
        tree.insert(&s2);
        try testing.expectEqual(&s2.rb, tree.root);
        try testing.expectEqual(&s1.rb, tree.root.?.left);
        try testing.expectEqual(&s3.rb, tree.root.?.right);
    }
    //   2
    //  / \
    // 1   4
    //    / \
    //   3   5
    {
        var tree = TestRbTree{};
        tree.insert(&s4);
        tree.insert(&s2);
        tree.insert(&s1);
        tree.insert(&s3);
        tree.insert(&s5);
        try testing.expectEqual(&s2.rb, tree.root);
        try testing.expectEqual(&s1.rb, tree.root.?.left);
        try testing.expectEqual(&s4.rb, tree.root.?.right);
        try testing.expectEqual(&s3.rb, tree.root.?.right.?.left);
        try testing.expectEqual(&s5.rb, tree.root.?.right.?.right);
    }
    //     4
    //    / \
    //   2   5
    //  / \
    // 1   3
    {
        var tree = TestRbTree{};
        tree.insert(&s5);
        tree.insert(&s3);
        tree.insert(&s4);
        tree.insert(&s2);
        tree.insert(&s1);
        try testing.expectEqual(&s4.rb, tree.root);
        try testing.expectEqual(&s2.rb, tree.root.?.left);
        try testing.expectEqual(&s1.rb, tree.root.?.left.?.left);
        try testing.expectEqual(&s3.rb, tree.root.?.left.?.right);
        try testing.expectEqual(&s5.rb, tree.root.?.right);
    }

    // =============================================================
    // lowerBound()
    //     4
    //    / \
    //   2   5
    //  / \
    // 1   3
    {
        var tree = TestRbTree{};
        tree.insert(&s5);
        tree.insert(&s3);
        tree.insert(&s4);
        tree.insert(&s2);
        tree.insert(&s1);
        try testing.expectEqual(&s1.rb, tree.lowerBound(@as(u32, 1)));
        try testing.expectEqual(&s2.rb, tree.lowerBound(@as(u32, 2)));
        try testing.expectEqual(&s3.rb, tree.lowerBound(@as(u32, 3)));
        try testing.expectEqual(&s4.rb, tree.lowerBound(@as(u32, 4)));
        try testing.expectEqual(&s5.rb, tree.lowerBound(@as(u32, 5)));
        try testing.expectEqual(null, tree.lowerBound(@as(u32, 6)));
        try testing.expectEqual(&s1.rb, tree.lowerBound(@as(u32, 0)));
    }

    // =============================================================
    // Can use RbTree without cmpByKey function.
    //     4
    //    / \
    //   2   5
    //  / \
    // 1   3
    {
        var tree = TestRbTreeWithOneCmp{};
        tree.insert(&sw5);
        tree.insert(&sw3);
        tree.insert(&sw4);
        tree.insert(&sw2);
        tree.insert(&sw1);
        try testing.expectEqual(&sw4.rb, tree.root);
        try testing.expectEqual(&sw2.rb, tree.root.?.left);
        try testing.expectEqual(&sw1.rb, tree.root.?.left.?.left);
        try testing.expectEqual(&sw3.rb, tree.root.?.left.?.right);
        try testing.expectEqual(&sw5.rb, tree.root.?.right);
    }
}

test "RbTree - additional tests" {
    var elms: [10]TestStruct = undefined;
    for (0..10) |i| {
        elms[i] = TestStruct{
            .a = @intCast(i + 1),
            .rb = .init,
        };
    }

    // =============================================================
    // Empty tree tests
    {
        var tree = TestRbTree{};
        try testing.expectEqual(null, tree.root);
        try testing.expectEqual(null, tree.lowerBound(@as(u32, 1)));
    }

    // =============================================================
    // Single element tests
    // 1
    {
        var tree = TestRbTree{};
        tree.insert(&elms[0]);
        try testing.expectEqual(&elms[0].rb, tree.root);
        try testing.expectEqual(null, tree.root.?.left);
        try testing.expectEqual(null, tree.root.?.right);
        try testing.expectEqual(.black, tree.root.?.color);
        try testing.expectEqual(&elms[0].rb, tree.lowerBound(@as(u32, 1)));
        try testing.expectEqual(&elms[0].rb, tree.lowerBound(@as(u32, 0)));
    }

    // =============================================================
    // Two element tests
    // 1
    //  \
    //   2
    {
        var tree = TestRbTree{};
        tree.insert(&elms[0]);
        tree.insert(&elms[1]);
        try testing.expectEqual(&elms[0].rb, tree.root);
        try testing.expectEqual(&elms[1].rb, tree.root.?.right);
        try testing.expectEqual(.black, tree.root.?.color);
        try testing.expectEqual(.red, tree.root.?.right.?.color);
    }
    //   2
    //  /
    // 1
    {
        var tree = TestRbTree{};
        tree.insert(&elms[1]);
        tree.insert(&elms[0]);
        try testing.expectEqual(&elms[1].rb, tree.root);
        try testing.expectEqual(&elms[0].rb, tree.root.?.left);
        try testing.expectEqual(.black, tree.root.?.color);
        try testing.expectEqual(.red, tree.root.?.left.?.color);
    }

    // =============================================================
    // Sequential insertion tests (ascending order)
    // Insert 1, 2, 3, 4, 5, 6, 7 in sequence
    //       2
    //      / \
    //     1   4
    //        / \
    //       3   6
    //          / \
    //         5   7
    {
        var tree = TestRbTree{};
        for (0..7) |i| {
            tree.insert(&elms[i]);
        }
        // Verify root is always black
        try testing.expectEqual(.black, tree.root.?.color);
        // Verify all elements are in tree by checking lowerBound
        for (0..7) |i| {
            try testing.expectEqual(&elms[i].rb, tree.lowerBound(@as(u32, @intCast(i + 1))));
        }

        // Verify tree structure
        try testing.expectEqual(&elms[1].rb, tree.root);
        try testing.expectEqual(&elms[0].rb, tree.root.?.left);
        try testing.expectEqual(&elms[3].rb, tree.root.?.right);
        try testing.expectEqual(&elms[2].rb, tree.root.?.right.?.left);
        try testing.expectEqual(&elms[5].rb, tree.root.?.right.?.right);
        try testing.expectEqual(&elms[4].rb, tree.root.?.right.?.right.?.left);
        try testing.expectEqual(&elms[6].rb, tree.root.?.right.?.right.?.right);
    }

    // =============================================================
    // Sequential insertion tests (descending order)
    // Insert 7, 6, 5, 4, 3, 2, 1 in sequence
    //       6
    //      / \
    //     4   7
    //    / \
    //   2   5
    //  / \
    // 1   3
    {
        var tree = TestRbTree{};
        var i: usize = 7;
        while (i > 0) {
            i -= 1;
            tree.insert(&elms[i]);
        }
        // Verify root is always black
        try testing.expectEqual(.black, tree.root.?.color);
        // Verify all elements are in tree by checking lowerBound
        for (0..7) |j| {
            try testing.expectEqual(&elms[j].rb, tree.lowerBound(@as(u32, @intCast(j + 1))));
        }

        // Verify tree structure
        try testing.expectEqual(&elms[5].rb, tree.root);
        try testing.expectEqual(&elms[3].rb, tree.root.?.left);
        try testing.expectEqual(&elms[6].rb, tree.root.?.right);
        try testing.expectEqual(&elms[1].rb, tree.root.?.left.?.left);
        try testing.expectEqual(&elms[4].rb, tree.root.?.left.?.right);
        try testing.expectEqual(&elms[0].rb, tree.root.?.left.?.left.?.left);
        try testing.expectEqual(&elms[2].rb, tree.root.?.left.?.left.?.right);
    }

    // =============================================================
    // Random insertion pattern tests
    //       4 (black)
    //      / \
    //     2   6
    //    / \ / \
    //   1  3 5  7
    {
        var tree = TestRbTree{};
        const order = [_]usize{ 3, 1, 5, 0, 2, 4, 6 };
        for (order) |idx| {
            tree.insert(&elms[idx]);
        }
        try testing.expectEqual(.black, tree.root.?.color);

        try testing.expectEqual(&elms[3].rb, tree.root);
        try testing.expectEqual(&elms[1].rb, tree.root.?.left);
        try testing.expectEqual(&elms[5].rb, tree.root.?.right);
        try testing.expectEqual(&elms[0].rb, tree.root.?.left.?.left);
        try testing.expectEqual(&elms[2].rb, tree.root.?.left.?.right);
        try testing.expectEqual(&elms[4].rb, tree.root.?.right.?.left);
        try testing.expectEqual(&elms[6].rb, tree.root.?.right.?.right);
    }

    // =============================================================
    // Comprehensive lowerBound tests
    // Insert odd numbers: 1, 3, 5, 7, 9
    //     5
    //    / \
    //   3   7
    //  /   / \
    // 1   x   9
    {
        var tree = TestRbTree{};
        // Insert odd numbers: 1, 3, 5, 7, 9
        for (0..5) |i| {
            tree.insert(&elms[i * 2]);
        }

        // Test exact matches
        try testing.expectEqual(&elms[0].rb, tree.lowerBound(@as(u32, 1)));
        try testing.expectEqual(&elms[2].rb, tree.lowerBound(@as(u32, 3)));
        try testing.expectEqual(&elms[4].rb, tree.lowerBound(@as(u32, 5)));
        try testing.expectEqual(&elms[6].rb, tree.lowerBound(@as(u32, 7)));
        try testing.expectEqual(&elms[8].rb, tree.lowerBound(@as(u32, 9)));

        // Test values between elements
        try testing.expectEqual(&elms[2].rb, tree.lowerBound(@as(u32, 2)));
        try testing.expectEqual(&elms[4].rb, tree.lowerBound(@as(u32, 4)));
        try testing.expectEqual(&elms[6].rb, tree.lowerBound(@as(u32, 6)));
        try testing.expectEqual(&elms[8].rb, tree.lowerBound(@as(u32, 8)));

        // Test boundary values
        try testing.expectEqual(&elms[0].rb, tree.lowerBound(@as(u32, 0)));
        try testing.expectEqual(null, tree.lowerBound(@as(u32, 10)));
    }

    // =============================================================
    // Color property tests
    {
        var tree = TestRbTree{};
        for (0..8) |i| {
            tree.insert(&elms[i]);
        }

        // Root must be black
        try testing.expectEqual(.black, tree.root.?.color);

        // Verify no red node has a red child (simplified check)
        try testVerifyNoRedRedParentChild(tree.root);
    }

    // =============================================================
    // Parent-child relationship tests
    //   2
    //  / \
    // 1   3
    {
        var tree = TestRbTree{};
        tree.insert(&elms[1]);
        tree.insert(&elms[0]);
        tree.insert(&elms[2]);

        // Check parent relationships
        try testing.expectEqual(null, tree.root.?.parent);
        try testing.expectEqual(tree.root, tree.root.?.left.?.parent);
        try testing.expectEqual(tree.root, tree.root.?.right.?.parent);
    }

    // =============================================================
    // Node initialization tests
    {
        const node = TestRbTree.Node.init;
        try testing.expectEqual(null, node.parent);
        try testing.expectEqual(.red, node.color);
        try testing.expectEqual(null, node.left);
        try testing.expectEqual(null, node.right);
    }

    // =============================================================
    // Duplicate value handling tests
    {
        var tree = TestRbTree{};
        var dup1 = TestStruct{ .a = 5, .rb = .init };
        var dup2 = TestStruct{ .a = 5, .rb = .init };

        tree.insert(&dup1);
        tree.insert(&dup2);

        // Both should be in tree (since they are different objects)
        try testing.expectEqual(.black, tree.root.?.color);
        // One should be root, other should be child
        try testing.expect(tree.root.?.left != null or tree.root.?.right != null);
    }
}

/// Helper function to verify no red node has a red child
fn testVerifyNoRedRedParentChild(node: ?*TestRbTree.Node) !void {
    if (node == null) return;

    const n = node.?;
    if (n.color == .red) {
        if (n.left) |left| {
            try testing.expectEqual(.black, left.color);
        }
        if (n.right) |right| {
            try testing.expectEqual(.black, right.color);
        }
    }

    try testVerifyNoRedRedParentChild(n.left);
    try testVerifyNoRedRedParentChild(n.right);
}

// =============================================================
// Test with different data types
const TestRbTreeString = RbTree(TestStructString, "rb", testCompareString, testCompareByKeyString);
const TestStructString = struct {
    name: []const u8,
    rb: TestRbTreeString.Node,
};

fn testCompareString(a: *const TestStructString, b: *const TestStructString) std.math.Order {
    return std.mem.order(u8, a.name, b.name);
}

fn testCompareByKeyString(key: []const u8, t: *const TestStructString) std.math.Order {
    return std.mem.order(u8, key, t.name);
}

test "RbTree - string type tests" {
    var alice = TestStructString{ .name = "alice", .rb = .init };
    var bob = TestStructString{ .name = "bob", .rb = .init };
    var charlie = TestStructString{ .name = "charlie", .rb = .init };

    //     bob
    //    /   \
    // alice charlie
    var tree = TestRbTreeString{};
    tree.insert(&bob);
    tree.insert(&alice);
    tree.insert(&charlie);

    try testing.expectEqual(&bob.rb, tree.root);
    try testing.expectEqual(&alice.rb, tree.root.?.left);
    try testing.expectEqual(&charlie.rb, tree.root.?.right);

    // Test lowerBound with strings
    try testing.expectEqual(&alice.rb, tree.lowerBound("alice"));
    try testing.expectEqual(&bob.rb, tree.lowerBound("bob"));
    try testing.expectEqual(&charlie.rb, tree.lowerBound("charlie"));
    try testing.expectEqual(&alice.rb, tree.lowerBound("a"));
    try testing.expectEqual(&bob.rb, tree.lowerBound("b"));
    try testing.expectEqual(null, tree.lowerBound("z"));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const EnumField = std.builtin.Type.EnumField;
