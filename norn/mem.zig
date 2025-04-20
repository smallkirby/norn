// =============================================================
// Types Definitions
// =============================================================

/// Allocator interface to manage pages.
pub const PageAllocator = @import("mem/PageAllocator.zig");

/// Errors.
pub const Error = error{
    /// Out of memory.
    OutOfMemory,
    /// The specified region is invalid.
    InvalidRegion,
};

/// Memory zone.
pub const Zone = enum(u8) {
    /// DMA region
    dma,
    /// Normal region
    normal,

    /// Get the physical range of the memory zone.
    pub fn range(self: Zone) struct { Phys, ?Phys } {
        switch (self) {
            .dma => return .{ 0x0, 16 * mib },
            .normal => return .{ 16 * mib, null },
        }
    }

    /// Get the zone mapped to the physical address.
    pub fn from(phys: Phys) Zone {
        inline for (meta.fields(Zone)) |T| {
            const zone: Zone = comptime @enumFromInt(T.value);
            const start, const end = zone.range();
            if (start <= phys and (end == null or phys < end.?)) {
                return zone;
            }
        }
        @panic("Zone is not exhaustive.");
    }
};

/// Physical address.
pub const Phys = u64;
/// Virtual address.
pub const Virt = u64;

// =============================================================
// Constants
// =============================================================

/// KiB in bytes.
pub const kib = 1024;
/// MiB in bytes.
pub const mib = 1024 * kib;
/// GiB in bytes.
pub const gib = 1024 * mib;

/// Size of a single page in bytes in Norn kernel.
pub const page_size: u64 = size_4kib;
/// Number of bits to shift to extract the PFN from physical address.
pub const page_shift: u64 = page_shift_4kib;
/// Bit mask to extract the page-aligned address.
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
/// Base virtual address of vmemory area.
/// Incontiguous physical pages are mapped to this region.
pub const vmem_base = 0xFFFF_9000_0000_0000;
/// Size in bytes of the vmemory area.
pub const vmem_size = 512 * gib;
/// The base virtual address of the kernel.
/// The virtual address starting from the address is directly mapped to the physical address at 0x0.
pub const kernel_base = 0xFFFF_FFFF_8000_0000;

comptime {
    norn.comptimeAssert(
        direct_map_base + direct_map_size <= vmem_base,
        "Invalid memory layout",
    );
    norn.comptimeAssert(
        vmem_base + vmem_size <= kernel_base,
        "Invalid memory layout",
    );
}

// =============================================================
// Variables
// =============================================================

/// General memory allocator.
pub const general_allocator = bin_allocator_instance.getAllocator();
/// General page allocator that can be used to allocate physically contiguous pages.
pub const page_allocator = buddy_allocator_instance.getAllocator();
/// Incontiguous virtual memory allocator.
pub var vm_allocator = VmAllocator.new();

/// One and only instance of the bootstrap allocator.
var bootstrap_allocator_instance = BootstrapAllocator.new();
/// One and only instance of the buddy allocator.
var buddy_allocator_instance = BuddyAllocator.new();
/// One and only instance of the bin allocator.
var bin_allocator_instance = BinAllocator.newUninit();

/// Whether the page table is initialized.
var pgtbl_initialized = atomic.Value(bool).init(false);

// =============================================================
// Functions
// =============================================================

/// Initialize the bootstrap allocator.
///
/// You MUST call this function before using `page_allocator`.
pub fn initBootstrapAllocator(map: MemoryMap) void {
    norn.rtt.expect(!pgtbl_initialized.load(.acquire));
    bootstrap_allocator_instance.init(map);
}

/// Initialize the buddy allocator.
///
/// You MUST call this function before using `buddy_allocator`.
pub fn initBuddyAllocator(log_fn: ?norn.LogFn) void {
    buddy_allocator_instance.init(&bootstrap_allocator_instance, log_fn);
}

/// Initialize the general allocator.
///
/// You MUST call this function before using `general_allocator`.
pub fn initGeneralAllocator() void {
    bin_allocator_instance.init(page_allocator);
}

/// Check if the page table is initialized.
pub fn isPgtblInitialized() bool {
    return pgtbl_initialized.load(.acquire);
}

/// Discard the initial direct mapping and construct Norn's page tables.
///
/// It creates two mappings: direct mapping and kernel mapping.
/// After this function, direct mapping provided by UEFI is no longer available.
pub fn reconstructMapping() !void {
    norn.rtt.expect(!pgtbl_initialized.load(.acquire));

    arch.disableIrq();
    defer arch.enableIrq();

    // Remap pages.
    try arch.mem.bootReconstructPageTable(bootstrap_allocator_instance.getAllocator());
    pgtbl_initialized.store(true, .release);
}

/// Check if the given virtual address is mapped and readable by the current task.
pub fn accessOk(addr: anytype) bool {
    const ptr: Virt = switch (@typeInfo(@TypeOf(addr))) {
        .int, .comptime_int => @as(Virt, addr),
        .pointer => @intFromPtr(addr),
        else => @compileError("accessOk: invalid type"),
    };

    const current = norn.sched.getCurrentTask();
    if (arch.mem.getPageAttribute(current.mm.pgtbl, ptr)) |attr| {
        return attr == .read_only or attr == .read_write or attr == .read_write_executable;
    } else return false;
}

/// Translate the given virtual address to physical address.
///
/// This function just use simple calculation and does not walk page tables.
/// To do page table walk, use arch-specific functions.
pub fn virt2phys(addr: anytype) Phys {
    const value = switch (@typeInfo(@TypeOf(addr))) {
        .int, .comptime_int => @as(u64, addr),
        .pointer => |p| switch (p.size) {
            .one, .many => @as(u64, @intFromPtr(addr)),
            .slice => @as(u64, @intFromPtr(addr.ptr)),
            else => @panic("virt2phys: invalid type"),
        },
        else => @compileError("virt2phys: invalid type"),
    };
    return if (value < kernel_base) b: {
        // Direct mapping region.
        @branchHint(.likely);
        break :b value - direct_map_base;
    } else if (vmem_base <= value and value < vmem_base + vmem_size) b: {
        // Vmemory region.
        @branchHint(.unlikely);
        break :b value - vmem_base;
    } else b: {
        // Kernel image mapping region.
        break :b value - kernel_base;
    };
}

/// Translate the given physical address to virtual address.
///
/// This function just use simple calculation and does not walk page tables.
/// To do page table walk, use arch-specific functions.
pub fn phys2virt(addr: anytype) Virt {
    const value = switch (@typeInfo(@TypeOf(addr))) {
        .int, .comptime_int => @as(u64, addr),
        .pointer => @as(u64, @intFromPtr(addr)),
        else => @compileError("phys2virt: invalid type"),
    };
    return value + direct_map_base;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const atomic = std.atomic;
const meta = std.meta;
const Allocator = std.mem.Allocator;

const surtr = @import("surtr");
const MemoryMap = surtr.MemoryMap;

const norn = @import("norn");
const arch = norn.arch;

const BootstrapAllocator = @import("mem/BootstrapAllocator.zig");
const BuddyAllocator = @import("mem/BuddyAllocator.zig");
const BinAllocator = @import("mem/BinAllocator.zig");
const VmAllocator = @import("mem/VmAllocator.zig");
