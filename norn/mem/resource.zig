//! This module provides a map of physical memory resources in the system.

pub const ResourceError = error{
    /// Resource not available.
    NotAvailable,
    /// Invalid argument.
    InvalidArgument,
    /// Memory allocation failed.
    OutOfMemory,
};

const ResourceList = InlineDoublyLinkedList(MemoryResource, "list_head");

/// List of memory resources.
///
/// This list must be sorted by the start address of the memory resources.
var resources: ResourceList = .{};

/// Memory resource description.
pub const MemoryResource = struct {
    const Self = @This();

    /// Readable name of the memory resource.
    name: ?[]const u8,
    /// Start address of the memory resource.
    start: Phys,
    /// Size in bytes of the memory resource.
    size: usize,
    /// Memory type.
    kind: Kind,

    /// Memory this resource belongs to.
    parent: ?*MemoryResource = null,
    /// Children of this memory resource.
    children: ResourceList = .{},
    /// List head.
    list_head: ResourceList.Head = .{},

    /// Type of the memory resource.
    const Kind = enum {
        /// Unknown memory type. Regarded as reserved.
        unknown,
        /// Reserved by firmware.
        reserved,
        /// System RAM.
        system_ram,
        /// Norn RAM. Kernel image is loaded here.
        norn_image,
        /// ACPI tables.
        acpi_tables,
        /// PCI device.
        pci,

        pub fn toString(self: Kind) []const u8 {
            return switch (self) {
                .unknown => "Unknown",
                .reserved => "Reserved",
                .system_ram => "System RAM",
                .norn_image => "Norn Image",
                .acpi_tables => "ACPI Tables",
                .pci => "PCI",
            };
        }
    };

    /// Add a child memory resource to this resource.
    pub fn appendChild(self: *Self, child: *MemoryResource) void {
        self.children.insertSorted(child, compareResources);
        child.parent = self;
    }
};

/// Comparator function for `MemoryResource`.
fn compareResources(a: *MemoryResource, b: *MemoryResource) std.math.Order {
    if (a.start < b.start) return .lt;
    if (a.start > b.start) return .gt;
    return .eq;
}

/// Parse the memory map provided by Surtr to construct a physical memory resource map.
pub fn init(rawmap: MemoryMap, allocator: Allocator) Allocator.Error!void {
    var map = rawmap;
    map.descriptors = @ptrFromInt(mem.phys2virt(map.descriptors));

    var desc_iter = MemoryDescriptorIterator.new(map);
    while (true) {
        var desc = (desc_iter.next() orelse break).*;
        const mtype = surtr.toExtendedMemoryType(desc.type);
        const resource_kind = mapTypeToResourceKind(mtype);

        // Merge contiguous memory regions of the same type.
        while (desc_iter.peek()) |next| {
            const phys_end = desc.physical_start + desc.number_of_pages * mem.size_4kib;
            const next_kind = mapTypeToResourceKind(surtr.toExtendedMemoryType(next.type));

            if (next.physical_start == phys_end and next_kind == resource_kind) {
                desc.number_of_pages += next.number_of_pages;
                _ = desc_iter.next();
                continue;
            }
            break;
        }

        // Populate the resource description.
        const resource = try allocator.create(MemoryResource);
        resource.* = .{
            .name = null,
            .start = desc.physical_start,
            .size = desc.number_of_pages * mem.size_4kib,
            .kind = resource_kind,
            .parent = null,
        };

        resources.insertSorted(resource, compareResources);
    }

    // Populate the kernel segment map.
    try populateKernelMap(allocator);

    // Runtime test.
    rttResourcesSorted();

    log.debug("Memory resource map is initialized.", .{});
    debugPrintResources(log.debug);
}

/// Populate the kernel segment map under Norn image resource.
fn populateKernelMap(allocator: Allocator) Allocator.Error!void {
    const norn_image: *MemoryResource = resources.findFirst("kind", .norn_image) orelse {
        @panic("Kernel image memory resource not found in the memory map.");
    };

    const text = try allocator.create(MemoryResource);
    text.* = .{
        .name = "Kernel text",
        .start = mem.virt2phys(&__norn_text_start),
        .size = mem.virt2phys(&__norn_text_end) - mem.virt2phys(&__norn_text_start),
        .kind = .norn_image,
    };
    norn_image.appendChild(text);

    const data = try allocator.create(MemoryResource);
    data.* = .{
        .name = "Kernel data",
        .start = mem.virt2phys(&__norn_data_start),
        .size = mem.virt2phys(&__norn_data_end) - mem.virt2phys(&__norn_data_start),
        .kind = .norn_image,
    };
    norn_image.appendChild(data);

    const rodata = try allocator.create(MemoryResource);
    rodata.* = .{
        .name = "Kernel rodata",
        .start = mem.virt2phys(&__norn_rodata_start),
        .size = mem.virt2phys(&__norn_rodata_end) - mem.virt2phys(&__norn_rodata_start),
        .kind = .norn_image,
    };
    norn_image.appendChild(rodata);

    const bss = try allocator.create(MemoryResource);
    bss.* = .{
        .name = "Kernel bss",
        .start = mem.virt2phys(&__norn_bss_start),
        .size = mem.virt2phys(&__norn_bss_end) - mem.virt2phys(&__norn_bss_start),
        .kind = .norn_image,
    };
    norn_image.appendChild(bss);
}

/// Request a physical memory range as a resource.
pub fn requestResource(
    name: []const u8,
    start: Phys,
    size: usize,
    kind: MemoryResource.Kind,
    allocator: Allocator,
) ResourceError!void {
    if (start % mem.size_4kib != 0) {
        return ResourceError.InvalidArgument;
    }
    if (start % mem.size_4kib != 0) {
        return ResourceError.InvalidArgument;
    }
    const end = start + size;

    var current = resources.first;
    while (current) |res| : (current = res.list_head.next) {
        if (res.start < end and start < res.start + res.size) {
            return ResourceError.NotAvailable;
        }
    }

    const resource = try allocator.create(MemoryResource);
    resource.* = .{
        .name = name,
        .start = start,
        .size = size,
        .kind = kind,
    };
    resources.insertSorted(resource, compareResources);

    log.debug("Resource created: {s}: 0x{X:0>12}-0x{X:0>12} ({s})", .{
        name,
        start,
        start + size,
        kind.toString(),
    });
}

extern const __norn_text_start: *void;
extern const __norn_text_end: *void;
extern const __norn_rodata_start: *void;
extern const __norn_rodata_end: *void;
extern const __norn_data_start: *void;
extern const __norn_data_end: *void;
extern const __norn_bss_start: *void;
extern const __norn_bss_end: *void;

/// Convert UEFI memory type to memory resource kind.
fn mapTypeToResourceKind(mtype: surtr.MemoryType) MemoryResource.Kind {
    return switch (mtype) {
        .boot_services_code,
        .boot_services_data,
        .loader_data,
        .loader_code,
        .conventional_memory,
        => .system_ram,
        .norn_reserved,
        => .norn_image,
        .acpi_reclaim_memory,
        => .acpi_tables,
        .acpi_memory_nvs,
        .runtime_services_code,
        .runtime_services_data,
        .reserved_memory_type,
        => .reserved,
        else => .unknown,
    };
}

// =============================================================
// Tests
// =============================================================

fn rttResourcesSorted() void {
    if (!norn.is_runtime_test) return;

    const S = struct {
        fn f(list: ResourceList) void {
            norn.rtt.expect(list.isSorted(compareResources));

            var current = list.first;
            while (current) |res| : (current = res.list_head.next) {
                f(res.children);
            }
        }
    };

    S.f(resources);
}

// =============================================================
// Debug
// =============================================================

/// Print all resources to the debug log.
pub fn debugPrintResources(logger: anytype) void {
    var current = resources.first;
    while (current) |res| : (current = res.list_head.next) {
        logger("{X:0>12}-{X:0>12} : {s}", .{
            res.start,
            res.start + res.size,
            res.name orelse res.kind.toString(),
        });

        var child_current = res.children.first;
        while (child_current) |child| : (child_current = child.list_head.next) {
            logger("\t{X:0>12}-{X:0>12} : {s}", .{
                child.start,
                child.start + child.size,
                child.name orelse child.kind.toString(),
            });
        }
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.res);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const mem = norn.mem;
const InlineDoublyLinkedList = norn.typing.InlineDoublyLinkedList;
const Phys = mem.Phys;

const surtr = @import("surtr");
const MemoryMap = surtr.MemoryMap;
const MemoryDescriptor = surtr.MemoryDescriptor;
const MemoryDescriptorIterator = surtr.MemoryDescriptorIterator;
