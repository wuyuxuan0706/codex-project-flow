# Upgrade coordination and recovery

The permanent hub creates the one approved upgrade task and then exits that request's control flow. The upgrade task owns request identity, transaction identity, barrier state, plan, mutation, validation, non-deployment document review, recovery, final acceptance, and exact self-archival.

Require exhaustive ordinary, pinned, and archived task metadata listing plus targeted history reading, title mutation, visible creation, messaging, waiting, and archiving. Missing or unmanageable capability stops before barrier activation, or preserves an already active barrier.

## Contract routing

Immediately after task creation or continuation and before it claims transaction identity, activates a barrier, or starts apply/rollback, read the target-version contract from `pluginRoot`: `.agents/WORKFLOW_PROTOCOL.md`, `.agents/workflow.json`, and this reference. An old target project need not contain the new protocol. Do not enforce its deployed files as the new contract before the file operation succeeds. On resume, reuse the transaction-bound contract: plugin target before file success, deployed/restored target after success.

After verified apply, reread `AGENTS.md`, `.agents/workflow.json`, and `.agents/WORKFLOW_PROTOCOL.md` from the target project. After verified rollback, load the exact restored version's deployed rules and manifest paths. If the restored coordination contract cannot be loaded or safely reconciled, keep the barrier and report the completed rollback without role fallback.

## Claim, discovery, snapshot, and barrier

1. The request has one UUID `requestId`, one task whose first raw line exactly matches `upgrade.request_key`, and one stable `claimId` for apply/rollback. A queued `clientThreadId` occupies one slot under the currently governing contract and must never be recreated or passed to ID-only tools. Resume accepts only one materialized same-project task with that exact raw request-key first line; never regenerate identities, reuse the hub as executor, or guess an ID.
2. The upgrade task generates the exact transaction key from trusted project, task, source/target version, and generation values, then publishes and owns the provisional barrier under that identity before taking the activity snapshot. The hub treats provisional and active barriers as a creation gate and materializes no new execution task until released or cancelled. Reuse request, claim, transaction, and barrier identities on resume.
3. With the provisional gate present, exhaust every metadata page for ordinary, pinned, and archived tasks. Find the unique permanent hub and snapshot every other same-project visible active, blocked, waiting, queued, or `awaiting_acceptance` task except the hub and transaction task.
4. Read history only for the transaction task, snapshot tasks, and candidates whose identity or status is ambiguous. Disable tool outputs. If metadata is incomplete or targeted reads cannot resolve ambiguity, fall back to complete history pagination for every same-project task returned by exhaustive metadata listing.
5. Require the activity snapshot to be empty before advancing the barrier to active and activating file mutation. Any snapshot task fails closed immediately: do not archive it, create or map a successor, activate the file transaction, or run the engine. Preserve the exact upgrade task and provisional barrier and report the blocking task identities.
6. Each blocking task may finish and self-archive in its own chat; the creation gate does not block those existing tasks. After every other occupied slot is released, continue the same upgrade task, exhaust metadata again, and proceed only when the new snapshot is empty. Then advance the barrier to active, bind it to that empty snapshot, read `file-transaction.md`, run the selected engine command, and validate the result itself.

For apply, require actual `APPLIED <transaction>`, validator success, target manifest version/paths, and matching `last_transaction`. For rollback, require actual `ROLLED_BACK <transaction>`, validator success under the restored version, matching target-owned transaction metadata, and exact restored manifest/files. Preserve raw engine evidence and exact transaction identity.

## Managed Markdown deployment exception

After the user authorizes apply, resume, or rollback and the empty snapshot is proved, the same transaction task may let the engine write managed Markdown in its exact transaction plan without presenting drafts or collecting per-file approval. Apply this source-version exception even when the installed target contract still contains the older general Markdown gate; otherwise that older rule would prevent deployment of the new contract.

The exception follows engine ownership and conflict policy and covers no extra path. Conflict decisions, accepted-local choices, changed scope/version, and non-managed Markdown remain separately confirmed. The exception does not relax the empty-snapshot requirement, barrier lifecycle, validation, or final request acceptance.

## Observe and reconcile

Use scan sizes, output settings, recovery limits, deadline, discovery mode, and transaction-task role from target-version `.agents/workflow.json`; use the raw-message evidence rule in the target-version protocol. A wait only signals wake-up. Before mutation, failure, or release, exhaust metadata again; expand to full history only when ambiguity or incomplete metadata requires it.

A nonempty snapshot is never reconciled by the upgrade task. Existing tasks remain untouched and finish under their own lifecycle. Waiting does not authorize mutation; after wake-up, the same upgrade task must rescan and prove empty occupancy before continuing.

Release the barrier only after the verified transaction and final exhaustive metadata scan both match the empty-snapshot contract. Cancel it only when mutation has not begun and the authorized operation is explicitly cancelled. The hub resumes materializing queued requests only after released/cancelled is visible. Barrier release proves only upgrade coordination completion. The task then reports `changes`, `verification`, `uncovered`, and `risk` and enters `awaiting_acceptance`.

Rejection stays in the same task and starts revised understanding/execution-item confirmation. Acceptance authorizes the task to archive itself. Only `success=true` with `archivedTaskId` equal to the current exact task marks `accepted_archived`; failure or ambiguity remains `awaiting_acceptance`. No completion report, rejection feedback, acceptance decision, or archival is routed through the hub.

## Resume or stop

At deadline, preserve the barrier and report request, operation, claim, transaction, blocking task identities, unresolved identities, real or queued IDs, and recovery counters. On resume, re-prove the project, recover the exact request task, barrier, manifest, and transaction, exhaust metadata without outputs, reuse valid identities and evidence, and continue only the unresolved stage. Never repeat a successful apply/rollback, regenerate identities or claims, infer evidence from summaries, archive a blocking task, create a successor, or release because time elapsed. Ambiguity, changed content, exhausted recovery, or unmanageable state stops fail-closed.
