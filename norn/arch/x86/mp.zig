const std = @import("std");
const atomic = std.atomic;
const Allocator = std.mem.Allocator;

const norn = @import("norn");
const acpi = norn.acpi;
const bits = norn.bits;
const mem = norn.mem;
const Phys = mem.Phys;

const apic = @import("apic.zig");
const arch = @import("arch.zig");

const Error = error{
    /// Failed to allocate memory.
    OutOfMemory,
};

/// Boot all APs.
pub fn bootAllAps(allocator: Allocator) Error!void {
    const ie = arch.isIrqEnabled();
    arch.disableIrq();
    defer if (ie) arch.enableIrq();

    const system_info = acpi.getSystemInfo();
    const bsp_id = arch.queryBspId();
    const local_apic_addr = system_info.local_apic_address;
    const lapic = apic.LocalApic.new(local_apic_addr); // local APIC of the BSP

    // Copy AP trampoline code to the 4KiB aligned physical memory.
    const trampoline: [*]const u8 = @ptrCast(&__ap_trampoline);
    const trampoline_end: [*]const u8 = @ptrCast(&__ap_trampoline_end);
    const trampoline_size = @intFromPtr(trampoline_end) - @intFromPtr(trampoline);
    const trampoline_page = try allocator.alignedAlloc(u8, mem.size_4kib, trampoline_size);
    @memcpy(trampoline_page[0..trampoline_size], trampoline[0..trampoline_size]);
    norn.rtt.expectEqual(0, @intFromPtr(trampoline_page.ptr) % mem.size_4kib);

    // Boot all APs.
    for (0..system_info.num_cpus) |i| {
        const ap_id = system_info.local_apic_ids.items[i];

        if (ap_id == bsp_id) {
            continue;
        }
        bootAp(ap_id, lapic, mem.virt2phys(trampoline_page.ptr));
    }

    // TODO free trampoline memory after all APs are booted.
}

/// Boot a single AP.
fn bootAp(ap_id: u8, lapic: apic.LocalApic, ap_entry: Phys) void {
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
        .delivery_mode = .startup,
        .dest_mode = .physical,
        .level = .deassert,
        .trigger_mode = .level,
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

extern const __ap_trampoline: *void;
extern const __ap_trampoline_end: *void;

/// Trampoline code for APs.
export fn apTrampoline() callconv(.Naked) noreturn {
    // TODO: implement
    asm volatile (
        \\.code16
        \\.global __ap_trampoline
        \\.global __ap_trampoline_end
        \\
        \\__ap_trampoline:
        \\
        \\cli
        \\hlt
        \\
        \\__ap_trampoline_end:
    );
}
