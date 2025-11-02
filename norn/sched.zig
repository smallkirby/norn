/// Error.
pub const SchedError = arch.ArchError || mem.MemError || thread.ThreadError;

/// Wait queue type.
///
/// Threads waiting for an specific event are managed in a wait queue.
/// Scheduler does not manage the wait queue.
/// Each subsystem must manage their own wait queue and wake up threads when the event occurs.
pub const WaitQueue = ThreadList;

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
/// Idle task.
var idle_task: *Thread linksection(pcpu.section) = undefined;
/// Counter for preemption disable calls.
///
/// While this counter is greater than zero, preemption is disabled.
var preempt_count: *PreemptCounter linksection(pcpu.section) = undefined;

/// Preemption counter type.
const PreemptCounter = std.atomic.Value(usize);

/// Initialize the scheduler for this CPU.
///
/// Note that the timer that triggers the scheduler does not start yet.
pub fn localInit() SchedError!void {
    // Initialize the run queue
    const rq = try general_allocator.create(ThreadList);
    rq.* = .{};
    pcpu.set(&runq, rq);
    pcpu.set(&is_initialized, true);

    // Initialize preemption counter.
    const counter = try general_allocator.create(PreemptCounter);
    counter.* = .init(1);
    pcpu.set(&preempt_count, counter);
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
    init.state = .running;
    pcpu.set(&current_task, init);
    pcpu.set(&idle_task, init);

    norn.arch.task.initialSwitchTo(init);
}

/// Allow the timer interrupt to schedule the next task.
pub fn unlock() void {
    norn.rtt.expect(!pcpu.get(&unlocked));
    pcpu.set(&unlocked, true);
}

/// Schedule the next task.
pub fn schedule() void {
    // Check if scheduling is allowed.
    if (!pcpu.get(&unlocked)) {
        @branchHint(.unlikely);
        return;
    }

    // Disable preemption during scheduling.
    // The counter is decremented in the context switch handler.
    if (!startSched()) {
        @branchHint(.unlikely);
        return;
    }

    const rq: *ThreadList = getRunQueue();
    const cur: *Thread = getCurrentTask();

    // Find the next task to run.
    const next: *Thread = rq.popFirst() orelse blk: {
        // No task to run. Run the idle task.
        break :blk pcpu.get(&idle_task);
    };
    if (next.tid == 0 and cur.tid == 0) {
        enablePreemption();
        return;
    }
    norn.rtt.expectEqual(.ready, next.state);

    // Update the current task.
    switch (cur.state) {
        .blocked => {
            // Managed in the wait queue.
        },
        .running => {
            // Insert the current task into the tail of the queue.
            if (cur.tid != 0) {
                rq.append(cur);
            } else {
                @branchHint(.cold);
            }
        },
        .dead => {
            // TODO: Destroy the task.
            norn.unimplemented("Destroy the task.");
        },
        else => {
            log.err(
                "Unexpected current task state (TID={d}): {s}",
                .{ cur.tid, @tagName(cur.state) },
            );
            @panic("Scheduler panic.");
        },
    }
    pcpu.set(&current_task, next);

    if (@import("option").debug_sched) {
        log.debug("Switching task: {d} -> {d}", .{ cur.tid, next.tid });
    }

    // Switch the context.
    cur.state = if (cur.state == .running) .ready else cur.state;
    next.state = .running;
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
    task.state = .ready;
    getRunQueue().append(task);
}

/// Block the current task and wait on the specified wait queue.
pub fn waitOn(queue: *WaitQueue, task: *Thread) void {
    task.state = .blocked;
    queue.append(task);

    schedule();
}

/// Wake up a task waiting on the specified wait queue.
pub fn wakeup(queue: *WaitQueue) void {
    const task = queue.popFirst() orelse return;
    task.state = .ready;

    enqueueTask(task);
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

/// Disable preemption.
pub fn disablePreemption() void {
    _ = pcpu.get(&preempt_count).fetchAdd(1, .release);
}

/// Enable preemption.
pub fn enablePreemption() void {
    const prev = pcpu.get(&preempt_count).fetchSub(1, .acquire);
    norn.rtt.expect(prev != 0);
}

/// Check if preemption is enabled.
pub fn isPreemptionEnabled() bool {
    return pcpu.get(&preempt_count).load(.acquire) == 0;
}

/// Check if we can start scheduling, then decrease the preemption counter.
fn startSched() bool {
    const counter: *PreemptCounter = pcpu.get(&preempt_count);
    const prev = counter.fetchAdd(1, .acquire);
    if (prev != 0) {
        _ = counter.fetchSub(1, .release);
        return false;
    }

    return true;
}

/// Check if the current task needs to be rescheduled.
pub fn needReschedule() bool {
    if (!isInitialized()) {
        return false;
    }

    const need_resched = getCurrentTask().flags.need_resched;
    const preempt_allowed = pcpu.get(&preempt_count).load(.acquire) == 0;

    return need_resched and preempt_allowed;
}

/// Set the current task to need rescheduling.
pub fn setNeedReschedule() void {
    getCurrentTask().flags.need_resched = true;
}

// =============================================================
// Debug
// =============================================================

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
