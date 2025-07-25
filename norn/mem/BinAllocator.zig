const Self = @This();
const BinAllocator = Self;

/// Backing page allocator.
page_allocator: PageAllocator,
/// Heads of the chunk lists.
list_heads: [bin_sizes.len]ChunkMetaPointer,
/// Spin lock.
lock: SpinLock,

const vtable = Allocator.VTable{
    .alloc = allocate,
    .free = free,
    .resize = resize,
    .remap = remap,
};

const bin_sizes = [_]usize{
    0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800,
};

comptime {
    if (bin_sizes[0] < @sizeOf(ChunkMetaNode)) {
        @compileError("The smallest bin size is smaller than the size of ChunkMetaNode");
    }
    if (bin_sizes[bin_sizes.len - 1] > mem.size_4kib) {
        @compileError("The largest bin size exceeds a 4KiB page size");
    }
}

/// Metadata of free chunk.
/// NOTE: In zig, we don't need to store the size of the in-use chunk.
const ChunkMetaNode = packed struct {
    next: ChunkMetaPointer = null,
};
const ChunkMetaPointer = ?*ChunkMetaNode;

/// Get a instance of BinAllocator without initialization.
pub fn newUninit() Self {
    return Self{
        .page_allocator = undefined,
        .list_heads = undefined,
        .lock = SpinLock{},
    };
}

/// Initialize the BinAllocator.
pub fn init(self: *Self, page_allocator: PageAllocator) void {
    self.page_allocator = page_allocator;
    @memset(self.list_heads[0..self.list_heads.len], null);
    self.lock = SpinLock{};
}

/// Get the Allocator interface.
pub fn getAllocator(self: *Self) Allocator {
    return Allocator{
        .ptr = self,
        .vtable = &vtable,
    };
}

/// Get the bin index for the given size.
/// If the size exceeds the largest bin size, return null.
fn binIndex(size: usize) ?usize {
    for (bin_sizes, 0..) |bin_size, i| {
        if (size <= bin_size) {
            return i;
        }
    }
    return null;
}

fn allocFromBin(self: *Self, bin_index: usize) ?[*]u8 {
    const mask = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(mask);

    if (self.list_heads[bin_index] == null) {
        initBinPage(self, bin_index) orelse return null;
    }
    return @ptrCast(pop(&self.list_heads[bin_index]));
}

fn freeToBin(self: *Self, bin_index: usize, ptr: [*]u8) void {
    const mask = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(mask);

    const chunk: *ChunkMetaNode = @alignCast(@ptrCast(ptr));
    push(&self.list_heads[bin_index], chunk);
}

fn initBinPage(self: *Self, bin_index: usize) ?void {
    const new_page = self.page_allocator.allocPages(1, .normal) catch return null;
    const bin_size = bin_sizes[bin_index];

    var i: usize = mem.size_4kib / bin_size - 1;
    while (true) : (i -= 1) {
        const chunk: *ChunkMetaNode = @ptrFromInt(@intFromPtr(new_page.ptr) + i * bin_size);
        push(&self.list_heads[bin_index], chunk);

        if (i == 0) break;
    }
}

fn push(list_head: *ChunkMetaPointer, node: *ChunkMetaNode) void {
    if (list_head.*) |next| {
        node.next = next;
        list_head.* = node;
    } else {
        list_head.* = node;
        node.next = null;
    }
}

fn pop(list_head: *ChunkMetaPointer) *ChunkMetaNode {
    if (list_head.*) |first| {
        list_head.* = first.next;
        return first;
    } else {
        @panic("BinAllocator: pop from empty list");
    }
}

fn allocate(ctx: *anyopaque, n: usize, log2_align: std.mem.Alignment, _: usize) ?[*]u8 {
    const self: *Self = @alignCast(@ptrCast(ctx));

    const ptr_align = log2_align.toByteUnits();
    const bin_index = binIndex(@max(ptr_align, n));

    if (bin_index) |index| {
        return self.allocFromBin(index);
    } else {
        // Requested size including alignment exceeds a 4KiB page size.
        // Zig's Allocator does not assume an align larger than a page size.
        // So we can safely ignore the alignment, ang just return for requested size.
        const num_pages = std.math.divCeil(usize, n, mem.size_4kib) catch {
            @panic("BinAllocator: Unexpected division.");
        };
        const ret = self.page_allocator.allocPages(num_pages, .normal) catch return null;
        return @ptrCast(ret.ptr);
    }
}

fn free(ctx: *anyopaque, slice: []u8, log2_align: Alignment, _: usize) void {
    const self: *Self = @alignCast(@ptrCast(ctx));

    const ptr_align = log2_align.toByteUnits();
    const bin_index = binIndex(@max(ptr_align, slice.len));

    if (bin_index) |index| {
        self.freeToBin(index, @ptrCast(slice.ptr));
    } else {
        self.page_allocator.freePages(slice);
    }
}

fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
    @panic("BinAllocator does not support resizing");
}

fn remap(ctx: *anyopaque, slice: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
    const self: *Self = @alignCast(@ptrCast(ctx));

    if (slice.len == new_len) return slice.ptr;

    const new_region = allocate(self, new_len, alignment, 0) orelse return null;
    @memcpy(new_region[0..slice.len], slice);
    free(self, slice, alignment, 0);

    return new_region;
}

// ========================================

const testing = std.testing;

const TestPageAllocator = struct {
    pub const vtable = PageAllocator.Vtable{
        .allocPages = allocPages,
        .freePages = freePages,
        .freePagesRaw = freePagesRaw,
    };

    const Error = PageAllocator.Error;

    pub fn new() TestPageAllocator {
        return .{};
    }

    pub fn allocator(self: *TestPageAllocator) PageAllocator {
        return PageAllocator{
            .ptr = self,
            .vtable = &TestPageAllocator.vtable,
        };
    }

    pub fn allocPages(_: *anyopaque, num_pages: usize, _: mem.Zone) Error![]align(mem.size_4kib) u8 {
        const ret = std.heap.page_allocator.alignedAlloc(
            u8,
            mem.size_4kib,
            mem.size_4kib * num_pages,
        );
        return ret;
    }

    pub fn freePages(_: *anyopaque, slice: []u8) void {
        std.heap.page_allocator.free(slice);
    }

    pub fn freePagesRaw(_: *anyopaque, _: mem.Virt, _: usize) Error!void {
        return;
    }
};

var test_page_allocator = TestPageAllocator.new();

test {
    testing.refAllDeclsRecursive(@This());
}

fn getTestingAllocator() Allocator {
    var bin_allocator_instance // we don't want an error check
    = std.heap.page_allocator.create(Self) catch unreachable;
    bin_allocator_instance.init(test_page_allocator.allocator());

    return Allocator{
        .ptr = bin_allocator_instance,
        .vtable = &vtable,
    };
}

test "allocation order" {
    const ba = getTestingAllocator();

    // Chunks are allocated in ascending order.
    // The distance between the chunks is same as the chunk size.
    const sizes = bin_sizes;
    for (sizes) |size| {
        var prev = try ba.alloc(u8, size);
        for (0..mem.size_4kib / size - 1) |_| {
            const ptr = try ba.alloc(u8, size);
            try testing.expectEqual(size, @intFromPtr(ptr.ptr) - @intFromPtr(prev.ptr));
            prev = ptr;
        }
    }

    // Most recently freed chunk is allocated first.
    for (0..3) |_| _ = try ba.alloc(u8, 0x10);
    const ptr = try ba.alloc(u8, 0x10);
    for (0..3) |_| _ = try ba.alloc(u8, 0x10);
    ba.free(ptr);
    try testing.expectEqual(ptr, try ba.alloc(u8, 0x10));
}

test "allocation size" {
    const ba = getTestingAllocator();

    for (0..5000) |size| {
        const ptr = try ba.alloc(u8, size);
        try testing.expectEqual(size, ptr.len);
        ba.free(ptr);
    }
}

test "allocation exceeds page size" {
    const ba = getTestingAllocator();

    for (0..mem.size_4kib / 0x20 + 8) |_| {
        const ptr = try ba.alloc(u8, 0x20);
        try testing.expectEqual(0x20, ptr.len);
    }
}

test "no mitigation against double free" {
    const ba = getTestingAllocator();

    const ptr = try ba.alloc(u8, 0x20);
    ba.free(ptr);
    ba.free(ptr);
}

// ========================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const norn = @import("norn");
const mem = norn.mem;
const PageAllocator = mem.PageAllocator;
const SpinLock = norn.SpinLock;
