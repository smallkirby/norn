const std = @import("std");
const log = std.log.scoped(.buddy);
const uefi = std.os.uefi;

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

const Error = error{
    /// Out of memory.
    OutOfMemory,
};

const vtable = PageAllocator.Vtable{
    .allocPages = allocPages,
    .freePages = freePages,
};

/// Represents a single free list that manages a set of pages of the same size.
const FreeList = struct {
    /// Size order.
    order: SizeOrder,
    /// Memory zone.
    zone: Zone,
    /// Pinter to the first free page.
    /// The list must be sorted in ascending order of physical addresses.
    head: ?*FreePage,
    /// Number of blocks used by the free list.
    num_in_use: usize,
    /// Total number of blocks for the free list.
    /// This contains both used and free blocks.
    num_total: usize,

    pub fn new(order: SizeOrder, zone: Zone) FreeList {
        return FreeList{
            .order = order,
            .zone = zone,
            .head = null,
            .num_in_use = 0,
            .num_total = 0,
        };
    }

    /// Add a memory region to this free list.
    pub fn addRegion(self: *FreeList, phys: Phys) void {
        rtt.expectEqual(0, phys & getOrderMask(self.order));

        // If the list is empty, just put the page into the head.
        if (self.head == null) {
            self.head = @ptrFromInt(mem.phys2virt(phys));
            self.head.?.next = null;
            return;
        }

        // Find the position to insert the page.
        var iter = Iterator.new(self);
        var prev: ?*FreePage = null;
        while (iter.next()) |cur| {
            const phys_cur = mem.virt2phys(cur);
            if (phys_cur < phys_cur) break;
            prev = cur;
        }

        // Insert the page.
        const new_page: *FreePage = @ptrFromInt(mem.phys2virt(phys));
        if (prev) |p| {
            new_page.next = p.next;
            p.next = new_page;
        } else {
            new_page.next = self.head;
            self.head = new_page;
        }

        self.num_total += 1;
    }

    pub fn allocBlock(self: *FreeList) Error!*FreePage {
        if (self.head != null) {
            const ret = self.head.?;
            self.head = ret.next;
            self.num_in_use += 1;
            return ret;
        } else return Error.OutOfMemory;
    }

    pub fn popBlock(self: *FreeList) Error!*FreePage {
        if (self.head != null) {
            const ret = self.head.?;
            self.head = ret.next;
            self.num_in_use -= 1;
            return ret;
        } else return Error.OutOfMemory;
    }

    pub fn pageAvailable(self: *FreeList) bool {
        return self.head != null;
    }

    const Iterator = struct {
        list: *FreeList,
        next_page: ?*FreePage,

        fn new(list: *FreeList) Iterator {
            return Iterator{
                .list = list,
                .next_page = list.head,
            };
        }

        fn next(self: *Iterator) ?*FreePage {
            if (self.next_page) |page| {
                self.next_page = page.next;
                return page;
            } else {
                return null;
            }
        }
    };
};

const ZoneList = struct {
    const FreeLists = [order_max]FreeList;
    const num_zones = std.meta.fields(Zone).len;

    /// Free lists for each zone.
    zones: [num_zones]FreeLists,

    pub fn new() ZoneList {
        var zones: [num_zones]FreeLists = undefined;
        for (0..num_zones) |zone_ix| {
            const zone: Zone = @enumFromInt(zone_ix);

            for (0..order_max) |order| {
                zones[zone_ix][order] = FreeList.new(order, zone);
            }
        }

        return ZoneList{
            .zones = zones,
        };
    }

    /// Add a memory region to the free list.
    /// TODO: MUST check alignment
    pub fn addRegion(self: *ZoneList, start: Phys, end: Phys, zone: Zone) void {
        rtt.expectEqual(0, start & mem.page_mask_4kib);
        rtt.expectEqual(0, end & mem.page_mask_4kib);

        const free_lists = &self.zones[@intFromEnum(zone)];

        var cur_start = start;
        while (true) {
            const size = end - cur_start;
            const result = sizeToOrder(size / mem.size_4kib);
            const free_list = &free_lists[result.order];

            free_list.addRegion(cur_start);
            cur_start += orderToPages(result.order) * mem.size_4kib;
            if (result.remaining == 0) break;
        }
    }

    pub fn allocPagesFrom(self: *ZoneList, num_pages: usize, zone: Zone) Error![]align(mem.size_4kib) u8 {
        const free_lists = &self.zones[@intFromEnum(zone)];
        const order = alignToOrder(num_pages);
        rtt.expect(order < order_max);

        const free_list = &free_lists[order];
        const block = free_list.allocBlock() catch retry: {
            self.splitRecursive(zone, order + 1);
            break :retry try free_list.allocBlock();
        };

        const ptr: [*]align(mem.size_4kib) u8 = @alignCast(@ptrCast(block));
        return ptr[0 .. num_pages * mem.size_4kib];
    }

    fn splitRecursive(self: *ZoneList, zone: Zone, order: SizeOrder) void {
        rtt.expect(order != 0);

        const free_lists = &self.zones[@intFromEnum(zone)];
        const free_list = &free_lists[order];

        // Ensure that the free list has at least one free page.
        if (!free_list.pageAvailable()) {
            self.splitRecursive(zone, order + 1);
        }

        // Detach a single block from the list.
        const page = free_list.popBlock() catch {
            @panic("BuddyAllocator: failed to split the free list.");
        };
        // Add the block to the lower order list.
        const block_size = orderToPages(order - 1) * mem.size_4kib;
        const num_blocks = orderToPages(order) * mem.size_4kib / block_size;
        for (0..num_blocks) |i| {
            free_lists[order - 1].addRegion(mem.phys2virt(mem.virt2phys(page) + i * block_size));
        }
    }
};

/// Exponent of power of 2 representing the number of contiguous physical pages.
const SizeOrder = u8;
/// Page frame number.
const Pfn = u64;
/// Free page.
/// This struct is placed at the beginning of the free pages.
const FreePage = packed struct {
    /// Next free page.
    next: ?*FreePage,
};

/// Number of free list orders.
const order_max: SizeOrder = 11;

/// Spin lock for this allocator.
lock: SpinLock,
/// System memory map.
map: MemoryMap,
/// Free lists for each zone.
zones: ZoneList,

pub fn new() Self {
    return Self{
        .lock = SpinLock{},
        .map = undefined,
        .zones = ZoneList.new(),
    };
}

pub fn init(self: *Self, bs: *BootstrapAllocator) void {
    rttExpectNewMap();

    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    // Convert the physical address to the virtual address.
    self.map = bs.memmap;
    self.map.descriptors = @ptrFromInt(mem.phys2virt(self.map.descriptors));

    const inuse_region = bs.getUsedRegion();

    // Scan memory map and initialize free lists.
    var desc_iter = MemoryDescriptorIterator.new(self.map);
    while (true) {
        const desc: *uefi.tables.MemoryDescriptor = desc_iter.next() orelse break;
        if (!isUsableMemory(desc)) continue;

        var phys_start = desc.physical_start;
        const phys_end = phys_start + desc.number_of_pages * mem.size_4kib;

        // Check the region can be used by BootstrapAllocator.
        // Note that BootstrapAllocator uses pages from single region,
        // and in-use pages are contiguous from the start of the region.
        const inuse_num_page = if (inuse_region.region == phys_start) inuse_region.num_pages else 0;
        const inuse_size = inuse_num_page * mem.size_4kib;
        phys_start += inuse_size;

        while (phys_start < phys_end) {
            const zone = Zone.from(phys_start);
            _, const zone_end = zone.range();

            const end = @min(zone_end orelse phys_end, phys_end);
            self.zones.addRegion(phys_start, end, zone);
            phys_start = end;
        }
    }
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
    return self.zones.allocPagesFrom(num_pages, zone);
}

fn freePages(ctx: *anyopaque, pages: []u8) void {
    const self: *Self = @alignCast(@ptrCast(ctx));
    _ = self; // autofix
    _ = pages; // autofix

    norn.unimplemented("freePages()");
}

/// Check if the memory region described by the descriptor is usable for norn kernel.
/// Note that these memory areas may contain crucial data for the kernel,
/// including page tables, stack, and GDT.
/// You MUST copy them before using the area.
inline fn isUsableMemory(descriptor: *uefi.tables.MemoryDescriptor) bool {
    return switch (descriptor.type) {
        .ConventionalMemory,
        .BootServicesCode,
        .BootServicesData,
        => true,
        else => false,
    };
}

/// Convert the number of pages to the order.
/// If the num is not a power of 2, the order is rounded down and the remaining size is returned.
fn sizeToOrder(num_pages: usize) struct { order: SizeOrder, remaining: usize } {
    var order = std.math.log2_int(usize, num_pages);
    if (order >= order_max) {
        order = order_max - 1;
    }
    const remaining = num_pages - (@as(usize, 1) << order);

    return .{ .order = @intCast(order), .remaining = remaining };
}

/// Align the number of pages to the order.
inline fn alignToOrder(num_pages: usize) SizeOrder {
    return std.math.log2_int_ceil(usize, num_pages);
}

/// Convert the order to the number of pages
inline fn orderToPages(order: SizeOrder) usize {
    return @as(usize, 1) << @intCast(order);
}

/// Get the bitmask for the order.
inline fn getOrderMask(order: SizeOrder) u64 {
    return (@as(usize, 1) << @intCast(order)) - 1;
}

// ====================================================

const rtt = norn.rtt;

inline fn rttExpectNewMap() void {
    if (norn.is_runtime_test and !mem.isPgtblInitialized()) {
        log.err("Page table must be initialized before calling the function.", .{});
        norn.endlessHalt();
    }
}
