//! Legacy Intel 8259 Programmable Interrupt Controller (PIC) driver.
//!
//! You can check the status of the PIC in QEMU by running: info pic
//!
//! Norn does not use the old PIC. Instead, she uses APIC.
//! Therefore, the small part of PIC is implemented here.
//!
//! Reference:
//! - https://wiki.osdev.org/8259_PIC
//! - https://pdos.csail.mit.edu/6.828/2014/readings/hardware/8259A.pdf

const icw = enum { icw1, icw2, icw3, icw4 };
const ocw = enum { ocw1, ocw2, ocw3 };

/// Primary command port
const primary_command_port: u16 = 0x20;
/// Primary data port
const primary_data_port: u16 = primary_command_port + 1;
/// Secondary command port
const secondary_command_port: u16 = 0xA0;
/// Secondary data port
const secondary_data_port: u16 = secondary_command_port + 1;

/// Offset to remap the interrupt vectors.
/// We don't want any interrupts from the old PIC,
/// so we remap them to unused vector space to avoid conflicts in case spurious interrupts occur.
const remap_offset: u8 = @intFromEnum(Vector.spurious);

/// Line numbers for the PIC.
pub const IrqLine = enum(u8) {
    /// Timer
    timer = 0,
    /// Keyboard
    keyboard = 1,
    /// Secondary PIC
    secondary = 2,
    /// Serial Port 2
    serial2 = 3,
    /// Serial Port 1
    serial1 = 4,
    /// Parallel Port 2/3
    parallel23 = 5,
    /// Floppy Disk
    floppy = 6,
    /// Parallel Port 1
    parallel1 = 7,
    /// Real Time Clock
    rtc = 8,
    /// ACPI
    acpi = 9,
    /// Available 1
    open1 = 10,
    /// Available 2
    open2 = 11,
    /// Mouse
    mouse = 12,
    /// Coprocessor
    cop = 13,
    /// Primary ATA
    primary_ata = 14,
    /// Secondary ATA
    secondary_ata = 15,

    /// Return true if the IRQ belongs to the primary PIC.
    pub fn isPrimary(self: IrqLine) bool {
        return @intFromEnum(self) < 8;
    }

    /// Get the command port for this IRQ.
    pub inline fn commandPort(self: IrqLine) u16 {
        return if (self.isPrimary()) primary_command_port else secondary_command_port;
    }

    /// Get the data port for this IRQ.
    pub inline fn dataPort(self: IrqLine) u16 {
        return if (self.isPrimary()) primary_data_port else secondary_data_port;
    }

    /// Get the offset of the IRQ within the PIC.
    pub fn delta(self: IrqLine) u3 {
        return @intCast(if (self.isPrimary()) @intFromEnum(self) else (@intFromEnum(self) - 8));
    }
};

/// Initialization command words.
const Icw = union(icw) {
    icw1: Icw1,
    icw2: Icw2,
    icw3: Icw3,
    icw4: Icw4,

    const Icw1 = packed struct(u8) {
        /// ICW4 is needed.
        icw4: bool = true,
        /// Single or cascade mode.
        single: bool = false,
        /// CALL address interval 4 or 8.
        interval4: bool = false,
        /// Level triggered or edge triggered.
        level: bool = false,
        /// Initialization command.
        _icw1: u1 = 1,
        /// Unused in 8085 mode.
        _unused: u3 = 0,
    };
    const Icw2 = packed struct(u8) {
        /// Vector offset.
        offset: u8,
    };
    const Icw3 = packed struct(u8) {
        /// For primary PIC, IRQ that is cascaded.
        /// For secondary PIC, cascade identity.
        cascade_id: u8,
    };
    const Icw4 = packed struct(u8) {
        /// 8086/8088 mode or MCS-80/85 mode.
        mode_8086: bool = true,
        /// Auto EOI or normal EOI.
        auto_eoi: bool = false,
        /// Buffered mode.
        buf: u2 = 0,
        /// Special fully nested mode.
        full_nested: bool = false,
        /// ReservedZ.
        _reserved: u3 = 0,
    };
};

/// Operationg command words.
const Ocw = union(ocw) {
    ocw1: Ocw1,
    ocw2: Ocw2,
    ocw3: Ocw3,

    const Ocw1 = packed struct(u8) {
        /// Interrupt mask.
        imr: u8,
    };
    const Ocw2 = packed struct(u8) {
        /// Target IRQ.
        level: u3 = 0,
        /// ReservedZ.
        _reserved: u2 = 0,
        /// EOI
        eoi: bool,
        /// If set, specific EOI.
        sl: bool,
        /// Rotate priority.
        rotate: bool = false,
    };
    const Ocw3 = packed struct(u8) {
        /// Target register to read.
        ris: Reg,
        /// Read register command.
        read: bool,
        /// Unused in Ymir.
        _unused1: u1 = 0,
        /// Reserved 01.
        _reserved1: u2 = 0b01,
        /// Unused in Ymir.
        _unused2: u2 = 0,
        /// ReservedZ.
        _reserved2: u1 = 0,

        const Reg = enum(u1) { irr = 0, isr = 1 };
    };
};

/// Initialize the PIC, but disable all interrupts.
pub fn initDisabled() void {
    // We have to disable interrupts to prevent PIC-driven interrupts before registering handlers.
    am.cli();
    defer am.sti();

    // Start initialization sequence.
    issue(Icw{ .icw1 = .{} }, primary_command_port);
    issue(Icw{ .icw1 = .{} }, secondary_command_port);

    // Set the vector offsets.
    issue(Icw{ .icw2 = .{ .offset = remap_offset } }, primary_data_port);
    issue(Icw{ .icw2 = .{ .offset = remap_offset } }, secondary_data_port);

    // Tell primary PIC that there is a slave PIC at IRQ2.
    issue(Icw{ .icw3 = .{ .cascade_id = 0b100 } }, primary_data_port);
    // Tell secondary PIC its cascade identity.
    issue(Icw{ .icw3 = .{ .cascade_id = 2 } }, secondary_data_port);

    // Set the mode.
    issue(Icw{ .icw4 = .{} }, primary_data_port);
    issue(Icw{ .icw4 = .{} }, secondary_data_port);

    // Mask all IRQ lines.
    setImr(0xFF, primary_data_port);
    setImr(0xFF, secondary_data_port);
}

/// Issue the CW to the PIC.
fn issue(cw: anytype, port: u16) void {
    const T = @TypeOf(cw);
    if (T != Icw and T != Ocw) {
        @compileError("Unsupported type for pic.issue()");
    }
    switch (cw) {
        inline else => |s| am.outb(@bitCast(s), port),
    }
    am.relax();
}

/// Set IMR.
inline fn setImr(imr: u8, port: u16) void {
    issue(Ocw{ .ocw1 = .{ .imr = imr } }, port);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const Vector = @import("norn").interrupt.Vector;

const am = @import("asm.zig");
