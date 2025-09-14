//! Serial 8250 UART.

const norn = @import("norn");
const arch = norn.arch;
const bits = norn.bits;

/// I/O ports for serial ports.
pub const Ports = enum(u16) {
    com1 = 0x3F8,
    com2 = 0x2F8,
    com3 = 0x3E8,
    com4 = 0x2E8,
};

/// IRQs to which serial ports can generate interrupts.
const Irq = struct {
    pub const com1 = 4;
    pub const com2 = 3;
    pub const com3 = 4;
    pub const com4 = 3;
};

const divisor_latch_numerator = 115200;
const default_baud_rate = 9600;

const Registers = struct {
    /// Transmitter Holding Buffer: DLAB=0, W
    pub const txr = 0;
    /// Receiver Buffer: DLAB=0, R
    pub const rxr = 0;
    /// Divisor Latch Low Byte: DLAB=1, R/W
    pub const dll = 0;
    /// Interrupt Enable Register: DLAB=0, R/W
    pub const ier = 1;
    /// Divisor Latch High Byte: DLAB=1, R/W
    pub const dlm = 1;
    /// Interrupt Identification Register: DLAB=X, R
    pub const iir = 2;
    /// FIFO Control Register: DLAB=X, W
    pub const fcr = 2;
    /// Line Control Register: DLAB=X, R/W
    pub const lcr = 3;
    /// Line Control Register: DLAB=0, R/W
    pub const mcr = 4;
    /// Line Status Register: DLAB=X, R
    pub const lsr = 5;
    /// Modem Status Register: DLAB=X, R
    pub const msr = 6;
    /// Scratch Register: DLAB=X, R/W
    pub const sr = 7;
};

const Functions = struct {
    write: *const fn (u8) void,
    read: *const fn () ?u8,
};

/// Initialize a serial console.
pub fn initSerial(port: Ports, baud: u32) Functions {
    const p: u16 = @intFromEnum(port);
    outb(0b00_000_0_00, p + Registers.lcr); // 8n1: no parity, 1 stop bit, 8 data bit
    outb(0, p + Registers.ier); // Disable interrupts
    outb(0, p + Registers.fcr); // Disable FIFO

    // Set baud rate
    const divisor = divisor_latch_numerator / baud;
    const c = inb(p + Registers.lcr);
    outb(c | 0b1000_0000, p + Registers.lcr); // Enable DLAB
    outb(@truncate(divisor & 0xFF), p + Registers.dll);
    outb(@truncate((divisor >> 8) & 0xFF), p + Registers.dlm);
    outb(c & 0b0111_1111, p + Registers.lcr); // Disable DLAB

    return .{
        .write = switch (port) {
            .com1 => writeByteCom1,
            .com2 => writeByteCom2,
            .com3 => writeByteCom3,
            .com4 => writeByteCom4,
        },
        .read = switch (port) {
            .com1 => tryReadByteCom1,
            .com2 => tryReadByteCom2,
            .com3 => tryReadByteCom3,
            .com4 => tryReadByteCom4,
        },
    };
}

/// Enable serial console interrupt for Rx-available.
pub fn enableInterrupt(port: Ports) void {
    var ie = inb(@intFromEnum(port) + Registers.ier);
    ie |= 0b0000_0010; // Enable Rx-available
    ie &= 0b1111_1101; // Disable Tx-empty
    outb(ie, @intFromEnum(port) + Registers.ier);
}

/// Write a single byte to the serial console.
pub fn writeByte(byte: u8, port: Ports) void {
    // Wait until the transmitter holding buffer is empty
    while (!bits.isset(inb(@intFromEnum(port) + Registers.lsr), 5)) {
        arch.relax();
    }

    // Put char to the transmitter holding buffer
    outb(byte, @intFromEnum(port));
}

fn writeByteCom1(byte: u8) void {
    writeByte(byte, .com1);
}

fn writeByteCom2(byte: u8) void {
    writeByte(byte, .com2);
}

fn writeByteCom3(byte: u8) void {
    writeByte(byte, .com3);
}

fn writeByteCom4(byte: u8) void {
    writeByte(byte, .com4);
}

/// Read a byte from Rx buffer.
/// If Rx buffer is empty, return null.
fn tryReadByte(port: Ports) ?u8 {
    // Check if Rx buffer is not empty
    if (!bits.isset(inb(@intFromEnum(port) + Registers.lsr), 0)) {
        return null;
    }

    // read char from the receiver buffer
    return inb(@intFromEnum(port));
}

fn tryReadByteCom1() ?u8 {
    return tryReadByte(.com1);
}

fn tryReadByteCom2() ?u8 {
    return tryReadByte(.com2);
}

fn tryReadByteCom3() ?u8 {
    return tryReadByte(.com3);
}

fn tryReadByteCom4() ?u8 {
    return tryReadByte(.com4);
}

fn inb(port: u16) u8 {
    return arch.in(u8, port);
}

fn outb(value: u8, port: u16) void {
    arch.out(u8, value, port);
}
