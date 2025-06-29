//! Bootstrap memory allocator.
//!
//! This allocator provides a ultimately limited memory allocation service
//! only to allocate memory for page tables or other bootstrapping purposes.
//! The size of usable memory is limited.
//! The address returned by this allocator is physical address.
//!
//! The allocation and management mechanism is so naive.
//! This allocator must be used only before the buddy allocator is initialized.

const Self = @This();
const Error = PageAllocator.Error;

/// Memory map provided by UEFI.
map: MemoryMap = undefined,
/// Management structure for pages.
pages: *[num_max_pages]Page = undefined,

/// Physical page managed by the allocator.
const Page = packed struct {
    /// Physical address of the page.
    phys: Phys,
    /// Status of the page.
    in_use: bool,

    pub fn new(phys: Phys, in_use: bool) Page {
        return .{ .phys = phys, .in_use = in_use };
    }
};

/// The size of memory this allocator provides.
const max_size = 50 * mem.mib;
/// Maximum number of pages this allocator provides.
const num_max_pages = max_size / mem.size_4kib;
/// Total size in 4KiB pages of meta data.
const meta_total_pages = norn.util.roundup(@sizeOf(Page) * num_max_pages, mem.size_4kib) / mem.size_4kib;

/// Vtable for PageAllocator interface.
const vtable = PageAllocator.Vtable{
    .allocPages = allocPages,
    .freePages = freePages,
    .freePagesRaw = freePagesRaw,
};

/// Create a new instance of the allocator.
/// The instance is uninitialized and must be initialized before use.
pub fn new() Self {
    return Self{};
}

/// Initialize the allocator.
pub fn init(self: *Self, map: MemoryMap) void {
    rttExpectOldMap();

    self.map = map;

    // Iterate over the memory map to find a region that can be used by the allocator.
    // Note that all the memory (both for metadata and pool) must be allocated from the single region.
    // Additionally, memory must be allocated from the beginning of the region.
    var desc_iter = MemoryDescriptorIterator.new(map);
    while (true) {
        const desc: *MemoryDescriptor = desc_iter.next() orelse break;
        if (!isUsableMemory(desc)) continue;

        var phys_start = desc.physical_start;
        // If the region does not have enough size, skip it.
        if (desc.number_of_pages < meta_total_pages + num_max_pages) continue;

        // Initialize the management structure.
        self.pages = @ptrFromInt(phys_start);
        for (0..meta_total_pages) |i| {
            self.pages[i] = Page.new(phys_start + i * mem.size_4kib, true);
        }
        phys_start += meta_total_pages * mem.size_4kib;

        // Mark the pages as available.
        norn.rtt.expectEqual(0, phys_start % mem.size_4kib);
        for (0..num_max_pages - meta_total_pages) |i| {
            self.pages[i + meta_total_pages] = Page.new(phys_start, false);
            phys_start += mem.size_4kib;
        }

        return;
    }

    @panic("BootstrapAllocator could not find enough memory.");
}

/// Get the PageAllocator interface.
pub fn getAllocator(self: *Self) PageAllocator {
    return PageAllocator{
        .ptr = self,
        .vtable = &vtable,
    };
}

/// Get the region of used pages.
pub fn getUsedRegion(self: *Self) struct { region: Phys, num_pages: usize } {
    rttExpectNewMap();

    const pages: *[num_max_pages]Page = @ptrFromInt(mem.phys2virt(self.pages.ptr));
    const region = pages[0].phys;
    const num_pages = for (0..num_max_pages) |i| {
        if (!pages[i].in_use) break i;
    } else num_max_pages;

    // Check if the in-use pages are contiguous and does not have gap between.
    if (norn.is_runtime_test) {
        for (0..num_max_pages) |i| {
            norn.rtt.expectEqual(i < num_pages, pages[i].in_use);
        }
    }

    return .{ .region = region, .num_pages = num_pages };
}

/// Allocate physically contiguous and aligned pages.
/// Returned slice points to physical address.
/// Note that the argument `zone` is ignored. It's undefined from which zone the memory is allocated.
fn allocPages(ctx: *anyopaque, num_pages: usize, _: mem.Zone) Error![]align(mem.size_4kib) u8 {
    rttExpectOldMap();

    const self: *Self = @alignCast(@ptrCast(ctx));
    var start_ix: usize = 0;

    while (true) {
        var i: usize = 0;

        // Iterate until the number of contiguous pages reaches `num_pages`.
        while (i < num_pages) : (i += 1) {
            if (num_max_pages <= start_ix + i) return Error.OutOfMemory;
            if (self.pages[start_ix + i].in_use) break;
        }
        // We found a contiguous region of requested size.
        if (i == num_pages) {
            for (0..num_pages) |j| {
                self.pages[start_ix + j].in_use = true;
            }
            const phys_addr: [*]u8 = @ptrFromInt(self.pages[start_ix].phys);
            return @alignCast(phys_addr[0 .. num_pages * mem.size_4kib]);
        }

        // Increment the start index and retry.
        start_ix += @max(i, 1);
        if (start_ix + num_pages >= num_max_pages) return Error.OutOfMemory;
    }
}

/// BootstrapAllocator does not support free.
fn freePages(_: *anyopaque, _: []u8) void {
    @panic("BootstrapAllocator is not supposed to free memory.");
}

/// BootstrapAllocator does not support free.
fn freePagesRaw(_: *anyopaque, _: mem.Virt, _: usize) Error!void {
    @panic("BootstrapAllocator is not supposed to free memory.");
}

/// Check if the memory region described by the descriptor is usable for this allocator.
///
/// Page tables are not reconstructed, so .loader_data is not usable here.
inline fn isUsableMemory(descriptor: *uefi.tables.MemoryDescriptor) bool {
    return switch (descriptor.type) {
        .conventional_memory,
        .boot_services_code,
        .boot_services_data,
        .loader_code,
        => true,
        else => false,
    };
}

// ====================================================

const rtt = norn.rtt;

inline fn rttExpectOldMap() void {
    if (norn.is_runtime_test and mem.isPgtblInitialized()) {
        log.err("Page table must not be initialized before calling the function.", .{});
        norn.endlessHalt();
    }
}

inline fn rttExpectNewMap() void {
    if (norn.is_runtime_test and !mem.isPgtblInitialized()) {
        log.err("Page table must be initialized before calling the function.", .{});
        norn.endlessHalt();
    }
}

// ====================================================

const std = @import("std");
const log = std.log.scoped(.pa);
const uefi = std.os.uefi;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;

const surtr = @import("surtr");
const MemoryMap = surtr.MemoryMap;
const MemoryDescriptorIterator = surtr.MemoryDescriptorIterator;

const norn = @import("norn");
const mem = norn.mem;
const PageAllocator = mem.PageAllocator;
const Phys = norn.mem.Phys;
