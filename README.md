# Codex Project Flow

一套简洁、可移植、可升级的 Codex 项目协作模板。它把只读 Work、编号授权、永久项目中枢、执行任务分代轮换、任务感知升级、证据分级和长期状态维护整理为可复制的规则、配置、提示词与文档骨架。

模板不绑定语言、框架、目录结构、设备或运行环境，可用于新项目，也可非破坏地安装到已有仓库。

## 模板内容

- `AGENTS.md`：通用协作边界、按需读取和证据规则。
- `.codex-plugin/plugin.json`：Codex 插件清单。
- `.agents/workflow.json`：schema 6 机器契约，只保存路径、安全开关、执行并发策略、精确数值和身份模板。
- `.agents/WORKFLOW_PROTOCOL.md`：统一的中枢、执行轮换、升级协调与结果回传协议。
- `skills/`：两个插件 Skill 共 6 个文件；Bootstrap 为元数据优先的单一状态机，Upgrade 按协调与文件事务两类信息加载契约。
- `.agents/skills/project-workflow-manager/`：只维护长期项目状态的 Skill。
- `docs/PROJECT_STATE.md`：唯一动态项目状态。
- `templates/PROJECT_STATE.md`：安装到新项目时使用的空白初始状态，避免携带模板仓库自身进度。
- `managed-files.json`：受管文件及升级策略。
- `baselines/`：每个旧版本的不可变内容与托管元数据；升级差异由路径集合自动推导。
- `scripts/project-flow.ps1` 与 `scripts/project-flow.sh`：PowerShell/POSIX 两个平台共享核心事务引擎；旧命令入口保留为静默兼容转发器。

## 一键导入并创建项目中枢

安装本插件后，在目标项目的 Codex 新任务中调用 `$bootstrap-project-flow`。这是完整的初始化入口：它一步安装项目协作文件，并默认让发出部署命令的当前任务认领永久项目中枢，标题形如 `项目中枢 · 项目名`。认领完成后，当前任务加载 `.agents/WORKFLOW_PROTOCOL.md` 并直接进入运行态，不再留下单独的一次性部署任务。

重复调用时，Skill 穷尽普通、固定和已归档任务的元数据，优先按精确项目标识与标题身份恢复已有中枢，只对匹配候选读取历史；无标题、矛盾或元数据不完整时才扩大历史读取。已有中枢时不把当前任务改成第二个中枢。若历史原因产生多个候选或强信号矛盾，Skill 停止并让用户指定保留项；明确获准清理后，被淘汰任务会获得版本化退役标题、取消固定并归档。只有用户明确要求独立中枢模式时才新建任务；若创建仍处于排队状态，应等待该任务出现在任务列表，不要再次启动 bootstrap。

插件安装或文件复制本身没有“安装完成后自动执行”的零点击钩子。应显式调用一次 `$bootstrap-project-flow`，不要把打开仓库、复制目录或安装插件本体误认为已经创建了项目中枢任务。

### 首次安装 Plugin

克隆仓库只获得源码，不会自动把 Plugin 注册到 Codex。每台设备首次使用时，需要把稳定的仓库检出登记到默认个人 Marketplace，并安装一次 `codex-project-flow@personal`。推荐在 Codex 中让 `$plugin-creator` 完成登记和安装；个人 Marketplace 的插件源码入口应为 `~/plugins/codex-project-flow`，可将它链接到长期维护的仓库检出，避免维护两份源码。

安装成功后新建一个任务，使 Codex 重新加载 `$bootstrap-project-flow` 和 `$upgrade-project-flow`。Plugin 是设备级能力，不需要为每个项目重复安装；每个新项目仍需调用一次 bootstrap，已部署项目则在 Plugin 更新后按需调用 upgrade。开发中的 Plugin 源码发生变化时，应使用 `$plugin-creator` 的 cachebuster 与重新安装流程刷新 Codex 缓存，而不是手工修改 Marketplace 清单。

## 仅安装项目文件

如只需把模板文件安装到项目，可手动运行安装器。

PowerShell：

```powershell
.\scripts\project-flow.ps1 install -Target ..\your-project -ProjectName "Your Project"
```

POSIX shell：

```sh
./scripts/project-flow.sh install --target ../your-project --project-name "Your Project"
```

POSIX 安装与升级脚本默认调用 `python3`，也可通过 `PYTHON` 显式指定兼容的 Python 3 解释器；PowerShell 入口不依赖 Python。

安装器默认跳过目标项目中的已有文件，不覆盖现有内容，并为完整的新安装写入 `.project-flow/manifest.json`；写入或最终校验中途失败时恢复本次已经替换或创建的受管文件。若检测到没有清单但已经存在受管文件，安装器保留原有跳过行为，但不会把未知来源的内容静默纳管；应改用升级器并显式确认 `0.2.0` 基线。目标项目已有根 `AGENTS.md` 时，人工把本模板的通用规则合并到原文件，并保留项目事实。

确实需要重置文件时，使用 PowerShell 的 `-Force` 或 shell 的 `--force`。被替换的文件会先备份到目标项目的 `.project-flow-backup/<timestamp>/`。`Force` 是显式重置，不是升级入口。

这些脚本以及直接复制模板只能安装文件，不能调用 Codex 桌面的任务 API，因此不会创建或复用用户可见的项目中枢任务。需要完整的一键流程时，在 Codex 中调用 `$bootstrap-project-flow`。

## 定制点

安装后至少完成以下定制：

1. 在 `AGENTS.md` 填写少量稳定的项目事实，并补充项目特有的安全边界。
2. 如项目使用不同路径，调整 `.agents/workflow.json` 中的规则和状态路径。
3. 在更深目录的 `AGENTS.md` 补充模块特有的构建、测试和外部操作约束。
4. 初始化 `docs/PROJECT_STATE.md` 的四个章节。
5. 如已有更具体的根规则，保留项目事实和更严格的项目边界。

## 升级已部署项目

更新插件只提供新版 Skill 和模板；已部署项目仍需在目标项目的永久中枢调用 `$upgrade-project-flow`。默认 plan 只授权中枢创建一个普通可见计划任务，不启用升级屏障。新 apply/rollback 时，中枢先在自身原始消息记录临时屏障状态并阻止普通创建，再创建一个独立用户可见升级事务任务；resume 只恢复已有屏障和原事务任务。中枢本身不运行引擎，也不兼任该任务。

1. apply/rollback 前从 `pluginRoot` 读取目标版本契约，不要求旧项目预先存在新版协议；文件事务成功后才切换到目标项目中新部署或恢复的规则。
2. 事务任务按机器模板认领身份、生成事务键，取得中枢的 active 屏障原始消息，把临时屏障重绑定到正式事务，穷尽当前项目任务元数据，只读取相关历史并固定活动任务快照；它直接完成文件修改、内部验证或回滚。
3. 插件所有内容采用新版；`AGENTS.md` 仅保留“项目事实”，项目状态保持 `seed_once`，退役文件先备份并可回滚。
4. 文件成功后取得中枢原始握手。空快照经一次最终元数据扫描直接进入释放；非空快照按可用名额并行处理独立的前任→继任任务对，每对内部保持归档、创建、握手顺序。中枢记录 released 原始屏障消息后才真正解除屏障。
5. 每个历史版本只有一份不可变内容/元数据基线；路径差异直接推导新增与退役，不维护成对迁移链。

resume 从中枢原始屏障消息恢复状态，复用既有事务任务、文件事务和握手，只继续未决阶段。rollback 必须指定目标项目所属的精确事务 ID，并由独立可见升级事务任务完成；成功后切换到已恢复版本的契约。任何身份、任务管理、契约加载或协调恢复失败都会保留屏障并停止，不回退到中枢执行。

Shell 和 PowerShell 的具体参数由 Skill 按当前平台选择。不要用安装器的 `--force` 或 `-Force` 代替升级。

## 项目中枢

认领或复用完成后，项目中枢任务本身就是日常入口；`.agents/WORKFLOW_PROTOCOL.md` 是中枢、执行轮换和升级协调的统一运行协议，不是初始化器。中枢不得调用 bootstrap、派生另一个中枢或因开始后续工作而重复创建中枢。

中枢先进入只读 Work，再把修改、检查、构建、测试、文档同步、提交、推送、外部操作和轮换分别编号。用户选择编号只授权创建对应用户可见任务，不授权中枢执行；名额、占用和并行/串行策略读取机器契约。任务管理或身份失败时停止，禁止中枢或隐藏代理替代执行。

## 执行任务分代轮换

单个执行任务只承载一个里程碑或一轮聚焦工作，并在机器契约规定的轮次评估和安全轮换。

自动轮换需要独立授权。前任任务先按 `.agents/WORKFLOW_PROTOCOL.md` 的执行轮换章节生成交接包并由中枢确认；中枢为继任生成版本化 `rotationKey` 并放在首条用户消息第一行，再归档前任、创建继任。创建无 ID 失败时恢复前任；只返回排队 ID 时保留该键、等待且不重试，物化后按同项目首条用户消息中的完整键精确恢复唯一继任。继任任务必须重新读取规则、核对实际工作区，并把前任验证视为历史证据。范围、接口、环境或验收标准变化时不直接轮换，而是返回 Work 重新确认。

轮换交接属于短期运行状态，不写入 `docs/PROJECT_STATE.md`。使用独立 Git worktree 时，只有改动已形成经授权的可传递检查点，才可以切换到新的执行任务。

只有需要协调、要求用户选择或用户明确要求时，才使用 `.agents/WORKFLOW_PROTOCOL.md` 的结果回传格式。

## 验证命令

校验模板仓库：

```powershell
.\scripts\project-flow.ps1 validate -Target . -AllowPlaceholders
```

```sh
./scripts/project-flow.sh validate --target . --allow-placeholders
```

安装到目标项目后：

```powershell
.\scripts\project-flow.ps1 validate -Target .
```

```sh
./scripts/project-flow.sh validate --target .
```

校验只确认模板结构和配置一致性，不替代项目自身的检查、构建或测试。发布前还应单独扫描项目专有名称、绝对路径、账号和凭据。

回归测试：

```powershell
.\tests\test.ps1
```

```sh
./tests/test.sh
```

跨平台差分测试在同一历史 fixture 上分别运行 PowerShell 与 POSIX 的 plan、apply 和 rollback，并比较规范化动作、托管内容、manifest、事务稳定字段和回滚结果；它还验证两个引擎能互相识别对方持有的事务锁：

```powershell
.\tests\test-parity.ps1 -RequirePosix
```

默认基线为 `0.7.0`，可用 `-BaselineVersion` 选择其他已认证基线。未安装带可用 Python 3 的 Git Bash 时，不带 `-RequirePosix` 会明确报告 `SKIP`；发布和 CI 应使用该开关，把缺失运行环境视为失败，不能把跳过记录成通过。

所有实际写入路径共用 `.project-flow/transaction.lock` 的跨平台 OS 单写者锁；plan、validate 和 dry-run 保持只读且不创建锁。rollback 会在首次恢复前认证事务元数据和全部备份，并在逐文件恢复前复核 live/manifest 状态，任一损坏或竞态都失败关闭，不留下部分恢复。

## 设计原则

- 用户决定任务方向和执行授权。
- Work 只读；各类执行动作分别授权。
- 部署任务默认原地成为永久中枢；已有中枢优先复用。
- 中枢持续作为只读协调入口，按机器契约维护用户可见活动任务并在安全点分代轮换。
- 工作流升级只处理当前项目；plan 使用普通可见计划任务，apply/resume/rollback 使用一个独立可见升级事务任务、创建屏障、目标版本协议、原始消息握手和有界恢复。
- 范围、接口、环境或验收变化时回到 Work。
- “文档确认”“静态检查”“实际构建或测试”“外部回传”分别记录。
- 安装默认非破坏；升级按声明的所有权保护项目内容，并在事务备份后让插件内容采用新版。
