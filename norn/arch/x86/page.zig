pub const Error = error{
    /// Invalid address.
    InvalidAddress,
    /// Specified address is not mapped.
    NotMapped,
    /// Specified address is already mapped.
    AlreadyMapped,
} || mem.Error;

/// Page attribute.
pub const Attribute = enum {
    /// Read-only.
    read_only,
    /// Read / Write.
    read_write,
    /// Executable.
    executable,
    /// Read / Write / Executable.
    /// TODO: Remove this attribute.
    read_write_executable,
};

const size_4k = mem.size_4kib;
const size_2mb = mem.size_2mib;
const size_1gb = mem.size_1gib;
const page_shift_4k = mem.page_shift_4kib;
const page_shift_2mb = mem.page_shift_2mib;
const page_shift_1gb = mem.page_shift_1gib;
const page_mask_4k = mem.page_mask_4kib;
const page_mask_2mb = mem.page_mask_2mib;
const page_mask_1gb = mem.page_mask_1gib;

/// Shift in bits to extract the level-4 index from a virtual address.
const lv4_shift = 39;
/// Shift in bits to extract the level-3 index from a virtual address.
const lv3_shift = 30;
/// Shift in bits to extract the level-2 index from a virtual address.
const lv2_shift = 21;
/// Shift in bits to extract the level-1 index from a virtual address.
const lv1_shift = 12;
/// Mask to extract page entry index from a shifted virtual address.
const index_mask = 0x1FF;

/// Number of entries in a page table.
const num_table_entries: usize = 512;

/// Length of the implemented bits.
const implemented_bit_length = 48;
/// Most significant implemented bit in 0-origin.
const msi_bit = 47;

/// PCID used by kernel.
/// TODO: Use a unique PCID for each process.
const kernel_pcid: u16 = 0x0001;

comptime {
    if (mem.direct_map_base % size_1gb != 0) {
        @compileError("direct_map_base must be multiple of 1GiB");
    }
    if (mem.direct_map_size % size_1gb != 0) {
        @compileError("direct_map_size must be multiple of 1GiB");
    }
}

/// Return true if the given address is canonical form.
/// The address is in canonical form if address bits 63 through 48 are copies of bit 47.
pub fn isCanonical(addr: Virt) bool {
    if ((addr >> msi_bit) & 1 == 0) {
        return (addr >> (implemented_bit_length)) == 0;
    } else {
        return addr >> (implemented_bit_length) == 0xFFFF;
    }
}

/// Get the page table at the given address.
///
/// `addr`: Physical address of the page table.
/// `offset`: Offset from the address to the table.
fn getTable(T: type, addr: Phys, offset: usize) []T {
    const ptr: [*]T = @ptrFromInt((phys2virt(addr) & ~page_mask_4k) + offset);
    return ptr[0..num_table_entries];
}

/// Get the level-4 page table of the current process.
fn getLv4Table(cr3: Phys) []Lv4Entry {
    return getTable(Lv4Entry, cr3, 0);
}

/// Get the level-3 page table at the given address.
fn getLv3Table(lv3_table_addr: Phys) []Lv3Entry {
    return getTable(Lv3Entry, lv3_table_addr, 0);
}

/// Get the level-2 page table at the given address.
fn getLv2Table(lv2_table_addr: Phys) []Lv2Entry {
    return getTable(Lv2Entry, lv2_table_addr, 0);
}

/// Get the level-1 page table at the given address.
fn getLv1Table(lv1_table_addr: Phys) []Lv1Entry {
    return getTable(Lv1Entry, lv1_table_addr, 0);
}

/// Get the page table entry for the given virtual address.
///
/// `vaddr`: Virtual address to translate.
/// `paddr`: Physical address of the page table.
/// `offset`: Offset from the address to the table.
fn getEntry(T: type, vaddr: Virt, paddr: Phys, offset: usize) *T {
    const table = getTable(T, paddr, offset);
    const shift = switch (T) {
        Lv4Entry => lv4_shift,
        Lv3Entry => lv3_shift,
        Lv2Entry => lv2_shift,
        Lv1Entry => lv1_shift,
        else => @compileError("Unsupported type"),
    };
    return &table[(vaddr >> shift) & index_mask];
}

/// Get the level-4 page table entry for the given virtual address.
fn getLv4Entry(addr: Virt, cr3: Phys) *Lv4Entry {
    return getEntry(Lv4Entry, addr, cr3, 0);
}

/// Get the level-3 page table entry for the given virtual address.
fn getLv3Entry(addr: Virt, lv3tbl_paddr: Phys) *Lv3Entry {
    return getEntry(Lv3Entry, addr, lv3tbl_paddr, 0);
}

/// Get the level-2 page table entry for the given virtual address.
fn getLv2Entry(addr: Virt, lv2tbl_paddr: Phys) *Lv2Entry {
    return getEntry(Lv2Entry, addr, lv2tbl_paddr, 0);
}

/// Get the level-1 page table entry for the given virtual address.
fn getLv1Entry(addr: Virt, lv1tbl_addr: Phys) *Lv1Entry {
    return getEntry(Lv1Entry, addr, lv1tbl_addr, 0);
}

/// Create a new root of page tables for user.
///
/// This function copies the current Level 4 page table first.
/// Then, it clears the user space entries in the copied table.
pub fn createPageTables() Error!Virt {
    const allocator = norn.mem.page_allocator;
    const current_lv4tbl = getLv4Table(am.readCr3());

    const new_lv4tbl_ptr: [*]Lv4Entry = @ptrCast(try allocator.allocPages(1, .normal));
    const new_lv4tbl = new_lv4tbl_ptr[0..num_table_entries];
    @memset(new_lv4tbl[0 .. num_table_entries / 2], std.mem.zeroes(Lv4Entry));
    @memcpy(new_lv4tbl[num_table_entries / 2 .. num_table_entries], current_lv4tbl[num_table_entries / 2 .. num_table_entries]);

    return @intFromPtr(new_lv4tbl);
}

/// Map the virtual address [vaddr, vaddr + size) to the physical address [paddr, paddr + size).
///
/// This function uses only 4KiB pages.
/// You can specify the attributes of the mapping.
///
/// If the pages are already mapped, return an error.
pub fn map(cr3: Virt, vaddr: Virt, paddr: Virt, size: usize, attr: Attribute) Error!void {
    if ((vaddr & page_mask_4k) != 0) return Error.InvalidAddress;
    if ((paddr & page_mask_4k) != 0) return Error.InvalidAddress;
    if ((size & page_mask_4k) != 0) return Error.InvalidAddress;
    const allocator = norn.mem.page_allocator;
    const cr3_phys = virt2phys(cr3);

    var i: usize = 0;
    while (i < size) : (i += size_4k) {
        const cur_vaddr = vaddr + i;
        const cur_paddr = paddr + i;

        const lv4ent = getLv4Entry(cur_vaddr, cr3_phys);
        if (!lv4ent.present) lv4ent.* = Lv4Entry.newMapTable(try Lv3Entry.newTable(allocator), true, true);
        if (lv4ent.ps) return Error.AlreadyMapped;

        const lv3ent = getLv3Entry(cur_vaddr, lv4ent.address());
        if (!lv3ent.present) lv3ent.* = Lv3Entry.newMapTable(try Lv2Entry.newTable(allocator), true, true);
        if (lv3ent.ps) return Error.AlreadyMapped;

        const lv2ent = getLv2Entry(cur_vaddr, lv3ent.address());
        if (!lv2ent.present) lv2ent.* = Lv2Entry.newMapTable(try Lv1Entry.newTable(allocator), true, true);
        if (lv2ent.ps) return Error.AlreadyMapped;

        const lv1ent = getLv1Entry(cur_vaddr, lv2ent.address());
        if (lv1ent.present) return Error.AlreadyMapped;
        lv1ent.* = Lv1Entry.newMapPage(cur_paddr, true, attr, true);
    }
}

/// Translate the given virtual address to physical address by walking page tables.
/// CR3 of the current CPU is used as the root of the page table.
/// If the translation fails, return null.
pub fn translateWalk(addr: Virt) ?Phys {
    if (!isCanonical(addr)) return null;

    const lv4ent = getLv4Entry(addr, am.readCr3());
    if (!lv4ent.present) return null;

    const lv3ent = getLv3Entry(addr, lv4ent.address());
    if (!lv3ent.present) return null;
    if (lv3ent.ps) { // 1GiB page
        return lv3ent.address() + (addr & page_mask_1gb);
    }

    const lv2ent = getLv2Entry(addr, lv3ent.address());
    if (!lv2ent.present) return null;
    if (lv2ent.ps) { // 2MiB page
        return lv2ent.address() + (addr & page_mask_2mb);
    }

    const lv1ent = getLv1Entry(addr, lv2ent.address());
    if (!lv1ent.present) return null;
    return lv1ent.phys + (addr & page_mask_4k); // 4KiB page
}

/// These functions must be used only before page tables are reconstructed.
pub const boot = struct {
    /// Directly map all memory with offset.
    /// After calling this function, it is safe to unmap direct mappings of UEFI.
    /// This function must be called only once.
    pub fn reconstruct(allocator: PageAllocator) Error!void {
        // We cannot use virt2phys and phys2virt here since page tables are not initialized yet.

        const lv4tbl_ptr: [*]Lv4Entry = @ptrCast(try boot.allocatePage(allocator));
        const lv4tbl = lv4tbl_ptr[0..num_table_entries];
        @memset(lv4tbl, std.mem.zeroes(Lv4Entry));

        const lv4idx_start = (direct_map_base >> lv4_shift) & index_mask;
        const lv4idx_end = lv4idx_start + (direct_map_size >> lv4_shift);
        norn.rtt.expect(lv4idx_start < lv4idx_end);

        // Create the direct mapping using 1GiB pages.
        const upper_bound = virt2phys(direct_map_base + direct_map_size);
        for (lv4tbl[lv4idx_start..lv4idx_end], 0..) |*lv4ent, i| {
            const lv3tbl: [*]Lv3Entry = @ptrCast(try boot.allocatePage(allocator));
            @memset(lv3tbl[0..num_table_entries], std.mem.zeroes(Lv3Entry));

            for (0..num_table_entries) |lv3idx| {
                const phys: u64 = (i << lv4_shift) + (lv3idx << lv3_shift);
                if (phys >= upper_bound) break;
                lv3tbl[lv3idx] = Lv3Entry.newMapPage(phys, true, .read_write_executable, false);
            }
            lv4ent.* = Lv4Entry{
                .present = true,
                .rw = true,
                .us = false,
                .ps = false,
                .phys = @truncate(@intFromPtr(lv3tbl) >> page_shift_4k),
            };
        }

        // Recursively clone tables for the kernel region.
        // Kernel text and data sections are mapped by UEFI and present in the tables.
        // Here we clone the tables so that UEFI tables can be discarded.
        // Note that kernel regions are located beyond the direct mapping region.
        const old_lv4tbl = boot.getLv4Table(am.readCr3());
        for (lv4idx_end..num_table_entries) |lv4idx| {
            // Search for any mappings beyond the direct mapping region.
            if (old_lv4tbl[lv4idx].present) {
                const lv3tbl = boot.getLv3Table(old_lv4tbl[lv4idx].address());
                const new_lv3tbl = try boot.cloneLevel3Table(lv3tbl, allocator);
                lv4tbl[lv4idx] = Lv4Entry{
                    .present = true,
                    .rw = true,
                    .us = false,
                    .ps = false,
                    .phys = @truncate(@intFromPtr(new_lv3tbl.ptr) >> page_shift_4k),
                };
            }
        }

        var cr3 = @intFromPtr(lv4tbl) & ~@as(u64, 0xFFF);

        // Enable PCID.
        if (boot.enablePcid()) {
            cr3 |= kernel_pcid;
        }

        // Set new lv4-table and flush all TLBs.
        am.loadCr3(cr3);
    }

    /// Map single 4KiB page at the given virtual address to the given physical address.
    /// Return an error if:
    /// - `virt` is not page-aligned.
    /// - `phys` is not page-aligned.
    /// - `virt` is already mapped.
    pub fn map4kPageDirect(virt: Virt, phys: Phys, allocator: PageAllocator) Error!void {
        if ((virt & page_mask_4k) != 0) return Error.InvalidAddress;
        if ((phys & page_mask_4k) != 0) return Error.InvalidAddress;

        var lv4ent = getLv4Entry(virt, am.readCr3());
        if (!lv4ent.present) lv4ent.* = Lv4Entry.newMapTable(try Lv3Entry.newTable(allocator), true, false);

        const lv3ent = getLv3Entry(virt, lv4ent.address());
        if (!lv3ent.present) lv3ent.* = Lv3Entry.newMapTable(try Lv2Entry.newTable(allocator), true, false);
        if (lv3ent.ps) return Error.AlreadyMapped;

        const lv2ent = getLv2Entry(virt, lv3ent.address());
        if (!lv2ent.present) lv2ent.* = Lv2Entry.newMapTable(try Lv1Entry.newTable(allocator), true, false);
        if (lv2ent.ps) return Error.AlreadyMapped;

        const lv1ent = getLv1Entry(virt, lv2ent.address());
        if (lv1ent.present) return Error.AlreadyMapped;

        lv1ent.* = Lv1Entry.newMapPage(phys, true, .read_write_executable, false);
    }

    /// Unmap single 4KiB page at the given virtual address.
    pub fn unmap4kPage(virt: Virt) Error!void {
        if ((virt & page_mask_4k) != 0) return Error.InvalidAddress;

        var lv4ent = getLv4Entry(virt, am.readCr3());
        if (!lv4ent.present) return Error.NotMapped;

        const lv3ent = getLv3Entry(virt, lv4ent.address());
        if (!lv3ent.present or lv3ent.ps) return Error.NotMapped;

        const lv2ent = getLv2Entry(virt, lv3ent.address());
        if (!lv2ent.present or lv2ent.ps) return Error.NotMapped;

        const lv1ent = getLv1Entry(virt, lv2ent.address());
        if (!lv1ent.present) return Error.NotMapped;

        lv1ent.present = false;
    }

    fn cloneLevel3Table(lv3_table: []Lv3Entry, allocator: PageAllocator) Error![]Lv3Entry {
        const new_lv3ptr: [*]Lv3Entry = @ptrCast(try allocatePage(allocator));
        const new_lv3tbl = new_lv3ptr[0..num_table_entries];
        @memcpy(new_lv3tbl, lv3_table);

        for (new_lv3tbl) |*lv3ent| {
            if (!lv3ent.present or lv3ent.ps) continue;
            lv3ent.us = false;

            const lv2tbl = boot.getLv2Table(lv3ent.address());
            const new_lv2tbl = try cloneLevel2Table(lv2tbl, allocator);
            lv3ent.phys = @truncate(@intFromPtr(new_lv2tbl.ptr) >> page_shift_4k);
        }

        return new_lv3tbl;
    }

    fn cloneLevel2Table(lv2_table: []Lv2Entry, allocator: PageAllocator) Error![]Lv2Entry {
        const new_lv2ptr: [*]Lv2Entry = @ptrCast(try allocatePage(allocator));
        const new_lv2tbl = new_lv2ptr[0..num_table_entries];
        @memcpy(new_lv2tbl, lv2_table);

        for (new_lv2tbl) |*lv2ent| {
            if (!lv2ent.present or lv2ent.ps) continue;
            lv2ent.us = false;

            const lv1tbl = boot.getLv1Table(lv2ent.address());
            const new_lv1tbl = try cloneLevel1Table(lv1tbl, allocator);
            lv2ent.phys = @truncate(@intFromPtr(new_lv1tbl.ptr) >> page_shift_4k);
        }

        return new_lv2tbl;
    }

    fn cloneLevel1Table(lv1_table: []Lv1Entry, allocator: PageAllocator) Error![]Lv1Entry {
        const new_lv1ptr: [*]Lv1Entry = @ptrCast(try allocatePage(allocator));
        const new_lv1tbl = new_lv1ptr[0..num_table_entries];
        @memcpy(new_lv1tbl, lv1_table);

        for (new_lv1tbl) |*lv1ent| {
            if (!lv1ent.present) continue;
            lv1ent.us = false;
        }

        return new_lv1tbl;
    }

    /// Enable PCID.
    fn enablePcid() bool {
        const cpuid_result = cpuid.Leaf.from(0x01).query(null);
        if (norn.bits.isset(cpuid_result.ecx, 17)) {
            var cr4 = am.readCr4();
            cr4.pcide = true;
            am.loadCr4(cr4);

            return true;
        } else return false;
    }

    /// Helper function to allocate a 4KiB page using the page allocator.
    fn allocatePage(allocator: PageAllocator) Error![*]align(size_4k) u8 {
        const ret = try allocator.allocPages(1, .normal);
        return ret.ptr;
    }

    fn getTable(T: type, addr: Phys, offset: usize) []T {
        const ptr: [*]T = @ptrFromInt((addr & ~page_mask_4k) + offset);
        return ptr[0..num_table_entries];
    }

    fn getLv4Table(cr3: Phys) []Lv4Entry {
        return boot.getTable(Lv4Entry, cr3, 0);
    }

    fn getLv3Table(lv3_table_addr: Phys) []Lv3Entry {
        return boot.getTable(Lv3Entry, lv3_table_addr, 0);
    }

    fn getLv2Table(lv2_table_addr: Phys) []Lv2Entry {
        return boot.getTable(Lv2Entry, lv2_table_addr, 0);
    }

    fn getLv1Table(lv1_table_addr: Phys) []Lv1Entry {
        return boot.getTable(Lv1Entry, lv1_table_addr, 0);
    }
};

const TranslationStructure = struct {
    lv4ent: ?Lv4Entry = null,
    lv3ent: ?Lv3Entry = null,
    lv2ent: ?Lv2Entry = null,
    lv1ent: ?Lv1Entry = null,
};
/// Show the process of the address translation for the given linear address.
pub fn showPageTable(vaddr: Virt, cr3: Phys) TranslationStructure {
    const lv4idx = (vaddr >> lv4_shift) & index_mask;
    const lv3idx = (vaddr >> lv3_shift) & index_mask;
    const lv2idx = (vaddr >> lv2_shift) & index_mask;
    const lv1idx = (vaddr >> lv1_shift) & index_mask;
    var ret = TranslationStructure{};

    const lv4_table = getLv4Table(cr3);
    const lv4_entry = getLv4Entry(vaddr, lv4_table[lv4idx].address());
    if (!lv4_entry.present) return ret;
    ret.lv4ent = lv4_entry.*;
    if (lv4_entry.ps) return ret;

    const lv3_table = getLv3Table(lv4_entry.address());
    const lv3_entry = getLv3Entry(vaddr, lv3_table[lv3idx].address());
    if (!lv3_entry.present) return ret;
    ret.lv3ent = lv3_entry.*;
    if (lv3_entry.ps) return ret;

    const lv2_table = getLv2Table(lv3_entry.address());
    const lv2_entry = getLv2Entry(vaddr, lv2_table[lv2idx].address());
    if (!lv2_entry.present) return ret;
    ret.lv2ent = lv2_entry.*;
    if (lv2_entry.ps) return ret;

    const lv1_table = getLv1Table(lv2_entry.address());
    const lv1_entry = getLv1Entry(vaddr, lv1_table[lv1idx].address());
    if (!lv1_entry.present) return ret;
    ret.lv1ent = lv1_entry.*;
    return ret;
}

/// Level of the page table.
/// Lv4 is the top level table that is pointed by CR3.
const TableLevel = enum {
    lv4,
    lv3,
    lv2,
    lv1,
};

/// Common structure for page table entries.
/// Note that the position of PAT bit differs between, (Lv3 or Lv2) and Lv1.
fn EntryBase(table_level: TableLevel) type {
    return packed struct(u64) {
        const Self = @This();
        const level = table_level;
        const LowerType = switch (level) {
            .lv4 => Lv3Entry,
            .lv3 => Lv2Entry,
            .lv2 => Lv1Entry,
            .lv1 => struct {},
        };

        /// Present.
        present: bool = true,
        /// Read/Write.
        /// If set to false, write access is not allowed to the region.
        rw: bool,
        /// User/Supervisor.
        /// If set to false, user-mode access is not allowed to the region.
        us: bool,
        /// Page-level writh-through.
        /// Indirectly determines the memory type used to access the page or page table.
        pwt: bool = false,
        /// Page-level cache disable.
        /// Indirectly determines the memory type used to access the page or page table.
        pcd: bool = false,
        /// Accessed.
        /// Indicates whether this entry has been used for translation.
        accessed: bool = false,
        /// Dirty bit.
        /// Indicates whether software has written to the 2MiB page.
        /// Ignored when this entry references a page table.
        dirty: bool = false,
        /// Page Size.
        /// If set to true, the entry maps a page.
        /// If set to false, the entry references a page table.
        ps: bool,
        /// Ignored when CR4.PGE != 1.
        /// Ignored when this entry references a page table.
        /// Ignored for level-4 entries.
        global: bool = true,
        /// Ignored
        _ignored1: u2 = 0,
        /// Ignored except for HLAT paging.
        restart: bool = false,
        /// When the entry maps a page, physical address of the page.
        /// When the entry references a page table, 4KB aligned address of the page table.
        phys: u35,
        /// ReservedZ
        _reserved: u16 = 0,
        /// Execute Disable.
        xd: bool = false,

        /// Get the physical address of the page or page table that this entry references or maps.
        pub inline fn address(self: Self) Phys {
            return @as(u64, @intCast(self.phys)) << page_shift_4k;
        }

        /// Get a new page table entry that references a page table.
        pub fn newMapTable(table: [*]LowerType, present: bool, user: bool) Self {
            if (level == .lv1) @compileError("Lv1 entry cannot reference a page table");
            return Self{
                .present = present,
                .rw = true,
                .us = user,
                .ps = false,
                .phys = @truncate(virt2phys(table) >> page_shift_4k),
            };
        }

        /// Get a new page table entry that maps a page.
        pub fn newMapPage(phys: Phys, present: bool, attr: Attribute, user: bool) Self {
            if (level == .lv4) @compileError("Lv4 entry cannot map a page");
            return Self{
                .present = present,
                .rw = switch (attr) {
                    .read_write, .read_write_executable => true,
                    .read_only, .executable => false,
                },
                .us = user,
                .ps = true,
                .xd = switch (attr) {
                    .read_only, .read_write => true,
                    .executable, .read_write_executable => false,
                },
                .phys = @truncate(phys >> page_shift_4k),
            };
        }

        /// Create a new empty page table.
        pub fn newTable(allocator: PageAllocator) Error![*]Self {
            const table = try allocator.allocPages(1, .normal);
            @memset(@as([*]u8, @ptrCast(table.ptr))[0..size_4k], 0);
            return @ptrCast(table.ptr);
        }
    };
}

const Lv4Entry = EntryBase(.lv4);
const Lv3Entry = EntryBase(.lv3);
const Lv2Entry = EntryBase(.lv2);
const Lv1Entry = EntryBase(.lv1);

// ========================================

const testing = std.testing;

test {
    testing.refAllDeclsRecursive(@This());
}

test "isCanonical" {
    try testing.expectEqual(true, isCanonical(0x0));
    try testing.expectEqual(true, isCanonical(0x0000_7FFF_FFFF_FFFF));
    try testing.expectEqual(false, isCanonical(0x0000_8000_0000_0000));
    try testing.expectEqual(false, isCanonical(0x1000_0000_0000_0000));
    try testing.expectEqual(false, isCanonical(0xFFFF_7FFF_FFFF_FFFF));
    try testing.expectEqual(true, isCanonical(0xFFFF_FFFF_8000_0000));
    try testing.expectEqual(true, isCanonical(0xFFFF_8880_0000_0000));
}

// ========================================

const std = @import("std");

const norn = @import("norn");
const mem = norn.mem;

const arch = @import("arch.zig");
const am = @import("asm.zig");
const cpuid = @import("cpuid.zig");

const direct_map_base = mem.direct_map_base;
const direct_map_size = mem.direct_map_size;
const virt2phys = mem.virt2phys;
const phys2virt = mem.phys2virt;
const Virt = mem.Virt;
const Phys = mem.Phys;
const PageAllocator = mem.PageAllocator;
