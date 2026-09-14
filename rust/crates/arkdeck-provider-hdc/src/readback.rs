//! Swift `ProviderReconcileOutcome`: what a readback of a durable intent
//! concludes about the mutation it was paired with.

use std::collections::BTreeMap;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Reconcile {
    /// The postcondition holds: the mutation completed, with the facts that
    /// prove it.
    ConfirmedCompleted(BTreeMap<String, String>),
    /// The postcondition does not hold: the mutation never took effect and
    /// may be replayed.
    ConfirmedNotExecuted,
    /// Nothing proves either way; the outcome stays unknown.
    StillUnknown(String),
}
