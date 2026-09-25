//! `arkdeck ui-dump inspect|hit-test`: Swift `RuntimeCLI.emitUIDumpDerivation`
//! over the shared offline parser (`UIDumpOfflineInspector`,
//! `ViewerCaptureParser`, `ViewerHitTesting`, `ViewerScreenshotMapping`) and
//! its machine projection (`CLIOfflineDerivation`).
//!
//! Both read the three Artifacts one UI dump capture published — its
//! screenshot, its component tree and, optionally, its raw dump — whole and
//! bound to their immutable metadata, and derive locally: nothing reaches a
//! device and nothing is written. Every answer says it is `offlineDerived`
//! and names the parser, the capture's observation window and each source's
//! digest, so it is never taken for a reading of the current screen.
use crate::CliError;
use serde_json::{Map, Number, Value, json};
use std::collections::{BTreeMap, BTreeSet};

const PARSER: &str = "arkdeck.viewer.ui-dump-parser";
const PARSER_VERSION: &str = "1.0.0";
const MAXIMUM_CAPTURE_BYTES: u64 = 64 * 1024 * 1024;
const INVENTORY_MAXIMUM: usize = 64_000;
/// Swift `ArtifactReadProjection.maximumBytes`.
const READ_MAXIMUM_BYTES: u64 = 4_194_304;
const SCREENSHOT: (&str, &str) = ("screenshot.png", "image/png");
const TREE: (&str, &str) = ("ui-tree.json", "application/json");
const RAW_DUMP: (&str, &str) = ("ui-dump.json", "application/json");

/// The options the leaf cannot run without. The registry pass judges them
/// too, and its refusal is the one reported for an argv this refuses.
pub(crate) fn configure(
    command: &str,
    fields: &Map<String, Value>,
    help: bool,
) -> Result<(), CliError> {
    let required: &[&str] = match command {
        _ if help => return Ok(()),
        "ui-dump.inspect" => &["jobId"],
        "ui-dump.hit-test" => &["jobId", "x", "y"],
        _ => return Ok(()),
    };
    if required.iter().any(|key| !fields.contains_key(*key)) {
        return Err(fail(
            "invalidOption",
            format!(
                "{} requires its --job, --x and --y options",
                command.replace('.', " ")
            ),
        ));
    }
    Ok(())
}

/// One request to the Runtime, as the leaf's session sends it.
pub type Request<'a> = dyn FnMut(&str, Map<String, Value>) -> Result<Value, CliError> + 'a;

fn fail(code: &'static str, message: impl Into<String>) -> CliError {
    CliError::new(code, message)
}

/// `session.fail(_, _, details: ["jobId": …])`.
fn fail_naming(code: &'static str, message: impl Into<String>, job: &str) -> CliError {
    let mut error = CliError::new(code, message);
    error.details = Map::from_iter([("jobId".to_owned(), json!(job))]);
    error
}

/// Swift `UIDumpOfflineSource`.
#[derive(Clone, Debug)]
struct Source {
    id: String,
    name: String,
    media_type: String,
    sha256: String,
    byte_count: u64,
}

impl Source {
    fn value(&self) -> Value {
        json!({"artifactId": self.id, "name": self.name, "mediaType": self.media_type,
            "sha256": self.sha256, "byteCount": self.byte_count})
    }
}

/// Swift `readWholeArtifact`: every range of one Artifact, each bound to the
/// metadata the inventory named. UI dump products are sensitive by contract;
/// choosing this leaf is the opt-in to read this exact capture.
fn read_whole(owner: &Value, source: &Source, request: &mut Request) -> Result<Vec<u8>, CliError> {
    let mut bytes = Vec::new();
    let mut offset = 0_u64;
    loop {
        let value = request(
            "artifact.read",
            Map::from_iter([
                ("owner".to_owned(), owner.clone()),
                ("artifactId".to_owned(), json!(source.id)),
                ("offset".to_owned(), json!(offset)),
                ("maxBytes".to_owned(), json!(READ_MAXIMUM_BYTES)),
                ("allowSensitive".to_owned(), json!(true)),
            ]),
        )?;
        let page = crate::diagnostics_resources::artifact_range(&value)?;
        if page.id != source.id
            || page.digest != source.sha256
            || page.total != source.byte_count
            || page.offset != offset
        {
            return Err(fail(
                "recordUnreadable",
                format!(
                    "artifact {} returned a range for different immutable metadata",
                    source.id
                ),
            ));
        }
        bytes.extend_from_slice(&page.bytes);
        if page.next == page.total {
            break;
        }
        if page.next <= offset {
            return Err(fail(
                "recordUnreadable",
                format!(
                    "artifact {} stopped advancing at {offset} without reporting eof",
                    source.id
                ),
            ));
        }
        offset = page.next;
    }
    if bytes.len() as u64 != source.byte_count {
        return Err(fail(
            "artifactIntegrityFailed",
            format!(
                "artifact {} read {} bytes; the index says {}",
                source.id,
                bytes.len(),
                source.byte_count
            ),
        ));
    }
    Ok(bytes)
}

/// The Job's Artifact inventory, every page of one snapshot.
fn inventory(owner: &Value, job: &str, request: &mut Request) -> Result<Vec<Value>, CliError> {
    let mut entries = Vec::new();
    let mut cursor: Option<String> = None;
    let mut revision: Option<String> = None;
    let mut seen = BTreeSet::new();
    loop {
        let mut params = Map::from_iter([
            ("owner".to_owned(), owner.clone()),
            ("pageSize".to_owned(), json!(1000)),
        ]);
        if let Some(cursor) = &cursor {
            params.insert("cursor".into(), json!(cursor));
        }
        let page = request("artifact.list", params)?;
        crate::validate_artifact_page(&page, owner, 1000)?;
        let (Some(rows), Some(snapshot), Some(more)) = (
            page["items"].as_array(),
            page["snapshotRevision"].as_str(),
            page["hasMore"].as_bool(),
        ) else {
            return Err(fail(
                "recordUnreadable",
                format!("job {job} returned no readable Artifact page"),
            ));
        };
        if revision.as_deref().is_some_and(|before| before != snapshot) {
            return Err(fail(
                "factsDrifted",
                format!("job {job} Artifact snapshot changed while paging"),
            ));
        }
        revision = Some(snapshot.to_owned());
        entries.extend(rows.iter().cloned());
        if entries.len() > INVENTORY_MAXIMUM {
            return Err(fail(
                "recordUnreadable",
                format!("job {job} Artifact inventory exceeds its read bound"),
            ));
        }
        if !more {
            return Ok(entries);
        }
        match page["nextCursor"].as_str() {
            Some(next) if seen.insert(next.to_owned()) => cursor = Some(next.to_owned()),
            _ => {
                return Err(fail(
                    "recordUnreadable",
                    format!("job {job} Artifact pagination stopped advancing"),
                ));
            }
        }
    }
}

/// Swift's `entry(named:mediaType:)`: the one published, sensitive Artifact
/// of that name and media type, or none of that name.
fn entry<'a>(
    entries: &'a [Value],
    (name, media_type): (&str, &str),
    job: &str,
) -> Result<Option<&'a Value>, CliError> {
    let matches: Vec<&Value> = entries.iter().filter(|row| row["name"] == name).collect();
    if matches.len() > 1 {
        return Err(fail(
            "recordUnreadable",
            format!("job {job} published duplicate `{name}` Artifacts"),
        ));
    }
    let Some(row) = matches.first() else {
        return Ok(None);
    };
    if row["status"] != "published"
        || row["mediaType"] != media_type
        || row["privacy"] != "sensitive"
    {
        return Err(fail(
            "recordUnreadable",
            format!("job {job} published `{name}` with invalid status, media type, or privacy"),
        ));
    }
    Ok(Some(row))
}

/// Swift's `source(_:)` and `UIDumpOfflineSource.init`.
fn source(row: &Value, job: &str) -> Result<Source, CliError> {
    let (Some(id), Some(name), Some(media_type), Some(sha256), Some(byte_count)) = (
        row["artifactId"].as_str(),
        row["name"].as_str(),
        row["mediaType"].as_str(),
        row["artifactDigest"].as_str(),
        row["byteCount"]
            .as_u64()
            .filter(|count| i64::try_from(*count).is_ok()),
    ) else {
        return Err(fail(
            "recordUnreadable",
            format!("job {job} published an artifact this build cannot read"),
        ));
    };
    let valid = !id.is_empty()
        && id.len() <= 512
        && !id.chars().any(char::is_control)
        && !name.is_empty()
        && name.len() <= 256
        && !media_type.is_empty()
        && media_type.len() <= 256
        && sha256.len() == 64
        && sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
    if !valid {
        return Err(fail(
            "recordUnreadable",
            format!("job {job} published invalid metadata for `{name}`"),
        ));
    }
    Ok(Source {
        id: id.into(),
        name: name.into(),
        media_type: media_type.into(),
        sha256: sha256.into(),
        byte_count,
    })
}

/// Why the capture did not parse, spelled as Swift's `\(error)` spells the
/// failure (`ViewerCaptureFailure`, `UIDumpOfflineInspectorError`).
#[derive(Debug)]
enum Unparsed {
    UnreadableTree,
    InvalidTree,
    InvalidPng,
    InvalidSource(&'static str),
}

impl Unparsed {
    fn described(&self) -> String {
        match self {
            Self::UnreadableTree => "unreadableTree".into(),
            Self::InvalidTree => "invalidTree".into(),
            Self::InvalidPng => "invalidPNG".into(),
            Self::InvalidSource(name) => format!("invalidSource(\"{name}\")"),
        }
    }
}

/// Swift `ViewerBounds`.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Bounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl Bounds {
    fn new(x: f64, y: f64, width: f64, height: f64) -> Option<Self> {
        (x.is_finite()
            && y.is_finite()
            && width.is_finite()
            && height.is_finite()
            && width >= 0.0
            && height >= 0.0)
            .then_some(Self {
                x,
                y,
                width,
                height,
            })
    }

    fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && y >= self.y && x <= self.x + self.width && y <= self.y + self.height
    }

    fn intersection(&self, other: &Bounds) -> Option<Bounds> {
        let left = self.x.max(other.x);
        let top = self.y.max(other.y);
        let right = (self.x + self.width).min(other.x + other.width);
        let bottom = (self.y + self.height).min(other.y + other.height);
        if right > left && bottom > top {
            Bounds::new(left, top, right - left, bottom - top)
        } else {
            None
        }
    }

    fn value(&self) -> Value {
        json!({"x": float(self.x), "y": float(self.y), "width": float(self.width),
            "height": float(self.height)})
    }
}

/// A Swift `JSONValue.number`: a binary64, whatever its value.
fn float(value: f64) -> Value {
    Number::from_f64(value).map_or(Value::Null, Value::Number)
}

/// Swift `ViewerNode`, as `CLIOfflineDerivation.encode(node:)` publishes it.
#[derive(Clone, Debug)]
struct Node {
    identity: String,
    device_id: Option<String>,
    parent: Option<String>,
    children: Vec<String>,
    kind: String,
    text: Option<String>,
    inspector_id: Option<String>,
    bounds: Option<Bounds>,
    visible: bool,
    enabled: Option<bool>,
    clickable: Option<bool>,
    focusable: Option<bool>,
    focused: Option<bool>,
    clips_children: bool,
    hit_test_behavior: Option<String>,
    z_index: Option<f64>,
    depth: usize,
}

impl Node {
    fn value(&self) -> Value {
        json!({"identity": self.identity, "deviceId": self.device_id,
            "parentIdentity": self.parent, "children": self.children, "type": self.kind,
            "text": self.text, "inspectorId": self.inspector_id,
            "bounds": self.bounds.map_or(Value::Null, |bounds| bounds.value()),
            "visible": self.visible, "enabled": self.enabled, "clickable": self.clickable,
            "focusable": self.focusable, "focused": self.focused,
            "clipsChildren": self.clips_children, "hitTestBehavior": self.hit_test_behavior,
            "zIndex": self.z_index.map_or(Value::Null, float), "depth": self.depth})
    }

    /// Swift `acceptsPointerHit`: `None` and `Transparent` pass a click
    /// through.
    fn accepts_pointer_hit(&self) -> bool {
        self.hit_test_behavior.as_ref().is_none_or(|behavior| {
            !matches!(
                behavior.to_lowercase().as_str(),
                "none" | "transparent" | "hittestmode.none" | "hittestmode.transparent"
            )
        })
    }
}

/// Swift `ViewerCapture`, what this leaf reads of it.
struct Capture {
    width: i64,
    height: i64,
    roots: Vec<String>,
    nodes: Vec<Node>,
    index: BTreeMap<String, usize>,
    verified: bool,
}

impl Capture {
    fn node(&self, identity: &str) -> Option<&Node> {
        self.index.get(identity).map(|at| &self.nodes[*at])
    }

    fn value(&self) -> Value {
        json!({"screenshot": {"width": self.width, "height": self.height},
            "coordinatesAreVerified": self.verified, "roots": self.roots,
            "nodeCount": self.nodes.len(),
            "nodes": self.nodes.iter().map(Node::value).collect::<Vec<_>>()})
    }

    /// Swift `ancestors(of:)`: root first.
    fn ancestors(&self, identity: &str) -> Vec<String> {
        let mut result = Vec::new();
        let mut visited = BTreeSet::new();
        let mut cursor = self.node(identity).and_then(|node| node.parent.clone());
        while let Some(value) = cursor {
            if !visited.insert(value.clone()) {
                break;
            }
            let Some(node) = self.node(&value) else { break };
            cursor = node.parent.clone();
            result.push(value);
        }
        result.reverse();
        result
    }

    /// Swift `subtreeNodes(rootIdentity:)`.
    fn subtree(&self, root: Option<&str>) -> Vec<&Node> {
        let Some(root) = root.filter(|root| !root.is_empty()) else {
            return self.nodes.iter().collect();
        };
        if self.node(root).is_none() {
            return Vec::new();
        }
        let mut included = BTreeSet::new();
        let mut pending = vec![root.to_owned()];
        while let Some(identity) = pending.pop() {
            if !included.insert(identity.clone()) {
                break;
            }
            if let Some(node) = self.node(&identity) {
                pending.extend(node.children.iter().cloned());
            }
        }
        self.nodes
            .iter()
            .filter(|node| included.contains(&node.identity))
            .collect()
    }

    /// Swift `ViewerScreenshotMapping.visibleBounds(_:screenshotWidth:screenshotHeight:)`.
    fn on_screen(&self, bounds: Option<Bounds>) -> Option<Bounds> {
        if self.width <= 0 || self.height <= 0 {
            return None;
        }
        let viewport = Bounds::new(0.0, 0.0, self.width as f64, self.height as f64)?;
        bounds?.intersection(&viewport)
    }

    /// Swift `ViewerScreenshotMapping.visibleBounds(of:in:)`: the node's
    /// pixels left visible by every clipping ancestor.
    fn visible_bounds(&self, node: &Node) -> Option<Bounds> {
        if !self.verified {
            return None;
        }
        let mut visible = self.on_screen(node.bounds)?;
        let mut visited = BTreeSet::new();
        let mut cursor = node.parent.clone();
        while let Some(identity) = cursor {
            if !visited.insert(identity.clone()) {
                break;
            }
            let Some(ancestor) = self.node(&identity) else {
                break;
            };
            if ancestor.clips_children {
                visible = visible.intersection(&self.on_screen(ancestor.bounds)?)?;
            }
            cursor = ancestor.parent.clone();
        }
        Some(visible)
    }

    /// Swift `ViewerHitTesting.node(in:rootIdentity:x:y:)`: the frontmost
    /// painted branch's deepest node under the point.
    fn hit(&self, root: Option<&str>, x: f64, y: f64) -> Option<&Node> {
        if !self.verified {
            return None;
        }
        let candidates = self.subtree(root);
        let mut order = BTreeMap::new();
        for (offset, candidate) in candidates.iter().enumerate() {
            order.entry(candidate.identity.clone()).or_insert(offset);
        }
        // `Sequence.max(by:)`: a later element replaces the best only when
        // the best is painted behind it.
        let mut best: Option<&Node> = None;
        for node in candidates.into_iter().filter(|node| {
            node.visible
                && node.accepts_pointer_hit()
                && self
                    .visible_bounds(node)
                    .is_some_and(|bounds| bounds.contains(x, y))
        }) {
            best = match best {
                Some(current) if !self.painted_behind(current, node, &order) => Some(current),
                _ => Some(node),
            };
        }
        best
    }

    /// Swift `isPaintedBehind`.
    fn painted_behind(&self, left: &Node, right: &Node, order: &BTreeMap<String, usize>) -> bool {
        let stable = |identity: &str| order.get(identity).copied().unwrap_or(0);
        let mut left_path = self.ancestors(&left.identity);
        left_path.push(left.identity.clone());
        let mut right_path = self.ancestors(&right.identity);
        right_path.push(right.identity.clone());
        let shared = left_path.len().min(right_path.len());
        let mut divergence = 0;
        while divergence < shared && left_path[divergence] == right_path[divergence] {
            divergence += 1;
        }
        if divergence < shared
            && let (Some(left_branch), Some(right_branch)) = (
                self.node(&left_path[divergence]),
                self.node(&right_path[divergence]),
            )
        {
            let z = |value: Option<f64>| value.filter(|value| value.is_finite()).unwrap_or(0.0);
            let (left_z, right_z) = (z(left_branch.z_index), z(right_branch.z_index));
            if left_z != right_z {
                return left_z < right_z;
            }
            if divergence > 0
                && let Some(parent) = self.node(&left_path[divergence - 1])
                && let Some(left_index) = parent
                    .children
                    .iter()
                    .position(|child| *child == left_branch.identity)
                && let Some(right_index) = parent
                    .children
                    .iter()
                    .position(|child| *child == right_branch.identity)
                && left_index != right_index
            {
                return left_index < right_index;
            }
            return stable(&left_branch.identity) < stable(&right_branch.identity);
        }
        if left_path.len() != right_path.len() {
            return left_path.len() < right_path.len();
        }
        stable(&left.identity) < stable(&right.identity)
    }
}

/// NSNumber's `stringValue` of a JSON number or boolean.
fn number_text(value: &Value) -> Option<String> {
    match value {
        Value::Bool(flag) => Some(if *flag { "1" } else { "0" }.into()),
        Value::Number(number) if number.is_f64() => {
            arkdeck_contract::foundation_json::float_text(number).ok()
        }
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

/// Swift's `string(_:)`: a non-empty string, or a number's text.
fn text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        other => number_text(other),
    }
}

/// Swift's `bool(_:)`: a boolean (a number bridges when it is exactly 0 or
/// 1), or the strings `true` and `false`.
fn flag(value: Option<&Value>) -> Option<bool> {
    match value? {
        Value::Bool(flag) => Some(*flag),
        Value::Number(number) => match number.as_f64() {
            Some(1.0) => Some(true),
            Some(0.0) => Some(false),
            _ => None,
        },
        Value::String(text) if text == "true" => Some(true),
        Value::String(text) if text == "false" => Some(false),
        _ => None,
    }
}

/// Swift `Double(_: String)`: a decimal or exponent spelling, with an
/// optional sign; `inf` and `nan` parse but are not finite.
fn swift_double(text: &str) -> Option<f64> {
    let body = text.strip_prefix(['+', '-']).unwrap_or(text);
    let decimal = !body.is_empty()
        && body
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'.' | b'e' | b'E' | b'+' | b'-'));
    if !decimal {
        return None;
    }
    text.parse::<f64>().ok()
}

/// Swift's `number(_:)`: a finite number, from a number, a boolean or a
/// numeric string.
fn number(value: Option<&Value>) -> Option<f64> {
    let parsed = match value? {
        Value::Bool(flag) => Some(if *flag { 1.0 } else { 0.0 }),
        Value::Number(number) => number.as_f64(),
        Value::String(text) => swift_double(text),
        _ => None,
    }?;
    parsed.is_finite().then_some(parsed)
}

/// The numbers `[-+]?(?:\d+(?:\.\d*)?|\.\d+)` finds in `text`, each parsed
/// as Swift parses it; a run that does not parse is skipped.
fn numbers_in(text: &str) -> Vec<f64> {
    let characters: Vec<char> = text.chars().collect();
    let digit = |at: usize| characters.get(at).is_some_and(|c| c.is_numeric());
    let mut values = Vec::new();
    let mut at = 0;
    while at < characters.len() {
        let start = at;
        let mut cursor = at;
        if matches!(characters[cursor], '+' | '-') {
            cursor += 1;
        }
        let begins_number =
            digit(cursor) || (characters.get(cursor) == Some(&'.') && digit(cursor + 1));
        if !begins_number {
            at += 1;
            continue;
        }
        if digit(cursor) {
            while digit(cursor) {
                cursor += 1;
            }
            if characters.get(cursor) == Some(&'.') {
                cursor += 1;
                while digit(cursor) {
                    cursor += 1;
                }
            }
        } else {
            cursor += 1;
            while digit(cursor) {
                cursor += 1;
            }
        }
        let token: String = characters[start..cursor].iter().collect();
        if let Some(value) = swift_double(&token) {
            values.push(value);
        }
        at = cursor;
    }
    values
}

/// Swift's `bounds(_:)`: an object of `x`/`left`, `y`/`top` and a size or a
/// far corner, four numbers, or a string holding the two corners.
fn bounds(value: Option<&Value>) -> Option<Bounds> {
    match value? {
        Value::Object(object) => {
            let x = number(object.get("x").or_else(|| object.get("left")));
            let y = number(object.get("y").or_else(|| object.get("top")));
            if let (Some(x), Some(y)) = (x, y) {
                if let (Some(width), Some(height)) =
                    (number(object.get("width")), number(object.get("height")))
                {
                    return Bounds::new(x, y, width, height);
                }
                if let (Some(right), Some(bottom)) =
                    (number(object.get("right")), number(object.get("bottom")))
                {
                    return Bounds::new(x, y, right - x, bottom - y);
                }
            }
            None
        }
        Value::Array(values) if values.len() == 4 => {
            let values: Vec<f64> = values
                .iter()
                .filter_map(|value| number(Some(value)))
                .collect();
            (values.len() == 4).then(|| Bounds::new(values[0], values[1], values[2], values[3]))?
        }
        Value::String(text) => {
            let values = numbers_in(text);
            (values.len() == 4).then(|| {
                Bounds::new(
                    values[0],
                    values[1],
                    values[2] - values[0],
                    values[3] - values[1],
                )
            })?
        }
        _ => None,
    }
}

/// An array whose every element is an object: Swift's `as? [[String: Any]]`.
fn objects(value: Option<&Value>) -> Option<Vec<&Map<String, Value>>> {
    value?.as_array()?.iter().map(Value::as_object).collect()
}

/// Swift's `attributes` of a component: its `attributes` object, or itself.
fn attributes(object: &Map<String, Value>) -> &Map<String, Value> {
    object
        .get("attributes")
        .and_then(Value::as_object)
        .unwrap_or(object)
}

/// Swift `componentRoots(of:)`: past the document envelope, which names no
/// component, to the real roots; and the envelope's bounds, the coordinate
/// space's proof.
fn component_roots(document: &Map<String, Value>) -> (Vec<&Map<String, Value>>, Option<Bounds>) {
    let mut current = document;
    let mut document_bounds = None;
    for _ in 0..8 {
        let fields = attributes(current);
        let names_itself = ["type", "accessibilityId", "id", "nodeId", "componentId"]
            .iter()
            .any(|key| text(fields.get(*key)).is_some());
        let Some(children) = objects(current.get("children")).filter(|c| !c.is_empty()) else {
            return (vec![current], document_bounds);
        };
        if names_itself {
            return (vec![current], document_bounds);
        }
        document_bounds = document_bounds
            .or_else(|| bounds(fields.get("bounds").or_else(|| current.get("bounds"))));
        if children.len() > 1 {
            return (children, document_bounds);
        }
        current = children[0];
    }
    (vec![current], document_bounds)
}

/// Swift's `ProvisionalNode`, before identities are settled.
struct Provisional {
    path: Vec<usize>,
    parent_path: Option<Vec<usize>>,
    child_paths: Vec<Vec<usize>>,
    source_id: Option<String>,
    node: Node,
}

/// Swift `appendNode`: this component, then each child, depth first.
fn append(
    object: &Map<String, Value>,
    path: Vec<usize>,
    parent_path: Option<Vec<usize>>,
    items: &mut Vec<Provisional>,
) -> Result<(), Unparsed> {
    let fields = attributes(object);
    let children = match object.get("children") {
        None => Vec::new(),
        Some(value) => objects(Some(value)).ok_or(Unparsed::InvalidTree)?,
    };
    let child_paths = (0..children.len())
        .map(|index| [path.as_slice(), &[index]].concat())
        .collect();
    let source_id = text(fields.get("accessibilityId"))
        .or_else(|| text(fields.get("id")))
        .or_else(|| text(fields.get("nodeId")))
        .or_else(|| text(fields.get("componentId")));
    let kind = text(fields.get("type"))
        .or_else(|| text(fields.get("componentType")))
        .or_else(|| text(fields.get("class")))
        .unwrap_or_else(|| "Unknown".into());
    let depth = path.len().saturating_sub(1);
    items.push(Provisional {
        path: path.clone(),
        parent_path,
        child_paths,
        source_id: source_id.clone(),
        node: Node {
            identity: String::new(),
            device_id: source_id,
            parent: None,
            children: Vec::new(),
            kind,
            text: text(fields.get("text")),
            inspector_id: text(fields.get("inspectorId")),
            bounds: bounds(fields.get("bounds").or_else(|| object.get("bounds"))),
            visible: flag(fields.get("visible")).unwrap_or(true),
            enabled: flag(fields.get("enabled")),
            clickable: flag(fields.get("clickable")),
            focusable: flag(fields.get("focusable")),
            focused: flag(fields.get("focused")),
            clips_children: flag(fields.get("clip")).unwrap_or(false),
            hit_test_behavior: text(fields.get("hitTestBehavior")),
            z_index: number(fields.get("zIndex").or_else(|| fields.get("zOrder"))),
            depth,
        },
    });
    for (index, child) in children.into_iter().enumerate() {
        append(
            child,
            [path.as_slice(), &[index]].concat(),
            Some(path.clone()),
            items,
        )?;
    }
    Ok(())
}

/// Swift `pngDimensions`: the IHDR width and height of a PNG.
fn png_dimensions(bytes: &[u8]) -> Result<(i64, i64), Unparsed> {
    if bytes.len() < 24
        || bytes[..8] != [137, 80, 78, 71, 13, 10, 26, 10]
        || bytes[12..16] != *b"IHDR"
    {
        return Err(Unparsed::InvalidPng);
    }
    let read = |range: std::ops::Range<usize>| {
        bytes[range]
            .iter()
            .fold(0_i64, |value, byte| (value << 8) | i64::from(*byte))
    };
    let (width, height) = (read(16..20), read(20..24));
    if width <= 0 || height <= 0 {
        return Err(Unparsed::InvalidPng);
    }
    Ok((width, height))
}

/// Swift `ViewerCaptureParser.parse`: the tree's components, their settled
/// identities, and whether the tree's coordinates are the screenshot's.
fn parse(screenshot: &[u8], tree: &[u8]) -> Result<Capture, Unparsed> {
    let (width, height) = png_dimensions(screenshot)?;
    let document: Value = serde_json::from_slice(tree).map_err(|_| Unparsed::UnreadableTree)?;
    let document = document.as_object().ok_or(Unparsed::UnreadableTree)?;
    let (roots, document_bounds) = component_roots(document);
    let mut provisional = Vec::new();
    for (index, component) in roots.into_iter().enumerate() {
        append(component, vec![index], None, &mut provisional)?;
    }
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for item in &provisional {
        if let Some(id) = &item.source_id {
            *counts.entry(id).or_default() += 1;
        }
    }
    let identities: BTreeMap<Vec<usize>, String> = provisional
        .iter()
        .map(|item| {
            let identity = match &item.source_id {
                Some(id) if counts[id.as_str()] == 1 => format!("device:{id}"),
                _ => format!(
                    "path:{}",
                    item.path
                        .iter()
                        .map(usize::to_string)
                        .collect::<Vec<_>>()
                        .join(".")
                ),
            };
            (item.path.clone(), identity)
        })
        .collect();
    let nodes: Vec<Node> = provisional
        .iter()
        .map(|item| Node {
            identity: identities[&item.path].clone(),
            parent: item
                .parent_path
                .as_ref()
                .and_then(|path| identities.get(path).cloned()),
            children: item
                .child_paths
                .iter()
                .filter_map(|path| identities.get(path).cloned())
                .collect(),
            ..item.node.clone()
        })
        .collect();
    let roots: Vec<String> = nodes
        .iter()
        .filter(|node| node.parent.is_none())
        .map(|node| node.identity.clone())
        .collect();
    if nodes.is_empty() || roots.is_empty() {
        return Err(Unparsed::InvalidTree);
    }
    // Swift's `Int(_: Double)` truncates toward zero.
    let covers = |bounds: &Bounds| {
        bounds.x == 0.0
            && bounds.y == 0.0
            && bounds.width as i64 == width
            && bounds.height as i64 == height
    };
    let verified = match document_bounds {
        Some(bounds) => covers(&bounds),
        None => nodes
            .iter()
            .any(|node| node.parent.is_none() && node.bounds.as_ref().is_some_and(covers)),
    };
    let mut index = BTreeMap::new();
    for (at, node) in nodes.iter().enumerate() {
        index.entry(node.identity.clone()).or_insert(at);
    }
    Ok(Capture {
        width,
        height,
        roots,
        nodes,
        index,
        verified,
    })
}

/// `ui-dump inspect|hit-test`, given the leaf's options (`jobId`, and for a
/// hit test `x`, `y` and optionally `root`) and its session.
pub fn run(
    verb: &str,
    options: &Map<String, Value>,
    request: &mut Request,
) -> Result<Value, CliError> {
    let job = options
        .get("jobId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            fail(
                "invalidOption",
                format!("ui-dump {verb} requires --job <id>"),
            )
        })?;
    let owner = json!({"kind": "job", "id": job});
    if !crate::artifact_resources::owner(&owner) {
        return Err(fail("invalidInput", "Artifact owner identity is malformed"));
    }
    let entries = inventory(&owner, job, request)?;
    if entries.is_empty() {
        return Err(fail_naming(
            "resourceNotFound",
            format!(
                "job {job} has published no artifacts; check the job identity and that it \
                 reached a terminal state"
            ),
            job,
        ));
    }
    let Some(tree_row) = entry(&entries, TREE, job)? else {
        return Err(fail_naming(
            "resourceNotFound",
            format!("job {job} published no `ui-tree.json`, so it is not a UI dump capture"),
            job,
        ));
    };
    let Some(screenshot_row) = entry(&entries, SCREENSHOT, job)? else {
        return Err(fail_naming(
            "resourceNotFound",
            format!("job {job} published no screenshot to derive against"),
            job,
        ));
    };
    let raw_row = entry(&entries, RAW_DUMP, job)?;
    let tree = source(tree_row, job)?;
    let screenshot = source(screenshot_row, job)?;
    let raw = raw_row.map(|row| source(row, job)).transpose()?;
    let mut total = 0_u64;
    for item in [Some(&tree), Some(&screenshot), raw.as_ref()]
        .into_iter()
        .flatten()
    {
        total = total
            .checked_add(item.byte_count)
            .filter(|total| *total <= MAXIMUM_CAPTURE_BYTES)
            .ok_or_else(|| {
                fail(
                    "recordUnreadable",
                    format!("job {job} UI dump exceeds the bounded offline inspection size"),
                )
            })?;
    }
    let tree_bytes = read_whole(&owner, &tree, request)?;
    let screenshot_bytes = read_whole(&owner, &screenshot, request)?;
    let raw_bytes = raw
        .as_ref()
        .map(|raw| read_whole(&owner, raw, request))
        .transpose()?;

    let window = &screenshot_row["observationWindow"];
    let observed_from = window["startUtc"].as_str();
    let observed_to = window["endUtc"].as_str();
    // Swift `UIDumpOfflineArtifact.init`, screenshot, tree, then raw dump.
    for (item, bytes) in [
        (Some(&screenshot), Some(&screenshot_bytes)),
        (Some(&tree), Some(&tree_bytes)),
        (raw.as_ref(), raw_bytes.as_ref()),
    ] {
        let Some(item) = item else { continue };
        let bytes = bytes.map_or(&[][..], Vec::as_slice);
        if item.byte_count != bytes.len() as u64 {
            return Err(fail_naming(
                "artifactIntegrityFailed",
                format!(
                    "artifact `{}` byte count does not match its Runtime metadata",
                    item.name
                ),
                job,
            ));
        }
        if arkdeck_contract::sha256_hex(bytes) != item.sha256 {
            return Err(fail_naming(
                "artifactIntegrityFailed",
                format!(
                    "artifact `{}` SHA-256 does not match its Runtime metadata",
                    item.name
                ),
                job,
            ));
        }
    }
    let unparsed = |failure: Unparsed| {
        fail_naming(
            "recordUnreadable",
            format!(
                "the capture artifacts did not parse: {}",
                failure.described()
            ),
            job,
        )
    };
    let mut sources = vec![screenshot.clone(), tree.clone()];
    sources.extend(raw.clone());
    let ids: BTreeSet<&str> = sources.iter().map(|item| item.id.as_str()).collect();
    if ids.len() != sources.len() {
        return Err(unparsed(Unparsed::InvalidSource("duplicateArtifactId")));
    }
    let capture = parse(&screenshot_bytes, &tree_bytes).map_err(unparsed)?;
    sources.sort_by(|left, right| (&left.name, &left.id).cmp(&(&right.name, &right.id)));
    let derivation = json!({"kind": "offlineDerived", "parser": PARSER,
        "parserVersion": PARSER_VERSION, "observedFromUtc": observed_from,
        "observedToUtc": observed_to,
        "sources": sources.iter().map(Source::value).collect::<Vec<_>>()});
    match verb {
        "inspect" => Ok(json!({"schemaVersion": "arkdeck.ui-dump-inspection/1",
            "derivation": derivation, "capture": capture.value()})),
        "hit-test" => {
            let coordinate = |key: &str| {
                options
                    .get(key)
                    .and_then(Value::as_str)
                    .and_then(swift_double)
            };
            let (Some(x), Some(y)) = (coordinate("x"), coordinate("y")) else {
                return Err(fail(
                    "invalidOption",
                    "ui-dump hit-test requires --x and --y",
                ));
            };
            if !capture.verified {
                return Err(fail_naming(
                    "factsDrifted",
                    "this capture's coordinate mapping was never verified, so a point cannot be \
                     resolved to a node",
                    job,
                ));
            }
            let root = options.get("root").and_then(Value::as_str);
            Ok(json!({"schemaVersion": "arkdeck.ui-dump-hit-test/1",
                "derivation": derivation, "point": {"x": float(x), "y": float(y)},
                "node": capture.hit(root, x, y).map_or(Value::Null, Node::value)}))
        }
        _ => Err(fail("invalidCommand", "unsupported ui-dump subcommand")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = vec![137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13];
        bytes.extend_from_slice(b"IHDR");
        bytes.extend_from_slice(&width.to_be_bytes());
        bytes.extend_from_slice(&height.to_be_bytes());
        bytes
    }

    #[test]
    fn the_envelope_is_skipped_and_its_bounds_verify_the_coordinates() {
        let tree = json!({"attributes": {"bounds": "[0,0][100,200]"}, "children": [
            {"attributes": {"type": "Window", "accessibilityId": 1, "bounds": [0, 0, 100, 50]},
             "children": [{"attributes": {"type": "Text", "accessibilityId": 2,
                "bounds": {"left": 10, "top": 10, "right": 40, "bottom": 30},
                "text": "hi", "zIndex": "2"}}]},
            {"attributes": {"type": "Bar", "id": "7", "bounds": [0, 150, 100, 50],
                "hitTestBehavior": "HitTestMode.Transparent", "clip": "true"}}]});
        let capture = parse(&png(100, 200), tree.to_string().as_bytes()).unwrap();
        assert!(capture.verified);
        assert_eq!(capture.roots, ["device:1", "device:7"]);
        let text = capture.node("device:2").unwrap();
        assert_eq!(text.parent.as_deref(), Some("device:1"));
        assert_eq!(text.bounds, Bounds::new(10.0, 10.0, 30.0, 20.0));
        assert_eq!(text.z_index, Some(2.0));
        assert_eq!(text.depth, 1);
        assert_eq!(capture.hit(None, 20.0, 20.0).unwrap().identity, "device:2");
        // The transparent bar passes the click through to nothing.
        assert!(capture.hit(None, 50.0, 160.0).is_none());
        assert!(capture.hit(Some("device:7"), 20.0, 20.0).is_none());
    }

    #[test]
    fn duplicate_device_identities_fall_back_to_paths() {
        let tree = json!({"type": "Root", "id": "a", "bounds": [0, 0, 10, 10], "children": [
            {"type": "A", "id": "a"}]});
        let capture = parse(&png(10, 10), tree.to_string().as_bytes()).unwrap();
        assert_eq!(capture.roots, ["path:0"]);
        assert_eq!(capture.nodes[1].identity, "path:0.0");
    }

    #[test]
    fn malformed_inputs_are_named_as_swift_names_them() {
        assert!(matches!(parse(b"nope", b"{}"), Err(Unparsed::InvalidPng)));
        assert!(matches!(
            parse(&png(1, 1), b"[]"),
            Err(Unparsed::UnreadableTree)
        ));
        let children = json!({"type": "A", "children": [1]}).to_string();
        assert!(matches!(
            parse(&png(1, 1), children.as_bytes()),
            Err(Unparsed::InvalidTree)
        ));
        assert_eq!(
            Unparsed::InvalidSource("duplicateArtifactId").described(),
            "invalidSource(\"duplicateArtifactId\")"
        );
    }

    #[test]
    fn scalars_bridge_as_foundation_bridges_them() {
        assert_eq!(text(Some(&json!(true))), Some("1".into()));
        assert_eq!(text(Some(&json!(12))), Some("12".into()));
        assert_eq!(text(Some(&json!(""))), None);
        assert_eq!(flag(Some(&json!(1))), Some(true));
        assert_eq!(flag(Some(&json!(2))), None);
        assert_eq!(flag(Some(&json!("TRUE"))), None);
        assert_eq!(number(Some(&json!("1e2"))), Some(100.0));
        assert_eq!(number(Some(&json!("inf"))), None);
        assert_eq!(number(Some(&json!(" 1"))), None);
        assert_eq!(numbers_in("[-1.5,.5][3.,x4]"), [-1.5, 0.5, 3.0, 4.0]);
    }
}
