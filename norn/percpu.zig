//! This file provides per-CPU data access.
//!
//! Per-CPU variable can be defined by adding `linksection(pcpu.section)` to the variable.
//! These variables are placed in the `.data..percpu` section.
//! By calling `init()` function, these data are copied for each CPU.
//!
//! Each CPU must call `initThisCpu()`.
//! The function sets the base address of per-CPU data to the segment register.
//! After that, you can access per-CPU data by using `thisCpuXYZ()` function.
//!
//! Note that pointer returned by `thisCpuVar()` is in the per-CPU address space.
//! So you cannot pass the pointer to the function that expects a pointer in the umua address space.

/// Section name where per-CPU data is placed.
pub const section = ".data..percpu";

/// Alignment of per-CPU data.
const percpu_align = 16;
/// Address space of per-CPU data.
const percpu_addrspace = std.builtin.AddressSpace.gs;

/// Start address of initial per-CPU data.
extern const __per_cpu_start: *void;
/// End address of initial per-CPU data.
extern const __per_cpu_end: *void;

/// Offsets of per-CPU data.
var cpu_offsets = [_]usize{0} ** norn.num_max_cpu;

/// Per-CPU data instance.
var percpu_instance: *void = undefined;

/// Whether per-CPU framework is initialized.
///
/// Note that this does not mean that per-CPU data is initialized.
var percpu_initialized: bool = false;
/// Whether per-CPU data for this CPU is initialized.
var percpu_thiscpu_initialized: [norn.num_max_cpu]bool = [_]bool{false} ** norn.num_max_cpu;

/// Initialize per-CPU data.
pub fn globalInit(num_cpus: usize, percpu_base: Virt) PageAllocator.Error!void {
    norn.rtt.expect(mem.isPgtblInitialized());

    const per_cpu_size = @intFromPtr(&__per_cpu_end) - @intFromPtr(&__per_cpu_start);
    if (per_cpu_size == 0) return;

    // Calculate offsets of per-CPU data.
    for (0..num_cpus) |i| {
        const offset = if (i == 0) 0 else cpu_offsets[i - 1] + per_cpu_size;
        cpu_offsets[i] = util.roundup(offset, percpu_align);
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
pub fn localInit(cpu: usize) void {
    norn.rtt.expect(percpu_initialized);
    norn.rtt.expect(!percpu_thiscpu_initialized[cpu]);

    norn.arch.setPerCpuBase(@intFromPtr(rawGetCpuHead(cpu)));

    percpu_thiscpu_initialized[cpu] = true;
}

/// Check if per-CPU data is initialized for this CPU.
pub fn isThisCpuInitialized(cpu: usize) bool {
    return percpu_initialized and percpu_thiscpu_initialized[cpu];
}

/// Get the address of per-CPU data relative to the per-CPU address space for the current CPU.
/// TODO disable preemption
pub inline fn ptr(comptime pointer: anytype) *allowzero addrspace(percpu_addrspace) @typeInfo(@TypeOf(pointer)).pointer.child {
    return @ptrCast(@addrSpaceCast(pointer));
}

/// Get the value of the per-CPU variable.
pub inline fn get(comptime pointer: anytype) @typeInfo(@TypeOf(pointer)).pointer.child {
    return ptr(pointer).*;
}

/// Set the given value to the per-CPU variable.
pub inline fn set(comptime pointer: anytype, value: @typeInfo(@TypeOf(pointer)).pointer.child) void {
    ptr(pointer).* = value;
}

/// Get the virtual address of per-CPU data area for the given CPU.
inline fn rawGetCpuHead(cpu: usize) [*]u8 {
    return @ptrFromInt(@intFromPtr(percpu_instance) + cpu_offsets[cpu]);
}

// =============================================================
// Mock
// =============================================================

/// Mock of `percpu` module for testing.
///
/// You cannot access per-CPU data in the unit test.
pub const mock_for_testing = struct {
    comptime {
        if (!@import("builtin").is_test) {
            @compileError("sched.mock_for_testing is only available in test mode");
        }
    }

    pub const section = ".data..percpu";

    pub fn localInit(_: usize) void {}

    pub fn isThisCpuInitialized(_: usize) bool {
        return false;
    }

    pub fn ptr(comptime pointer: anytype) *@typeInfo(@TypeOf(pointer)).pointer.child {
        return pointer;
    }

    pub fn get(comptime pointer: anytype) @typeInfo(@TypeOf(pointer)).pointer.child {
        return pointer.*;
    }

    pub fn set(comptime pointer: anytype, value: @typeInfo(@TypeOf(pointer)).pointer.child) void {
        pointer.* = value;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");

const norn = @import("norn");
const arch = norn.arch;
const mem = norn.mem;
const util = norn.util;
const PageAllocator = mem.PageAllocator;
const Virt = mem.Virt;

const page_allocator = mem.page_allocator;
