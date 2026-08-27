# Upgrade coordination and recovery

The permanent hub creates or recovers one visible upgrade transaction task. That task is the transaction's visible coordinator-executor: it owns coordination and runs the file engine, without creating a separate coordinator or executor. The hub remains coordination-only. Require exhaustive ordinary, pinned, and archived task metadata listing plus targeted history reading, title mutation, visible creation, messaging, waiting, and archiving. Missing or unmanageable capability stops before barrier activation, or preserves an already active barrier.

## Contract routing

Immediately after transaction-task creation and before it claims identity, rebinds the provisional barrier, or starts apply/rollback, read the target-version contract from `pluginRoot`: `.agents/WORKFLOW_PROTOCOL.md`, `.agents/workflow.json`, and this reference. An old target project need not contain the new protocol. Do not enforce its deployed files as the new contract before the file operation succeeds. On resume, reuse the transaction-bound contract: plugin target before file success, deployed/restored target after success.

After verified apply, reread `AGENTS.md`, `.agents/workflow.json`, and `.agents/WORKFLOW_PROTOCOL.md` from the target project; that deployed contract governs handoff, handshake, and release. After verified rollback, load the exact restored version's deployed rules and manifest paths, using its authenticated plugin baseline only to locate them. If the restored coordination contract cannot be loaded or safely reconciled, keep the barrier and report the completed rollback without role fallback.

## Claim, discovery, snapshot, and barrier

1. The hub has already generated one fresh UUID `claimId`, recorded the exact provisional-barrier marker containing it in its own original message, and blocked ordinary creation; the exact machine claim with the same `claimId` is the creation prompt's first line. A queued `clientThreadId` occupies a slot and must never be recreated or passed to ID-only tools; resume waits for materialization and accepts only one same-project task with that exact raw first line. Once running, implicitly title the current transaction task from the same template, then recover exactly one same-project real task ID from exhaustive metadata. Never regenerate the claim, reuse the permanent hub, or guess an ID.
2. Generate the exact transaction key from trusted project, transaction task, source/target version, and generation values, then ask the hub to emit the exact active-barrier marker and rebind the provisional barrier to it. Reuse both on resume.
3. Exhaust every metadata page for ordinary, pinned, and archived tasks. Find the unique permanent hub and snapshot every other same-project visible active, blocked, waiting, or queued task except the hub and transaction task. Compute occupancy from the target contract.
4. Read history only for the hub, transaction task, snapshot tasks, and candidates whose identity or status is ambiguous. Disable tool outputs. If metadata is incomplete or targeted reads cannot resolve an ambiguity, fall back to complete history pagination for every same-project task returned by exhaustive metadata listing before proceeding.
5. Bind the already active barrier to the immutable snapshot. The transaction task then reads `file-transaction.md`, runs the selected engine command, and validates the result itself. Never create a separate executor.

For apply, require actual `APPLIED <transaction>`, validator success, target manifest version/paths, and matching `last_transaction`. For rollback, require actual `ROLLED_BACK <transaction>`, validator success under the restored version, matching target-owned transaction metadata, and exact restored manifest/files. Preserve the task's raw engine evidence and exact transaction identity.

## Observe and reconcile

Use scan sizes, output settings, recovery limits, deadline, discovery mode, transaction-task role, zero-active fast path, and pair reconciliation policy from target-version `.agents/workflow.json`; use the raw-message evidence rule in the target-version protocol. At entry/resume, exhaust metadata but target history as defined above. A wait only signals wake-up; reread only the configured latest turns of affected tasks afterward. Before resend, compensation, failure, or release, exhaust metadata again; expand to full history only when ambiguity or incomplete metadata requires it.

Accept only the exact first line of original raw `agentMessage.text` from the known task ID. Collapse identical valid acknowledgements. Outside the zero-active fast path, determine stable-empty only from the configured terminal snapshots/delays and accept valid evidence immediately.

After the file operation succeeds, switch contracts. The zero-active path requests the hub handshake exactly once as specified below. A nonempty snapshot asks the hub to reread the deployed/restored rules and emit the applicable raw handshake before reconciling predecessors.

When the immutable snapshot is empty, use the zero-active fast path: request the hub handshake once, perform one final exhaustive ordinary/pinned/archived metadata scan, and release immediately when the transaction result, exact identities, hub handshake, barrier, and empty snapshot all match. Do not create successors, wait for stable-empty observations, repeat the hub request, or add a settling delay.

When the snapshot is nonempty, reconcile each captured predecessor:

1. Obtain completion evidence or a safe-point handoff under that contract. Any changed goal, scope, requirements, interface/protocol, environment, acceptance criteria, or authorization returns the item to Work and keeps the barrier.
2. Archive the known predecessor first, then create or fork one visible successor preserving environment. An independent worktree requires its authorized transferable checkpoint and supported exact starting state.
3. Require the successor's exact identity and raw handshake from that contract. Never duplicate a queued successor; follow its machine recovery limits.

Each predecessor→successor pair preserves the strict order archive predecessor → create/fork successor → verify exact handshake. Independent pairs may run in parallel within currently available task slots; a blocked, waiting, or queued task still consumes its configured slot. Task-management mutations are not commit, push, deployment, or another external operation and need not be globally serialized across independent pairs. Serialize pairs that conflict, and continue to serialize high-risk actions and genuine external operations.

Release only after every required exact handshake and the final exhaustive metadata scan; send the predecessor→successor mapping to the hub, require its exact released-barrier marker, then report and safely archive the transaction task. Never infer success from an empty wait or summary.

## Resume or stop

At deadline, preserve the barrier and report operation, claim, transaction, confirmations, unresolved identities/handshakes, real or queued IDs, and recovery counters. On resume, re-prove the project, recover the latest exact provisional/active barrier marker from the known hub's original messages, recover the exact transaction task by the matching `claimId` when still provisional, read the installed/restored manifest and recorded transaction, exhaust metadata without outputs, target only required history unless ambiguity forces full fallback, reuse valid identities/evidence, and continue the unresolved stage. Never repeat a successful apply/rollback, regenerate identities or claims, infer evidence from summaries, or release because time elapsed. Ambiguity, changed content, exhausted recovery, or unmanageable state stops fail-closed.
