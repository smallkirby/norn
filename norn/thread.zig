const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn.zig");
const arch = norn.arch;
const mem = norn.mem;

const PageAllocator = mem.PageAllocator;

pub const Error = error{} || PageAllocator.Error;

/// Thread ID type.
pub const Tid = usize;
/// Entry point of kernel thread.
pub const KernelThreadEntry = *const fn () noreturn;

/// Default stack size of a thread.
const default_stack_size: usize = 1 * mem.size_4kib;
/// Default number of pages for the stack.
const default_stack_pgnum: usize = @divFloor(default_stack_size - 1, mem.size_4kib) + 1;

/// Next thread ID.
var tid_next: Tid = 0;

/// Thread state.
pub const State = enum {
    /// Thread is running.
    running,
    /// Thread has finished execution and is waiting to be destroyed.
    dead,
};

/// Execution context.
pub const Thread = struct {
    /// Thread ID.
    tid: Tid,
    /// Stack.
    stack: []u8,
    /// Stack pointer.
    stack_ptr: [*]u8,
    /// Thread state.
    state: State = .running,

    /// Create a new thread.
    fn create(
        allocator: Allocator,
        page_allocator: PageAllocator,
    ) Error!*Thread {
        const self = try allocator.create(Thread);
        errdefer allocator.destroy(self);

        const stack = try page_allocator.allocPages(default_stack_pgnum, .normal);
        errdefer page_allocator.freePages(stack);
        const stack_ptr = stack.ptr + stack.len - 0x10;

        self.* = Thread{
            .tid = assignNewTid(),
            .stack = stack,
            .stack_ptr = stack_ptr,
        };
        return self;
    }

    /// Destroy the thread.
    fn destroy(self: *Thread, allocator: Allocator, page_allocator: PageAllocator) void {
        page_allocator.freePages(self.stack);
        allocator.destroy(self);
    }
};

/// Assign new unique TID.
fn assignNewTid() Tid {
    const tid = tid_next;
    tid_next +%= 1;
    return tid;
}

/// Create a new kernel thread.
pub fn createKernelThread(
    entry: KernelThreadEntry,
    allocator: Allocator,
    page_allocator: PageAllocator,
) Error!*Thread {
    const thread = try Thread.create(allocator, page_allocator);
    thread.stack_ptr = arch.task.initOrphanFrame(thread.stack_ptr, @intFromPtr(entry));

    return thread;
}
