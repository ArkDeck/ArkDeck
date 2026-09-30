#[cfg(any(target_os = "macos", windows))]
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // The fixtures that seed or time the Job store, whose owners are not on
    // Windows yet (G01): refused there before anything is created.
    #[cfg(windows)]
    if let Some(flag) = args.first().filter(|flag| {
        matches!(
            flag.as_str(),
            "--seed-artifact-bench" | "--measure-journal" | "--seed-recovery"
        )
    }) {
        eprintln!("{flag} needs the Job store, which is macOS-only until it reaches Windows (G01)");
        std::process::exit(1);
    }
    #[cfg(target_os = "macos")]
    if args.first().map(String::as_str) == Some("--seed-artifact-bench") {
        let result = (|| {
            if args.len() != 4 {
                return Err("usage: --seed-artifact-bench ROOT BYTE_COUNT SHA256".to_owned());
            }
            arkdeck_soak::artifact_bench::seed(
                std::path::Path::new(&args[1]),
                args[2].parse::<u64>().map_err(|e| e.to_string())?,
                &args[3],
            )
        })();
        match result {
            Ok(receipt) => println!(
                "{}",
                serde_json::json!({"kind":"artifactReady", "receipt":receipt})
            ),
            Err(error) => {
                eprintln!("artifact fixture failed: {error}");
                std::process::exit(1);
            }
        }
        return;
    }
    #[cfg(target_os = "macos")]
    if args.first().map(String::as_str) == Some("--measure-journal") {
        let result = if args.len() == 2 {
            arkdeck_soak::recovery::measure_journal(std::path::Path::new(&args[1]))
        } else {
            Err("usage: --measure-journal ABSOLUTE_EMPTY_ROOT".to_owned())
        };
        match result {
            Ok(manifest) => println!(
                "{}",
                serde_json::json!({"kind":"journalComplete", "manifest":manifest})
            ),
            Err(error) => {
                eprintln!("journal measurement failed: {error}");
                std::process::exit(1);
            }
        }
        return;
    }
    #[cfg(target_os = "macos")]
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
        #[cfg(target_os = "macos")]
        Ok(metrics) => println!(
            "ArkDeck Rust soak completed simulatedProvider=true terminalJobs={} verifiedArtifactJobs={}",
            metrics.terminal_job_count,
            metrics.verified_artifact_evidence_job_count.unwrap_or(0)
        ),
        #[cfg(windows)]
        Ok(metrics) => println!(
            "ArkDeck Rust soak completed workload={} cycles={} peakWorkingSetGrowthBytes={} handleGrowth={}",
            arkdeck_soak::WORKLOAD,
            metrics.cycle,
            metrics.resident_set_growth_bytes,
            metrics.open_file_descriptor_growth
        ),
        Err(error) => {
            eprintln!("ArkDeck Rust soak failed: {error}");
            std::process::exit(1);
        }
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
fn main() {
    eprintln!("arkdeck-soak currently supports macOS and Windows only");
    std::process::exit(1);
}
