//! Surtr bootloader as a UEFI application.

// Override the default log options
pub const std_options = blog.default_log_options;

const SurtrError = error{
    TextOutput,
    GetBootServices,
    Fs,
    AllocatePool,
    ParseElf,
    Load,
    PageTable,
    MemoryMap,
    ExitBootServices,
    Other,
};
const Error = SurtrError || uefi.Error || arch.page.PageError;

/// TODO: do not hardcode. Must be sync with norn.mem
const percpu_base = 0xFFFF_FFFF_8010_0000;

/// Bootloader entry point.
pub fn main() uefi.Status {
    boot() catch |e| {
        log.err("Failed to boot: {s}", .{@errorName(e)});
        return .aborted;
    };

    return .success;
}

/// Main function.
pub fn boot() Error!void {
    // Initialize log.
    const con_out = uefi.system_table.con_out orelse {
        return Error.TextOutput;
    };
    try con_out.clearScreen();
    blog.init(con_out);
    log.info("Initialized bootloader log.", .{});

    // Get boot services.
    const bs: *uefi.tables.BootServices = uefi.system_table.boot_services orelse {
        return Error.GetBootServices;
    };
    log.debug("Got boot services.", .{});

    // Locate simple file system protocol.
    const fs = try bs.locateProtocol(
        uefi.protocol.SimpleFileSystem,
        null,
    ) orelse return Error.Fs;
    log.info("Located simple file system protocol.", .{});

    // Open volume.
    var root_dir = fs.openVolume() catch {
        return Error.Fs;
    };
    log.info("Opened filesystem volume.", .{});

    // Open kernel file.
    const kernel = try root_dir.open(
        &toUcs2("norn.elf"),
        .read,
        .{},
    );
    const kernel_info_size: usize = @sizeOf(File.Info) + 0x100;
    var kernel_info_buffer: [kernel_info_size]u8 align(@alignOf(File.Info.File)) = undefined;
    const kernel_info: *const File.Info.File =
        try kernel.getInfo(.file, kernel_info_buffer[0..]);
    const kernel_size = kernel_info.file_size;
    log.info("Opened kernel file.", .{});

    // Read kernel ELF header
    const kernel_image = try allocatePool(
        bs,
        kernel_size,
        .loader_data,
    );
    {
        const num_read = try kernel.read(kernel_image[0..kernel_size]);
        assert(num_read == kernel_size, "Invalid number of bytes read as kernel image.");
    }

    const kernel_header_size = @sizeOf(elf.Elf64_Ehdr);
    var header_reader = std.Io.Reader.fixed(kernel_image[0..kernel_header_size]);
    const elf_header = elf.Header.read(&header_reader) catch {
        return Error.ParseElf;
    };
    log.debug("Parsed kernel ELF header.", .{});
    log.debug(
        \\Kernel ELF information:
        \\  Entry Point         : 0x{X}
        \\  Is 64-bit           : {d}
        \\  # of Program Headers: {d}
        \\  # of Section Headers: {d}
    ,
        .{
            elf_header.entry,
            @intFromBool(elf_header.is_64),
            elf_header.phnum,
            elf_header.shnum,
        },
    );

    // Calculate necessary memory size for kernel image.
    const Addr = elf.Elf64_Addr;
    var kernel_start_virt: Addr = std.math.maxInt(Addr);
    var kernel_start_phys: Addr align(page_size) = std.math.maxInt(Addr);
    var kernel_end_phys: Addr = 0;

    var iter = elf_header.iterateProgramHeadersBuffer(kernel_image);
    while (true) {
        const phdr = iter.next() catch |err| {
            log.err("Failed to get program header: {t}\n", .{err});
            return Error.Load;
        } orelse break;
        if (phdr.p_type != elf.PT_LOAD) continue;

        // If the virtual address is zero, regard the segment as per-CPU data.
        const vaddr = if (phdr.p_vaddr != 0) phdr.p_vaddr else percpu_base;
        const paddr = phdr.p_paddr;

        // Record the start and end address of the segment.
        if (paddr < kernel_start_phys) kernel_start_phys = paddr;
        if (vaddr < kernel_start_virt) kernel_start_virt = vaddr;
        if (paddr + phdr.p_memsz > kernel_end_phys) kernel_end_phys = paddr + phdr.p_memsz;
    }
    const pages_4kib = (kernel_end_phys - kernel_start_phys + (page_size - 1)) / page_size;
    log.info("Kernel image: 0x{X:0>16} - 0x{X:0>16} (0x{X} pages)", .{ kernel_start_phys, kernel_end_phys, pages_4kib });

    // Allocate memory for kernel image.
    const allocated_kern_memory = allocatePages(
        bs,
        .norn_reserved,
        pages_4kib,
        kernel_start_phys,
    ) catch |err| {
        log.err("Failed to allocate memory for kernel image: {t}", .{err});
        return err;
    };
    if (@intFromPtr(allocated_kern_memory.ptr) != kernel_start_phys) {
        log.err("Failed to allocate memory at expected address: 0x{X:0>16} != 0x{X:0>16}", .{
            @intFromPtr(allocated_kern_memory.ptr),
            kernel_start_phys,
        });
    }
    log.info("Allocated memory for kernel image @ 0x{X:0>16} ~ 0x{X:0>16}", .{ kernel_start_phys, kernel_start_phys + pages_4kib * page_size });

    // Map memory for kernel image.
    try arch.page.setLv4Writable(bs);
    log.debug("Set page table writable.", .{});

    for (0..pages_4kib) |i| {
        try arch.page.map4kTo(
            kernel_start_virt + page_size * i,
            kernel_start_phys + page_size * i,
            .read_write,
            bs,
        );
    }
    log.info("Mapped memory for kernel image.", .{});

    // Load kernel image.
    log.info("Loading kernel image...", .{});
    iter = elf_header.iterateProgramHeadersBuffer(kernel_image);
    while (true) {
        const phdr = iter.next() catch |err| {
            log.err("Failed to get program header: {t}\n", .{err});
            return Error.Load;
        } orelse break;
        if (phdr.p_type != elf.PT_LOAD) continue;

        // Load data
        try kernel.setPosition(phdr.p_offset);
        const vaddr = if (phdr.p_vaddr != 0) phdr.p_vaddr else percpu_base;
        const segment: [*]u8 = @ptrFromInt(vaddr);
        const mem_size = phdr.p_memsz;
        _ = try kernel.read(segment[0..mem_size]);
        const chr_x: u8 = if (phdr.p_flags & elf.PF_X != 0) 'X' else '-';
        const chr_w: u8 = if (phdr.p_flags & elf.PF_W != 0) 'W' else '-';
        const chr_r: u8 = if (phdr.p_flags & elf.PF_R != 0) 'R' else '-';
        log.info(
            "  Seg @ 0x{X:0>16} - 0x{X:0>16} [{c}{c}{c}]",
            .{ vaddr, vaddr + phdr.p_memsz, chr_x, chr_w, chr_r },
        );

        // Zero-clear the BSS section and uninitialized data.
        const zero_count = phdr.p_memsz - phdr.p_filesz;
        if (zero_count > 0) {
            bs._setMem(@ptrFromInt(vaddr + phdr.p_filesz), zero_count, 0);
        }

        // Change memory protection.
        const page_start = vaddr & ~page_mask;
        const page_end = (vaddr + phdr.p_memsz + (page_size - 1)) & ~page_mask;
        const size = (page_end - page_start) / page_size;
        const attribute = arch.page.PageAttribute.fromFlags(phdr.p_flags);
        for (0..size) |i| {
            try arch.page.changeMap4k(
                page_start + page_size * i,
                attribute,
            );
        }
    }

    // Enable NX-bit.
    arch.enableNxBit();

    // Load initramfs.
    const initramfs = try loadInitramfs(root_dir, bs);
    log.info(
        "Loaded initramfs @ 0x{X:0>16} ~ 0x{X:0>16}",
        .{ @intFromPtr(initramfs.ptr), @intFromPtr(initramfs.ptr) + initramfs.len },
    );

    // Clean up memory.
    try kernel.close();
    try root_dir.close();

    // Find RSDP.
    const rsdp = getRsdp() orelse {
        log.err("Failed to find RSDP.", .{});
        return Error.Other;
    };

    // Get memory map.
    const map_buffer_size = page_size * 4;
    var map_buffer: [map_buffer_size]u8 align(@alignOf(MemoryDescriptor)) = undefined;
    var map_slice = try bs.getMemoryMap(map_buffer[0..]);
    var map = surtr.MemoryMap{
        .buffer_size = map_buffer_size,
        .descriptors = @ptrCast(@alignCast(map_slice.ptr)),
        .map_size = map_slice.info.len * map_slice.info.descriptor_size,
        .map_key = map_slice.info.key,
        .descriptor_size = map_slice.info.descriptor_size,
        .descriptor_version = map_slice.info.descriptor_version,
    };

    // Print memory map.
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

    // Exit boot services.
    // After this point, we can't use any boot services including logging.
    log.info("Exiting boot services.", .{});
    bs.exitBootServices(uefi.handle, map.map_key) catch {
        // May fail if the memory map has been changed.
        // Retry after getting the memory map again.
        map_slice = try bs.getMemoryMap(map_buffer[0..]);
        map = surtr.MemoryMap{
            .buffer_size = map_buffer_size,
            .descriptors = @ptrCast(@alignCast(map_slice.ptr)),
            .map_size = map_slice.info.len * map_slice.info.descriptor_size,
            .map_key = map_slice.info.key,
            .descriptor_size = map_slice.info.descriptor_size,
            .descriptor_version = map_slice.info.descriptor_version,
        };

        try bs.exitBootServices(uefi.handle, map.map_key);
    };

    // Jump to kernel entry point.
    const KernelEntryType = fn (surtr.BootInfo) callconv(.{ .x86_64_win = .{} }) noreturn;
    const kernel_entry: *KernelEntryType = @ptrFromInt(elf_header.entry);
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

/// Convert ASCII string to UCS-2.
inline fn toUcs2(comptime s: [:0]const u8) [s.len * 2:0]u16 {
    var ucs2: [s.len * 2:0]u16 = [_:0]u16{0} ** (s.len * 2);
    for (s, 0..) |c, i| {
        ucs2[i] = c;
        ucs2[i + 1] = 0;
    }
    return ucs2;
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
) Error![]align(arch.page.page_size_4k) u8 {
    const location: uefi.tables.AllocateLocation = if (requested_address) |addr| .{
        .address = @ptrFromInt(addr),
    } else .any;
    const out = try bs.allocatePages(
        location,
        surtr.toUefiMemoryType(mem_type),
        num_pages,
    );
    return @ptrCast(&out[0]);
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
    const initramfs = try root.open(
        &toUcs2("rootfs.cpio"),
        .read,
        .{},
    );
    defer initramfs.close() catch {};

    // Get initramfs size.
    const initramfs_info_size: usize = @sizeOf(File.Info.File) + 0x100;
    var initramfs_info_buffer: [initramfs_info_size]u8 align(@alignOf(File.Info.File)) = undefined;

    const initramfs_info: *const File.Info.File = try initramfs.getInfo(
        .file,
        initramfs_info_buffer[0..],
    );
    const initramfs_size = initramfs_info.file_size;

    // Allocate memory for initramfs in .loader_data pages.
    const initramfs_size_pages = (initramfs_size + (page_size - 1)) / page_size;
    const initramfs_start = try bs.allocatePages(
        .any,
        .loader_data,
        initramfs_size_pages,
    );
    const initramfs_buffer = pagesToBuffer(initramfs_start);

    // Load initramfs.
    const loaded_size = try initramfs.read(initramfs_buffer);
    return initramfs_buffer[0..loaded_size];
}

fn pagesToBuffer(pages: [][arch.page.page_size_4k]u8) []u8 {
    const total_size = pages.len * arch.page.page_size_4k;
    return @as([*]u8, @ptrCast(pages.ptr))[0..total_size];
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.surtr);
const uefi = std.os.uefi;
const elf = std.elf;
const File = uefi.protocol.File;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;

const AllocateType = uefi.tables.AllocateType;
const BootServices = uefi.tables.BootServices;

const surtr = @import("surtr.zig");
const blog = @import("log.zig");
const arch = @import("arch.zig").impl;
const MemoryType = surtr.MemoryType;

const page_size = arch.page.page_size_4k;
const page_mask = arch.page.page_mask_4k;
const is_debug = builtin.mode == .Debug;

// =============================================================
// Tests
// =============================================================

fn assert(condition: bool, comptime message: []const u8) void {
    if (is_debug) {
        if (!condition) {
            log.err("Assertion failed: {s}", .{message});
            while (true) arch.halt();
        }
    }
}
