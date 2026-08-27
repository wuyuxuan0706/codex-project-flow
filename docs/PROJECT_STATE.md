# 项目状态

## 当前目标

- 发布 `0.7.1`：正式交付元数据优先、零活动快速路径、单事务任务和并行继任协调的速度优化，并完成真实 Codex 验收。

## 当前进展

- 工作流保持 schema 6；机器契约包含路径、安全开关、执行并发策略、精确数值、协调器认领和事务/握手模板，项目托管集仍为 6 个文件。
- bootstrap/upgrade 两个插件 Skill 目录合计固定为 6 个文件；Bootstrap 使用元数据优先、历史按需读取的单一状态机，Upgrade 使用一个可见事务任务同时协调和执行。
- PowerShell/POSIX 各自只有一套共享核心、内部 validator 和独立操作函数；旧的六个脚本名仅作静默兼容转发。
- 旧项目升级在事务前读取 pluginRoot 目标契约，成功后才切换到已部署协议；plan/apply/resume/rollback 均由中枢路由到独立可见任务，PowerShell 不再受陈旧 `$LASTEXITCODE` 影响。
- `0.6.0` 已冻结为不可变 8 文件结构基线；实际安装缓存中的 `0.7.0` 已冻结为不可变 6 文件补丁基线，支持从所有历史基线直接推导到 `0.7.1`。
- 两平台 validator 已同步 schema 6；安装失败恢复、plan 后和备份后并发变化、跨平台占位符/JSON/控制字符/manifest 证据均有回归覆盖，PowerShell/POSIX 完整集成复跑通过。
- 跨平台差分测试已在 `0.6.0` 和 `0.5.0` 同源 fixture 上通过：plan 动作、apply 后 managed/manifest、事务稳定字段和 rollback 结果一致，PowerShell/POSIX 双向事务锁互操作均失败关闭且项目零变化。
- install 实写、upgrade apply 与 rollback 共用跨平台 OS 单写者锁；rollback 在首次恢复前认证完整事务和全部备份，并在每个写入点复核目标，拒绝损坏、竞态和类型伪造而不产生部分恢复。
- `0.7.1` 的 PowerShell/POSIX 完整回归、`0.7.0`/`0.6.0` 跨平台差分、23 个 JSON、三个 Skill 快速验证、plugin validator、6/6/2 结构与冲突语义扫描均通过；个人 Marketplace `personal` 的新 cachebuster 已生成，待正式提交、推送和重装。

## 重要结论

- 最佳维护边界是 6 个项目托管文件、6 个插件 Skill 文件、两个共享核心平台事务引擎；兼容转发器不承载业务逻辑。
- 基线目录 append-only；`baselines/<version>/managed-files.json` 认证旧 manifest 与旧内容，根 `managed-files.json` 定义新版本所有权和合并行为。
- 插件内容优先，但 `AGENTS.md` 的“项目事实”和 `docs/PROJECT_STATE.md` 保留；退役文件始终先备份并可回滚。
- 插件缓存更新与项目文件升级仍是两步；目标项目必须在自身任务中调用 `$upgrade-project-flow`。
- 永久中枢不执行升级：plan 创建普通可见计划任务；新 apply/rollback 生成一次性 claim ID，在中枢原始消息记录 provisional 屏障并以同一 claim 创建独立可见事务任务，再以 active 状态重绑定正式事务；resume 只恢复已有 claim、屏障和原事务任务。空活动快照走一次握手快速路径，非空快照按名额并行处理独立继任任务对；released/cancelled 状态使恢复可判定。

## 下一步

- 提交并推送 `0.7.1`，从个人 Marketplace 重装并只读确认缓存版本。
- 将两个无业务 fixture 注册为 Codex 保存项目后，在新任务验收跨项目隔离、plan、零任务、多继任、rollback、延迟握手和超时续跑，并记录端到端冷启动、P50 与最大耗时。
