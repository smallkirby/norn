/// Initial task of Norn kernel with PID 1.
pub fn initialTask() noreturn {
    log.debug("Initial task started.", .{});

    // Enter user.
    arch.task.enterUser();

    // Unreachable.
    {
        log.warn("Reached end of initial task.", .{});
        norn.terminateQemu(0);
        norn.unimplemented("initialTask() reached its end.");
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.init);

const norn = @import("norn");
const arch = norn.arch;
