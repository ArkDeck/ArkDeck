//! Swift's pointer gestures — `input.tap@1`, `input.long-press@1` and
//! `input.swipe@1` — as `HDCObservationProviderAdapter` injects them
//! (`HDCPointerInputSpec`, `pointerInputSpec`, the `injectPointerInput`
//! lowering, verdict, persisted form and reconciliation): one primary
//! pointer gesture at exact device coordinates, bounded inside the frame it
//! was mapped against, refused when that frame is older than the freshness
//! budget, lowered to `uinput -T`, and judged by the injector's own
//! acknowledgement rather than by an exit status `hdc shell` never
//! propagates (measured 2026-08-25 on OpenHarmony-7.0.0.39). An injected
//! gesture leaves nothing to read back, so an unknown outcome stays unknown.

use crate::capture_files::{FileActionError, FilePlan};
use crate::operation::{Outcome, ProcessPlan, Receipt, RequestError};
use crate::readback::Reconcile;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;

/// Swift `HDCPointerInputSpec.coordinateRange`.
pub const COORDINATE_MAXIMUM: i64 = 32767;
/// Swift `HDCPointerInputSpec.durationRangeMs`.
pub const DURATION_MINIMUM_MS: i64 = 80;
pub const DURATION_MAXIMUM_MS: i64 = 2000;
/// Swift `HDCPointerInputSpec.displayRange`.
pub const DISPLAY_MAXIMUM: i64 = 64;
/// Swift `HDCPointerInputSpec.defaultLongPressMs`: the bounded stand-in
/// hold for a long press whose caller reported no press time.
pub const DEFAULT_LONG_PRESS_MS: i64 = 800;
/// Swift `HDCPointerInputSpec.frameFreshnessBudgetMs`: how stale the frame
/// a gesture was computed from may be when it is about to be injected.
pub const FRAME_FRESHNESS_BUDGET_MS: i64 = 1000;
/// The dispatcher's capture budget, as the other legs use it.
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;

/// Swift `HDCPointerGesture`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Gesture {
    Tap,
    LongPress,
    Swipe,
}

impl Gesture {
    /// The gesture the operation injects (Swift `pointerInputSpec`'s switch).
    pub fn for_operation(reference: &str) -> Option<Self> {
        match reference {
            "input.tap@1" => Some(Self::Tap),
            "input.long-press@1" => Some(Self::LongPress),
            "input.swipe@1" => Some(Self::Swipe),
            _ => None,
        }
    }

    /// Swift's raw value.
    pub fn raw(self) -> &'static str {
        match self {
            Self::Tap => "tap",
            Self::LongPress => "longPress",
            Self::Swipe => "swipe",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "tap" => Some(Self::Tap),
            "longPress" => Some(Self::LongPress),
            "swipe" => Some(Self::Swipe),
            _ => None,
        }
    }

    /// The lines `uinput` prints for the gesture it accepted, lowercased;
    /// every one is required.
    fn acknowledgement(self) -> &'static [&'static str] {
        match self {
            Self::Tap => &["click coordinate"],
            Self::LongPress => &["touch down", "touch up"],
            Self::Swipe => &["startx:", "endx:"],
        }
    }
}

/// Swift `HDCPointerInputSpec`: one gesture at exact device coordinates
/// with the frame it was mapped against.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PointerInput {
    pub gesture: Gesture,
    pub x: i64,
    pub y: i64,
    pub to_x: Option<i64>,
    pub to_y: Option<i64>,
    pub duration_ms: Option<i64>,
    pub display_id: Option<i64>,
    pub display_width: i64,
    pub display_height: i64,
    /// Capture time of the frame, when the caller supplied one.
    pub screen_epoch_utc: Option<String>,
}

fn out_of_bounds(field: &'static str, detail: &str) -> RequestError {
    RequestError::OutOfBounds {
        field,
        detail: detail.to_owned(),
    }
}

impl PointerInput {
    /// Swift `HDCPointerInputSpec.init`: the closed bounds in Swift's order
    /// of refusal, the frame guard last.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        gesture: Gesture,
        x: i64,
        y: i64,
        display_width: i64,
        display_height: i64,
        to_x: Option<i64>,
        to_y: Option<i64>,
        duration_ms: Option<i64>,
        display_id: Option<i64>,
        screen_epoch_utc: Option<String>,
    ) -> Result<Self, RequestError> {
        let coordinate = |value: i64| (0..=COORDINATE_MAXIMUM).contains(&value);
        let duration = |value: i64| (DURATION_MINIMUM_MS..=DURATION_MAXIMUM_MS).contains(&value);
        for (value, field) in [(x, "pointerX"), (y, "pointerY")] {
            if !coordinate(value) {
                return Err(out_of_bounds(field, "0...32767"));
            }
        }
        match gesture {
            Gesture::Swipe => {
                let (Some(to_x), Some(to_y), Some(duration_ms)) = (to_x, to_y, duration_ms) else {
                    return Err(out_of_bounds(
                        "pointerToX/pointerToY/durationMs",
                        "required for a swipe",
                    ));
                };
                for (value, field) in [(to_x, "pointerToX"), (to_y, "pointerToY")] {
                    if !coordinate(value) {
                        return Err(out_of_bounds(field, "0...32767"));
                    }
                }
                if !duration(duration_ms) {
                    return Err(out_of_bounds("durationMs", "80...2000"));
                }
            }
            Gesture::LongPress => {
                if to_x.is_some() || to_y.is_some() {
                    return Err(out_of_bounds(
                        "pointerToX/pointerToY",
                        "only a swipe travels",
                    ));
                }
                if let Some(duration_ms) = duration_ms
                    && !duration(duration_ms)
                {
                    return Err(out_of_bounds("durationMs", "80...2000"));
                }
            }
            Gesture::Tap => {
                if to_x.is_some() || to_y.is_some() || duration_ms.is_some() {
                    return Err(out_of_bounds(
                        "pointerToX/pointerToY/durationMs",
                        "a tap carries none of these",
                    ));
                }
            }
        }
        if let Some(display_id) = display_id
            && !(0..=DISPLAY_MAXIMUM).contains(&display_id)
        {
            return Err(out_of_bounds("displayId", "0...64"));
        }
        if display_width <= 0 || display_height <= 0 {
            return Err(out_of_bounds(
                "displayWidth/displayHeight",
                "positive device pixels",
            ));
        }
        // Every point the gesture names has to fit the frame it was mapped
        // against: `uinput` injects a coordinate it never checked.
        for (px, py, label) in [
            (x, y, "pointer"),
            (to_x.unwrap_or(x), to_y.unwrap_or(y), "pointerTo"),
        ] {
            if px >= display_width || py >= display_height {
                return Err(out_of_bounds(
                    label,
                    &format!("inside the declared {display_width}x{display_height} frame"),
                ));
            }
        }
        Ok(Self {
            gesture,
            x,
            y,
            to_x,
            to_y,
            duration_ms,
            display_id,
            display_width,
            display_height,
            screen_epoch_utc,
        })
    }

    /// Swift `pointerInputSpec` over the request's inputs (already
    /// schema-bounded by admission), the freshness gate excluded: see
    /// [`PointerInput::refuse_if_stale`].
    pub fn from_inputs(
        operation_reference: &str,
        inputs: &Map<String, Value>,
    ) -> Result<Self, FileActionError> {
        let Some(gesture) = Gesture::for_operation(operation_reference) else {
            return Err(FileActionError::Unsupported(format!(
                "{operation_reference} has no registered pointer gesture"
            )));
        };
        let required = |key: &str| -> Result<i64, FileActionError> {
            match inputs.get(key).and_then(Value::as_i64) {
                Some(value) => Ok(value),
                None => Err(FileActionError::Unsupported(format!(
                    "{key} is required for a pointer input"
                ))),
            }
        };
        let optional_integer = |key: &str| -> Result<Option<i64>, FileActionError> {
            match inputs.get(key) {
                None => Ok(None),
                Some(raw) => match raw.as_i64() {
                    Some(value) => Ok(Some(value)),
                    None => Err(FileActionError::Unsupported(format!(
                        "{key} must be an integer"
                    ))),
                },
            }
        };
        let optional_string = |key: &str| -> Result<Option<String>, FileActionError> {
            match inputs.get(key) {
                None => Ok(None),
                Some(Value::String(value)) => Ok(Some(value.clone())),
                Some(_) => Err(FileActionError::Unsupported(format!(
                    "{key} must be a string"
                ))),
            }
        };
        let frame_width = required("displayWidth")?;
        let frame_height = required("displayHeight")?;
        let spec = if gesture == Gesture::Swipe {
            Self::new(
                gesture,
                required("fromX")?,
                required("fromY")?,
                frame_width,
                frame_height,
                Some(required("toX")?),
                Some(required("toY")?),
                Some(required("durationMs")?),
                optional_integer("displayId")?,
                optional_string("screenEpochUtc")?,
            )
        } else {
            Self::new(
                gesture,
                required("x")?,
                required("y")?,
                frame_width,
                frame_height,
                None,
                None,
                optional_integer("durationMs")?,
                optional_integer("displayId")?,
                optional_string("screenEpochUtc")?,
            )
        };
        spec.map_err(FileActionError::Request)
    }

    /// Swift `frameAgeMs(atUTC:)`: how old the frame is at `now_utc`, or
    /// nothing when the caller supplied no epoch or either stamp does not
    /// parse — no freshness claim is invented from an absent fact.
    pub fn frame_age_ms(&self, now_utc: &str) -> Option<i64> {
        let captured = utc_nanoseconds(self.screen_epoch_utc.as_deref()?)?;
        let now = utc_nanoseconds(now_utc)?;
        Some(((now - captured) as f64 / 1_000_000.0).round() as i64)
    }

    /// The freshness gate `pointerInputSpec` applies at dispatch time, not
    /// submit time: an input that sat behind the device lane is discarded
    /// before any action exists, so nothing is dispatched and the outcome
    /// is a clean refusal.
    pub fn refuse_if_stale(&self, now_utc: &str) -> Result<(), FileActionError> {
        match self.frame_age_ms(now_utc) {
            Some(age) if age > FRAME_FRESHNESS_BUDGET_MS => {
                Err(FileActionError::Unsupported(format!(
                    "inputExpired: the frame this gesture was mapped against is {age} ms old, \
                     beyond the {FRAME_FRESHNESS_BUDGET_MS} ms freshness bound; refresh the \
                     screen and send a new gesture"
                )))
            }
            _ => Ok(()),
        }
    }

    /// Swift `loweredHoldMs`: the hold interval the device command is
    /// given — a swipe's real press-to-release time, a long press's own or
    /// the bounded default, nothing for a tap.
    pub fn lowered_hold_ms(&self) -> Option<i64> {
        match self.gesture {
            Gesture::Tap => None,
            Gesture::Swipe => self.duration_ms,
            Gesture::LongPress => Some(self.duration_ms.unwrap_or(DEFAULT_LONG_PRESS_MS)),
        }
    }

    /// Swift's durable typed intent for `hdc.injectPointerInput`: the
    /// journal form, the frame's capture time kept when the caller sent one.
    pub fn persisted(&self) -> (&'static str, Map<String, Value>) {
        let mut arguments = Map::new();
        arguments.insert("gesture".into(), Value::from(self.gesture.raw()));
        arguments.insert("pointerX".into(), Value::from(self.x));
        arguments.insert("pointerY".into(), Value::from(self.y));
        if let Some(to_x) = self.to_x {
            arguments.insert("pointerToX".into(), Value::from(to_x));
        }
        if let Some(to_y) = self.to_y {
            arguments.insert("pointerToY".into(), Value::from(to_y));
        }
        if let Some(duration_ms) = self.duration_ms {
            arguments.insert("durationMs".into(), Value::from(duration_ms));
        }
        if let Some(display_id) = self.display_id {
            arguments.insert("displayId".into(), Value::from(display_id));
        }
        arguments.insert("displayWidth".into(), Value::from(self.display_width));
        arguments.insert("displayHeight".into(), Value::from(self.display_height));
        if let Some(epoch) = &self.screen_epoch_utc {
            arguments.insert("screenEpochUtc".into(), Value::from(epoch.as_str()));
        }
        ("hdc.injectPointerInput", arguments)
    }

    /// Swift's decoder of that intent (`ProviderDurableIntentReference`,
    /// `hdc.injectPointerInput`): the persisted gesture must be one Swift
    /// knows; the bounds are checked again.
    pub fn from_persisted(arguments: &Map<String, Value>) -> Result<Self, FileActionError> {
        let Some(gesture) = arguments
            .get("gesture")
            .and_then(Value::as_str)
            .and_then(Gesture::parse)
        else {
            return Err(FileActionError::Unsupported(
                "persisted pointer gesture is invalid".into(),
            ));
        };
        let integer = |key: &str| arguments.get(key).and_then(Value::as_i64).unwrap_or(0);
        let optional = |key: &str| arguments.get(key).and_then(Value::as_i64);
        Self::new(
            gesture,
            integer("pointerX"),
            integer("pointerY"),
            integer("displayWidth"),
            integer("displayHeight"),
            optional("pointerToX"),
            optional("pointerToY"),
            optional("durationMs"),
            optional("displayId"),
            arguments
                .get("screenEpochUtc")
                .and_then(Value::as_str)
                .map(str::to_owned),
        )
        .map_err(FileActionError::Request)
    }
}

/// Swift `ISO8601Timestamps.parse` for the stamps the gate compares: a UTC
/// instant `YYYY-MM-DDTHH:MM:SS[.fraction]Z`, as nanoseconds since the
/// epoch.
fn utc_nanoseconds(value: &str) -> Option<i128> {
    let bytes = value.as_bytes();
    if bytes.len() < 20 || bytes[bytes.len() - 1] != b'Z' {
        return None;
    }
    let digits = |range: std::ops::Range<usize>| -> Option<i64> {
        let text = std::str::from_utf8(&bytes[range]).ok()?;
        if !text.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        text.parse().ok()
    };
    if bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return None;
    }
    let (year, month, day) = (digits(0..4)?, digits(5..7)?, digits(8..10)?);
    let (hour, minute, second) = (digits(11..13)?, digits(14..16)?, digits(17..19)?);
    let fraction = &bytes[19..bytes.len() - 1];
    let nanoseconds = match fraction {
        [] => 0,
        [b'.', rest @ ..] if !rest.is_empty() && rest.len() <= 9 => {
            let mut scaled = digits(20..20 + rest.len())?;
            for _ in rest.len()..9 {
                scaled *= 10;
            }
            scaled
        }
        _ => return None,
    };
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let (y, m) = if month <= 2 {
        (year - 1, month + 9)
    } else {
        (year, month - 3)
    };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let seconds = days * 86_400 + hour * 3600 + minute * 60 + second;
    Some(i128::from(seconds) * 1_000_000_000 + i128::from(nanoseconds))
}

/// Swift `.hdc(.injectPointerInput(spec))`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PointerAction(pub PointerInput);

impl fmt::Display for PointerAction {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "hdc.injectPointerInput({})",
            self.0.gesture.raw()
        )
    }
}

impl PointerAction {
    /// Swift `HDCObservationProviderAdapter.action` for an
    /// `injectPointerInput` step of one of the three operations at dispatch
    /// time (`now_utc` the provider's clock): the spec from the inputs, then
    /// the freshness gate. Any other step kind is not this module's.
    pub fn for_step(
        step_kind: &str,
        operation_reference: &str,
        inputs: &Map<String, Value>,
        now_utc: &str,
    ) -> Result<Option<Self>, FileActionError> {
        if step_kind != "injectPointerInput" {
            return Ok(None);
        }
        let spec = PointerInput::from_inputs(operation_reference, inputs)?;
        spec.refuse_if_stale(now_utc)?;
        Ok(Some(Self(spec)))
    }

    pub fn effect(&self) -> &'static str {
        "deviceMutation"
    }

    /// Swift's lowering: `uinput -T` argv is positional — the display
    /// selector, when present, precedes the device option; the touch
    /// commands follow it — on one 30 s process.
    pub fn lower(&self, step_id: &str, connect_key: Option<&str>) -> Result<FilePlan, String> {
        let key = match connect_key {
            Some(key) if !key.is_empty() => key,
            _ => {
                return Err(format!(
                    "factsUnavailable(\"{step_id} has no descriptor-bound target connect key\")"
                ));
            }
        };
        let spec = &self.0;
        let mut arguments = vec![
            "-t".to_owned(),
            key.to_owned(),
            "shell".into(),
            "uinput".into(),
        ];
        if let Some(display_id) = spec.display_id {
            arguments.push("-D".into());
            arguments.push(display_id.to_string());
        }
        arguments.push("-T".into());
        match spec.gesture {
            Gesture::Tap => {
                arguments.extend(["-c".to_owned(), spec.x.to_string(), spec.y.to_string()]);
            }
            Gesture::LongPress => {
                // No single long-press command exists: press, hold for the
                // interval, release at the same point.
                let hold = spec.lowered_hold_ms().unwrap_or(DEFAULT_LONG_PRESS_MS);
                arguments.extend([
                    "-d".to_owned(),
                    spec.x.to_string(),
                    spec.y.to_string(),
                    "-i".into(),
                    hold.to_string(),
                    "-u".into(),
                    spec.x.to_string(),
                    spec.y.to_string(),
                ]);
            }
            Gesture::Swipe => {
                let (Some(to_x), Some(to_y), Some(duration)) =
                    (spec.to_x, spec.to_y, spec.duration_ms)
                else {
                    return Err(
                        "unsupportedAction(\"a swipe needs an end point and duration\")".into(),
                    );
                };
                // The smooth-move time is a duration in milliseconds, so the
                // caller's real press-to-release time travels unchanged.
                arguments.extend([
                    "-m".to_owned(),
                    spec.x.to_string(),
                    spec.y.to_string(),
                    to_x.to_string(),
                    to_y.to_string(),
                    duration.to_string(),
                ]);
            }
        }
        Ok(FilePlan::Process(ProcessPlan {
            arguments,
            timeout: Duration::from_secs(30),
            capture_bytes: CAPTURE_BYTES,
        }))
    }

    /// Swift's verdict: `hdc shell` reports its own success, not the remote
    /// command's, so the exit status carries nothing. A parameter error
    /// fails; the gesture's own acknowledgement verifies (one shape per
    /// gesture, every line required); anything else — the standing hint
    /// about screen boundaries included — leaves the outcome unknown. What a
    /// verified outcome claims is that the injector accepted the gesture,
    /// never that anything on screen reacted.
    pub fn verify(&self, receipt: &Receipt) -> Outcome {
        let spec = &self.0;
        let Ok(text) = std::str::from_utf8(&receipt.stdout) else {
            return Outcome::Unknown(
                "uinput stdout is not UTF-8; the gesture outcome is unknown".into(),
            );
        };
        let lowered = text.to_lowercase();
        if lowered.contains("parameter error") {
            return Outcome::Failed {
                code: "pointerInputRejected",
                detail: text
                    .split('\n')
                    .find(|line| !line.is_empty())
                    .map(|line| line.trim_matches(horizontal_whitespace).to_owned())
                    .unwrap_or_else(|| "parameter error".to_owned()),
            };
        }
        if !spec
            .gesture
            .acknowledgement()
            .iter()
            .all(|line| lowered.contains(line))
        {
            return Outcome::Unknown(format!(
                "uinput did not acknowledge the {} it was given; the gesture may or may not \
                 have been injected",
                spec.gesture.raw()
            ));
        }
        let mut summary = BTreeMap::from([
            ("gesture".to_owned(), spec.gesture.raw().to_owned()),
            ("x".to_owned(), spec.x.to_string()),
            ("y".to_owned(), spec.y.to_string()),
            (
                "frame".to_owned(),
                format!("{}x{}", spec.display_width, spec.display_height),
            ),
        ]);
        if let Some(to_x) = spec.to_x {
            summary.insert("toX".into(), to_x.to_string());
        }
        if let Some(to_y) = spec.to_y {
            summary.insert("toY".into(), to_y.to_string());
        }
        if let Some(duration_ms) = spec.duration_ms {
            summary.insert("durationMs".into(), duration_ms.to_string());
        }
        if let Some(hold) = spec.lowered_hold_ms() {
            summary.insert("loweredHoldMs".into(), hold.to_string());
        }
        if let Some(display_id) = spec.display_id {
            summary.insert("displayId".into(), display_id.to_string());
        }
        Outcome::Verified(summary)
    }

    /// Swift's `reconciliationReadback`: an injected gesture has none.
    pub fn readback(&self) -> Option<Self> {
        None
    }

    /// Swift `reconcile` for `injectPointerInput`: the outcome stays
    /// unknown permanently and the intent is never replayed.
    pub fn reconcile(&self) -> Reconcile {
        Reconcile::StillUnknown("an injected pointer gesture has no observable readback".into())
    }

    pub fn persisted(&self) -> (&'static str, Map<String, Value>) {
        self.0.persisted()
    }
}

/// Swift's `CharacterSet.whitespaces`: spaces and tabs, never line breaks.
fn horizontal_whitespace(character: char) -> bool {
    character == '\t'
        || (character.is_whitespace()
            && !matches!(
                character,
                '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
            ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const KEY: &str = "150100424a544e4600";
    const NOW: &str = "2026-09-14T00:00:00Z";

    fn inputs(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap()
    }

    fn receipt(stdout: &str) -> Receipt {
        Receipt {
            exit_status: 0,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(272),
        }
    }

    fn tap() -> PointerInput {
        PointerInput::new(
            Gesture::Tap,
            640,
            1500,
            1280,
            2832,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap()
    }

    fn arguments(action: &PointerAction) -> Vec<String> {
        let FilePlan::Process(process) = action.lower("inject-pointer-input", Some(KEY)).unwrap()
        else {
            panic!("one process")
        };
        assert_eq!(process.timeout, Duration::from_secs(30));
        process.arguments
    }

    /// Swift `HDCPointerInputSpec.init`'s refusals, in its order.
    #[test]
    fn the_spec_holds_swift_s_closed_bounds() {
        let refused = |gesture, x, y, w, h, to_x, to_y, duration, display| {
            PointerInput::new(gesture, x, y, w, h, to_x, to_y, duration, display, None)
                .unwrap_err()
                .to_string()
        };
        assert_eq!(
            refused(Gesture::Tap, -1, 0, 1, 1, None, None, None, None),
            "outOfBounds(field: \"pointerX\", detail: \"0...32767\")"
        );
        assert_eq!(
            refused(Gesture::Tap, 0, 32768, 1, 1, None, None, None, None),
            "outOfBounds(field: \"pointerY\", detail: \"0...32767\")"
        );
        assert_eq!(
            refused(Gesture::Swipe, 0, 0, 1, 1, Some(0), None, Some(100), None),
            "outOfBounds(field: \"pointerToX/pointerToY/durationMs\", detail: \"required for a swipe\")"
        );
        assert_eq!(
            refused(
                Gesture::Swipe,
                0,
                0,
                1,
                1,
                Some(0),
                Some(40000),
                Some(100),
                None
            ),
            "outOfBounds(field: \"pointerToY\", detail: \"0...32767\")"
        );
        assert_eq!(
            refused(Gesture::Swipe, 0, 0, 1, 1, Some(0), Some(0), Some(79), None),
            "outOfBounds(field: \"durationMs\", detail: \"80...2000\")"
        );
        assert_eq!(
            refused(Gesture::LongPress, 0, 0, 1, 1, Some(0), None, None, None),
            "outOfBounds(field: \"pointerToX/pointerToY\", detail: \"only a swipe travels\")"
        );
        assert_eq!(
            refused(Gesture::LongPress, 0, 0, 1, 1, None, None, Some(2001), None),
            "outOfBounds(field: \"durationMs\", detail: \"80...2000\")"
        );
        assert_eq!(
            refused(Gesture::Tap, 0, 0, 1, 1, None, None, Some(100), None),
            "outOfBounds(field: \"pointerToX/pointerToY/durationMs\", detail: \"a tap carries none of these\")"
        );
        assert_eq!(
            refused(Gesture::Tap, 0, 0, 1, 1, None, None, None, Some(65)),
            "outOfBounds(field: \"displayId\", detail: \"0...64\")"
        );
        assert_eq!(
            refused(Gesture::Tap, 0, 0, 0, 1, None, None, None, None),
            "outOfBounds(field: \"displayWidth/displayHeight\", detail: \"positive device pixels\")"
        );
        assert_eq!(
            refused(Gesture::Tap, 1280, 0, 1280, 2832, None, None, None, None),
            "outOfBounds(field: \"pointer\", detail: \"inside the declared 1280x2832 frame\")"
        );
        assert_eq!(
            refused(
                Gesture::Swipe,
                0,
                0,
                1280,
                2832,
                Some(0),
                Some(2832),
                Some(500),
                None
            ),
            "outOfBounds(field: \"pointerTo\", detail: \"inside the declared 1280x2832 frame\")"
        );
        let long_press = PointerInput::new(
            Gesture::LongPress,
            12,
            700,
            1280,
            2832,
            None,
            None,
            None,
            Some(2),
            None,
        )
        .unwrap();
        assert_eq!(long_press.lowered_hold_ms(), Some(DEFAULT_LONG_PRESS_MS));
        assert_eq!(tap().lowered_hold_ms(), None);
    }

    /// Swift `pointerInputSpec`: the operation names the gesture, the
    /// inputs are read with Swift's refusals, the freshness gate is the
    /// provider's clock against the frame's capture time.
    #[test]
    fn the_inputs_are_read_as_swift_reads_them() {
        let frame = json!({"displayWidth": 1280, "displayHeight": 2832, "screenEpochUtc": "2026-09-14T00:00:00.000Z"});
        let mut swipe = inputs(frame.clone());
        swipe.extend(inputs(
            json!({"fromX": 100, "fromY": 2200, "toX": 100, "toY": 1200, "durationMs": 500}),
        ));
        let spec = PointerInput::from_inputs("input.swipe@1", &swipe).unwrap();
        assert_eq!(
            (
                spec.gesture,
                spec.x,
                spec.y,
                spec.to_x,
                spec.to_y,
                spec.duration_ms
            ),
            (Gesture::Swipe, 100, 2200, Some(100), Some(1200), Some(500))
        );
        assert_eq!(spec.frame_age_ms(NOW), Some(0));
        assert_eq!(spec.frame_age_ms("2026-09-14T00:00:01.000Z"), Some(1000));
        assert!(
            spec.refuse_if_stale("2026-09-14T00:00:01Z").is_ok(),
            "the bound is inclusive"
        );
        assert_eq!(
            spec.refuse_if_stale("2026-09-14T00:00:01.001Z")
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"inputExpired: the frame this gesture was mapped against is 1001 ms old, beyond the 1000 ms freshness bound; refresh the screen and send a new gesture\")"
        );
        assert_eq!(spec.frame_age_ms("not a stamp"), None);
        let mut tap = inputs(frame.clone());
        tap.extend(inputs(json!({"x": 640, "y": 1500})));
        assert_eq!(
            PointerInput::from_inputs("input.tap@1", &tap).unwrap(),
            PointerInput {
                screen_epoch_utc: Some("2026-09-14T00:00:00.000Z".into()),
                ..self::tests::tap()
            }
        );
        let mut stale = tap.clone();
        stale.insert("screenEpochUtc".into(), json!("2026-09-13T23:59:58Z"));
        let action = PointerAction::for_step("injectPointerInput", "input.tap@1", &stale, NOW);
        assert!(action.unwrap_err().to_string().starts_with("unsupportedAction(\"inputExpired: the frame this gesture was mapped against is 2000 ms old"));
        let mut unstamped = tap.clone();
        unstamped.remove("screenEpochUtc");
        assert!(
            PointerAction::for_step("injectPointerInput", "input.tap@1", &unstamped, NOW)
                .unwrap()
                .is_some(),
            "no epoch, no claim"
        );
        assert_eq!(
            PointerAction::for_step("probeDevice", "input.tap@1", &tap, NOW).unwrap(),
            None
        );
        assert_eq!(
            PointerInput::from_inputs("debug.hap@1", &tap)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"debug.hap@1 has no registered pointer gesture\")"
        );
        let mut missing = tap.clone();
        missing.remove("y");
        assert_eq!(
            PointerInput::from_inputs("input.tap@1", &missing)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"y is required for a pointer input\")"
        );
        let mut frameless = tap.clone();
        frameless.remove("displayHeight");
        assert_eq!(
            PointerInput::from_inputs("input.tap@1", &frameless)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"displayHeight is required for a pointer input\")"
        );
        let mut text = tap.clone();
        text.insert("displayId".into(), json!("2"));
        assert_eq!(
            PointerInput::from_inputs("input.tap@1", &text)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"displayId must be an integer\")"
        );
        let mut number = tap.clone();
        number.insert("screenEpochUtc".into(), json!(1));
        assert_eq!(
            PointerInput::from_inputs("input.tap@1", &number)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"screenEpochUtc must be a string\")"
        );
        let mut outside = tap;
        outside.insert("x".into(), json!(1280));
        assert_eq!(
            PointerInput::from_inputs("input.tap@1", &outside)
                .unwrap_err()
                .to_string(),
            "outOfBounds(field: \"pointer\", detail: \"inside the declared 1280x2832 frame\")"
        );
    }

    /// Swift `DeviceProviderContractTests`' argv: the display selector
    /// before the device option, the touch commands after it.
    #[test]
    fn the_lowering_is_swift_s_positional_uinput_argv() {
        assert_eq!(
            arguments(&PointerAction(tap())),
            ["-t", KEY, "shell", "uinput", "-T", "-c", "640", "1500"]
        );
        let long_press = PointerInput::new(
            Gesture::LongPress,
            12,
            0,
            1280,
            2832,
            None,
            None,
            None,
            Some(2),
            None,
        )
        .unwrap();
        assert_eq!(
            arguments(&PointerAction(long_press)),
            [
                "-t", KEY, "shell", "uinput", "-D", "2", "-T", "-d", "12", "0", "-i", "800", "-u",
                "12", "0"
            ]
        );
        let held = PointerInput::new(
            Gesture::LongPress,
            12,
            700,
            1280,
            2832,
            None,
            None,
            Some(1200),
            None,
            None,
        )
        .unwrap();
        assert_eq!(
            arguments(&PointerAction(held))[5..],
            ["-d", "12", "700", "-i", "1200", "-u", "12", "700"].map(str::to_owned)
        );
        let swipe = PointerInput::new(
            Gesture::Swipe,
            100,
            200,
            1280,
            2832,
            Some(100),
            Some(1200),
            Some(500),
            None,
            None,
        )
        .unwrap();
        assert_eq!(
            arguments(&PointerAction(swipe.clone())),
            [
                "-t", KEY, "shell", "uinput", "-T", "-m", "100", "200", "100", "1200", "500"
            ]
        );
        assert_eq!(
            PointerAction(swipe)
                .lower("inject-pointer-input", None)
                .unwrap_err(),
            "factsUnavailable(\"inject-pointer-input has no descriptor-bound target connect key\")"
        );
    }

    /// Swift's verdict from the injector's acknowledgement (verbatim device
    /// output, OpenHarmony-7.0.0.39, 2026-08-25), never from the exit status.
    #[test]
    fn the_verdict_comes_from_the_injector_s_acknowledgement() {
        let action = PointerAction(tap());
        let accepted = "   click coordinate: (640, 1500)\nclick interval time: 100ms\nIf the command does not work as expected, check whether the specified coordinates exceed the screen boundary\n";
        assert_eq!(
            action.verify(&receipt(accepted)),
            Outcome::Verified(BTreeMap::from([
                ("gesture".to_owned(), "tap".to_owned()),
                ("x".to_owned(), "640".to_owned()),
                ("y".to_owned(), "1500".to_owned()),
                ("frame".to_owned(), "1280x2832".to_owned()),
            ]))
        );
        assert_eq!(
            action.verify(&receipt("parameter error, unable to run\n")),
            Outcome::Failed {
                code: "pointerInputRejected",
                detail: "parameter error, unable to run".into()
            }
        );
        assert_eq!(
            action.verify(&receipt("\n  Parameter Error \t\n")),
            Outcome::Failed {
                code: "pointerInputRejected",
                detail: "Parameter Error".into()
            }
        );
        assert_eq!(
            action.verify(&receipt("")),
            Outcome::Unknown("uinput did not acknowledge the tap it was given; the gesture may or may not have been injected".into())
        );
        assert_eq!(
            action.verify(&receipt("startX:100, startY:200, endX:100, endY:1200\n")),
            Outcome::Unknown("uinput did not acknowledge the tap it was given; the gesture may or may not have been injected".into())
        );
        assert_eq!(
            action.verify(&Receipt {
                stdout: vec![0xff, 0xfe],
                ..receipt("")
            }),
            Outcome::Unknown("uinput stdout is not UTF-8; the gesture outcome is unknown".into())
        );
        let held = PointerAction(
            PointerInput::new(
                Gesture::LongPress,
                12,
                700,
                1280,
                2832,
                None,
                None,
                Some(1200),
                Some(2),
                None,
            )
            .unwrap(),
        );
        let Outcome::Verified(summary) =
            held.verify(&receipt("touch down 12 700\ntouch up 12 700\n"))
        else {
            panic!()
        };
        assert_eq!(summary["loweredHoldMs"], "1200");
        assert_eq!(summary["durationMs"], "1200");
        assert_eq!(summary["displayId"], "2");
        assert!(
            matches!(
                held.verify(&receipt("touch down 12 700\n")),
                Outcome::Unknown(_)
            ),
            "both lines are required"
        );
        let swipe = PointerAction(
            PointerInput::new(
                Gesture::Swipe,
                100,
                2200,
                1280,
                2832,
                Some(100),
                Some(1200),
                Some(500),
                None,
                None,
            )
            .unwrap(),
        );
        let Outcome::Verified(summary) =
            swipe.verify(&receipt("startX:100, startY:2200, endX:100, endY:1200\n"))
        else {
            panic!()
        };
        assert_eq!(
            (
                summary["toX"].as_str(),
                summary["toY"].as_str(),
                summary["durationMs"].as_str(),
                summary["loweredHoldMs"].as_str()
            ),
            ("100", "1200", "500", "500")
        );
        assert_eq!(action.readback(), None);
        assert_eq!(
            action.reconcile(),
            Reconcile::StillUnknown(
                "an injected pointer gesture has no observable readback".into()
            )
        );
        assert_eq!(action.effect(), "deviceMutation");
        assert_eq!(action.to_string(), "hdc.injectPointerInput(tap)");
    }

    /// Swift's durable intent and its decoder.
    #[test]
    fn the_persisted_form_round_trips() {
        let spec = PointerInput::new(
            Gesture::Swipe,
            100,
            2200,
            1280,
            2832,
            Some(100),
            Some(1200),
            Some(500),
            Some(0),
            Some("2026-09-14T00:00:00.000Z".into()),
        )
        .unwrap();
        let (kind, arguments) = PointerAction(spec.clone()).persisted();
        assert_eq!(kind, "hdc.injectPointerInput");
        assert_eq!(
            Value::Object(arguments.clone()),
            json!({"gesture": "swipe", "pointerX": 100, "pointerY": 2200, "pointerToX": 100, "pointerToY": 1200, "durationMs": 500, "displayId": 0, "displayWidth": 1280, "displayHeight": 2832, "screenEpochUtc": "2026-09-14T00:00:00.000Z"})
        );
        assert_eq!(PointerInput::from_persisted(&arguments).unwrap(), spec);
        let (_, arguments) = tap().persisted();
        assert_eq!(arguments.len(), 5, "nothing optional is written for a tap");
        assert_eq!(PointerInput::from_persisted(&arguments).unwrap(), tap());
        let mut unknown = arguments.clone();
        unknown.insert("gesture".into(), json!("pinch"));
        assert_eq!(
            PointerInput::from_persisted(&unknown)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"persisted pointer gesture is invalid\")"
        );
        let mut outside = arguments;
        outside.insert("pointerX".into(), json!(1280));
        assert!(
            PointerInput::from_persisted(&outside).is_err(),
            "the bounds are checked again"
        );
    }

    /// The stamp parser behind the freshness gate.
    #[test]
    fn utc_stamps_parse_as_swift_parses_them() {
        assert_eq!(utc_nanoseconds("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            utc_nanoseconds("2026-09-14T00:00:00Z"),
            Some(1_789_344_000 * 1_000_000_000)
        );
        assert_eq!(
            utc_nanoseconds("2026-09-14T00:00:00.5Z"),
            Some(1_789_344_000 * 1_000_000_000 + 500_000_000)
        );
        assert_eq!(
            utc_nanoseconds("2026-09-14T00:00:00.123456Z"),
            Some(1_789_344_000 * 1_000_000_000 + 123_456_000)
        );
        assert_eq!(
            utc_nanoseconds("2000-02-29T12:30:45Z"),
            Some(951_827_445 * 1_000_000_000)
        );
        for bad in [
            "2026-09-14T00:00:00",
            "2026-09-14 00:00:00Z",
            "2026-13-14T00:00:00Z",
            "2026-09-14T00:00:00.Z",
            "2026-09-14T00:00:00.1234567890Z",
            "",
        ] {
            assert_eq!(utc_nanoseconds(bad), None, "{bad}");
        }
    }
}
