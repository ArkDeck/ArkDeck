//! Bounded CPU identity and evidence linking Normal to an already bound Loader.
//! The Normal USB CID, CPU serial and factory Loader SN remain separate facts.
//! Only a fixed, target-scoped kernel read is accepted. No property supplied
//! by a caller, model/build match, topology alone or old receipt proves it.
use crate::{HdcDispatch, ProcessPlan, Receipt, UsbProbe, device_arguments};
use arkdeck_contract::sha256_hex;
use std::collections::BTreeMap;
use std::time::Duration;

pub const NORMAL_HARDWARE_IDENTITY_SOURCE: &str = "linux-proc-cpuinfo-serial-v1";
const CAPTURE_BYTES: usize = 64 * 1024;
const TIMEOUT: Duration = Duration::from_secs(15);

/// Only digests leave the fixed read's parser. Raw CPU information and the
/// hardware serial must not enter a Job timeline, error or public receipt.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NormalHardwareIdentity {
    pub normal_identity_sha256: String,
    pub hardware_serial_sha256: String,
    pub usb_topology: String,
    pub connector_identity_sha256: String,
    pub stdout_sha256: String,
    pub stdout_byte_count: usize,
    /// A factory serial is a cross-mode locator, not the CPU serial. This
    /// proof is produced only by the fixed vendor reader over this attachment.
    pub vendor_serial: Option<crate::rockchip_vendor_identity::VendorSerialProof>,
}

/// Runtime composition port, like `LoaderObserver`. No control-protocol input
/// selects it; production uses the fixed kernel reader below.
pub type NormalHardwareIdentityObserver =
    fn(&dyn HdcDispatch, &dyn UsbProbe, &str, &str) -> Result<NormalHardwareIdentity, &'static str>;

impl NormalHardwareIdentity {
    pub fn loader_serial_sha256(&self) -> &str {
        self.vendor_serial
            .as_ref()
            .map_or(&self.hardware_serial_sha256, |proof| &proof.serial_sha256)
    }

    pub fn matches_loader(&self, expected: &str) -> bool {
        self.loader_serial_sha256() == expected
    }

    pub fn summary(&self) -> BTreeMap<String, String> {
        let mut summary = BTreeMap::from([
            (
                "identitySource".into(),
                NORMAL_HARDWARE_IDENTITY_SOURCE.into(),
            ),
            (
                "hdcNormalIdentitySha256".into(),
                self.normal_identity_sha256.clone(),
            ),
            (
                "hardwareSerialSha256".into(),
                self.hardware_serial_sha256.clone(),
            ),
            ("usbTopology".into(), self.usb_topology.clone()),
            (
                "usbConnectorSha256".into(),
                self.connector_identity_sha256.clone(),
            ),
            ("sourceStdoutSha256".into(), self.stdout_sha256.clone()),
            (
                "sourceStdoutByteCount".into(),
                self.stdout_byte_count.to_string(),
            ),
        ]);
        if let Some(proof) = &self.vendor_serial {
            summary.extend(proof.summary());
        }
        summary
    }
}

pub fn normal_hardware_identity_plan(connect_key: &str) -> ProcessPlan {
    ProcessPlan {
        arguments: device_arguments(
            connect_key,
            ["shell", "cat", "/proc/cpuinfo"].map(str::to_owned),
        ),
        timeout: TIMEOUT,
        capture_bytes: CAPTURE_BYTES,
    }
}

/// Read one exact USB-routed Normal target and prove that the attachment did
/// not change across the read. Unsupported kernels fail closed.
pub fn observe_normal_hardware_identity(
    hdc: &dyn HdcDispatch,
    usb: &dyn UsbProbe,
    connect_key: &str,
) -> Result<NormalHardwareIdentity, &'static str> {
    if connect_key.is_empty() {
        return Err("normalLoaderIdentity.connectKeyMissing");
    }
    let normal_identity_sha256 = sha256_hex(connect_key.as_bytes());
    let before = usb
        .single_hdc_normal(&normal_identity_sha256)
        .map_err(|_| "normalLoaderIdentity.exactNormalTargetUnavailable")?;
    if before.serial_digest_sha256 != normal_identity_sha256 || before.topology.is_empty() {
        return Err("normalLoaderIdentity.normalIdentityMismatch");
    }
    let connector_identity_sha256 = usb
        .connector_identity(&before.topology)
        .map_err(|_| "normalLoaderIdentity.usbConnectorUnavailable")?;
    if connector_identity_sha256.len() != 64
        || !connector_identity_sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("normalLoaderIdentity.usbConnectorUnavailable");
    }
    let receipt = hdc
        .dispatch(&normal_hardware_identity_plan(connect_key))
        .map_err(|_| "normalLoaderIdentity.hardwareReadUnavailable")?;
    let hardware_serial_sha256 = hardware_serial(&receipt)?;
    let after = usb
        .single_hdc_normal(&normal_identity_sha256)
        .map_err(|_| "normalLoaderIdentity.normalIdentityChanged")?;
    if before != after
        || usb.connector_identity(&after.topology).as_ref() != Ok(&connector_identity_sha256)
    {
        return Err("normalLoaderIdentity.normalIdentityChanged");
    }
    Ok(NormalHardwareIdentity {
        normal_identity_sha256,
        hardware_serial_sha256,
        usb_topology: before.topology,
        connector_identity_sha256,
        stdout_sha256: sha256_hex(&receipt.stdout),
        stdout_byte_count: receipt.stdout.len(),
        vendor_serial: None,
    })
}

/// Preserve the kernel-serial route. Boards whose Loader uses a factory SN
/// need independent agreement with the bootloader's bounded vendor record,
/// the boot device tree and a repeated CPU/USB observation.
pub fn observe_normal_loader_identity(
    hdc: &dyn HdcDispatch,
    usb: &dyn UsbProbe,
    connect_key: &str,
    expected_loader_sha256: &str,
) -> Result<NormalHardwareIdentity, &'static str> {
    let started = std::time::Instant::now();
    let mut before = observe_normal_hardware_identity(hdc, usb, connect_key)?;
    if before.matches_loader(expected_loader_sha256) {
        return Ok(before);
    }
    let proof = crate::rockchip_vendor_identity::observe(
        hdc,
        connect_key,
        expected_loader_sha256,
        started,
    )?;
    let after = observe_normal_hardware_identity(hdc, usb, connect_key)?;
    if before != after || started.elapsed() > Duration::from_secs(30) {
        return Err("normalLoaderIdentity.vendorCaptureChangedOrExpired");
    }
    before.vendor_serial = Some(proof);
    Ok(before)
}

/// Fresh chain for a Normal-only historical binding. Unlike the ordinary
/// observer this never treats CPU equality as sufficient: both factory-SN
/// sources must agree, the CID must match the exact HDC route, and CPU and USB
/// attachment are sampled again before returning. This only observes; it does
/// not rebind a Target or authorize a mode transition.
pub fn observe_recommission_identity(
    hdc: &dyn HdcDispatch,
    usb: &dyn UsbProbe,
    connect_key: &str,
) -> Result<NormalHardwareIdentity, &'static str> {
    let started = std::time::Instant::now();
    let mut before = observe_normal_hardware_identity(hdc, usb, connect_key)?;
    let proof = crate::rockchip_vendor_identity::discover(hdc, connect_key, started)?;
    let after = observe_normal_hardware_identity(hdc, usb, connect_key)?;
    if before != after || started.elapsed() > Duration::from_secs(30) {
        return Err("normalLoaderIdentity.vendorCaptureChangedOrExpired");
    }
    before.vendor_serial = Some(proof);
    Ok(before)
}

fn hardware_serial(receipt: &Receipt) -> Result<String, &'static str> {
    let invalid = "normalLoaderIdentity.hardwareSerialMissingOrMalformed";
    if receipt.exit_status != 0
        || receipt.truncated
        || !receipt.stderr.is_empty()
        || receipt.stdout.len() > CAPTURE_BYTES
    {
        return Err("normalLoaderIdentity.hardwareReadUnconfirmed");
    }
    let text = std::str::from_utf8(&receipt.stdout).map_err(|_| invalid)?;
    let mut serials = text.lines().filter_map(|line| {
        let (key, value) = line.split_once(':')?;
        (key.trim() == "Serial").then(|| value.trim())
    });
    let serial = serials.next().ok_or(invalid)?;
    if serials.next().is_some()
        || serial.len() != 16
        || !serial.bytes().all(|byte| byte.is_ascii_hexdigit())
        || serial.bytes().all(|byte| byte == b'0')
        || serial.bytes().all(|byte| byte.eq_ignore_ascii_case(&b'f'))
    {
        return Err(invalid);
    }
    // Rockchip's kernel renders this value as sixteen lowercase hexadecimal
    // digits. Do not normalize a different presentation into a match with
    // the USB descriptor's exact-byte identity namespace.
    if serial.bytes().any(|byte| byte.is_ascii_uppercase()) {
        return Err(invalid);
    }
    Ok(sha256_hex(serial.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn receipt(stdout: &[u8]) -> Receipt {
        Receipt {
            exit_status: 0,
            stdout: stdout.to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::ZERO,
        }
    }

    #[test]
    fn fixed_target_scoped_read_and_unique_kernel_serial() {
        let plan = normal_hardware_identity_plan("normal-usb-cid");
        assert_eq!(
            plan.arguments,
            ["-t", "normal-usb-cid", "shell", "cat", "/proc/cpuinfo"]
        );
        assert_eq!(plan.capture_bytes, CAPTURE_BYTES);
        assert_eq!(plan.timeout, TIMEOUT);
        assert_eq!(
            hardware_serial(&receipt(b"processor\t: 0\nSerial\t\t: 0123456789abcdef\n")),
            Ok(sha256_hex(b"0123456789abcdef"))
        );
    }

    #[test]
    fn incomplete_ambiguous_default_and_unconfirmed_reads_never_prove_identity() {
        for bytes in [
            b"Hardware: RK3568\n".as_slice(),
            b"Serial: 0000000000000000\n",
            b"Serial: ffffffffffffffff\n",
            b"Serial: 0123456789ABCDEF\n",
            b"Serial: 0123456789abcde\n",
            b"Serial: 0123456789abcdef extra\n",
            b"Serial: 0123456789abcdef\nSerial: 0123456789abcdef\n",
            b"Serial: \xff\n",
        ] {
            assert!(hardware_serial(&receipt(bytes)).is_err());
        }
        let good = receipt(b"Serial: 0123456789abcdef\n");
        for bad in [
            Receipt {
                exit_status: 1,
                ..good.clone()
            },
            Receipt {
                truncated: true,
                ..good.clone()
            },
            Receipt {
                stderr: b"untrusted device diagnostic".to_vec(),
                ..good.clone()
            },
            receipt(&vec![b'x'; CAPTURE_BYTES + 1]),
        ] {
            assert_eq!(
                hardware_serial(&bad),
                Err("normalLoaderIdentity.hardwareReadUnconfirmed")
            );
        }
    }
}
