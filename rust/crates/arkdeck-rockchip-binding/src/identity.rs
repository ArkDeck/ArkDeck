//! Swift `RockchipProductUSBIdentity`'s personalities of a DAYU200, over one
//! entry of the host's I/O Registry census.
use arkdeck_platform::UsbHostDevice;

/// Swift `RockchipProbeEvidence.rockUSBVendorID`.
pub const ROCKUSB_VENDOR_ID: u16 = 0x2207;
/// Swift `RockchipHDCIntegrationProfile.dayu200NormalProductID`.
pub const DAYU200_NORMAL_PRODUCT_ID: u16 = 0x5000;
/// Swift `RockchipProbeEvidence.dayu200LoaderProductID`: the RockUSB Loader
/// personality of the board.
pub const DAYU200_LOADER_PRODUCT_ID: u16 = 0x350a;
/// The product name of the board's HDC-normal personality, once quotes and
/// spaces are trimmed from both ends.
const HDC_NORMAL_PRODUCT_NAME: &str = "HDC Device";

/// Swift `RockchipProductUSBIdentity.isHDCNormal`: the registered vendor, the
/// DAYU200's normal-mode product, and a product name that is exactly
/// `HDC Device` once quotes and spaces are trimmed from both ends. The Loader
/// personality and every other device are not.
pub fn is_dayu200_hdc_normal(device: &UsbHostDevice) -> bool {
    device.vendor_id == ROCKUSB_VENDOR_ID
        && device.product_id == DAYU200_NORMAL_PRODUCT_ID
        && device
            .product_name
            .as_deref()
            .is_some_and(|name| name.trim_matches(['"', ' ']) == HDC_NORMAL_PRODUCT_NAME)
}

/// Swift `RockchipProductUSBIdentity.isLoader`: the registered vendor and the
/// DAYU200's Loader product, whatever name it reports.
pub fn is_dayu200_loader(device: &UsbHostDevice) -> bool {
    device.vendor_id == ROCKUSB_VENDOR_ID && device.product_id == DAYU200_LOADER_PRODUCT_ID
}

/// Swift `RockchipProductUSBProbe.registeredDAYU200Identities()` over one
/// census: every device in a registered DAYU200 personality, Loader or
/// HDC-normal, in census order and without deduplication; a registry entry ID
/// is not required.
pub fn registered_dayu200_devices(devices: Vec<UsbHostDevice>) -> Vec<UsbHostDevice> {
    devices
        .into_iter()
        .filter(|device| is_dayu200_loader(device) || is_dayu200_hdc_normal(device))
        .collect()
}
