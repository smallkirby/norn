const std = @import("std");
const log = std.log.scoped(.main);

const surtr = @import("surtr");
const norn = @import("norn");
const arch = norn.arch;
const klog = norn.klog;

const BootInfo = surtr.BootInfo;

/// Override the standard options.
pub const std_options = std.Options{
    // Logging
    .logFn = klog.log,
    .log_level = klog.log_level,
};
/// Override the panic function.
pub const panic = @import("panic.zig").panic_fn;

/// Early-phase kernel stack for BSP.
extern const __early_stack_bottom: [*]const u8;

/// Entry point from the bootloader.
/// BSP starts here with its early stack.
export fn kernelEntry() callconv(.Naked) noreturn {
    asm volatile (
        \\movq %[new_stack], %%rsp
        \\call kernelTrampoline
        :
        : [new_stack] "r" (@intFromPtr(&__early_stack_bottom) - 0x10),
    );
}

/// Trampoline function to call the main kernel function.
/// This function is intended to convert the calling convention from .Win64 to Zig.
export fn kernelTrampoline(boot_info: BootInfo) callconv(.Win64) noreturn {
    kernelMain(boot_info) catch |err| {
        log.err("Kernel aborted with error: {}", .{err});
        @panic("Exiting...");
    };

    unreachable;
}

/// Kernel main function in Zig calling convention.
fn kernelMain(early_boot_info: BootInfo) !void {
    // Init kernel logger.
    klog.init();
    log.info("Booting Norn kernel...", .{});

    // Init runtime testing.
    if (norn.is_runtime_test) {
        norn.rtt.init();
        log.info("Initialized runtime testing.", .{});
    }

    // Validate the boot info.
    validateBootInfo(early_boot_info) catch |err| {
        log.err("Invalid boot info: {}", .{err});
        return error.InvalidBootInfo;
    };

    // Copy boot_info into Norn's stack since it becomes inaccessible soon.
    // `var` is to avoid the copy from being delayed.
    // (If the copy is performed after the mapping reconstruction, we cannot access the original boot_info and results in #PF).
    var boot_info: BootInfo = undefined;
    boot_info = early_boot_info;

    // Initialize GDT.
    arch.initGdt();
    log.info("Initialized GDT.", .{});

    // Initialize IDT.
    arch.intr.init();
    arch.enableIrq();
    log.info("Initialized IDT.", .{});

    // Initialize page allocator.
    norn.mem.initPageAllocator(boot_info.memory_map);
    log.info("Initialized page allocator.", .{});

    // Reconstruct memory mapping from the one provided by UEFI and Sutr.
    log.info("Reconstructing memory mapping...", .{});
    try norn.mem.reconstructMapping();
    log.info("Memory mapping is reconstructed.", .{});

    // Initialize general allocator.
    norn.mem.initGeneralAllocator();
    log.info("Initialized general allocator.", .{});

    // Initialize ACPI.
    try norn.acpi.init(boot_info.rsdp);
    log.info("Initialized ACPI.", .{});
    log.info("Number of available CPUs: {d}", .{norn.acpi.getSystemInfo().num_cpus});

    // EOL
    if (norn.is_runtime_test) {
        norn.terminateQemu(0);
    }
    norn.unimplemented("Reached unreachable Norn EOL.");
}

/// Validate the BootInfo passed by the bootloader.
fn validateBootInfo(boot_info: BootInfo) !void {
    if (boot_info.magic != surtr.magic) {
        return error.InvalidMagic;
    }
}
