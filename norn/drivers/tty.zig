const tty_dev = CharDev{
    .name = "tty",
    .type = .{ .major = 5, .minor = 0 },
    .fops = fops,
};

const fops = fs.File.Ops{
    .iterate = iterate,
    .read = read,
    .write = write,
    .ioctl = ioctl,
};

comptime {
    device.staticRegisterDevice(init, "tty");
}

/// Wait queue for TTY read.
var wait_queue: WaitQueue = .{};
/// TTY instance.
var tty: Tty = undefined;

/// Event handler called when a character is received on the serial port.
pub fn eventHandler(_: *const anyopaque) void {
    const rb = &norn.getSerial().rb;
    while (true) {
        const c = rb.consumeOne() orelse break;
        tty.putc(c);
    }
}

/// Module init function.
fn init() callconv(.c) void {
    tty = Tty.new(norn.mem.general_allocator) catch @panic("tty.init");

    device.registerCharDev(tty_dev) catch |err| {
        std.log.err("Failed to register TTY device: {s}", .{@errorName(err)});
    };
}

fn iterate(file: *fs.File, allocator: Allocator) fs.FsError![]fs.File.IterResult {
    _ = file;
    _ = allocator;

    norn.unimplemented("tty.iterate");
}

/// Read from serial console.
fn read(_: *fs.File, buf: []u8, _: fs.Offset) fs.FsError!usize {
    return tty.read(buf) catch |err| {
        log.err("Failed to read from TTY: {s}", .{@errorName(err)});
        @panic("Aborting.");
    };
}

/// Write to serial console.
fn write(_: *fs.File, buffer: []const u8, _: fs.Offset) fs.FsError!usize {
    norn.getSerial().writeString(buffer);

    return buffer.len;
}

/// POSIX-compliant struct termios.
const Termios = extern struct {
    iflag: Iflag,
    oflag: Oflag,
    cflag: Cflag,
    lflag: Lflag,
    line: u8 = 0,
    cc: [19]u8,

    comptime {
        norn.comptimeAssert(
            @bitSizeOf(Termios) == 288,
            "Termios must be 288 bits (actual {d} bits)",
            .{@bitSizeOf(Termios)},
        );
    }

    /// Input flags.
    const Iflag = packed struct(u32) {
        /// Ignore break condition.
        ignore_break: bool,
        /// Signal interrupt on break.
        break_intr: bool,
        /// Ignore characters with parity errors.
        ignore_parity: bool,
        /// Mark parity and framing errors.
        parity_mark: bool,
        /// Enable input parity checking.
        input_parity_check: bool,
        /// Strip 8-th bit off characters.
        strip: bool,
        /// Map NL to CR on input.
        nl_to_cr: bool,
        /// Ignore CR.
        ignore_cr: bool,
        /// Map CR to NL on input.
        cr_to_nl: bool,
        /// Reserved.
        _reserved0: u23 = 0,
    };

    /// Output flags.
    const Oflag = packed struct(u32) {
        /// Process output string.
        process: bool,
        /// Reserved.
        _reserved0: u2 = 0,
        /// Map NL to CR+NL.
        crnl: bool,
        /// Ignore CR at start of line.
        nocl: bool,
        /// Map NL to line start.
        nlret: bool,
        /// Use fill character.
        fill: bool,
        /// Map DEL to fill character.
        fill_del: bool,
        /// Reserved.
        _reserved1: u24 = 0,
    };

    /// Control flags.
    /// TODO: implement
    const Cflag = packed struct(u32) {
        _unimplemented: u32 = 0,
    };

    /// Local flags.
    const Lflag = packed struct(u32) {
        /// ISIG. Enable signals.
        signals_enable: bool,
        /// ICANON. Canonical mode (line buffering, input is available after newline).
        canonical: bool,
        /// ECHO. Echo input characters.
        echo: bool,
        /// ECHOE. Echo erase characters as BS-SP-BS.
        echo_erase: bool,
        /// ECHOK. Echo newline after kill character.
        echo_kill: bool,
        /// ECHONL. Echo newline even if ECHO is off.
        echo_newline: bool,
        /// NOFLSH. Do not flush input/output buffers when generating signals.
        no_flush_on_signal: bool,
        /// TOSTOP. Stop background processes from outputting to terminal.
        tostop: bool,
        /// IEXTEN. Enable implementation-defined input processing.
        extended_input: bool,
        /// Reserved bits.
        _reserved0: u23 = 0,
    };
};

/// Window size.
const WinSize = extern struct {
    /// Lines.
    row: u16,
    /// Columns.
    col: u16,
    /// Width in pixels.
    xpixel: u16,
    /// Height in pixels.
    ypixel: u16,

    comptime {
        norn.comptimeAssert(
            @bitSizeOf(WinSize) == 64,
            "WinSize must be 64 bits (actual {d} bits)",
            .{@bitSizeOf(WinSize)},
        );
    }
};

/// ioctl commands supported by TTY device.
const IoctlCommand = enum(u64) {
    /// Get the current serial port settings.
    tcgets = 0x5401,
    /// Get foreground process group.
    tiocgpgrp = 0x540F,
    /// Set foreground process group.
    tiocspgrp = 0x5410,
    /// Get window size.
    tiocgwinsz = 0x541F,

    _,
};

/// Control command.
fn ioctl(_: *fs.File, command: u64, args: *anyopaque) fs.FsError!i64 {
    return switch (@as(IoctlCommand, @enumFromInt(command))) {
        .tcgets => {
            const output: *align(1) Termios = @ptrCast(args);
            output.* = std.mem.zeroInit(Termios, .{});
            output.iflag.ignore_parity = true;
            output.lflag.echo = true;
            output.lflag.canonical = true;
            return 0;
        },
        .tiocgpgrp => {
            return 0; // TODO
        },
        .tiocspgrp => {
            return 0; // TODO
        },
        .tiocgwinsz => {
            const output: *align(1) WinSize = @ptrCast(args);
            output.* = std.mem.zeroInit(WinSize, .{
                .row = 50, // TODO
                .col = 100, // TODO
            });
            return 0;
        },
        _ => {
            log.warn("Unsupported ioctl command: {d}", .{command});
            return fs.FsError.Unimplemented;
        },
    };
}

/// TTY.
const Tty = struct {
    /// Max buffer size.
    const buffer_size = 1024;

    /// Ring buffer.
    ring: RingBuffer(u8),
    /// Ready to return data.
    ready: bool = false,

    /// Create a new TTY.
    pub fn new(allocator: Allocator) Allocator.Error!Tty {
        const buf = try allocator.alloc(u8, buffer_size);
        return .{
            .ring = .init(buf),
        };
    }

    /// Put a character to the TTY.
    ///
    /// If newline is inserted, the TTY is marked as ready
    /// and any task waiting on the TTY is woken up.
    pub fn putc(self: *Tty, c: u8) void {
        if (self.ring.isFull()) {
            return;
        }

        // Convert CR to NL.
        const b = if (c == '\r') '\n' else c;

        // Echo input.
        // TODO: should check if ECHO is enabled.
        const serial = norn.getSerial();
        serial.write(b);

        self.ring.produceOne(b) catch {
            return;
        };

        // If newline is inserted, mark as ready and wake up waiters.
        // TODO: check if CANONICAL is enabled.
        if ((b == '\n') or self.ring.isFull()) {
            self.ready = true;
            norn.sched.wakeup(&wait_queue);
        }
    }

    /// Read from the TTY.
    ///
    /// If no data is available, the current task is blocked until data is available.
    pub fn read(self: *Tty, buf: []u8) !usize {
        while (!self.ready) {
            norn.sched.waitOn(&wait_queue, norn.sched.getCurrentTask());
        }

        const len = @min(buf.len, self.ring.len());
        const n = self.ring.consume(buf[0..len]);
        self.ready = false;

        return n;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.tty);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const fs = norn.fs;
const device = norn.device;
const CharDev = device.CharDev;
const RingBuffer = norn.ring_buffer.RingBuffer;
const WaitQueue = norn.sched.WaitQueue;
