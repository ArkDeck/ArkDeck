//! Swift's port rules — `port-forward.create@1` and `port-forward.remove@1`
//! — as `HDCObservationProviderAdapter` handles them (`HDCPortForwardSpec`,
//! `portForwardSpec`, the `createPortForward`/`removePortForward`/
//! `readPortForwardPresence` lowerings, verdicts, persisted forms and
//! reconciliation): one rule between a host port and a device port in one
//! direction, created with `fport`/`rport`, removed with `fport rm`, and
//! read back from `fport ls` — the mutation judged by its exit status
//! alone, the truth by the readback the engine pairs with it.

use crate::capture_files::{FileActionError, FilePlan};
use crate::native_library::Reconcile;
use crate::operation::{Outcome, ProcessPlan, Receipt, RequestError};
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;

/// Swift `HDCPortForwardSpec`'s port range.
pub const PORT_MINIMUM: i64 = 1024;
pub const PORT_MAXIMUM: i64 = 65535;
/// The dispatcher's capture budget, as the other legs use it.
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;

/// Swift `HDCPortForwardDirection`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Direction {
    Forward,
    Reverse,
}

impl Direction {
    pub fn raw(self) -> &'static str {
        match self {
            Self::Forward => "forward",
            Self::Reverse => "reverse",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "forward" => Some(Self::Forward),
            "reverse" => Some(Self::Reverse),
            _ => None,
        }
    }

    /// The tag `fport ls` prints on a row of this direction.
    fn tag(self) -> &'static str {
        match self {
            Self::Forward => "[Forward]",
            Self::Reverse => "[Reverse]",
        }
    }
}

/// Swift `HDCPortForwardSpec`: the typed rule always names the host as
/// `local_port` and the device as `remote_port`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PortRule {
    pub direction: Direction,
    pub local_port: i64,
    pub remote_port: i64,
}

impl PortRule {
    /// Swift `HDCPortForwardSpec.init`: both ports inside `1024...65535`.
    pub fn new(
        direction: Direction,
        local_port: i64,
        remote_port: i64,
    ) -> Result<Self, RequestError> {
        for (value, field) in [(local_port, "localPort"), (remote_port, "remotePort")] {
            if !(PORT_MINIMUM..=PORT_MAXIMUM).contains(&value) {
                return Err(RequestError::OutOfBounds {
                    field,
                    detail: "1024...65535".into(),
                });
            }
        }
        Ok(Self {
            direction,
            local_port,
            remote_port,
        })
    }

    /// Swift `portForwardSpec` over the request's inputs: a known direction
    /// and two integer ports, or one refusal for all of them.
    pub fn from_inputs(inputs: &Map<String, Value>) -> Result<Self, FileActionError> {
        let direction = inputs
            .get("direction")
            .and_then(Value::as_str)
            .and_then(Direction::parse);
        let local_port = inputs.get("localPort").and_then(Value::as_i64);
        let remote_port = inputs.get("remotePort").and_then(Value::as_i64);
        let (Some(direction), Some(local_port), Some(remote_port)) =
            (direction, local_port, remote_port)
        else {
            return Err(FileActionError::Unsupported(
                "direction, localPort and remotePort are required for a port rule".into(),
            ));
        };
        Self::new(direction, local_port, remote_port).map_err(FileActionError::Request)
    }

    /// Swift `portForwardEndpoints`: forward rows are host -> device,
    /// reverse rows device -> host, so the endpoint order changes with the
    /// direction even though the rule always names host as `local_port`.
    pub fn endpoints(&self) -> [String; 2] {
        match self.direction {
            Direction::Forward => [
                format!("tcp:{}", self.local_port),
                format!("tcp:{}", self.remote_port),
            ],
            Direction::Reverse => [
                format!("tcp:{}", self.remote_port),
                format!("tcp:{}", self.local_port),
            ],
        }
    }

    /// Swift's persisted arguments, shared by the three intents.
    fn arguments(&self) -> Map<String, Value> {
        let mut arguments = Map::new();
        arguments.insert("direction".into(), Value::from(self.direction.raw()));
        arguments.insert("localPort".into(), Value::from(self.local_port));
        arguments.insert("remotePort".into(), Value::from(self.remote_port));
        arguments
    }

    /// Swift's decoder of a persisted rule.
    pub fn from_persisted(arguments: &Map<String, Value>) -> Result<Self, FileActionError> {
        Self::from_inputs(arguments)
    }

    /// Swift `readPortForwardPresence`'s reading of `fport ls`: trusted only
    /// on a clean, untruncated, UTF-8 answer; present when a row carries the
    /// direction's tag and the exact endpoint tuple in order.
    pub fn presence(&self, receipt: &Receipt) -> Option<bool> {
        if receipt.exit_status != 0 || receipt.truncated {
            return None;
        }
        let text = std::str::from_utf8(&receipt.stdout).ok()?;
        let expected = self.endpoints();
        let tag = self.direction.tag();
        Some(text.lines().any(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            fields.contains(&tag)
                && fields.len() >= expected.len()
                && fields
                    .windows(expected.len())
                    .any(|window| window == expected.iter().map(String::as_str).collect::<Vec<_>>())
        }))
    }
}

/// Swift `.hdc(.createPortForward)`, `.hdc(.removePortForward)` and
/// `.hdc(.readPortForwardPresence)`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PortAction {
    Create(PortRule),
    Remove(PortRule),
    ReadPresence(PortRule),
}

impl fmt::Display for PortAction {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.persisted().0)
    }
}

impl PortAction {
    /// Swift `HDCObservationProviderAdapter.action` for the steps of the two
    /// operations: `createPortForward`, `removePortForward`, and
    /// `verifyRemoteState` — which reads the rule's presence for these two
    /// operations only. Other step kinds are not this module's.
    pub fn for_step(
        step_kind: &str,
        operation_reference: &str,
        inputs: &Map<String, Value>,
    ) -> Result<Option<Self>, FileActionError> {
        let port_operation = operation_reference == "port-forward.create@1"
            || operation_reference == "port-forward.remove@1";
        match step_kind {
            "createPortForward" => Ok(Some(Self::Create(PortRule::from_inputs(inputs)?))),
            "removePortForward" => Ok(Some(Self::Remove(PortRule::from_inputs(inputs)?))),
            "verifyRemoteState" if port_operation => {
                Ok(Some(Self::ReadPresence(PortRule::from_inputs(inputs)?)))
            }
            _ => Ok(None),
        }
    }

    pub fn rule(&self) -> &PortRule {
        match self {
            Self::Create(rule) | Self::Remove(rule) | Self::ReadPresence(rule) => rule,
        }
    }

    pub fn effect(&self) -> &'static str {
        match self {
            Self::Create(_) | Self::Remove(_) => "deviceMutation",
            Self::ReadPresence(_) => "readOnly",
        }
    }

    /// Swift's lowering: `fport`/`rport` by direction for a create, `fport
    /// rm` with the tuple for a remove, `fport ls` for the readback — one
    /// 30 s process each.
    pub fn lower(&self, step_id: &str, connect_key: Option<&str>) -> Result<FilePlan, String> {
        let key = match connect_key {
            Some(key) if !key.is_empty() => key,
            _ => {
                return Err(format!(
                    "factsUnavailable(\"{step_id} has no descriptor-bound target connect key\")"
                ));
            }
        };
        let mut arguments = vec!["-t".to_owned(), key.to_owned()];
        match self {
            Self::Create(rule) => {
                arguments.push(
                    match rule.direction {
                        Direction::Forward => "fport",
                        Direction::Reverse => "rport",
                    }
                    .to_owned(),
                );
                arguments.extend(rule.endpoints());
            }
            Self::Remove(rule) => {
                arguments.extend(["fport".to_owned(), "rm".to_owned()]);
                arguments.extend(rule.endpoints());
            }
            Self::ReadPresence(_) => arguments.extend(["fport".to_owned(), "ls".to_owned()]),
        }
        Ok(FilePlan::Process(ProcessPlan {
            arguments,
            timeout: Duration::from_secs(30),
            capture_bytes: CAPTURE_BYTES,
        }))
    }

    /// Swift's verdicts: a mutation is `portForwardFailed` on a non-zero
    /// exit and otherwise verified with the host port — no stdout is read,
    /// the truth comes from the paired readback; the readback is unknown
    /// unless trustworthy, and otherwise `present` true or false.
    pub fn verify(&self, receipt: &Receipt) -> Outcome {
        match self {
            Self::Create(rule) | Self::Remove(rule) => {
                if receipt.exit_status != 0 {
                    return Outcome::Failed {
                        code: "portForwardFailed",
                        detail: format!("tcp:{}", rule.local_port),
                    };
                }
                Outcome::Verified(BTreeMap::from([(
                    "localPort".to_owned(),
                    rule.local_port.to_string(),
                )]))
            }
            Self::ReadPresence(rule) => match rule.presence(receipt) {
                None => {
                    Outcome::Unknown("port-forward presence readback is not trustworthy".into())
                }
                Some(present) => Outcome::Verified(BTreeMap::from([(
                    "present".to_owned(),
                    if present { "true" } else { "false" }.to_owned(),
                )])),
            },
        }
    }

    /// Swift's `reconciliationReadback`: both mutations read the rule's
    /// presence back; the readback itself has none.
    pub fn readback(&self) -> Option<Self> {
        match self {
            Self::Create(rule) | Self::Remove(rule) => Some(Self::ReadPresence(rule.clone())),
            Self::ReadPresence(_) => None,
        }
    }

    /// Swift's `desiredPresence`: a created rule should be listed, a removed
    /// one should not.
    pub fn desired_presence(&self) -> Option<bool> {
        match self {
            Self::Create(_) => Some(true),
            Self::Remove(_) => Some(false),
            Self::ReadPresence(_) => None,
        }
    }

    /// Swift `concludeReadback` over a readback's outcome: a trustworthy
    /// presence equal to the desired one concludes the mutation as
    /// completed, a different one as not executed; an untrustworthy
    /// readback, or a readback that was not paired with a mutation, leaves
    /// it unknown.
    pub fn conclude(&self, readback: Outcome) -> Reconcile {
        let Some(desired) = self.desired_presence() else {
            return Reconcile::StillUnknown("readback was not paired with a mutation".into());
        };
        match readback {
            Outcome::Verified(summary) => match summary.get("present").map(String::as_str) {
                Some("true") => Self::concluded(true, desired),
                Some("false") => Self::concluded(false, desired),
                _ => Reconcile::StillUnknown("readback was not paired with a mutation".into()),
            },
            Outcome::Unknown(reason) => Reconcile::StillUnknown(reason),
            Outcome::Failed { code, detail } => {
                Reconcile::StillUnknown(format!("{code}: {detail}"))
            }
            Outcome::Unsupported(detail) => Reconcile::StillUnknown(detail),
        }
    }

    fn concluded(present: bool, desired: bool) -> Reconcile {
        if present == desired {
            Reconcile::ConfirmedCompleted(BTreeMap::from([(
                "postconditionPresent".to_owned(),
                present.to_string(),
            )]))
        } else {
            Reconcile::ConfirmedNotExecuted
        }
    }

    /// Swift `reconcile` without a readback: a device mutation needs
    /// positive readback evidence to conclude.
    pub fn reconcile_without_readback(&self) -> Reconcile {
        match self {
            Self::Create(_) | Self::Remove(_) => Reconcile::StillUnknown(
                "device mutation needs a readback pass before it can be concluded".into(),
            ),
            Self::ReadPresence(_) => Reconcile::ConfirmedNotExecuted,
        }
    }

    /// Swift's durable typed intents.
    pub fn persisted(&self) -> (&'static str, Map<String, Value>) {
        match self {
            Self::Create(rule) => ("hdc.createPortForward", rule.arguments()),
            Self::Remove(rule) => ("hdc.removePortForward", rule.arguments()),
            Self::ReadPresence(rule) => ("hdc.readPortForwardPresence", rule.arguments()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const KEY: &str = "150100424a544e4600";

    fn receipt(stdout: &str, exit_status: i32) -> Receipt {
        Receipt {
            exit_status,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(100),
        }
    }

    fn arguments(action: &PortAction) -> Vec<String> {
        let FilePlan::Process(process) = action.lower("create-port-rule", Some(KEY)).unwrap()
        else {
            panic!("one process")
        };
        assert_eq!(process.timeout, Duration::from_secs(30));
        process.arguments
    }

    fn forward() -> PortRule {
        PortRule::new(Direction::Forward, 23451, 34561).unwrap()
    }

    fn reverse() -> PortRule {
        PortRule::new(Direction::Reverse, 23452, 34562).unwrap()
    }

    /// Swift `HDCPortForwardSpec.init` and `portForwardSpec`.
    #[test]
    fn the_rule_holds_swift_s_bounds_and_reads_swift_s_inputs() {
        assert_eq!(
            PortRule::new(Direction::Forward, 1023, 34561)
                .unwrap_err()
                .to_string(),
            "outOfBounds(field: \"localPort\", detail: \"1024...65535\")"
        );
        assert_eq!(
            PortRule::new(Direction::Forward, 1024, 65536)
                .unwrap_err()
                .to_string(),
            "outOfBounds(field: \"remotePort\", detail: \"1024...65535\")"
        );
        let inputs = |value: Value| value.as_object().cloned().unwrap();
        assert_eq!(
            PortRule::from_inputs(&inputs(
                json!({"direction": "forward", "localPort": 23451, "remotePort": 34561})
            ))
            .unwrap(),
            forward()
        );
        for incomplete in [
            json!({"direction": "sideways", "localPort": 23451, "remotePort": 34561}),
            json!({"direction": "forward", "localPort": "23451", "remotePort": 34561}),
            json!({"direction": "forward", "localPort": 23451}),
            json!({}),
        ] {
            assert_eq!(
                PortRule::from_inputs(&inputs(incomplete))
                    .unwrap_err()
                    .to_string(),
                "unsupportedAction(\"direction, localPort and remotePort are required for a port rule\")"
            );
        }
        assert_eq!(
            PortRule::from_inputs(&inputs(
                json!({"direction": "reverse", "localPort": 80, "remotePort": 34561})
            ))
            .unwrap_err()
            .to_string(),
            "outOfBounds(field: \"localPort\", detail: \"1024...65535\")"
        );
        assert_eq!(forward().endpoints(), ["tcp:23451", "tcp:34561"]);
        assert_eq!(reverse().endpoints(), ["tcp:34562", "tcp:23452"]);
        let step = |kind: &str, reference: &str| {
            PortAction::for_step(
                kind,
                reference,
                &inputs(json!({"direction": "forward", "localPort": 23451, "remotePort": 34561})),
            )
            .unwrap()
        };
        assert_eq!(
            step("createPortForward", "port-forward.create@1"),
            Some(PortAction::Create(forward()))
        );
        assert_eq!(
            step("removePortForward", "port-forward.remove@1"),
            Some(PortAction::Remove(forward()))
        );
        assert_eq!(
            step("verifyRemoteState", "port-forward.create@1"),
            Some(PortAction::ReadPresence(forward()))
        );
        assert_eq!(
            step("verifyRemoteState", "port-forward.remove@1"),
            Some(PortAction::ReadPresence(forward()))
        );
        assert_eq!(step("verifyRemoteState", "debug.hap@1"), None);
        assert_eq!(step("probeDevice", "port-forward.create@1"), None);
    }

    /// Swift `DeviceProviderContractTests`' canonical full-task tuples.
    #[test]
    fn the_lowering_uses_the_canonical_full_hdc_task_tuple() {
        assert_eq!(
            arguments(&PortAction::Create(forward())),
            ["-t", KEY, "fport", "tcp:23451", "tcp:34561"]
        );
        assert_eq!(
            arguments(&PortAction::Create(reverse())),
            ["-t", KEY, "rport", "tcp:34562", "tcp:23452"]
        );
        assert_eq!(
            arguments(&PortAction::Remove(forward())),
            ["-t", KEY, "fport", "rm", "tcp:23451", "tcp:34561"]
        );
        assert_eq!(
            arguments(&PortAction::Remove(reverse())),
            ["-t", KEY, "fport", "rm", "tcp:34562", "tcp:23452"]
        );
        for rule in [forward(), reverse()] {
            assert_eq!(
                arguments(&PortAction::ReadPresence(rule)),
                ["-t", KEY, "fport", "ls"]
            );
        }
        assert_eq!(
            PortAction::Create(forward())
                .lower("create-port-rule", Some(""))
                .unwrap_err(),
            "factsUnavailable(\"create-port-rule has no descriptor-bound target connect key\")"
        );
    }

    /// Swift's verdicts: the mutation by exit status alone, the readback by
    /// tuple order and direction.
    #[test]
    fn the_verdicts_follow_swift() {
        let create = PortAction::Create(forward());
        assert_eq!(
            create.verify(&receipt("Forwardport result:OK\n", 0)),
            Outcome::Verified(BTreeMap::from([(
                "localPort".to_owned(),
                "23451".to_owned()
            )]))
        );
        assert_eq!(
            create.verify(&receipt("[Fail]Forwardport result failed\n", 1)),
            Outcome::Failed {
                code: "portForwardFailed",
                detail: "tcp:23451".into()
            }
        );
        assert_eq!(
            PortAction::Remove(reverse()).verify(&receipt("", 1)),
            Outcome::Failed {
                code: "portForwardFailed",
                detail: "tcp:23452".into()
            }
        );
        let rows = "tcp:23451 tcp:34561 [Forward]\ntcp:34561 tcp:23451 [Reverse]\n";
        let presence = |rule: PortRule, text: &str| match PortAction::ReadPresence(rule)
            .verify(&receipt(text, 0))
        {
            Outcome::Verified(summary) => summary["present"].clone(),
            other => panic!("{other:?}"),
        };
        assert_eq!(presence(forward(), rows), "true");
        assert_eq!(
            presence(
                PortRule::new(Direction::Reverse, 23451, 34561).unwrap(),
                rows
            ),
            "true"
        );
        assert_eq!(
            presence(forward(), "tcp:34561 tcp:23451 [Forward]\n"),
            "false",
            "swapped endpoints are a different task"
        );
        assert_eq!(
            presence(forward(), "tcp:23451 tcp:34561 [Reverse]\n"),
            "false",
            "the same endpoints in the other direction are a different task"
        );
        assert_eq!(
            presence(
                forward(),
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa    tcp:23451 tcp:34561    [Forward]\n"
            ),
            "true",
            "the device's own row shape"
        );
        assert_eq!(
            presence(forward(), "tcp:23451\ttcp:34561\t[Forward]"),
            "true"
        );
        assert_eq!(presence(forward(), ""), "false");
        assert_eq!(
            presence(forward(), "tcp:23451 tcp:34561\n"),
            "false",
            "no direction tag"
        );
        assert_eq!(
            PortAction::ReadPresence(forward()).verify(&receipt(rows, 1)),
            Outcome::Unknown("port-forward presence readback is not trustworthy".into())
        );
        assert_eq!(
            PortAction::ReadPresence(forward()).verify(&Receipt {
                truncated: true,
                ..receipt(rows, 0)
            }),
            Outcome::Unknown("port-forward presence readback is not trustworthy".into())
        );
        assert_eq!(
            PortAction::ReadPresence(forward()).verify(&Receipt {
                stdout: vec![0xff],
                ..receipt("", 0)
            }),
            Outcome::Unknown("port-forward presence readback is not trustworthy".into())
        );
    }

    /// Swift's readback table and its conclusions.
    #[test]
    fn readbacks_conclude_as_swift_concludes_them() {
        let create = PortAction::Create(forward());
        let remove = PortAction::Remove(forward());
        assert_eq!(create.readback(), Some(PortAction::ReadPresence(forward())));
        assert_eq!(remove.readback(), Some(PortAction::ReadPresence(forward())));
        assert_eq!(PortAction::ReadPresence(forward()).readback(), None);
        assert_eq!(
            (
                create.desired_presence(),
                remove.desired_presence(),
                PortAction::ReadPresence(forward()).desired_presence()
            ),
            (Some(true), Some(false), None)
        );
        let present =
            Outcome::Verified(BTreeMap::from([("present".to_owned(), "true".to_owned())]));
        let absent =
            Outcome::Verified(BTreeMap::from([("present".to_owned(), "false".to_owned())]));
        assert_eq!(
            create.conclude(present.clone()),
            Reconcile::ConfirmedCompleted(BTreeMap::from([(
                "postconditionPresent".to_owned(),
                "true".to_owned()
            )]))
        );
        assert_eq!(
            create.conclude(absent.clone()),
            Reconcile::ConfirmedNotExecuted
        );
        assert_eq!(
            remove.conclude(absent),
            Reconcile::ConfirmedCompleted(BTreeMap::from([(
                "postconditionPresent".to_owned(),
                "false".to_owned()
            )]))
        );
        assert_eq!(
            remove.conclude(present.clone()),
            Reconcile::ConfirmedNotExecuted
        );
        assert_eq!(
            create.conclude(Outcome::Unknown("u".into())),
            Reconcile::StillUnknown("u".into())
        );
        assert_eq!(
            PortAction::ReadPresence(forward()).conclude(present),
            Reconcile::StillUnknown("readback was not paired with a mutation".into())
        );
        assert_eq!(
            create.reconcile_without_readback(),
            Reconcile::StillUnknown(
                "device mutation needs a readback pass before it can be concluded".into()
            )
        );
        assert_eq!(
            PortAction::ReadPresence(forward()).reconcile_without_readback(),
            Reconcile::ConfirmedNotExecuted
        );
        assert_eq!(
            (
                create.effect(),
                PortAction::ReadPresence(forward()).effect()
            ),
            ("deviceMutation", "readOnly")
        );
    }

    /// Swift's durable intents.
    #[test]
    fn the_persisted_forms_follow_swift() {
        for (action, kind) in [
            (PortAction::Create(reverse()), "hdc.createPortForward"),
            (PortAction::Remove(reverse()), "hdc.removePortForward"),
            (
                PortAction::ReadPresence(reverse()),
                "hdc.readPortForwardPresence",
            ),
        ] {
            let (persisted_kind, arguments) = action.persisted();
            assert_eq!(persisted_kind, kind);
            assert_eq!(
                Value::Object(arguments.clone()),
                json!({"direction": "reverse", "localPort": 23452, "remotePort": 34562})
            );
            assert_eq!(PortRule::from_persisted(&arguments).unwrap(), reverse());
            assert_eq!(action.to_string(), kind);
        }
    }
}
