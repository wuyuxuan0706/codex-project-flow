# Upgrade coordination and recovery

The permanent hub creates the one approved upgrade task and then exits that request's control flow. The upgrade task owns request identity, transaction identity, barrier state, plan, mutation, validation, document review, recovery, final acceptance, and exact self-archival.

Require exhaustive ordinary, pinned, and archived task metadata listing plus targeted history reading, title mutation, visible creation, messaging, waiting, and archiving. Missing or unmanageable capability stops before barrier activation, or preserves an already active barrier.

## Contract routing

Immediately after task creation or continuation and before it claims transaction identity, activates a barrier, or starts apply/rollback, read the target-version contract from `pluginRoot`: `.agents/WORKFLOW_PROTOCOL.md`, `.agents/workflow.json`, and this reference. An old target project need not contain the new protocol. Do not enforce its deployed files as the new contract before the file operation succeeds. On resume, reuse the transaction-bound contract: plugin target before file success, deployed/restored target after success.

After verified apply, reread `AGENTS.md`, `.agents/workflow.json`, and `.agents/WORKFLOW_PROTOCOL.md` from the target project. After verified rollback, load the exact restored version's deployed rules and manifest paths. If the restored coordination contract cannot be loaded or safely reconciled, keep the barrier and report the completed rollback without role fallback.

## Claim, discovery, snapshot, and barrier

1. The request has one UUID `requestId`, one task whose first raw line exactly matches `upgrade.request_key`, and one stable `claimId` for apply/rollback. A queued `clientThreadId` occupies the only slot and must never be recreated or passed to ID-only tools. Resume accepts only one materialized same-project task with that exact raw request-key first line; never regenerate identities, reuse the hub as executor, or guess an ID.
2. The upgrade task generates the exact transaction key from trusted project, task, source/target version, and generation values, then activates and owns the barrier under that identity. Reuse request, claim, transaction, and barrier identities on resume.
3. Exhaust every metadata page for ordinary, pinned, and archived tasks. Find the unique permanent hub and snapshot every other same-project visible active, blocked, waiting, or queued task except the hub and transaction task.
4. Read history only for the transaction task, snapshot tasks, and candidates whose identity or status is ambiguous. Disable tool outputs. If metadata is incomplete or targeted reads cannot resolve ambiguity, fall back to complete history pagination for every same-project task returned by exhaustive metadata listing.
5. Require the activity snapshot to be empty before activating file mutation. Any snapshot task fails closed immediately: do not archive it, create or map a successor, activate the file transaction, or run the engine. Preserve the exact upgrade task and report the blocking task identities.
6. Each blocking task must finish and self-archive in its own chat. After the only execution slot becomes available, continue the same upgrade task, exhaust metadata again, and proceed only when the new snapshot is empty. Then bind the barrier to that empty snapshot, read `file-transaction.md`, run the selected engine command, and validate the result itself.

For apply, require actual `APPLIED <transaction>`, validator success, target manifest version/paths, and matching `last_transaction`. For rollback, require actual `ROLLED_BACK <transaction>`, validator success under the restored version, matching target-owned transaction metadata, and exact restored manifest/files. Preserve raw engine evidence and exact transaction identity.

## Document review

When the file plan contains Markdown writes, keep the same transaction task and active barrier while review is pending. Present every affected exact path and complete final plain-text draft before mutation, then wait for explicit user approval.

Bind approval to `requestId`, exact path, review round, source contract, and content SHA-256. A changed merge result, accepted-local decision, rendered value, source content, target path, or resume mismatch invalidates the affected approval and returns it to `draft_pending_review`. Review remains in the same task and never repeats a completed file transaction.

Document approval permits only the reviewed file content. It is independent of the empty-snapshot requirement, barrier release, and final request acceptance.

## Observe and reconcile

Use scan sizes, output settings, recovery limits, deadline, discovery mode, and transaction-task role from target-version `.agents/workflow.json`; use the raw-message evidence rule in the target-version protocol. A wait only signals wake-up. Before mutation, failure, or release, exhaust metadata again; expand to full history only when ambiguity or incomplete metadata requires it.

A nonempty snapshot is never reconciled by the upgrade task. Existing tasks remain untouched and finish under their own lifecycle. Waiting does not authorize mutation; after wake-up, the same upgrade task must rescan and prove empty occupancy before continuing.

Release the barrier only after the verified transaction and final exhaustive metadata scan both match the empty-snapshot contract. Barrier release proves only upgrade coordination completion. The task then reports `changes`, `verification`, `uncovered`, and `risk` and enters `awaiting_acceptance`.

Rejection stays in the same task and starts revised understanding/execution-item confirmation. Acceptance authorizes the task to archive itself. Only `success=true` with `archivedTaskId` equal to the current exact task marks `accepted_archived`; failure or ambiguity remains `awaiting_acceptance`. No completion report, rejection feedback, acceptance decision, or archival is routed through the hub.

## Resume or stop

At deadline, preserve the barrier and report request, operation, claim, transaction, blocking task identities, unresolved identities, real or queued IDs, and recovery counters. On resume, re-prove the project, recover the exact request task, barrier, manifest, and transaction, exhaust metadata without outputs, reuse valid identities and evidence, and continue only the unresolved stage. Never repeat a successful apply/rollback, regenerate identities or claims, infer evidence from summaries, archive a blocking task, create a successor, or release because time elapsed. Ambiguity, changed content, exhausted recovery, or unmanageable state stops fail-closed.
