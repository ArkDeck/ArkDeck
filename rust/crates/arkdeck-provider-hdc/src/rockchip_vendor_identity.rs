//! DAYU200's bootloader serial selection: the boot device tree must agree
//! with SN_ID=1 in the current Rockchip eMMC vendor slot. Read metadata and
//! that one public serial only; never expose another vendor payload, accept
//! a caller path/offset, or substitute this mutable locator for the CPU ID.
use crate::{HdcDispatch, ProcessPlan, device_arguments};
use arkdeck_contract::sha256_hex;
use std::collections::BTreeMap;
use std::time::{Duration, Instant};

const SOURCE: &str = "rockchip-emmc-vendor-sn-and-cpu-v1";
const DISK: &str = "/dev/block/mmcblk0";
const BASE: usize = 7168 * 512;
const SLOT_SIZE: usize = 64 * 1024;
const DATA_OFFSET: usize = 1024;
const DATA_SIZE: usize = 64504;
const TIMEOUT: Duration = Duration::from_secs(30);
const INVALID: &str = "normalLoaderIdentity.vendorRecordInvalid";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VendorSerialProof {
    pub serial_sha256: String,
    pub source_sha256: String,
    pub source_byte_count: usize,
}

impl VendorSerialProof {
    pub(crate) fn summary(&self) -> BTreeMap<String, String> {
        BTreeMap::from([
            ("identitySource".into(), SOURCE.into()),
            ("loaderSerialSha256".into(), self.serial_sha256.clone()),
            ("vendorSourceSha256".into(), self.source_sha256.clone()),
            (
                "vendorSourceByteCount".into(),
                self.source_byte_count.to_string(),
            ),
        ])
    }
}

struct Reader<'a> {
    hdc: &'a dyn HdcDispatch,
    connect_key: &'a str,
    started: Instant,
    digests: Vec<String>,
    bytes: usize,
}

impl Reader<'_> {
    fn hex(&mut self, path: &str, offset: usize, count: usize) -> Result<Vec<u8>, &'static str> {
        let remaining = TIMEOUT
            .checked_sub(self.started.elapsed())
            .filter(|remaining| !remaining.is_zero())
            .ok_or("normalLoaderIdentity.vendorCaptureChangedOrExpired")?;
        let receipt = self
            .hdc
            .dispatch(&ProcessPlan {
                arguments: device_arguments(
                    self.connect_key,
                    [
                        "shell".into(),
                        "od".into(),
                        "-An".into(),
                        "-v".into(),
                        "-tx1".into(),
                        "-j".into(),
                        offset.to_string(),
                        "-N".into(),
                        count.to_string(),
                        path.into(),
                    ],
                ),
                timeout: remaining.min(Duration::from_secs(15)),
                capture_bytes: 4096,
            })
            .map_err(|_| "normalLoaderIdentity.vendorReadUnavailable")?;
        if receipt.exit_status != 0
            || receipt.truncated
            || !receipt.stderr.is_empty()
            || receipt.stdout.len() > 4096
            || self.started.elapsed() > TIMEOUT
        {
            return Err("normalLoaderIdentity.vendorReadUnconfirmed");
        }
        let bytes = parse_hex(&receipt.stdout, count)?;
        self.bytes += receipt.stdout.len();
        self.digests.push(format!(
            "{}:{}",
            receipt.stdout.len(),
            sha256_hex(&receipt.stdout)
        ));
        Ok(bytes)
    }

    fn disk(&mut self, offset: usize, count: usize) -> Result<Vec<u8>, &'static str> {
        if count == 0
            || count > 1008
            || offset < BASE
            || offset
                .checked_add(count)
                .is_none_or(|end| end > BASE + 4 * SLOT_SIZE)
        {
            return Err(INVALID);
        }
        let bytes = self.hex(DISK, offset, count)?;
        if bytes.len() != count {
            return Err(INVALID);
        }
        Ok(bytes)
    }

    fn slots(&mut self) -> Result<Vec<Slot>, &'static str> {
        (0..4)
            .map(|index| {
                let base = BASE + index * SLOT_SIZE;
                let header = self.disk(base, 16)?;
                let footer = self.disk(base + SLOT_SIZE - 4, 4)?;
                Slot::read(base, header, footer)
            })
            .collect()
    }
}

fn parse_hex(stdout: &[u8], maximum: usize) -> Result<Vec<u8>, &'static str> {
    let text = std::str::from_utf8(stdout).map_err(|_| INVALID)?;
    let mut bytes = Vec::new();
    for token in text.split_ascii_whitespace() {
        if token.len() != 2
            || !token.bytes().all(|byte| byte.is_ascii_hexdigit())
            || bytes.len() == maximum
        {
            return Err(INVALID);
        }
        bytes.push(u8::from_str_radix(token, 16).map_err(|_| INVALID)?);
    }
    Ok(bytes)
}

fn word(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
}
fn dword(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(
        bytes[offset..offset + 4]
            .try_into()
            .expect("bounded vendor header"),
    )
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Slot {
    base: usize,
    header: Vec<u8>,
    footer: Vec<u8>,
    valid: bool,
    version: u32,
    items: usize,
}

impl Slot {
    fn read(base: usize, header: Vec<u8>, footer: Vec<u8>) -> Result<Self, &'static str> {
        let version = dword(&header, 4);
        let items = usize::from(word(&header, 10));
        let valid = dword(&header, 0) == 0x524b5644 && version == dword(&footer, 0);
        if valid
            && (version == 0
                || word(&header, 8) >= 4
                || items == 0
                || items > 126
                || usize::from(word(&header, 12)) + usize::from(word(&header, 14)) > DATA_SIZE)
        {
            return Err(INVALID);
        }
        Ok(Self {
            base,
            header,
            footer,
            valid,
            version,
            items,
        })
    }
}

fn selected_slot(slots: &[Slot]) -> Result<&Slot, &'static str> {
    let selected = slots
        .iter()
        .filter(|slot| slot.valid)
        .max_by_key(|slot| slot.version)
        .ok_or(INVALID)?;
    if slots
        .iter()
        .filter(|slot| slot.valid && slot.version == selected.version)
        .count()
        != 1
    {
        return Err("normalLoaderIdentity.vendorRecordAmbiguous");
    }
    Ok(selected)
}

fn serial_item(table: &[u8]) -> Result<(usize, usize), &'static str> {
    let mut serial = None;
    let mut ranges = Vec::new();
    let mut ids = std::collections::BTreeSet::new();
    let (items, trailing) = table.as_chunks::<8>();
    if !trailing.is_empty() {
        return Err(INVALID);
    }
    for item in items {
        let id = word(item, 0);
        let offset = usize::from(word(item, 2));
        let size = usize::from(word(item, 4));
        let end = offset.checked_add(size).ok_or(INVALID)?;
        if !ids.insert(id)
            || size == 0
            || offset % 64 != 0
            || end > DATA_SIZE
            || ranges
                .iter()
                .any(|&(start, previous_end)| offset < previous_end && start < end)
        {
            return Err(INVALID);
        }
        ranges.push((offset, end));
        if id == 1 {
            // Current DAYU200 profile: sixteen exact lowercase hex digits,
            // optionally one C terminator. No generic vendor data is read.
            if !(16..=17).contains(&size) {
                return Err(INVALID);
            }
            serial = Some((offset, size));
        }
    }
    serial.ok_or("normalLoaderIdentity.vendorSerialMissing")
}

fn canonical_serial(bytes: &[u8]) -> Result<&[u8], &'static str> {
    let serial = bytes.strip_suffix(&[0]).unwrap_or(bytes);
    if serial.len() != 16
        || !serial
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
        || serial.iter().all(|byte| *byte == b'0')
        || serial.iter().all(|byte| *byte == b'f')
    {
        return Err("normalLoaderIdentity.vendorSerialMalformed");
    }
    Ok(serial)
}

pub(crate) fn observe(
    hdc: &dyn HdcDispatch,
    connect_key: &str,
    expected: &str,
    started: Instant,
) -> Result<VendorSerialProof, &'static str> {
    if connect_key.len() != 32
        || !connect_key
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("normalLoaderIdentity.vendorNormalIdentityMismatch");
    }
    let mut reader = Reader {
        hdc,
        connect_key,
        started,
        digests: Vec::new(),
        bytes: 0,
    };
    let compatible = reader.hex("/proc/device-tree/compatible", 0, 256)?;
    if compatible.len() == 256
        || !compatible
            .split(|byte| *byte == 0)
            .any(|item| item == b"rockchip,rk3568-toybrick-dev-linux-x0")
    {
        return Err("normalLoaderIdentity.vendorProfileUnsupported");
    }
    let cid = reader.hex("/sys/class/block/mmcblk0/device/cid", 0, 34)?;
    let cid = cid.strip_suffix(b"\n").unwrap_or(&cid);
    if cid.len() != 32
        || cid != connect_key.as_bytes()
        || !cid
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        return Err("normalLoaderIdentity.vendorNormalIdentityMismatch");
    }
    let tree = reader.hex("/proc/device-tree/serial-number", 0, 18)?;
    let tree_serial = canonical_serial(&tree)?;
    if sha256_hex(tree_serial) != expected {
        return Err("normalLoaderIdentity.boundLoaderIdentityMismatch");
    }
    let slots = reader.slots()?;
    let slot = selected_slot(&slots)?;
    let table = reader.disk(slot.base + 16, slot.items * 8)?;
    let (offset, size) = serial_item(&table)?;
    let serial = reader.disk(slot.base + DATA_OFFSET + offset, size)?;
    if canonical_serial(&serial)? != tree_serial {
        return Err("normalLoaderIdentity.vendorBootSerialMismatch");
    }
    // A serial, item pointer or slot rollover changing during the capture
    // invalidates the entire observation. No retry selects a convenient slot.
    if reader.disk(slot.base + DATA_OFFSET + offset, size)? != serial
        || reader.disk(slot.base + 16, slot.items * 8)? != table
        || reader.slots()? != slots
        || reader.hex("/proc/device-tree/serial-number", 0, 18)? != tree
    {
        return Err("normalLoaderIdentity.vendorCaptureChangedOrExpired");
    }
    Ok(VendorSerialProof {
        serial_sha256: sha256_hex(tree_serial),
        source_sha256: sha256_hex(reader.digests.join("\n").as_bytes()),
        source_byte_count: reader.bytes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        DispatchFailure, LoaderIdentity, Receipt, UsbProbe, observe_normal_loader_identity,
    };
    use std::cell::{Cell, RefCell};

    const KEY: &str = "0123456789abcdef0123456789abcdef";
    const CPU: &str = "0123456789abcdef";
    const SN: &str = "13579bdf2468ace0";
    const SLOT: usize = 2 * SLOT_SIZE;

    struct Device {
        disk: Vec<u8>,
        fault: &'static str,
        cpu_reads: Cell<usize>,
        sn_reads: Cell<usize>,
        disk_reads: RefCell<Vec<(usize, usize)>>,
        entered: Cell<bool>,
        persisted: Cell<bool>,
    }

    impl Device {
        fn new(fault: &'static str) -> Self {
            let mut disk = vec![0; 4 * SLOT_SIZE];
            let header = &mut disk[SLOT..SLOT + 16];
            header[..4].copy_from_slice(&0x524b5644u32.to_le_bytes());
            header[4..8].copy_from_slice(&7u32.to_le_bytes());
            header[8..10].copy_from_slice(&3u16.to_le_bytes());
            header[10..12].copy_from_slice(&2u16.to_le_bytes());
            header[12..14].copy_from_slice(&128u16.to_le_bytes());
            header[14..16].copy_from_slice(&((DATA_SIZE - 128) as u16).to_le_bytes());
            for (item, id, offset, size) in [(0, 1u16, 0u16, 16u16), (1, 2, 64, 64)] {
                let at = SLOT + 16 + item * 8;
                disk[at..at + 2].copy_from_slice(&id.to_le_bytes());
                disk[at + 2..at + 4].copy_from_slice(&offset.to_le_bytes());
                disk[at + 4..at + 6].copy_from_slice(&size.to_le_bytes());
            }
            disk[SLOT + DATA_OFFSET..SLOT + DATA_OFFSET + 16].copy_from_slice(SN.as_bytes());
            disk[SLOT + DATA_OFFSET + 64..SLOT + DATA_OFFSET + 128].fill(0xa5);
            disk[SLOT + SLOT_SIZE - 4..SLOT + SLOT_SIZE].copy_from_slice(&7u32.to_le_bytes());
            match fault {
                "duplicateSlot" => {
                    let duplicate = disk[SLOT..SLOT + SLOT_SIZE].to_vec();
                    disk[..SLOT_SIZE].copy_from_slice(&duplicate);
                }
                "missingSN" => disk[SLOT + 16] = 3,
                "duplicateID" => disk[SLOT + 24] = 1,
                "overlap" => disk[SLOT + 26] = 0,
                "oversizedSN" => disk[SLOT + 20] = 64,
                "badFooter" => disk[SLOT + SLOT_SIZE - 4] = 6,
                "wrongVendor" => disk[SLOT + DATA_OFFSET] = b'2',
                _ => {}
            }
            Self {
                disk,
                fault,
                cpu_reads: Cell::new(0),
                sn_reads: Cell::new(0),
                disk_reads: RefCell::new(Vec::new()),
                entered: Cell::new(false),
                persisted: Cell::new(false),
            }
        }
    }

    impl HdcDispatch for Device {
        fn mutation_identity_current(&self) -> bool {
            true
        }

        fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
            if plan == &crate::enter_loader_plan(KEY) {
                assert!(
                    self.persisted.get(),
                    "proof must precede mode-changing dispatch"
                );
                assert!(
                    !self.entered.replace(true),
                    "mode-changing command must not replay"
                );
                return Ok(Receipt {
                    exit_status: 0,
                    stdout: Vec::new(),
                    stderr: Vec::new(),
                    truncated: false,
                    duration: Duration::ZERO,
                });
            }
            assert_eq!(&plan.arguments[..2], ["-t", KEY]);
            assert!(plan.timeout <= Duration::from_secs(15));
            let stdout = if plan == &crate::normal_hardware_identity_plan(KEY) {
                self.cpu_reads.set(self.cpu_reads.get() + 1);
                let serial = if self.fault == "changedCPU" && self.cpu_reads.get() > 1 {
                    SN
                } else {
                    CPU
                };
                format!("Serial: {serial}\n").into_bytes()
            } else {
                assert_eq!(plan.arguments.len(), 12);
                assert_eq!(
                    &plan.arguments[2..8],
                    ["shell", "od", "-An", "-v", "-tx1", "-j"]
                );
                assert_eq!(plan.arguments[9], "-N");
                let offset: usize = plan.arguments[8].parse().unwrap();
                let count: usize = plan.arguments[10].parse().unwrap();
                let mut bytes = match plan.arguments[11].as_str() {
                    "/proc/device-tree/compatible" => {
                        if self.fault == "wrongProfile" {
                            b"unsupported,board\0".to_vec()
                        } else {
                            b"rockchip,rk3568-toybrick-dev-linux-x0\0rockchip,rk3568\0".to_vec()
                        }
                    }
                    "/sys/class/block/mmcblk0/device/cid" => {
                        if self.fault == "wrongCID" {
                            b"fedcba9876543210fedcba9876543210\n".to_vec()
                        } else {
                            format!("{KEY}\n").into_bytes()
                        }
                    }
                    "/proc/device-tree/serial-number" => {
                        if self.fault == "wrongTree" {
                            CPU.as_bytes().to_vec()
                        } else {
                            SN.as_bytes().to_vec()
                        }
                    }
                    DISK => {
                        assert!(offset >= BASE && count <= 1008);
                        self.disk_reads.borrow_mut().push((offset, count));
                        let mut bytes = self.disk[offset - BASE..offset - BASE + count].to_vec();
                        if offset == BASE + SLOT + DATA_OFFSET {
                            self.sn_reads.set(self.sn_reads.get() + 1);
                            if self.fault == "changedSN" && self.sn_reads.get() > 1 {
                                bytes[0] = b'2';
                            }
                        }
                        if self.fault == "shortRead" {
                            bytes.pop();
                        }
                        bytes
                    }
                    other => panic!("unexpected fixed read: {other}"),
                };
                bytes.truncate(count);
                bytes
                    .iter()
                    .map(|byte| format!("{byte:02x} "))
                    .collect::<String>()
                    .into_bytes()
            };
            Ok(Receipt {
                exit_status: 0,
                stdout,
                stderr: if self.fault == "stderr" {
                    b"unconfirmed".to_vec()
                } else {
                    Vec::new()
                },
                truncated: self.fault == "truncated",
                duration: Duration::ZERO,
            })
        }
    }

    impl UsbProbe for Device {
        fn single_loader(&self, expected: &str) -> Result<LoaderIdentity, String> {
            if self.entered.get() && expected == sha256_hex(SN.as_bytes()) {
                Ok(LoaderIdentity {
                    serial_digest_sha256: expected.into(),
                    topology: "42".into(),
                })
            } else {
                Err("no exact Loader".into())
            }
        }
        fn single_hdc_normal(&self, expected: &str) -> Result<LoaderIdentity, String> {
            if !self.entered.get() && expected == sha256_hex(KEY.as_bytes()) {
                Ok(LoaderIdentity {
                    serial_digest_sha256: expected.into(),
                    topology: "42".into(),
                })
            } else {
                Err("no exact Normal device".into())
            }
        }
        fn connector_identity(&self, topology: &str) -> Result<String, String> {
            assert_eq!(topology, "42");
            Ok("d".repeat(64))
        }
    }
    impl crate::LoaderObserver for Device {
        fn observe_loader(
            &self,
            expected: &str,
            _: Option<&str>,
            _: &str,
        ) -> Result<LoaderIdentity, String> {
            self.single_loader(expected)
        }
        fn confirm_loader(
            &self,
            identity: &LoaderIdentity,
            expected: &str,
            _: Option<&str>,
            _: &str,
        ) -> Result<LoaderIdentity, String> {
            let observed = self.single_loader(expected)?;
            assert_eq!(&observed, identity);
            Ok(observed)
        }
    }

    #[test]
    fn factory_transition_requires_durable_separate_serial_proof_before_its_only_dispatch() {
        for (fault, persist) in [
            ("", true),
            ("", false),
            ("duplicateSlot", true),
            ("changedCPU", true),
            ("wrongVendor", true),
        ] {
            let device = Device::new(fault);
            let result = crate::RockchipLoaderTransition::new(
                &device,
                &device,
                &device,
                &crate::SystemClock,
            )
            .enter_loader(
                &crate::TransitionRequest {
                    connect_key: KEY,
                    stable_identity_sha256: &sha256_hex(SN.as_bytes()),
                    job_id: "job-vendor-fixture",
                    step_id: "enter-loader",
                },
                &crate::ReadbackBudget::DEFAULT,
                |proof| {
                    assert_eq!(proof.hardware_serial_sha256, sha256_hex(CPU.as_bytes()));
                    assert_eq!(proof.loader_serial_sha256(), sha256_hex(SN.as_bytes()));
                    if persist {
                        device.persisted.set(true);
                        Ok("a".repeat(64))
                    } else {
                        Err("fixture persistence unavailable".into())
                    }
                },
            );
            let success = fault.is_empty() && persist;
            assert_eq!(result.is_ok(), success, "{fault}/{persist}: {result:?}");
            assert_eq!(device.entered.get(), success);
            if let Ok(transition) = result {
                assert_eq!(transition.transition, crate::Transition::NormalToLoader);
                assert_eq!(transition.identity_observation_sha256, Some("a".repeat(64)));
            }
        }
    }

    #[derive(Default)]
    struct Usb {
        changed: bool,
        reads: Cell<usize>,
    }
    impl UsbProbe for Usb {
        fn single_loader(&self, _: &str) -> Result<LoaderIdentity, String> {
            Err("Normal mode".into())
        }
        fn single_hdc_normal(&self, identity: &str) -> Result<LoaderIdentity, String> {
            assert_eq!(identity, sha256_hex(KEY.as_bytes()));
            self.reads.set(self.reads.get() + 1);
            Ok(LoaderIdentity {
                serial_digest_sha256: identity.into(),
                topology: "42".into(),
            })
        }
        fn connector_identity(&self, _: &str) -> Result<String, String> {
            Ok(if self.changed && self.reads.get() > 2 {
                "e"
            } else {
                "d"
            }
            .repeat(64))
        }
    }

    #[test]
    fn factory_sn_proves_the_loader_without_relabeling_the_cpu_or_reading_other_payloads() {
        let device = Device::new("");
        let result = observe_normal_loader_identity(
            &device,
            &Usb::default(),
            KEY,
            &sha256_hex(SN.as_bytes()),
        )
        .unwrap();
        assert_eq!(result.hardware_serial_sha256, sha256_hex(CPU.as_bytes()));
        assert_eq!(result.loader_serial_sha256(), sha256_hex(SN.as_bytes()));
        assert_eq!(device.cpu_reads.get(), 2);
        assert_eq!(device.sn_reads.get(), 2);
        for (offset, count) in device.disk_reads.borrow().iter().copied() {
            let within = (offset - BASE) % SLOT_SIZE;
            assert!(
                within == 0 && count == 16
                    || within == SLOT_SIZE - 4 && count == 4
                    || within == 16 && count == 16
                    || within == DATA_OFFSET && count == 16,
                "read outside public metadata/SN_ID: {within}+{count}"
            );
        }
        let summary = format!("{:?}", result.summary());
        assert!(summary.contains(SOURCE));
        assert!(!summary.contains(CPU) && !summary.contains(SN) && !summary.contains(KEY));
    }

    #[test]
    fn malformed_ambiguous_unconfirmed_and_mismatched_vendor_sources_fail_closed() {
        for fault in [
            "duplicateSlot",
            "missingSN",
            "duplicateID",
            "overlap",
            "oversizedSN",
            "badFooter",
            "wrongVendor",
            "wrongTree",
            "wrongCID",
            "wrongProfile",
            "shortRead",
            "stderr",
            "truncated",
        ] {
            let device = Device::new(fault);
            assert!(
                observe_normal_loader_identity(
                    &device,
                    &Usb::default(),
                    KEY,
                    &sha256_hex(SN.as_bytes())
                )
                .is_err(),
                "{fault}"
            );
        }
    }

    #[test]
    fn capture_drift_or_expiry_never_produces_cross_mode_evidence() {
        for fault in ["changedSN", "changedCPU"] {
            assert!(
                observe_normal_loader_identity(
                    &Device::new(fault),
                    &Usb::default(),
                    KEY,
                    &sha256_hex(SN.as_bytes())
                )
                .is_err(),
                "{fault}"
            );
        }
        assert!(
            observe_normal_loader_identity(
                &Device::new(""),
                &Usb {
                    changed: true,
                    ..Default::default()
                },
                KEY,
                &sha256_hex(SN.as_bytes())
            )
            .is_err()
        );
        assert!(
            observe(
                &Device::new(""),
                KEY,
                &sha256_hex(SN.as_bytes()),
                Instant::now() - Duration::from_secs(31)
            )
            .is_err()
        );
    }

    #[test]
    fn matching_kernel_serial_preserves_the_original_single_read_route() {
        let device = Device::new("wrongProfile");
        let identity = observe_normal_loader_identity(
            &device,
            &Usb::default(),
            KEY,
            &sha256_hex(CPU.as_bytes()),
        )
        .unwrap();
        assert!(identity.vendor_serial.is_none());
        assert_eq!(device.cpu_reads.get(), 1);
        assert!(device.disk_reads.borrow().is_empty());
    }
}
