# 执行任务轮换交接

仅在执行任务轮换已获授权，且目标、范围、不做项、环境、验收标准和已授权动作均未变化时使用。若任一项变化，停止并返回 Work。

前任提交：当前/继任代次、前任任务 ID；目标、范围、不做项、环境、验收标准、授权与禁令；实际工作区、已完成修改、本轮验证及未覆盖项；剩余步骤、风险、安全点、必读文件；独立 worktree 的可传递检查点（没有则“不可轮换”）。历史证据必须明确标注。

中枢 ACK 后、创建继任前生成完整首行键：普通轮换使用 `[codex-project-flow:execution:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>`；升级屏障内只能使用 `[codex-project-flow:execution:v2] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>`。版本和事务取自已验证事务；键仅用于精确身份匹配。

继任重新读取规则和实际工作区。升级继任核对版本/事务，并返回 `.agents/prompts/10_upgrade_coordination.md` 的完整握手；普通轮换不得伪造升级握手。

不复制完整日志，不把交接包写入项目状态。中枢确认完整后，先归档前任再创建继任；失败按 `AGENTS.md` 恢复。

## 结果回传

仅在需要协调、用户选择或用户明确要求时，回传目标、修改、本轮验证、风险和下一步。普通完成报告留在当前任务。

