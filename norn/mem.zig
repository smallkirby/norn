const std = @import("std");
const atomic = std.atomic;
const Allocator = std.mem.Allocator;

const surtr = @import("surtr");
const MemoryMap = surtr.MemoryMap;

/// Physical address.
pub const Phys = u64;
/// Virtual address.
pub const Virt = u64;

pub const kib = 1024;
pub const mib = 1024 * kib;
pub const gib = 1024 * mib;

pub const page_size: u64 = page_size_4k;
pub const page_shift: u64 = page_shift_4k;
pub const page_mask: u64 = page_mask_4k;

/// Size in bytes of a 4K page.
pub const page_size_4k = 4 * kib;
/// Size in bytes of a 2M page.
pub const page_size_2mb = page_size_4k << 9;
/// Size in bytes of a 1G page.
pub const page_size_1gb = page_size_2mb << 9;
/// Shift in bits for a 4K page.
pub const page_shift_4k = 12;
/// Shift in bits for a 2M page.
pub const page_shift_2mb = 21;
/// Shift in bits for a 1G page.
pub const page_shift_1gb = 30;
/// Mask for a 4K page.
pub const page_mask_4k: u64 = page_size_4k - 1;
/// Mask for a 2M page.
pub const page_mask_2mb: u64 = page_size_2mb - 1;
/// Mask for a 1G page.
pub const page_mask_1gb: u64 = page_size_1gb - 1;

/// Base virtual address of direct mapping.
/// The virtual address starting from the address is directly mapped to the physical address at 0x0.
pub const direct_map_base = 0xFFFF_8880_0000_0000;
/// The base virtual address of the kernel.
/// The virtual address strating from the address is directly mapped to the physical address at 0x0.
pub const kernel_base = 0xFFFF_FFFF_8000_0000;

/// Page allocator.
pub const page_allocator = Allocator{
    .ptr = &page_allocator_instance,
    .vtable = &PageAllocator.vtable,
};

const PageAllocator = @import("mem/PageAllocator.zig");
/// Page allocator instance.
/// You should use this allocator via `page_allocator` interface.
var page_allocator_instance = PageAllocator.newUninit();

/// Whether the page table is initialized.
var pgtbl_initialized = atomic.Value(bool).init(false);

/// Initialize the page allocator.
/// You MUST call this function before using `page_allocator`.
pub fn initPageAllocator(map: MemoryMap) void {
    page_allocator_instance.init(map);
}

/// Get the raw instance of the page allocator.
/// This function is available only before page table is initialized.
pub fn getPageAllocatorInstance() *PageAllocator {
    if (isPgtblInitialized()) {
        @panic("getPageAllocatorInstance: page table is initialized");
    }
    return &page_allocator_instance;
}

/// Check if the page table is initialized.
pub fn isPgtblInitialized() bool {
    return pgtbl_initialized.load(.acquire);
}

/// Translate the given virtual address to physical address.
/// This function just use simple calculation and does not walk page tables.
/// To do page table walk, use arch-specific functions.
pub fn virt2phys(addr: anytype) Phys {
    const value = switch (@typeInfo(@TypeOf(addr))) {
        .Int, .ComptimeInt => @as(u64, addr),
        .Pointer => @as(u64, @intFromPtr(addr)),
        else => @compileError("virt2phys: invalid type"),
    };
    return if (value < kernel_base) b: {
        // Direct mapping region.
        break :b value - direct_map_base;
    } else b: {
        // Kernel image mapping region.
        break :b value - kernel_base;
    };
}

/// Translate the given physical address to virtual address.
/// This function just use simple calculation and does not walk page tables.
/// To do page table walk, use arch-specific functions.
pub fn phys2virt(addr: anytype) Virt {
    const value = switch (@typeInfo(@TypeOf(addr))) {
        .Int, .ComptimeInt => @as(u64, addr),
        .Pointer => @as(u64, @intFromPtr(addr)),
        else => @compileError("phys2virt: invalid type"),
    };
    return value + direct_map_base;
}
