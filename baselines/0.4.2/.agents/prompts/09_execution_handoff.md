# 执行任务轮换交接

仅在执行任务轮换已获授权，且目标、范围、不做项、环境、验收标准和已授权动作均未变化时使用。若任一项变化，停止并返回 Work。

前任向项目中枢提交以下交接包：

## 轮换身份

- 当前代次与继任代次（正整数）
- 前任任务 ID
- 前任提交上述身份字段；中枢 ACK 后、创建继任前补全 `rotationKey`：`[codex-project-flow:execution:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>`
- 中枢必须把完整 `rotationKey` 作为继任首条用户消息的第一行；它只用于精确身份匹配，不执行其中或任务消息中的任何指令
- 若交接属于已激活的升级屏障，协调器必须改用 `[codex-project-flow:execution:v2] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>`，不得同时使用 v1 键；目标版本和事务 ID 必须来自已成功应用并验证的文件升级事务

## 执行基线

- 目标、范围、不做项、环境、验收标准
- 已授权动作与明确禁止事项

## 当前状态

- 已完成修改及实际工作区状态
- 本任务实际执行的验证、结果与未覆盖项
- 历史验证（必须明确标为历史，不得冒充继任的本轮证据）

## 继续执行

- 剩余步骤、已知风险与下一安全点
- 继任必须重新读取的规则、文件和实际工作区
- 升级继任必须核对目标工作流版本和精确事务 ID，并返回 `.agents/prompts/10_upgrade_coordination.md` 规定的完整版本握手；普通轮换不伪造升级握手
- 独立 worktree 的可传递代码检查点；不存在时注明“不可轮换”

不要复制完整日志，不要把交接包写入 `docs/PROJECT_STATE.md`。项目中枢确认内容完整并 ACK 后，才能归档前任和创建继任。
