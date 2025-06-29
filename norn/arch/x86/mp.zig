const MpError = mem.MemError || pg.PageError;

/// Number of pages for the each AP stack.
const num_ap_stack_pages = 10;

/// Spin lock shared by all APs while booting.
var lock = SpinLock{};

/// Boot all APs.
pub fn bootAllAps() MpError!void {
    const ie = arch.disableIrq();
    defer if (ie) arch.enableIrq();

    const system_info = acpi.getSystemInfo();
    const bsp_id = arch.queryBspId();
    const lapic = arch.getLocalApic();

    // Copy AP trampoline code to the 4KiB aligned physical memory.
    const trampoline: [*]const u8 = @ptrCast(&__ap_trampoline);
    const trampoline_end: [*]const u8 = @ptrCast(&__ap_trampoline_end);
    const trampoline_size = @intFromPtr(trampoline_end) - @intFromPtr(trampoline);
    const trampoline_page = try page_allocator.allocPages(1, .dma);
    defer page_allocator.freePages(trampoline_page);
    const trampoline_page_phys = mem.virt2phys(trampoline_page.ptr);
    @memcpy(trampoline_page[0..trampoline_size], trampoline[0..trampoline_size]);

    // Physical address of the trampoline code must be located at address lower than 1MiB and 4KiB aligned,
    // so that we can put the address into the SIPI vector field.
    norn.rtt.expectEqual(0, trampoline_page_phys & ~@as(Phys, 0xF_F000));

    // Direct map the trampoline page.
    // This is required when AP enables paging.
    try pg.boot.map4kPageDirect(
        trampoline_page_phys,
        trampoline_page_phys,
        .read_write_executable,
        page_allocator,
    );

    // Prepare temporary stack for APs.
    const ap_stack = try page_allocator.allocPages(1, .dma);
    defer page_allocator.freePages(ap_stack);
    @memset(ap_stack, 0);
    try pg.boot.map4kPageDirect(
        mem.virt2phys(ap_stack.ptr),
        mem.virt2phys(ap_stack.ptr),
        .read_write,
        page_allocator,
    );

    // Relocate boot code.
    relocateTrampoline(trampoline_page, ap_stack);

    // Boot all APs.
    for (0..system_info.num_cpus) |i| {
        const ap_id = system_info.local_apic_ids.items[i];

        if (ap_id == bsp_id) {
            continue;
        }
        bootAp(ap_id, lapic, trampoline_page_phys);

        // Wait for the AP to boot.
        while (lock.isLocked()) {
            atomic.spinLoopHint();
        }
    }

    // Unmap and free the temporary pages.
    try pg.boot.unmap4kPage(mem.virt2phys(ap_stack.ptr));
    try pg.boot.unmap4kPage(mem.virt2phys(trampoline_page.ptr));
}

/// Boot a single AP.
fn bootAp(ap_id: u8, lapic: apic.LocalApic, ap_entry: Phys) void {
    // Lock. This lock is released by the booted AP.
    lock.lock();

    // Clear error.
    lapic.write(u32, .esr, 0);

    // Issue INIT IPI for the AP.
    var icr_high: apic.IcrHigh = @bitCast(lapic.read(u32, .icr_high));
    var icr_low: apic.IcrLow = @bitCast(lapic.read(u32, .icr_low));
    icr_high.set(.{
        .dest = ap_id,
    });
    icr_low.set(.{
        .vector = 0,
        .delivery_mode = .init,
        .dest_mode = .physical,
        .level = .assert,
        .trigger_mode = .level,
        .dest_shorthand = .no_shorthand,
    });

    lapic.write(u32, .icr_high, icr_high);
    lapic.write(u32, .icr_low, icr_low);

    // Wait for the IPI to be delivered.
    while (true) {
        atomic.spinLoopHint();
        icr_low = @bitCast(lapic.read(u32, .icr_low));
        if (icr_low.inner.delivery_status == .idle) break;
    }

    // Deassert INIT IPI.
    icr_high = @bitCast(lapic.read(u32, .icr_high));
    icr_low = @bitCast(lapic.read(u32, .icr_low));
    icr_high.set(.{
        .dest = ap_id,
    });
    icr_low.set(.{
        .vector = 0,
        .delivery_mode = .init,
        .dest_mode = .physical,
        .level = .deassert,
        .trigger_mode = .level,
        .dest_shorthand = .no_shorthand,
    });
    lapic.write(u32, .icr_high, icr_high);
    lapic.write(u32, .icr_low, icr_low);

    // Wait for 10ms
    acpi.spinForUsec(10 * 1000) catch @panic("Unexpected error while spinning for 10ms");

    // Issue SIPI twice for the AP.
    for (0..2) |_| {
        // Clear error.
        lapic.write(u32, .icr_high, icr_high);

        // Issue SIPI.
        icr_high = @bitCast(lapic.read(u32, .icr_high));
        icr_low = @bitCast(lapic.read(u32, .icr_low));
        icr_high.set(.{
            .dest = ap_id,
        });
        icr_low.set(.{
            .vector = @as(u8, @intCast(ap_entry >> mem.page_shift_4kib)),
            .delivery_mode = .startup,
            .trigger_mode = .edge,
            .dest_shorthand = .no_shorthand,
        });

        lapic.write(u32, .icr_high, icr_high);
        lapic.write(u32, .icr_low, icr_low);

        // Wait for 200us
        acpi.spinForUsec(200) catch @panic("Unexpected error while spinning for 200us");

        // Wait for the IPI to be delivered.
        while (true) {
            atomic.spinLoopHint();
            icr_low = @bitCast(lapic.read(u32, .icr_low));
            if (icr_low.inner.delivery_status == .idle) break;
        }
    }
}

/// AP entry code.
/// Trampoline code in assembly starts from protected mode and jumps to this function in long mode.
/// At this point, CR3 is set to BSP's one.
/// GDT is temporary. IDT is not set. Interrupts are disabled.
/// Stack is shared and temporary.
fn apEntry64() callconv(.c) noreturn {
    // Allocate stack.
    // TODO: set guard page.
    const stack_top = page_allocator.allocPages(num_ap_stack_pages + 1, .normal) catch @panic("Failed to allocate stack for AP");
    const stack = @intFromPtr(stack_top.ptr) + (num_ap_stack_pages + 1) * mem.size_4kib - 0x10;

    // Set stack pointer.
    asm volatile (
        \\xorq %%rbp, %%rbp
        \\movq %[stack], %%rsp
        \\call apTrampolineToMain
        :
        : [stack] "r" (stack),
    );

    unreachable;
}

/// Final function before entering the AP main function.
/// AP uses its own stack here. The only shared resource is the lock.
export fn apTrampolineToMain() callconv(.c) noreturn {
    // Unlock the lock for BSP to continue booting other APs.
    lock.unlock();

    // Initialize APIC.
    arch.initApic() catch @panic("Failed to initialize APIC");
    const lapic = apic.LocalApic.new(acpi.getSystemInfo().local_apic_address);

    // Initialize per-CPU data.
    norn.pcpu.initThisCpu(lapic.id());

    // Setup GDT.
    gdt.setupThisCpu(mem.page_allocator) catch {
        @panic("Failed to setup GDT for AP");
    };

    // Greeting
    const lapic_id = lapic.id();
    log.info("AP #{d} has been booted.", .{lapic_id});

    // TODO jump to AP main
    while (true) am.hlt();

    unreachable;
}

extern const __ap_trampoline: *void;
extern const __ap_trampoline_end: *void;
extern const __ap_gdt: *void;
extern const __ap_gdtr: *void;
extern const __ap_entry32: *void;
extern const __ap_entry64: *void;
extern const __ap_reloc_farjmp32: *void;
extern const __ap_reloc_farjmp64: *void;
extern const __ap_reloc_stack: *void;
extern const __ap_reloc_cr3: *void;
extern const __ap_reloc_zigentry: *void;

/// Relocate AP trampoline code.
fn relocateTrampoline(trampoline: []u8, ap_stack: []u8) void {
    relocateGdtr(trampoline);
    relocateFarjmp32(trampoline);
    relocateFarjmp64(trampoline);
    relocateStack(trampoline, ap_stack);
    relocateCr3(trampoline);
    relocateZigEntry(trampoline);
}

fn relocateGdtr(trampoline: []u8) void {
    const gdtr_offset = @intFromPtr(&__ap_gdtr) - @intFromPtr(&__ap_trampoline);
    const gdt_offset = @intFromPtr(&__ap_gdt) - @intFromPtr(&__ap_trampoline);
    const gdt_addr = mem.virt2phys(trampoline.ptr) + gdt_offset;
    const reloc: [*]volatile u16 = @ptrFromInt(@intFromPtr(trampoline.ptr) + gdtr_offset + 2); // +2 for `Base` field of GDTR

    // GDT must be addressable by 4-byte physical address.
    norn.rtt.expectEqual(0, gdt_addr & ~@as(u64, 0xFFFF_FFFF));

    // GDTR.Base is not 4-byte aligned. So we have to set it by 2-byte chunks to suppress Zig's runtime check.
    for (0..2) |i| {
        reloc[i] = @truncate(gdt_addr >> @as(u6, @intCast(16 * i)));
    }
}

fn relocateFarjmp32(trampoline: []u8) void {
    const reloc_offset = @intFromPtr(&__ap_reloc_farjmp32) - @intFromPtr(&__ap_trampoline);
    const reloc: [*]volatile u8 = @ptrFromInt(@intFromPtr(trampoline.ptr) + reloc_offset);
    const entry32_offset = @intFromPtr(&__ap_entry32) - @intFromPtr(&__ap_trampoline);
    const entry32_addr = mem.virt2phys(trampoline.ptr) + entry32_offset;

    for (0..4) |i| {
        reloc[2 + i] = @truncate(entry32_addr >> (@as(u6, @intCast(i)) * 8));
    }
}

fn relocateFarjmp64(trampoline: []u8) void {
    const reloc_offset = @intFromPtr(&__ap_reloc_farjmp64) - @intFromPtr(&__ap_trampoline);
    const reloc: [*]volatile u8 = @ptrFromInt(@intFromPtr(trampoline.ptr) + reloc_offset);
    const entry64_offset = @intFromPtr(&__ap_entry64) - @intFromPtr(&__ap_trampoline);
    const entry64_addr = mem.virt2phys(trampoline.ptr) + entry64_offset;

    for (0..4) |i| {
        reloc[1 + i] = @truncate(entry64_addr >> (@as(u6, @intCast(i)) * 8));
    }
}

fn relocateStack(trampoline: []u8, ap_stack: []u8) void {
    const reloc_offset = @intFromPtr(&__ap_reloc_stack) - @intFromPtr(&__ap_trampoline);
    const reloc: [*]volatile u8 = @ptrFromInt(@intFromPtr(trampoline.ptr) + reloc_offset);
    const stack_addr: u32 = @intCast(mem.virt2phys(ap_stack.ptr) + mem.size_4kib - 0x10);

    for (0..4) |i| {
        reloc[1 + i] = @truncate(stack_addr >> (@as(u5, @intCast(i)) * 8));
    }
}

fn relocateCr3(trampoline: []u8) void {
    const reloc_offset = @intFromPtr(&__ap_reloc_cr3) - @intFromPtr(&__ap_trampoline);
    const reloc: [*]volatile u8 = @ptrFromInt(@intFromPtr(trampoline.ptr) + reloc_offset);
    const cr3 = am.readCr3() & ~@as(u64, 1);

    for (0..4) |i| {
        reloc[1 + i] = @truncate(cr3 >> (@as(u6, @intCast(i)) * 8));
    }
}

fn relocateZigEntry(trampoline: []u8) void {
    const reloc_offset = @intFromPtr(&__ap_reloc_zigentry) - @intFromPtr(&__ap_trampoline);
    const reloc: [*]volatile u8 = @ptrFromInt(@intFromPtr(trampoline.ptr) + reloc_offset);
    const zigentry_addr: mem.Virt = @intFromPtr(&apEntry64);

    for (0..8) |i| {
        reloc[2 + i] = @truncate(zigentry_addr >> (@as(u6, @intCast(i)) * 8));
    }
}

const std = @import("std");
const atomic = std.atomic;
const log = std.log.scoped(.mp);

const norn = @import("norn");
const acpi = norn.acpi;
const bits = norn.bits;
const mem = norn.mem;
const Phys = mem.Phys;
const SpinLock = norn.SpinLock;

const page_allocator = mem.page_allocator;
const PageAllocator = mem.PageAllocator;

const am = @import("asm.zig");
const apic = @import("apic.zig");
const arch = @import("arch.zig");
const gdt = @import("gdt.zig");
const intr = @import("intr.zig");
const pg = @import("page.zig");
