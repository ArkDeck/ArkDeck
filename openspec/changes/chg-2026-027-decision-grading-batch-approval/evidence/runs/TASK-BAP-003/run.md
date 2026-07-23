# TASK-BAP-003 run — Agent 凭据分离落实

- Date:2026-07-23;executor:human。
- Classification:真实 GitHub control-plane/ref 权限执行;无设备、无硬件操作。
- Final run window:`2026-07-23T02:46:27Z` → `2026-07-23T02:47:30Z`。
- Repository:`ArkDeck/ArkDeck`。
- Secret handling:token 已脱敏;私钥、公钥正文与本机私钥路径均未记录。证据只保留
  GitHub 对象 ID 与公钥 SHA-256 指纹。

## 实际落地

1. Repository ruleset:
   - name:`agent-ref-boundary`;ID:`19595282`;enforcement:`active`;
   - target:`branch`;include:`~ALL`;exclude:`refs/heads/agent/**`;
   - rules:`creation`、`update`、`deletion`;
   - bypass 仅维护者 `lvye`(`actor_type=User`,`actor_id=4340161`,
     `bypass_mode=always`);Deploy Key 不在 bypass list。
2. Agent credential:
   - repository-scoped Deploy Key ID:`158088026`;
   - title:`arkdeck-agent-writer`;write access:`true`;
   - fingerprint:`SHA256:HUhfMAcNoDNfZgYKmXjgqpkkjzSs9mWYI+LtyAUuDOI`;
   - SSH alias:`github-arkdeck-agent`;Agent remote:
     `git@github-arkdeck-agent:ArkDeck/ArkDeck.git`;
   - Agent-only checkout 的共享 origin 已覆盖 47 个 linked worktree。
3. Organization Deploy Key policy:
   - `deploy_keys_enabled_for_repositories=true`;
   - 该组织级变更由维护者在本次 D2 窗口显式确认;其作用面包含 ArkDeck 组织
     当前及未来 repository。
4. GitHub active-rule evaluation:
   - `main`:creation/update/deletion 命中 ruleset `19595282`;
   - `cred-probe-denied`:creation/update/deletion 命中同一 ruleset;
   - `agent/cred-probe`:不命中该 ruleset。
5. 既有 `main` branch protection 在设置前后 JSON read-back 一致,未替换或放宽。

## 维护者凭据移除

执行前 `gh auth status` 显示维护者 `lvye` 为 active account;token 值未记录。

```text
command: gh auth logout -h github.com -u lvye
exit_code: 0
✓ Logged out of github.com account lvye

command: git credential reject (github.com, username=lvye; no credential value supplied)
exit_code: 0

command: gh auth status (after credential removal)
exit_code: 1
You are not logged into any GitHub hosts.
```

执行后的独立检查:

- usable `gh` accounts reachable:`0`;
- `GH_TOKEN`/`GITHUB_TOKEN`/enterprise variants:absent;
- Git credential helper 对 `github.com` 的 credential fill 不返回 password;
- `ssh-add -l`:no reachable identities。

结论:`lvye` 的 `gh`、Git credential-helper 与 ssh-agent 凭据均不在 Agent
运行环境可达面;Agent Git origin 仅使用上述 Deploy Key alias。

## 三项真实 ref 验证

测试前 `main` OID:
`e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2`。

### 正向 — `agent/**`

```text
command: git push <agent-remote> HEAD:refs/heads/agent/cred-probe
exit_code: 0
To github-arkdeck-agent:ArkDeck/ArkDeck.git
 * [new branch]      HEAD -> agent/cred-probe

command: git push <agent-remote> :refs/heads/agent/cred-probe
exit_code: 0
To github-arkdeck-agent:ArkDeck/ArkDeck.git
 - [deleted]         agent/cred-probe
```

远端删除后复查为空。结论:`agent/cred-probe: PASS`。

### 负向 — 普通分支创建

```text
command: git push <agent-remote> HEAD:refs/heads/cred-probe-denied
exit_code: 1
remote: error: GH013: Repository rule violations found for refs/heads/cred-probe-denied.
remote:
remote: - Cannot create ref due to creations being restricted.
remote:
 ! [remote rejected] HEAD -> cred-probe-denied (push declined due to repository rule violations)
error: failed to push some refs to 'github-arkdeck-agent:ArkDeck/ArkDeck.git'
```

远端复查 `refs/heads/cred-probe-denied` 为空。结论:
`cred-probe-denied: PASS`。

### 负向 — 直接更新 `main`

基于测试时 `origin/main` 创建空提交
`02f030377379bde3333ef79dbfb4ca8f1f3fe1f4`,零文件差异。

```text
command: git push origin <probe_oid>:refs/heads/main
exit_code: 1
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote:
remote: - Cannot update this protected ref.
remote:
 ! [remote rejected] 02f030377379bde3333ef79dbfb4ca8f1f3fe1f4 -> main (push declined due to repository rule violations)
error: failed to push some refs to 'github-arkdeck-agent:ArkDeck/ArkDeck.git'
```

测试后 `main` OID:
`e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2`,与测试前完全一致。结论:
`direct main rejection: PASS`。

## 执行偏差与 fail-closed 记录

本 D2 窗口在最终成功前有四次脚本 fail-closed;均发生在维护者凭据移除与 push
probe 之前,没有把失败记为通过:

1. `2026-07-23T02:20:02Z`:ruleset 创建成功(ID `19595282`),但首次严格
   read-back 未兼容 GitHub 对 update 默认参数的省略,脚本误报 mismatch 后停止。
2. `2026-07-23T02:23:05Z`:ruleset 严格复核通过;Deploy Key 创建因组织策略
   disabled 返回 HTTP 422 后停止。
3. 维护者随后显式授权组织级 Deploy Key policy;`2026-07-23T02:28:22Z`
   启用策略并创建 Deploy Key(ID `158088026`),但首次 key read-back 将 GitHub
   省略公钥 comment 误判为不匹配,脚本停止。
4. `2026-07-23T02:31:03Z`:ruleset 与 Deploy Key 严格复核通过;共享 Git
   config 与 worktree config 的多值 origin 造成 read-back 误判,脚本停止。

脚本随后改为比较规范化的公钥 key material、接受 GitHub 省略的 update 默认
参数,并把 Agent-only checkout 的共同 origin 原子地统一到 Deploy Key alias;
`2026-07-23T02:46:27Z` 最终 run 完整通过。上述期间 ruleset 保持 active,
未为修复测试而删除、停用或放宽。

## AC 结论(candidate)

`BAP-CRED-001`(documentReview):候选 PASS。

- 受限 Agent credential 对 `agent/**` 创建/删除成功;
- 同一 credential 创建普通分支与直接更新 `main` 均收到明确 `GH013`
  ruleset rejection;
- direct-main 测试前后 OID 相同;
- 维护者账号凭据与批准动作不在 Agent 可达的 `gh`、环境变量、
  credential helper 或 ssh-agent 中;
- evidence 零 token、零私钥、零本机私钥路径。

本 run 只提交执行 evidence;`TASK-BAP-003` 仍保持 `ready`,须待本 evidence PR
由维护者 review/merge 并取得准确 merge OID 后,再由独立状态 PR 起草
`ready → done`。

## 遗留风险

- Deploy Key 不自动过期;若私钥疑似泄露,维护者须删除/轮换 ID `158088026`
  并重新执行双向 ref 验证。
- 组织 Deploy Key policy 是显式接受的组织级作用面,不是仅对单仓库的开关;
  新 repository 是否添加 Deploy Key 仍需各仓库单独配置。
- V1 三私钥轮换/删除与两个历史 GitHub secrets 清理属于 TASK-BAP-003
  out of scope,本 run 不声称完成。
