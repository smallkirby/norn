pub const MmError = error{
    /// Failed to allocate memory.
    OutOfMemory,
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
    flags: Flags,
    /// List of VM areas.
    list_head: VmAreaListHead = .{},

    pub const Flags = packed struct {
        read: bool,
        write: bool,
        exec: bool,
    };
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
};

const VmAreaList = InlineDoublyLinkedList(VmArea, "list_head");
const VmAreaListHead = VmAreaList.Head;

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const mem = norn.mem;
const Virt = mem.Virt;
const InlineDoublyLinkedList = norn.InlineDoublyLinkedList;

const allocator = norn.mem.general_allocator;
