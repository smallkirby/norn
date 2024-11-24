const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const elf = std.elf;
const log = std.log.scoped(.surtr);
const BootService = uefi.tables.BootServices;

const surtr = @import("surtr.zig");
const blog = @import("log.zig");
const arch = @import("arch.zig");

const page_size = arch.page.page_size_4k;
const page_mask = arch.page.page_mask_4k;
const is_debug = builtin.mode == .Debug;

// Override the default log options
pub const std_options = blog.default_log_options;

const Error = error{
    FailureTextOutput,
    FailureGetBootServices,
    FailureLocateFs,
    FailureOpenRoot,
    FailureOpenFile,
    FailureAllocatePool,
    FailureReadFile,
    FailureParseElf,
};

// Bootloader entry point.
pub fn main() uefi.Status {
    boot() catch |e| {
        log.err("Failed to boot: {s}", .{@errorName(e)});
        return .Aborted;
    };

    return .Success;
}

pub fn boot() Error!void {
    var status: uefi.Status = undefined;

    // Initialize log.
    const con_out = uefi.system_table.con_out orelse return Error.FailureTextOutput;
    status = con_out.clearScreen();
    blog.init(con_out);
    log.info("Initialized bootloader log.", .{});

    // Get boot services.
    const bs: *uefi.tables.BootServices = uefi.system_table.boot_services orelse {
        return Error.FailureGetBootServices;
    };
    log.debug("Got boot services.", .{});

    // Locate simple file system protocol.
    var fs: *uefi.protocol.SimpleFileSystem = undefined;
    status = bs.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @ptrCast(&fs));
    if (status != .Success)
        return Error.FailureLocateFs;
    log.info("Located simple file system protocol.", .{});

    // Open volume.
    var root_dir: *uefi.protocol.File = undefined;
    status = fs.openVolume(&root_dir);
    if (status != .Success)
        return Error.FailureOpenRoot;
    log.info("Opened filesystem volume.", .{});

    // Open kernel file.
    const kernel = try openFile(root_dir, "norn.elf");
    log.info("Opened kernel file.", .{});

    // Read kernel ELF header
    const kernel_header = try allocatePool(bs, @sizeOf(elf.Elf64_Ehdr), .LoaderData);
    const header_size = try readFile(kernel, kernel_header);
    assert(header_size == @sizeOf(elf.Elf64_Ehdr), "invalid ELF header size");

    const elf_header = elf.Header.parse(kernel_header[0..@sizeOf(elf.Elf64_Ehdr)]) catch {
        return Error.FailureParseElf;
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

    log.warn("Reached end of bootloader.", .{});
    while (true) arch.halt();
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
    root: *uefi.protocol.File,
    comptime name: [:0]const u8,
) Error!*uefi.protocol.File {
    var file: *uefi.protocol.File = undefined;
    const status = root.open(
        &file,
        &toUcs2(name),
        uefi.protocol.File.efi_file_mode_read,
        0,
    );

    return if (status == .Success) file else Error.FailureOpenFile;
}

/// Allocate memory pool.
fn allocatePool(bs: *BootService, size: usize, mem_type: uefi.tables.MemoryType) Error![]align(8) u8 {
    var out_buffer: [*]align(8) u8 = undefined;
    const status = bs.allocatePool(mem_type, size, &out_buffer);
    if (status != .Success) {
        return Error.FailureAllocatePool;
    }
    return if (status == .Success) out_buffer[0..size] else Error.FailureAllocatePool;
}

/// Read file content to the buffer.
fn readFile(file: *uefi.protocol.File, buffer: []u8) Error!usize {
    var size = buffer.len;
    const status = file.read(&size, buffer.ptr);
    return if (status == .Success) size else Error.FailureReadFile;
}

fn getMemoryMap(map: *surtr.MemoryMap, boot_services: *uefi.tables.BootServices) uefi.Status {
    return boot_services.getMemoryMap(
        &map.map_size,
        map.descriptors,
        &map.map_key,
        &map.descriptor_size,
        &map.descriptor_version,
    );
}

fn assert(condition: bool, comptime message: []const u8) void {
    if (is_debug) {
        if (!condition) {
            log.err("Assertion failed: {s}", .{message});
            while (true) arch.halt();
        }
    }
}
