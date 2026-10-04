# Historical HAP provenance fixture

The unmodified simulated Swift Job record from `debug-hap/store/jobs/job-e79d1b4e261f4a13d0bfb58a97fbf163/job-record.json` at repository commit `a3ca03c1e54c8ae423018e9d4f55b645caee52db`, before the interactive Diagnostics Catalog extension.

The historical-read tests retain this exact record while current-Catalog execution fixtures are regenerated. It verifies that adding an unrelated operation does not bypass the `debug.hap@1` step-correlation checks, and that the narrowly supported pre-compensation terminal digest remains readable without changing the record or granting replay authority. This is fake-provider test data, never hardware evidence or a usable RuntimeCapability.
