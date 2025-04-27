pub const TimerError = error{
    /// Required feature is not supported.
    NotSupported,
} || arch.ArchError || norn.acpi.AcpiError;

/// Frequency of the timer interrupt in Hz.
const freq_hz = 250;

/// Number of jiffies since boot.
var jiffies: u64 = 0;

/// Frequency in KHz of the TSC.
var tsc_freq_khz: u64 = undefined;

/// Start the periodic timer service.
pub fn init() TimerError!void {
    // Set up timer interrupt handler.
    try arch.setInterruptHandler(
        @intFromEnum(norn.interrupt.VectorTable.timer),
        timer,
    );

    // Get the TSC frequency.
    tsc_freq_khz = try calibrateTsc();
    log.info("TSC frequency: {d} KHz", .{tsc_freq_khz});

    norn.rtt.expect(!arch.isIrqEnabled());

    // Initialize the jiffies counter.
    jiffies = 0;

    // Start the periodic timer.
    const lapic = norn.arch.getLocalApic();
    const lapic_timer = lapic.timer();
    const lapic_freq = lapic_timer.measureFreq();

    const interval_ns = 1000 * 1000 * 1000 / freq_hz;
    try lapic_timer.startPeriodic(
        @intFromEnum(norn.interrupt.VectorTable.timer),
        interval_ns,
        lapic_freq,
    );
}

/// Get timestamp.
pub fn getTimestamp() u64 {
    return arch.readTsc();
}

/// Calibrate the TSC frequency in Hz.
fn calibrateTsc() TimerError!u64 {
    if (!arch.isTscSupported()) {
        return TimerError.NotSupported;
    }

    // Get TSC value from CPUID.
    if (arch.getTscFrequency()) |freq| {
        return freq / 1000;
    } else |_| {}

    // Calibrate TSC frequency.
    const repeat = 3;
    var sum_tsc_freq: u64 = 0;
    for (0..repeat) |_| {
        const wait_us = 1000;
        const tsc1 = arch.readTsc();
        try norn.acpi.spinForUsec(wait_us); // 1ms
        const tsc2 = arch.readTsc();

        sum_tsc_freq += (tsc2 - tsc1) * 1000 / wait_us;
    }

    return sum_tsc_freq / repeat;
}

/// Timer interrupt handler.
fn timer(_: *norn.interrupt.Context) void {
    jiffies += 1;
    arch.getLocalApic().eoi();

    sched.schedule();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.timer);

const norn = @import("norn");
const arch = norn.arch;
const sched = norn.sched;
