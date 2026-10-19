//! A closed, bounded read of one kernel boot. The optional fault report is
//! held in RAM by its controller, never read from persistent device storage.
use crate::{Outcome, Receipt};
use std::collections::BTreeMap;

pub(crate) const CAPTURE_BYTES: usize = 4096;
// No caller value is interpolated. Reading boot_id again rejects a snapshot
// spanning a reboot. A report must be the controller's owner-only RAM file;
// a missing/unreadable or duplicate controller report cannot mean healthy.
pub(crate) const QUERY: &str = r#"set -eu
t=/system/bin/toybox
printf 'ARKDECK_BOOT_CONTEXT_V1\n'
$t cat /proc/sys/kernel/random/boot_id
$t cat /proc/uptime
holder=
for p in /proc/[0-9]*; do
    bytes=$($t od -An -v -tx1 -N 30 "$p/cmdline" 2>/dev/null) || continue
    command=
    for byte in $bytes; do command=$command$byte; done
    if test "$command" = 2f61726b6465636b2d626f6f742d6c6f6f702f636f6e74726f6c6c657200; then
        test -z "$holder"
        holder=$p
    fi
done
if test -n "$holder"; then
    report=$holder/fd/9
    test -f "$report"
    path=$($t readlink "$report")
    case "$path" in '/arkdeck-boot-loop/report'|'/arkdeck-boot-loop/report (deleted)') ;; *) exit 1;; esac
    test "$($t stat -L -c '%u:%a' "$report")" = 0:400
    size=$($t stat -L -c '%s' "$report")
    test "$size" -gt 0
    test "$size" -le 256
    filesystem=$($t stat -L -f -c '%t' "$report")
    case "$filesystem" in 858458f6|1021994) ;; *) exit 1;; esac
    $t cat "$report"
else
    printf 'none\n'
fi
$t cat /proc/sys/kernel/random/boot_id"#;

fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, byte)| {
            if [8, 13, 18, 23].contains(&i) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
        && value != "00000000-0000-0000-0000-000000000000"
}

fn milliseconds(value: &str) -> Option<u64> {
    let (seconds, fraction) = value.split_once('.')?;
    if seconds.is_empty()
        || seconds.len() > 12
        || fraction.len() != 2
        || !seconds
            .bytes()
            .chain(fraction.bytes())
            .all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    seconds
        .parse::<u64>()
        .ok()?
        .checked_mul(1000)?
        .checked_add(fraction.parse::<u64>().ok()? * 10)
}

fn parse(output: &str) -> Option<BTreeMap<String, String>> {
    let lines: Vec<_> = output.lines().collect();
    if lines.len() != 5
        || lines[0] != "ARKDECK_BOOT_CONTEXT_V1"
        || !uuid(lines[1])
        || lines[1] != lines[4]
    {
        return None;
    }
    let times: Vec<_> = lines[2].split_ascii_whitespace().collect();
    if times.len() != 2 {
        return None;
    }
    let uptime = milliseconds(times[0])?;
    let idle = milliseconds(times[1])?;
    let mut facts = BTreeMap::from([
        ("bootId".into(), lines[1].into()),
        ("uptimeMilliseconds".into(), uptime.to_string()),
        ("idleMilliseconds".into(), idle.to_string()),
        ("faultPresent".into(), (lines[3] != "none").to_string()),
    ]);
    if lines[3] != "none" {
        let marker: Vec<_> = lines[3].split(' ').collect();
        if marker.len() != 4
            || marker[0] != "arkdeck-reboot-v1"
            || marker[1].len() != 32
            || !marker[1]
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            || marker[2] != lines[1]
            || !marker[3].bytes().all(|byte| byte.is_ascii_digit())
        {
            return None;
        }
        let period = marker[3].parse::<u64>().ok()?;
        if !(60..=600).contains(&period) {
            return None;
        }
        facts.insert("faultNonce".into(), marker[1].into());
        facts.insert("faultRebootAfterSeconds".into(), period.to_string());
    }
    Some(facts)
}

pub(crate) fn verify(receipt: &Receipt) -> Outcome {
    if receipt.exit_status != 0 || receipt.truncated || receipt.stdout.len() > CAPTURE_BYTES {
        return Outcome::Failed {
            code: "bootContextUnavailable",
            detail: "boot context read failed or exceeded its byte budget".into(),
        };
    }
    match std::str::from_utf8(&receipt.stdout).ok().and_then(parse) {
        Some(facts) => Outcome::Verified(facts),
        None => Outcome::Failed {
            code: "invalidBootContext",
            detail: "boot context is incomplete, incoherent or malformed".into(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Action;
    use std::time::Duration;

    const BOOT: &str = "01234567-89ab-cdef-0123-456789abcdef";
    const NONCE: &str = "0123456789abcdef0123456789abcdef";

    fn snapshot(marker: &str) -> String {
        format!("ARKDECK_BOOT_CONTEXT_V1\n{BOOT}\n42.31 17.20\n{marker}\n{BOOT}\n")
    }

    #[test]
    fn boot_reads_are_closed_device_bound_and_bounded() {
        let action = Action::for_step("runApprovedRemoteRead", Some("bootContext")).unwrap();
        assert!(action.lower("boot", None).is_err());
        let plan = action.lower("boot", Some("bound-device")).unwrap();
        assert_eq!(plan.arguments, ["-t", "bound-device", "shell", QUERY]);
        assert_eq!(plan.capture_bytes, CAPTURE_BYTES);
        assert_eq!(plan.timeout, Duration::from_secs(15));
        assert_eq!(action.effect(), "readOnly");
        assert_eq!(action.persisted(), ("hdc.observeBootContext", Vec::new()));
    }

    #[test]
    fn coherent_boots_distinguish_a_ram_fault_marker_from_its_absence() {
        let normal = parse(&snapshot("none")).unwrap();
        assert_eq!(normal["bootId"], BOOT);
        assert_eq!(normal["uptimeMilliseconds"], "42310");
        assert_eq!(normal["faultPresent"], "false");
        assert!(!normal.contains_key("faultNonce"));
        let fault = parse(&snapshot(&format!("arkdeck-reboot-v1 {NONCE} {BOOT} 180"))).unwrap();
        assert_eq!(fault["faultPresent"], "true");
        assert_eq!(fault["faultNonce"], NONCE);
        assert_eq!(fault["faultRebootAfterSeconds"], "180");
    }

    #[test]
    fn reboot_races_bad_markers_and_incomplete_output_are_not_boot_facts() {
        let good = snapshot("none");
        for bad in [
            good.replacen("42.31", "NaN", 1),
            good.replacen("42.31", "-1.00", 1),
            good.replacen("42.31", "99999999999999999999999.00", 1),
            good.replacen(BOOT, "11234567-89ab-cdef-0123-456789abcdef", 1),
            good.replace(BOOT, "00000000-0000-0000-0000-000000000000"),
            snapshot(&format!("arkdeck-reboot-v1 {NONCE} {BOOT} 0")),
            snapshot(&format!("arkdeck-reboot-v1 {NONCE} {BOOT} 601")),
            snapshot(&format!("arkdeck-reboot-v1 bad {BOOT} 180")),
            snapshot(&format!("arkdeck-reboot-v1 {NONCE} other-boot 180")),
            format!("{good}unexpected\n"),
            good.trim_end().rsplit_once('\n').unwrap().0.to_owned(),
        ] {
            assert!(parse(&bad).is_none(), "{bad:?}");
        }
        for (exit_status, truncated, stdout) in [
            (1, false, good.as_bytes().to_vec()),
            (0, true, good.as_bytes().to_vec()),
            (0, false, vec![b'x'; CAPTURE_BYTES + 1]),
            (0, false, vec![255]),
        ] {
            assert!(matches!(
                verify(&Receipt {
                    exit_status,
                    truncated,
                    stdout,
                    stderr: Vec::new(),
                    duration: Duration::ZERO,
                }),
                Outcome::Failed { .. }
            ));
        }
    }
}
