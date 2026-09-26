//! `arkdeck maintainer update-feed prepare|assemble` and its deprecated
//! `update-feed` spelling: Swift's `RuntimeCLI` update-feed handlers
//! with `UpdateFeedCodec` and `UpdateFeedVerifier.validateUnsignedPayloadForSigning`.
//!
//! A maintainer names a release artifact and its facts; this measures the
//! artifact (its bytes and SHA-256, read without following a link and
//! refused if it changes while measured), validates every payload field that
//! can be checked before signing, and writes the canonical payload and the
//! exact bytes to be signed (`ArkDeck.UpdateFeed.v1`, NUL, the production key
//! identity, NUL, the payload) into the output directory. It never holds or
//! asks for a private key; signing happens elsewhere, and `assemble` checks
//! the result.
// Measuring the artifact is macOS's (`arkdeck_platform::measure_unchanged_file`);
// elsewhere `prepare` refuses before it, leaving the validation unused.
#![cfg_attr(not(target_os = "macos"), allow(dead_code, unused_imports))]
use crate::CliError;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[path = "update_feed_signed.rs"]
pub mod signed;

/// Swift `UpdateFeedTrust.productionKeyID`.
pub const PRODUCTION_KEY_ID: &str = "arkdeck-update-2026-07-b949b102";
/// Swift `UpdateNetworkContract.allowedHosts`.
const ALLOWED_HOSTS: [&str; 3] = [
    "github.com",
    "release-assets.githubusercontent.com",
    "objects.githubusercontent.com",
];
/// Swift `UpdateFeedCodec.maximumPayloadBytes`.
const MAXIMUM_PAYLOAD_BYTES: usize = 64 * 1024;
/// Swift `UpdateFeedVerifier.maximumValiditySeconds`.
const MAXIMUM_VALIDITY_SECONDS: i64 = 30 * 24 * 60 * 60;

/// How `prepare` ends, as Swift's handler ends it.
#[derive(Debug)]
pub enum Answer {
    /// The machine document, and the human lines Swift prints instead (a
    /// release runbook, kept verbatim).
    Prepared { document: Value, lines: Vec<String> },
    /// `session.fail`: the failure envelope.
    Refused(CliError),
    /// A plain `CLIError`: a diagnostic and its exit status.
    Plain { exit_code: u8, message: String },
}

/// The leaf's options as Swift's `CLIOptions` reads the argv its registry
/// pass accepted: each flag and the value after it.
pub fn options(argv: &[String]) -> BTreeMap<String, String> {
    let mut options = BTreeMap::new();
    let mut index = 0;
    while index < argv.len() {
        if argv[index].starts_with("--")
            && let Some(value) = argv.get(index + 1)
        {
            options.insert(argv[index].clone(), value.clone());
            index += 2;
        } else {
            index += 1;
        }
    }
    options
}

/// Swift `URL(filePath:).standardizedFileURL.path`: a relative path against
/// the working directory, then standardized.
pub(crate) fn standardized_file(path: &str) -> String {
    let absolute = if path.starts_with('/') {
        path.to_owned()
    } else {
        std::env::current_dir()
            .map(|directory| directory.join(path).to_string_lossy().into_owned())
            .unwrap_or_else(|_| format!("/{path}"))
    };
    let mut components: Vec<&str> = Vec::new();
    for component in absolute.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                components.pop();
            }
            name => components.push(name),
        }
    }
    // Foundation drops a leading `/private` (or `/var/automount`) only where
    // what remains exists (`arkdeck_contract::foundation_path`'s rule): an
    // output directory not yet made keeps its `/private` spelling.
    let lexical = format!("/{}", components.join("/"));
    for prefix in ["/private/var/automount", "/var/automount", "/private"] {
        if let Some(rest) = lexical.strip_prefix(prefix)
            && rest.len() > 1
            && rest.starts_with('/')
            && std::fs::symlink_metadata(rest).is_ok()
        {
            return rest.to_owned();
        }
    }
    lexical
}

/// `argv` answered when it names an update-feed leaf in either spelling:
/// Swift's registry pass judges it, and an argv Swift would dispatch becomes
/// the leaf's invocation, its options as Swift's `CLIOptions` reads them.
pub(crate) fn answer(argv: &[String]) -> Option<Result<crate::Invocation, CliError>> {
    use crate::registry_parse::{self, Accepted};
    let command = registry_parse::leaf(argv).filter(|command| {
        matches!(
            *command,
            "maintainer.update-feed.prepare"
                | "update-feed.prepare"
                | "maintainer.update-feed.assemble"
                | "update-feed.assemble"
        )
    })?;
    let (help, handler) = match registry_parse::check(argv) {
        Err(error) => return Some(Err(error)),
        Ok(Some(Accepted::LeafHelp(_))) => (true, Vec::new()),
        Ok(Some(Accepted::Dispatch {
            handler_arguments, ..
        })) => (false, handler_arguments),
        Ok(_) => {
            return Some(Err(CliError::new(
                "internalError",
                format!("`{}` resolved to no answer", command.replace('.', " ")),
            )));
        }
    };
    let mode = argv
        .iter()
        .position(|token| token == "--output")
        .and_then(|index| argv.get(index + 1))
        .cloned();
    let params = options(&handler)
        .into_iter()
        .filter(|(flag, _)| !matches!(flag.as_str(), "--output" | "--control-request-id"))
        .map(|(flag, value)| (flag, json!(value)))
        .collect();
    Some(Ok(crate::Invocation {
        command,
        method: command,
        params: Some(params),
        json: mode.as_deref() == Some("json"),
        jsonl: mode.as_deref() == Some("jsonl"),
        raw: false,
        legacy_json: false,
        help,
        require_healthy: false,
        control_request_id: None,
        socket: None,
        timeout_ms: None,
    }))
}

/// Swift `UpdateFeedError`, by its case name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FeedError {
    Payload,
    Version,
    SystemVersion,
    Timestamp,
    ValidityWindow,
    ArtifactUrl,
    ArtifactLength,
    ArtifactDigest,
}

impl FeedError {
    fn name(self) -> &'static str {
        match self {
            Self::Payload => "invalidPayload",
            Self::Version => "invalidVersion",
            Self::SystemVersion => "invalidSystemVersion",
            Self::Timestamp => "invalidTimestamp",
            Self::ValidityWindow => "invalidValidityWindow",
            Self::ArtifactUrl => "invalidArtifactURL",
            Self::ArtifactLength => "invalidArtifactLength",
            Self::ArtifactDigest => "invalidArtifactDigest",
        }
    }
}

/// Swift `updateFeedFailure` of an `UpdateFeedError`: every one `prepare`
/// can meet is an invalid input, named in the words and the details.
fn feed_failure(error: FeedError, doing: &str) -> CliError {
    let mut failure = CliError::new("invalidInput", format!("{doing} failed: {}", error.name()));
    failure.details.insert("reason".into(), json!(error.name()));
    failure
}

/// Swift `UpdateSemanticVersion(_:)`: three dot-separated decimal numbers
/// without leading zeros.
pub(crate) fn semantic_version(value: &str) -> Option<(u64, u64, u64)> {
    let parts: Vec<&str> = value.split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    let mut numbers = [0_u64; 3];
    for (slot, part) in numbers.iter_mut().zip(&parts) {
        if part.is_empty()
            || !part.bytes().all(|byte| byte.is_ascii_digit())
            || (*part != "0" && part.starts_with('0'))
        {
            return None;
        }
        *slot = part.parse().ok()?;
    }
    Some((numbers[0], numbers[1], numbers[2]))
}

/// Swift `normalizedSystemVersion`: a two-part system version gains `.0`.
pub(crate) fn normalized_system(value: &str) -> String {
    if value.split('.').count() == 2 {
        format!("{value}.0")
    } else {
        value.to_owned()
    }
}

/// Swift `ISO8601Timestamps.parseCanonicalPlain`: exactly
/// `YYYY-MM-DDTHH:MM:SSZ`, a real instant, as seconds since the epoch.
pub(crate) fn canonical_timestamp(value: &str) -> Option<i64> {
    let bytes = value.as_bytes();
    if !value.is_ascii()
        || bytes.len() != 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'Z'
    {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i64> {
        let text = &value[range];
        text.bytes()
            .all(|byte| byte.is_ascii_digit())
            .then(|| text.parse().ok())
            .flatten()
    };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    let days_in_month = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if year < 1
        || !(1..=12).contains(&month)
        || day < 1
        || day > days_in_month[(month - 1) as usize]
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let shifted = if month <= 2 { year - 1 } else { year };
    let era = shifted.div_euclid(400);
    let year_of_era = shifted - era * 400;
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

/// Swift `isIPAddress`.
fn ip_address(host: &str) -> bool {
    let parts: Vec<&str> = host.split('.').collect();
    host.contains(':') || (parts.len() == 4 && parts.iter().all(|part| part.parse::<u8>().is_ok()))
}

/// Swift `validateArtifact`'s URL: `URLComponents(string:)` of an https URL
/// with no user, password, port or fragment, an allowed host that is not an
/// address, a path ending in `.dmg`, and a spelling it would write back as is.
fn artifact_url(url: &str) -> bool {
    // `URLComponents(string:)` refuses a string outside the URL character set.
    let legal = |byte: u8| byte.is_ascii_alphanumeric() || b"-._~:/?#@!$&'()*+,;=%".contains(&byte);
    if !url.bytes().all(legal) {
        return false;
    }
    // URLComponents percent-decodes `.path`, but preserves valid escape
    // spelling in `.url.absoluteString`. A malformed escape is re-escaped
    // by Foundation, so the required round-trip equality rejects it.
    let decode = |text: &str| -> Option<Vec<u8>> {
        let mut result = Vec::new();
        let mut bytes = text.bytes();
        while let Some(byte) = bytes.next() {
            if byte == b'%' {
                let high = char::from(bytes.next()?).to_digit(16)?;
                let low = char::from(bytes.next()?).to_digit(16)?;
                result.push((high * 16 + low) as u8);
            } else {
                result.push(byte);
            }
        }
        Some(result)
    };
    if decode(url).is_none() {
        return false;
    }
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    if rest.contains('#') {
        return false;
    }
    let (authority, path_and_query) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, ""),
    };
    if authority.contains('@') || authority.contains(':') || authority.is_empty() {
        return false;
    }
    let Some(host) = decode(authority).and_then(|bytes| String::from_utf8(bytes).ok()) else {
        return false;
    };
    let host = host.to_lowercase();
    let path = path_and_query.split('?').next().unwrap_or_default();
    ALLOWED_HOSTS.contains(&host.as_str())
        && !ip_address(&host)
        && decode(path)
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .is_some_and(|path| path.ends_with(".dmg"))
}

/// Swift `measureArtifact`: its bytes and SHA-256, the file opened without
/// following a link, a non-empty regular file that did not change while it
/// was read. A failure is Swift's plain `CLIError`, exit 2.
#[cfg(target_os = "macos")]
fn measure(path: &Path) -> Result<(u64, String), (u8, String)> {
    use arkdeck_platform::FileMeasureError;
    arkdeck_platform::measure_unchanged_file(path).map_err(|error| {
        (
            2,
            match error {
                FileMeasureError::Open(errno) => format!("cannot open artifact (errno {errno})"),
                FileMeasureError::NotRegularOrEmpty => {
                    "artifact must be a non-empty regular file".to_owned()
                }
                FileMeasureError::Read(errno) => format!("artifact read failed (errno {errno})"),
                FileMeasureError::Changed => "artifact changed while being measured".to_owned(),
            },
        )
    })
}

/// Foundation's `Data.write(to:options: .atomic)`: a sibling written whole,
/// then renamed over the name.
fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = path.with_file_name(format!(
        ".dat.nosync{:08x}.{name}",
        u32::from_ne_bytes(arkdeck_platform::random_bytes::<4>()?)
    ));
    // Foundation's atomic write stages the bytes in a new owner-only file.
    {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&temporary)?;
        file.write_all(bytes).inspect_err(|_| {
            let _ = std::fs::remove_file(&temporary);
        })?;
    }
    std::fs::rename(&temporary, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}

/// Swift `updateFeedFailure` of a Foundation error: a missing file is
/// `resourceNotFound`, anything else `ioFailure`.
fn io_failure(error: &std::io::Error, doing: &str) -> CliError {
    let code = if error.kind() == std::io::ErrorKind::NotFound {
        "resourceNotFound"
    } else {
        "ioFailure"
    };
    CliError::new(code, format!("{doing} failed: {error}"))
}

fn signed_failure(reason: &str, doing: &str) -> CliError {
    let code = match reason {
        "feedTooLarge" | "payloadTooLarge" => "inputTooLarge",
        "invalidSignature" | "unknownKey" => "artifactIntegrityFailed",
        _ => "invalidInput",
    };
    let mut error = CliError::new(code, format!("{doing} failed: {reason}"));
    error.details.insert("reason".into(), json!(reason));
    error
}

/// Reads only the bytes the codec can accept plus one overflow sentinel.
fn read_bounded(path: &str, maximum: usize) -> std::io::Result<Vec<u8>> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(maximum as u64 + 1)
        .read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn read_failure(error: &std::io::Error, path: &str) -> CliError {
    if error.kind() == std::io::ErrorKind::NotFound {
        let name = Path::new(path)
            .file_name()
            .unwrap_or_default()
            .to_string_lossy();
        return CliError::new(
            "resourceNotFound",
            format!(
                "reading {path} failed: The file “{name}” couldn’t be opened because there is no such file."
            ),
        );
    }
    io_failure(error, &format!("reading {path}"))
}

/// The release maintainer assembles already-signed public material. No private
/// key or caller-selected trust root enters this command.
pub fn assemble(options: &BTreeMap<String, String>) -> Answer {
    let (Some(payload_path), Some(signature_path), Some(out)) = (
        options.get("--payload"),
        options.get("--signature"),
        options.get("--out"),
    ) else {
        return Answer::Plain {
            exit_code: 64,
            message: "assemble requires --payload, --signature and --out".into(),
        };
    };
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (payload_path, signature_path, out);
        Answer::Refused(CliError::new(
            "unsupportedOnPlatform",
            "the update feed maintainer tools are macOS-only",
        ))
    }
    #[cfg(target_os = "macos")]
    {
        let payload = match read_bounded(payload_path, MAXIMUM_PAYLOAD_BYTES) {
            Ok(bytes) => bytes,
            Err(error) => {
                return Answer::Refused(read_failure(&error, payload_path));
            }
        };
        let signature = match read_bounded(signature_path, 64) {
            Ok(bytes) => bytes,
            Err(error) => {
                return Answer::Refused(read_failure(&error, signature_path));
            }
        };
        let verified = (|| {
            let envelope = signed::assemble(&payload, &signature, PRODUCTION_KEY_ID)?;
            let (decoded, _) = signed::decode_and_verify(
                &envelope,
                PRODUCTION_KEY_ID,
                &signed::PRODUCTION_PUBLIC_KEY,
            )?;
            Ok::<_, signed::Error>((envelope, decoded))
        })();
        let (envelope, decoded) = match verified {
            Ok(value) => value,
            Err(error) => return Answer::Refused(signed_failure(error, "assembling the feed")),
        };
        let now = match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
            Ok(duration) => i64::try_from(duration.as_secs()).unwrap_or(i64::MAX),
            Err(_) => -1,
        };
        if let Err(error) = signed::validate_at(&decoded, now) {
            return Answer::Refused(signed_failure(error, "verifying and writing the feed"));
        }
        // The maintainer's replay store is empty and in-memory; installed
        // version is 0.0.0. Unsupported OS is a successful no-update result,
        // not a refusal to publish, so it cannot change this output.
        let output = standardized_file(out);
        if let Err(error) = write_atomically(Path::new(&output), &envelope) {
            return Answer::Refused(io_failure(&error, "verifying and writing the feed"));
        }
        let digest = arkdeck_contract::sha256_hex(&envelope);
        Answer::Prepared {
            lines: vec![
                format!("feed: {output}"),
                format!("feed sha256: {digest}"),
                "self-verification: valid".into(),
            ],
            document: json!({"feedPath":output,"feedSha256":digest,
                "keyId":PRODUCTION_KEY_ID,"selfVerified":true}),
        }
    }
}

/// Swift `prepareUpdateFeed`.
pub fn prepare(options: &BTreeMap<String, String>) -> Answer {
    let value = |flag: &str| options.get(flag).map(String::as_str);
    let fields = (
        value("--sequence")
            .and_then(|text| text.parse::<u64>().ok())
            .filter(|n| *n > 0),
        value("--version"),
        value("--minimum-system"),
        value("--issued-at"),
        value("--expires-at"),
        value("--artifact"),
        value("--artifact-url"),
        value("--notes"),
        value("--out"),
    );
    let (
        Some(sequence),
        Some(version),
        Some(minimum),
        Some(issued),
        Some(expires),
        Some(artifact),
        Some(url),
        Some(notes),
        Some(out),
    ) = fields
    else {
        return Answer::Plain {
            exit_code: 64,
            message: "prepare requires sequence/version/minimum-system/issued-at/expires-at/\
                      artifact/artifact-url/notes/out"
                .into(),
        };
    };
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (
            sequence, version, minimum, issued, expires, artifact, url, notes, out,
        );
        Answer::Refused(CliError::new(
            "unsupportedOnPlatform",
            "the update feed maintainer tools are macOS-only",
        ))
    }
    #[cfg(target_os = "macos")]
    {
        let artifact_path = standardized_file(artifact);
        let (length, digest) = match measure(Path::new(&artifact_path)) {
            Ok(measured) => measured,
            Err((exit_code, message)) => return Answer::Plain { exit_code, message },
        };
        let doing = "preparing the payload";
        let payload = json!({"sequence": sequence, "version": version,
            "minimumSystemVersion": minimum, "architectures": ["arm64"], "issuedAt": issued,
            "expiresAt": expires, "artifact": {"url": url, "byteLength": length, "sha256": digest},
            "releaseNotesSummary": notes});
        // Swift then refuses a value whose `precomposedStringWithCanonicalMapping`
        // is not `==` to it; Swift's `==` is canonical equivalence, which NFC
        // always keeps, so that guard never refuses and has no port.
        if let Err(error) = validate(
            version, minimum, notes, issued, expires, length, &digest, url,
        ) {
            return Answer::Refused(feed_failure(error, doing));
        }
        let canonical = match signed::canonical(&payload) {
            Ok(bytes) => bytes,
            Err(_) => return Answer::Refused(feed_failure(FeedError::Payload, doing)),
        };
        if canonical.len() > MAXIMUM_PAYLOAD_BYTES {
            return Answer::Refused(feed_failure(FeedError::Payload, doing));
        }
        let mut input = b"ArkDeck.UpdateFeed.v1".to_vec();
        input.push(0);
        input.extend_from_slice(PRODUCTION_KEY_ID.as_bytes());
        input.push(0);
        input.extend_from_slice(&canonical);
        let output = PathBuf::from(standardized_file(out));
        let payload_path = output.join("arkdeck-update-payload-v1.json");
        let input_path = output.join("arkdeck-update-signature-input-v1.bin");
        let written = (|| {
            let mut directories = std::fs::DirBuilder::new();
            std::os::unix::fs::DirBuilderExt::mode(&mut directories, 0o700);
            directories.recursive(true).create(&output)?;
            write_atomically(&payload_path, &canonical)?;
            write_atomically(&input_path, &input)
        })();
        if let Err(error) = written {
            return Answer::Refused(io_failure(&error, doing));
        }
        let payload_path = payload_path.to_string_lossy().into_owned();
        let input_path = input_path.to_string_lossy().into_owned();
        Answer::Prepared {
            lines: vec![
                format!("payload: {payload_path}"),
                format!("signature input: {input_path}"),
                format!("artifact bytes: {length}"),
                format!("artifact sha256: {digest}"),
                format!("key ID: {PRODUCTION_KEY_ID}"),
            ],
            document: json!({"payloadPath": payload_path, "signatureInputPath": input_path,
                "artifact": {"url": url, "byteLength": length, "sha256": digest},
                "keyId": PRODUCTION_KEY_ID, "sequence": sequence, "version": version}),
        }
    }
}

/// Swift `validateStaticPayload`, in its order.
#[allow(clippy::too_many_arguments)]
fn validate(
    version: &str,
    minimum: &str,
    notes: &str,
    issued: &str,
    expires: &str,
    length: u64,
    digest: &str,
    url: &str,
) -> Result<(), FeedError> {
    semantic_version(version).ok_or(FeedError::Version)?;
    semantic_version(&normalized_system(minimum))
        .filter(|minimum| *minimum >= (14, 0, 0))
        .ok_or(FeedError::SystemVersion)?;
    if notes.len() > 4 * 1024 {
        return Err(FeedError::Payload);
    }
    let issued = canonical_timestamp(issued).ok_or(FeedError::Timestamp)?;
    let expires = canonical_timestamp(expires).ok_or(FeedError::Timestamp)?;
    let duration = expires - issued;
    if duration <= 0 || duration > MAXIMUM_VALIDITY_SECONDS {
        return Err(FeedError::ValidityWindow);
    }
    if length == 0 {
        return Err(FeedError::ArtifactLength);
    }
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(FeedError::ArtifactDigest);
    }
    if !artifact_url(url) {
        return Err(FeedError::ArtifactUrl);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timestamp_is_canonical_plain_utc() {
        assert_eq!(canonical_timestamp("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            canonical_timestamp("2026-09-30T00:00:00Z").unwrap()
                - canonical_timestamp("2026-09-01T00:00:00Z").unwrap(),
            29 * 86_400
        );
        for bad in [
            "2026-09-01T00:00:00.000Z",
            "2026-09-01T00:00:00+00:00",
            "2026-02-30T00:00:00Z",
            "2026-09-01 00:00:00Z",
            "2026-09-01T24:00:00Z",
        ] {
            assert_eq!(canonical_timestamp(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_version_is_three_plain_numbers() {
        assert_eq!(semantic_version("1.2.3"), Some((1, 2, 3)));
        assert_eq!(semantic_version("10.0.0"), Some((10, 0, 0)));
        for bad in ["1.2", "1.02.3", "1.2.3.4", "a.b.c", "1..3"] {
            assert_eq!(semantic_version(bad), None, "{bad}");
        }
        assert_eq!(normalized_system("14.0"), "14.0.0");
    }
}
