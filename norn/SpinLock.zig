const Self = @This();
const SpinLock = Self;

const State = atomic.Value(bool);

/// State of the spin lock.
/// true when locked, false when unlocked.
_state: State = State.init(false),

/// Lock the spin lock.
pub fn lock(self: *Self) void {
    while (self._state.cmpxchgWeak(
        false,
        true,
        .acq_rel,
        .monotonic,
    ) != null) {
        atomic.spinLoopHint();
    }
}

/// Lock the spin lock and disable IRQ.
/// Must be paired with `unlockRestoreIrq()`.
pub fn lockDisableIrq(self: *SpinLock) bool {
    if (!is_test) {
        const ie = arch.disableIrq();
        lock(self);
        return ie;
    } else {
        lock(self);
        return false;
    }
}

/// Unlock the spin lock.
pub fn unlock(self: *Self) void {
    self._state.store(false, .release);
}

/// Unlock the spin lock and restore IRQ mask.
pub fn unlockRestoreIrq(self: *SpinLock, ie: bool) void {
    self.unlock();
    if (!is_test and ie) {
        arch.enableIrq();
    }
}

/// Check if the spin lock is locked.
pub fn isLocked(self: *Self) bool {
    return self._state.load(.acquire);
}

// =============================================================
// Imports
// =============================================================

const atomic = @import("std").atomic;
const is_test = @import("builtin").is_test;

const norn = @import("norn");
const arch = norn.arch;
