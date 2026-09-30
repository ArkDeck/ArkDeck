//! The facts the DevEco toolchain registry takes from DevEco Studio's
//! product manifest (`product-info.json`) and SDK manifest
//! (`sdk/default/sdk-pkg.json`). Both files have the same format on macOS and
//! Windows (TASK-XPA-011, G15); only the launch entry that must name this
//! host differs: `macOS` on `aarch64`/`x86_64`, `Windows` on `amd64` (the
//! Windows 11 x64 support tuple). Portable, and free of I/O: the caller
//! passes the bytes it read through the pinned DevEco reader.
use arkdeck_contract::strict_json;
use serde::Deserialize;

/// The launch entry a manifest must carry for the reading host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DevEcoLaunchHost {
    MacOs,
    Windows,
}

impl DevEcoLaunchHost {
    /// The host this build reads for, if DevEco supports it.
    pub const CURRENT: Option<Self> = if cfg!(target_os = "macos") {
        Some(Self::MacOs)
    } else if cfg!(all(windows, target_arch = "x86_64")) {
        Some(Self::Windows)
    } else {
        None
    };

    fn accepts(self, launch: &Launch) -> bool {
        match self {
            Self::MacOs => {
                launch.os == "macOS" && ["aarch64", "x86_64"].contains(&launch.arch.as_str())
            }
            Self::Windows => launch.os == "Windows" && launch.arch == "amd64",
        }
    }
}

/// What the two manifests establish.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DevEcoManifestFacts {
    pub product_version: String,
    pub build_number: String,
    pub sdk_version: String,
    pub api_version: String,
}

/// Why the manifests were refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DevEcoManifestError {
    /// Not strict JSON of the recorded shape.
    Unreadable,
    /// Well formed, but not DevEco Studio by Huawei for this host, or a
    /// version or identifier outside the closed spelling.
    Unsupported,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProductInfo {
    name: String,
    version: String,
    build_number: String,
    product_code: String,
    product_vendor: String,
    launch: Vec<Launch>,
}

#[derive(Deserialize)]
struct Launch {
    os: String,
    arch: String,
}

#[derive(Deserialize)]
struct SdkPackage {
    data: SdkData,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SdkData {
    api_version: String,
    platform_version: String,
    version: String,
}

pub(crate) fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
}

pub(crate) fn version(value: &str) -> bool {
    identifier(value) && value.bytes().any(|b| b.is_ascii_digit())
}

/// Parse and check the product and SDK manifests for `host`, with the
/// checks the macOS registry has always made.
pub fn parse_deveco_manifests(
    product: &[u8],
    sdk: &[u8],
    host: DevEcoLaunchHost,
) -> Result<DevEcoManifestFacts, DevEcoManifestError> {
    fn unreadable<E>(_: E) -> DevEcoManifestError {
        DevEcoManifestError::Unreadable
    }
    let product: ProductInfo =
        serde_json::from_value(strict_json(product).map_err(unreadable)?).map_err(unreadable)?;
    let sdk: SdkPackage =
        serde_json::from_value(strict_json(sdk).map_err(unreadable)?).map_err(unreadable)?;
    if product.name != "DevEco Studio"
        || product.product_code != "DS"
        || product.product_vendor != "Huawei"
        || !version(&product.version)
        || !identifier(&product.build_number)
        || !product.launch.iter().any(|launch| host.accepts(launch))
        || !version(&sdk.data.version)
        || !version(&sdk.data.platform_version)
        || !identifier(&sdk.data.api_version)
    {
        return Err(DevEcoManifestError::Unsupported);
    }
    Ok(DevEcoManifestFacts {
        product_version: product.version,
        build_number: product.build_number,
        sdk_version: sdk.data.version,
        api_version: sdk.data.api_version,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SDK: &str = r#"{"meta":{"version":"1.0.0"},"data":{"apiVersion":"99","displayName":"fixture","platformVersion":"9.9.9","version":"9.9.9.1"}}"#;

    fn product(os: &str, arch: &str) -> String {
        format!(
            r#"{{"name":"DevEco Studio","version":"9.8.7.6","buildNumber":"DS-999.1.2","productCode":"DS","productVendor":"Huawei","dataDirectoryName":"fixture","launch":[{{"os":"{os}","arch":"{arch}","launcherPath":"bin/fixture"}}]}}"#
        )
    }

    #[test]
    fn the_same_manifest_format_yields_the_same_facts_on_each_host() {
        let facts = DevEcoManifestFacts {
            product_version: "9.8.7.6".into(),
            build_number: "DS-999.1.2".into(),
            sdk_version: "9.9.9.1".into(),
            api_version: "99".into(),
        };
        for (host, os, arch) in [
            (DevEcoLaunchHost::MacOs, "macOS", "aarch64"),
            (DevEcoLaunchHost::MacOs, "macOS", "x86_64"),
            (DevEcoLaunchHost::Windows, "Windows", "amd64"),
        ] {
            assert_eq!(
                parse_deveco_manifests(product(os, arch).as_bytes(), SDK.as_bytes(), host),
                Ok(facts.clone())
            );
        }
        // A manifest for the other host, or another architecture, is not
        // this host's DevEco.
        for (host, os, arch) in [
            (DevEcoLaunchHost::Windows, "macOS", "aarch64"),
            (DevEcoLaunchHost::MacOs, "Windows", "amd64"),
            (DevEcoLaunchHost::Windows, "Windows", "aarch64"),
            (DevEcoLaunchHost::Windows, "Linux", "amd64"),
        ] {
            assert_eq!(
                parse_deveco_manifests(product(os, arch).as_bytes(), SDK.as_bytes(), host),
                Err(DevEcoManifestError::Unsupported)
            );
        }
    }

    #[test]
    fn malformed_or_foreign_manifests_are_refused() {
        let windows = DevEcoLaunchHost::Windows;
        let good = product("Windows", "amd64");
        for (product, sdk, error) in [
            (
                "{".to_owned(),
                SDK.to_owned(),
                DevEcoManifestError::Unreadable,
            ),
            (
                good.replace("\"launch\"", "\"launches\""),
                SDK.to_owned(),
                DevEcoManifestError::Unreadable,
            ),
            (
                good.clone(),
                SDK.replace("apiVersion", "api"),
                DevEcoManifestError::Unreadable,
            ),
            (
                good.replace("Huawei", "Other"),
                SDK.to_owned(),
                DevEcoManifestError::Unsupported,
            ),
            (
                good.replace("\"DS\"", "\"IC\""),
                SDK.to_owned(),
                DevEcoManifestError::Unsupported,
            ),
            (
                good.replace("9.8.7.6", "nine"),
                SDK.to_owned(),
                DevEcoManifestError::Unsupported,
            ),
            (
                good.replace("DS-999.1.2", "DS 999"),
                SDK.to_owned(),
                DevEcoManifestError::Unsupported,
            ),
            (
                good.clone(),
                SDK.replace("\"99\"", "\"\""),
                DevEcoManifestError::Unsupported,
            ),
        ] {
            assert_eq!(
                parse_deveco_manifests(product.as_bytes(), sdk.as_bytes(), windows),
                Err(error),
                "{product} {sdk}"
            );
        }
    }
}
