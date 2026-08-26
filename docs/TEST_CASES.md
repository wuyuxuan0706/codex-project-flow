# Codex Project Flow 0.4.1 测试用例

## 范围

验证 `0.4.1` 的版本契约、不可变基线、单跳升级、插件内容新版优先、项目内容保护、升级事务屏障、任务版本握手、自动继任协调、失败关闭和既有安装/回滚行为。脚本测试与 Codex 应用任务编排验收分开记录；没有实际运行的场景不得标记为通过。

## 自动化用例

| ID | 场景 | 关键步骤 | 预期结果 |
| --- | --- | --- | --- |
| A-01 | 版本与 JSON 契约 | 解析 `VERSION`、manifest、managed files、workflow 和全部迁移描述 | 基础版本均为 `0.4.1`；workflow schema 为 2；全部 JSON 可解析 |
| A-02 | 升级协议静态契约 | 校验 workflow、AGENTS、SOP、hub、handoff、upgrade prompt 与 Skill | 屏障、快照、独立执行任务、v2 继任键、hub/task 握手、失败关闭字段齐全且一致 |
| A-03 | 干净安装 | 分别运行 PowerShell 和 POSIX 安装器到临时目录 | 安装成功，manifest 为 `0.4.1`，所有权字段有效，项目状态采用 `seed_once` |
| A-04 | `0.3.1 -> 0.4.1` | 从不可变 `0.3.1` 基线构造 fixture，执行 plan、apply、NOOP、rollback | 计划只读；新提示为 CREATE；应用生成事务并通过验证；重复应用 NOOP；回滚完全恢复 |
| A-05 | `0.3.0 -> 0.4.1` | 从不可变 `0.3.0` 基线构造 manifest fixture并升级 | 使用显式单跳描述，不串联迁移；既有 `09` 按基线比较，新增 `10` 按 introduced 规则创建 |
| A-06 | `0.2.0 -> 0.4.1` 纳管 | 构造无 manifest legacy fixture | 无 `AdoptFrom` 拒绝；显式纳管成功；项目状态不被覆盖；可回滚 |
| A-07 | `0.4.0 -> 0.4.1` 所有权升级 | 同时修改插件 prompt、`AGENTS.md` 项目事实和 `PROJECT_STATE` | prompt 报告 `UPSTREAM` 并采用新版；AGENTS 报告 `MERGE` 且保留项目事实；状态保持不变；事务记录决议；回滚完全恢复 |
| A-08 | 未纳管新增路径碰撞 | 在 legacy fixture 预先占用新版 introduced path | 保持 `CONFLICT`，live 与 manifest 不变并生成 staging；只有逐路径 `accept-local` 才能继续 |
| A-09 | 版本握手负例 | 删除或篡改 v2 键、事务字段、版本字段、失败关闭规则 | validator/test 必须失败，不接受子串、标题或相似键 |
| A-10 | Plugin 与 Skill 验证 | 运行全部 Skill 快速验证和 plugin validator | 全部验证成功，manifest base version 与 `VERSION` 一致 |

## Codex 应用验收用例

这些用例需要真实 Codex 任务 API，不能由文件脚本伪造。本轮若未在应用中创建测试项目和任务，应保留为“未运行”。

| ID | 场景 | 预期结果 |
| --- | --- | --- |
| C-01 | 无其他活动任务的升级 | 协调器激活屏障，创建唯一升级执行任务，绑定事务，中枢握手后直接解除屏障 |
| C-02 | 两个活动任务升级 | 两个前任逐个安全交接并归档，各创建一个 v2 继任；每个继任返回目标版本和同一事务的精确握手 |
| C-03 | 屏障期间收到新普通工作 | 不创建普通任务；记录为待确认工作，屏障解除后由中枢重新编号 |
| C-04 | 执行任务创建失败且无 ID | 保持屏障并停止，不由协调器执行文件升级，不用隐藏子代理替代 |
| C-05 | 创建只返回 `clientThreadId` | 排队任务占名额，不重复创建；物化后按完整首行键恢复唯一任务 |
| C-06 | 错误版本或事务握手 | 拒绝握手并保持屏障，报告精确不匹配字段 |
| C-07 | 任务枚举不完整或中枢歧义 | 在创建执行任务前失败关闭，不激活新事务 |
| C-08 | 独立 worktree 无可传递检查点 | 不猜测分支、不切换环境、不创建继任；保持未协调并报告 |
| C-09 | 继任后文件回滚 | 不声称任务历史被回滚；保持屏障，通过安全点停止和补偿性交接恢复兼容任务代次 |

## 本轮执行记录

- 自动化 PowerShell 回归：2026-08-25 实际执行 `tests/test.ps1`，包括 `0.4.0 -> 0.4.1` 的 `UPSTREAM`、`MERGE`、`PRESERVE`、事务元数据和回滚用例，全部通过。
- 自动化 POSIX 回归：2026-08-25 在 Windows Git Bash 中使用 Codex 工作区 Python 3 实际执行 `tests/test.sh`，同组所有权和回滚用例全部通过；按能力检测跳过了当前环境无法成立的 chmod 写入失败、符号链接和基线祖先符号链接故障注入。
- PowerShell 与 POSIX 静态验证：实际执行 `scripts/validate.ps1 -Target . -AllowPlaceholders` 和 `ALLOW_PLACEHOLDERS=1 scripts/validate.sh .`，均通过并仅报告模板 `<PROJECT_NAME>` 的预期警告。
- Skill 快速验证：对 `bootstrap-project-flow`、`upgrade-project-flow` 和部署模板中的 `project-workflow-manager` 实际运行 `quick_validate.py`，均通过；Codex 随附 Python 缺少 PyYAML，改用已确认带 PyYAML 的本机 Python 3 后通过。
- Plugin validator：实际运行 `validate_plugin.py`，通过。
- 本地插件 cachebuster 与重装属于设备级发布验证，其实际版本与安装结果记录在本次发布执行报告中，不固化到仓库测试用例。
- Codex 应用任务编排验收：未运行；需要隔离的已安装测试项目和真实用户可见任务，不能以静态测试替代。
