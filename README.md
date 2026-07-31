# Codex Project Flow

一套简洁、可移植的 Codex 项目协作模板。它把只读 Work、编号授权、单活动任务、证据分级和长期状态维护整理为可复制的规则、配置、提示词与文档骨架。

模板不绑定语言、框架、目录结构、设备或运行环境，可用于新项目，也可非破坏地安装到已有仓库。

## 模板内容

- `AGENTS.md`：通用协作边界、按需读取和证据规则。
- `.agents/workflow.json`：规则、SOP、状态路径与授权策略。
- `.agents/prompts/00_project_hub.md`：项目中枢入口。
- `.agents/prompts/08_result_handoff.md`：必要时的结果回传格式。
- `.agents/skills/project-workflow-manager/`：只维护长期项目状态的 Skill。
- `.agents/snippets/AGENTS.integration.md`：已有根规则时的人工合并片段。
- `docs/PROJECT_STATE.md`：唯一动态项目状态。
- `docs/DEVELOPMENT_SOP.md`：从 Work、授权到证据收尾的执行规范。
- `docs/WORKFLOW_GUIDE.md`：日常使用说明。
- `scripts/`：安装与结构校验入口。

## 安装

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

## 定制点

安装后至少完成以下定制：

1. 在 `AGENTS.md` 填写少量稳定的项目事实，并补充项目特有的安全边界。
2. 如项目使用不同路径，调整 `.agents/workflow.json` 中的规则、SOP 和状态路径。
3. 在 `docs/DEVELOPMENT_SOP.md` 补充实际构建、测试和外部操作约束。
4. 初始化 `docs/PROJECT_STATE.md` 的四个章节。
5. 如已有更具体的根规则，人工合并集成片段，保留原项目更严格的约束。

## 项目中枢

将 `.agents/prompts/00_project_hub.md` 作为日常入口。中枢先进入只读 Work，确认目标、范围、不做项、环境和验收标准，再把修改、检查、构建、测试、文档同步、提交与推送拆成独立编号项。

只有用户选中的编号项可以执行。默认最多保留一个用户可见活动任务；阻塞和等待仍占槽。若当前产品具备任务管理能力，中枢使用它维护该任务；若不具备，则在当前会话继续并如实说明。

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
- 一次只维护一个用户可见活动任务。
- 范围、接口、环境或验收变化时回到 Work。
- “文档确认”“静态检查”“实际构建或测试”“外部回传”分别记录。
- 安装默认非破坏；强制覆盖前自动备份。
