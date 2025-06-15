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
    /// Thread name.
    name: []const u8,
    /// Command line.
    comm: ?[]const u8 = null,
    /// Memory map.
    mm: *MemoryMap,
    /// CPU time consumed for the thread.
    cpu_time: CpuTime = .{},
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
        const self = try general_allocator.create(Thread);
        errdefer general_allocator.destroy(self);
        self.* = Thread{
            .tid = assignNewTid(),
            .mm = try MemoryMap.new(),
            .fs = fs.ThreadFs.new(undefined, undefined), // TODO
            .name = try general_allocator.dupe(u8, name),
        };

        // Set kernel thread entry point.
        const ArgType = @TypeOf(args);
        const ThreadInstance = struct {
            /// Trampoline function for kernel thread entry point.
            fn entryKernelThread(raw_args: ?*anyopaque) callconv(.c) void {
                const args_ptr: *ArgType = @ptrCast(@alignCast(raw_args));
                defer general_allocator.destroy(args_ptr);
                callThreadFunction(kentry, args_ptr.*);
            }
        };
        const args_ptr = try general_allocator.create(ArgType);
        args_ptr.* = args;
        errdefer general_allocator.destroy(args_ptr);

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
        general_allocator.destroy(self);
    }

    /// Set command string.
    fn setComm(self: *Self, comm: []const u8) error{OutOfMemory}!void {
        if (self.comm) |old| {
            // If the com is already set, assign new one and then free the old one.
            self.comm = try general_allocator.dupe(u8, comm);
            general_allocator.free(old);
        } else {
            self.comm = try general_allocator.dupe(u8, comm);
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
pub fn createInitialThread(comptime filename: []const u8) ThreadError!*Thread {
    const thread = try Thread.create(
        "init",
        norn.init.initialTask,
        .{},
    );
    try thread.setComm(filename);

    // Setup FS.
    const current = sched.getCurrentTask();
    thread.fs.root = current.fs.root;
    thread.fs.cwd = current.fs.cwd;

    // Copy initial user function for debug.
    var elf_loader = try loader.ElfLoader.new(filename);
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
        var sc = StackCreator.new(stack_vma) catch @panic("StackCreator.new");
        try sc.appendArgvs(&.{ filename, "ls", "-la" });
        const at_random_handle = try sc.appendOpaqueData(u128, 0x0123_4567_89AB_CDEF_1122_3344_5566_7788);
        try sc.appendAuxvWithHandle(AuxVector.new(.random, at_random_handle));

        break :blk try sc.finalize();
    };

    // Set up user stack.
    thread.setUserContext(elf_loader.entry_point, stack_top);

    return thread;
}

/// Construct stack frame in the given area.
///
/// You build a stack by calling these APIS.
/// Until you call `finalize()`, the stack is not touched.
const StackCreator = struct {
    const Self = @This();

    /// User stack.
    _stack: Stack,
    /// argv
    _argvs: ArgvList,
    /// envp
    _envps: EnvpList,
    /// auxv with immediate value.
    _imm_auxvs: AuxVectorList,
    /// auxv with opaque data.
    _handle_auxvs: AuxVectorList,
    /// Opaque data.
    _opaque_data: OpaqueList,

    /// argv type.
    const Argv = []const u8;
    /// argv list type.
    const ArgvList = ArrayList(Argv);
    /// envp type.
    const Envp = []const u8;
    /// envp list type.
    const EnvpList = ArrayList(Envp);
    /// auxv list type.
    const AuxVectorList = ArrayList(AuxVector);
    /// Opaque data type.
    const OpaqueType = struct {
        data: []const u8,
        handle: StackOpaqueHandler,
        pointer: u64 = undefined,
    };
    /// Opaque data list type.
    const OpaqueList = ArrayList(OpaqueType);

    /// Stack alignment in bytes.
    const alignment = 16;

    /// Instantiate a new stack creator.
    ///
    /// Cursor is set to the bottom of the stack.
    pub fn new(stack_vma: *const Vma) !StackCreator {
        return .{
            ._stack = try Stack.new(stack_vma),
            ._argvs = ArgvList.init(general_allocator),
            ._envps = EnvpList.init(general_allocator),
            ._imm_auxvs = AuxVectorList.init(general_allocator),
            ._handle_auxvs = AuxVectorList.init(general_allocator),
            ._opaque_data = OpaqueList.init(general_allocator),
        };
    }

    /// Append an argv.
    ///
    /// The argument `argv` must not be freed until you call `finalize()`.
    pub fn appendArgv(self: *Self, argv: []const u8) !void {
        try self._argvs.append(argv);
    }

    /// Append argvs.
    ///
    /// The argument `argvs` must not be freed until you call `finalize()`.
    pub fn appendArgvs(self: *Self, argvs: []const []const u8) !void {
        try self._argvs.appendSlice(argvs);
    }

    /// Append an envp.
    ///
    /// The argument `envp` must not be freed until you call `finalize()`.
    pub fn appendEnvp(self: *Self, envp: []const u8) !void {
        try self._envps.append(envp);
    }

    /// Append envps.
    ///
    /// The argument `envps` must not be freed until you call `finalize()`.
    pub fn appendEnvps(self: *Self, envps: []const []const u8) !void {
        try self._envps.appendSlice(envps);
    }

    /// Append an auxv with an immediate value.
    pub fn appendAuxvImmediate(self: *Self, auxv: AuxVector) !void {
        try self._imm_auxvs.append(auxv);
    }

    /// Append an auxv with a handle to opaque data.
    pub fn appendAuxvWithHandle(self: *Self, auxv: AuxVector) !void {
        try self._handle_auxvs.append(auxv);
    }

    /// Append an arbitrary opaque data.
    ///
    /// Returns the handler of the data.
    /// You can pass the handler as a data, that's resolve to the pointer to the opaque data.
    pub fn appendOpaqueData(self: *Self, T: type, data: T) !StackOpaqueHandler {
        const duped = try general_allocator.create(T);
        duped.* = data;
        const raw_ptr: [*]const u8 = @alignCast(@ptrCast(duped));
        const u8_size = @sizeOf(T);

        const handle: StackOpaqueHandler = self._opaque_data.items.len;
        try self._opaque_data.append(.{ .data = raw_ptr[0..u8_size], .handle = handle });
        return handle;
    }

    /// Perform the construction of the user stack frame.
    ///
    /// Calling this function constructs the user stack frame.
    /// You can free the arguments passed to this function after calling this function.
    ///
    /// Returns the address of the top of the user stack.
    pub fn finalize(self: *Self) !u64 {
        // Push opaque data.
        var opaque_num_pushed: usize = 0;
        while (opaque_num_pushed < self._opaque_data.items.len) : (opaque_num_pushed += 1) {
            const data = self._opaque_data.items[opaque_num_pushed];
            const addr = self._stack.pushData(data.data);
            self._opaque_data.items[opaque_num_pushed].pointer = @intFromPtr(addr);
        }

        // Push envp strings.
        var envp_addrs = ArrayList(u64).init(general_allocator);
        defer envp_addrs.deinit();

        var envp_num_pushed: usize = 0;
        while (envp_num_pushed < self._envps.items.len) : (envp_num_pushed += 1) {
            const envp = self._envps.items[self._envps.items.len - envp_num_pushed - 1];
            const addr = self._stack.pushData(envp);
            try envp_addrs.append(@intFromPtr(addr));
        }

        // Push argv strings.
        var argv_addrs = ArrayList(u64).init(general_allocator);
        defer argv_addrs.deinit();

        var argv_num_pushed: usize = 0;
        while (argv_num_pushed < self._argvs.items.len) : (argv_num_pushed += 1) {
            const argv = self._argvs.items[self._argvs.items.len - argv_num_pushed - 1];
            const addr = self._stack.pushData(argv);
            try argv_addrs.append(@intFromPtr(addr));
        }

        // Adjust alignment to 16 bytes.
        self._stack.makeAlignment();

        // Construct auxv array.
        _ = self._stack.push(AuxVector.new(.terminator, 0)); // AT_NULL
        var auxv_num_pushed: usize = 0;
        while (auxv_num_pushed < self._imm_auxvs.items.len) : (auxv_num_pushed += 1) {
            const auxv: AuxVector = self._imm_auxvs.items[auxv_num_pushed];
            _ = self._stack.push(auxv);
        }
        auxv_num_pushed = 0;
        while (auxv_num_pushed < self._handle_auxvs.items.len) : (auxv_num_pushed += 1) {
            const auxv: AuxVector = self._handle_auxvs.items[auxv_num_pushed];
            const opaque_ptr = self._opaque_data.items[auxv.value].pointer;
            _ = self._stack.push(AuxVector.new(auxv.auxv_type, opaque_ptr));
        }

        // Construct envp array.
        envp_num_pushed = 0;
        _ = self._stack.push(@as(u64, 0)); // NULL (envp)
        while (envp_num_pushed < self._envps.items.len) : (envp_num_pushed += 1) {
            _ = self._stack.push(@as(u64, envp_addrs.items[envp_num_pushed]));
        }

        // Construct argv array.
        argv_num_pushed = 0;
        _ = self._stack.push(@as(u64, 0)); // NULL (argv)
        while (argv_num_pushed < self._argvs.items.len) : (argv_num_pushed += 1) {
            _ = self._stack.push(@as(u64, argv_addrs.items[argv_num_pushed]));
        }

        // Push argc.
        _ = self._stack.push(@as(u64, argv_num_pushed));

        // Free items.
        for (self._opaque_data.items) |data| {
            general_allocator.free(data.data);
        }
        self._opaque_data.deinit();
        self._handle_auxvs.deinit();
        self._imm_auxvs.deinit();
        self._envps.deinit();
        self._argvs.deinit();

        return self._stack.getUserStackTop();
    }

    /// User stack mapper.
    const Stack = struct {
        /// Upper limit of the stack.
        _stack_top: [*]u8,
        /// Bottom of the stack.
        _stack_bottom: [*]u8,
        /// Stack pointer.
        _sp: [*]u8,

        /// User stack VMA.
        _user_vma: *const Vma,

        /// Instantiate a new stack information from the userland VMA.
        pub fn new(stack_vma: *const Vma) !Stack {
            const start = stack_vma.start;
            const stack_size = stack_vma.end - stack_vma.start;
            if (start % alignment != 0) return error.InvalidStack;
            if (stack_size % alignment != 0) return error.InvalidStack;

            const slice = stack_vma.slice();

            return .{
                ._stack_top = @constCast(@ptrCast(slice.ptr)),
                ._stack_bottom = @ptrFromInt(@intFromPtr(slice.ptr) + slice.len),
                ._sp = @ptrFromInt(@intFromPtr(slice.ptr) + slice.len),
                ._user_vma = stack_vma,
            };
        }

        /// Push a value to the stack.
        ///
        /// The size of value must be 8-byte aligned.
        /// Returns the address of the pushed value.
        /// Note that the address belongs to user, and you MUST NOT touch it.
        fn push(self: *Stack, value: anytype) [*]const u8 {
            const T = @TypeOf(value);

            const value_size = @sizeOf(T);
            comptime norn.comptimeAssert(
                value_size != 0,
                "StackCreator does not support zero-sized type",
                .{},
            );
            comptime norn.comptimeAssert(
                value_size % 8 == 0,
                "StackCreator only supports 64-bit aligned types",
                .{},
            );

            if (util.ptrLte(self._sp - value_size, self._stack_top)) {
                @panic("StackCreator overflow");
            }
            self._sp -= value_size;

            const ptr: *T = @alignCast(@ptrCast(self._sp));
            ptr.* = value;

            const diff = @intFromPtr(self._sp) - @intFromPtr(self._stack_top);
            return @ptrFromInt(self._user_vma.start + diff);
        }

        /// Push an u8 array to the stack.
        ///
        /// The address of the pushed data is aligned to 8 bytes.
        /// Returns the address of the pushed value.
        ///
        /// Note that the address belongs to user, and you MUST NOT touch it.
        fn pushData(self: *Stack, value: []const u8) [*]const u8 {
            const aligned_size = util.roundup(value.len, alignment);
            if (util.ptrLte(self._sp - aligned_size, self._stack_top)) {
                @panic("StackCreator overflow");
            }
            self._sp -= aligned_size;
            @memcpy(self._sp[0..value.len], value);

            const diff = @intFromPtr(self._sp) - @intFromPtr(self._stack_top);
            return @ptrFromInt(self._user_vma.start + diff);
        }

        /// Align the stack pointer to the alignment.
        fn makeAlignment(self: *Stack) void {
            const diff = @intFromPtr(self._sp) % alignment;
            if (diff != 0) {
                self._sp -= diff;
            }
        }

        /// Get the total size of the pushed values on the stack.
        fn size(self: *Stack) usize {
            return self._stack_bottom - self._sp;
        }

        /// Get the top of the user stack.
        fn getUserStackTop(self: *Stack) u64 {
            return self._user_vma.end - self.size();
        }
    };

    /// Opaque data that can be resolved to a pointer to the actual data on user stack.
    const StackOpaqueHandler = u64;
};

/// Auxiliary vector for passing information from Norn to the user process.
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

    /// Construct an auxiliary vector using immediate value.
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
const ArrayList = std.ArrayList;

const norn = @import("norn");
const arch = norn.arch;
const fs = norn.fs;
const loader = norn.loader;
const mem = norn.mem;
const sched = norn.sched;
const util = norn.util;
const InlineDoublyLinkedList = norn.InlineDoublyLinkedList;
const MemoryMap = norn.mm.MemoryMap;
const Vma = norn.mm.VmArea;
const SpinLock = norn.SpinLock;

const page_allocator = mem.page_allocator;
const general_allocator = mem.general_allocator;
