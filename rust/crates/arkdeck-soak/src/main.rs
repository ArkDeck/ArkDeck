#[cfg(target_os = "macos")]
fn main() {
    let result = arkdeck_soak::Configuration::parse(std::env::args().skip(1))
        .and_then(|configuration| arkdeck_soak::run(&configuration));
    match result {
        Ok(metrics) => println!(
            "ArkDeck Rust soak completed simulatedProvider=true terminalJobs={} verifiedArtifactJobs={}",
            metrics.terminal_job_count,
            metrics.verified_artifact_evidence_job_count.unwrap_or(0)
        ),
        Err(error) => {
            eprintln!("ArkDeck Rust soak failed: {error}");
            std::process::exit(1);
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("arkdeck-soak currently supports macOS only");
    std::process::exit(1);
}
