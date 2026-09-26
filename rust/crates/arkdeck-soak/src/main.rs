#[cfg(target_os = "macos")]
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--seed-recovery") {
        let result = (|| {
            if args.len() != 4 {
                return Err(
                    "usage: --seed-recovery journal|history COUNT ABSOLUTE_EMPTY_ROOT".to_owned(),
                );
            }
            let count = args[2].parse::<usize>().map_err(|e| e.to_string())?;
            arkdeck_soak::recovery::seed(std::path::Path::new(&args[3]), &args[1], count)
        })();
        match result {
            Ok(manifest) => println!("{manifest}"),
            Err(error) => {
                eprintln!("recovery seed failed: {error}");
                std::process::exit(1);
            }
        }
        return;
    }
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
