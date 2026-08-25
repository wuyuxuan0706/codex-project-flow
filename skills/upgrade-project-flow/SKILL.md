---
name: upgrade-project-flow
description: Safely plan, apply, or roll back codex-project-flow upgrades in an already initialized local project. Use for syncing deployed projects to a newer workflow release, adopting a legacy 0.2.0 installation, reviewing upgrade conflicts, or restoring an upgrade transaction.
---

# Upgrade Project Flow

Upgrade only an existing local `codex-project-flow` deployment. Default to a read-only plan. Require explicit user authorization immediately before `--apply` or `--rollback`; a request to upgrade or roll back a named target counts as authorization for that action, but does not authorize resolving manual conflicts.

## Run the deterministic upgrader

Resolve `pluginRoot` as `../..` from this skill directory, then use the platform script:

- POSIX plan: `sh <pluginRoot>/scripts/upgrade.sh --target <absolute-path>`
- POSIX apply: add `--apply`; use `--adopt-from 0.2.0` only for a confirmed legacy deployment without a manifest.
- Windows plan: `& <pluginRoot>\scripts\upgrade.ps1 -Target <absolute-path>`
- Windows apply: add `-Apply`; use `-AdoptFrom 0.2.0` only for a confirmed legacy deployment without a manifest.
- After manually merging or deliberately retaining a conflicted live file, accept only that reviewed path with `--apply --accept-local <relative-path>` or `-Apply -AcceptLocal <relative-path>`. Repeat the POSIX option for multiple paths; in PowerShell pass a string array to `-AcceptLocal`. This advances each accepted upstream baseline without overwriting current live content.
- Rollback requires the exact transaction ID printed by a prior apply.

Read [references/upgrade-contract.md](references/upgrade-contract.md) before applying, adopting, resolving conflicts, or rolling back. Never replace `docs/PROJECT_STATE.md`, bypass a conflict with force, edit the target manifest manually, or claim success unless the script and post-upgrade validator succeed.

A manifest-backed `0.3.0` project upgrades directly through the immutable `0.3.0` baseline and the `0.3.0-to-0.3.1` descriptor. Only a confirmed legacy project without a manifest uses the explicit `0.2.0` adoption flag; migrations are single-hop and are never chained implicitly.

Report the target, source and destination versions, mode, per-file plan summary, conflict staging path if any, transaction ID if created, validation result, and whether rollback occurred.
