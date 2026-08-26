# Upgrade contract

## Modes and durable state

The default mode and `--plan`/`-Plan` are read-only. `--apply`/`-Apply` may mutate the target only after the complete plan is known. `--rollback <transaction>`/`-Rollback <transaction>` restores one exact transaction.

An ordinary deployed project must have `.project-flow/manifest.json`. A legacy project without it is eligible only when the caller explicitly supplies `--adopt-from 0.2.0` or `-AdoptFrom 0.2.0`. Adoption derives the project name from the installed workflow configuration, compares against the immutable 0.2.0 baseline, and writes the first manifest only as the final step of a successful apply.

When the installed version differs from the destination, the upgrader requires the exact single-hop descriptor `migrations/<installed>-to-<destination>.json` and the immutable `baselines/<installed>/` tree. The descriptor identifies introduced paths; all other managed paths must have an old-version baseline. Descriptors are not chained implicitly.

The manifest owns the installed workflow version, project name, and normalized baseline hash for each managed path. Text hashes are SHA-256 over UTF-8 text after removing one BOM and normalizing CRLF or CR to LF.

The filesystem upgrader owns only the file transaction. The Codex upgrade coordinator owns the current-project identity gate, user-visible task creation barrier, active-task snapshot, exact transaction binding, successor mapping, and raw-message version handshakes described by `.agents/prompts/10_upgrade_coordination.md`. The target must be the saved local project that owns the invoking task; a named path to another project is not authorization to read, coordinate, or mutate it. Do not create a project marker, lock, or registry file that pretends to replace Codex task identity. A file transaction may complete before task reconciliation; the coordination barrier remains active until the hub and every required successor acknowledge that exact transaction and destination version. An empty active-task snapshot may release immediately after the executor succeeds and the hub's raw handshake is valid.

## B/L/N decisions

For each path, `B` is the rendered baseline from the installed version, `L` is the live target, and `N` is the rendered source in the plugin being applied.

A file introduced by the destination version intentionally has no `B`. If `L` is missing it is created; if `L == N` it is a no-op; if a different live file already occupies that path it is staged as a conflict. Never fabricate an old baseline for an introduced path.

- `seed_once`: create a missing file, otherwise preserve it. `docs/PROJECT_STATE.md` always has this policy and is never replaced by an upgrade or rollback from a transaction in which it was already present.
- `replace_if_unmodified`, `merge_manual`, and `structured_manual` retain their installed-baseline meaning. The additional ownership contract decides a true B/L/N double change: `plugin/upstream_wins` writes `N`; `mixed/preserve_markdown_sections` writes `N` with each declared project-owned H2 section copied from `L`; `project/preserve` keeps `L`.
- The current mixed-content contract applies only to the unique `AGENTS.md` H2 section named `项目事实`. Missing or duplicate protected headings fail closed. Local edits elsewhere in plugin-managed workflow files are workflow customizations and may be replaced by upstream after transaction backup.
- If `B == N`, preserve the local-only change. If `L == N`, use a no-op. These cases do not need automatic conflict resolution.

An introduced path intentionally has no `B`; a different file already present at that path is an unowned collision and remains a conflict even when the destination policy is upstream-wins. If any unresolved conflict exists, apply writes only `.project-flow/staging/<transaction>/conflicts/` bundles containing available `base`, `local`, and `upstream` copies plus a machine-readable plan. It does not modify live managed files or the manifest. Resolve and review conflicts in the live project, then explicitly accept each reviewed live result with `--apply --accept-local <path>` or `-Apply -AcceptLocal <path>`. Acceptance never writes that live file; it records the destination baseline so a manually merged or deliberately retained local result does not conflict forever. An accepted path must be a current unresolved conflict, is recorded in the transaction, and is restored with the rest of the transaction on rollback. Do not edit a conflict bundle and assume it was applied, and never accept an unreviewed path merely to bypass the stop.

## Transaction guarantees

Before changing live files, apply backs up every existing managed file and the prior manifest under `.project-flow/transactions/<transaction>/`. Writes use temporary siblings followed by atomic replacement. The manifest is written last. The repository validator runs after that write; validation failure triggers automatic rollback.

Rollback accepts only an exact safe transaction identifier, restores backed-up files, removes files that transaction created, restores the previous manifest state, and marks the transaction rolled back. A repeated successful apply whose `L` already equals `N` returns `NOOP` without creating a transaction.

Task coordination is compensating rather than atomically rollbackable. If a file rollback occurs after successor creation, stop the affected tasks at safe points, keep the task-creation barrier active, and coordinate explicit handoffs back to a compatible task generation. Never describe archived tasks, messages, or task history as rolled back by the filesystem transaction.

Handshake evidence comes only from the literal first line of an original `agentMessage.text` read from the exact known thread. Task summaries, previews, titles, reasoning summaries, tool output, transformed text, truncation, and prompt echoes are not evidence. A successor that completes without any `agentMessage` receives one same-thread follow-up; after a second empty completed turn it may be replaced by one generation-incremented compensating successor whose predecessor is the empty task. The compensating successor is the final attempt and never starts an unbounded retry chain.

The upgrader rejects absolute or escaping managed paths, symbolic links or reparse points in managed/control paths, non-file live targets, unsupported manifest schemas or versions, and mismatched baseline hashes. Do not work around these stops with manual copying.
