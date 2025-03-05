const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.surtr);
const uefi = std.os.uefi;
const elf = std.elf;

const AllocateType = uefi.tables.AllocateType;
const BootServices = uefi.tables.BootServices;
const File = uefi.protocol.File;
const MemoryType = uefi.tables.MemoryType;

const surtr = @import("surtr.zig");
const blog = @import("log.zig");
const arch = @import("arch.zig");

const page_size = arch.page.page_size_4k;
const page_mask = arch.page.page_mask_4k;
const is_debug = builtin.mode == .Debug;

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
const Error = SurtrError || arch.page.PageError;

// TODO: do not hardcode. Must be sync with norn.mem
const percpu_base = 0xFFFF_FFFF_8010_0000;

// Bootloader entry point.
pub fn main() uefi.Status {
    boot() catch |e| {
        log.err("Failed to boot: {s}", .{@errorName(e)});
        return .aborted;
    };

    return .success;
}

pub fn boot() Error!void {
    var status: uefi.Status = undefined;

    // Initialize log.
    const con_out = uefi.system_table.con_out orelse return Error.TextOutput;
    status = con_out.clearScreen();
    blog.init(con_out);
    log.info("Initialized bootloader log.", .{});

    // Get boot services.
    const bs: *uefi.tables.BootServices = uefi.system_table.boot_services orelse {
        return Error.GetBootServices;
    };
    log.debug("Got boot services.", .{});

    // Locate simple file system protocol.
    var fs: *uefi.protocol.SimpleFileSystem = undefined;
    status = bs.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @ptrCast(&fs));
    if (status != .success)
        return Error.Fs;
    log.info("Located simple file system protocol.", .{});

    // Open volume.
    var root_dir: *const uefi.protocol.File = undefined;
    status = fs.openVolume(&root_dir);
    if (status != .success)
        return Error.Fs;
    log.info("Opened filesystem volume.", .{});

    // Open kernel file.
    const kernel = try openFile(root_dir, "norn.elf");
    log.info("Opened kernel file.", .{});

    // Read kernel ELF header
    const kernel_header = try allocatePool(bs, @sizeOf(elf.Elf64_Ehdr), .loader_data);
    const header_size = try readFile(kernel, kernel_header);
    assert(header_size == @sizeOf(elf.Elf64_Ehdr), "invalid ELF header size");

    const elf_header = elf.Header.parse(kernel_header[0..@sizeOf(elf.Elf64_Ehdr)]) catch {
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

    var iter = elf_header.program_header_iterator(@as(*File, @constCast(kernel)));
    while (true) {
        const phdr = iter.next() catch |err| {
            log.err("Failed to get program header: {?}\n", .{err});
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
    status = bs.allocatePages(.allocate_address, .loader_data, pages_4kib, @ptrCast(&kernel_start_phys));
    if (status != .success) {
        log.err("Failed to allocate memory for kernel image: {?}", .{status});
        return Error.AllocatePool;
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
    iter = elf_header.program_header_iterator(@constCast(kernel));
    while (true) {
        const phdr = iter.next() catch |err| {
            log.err("Failed to get program header: {?}\n", .{err});
            return Error.Load;
        } orelse break;
        if (phdr.p_type != elf.PT_LOAD) continue;

        // Load data
        status = kernel.setPosition(phdr.p_offset);
        if (status != .success) {
            log.err("Failed to set position for kernel image.", .{});
            return Error.Fs;
        }
        const vaddr = if (phdr.p_vaddr != 0) phdr.p_vaddr else percpu_base;
        const segment: [*]u8 = @ptrFromInt(vaddr);
        var mem_size = phdr.p_memsz;
        status = kernel.read(&mem_size, segment);
        if (status != .success) {
            log.err("Failed to read kernel image.", .{});
            return Error.Fs;
        }
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
            bs.setMem(@ptrFromInt(vaddr + phdr.p_filesz), zero_count, 0);
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
    status = kernel.close();
    if (status != .success) {
        log.err("Failed to close kernel file.", .{});
        return Error.Fs;
    }
    status = root_dir.close();
    if (status != .success) {
        log.err("Failed to close filesystem volume.", .{});
        return Error.Fs;
    }

    // Find RSDP.
    const rsdp = getRsdp() orelse {
        log.err("Failed to find RSDP.", .{});
        return Error.Other;
    };

    // Get memory map.
    const map_buffer_size = page_size * 4;
    var map_buffer: [map_buffer_size]u8 = undefined;
    var map = surtr.MemoryMap{
        .buffer_size = map_buffer.len,
        .descriptors = @alignCast(@ptrCast(&map_buffer)),
        .map_key = 0,
        .map_size = map_buffer.len,
        .descriptor_size = 0,
        .descriptor_version = 0,
    };
    try getMemoryMap(&map, bs);

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
                @tagName(md.type),
            });
        } else break;
    }

    // Exit boot services.
    // After this point, we can't use any boot services including logging.
    log.info("Exiting boot services.", .{});
    status = bs.exitBootServices(uefi.handle, map.map_key);
    if (status != .success) {
        // May fail if the memory map has been changed.
        // Retry after getting the memory map again.
        map.buffer_size = map_buffer.len;
        map.map_size = map_buffer.len;
        try getMemoryMap(&map, bs);

        status = bs.exitBootServices(uefi.handle, map.map_key);
        if (status != .success) {
            log.err("Failed to exit boot services.", .{});
            return Error.ExitBootServices;
        }
    }

    // Jump to kernel entry point.
    const KernelEntryType = fn (surtr.BootInfo) callconv(.Win64) noreturn;
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

/// Open a file using Simple File System protocol.
fn openFile(
    root: *const File,
    comptime name: [:0]const u8,
) Error!*const File {
    var file: *const File = undefined;
    const status = root.open(
        &file,
        &toUcs2(name),
        File.efi_file_mode_read,
        0,
    );

    return if (status == .success) file else Error.Fs;
}

/// Allocate memory pool.
fn allocatePool(bs: *BootServices, size: usize, mem_type: MemoryType) Error![]align(8) u8 {
    var out_buffer: [*]align(8) u8 = undefined;
    const status = bs.allocatePool(mem_type, size, &out_buffer);
    return if (status == .success) out_buffer[0..size] else Error.AllocatePool;
}

/// Read file content to the buffer.
fn readFile(file: *const File, buffer: []u8) Error!usize {
    var size = buffer.len;
    const status = file.read(&size, buffer.ptr);
    return if (status == .success) size else Error.Fs;
}

fn getMemoryMap(map: *surtr.MemoryMap, boot_services: *BootServices) Error!void {
    const status = boot_services.getMemoryMap(
        &map.map_size,
        map.descriptors,
        &map.map_key,
        &map.descriptor_size,
        &map.descriptor_version,
    );
    return if (status == .success) {} else Error.MemoryMap;
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
    var status: uefi.Status = undefined;

    const initramfs = try openFile(root, "rootfs.cpio");
    defer _ = initramfs.close();

    // Get initramfs size.
    const initramfs_info_size: usize = @sizeOf(uefi.FileInfo) + 0x100;
    var initramfs_info_actual_size: usize = initramfs_info_size;
    var initramfs_info_buffer: [initramfs_info_size]u8 align(@alignOf(uefi.FileInfo)) = undefined;

    status = initramfs.getInfo(
        &uefi.FileInfo.guid,
        &initramfs_info_actual_size,
        &initramfs_info_buffer,
    );
    if (status != .success) return Error.Fs;

    const initramfs_info: *const uefi.FileInfo = @alignCast(@ptrCast(&initramfs_info_buffer));
    const initramfs_size = initramfs_info.file_size;

    // Allocate memory for initramfs in .loader_data pages.
    var initramfs_start: u64 = undefined;
    const initramfs_size_pages = (initramfs_size + (page_size - 1)) / page_size;
    status = bs.allocatePages(
        .allocate_any_pages,
        .loader_data,
        initramfs_size_pages,
        @ptrCast(&initramfs_start),
    );
    if (status != .success) {
        return Error.AllocatePool;
    }

    // Load initramfs.
    const start: [*]u8 = @ptrFromInt(initramfs_start);
    const loaded_size = try readFile(initramfs, start[0..initramfs_size]);
    return start[0..loaded_size];
}

fn assert(condition: bool, comptime message: []const u8) void {
    if (is_debug) {
        if (!condition) {
            log.err("Assertion failed: {s}", .{message});
            while (true) arch.halt();
        }
    }
}
