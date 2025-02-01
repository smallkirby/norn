const std = @import("std");
const meta = std.meta;

const norn = @import("norn");
const mem = norn.mem;
const Phys = mem.Phys;
const Zone = mem.Zone;

/// The type erased pointer to the allocator implementation.
ptr: *anyopaque,
/// The vtable for the allocator.
vtable: *const Vtable,

pub const Error = mem.Error;

const Self = @This();

/// Common interface for PageAllocator.
pub const Vtable = struct {
    allocPages: *const fn (ctx: *anyopaque, num_pages: usize, zone: Zone) Error![]align(mem.size_4kib) u8,
    freePages: *const fn (ctx: *anyopaque, slice: []u8) void,
    freePagesRaw: *const fn (ctx: *anyopaque, addr: norn.mem.Virt, num_pages: usize) Error!void,
};

/// Allocate the given number of pages from the given memory zone.
pub fn allocPages(self: Self, num_pages: usize, zone: Zone) Error![]align(mem.size_4kib) u8 {
    return self.vtable.allocPages(self.ptr, num_pages, zone);
}

/// Free the given pages.
///
/// Allocator implementation infers the actual page sizes from the given slice.
/// Callers must ensure that the slice is a valid page-aligned memory region.
pub fn freePages(self: Self, slice: []u8) void {
    return self.vtable.freePages(self.ptr, slice);
}

/// Free the given number of pages at the given address.
///
/// Unlike freePages(), this function can feed the pages that were not provided by the allocator.
pub fn freePagesRaw(self: Self, addr: norn.mem.Virt, num_pages: usize) Error!void {
    if (addr % norn.mem.size_4kib != 0) return Error.InvalidRegion;
    return self.vtable.freePagesRaw(self.ptr, addr, num_pages);
}
