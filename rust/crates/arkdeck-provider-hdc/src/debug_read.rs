//! Fixed read-only Debug probes. Callers provide an adopted route, never argv.
use crate::{
    CommandOutcome, Direction, HdcDispatch, PortRule, ProcessPlan, Receipt, SemanticOutputParser,
};
use std::{collections::BTreeSet, time::Duration};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DebugReadTemplate {
    PackageInventory,
    DebugParameter,
    WindowInventory,
    Uptime,
}
impl DebugReadTemplate {
    pub fn parse(value: &str) -> Option<Self> {
        [
            Self::PackageInventory,
            Self::DebugParameter,
            Self::WindowInventory,
            Self::Uptime,
        ]
        .into_iter()
        .find(|template| template.definition().id == value)
    }
    fn definition(self) -> &'static arkdeck_contract::DebugTemplateDefinition {
        &arkdeck_contract::DEBUG_TEMPLATES[match self {
            Self::PackageInventory => 0,
            Self::DebugParameter => 1,
            Self::WindowInventory => 2,
            Self::Uptime => 3,
        }]
    }
    pub fn raw(self) -> &'static str {
        match self {
            Self::PackageInventory => "device.packageInventory",
            Self::DebugParameter => "device.debugParameterRead",
            Self::WindowInventory => "device.windowInventory",
            Self::Uptime => "device.uptime",
        }
    }

    /// Job verification, including zero-exit HDC transport failures. Raw output
    /// is not decoded here: the declared sensitive Artifact retains its bytes.
    pub fn verify(self, receipt: &Receipt) -> crate::Outcome {
        use crate::{CommandFailure, Outcome};
        if receipt.truncated {
            return Outcome::Failed {
                code: "truncated",
                detail: "template output exceeded its byte budget".into(),
            };
        }
        if receipt.exit_status != 0 {
            return Outcome::Failed {
                code: "templateExitStatus",
                detail: format!("template {} exited {}", self.raw(), receipt.exit_status),
            };
        }
        let mut parser = SemanticOutputParser::new();
        parser.consume(&receipt.stdout);
        parser.consume(&receipt.stderr);
        if let CommandOutcome::Failure(failure) = parser.finish(0) {
            let detail = match failure {
                CommandFailure::Unauthorized => "target authorization is unavailable".into(),
                CommandFailure::Offline => "target is offline".into(),
                CommandFailure::ExplicitFailureMarker => "HDC reported an explicit failure".into(),
                CommandFailure::NonZeroExit(code) => format!("HDC exited {code}"),
            };
            return Outcome::Failed {
                code: "targetUnavailable",
                detail,
            };
        }
        let millis = receipt.duration.as_millis()
            + u128::from(receipt.duration.subsec_nanos() % 1_000_000 >= 500_000);
        Outcome::Verified(std::collections::BTreeMap::from([
            ("templateId".into(), self.raw().into()),
            (
                "remoteCommand".into(),
                self.plan("").arguments[2..].join(" "),
            ),
            ("exitStatus".into(), receipt.exit_status.to_string()),
            ("durationMilliseconds".into(), millis.to_string()),
            ("stdoutByteCount".into(), receipt.stdout.len().to_string()),
            ("stdoutTruncated".into(), "false".into()),
            ("stderrByteCount".into(), receipt.stderr.len().to_string()),
        ]))
    }

    pub fn plan(self, connect_key: &str) -> ProcessPlan {
        let definition = self.definition();
        plan(
            connect_key,
            definition.command,
            definition.output_byte_budget,
        )
    }
}
fn plan(key: &str, command: &[&str], capture_bytes: usize) -> ProcessPlan {
    ProcessPlan {
        arguments: ["-t", key]
            .into_iter()
            .chain(command.iter().copied())
            .map(str::to_owned)
            .collect(),
        timeout: Duration::from_secs(30),
        capture_bytes,
    }
}
#[derive(Debug)]
pub struct DebugInventory {
    pub packages: Vec<String>,
    pub port_rules: Vec<PortRule>,
    pub warnings: Vec<&'static str>,
}
fn read(dispatch: &dyn HdcDispatch, plan: &ProcessPlan) -> Option<Receipt> {
    let receipt = dispatch.dispatch(plan).ok()?;
    let mut semantic = SemanticOutputParser::new();
    semantic.consume(&receipt.stdout);
    semantic.consume(&receipt.stderr);
    (receipt.exit_status == 0
        && !receipt.truncated
        && !matches!(semantic.finish(0), CommandOutcome::Failure(_)))
    .then_some(receipt)
}
/// Mirrors the package inventory parser, before the stricter wire projection check.
fn package_names(bytes: &[u8]) -> Vec<String> {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return vec![];
    };
    text.lines()
        .map(str::trim)
        .filter(|name| {
            let parts: Vec<_> = name.split('.').collect();
            parts.len() >= 2
                && parts.iter().enumerate().all(|(index, part)| {
                    !part.is_empty()
                        && (index != 0
                            || part.as_bytes().first().is_some_and(u8::is_ascii_alphabetic))
                        && part.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
                })
        })
        .map(str::to_owned)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}
fn port_rules(bytes: &[u8], direction: Direction) -> Vec<PortRule> {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return vec![];
    };
    text.lines()
        .filter_map(|line| {
            let ports: Vec<i64> = line
                .split_whitespace()
                .filter_map(|token| token.strip_prefix("tcp:")?.parse().ok())
                .filter(|port| (1024..=65535).contains(port))
                .take(2)
                .collect();
            (ports.len() == 2).then(|| PortRule {
                direction,
                local_port: ports[0],
                remote_port: ports[1],
            })
        })
        .collect()
}
/// Independent reads run concurrently, with one route retained for the snapshot.
pub fn debug_inventory(dispatch: &(dyn HdcDispatch + Sync), key: &str) -> DebugInventory {
    let (package, forward, reverse) = std::thread::scope(|scope| {
        let package =
            scope.spawn(|| read(dispatch, &DebugReadTemplate::PackageInventory.plan(key)));
        let forward = scope.spawn(|| read(dispatch, &plan(key, &["fport", "ls"], 128 * 1024)));
        let reverse = read(dispatch, &plan(key, &["rport", "ls"], 128 * 1024));
        (package.join().unwrap(), forward.join().unwrap(), reverse)
    });
    let mut warnings = vec![];
    let packages = match package {
        Some(receipt) => {
            let names = package_names(&receipt.stdout);
            if names.is_empty() && !receipt.stdout.is_empty() {
                warnings.push("packageInventoryUnparseable");
            }
            names
        }
        None => {
            warnings.push("packageInventoryUnavailable");
            vec![]
        }
    };
    let mut rules = vec![];
    for (receipt, direction, warning) in [
        (forward, Direction::Forward, "forwardRulesUnavailable"),
        (reverse, Direction::Reverse, "reverseRulesUnavailable"),
    ] {
        match receipt {
            Some(receipt) => rules.extend(port_rules(&receipt.stdout, direction)),
            None => warnings.push(warning),
        }
    }
    rules.sort_by_key(|rule| (rule.direction.raw(), rule.local_port, rule.remote_port));
    warnings.sort_unstable();
    DebugInventory {
        packages,
        port_rules: rules,
        warnings,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DispatchFailure;
    use std::sync::{Barrier, Mutex};
    struct Dispatcher {
        calls: Mutex<Vec<ProcessPlan>>,
        barrier: Barrier,
        fail: bool,
    }
    impl HdcDispatch for Dispatcher {
        fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
            self.calls.lock().unwrap().push(plan.clone());
            self.barrier.wait(); // All three independent probes must reach dispatch together.
            let command = &plan.arguments[2];
            let (stdout, stderr, truncated) = match (command.as_str(), self.fail) {
                ("shell", false) => (
                    b" com.example.z\ncom.example.a\ncom.example.a\nnoise\n".to_vec(),
                    vec![],
                    false,
                ),
                ("fport", false) => (b"tcp:9000 tcp:8000\ntcp:1 tcp:80\n".to_vec(), vec![], false),
                ("rport", false) => (b"tcp:7000 tcp:6000\n".to_vec(), vec![], false),
                ("shell", true) => (
                    b"com.example.app".to_vec(),
                    b"[Fail] unauthorized".to_vec(),
                    false,
                ),
                ("fport", true) => (b"tcp:9000 tcp:8000".to_vec(), vec![], true),
                _ => return Err(DispatchFailure::Unobservable("lost receipt".into())),
            };
            Ok(Receipt {
                stdout,
                stderr,
                truncated,
                exit_status: 0,
                duration: Duration::ZERO,
            })
        }
    }
    #[test]
    fn inventory_is_concurrent_target_bound_sorted_and_bounded() {
        let dispatcher = Dispatcher {
            calls: Mutex::new(vec![]),
            barrier: Barrier::new(3),
            fail: false,
        };
        let result = debug_inventory(&dispatcher, "exact-key");
        assert_eq!(result.packages, ["com.example.a", "com.example.z"]);
        assert_eq!(result.port_rules.len(), 2);
        assert_eq!(result.port_rules[0].direction, Direction::Forward);
        assert_eq!(result.port_rules[1].local_port, 7000);
        assert!(result.warnings.is_empty());
        for call in dispatcher.calls.lock().unwrap().iter() {
            assert_eq!(&call.arguments[..2], ["-t", "exact-key"]);
            assert_eq!(call.timeout, Duration::from_secs(30));
            assert_eq!(
                call.capture_bytes,
                if call.arguments[2] == "shell" {
                    2 * 1024 * 1024
                } else {
                    128 * 1024
                }
            );
        }
    }
    #[test]
    fn independent_failures_never_publish_partial_inventories_or_retry() {
        let dispatcher = Dispatcher {
            calls: Mutex::new(vec![]),
            barrier: Barrier::new(3),
            fail: true,
        };
        let result = debug_inventory(&dispatcher, "exact-key");
        assert!(result.packages.is_empty() && result.port_rules.is_empty());
        assert_eq!(
            result.warnings,
            [
                "forwardRulesUnavailable",
                "packageInventoryUnavailable",
                "reverseRulesUnavailable"
            ]
        );
        assert_eq!(dispatcher.calls.lock().unwrap().len(), 3);
    }
    #[test]
    fn closed_templates_preserve_commands_and_capture_budgets() {
        for (name, command, budget) in [
            (
                "device.packageInventory",
                vec!["shell", "bm", "dump", "-a"],
                2 * 1024 * 1024,
            ),
            (
                "device.debugParameterRead",
                vec!["shell", "param", "get", "persist.ace.debug.enabled"],
                4096,
            ),
            (
                "device.windowInventory",
                vec![
                    "shell",
                    "hidumper",
                    "-s",
                    "WindowManagerService",
                    "-a",
                    "-a",
                ],
                8 * 1024 * 1024,
            ),
            ("device.uptime", vec!["shell", "uptime"], 16 * 1024),
        ] {
            let plan = DebugReadTemplate::parse(name).unwrap().plan("key");
            assert_eq!(&plan.arguments[2..], command);
            assert_eq!(plan.capture_bytes, budget);
        }
        assert!(DebugReadTemplate::parse("shell rm -rf /").is_none());
        assert!(package_names(&[0xff]).is_empty());
        assert!(port_rules(&[0xff], Direction::Forward).is_empty());
        assert_eq!(package_names(b"com.1part\n"), ["com.1part"]);
    }
}
