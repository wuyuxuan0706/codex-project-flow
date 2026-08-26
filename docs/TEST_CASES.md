# Codex Project Flow 0.4.2 测试用例

## 范围

验证 `0.4.2` 的版本契约、`0.4.1` 不可变基线、单跳升级、当前项目硬门槛、零活动任务快速路径、原始 `agentMessage` 握手、有界空响应继任恢复、项目内容保护、失败关闭和既有安装/回滚行为。脚本测试与 Codex 应用任务编排验收分开记录；没有实际运行的场景不得标记为通过。

## 自动化用例

| ID | 场景 | 关键步骤 | 预期结果 |
| --- | --- | --- | --- |
| A-01 | 版本与 JSON 契约 | 解析 `VERSION`、manifest、managed files、workflow 和全部迁移描述 | 基础版本均为 `0.4.2`；workflow schema 为 2；全部 JSON 可解析 |
| A-02 | 升级协议静态契约 | 校验 workflow、AGENTS、SOP、hub、upgrade prompt 与 Skill，并逐项篡改关键字段 | 当前项目门槛、原始消息握手、零任务快速路径、一次补发/一次补偿上限与失败关闭字段齐全；篡改后 validator 拒绝 |
| A-03 | 干净安装 | 分别运行 PowerShell 和 POSIX 安装器到临时目录 | 安装成功，manifest 为 `0.4.2`，所有权字段有效，项目状态采用 `seed_once` |
| A-04 | `0.4.1 -> 0.4.2` | 从新冻结的不可变 `0.4.1` 基线构造 fixture，执行 plan、apply、rollback | 计划只读且列出 workflow/prompt 替换；应用生成事务并通过验证；回滚完全恢复 |
| A-05 | `0.3.1 -> 0.4.2` | 从不可变 `0.3.1` 基线构造 fixture，执行 plan、apply、NOOP、rollback | 使用显式单跳描述；应用生成事务并通过验证；重复应用 NOOP；回滚完全恢复 |
| A-06 | `0.3.0 -> 0.4.2` | 从不可变 `0.3.0` 基线构造 manifest fixture并升级 | 使用显式单跳描述，不串联迁移；新增 `10` 按 introduced 规则创建 |
| A-07 | `0.2.0 -> 0.4.2` 纳管 | 构造无 manifest legacy fixture | 无 `AdoptFrom` 拒绝；显式纳管成功；项目状态不被覆盖；可回滚 |
| A-08 | `0.4.0 -> 0.4.2` 所有权升级 | 同时修改插件 prompt、`AGENTS.md` 项目事实和 `PROJECT_STATE` | prompt 报告 `UPSTREAM` 并采用新版；AGENTS 报告 `MERGE` 且保留项目事实；状态保持不变；事务记录决议；回滚完全恢复 |
| A-09 | 未纳管新增路径碰撞 | 在 legacy fixture 预先占用新版 introduced path | 保持 `CONFLICT`，live 与 manifest 不变并生成 staging；只有逐路径 `accept-local` 才能继续 |
| A-10 | 协调契约负例 | 篡改当前项目范围、握手证据源、快速路径或恢复上限 | PowerShell 与 POSIX validator/test 均拒绝 |
| A-11 | Plugin 与 Skill 验证 | 运行全部 Skill 快速验证和 plugin validator | 全部验证成功，manifest base version 与 `VERSION` 一致 |

## Codex 应用验收用例

这些用例需要真实 Codex 任务 API，不能由文件脚本伪造。本轮若未在应用中创建测试项目和任务，应保留为“未运行”。

| ID | 场景 | 预期结果 |
| --- | --- | --- |
| C-01 | 在其他项目调用并指定目标路径 | 在读取目标 manifest、枚举/管理目标任务或修改目标文件前停止，提示到目标项目新建任务 |
| C-02 | 无其他活动任务的升级 | 协调器激活屏障，创建唯一升级执行任务，绑定事务，从中枢原始 `agentMessage` 验证握手后直接解除屏障且不创建继任 |
| C-03 | 摘要包含正确握手但原始消息不匹配 | 拒绝摘要，只认精确任务的原始 `agentMessage` 第一行；已有有效原始消息时不重复请求 |
| C-04 | 继任首次空响应、补发后有效 | 只在同一继任补发一次，原始握手有效后完成，不创建补偿继任 |
| C-05 | 继任连续两次空响应 | 归档空响应继任，创建唯一代次加一补偿继任并记录完整链；补偿继任再失败时保持屏障且不继续创建 |
| C-06 | 两个活动任务升级 | 两个前任逐个安全交接并归档，各创建一个 v2 继任；每个继任返回目标版本和同一事务的原始消息握手 |
| C-07 | 屏障期间收到新普通工作 | 不创建普通任务；记录为待确认工作，屏障解除后由中枢重新编号 |
| C-08 | 执行任务创建失败且无 ID | 保持屏障并停止，不由协调器执行文件升级，不用隐藏子代理替代 |
| C-09 | 创建只返回 `clientThreadId` | 排队任务占名额，不重复创建；物化后按完整首行键恢复唯一任务 |
| C-10 | 错误版本或事务握手 | 拒绝握手并保持屏障，报告精确不匹配字段 |
| C-11 | 任务枚举不完整或中枢歧义 | 在创建执行任务前失败关闭，不激活新事务 |
| C-12 | 独立 worktree 无可传递检查点 | 不猜测分支、不切换环境、不创建继任；保持未协调并报告 |
| C-13 | 继任后文件回滚 | 不声称任务历史被回滚；保持屏障，通过安全点停止和补偿性交接恢复兼容任务代次 |

## 本轮执行记录

- 自动化 PowerShell 回归：2026-08-26 实际执行 `tests/test.ps1`，覆盖 `0.4.1 -> 0.4.2` 计划/应用/回滚、旧版单跳升级、NOOP、所有权合并、冲突暂存和协调契约负例，全部通过。
- 自动化 POSIX 回归：2026-08-26 在 Windows Git Bash 中显式使用 Codex 工作区 Python 3 执行 `tests/test.sh`，同组用例全部通过；按能力检测跳过当前环境无法成立的 chmod 写入失败、符号链接、备份符号链接与基线祖先符号链接故障注入。
- PowerShell 与 POSIX 静态验证：2026-08-26 实际执行 `scripts/validate.ps1 -Target . -AllowPlaceholders` 和 `ALLOW_PLACEHOLDERS=1 scripts/validate.sh .`，均通过并仅报告项目名称模板占位符的预期警告；首次 POSIX 尝试因系统商店 `python` 别名不可用而失败，指定已存在解释器后通过。
- Skill 快速验证：2026-08-26 对 `bootstrap-project-flow`、`upgrade-project-flow` 和部署模板中的 `project-workflow-manager` 实际运行 `quick_validate.py`，均通过。
- Plugin validator：2026-08-26 实际运行 `validate_plugin.py`，通过。
- 本地插件 cachebuster 与重装属于设备级发布验证，其实际版本与安装结果记录在本次发布执行报告中，不固化到仓库测试用例。
- Codex 应用任务编排验收：未运行；需要隔离的已安装测试项目和真实用户可见任务，不能以静态测试替代。
