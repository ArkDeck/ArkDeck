//! Known SHA-256 answers independent of the chosen CPU backend.
use sha2::{Digest, Sha256};

#[test]
fn sha256_standard_answers_survive_backend_selection() {
    // FIPS 180-4 examples, including padding across the 512-bit block boundary.
    for (input, expected) in [
        (
            b"abc".as_slice(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        ),
        (
            b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".as_slice(),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        ),
    ] {
        for width in [1, 7, 64, 65] {
            let mut hash = Sha256::new();
            for chunk in input.chunks(width) {
                hash.update(chunk);
            }
            assert_eq!(format!("{:x}", hash.finalize()), expected);
        }
    }
    let mut hash = Sha256::new();
    for _ in 0..1000 {
        hash.update([b'a'; 1000]);
    }
    assert_eq!(
        format!("{:x}", hash.finalize()),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    );
}
