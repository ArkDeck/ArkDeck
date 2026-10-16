//! Expectations belong to ArkDeck: an upstream bump must not silently move them.
#[test]
fn pinned_consumer_versions() {
    assert_eq!(arkforge_ipc::contract::PROTOCOL_VERSION, "1.0");
    assert_eq!(
        (arkforge_ipc::PROTOCOL_MAJOR, arkforge_ipc::PROTOCOL_MINOR),
        (1, 0)
    );
    assert_eq!(
        arkforge_arkdeck_adapter::ARKDECK_CONTRACT_VERSION,
        "arkforge.arkdeck-contract/1.0.0"
    );
}
