# Codex Project Flow

一套可移植、可升级的 Codex 项目协作模板。永久项目中枢只负责启动请求；最多五个用户可见执行任务可并行处理路径不重叠的独立请求，每个请求始终由唯一任务负责后续确认、实现、文档评审、完成验收和自归档。

模板不绑定语言、框架、目录结构或设备，既可用于新项目，也可非破坏地安装到已有仓库。

## 包含内容

- `AGENTS.md`：通用协作边界和证据规则。
- `.agents/workflow.json`：schema 11 机器契约。
- `.agents/WORKFLOW_PROTOCOL.md`：中枢、执行任务、升级和结果回传协议。
- `docs/INTERACTION_FLOW.md`：可共同修改的交互流程图。
- `docs/PROJECT_STATE.md`：唯一动态项目状态。
- `skills/`：Bootstrap 与 Upgrade 插件 Skill。
- `.agents/skills/project-workflow-manager/`：长期项目状态维护 Skill。
- `templates/PROJECT_STATE.md`：新项目的空白状态模板。
- `managed-files.json`：受管文件和升级策略。
- `baselines/`：受支持版本基线，最低版本为 `0.8.3`。
- `scripts/project-flow.ps1`、`scripts/project-flow.sh`：PowerShell/POSIX 事务引擎；旧入口仅作兼容转发。

## 安装 Plugin

克隆仓库只会取得源码，不会把 Plugin 注册到 Codex。每台设备首次使用时，应把稳定仓库检出登记到个人 Marketplace，并安装：

```text
codex-project-flow@personal
```

推荐让 `$plugin-creator` 完成登记、cachebuster 和安装。个人 Marketplace 的源码入口应为 `~/plugins/codex-project-flow`，可以链接到长期维护的仓库检出，避免维护两份源码。

安装或更新 Plugin 后新建任务，使 Codex 加载最新的 `$bootstrap-project-flow` 和 `$upgrade-project-flow`。Plugin 是设备级能力，每个项目只需单独执行 bootstrap。

## 初始化项目

在目标项目的新任务中调用：

```text
$bootstrap-project-flow
```

默认情况下，当前任务会安装项目文件并认领为永久项目中枢，标题为：

```text
项目中枢 · <项目名>
```

不会额外创建一次性部署任务。只有用户明确要求独立中枢时，才允许创建另一个任务；已有中枢只有在用户明确授权当前任务替换登记中的精确旧中枢时才能替换。

用户授权 Bootstrap 安装或恢复后，引擎可直接写入安装计划中的受管 Markdown，无需逐文件提交草稿或批准。该例外只覆盖引擎受管路径；未知文件、冲突、范围变化和额外 Markdown 修改仍按各自规则处理。

初始化状态保存在：

- `.project-flow/hub.json`：项目与真实中枢任务的登记。
- `.project-flow/bootstrap.lock`：认领、恢复和替换操作的 owner 锁。
- `.project-flow/manifest.json`：已安装受管文件的唯一项目入口。

正常重复调用只按登记的精确任务 ID 定向读取，不枚举所有任务。只有登记损坏、任务不可访问、陈旧锁或身份歧义等异常情况才进行完整发现。任何身份冲突、多个候选、锁竞争或不完整结果都失败关闭，不猜测任务 ID，也不创建替代中枢。

复制项目会形成新的项目路径和身份，不能复用来源项目的登记、锁或中枢任务。

## 手动安装项目文件

如果只需要复制模板文件，而不需要创建或认领 Codex 项目中枢，可直接运行引擎。

PowerShell：

```powershell
.\scripts\project-flow.ps1 install -Target ..\your-project -ProjectName "Your Project"
```

POSIX：

```sh
./scripts/project-flow.sh install --target ../your-project --project-name "Your Project"
```

POSIX 默认使用 `python3`，也可通过 `PYTHON` 指定兼容的 Python 3；PowerShell 入口不依赖 Python。

安装默认跳过目标项目已有文件，不覆盖未知内容。完整安装会写入 `.project-flow/manifest.json`；失败时恢复本次已创建或替换的受管文件。

已有受管文件但没有有效 manifest 的项目不会被静默纳管，也不能直接升级。应恢复 `0.8.3` 或更新版本的有效 manifest，或者执行干净安装。

需要显式重置时使用 PowerShell 的 `-Force` 或 POSIX 的 `--force`。被替换文件先备份到 `.project-flow-backup/<timestamp>/`。Force 是重置操作，不能代替升级。

手动脚本无法调用 Codex 任务接口，因此不会创建、复用或替换项目中枢。

## 交互模式

共享流程图位于 `docs/INTERACTION_FLOW.md`，机器约束位于 `.agents/workflow.json`，完整运行规则位于 `.agents/WORKFLOW_PROTOCOL.md`。

每个新请求按以下方式处理：

1. 用户在永久项目中枢下达任务。
2. 中枢生成唯一 `requestId`，输出初始理解和执行项。
3. 用户确认后，中枢在五个名额内为该请求创建唯一的用户可见执行任务；满额或目标路径重叠时先排队。
4. 一旦取得真实任务 ID 或 queued `clientThreadId`，中枢退出该请求。
5. 执行任务直接与用户完成范围确认、修改循环、实现、验证、文档评审和完成验收。
6. 用户否决结果时，原执行任务输出新理解和执行项，确认后继续原任务。
7. 用户最终同意后，执行任务精确归档自身；归档明确成功后请求结束。

同一请求的多模块、多文件、多轮修改和多种内部动作都留在同一执行任务。路径不重叠的独立请求可并行，总数最多五个；active、blocked、waiting、queued 和 `awaiting_acceptance` 都占名额。升级 provisional/active 创建屏障期间，中枢暂停物化新任务并保留排队，既有任务仍可完成和自归档。中枢不接收完成项、不转发修改意见，也不归档执行任务。

替代或轮换执行任务必须由用户在当前执行任务中明确授权，不能因失败恢复、上下文长度或升级自动触发。隐藏代理不能替代用户可见执行任务。

## 文档评审

除部署例外外，所有新建或修改的 Markdown 必须由当前执行任务先在聊天中提交：

- 精确目标路径；
- 完整纯文本草稿；
- 与批准内容绑定的内容哈希。

只有用户明确批准当前精确草稿后才能写入。否决、实质内容变化、路径变化或哈希变化都会使批准失效，原任务必须重新提交完整草稿。

批准只授权对应路径和内容，不授权覆盖未知文件、扩大任务范围或执行其他外部动作。写入后再次修改同一文档，需要开始新的评审轮次。

部署例外仅限 Bootstrap install/recovery 和 Upgrade apply/resume/rollback 通过引擎写入事务计划中的受管 Markdown。用户授权相应部署动作后无需逐文件草稿评审，即使目标项目仍部署旧版全局 Markdown 门禁也适用；冲突选择、accepted-local、范围或版本变化、非受管 Markdown 和最终验收仍需各自确认。

## 升级项目

Plugin 更新不会自动修改已部署项目。应在目标项目的永久中枢调用：

```text
$upgrade-project-flow
```

中枢只完成初始理解、执行项、首次授权和唯一升级任务创建。任务身份建立后，plan、apply、resume、rollback、屏障、非部署文档评审、验证、完成验收和自归档全部由该升级任务完成。

关键约束：

1. 同一升级请求始终复用同一用户可见任务。
2. apply、resume 或 rollback 文件事务前，活动任务快照必须为空。
3. 如果除中枢和当前升级任务外还存在 active、blocked、waiting、queued 或 `awaiting_acceptance` 任务，立即失败关闭：不写文件、不归档任务、不创建第二个任务。
4. 现有任务各自在原任务中结束；空闲后由原升级任务重新扫描并继续。
5. 升级任务先发布 provisional 创建屏障，再固定空快照；屏障为 provisional/active 时中枢不物化新任务，released/cancelled 后恢复。
6. 插件内容采用目标版本；`AGENTS.md` 保留项目事实，项目状态使用 `seed_once`。
7. 退役和替换文件先进入事务备份，失败可回滚。
8. 屏障释放后仍需输出完成项并等待用户验收；最终同意后升级任务自归档。
9. rollback 必须使用目标项目所属的精确事务 ID。
10. 不得用安装器的 `-Force` 或 `--force` 代替升级。

任何身份、契约、任务协调、备份认证或竞态检查失败都会保留可恢复证据并停止。

## 项目定制

安装后通常只需：

1. 在根 `AGENTS.md` 填写稳定的项目事实和项目特有边界。
2. 必要时调整 `.agents/workflow.json` 中的规则或状态路径。
3. 在更深目录的 `AGENTS.md` 增加模块专用约束。
4. 初始化 `docs/PROJECT_STATE.md`。
5. 保留已有项目中更具体或更严格的规则。

## 验证

完整审计模板仓库：

```powershell
.\scripts\project-flow.ps1 validate -Target . -AllowPlaceholders
```

```sh
./scripts/project-flow.sh validate --target . --allow-placeholders
```

校验目标项目已声明的运行时路径：

```powershell
.\scripts\project-flow.ps1 validate -Target . -Runtime
```

```sh
./scripts/project-flow.sh validate --target . --runtime
```

完整回归：

```powershell
.\tests\test.ps1
```

```sh
./tests/test.sh
```

跨平台差分测试：

```powershell
.\tests\test-parity.ps1 -RequirePosix
```

缺少带 Python 3 的 POSIX 环境时，未使用 `-RequirePosix` 会明确报告 `SKIP`；发布和 CI 应使用该开关。

校验只证明模板结构和契约一致，不替代项目自身的构建、测试或外部验收。发布前还应检查项目专有名称、绝对路径、账号和凭据。

所有文件写入共用 `.project-flow/transaction.lock` 的跨平台单写者锁。plan、validate 和 dry-run 保持只读；rollback 在恢复前认证事务元数据、备份和当前文件状态，发生损坏或竞态时失败关闭。
