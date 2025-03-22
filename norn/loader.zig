pub const Error =
    arch.Error ||
    fs.Error ||
    mem.Error ||
    error{
        /// Invalid ELF file.
        InvalidElf,
    };

// TODO: doc
pub const ElfLoader = struct {
    const Self = @This();

    const elf_header_size = @sizeOf(elf.Elf64_Ehdr);

    filename: []const u8,
    elf_data: []align(8) u8,
    elf_header: elf.Header,

    pgtbl: Virt,
    entry_point: u64,

    pub fn new(filename: []const u8, pgtbl: Virt) Error!Self {
        const elf_data = try readElfFile(filename);
        const elf_header = elf.Header.parse(elf_data[0..elf_header_size]) catch {
            return error.InvalidElf;
        };

        return .{
            .filename = filename,
            .elf_data = elf_data,
            .elf_header = elf_header,
            .pgtbl = pgtbl,
            .entry_point = elf_header.entry,
        };
    }

    pub fn load(self: *Self) Error!void {
        const elf_stream = std.io.fixedBufferStream(self.elf_data);
        var prog_iter = self.elf_header.program_header_iterator(elf_stream);

        var cur_prog = prog_iter.next() catch return error.InvalidElf;
        while (cur_prog) |cur| : (cur_prog = prog_iter.next() catch return error.InvalidElf) {
            if (cur.p_type != elf.PT_LOAD) continue;

            // Map pages.
            const page = try self.mapSegment(
                cur.p_vaddr,
                cur.p_memsz,
                getAttribute(cur),
            );

            // Copy segment data.
            const segment_data = self.elf_data[cur.p_offset .. cur.p_offset + cur.p_filesz];
            const offset = cur.p_vaddr % mem.size_4kib;
            @memcpy(page[offset .. offset + cur.p_filesz], segment_data);
        }
    }

    pub fn deinit(self: *Self) void {
        general_allocator.free(self.elf_data);
    }

    fn mapSegment(
        self: *Self,
        vaddr: Virt,
        size: usize,
        attr: Attribute,
    ) Error![]align(mem.size_4kib) u8 {
        const vaddr_aligned = util.rounddown(vaddr, mem.size_4kib);
        const vaddr_end = util.roundup(vaddr + size, mem.size_4kib);
        norn.rtt.expectEqual(0, (vaddr_end - vaddr_aligned) % mem.size_4kib);

        const num_pages = (vaddr_end - vaddr_aligned) / mem.size_4kib;
        const page = try page_allocator.allocPages(num_pages, .normal);
        const paddr = mem.virt2phys(page.ptr);
        try arch.mem.map(self.pgtbl, vaddr_aligned, paddr, page.len, attr);

        return page;
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

fn getAttribute(phdr: elf.Elf64_Phdr) Attribute {
    const flags = phdr.p_flags;
    return if (flags & elf.PF_X != 0) .executable else if (flags & elf.PF_W != 0) .read_write else .read_only;
}

const std = @import("std");
const elf = std.elf;
const log = std.log.scoped(.loader);

const norn = @import("norn");
const arch = norn.arch;
const fs = norn.fs;
const mem = norn.mem;
const util = norn.util;

const Attribute = arch.mem.Attribute;
const Virt = mem.Virt;

const general_allocator = mem.general_allocator;
const page_allocator = mem.page_allocator;
