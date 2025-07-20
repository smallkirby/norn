//! Manages allocation from the vmap region.
//!
//! The vmap region is backed by non-contiguous physical pages.
//! The regino is usually not mapped to physical pages until requested.
//! This allocator uses 4KiB pages only. You can change the permission of allocated pages as needed.

const Error = norn.mem.MemError;

const Self = @This();
const VmAllocator = Self;

/// Spin lock.
_lock: norn.SpinLock = .{},
/// All areas allocated in the valloc region.
_area_list: VmArea.Tree = .{},

/// Start virtual address of the valloc area.
const vmap_start = mem.vmem_base;
/// End virtual address of the valloc area.
const vmap_end = mem.vmem_base + mem.vmem_size;

/// Single virtually contiguous area.
const VmArea = struct {
    /// Start virtual address of this area.
    start: Virt,
    /// End virtual address of this area.
    end: Virt,
    /// Position of the guard page.
    guard_position: GuardPagePosition,
    /// List node.
    rbnode: Tree.Node,
    /// VmStruct list for this area.
    vmtree: VmStruct.Tree,
    /// Status of the area.
    _status: Status = .not_mapped,

    /// RB tree of VmArea.
    const Tree = norn.RbTree(
        @This(),
        "rbnode",
        compareVmArea,
        compareVmAreaByKey,
    );

    const Status = enum {
        /// Backing physical pages are not mapped.
        not_mapped,
        /// Mapped to physical pages.
        mapped,
    };

    /// Compares two `VmArea` instances based on their start addresses.
    ///
    /// BUG: Zig v0.14.1: using `*const VmArea` as an argument leads to a dependency loop error.
    ///     See https://github.com/ziglang/zig/issues/12325.
    fn compareVmArea(ap: *const anyopaque, bp: *const anyopaque) std.math.Order {
        const a: *const VmArea = @alignCast(@ptrCast(ap));
        const b: *const VmArea = @alignCast(@ptrCast(bp));
        if (a.start < b.start) return .lt;
        if (a.start > b.start) return .gt;
        return .eq;
    }

    /// Compares a `VmArea` with a key based on the start address of the `VmArea`.
    ///
    /// BUG: Same as above. See https://github.com/ziglang/zig/issues/12325.
    fn compareVmAreaByKey(key: Virt, ap: *const anyopaque) std.math.Order {
        const a: *const VmArea = @alignCast(@ptrCast(ap));
        if (key < a.start) return .lt;
        if (key >= a.end) return .gt;
        return .eq;
    }

    /// Allocate a new virtual memory area.
    ///
    /// Newly allocated areas are inserted into the RB tree.
    /// They're not mapped to physical pages yet.
    pub fn allocateVrange(
        vmallocator: *VmAllocator,
        size: usize,
        align_size: usize,
        guard: GuardPagePosition,
    ) Error!*VmArea {
        norn.rtt.expectEqual(0, size % mem.size_4kib);

        const size_aligned = util.roundup(size, align_size);
        const start = if (vmallocator._area_list.max()) |max| max.container().end else vmap_start;
        const start_aligned = util.roundup(start, align_size);
        const end = start_aligned + size_aligned + switch (guard) {
            .before, .after => @as(usize, mem.size_4kib),
            .none => @as(usize, 0),
        };
        if (end >= vmap_end) {
            return error.OutOfVirtualMemory;
        }

        const area = try allocator.create(VmArea);
        area.* = .{
            .start = start_aligned,
            .end = end,
            .guard_position = guard,
            .rbnode = .init,
            .vmtree = .{},
        };
        vmallocator._area_list.insert(area);

        return area;
    }

    /// Free the given virtual memory area.
    pub fn freeVrange(self: *VmAllocator, area: *VmArea) void {
        norn.rtt.expect(self._area_list.contains(area.start));

        self._area_list.delete(area);
        allocator.destroy(area);
    }

    /// Allocate physical pages and map them to the given virtual memory area.
    ///
    /// - self: The virtual memory range to map.
    ///     When the guard page is .before, a first page is not mapped.
    ///     When the guard page is .after, a last page is not mapped.
    pub fn allocateMapPhysicalPages(self: *VmArea) Error!void {
        norn.rtt.expectEqual(.not_mapped, self._status);

        const tbl = arch.mem.getRootTable();
        const num_pages = (self.end - self.start) / mem.size_4kib - switch (self.guard_position) {
            .before, .after => @as(usize, 1),
            .none => @as(usize, 0),
        };
        const vstart: Virt = self.start + mem.size_4kib * switch (self.guard_position) {
            .before => @as(usize, 1),
            .after => @as(usize, 0),
            .none => @as(usize, 0),
        };

        var vmtree = VmStruct.Tree{};
        errdefer {
            var vmtree_iter = vmtree.iterator();
            while (vmtree_iter.next()) |node| {
                const vmstruct = node.container();
                arch.mem.unmap(tbl, vmstruct.virt, vmstruct.size) catch |err| {
                    log.err("Failed to unmap virtual address 0x{X}: {s}", .{ vmstruct.virt, @errorName(err) });
                };
                allocator.destroy(node);
            }
        }

        var i: usize = 0;
        while (i < num_pages) : (i += 1) {
            const page = try mem.page_allocator.allocPages(1, .normal);
            errdefer mem.page_allocator.freePages(page);

            const virt = vstart + i * mem.size_4kib;
            const phys = mem.virt2phys(page);

            arch.mem.map(
                tbl,
                virt,
                phys,
                mem.size_4kib,
                .read_write,
            ) catch return Error.OutOfVirtualMemory;

            const vmstruct = try allocator.create(VmStruct);
            errdefer allocator.destroy(vmstruct);
            vmstruct.* = .{
                .virt = virt,
                .phys = phys,
                .size = mem.size_4kib,
                .area = self,
                .rbnode = .{},
            };
            vmtree.insert(vmstruct);
        }

        self.vmtree = vmtree;
        self._status = .mapped;
    }

    /// Unmap the physical pages backing the given virtual memory area, then free the internal structures.
    pub fn freeUnmapPhysicalPages(self: *VmArea) !void {
        const tbl = arch.mem.getRootTable();

        var vmtree_iter = self.vmtree.iterator();
        while (vmtree_iter.next()) |node| {
            const vmstruct = node.container();
            try arch.mem.unmap(tbl, vmstruct.virt, vmstruct.size);
            allocator.destroy(vmstruct);
        }
    }

    /// Get the memory slice for the virtual memory area.
    ///
    /// Guard page is omitted.
    /// If the size is larger than the area, the returned slice is smaller than the requested size.
    pub fn usableSlice(self: *const VmArea, size: usize) []u8 {
        const ptr: [*]u8 = @ptrFromInt(self.start);
        const offset = switch (self.guard_position) {
            .before => @as(usize, mem.size_4kib),
            .after => @as(usize, 0),
            .none => @as(usize, 0),
        };
        const max_size = switch (self.guard_position) {
            .before, .after => self.end - self.start - mem.size_4kib,
            .none => self.end - self.start,
        };

        return (ptr + offset)[0..@min(size, max_size)];
    }
};

/// Single virtual-physical memory mapping.
const VmStruct = struct {
    /// Virtual address of this mapping.
    virt: Virt,
    /// Physical address of the backing page.
    phys: Phys,
    /// Size in bytes of this mapping.
    size: usize,
    /// VmArea this mapping belongs to.
    area: *VmArea,
    /// List node.
    rbnode: Tree.Node,

    /// Rb tree of VmStruct.
    const Tree = norn.RbTree(
        VmStruct,
        "rbnode",
        compareVmStruct,
        compareVmStructByKey,
    );

    /// Compares two `VmStruct` instances based on their virtual addresses.
    ///
    /// BUG: Zig v0.14.1: using `*const VmStruct` as an argument leads to a dependency loop error.
    ///     See https://github.com/ziglang/zig/issues/12325.
    fn compareVmStruct(ap: *const anyopaque, bp: *const anyopaque) std.math.Order {
        const a: *const VmStruct = @alignCast(@ptrCast(ap));
        const b: *const VmStruct = @alignCast(@ptrCast(bp));
        if (a.virt < b.virt) return .lt;
        if (a.virt > b.virt) return .gt;
        return .eq;
    }

    /// Compares a `VmStruct` with a key based on the virtual address.
    ///
    /// BUG: Same as above. See https://github.com/ziglang/zig/issues/12325.
    fn compareVmStructByKey(key: Virt, ap: *const anyopaque) std.math.Order {
        const a: *const VmStruct = @alignCast(@ptrCast(ap));
        if (key < a.virt) return .lt;
        if (key >= a.virt + a.size) return .gt;
        return .eq;
    }
};

/// Where to place the guard page.
const GuardPagePosition = enum {
    /// Before the requested region.
    before,
    /// After the requested region.
    after,
    /// No guard page.
    none,
};

/// Create a new instance.
pub fn new() VmAllocator {
    return .{};
}

/// Allocates a memory from vmap region.
///
/// The allocated memory is virtually contiguous, but can be backed by non-contiguous physical pages.
pub fn virtualAlloc(self: *VmAllocator, size: usize, guard: GuardPagePosition) Error![]u8 {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    // Allocate a virtual memory range.
    const vmarea = try VmArea.allocateVrange(
        self,
        size,
        mem.size_4kib,
        guard,
    );
    errdefer VmArea.freeVrange(self, vmarea);

    // Allocate backing physical pages and map them to the allocated virtual memory area.
    try vmarea.allocateMapPhysicalPages();

    // Returns the slice with the exact requested size.
    return vmarea.usableSlice(size);
}

/// Frees a memory allocated by `virtualAlloc()`.
pub fn virtualFree(self: *VmAllocator, ptr: []u8) void {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    const vmarea_node = self._area_list.find(@intFromPtr(ptr.ptr)) orelse {
        @panic("Invalid pointer passed to VmAllocator.virtualFree()");
    };
    const vmarea = vmarea_node.container();

    vmarea.freeUnmapPhysicalPages() catch |err| {
        log.err("Failed to unmap physical pages for virtual memory area: {s}", .{@errorName(err)});
    };
    VmArea.freeVrange(self, vmarea);
}

/// Maps the given physical address to a virtual address.
///
/// Caller must reserve the physical address range beforehand.
pub fn iomap(self: *VmAllocator, phys: Phys, size: usize) Error!IoAddr {
    const ie = self._lock.lockDisableIrq();
    defer self._lock.unlockRestoreIrq(ie);

    norn.rtt.expectEqual(0, size % mem.size_4kib);
    norn.rtt.expectEqual(0, phys % mem.size_4kib);
    const num_pages = size / mem.size_4kib;

    // Allocate a virtual memory range.
    const vmarea_node = try VmArea.allocateVrange(
        self,
        size,
        mem.size_4kib,
        .none,
    );
    errdefer VmArea.freeVrange(self, vmarea_node);

    // Map the physical address to the allocated virtual memory range.
    const tbl = arch.mem.getRootTable();
    var vmtree = VmStruct.Tree{};
    errdefer {
        var vmtree_iter = vmtree.iterator();
        while (vmtree_iter.next()) |node| {
            const vmstruct = node.container();
            arch.mem.unmap(tbl, vmstruct.virt, vmstruct.size) catch |err| {
                log.err("Failed to unmap virtual address 0x{X}: {s}", .{ vmstruct.virt, @errorName(err) });
            };
            allocator.destroy(node);
        }
    }

    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        const virt = vmarea_node.start + i * mem.size_4kib;
        const phys_page = phys + i * mem.size_4kib;

        arch.mem.map(
            tbl,
            virt,
            phys_page,
            mem.size_4kib,
            .read_write,
        ) catch return Error.OutOfVirtualMemory;

        const vmstruct = try allocator.create(VmStruct);
        errdefer allocator.destroy(vmstruct);
        vmstruct.* = .{
            .virt = virt,
            .phys = phys_page,
            .size = mem.size_4kib,
            .area = vmarea_node,
            .rbnode = .{},
        };
        vmtree.insert(vmstruct);
    }

    vmarea_node.vmtree = vmtree;
    vmarea_node._status = .mapped;

    return .{ ._virt = vmarea_node.start };
}

/// Unmap the given virtual address.
pub fn iounmap(self: *VmAllocator, addr: IoAddr) void {
    _ = self;
    _ = addr;

    norn.unimplemented("iounmap");
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.VmAllocator);

const norn = @import("norn");
const algorithm = norn.algorithm;
const arch = norn.arch;
const mem = norn.mem;
const util = norn.util;
const IoAddr = mem.IoAddr;
const Phys = mem.Phys;
const Virt = mem.Virt;

const allocator = mem.general_allocator;
const page_allocator = mem.page_allocator;
