//! Arch-independent thread structure.
//!
//! This filed provides a thread structure and related functions,
//! that are independent from the specific architecture.

const norn = @import("norn");
const arch = norn.arch;
const loader = norn.loader;
const mem = norn.mem;
const InlineDoublyLinkedList = norn.InlineDoublyLinkedList;

const page_allocator = mem.page_allocator;
const general_allocator = mem.general_allocator;

/// Error.
pub const Error =
    arch.Error ||
    loader.Error ||
    mem.Error;

/// Type of thread ID.
pub const Tid = usize;
/// Entry point of kernel thread.
pub const KernelThreadEntry = *const fn () noreturn;

/// Type representing a linked list of threads.
pub const ThreadList = InlineDoublyLinkedList(Thread, "list_head");

/// Thread state.
pub const State = enum {
    /// Thread is running.
    running,
    /// Thread has finished execution and is waiting to be destroyed.
    dead,
};

/// CPU time consumed for the thread.
pub const CpuTime = struct {
    /// CPU time consumed in user mode.
    user: u64 = 0,
    /// CPU time consumed in kernel mode.
    kernel: u64 = 0,
    /// Time when the thread was last executed in user mode.
    user_last_start: ?u64 = null,
    /// Time when the thread was last executed in kernel mode.
    kernel_last_kernel: ?u64 = null,

    /// Update to record the time when the thread enters user mode.
    pub fn updateEnterUser(self: *CpuTime, now: u64) void {
        self.user_last_start = now;
    }

    /// Update to record the time when the thread exits user mode.
    pub fn updateExitUser(self: *CpuTime, now: u64) void {
        if (self.user_last_start) |last_start| {
            self.user += now - last_start;
        }
    }
};

/// Default stack size of a kernel thread.
const default_stack_size: usize = 1 * mem.size_4kib;
/// Default number of pages for kernel stack.
const default_stack_pgnum: usize = @divFloor(default_stack_size - 1, mem.size_4kib) + 1;

/// Next thread ID.
var tid_next: Tid = 0;

/// Execution context and resources.
pub const Thread = struct {
    /// Maximum length of the thread name.
    const name_max_len: usize = 16;

    /// Thread ID.
    tid: Tid,
    /// Kernel stack.
    stack: []u8 = undefined,
    /// Kernel stack pointer.
    stack_ptr: [*]u8 = undefined,
    /// Thread state.
    state: State = .running,
    /// Thread name with null-termination.
    name: [name_max_len:0]u8 = undefined,
    /// CR3 of the user space.
    pgtbl: mem.Virt = undefined,
    /// CPU time consumed for the thread.
    cpu_time: CpuTime = .{},
    /// Arch-specific context.
    arch_ctx: *anyopaque = undefined,

    /// User stack pointer.
    user_stack_ptr: ?mem.Virt = null, // TODO
    /// User IP.
    user_ip: ?mem.Virt = null, // TODO

    /// Linked list of threads.
    list_head: ThreadList.Head = .{},

    /// Create a new thread.
    ///
    /// - `name`: Name of the thread.
    fn create(name: []const u8) Error!*Thread {
        const self = try general_allocator.create(Thread);
        errdefer general_allocator.destroy(self);
        self.* = Thread{
            .tid = assignNewTid(),
        };

        // Initialize arch-specific context.
        try arch.task.setupNewTask(self);

        // Initialize thread name.
        truncCopyName(&self.name, name);

        return self;
    }

    /// Destroy the thread.
    fn destroy(self: *Thread) void {
        page_allocator.freePages(self.stack);
        general_allocator.destroy(self);
    }

    /// Copy the thread name to the output buffer.
    ///
    /// The name is truncated if it exceeds the maximum length.
    /// The output buffer is null-terminated.
    ///
    /// - `out`: Buffer to copy the name.
    /// - `in` : Name to copy.
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

/// Consume TID pool to allocate a new unique TID.
fn assignNewTid() Tid {
    const tid = tid_next;
    tid_next +%= 1;
    return tid;
}

/// Create a new kernel thread.
///
/// - `name` : Name of the kernel thread.
/// - `entry`: Entry point of the kernel thread.
pub fn createKernelThread(name: []const u8, entry: KernelThreadEntry) Error!*Thread {
    const thread = try Thread.create(name);
    thread.stack_ptr = arch.task.initOrphanFrame(thread.stack_ptr, @intFromPtr(entry));

    return thread;
}

/// Create a initial thread (PID 1).
///
/// TODO: This function now has many hardcoded code for debug.
/// TODO: Read init from FS and parse it.
pub fn createInitialThread(comptime filename: []const u8) Error!*Thread {
    const thread = try Thread.create("init");

    // Copy initial user function for debug.
    var elf_loader = try loader.ElfLoader.new(filename, thread.pgtbl);
    try elf_loader.load();

    // Create user stack.
    const stack_page = try norn.mem.page_allocator.allocPages(1, .normal);
    @memset(stack_page, 0);

    // Map stack.
    const stack_base = 0x200000;
    const stack_size = 0x1000;
    try arch.mem.map(
        thread.pgtbl,
        stack_base,
        mem.virt2phys(stack_page.ptr),
        stack_size,
        .read_write,
    );

    thread.stack_ptr = arch.task.initOrphanFrame(
        thread.stack_ptr,
        @intFromPtr(&norn.init.initialTask),
    );
    thread.user_ip = elf_loader.entry_point;
    thread.user_stack_ptr = stack_base + stack_size - 0x10;

    return thread;
}
