# Codex Project Flow

一套简洁、可移植的 Codex 项目协作模板。它把只读 Work、编号授权、单活动任务、证据分级和长期状态维护整理为可复制的规则、配置、提示词与文档骨架。

模板不绑定语言、框架、目录结构、设备或运行环境，可用于新项目，也可非破坏地安装到已有仓库。

## 模板内容

- `AGENTS.md`：通用协作边界、按需读取和证据规则。
- `.codex-plugin/plugin.json`：Codex 插件清单。
- `.agents/workflow.json`：规则、SOP、状态路径与授权策略。
- `.agents/prompts/00_project_hub.md`：已创建项目中枢任务内的运行提示。
- `.agents/prompts/08_result_handoff.md`：必要时的结果回传格式。
- `skills/bootstrap-project-flow/`：安装项目文件并创建或复用项目中枢任务的初始化 Skill。
- `.agents/skills/project-workflow-manager/`：只维护长期项目状态的 Skill。
- `.agents/snippets/AGENTS.integration.md`：已有根规则时的人工合并片段。
- `docs/PROJECT_STATE.md`：唯一动态项目状态。
- `templates/PROJECT_STATE.md`：安装到新项目时使用的空白初始状态，避免携带模板仓库自身进度。
- `docs/DEVELOPMENT_SOP.md`：从 Work、授权到证据收尾的执行规范。
- `docs/WORKFLOW_GUIDE.md`：日常使用说明。
- `scripts/`：安装与结构校验入口。

## 一键导入并创建项目中枢

安装本插件后，在目标项目的 Codex 新任务中调用 `$bootstrap-project-flow`。这是完整的初始化入口：它一步安装项目协作文件，并通过 Codex 桌面任务能力创建和固定用户可见的项目中枢任务，标题形如 `项目中枢 · 项目名`。中枢任务创建后加载 `.agents/prompts/00_project_hub.md`，进入运行态。

串行重复调用时，Skill 先按项目标识与规范中枢标题复用已有任务；若任务已经创建但命名尚未完成，则通过首条启动消息中的中枢键找回同一任务，取消归档、补全标题并重新固定。只有两类匹配都不存在时才新建。若创建仍处于排队状态，应等待该任务出现在任务列表，不要再次启动 bootstrap。

插件安装或文件复制本身没有“安装完成后自动执行”的零点击钩子。应显式调用一次 `$bootstrap-project-flow`，不要把打开仓库、复制目录或安装插件本体误认为已经创建了项目中枢任务。

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

安装器默认跳过目标项目中的已有文件，不覆盖现有内容。目标项目已有根 `AGENTS.md` 时，安装后人工合并 `.agents/snippets/AGENTS.integration.md`。

确实需要覆盖时，使用 PowerShell 的 `-Force` 或 shell 的 `--force`。被替换的文件会先备份到目标项目的 `.project-flow-backup/<timestamp>/`。

这些脚本以及直接复制模板只能安装文件，不能调用 Codex 桌面的任务 API，因此不会创建或复用用户可见的项目中枢任务。需要完整的一键流程时，在 Codex 中调用 `$bootstrap-project-flow`。

## 定制点

安装后至少完成以下定制：

1. 在 `AGENTS.md` 填写少量稳定的项目事实，并补充项目特有的安全边界。
2. 如项目使用不同路径，调整 `.agents/workflow.json` 中的规则、SOP 和状态路径。
3. 在 `docs/DEVELOPMENT_SOP.md` 补充实际构建、测试和外部操作约束。
4. 初始化 `docs/PROJECT_STATE.md` 的四个章节。
5. 如已有更具体的根规则，人工合并集成片段，保留原项目更严格的约束。

## 项目中枢

创建完成后，项目中枢任务本身就是日常入口；`.agents/prompts/00_project_hub.md` 是该任务内的运行提示，不是初始化器。中枢不得调用 bootstrap、派生另一个中枢或因开始后续工作而重复创建中枢。

中枢先进入只读 Work，确认目标、范围、不做项、环境和验收标准，再把修改、检查、构建、测试、文档同步、提交与推送拆成独立编号项。

只有用户选中的编号项可以执行。中枢本身不计入执行任务名额；默认最多维护一个由中枢协调的用户可见后续活动执行任务，阻塞和等待仍占用该名额。若当前产品具备任务管理能力，中枢使用它维护该执行任务；若不具备，则在当前中枢任务继续并如实说明。

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

## 设计原则

- 用户决定任务方向和执行授权。
- Work 只读；各类执行动作分别授权。
- 中枢持续作为协调入口，一次只维护一个后续用户可见活动执行任务。
- 范围、接口、环境或验收变化时回到 Work。
- “文档确认”“静态检查”“实际构建或测试”“外部回传”分别记录。
- 安装默认非破坏；强制覆盖前自动备份。
