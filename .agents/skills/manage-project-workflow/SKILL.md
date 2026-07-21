---
name: manage-project-workflow
description: Maintain project context, module index, one current task, evidence-based status, and periodic summaries across arbitrary repository structures. Use when Codex needs to onboard to a repository, set or refine the user-authorized next task, synchronize project records after development, prepare a weekly summary, or audit workflow consistency.
---

# Manage Project Workflow

## Read configuration first

1. Locate the nearest applicable `AGENTS.md` files from the repository root to the target path.
2. Read `.agents/workflow.json` and resolve document roles from `paths.documents`.
3. Read every enabled document in `required_context`.
4. If configuration or documents are missing, follow `missing_document_policy`; never invent project facts while initializing a file.
5. For a module task, discover and read its local rules, README, build/package manifests, interface docs, and test entry points.

Treat configured paths as defaults, not evidence that a directory exists. Discover the actual repository structure before naming modules or commands.

## Select the operation

- **Onboard**: read only; summarize the project stage, current task, main modules, blockers, and missing context.
- **Set task**: require a user-specified task or explicit authority to derive it from an issue/milestone. Keep no more than `task_policy.max_active_tasks` active tasks.
- **Develop**: change only the authorized task scope, run safe relevant checks, then apply the configured document synchronization rules.
- **Synchronize**: use the current turn baseline, unstaged diff, staged diff, untracked files, relevant commits, command output, and user-reported target results. Do not attribute unrelated dirty-worktree changes to the current task.
- **Periodic summary**: run only when requested or when the configured schedule is due; use the configured time zone and period.
- **Audit**: compare rules, configuration, documents, repository structure, and VCS evidence; report contradictions before editing them.

## Use evidence states precisely

- `not_started`: no implementation evidence.
- `in_progress`: authorized work has started but the acceptance criteria are not met.
- `implemented_not_verified`: implementation exists, but the required verification was not executed or is incomplete.
- `verified`: relevant verification actually ran and met the recorded criteria.
- `blocked`: progress depends on a stated external condition, decision, credential, environment, or failing prerequisite.
- `needs_confirmation`: available evidence is insufficient or conflicting.

Never convert a plan, checklist, code inspection, historical test, or another environment's result into current verification. Record user-reported results as user-reported evidence unless the current agent observed them directly.

## Synchronize by impact

- Update the current-task document when scope, status, acceptance evidence, blocker, or next action changes.
- Update project state only when the stage, main capability, primary blocker, or next direction changes.
- Update the module index when module ownership, major paths, or entry points change.
- Update the periodic log according to `sync_policy` and `schedule`; do not use it as a file-by-file development diary.

Read [references/document-contracts.md](references/document-contracts.md) before creating a missing workflow document or changing its section schema.

## Protect project integrity

- Preserve user changes and unrelated files; never reset or overwrite them to simplify the workflow.
- Do not move, delete, or reorganize project assets unless the task explicitly requires it.
- Do not operate remote systems, production services, devices, accounts, or external repositories without scope and authority.
- When VCS evidence is unavailable or ambiguous, say so and use `needs_confirmation`.
- Report each verification with location, exact command/action, result, and uncovered items.
- Keep the final report concise: outcome, changed files, verification, remaining uncertainty.
