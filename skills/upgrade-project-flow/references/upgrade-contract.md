# Upgrade contract

## Modes and durable state

The default mode and `--plan`/`-Plan` are read-only. `--apply`/`-Apply` may mutate the target only after the complete plan is known. `--rollback <transaction>`/`-Rollback <transaction>` restores one exact transaction.

An ordinary deployed project must have `.project-flow/manifest.json`. A legacy project without it is eligible only when the caller explicitly supplies `--adopt-from 0.2.0` or `-AdoptFrom 0.2.0`. Adoption derives the project name from the installed workflow configuration, compares against the immutable 0.2.0 baseline, and writes the first manifest only as the final step of a successful apply.

The manifest owns the installed workflow version, project name, and normalized baseline hash for each managed path. Text hashes are SHA-256 over UTF-8 text after removing one BOM and normalizing CRLF or CR to LF.

## B/L/N decisions

For each path, `B` is the rendered baseline from the installed version, `L` is the live target, and `N` is the rendered source in the plugin being applied.

A file introduced by the destination version intentionally has no `B`. If `L` is missing it is created; if `L == N` it is a no-op; if a different live file already occupies that path it is staged as a conflict. Never fabricate an old baseline for an introduced path.

- `seed_once`: create a missing file, otherwise preserve it. `docs/PROJECT_STATE.md` always has this policy and is never replaced by an upgrade or rollback from a transaction in which it was already present.
- `replace_if_unmodified`: replace only when `L == B` and `N != B`; create when missing; preserve a local-only change when `B == N`; stage a conflict when both local and upstream changed; treat `L == N` as a no-op.
- `merge_manual` and `structured_manual`: use the same safe B/L/N gate: replace only when the live file still equals `B`, preserve a local-only change, and stage a conflict when both sides changed. A conflict is always resolved manually; this conservative first version performs no automatic text or structured merge.

If any conflict exists, apply writes only `.project-flow/staging/<transaction>/conflicts/` bundles containing available `base`, `local`, and `upstream` copies plus a machine-readable plan. It does not modify live managed files or the manifest. Resolve and review conflicts in the live project, then explicitly accept each reviewed live result with `--apply --accept-local <path>` or `-Apply -AcceptLocal <path>`. Acceptance never writes that live file; it records the destination baseline so a manually merged or deliberately retained local result does not conflict forever. An accepted path must be a current conflict, is recorded in the transaction, and is restored with the rest of the transaction on rollback. Do not edit a conflict bundle and assume it was applied, and never accept an unreviewed path merely to bypass the stop.

## Transaction guarantees

Before changing live files, apply backs up every existing managed file and the prior manifest under `.project-flow/transactions/<transaction>/`. Writes use temporary siblings followed by atomic replacement. The manifest is written last. The repository validator runs after that write; validation failure triggers automatic rollback.

Rollback accepts only an exact safe transaction identifier, restores backed-up files, removes files that transaction created, restores the previous manifest state, and marks the transaction rolled back. A repeated successful apply whose `L` already equals `N` returns `NOOP` without creating a transaction.

The upgrader rejects absolute or escaping managed paths, symbolic links or reparse points in managed/control paths, non-file live targets, unsupported manifest schemas or versions, and mismatched baseline hashes. Do not work around these stops with manual copying.
