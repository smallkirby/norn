//! https://uefi.org/htmlspecs/ACPI_Spec_6_4_html/05_ACPI_Software_Programming_Model/ACPI_Software_Programming_Model.html

const std = @import("std");
const atomic = std.atomic;

const norn = @import("norn");
const mem = norn.mem;
const SpinLock = norn.SpinLock;

const Error = error{
    /// Failed to validate SDT.
    InvalidTable,
};

/// XSDT.
var xsdt: *Xsdt = undefined;
/// MADT.
var madt: *Madt = undefined;

/// Whether the ACPI is initialized.
var initialized = atomic.Value(bool).init(false);
/// Lock for the ACPI.
var lock = SpinLock{};

/// Root System Description Pointer version 2.0.
/// This structure is used to locate the XSDT (RSDT).
const Rsdp = extern struct {
    /// Signature. Must be "RSD PTR ".
    signature: [8]u8,
    /// Checksum of the first 20 bytes.
    checksum: u8,
    /// OEM ID.
    oem_id: [6]u8,
    /// Revision.
    /// 0 for ACPI 1.0 and 2 for ACPI 2.0. Must be 2.
    revision: u8,
    /// Physical address of the RSDT.
    rsdt_address: u32,

    /// Length of the table in bytes.
    length: u32,
    /// Physical address of the XSDT.
    xsdt_address: u64,
    /// Checksum of the entire RSDP.
    extended_checksum: u8,
    /// Reserved.
    _reserved: [3]u8,

    __end_marker: void,

    const size_rsdp_v1 = @offsetOf(Rsdp, "length");
    const size_rsdp_v2 = @offsetOf(Rsdp, "__end_marker");
    comptime {
        if (size_rsdp_v1 != 20 or size_rsdp_v2 != 36) {
            @compileError("Invalid Rsdp size");
        }
    }

    /// Check if the RSDP is valid and has expected values..
    fn validate(self: *align(1) Rsdp) Error!void {
        if (!std.mem.eql(u8, &self.signature, "RSD PTR ")) {
            return Error.InvalidTable;
        }
        if (self.revision != 2) {
            return Error.InvalidTable;
        }
        if (checksum(std.mem.asBytes(self)[0..size_rsdp_v1]) != 0) {
            return Error.InvalidTable;
        }
        if (checksum(std.mem.asBytes(self)[0..size_rsdp_v2]) != 0) {
            return Error.InvalidTable;
        }
    }
};

/// 64-bit System Description Table.
/// This table contains pointers to all the other ACPI tables.
const Xsdt = extern struct {
    /// ACPI table header.
    /// The signature must be "XSDT".
    header: SdtHeader,
    /// Pointers to the other ACPI tables.
    sdts: void,

    /// Get the SDT with the specified signature.
    fn find(self: *Xsdt, signature: []const u8) ?*anyopaque {
        for (0..self.size()) |i| {
            const sdt = self.get(i);
            if (std.mem.eql(u8, &sdt.signature, signature)) {
                return sdt;
            }
        }
        return null;
    }

    /// Get the SDT at the specified index.
    fn get(self: *Xsdt, index: usize) *SdtHeader {
        // NOTE: The pointers can be aligned to 4 bytes, not 8 bytes.
        const ents_start: u64 = @intFromPtr(&self.sdts);
        const first: *u32 = @ptrFromInt(ents_start + index * @sizeOf(*u64));
        const second: *u32 = @ptrFromInt(ents_start + index * @sizeOf(*u64) + 4);
        const ptr = (@as(u64, second.*) << 32) + first.*;
        return @ptrFromInt(mem.phys2virt(ptr));
    }

    /// Number of SDTs.
    fn size(self: *Xsdt) usize {
        return (self.header.length - @sizeOf(SdtHeader)) / @sizeOf(*u64);
    }
};

/// Multiple APIC Description Table.
const Madt = extern struct {
    /// ACPI table header.
    /// The signature must be "APIC".
    header: SdtHeader,
    /// Physical address at which each processor can access its local APIC.
    local_apic_address: u32,
    /// Multiple APIC flags.
    flags: u32,
    /// List of variable length records that describe the interrupt devices.
    records: void,

    const EntryType = enum(u8) {
        /// Processor Local APIC.
        local_apic = 0,
        /// I/O APIC.
        io_apic = 1,
        /// I/O APIC Interrupt Source Override.
        io_apic_src_override = 2,
        /// I/O APIC NMI Source.
        io_apic_nmi_src = 3,
        /// Local APIC NMI Source.
        local_apic_nmi_src = 4,
        /// Local APIC Address Override.
        local_apic_address_override = 5,
        /// Processor Local x2APIC.
        local_x2apic = 9,
    };

    const Entry = union(EntryType) {
        const Header = packed struct {
            /// Entry type.
            entry_type: EntryType,
            /// Length of the entry.
            length: u8,
        };

        local_apic: *packed struct {
            /// Common header.
            header: Header,
            /// ACPI Processor ID.
            acpi_proc_id: u8,
            /// APIC ID.
            apic_id: u8,
            /// Flags.
            flags: u32,
        },
        io_apic: *packed struct {
            /// Common header.
            header: Header,
            /// I/O APIC ID.
            io_apic_id: u8,
            /// Reserved.
            _reserved: u8,
            /// I/O APIC address.
            io_apic_address: u32,
            /// Global system interrupt base.
            gsi_base: u32,
        },
        io_apic_src_override: *packed struct {
            /// Common header.
            header: Header,
            /// Bus source.
            bus: u8,
            /// IRQ source.
            irq: u8,
            /// Global system interrupt.
            gsi: u32,
            /// Flags.
            flags: u16,
        },
        io_apic_nmi_src: *packed struct {
            /// Common header.
            header: Header,
            /// Flags.
            flags: u16,
            /// Global system interrupt.
            gsi: u32,
        },
        local_apic_nmi_src: *packed struct {
            /// Common header.
            header: Header,
            /// ACPI Processor ID.
            acpi_proc_id: u8,
            /// Flags.
            flags: u16,
            /// Local APIC LINT number.
            lint: u8,
        },
        local_apic_address_override: *packed struct {
            /// Common header.
            header: Header,
            /// Reserved.
            _reserved: u16,
            /// Local APIC address.
            local_apic_address: u64,
        },
        local_x2apic: *packed struct {
            /// Common header.
            header: Header,
            /// Reserved.
            _reserved: u16,
            /// APIC ID.
            apic_id: u32,
            /// Flags.
            flags: u32,
            /// ACPI Processor UID.
            acpi_proc_uid: u32,
        },
    };

    /// Iterator for the MADT entries.
    const Iterator = struct {
        _madt: *Madt,
        _offset: usize = @offsetOf(Madt, "records"),

        /// Get the next entry if available.
        pub fn next(self: *Iterator) ?Entry {
            if (self._offset >= self._madt.header.length) {
                return null;
            }

            const header: *Entry.Header = @ptrFromInt(@intFromPtr(self._madt) + self._offset);
            self._offset += header.length;

            return switch (header.entry_type) {
                EntryType.local_apic => Entry{ .local_apic = @alignCast(@ptrCast(header)) },
                EntryType.io_apic => Entry{ .io_apic = @alignCast(@ptrCast(header)) },
                EntryType.io_apic_src_override => Entry{ .io_apic_src_override = @alignCast(@ptrCast(header)) },
                EntryType.io_apic_nmi_src => Entry{ .io_apic_nmi_src = @alignCast(@ptrCast(header)) },
                EntryType.local_apic_nmi_src => Entry{ .local_apic_nmi_src = @alignCast(@ptrCast(header)) },
                EntryType.local_apic_address_override => Entry{ .local_apic_address_override = @alignCast(@ptrCast(header)) },
                EntryType.local_x2apic => Entry{ .local_x2apic = @alignCast(@ptrCast(header)) },
            };
        }
    };

    /// Get an iterator for the MADT entries.
    pub fn iter(self: *Madt) Iterator {
        return Iterator{
            ._madt = self,
        };
    }
};

/// Common header for all ACPI tables (except RSDP).
const SdtHeader = extern struct {
    /// Signature.
    signature: [4]u8,
    /// Length of the table in bytes.
    length: u32,
    /// Revision.
    revision: u8,
    /// Checksum of the entire table.
    checksum: u8,
    /// OEM ID.
    oem_id: [6]u8,
    /// OEM table ID.
    oem_table_id: [8]u8,
    /// OEM revision.
    oem_revision: u32,
    /// Creator ID.
    creator_id: u32,
    /// Creator revision.
    creator_revision: u32,

    /// Check if the SDT is valid.
    fn validate(self: *SdtHeader, signature: []const u8) Error!void {
        if (!std.mem.eql(u8, &self.signature, signature)) {
            return Error.InvalidTable;
        }
        const bytes: [*]u8 = @ptrCast(self);
        if (checksum(bytes[0..self.length]) != 0) {
            return Error.InvalidTable;
        }
    }
};

/// Initialize the ACPI.
pub fn init(rsdp_phys: *anyopaque) Error!void {
    norn.rtt.expect(norn.mem.isPgtblInitialized());

    const mask = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(mask);

    // Find XSDT structure.
    const rsdp: *align(1) Rsdp = @ptrFromInt(mem.phys2virt(rsdp_phys));
    try rsdp.validate();
    xsdt = @ptrFromInt(mem.phys2virt(rsdp.xsdt_address));
    try xsdt.header.validate("XSDT");

    // Find MADT structure.
    madt = @alignCast(@ptrCast(xsdt.find("APIC") orelse return Error.InvalidTable));
    try madt.header.validate("APIC");
    if (norn.is_runtime_test) {
        var madt_iter = madt.iter();
        while (madt_iter.next() != null) {}
        norn.rtt.expectEqual(madt.header.length, madt_iter._offset);
    }

    initialized.store(true, .release);
}

/// Calculate the checksum of a SDP table.
fn checksum(data: []u8) u8 {
    var sum: u8 = 0;
    for (data) |byte| {
        sum +%= byte;
    }
    return sum;
}
