const std = @import("std");
const log = std.log.scoped(.init);

const norn = @import("norn");
const sched = norn.sched;
const thread = norn.thread;

/// Initial task of Norn kernel with PID 1.
pub fn initialTask() noreturn {
    log.debug("Initial task started.", .{});

    {
        log.warn("Reached end of initial task.", .{});
        norn.terminateQemu(0);
        norn.unimplemented("initialTask() reached its end.");
    }
}
