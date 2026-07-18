# Evidence placeholder

change approved 且任务执行前,本目录不得出现任何 run 或 evidence 记录。

approved 后的一次执行只可产出:

- `runs/TASK-M0B-001/run.md`(V2 轻量格式:操作者、时间、macOS/设备信息、逐命令
  argv/exit code、capture hash 清单、四个 AC 二值结论、偏差与遗留风险);
- 符合 `contracts/hardware-evidence.schema.json`(2.0.0)的 evidence JSON
  (provider:none;operator 与 physicalTargetConfirmation 必填);
- `runs/TASK-M0B-002/run.md`(supervisor 观察,依赖 TASK-M1-006 done)。

边界:含设备序列号/网络地址的 raw capture 字节存放维护者受控位置,仓库内只记
SHA-256 与脱敏摘要;不得包含用户路径、密钥、可执行镜像字节;本目录任何记录都
只支持 `observed`/`partial` matrix 行,不构成 `verified`、兼容性、支持声明、
DEC-002 结论或 release claim。simulation/fake 证据不得写入本目录。
