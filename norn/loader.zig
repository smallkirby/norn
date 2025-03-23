pub const Error =
    arch.Error ||
    fs.Error ||
    mem.Error ||
    error{
        /// Invalid ELF file.
        InvalidElf,
    };

/// Base address of a program break.
const brk_base: u64 = 0x80_000_000;

/// ELF loader that parses an ELF file and loads it into process memory.
pub const ElfLoader = struct {
    const Self = @This();

    const elf_header_size = @sizeOf(elf.Elf64_Ehdr);

    filename: []const u8,
    _elf_data: []align(8) u8,
    _elf_header: elf.Header,
    entry_point: Virt,

    /// Read the ELF file and prepare for loading.
    ///
    /// Caller must deallocate the struct with `deinit`.
    pub fn new(filename: []const u8) Error!Self {
        const elf_data = try readElfFile(filename);
        const elf_header = elf.Header.parse(elf_data[0..elf_header_size]) catch {
            return error.InvalidElf;
        };

        return .{
            .filename = filename,
            ._elf_data = elf_data,
            ._elf_header = elf_header,
            .entry_point = elf_header.entry,
        };
    }

    pub fn load(self: *Self, mm: *MemoryMap) Error!void {
        const elf_stream = std.io.fixedBufferStream(self._elf_data);
        var prog_iter = self._elf_header.program_header_iterator(elf_stream);

        // Iterate over program headers.
        var cur_prog = prog_iter.next() catch return error.InvalidElf;
        while (cur_prog) |cur| : (cur_prog = prog_iter.next() catch return error.InvalidElf) {
            if (cur.p_type != elf.PT_LOAD) continue;

            // Map pages.
            const vma = try mm.map(
                cur.p_vaddr,
                cur.p_memsz,
                getAttribute(cur),
            );
            mm.vm_areas.append(vma);

            // Copy segment data.
            const segment_data = self._elf_data[cur.p_offset .. cur.p_offset + cur.p_filesz];
            const offset = cur.p_vaddr % mem.size_4kib;
            const page: []u8 = @constCast(vma.slice());
            @memcpy(page[offset .. offset + cur.p_filesz], segment_data);

            // Zero clear the rest of the page.
            @memset(page[offset + cur.p_filesz ..], 0);
        }

        mm.brk = .{ .start = brk_base, .end = brk_base };
    }

    pub fn deinit(self: *Self) void {
        general_allocator.free(self._elf_data);
    }
};

fn readElfFile(filename: []const u8) Error![]align(8) u8 {
    const file = try fs.open(filename, .{}, null);
    defer fs.close(file);
    const stat = try fs.stat(file);
    const size = stat.size;

    const buf = try general_allocator.alignedAlloc(u8, 8, size);
    const read_size = try fs.read(file, buf);
    norn.rtt.expectEqual(size, read_size);

    return buf;
}

/// Get the VM flags from the ELF program header.
fn getAttribute(phdr: elf.Elf64_Phdr) VmFlags {
    const flags = phdr.p_flags;
    var vmflags: VmFlags = .none;

    if (flags & elf.PF_R != 0) vmflags.read = true;
    if (flags & elf.PF_W != 0) vmflags.write = true;
    if (flags & elf.PF_X != 0) vmflags.exec = true;

    return vmflags;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const elf = std.elf;
const log = std.log.scoped(.loader);

const norn = @import("norn");
const arch = norn.arch;
const fs = norn.fs;
const mem = norn.mem;
const util = norn.util;

const Virt = mem.Virt;
const MemoryMap = norn.mm.MemoryMap;
const VmFlags = norn.mm.VmFlags;

const general_allocator = mem.general_allocator;
const page_allocator = mem.page_allocator;
