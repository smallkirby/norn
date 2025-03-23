//! Arch-independent thread structure.
//!
//! This filed provides a thread structure and related functions,
//! that are independent from the specific architecture.

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
    kernel_last_start: ?u64 = null,

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
pub const kernel_stack_size: usize = 2 * mem.size_4kib;
/// Default number of pages for kernel stack.
const kernel_stack_pgnum: usize = @divFloor(kernel_stack_size - 1, mem.size_4kib) + 1;

comptime {
    norn.comptimeAssert(kernel_stack_pgnum == 2, "kernel_stack_pgnum must be 2");
}

/// Next thread ID.
var tid_next: Tid = 0;
/// Spin lock for thread module.
var thread_lock = SpinLock{};

/// Execution context and resources.
pub const Thread = struct {
    /// Maximum length of the thread name.
    const name_max_len: usize = 16;

    /// Thread ID.
    tid: Tid,
    /// Kernel stack top.
    kernel_stack: []u8 = undefined,
    /// Kernel stack pointer.
    kernel_stack_ptr: [*]u8 = undefined,
    /// User stack top.
    user_stack: []u8 = undefined,
    /// Thread state.
    state: State = .running,
    /// Thread name with null-termination.
    name: [name_max_len:0]u8 = undefined,
    /// Command line.
    comm: []const u8 = undefined,
    /// Memory map.
    mm: *MemoryMap,
    /// CPU time consumed for the thread.
    cpu_time: CpuTime = .{},
    /// Arch-specific context.
    arch_ctx: *anyopaque = undefined,

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
            .mm = try MemoryMap.new(),
        };

        // Initialize arch-specific context.
        try arch.task.setupNewTask(self);

        // Initialize thread name.
        truncCopyName(&self.name, name);

        return self;
    }

    /// Destroy the thread.
    fn destroy(self: *Thread) void {
        page_allocator.freePages(self.kernel_stack);
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
    const ie = thread_lock.lockDisableIrq();
    defer thread_lock.unlockRestoreIrq(ie);

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
    arch.task.initKernelStack(thread, @intFromPtr(entry));

    return thread;
}

/// Create a initial thread (PID 1).
///
/// TODO: This function now has many hardcoded code for debug.
/// TODO: Read init from FS and parse it.
pub fn createInitialThread(comptime filename: []const u8) Error!*Thread {
    const thread = try Thread.create("init");
    thread.comm = try general_allocator.dupe(u8, filename);

    // Copy initial user function for debug.
    var elf_loader = try loader.ElfLoader.new(filename);
    try elf_loader.load(thread.mm);

    // Create user stack.
    const stack_page = try page_allocator.allocPages(1, .normal);
    @memset(stack_page, 0);

    // Map stack.
    const stack_base = 0x200000;
    const stack_size = 0x1000 * 20;
    const stack_vma = try thread.mm.map(stack_base, stack_size, .rw);
    thread.mm.vm_areas.append(stack_vma);

    arch.task.initKernelStack(thread, @intFromPtr(&norn.init.initialTask));

    // Initialize user stack.
    const stack: []u8 = @constCast(stack_vma.slice());
    var sc = StackCreator.new(stack) catch @panic("StackCreator.new");
    sc.push(@as(u64, 0)); // padding for alignment
    sc.push(@as(u64, 0)); // end marker
    sc.push(@as(u128, 0x0123_4567_89AB_CDEF_1122_3344_5566_7788)); // Random value for AT_RANDOM
    sc.push(AuxVector.new(.terminator, 0)); // AT_NULL (auxvec)
    sc.push(AuxVector.new(.random, stack_base + stack_size - 0x20)); // AT_RANDOM (auxvec)
    sc.push(@as(u64, 0)); // NULL (envp)
    sc.push(@as(u64, 0)); // NULL (argv)
    sc.push(@as(u64, 0)); // argc

    // Set up user stack.
    arch.task.setupUserContext(
        thread,
        elf_loader.entry_point,
        stack_base + stack_size - sc.size(),
    );

    return thread;
}

/// Construct stack frame in the given area.
const StackCreator = struct {
    const Self = @This();

    /// Upper limit of the stack.
    _stack_top: [*]u8,
    /// Bottom of the stack.
    _stack_bottom: [*]u8,
    /// Stack pointer.
    _sp: [*]u8,

    /// Instantiate a new stack creator.
    ///
    /// Cursor is set to the bottom of the stack.
    pub fn new(stack: []u8) !StackCreator {
        if (@intFromPtr(stack.ptr) % 8 != 0) return error.InvalidStack;

        return .{
            ._stack_top = @ptrCast(stack.ptr),
            ._stack_bottom = @ptrFromInt(@intFromPtr(stack.ptr) + stack.len),
            ._sp = @ptrFromInt(@intFromPtr(stack.ptr) + stack.len),
        };
    }

    /// Push a value to the stack.
    ///
    /// The size of value must be 8-byte aligned.
    pub fn push(self: *Self, comptime value: anytype) void {
        const T = @TypeOf(value);

        const value_size = @sizeOf(T);
        comptime norn.comptimeAssert(
            value_size != 0,
            "StackCreator does not support zero-sized type",
        );
        comptime norn.comptimeAssert(
            value_size % 8 == 0,
            "StackCreator only supports 64-bit aligned types",
        );

        if (util.ptrLte(self._sp + value_size, self._stack_top)) {
            @panic("StackCreator overflow");
        }
        self._sp -= value_size;

        const ptr: *T = @alignCast(@ptrCast(self._sp));
        ptr.* = value;
    }

    /// Get the total size of the pushed values on the stack.
    pub fn size(self: *Self) usize {
        return self._stack_bottom - self._sp;
    }
};

/// Auxiliary vector for passing information to the program.
const AuxVector = packed struct(u128) {
    /// Type of the entry.
    auxv_type: AuxvType,
    /// Value of the entry.
    value: u64,

    const AuxvType = enum(u64) {
        terminator = 0,
        ignore = 1,
        execfd = 2,
        phdr = 3,
        phent = 4,
        phnum = 5,
        pagesz = 6,
        base = 7,
        flags = 8,
        entry = 9,
        notelf = 10,
        uid = 11,
        euid = 12,
        gid = 13,
        egid = 14,
        platform = 15,
        hwcap = 16,
        clktck = 17,
        fpucw = 18,
        dcachebsize = 19,
        icachebsize = 20,
        ucachebsize = 21,
        ignorepc = 22,
        secure = 23,
        base_platform = 24,
        random = 25,

        sysinfo = 32,
        sysinfo_ehdr = 33,
    };

    pub fn new(auxv_type: AuxvType, value: u64) AuxVector {
        return .{
            .auxv_type = auxv_type,
            .value = value,
        };
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const arch = norn.arch;
const loader = norn.loader;
const mem = norn.mem;
const util = norn.util;
const InlineDoublyLinkedList = norn.InlineDoublyLinkedList;
const MemoryMap = norn.mm.MemoryMap;
const SpinLock = norn.SpinLock;

const page_allocator = mem.page_allocator;
const general_allocator = mem.general_allocator;
