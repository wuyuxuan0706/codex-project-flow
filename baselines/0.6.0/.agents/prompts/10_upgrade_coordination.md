# 升级协调

本提示只用于 `$upgrade-project-flow` 的当前项目升级。协调器只协调；文件修改、检查和验证必须由独立用户可见升级执行任务完成。

## 事务边界

确认当前保存项目的精确 ID 和规范路径；完整快照活动任务，激活屏障，再创建一个可见执行器。执行器应用、验证并返回事务；协调器只读核对。然后取得中枢握手：快照为空走快速完成，否则按 `09_execution_handoff.md` 先归档前任、再创建继任并取得握手。身份、管理或验证失败时保持屏障，禁止替代执行。

## 增量原始消息观察

- 进入阶段或恢复时，对目标任务分页读取全部历史一次，`includeOutputs=false`。
- 等待只作唤醒；之后读最新 3 轮。补发、补偿、失败或解除屏障前再完整扫描。
- 只接受已知任务原始 `agentMessage.text` 的精确第一行；摘要、预览、标题、推理、工具输出和提示回显均不是证据。
- 相同合法握手幂等折叠；三次相同终止快照间隔 1 秒、2 秒仍无原始消息，才算稳定空响应。

## 精确首行

中枢：

```text
[codex-project-flow:hub-handshake:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>
```

继任首条用户消息：

```text
[codex-project-flow:execution:v2] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; predecessorThreadId=<exactPredecessorThreadId>; generation=<positiveInteger>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>
```

继任回复：

```text
[codex-project-flow:handshake:v1] projectId=<exactProjectId>; hubThreadId=<exactHubThreadId>; workflowVersion=<exactWorkflowVersion>; upgradeTransaction=<exactUpgradeTransaction>; generation=<positiveInteger>
```

## 有界恢复

- 中枢稳定空响应只补发一次；继任稳定空响应只补发一次，并最多创建一个代次加一的补偿继任。
- 每次等待不得超过本次协调剩余预算。单次尝试从进入或恢复起最多 60 秒。
- 到期保持屏障，报告事务、已确认项和待续项；恢复时复用现有 manifest、事务和握手，禁止重复应用。
- 任一身份不明确、消息不可管理、验证失败或补偿耗尽时保持屏障并停止；禁止回退到中枢执行。

