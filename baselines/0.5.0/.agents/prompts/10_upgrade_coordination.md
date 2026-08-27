# 升级协调

本提示只用于 `$upgrade-project-flow` 的当前项目升级。协调器只协调；文件修改、检查和验证必须由独立用户可见升级执行任务完成。

## 事务边界

1. 精确确认调用任务所属已保存本地项目的 `projectId` 与规范路径；不匹配时在读取或操作其他项目前停止。
2. 完整枚举同项目用户可见活动任务，记录快照，激活创建屏障，再创建一个升级执行器。任务管理或身份确认失败时保持失败关闭，禁止中枢或隐藏子代理代替。
3. 执行器应用并验证文件事务，返回精确目标版本和事务 ID；协调器只读核对 manifest。插件所有内容采用新版，项目事实与状态保留，未托管碰撞停止。
4. 文件事务成功后先取得中枢握手；快照为空则直接解除屏障，否则逐一安全交接、先归档前任、再创建继任并取得继任握手。无冲突等待可并行，消息、归档和创建等外部变更串行。

## 增量原始消息观察

- 进入阶段或恢复时，对目标任务分页读取全部历史一次，`includeOutputs=false`。
- 每次等待只作唤醒信号；随后只读该任务最新 3 轮，仍设置 `includeOutputs=false`。
- 补发、创建补偿继任、判定失败或解除屏障前，再完整分页扫描一次。
- 只接受已知任务原始 `agentMessage.text` 的精确第一行；摘要、预览、标题、推理、工具输出和提示回显均不是证据。
- 同一任务、版本、事务和代次的完全相同合法握手幂等折叠。终止轮次连续三次相同快照，快照间等待 1 秒、2 秒且仍无原始消息，才算稳定空响应。

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
- 到期时保持屏障，报告已应用事务、已确认项和待续项。下次继续先读取现有 manifest、事务和握手，禁止重复应用文件事务。
- 任一身份不明确、消息不可管理、验证失败或补偿耗尽时保持屏障并停止；禁止回退到中枢执行。
