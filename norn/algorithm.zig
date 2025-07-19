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
///
/// 1. Every node is either red or black.
/// 2. All NIL nodes are black.
/// 3. A red node does not have a red child.
/// 4. Every path from a given node to any of its leaf nodes goes through the same number of black nodes.
/// 5. (If a node has exactly one child, the child must be red.)
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
            _parent: ?*Node = null,
            /// Color of this node.
            _color: Color = .red,
            /// Left child node.
            _left: ?*Node = null,
            /// Right child node.
            _right: ?*Node = null,

            /// New node with initial values.
            pub const init = Node{};

            /// Get the struct `T` that this node belongs to.
            pub inline fn container(self: *Node) *T {
                return @fieldParentPtr(node_field, self);
            }

            /// Get the maximum node in the subtree.
            pub fn max(self: *Node) *Node {
                var current: *Node = self;
                while (true) {
                    if (current._right) |right| {
                        current = right;
                    } else {
                        break;
                    }
                }
                return current;
            }

            /// Get the minimum node in the subtree.
            pub fn min(self: *Node) *Node {
                var current: *Node = self;
                while (true) {
                    if (current._left) |left| {
                        current = left;
                    } else {
                        break;
                    }
                }
                return current;
            }
        };

        /// Root node of the tree.
        root: ?*Node = null,

        inline fn getRbNode(t: *T) *Node {
            return &@field(t, node_field);
        }

        /// Insert a new element into the tree.
        pub fn insert(self: *Self, new: *T) void {
            const new_node = getRbNode(new);
            new_node.* = .{};

            var y: ?*Node = null;
            var x: ?*Node = self.root;

            while (x) |node| {
                y = node;
                x = switch (cmp(new_node.container(), node.container())) {
                    .lt => node._left,
                    else => node._right,
                };
            }
            new_node._parent = y;

            if (y) |node| {
                switch (cmp(new_node.container(), node.container())) {
                    .lt => node._left = new_node,
                    else => node._right = new_node,
                }
            } else {
                self.root = new_node;
            }

            self.insertFixup(new_node);
        }

        fn insertFixup(self: *Self, new: *Node) void {
            var current = new;

            while (current._parent) |p| {
                var parent = p;
                if (parent._color == .black) break;
                const grandparent = parent._parent.?; // Grandparent is guaranteed to exist since it is red.

                if (parent == grandparent._left) {
                    // When the parent is a left child of the grandparent.

                    const uncle = grandparent._right;
                    if (uncle != null and uncle.?._color == .red) {
                        // Case 1: Uncle is red.
                        // Change colors of parent, uncle, and grandparent.
                        // Then, restart from grandparent.
                        const u = uncle.?;
                        parent._color = .black;
                        u._color = .black;
                        grandparent._color = .red;
                        current = grandparent;
                    } else {
                        if (current == parent._right) {
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
                        parent._color = .black;
                        grandparent._color = .red;
                    }
                } else {
                    // When the parent is a right child of the grandparent.

                    const uncle = grandparent._left;
                    if (uncle != null and uncle.?._color == .red) {
                        const u = uncle.?;
                        parent._color = .black;
                        u._color = .black;
                        grandparent._color = .red;
                        current = grandparent;
                    } else {
                        if (current == parent._left) {
                            self.rotateRight(parent);
                            const tmp = current;
                            current = parent;
                            parent = tmp;
                        }
                        self.rotateLeft(grandparent);
                        parent._color = .black;
                        grandparent._color = .red;
                    }
                }
            }

            self.root.?._color = .black; // Ensure the root is always black.
        }

        /// Delete the element u and replace it with v.
        ///
        /// u must have none or one child.
        ///
        /// u and its subtree can no longer be reached from the root after this operation.
        fn transplant(self: *Self, u: *Node, v: ?*Node) void {
            if (u._left != null and u._right != null) {
                @panic("Invalid call to transplant: u has two children");
            }

            if (u._parent) |parent| {
                if (u == parent._left) {
                    parent._left = v;
                } else {
                    parent._right = v;
                }
            } else {
                self.root = v;
            }

            if (v) |node| {
                node._parent = u._parent;
            }
        }

        /// Delete the element from the tree.
        pub fn delete(self: *Self, t: *T) void {
            const node = getRbNode(t);

            var color = node._color;
            var fixup_target: ?*Node = undefined;
            var fixup_parent: ?*Node = undefined;

            if (node._left == null) {
                fixup_target = node._right;
                fixup_parent = node._parent;
                self.transplant(node, node._right);
            } else if (node._right == null) {
                fixup_target = node._left;
                fixup_parent = node._parent;
                self.transplant(node, node._left);
            } else {
                // node has two children.

                const next = node._right.?.min(); // Next does not have a left child.
                fixup_target = next._right;
                color = next._color;

                if (next._parent == node) {
                    // Next is the direct right child of node.
                    fixup_parent = node._parent;
                    next._left = node._left;
                    next._left.?._parent = next;
                    next._parent = node._parent;
                    next._color = node._color;
                } else {
                    // Next is not the direct right child of node.
                    fixup_parent = next._parent;
                    self.transplant(next, next._right);
                    next._right = node._right;
                    next._right.?._parent = next;
                    next._left = node._left;
                    next._left.?._parent = next;
                    next._parent = node._parent;
                    next._color = node._color;
                }

                if (node._parent) |p| {
                    if (node == p._left) {
                        p._left = next;
                    } else {
                        p._right = next;
                    }
                } else {
                    self.root = next;
                }
            }

            if (color == .black) {
                self.deleteFixup(fixup_target, fixup_parent);
            }
        }

        fn deleteFixup(self: *Self, target: ?*Node, target_parent: ?*Node) void {
            var x = target;
            var tp = target_parent;

            while (tp) |parent| {
                if (getColor(x) == .red) break;

                if (x == parent._left) {
                    const sibling = parent._right.?; // When x is a black, sibling must exist (not to violate the requirements 5).

                    if (sibling._color == .red) {
                        sibling._color = .black;
                        parent._color = .red;
                        self.rotateLeft(parent);
                    } else if (getColor(sibling._left) == .black and getColor(sibling._right) == .black) {
                        sibling._color = .red;

                        x = parent;
                        tp = parent._parent;
                    } else if (getColor(sibling._left) == .red and getColor(sibling._right) == .black) {
                        sibling._left.?._color = .black;
                        sibling._color = .red;
                        self.rotateRight(sibling);
                    } else if (getColor(sibling._right) == .red) {
                        sibling._color = parent._color;
                        parent._color = .black;
                        self.rotateLeft(parent);

                        break;
                    }
                } else {
                    const sibling = parent._left.?; // When x is a black, sibling must exist (not to violate the requirements 5).

                    if (sibling._color == .red) {
                        sibling._color = .black;
                        parent._color = .red;
                        self.rotateRight(parent);
                    } else if (getColor(sibling._left) == .black and getColor(sibling._right) == .black) {
                        sibling._color = .red;

                        x = parent;
                        tp = parent._parent;
                    } else if (getColor(sibling._right) == .red and getColor(sibling._left) == .black) {
                        sibling._right.?._color = .black;
                        sibling._color = .red;
                        self.rotateLeft(sibling);
                    } else if (getColor(sibling._left) == .red) {
                        sibling._color = parent._color;
                        parent._color = .black;
                        self.rotateRight(parent);

                        break;
                    }
                }
            }

            if (x) |node| {
                node._color = .black; // Ensure the node is black.
            }
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
                        current = node._left;
                    },
                    .gt => {
                        current = node._right;
                    },
                }
            }

            return result;
        }

        /// Get the maximum node in the tree.
        pub fn max(self: *Self) ?*Node {
            return if (self.root) |root| root.max() else null;
        }

        /// Get the minimum node in the tree.
        pub fn min(self: *Self) ?*Node {
            return if (self.root) |root| root.min() else null;
        }

        fn rotateLeft(self: *Self, x: *Node) void {
            const y = x._right.?;

            x._right = y._left;
            if (y._left) |l| l._parent = x;

            y._parent = x._parent;
            if (x._parent) |p| {
                if (x == p._left) {
                    p._left = y;
                } else {
                    p._right = y;
                }
            } else {
                self.root = y;
            }

            y._left = x;
            x._parent = y;
        }

        fn rotateRight(self: *Self, x: *Node) void {
            const y = x._left.?;

            x._left = y._right;
            if (y._right) |r| r._parent = x;

            y._parent = x._parent;
            if (x._parent) |p| {
                if (x == p._right) {
                    p._right = y;
                } else {
                    p._left = y;
                }
            } else {
                self.root = y;
            }

            y._right = x;
            x._parent = y;
        }

        inline fn getColor(node: ?*Node) Color {
            return if (node) |n| n._color else .black;
        }
    };
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

fn testCompare(a: *const TestStruct, b: *const TestStruct) std.math.Order {
    if (a.value < b.value) return .lt;
    if (a.value > b.value) return .gt;
    return .eq;
}

fn testCompareByKey(key: u32, t: *const TestStruct) std.math.Order {
    if (key < t.value) return .lt;
    if (key > t.value) return .gt;
    return .eq;
}

const TestRbTree = RbTree(TestStruct, "rb", testCompare, testCompareByKey);
const TestStruct = struct {
    value: u32,
    rb: TestRbTree.Node,
};

fn testCompareWithOneCmp(a: *const TestStructWithOneCmp, b: *const TestStructWithOneCmp) std.math.Order {
    if (a.value < b.value) return .lt;
    if (a.value > b.value) return .gt;
    return .eq;
}

const TestRbTreeWithOneCmp = RbTree(TestStructWithOneCmp, "rb", testCompareWithOneCmp, null);
const TestStructWithOneCmp = struct {
    value: u32,
    rb: TestRbTreeWithOneCmp.Node,
};

test "RbTree - basic tests" {
    var s1 = TestStruct{
        .value = 1,
        .rb = .init,
    };
    var s2 = TestStruct{
        .value = 2,
        .rb = .init,
    };
    var s3 = TestStruct{
        .value = 3,
        .rb = .init,
    };
    var s4 = TestStruct{
        .value = 4,
        .rb = .init,
    };
    var s5 = TestStruct{
        .value = 5,
        .rb = .init,
    };

    var sw1 = TestStructWithOneCmp{
        .value = 1,
        .rb = .init,
    };
    var sw2 = TestStructWithOneCmp{
        .value = 2,
        .rb = .init,
    };
    var sw3 = TestStructWithOneCmp{
        .value = 3,
        .rb = .init,
    };
    var sw4 = TestStructWithOneCmp{
        .value = 4,
        .rb = .init,
    };
    var sw5 = TestStructWithOneCmp{
        .value = 5,
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
        try testing.expectEqual(&s1.rb, tree.root.?._left);
        try testing.expectEqual(&s3.rb, tree.root.?._right);
        try verifyRules(tree);
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
        try testing.expectEqual(&s1.rb, tree.root.?._left);
        try testing.expectEqual(&s3.rb, tree.root.?._right);
        try verifyRules(tree);
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
        try testing.expectEqual(&s1.rb, tree.root.?._left);
        try testing.expectEqual(&s4.rb, tree.root.?._right);
        try testing.expectEqual(&s3.rb, tree.root.?._right.?._left);
        try testing.expectEqual(&s5.rb, tree.root.?._right.?._right);
        try verifyRules(tree);
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
        try testing.expectEqual(&s2.rb, tree.root.?._left);
        try testing.expectEqual(&s1.rb, tree.root.?._left.?._left);
        try testing.expectEqual(&s3.rb, tree.root.?._left.?._right);
        try testing.expectEqual(&s5.rb, tree.root.?._right);
        try verifyRules(tree);
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
        try verifyRules(tree);
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
        try testing.expectEqual(&sw2.rb, tree.root.?._left);
        try testing.expectEqual(&sw1.rb, tree.root.?._left.?._left);
        try testing.expectEqual(&sw3.rb, tree.root.?._left.?._right);
        try testing.expectEqual(&sw5.rb, tree.root.?._right);
    }
}

test "RbTree - additional tests" {
    var elms: [10]TestStruct = undefined;
    for (0..10) |i| {
        elms[i] = TestStruct{
            .value = @intCast(i),
            .rb = .init,
        };
    }

    // =============================================================
    // Empty tree tests
    {
        var tree = TestRbTree{};
        try testing.expectEqual(null, tree.root);
        try testing.expectEqual(null, tree.lowerBound(@as(u32, 1)));
        try verifyRules(tree);
    }

    // =============================================================
    // Single element tests
    // 1
    {
        var tree = TestRbTree{};
        tree.insert(&elms[1]);
        try testing.expectEqual(&elms[1].rb, tree.root);
        try testing.expectEqual(null, tree.root.?._left);
        try testing.expectEqual(null, tree.root.?._right);
        try testing.expectEqual(.black, tree.root.?._color);
        try testing.expectEqual(&elms[1].rb, tree.lowerBound(@as(u32, 1)));
        try testing.expectEqual(&elms[1].rb, tree.lowerBound(@as(u32, 0)));
        try verifyRules(tree);
    }

    // =============================================================
    // Two element tests
    // 1
    //  \
    //   2
    {
        var tree = TestRbTree{};
        tree.insert(&elms[1]);
        tree.insert(&elms[2]);
        try testing.expectEqual(&elms[1].rb, tree.root);
        try testing.expectEqual(&elms[2].rb, tree.root.?._right);
        try testing.expectEqual(.black, tree.root.?._color);
        try testing.expectEqual(.red, tree.root.?._right.?._color);
        try verifyRules(tree);
    }
    //   2
    //  /
    // 1
    {
        var tree = TestRbTree{};
        tree.insert(&elms[2]);
        tree.insert(&elms[1]);
        try testing.expectEqual(&elms[2].rb, tree.root);
        try testing.expectEqual(&elms[1].rb, tree.root.?._left);
        try testing.expectEqual(.black, tree.root.?._color);
        try testing.expectEqual(.red, tree.root.?._left.?._color);
        try verifyRules(tree);
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
        for (1..8) |i| {
            tree.insert(&elms[i]);
        }
        // Verify root is always black
        try testing.expectEqual(.black, tree.root.?._color);
        // Verify all elements are in tree by checking lowerBound
        for (1..8) |i| {
            try testing.expectEqual(&elms[i].rb, tree.lowerBound(@as(u32, @intCast(i))));
        }

        // Verify tree structure
        try testing.expectEqual(&elms[2].rb, tree.root);
        try testing.expectEqual(&elms[1].rb, tree.root.?._left);
        try testing.expectEqual(&elms[4].rb, tree.root.?._right);
        try testing.expectEqual(&elms[3].rb, tree.root.?._right.?._left);
        try testing.expectEqual(&elms[6].rb, tree.root.?._right.?._right);
        try testing.expectEqual(&elms[5].rb, tree.root.?._right.?._right.?._left);
        try testing.expectEqual(&elms[7].rb, tree.root.?._right.?._right.?._right);
        try verifyRules(tree);
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
        var i: usize = 8;
        while (i > 1) {
            i -= 1;
            tree.insert(&elms[i]);
        }
        // Verify root is always black
        try testing.expectEqual(.black, tree.root.?._color);
        // Verify all elements are in tree by checking lowerBound
        for (1..8) |j| {
            try testing.expectEqual(&elms[j].rb, tree.lowerBound(@as(u32, @intCast(j))));
        }

        // Verify tree structure
        try testing.expectEqual(&elms[6].rb, tree.root);
        try testing.expectEqual(&elms[4].rb, tree.root.?._left);
        try testing.expectEqual(&elms[7].rb, tree.root.?._right);
        try testing.expectEqual(&elms[2].rb, tree.root.?._left.?._left);
        try testing.expectEqual(&elms[5].rb, tree.root.?._left.?._right);
        try testing.expectEqual(&elms[1].rb, tree.root.?._left.?._left.?._left);
        try testing.expectEqual(&elms[3].rb, tree.root.?._left.?._left.?._right);
        try verifyRules(tree);
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
        const order = [_]usize{ 4, 2, 6, 1, 3, 5, 7 };
        for (order) |idx| {
            tree.insert(&elms[idx]);
        }
        try testing.expectEqual(.black, tree.root.?._color);

        try testing.expectEqual(&elms[4].rb, tree.root);
        try testing.expectEqual(&elms[2].rb, tree.root.?._left);
        try testing.expectEqual(&elms[6].rb, tree.root.?._right);
        try testing.expectEqual(&elms[1].rb, tree.root.?._left.?._left);
        try testing.expectEqual(&elms[3].rb, tree.root.?._left.?._right);
        try testing.expectEqual(&elms[5].rb, tree.root.?._right.?._left);
        try testing.expectEqual(&elms[7].rb, tree.root.?._right.?._right);
        try verifyRules(tree);
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
        for (1..6) |i| {
            tree.insert(&elms[i * 2 - 1]);
        }
        try verifyRules(tree);

        // Test exact matches
        try testing.expectEqual(&elms[1].rb, tree.lowerBound(@as(u32, 1)));
        try testing.expectEqual(&elms[3].rb, tree.lowerBound(@as(u32, 3)));
        try testing.expectEqual(&elms[5].rb, tree.lowerBound(@as(u32, 5)));
        try testing.expectEqual(&elms[7].rb, tree.lowerBound(@as(u32, 7)));
        try testing.expectEqual(&elms[9].rb, tree.lowerBound(@as(u32, 9)));

        // Test values between elements
        try testing.expectEqual(&elms[3].rb, tree.lowerBound(@as(u32, 2)));
        try testing.expectEqual(&elms[5].rb, tree.lowerBound(@as(u32, 4)));
        try testing.expectEqual(&elms[7].rb, tree.lowerBound(@as(u32, 6)));
        try testing.expectEqual(&elms[9].rb, tree.lowerBound(@as(u32, 8)));

        // Test boundary values
        try testing.expectEqual(&elms[1].rb, tree.lowerBound(@as(u32, 0)));
        try testing.expectEqual(null, tree.lowerBound(@as(u32, 10)));
    }

    // =============================================================
    // Parent-child relationship tests
    //   2
    //  / \
    // 1   3
    {
        var tree = TestRbTree{};
        tree.insert(&elms[2]);
        tree.insert(&elms[1]);
        tree.insert(&elms[3]);

        // Check parent relationships
        try testing.expectEqual(null, tree.root.?._parent);
        try testing.expectEqual(tree.root, tree.root.?._left.?._parent);
        try testing.expectEqual(tree.root, tree.root.?._right.?._parent);

        try verifyRules(tree);
    }

    // =============================================================
    // Node initialization tests
    {
        const node = TestRbTree.Node.init;
        try testing.expectEqual(null, node._parent);
        try testing.expectEqual(.red, node._color);
        try testing.expectEqual(null, node._left);
        try testing.expectEqual(null, node._right);
    }

    // =============================================================
    // Duplicate value handling tests
    {
        var tree = TestRbTree{};
        var dup1 = TestStruct{ .value = 5, .rb = .init };
        var dup2 = TestStruct{ .value = 5, .rb = .init };

        tree.insert(&dup1);
        tree.insert(&dup2);

        // Both should be in tree (since they are different objects)
        try testing.expectEqual(.black, tree.root.?._color);
        // One should be root, other should be child
        try testing.expect(tree.root.?._left != null or tree.root.?._right != null);
    }
}

test "RbTree - Basic Delete" {
    var elms: [10]TestStruct = undefined;
    for (0..10) |i| {
        elms[i] = TestStruct{
            .value = @intCast(i),
            .rb = .init,
        };
    }

    // =============================================================
    //       4 (black)
    //      / \
    //     2   6
    //    / \ / \
    //   1  3 5  7 (reds)
    {
        var tree = TestRbTree{};
        const order = [_]usize{ 4, 2, 6, 1, 3, 5, 7 };
        for (order) |idx| {
            tree.insert(&elms[idx]);
        }
        try verifyRules(tree);

        //       5
        //      / \
        //     2   6
        //    / \   \
        //   1  3    7
        tree.delete(&elms[4]);
        {
            try verifyRules(tree);
            try testing.expectEqual(&elms[5].rb, tree.root);
            try testing.expectEqual(&elms[2].rb, tree.root.?._left);
            try testing.expectEqual(&elms[6].rb, tree.root.?._right);
            try testing.expectEqual(&elms[1].rb, tree.root.?._left.?._left);
            try testing.expectEqual(&elms[3].rb, tree.root.?._left.?._right);
            try testing.expectEqual(&elms[7].rb, tree.root.?._right.?._right);
        }

        //       5
        //      / \
        //     2   6
        //    / \
        //   1  3
        tree.delete(&elms[7]);
        {
            try verifyRules(tree);
            try testing.expectEqual(&elms[5].rb, tree.root);
            try testing.expectEqual(&elms[2].rb, tree.root.?._left);
            try testing.expectEqual(&elms[6].rb, tree.root.?._right);
            try testing.expectEqual(&elms[1].rb, tree.root.?._left.?._left);
            try testing.expectEqual(&elms[3].rb, tree.root.?._left.?._right);
        }

        tree.delete(&elms[2]);
        //       5
        //      / \
        //     3   6
        //    /
        //   1 (red)
        {
            try verifyRules(tree);
            try testing.expectEqual(&elms[5].rb, tree.root);
            try testing.expectEqual(&elms[3].rb, tree.root.?._left);
            try testing.expectEqual(&elms[6].rb, tree.root.?._right);
            try testing.expectEqual(&elms[1].rb, tree.root.?._left.?._left);
        }

        //       5
        //      / \
        //     1   6
        tree.delete(&elms[3]);
        {
            try verifyRules(tree);
            try testing.expectEqual(&elms[5].rb, tree.root);
            try testing.expectEqual(&elms[1].rb, tree.root.?._left);
            try testing.expectEqual(&elms[6].rb, tree.root.?._right);
        }

        //       5
        //        \
        //         6
        tree.delete(&elms[1]);
        {
            try verifyRules(tree);
            try testing.expectEqual(&elms[5].rb, tree.root);
            try testing.expectEqual(null, tree.root.?._left);
            try testing.expectEqual(&elms[6].rb, tree.root.?._right);
        }

        //       6
        tree.delete(&elms[5]);
        {
            try verifyRules(tree);
            try testing.expectEqual(&elms[6].rb, tree.root);
            try testing.expectEqual(null, tree.root.?._left);
            try testing.expectEqual(null, tree.root.?._right);
        }

        tree.delete(&elms[6]);
        {
            try verifyRules(tree);
            try testing.expectEqual(null, tree.root);
        }
    }
}

test "RbTree - Additional Delete" {
    var elms: [10]TestStruct = undefined;
    for (0..10) |i| {
        elms[i] = TestStruct{
            .value = @intCast(i),
            .rb = .init,
        };
    }

    // =============================================================
    {
        var tree = TestRbTree{};
        tree.insert(&elms[5]);
        try verifyRules(tree);

        tree.delete(&elms[5]);
        try verifyRules(tree);
        try testing.expectEqual(null, tree.root);
    }

    // =============================================================
    {
        var tree = TestRbTree{};
        tree.insert(&elms[5]);
        tree.insert(&elms[3]);
        try verifyRules(tree);

        tree.delete(&elms[5]);
        try verifyRules(tree);
        try testing.expectEqual(&elms[3].rb, tree.root);
    }

    // =============================================================
    {
        var tree = TestRbTree{};
        tree.insert(&elms[5]);
        tree.insert(&elms[7]);
        try verifyRules(tree);

        tree.delete(&elms[7]);
        try verifyRules(tree);
        try testing.expectEqual(&elms[5].rb, tree.root);
    }

    // =============================================================
    {
        var tree = TestRbTree{};
        tree.insert(&elms[2]);
        tree.insert(&elms[1]);
        tree.insert(&elms[3]);
        try verifyRules(tree);

        tree.delete(&elms[3]);
        try verifyRules(tree);
        tree.delete(&elms[1]);
        try verifyRules(tree);
        tree.delete(&elms[2]);
        try verifyRules(tree);
        try testing.expectEqual(null, tree.root);
    }

    // =============================================================
    {
        var tree = TestRbTree{};
        const order = [_]usize{ 4, 2, 6, 1, 3, 5, 7 };
        for (order) |idx| {
            tree.insert(&elms[idx]);
        }
        try verifyRules(tree);

        tree.delete(&elms[4]);
        try verifyRules(tree);
        tree.delete(&elms[7]);
        try verifyRules(tree);
        tree.delete(&elms[2]);
        try verifyRules(tree);

        // Delete root until empty
        while (tree.root) |root| {
            const remaining = root.container();
            tree.delete(remaining);
            try verifyRules(tree);
        }
        try testing.expectEqual(null, tree.root);
    }

    // =============================================================
    {
        var tree = TestRbTree{};

        tree.insert(&elms[2]);
        tree.insert(&elms[1]);
        tree.insert(&elms[3]);
        try verifyRules(tree);

        tree.delete(&elms[2]);
        try verifyRules(tree);
        tree.delete(&elms[1]);
        try verifyRules(tree);
        tree.delete(&elms[3]);
        try verifyRules(tree);
        try testing.expectEqual(null, tree.root);

        tree.insert(&elms[1]);
        tree.insert(&elms[3]);
        tree.insert(&elms[2]);
        try verifyRules(tree);

        tree.delete(&elms[3]);
        try verifyRules(tree);
        tree.delete(&elms[1]);
        try verifyRules(tree);
        tree.delete(&elms[2]);
        try verifyRules(tree);
        try testing.expectEqual(null, tree.root);
    }

    // =============================================================
    {
        var tree = TestRbTree{};

        tree.insert(&elms[5]);
        try verifyRules(tree);
        tree.delete(&elms[5]);
        try verifyRules(tree);

        tree.insert(&elms[3]);
        try verifyRules(tree);
        tree.insert(&elms[7]);
        try verifyRules(tree);
        tree.delete(&elms[3]);
        try verifyRules(tree);
        tree.delete(&elms[7]);
        try verifyRules(tree);

        try testing.expectEqual(null, tree.root);
    }
}

/// Helper function to verify that the red-black tree properties are maintained.
fn verifyRules(tree: TestRbTree) !void {
    const S = struct {
        /// Given the root node, recursively verify that the black depths for all paths are equal.
        fn verifyBlackDepth(node: ?*TestRbTree.Node) !void {
            if (node == null) return;

            var nodes = std.ArrayList(*TestRbTree.Node).init(std.testing.allocator);
            defer nodes.deinit();
            collectAllLeaves(node, &nodes);

            var count: usize = 0;
            var first = true;
            for (nodes.items) |leaf| {
                var depth: usize = 0;
                var parent: *TestRbTree.Node = leaf;
                while (parent != node) : (parent = parent._parent.?) {
                    if (parent._color == .black) {
                        depth += 1;
                    }
                }
                if (first) {
                    count = depth;
                    first = false;
                } else {
                    try testing.expectEqual(count, depth);
                }
            }

            if (node.?._left) |left| try verifyBlackDepth(left);
            if (node.?._right) |right| try verifyBlackDepth(right);
        }

        fn collectAllLeaves(node: ?*TestRbTree.Node, nodes: *std.ArrayList(*TestRbTree.Node)) void {
            if (node == null) return;
            const n = node.?;

            if (n._left == null and n._right == null) {
                nodes.append(n) catch unreachable;
            } else {
                collectAllLeaves(n._left, nodes);
                collectAllLeaves(n._right, nodes);
            }
        }

        /// Helper function to test parent-child links in the tree
        fn testLinks(node: ?*TestRbTree.Node) !void {
            if (node) |n| {
                if (n._left) |left| {
                    try testing.expectEqual(n, left._parent);
                    try testing.expect(left.container().value <= n.container().value);
                    try testLinks(left);
                }
                if (n._right) |right| {
                    try testing.expectEqual(n, right._parent);
                    try testing.expect(n.container().value <= right.container().value);
                    try testLinks(right);
                }
            } else {
                return;
            }
        }

        /// Helper function to verify no red node has a red child
        fn testVerifyNoRedRedParentChild(node: ?*TestRbTree.Node) !void {
            if (node == null) return;

            const n = node.?;
            if (n._color == .red) {
                if (n._left) |left| {
                    try testing.expectEqual(.black, left._color);
                }
                if (n._right) |right| {
                    try testing.expectEqual(.black, right._color);
                }
            }

            try testVerifyNoRedRedParentChild(n._left);
            try testVerifyNoRedRedParentChild(n._right);
        }
    };

    if (tree.root) |root| {
        try testing.expectEqual(.black, root._color);
        try testing.expectEqual(null, root._parent);
    }
    try S.testLinks(tree.root);
    try S.testVerifyNoRedRedParentChild(tree.root);
    try S.verifyBlackDepth(tree.root);
}

fn debugPrintTree(node: ?*TestRbTree.Node) void {
    if (node == null) return;

    const n = node.?;
    std.debug.print("Node: {d}({s}) -> {?}({s}), {?}({s})\n", .{
        n.container().value,
        @tagName(n._color),
        if (n._left) |l| l.container().value else null,
        if (n._left) |l| @tagName(l._color) else "null",
        if (n._right) |r| r.container().value else null,
        if (n._right) |r| @tagName(r._color) else "null",
    });
    if (n._left) |left| debugPrintTree(left);
    if (n._right) |right| debugPrintTree(right);
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
    try testing.expectEqual(&alice.rb, tree.root.?._left);
    try testing.expectEqual(&charlie.rb, tree.root.?._right);

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
