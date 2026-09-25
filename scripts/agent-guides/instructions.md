# 指令与项目 skill 维护

适用：维护 `AGENTS.md`、项目 skill，或排查指令冲突。其他任务无需读取本指南或下列外部资料。

- 根 [AGENTS.md](../../AGENTS.md) 保留所有任务都需要的边界、完成标准与任务入口。
  跨目录的专用流程放在按需指南中，入口写明触发场景；只有确属某个目录的规则才放到该目录
  的 `AGENTS.md`。子目录文件不能替代根入口对跨目录流程的显式导航。
- 本目录沿用 `scripts/**` 已有的 sensitive paths 与 `never_self_extend` 保护，拆分只改变
  读取时机，不降低原指令的审查边界，也不新增审批流程。
- 项目 skill 放在 `.agents/skills/<name>/SKILL.md`，description 简短且明确适用任务；正文
  说明输入、产出与专门知识，多流程内容按需链接。避免泛化触发词、通用能力教学和固定步骤堆叠。
  普通操作指南无需仅为拆文件而包装成 skill。
- 清除失效路径、重复约束和历史状态；删除前检查引用及脚本用途。指令保留目标、完成条件和
  必要边界，常规实现选择留给 Agent。修改后核对链接、触发场景和迁移前后约束是否完整。
  个人与插件 skills 属于独立修改范围。
- `AGENTS.md` 同时由 Codex 与 Claude 读取，写模型中立的目标、边界与停止条件。不加通用的
  “仔细思考”“完成前再核一遍”类指令：Claude Opus 5/5.5 默认会思考与自查，这类指令只增加
  思考量或造成重复验证；思考深度由 effort 控制。

维护依据：[Rethinking skills and prompts for GPT-6 Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)、
[OpenAI 提示指导](https://developers.openai.com/api/docs/guides/latest-model#prompting-best-practices)、
[AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)、
[Skills](https://learn.chatgpt.com/docs/build-skills)；
[Prompting Claude Opus 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5)、
[Prompting Claude Opus 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5)、
[Claude prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)。
