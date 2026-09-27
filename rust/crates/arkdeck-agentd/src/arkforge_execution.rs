//! Execution over the lane generation already owned by this daemon. The
//! dispatcher and the lane's managed control share one durable action host,
//! the Host's existing HDC owner and the same Runtime USB census.
use crate::{arkforge_lane::Composed, host::Host};
use arkdeck_hoststore::{
    ArkForgeControlPerformer, ArkForgeLoader, ControlBinding, NativeRockchipDispatcher,
    PostFlashAliasStore, RockchipExecutor, RockchipUsbProbe,
};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_arkforge::NativeLaneConnections;
use std::{path::Path, sync::Arc};

pub(crate) fn install(
    host: Host,
    composed: &Composed,
    state: &Path,
    application_support: &Path,
    census: impl Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> + Send + Sync + 'static,
) -> Host {
    let (Ok(lane), Some(hdc)) = (&composed.lane, host.rockchip_hdc_resolver()) else {
        return host;
    };
    let census = Arc::new(census);
    let usb_census = census.clone();
    let loader_census = census.clone();
    let executor = RockchipExecutor::new(
        hdc,
        Box::new(RockchipUsbProbe::new(move || usb_census())),
        Box::new(ArkForgeLoader::new(
            move || loader_census(),
            &composed.runtime_directory,
        )),
        Box::new(arkdeck_provider_hdc::SystemClock),
    )
    .with_post_flash_aliases(PostFlashAliasStore::new(application_support), || {
        arkdeck_hoststore::runtime_now().unwrap_or_default()
    });
    let dispatcher = Arc::new(NativeRockchipDispatcher::durable(
        composed.rockusb(),
        executor,
        state,
    ));
    let actions = dispatcher.action_host();
    let directory = composed.runtime_directory.clone();
    let provider_digest = lane.daemon_sha256().to_owned();
    let connections =
        NativeLaneConnections::new(&composed.runtime_directory, move |job, binding| {
            let census = census.clone();
            Box::new(ArkForgeControlPerformer::new(
                ControlBinding {
                    job_id: job.to_owned(),
                    target_id: binding.target_id.clone(),
                    binding_revision: binding.binding_revision,
                    connect_key: binding.connect_key.clone(),
                    stable_identity_sha256: binding.stable_identity_sha256.clone(),
                    usb_topology: binding.usb_topology.clone(),
                    provider_executable_sha256: provider_digest.clone(),
                },
                actions.clone(),
                Box::new(ArkForgeLoader::new(move || census(), &directory)),
            ))
        });
    host.with_flash_execution(
        Arc::new(lane.execution_host(Box::new(connections))),
        dispatcher,
        lane.profile_reference().to_owned(),
    )
}
