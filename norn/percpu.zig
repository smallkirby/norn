const std = @import("std");

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const Virt = mem.Virt;

const page_allocator = mem.page_allocator;
const PageAllocator = mem.PageAllocator;

/// Section name where per-CPU data is placed.
pub const section = ".data..percpu";

pub const Error = error{} || PageAllocator.Error;

/// Alignment of per-CPU data.
const percpu_align = 16;
/// Address space of per-CPU data.
const percpu_addrspace = std.builtin.AddressSpace.gs;

extern const __per_cpu_start: *void;
extern const __per_cpu_end: *void;

/// Offsets of per-CPU data.
var cpu_offsets = [_]usize{0} ** norn.num_max_cpu;

/// Per-CPU data instance.
var percpu_instance: *void = undefined;

/// Whether per-CPU data is initialized.
var percpu_initialized: bool = false;

/// Initialize per-CPU data.
pub fn init(num_cpus: usize, percpu_base: Virt) Error!void {
    const per_cpu_size = @intFromPtr(&__per_cpu_end) - @intFromPtr(&__per_cpu_start);
    if (per_cpu_size == 0) return;

    // Calculate offsets of per-CPU data.
    for (0..num_cpus) |i| {
        const offset = if (i == 0) 0 else cpu_offsets[i - 1] + per_cpu_size;
        cpu_offsets[i] = roundup(offset, percpu_align);
    }

    // Allocate per-CPU data area.
    const total_size = cpu_offsets[num_cpus - 1] + per_cpu_size;
    percpu_instance = @ptrCast(try page_allocator.allocPages(
        @divFloor(total_size - 1, mem.size_4kib) + 1,
        .normal,
    ));

    // Copy initial data to per-CPU data.
    const original_data: [*]const u8 = @ptrFromInt(percpu_base);
    for (0..num_cpus) |i| {
        @memcpy(rawGetCpuHead(i)[0..per_cpu_size], original_data[0..per_cpu_size]);
    }

    percpu_initialized = true;
}

/// Initialize per-CPU data for this core.
pub fn initThisCpu(cpu: usize) void {
    norn.rtt.expect(percpu_initialized);
    norn.arch.setPerCpuBase(@intFromPtr(rawGetCpuHead(cpu)));
}

/// Get the address of per-CPU data relative to the per-CPU address space for the current CPU.
/// TODO disable preemption
pub inline fn thisCpuGet(comptime pointer: anytype) *allowzero addrspace(percpu_addrspace) @typeInfo(@TypeOf(pointer)).Pointer.child {
    return @addrSpaceCast(@ptrCast(pointer));
}

/// Get the virtual address of per-CPU data area for the given CPU.
inline fn rawGetCpuHead(cpu: usize) [*]u8 {
    return @ptrFromInt(@intFromPtr(percpu_instance) + cpu_offsets[cpu]);
}

inline fn roundup(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

// =======================================

// `percpu` module for testing.
pub const mock_for_testing = struct {
    comptime {
        if (!@import("builtin").is_test) {
            @compileError("sched.mock_for_testing is only available in test mode");
        }
    }

    pub const section = ".data..percpu";
    pub fn initThisCpu(_: usize) void {}
    pub fn thisCpuGet(comptime pointer: anytype) *@typeInfo(@TypeOf(pointer)).Pointer.child {
        return pointer;
    }
};
