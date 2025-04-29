pub const MmError = error{
    /// Failed to allocate memory.
    OutOfMemory,
    /// Requested memory region is invalid.
    InvalidRegion,
} || arch.ArchError;

/// Convert FsError to syscall error type.
fn syscallError(err: MmError) SysError {
    const E = MmError;
    const S = SysError;
    return switch (err) {
        E.OutOfMemory => S.NoMemory,
        E.InvalidRegion, E.ValueOutOfRange => S.InvalidArg,
        else => {
            log.err("Unexpected error in syscallError(): {s}", .{@errorName(err)});
            @panic("Panic.");
        },
    };
}

const VmAreaList = InlineDoublyLinkedList(VmArea, "list_head");
const VmAreaListHead = VmAreaList.Head;

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

    /// Check if the VMA contains the given address.
    pub fn contains(self: Self, addr: u64) bool {
        return self.start <= addr and addr < self.end;
    }

    /// Get the size in bytes of the VMA.
    pub fn size(self: Self) usize {
        return self.end - self.start;
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

    /// Split the given VMA struct at the given address.
    ///
    /// The two split VMAs have the same attributes.
    /// Caller must ensure that `at` is within the VMA.
    ///
    /// Returns the two split VM areas.
    /// If `at` is the start address of the VMA, returns {null, *VmArea}.
    /// If `at` is the end address of the VMA, returns {*VmArea, null}.
    fn splitVma(self: *Self, vma: *VmArea, at: u64) error{OutOfMemory}!struct { ?*VmArea, ?*VmArea } {
        norn.rtt.expect(vma.contains(at));

        if (vma.start == at) {
            return .{ null, vma };
        }
        if (vma.end == at) {
            return .{ vma, null };
        }

        const second = try allocator.create(VmArea);
        errdefer allocator.destroy(second);

        // Init the second VMA and modify the first one.
        const offset = at - vma.start;
        second.* = .{
            ._kernel_page = vma._kernel_page[0..offset],
            .start = at,
            .end = vma.end,
            .mm = self,
            .flags = vma.flags,
        };
        vma.end = at;
        vma._kernel_page = vma._kernel_page[offset..];

        // Operate VMA list.
        self.vm_areas.insertAfter(vma, second);

        return .{ vma, second };
    }
};

/// Syscall handler for `brk`.
///
/// Change the position of the program break.
pub fn sysBrk(requested_brk: u64) SysError!i64 {
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
            return SysError.NoMemory;
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

/// Memory access flag compatible with Linux mman.
const MemoryProt = packed struct(u32) {
    /// Readable.
    read: bool,
    /// Writable.
    write: bool,
    /// Executable.
    exec: bool,
    /// Reserved.
    _reserved: u29 = 0,

    /// Convert to VmFlags.
    fn toVmFlags(self: MemoryProt) VmFlags {
        return VmFlags{
            .read = self.read,
            .write = self.write,
            .exec = self.exec,
        };
    }
};

/// Set protection on a region of memory.
pub fn sysMemoryProtect(addr: u64, len: usize, prot: MemoryProt) SysError!i64 {
    if (addr % mem.page_size != 0) {
        return SysError.InvalidArg;
    }
    if (len % mem.page_size != 0) {
        return SysError.InvalidArg;
    }
    if (prot._reserved != 0) {
        return SysError.InvalidArg;
    }

    const addr_end = addr + len;
    const mm = norn.sched.getCurrentTask().mm;

    var current_mapped = addr; // Mapping has been completed up to this.
    while (current_mapped < addr_end) {
        // Find the VMA that maps the current address.
        const vma = mm.findVma(current_mapped) orelse {
            return SysError.NoMemory; // TODO: should revert the changes.
        };
        const current_end = @min(vma.end, addr_end);

        // Skip if the VM has the requested protection.
        if (vma.flags == prot.toVmFlags()) {
            current_mapped = current_end;
            continue;
        }

        // Split the VM area.
        const first_vma, const second_vma = mm.splitVma(
            vma,
            current_end,
        ) catch |err| switch (err) {
            error.OutOfMemory => return SysError.NoMemory,
        };

        // Change the attribute.
        const attr = arch.mem.Attribute.fromVmFlags(prot.toVmFlags());
        for (@as([]const ?*VmArea, &.{ first_vma, second_vma })) |v| {
            if (v) |target| {
                if (target.contains(current_mapped)) {
                    target.flags = prot.toVmFlags();
                    arch.mem.changeAttribute(
                        mm.pgtbl,
                        target.start,
                        target.size(),
                        attr,
                    ) catch |err| return syscallError(err);
                }
            }
        }

        current_mapped = current_end;
    }

    return 0;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.mm);

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const util = norn.util;
const SysError = norn.syscall.SysError;
const Virt = mem.Virt;
const InlineDoublyLinkedList = norn.InlineDoublyLinkedList;

const allocator = norn.mem.general_allocator;
const page_allocator = norn.mem.page_allocator;
