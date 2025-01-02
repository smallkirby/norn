const std = @import("std");
const log = std.log.scoped(.buddy);
const uefi = std.os.uefi;
const DoublyLinkedList = std.DoublyLinkedList;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;

const surtr = @import("surtr");
const MemoryDescriptorIterator = surtr.MemoryDescriptorIterator;
const MemoryMap = surtr.MemoryMap;

const norn = @import("norn");
const mem = norn.mem;
const PageAllocator = mem.PageAllocator;
const Phys = mem.Phys;
const Virt = mem.Virt;
const Zone = mem.Zone;
const SpinLock = norn.SpinLock;

const BootstrapAllocator = @import("BootstrapAllocator.zig");

const Self = @This();
const Error = PageAllocator.Error;

/// Spin lock for this allocator.
lock: SpinLock,
/// System memory map.
map: MemoryMap,
/// Free lists for each zone.
zones: ZoneList,

/// Vtable for PageAllocator interface.
const vtable = PageAllocator.Vtable{
    .allocPages = allocPages,
    .freePages = freePages,
};

/// Exponent of power of 2 representing the number of contiguous physical pages.
const SizeOrder = u8;

/// Manages free lists of each order for single memory zone.
/// The list must be sorted in ascending order of physical addresses.
/// Each page is ensured to be aligned to the order.
const FreeList = struct {
    /// Doubly linked list of free pages.
    link: FreePageLink,
    /// Total number of blocks for the free list.
    /// This contains both used and free blocks.
    num_total: usize,

    /// Doubly linked list of free pages.
    const FreePageLink = DoublyLinkedList(void);
    /// Free page.
    /// This struct is placed at the beginning of the free pages.
    const FreePage = FreePageLink.Node;

    /// Create a new empty free list.
    pub fn new() FreeList {
        return FreeList{
            .link = FreePageLink{},
            .num_total = 0,
        };
    }

    /// Add a memory region to this free list.
    pub fn addRegion(self: *FreeList, phys: Phys) void {
        const new_page: *FreePage = @ptrFromInt(mem.phys2virt(phys));
        self.insertSorted(new_page);
        self.num_total += 1;
    }

    /// Allocate a block of pages from the free list.
    pub fn allocBlock(self: *FreeList) Error!*FreePage {
        return self.link.popFirst() orelse Error.OutOfMemory;
    }

    /// Detach a block of pages from the free list.
    /// Detached pages are no longer managed by the free list.
    pub fn detachBlock(self: *FreeList) Error!*FreePage {
        if (self.link.popFirst()) |node| {
            self.num_total -= 1;
            return node;
        } else return Error.OutOfMemory;
    }

    /// Add a block of pages to the free list.
    pub fn freeBlock(self: *FreeList, block: []u8) void {
        const page: *FreePage = @alignCast(@ptrCast(block));
        self.insertSorted(page);
    }

    /// Insert the block to the freelist keeping list sorted.
    /// Note that this function does not increment the counter.
    /// TODO: Use binary search.
    fn insertSorted(self: *FreeList, new_page: *FreePage) void {
        // Starting from the last block, find the first block whose address is smaller than the new block.
        var cur: ?*FreePage = self.link.last;
        while (cur) |page| : (cur = page.prev) {
            if (@intFromPtr(page) < @intFromPtr(new_page)) break;
        }
        if (cur) |c| {
            self.link.insertAfter(c, new_page);
        } else {
            self.link.append(new_page);
        }
    }

    /// Check if the list does not have any free pages.
    pub fn isEmpty(self: *FreeList) bool {
        return self.numFree() == 0;
    }

    /// Get the number of blocks in the freelist.
    /// Blocks in use are included.
    pub inline fn numTotal(self: FreeList) usize {
        return self.num_total;
    }

    /// Get the number of blocks in the freelist.
    pub inline fn numFree(self: FreeList) usize {
        return self.link.len;
    }

    /// Get the number of blocks in use.
    pub inline fn numInUse(self: FreeList) usize {
        return self.num_total - self.numFree();
    }
};

/// Manages free lists of each order for single memory zone.
const Arena = struct {
    /// Available number of page orders.
    const avail_orders: usize = 11;

    /// Free list for each order.
    lists: [avail_orders]FreeList,

    /// Create a new arena.
    pub fn new() Arena {
        return Arena{
            .lists = [_]FreeList{FreeList.new()} ** avail_orders,
        };
    }

    /// Add a memory region to the free list.
    pub fn addRegion(self: *Arena, start: Phys, end: Phys) void {
        rtt.expect(start < end);

        var cur_start = start;
        while (true) {
            const size = end - cur_start;
            const orig_order, var remaining = orderFloor(size / mem.size_4kib);

            // Find the order that matches the alignment.
            var order = orig_order;
            while (order != 0) {
                const mask = getOrderMask(order);
                if (cur_start & mask == 0) break;
                order -= 1;
            }
            remaining += orderToInt(order) - orderToInt(orig_order);

            // Add the region to the free list.
            self.getList(order).addRegion(cur_start);

            cur_start += orderToInt(order) * mem.size_4kib;
            if (remaining == 0) break;
        }
    }

    /// Allocate the given number of pages.
    pub fn allocPages(self: *Arena, num_pages: usize) Error![]align(mem.size_4kib) u8 {
        const order = roundUpToOrder(num_pages);
        const free_list = self.getList(order);

        const block = free_list.allocBlock() catch retry: {
            // Split the free list and retry.
            self.splitRecursive(order + 1);
            break :retry try free_list.allocBlock();
        };

        const ptr: [*]align(mem.size_4kib) u8 = @alignCast(@ptrCast(block));
        return ptr[0 .. num_pages * mem.size_4kib];
    }

    /// Free the given pages to the appropriate list.
    pub fn freePages(self: *Arena, pages: []u8) void {
        const order = roundUpToOrder(pages.len / mem.size_4kib);
        rtt.expectEqual(0, @intFromPtr(pages.ptr) & getOrderMask(order));
        self.getList(order).freeBlock(pages);
    }

    /// Split pages in the `order`-th freelist the `order - 1`-th freelist.
    /// If the `order`-th freelist is empty, this function is called recursively for larger list.
    fn splitRecursive(self: *Arena, order: SizeOrder) void {
        rtt.expect(order != 0);

        const lower_order = order - 1;
        const free_list = self.getList(order);

        // Ensure that the freelist is not empty.
        if (free_list.isEmpty()) {
            self.splitRecursive(order + 1);
            rtt.expectEqual(false, free_list.isEmpty());
        }

        const block = free_list.detachBlock() catch {
            @panic("BuddyAllocator: failed to split the free list.");
        };

        const block_size = orderToInt(lower_order) * mem.size_4kib;
        const num_blocks = (orderToInt(order) * mem.size_4kib) / block_size;
        rtt.expectEqual(2, num_blocks);
        for (0..2) |i| {
            self.getList(lower_order).addRegion(mem.virt2phys(block) + i * block_size);
        }
    }

    /// Get the free list for the given order.
    inline fn getList(self: *Arena, order: SizeOrder) *FreeList {
        return &self.lists[order];
    }

    /// Get the address mask for the order.
    inline fn getOrderMask(order: SizeOrder) u64 {
        return (@as(usize, 1) << @intCast(order)) - 1;
    }

    /// Convert the number of pages to the order.
    /// If the num is not a power of 2, the order is rounded down and the remaining size is returned.
    /// If the order exceeds the available orders, the order is clamped to the max.
    /// Returnes the pair of the order and the remaining number of pages.
    fn orderFloor(num_pages: usize) struct { SizeOrder, usize } {
        var order = std.math.log2_int(usize, num_pages);
        if (order >= avail_orders) {
            order = avail_orders - 1;
        }
        const remaining = num_pages - (@as(usize, 1) << order);

        return .{ @intCast(order), remaining };
    }

    /// Convert the order to integer.
    inline fn orderToInt(order: SizeOrder) usize {
        return @as(usize, 1) << @intCast(order);
    }

    /// Align the number of pages to the order.
    inline fn roundUpToOrder(num_pages: usize) SizeOrder {
        return std.math.log2_int_ceil(usize, num_pages);
    }
};

/// Manages arenas for each memory zone.
const ZoneList = struct {
    const num_zones = std.meta.fields(Zone).len;

    /// Free lists for each zone.
    arenas: [num_zones]Arena,

    /// Create new arenas for each zone.
    pub fn new() ZoneList {
        return ZoneList{
            .arenas = [_]Arena{Arena.new()} ** num_zones,
        };
    }

    /// Add a memory region to the free list.
    /// Caller MUST ensure that the region is in the given zone.
    pub fn addRegion(self: *ZoneList, start: Phys, end: Phys, zone: Zone) void {
        rtt.expectEqual(0, start & mem.page_mask_4kib);
        rtt.expectEqual(0, end & mem.page_mask_4kib);

        self.getArena(zone).addRegion(start, end);
    }

    /// Allocate the given number of pages from the given memory zone.
    pub fn allocPagesFrom(self: *ZoneList, num_pages: usize, zone: Zone) Error![]align(mem.size_4kib) u8 {
        return self.getArena(zone).allocPages(num_pages);
    }

    /// Free the given pages to the appropriate zone list.
    pub fn freePagesTo(self: *ZoneList, pages: []u8) void {
        const phys_start = mem.virt2phys(pages.ptr);
        const zone = Zone.from(phys_start);
        self.getArena(zone).freePages(pages);

        // Check if the pages are over the zone boundary.
        const phys_end = phys_start + pages.len;
        _, const zone_end = zone.range();
        rtt.expect(phys_end < (zone_end orelse std.math.maxInt(Phys)));
    }

    /// Get the arena for the given zone.
    fn getArena(self: *ZoneList, zone: Zone) *Arena {
        return &self.arenas[@intFromEnum(zone)];
    }
};

/// Create a new uninitialized buddy allocator.
pub fn new() Self {
    return Self{
        .lock = SpinLock{},
        .map = undefined,
        .zones = ZoneList.new(),
    };
}

/// Initialize buddy allocator.
/// This function must be called after the memory map is initialized.
pub fn init(self: *Self, bs: *BootstrapAllocator) void {
    rttExpectNewMap();

    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    // Convert the physical address to the virtual address.
    self.map = bs.map;
    self.map.descriptors = @ptrFromInt(mem.phys2virt(self.map.descriptors));

    const inuse_region = bs.getUsedRegion();

    // Scan memory map and initialize free lists.
    var desc_iter = MemoryDescriptorIterator.new(self.map);
    while (true) {
        const desc: *MemoryDescriptor = desc_iter.next() orelse break;
        if (!isUsableMemory(desc)) continue;

        var phys_start = desc.physical_start;
        const phys_end = phys_start + desc.number_of_pages * mem.size_4kib;

        // Check the region can be used by BootstrapAllocator.
        // Note that BootstrapAllocator uses pages from single region,
        // and in-use pages are contiguous from the start of the region.
        const inuse_num_page = if (inuse_region.region == phys_start) inuse_region.num_pages else 0;
        const inuse_size = inuse_num_page * mem.size_4kib;
        phys_start += inuse_size;

        // The region can placed over multiple zones.
        // Add the part of (or entire) region to the free lists.
        while (phys_start < phys_end) {
            const zone = Zone.from(phys_start);
            _, const zone_end = zone.range();

            const end = @min(zone_end orelse phys_end, phys_end);
            self.zones.addRegion(phys_start, end, zone);
            phys_start = end;
        }
    }

    // Debug print the managed regions.
    log.debug("Statistics of Buddy Allocator's initial state:", .{});
    for ([_]Zone{ .dma, .normal }) |zone| {
        const arena = self.zones.getArena(zone);
        const name = @tagName(zone);
        log.debug(
            "{s: <7}                   Used / Total",
            .{name},
        );

        var total_pages: usize = 0;
        var total_inuse_pages: usize = 0;
        for (arena.lists, 0..) |list, order| {
            const page_unit = Arena.orderToInt(@intCast(order));
            const pages = page_unit * list.numTotal();
            const inuse_pages = page_unit * list.numInUse();
            total_pages += pages;
            total_inuse_pages += inuse_pages;
            log.debug(
                "   {d: >2}: {d: >7} ({d: >7} pages) / {d: >7} ({d: >7} pages)",
                .{ order, list.numInUse(), inuse_pages, list.numTotal(), pages },
            );
        }

        log.debug(
            "    >             {d:>8} MiB / {d: >8} MiB",
            .{ total_inuse_pages * mem.size_4kib / mem.mib, total_pages * mem.size_4kib / mem.mib },
        );
    }

    // Runtime test.
    if (norn.is_runtime_test) {
        self.lock.unlockRestoreIrq(ie);
    }
    rttTestBuddyAllocator(self);
}

/// Get the PageAllocator interface.
pub fn getAllocator(self: *Self) PageAllocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn allocPages(ctx: *anyopaque, num_pages: usize, zone: Zone) Error![]align(mem.size_4kib) u8 {
    rttExpectNewMap();

    const self: *Self = @alignCast(@ptrCast(ctx));
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    return self.zones.allocPagesFrom(num_pages, zone);
}

fn freePages(ctx: *anyopaque, pages: []u8) void {
    const self: *Self = @alignCast(@ptrCast(ctx));
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    self.zones.freePagesTo(pages);
}

/// Check if the memory region described by the descriptor is usable for norn kernel.
/// Note that these memory areas may contain crucial data for the kernel,
/// including page tables, stack, and GDT.
/// You MUST copy them before using the area.
inline fn isUsableMemory(descriptor: *MemoryDescriptor) bool {
    return switch (descriptor.type) {
        .ConventionalMemory,
        .BootServicesCode,
        .BootServicesData,
        => true,
        else => false,
    };
}

// ====================================================

const rtt = norn.rtt;

inline fn rttExpectNewMap() void {
    if (norn.is_runtime_test and !mem.isPgtblInitialized()) {
        log.err("Page table must be initialized before calling the function.", .{});
        norn.endlessHalt();
    }
}

const TestingAllocatedPage = packed struct {
    next: TestingPagePointer,
};
const TestingPagePointer = ?*TestingAllocatedPage;

/// Runtime test for BuddyAllocator.
fn rttTestBuddyAllocator(buddy_allocator: *Self) void {
    if (!norn.is_runtime_test) return;

    const allocator = buddy_allocator.getAllocator();
    const arena = buddy_allocator.zones.getArena(.normal);

    var allocated_pages_order0: TestingPagePointer = null;
    const num_pages_order0 = arena.lists[0].numFree() * Arena.orderToInt(0);

    // Allocate 3 pages and check the alignment.
    {
        const page = allocator.allocPages(3, .normal) catch {
            @panic("Unexpected failure in rttTestBuddyAllocator()");
        };
        // Must be aligned to 16 KiB.
        rtt.expectEqual(0, @intFromPtr(page.ptr) & 0x3_FFF);
        allocator.freePages(page);
    }

    // Consume all pages from 0-th freelist.
    {
        var prev: [*]allowzero u8 = @ptrFromInt(0);
        for (0..num_pages_order0) |_| {
            const page = rttAllocatePage(&allocated_pages_order0, allocator);
            // Blocks in the freelist must be sorted.
            rtt.expect(@intFromPtr(prev) < @intFromPtr(page.ptr));
            prev = page.ptr;
        }
        rtt.expectEqual(0, arena.lists[0].link.len);
        rtt.expectEqual(null, arena.lists[0].link.first);
        rtt.expectEqual(null, arena.lists[0].link.last);
    }

    // Split pages in the 1-st freelist to the 0-th.
    {
        const page1 = rttAllocatePage(&allocated_pages_order0, allocator);
        const page2 = rttAllocatePage(&allocated_pages_order0, allocator);
        // Two pages must be contiguous because they are split from the same block.
        rtt.expectEqual(@intFromPtr(page1.ptr) + mem.size_4kib, @intFromPtr(page2.ptr));
    }
}

fn rttAllocatePage(list: *TestingPagePointer, allocator: PageAllocator) []align(mem.size_4kib) u8 {
    const page = allocator.allocPages(1, .normal) catch {
        @panic("Unexpected failure in rttAllocatePage()");
    };
    const new_page: *TestingAllocatedPage = @ptrCast(page.ptr);
    new_page.next = list.*;
    list.* = new_page;
    return page;
}
