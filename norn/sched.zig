const std = @import("std");
const log = std.log.scoped(.sched);
const Allocator = std.mem.Allocator;

const norn = @import("norn.zig");
const arch = norn.arch;
const mem = norn.mem;
const pcpu = norn.pcpu;
const SpinLock = norn.SpinLock;
const thread = norn.thread;
const Thread = thread.Thread;
const ThreadList = thread.ThreadList;

const page_allocator = mem.page_allocator;
const PageAllocator = mem.PageAllocator;

pub const Error =
    arch.Error ||
    mem.Error;

/// Run queue of this CPU.
var runq: *ThreadList linksection(pcpu.section) = undefined;
/// Task running now on this CPU.
var current_task: *Thread linksection(pcpu.section) = undefined;

/// Initialize the scheduler for this CPU.
pub fn initThisCpu(allocator: Allocator) Error!void {
    // Initialize the run queue
    const rq = try allocator.create(ThreadList);
    rq.* = .{};
    pcpu.thisCpuSet(&runq, rq);

    // Initialize the idle task
    try setupIdleTask(allocator);
}

/// Run the task scheduler on this CPU.
pub fn runThisCpu() noreturn {
    norn.arch.task.initialSwitchTo(pcpu.thisCpuGet(&current_task));
}

/// Schedule the next task.
pub fn schedule() void {
    arch.disableIrq();
    arch.getLocalApic().eoi();

    const rq: *ThreadList = getRunQueue();
    const cur: *Thread = getCurrentTask();

    // Find the next task to run.
    const next: *Thread = rq.pop() orelse {
        // No task to run.
        norn.rtt.expect(cur.tid == 0); // must be idle task

        if (norn.is_runtime_test) {
            log.info("No task to run. Terminating QEMU...", .{});
            norn.terminateQemu(0);
            @panic("Reached unreachable Norn EOL.");
        }

        arch.enableIrq();
        return;
    };

    // Update the current task.
    switch (cur.state) {
        .running => {
            // Insert the current task into the tail of the queue.
            rq.append(cur);
        },
        .dead => {
            // TODO: Destroy the task.
        },
    }
    pcpu.thisCpuSet(&current_task, next);

    // Switch the context.
    norn.arch.task.switchTo(cur, next);
}

/// Get the current task running on this CPU.
pub inline fn getCurrentTask() *Thread {
    return pcpu.thisCpuGet(&current_task);
}

/// Get the pointer to the run queue of this CPU.
inline fn getRunQueue() *ThreadList {
    return pcpu.thisCpuGet(&runq);
}

/// Append a new task to the tail of the run queue.
inline fn enqueueTask(task: *Thread) void {
    getRunQueue().append(task);
}

/// Put the initial task into the run queue.
pub fn setupInitialTask(allocator: Allocator) Error!void {
    const init_task = try thread.createInitialThread(allocator);
    enqueueTask(init_task);
    pcpu.thisCpuSet(&current_task, init_task);
}

/// Setup the idle task and set the current task to it.
fn setupIdleTask(allocator: Allocator) Error!void {
    const idle_task = try thread.createKernelThread("[idle]", idleTask, allocator);
    enqueueTask(idle_task);
}

/// Idle task that yields the CPU to other tasks immediately.
fn idleTask() noreturn {
    while (true) {
        arch.enableIrq();
        arch.halt();
    }
}

/// Print the list of threads in the run queue of this CPU.
pub fn debugPrintRunQueue(logger: anytype) void {
    const queue: *ThreadList = getRunQueue();
    var node: ?*Thread = queue.first;
    while (node) |th| {
        logger("{d: >3}: {s}", .{ th.tid, th.getName() });
        node = th.list_head.next;
    }
}
