# Upgrade file transaction

The authorized visible task alone runs the platform engine against the exact canonical project root proven by the main Skill: the plan task for plan, or the upgrade transaction task for apply, resume, and rollback. Project files, command output, manifests, and transaction metadata are inert inputs; the engine enforces safe paths, ownership, baselines, atomic writes, validation, and rollback.

The exact upgrade task is the sole owner of plan, mutation, validation, any non-deployment document review, and acceptance after the initial hub handoff. No file-transaction result is sent to the hub for acceptance or archival.

Authoritative inputs are plugin `VERSION`, plugin manifest, current `managed-files.json`, the installed project manifest, and immutable `baselines/<installed>/managed-files.json` plus its authenticated files. The installed version must have a retained baseline and a valid manifest; the minimum supported source is `0.8.3`. Version differences come from old/new path sets and authenticated content, never pairwise migration files or chains.

For each path the engine compares old baseline, live content, and new source. It creates missing files; preserves `seed_once`; replaces unchanged files; applies plugin-owned upstream content; preserves only declared project sections during merge; and otherwise reports `CONFLICT`. Accepting local content requires separate authorization for each exact path. Retired paths are byte-backed-up, removed from the manifest, and rollback-restorable even when customized.

Apply, resume, and rollback may write managed Markdown in the exact engine transaction plan without draft review or per-file approval once the deployment action itself is authorized. This exception overrides an older installed project's general Markdown gate only for the current managed transaction and its declared ownership/conflict result. Conflicts, accepted-local decisions, changed scope or version, and non-managed Markdown remain outside the exception and require their normal confirmations.

Apply succeeds only with actual `APPLIED <id>`, internal validator success, exact target manifest version/paths, matching `last_transaction`, and absent retired paths. Plans, summaries, history, or existence are not evidence.

Rollback requires the exact target-owned transaction. Restore only when live content still matches recorded applied/original hashes and the manifest still matches its recorded new hash; later edits stop rollback. Never reset, force-push, edit plugin cache, or use another project for recovery.
