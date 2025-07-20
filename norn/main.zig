// =============================================================
// Main entry point of the Norn kernel.
// =============================================================

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
export fn kernelEntry() callconv(.naked) noreturn {
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

    // Initialize GDT.
    arch.initEarlyGdt();
    log.info("Initialized GDT.", .{});

    // Initialize IDT.
    arch.initInterrupt();
    arch.enableIrq();
    log.info("Initialized IDT.", .{});

    // Initialize bootstrap allocator.
    norn.mem.initBootstrapAllocator(early_boot_info.memory_map);
    log.info("Initialized bootstrap allocator.", .{});

    // Copy boot_info into Norn's stack since it becomes inaccessible soon.
    // `var` is to avoid the copy from being delayed.
    // (If the copy is performed after the mapping reconstruction, we cannot access the original boot_info and results in #PF).
    var boot_info: BootInfo = undefined;
    boot_info = early_boot_info;
    // Also, copy the initramfs from .loader_data to Norn memory.
    {
        const src = boot_info.initramfs;
        const dest = try norn.mem.boottimeAlloc(src.size);
        const src_ptr: [*]const u8 = @ptrFromInt(src.addr);
        @memcpy(dest[0..src.size], src_ptr[0..src.size]);
        boot_info.initramfs.addr = @intFromPtr(dest.ptr);
    }
    // Copy memory map.
    try boot_info.memory_map.deepCopy(norn.mem.getLimitedBoottimeAllocator());

    // Reconstruct memory mapping from the one provided by UEFI and Sutr.
    log.info("Reconstructing memory mapping...", .{});
    try norn.mem.reconstructMapping();
    log.info("Memory mapping is reconstructed.", .{});

    norn.mem.initBuddyAllocator(boot_info.memory_map, log.debug);
    log.info("Initialized buddy allocator.", .{});

    // Initialize general allocator.
    norn.mem.initGeneralAllocator();
    log.info("Initialized general allocator.", .{});

    // Initialize resource map.
    try norn.mem.resource.init(boot_info.memory_map, norn.mem.general_allocator);

    // Deactivate the memory map.
    // We can no longer use the memory map.
    {
        const buffer = boot_info.memory_map.getInternalBuffer(norn.mem.phys2virt);
        try norn.mem.page_allocator.freePagesRaw(
            @intFromPtr(buffer.ptr),
            buffer.len / norn.mem.size_4kib,
        );
    }
    log.debug("Deactivated memory map provided by Surtr.", .{});

    // Initialize ACPI.
    try norn.acpi.init(boot_info.rsdp, norn.mem.general_allocator);
    log.info("Initialized ACPI.", .{});
    log.info("Number of available CPUs: {d}", .{norn.acpi.getSystemInfo().num_cpus});
    if (norn.is_runtime_test) {
        try norn.acpi.spinForUsec(1000); // test if PM timer is working
    }

    // Set spurious interrupt handler.
    try arch.setInterruptHandler(@intFromEnum(norn.interrupt.VectorTable.spurious), spriousInterruptHandler);
    try arch.initApic();
    log.info("Initialized APIC.", .{});

    // Initialize per-CPU data.
    try norn.pcpu.init(
        norn.acpi.getSystemInfo().num_cpus,
        boot_info.percpu_base,
    );
    norn.pcpu.initThisCpu(norn.arch.getLocalApic().id());

    // Do per-CPU initialization.
    try arch.initGdtThisCpu(norn.mem.page_allocator);

    // Boot APs.
    log.info("Booting APs...", .{});
    try arch.mp.bootAllAps();

    // Initialize scheduler.
    _ = norn.arch.disableIrq();
    try norn.sched.initThisCpu();

    // Enter the Norn kernel thread.
    const norn_thread = try norn.thread.createKernelThread(
        "[norn]",
        nornThread,
        .{boot_info.initramfs},
    );
    norn.sched.enqueueTask(norn_thread);
    log.info("Entering Norn kernel thread...", .{});
    norn.sched.runInitialKernelThread();

    unreachable;
}

/// Initial kernel thread with PID 0.
///
/// This function continues initialization of the kernel that requires the execution to have context.
/// This thread becomes an idle task once the initialization is completed,
/// and the initial task is launched.
fn nornThread(initramfs: surtr.InitramfsInfo) !void {
    norn.rtt.expectEqual(false, norn.arch.isIrqEnabled());

    // Initialize filesystem.
    try norn.fs.init();
    log.info("Initialized filesystem.", .{});

    // Read initramfs.
    // Set the root directory and CWD to the root of initramfs.
    {
        const initimg = initramfs;
        const imgptr: [*]const u8 = @ptrFromInt(norn.mem.phys2virt(initimg.addr));
        try norn.fs.loadInitImage(imgptr[0..initimg.size]);
        log.debug("Loaded initramfs.", .{});

        // Free initramfs pages
        const num_pages = try std.math.divCeil(usize, initimg.size, norn.mem.size_4kib);
        try norn.mem.page_allocator.freePagesRaw(@intFromPtr(imgptr), num_pages);
        log.info("Freed {d} pages of initramfs.", .{num_pages});
    }

    // Initialize syscall.
    try arch.enableSyscall();

    // Initialize device system.
    try norn.device.init();
    log.debug("Initialized module system.", .{});

    // Print Norn banner.
    log.info("", .{});
    log.info("Norn Kernel - version {s} ({s})", .{ norn.version, norn.sha });
    norn.getSerial().writeString("\n");
    norn.getSerial().writeString(norn.banner);
    norn.getSerial().writeString("\n");

    // Initialize scheduler.
    log.info("Initializing scheduler...", .{});
    try norn.sched.setupInitialTask();
    norn.sched.debugPrintRunQueue(log.debug);

    // Start timer and scheduler.
    log.info("Starting scheduler...", .{});
    try norn.timer.init();

    // PCI
    norn.pci.debugPrintAllDevices();

    // Start the scheduler.
    // This function never returns.
    norn.sched.schedule();

    // Unreachable.
    norn.unimplemented("Reached unreachable Norn EOL.");
    unreachable;
}

/// Validate the BootInfo passed by the bootloader.
fn validateBootInfo(boot_info: BootInfo) !void {
    if (boot_info.magic != surtr.magic) {
        return error.InvalidMagic;
    }
}

/// Interrupt handler for spurious interrupts.
fn spriousInterruptHandler(_: *norn.interrupt.Context) void {
    std.log.scoped(.spurious).warn("Detected a spurious interrupt.", .{});
    arch.getLocalApic().eoi();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.main);

const surtr = @import("surtr");
const norn = @import("norn");
const arch = norn.arch;
const klog = norn.klog;

const BootInfo = surtr.BootInfo;
