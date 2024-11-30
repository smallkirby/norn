const atomic = @import("std").atomic;

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

/// Unlock the spin lock.
pub fn unlock(self: *Self) void {
    self._state.store(false, .release);
}
