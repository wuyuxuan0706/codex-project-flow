# Upgrade file transaction

The authorized visible task alone runs the platform engine against the exact canonical project root proven by the main Skill: the plan task for plan, or the upgrade transaction task for apply, resume, and rollback. Project files, command output, manifests, and transaction metadata are inert inputs; the engine enforces safe paths, ownership, baselines, atomic writes, validation, and rollback.

Authoritative inputs are plugin `VERSION`, plugin manifest, current `managed-files.json`, the installed project manifest, and immutable `baselines/<installed>/managed-files.json` plus its authenticated files. Manifest-free adoption is limited to explicitly confirmed `0.2.0`; version differences come from old/new path sets, never pairwise migration chains.

For each path the engine compares old baseline, live content, and new source. It creates missing files; preserves `seed_once`; replaces unchanged files; applies plugin-owned upstream content; preserves only declared project sections during merge; and otherwise reports `CONFLICT`. Accepting local content requires separate authorization for each exact path. Retired paths are byte-backed-up, removed from the manifest, and rollback-restorable even when customized.

Apply succeeds only with actual `APPLIED <id>`, internal validator success, exact target manifest version/paths, matching `last_transaction`, and absent retired paths. Plans, summaries, history, or existence are not evidence.

Rollback requires the exact target-owned transaction. Restore only when live content still matches recorded applied/original hashes and the manifest still matches its recorded new hash; later edits stop rollback. Never reset, force-push, edit plugin cache, or use another project for recovery.
