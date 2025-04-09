pub const MmError = error{
    /// Failed to allocate memory.
    OutOfMemory,
    /// Requested memory region is invalid.
    InvalidRegion,
} || arch.Error;

/// Memory attributes of a VM area.
pub const VmFlags = packed struct {
    read: bool,
    write: bool,
    exec: bool,

    pub const none = VmFlags{
        .read = false,
        .write = false,
        .exec = false,
    };
    pub const rw = VmFlags{
        .read = true,
        .write = true,
        .exec = false,
    };

    /// Generate a string representation of the VM flags.
    pub fn toString(self: VmFlags) [3]u8 {
        var buf: [3]u8 = undefined;
        buf[0] = if (self.read) 'r' else '-';
        buf[1] = if (self.write) 'w' else '-';
        buf[2] = if (self.exec) 'x' else '-';
        return buf;
    }
};

/// Single contiguous area of virtual memory.
pub const VmArea = struct {
    const Self = @This();

    /// Memory map this VM area belongs to.
    mm: *MemoryMap,
    /// Virtual address of the start of this VM area.
    start: Virt,
    /// Virtual address of the end of this VM area.
    end: Virt,
    /// Attributes of this VM area.
    flags: VmFlags,
    /// List of VM areas.
    list_head: VmAreaListHead = .{},

    /// Kernel pages corresponding to this VM area.
    _kernel_page: []const u8,

    /// Get the slice of the VM area.
    pub fn slice(self: *const Self) []const u8 {
        return self._kernel_page[0..(self.end - self.start)];
    }
};

/// Memory map of a process.
pub const MemoryMap = struct {
    const Self = @This();

    /// List of VM areas this process has.
    vm_areas: VmAreaList,
    /// Virtual address of the level-4 page table.
    pgtbl: Virt,
    /// Text region.
    code: Region,
    /// Data region.
    data: Region,
    /// Program break.
    brk: Region,

    const Region = struct {
        start: Virt = 0,
        end: Virt = 0,
    };

    /// Create a new memory map.
    pub fn new() MmError!*Self {
        const mm = try allocator.create(Self);
        mm.* = std.mem.zeroInit(Self, .{});
        return mm;
    }

    /// Allocate new pages and map it to the process VM.
    ///
    /// Note that returned VM area is not linked to the list.
    pub fn map(self: *Self, vaddr: Virt, size: usize, attr: VmFlags) MmError!*VmArea {
        const vaddr_aligned = util.rounddown(vaddr, mem.size_4kib);
        const vaddr_end = util.roundup(vaddr + size, mem.size_4kib);
        norn.rtt.expectEqual(0, (vaddr_end - vaddr_aligned) % mem.size_4kib);

        // Allocate physical pages.
        const num_pages = (vaddr_end - vaddr_aligned) / mem.size_4kib;
        const page = try page_allocator.allocPages(num_pages, .normal);
        @memset(page, 0);
        const page_phys = mem.virt2phys(page.ptr);

        // Map the pages.
        try arch.mem.map(
            self.pgtbl,
            vaddr_aligned,
            page_phys,
            page.len,
            arch.mem.convertVmFlagToAttribute(attr),
        );

        const list_head = try allocator.create(VmAreaListHead);
        list_head.* = VmAreaList.Head{};

        const vma = try allocator.create(VmArea);
        vma.* = .{
            .mm = self,
            .start = vaddr_aligned,
            .end = vaddr_end,
            .flags = attr,
            .list_head = VmAreaList.Head{},
            ._kernel_page = page,
        };

        return vma;
    }

    /// Find the VM area that contains the given address.
    fn findVma(self: *Self, addr: Virt) ?*VmArea {
        var iter = self.vm_areas.first;
        while (iter) |vma| : (iter = vma.list_head.next) {
            if (vma.start <= addr and addr < vma.end) {
                return vma;
            }
        }
        return null;
    }

    /// Find the VM area that maps the highest address in the given range [begin, end).
    fn findLastVma(self: *Self, begin: Virt, end: Virt) ?*VmArea {
        var highest: ?*VmArea = null;

        var iter = self.vm_areas.first;
        while (iter) |vma| : (iter = vma.list_head.next) {
            if (vma.start < end and begin < vma.end) {
                if (highest) |h| {
                    if (vma.start > h.start) {
                        highest = vma;
                    }
                } else {
                    highest = vma;
                }
            }
        }

        return highest;
    }
};

/// Syscall handler for `brk`.
///
/// Change the position of the program break.
pub fn sysBrk(_: *syscall.Context, requested_brk: u64) syscall.Error!i64 {
    const task = norn.sched.getCurrentTask();
    const mm = task.mm;
    const current_brk_start = mm.brk.start;
    const current_brk_end = mm.brk.end;

    if (requested_brk <= current_brk_start) {
        return @bitCast(mm.brk.end);
    }
    // TODO: Shrinking the brk is not supported yet.
    if (requested_brk <= mm.brk.end) {
        return @bitCast(mm.brk.end);
    }

    const rounded_requested_brk = util.roundup(requested_brk, mem.size_4kib);

    if (mm.findLastVma(current_brk_start, current_brk_end)) |last| {
        const grow_size = rounded_requested_brk - last.end;
        const new_last = mm.map(
            last.end,
            grow_size,
            .rw,
        ) catch |err| {
            log.err("Failed to map growing brk: {?}", .{err});
            return error.Nomem;
        };
        mm.vm_areas.append(new_last);
        mm.brk.end = new_last.end;
    } else {
        const vma = mm.map(
            current_brk_start,
            rounded_requested_brk - current_brk_start,
            .rw,
        ) catch |err| {
            log.err("Failed to map new brk: {?}", .{err});
            return @bitCast(mm.brk.end);
        };
        mm.vm_areas.append(vma);
        mm.brk = .{
            .start = current_brk_start,
            .end = rounded_requested_brk,
        };
    }

    return @bitCast(mm.brk.end);
}

const VmAreaList = InlineDoublyLinkedList(VmArea, "list_head");
const VmAreaListHead = VmAreaList.Head;

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.mm);

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const syscall = norn.syscall;
const util = norn.util;
const Virt = mem.Virt;
const InlineDoublyLinkedList = norn.InlineDoublyLinkedList;

const allocator = norn.mem.general_allocator;
const page_allocator = norn.mem.page_allocator;
