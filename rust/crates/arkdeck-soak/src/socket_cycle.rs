//! The Swift soak's actual client/server leg over the shared production server.
//! Only the existing owner fixture is composed here; no production device host.
use super::*;
use arkdeck_client::Client;
use arkdeck_contract::{DeviceObservationsResult, WireError};
use arkdeck_control::{Control, HdcStatus, HostServices};
use arkdeck_platform::{Latch, LocalEndpoint, LocalListener, ServerIdentity};
use std::sync::Arc;
use std::thread::JoinHandle;

struct Host {
    owners: Arc<Owners>,
    fake: Arc<SimulatedHdc>,
    root: PathBuf,
    home: String,
    claims: StorageClaims,
}
impl Host {
    fn hdc(&self) -> HdcComposition<'_> {
        HdcComposition {
            targets: &self.owners.targets,
            dispatch: self.fake.as_ref(),
            receive_root: None,
            tool_sha256: DIGEST,
            now: runtime_now,
            code_sign_helper: None,
        }
    }
}
impl HostServices for Host {
    fn job_submit(&self, params: &Map<String, Value>) -> std::result::Result<Value, WireError> {
        let hdc = self.hdc();
        JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&self.owners.artifacts),
                analyzer: None,
                state_root: &self.root,
                hdc: Some(&hdc),
                workspace: None,
            },
            jobs: &self.owners.jobs,
            now: runtime_now,
            authority: None,
        }
        .handle(params)
        .map_err(|refusal| WireError {
            code: refusal.code.into(),
            message: refusal.message,
            details: Some(if refusal.proven {
                Map::from_iter([
                    ("phase".into(), json!("preAdmission")),
                    ("newDispatchCount".into(), json!(0)),
                ])
            } else {
                Map::new()
            }),
        })
    }
    fn job_resource(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> std::result::Result<Value, WireError> {
        self.owners.jobs.handle_resource(method, params)
    }
    fn job_run(&self, params: &Map<String, Value>) -> std::result::Result<Value, WireError> {
        let hdc = self.hdc();
        let probe = SystemStorageProbe;
        let publisher = SessionPublisher {
            sessions: &self.owners.sessions,
            claims: &self.claims,
            probe: &probe,
        };
        JobRunner {
            imports: None,
            mutation: None,
            jobs: &self.owners.jobs,
            artifacts: &self.owners.artifacts,
            analyzer: None,
            quota: 8 * 1024 * 1024 * 1024,
            home: &self.home,
            now: runtime_now,
            precise_now: runtime_precise_now,
            sessions: Some(&publisher),
            cancellation: None,
            after_commit: None,
            hdc: Some(&hdc),
            workspace: None,
        }
        .handle(params)
        .map_err(|refusal| WireError {
            code: refusal.code.into(),
            message: refusal.message,
            details: Some(refusal.details),
        })
    }
    fn job_cancel(&self, params: &Map<String, Value>) -> std::result::Result<Value, WireError> {
        let probe = SystemStorageProbe;
        let publisher = SessionPublisher {
            sessions: &self.owners.sessions,
            claims: &self.claims,
            probe: &probe,
        };
        JobCanceller {
            jobs: &self.owners.jobs,
            now: runtime_now,
            sessions: Some(&publisher),
        }
        .handle(params)
    }
    fn observed_at(&self) -> String {
        runtime_now().unwrap_or_default()
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
        HdcStatus::unavailable(deep, "simulatedProvider")
    }
    fn observations(&self) -> std::result::Result<DeviceObservationsResult, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "soak observations are composed directly from the simulated provider".into(),
            details: None,
        })
    }
}

/// Keep the private transport suffix shorter than the benchmark's /agentd.sock
/// and reject oversized roots before opening
/// owners or publishing a marker. Darwin reserves one of sun_path's 104 bytes
/// for the terminator; caller-selected UTF-8 paths are measured as bytes.
pub(super) fn validate_root(root: &Path) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        let path = root.join("d/ctl.sock");
        if path.as_os_str().as_encoded_bytes().len() > 103 {
            return Err(format!(
                "soak socket path {} exceeds 103 bytes; choose a shorter --state-directory (for example under /private/tmp)",
                path.display()
            ));
        }
    }
    #[cfg(windows)]
    let _ = root;
    Ok(())
}

pub(super) fn server_identity() -> Result<ServerIdentity> {
    let identity = ServerIdentity::new(std::env::current_exe().map_err(error)?);
    #[cfg(target_os = "macos")]
    {
        Ok(identity)
    }
    #[cfg(windows)]
    {
        let pin = std::env::var(crate::SIGNER_VARIABLE).unwrap_or_default();
        if pin.len() != 64
            || !pin
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        {
            return Err(format!(
                "{} must name the lowercase SHA-256 pin of the host-trusted certificate this executable is signed with",
                crate::SIGNER_VARIABLE
            ));
        }
        Ok(ServerIdentity {
            authenticode_sha256: Some(pin),
            ..identity
        })
    }
}

pub(super) struct Cycle {
    endpoint: LocalEndpoint,
    stop: Arc<Latch>,
    worker: Option<JoinHandle<std::io::Result<arkdeck_agentd::DrainOutcome>>>,
    next_request: u64,
}
impl Cycle {
    pub(super) fn start(root: &Path, owners: Arc<Owners>, fake: Arc<SimulatedHdc>) -> Result<Self> {
        #[cfg(target_os = "macos")]
        let endpoint = LocalEndpoint::new(root.join("d/ctl.sock"));
        #[cfg(windows)]
        let endpoint = LocalEndpoint::new(format!(
            r"\\.\pipe\arkdeck-soak-{}",
            arkdeck_contract::sha256_hex(root.as_os_str().as_encoded_bytes())
        ));
        let control = Arc::new(
            Control::new(Host {
                owners,
                fake,
                root: root.to_path_buf(),
                home: home()?,
                claims: StorageClaims::default(),
            })
            .map_err(error)?,
        );
        // Bind synchronously: no readiness sleep, no other generation can own
        // this private endpoint while it is being served or drained.
        #[cfg(target_os = "macos")]
        HostDirectory::open(root)
            .map_err(error)?
            .private_child("d")
            .map_err(error)?;
        // Reuse the production kernel directory lease; plain bind has no
        // retained directory lock once the socket name is removed.
        #[cfg(target_os = "macos")]
        let listener = LocalListener::bind_facade(&endpoint).map_err(error)?;
        let stop = Arc::new(Latch::new().map_err(error)?);
        let accept_stop = Arc::clone(&stop);
        #[cfg(target_os = "macos")]
        let worker = std::thread::spawn(move || {
            arkdeck_agentd::serve_control(
                listener,
                control,
                |listener| listener.accept_until_latch(&accept_stop),
                Duration::from_secs(5),
                Duration::from_secs(5),
            )
        });
        #[cfg(windows)]
        let worker = {
            // A Windows listener stays on the thread that binds it. Publish
            // readiness after bind, so clients need no readiness sleeps.
            let endpoint = endpoint.clone();
            let (ready, bound) = std::sync::mpsc::sync_channel(1);
            let worker = std::thread::spawn(move || {
                let listener = LocalListener::bind(&endpoint);
                let _ = ready.send(listener.as_ref().map(|_| ()).map_err(|e| e.to_string()));
                arkdeck_agentd::serve_control(
                    listener?,
                    control,
                    |listener| listener.accept_until_latch(&accept_stop),
                    Duration::from_secs(5),
                    Duration::from_secs(5),
                )
            });
            match bound.recv().map_err(error)? {
                Ok(()) => worker,
                Err(message) => {
                    let _ = worker.join();
                    return Err(message);
                }
            }
        };
        Ok(Self {
            endpoint,
            stop,
            worker: Some(worker),
            next_request: 0,
        })
    }

    pub(super) fn request(&mut self, method: &str, params: Map<String, Value>) -> Result<Value> {
        self.next_request += 1;
        // Swift AgentClient.exchange opens one connection per business request,
        // verifies health on that connection and never replays a lost reply.
        let identity = server_identity()?;
        let mut client = Client::connect_bounded(&self.endpoint, &identity, Duration::from_secs(5))
            .map_err(error)?;
        client
            .request(&format!("soak-{}", self.next_request), method, Some(params))
            .map_err(error)
    }

    pub(super) fn finish(mut self) -> Result<()> {
        self.stop.set();
        let result = self
            .worker
            .take()
            .expect("one serving generation")
            .join()
            .map_err(|_| "soak control serving thread panicked".to_owned())?
            .map_err(error)?;
        if !result.complete {
            // Remaining handlers retain the listener lock until they actually
            // release their owners. This run fails and cannot start a new cycle.
            return Err("soak control generation did not drain before its deadline".into());
        }
        drop(result);
        Ok(())
    }
}
impl Drop for Cycle {
    fn drop(&mut self) {
        // Early workload failure follows the same stop/drain path. No next
        // cycle follows an error; the original failure remains the run result.
        if let Some(worker) = self.worker.take() {
            self.stop.set();
            let _ = worker.join();
        }
    }
}
