//! The DevEco password decoder against vectors Swift produced (SPK-10,
//! TASK-XPA-015). The hex below was printed by
//! `evidence/runs/TASK-XPA-015/spk-10/deveco-vectors.swift`, which rebuilds
//! `OpenHarmonyLocalSigningContractTests.makeDevEcoPasswordFixture` with
//! CryptoKit and fixed nonces: `swiftTest` is that fixture, `illFormed` makes
//! the XORed key material an ill-formed UTF-8 sequence of every kind, and
//! `ascii` makes it plain text. A decoder that re-encoded the key material
//! differently from Swift would derive another root key and fail to open the
//! work key.
#![cfg(unix)]

use arkdeck_provider_workspace::SigningError;
use arkdeck_provider_workspace::deveco_password::{
    decode_if_needed, decode_with_material, pbkdf2_sha256,
};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

struct Vector {
    parts: [&'static str; 3],
    salt: &'static str,
    lossy: &'static str,
    work_key_envelope: &'static str,
    encrypted: &'static str,
    plaintext: &'static str,
}

const SWIFT_TEST: Vector = Vector {
    parts: [
        "11111111111111111111111111111111",
        "42424242424242424242424242424242",
        "a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5",
    ],
    salt: "000102030405060708090a0b0c0d0e0f",
    lossy: "efbfbd05efbfbdefbfbd2059efbfbd4e254847efbfbdefbfbd7536efbfbd",
    work_key_envelope: "00000020212121212121212121212121995703aa42513e859495056d6c978fd621d24b98a0fbc95c72e355d17630bf7a",
    encrypted: "0000002937373737373737373737373724639e22e0a17224e9556e5e89cd83f938a39b7684f35148b4b0967540b1dcb425687b58aa91d813e1",
    plaintext: "deveco-plaintext-password",
};

const ILL_FORMED: Vector = Vector {
    parts: [
        "f173e9f39742fb38272e31d8951c58f7",
        "00000000000000000000000000000000",
        "00000000000000000000000000000000",
    ],
    salt: "000102030405060708090a0b0c0d0e0f",
    lossy: "efbfbdefbfbdefbfbdefbfbd41efbfbdefbfbdefbfbdefbfbdefbfbdefbfbdefbfbdf09f9880",
    work_key_envelope: "00000020212121212121212121212121ec925b87a05af96259ee6410cee1bbf9dfeb94aab09b54c0b1e1db30333723e9",
    encrypted: "0000002f37373737373737373737373722e3ecd8ae5c9aaaf31a1ed06dfe325501adf948a25d433f75c0946bdc343c179b1f3bdd00b9294b592aad5fb31374",
    plaintext: "Ill-formed UTF-8 key material 7",
};

const ASCII: Vector = Vector {
    parts: [
        "00000000000000000000000000000000",
        "01c23b40e29a6d8feb87d03a06e7a511",
        "00000000000000000000000000000000",
    ],
    salt: "000102030405060708090a0b0c0d0e0f",
    lossy: "30313233343536373839616263646566",
    work_key_envelope: "00000020212121212121212121212121b3c0166ce54135a58b43127a4bf0d53653335abfe169668a4ed74290e4bf9446",
    encrypted: "000000273737373737373737373737374bdb2b8499aa236d645b19494b0beea0305c17f4240b14e5c7b0e0d4478f86981dc99b6452516e",
    plaintext: "ascii-material-password",
};

const COMPONENT: [u8; 16] = [
    49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119,
];

fn bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&hex[index..index + 2], 16).unwrap())
        .collect()
}

#[test]
fn every_swift_vector_decodes_to_its_plaintext() {
    for vector in [&SWIFT_TEST, &ILL_FORMED, &ASCII] {
        let parts = vector.parts.map(bytes);
        let decoded = decode_with_material(
            &bytes(vector.encrypted),
            [&parts[0], &parts[1], &parts[2]],
            &bytes(vector.salt),
            &bytes(vector.work_key_envelope),
        )
        .unwrap();
        assert_eq!(decoded.as_bytes(), vector.plaintext.as_bytes());
    }
}

/// Node's `Buffer.toString()`, Swift's `String(decoding:as: UTF8.self)` and
/// Rust's `from_utf8_lossy` replace the same maximal ill-formed subsequences.
#[test]
fn key_material_is_reencoded_exactly_as_swift_reencodes_it() {
    for vector in [&SWIFT_TEST, &ILL_FORMED, &ASCII] {
        let mut combined = COMPONENT;
        for part in vector.parts.map(bytes) {
            for (byte, other) in combined.iter_mut().zip(part) {
                *byte ^= other;
            }
        }
        assert_eq!(
            String::from_utf8_lossy(&combined).as_bytes(),
            bytes(vector.lossy)
        );
    }
    // Printed by Swift for the same inputs.
    for (input, expected) in [
        ("e282", "efbfbd"),
        ("f0808041", "efbfbdefbfbdefbfbd41"),
        ("fffe41", "efbfbdefbfbd41"),
        ("e180e2f09192f1bf41", "efbfbdefbfbdefbfbdefbfbd41"),
    ] {
        assert_eq!(
            String::from_utf8_lossy(&bytes(input)).as_bytes(),
            bytes(expected),
            "{input}"
        );
    }
}

/// RFC 7914 §11, which Swift's derivation also reproduces.
#[test]
fn the_derivation_is_pbkdf2_hmac_sha256() {
    assert_eq!(
        pbkdf2_sha256(b"passwd", b"salt", 1, 64).unwrap().as_bytes(),
        bytes(
            "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
        )
    );
    assert!(pbkdf2_sha256(b"p", b"s", 0, 16).is_err());
    assert!(pbkdf2_sha256(b"p", b"s", 1, 0).is_err());
}

/// The material tree DevEco keeps beside a keystore, as the Swift fixture
/// builds it.
struct Material {
    root: PathBuf,
    keystore: PathBuf,
}

impl Material {
    fn new(name: &str, vector: &Vector) -> Self {
        let root = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
            .join(format!("deveco-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let material = root.join("material");
        for (index, part) in vector.parts.iter().enumerate() {
            let slot = material.join("fd").join(index.to_string());
            std::fs::create_dir_all(&slot).unwrap();
            std::fs::write(slot.join(format!("part-{index}")), bytes(part)).unwrap();
        }
        std::fs::create_dir_all(material.join("ac")).unwrap();
        std::fs::write(material.join("ac/salt"), bytes(vector.salt)).unwrap();
        std::fs::create_dir_all(material.join("ce")).unwrap();
        std::fs::write(
            material.join("ce/work-key"),
            bytes(vector.work_key_envelope),
        )
        .unwrap();
        for directory in walk_directories(&root) {
            std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let keystore = root.join("release.p12");
        std::fs::write(&keystore, b"fixture").unwrap();
        Self { root, keystore }
    }
}

impl Drop for Material {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn walk_directories(root: &Path) -> Vec<PathBuf> {
    let mut directories = vec![root.to_owned()];
    let mut index = 0;
    while index < directories.len() {
        for entry in std::fs::read_dir(&directories[index]).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                directories.push(path);
            }
        }
        index += 1;
    }
    directories
}

#[test]
fn ciphertext_decodes_through_the_material_beside_the_keystore() {
    let material = Material::new("layout", &SWIFT_TEST);
    for text in [
        SWIFT_TEST.encrypted.to_owned(),
        SWIFT_TEST.encrypted.to_uppercase(),
    ] {
        assert_eq!(
            decode_if_needed(text.as_bytes(), &material.keystore)
                .unwrap()
                .as_bytes(),
            SWIFT_TEST.plaintext.as_bytes()
        );
    }
    // Finder's `.DS_Store` never becomes key material.
    std::fs::write(material.root.join("material/fd/.DS_Store"), b"finder").unwrap();
    std::fs::write(material.root.join("material/ce/.DS_Store"), b"finder").unwrap();
    assert_eq!(
        decode_if_needed(SWIFT_TEST.encrypted.as_bytes(), &material.keystore)
            .unwrap()
            .as_bytes(),
        SWIFT_TEST.plaintext.as_bytes()
    );
}

/// Swift's own passthrough cases: an ordinary password, a long hexadecimal
/// plaintext that is not envelope-shaped, and bytes that are not UTF-8.
#[test]
fn a_candidate_that_is_not_deveco_ciphertext_comes_back_unchanged() {
    let keystore = Path::new("/nonexistent/release.p12");
    for candidate in [
        b"ordinary-plaintext".to_vec(),
        "a".repeat(64).into_bytes(),
        vec![0xff; 40],
        b"0123456789abcdef0123456789abcde".to_vec(),
    ] {
        assert_eq!(
            decode_if_needed(&candidate, keystore).unwrap().as_bytes(),
            candidate.as_slice()
        );
    }
    assert_eq!(
        decode_if_needed("ab".repeat(1_025).as_bytes(), keystore).err(),
        Some(SigningError::InvalidConfiguration(
            "DevEco password ciphertext is malformed".into()
        ))
    );
}

#[test]
fn material_that_is_absent_unsafe_or_tampered_is_refused() {
    let invalid = |message: &str| Some(SigningError::InvalidConfiguration(message.into()));
    let decode = |material: &Material| {
        decode_if_needed(SWIFT_TEST.encrypted.as_bytes(), &material.keystore).err()
    };

    // Swift's own tamper: 48 zero bytes are not even envelope-shaped.
    let material = Material::new("zeroed", &SWIFT_TEST);
    std::fs::write(material.root.join("material/ce/work-key"), [0u8; 48]).unwrap();
    assert_eq!(
        decode(&material),
        invalid("DevEco encrypted material envelope is malformed")
    );

    // One flipped tag byte keeps the shape and fails authentication.
    let material = Material::new("tampered", &SWIFT_TEST);
    let mut work_key = bytes(SWIFT_TEST.work_key_envelope);
    *work_key.last_mut().unwrap() ^= 1;
    std::fs::write(material.root.join("material/ce/work-key"), work_key).unwrap();
    assert_eq!(
        decode(&material),
        invalid("DevEco encrypted password could not be authenticated")
    );

    let material = Material::new("missing-slot", &SWIFT_TEST);
    std::fs::remove_dir_all(material.root.join("material/fd/2")).unwrap();
    assert_eq!(
        decode(&material),
        invalid("DevEco signing material layout is incomplete")
    );

    let material = Material::new("second-salt", &SWIFT_TEST);
    std::fs::write(material.root.join("material/ac/other"), [0u8; 16]).unwrap();
    assert_eq!(
        decode(&material),
        invalid("DevEco signing material layout is incomplete")
    );

    let material = Material::new("writable", &SWIFT_TEST);
    std::fs::set_permissions(
        material.root.join("material/fd"),
        std::fs::Permissions::from_mode(0o777),
    )
    .unwrap();
    assert_eq!(
        decode(&material),
        invalid("DevEco signing material directory is absent or unsafe")
    );

    let material = Material::new("symlink", &SWIFT_TEST);
    let salt = material.root.join("material/ac/salt");
    std::fs::rename(&salt, material.root.join("salt-target")).unwrap();
    std::os::unix::fs::symlink(material.root.join("salt-target"), &salt).unwrap();
    assert_eq!(
        decode(&material),
        invalid("DevEco signing material file is absent or unsafe")
    );

    let material = Material::new("short-part", &SWIFT_TEST);
    std::fs::write(material.root.join("material/fd/1/part-1"), [0x42; 15]).unwrap();
    assert_eq!(
        decode(&material),
        invalid("DevEco signing material file is absent or unsafe")
    );

    let absent = Path::new(env!("CARGO_TARGET_TMPDIR")).join("no-deveco-material/release.p12");
    assert_eq!(
        decode_if_needed(SWIFT_TEST.encrypted.as_bytes(), &absent).err(),
        invalid("DevEco signing material directory is absent or unsafe")
    );
}
