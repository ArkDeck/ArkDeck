# TASK-M0B-001 capture hash 清单

原始 capture 字节(含设备序列号)存放于维护者受控位置 `~/m0b-capture/2026-07-18/`,
不进入仓库;本清单钉死每个文件的 SHA-256。脱敏后的 redacted manifest 副本在
`redacted-manifests/` 下(runbook 约定其为 repo-safe)。

| controlled-location file | bytes | sha256 |
| --- | --- | --- |
| `~/m0b-capture/2026-07-18/pre-auth/00-hdc-version-flag.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/pre-auth/00-hdc-version-flag.stdout` | 12 | `906d35a917937ecbb33d8dc3bbb6b3e1783bd2996a6201ab7227fb406d474ed9` |
| `~/m0b-capture/2026-07-18/pre-auth/01-hdc-version-word.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/pre-auth/01-hdc-version-word.stdout` | 12 | `906d35a917937ecbb33d8dc3bbb6b3e1783bd2996a6201ab7227fb406d474ed9` |
| `~/m0b-capture/2026-07-18/pre-auth/02-hdc-checkserver.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/pre-auth/02-hdc-checkserver.stdout` | 55 | `50e8dfe03cb770dfade5b91198523b964fd3bd6fd8855b541ceb46201f0d014a` |
| `~/m0b-capture/2026-07-18/pre-auth/03-hdc-list-targets.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/pre-auth/03-hdc-list-targets.stdout` | 33 | `2035c0783fe1b2fbc3bba6badfb76003c1a5d46bbe16d1479de439e9fd874fc2` |
| `~/m0b-capture/2026-07-18/pre-auth/04-hdc-list-targets-verbose.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/pre-auth/04-hdc-list-targets-verbose.stdout` | 58 | `d8816e413776d80e6e577b78f6abbf8c114bfd570b3627f7a007c97681af9c48` |
| `~/m0b-capture/2026-07-18/pre-auth/manifest.json` | 6433 | `fdbcb0af8bda09f2a060c42f7cb9b9c02c3886c7979280304685224fae1ae58d` |
| `~/m0b-capture/2026-07-18/pre-auth/redacted-manifest.json` | 6433 | `10abbfa44348e34e1b9cd0901fc5140bc5cdaa33fae9f9a674fc7cb0cc030111` |
| `~/m0b-capture/2026-07-18/negative/00-hdc-list-targets.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/negative/00-hdc-list-targets.stdout` | 33 | `2035c0783fe1b2fbc3bba6badfb76003c1a5d46bbe16d1479de439e9fd874fc2` |
| `~/m0b-capture/2026-07-18/negative/01-hdc-list-targets-verbose.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/negative/01-hdc-list-targets-verbose.stdout` | 58 | `d8816e413776d80e6e577b78f6abbf8c114bfd570b3627f7a007c97681af9c48` |
| `~/m0b-capture/2026-07-18/negative/manifest.json` | 3178 | `74bf83943b5edcea7d45be773417ebcff3947bcf4d715902c2d6382c1eac3802` |
| `~/m0b-capture/2026-07-18/negative/redacted-manifest.json` | 3178 | `7c90789cfe7c1a03de9f4a9bce1aad2e69575da1498d5f9c64238c667208cb40` |
| `~/m0b-capture/2026-07-18/post-auth/00-hdc-list-targets.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/post-auth/00-hdc-list-targets.stdout` | 33 | `2035c0783fe1b2fbc3bba6badfb76003c1a5d46bbe16d1479de439e9fd874fc2` |
| `~/m0b-capture/2026-07-18/post-auth/01-hdc-list-targets-verbose.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/post-auth/01-hdc-list-targets-verbose.stdout` | 58 | `d8816e413776d80e6e577b78f6abbf8c114bfd570b3627f7a007c97681af9c48` |
| `~/m0b-capture/2026-07-18/post-auth/manifest.json` | 3178 | `74bf83943b5edcea7d45be773417ebcff3947bcf4d715902c2d6382c1eac3802` |
| `~/m0b-capture/2026-07-18/post-auth/redacted-manifest.json` | 3178 | `7c90789cfe7c1a03de9f4a9bce1aad2e69575da1498d5f9c64238c667208cb40` |
| `~/m0b-capture/2026-07-18/hidumper/00-hidumper-help.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/hidumper/00-hidumper-help.stdout` | 34 | `a4904901becfb1a15517c14c51f6fa26524162008578bab3dc64f1c7baa006e5` |
| `~/m0b-capture/2026-07-18/hidumper/01-hidumper-services.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `~/m0b-capture/2026-07-18/hidumper/01-hidumper-services.stdout` | 3121 | `351fc59ea33de263a6123c6030624e1a1fcd17ae0eb5dab6d67ffba09ec07a4b` |
| `~/m0b-capture/2026-07-18/hidumper/manifest.json` | 3365 | `38645888b707cdef2d6156d81dfcc32637ef91a552d900e5cbaa9d8c6fb46c5e` |
| `~/m0b-capture/2026-07-18/hidumper/redacted-manifest.json` | 3325 | `14e0ce82eaccbd92b8755417104f8c0a57a8aa313db4566d19db3d5a83f1811f` |

校验方式:对受控位置文件重算 SHA-256 与本表比对;每条命令的 per-stream hash
同时登记在对应 redacted manifest 的 `commands[].stdout/stderr.sha256` 字段,
两处必须一致。
