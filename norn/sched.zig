/// Error.
pub const SchedError = arch.ArchError || mem.MemError || thread.ThreadError;

/// Run queue of this CPU.
///
/// This variable manages a list of tasks that are ready to run.
/// Task (`Thread`) itself contains a list head which constitutes a linked list.
///
/// Per-CPU variable.
var runq: *ThreadList linksection(pcpu.section) = undefined;
/// Task running now on this CPU.
///
/// The task represented by this variable is not managed by the run queue.
/// This variable must not be `undefined` once the scheduler is initialized.
///
/// Per-CPU variable.
var current_task: *Thread linksection(pcpu.section) = undefined;
/// Whether the scheduler is initialized for this CPU.
var is_initialized: bool linksection(pcpu.section) = false;
/// True once main thread first called `schedule()` function.
var unlocked: bool linksection(pcpu.section) = false;

/// Initialize the scheduler for this CPU.
///
/// Note that the timer that triggers the scheduler does not start yet.
pub fn initThisCpu() SchedError!void {
    // Initialize the run queue
    const rq = try general_allocator.create(ThreadList);
    rq.* = .{};
    pcpu.set(&runq, rq);
    pcpu.set(&is_initialized, true);
}

/// Check if the scheduler is initialized for this CPU.
pub fn isInitialized() bool {
    return pcpu.get(&is_initialized);
}

/// Switch to the initial kernel thread queued in the run queue.
///
/// You must call this function for each CPU.
/// This function never returns.
pub fn runInitialKernelThread() noreturn {
    norn.rtt.expectEqual(1, getRunQueue().len);

    const init = getRunQueue().pop() orelse unreachable;
    pcpu.set(&current_task, init);

    norn.arch.task.initialSwitchTo(init);
}

/// Allow the timer interrupt to schedule the next task.
pub fn unlock() void {
    norn.rtt.expect(!pcpu.get(&unlocked));
    pcpu.set(&unlocked, true);
}

/// Schedule the next task.
pub fn schedule() void {
    _ = arch.disableIrq();
    arch.getLocalApic().eoi();

    if (!pcpu.get(&unlocked)) {
        @branchHint(.unlikely);
        return;
    }

    const rq: *ThreadList = getRunQueue();
    const cur: *Thread = getCurrentTask();

    // Find the next task to run.
    const next: *Thread = rq.popFirst() orelse {
        // No task to run.
        norn.rtt.expect(cur.tid == 0); // must be idle task

        if (norn.is_runtime_test) {
            log.info("No task to run. Terminating QEMU...", .{});
            norn.terminateQemu(0);
        }

        arch.enableIrq();
        return;
    };

    // Skip if the next task is the idle task.
    // TODO: should switch to the next of the idle task.
    if (next.tid == 0) {
        rq.append(next);
        arch.enableIrq();
        return;
    }

    // Update the current task.
    switch (cur.state) {
        .running => {
            // Insert the current task into the tail of the queue.
            rq.append(cur);
        },
        .dead => {
            // TODO: Destroy the task.
            norn.unimplemented("Destroy the task.");
        },
    }
    pcpu.set(&current_task, next);

    // Update the CPU time.
    // TODO: properly record user/kernel -CPU time.
    const tsc = timer.getTimestamp();
    cur.cpu_time.updateExitUser(tsc);
    next.cpu_time.updateEnterUser(tsc);

    // Switch the context.
    norn.arch.task.switchTo(cur, next);
}

/// Get the pointer to the current task running on this CPU.
pub inline fn getCurrentTask() *Thread {
    return pcpu.get(&current_task);
}

/// Get the pointer to the run queue of this CPU.
inline fn getRunQueue() *ThreadList {
    return pcpu.get(&runq);
}

/// Append a new task to the tail of the run queue.
pub fn enqueueTask(task: *Thread) void {
    getRunQueue().append(task);
}

/// Create an initial task (PID 1) and set the current task to it.
pub fn setupInitialTask(args: ?[]const []const u8) SchedError!void {
    norn.rtt.expectEqual(0, getCurrentTask().tid);

    // Create a task.
    const init_task = try thread.createInitialThread(
        @constCast(args orelse &[_][]const u8{"/sbin/init"}),
    );

    // Set FS.
    init_task.fs.setRoot(getCurrentTask().fs.root);
    init_task.fs.setCwd(getCurrentTask().fs.cwd);

    // Enqueue the initial task to the run queue.
    enqueueTask(init_task);
}

/// Create an idle task and append it to the run queue.
fn setupIdleTask() SchedError!void {
    const idle_task = try thread.createKernelThread("[idle]", idleTask);
    enqueueTask(idle_task);
}

/// Idle task that waits for interrupts endlessly.
fn idleTask() noreturn {
    while (true) {
        arch.enableIrq();
        arch.halt();
    }
}

/// Print the list of threads in the run queue of this CPU.
///
/// - `logger`: Logging function.
pub fn debugPrintRunQueue(logger: anytype) void {
    const queue: *ThreadList = getRunQueue();
    var node: ?*Thread = queue.first;
    while (node) |th| {
        logger("{d: >3}: {s}", .{ th.tid, th.name });
        node = th.list_head.next;
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.sched);

const norn = @import("norn.zig");
const arch = norn.arch;
const mem = norn.mem;
const pcpu = norn.pcpu;
const timer = norn.timer;
const thread = norn.thread;
const Thread = thread.Thread;
const ThreadList = thread.ThreadList;

const general_allocator = mem.general_allocator;
