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

维护依据：[Rethinking skills and prompts for GPT-6 Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)、
[OpenAI 提示指导](https://developers.openai.com/api/docs/guides/latest-model#prompting-best-practices)、
[AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)、
[Skills](https://learn.chatgpt.com/docs/build-skills)。
