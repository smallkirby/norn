const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn.zig");
const arch = norn.arch;
const mem = norn.mem;

const page_allocator = mem.page_allocator;
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
    /// Maximum length of the thread name.
    const name_max_len: usize = 16;

    /// Thread ID.
    tid: Tid,
    /// Stack.
    stack: []u8,
    /// Stack pointer.
    stack_ptr: [*]u8,
    /// Thread state.
    state: State = .running,
    /// Thread name with null-termination.
    name: [name_max_len:0]u8 = undefined,

    /// Create a new thread.
    fn create(
        name: []const u8,
        allocator: Allocator,
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
        truncCopyName(&self.name, name);

        return self;
    }

    /// Destroy the thread.
    fn destroy(self: *Thread, allocator: Allocator) void {
        page_allocator.freePages(self.stack);
        allocator.destroy(self);
    }

    /// Copy the thread name to the output buffer.
    /// The name is truncated if it exceeds the maximum length.
    /// The output buffer is null-terminated.
    inline fn truncCopyName(out: *[name_max_len:0]u8, in: []const u8) void {
        const length = @min(in.len, name_max_len);
        @memcpy(out[0..length], in[0..length]);
        out[length] = 0;
    }

    /// Get the thread name.
    pub fn getName(self: *Thread) []const u8 {
        for (0..name_max_len) |i| {
            if (self.name[i] == 0) return self.name[0..i];
        } else return &self.name;
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
    name: []const u8,
    entry: KernelThreadEntry,
    allocator: Allocator,
) Error!*Thread {
    const thread = try Thread.create(name, allocator);
    thread.stack_ptr = arch.task.initOrphanFrame(thread.stack_ptr, @intFromPtr(entry));

    return thread;
}
