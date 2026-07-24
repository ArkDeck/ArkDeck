# CHG-2026-033 read-only discovery — 2026-07-24

> Classification:read-only proposal input; non-executable.
> Final bounded snapshot:`2026-07-24T03:25:12Z`.
> Repository:`ArkDeck/ArkDeck`.
> GitHub control-plane/ref/PR/credential write during discovery:`0`.

## Snapshot and concurrency

- protected main audit OID：
  `e8eaef86acc13ef76270e29f7a63873d0b2fa6cb`（#451 merge）。
- #449 已把 CHG-2026-030 r6 合入为 approved authority；其 constrained gateway
  授权 Agent 修改 ruleset，与本 change human-executed D2 边界冲突。受影响 D2
  工作停止，待本 change approval 与独立 CHG-2026-030 r7。
- open PR：#452（base 为上述 main；head branch
  `agent/rkfui-001a-firmware-repin-readiness`，head
  `19bfd772420ef5945f87672ed9995ebd2c44ecbd`，等待 `lvye`）；它只修改
  CHG-2026-026 firmware readiness，与本 proposal paths/control-plane plan 不重叠。

Related change state：

- CHG-2026-027：`verified`；`BAP-CRED-001` 历史行为 evidence 在案。
- CHG-2026-030：r6 `approved`；#435 readiness 因 main drift 已不可执行；
  TASK-HLR-002A/002B 与 D2 gateway 受本 change 提出的冲突 stop gate 约束。
- CHG-2026-032：#451 已归档；与 ref-protection 路径无文件交集。

本 OID 只用于 proposal discovery，绝不是 D2 readiness/execution pin。

## Remote branches

最终 `git ls-remote --heads origin`：

```text
21be4ce872e9b673712efa1d65f3b934a45f8f46 refs/heads/agent/chg-2026-029-r5-remediation
3c7f049bb5dac137351f6f6eb4bbfbbb3ab1d2a0 refs/heads/agent/obs-001-observability
53bbec764c645978accb8020415a64e6fe7ce1b4 refs/heads/agent/rkfui-001-identity-separation-readiness
19bfd772420ef5945f87672ed9995ebd2c44ecbd refs/heads/agent/rkfui-001a-firmware-repin-readiness
8c39aab06f03538c9f95bfbc7ccb17b44f110fae refs/heads/agent/task-hlr-002-readiness
6744d353b42faf8da15314c09f3465749be05f77 refs/heads/agent/task-hlr-002a-bootstrap-partition
66474de216bc1ae80e59a6ba7d1ea12ca1f76a07 refs/heads/agent/task-mech-002
bee1f96420f8a70c6652be1ae9bd1c97386405a2 refs/heads/agent/task-tr-003
e8eaef86acc13ef76270e29f7a63873d0b2fa6cb refs/heads/main
```

不存在 main 以外的非 `agent/**` branch。stale Agent branches 不授权本阶段删除。

## Current public ruleset JSON

```json
{
  "id": 19595282,
  "name": "agent-ref-boundary",
  "target": "branch",
  "source_type": "Repository",
  "source": "ArkDeck/ArkDeck",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "exclude": [
        "refs/heads/agent/**"
      ],
      "include": [
        "~ALL"
      ]
    }
  },
  "rules": [
    {
      "type": "creation"
    },
    {
      "type": "update"
    },
    {
      "type": "deletion"
    }
  ],
  "node_id": "RRS_lACqUmVwb3NpdG9yec5Na16-zgErABI",
  "created_at": "2026-07-23T02:20:11.391Z",
  "updated_at": "2026-07-23T02:20:11.425Z",
  "_links": {
    "self": {
      "href": "https://api.github.com/repos/ArkDeck/ArkDeck/rulesets/19595282"
    },
    "html": {
      "href": "https://github.com/ArkDeck/ArkDeck/rules/19595282"
    }
  }
}
```

最后一次 authenticated full JSON（#435）在同一 `updated_at` 下另含：

```json
{
  "bypass_actors": [
    {
      "actor_id": 4340161,
      "actor_type": "User",
      "bypass_mode": "always"
    }
  ],
  "current_user_can_bypass": "always"
}
```

public response 不含 `bypass_actors`/`current_user_can_bypass`。unchanged timestamp
只能支持“公开结构看起来未变”，不能替代 fresh authenticated full JSON。

## Current public main protection projection

```json
{
  "name": "main",
  "protected": true,
  "commit": {
    "sha": "e8eaef86acc13ef76270e29f7a63873d0b2fa6cb"
  },
  "protection": {
    "enabled": true,
    "required_status_checks": {
      "enforcement_level": "non_admins",
      "contexts": [
        "guard"
      ],
      "checks": [
        {
          "context": "guard",
          "app_id": 15368
        }
      ]
    }
  }
}
```

unauthenticated full
`GET /repos/ArkDeck/ArkDeck/branches/main/protection` 返回 401；以下字段当前未知：

- full `required_pull_request_reviews`；
- `require_code_owner_reviews`；
- required checks strictness；
- `enforce_admins`；
- restrictions users/teams/apps；
- `allow_force_pushes`；
- `allow_deletions`；
- 所有其他 protection 字段。

`enforcement_level:non_admins` 是 warning，不能假定 admin enforcement 已存在。

## Credential and integration finding

- historical BAP evidence：Deploy Key ID `158088026`，
  `arkdeck-agent-writer`，write-enabled、non-bypass；本轮无 authenticated deploy-key
  enumeration。
- sandbox 外 `gh auth status`：zero logged-in hosts，符合维护者 CLI credential 移除。
- Agent 可达 Codex GitHub connector：
  - authenticated login：`lvye`（ID `4340161`）；
  - repository permissions：`admin=true`、`maintain=true`、`push=true`；
  - callable surface 包含 ref update、review `APPROVE`、PR merge、enable-auto-merge。

最后一项本身已经违反 human-credential containment；即使 connector 不在一个具名
App allowlist 中，它仍以 ruleset bypass user `lvye` 的身份行动。任何 D2 前必须移除。

## Old HLR-002A invalidation

#435 固定：

- audit base：`e9406075cb6ac1401447d2f90c22ffc488a05512`；
- absolute window：`2026-07-24T02:30:00Z`→`03:30:00Z`；
- old authenticated before、after/rollback payload/hash；
- old target refs、probe UUID 与 executor script。

proposal audit main 已为
`e8eaef86acc13ef76270e29f7a63873d0b2fa6cb`，且 #449/r6 形成新语义冲突。无论旧
wall-clock interval 是否仍在文本范围内，上述所有值均失效，不得通过只换时间戳或 UUID
复用。

## Discovery limitation and stop decision

维护者 credential 按治理要求不在 `gh`；不应为了完成 discovery 注入 Agent 环境。
因此本 proposal 不能声称拿到了 current authenticated full control-plane snapshot。

允许：

- proposal/approval drafting；
- human-controlled、secret-free authenticated JSON export 的后续准备；
- non-executable D2 readiness template。

禁止：

- ruleset、branch protection、repository setting、credential、ref、review、merge 或
  PR state write；
- 把 public projection 或 #435 JSON 伪装为 fresh current before；
- 在本 change approval 与 CHG-2026-030 r7 supersession 前进入受影响 D2。
