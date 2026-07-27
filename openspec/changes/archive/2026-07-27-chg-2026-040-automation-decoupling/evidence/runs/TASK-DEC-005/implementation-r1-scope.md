# TASK-DEC-005 implementation run（r1 授权面）

- Task:TASK-DEC-005
- Executor:agent（会话实现;never-claim,循环零认领）
- Date:2026-07-27
- Readiness:**r1**(#607 merge `16f184f…`)。**r2（三项跨分区移交）在起草时
  尚未合入,故本 PR 只交付 r1 授权面**;移交三项待 r2 合入后独立 PR。
- Implementation base:`0b8179daf709174162b1b4d94d06b4ca3585c4d3`
- Hardware:none(host-only)。设备零触碰、launchd 零动作、GitHub 零写入。

## Input gate 复核

r1 六个 blob 在实现 base 上**逐一 HOLD**:transport.py `537d57a0…`、
lease.py `685fb3c3…`、backends.py `0efa3e8c…`、test_fault_matrix.py
`7a3b2d94…`、test_backends_cli.py `08f87845…`、test_token_parity.py
`efb93754…`。

## 已交付

1. **D-H1 重定向**:`UrllibSender` 改用 `build_opener(_NoRedirect)`,3xx 以
   状态呈现而非透明跟随;绝对 URL 与 protocol-relative 路径均拒绝。
2. **D-H2 refname 等值**:`RefPort.read` 拒多行匹配集,并断言 ls-remote
   回的 refname 与所请求的**完全相等**。
3. **D-H3 renew owner 校验**:`_advance` 拒绝非本 owner 的 `HeldLease`,
   使 `renew()` 不再成为绕过 `takeover()` 前置的后门。**已核** `takeover`
   自建 record 直写、不经 `_advance`,7 个既有 takeover 测试未受影响。
4. **D-M3 git 子进程环境白名单**:`_GIT_ENV_PASSTHROUGH` 七项,
   `GIT_CONFIG_NOSYSTEM`/`GIT_CONFIG_GLOBAL`/`GIT_CONFIG_COUNT` 硬设;
   token 变量不进 git 子进程环境。
5. **D-M6 403 歧义化**:带限流形状的 403 → `TransportError` 而非
   `Refused`（后者是唯一可作 fence-loss 证据的类)。
6. **D-M7 绑定器排 bool**:`bound_to_pull`/`bound_to_issue`。
7. **D-M8 committer 身份硬设**（assignment 非 setdefault）。
8. **D-M9 写入余量**:`assert_still_held` 要求剩余 TTL ≥
   `WRITE_MARGIN_SECONDS`(90s > HTTP 超时 60s)。
9. **死代码退役**:Python minter(`mint_installation_token` /
   `_openssl_sign`)整体删除——零生产调用,且其 `sudo openssl dgst -sign`
   需要 NOPASSWD sudoers 规则 = 该账户 root 等价升级,正是 shell minter
   头部记载的**被拒绝设计**;它还走一条无 allowlist 覆盖的 GitHub 路由。
   四个只测它的用例退役,换成**缺席契约**测试防复采;恒假 fence 断言
   (`nxt.fence <= held.record.fence`,上一行刚 +1)删除。
10. **E-M3 渲染半侧**(r1 明确授权的一半):`backends.py` 的 evidence 声明
    由 `none — …` 改 `none: …`,进入 envelope 的严格 `none:` 文法。

## 验收

**变异门 7/7 全部击杀,负对照正确存活**:

| 变异 | 结果 |
| --- | --- |
| D-H1: 恢复跟随重定向 | KILLED(2) |
| D-H1: 重开绝对 URL 逃逸口 | KILLED(2) |
| D-H2: 去掉 refname 等值 | KILLED(1) |
| D-H3: renew 又能偷他人租约 | KILLED(1) |
| D-M3: 恢复整体复制环境 | KILLED(2) |
| D-M8: committer 回 setdefault | KILLED(1) |
| 死代码: 重新引入 minter 符号 | KILLED(2) |
| **负对照**:仅改注释文字 | **SURVIVED**(正确) |

**首轮 harness 有两条存活(D-H2/D-H3),如实记录**:说明这两条修复当时
**零测试覆盖**——正是 readiness 勘察预测的结果（三个最小修复各零断言
反应 = 零构造点**且**零覆盖）。已补 `LsRemoteMustAnswerAboutTheRefIt
WasAsked`(4 例)与 `RenewIsNotABackDoorAroundTakeover`(2 例),二轮
harness 全杀。这正是 readiness 把变异门写成硬条件的理由。

**D-H1 live 双服务器实测**(非替身):第一台答 301 指向第二台,
`UrllibSender` 返回 `(301, None)`,第二台**零请求记录**——token 未被重放;
绝对 URL 入参得 `BackendError`。

**套件与 guard**:host_loop `-m unittest discover` **607 OK + 2 expected
failure**(基线 595 OK + 2 xf);`check-sdd` **0/0/111**。

## 未交付(如实记录)

- **r2 移交三项**(`identity.confirm_merge` 退役、envelope path 分支收紧、
  `test_v3_hardening.py` stray-main + DEC-007 expectedFailure 同步):r2
  readiness 起草时未合,**D1 门后不投机开工**,待 r2 合入后独立 PR。
- **D-H2 的 `observed_main` 半侧**:该函数在 `scripts/host_loop/__main__.py`,
  属本任务 **Forbidden paths**(DEC-007 分区)。r1 的 In scope 文字含
  `read/observed_main`,但授权面不含该文件——**已停**,未触碰。需 r3 扩权
  或由 DEC-007 侧承接。同型缺陷仍在:`observed_main` 用
  `out.split()[0]` 取多行输出首 token,任何尾为 `refs/heads/main` 的 ref
  可顶替受保护 main 的 OID。
- **测试替身补真实字段**(FakeApi 的 GET issue 路由、pull 的
  merged/auto_merge/merge_commit_sha/html_url、check-run `id`):r1 In scope
  内但本轮未做,`test_fault_matrix.py` 未改动一行。留待 r2 移交 PR 一并
  处理（该文件亦是 `confirm_merge` 迁移的落点,合并处理可省一轮）。
