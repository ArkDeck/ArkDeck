use arkdeck_contract::{
    CATALOG_DIGEST, CONTRACT_IDENTITY, DeviceObservationsResult, MAX_REQUEST_BYTES, METHODS,
    PROTOCOL_VERSION, Request, WireError, decode_response, encode_frame, validate_health,
};
use arkdeck_control::{Control, HdcStatus, HostServices};
use serde_json::{Value, json};

struct Inventory(Vec<&'static str>);
impl HostServices for Inventory {
    fn registered_provider_ids(&self) -> Vec<&'static str> {
        self.0.clone()
    }
    fn operation_availability(&self, _: &str, _: &str) -> Option<Vec<(&'static str, String)>> {
        panic!("health must not probe operation availability or initialize owners")
    }
    fn observed_at(&self) -> String {
        panic!("health must not observe the host")
    }
    fn hdc_status(&self, _: bool) -> HdcStatus {
        panic!("health must not probe HDC")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        panic!("health must not observe devices")
    }
}

fn health(providers: Vec<&'static str>, app: bool) -> Value {
    let control = Control::new(Inventory(providers)).unwrap();
    let request = Request::new("health-inventory", "health", None);
    let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
    let response = if app {
        control.handle_app_frame(frame.trim_ascii_end())
    } else {
        control.handle_frame(frame.trim_ascii_end())
    };
    let response =
        decode_response(response.trim_ascii_end(), "health-inventory", "health").unwrap();
    validate_health(&response).unwrap();
    response.outcome.unwrap()
}

#[test]
fn health_lists_only_the_assembled_ports_without_probing_their_availability() {
    for app in [false, true] {
        let answer = health(vec!["workspace", "hdc", "analyzer", "hdc", "arkforge"], app);
        assert_eq!(
            answer,
            json!({
                "status":"ok", "protocolVersion":PROTOCOL_VERSION,
                "contractIdentity":CONTRACT_IDENTITY, "catalogDigest":CATALOG_DIGEST,
                "providers":["analyzer", "arkforge", "hdc", "workspace"],
                "publishedMethods":METHODS,
            })
        );
        // Publishing the Catalog alone does not assemble any provider.
        assert_eq!(health(Vec::new(), app)["providers"], json!([]));
    }
}
