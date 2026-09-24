//! Swift `DeviceMutationLaneCoordinator` (`ArkDeckCore/DeviceTargeting.swift`)
//! for the Rust Runtime (TASK-XPA-014, M2): one mutation lane per Target, in
//! memory, kept by the Target owner as Swift's engine keeps one coordinator.
//!
//! A request waits for its lane behind every request that asked before it, in
//! arrival order and with no deadline, and the lane passes straight to the
//! first waiter when its holder lets go of it, so no later request overtakes
//! (Swift `acquire` and `release`). The lane is the guard [`MutationLane`]:
//! whatever ends a holder's hold — its return, its error, its panic — drops
//! the guard and hands the lane on, and a waiter that stops waiting, because
//! it was abandoned or because it is unwinding, leaves the queue the same
//! way. One holder identity holds or awaits at most one lane at a time (Swift
//! `duplicateRequest`). Nothing here is durable: a process that ends takes its
//! lanes with it, as Swift's actor state goes with its process.
//!
//! Lock order: a lane is awaited holding no Target lock — its key is read in a
//! Target transaction that has ended before the wait (`TargetStore::
//! enter_mutation_lane`) — and its holder takes Target transactions inside
//! it: the lane first, the transactions after. This lock is the innermost one
//! a Runtime thread takes while it waits for a lane. It is held only inside
//! these methods, where nothing is waited for but its own condition variable,
//! and where the only foreign code run is an abandonment predicate, which
//! reads a run's cancellation request and takes no other lock.
use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

/// How often a waiter that may be abandoned asks again whether it is, while
/// no holder lets go of its lane.
const ABANDON_POLL: Duration = Duration::from_millis(20);

/// Every Target's mutation lane in one owner.
#[derive(Default)]
pub(crate) struct DeviceMutationLanes {
    state: Mutex<Lanes>,
    changed: Condvar,
}

#[derive(Default)]
struct Lanes {
    /// Each lane's holder, by lane key.
    active: HashMap<String, String>,
    /// Each lane's waiters, by lane key, in arrival order.
    queued: HashMap<String, VecDeque<String>>,
}

impl Lanes {
    fn holds_or_awaits(&self, holder: &str) -> bool {
        self.active.values().any(|active| active == holder)
            || self
                .queued
                .values()
                .any(|waiters| waiters.iter().any(|waiter| waiter == holder))
    }
}

/// Where a holder stands in a lane (Swift `DeviceMutationLaneRequestState`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaneState {
    /// It holds the lane.
    Active,
    /// It waits behind the holder (Swift `.queued(reason: .deviceLaneBusy)`).
    Queued,
}

/// Why a request was refused a lane before it held or awaited one.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum LaneRefusal {
    /// The holder already holds or awaits a lane (Swift `duplicateRequest`).
    Duplicate(String),
}

impl fmt::Display for LaneRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Duplicate(holder) => {
                write!(f, "{holder} already holds or awaits a Target mutation lane")
            }
        }
    }
}

/// A held lane. Dropping it hands the lane to the first waiter, or frees it;
/// dropping one that was still waiting takes its holder out of the queue.
#[must_use = "the lane is let go of as soon as its guard is dropped"]
pub struct MutationLane<'a> {
    lanes: &'a DeviceMutationLanes,
    key: String,
    holder: String,
}

impl DeviceMutationLanes {
    /// The lanes as the last thread left them. A thread can only panic in
    /// here between whole updates, so a poisoned lock still guards
    /// consistent lanes, and a guard must let go of its lane regardless.
    fn lock(&self) -> MutexGuard<'_, Lanes> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Enters the lane `key` for `holder`: at once when nobody holds it, else
    /// once every earlier request has let go of it. `abandon` is asked while
    /// the request waits; once it answers true the request leaves the queue
    /// and gets no lane (`None`). A holder that already holds or awaits a
    /// lane is refused.
    pub(crate) fn enter(
        &self,
        key: &str,
        holder: &str,
        abandon: Option<&dyn Fn() -> bool>,
    ) -> Result<Option<MutationLane<'_>>, LaneRefusal> {
        {
            let mut lanes = self.lock();
            if lanes.holds_or_awaits(holder) {
                return Err(LaneRefusal::Duplicate(holder.to_owned()));
            }
            if lanes.active.contains_key(key) {
                lanes
                    .queued
                    .entry(key.to_owned())
                    .or_default()
                    .push_back(holder.to_owned());
            } else {
                lanes.active.insert(key.to_owned(), holder.to_owned());
            }
        }
        self.changed.notify_all();
        // From here on the guard owns the holder's place, held or queued, so
        // every way out of the wait below lets go of it. It is declared before
        // the lock guard, which an unwinding thread therefore drops first.
        let lane = MutationLane {
            lanes: self,
            key: key.to_owned(),
            holder: holder.to_owned(),
        };
        let mut lanes = self.lock();
        loop {
            if lanes.active.get(key).is_some_and(|active| active == holder) {
                return Ok(Some(lane));
            }
            match abandon {
                Some(abandon) if abandon() => {
                    drop(lanes);
                    drop(lane);
                    return Ok(None);
                }
                Some(_) => {
                    lanes = self
                        .changed
                        .wait_timeout(lanes, ABANDON_POLL)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
                None => {
                    lanes = self
                        .changed
                        .wait(lanes)
                        .unwrap_or_else(PoisonError::into_inner);
                }
            }
        }
    }

    /// Who waits for the lane `key`, first in line first.
    pub(crate) fn queue(&self, key: &str) -> Vec<String> {
        self.lock()
            .queued
            .get(key)
            .map(|waiters| waiters.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// Where `holder` stands in the lane `key`, if anywhere.
    pub(crate) fn state(&self, key: &str, holder: &str) -> Option<LaneState> {
        let lanes = self.lock();
        if lanes.active.get(key).is_some_and(|active| active == holder) {
            return Some(LaneState::Active);
        }
        lanes
            .queued
            .get(key)
            .is_some_and(|waiters| waiters.iter().any(|waiter| waiter == holder))
            .then_some(LaneState::Queued)
    }
}

impl MutationLane<'_> {
    /// The lane this guard holds or awaits.
    pub fn key(&self) -> &str {
        &self.key
    }
}

impl Drop for MutationLane<'_> {
    fn drop(&mut self) {
        let mut lanes = self.lanes.lock();
        if lanes
            .active
            .get(&self.key)
            .is_some_and(|active| *active == self.holder)
        {
            match lanes
                .queued
                .get_mut(&self.key)
                .and_then(VecDeque::pop_front)
            {
                Some(next) => {
                    lanes.active.insert(self.key.clone(), next);
                }
                None => {
                    lanes.active.remove(&self.key);
                }
            }
        } else if let Some(waiters) = lanes.queued.get_mut(&self.key) {
            waiters.retain(|waiter| *waiter != self.holder);
        }
        if lanes.queued.get(&self.key).is_some_and(VecDeque::is_empty) {
            lanes.queued.remove(&self.key);
        }
        drop(lanes);
        self.lanes.changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Instant;

    /// Waits, without a clock deciding anything, until `condition` holds; the
    /// bound only keeps a broken lane from hanging the suite.
    fn until(what: &str, condition: impl Fn() -> bool) {
        let started = Instant::now();
        while !condition() {
            assert!(
                started.elapsed() < Duration::from_secs(60),
                "never reached: {what}"
            );
            std::thread::yield_now();
        }
    }

    #[test]
    fn waiters_enter_one_at_a_time_in_arrival_order() {
        let lanes = DeviceMutationLanes::default();
        let first = lanes.enter("TGT-a", "job-1", None).unwrap().unwrap();
        let order = Mutex::new(Vec::new());
        std::thread::scope(|scope| {
            for holder in ["job-2", "job-3"] {
                let (lanes, order) = (&lanes, &order);
                scope.spawn(move || {
                    let lane = lanes.enter("TGT-a", holder, None).unwrap().unwrap();
                    order.lock().unwrap().push(holder);
                    drop(lane);
                });
                until(holder, || {
                    lanes.state("TGT-a", holder) == Some(LaneState::Queued)
                });
            }
            assert!(
                order.lock().unwrap().is_empty(),
                "nobody overtook the holder"
            );
            assert_eq!(lanes.state("TGT-a", "job-1"), Some(LaneState::Active));
            assert_eq!(lanes.queue("TGT-a"), ["job-2", "job-3"]);
            drop(first);
        });
        assert_eq!(*order.lock().unwrap(), ["job-2", "job-3"]);
        assert!(lanes.lock().active.is_empty());
        assert!(lanes.lock().queued.is_empty());
    }

    #[test]
    fn other_targets_are_not_held_up() {
        let lanes = DeviceMutationLanes::default();
        let _first = lanes.enter("TGT-a", "job-1", None).unwrap().unwrap();
        let second = lanes.enter("TGT-b", "job-2", None).unwrap().unwrap();
        assert_eq!(second.key(), "TGT-b");
        assert_eq!(lanes.state("TGT-b", "job-2"), Some(LaneState::Active));
    }

    #[test]
    fn one_holder_holds_or_awaits_one_lane() {
        let lanes = DeviceMutationLanes::default();
        let _held = lanes.enter("TGT-a", "job-1", None).unwrap().unwrap();
        for key in ["TGT-a", "TGT-b"] {
            assert_eq!(
                lanes.enter(key, "job-1", None).err(),
                Some(LaneRefusal::Duplicate("job-1".into()))
            );
        }
        let waiting = AtomicBool::new(true);
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let abandon = || !waiting.load(Ordering::SeqCst);
                assert!(
                    lanes
                        .enter("TGT-a", "job-2", Some(&abandon))
                        .unwrap()
                        .is_none()
                );
            });
            until("job-2 queued", || {
                lanes.state("TGT-a", "job-2") == Some(LaneState::Queued)
            });
            assert_eq!(
                lanes.enter("TGT-b", "job-2", None).err(),
                Some(LaneRefusal::Duplicate("job-2".into()))
            );
            waiting.store(false, Ordering::SeqCst);
        });
    }

    #[test]
    fn an_abandoned_waiter_leaves_the_queue_without_the_lane() {
        let lanes = DeviceMutationLanes::default();
        let first = lanes.enter("TGT-a", "job-1", None).unwrap().unwrap();
        let cancelled = AtomicBool::new(false);
        std::thread::scope(|scope| {
            let waiter = scope.spawn(|| {
                let abandon = || cancelled.load(Ordering::SeqCst);
                lanes
                    .enter("TGT-a", "job-2", Some(&abandon))
                    .map(|lane| lane.is_none())
            });
            until("job-2 queued", || {
                lanes.state("TGT-a", "job-2") == Some(LaneState::Queued)
            });
            cancelled.store(true, Ordering::SeqCst);
            assert_eq!(waiter.join().unwrap(), Ok(true));
        });
        assert_eq!(lanes.state("TGT-a", "job-2"), None);
        drop(first);
        assert!(lanes.lock().active.is_empty(), "nobody was handed the lane");
        assert!(lanes.enter("TGT-a", "job-3", None).unwrap().is_some());
    }

    #[test]
    fn a_holder_that_panics_hands_its_lane_on() {
        let lanes = DeviceMutationLanes::default();
        let panicked = std::thread::scope(|scope| {
            scope
                .spawn(|| {
                    let _lane = lanes.enter("TGT-a", "job-1", None).unwrap().unwrap();
                    panic!("the holder's step panicked");
                })
                .join()
        });
        assert!(panicked.is_err());
        assert_eq!(lanes.state("TGT-a", "job-1"), None);
        assert!(lanes.enter("TGT-a", "job-2", None).unwrap().is_some());
    }

    #[test]
    fn a_waiter_that_panics_leaves_the_queue() {
        let lanes = DeviceMutationLanes::default();
        let first = lanes.enter("TGT-a", "job-1", None).unwrap().unwrap();
        let fail = AtomicBool::new(false);
        let panicked = std::thread::scope(|scope| {
            let waiter = scope.spawn(|| {
                let abandon = || {
                    assert!(!fail.load(Ordering::SeqCst), "the predicate panicked");
                    false
                };
                let _ = lanes.enter("TGT-a", "job-2", Some(&abandon));
            });
            until("job-2 queued", || {
                lanes.state("TGT-a", "job-2") == Some(LaneState::Queued)
            });
            fail.store(true, Ordering::SeqCst);
            waiter.join()
        });
        assert!(panicked.is_err());
        assert_eq!(lanes.state("TGT-a", "job-2"), None);
        drop(first);
        assert!(
            lanes.lock().active.is_empty(),
            "no ghost was handed the lane"
        );
        assert!(lanes.enter("TGT-a", "job-3", None).unwrap().is_some());
    }
}
