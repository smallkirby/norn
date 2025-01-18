const norn = @import("norn");
const arch = norn.arch;

pub const Error = error{} || arch.Error;

/// Frequency of the timer timer interrupt in Hz.
const freq_hz = 250;

/// Start the periodic timer service.
pub fn init() Error!void {
    // Set up timer interrupt handler.
    try arch.setInterruptHandler(
        @intFromEnum(norn.interrupt.VectorTable.timer),
        timer,
    );

    norn.rtt.expect(!arch.isIrqEnabled());

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

/// Timer interrupt handler.
fn timer(_: *norn.interrupt.Context) void {
    norn.sched.schedule();
}
