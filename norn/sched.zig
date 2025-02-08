const std = @import("std");
const log = std.log.scoped(.sched);
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

const norn = @import("norn.zig");
const arch = norn.arch;
const mem = norn.mem;
const pcpu = norn.pcpu;
const SpinLock = norn.SpinLock;
const thread = norn.thread;
const Thread = thread.Thread;

const page_allocator = mem.page_allocator;
const PageAllocator = mem.PageAllocator;

pub const Error = error{} || mem.Error;

/// List of tasks.
const TaskList = DoublyLinkedList(*Thread);
/// Node of a queued task.
const QueuedTask = TaskList.Node;

/// Run queue of this CPU.
var runq: RunQueue linksection(pcpu.section) = undefined;
/// Task running now on this CPU.
var current_task: *QueuedTask linksection(pcpu.section) = undefined;

/// Run queue that manages tasks waiting for execution.
const RunQueue = struct {
    /// List of tasks.
    list: *TaskList,

    /// Create a new run queue.
    fn new(allocator: Allocator) Error!RunQueue {
        const list = try allocator.create(TaskList);
        list.* = TaskList{};

        return .{
            .list = list,
        };
    }
};

/// Initialize the scheduler for this CPU.
pub fn initThisCpu(allocator: Allocator) Error!void {
    // Initialize the run queue
    pcpu.thisCpuGet(&runq).* = try RunQueue.new(allocator);

    // Initialize the idle task
    try setupIdleTask(allocator);
}

/// Run the task scheduler on this CPU.
pub fn runThisCpu() noreturn {
    norn.arch.task.initialSwitchTo(pcpu.thisCpuGet(&current_task).*.data);
}

/// Schedule the next task.
pub fn schedule() void {
    arch.disableIrq();
    arch.getLocalApic().eoi();

    const queue = pcpu.thisCpuGet(&runq);
    const cur_node = pcpu.thisCpuGet(&current_task).*;

    // Find the next task to run.
    const next_node = if (queue.list.first) |first| first else {
        // No task to run.
        norn.rtt.expect(cur_node.data.tid == 0); // must be idle task

        if (norn.is_runtime_test) {
            log.info("No task to run. Terminating QEMU...", .{});
            norn.terminateQemu(0);
            @panic("Reached unreachable Norn EOL.");
        }

        arch.enableIrq();
        return;
    };
    const next_task: *Thread = next_node.data;

    // Remove the next task from the queue.
    queue.list.remove(next_node);

    // Update the current task.
    switch (cur_node.data.state) {
        .running => {
            // Insert the current task into the tail of the queue.
            queue.list.append(cur_node);
        },
        .dead => {
            // TODO: Destroy the task.
        },
    }
    pcpu.thisCpuGet(&current_task).* = next_node;

    // Switch the context.
    norn.arch.task.switchTo(cur_node.data, next_task);
}

/// Enqueue a task to the run queue.
pub fn enqueue(task: *Thread, allocator: Allocator) Error!void {
    const queue = pcpu.thisCpuGet(&runq);
    const node = try allocator.create(QueuedTask);
    node.* = QueuedTask{ .data = task };
    queue.list.append(node);
}

/// Setup the idle task and set the current task to it.
fn setupIdleTask(allocator: Allocator) Error!void {
    const idle_task = try thread.createKernelThread("[idle]", idleTask, allocator);
    const idle_node = try allocator.create(QueuedTask);
    idle_node.* = QueuedTask{ .data = idle_task };
    pcpu.thisCpuGet(&current_task).* = idle_node;

    const taskA = try thread.createKernelThread("threadA", debugTmpThreadA, allocator);
    const taskB = try thread.createKernelThread("threadB", debugTmpThreadB, allocator);
    try enqueue(taskA, allocator);
    try enqueue(taskB, allocator);
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
    const queue = pcpu.thisCpuGet(&runq);
    var node: ?*QueuedTask = queue.list.first;
    while (node) |n| {
        logger("{d: >3}: {s}", .{ n.data.tid, n.data.getName() });
        node = n.next;
    }
}

/// Example thread for debugging.
/// TODO remove this.
fn debugTmpThreadA() noreturn {
    arch.enableIrq();

    log.debug("Thread A1", .{});
    norn.acpi.spinForUsec(1000 * 1000) catch unreachable;
    log.debug("Thread A2", .{});

    const current = pcpu.thisCpuGet(&current_task).*;
    current.data.state = .dead;
    schedule();
    unreachable;
}

/// Example thread for debugging.
/// TODO remove this.
fn debugTmpThreadB() noreturn {
    arch.enableIrq();
    log.debug("Thread B", .{});

    const current = pcpu.thisCpuGet(&current_task).*;
    current.data.state = .dead;
    schedule();
    unreachable;
}
