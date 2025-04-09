//! Virtual memory allocator that uses incontiguous physical memory.
//!
//! This allocator uses 4KiB pages, so you can change the attributes of allocated pages.

const Self = @This();
const Error = mem.PageAllocator.Error;

/// Spin lock for this allocator.
_lock: SpinLock,
/// List of allocated VMAs.
_list: VmaList,
/// Virtual address where next allocation starts.
/// This algorithm is so naive that it doesn't even try to find a once allocated and freed region.
_next_start: u64,

const VmaList = InlineDoublyLinkedList(VirtualMemoryArea, "head");
const VmaListHead = VmaList.Head;

/// Page frame number.
const Pfn = u64;
/// List of PFNs.
const PfnList = ArrayList(Pfn);

/// Describes allocated pages.
///
/// The backing physical pages might not be contiguous.
const VirtualMemoryArea = struct {
    /// Virtual address of the start of this VM area.
    start: u64,
    /// Size of the VM area.
    size: usize,
    /// List of physical pages for this VM area.
    pages: PfnList,
    /// List head.
    head: VmaListHead,
};

/// Initialize the allocator.
pub fn new() Self {
    return .{
        ._lock = .{},
        ._list = .{},
        ._next_start = mem.vmem_base,
    };
}

/// Allocate a new virtual memory.
///
/// The backing physical pages might not be contiguous.
/// The default page attribute is RW.
pub fn allocate(self: *Self, size: usize) Error![]u8 {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    const aligned_size = util.roundup(size, mem.size_4kib);
    const num_pages = aligned_size / mem.size_4kib;

    const vma = try general_allocator.create(VirtualMemoryArea);
    errdefer general_allocator.destroy(vma);

    var pfn_list = PfnList.init(general_allocator);
    errdefer pfn_list.deinit();

    const tbl = arch.mem.getRootTable();
    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        // Allocate a page from the page allocator.
        const page = try mem.page_allocator.allocPages(1, .normal);
        errdefer mem.page_allocator.freePages(page);

        // Map the page.
        arch.mem.map(
            tbl,
            self._next_start + i * mem.size_4kib,
            mem.virt2phys(page),
            mem.size_4kib,
            .read_write,
        ) catch return Error.OutOfMemory;
        // TODO: unmap the pages on error.

        // Record the page frame number.
        const pfn = mem.page_allocator.getPfn(page);
        try pfn_list.append(pfn);
    }

    // Initialize the VMA insert it to the list.
    vma.* = .{
        .start = self._next_start,
        .size = aligned_size,
        .pages = pfn_list,
        .head = VmaList.Head{},
    };
    self._list.append(vma);
    self._next_start += aligned_size;

    const ret_ptr: [*]u8 = @ptrFromInt(vma.start);
    return ret_ptr[0..aligned_size];
}

/// Free and unmap the given virtual memory.
pub fn free(_: *Self, _: []u8) void {
    norn.unimplemented("VmAllocator: free()");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const ArrayList = std.ArrayList;

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const util = norn.util;

const InlineDoublyLinkedList = norn.InlineDoublyLinkedList;
const SpinLock = norn.SpinLock;

const general_allocator = mem.general_allocator;
