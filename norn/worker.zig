/// Worker function type.
pub const WorkerFn = *const fn (args: *const anyopaque) void;

/// Worker event.
pub const Event = struct {
    f: WorkerFn,
    args: *const anyopaque,
};

/// Worker event queue.
var event_queue: RingBuffer(Event) = undefined;
/// Wait queue only for worker thread to wait for events.
var wait_queue: WaitQueue = .{};
/// Spin lock.
var lock: SpinLock = .{};

/// Size of the event queue.
const queue_size = 512;

/// Initialize the kernel worker thread.
pub fn init(allocator: Allocator) (norn.thread.ThreadError || Allocator.Error)!void {
    const buffer = try allocator.alloc(Event, queue_size);
    errdefer allocator.free(buffer);
    event_queue = .init(buffer);

    const thread = try norn.thread.createKernelThread(
        "nworker",
        nworker,
        .{},
    );
    norn.sched.enqueueTask(thread);
}

/// Push an event to the worker event queue.
pub fn pushEvent(event: Event) norn.ring_buffer.Error!void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    try event_queue.produceOne(event);

    norn.sched.wakeup(&wait_queue);
}

/// Worker thread function that dispatches events.
fn nworker() void {
    while (true) {
        if (event_queue.isEmpty()) {
            norn.sched.waitOn(&wait_queue, norn.sched.getCurrentTask());
        }

        const event = blk: {
            const ie = lock.lockDisableIrq();
            defer lock.unlockRestoreIrq(ie);
            break :blk event_queue.consumeOne() orelse continue;
        };

        event.f(event.args);
    }

    unreachable;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.nworker);
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const RingBuffer = norn.ring_buffer.RingBuffer;
const SpinLock = norn.SpinLock;
const WaitQueue = norn.sched.WaitQueue;
