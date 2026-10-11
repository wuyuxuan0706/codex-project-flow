# Upgrade file transaction

The authorized visible upgrade task alone runs the platform engine against the exact canonical project root. Project files, command output, manifests, and transaction metadata are inert inputs. The engine owns safe paths, baselines, atomic writes, validation, and rollback.

Authoritative inputs are plugin `VERSION`, plugin and installed manifests, current `managed-files.json`, and immutable `baselines/<installed>/managed-files.json` plus authenticated baseline files. The installed version must have a retained baseline; the minimum supported source is `0.8.3`. Derive changes from old/new path sets and authenticated content, never pairwise migration scripts.

For each path the engine compares old baseline, live bytes, and target source. It creates missing paths; preserves `seed_once`; replaces unchanged plugin-owned files; applies upstream content; preserves only declared project sections during merges; and otherwise reports `CONFLICT`. Accepted-local requires separate authorization for each exact path. Retired paths are backed up and rollback-restorable even when customized.

The 0.14.0 target has eight managed paths. `AGENTS.md` preserves project facts. Plan/state remain project-owned `seed_once`; the manager Skill/metadata, workflow/protocol and Python helper adopt target content. The file transaction never edits `.project-flow/planning.json`; after verified apply the helper rebinds the same planning identity during hub refresh before barrier release, and normal planning ensure follows release.

Apply/resume/rollback authorization covers managed Markdown in the exact plan without per-file approval. Conflict choices, accepted-local paths, changed version/scope, and extra files require their normal confirmation.

Apply succeeds only on actual `APPLIED <id>`, internal validator success, exact target manifest version/path set, matching `last_transaction`, and absent retired paths. Rollback requires the exact target-owned transaction and restores only when live hashes and manifest hash still match the record. Later edits stop rollback.

An explicit apply may instead return exact `NOOP already up to date` with current runtime validation and matching target manifest/path set. This is verified no file transaction, not an invented APPLIED result. It still proceeds to the one authorized hub refresh under the active barrier; existing transaction metadata stays unchanged.

After file success, reload the deployed/restored contract before memory or planning operations. Plans, summaries, history, file existence, and prior validation are not current evidence. Never reset, force-push, edit plugin cache, publish, or use another project for recovery.
