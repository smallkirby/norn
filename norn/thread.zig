//! Arch-independent thread structure.
//!
//! This filed provides a thread structure and related functions,
//! that are independent from the specific architecture.

/// Error.
pub const ThreadError = arch.ArchError || loader.LoaderError || mem.MemError;

/// Type of thread ID.
pub const Tid = usize;

/// Type representing a linked list of threads.
pub const ThreadList = InlineDoublyLinkedList(Thread, "list_head");

/// Thread state.
pub const State = enum {
    /// Can be scheduled.
    ready,
    /// Thread is running.
    running,
    /// Waiting for an event.
    blocked,
    /// Thread has finished execution and is waiting to be destroyed.
    dead,
};

/// Next thread ID.
var tid_next: Tid = 0;
/// Spin lock for thread module.
var thread_lock = SpinLock{};

/// User ID type.
pub const Uid = u32;
/// Group ID type.
pub const Gid = u32;

/// Credential for the thread.
pub const Credential = struct {
    /// User ID.
    uid: Uid,
    /// Group ID.
    gid: Gid,

    /// Root user.
    const root = Credential{ .uid = 0, .gid = 0 };
};

/// Execution context and resources.
pub const Thread = struct {
    const Self = @This();

    /// Size in bytes of kernel stack.
    const kstack_size = 3 * mem.size_4kib;
    /// Number of pages for kernel stack.
    const kstack_num_pages = kstack_size / mem.size_4kib;

    /// Thread flags.
    pub const Flags = struct {
        /// This thread needs to be rescheduled.
        need_resched: bool = false,
        /// In IRQ context.
        in_irq: std.atomic.Value(bool) = .init(false),
        /// How many times preemption is disabled.
        preempt_count: std.atomic.Value(u8) = .init(0),
    };

    /// Thread ID.
    tid: Tid,
    /// Thread flags.
    flags: Flags = .{},
    /// Kernel stack top.
    ///
    /// Set to RSP0 for interrupts while in user-mode and syscalls.
    kstack: []u8 = undefined,
    /// Kernel stack pointer.
    ///
    /// Used to track the kernel stack top among context switches.
    ksp: u64 = undefined,
    /// User stack top.
    user_stack: []u8 = undefined,
    /// Thread state.
    state: State = .running,
    /// Thread name.
    name: []const u8,
    /// Command line.
    comm: ?[]const u8 = null,
    /// Memory map.
    mm: *MemoryMap,
    /// Thread credential.
    cred: Credential = .root,
    /// FS.
    fs: fs.ThreadFs,
    /// Arch-specific context.
    arch_ctx: *anyopaque = undefined,

    /// Linked list of threads.
    list_head: ThreadList.Head = .{},

    /// Create a new thread.
    ///
    /// - `name`: Name of the thread.
    /// - `kentry`: Entry point of kernel thread.
    /// - `args`: Arguments for `kentry`.
    fn create(name: []const u8, comptime kentry: anytype, args: anytype) ThreadError!*Thread {
        const self = try allocator.create(Thread);
        errdefer allocator.destroy(self);
        self.* = Thread{
            .tid = assignNewTid(),
            .mm = try MemoryMap.new(),
            .fs = fs.ThreadFs.new(undefined, undefined, allocator), // TODO
            .name = try allocator.dupe(u8, name),
        };

        // Set kernel thread entry point.
        const ArgType = @TypeOf(args);
        const ThreadInstance = struct {
            /// Trampoline function for kernel thread entry point.
            fn entryKernelThread(raw_args: ?*anyopaque) callconv(.c) void {
                const args_ptr: *ArgType = @ptrCast(@alignCast(raw_args));
                defer allocator.destroy(args_ptr);
                callThreadFunction(kentry, args_ptr.*);
            }
        };
        const args_ptr = try allocator.create(ArgType);
        args_ptr.* = args;
        errdefer allocator.destroy(args_ptr);

        // Create kernel stack.
        const kstack = try mem.vm_allocator.virtualAlloc(kstack_size, .before);
        errdefer mem.vm_allocator.virtualFree(kstack);
        self.kstack = kstack;

        // Initialize arch-specific context.
        try arch.task.setupNewTask(
            self,
            @intFromPtr(&ThreadInstance.entryKernelThread),
            args_ptr,
        );

        return self;
    }

    /// Destroy the thread.
    fn destroy(self: *Thread) void {
        page_allocator.freePages(self.kernel_stack);
        allocator.destroy(self);
    }

    /// Set command string.
    fn setComm(self: *Self, comm: []const u8) error{OutOfMemory}!void {
        if (self.comm) |old| {
            // If the com is already set, assign new one and then free the old one.
            self.comm = try allocator.dupe(u8, comm);
            allocator.free(old);
        } else {
            self.comm = try allocator.dupe(u8, comm);
        }
    }

    /// Set entry point and stack for user thread.
    fn setUserContext(self: *Self, rip: u64, rsp: u64) void {
        arch.task.setUserContext(self, rip, rsp);
    }

    /// Call a function with the given anytype argument.
    fn callThreadFunction(comptime f: anytype, args: anytype) void {
        switch (@typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?)) {
            .void, .noreturn => {
                @call(.auto, f, args);
            },
            .error_union => |info| {
                switch (info.payload) {
                    void, noreturn => {
                        @call(.never_inline, f, args) catch |err| {
                            std.log.scoped(.thread).err(
                                "Thread returned error: {s}",
                                .{@errorName(err)},
                            );
                            @panic("Panic.");
                        };
                    },
                    else => @compileError("Kernel thread function cannot return value."),
                }
            },
            else => @compileError("Kernel thread function cannot return value."),
        }
    }

    /// Get bottom address of the kernel stack.
    pub fn kstackBottom(self: *const Self) u64 {
        return @intFromPtr(self.kstack.ptr) + kstack_size;
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
/// - `args`: Arguments for `entry`.
pub fn createKernelThread(comptime name: []const u8, comptime entry: anytype, args: anytype) ThreadError!*Thread {
    return Thread.create(name, entry, args);
}

/// Create a initial thread (PID 1).
///
/// TODO: This function now has many hardcoded code for debug.
pub fn createInitialThread(args: [][]const u8) ThreadError!*Thread {
    const thread = try Thread.create(
        "init",
        norn.init.initialTask,
        .{},
    );
    try thread.setComm(args[0]);

    // Setup FS.
    const current = sched.getCurrentTask();
    thread.fs.root = current.fs.root;
    thread.fs.cwd = current.fs.cwd;

    // Open stdin, stdout, and stderr.
    {
        const open_flags_rw: fs.OpenFlags = .{
            .mode = .read_write,
        };
        const open_flags_ro: fs.OpenFlags = .{
            .mode = .read_only,
        };
        const stdin = try thread.fs.fdtable.put(try fs.openFile("/dev/tty", open_flags_ro, null));
        const stdout = try thread.fs.fdtable.put(try fs.openFile("/dev/tty", open_flags_rw, null));
        const stderr = try thread.fs.fdtable.put(try fs.openFile("/dev/tty", open_flags_rw, null));

        norn.rtt.expectEqual(0, stdin.value());
        norn.rtt.expectEqual(1, stdout.value());
        norn.rtt.expectEqual(2, stderr.value());
    }

    // Copy initial user function for debug.
    var elf_loader = try loader.ElfLoader.new(args[0]);
    try elf_loader.load(thread.mm);

    // Create user stack.
    const stack_page = try page_allocator.allocPages(1, .normal);
    @memset(stack_page, 0);

    // Map stack.
    const stack_base = 0x7FFFFF000000;
    const stack_size = 0x1000 * 20;
    const stack_vma = try thread.mm.map(stack_base, stack_size, .rw);
    thread.mm.vm_areas.append(stack_vma);

    // Initialize user stack.
    const stack_top = blk: {
        var sc = StackCreator.new(
            stack_vma,
            allocator,
        ) catch @panic("StackCreator.new");
        try sc.appendArgvs(args);
        const at_random_handle = try sc.appendOpaqueData(u128, 0x0123_4567_89AB_CDEF_1122_3344_5566_7788);
        try sc.appendAuxvWithHandle(StackCreator.AuxVector.new(.random, at_random_handle));

        break :blk try sc.finalize();
    };
    norn.rtt.expectEqual(0, stack_top % 16);

    // Set up user stack.
    thread.setUserContext(elf_loader.entry_point, stack_top);

    return thread;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const options = @import("option");

const norn = @import("norn");
const arch = norn.arch;
const fs = norn.fs;
const loader = norn.loader;
const mem = norn.mem;
const sched = norn.sched;
const InlineDoublyLinkedList = norn.typing.InlineDoublyLinkedList;
const MemoryMap = norn.mm.MemoryMap;
const SpinLock = norn.SpinLock;
const StackCreator = norn.StackCreator;

const page_allocator = mem.page_allocator;
const allocator = mem.general_allocator;
