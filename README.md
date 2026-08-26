# Codex Project Flow

一套简洁、可移植、可升级的 Codex 项目协作模板。它把只读 Work、编号授权、永久项目中枢、执行任务分代轮换、任务感知升级、证据分级和长期状态维护整理为可复制的规则、配置、提示词与文档骨架。

模板不绑定语言、框架、目录结构、设备或运行环境，可用于新项目，也可非破坏地安装到已有仓库。

## 模板内容

- `AGENTS.md`：通用协作边界、按需读取和证据规则。
- `.codex-plugin/plugin.json`：Codex 插件清单。
- `.agents/workflow.json`：规则、SOP、状态路径与授权策略。
- `.agents/prompts/00_project_hub.md`：已创建项目中枢任务内的运行提示。
- `.agents/prompts/08_result_handoff.md`：必要时的普通结果回传格式。
- `.agents/prompts/09_execution_handoff.md`：执行任务轮换时使用的结构化交接包。
- `.agents/prompts/10_upgrade_coordination.md`：升级事务屏障、任务快照、版本握手和自动继任协议。
- `skills/bootstrap-project-flow/`：安装项目文件并让当前任务认领或复用项目中枢的初始化 Skill。
- `skills/upgrade-project-flow/`：为已安装项目生成升级计划、处理冲突、应用升级或回滚的 Skill。
- `.agents/skills/project-workflow-manager/`：只维护长期项目状态的 Skill。
- `.agents/snippets/AGENTS.integration.md`：已有根规则时的人工合并片段。
- `docs/PROJECT_STATE.md`：唯一动态项目状态。
- `templates/PROJECT_STATE.md`：安装到新项目时使用的空白初始状态，避免携带模板仓库自身进度。
- `docs/DEVELOPMENT_SOP.md`：从 Work、授权到证据收尾的执行规范。
- `docs/WORKFLOW_GUIDE.md`：日常使用说明。
- `managed-files.json`：受管文件及升级策略。
- `baselines/`、`migrations/`：旧版基线与声明式迁移。
- `scripts/`：安装、升级与结构校验入口。

## 一键导入并创建项目中枢

安装本插件后，在目标项目的 Codex 新任务中调用 `$bootstrap-project-flow`。这是完整的初始化入口：它一步安装项目协作文件，并默认让发出部署命令的当前任务认领永久项目中枢，标题形如 `项目中枢 · 项目名`。认领完成后，当前任务加载 `.agents/prompts/00_project_hub.md` 并直接进入运行态，不再留下单独的一次性部署任务。

串行重复调用时，Skill 先按项目标识、规范中枢标题、旧版启动消息中的中枢键和认领中的临时身份复用已有任务，取消归档、补全标题并重新固定。已有中枢时不把当前任务改成第二个中枢。若历史原因产生多个候选，Skill 停止并让用户指定保留项；明确获准清理后，被淘汰任务会获得版本化退役标题、取消固定并归档，使其旧启动消息不再触发恢复。只有用户明确要求独立中枢模式时才新建任务；若创建仍处于排队状态，应等待该任务出现在任务列表，不要再次启动 bootstrap。

插件安装或文件复制本身没有“安装完成后自动执行”的零点击钩子。应显式调用一次 `$bootstrap-project-flow`，不要把打开仓库、复制目录或安装插件本体误认为已经创建了项目中枢任务。

### 首次安装 Plugin

克隆仓库只获得源码，不会自动把 Plugin 注册到 Codex。每台设备首次使用时，需要把稳定的仓库检出登记到默认个人 Marketplace，并安装一次 `codex-project-flow@personal`。推荐在 Codex 中让 `$plugin-creator` 完成登记和安装；个人 Marketplace 的插件源码入口应为 `~/plugins/codex-project-flow`，可将它链接到长期维护的仓库检出，避免维护两份源码。

安装成功后新建一个任务，使 Codex 重新加载 `$bootstrap-project-flow` 和 `$upgrade-project-flow`。Plugin 是设备级能力，不需要为每个项目重复安装；每个新项目仍需调用一次 bootstrap，已部署项目则在 Plugin 更新后按需调用 upgrade。开发中的 Plugin 源码发生变化时，应使用 `$plugin-creator` 的 cachebuster 与重新安装流程刷新 Codex 缓存，而不是手工修改 Marketplace 清单。

## 仅安装项目文件

如只需把模板文件安装到项目，可手动运行安装器。

PowerShell：

```powershell
.\scripts\install.ps1 -Target ..\your-project -ProjectName "Your Project"
```

POSIX shell：

```sh
./scripts/install.sh ../your-project "Your Project"
```

POSIX 安装与升级脚本默认调用 `python3`，也可通过 `PYTHON` 显式指定兼容的 Python 3 解释器；PowerShell 入口不依赖 Python。

安装器默认跳过目标项目中的已有文件，不覆盖现有内容，并为完整的新安装写入 `.project-flow/manifest.json`；写入或最终校验中途失败时恢复本次已经替换或创建的受管文件。若检测到没有清单但已经存在受管文件，安装器保留原有跳过行为，但不会把未知来源的内容静默纳管；应改用升级器并显式确认 `0.2.0` 基线。目标项目已有根 `AGENTS.md` 时，安装后人工合并 `.agents/snippets/AGENTS.integration.md`。

确实需要重置文件时，使用 PowerShell 的 `-Force` 或 shell 的 `--force`。被替换的文件会先备份到目标项目的 `.project-flow-backup/<timestamp>/`。`Force` 是显式重置，不是升级入口。

这些脚本以及直接复制模板只能安装文件，不能调用 Codex 桌面的任务 API，因此不会创建或复用用户可见的项目中枢任务。需要完整的一键流程时，在 Codex 中调用 `$bootstrap-project-flow`。

## 定制点

安装后至少完成以下定制：

1. 在 `AGENTS.md` 填写少量稳定的项目事实，并补充项目特有的安全边界。
2. 如项目使用不同路径，调整 `.agents/workflow.json` 中的规则、SOP 和状态路径。
3. 在 `docs/DEVELOPMENT_SOP.md` 补充实际构建、测试和外部操作约束。
4. 初始化 `docs/PROJECT_STATE.md` 的四个章节。
5. 如已有更具体的根规则，人工合并集成片段，保留原项目更严格的约束。

## 升级已部署项目

更新插件只会提供新版 Skill 和模板，不会自动改写此前复制到项目中的文件。在目标项目的新任务中调用 `$upgrade-project-flow`。计划模式只分析文件；明确应用后，当前任务成为临时、用户可见、只负责协调的升级协调器：

1. 默认只生成升级计划，不修改项目或 Codex 任务。
2. 计划和应用都只允许针对调用 Skill 的当前任务所属项目；项目 ID 或规范化工作目录不匹配时，在读取或操作其他项目前停止。应用前穷尽发现永久中枢和活动任务快照，激活普通任务创建屏障，再创建一个独立的用户可见升级执行任务。
3. 文件事务成功后，将升级器返回的精确事务 ID 绑定到中枢与继任握手；仍需继续的旧任务会在安全点交接、归档并自动创建新版继任。
4. 握手只从精确任务的原始 `agentMessage` 第一行验证，摘要、预览、标题、推理摘要、工具输出和提示回显无效。快照为空时，中枢原始握手成功后直接解除屏障；非空快照中的继任两次空响应后最多创建一个代次加一的补偿继任。
5. 只有中枢和全部必要继任完成精确版本握手后才解除屏障；身份不明、任务管理失败、版本或事务不匹配时保持失败关闭。
6. 受插件所有的工作流内容在本地与上游同时修改时自动采用新版；`AGENTS.md` 只保留其“项目事实”章节，其他工作流规则按新版更新。
7. `docs/PROJECT_STATE.md` 采用 `seed_once` 策略，升级永不覆盖；没有旧基线的新增路径如果已被其他内容占用，仍进入冲突暂存并停止。文件失败会回滚，但 Codex 任务历史只能通过补偿性交接恢复，不能声称被文件事务原子回滚。
8. `0.2.0`、`0.3.0`、`0.3.1`、`0.4.0` 和 `0.4.1` 项目分别通过对应不可变基线和显式单跳描述直接升级到 `0.4.2`，不会隐式串联迁移。

Shell 和 PowerShell 的具体参数由 Skill 按当前平台选择。不要用安装器的 `--force` 或 `-Force` 代替升级。

## 项目中枢

认领或复用完成后，项目中枢任务本身就是日常入口；`.agents/prompts/00_project_hub.md` 是该任务内的运行提示，不是初始化器。中枢不得调用 bootstrap、派生另一个中枢或因开始后续工作而重复创建中枢。

中枢先进入只读 Work，确认目标、范围、不做项、环境和验收标准，再把修改、检查、构建、测试、文档同步、提交与推送拆成独立编号项。

每个执行编号项都必须明确要求创建对应的用户可见活动执行任务；用户选择编号只授权中枢创建该任务，不授权中枢亲自执行。中枢本身不计入执行任务名额；中枢之外默认最多维护五个用户可见活动执行任务，阻塞、等待和排队中的任务仍各占一个名额。无冲突任务可以并行，高风险操作和外部操作仍串行。任务管理能力不可用、创建失败、创建结果无法继续管理或无法确认任务身份时，中枢停止并报告，禁止回退执行；隐藏子代理不得替代用户可见活动执行任务。

## 执行任务分代轮换

单个执行任务只承载一个里程碑或一轮聚焦的修改与验证。默认在第 6 个实质执行轮次评估上下文压力，最迟在第 10 个轮次到达安全点时轮换；里程碑完成、用户明确要求或模型无法可靠复述执行基线时也可提前触发。

自动轮换需要独立授权。前任任务先按 `.agents/prompts/09_execution_handoff.md` 生成交接包并由中枢确认；中枢为继任生成版本化 `rotationKey` 并放在首条用户消息第一行，再归档前任、创建继任。创建无 ID 失败时恢复前任；只返回排队 ID 时保留该键、等待且不重试，物化后按同项目首条用户消息中的完整键精确恢复唯一继任。继任任务必须重新读取规则、核对实际工作区，并把前任验证视为历史证据。范围、接口、环境或验收标准变化时不直接轮换，而是返回 Work 重新确认。

轮换交接属于短期运行状态，不写入 `docs/PROJECT_STATE.md`。使用独立 Git worktree 时，只有改动已形成经授权的可传递检查点，才可以切换到新的执行任务。

只有需要协调、要求用户选择或用户明确要求时，才使用 `.agents/prompts/08_result_handoff.md` 回传结果。

## 验证命令

校验模板仓库：

```powershell
.\scripts\validate.ps1 -Target . -AllowPlaceholders
```

```sh
ALLOW_PLACEHOLDERS=1 ./scripts/validate.sh .
```

安装到目标项目后：

```powershell
.\scripts\validate.ps1 -Target .
```

```sh
./scripts/validate.sh .
```

校验只确认模板结构和配置一致性，不替代项目自身的检查、构建或测试。发布前还应单独扫描项目专有名称、绝对路径、账号和凭据。

回归测试：

```powershell
.\tests\test.ps1
```

```sh
./tests/test.sh
```

## 设计原则

- 用户决定任务方向和执行授权。
- Work 只读；各类执行动作分别授权。
- 部署任务默认原地成为永久中枢；已有中枢优先复用。
- 中枢持续作为只读协调入口，一次最多维护五个后续用户可见活动执行任务，并在安全点分代轮换。
- 工作流升级只处理当前项目，使用临时协调器、任务创建屏障、原始消息事务握手、零活动任务快速路径和有界补偿继任。
- 范围、接口、环境或验收变化时回到 Work。
- “文档确认”“静态检查”“实际构建或测试”“外部回传”分别记录。
- 安装默认非破坏；升级按声明的所有权保护项目内容，并在事务备份后让插件内容采用新版。
