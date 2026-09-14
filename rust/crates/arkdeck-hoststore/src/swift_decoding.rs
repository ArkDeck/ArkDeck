//! Swift `JSONDecoder` as ArkDeck's durable readers meet it: a keyed decoding
//! container that reports Swift's `DecodingError` descriptions with their
//! coding paths, Foundation's readings of a JSON number as `Int` and as
//! `JSONValue`, and Swift's counting and equality of a `String`.

use serde_json::{Map, Value, json};
use unicode_segmentation::UnicodeSegmentation;

const DICTIONARY: &str = "Dictionary<String, Any>";
const ARRAY: &str = "Array<Any>";

/// Foundation's `Int` of a JSON number: an integer, or a number with no
/// fraction, inside `Int`'s range.
pub(crate) fn swift_integer(number: &serde_json::Number) -> Option<i64> {
    number.as_i64().or_else(|| {
        number
            .as_f64()
            .filter(|float| {
                float.fract() == 0.0 && *float >= i64::MIN as f64 && *float < i64::MAX as f64
            })
            .map(|float| float as i64)
    })
}

/// A JSON value as Swift's `JSONValue` holds it, which it tries as `Int64`,
/// then `UInt64`, then `Double`: a number with no fraction is an integer.
pub(crate) fn swift_value(value: &Value) -> Value {
    match value {
        Value::Number(number) if !number.is_i64() && !number.is_u64() => match number.as_f64() {
            Some(float)
                if float.fract() == 0.0 && float >= i64::MIN as f64 && float < i64::MAX as f64 =>
            {
                json!(float as i64)
            }
            Some(float) if float.fract() == 0.0 && float >= 0.0 && float < u64::MAX as f64 => {
                json!(float as u64)
            }
            _ => value.clone(),
        },
        Value::Array(items) => Value::Array(items.iter().map(swift_value).collect()),
        Value::Object(members) => Value::Object(
            members
                .iter()
                .map(|(name, member)| (name.clone(), swift_value(member)))
                .collect(),
        ),
        other => other.clone(),
    }
}

// MARK: - Swift `DecodingError`

#[derive(Clone, Debug)]
pub(crate) enum Step {
    Key(String),
    Index(usize),
}

/// A Swift `DecodingError`, as its description renders it.
#[derive(Debug)]
pub(crate) enum Decoding {
    TypeMismatch {
        expected: &'static str,
        found: &'static str,
        path: Vec<Step>,
    },
    /// A type mismatch a synthesized decoder describes itself, such as an
    /// enum case container without exactly one case key.
    TypeMismatchDescribed {
        expected: &'static str,
        description: String,
        path: Vec<Step>,
    },
    ValueNotFound {
        expected: &'static str,
        container: Option<&'static str>,
        path: Vec<Step>,
    },
    KeyNotFound {
        key: String,
        path: Vec<Step>,
    },
    DataCorrupted {
        description: String,
        path: Vec<Step>,
    },
}

impl Decoding {
    pub(crate) fn describe(&self) -> String {
        match self {
            Self::TypeMismatch {
                expected,
                found,
                path,
            } => format!(
                "DecodingError.typeMismatch: expected value of type {expected}.{} Debug description: Expected to decode {expected} but found {found} instead.",
                at(path)
            ),
            Self::TypeMismatchDescribed {
                expected,
                description,
                path,
            } => format!(
                "DecodingError.typeMismatch: expected value of type {expected}.{} Debug description: {description}",
                at(path)
            ),
            Self::ValueNotFound {
                expected,
                container,
                path,
            } => format!(
                "DecodingError.valueNotFound: Expected value of type {expected} but found null instead.{} Debug description: {}",
                at(path),
                match container {
                    Some(kind) =>
                        format!("Cannot get {kind} decoding container -- found null value instead"),
                    None =>
                        format!("Cannot get value of type {expected} -- found null value instead"),
                }
            ),
            Self::KeyNotFound { key, path } => format!(
                "DecodingError.keyNotFound: Key '{key}' not found in keyed decoding container.{} Debug description: No value associated with key CodingKeys(stringValue: \"{key}\", intValue: nil) (\"{key}\").",
                at(path)
            ),
            Self::DataCorrupted { description, path } => format!(
                "DecodingError.dataCorrupted: Data was corrupted.{} Debug description: {description}",
                at(path)
            ),
        }
    }
}

/// The coding path a description names: keys joined by dots, indices
/// appended in brackets.
pub(crate) fn at(path: &[Step]) -> String {
    if path.is_empty() {
        return String::new();
    }
    let mut rendered = String::new();
    for step in path {
        match step {
            Step::Key(key) => {
                if !rendered.is_empty() {
                    rendered.push('.');
                }
                rendered.push_str(key);
            }
            Step::Index(index) => rendered.push_str(&format!("[{index}]")),
        }
    }
    format!(" Path: {rendered}.")
}

/// Foundation `JSONDecoder`'s name for the JSON value it met.
pub(crate) fn found(value: &Value) -> &'static str {
    match value {
        Value::Array(_) => "an array",
        Value::Object(_) => "a dictionary",
        Value::String(_) => "a string",
        Value::Number(_) => "number",
        Value::Bool(_) => "bool",
        Value::Null => "null",
    }
}

pub(crate) fn child(path: &[Step], step: Step) -> Vec<Step> {
    let mut path = path.to_vec();
    path.push(step);
    path
}

/// A keyed decoding container.
pub(crate) struct Keyed<'a> {
    pub(crate) members: &'a Map<String, Value>,
    pub(crate) path: Vec<Step>,
}

impl<'a> Keyed<'a> {
    pub(crate) fn of(value: &'a Value, path: Vec<Step>) -> Result<Self, Decoding> {
        match value {
            Value::Object(members) => Ok(Self { members, path }),
            Value::Null => Err(Decoding::ValueNotFound {
                expected: DICTIONARY,
                container: Some("keyed"),
                path,
            }),
            other => Err(Decoding::TypeMismatch {
                expected: DICTIONARY,
                found: found(other),
                path,
            }),
        }
    }

    pub(crate) fn path(&self, key: &str) -> Vec<Step> {
        child(&self.path, Step::Key(key.into()))
    }

    pub(crate) fn present(&self, key: &str) -> Result<&'a Value, Decoding> {
        self.members.get(key).ok_or_else(|| Decoding::KeyNotFound {
            key: key.into(),
            path: self.path.clone(),
        })
    }

    /// `decodeIfPresent`: an absent or null member is nil.
    pub(crate) fn optional(&self, key: &str) -> Option<&'a Value> {
        self.members.get(key).filter(|value| !value.is_null())
    }

    pub(crate) fn string(&self, key: &str) -> Result<String, Decoding> {
        string(self.present(key)?, self.path(key))
    }

    pub(crate) fn optional_string(&self, key: &str) -> Result<Option<String>, Decoding> {
        self.optional(key)
            .map(|value| string(value, self.path(key)))
            .transpose()
    }

    pub(crate) fn int(&self, key: &str) -> Result<i64, Decoding> {
        int(self.present(key)?, self.path(key))
    }

    pub(crate) fn optional_int(&self, key: &str) -> Result<Option<i64>, Decoding> {
        self.optional(key)
            .map(|value| int(value, self.path(key)))
            .transpose()
    }

    /// `decodeIfPresent(Int64.self, …)`, whose refusals name `Int64`.
    pub(crate) fn optional_int64(&self, key: &str) -> Result<Option<i64>, Decoding> {
        self.optional(key)
            .map(|value| integer(value, self.path(key), "Int64"))
            .transpose()
    }

    pub(crate) fn bool(&self, key: &str) -> Result<bool, Decoding> {
        let path = self.path(key);
        match self.present(key)? {
            Value::Bool(flag) => Ok(*flag),
            Value::Null => Err(Decoding::ValueNotFound {
                expected: "Bool",
                container: None,
                path,
            }),
            other => Err(Decoding::TypeMismatch {
                expected: "Bool",
                found: found(other),
                path,
            }),
        }
    }

    pub(crate) fn keyed(&self, key: &str) -> Result<Keyed<'a>, Decoding> {
        Keyed::of(self.present(key)?, self.path(key))
    }

    pub(crate) fn array(&self, key: &str) -> Result<Vec<(&'a Value, Vec<Step>)>, Decoding> {
        let path = self.path(key);
        match self.present(key)? {
            Value::Array(items) => Ok(items
                .iter()
                .enumerate()
                .map(|(index, item)| (item, child(&path, Step::Index(index))))
                .collect()),
            Value::Null => Err(Decoding::ValueNotFound {
                expected: ARRAY,
                container: Some("unkeyed"),
                path,
            }),
            other => Err(Decoding::TypeMismatch {
                expected: ARRAY,
                found: found(other),
                path,
            }),
        }
    }

    /// A `RawRepresentable` enum member spelled by its raw string.
    pub(crate) fn raw<T>(
        &self,
        key: &str,
        name: &str,
        parse: fn(&str) -> Option<T>,
    ) -> Result<T, Decoding> {
        let text = self.string(key)?;
        parse(&text).ok_or_else(|| Decoding::DataCorrupted {
            description: format!("Cannot initialize {name} from invalid String value {text}"),
            path: self.path(key),
        })
    }

    /// A custom decoder's `dataCorruptedError(forKey:in:debugDescription:)`.
    pub(crate) fn corrupted(&self, key: &str, description: String) -> Decoding {
        Decoding::DataCorrupted {
            description,
            path: self.path(key),
        }
    }
}

pub(crate) fn string(value: &Value, path: Vec<Step>) -> Result<String, Decoding> {
    match value {
        Value::String(text) => Ok(text.clone()),
        Value::Null => Err(Decoding::ValueNotFound {
            expected: "String",
            container: None,
            path,
        }),
        other => Err(Decoding::TypeMismatch {
            expected: "String",
            found: found(other),
            path,
        }),
    }
}

pub(crate) fn int(value: &Value, path: Vec<Step>) -> Result<i64, Decoding> {
    integer(value, path, "Int")
}

/// A fixed-width integer named `name` in Swift's refusals.
fn integer(value: &Value, path: Vec<Step>, name: &'static str) -> Result<i64, Decoding> {
    match value {
        // Foundation fails the whole decode, at no coding path.
        Value::Number(number) => swift_integer(number).ok_or_else(|| Decoding::DataCorrupted {
            description: format!(
                "The given data was not valid JSON.. Underlying error: Error Domain=NSCocoaErrorDomain Code=3840 \"Number {number} is not representable in Swift.\" UserInfo={{NSDebugDescription=Number {number} is not representable in Swift.}}"
            ),
            path: Vec::new(),
        }),
        Value::Null => Err(Decoding::ValueNotFound {
            expected: name,
            container: None,
            path,
        }),
        other => Err(Decoding::TypeMismatch {
            expected: name,
            found: found(other),
            path,
        }),
    }
}

/// Swift's `String.count`: extended grapheme clusters.
pub(crate) fn characters(text: &str) -> usize {
    text.graphemes(true).count()
}

/// The key Swift's `String` equality compares: an ASCII text is its own, any
/// other its canonical-equivalence key.
pub(crate) fn text_key(text: &str) -> String {
    if text.is_ascii() {
        return text.to_owned();
    }
    crate::canonical_host_text(text).unwrap_or_else(|_| text.to_owned())
}

pub(crate) fn same_text(left: &str, right: &str) -> bool {
    left == right || text_key(left) == text_key(right)
}
