# Codex Project Flow

一套可移植、可升级的 Codex 项目协作模板。每个项目有一个永久中枢、一个独立可见的规划聊天，以及最多五个占位执行身份。中枢只启动请求；规划聊天帮助用户逐步明确背景、目标和步骤；执行任务负责实施、验证、记忆同步、验收和归档。

当前源码版本为 `0.14.1`，机器契约为 schema 13，安装 manifest 包含八个受管路径。升级支持 `0.8.3`、`0.9.0`、`0.9.1`、`0.10.0`、`0.11.0`、`0.12.0`、`0.13.0` 和 `0.14.0` 八份保留基线。

## 快速使用

- 新项目：在 Codex 保存的本地项目中新建聊天，输入 `$bootstrap-project-flow`。当前聊天成为中枢，自动创建独立计划讨论聊天。
- 已安装旧版的项目：在项目中枢输入 `$upgrade-project-flow 应用新版，并更新项目中枢。`，确认本次升级范围后继续同一升级任务。
- 日常工作：在中枢提出新请求；执行聊天自动读取本地计划和状态，只有用户验收后才勾选相应步骤。
- 换聊天：在当前执行聊天说“保存后换个聊天继续”；暂时不做则说“保存后归档，先不继续”。只说“归档”时会先询问继续还是暂停。

0.14.1 修复 Windows bootstrap 锁释放：在保持独占句柄的情况下标记该文件删除，关闭句柄后才报告成功；身份校验、中枢替换阶段和退休确认仍是释放前提。未发布的新锁在创建或替换准备失败时也安全清理，避免遗留空锁。

0.14.0 的两项变化：新建聊天采用 Codex 默认模型设置；升级 apply 会交接到新中枢，确认新身份后归档旧中枢。项目计划、状态和规划身份保留，不要求重新制定计划。

## 包含内容

- `AGENTS.md`：通用协作、授权和失败关闭边界。
- `.agents/workflow.json`：schema 13 机器契约。
- `.agents/WORKFLOW_PROTOCOL.md`：中枢、规划、执行、续接、验收和升级步骤。
- `docs/PROJECT_PLAN.md`：用户确认的项目目标、总体进度和可勾选步骤。
- `docs/PROJECT_STATE.md`：当前步骤的上下文、决定、结果、验证、阻塞和待续事项。
- `.agents/skills/project-workflow-manager/`：双文件记忆维护 Skill 与 Python helper。
- `skills/`：Bootstrap 与 Upgrade Plugin Skill。
- `templates/`：新项目的 plan/state 初始模板。
- `managed-files.json` 与 `baselines/`：受管文件、所有权和历史认证基线。
- `scripts/project-flow.ps1`、`scripts/project-flow.sh`：PowerShell/POSIX 事务引擎。

`PROJECT_PLAN` 和 `PROJECT_STATE` 是项目内容，采用 `seed_once`；升级保留现有内容。项目事实也保留。其余插件托管内容采用目标版本。

## 安装 Plugin

克隆仓库不会自动注册 Plugin。每台设备需把稳定检出登记到个人 Marketplace 并安装：

```text
codex plugin add codex-project-flow@personal
```

安装或更新后新建任务，使 Codex 加载最新 `$bootstrap-project-flow` 和 `$upgrade-project-flow`。源码修改不会自动发布、部署到项目或更新 Plugin cache；这些动作需要单独授权和验证。

所有工作流创建的可见聊天省略 `model` 和 `thinking` 参数，采用 Codex 的默认模型设置；后续消息也不覆盖已有聊天设置。隐藏子代理省略 `model` 和 `reasoning_effort`，采用平台默认继承行为。工作流不按角色选择模型，不修改全局设置，也不会强行重设已有聊天的模型。

## 初始化项目

在目标保存项目的新任务中调用：

```text
$bootstrap-project-flow
```

一次初始化授权涵盖受管安装计划、当前任务认领永久中枢，以及自动创建或恢复一个独立规划聊天。默认不会创建一次性部署任务。中枢标题为：

```text
项目中枢 · <项目名>
```

Bootstrap 先用保存项目的精确路径和 opaque `projectId` 建立中枢。规划登记不存在时，它先证明任务列表完整、无升级屏障、名额未满且项目 ID/路径精确匹配；gate 关闭时不写 registry。gate 通过后才写入 `.project-flow/planning.json` 的持久 creating intent，并在同一连续动作中调用一次任务创建、立即绑定 real `threadId` 或 queued `clientThreadId`。begin 后结果未知时只恢复同一身份，绝不重建第二个规划聊天。

运行时状态：

- `.project-flow/hub.json`：永久中枢登记。
- `.project-flow/bootstrap.lock`：中枢认领、恢复和替换 owner 锁。
- `.project-flow/planning.json`：规划聊天 durable intent 与真实/queued 身份。
- `.project-flow/upgrade-hub.json`：升级中新中枢的唯一创建意图、绑定身份和交接进度。
- `.project-flow/manifest.json`：受管安装入口。

有效中枢和有效规划登记都走定向读取 fast path。只有登记缺损、锁恢复、身份歧义或确需创建规划聊天时才穷尽任务元数据。任务管理能力不完整、跨项目矛盾、多个候选、屏障或未知创建结果都失败关闭。

普通 Bootstrap 不替换已有中枢；用户明确授权当前任务替换精确旧中枢时，才走手动替换流程。升级 apply 则包含自动创建唯一新中枢的专用流程，详见“升级项目”。两种交接都使用 owner 锁与原始 registry token 的原子 CAS，核对新身份后按版本化退役标题、取消置顶、归档的顺序处理精确旧中枢，并保留规划身份与根 token。手动替换本身不升级项目文件。

## 规划聊天

规划聊天不是第二个中枢，也不执行项目工作。新计划或不完整计划会自动主动使用 `$grilling`，把规划建成有依赖关系的决策树。它允许用户从不完整想法开始，逐步讨论：

1. 项目背景与动机；
2. 希望达到的目标和边界；
3. 可以落地的步骤、顺序和验收含义。

每轮只处理当前依赖已经确定的 frontier：一次列出全部已可决定的问题，为每题给出建议，然后等待用户回答。依赖仍未解决的问题留到后续轮次。需要环境或代码事实时，规划聊天自行派出事实助手查询；事实助手只提供证据，不替用户作决定，查询下游问题暂缓，同轮其他 frontier 继续询问。

如果当前环境没有 `$grilling`，规划聊天先告知用户，再按项目协议内置的同一决策树、frontier、建议和轮次等待流程继续，不要求用户安装 Skill。事实代理不可用时，规划聊天自行做范围内的只读查证；仍不可得的事实作为未决节点保存，不转嫁给用户猜测。

每轮回答后都把未决决策树、问题与回答、事实结果和下一 frontier 保存到 `PROJECT_STATE`。规划聊天或其继任从这些未决节点继续，不重复已回答轮次。只有目标、包含范围、排除范围、验收标准和步骤全部明确，决策树 frontier 为空，且用户确认已形成共同理解后，才把候选 plan/state 与确认原文交给 helper `save-plan` 原子 CAS 写入。它保留已有稳定步骤 ID 和验收勾选、拒绝凭空新增勾选；hash 冲突必须重读合并。这个确认是目标/步骤确认，不是 Markdown 逐文件审批。

只有计划完整有效，且 `PROJECT_STATE` 或可信原始记录提供明确的人类确认依据时，才直接复用登记而跳过 grilling；若对应规划聊天已归档，默认保持归档。格式合法本身不算确认。已有内容有用但缺项或缺确认时，只精确恢复原规划聊天补问缺失项并请求确认，不强迫从头重做。规划聊天活跃或 queued 时占一个执行名额；它不会自动开始步骤、勾选步骤或创建执行任务。

规划聊天明确续接时，先把唯一 rotation 意图保存到 `PROJECT_STATE`，创建一个等待前任归档的后继，并把所得 real/queued 身份再次保存。随后 helper `planning-continue` 以根 creation token、精确前任和预期 generation 做 CAS，把唯一规划登记推进到后继并追加 lineage；`rotation-request` 必须使用 helper 按 registry project/current hub/root token/predecessor/下一 generation 严格计算的前任机器 `rotation.key` 首行，不能改写成用户描述。lineage 同时保存该代的 `hubThreadId`；hub rebind 后，旧交接按原 old-hub key 幂等恢复，新交接使用 current hub。登记与 STATE 都确认后才归档前任。queued 后继物化时由 `planning-resolve` 补入 real ID，保留 client ID 与整条 lineage。失败或结果未知只恢复同一次交接，不重复创建；Bootstrap/Upgrade 始终跟随登记中的当前代，不恢复已被续接的旧前任。

## 项目记忆

每个中枢、规划聊天、执行任务和升级任务启动时读取 `PROJECT_PLAN` 与 `PROJECT_STATE`。Python helper 的 `read` 读取两文件，`save` 用 CAS 更新 state，`save-plan` 在用户确认目标/步骤后原子写 plan/state，`accept` 在明确验收后原子勾选 plan 步骤并记录 state；它还独占规划登记操作。

记忆写入发生在有意义进展、用户验收、归档前和继任创建前。计划步骤只在用户明确验收对应结果时勾选；代码存在、历史验证和聊天摘要都不能代替验收。继任任务重读工作区并重新验证，历史结果只作为历史证据。

## 请求与执行

每个新请求：

1. 用户在永久中枢提出请求。
2. 中枢先生成 `requestId`，输出“理解”和“执行项”。
3. 用户确认后，中枢核对屏障、五名额和路径冲突，创建该请求当前唯一的可见执行任务。
4. 真实任务 ID 或 queued `clientThreadId` 一经建立，中枢退出该请求。
5. 执行任务读取项目记忆，完成范围确认、实施、文档更新、验证、记忆同步和验收。

规划聊天、active、blocked、waiting、queued 和 `awaiting_acceptance` 身份都占名额；永久中枢不占。独立且路径不重叠的请求可以并行，同一请求、路径重叠和升级文件事务保持串行。管理能力或身份不确定时停止，隐藏代理不替代用户可见任务。

范围、目标或验收标准变化时，当前执行任务输出新的理解和执行项并等待确认，不返回中枢。请求授权范围内可直接更新 Markdown，无完整草稿、哈希或逐文件批准门禁；冲突、范围扩大、提交、推送和外部操作仍分别授权。

## Continue、Pause 与验收

用户用自然语言要求归档时，执行任务区分三种语义：

- **continue**：先读取计划并保存 state；预留名额并创建同一请求、同一步骤的 generation+1 继任。路径冲突只排除本次精确前任，不排除其他任务；前任精确归档后，继任用原生等待与归档核对才执行。名额不足或等待超时时保留身份等待，不能超过五个占位或重复创建。
- **pause**：先保存，再归档当前任务；不创建继任，不视为验收。
- **含糊**：先保存，询问 continue 还是 pause；未澄清前不归档。

用户最终验收时，任务只同步明确映射的步骤；无映射请求只保存状态，不猜测勾选。随后清理该请求过时的待验收信息，所有保存成功后精确自归档，不为已完成请求创建继任或自动启动下一步骤。“验收后换聊天继续”未说明新工作时先问清。UI 原生归档没有可靠拦截钩子，也没有稳定的 80% 上下文阈值信号；系统不承诺在没有消息或可靠信号时自动保存，或避免所有上下文压缩。

同一请求仍只有一个“当前代”执行任务。允许的后继只为已明确 continue 的同一请求服务；旧的冲突残留身份若不可能继续，应按精确证据清理，不能与当前代并行工作。

## 升级项目

在目标项目永久中枢调用：

```text
$upgrade-project-flow
```

默认先产生只读 plan。用户追加 apply 授权后继续同一升级任务。apply/resume/rollback 在文件事务前发布 provisional 创建屏障，并穷尽同项目普通、置顶和归档元数据；除中枢和当前升级任务外，活动快照必须为空。

任何执行或规划身份仍占位时，升级任务立即以零文件事务停止：不强制归档、不推断验收、不创建继任。现有任务各自保存并完成、暂停或归档；随后用户继续原升级任务重新扫描。只有空快照才能推进 active 屏障和文件事务。

升级保留项目事实、`PROJECT_PLAN` 和 `PROJECT_STATE`。新文件按 `seed_once` 建立，未知步骤保持未勾选；现有计划完整且有明确人类确认依据时不重新讨论，缺项或缺确认时只补问必要内容。

apply 的中枢更新顺序：

1. 文件升级验证成功后，保存唯一创建意图，再创建一个加载新版规则的新中枢；升级任务本身不转成中枢。
2. 核对新中枢的真实身份、版本、登记、规范标题和置顶；屏障释放前，新中枢不派发项目工作。
3. 精确旧中枢改为退役标题、取消置顶并归档，原规划聊天重绑到新中枢，保留根 token、身份和续接链。
4. 交接完成并重新核对后才释放屏障，再按名额确保规划聊天。不自动开始下一项目步骤。

创建结果未知、排队或交接失败时保留原意图，只恢复同一次操作，不重复创建中枢。只读 plan 和 rollback 不更新中枢；明确 apply 即使文件已是最新版，也可以完成本次中枢刷新。已有占位任务仍须按前述空快照要求先自行结束或暂停，不由升级任务强制归档。

升级完成仍输出 `changes`、`verification`、`uncovered`、`risk` 并等待验收。屏障 released 只表示协调结束，不表示用户验收。rollback 必须使用精确目标项目事务 ID。

## 手动文件安装

只复制模板而不认领 Codex 中枢或规划聊天时可运行引擎：

```powershell
.\scripts\project-flow.ps1 install -Target ..\your-project -ProjectName "Your Project"
```

```sh
./scripts/project-flow.sh install --target ../your-project --project-name "Your Project"
```

脚本无法调用 Codex 任务 API，因此只处理文件。默认不覆盖未知内容；有效安装写入 manifest。`-Force` / `--force` 是显式重置，不可代替升级。

## 验证

```powershell
.\scripts\project-flow.ps1 validate -Target . -AllowPlaceholders
.\tests\test.ps1
```

```sh
./scripts/project-flow.sh validate --target . --allow-placeholders
./tests/test.sh
```

目标项目运行时校验使用 `-Runtime` / `--runtime`。跨平台差分用 `tests/test-parity.ps1 -RequirePosix`。校验只证明模板、事务和契约，不代替项目构建、真实 Codex 任务 API 验收或发布验证。

0.14.1 已通过本机 Windows 10 / PowerShell 7.6.5 完整回归，以及 0.14.0 基线的 PowerShell/Git Bash 跨引擎差分与互斥验证。记忆测试 21 项通过、1 项因 Windows 符号链接权限跳过；模型策略 5 项和中枢交接引擎集成 6 项通过。持续集成增加 Windows 与 Linux 回归。真实 Codex 模型选择、置顶和归档交接仍待实际使用验证；历史与本轮证据分别记录于 `docs/TEST_CASES.md`。
