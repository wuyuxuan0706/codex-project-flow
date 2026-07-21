# Codex Project Flow

一套可移植的 Codex 项目协作工作流。它把“先理解项目、只维护一个当前任务、基于证据更新状态、区分实现与验证、按需生成周报”整理成可复制的 `.agents`、`AGENTS.md` 和 `docs` 骨架。

它不绑定编程语言、构建系统、目录名称或硬件环境，适用于新项目，也可以非破坏地安装到已有仓库。

## 包含内容

- `.agents/skills/manage-project-workflow/`：项目状态维护技能。
- `.agents/prompts/`：熟悉项目、设置任务、开发、开发后同步和周报提示词。
- `.agents/workflow.json`：项目级路径和策略配置。
- `AGENTS.md`：可直接定制的通用协作规则。
- `docs/`：状态、模块索引、当前任务和周记录模板。
- `scripts/`：零第三方依赖的安装和校验脚本。

## 使用方式

### 方式一：把本仓库作为新项目模板

复制或克隆本仓库，删除本 README 中不需要的说明，然后填写：

1. `AGENTS.md` 的项目概况和环境约束。
2. `.agents/workflow.json` 的项目名、源码根目录和必读文件。
3. `docs/PROJECT_STATE.md` 与 `docs/MODULE_INDEX.md`。
4. `docs/NEXT_TASK.md` 中由用户指定的唯一当前任务。

### 方式二：安装到已有项目

Windows PowerShell 5.1+：

```powershell
.\scripts\install.ps1 -Target C:\path\to\project -ProjectName "My Project"
```

Linux/macOS：

```sh
./scripts/install.sh /path/to/project "My Project"
```

安装器默认跳过已有文件，不覆盖你的内容。已有根 `AGENTS.md` 时，可从新安装的 `.agents/snippets/AGENTS.integration.md` 人工合并通用规则。确实需要替换时使用 PowerShell 的 `-Force` 或 shell 的 `--force`；原文件会先备份到目标项目的 `.project-flow-backup/<timestamp>/`。

如果现有工程已经采用不同的状态文档路径，安装后调整 `.agents/workflow.json` 的 `paths.documents`，再运行校验；不要为了迎合模板移动原有工程文件。

## 日常入口

按需把 `.agents/prompts/` 中的提示词发送给 Codex：

1. `01_start_project.md`：只读熟悉工程。
2. `02_set_next_task.md`：把用户指定的任务写成唯一当前任务。
3. `03_develop_task.md`：围绕当前任务开发和验证。
4. `04_update_after_dev.md`：基于本轮证据同步状态文档。
5. `05_weekly_log.md`：生成偏结果的周记录。
6. `06_audit_workflow.md`：检查文档、状态和工程结构是否一致。

也可以直接调用 `$manage-project-workflow`。

## 校验

校验尚未渲染的模板仓库：

```powershell
.\scripts\validate.ps1 -Target . -AllowPlaceholders
```

```sh
ALLOW_PLACEHOLDERS=1 ./scripts/validate.sh .
```

安装到目标工程后，不应再残留项目名占位符：

```powershell
.\scripts\validate.ps1 -Target C:\path\to\project
```

```sh
./scripts/validate.sh /path/to/project
```

校验覆盖必需文件、JSON 配置、文档角色、必读路径、技能 frontmatter 和占位符。发布前还应单独扫描项目专有名称、绝对路径和凭据。

PowerShell 自测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test.ps1
```

## 设计原则

- 用户决定任务方向；工作流只负责整理和执行。
- 一次只维护一个最小工作单元。
- “已有实现”“已执行测试”“已通过验收”分别记录。
- 不把历史结果或计划当成本轮验证证据。
- 不假设 `src/`、`test/`、单体仓库或特定语言；模块结构由实际仓库发现。
- 安装默认非破坏，强制覆盖前自动备份。
