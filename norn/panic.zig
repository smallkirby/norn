const std = @import("std");
const atomic = std.atomic;
const builtin = std.builtin;
const debug = std.debug;
const log = std.log.scoped(.panic);
const format = std.fmt.format;

const norn = @import("norn");
const arch = norn.arch;

/// Implementation of the panic function.
pub const panic_fn = panic;

/// Flag to indicate that a panic occurred.
var panicked = atomic.Value(bool).init(false);

fn panic(msg: []const u8, _: ?*builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);
    arch.disableIrq();

    // Print the panic message.
    log.err("{s}", .{msg});

    // Check if a double panic occurred.
    if (panicked.load(.acquire)) {
        log.err("Double panic detected. Halting.", .{});
        norn.endlessHalt();
    }
    panicked.store(true, .release);

    // Print the stack trace.
    var it = std.debug.StackIterator.init(@returnAddress(), null);
    var ix: usize = 0;
    log.err("=== Stack Trace ==============", .{});
    while (it.next()) |frame| : (ix += 1) {
        log.err("#{d:0>2}: 0x{X:0>16}", .{ ix, frame });
    }

    // Halt the CPU.
    norn.endlessHalt();
}
