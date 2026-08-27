# Codex Project Flow 0.7.1 测试用例

## 范围

验证 schema 6、6 文件部署集、6 个插件 Skill 文件、两个共享核心平台引擎、逐版本基线、旧项目协议路由、可靠退出码、事务回滚、项目内容保护和失败关闭。未实际运行不得标记通过。

## 自动化用例

| ID | 场景 | 预期结果 |
| --- | --- | --- |
| A-01 | 版本与 JSON | `VERSION`、manifest、workflow、根/历史 managed metadata 全部可解析且版本一致 |
| A-02 | 基线闭包 | 每份旧版元数据的路径集与目录文件精确一致，规范化内容哈希全部匹配 |
| A-03 | 干净安装 | 两平台引擎生成 schema 6、6 路径 manifest；历史退役路径不存在 |
| A-04 | 全旧版计划 | `0.2.0` 至 `0.7.0` 均从单份旧基线直接计划到 `0.7.1`，无需成对迁移文件 |
| A-05 | `0.6.0/0.7.0 -> 0.7.1` | 结构升级继续验证三个旧提示退役；补丁升级无路径退役；两者 apply 写入 6 路径 manifest 且 rollback 字节级恢复 |
| A-06 | 定制退役文件 | 本地修改过的旧提示仍按新版退役，rollback 恢复定制字节 |
| A-07 | legacy 纳管 | 无 manifest 的 `0.2.0` 默认拒绝，显式纳管后通过 |
| A-08 | schema 负例 | `max_active=1` 被 validator 拒绝 |
| A-09 | 机器协调契约 | 并行/串行策略、事务任务角色、带唯一 claim ID 的四态原始屏障模板、元数据优先发现、零任务快速路径、继任并行、事务键、观察与恢复上限由 validator 精确校验 |
| A-10 | 冲突扫描 | 托管规则中不存在回退中枢、隐藏代理替代或活动上限 1 |
| A-11 | Skill / Plugin | 三个 Skill 快速验证、6 文件边界与 plugin validator 通过 |
| A-12 | 引擎/兼容入口 | 两平台各只有一套共享核心和内部 validator；旧入口只转发且行为兼容 |
| A-13 | 退出码污染 | 预置非零 `$LASTEXITCODE` 后，成功 validate 与 NOOP upgrade 仍成功；真实失败返回非零 |
| A-14 | 旧项目协议路由 | apply/rollback 前读取 pluginRoot 目标契约；事务成功后才读取项目中新部署或恢复协议，resume 复用事务绑定契约 |
| A-15 | 四模式路由 | plan 只创建普通可见计划任务；apply 创建一个可见事务任务；resume 复用该任务和原事务；rollback 由精确授权的可见事务任务完成 |
| A-16 | 安装失败原子性 | manifest 写入后的最终验证失败会恢复全部托管文件并删除或恢复 manifest，预存退役文件保持不变 |
| A-17 | 并发写入屏障 | plan 后及 transaction 备份后的 live/manifest 变化均在写入前停止；外部改动保留，其他文件和事务目录无污染 |
| A-18 | 两平台校验对等 | workflow/manifest 项目名、占位符、非对象 JSON、Unicode Cc、事务 ID 与 manifest 哈希均按同一契约校验 |
| A-19 | 跨平台语义差分 | 同一已渲染历史 fixture 的 plan 动作集合、apply 后 managed 内容/manifest、transaction 稳定字段和 rollback 结果完全一致 |
| A-20 | 跨平台事务锁 | PowerShell 持锁时 POSIX apply 失败且项目零变化；Windows Python `msvcrt` 持锁时 PowerShell apply 同样失败；锁文件保持普通非空文件 |
| A-21 | 严格两阶段回滚 | 回滚在首次恢复前完成元数据、全部备份和 live/manifest 认证；后段备份损坏、元数据竞态或类型伪造均零恢复、零部分写入 |
| A-22 | 单写者生命周期 | install 实写、upgrade apply 与 rollback 共用持久 OS 锁；竞争者失败关闭，持锁进程终止后可重试；plan/validate/dry-run 不创建或占用锁 |
| A-23 | 速度机器契约 | 两平台 validator 同时拒绝分离角色、关闭零任务快速路径、非按需历史读取、非并行独立任务对或错误的对内顺序 |

## Codex 应用验收

| ID | 场景 | 预期结果 |
| --- | --- | --- |
| C-01 | 跨项目调用 | 读取或修改其他项目前停止，要求在目标项目任务中调用 |
| C-02 | 零活动任务 | 单一事务任务完成文件操作和验证，取得一次中枢原始握手并做一次最终元数据扫描；中枢记录 released 原始状态后解除屏障 |
| C-03 | 多活动任务 | 前任安全归档，一个 v2 继任对应一个前任，均确认同一事务 |
| C-04 | 延迟消息 | wait/摘要无效；已知任务原始首行出现后立即接受 |
| C-05 | 稳定空响应 | 三次同终止快照及 1/2 秒间隔后才补发；恢复次数有界 |
| C-06 | 60 秒到期 | 中枢保留 provisional/active 原始屏障状态；续跑复用 manifest、事务、身份和握手，不重做 apply |
| C-07 | 身份或管理失败 | 停止且不由中枢或隐藏代理执行文件工作 |
| C-08 | bootstrap 分支 | 普通、固定、归档任务元数据全部分页穷尽；唯一标题候选只读必要历史，无标题或歧义才扩大历史读取，并完成认领、恢复、清理或显式独立中枢 |
| C-09 | plan 角色 | 从永久中枢调用默认 plan，只创建一个普通可见计划执行任务；中枢不运行引擎且不启用升级屏障 |
| C-10 | rollback 角色 | 精确事务 rollback 创建或恢复一个可见事务任务；成功后切换恢复契约，失败或契约不可加载时保留屏障 |
| C-11 | 多任务速度 | 不同前任→继任任务对按可用名额并行；每一对仍严格先归档、再创建、再验证精确握手 |
| C-12 | 历史读取回退 | 完整元数据足以确定身份时不读取无关历史；缺字段、矛盾或身份歧义时扩大读取并最终失败关闭或唯一消歧 |

## 性能基线

2026-08-27 在当前 Windows 主机以新进程单轮实测，包含进程启动：PowerShell install `2444.8 ms`、plan `1808.4 ms`、apply `2669.4 ms`；Git Bash/POSIX install `692.3 ms`、plan `549.1 ms`、apply `862.1 ms`。这些结果证明文件引擎不是分钟级瓶颈，但不是其他设备的 SLA；C-02、C-08、C-11 和 C-12 必须在真实 Codex 可见任务中另行计时。

## 本轮执行记录

- 2026-08-27：`0.7.1` 发布门禁通过：PowerShell 与 Git Bash/POSIX 完整回归均通过，新增 `0.7.0 -> 0.7.1` plan/apply/validate/rollback 且补丁升级无路径退役；`0.7.0` 与 `0.6.0` 两组跨平台差分分别以 6/9 个规范化动作、6 个托管文件和双向事务锁通过。
- 2026-08-27：从实际已安装的 `0.7.0+codex.20260827071929` 缓存冻结 6 文件不可变 `0.7.0` 基线；23 个 JSON、三个 Skill 快速验证、plugin validator、冲突语义扫描和 `git diff --check` 通过。`$plugin-creator` 生成待发布版本 `0.7.1+codex.20260827102940`。
- 2026-08-26：21 个 JSON、PowerShell 解析、Git Bash `sh -n`、冲突/失效引用扫描、严格 schema 6 字段集和 `git diff --check` 通过。
- 2026-08-26：`tests/test.ps1` 与 Git Bash `tests/test.sh` 完整回归通过，覆盖全部历史计划、安装、NOOP、升级、回滚、定制退役、legacy 纳管、控制字符、包装器与 `$LASTEXITCODE` 污染。
- 2026-08-26：三个 Skill 快速验证、6 个插件 Skill 文件边界和 plugin validator 通过。
- 2026-08-27：两平台引擎内部无重复函数名、外部 validator 调用或分裂 POSIX heredoc；严格回滚预检和 OS 单写者锁保持跨平台对等，不用易过期的代码行数作为契约。
- 2026-08-26：`$plugin-creator` 生成 cachebuster 并从个人 Marketplace `personal` 重装；缓存版本 `0.7.0+codex.20260827071929` 只读核对通过。
- 2026-08-27：补回协调器/事务模板、执行并发策略及四模式可见任务路由；21 个 JSON、三个 Skill 快速验证、plugin validator、结构/冲突扫描和差异格式检查通过。
- 2026-08-27：PowerShell 与 POSIX 完整回归由根任务集成复跑通过；新增安装最终验证失败恢复、plan 后竞态、备份后竞态、占位符、非对象 JSON、Unicode Cc、精确 manifest 事务证据及跨平台命令/退出码覆盖。
- 2026-08-27：`tests/test-parity.ps1 -RequirePosix` 在 `0.6.0` 与追加的 `0.5.0` 同源 fixture 上通过，分别比较 9/10 个规范化动作、6 个托管文件及 manifest/事务/回滚契约；每次 PowerShell→POSIX 与 Python `msvcrt`→PowerShell 两个跨锁阻塞方向均通过。
- 2026-08-27：根任务最终集成复跑通过：PowerShell 与 POSIX 完整回归、POSIX 连续两轮确定性锁竞争、两份历史基线差分、21 个 JSON、PowerShell/Shell 解析、项目 validator、plugin validator 与 `git diff --check`；并发失败用例均确认项目零变化。
- 2026-08-27：速度优化后的 PowerShell/POSIX 完整回归、`0.5.0`/`0.6.0` 跨平台差分、21 个 JSON、三个 Skill 快速验证、plugin validator、机器契约负例和冲突扫描通过；独立前向推演确认默认 bootstrap、零活动升级、4 个并行继任及歧义失败关闭路径一致。真实 Codex 端到端时间仍归 C-01 至 C-12 验收。
- 2026-08-27：本轮未刷新 cachebuster、未重新安装插件，现有 Codex 缓存不能作为当前源码验证结果。
- Codex 应用验收 C-01 至 C-12 未运行：当前 Codex 未注册专用隔离保存项目，现有业务项目和源码父目录均不得作为替代；完成插件重装后需要先添加两个无业务内容的本地 fixture 项目，再新建真实用户可见任务执行。
