//! Test support (feature `allocation-meter`): the system allocator, counting
//! the bytes each thread holds, so a test can bound what an operation holds at
//! once. A test binary installs [`AllocationMeter`] as its global allocator.
//! Production binaries never enable the feature.
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

/// The system allocator, counting on each thread the bytes that thread
/// allocated and has not freed, and the most it held since
/// [`peak_allocation`] began to measure. The counts are the sizes callers
/// ask for, so they do not depend on the allocator's own rounding or
/// bookkeeping, nor on what other threads do.
pub struct AllocationMeter;

thread_local! {
    // Constant, droppable-free cells: reading them never allocates.
    static HELD: Cell<isize> = const { Cell::new(0) };
    static PEAK: Cell<isize> = const { Cell::new(0) };
}

fn record(delta: isize) {
    let held = HELD.with(|held| {
        let now = held.get().wrapping_add(delta);
        held.set(now);
        now
    });
    PEAK.with(|peak| {
        if held > peak.get() {
            peak.set(held);
        }
    });
}

fn signed(size: usize) -> isize {
    isize::try_from(size).unwrap_or(isize::MAX)
}

// SAFETY: every call is forwarded unchanged to the system allocator; the
// meter only updates this thread's counters around it.
unsafe impl GlobalAlloc for AllocationMeter {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // SAFETY: the caller's contract for `alloc` is `System.alloc`'s.
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() {
            record(signed(layout.size()));
        }
        pointer
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        // SAFETY: the caller's contract for `alloc_zeroed` is `System`'s.
        let pointer = unsafe { System.alloc_zeroed(layout) };
        if !pointer.is_null() {
            record(signed(layout.size()));
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: `pointer` came from this allocator, which is `System`.
        unsafe { System.dealloc(pointer, layout) };
        record(-signed(layout.size()));
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        // SAFETY: `pointer` came from this allocator, which is `System`.
        let moved = unsafe { System.realloc(pointer, layout, size) };
        if !moved.is_null() {
            record(signed(size).wrapping_sub(signed(layout.size())));
        }
        moved
    }
}

/// Run `work` on this thread and return its result with the most bytes the
/// thread held at once while it ran, beyond what it held when it began. Only
/// meaningful in a binary whose global allocator is [`AllocationMeter`].
pub fn peak_allocation<T>(work: impl FnOnce() -> T) -> (T, usize) {
    let start = HELD.with(Cell::get);
    PEAK.with(|peak| peak.set(start));
    let result = work();
    let peak = PEAK.with(Cell::get);
    (result, usize::try_from(peak - start).unwrap_or(0))
}
