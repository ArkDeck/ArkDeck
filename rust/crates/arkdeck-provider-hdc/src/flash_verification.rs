//! Closed DAYU200 partition reads, derived from the pinned ArkForge verifier.
//! No caller path, expected digest or arbitrary shell fragment is accepted.
use crate::{HdcDispatch, ProcessPlan, device_arguments};
use std::time::Instant;
const OUTPUT_LIMIT: usize = 1024 * 1024;
const TARGETS: [&str; 9] = [
    "uboot",
    "resource",
    "boot_linux",
    "ramdisk",
    "system",
    "vendor",
    "updater",
    "chip_ckm",
    "userdata",
];

#[derive(Clone, Debug)]
pub struct PartitionRange {
    pub target: String,
    pub range_start: u64,
    pub range_length: u64,
}
#[derive(Debug, PartialEq, Eq)]
pub enum PartitionHash {
    Full(String),
    MountedWritable,
}

pub fn read_flash_partition(
    hdc: &dyn HdcDispatch,
    key: &str,
    effect: &PartitionRange,
    deadline: Instant,
) -> Result<PartitionHash, &'static str> {
    if key.is_empty()
        || !TARGETS.contains(&effect.target.as_str())
        || effect.range_length == 0
        || effect.range_length > 16 * 1024 * 1024 * 1024
        || !effect.range_start.is_multiple_of(512)
        || effect
            .range_start
            .checked_add(effect.range_length)
            .is_none()
    {
        return Err("invalid-sealed-partition-range");
    }
    let run = |query: String, capture_bytes| {
        let timeout = deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or("verification-budget-exhausted")?;
        let receipt = hdc
            .dispatch(&ProcessPlan {
                arguments: device_arguments(key, ["shell".into(), query]),
                timeout,
                capture_bytes,
            })
            .map_err(|_| "partition-read-unavailable")?;
        if Instant::now() >= deadline || receipt.exit_status != 0 || receipt.truncated {
            return Err("partition-read-incomplete");
        }
        Ok(receipt.stdout)
    };
    let before = parse_metadata(&run(metadata_query(&effect.target), OUTPUT_LIMIT)?)?;
    before.validate_range(effect)?;
    if before.writable {
        return Ok(PartitionHash::MountedWritable);
    }
    let hash = parse_hash(&run(hash_query(&before.name, effect.range_length), 256)?)?;
    let after = parse_metadata(&run(metadata_query(&effect.target), OUTPUT_LIMIT)?)?;
    if before != after {
        return Err("partition-mapping-or-mount-changed");
    }
    Ok(PartitionHash::Full(hash))
}

fn metadata_query(target: &str) -> String {
    // target has been checked against TARGETS before this function is called.
    format!(
        r#"set -eu; p=$(/system/bin/toybox readlink -f /dev/block/by-name/{target}); case "$p" in /dev/block/mmcblk0p[0-9]|/dev/block/mmcblk0p[0-9][0-9]) ;; *) exit 31;; esac; test -b "$p"; n=${{p##*/}}; printf 'ARKFORGE_BLOCK_V1\n%s\n' "$n"; /system/bin/toybox cat /sys/class/block/$n/dev /sys/class/block/$n/start /sys/class/block/$n/size; /system/bin/toybox stat -c '%t:%T' "$p"; for h in /sys/class/block/$n/holders/* /sys/class/block/mmcblk0/holders/*; do if test -e "$h"; then printf 'HOLDER\n'; fi; done; printf 'MOUNTS\n'; /system/bin/toybox cat /proc/self/mountinfo; printf '\nARKFORGE_BLOCK_OK\n'"#
    )
}

fn hash_query(name: &str, bytes: u64) -> String {
    // count_bytes avoids head -c's signed 32-bit limit and covers partial blocks.
    // pipefail plus a terminal marker rejects a short/erroring remote pipeline,
    // even when the HDC client exits zero for a failed remote shell.
    format!(
        "set -eu; set -o pipefail; /system/bin/toybox dd if=/dev/block/{name} bs=1048576 count={bytes} iflag=count_bytes status=none | /system/bin/toybox sha256sum; printf '\\nARKFORGE_HASH_OK\\n'"
    )
}

#[derive(Debug, PartialEq, Eq)]
struct BlockMetadata {
    name: String,
    device: String,
    start: u64,
    size: u64,
    writable: bool,
}

impl BlockMetadata {
    fn validate_range(&self, effect: &PartitionRange) -> Result<(), &'static str> {
        if self.start != effect.range_start || self.size < effect.range_length {
            return Err("partition-range-differs-from-sealed-plan");
        }
        Ok(())
    }
}

fn parse_metadata(bytes: &[u8]) -> Result<BlockMetadata, &'static str> {
    let invalid = "partition-metadata-invalid";
    if bytes.len() > OUTPUT_LIMIT {
        return Err(invalid);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| invalid)?;
    let lines = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    if lines.len() < 9
        || lines[0] != "ARKFORGE_BLOCK_V1"
        || lines.last() != Some(&"ARKFORGE_BLOCK_OK")
    {
        return Err(invalid);
    }
    let suffix = lines[1].strip_prefix("mmcblk0p").ok_or(invalid)?;
    if suffix.is_empty()
        || suffix.len() > 2
        || suffix.starts_with('0')
        || !suffix.bytes().all(|c| c.is_ascii_digit())
    {
        return Err(invalid);
    }
    let number = suffix.parse::<u64>().map_err(|_| invalid)?;
    // Linux MMC disk 0 and its first 31 partitions use major 179, minor 0..31.
    if number > 31 || lines[2] != format!("179:{number}") {
        return Err(invalid);
    }
    if lines[5] != format!("b3:{number:x}") {
        return Err("block-node-differs-from-sysfs");
    }
    let sectors = |s: &str| {
        s.parse::<u64>()
            .ok()
            .and_then(|n| n.checked_mul(512))
            .ok_or(invalid)
    };
    let mut metadata = BlockMetadata {
        name: lines[1].into(),
        device: lines[2].into(),
        start: sectors(lines[3])?,
        size: sectors(lines[4])?,
        writable: false,
    };
    if lines[6] == "HOLDER" {
        return Err("partition-has-block-holder");
    }
    if lines[6] != "MOUNTS" {
        return Err(invalid);
    }
    for line in &lines[7..lines.len() - 1] {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        let separator = fields
            .iter()
            .position(|field| *field == "-")
            .ok_or(invalid)?;
        if separator < 6 || fields.len() != separator + 4 {
            return Err(invalid);
        }
        let options = [fields[5], fields[separator + 3]];
        for option in options {
            if !option.split(',').any(|v| v == "ro" || v == "rw") {
                return Err(invalid);
            }
        }
        if fields[2] == metadata.device || fields[2] == "179:0" {
            metadata.writable |= options.iter().any(|o| o.split(',').any(|v| v == "rw"));
        }
    }
    Ok(metadata)
}

fn parse_hash(bytes: &[u8]) -> Result<String, &'static str> {
    let invalid = "partition-hash-output-invalid";
    if bytes.len() > 256 {
        return Err(invalid);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| invalid)?;
    let words = text.split_whitespace().collect::<Vec<_>>();
    if words.len() != 3
        || words[1] != "-"
        || words[2] != "ARKFORGE_HASH_OK"
        || words[0].len() != 64
        || !words[0]
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
    {
        return Err(invalid);
    }
    Ok(words[0].into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DispatchFailure, Receipt};
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use std::time::Duration;
    struct Script {
        replies: Mutex<VecDeque<Receipt>>,
        calls: Mutex<Vec<ProcessPlan>>,
    }
    impl Script {
        fn new(outputs: Vec<Vec<u8>>) -> Self {
            Self {
                replies: Mutex::new(
                    outputs
                        .into_iter()
                        .map(|stdout| Receipt {
                            exit_status: 0,
                            stdout,
                            stderr: vec![],
                            truncated: false,
                            duration: Duration::ZERO,
                        })
                        .collect(),
                ),
                calls: Mutex::new(vec![]),
            }
        }
    }
    impl HdcDispatch for Script {
        fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
            self.calls.lock().unwrap().push(plan.clone());
            Ok(self
                .replies
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected extra dispatch"))
        }
    }
    fn metadata(writable: bool) -> Vec<u8> {
        format!("ARKFORGE_BLOCK_V1\nmmcblk0p4\n179:4\n8\n8\nb3:4\nMOUNTS\n1 0 179:4 / /data {} - ext4 /dev/block/mmcblk0p4 {}\nARKFORGE_BLOCK_OK\n",
            if writable {"rw"} else {"ro"}, if writable {"rw"} else {"ro"}).into_bytes()
    }
    fn range() -> PartitionRange {
        PartitionRange {
            target: "userdata".into(),
            range_start: 4096,
            range_length: 4096,
        }
    }
    fn read(s: &Script) -> Result<PartitionHash, &'static str> {
        read_flash_partition(
            s,
            "bound-device",
            &range(),
            Instant::now() + Duration::from_secs(2),
        )
    }
    #[test]
    fn full_hash_requires_matching_metadata_before_and_after() {
        let hash = "a".repeat(64);
        let s = Script::new(vec![
            metadata(false),
            format!("{hash}  -\nARKFORGE_HASH_OK\n").into_bytes(),
            metadata(false),
        ]);
        assert_eq!(read(&s), Ok(PartitionHash::Full(hash)));
        let calls = s.calls.lock().unwrap();
        assert_eq!(calls.len(), 3);
        assert!(
            calls
                .iter()
                .all(|p| p.arguments[..3] == ["-t", "bound-device", "shell"]
                    && p.timeout <= Duration::from_secs(2))
        );
        assert!(calls[1].arguments[3].contains("count=4096 iflag=count_bytes"));
    }
    #[test]
    fn writable_mounts_are_skipped_without_hash_dispatch() {
        let s = Script::new(vec![metadata(true)]);
        assert_eq!(read(&s), Ok(PartitionHash::MountedWritable));
        assert_eq!(s.calls.lock().unwrap().len(), 1);
    }
    #[test]
    fn holders_mapping_drift_and_partial_output_fail_closed() {
        let holder = String::from_utf8(metadata(false))
            .unwrap()
            .replace("MOUNTS", "HOLDER\nMOUNTS")
            .into_bytes();
        assert_eq!(
            read(&Script::new(vec![holder])),
            Err("partition-has-block-holder")
        );
        let wrong = String::from_utf8(metadata(false))
            .unwrap()
            .replace("\n8\n8\n", "\n9\n8\n")
            .into_bytes();
        assert_eq!(
            read(&Script::new(vec![wrong])),
            Err("partition-range-differs-from-sealed-plan")
        );
        assert!(
            read(&Script::new(vec![
                metadata(false),
                format!("{} -", "a".repeat(64)).into_bytes()
            ]))
            .is_err()
        );
        assert_eq!(
            read(&Script::new(vec![
                metadata(false),
                format!("{} - ARKFORGE_HASH_OK", "a".repeat(64)).into_bytes(),
                metadata(true)
            ])),
            Err("partition-mapping-or-mount-changed")
        );
    }
    #[test]
    fn invalid_target_and_expired_budget_dispatch_nothing() {
        let s = Script::new(vec![]);
        let mut r = range();
        r.target = "userdata; reboot".into();
        assert!(
            read_flash_partition(&s, "bound", &r, Instant::now() + Duration::from_secs(2)).is_err()
        );
        assert!(read_flash_partition(&s, "bound", &range(), Instant::now()).is_err());
        assert!(s.calls.lock().unwrap().is_empty());
    }
    #[test]
    fn truncated_or_nonzero_process_never_proves_a_hash() {
        for truncated in [false, true] {
            let s = Script::new(vec![metadata(false)]);
            let mut replies = s.replies.lock().unwrap();
            if truncated {
                replies[0].truncated = true;
            } else {
                replies[0].exit_status = 1;
            }
            drop(replies);
            assert_eq!(read(&s), Err("partition-read-incomplete"));
        }
    }
}
