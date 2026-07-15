# Document contracts

Use the paths configured in `.agents/workflow.json`; the filenames below are default role names. Preserve useful existing project content when normalizing a document.

## Contents

1. Project state
2. Module index
3. Current task
4. Risks
5. Decisions
6. Periodic log

## Project state

Purpose: communicate the stable project goal, current stage, major delivered capabilities, current blockers, and one primary direction. Keep implementation details in module docs.

Required sections:

```md
# Project state
## Current stage
## Implemented capabilities
## Current blockers
## Primary direction
```

## Module index

Purpose: route future work to actual modules without assuming a language or folder convention.

Recommended columns:

```md
| Path | Responsibility | Main entry points / manifests | Read when |
```

Build it from existing paths, local `AGENTS.md`, README files, build/package manifests, deployment configuration, and test entry points. Exclude generated outputs and dependency caches.

## Current task

Purpose: define the smallest authorized work unit and its evidence state. Do not silently replace the user's direction.

Required sections:

```md
# Current task
## Name
## Goal
## Scope
## Acceptance criteria
## Status
## Evidence and blockers
## Documents to update
```

If the task is missing or still contains placeholder text, do not start development. Ask for a concrete task unless `task_policy.source` grants explicit issue/milestone or autonomous derivation authority.

## Risks

Purpose: track real conditions that can affect delivery, safety, correctness, or verification.

Recommended columns:

```md
| ID | Risk / blocker | Impact | Evidence | Status | Mitigation / next action |
```

Do not list generic anxieties without project evidence. Close or supersede entries instead of deleting history when that history remains useful.

## Decisions

Purpose: preserve choices that constrain later implementation.

Recommended columns:

```md
| ID | Date | Decision | Reason | Scope | Status / review condition |
```

Record decisions, not unresolved options. Put unresolved choices in the task or risk document.

## Periodic log

Purpose: summarize outcomes for the configured period. Do not duplicate a low-level development log.

Required sections:

```md
# Periodic work log
## <configured date range>
### Completed outcomes
### Period summary
### Next-period plan
```

Use the configured date format, time zone, schedule, and audience. Include incomplete or blocked work only when it materially affects the period summary, with its evidence state stated accurately.
