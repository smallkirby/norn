//! Surtr bootloader as a UEFI application.

// Override the default log options
pub const std_options = blog.default_log_options;

const Error = error{
    /// Failed to get SimpleTextOutput.
    TextOutput,
    /// Failed to get BootServices.
    BootServices,
    /// Failed to get SimpleFileSystem protocol.
    FileSystem,
    /// Failed to load kernel ELF image.
    Elf,
    /// Other misc errors.
    Other,
} || uefi.Error || arch.page.PageError;

/// TODO: do not hardcode. Must be sync with norn.mem
const percpu_base = 0xFFFF_FFFF_8010_0000;

/// Kernel entry function signature.
const KernelEntryType = fn (surtr.BootInfo) callconv(.{ .x86_64_win = .{} }) noreturn;

/// Surtr entry point.
pub fn main() uefi.Status {
    boot() catch |e| {
        log.err("Failed to boot: {s}", .{@errorName(e)});
        return .aborted;
    };

    return .success;
}

/// Main function.
fn boot() Error!void {
    // Initialize log.
    const con_out = uefi.system_table.con_out orelse {
        return Error.TextOutput;
    };
    try con_out.clearScreen();
    blog.init(con_out);
    log.info("Initialized Surtr log.", .{});

    // Get boot services.
    log.debug("Locating boot services.", .{});
    const bs: *uefi.tables.BootServices = uefi.system_table.boot_services orelse {
        return Error.BootServices;
    };

    // Locate simple file system protocol.
    log.info("Locating simple file system protocol.", .{});
    const fs = try bs.locateProtocol(
        uefi.protocol.SimpleFileSystem,
        null,
    ) orelse return Error.FileSystem;

    // Open volume.
    log.info("Opening filesystem volume.", .{});
    var root_dir = try fs.openVolume();

    // Open kernel file.
    log.info("Opening kernel file.", .{});
    const kernel_file = try root_dir.open(
        &toUcs2("norn.elf"),
        .read,
        .{},
    );
    const kernel_size = try getFileSize(kernel_file);

    // Load kernel.
    log.info("Loading kernel image.", .{});
    const kernel_image = try allocatePool(
        bs,
        kernel_size,
        .loader_data,
    );
    {
        const num_read = try kernel_file.read(kernel_image[0..kernel_size]);
        assert(num_read == kernel_size, "Invalid number of bytes read as kernel image.");
    }
    const kernel_loader = try KernelLoader.new(kernel_image);
    try kernel_loader.load(bs);

    // Load initramfs.
    const initramfs = try loadInitramfs(root_dir, bs);
    log.info(
        "Loaded initramfs @ 0x{X:0>16} ~ 0x{X:0>16}",
        .{ @intFromPtr(initramfs.ptr), @intFromPtr(initramfs.ptr) + initramfs.len },
    );

    // Clean up memory.
    try kernel_file.close();
    try root_dir.close();

    // Find RSDP.
    const rsdp = getRsdp() orelse {
        log.err("Failed to find RSDP.", .{});
        return Error.Other;
    };

    // Get memory map.
    var map = try getMemoryMap(bs);
    debugPrintMemoryMap(map);

    // Exit boot services.
    // After this point, we can't use any boot services including logging.
    log.info("Exiting boot services.", .{});
    bs.exitBootServices(uefi.handle, map.map_key) catch {
        // May fail if the memory map has been changed.
        // Retry after getting the latest memory map.

        log.debug("Retrying exit boot services...", .{});
        map = try getMemoryMap(bs);

        try bs.exitBootServices(uefi.handle, map.map_key);
    };

    // Jump to kernel entry point.
    const kernel_entry = kernel_loader.getEntry();
    const boot_info = surtr.BootInfo{
        .magic = surtr.magic,
        .memory_map = map,
        .rsdp = rsdp,
        .percpu_base = percpu_base,
        .initramfs = .{
            .size = initramfs.len,
            .addr = @intFromPtr(initramfs.ptr),
        },
    };
    kernel_entry(boot_info);

    // Unreachable
    unreachable;
}

/// Get a file size.
fn getFileSize(file: *const File) Error!usize {
    const info_size: usize = @sizeOf(File.Info) + 0x10;
    var info_buffer: [info_size]u8 align(@alignOf(File.Info.File)) = undefined;
    const info = try file.getInfo(.file, info_buffer[0..]);
    return info.file_size;
}

/// Allocate memory pool.
fn allocatePool(bs: *BootServices, size: usize, mem_type: MemoryType) Error![]align(8) u8 {
    return bs.allocatePool(surtr.toUefiMemoryType(mem_type), size);
}

/// Allocate pages of memory.
fn allocatePages(
    bs: *BootServices,
    mem_type: MemoryType,
    num_pages: usize,
    requested_address: ?u64,
) Error![]u8 {
    const location: uefi.tables.AllocateLocation = if (requested_address) |addr| .{
        .address = @ptrFromInt(addr),
    } else .any;
    const out = try bs.allocatePages(
        location,
        surtr.toUefiMemoryType(mem_type),
        num_pages,
    );
    return pagesToBuffer(out);
}

/// Find ACPI v2.0 table from UEFI configuration table.
fn getRsdp() ?*anyopaque {
    for (0..uefi.system_table.number_of_table_entries) |i| {
        const ctent = uefi.system_table.configuration_table[i];
        if (ctent.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            return ctent.vendor_table;
        }
    }
    return null;
}

/// Load initramfs from EFI filesystem.
fn loadInitramfs(root: *const File, bs: *BootServices) Error![]u8 {
    const file = try root.open(
        &toUcs2("rootfs.cpio"),
        .read,
        .{},
    );
    defer file.close() catch {};
    const size = try getFileSize(file);

    // Allocate memory for initramfs in .loader_data pages.
    const initramfs = try allocatePages(
        bs,
        .loader_data,
        roundup(size, page_size) / page_size,
        null,
    );

    // Load initramfs.
    const loaded_size = try file.read(initramfs);
    return initramfs[0..loaded_size];
}

/// Get a memory map.
fn getMemoryMap(bs: *BootServices) Error!surtr.MemoryMap {
    const buffer_size = page_size * 4;
    const buffer = try allocatePool(bs, buffer_size, .loader_data);
    const slice = try bs.getMemoryMap(buffer);

    return .{
        .buffer_size = buffer_size,
        .descriptors = @ptrCast(@alignCast(slice.ptr)),
        .map_size = slice.info.len * slice.info.descriptor_size,
        .map_key = slice.info.key,
        .descriptor_size = slice.info.descriptor_size,
        .descriptor_version = slice.info.descriptor_version,
    };
}

/// Print a memory map for debug.
fn debugPrintMemoryMap(map: surtr.MemoryMap) void {
    log.debug("Memory Map (Physical): Buf=0x{X}, MapSize=0x{X}, DescSize=0x{X}", .{
        @intFromPtr(map.descriptors),
        map.map_size,
        map.descriptor_size,
    });
    var map_iter = surtr.MemoryDescriptorIterator.new(map);
    while (true) {
        if (map_iter.next()) |md| {
            log.debug("  0x{X:0>16} - 0x{X:0>16} : {s}", .{
                md.physical_start,
                md.physical_start + md.number_of_pages * page_size,
                @tagName(surtr.toExtendedMemoryType(md.type)),
            });
        } else break;
    }
}

/// Kernel ELF loader.
const KernelLoader = struct {
    const Self = @This();

    /// Kernel image data.
    _image: []const u8,
    /// Kernel ELF header.
    _header: elf.Header,

    pub fn new(image: []const u8) Error!Self {
        var header_reader = std.Io.Reader.fixed(image[0..@sizeOf(elf.Elf64_Ehdr)]);
        const header = elf.Header.read(&header_reader) catch {
            return Error.Elf;
        };

        log.debug(
            \\Kernel ELF information:
            \\  Entry Point         : 0x{X}
            \\  Is 64-bit           : {d}
            \\  # of Program Headers: {d}
            \\  # of Section Headers: {d}
        ,
            .{
                header.entry,
                @intFromBool(header.is_64),
                header.phnum,
                header.shnum,
            },
        );
        const self = Self{
            ._image = image,
            ._header = header,
        };

        return self;
    }

    /// Get the entry point address.
    pub fn getEntry(self: Self) *KernelEntryType {
        return @ptrFromInt(self._header.entry);
    }

    /// Load PT_LOAD segments.
    pub fn load(self: Self, bs: *BootServices) Error!void {
        log.debug("Setting page table writable.", .{});
        try arch.page.setLv4Writable(bs);

        var iter = self._header.iterateProgramHeadersBuffer(self._image);
        while (true) {
            const phdr = iter.next() catch |err| {
                log.err("Failed to iterate program header: {t}\n", .{err});
                return Error.Elf;
            } orelse break;

            try self.loadSegment(bs, phdr);
        }

        log.debug("Setting NX bit.", .{});
        arch.enableNxBit();
    }

    /// Load a segment into memory.
    ///
    /// It first allocates memory for a segment, then map allocated pages.
    /// Finally, it loads the segment into memory.
    fn loadSegment(self: Self, bs: *BootServices, phdr: elf.Phdr) Error!void {
        if (phdr.p_type != elf.PT_LOAD) return;

        // If the virtual address is zero, regard the segment as per-CPU data.
        const vaddr = if (phdr.p_vaddr != 0) phdr.p_vaddr else percpu_base;
        const paddr = phdr.p_paddr;
        const msize = roundup(phdr.p_memsz, page_size);
        const fsize = phdr.p_filesz;
        assert(0 == vaddr & page_mask, "invalid alignment: vaddr");
        assert(0 == paddr & page_mask, "invalid alignment: paddr");

        // Allocate pages and map them.
        const mem = try allocatePages(
            bs,
            .norn_reserved,
            msize / page_size,
            paddr,
        );
        assert(@intFromPtr(mem.ptr) == paddr, "Failed to allocate memory at expected address.");
        assert(mem.len == msize, "Failed to allocate memory of requested size");

        for (0..msize / page_size) |i| {
            try arch.page.map4kTo(
                vaddr + page_size * i,
                paddr + page_size * i,
                .read_write,
                bs,
            );
        }

        // Load segment into memory.
        const chr_x: u8 = if (phdr.p_flags & elf.PF_X != 0) 'X' else '-';
        const chr_w: u8 = if (phdr.p_flags & elf.PF_W != 0) 'W' else '-';
        const chr_r: u8 = if (phdr.p_flags & elf.PF_R != 0) 'R' else '-';
        log.info(
            "  Seg @ 0x{X:0>16} - 0x{X:0>16} [{c}{c}{c}]",
            .{ vaddr, vaddr + phdr.p_memsz, chr_x, chr_w, chr_r },
        );
        @memcpy(mem[0..msize], self._image[phdr.p_offset .. phdr.p_offset + msize]);

        // Zero-clear the BSS section and uninitialized data.
        const zero_count = msize - fsize;
        if (zero_count > 0) {
            @memset(mem[fsize..], 0);
        }

        // Change memory protection.
        const page_start = vaddr;
        const page_end = roundup(vaddr + msize, page_size);
        const size = @divExact(page_end - page_start, page_size);
        const attribute = arch.page.PageAttribute.fromFlags(phdr.p_flags);
        for (0..size) |i| {
            try arch.page.changeMap4k(
                page_start + page_size * i,
                attribute,
            );
        }
    }
};

// =============================================================
// Utilities
// =============================================================

/// Round up the value to the given alignment.
///
/// If the type of `value` is a comptime integer, it's regarded as `usize`.
inline fn roundup(value: anytype, alignment: @TypeOf(value)) @TypeOf(value) {
    const T = if (@typeInfo(@TypeOf(value)) == .comptime_int) usize else @TypeOf(value);
    return (value + alignment - 1) & ~@as(T, alignment - 1);
}

/// Convert a slice of pages to a slice of bytes.
fn pagesToBuffer(pages: [][page_size]u8) []u8 {
    const total_size = pages.len * page_size;
    return @as([*]u8, @ptrCast(pages.ptr))[0..total_size];
}

/// Convert ASCII string to UCS-2 slice.
fn toUcs2(comptime s: [:0]const u8) [s.len * 2:0]u16 {
    var ucs2: [s.len * 2:0]u16 = [_:0]u16{0} ** (s.len * 2);
    for (s, 0..) |c, i| {
        ucs2[i] = c;
        ucs2[i + 1] = 0;
    }
    return ucs2;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.surtr);
const uefi = std.os.uefi;
const elf = std.elf;
const File = uefi.protocol.File;
const AllocateType = uefi.tables.AllocateType;
const BootServices = uefi.tables.BootServices;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;

const surtr = @import("surtr.zig");
const blog = @import("log.zig");
const arch = @import("arch.zig").impl;
const MemoryType = surtr.MemoryType;

const page_size = arch.page.page_size_4k;
const page_mask = arch.page.page_mask_4k;

// =============================================================
// Tests
// =============================================================

const builtin = @import("builtin");
const is_debug = builtin.mode == .Debug;

fn assert(condition: bool, comptime message: []const u8) void {
    if (is_debug) {
        if (!condition) {
            log.err("Assertion failed: {s}", .{message});
            while (true) arch.halt();
        }
    }
}
