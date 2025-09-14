//! Construct stack frame in the given area.
//!
//! You build a stack by calling these APIS.
//! Until you call `finalize()`, the stack is not constructed.

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
/// Memory allocator.
_allocator: Allocator,

/// Endmark type that's placed at the bottom of the stack.
const EndmarkType = u64;
/// argc type.
const ArgcType = u64;
/// argv type.
const Argv = []const u8;
/// argv list type.
const ArgvList = std.array_list.Aligned(Argv, null);
/// envp type.
const Envp = []const u8;
/// envp list type.
const EnvpList = std.array_list.Aligned(Envp, null);
/// auxv list type.
const AuxVectorList = std.array_list.Aligned(AuxVector, null);
/// Opaque data type.
const OpaqueType = struct {
    data: []const u8,
    handle: StackOpaqueHandler,
    pointer: u64 = undefined,
};
/// Opaque data list type.
const OpaqueList = std.array_list.Aligned(OpaqueType, null);

/// Stack alignment in bytes.
const alignment = 16;

/// Instantiate a new stack creator.
///
/// Cursor is set to the bottom of the stack.
pub fn new(stack_vma: *const Vma, allocator: Allocator) !Self {
    return .{
        ._stack = try Stack.new(stack_vma),
        ._argvs = .empty,
        ._envps = .empty,
        ._imm_auxvs = .empty,
        ._handle_auxvs = .empty,
        ._opaque_data = .empty,
        ._allocator = allocator,
    };
}

/// Append an argv.
///
/// The argument `argv` must not be freed until you call `finalize()`.
pub fn appendArgv(self: *Self, argv: []const u8) !void {
    try self._argvs.append(self._allocator, argv);
}

/// Append argvs.
///
/// The argument `argvs` must not be freed until you call `finalize()`.
pub fn appendArgvs(self: *Self, argvs: []const []const u8) !void {
    try self._argvs.appendSlice(self._allocator, argvs);
}

/// Append an envp.
///
/// The argument `envp` must not be freed until you call `finalize()`.
pub fn appendEnvp(self: *Self, envp: []const u8) !void {
    try self._envps.append(self._allocator, envp);
}

/// Append envps.
///
/// The argument `envps` must not be freed until you call `finalize()`.
pub fn appendEnvps(self: *Self, envps: []const []const u8) !void {
    try self._envps.appendSlice(self._allocator, envps);
}

/// Append an auxv with an immediate value.
pub fn appendAuxvImmediate(self: *Self, auxv: AuxVector) !void {
    try self._imm_auxvs.append(self._allocator, auxv);
}

/// Append an auxv with a handle to opaque data.
pub fn appendAuxvWithHandle(self: *Self, auxv: AuxVector) !void {
    try self._handle_auxvs.append(self._allocator, auxv);
}

/// Append an arbitrary opaque data.
///
/// Returns the handler of the data.
/// You can pass the handler as a data, that's resolved to the pointer to the opaque data.
pub fn appendOpaqueData(self: *Self, T: type, data: T) !StackOpaqueHandler {
    const duped = try self._allocator.create(T);
    duped.* = data;
    const raw_ptr: [*]const u8 = @ptrCast(@alignCast(duped));
    const u8_size = @sizeOf(T);

    const handle: StackOpaqueHandler = self._opaque_data.items.len;
    try self._opaque_data.append(
        self._allocator,
        .{ .data = raw_ptr[0..u8_size], .handle = handle },
    );
    return handle;
}

/// Perform the construction of the user stack frame.
///
/// Calling this function constructs the user stack frame.
/// You can free the arguments passed to this function after calling this function.
///
/// Returns the address of the top of the user stack.
///
/// ### Stack Structure
///
/// - argc
/// - argv[0]
/// - ...
/// - argv[n1] == NULL
/// - envp[0]
/// - ...
/// - envp[n2] == NULL
/// - auxv[0]
/// - ...
/// - auxv[n3] == AT_NULL
/// - padding (0~15 bytes)
/// - opaque data
/// - NULL
pub fn finalize(self: *Self) !u64 {
    // Push an endmark.
    _ = self._stack.push(@as(EndmarkType, 0));

    // Push opaque data.
    var opaque_num_pushed: usize = 0;
    while (opaque_num_pushed < self._opaque_data.items.len) : (opaque_num_pushed += 1) {
        const data = self._opaque_data.items[opaque_num_pushed];
        const addr = self._stack.pushData(data.data);
        self._opaque_data.items[opaque_num_pushed].pointer = @intFromPtr(addr);
    }

    // Push envp strings.
    var envp_addrs = std.array_list.Aligned(u64, null).empty;
    defer envp_addrs.deinit(self._allocator);

    var envp_num_pushed: usize = 0;
    while (envp_num_pushed < self._envps.items.len) : (envp_num_pushed += 1) {
        const envp = self._envps.items[self._envps.items.len - envp_num_pushed - 1];
        const addr = self._stack.pushData(envp);
        try envp_addrs.append(self._allocator, @intFromPtr(addr));
    }

    // Push argv strings.
    var argv_addrs = std.array_list.Aligned(u64, null).empty;
    defer argv_addrs.deinit(self._allocator);

    var argv_num_pushed: usize = 0;
    while (argv_num_pushed < self._argvs.items.len) : (argv_num_pushed += 1) {
        const argv = self._argvs.items[self._argvs.items.len - argv_num_pushed - 1];
        const addr = self._stack.pushData(argv);
        try argv_addrs.append(self._allocator, @intFromPtr(addr));
    }

    // Ensure alignment.
    const remaining_size =
        (self._imm_auxvs.items.len + self._handle_auxvs.items.len + 1) * @sizeOf(AuxVector) +
        (envp_addrs.items.len + 1) * @sizeOf(u64) +
        (argv_addrs.items.len + 1) * @sizeOf(u64) +
        @sizeOf(ArgcType);
    {
        const final_sp = @intFromPtr(self._stack._sp - remaining_size);
        const align_adjust = final_sp - norn.util.rounddown(final_sp, alignment);
        self._stack.pad(align_adjust);
    }

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
        self._allocator.free(data.data);
    }
    self._opaque_data.deinit(self._allocator);
    self._handle_auxvs.deinit(self._allocator);
    self._imm_auxvs.deinit(self._allocator);
    self._envps.deinit(self._allocator);
    self._argvs.deinit(self._allocator);

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
            ._stack_top = @ptrCast(@constCast(slice.ptr)),
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

        const ptr: *align(8) T = @ptrCast(@alignCast(self._sp));
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

    /// Decrease the stack pointer by `n` bytes.
    fn pad(self: *Stack, n: usize) void {
        if (util.ptrLte(self._sp - n, self._stack_top)) {
            @panic("StackCreator overflow");
        }
        self._sp -= n;
    }

    /// Check if the stack pointer is aligned.
    fn isAligned(self: *Stack) bool {
        return @intFromPtr(self._sp) % alignment == 0;
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

/// Auxiliary vector for passing information from Norn to the user process.
pub const AuxVector = packed struct(u128) {
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

/// Opaque data that can be resolved to a pointer to the actual data on user stack.
pub const StackOpaqueHandler = u64;

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const util = norn.util;
const Vma = norn.mm.VmArea;
