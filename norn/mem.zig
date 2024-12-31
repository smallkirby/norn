const std = @import("std");
const atomic = std.atomic;
const Allocator = std.mem.Allocator;

const surtr = @import("surtr");
const MemoryMap = surtr.MemoryMap;

const norn = @import("norn");
const arch = norn.arch;

/// Physical address.
pub const Phys = u64;
/// Virtual address.
pub const Virt = u64;

pub const kib = 1024;
pub const mib = 1024 * kib;
pub const gib = 1024 * mib;

pub const page_size: u64 = size_4kib;
pub const page_shift: u64 = page_shift_4kib;
pub const page_mask: u64 = page_mask_4kib;

/// Size in bytes of a 4KiB.
pub const size_4kib = 4 * kib;
/// Size in bytes of a 2MiB.
pub const size_2mib = size_4kib << 9;
/// Size in bytes of a 1GiB.
pub const size_1gib = size_2mib << 9;
/// Shift in bits for a 4K page.
pub const page_shift_4kib = 12;
/// Shift in bits for a 2M page.
pub const page_shift_2mib = 21;
/// Shift in bits for a 1G page.
pub const page_shift_1gib = 30;
/// Mask for a 4K page.
pub const page_mask_4kib: u64 = size_4kib - 1;
/// Mask for a 2M page.
pub const page_mask_2mib: u64 = size_2mib - 1;
/// Mask for a 1G page.
pub const page_mask_1gib: u64 = size_1gib - 1;

/// Base virtual address of direct mapping.
/// The virtual address starting from the address is directly mapped to the physical address at 0x0.
pub const direct_map_base = 0xFFFF_8880_0000_0000;
/// Size in bytes of the direct mapping region.
pub const direct_map_size = 512 * gib;
/// The base virtual address of the kernel.
/// The virtual address strating from the address is directly mapped to the physical address at 0x0.
pub const kernel_base = 0xFFFF_FFFF_8000_0000;

/// Page allocator.
pub const page_allocator = Allocator{
    .ptr = &page_allocator_instance,
    .vtable = &PageAllocator.vtable,
};
/// General memory allocator.
pub const general_allocator = Allocator{
    .ptr = &bin_allocator_instance,
    .vtable = &BinAllocator.vtable,
};

/// Raw page allocator.
/// You should use `Allocator` instead of this.
pub const PageAllocator = @import("mem/PageAllocator.zig");
var page_allocator_instance = PageAllocator.newUninit();

const BinAllocator = @import("mem/BinAllocator.zig");
var bin_allocator_instance = BinAllocator.newUninit();

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
    return &page_allocator_instance;
}

/// Initialize the general allocator.
/// You MUST call this function before using `general_allocator`.
pub fn initGeneralAllocator() void {
    bin_allocator_instance.init(page_allocator);
}

/// Check if the page table is initialized.
pub fn isPgtblInitialized() bool {
    return pgtbl_initialized.load(.acquire);
}

/// Discard the initial direct mapping and construct Norn's page tables.
/// It creates two mappings: direct mapping and kernel mapping.
/// After this function, direct mapping provided by UEFI is no longer available.
pub fn reconstructMapping() !void {
    arch.disableIrq();
    defer arch.enableIrq();

    // Remap pages.
    try arch.page.boot.reconstruct(getPageAllocatorInstance());
    pgtbl_initialized.store(true, .release);

    // Notify that BootServicesData region is no longer needed.
    page_allocator_instance.discardBootService();
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
