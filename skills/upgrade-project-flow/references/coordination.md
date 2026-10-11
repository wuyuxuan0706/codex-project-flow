# Upgrade coordination and recovery

The permanent hub creates the one approved upgrade task and then leaves that request. The upgrade task owns request/transaction identity, barrier state, plan, mutation, managed documentation, memory synchronization, validation, recovery, acceptance, and archival.

Require complete ordinary, pinned, and archived metadata pagination plus targeted history reading, title mutation, visible creation, waiting, and archival. Missing or partially manageable capabilities stop before barrier activation, or preserve an existing barrier.

For native discovery, request `list_threads` with a limit no greater than 50. Because it has no cursor, completeness requires the non-pinned count to be strictly below the requested limit and all reported unavailable host/source collections to be empty; equality is incomplete. Pinned results are complete by contract. Follow every `list_archived_threads` cursor until null and require no unavailable source. Do not invent `hasMore` or a cursor absent from the tool schema.

## Contract routing

Before claiming a transaction or publishing a barrier, read the target-version contract from `pluginRoot`: `.agents/WORKFLOW_PROTOCOL.md`, `.agents/workflow.json`, and this reference. An old project does not need to satisfy target rules before apply. On resume, use the transaction-bound contract: plugin target before file success, deployed/restored target afterward.

After verified apply, reread target `AGENTS.md`, workflow, protocol, and both project-memory files. After verified rollback, load the exact restored contract and manifest. If reconciliation is unsafe, preserve the barrier and report the completed file result without role fallback.

## Claim, snapshot, and barrier

Resume first reconciles the original manifest and transaction. Verified successful apply goes directly to `hub-refresh.md` under its existing active barrier; it does not repeat apply or demand a new pre-file empty snapshot that would reject its own newly created waiting hub. Authenticate only the exact durable creating/queued/bound refresh identity and raw key as the narrow refresh recovery exception, even before CAS. Other occupants stop. Plan/rollback use their original coordination path and never refresh.

1. Keep one UUID `requestId`, one raw first-line `upgrade.request_key`, and one stable `claimId` for apply/rollback. A queued `clientThreadId` occupies a slot and is never recreated or passed to ID-only tools. Resume requires exactly one materialized same-project match.
2. Derive the transaction key from trusted project, task, versions, and generation. Publish the provisional barrier before taking the activity snapshot. Reuse all identities on resume.
3. Exhaust every ordinary, pinned, and archived page. Identify the unique hub and every other same-project visible identity occupying a slot, including the planning chat and any active, blocked, waiting, queued, or `awaiting_acceptance` task.
4. Read history only for the upgrade task, occupying tasks, and ambiguous candidates, with outputs disabled. Incomplete metadata or unresolved ambiguity requires full same-project history pagination.
5. Require an empty snapshot except for hub and current upgrade task. Any occupant stops immediately with no archive, successor, active barrier, or engine call. Preserve provisional state and report exact blockers.
6. Blocking tasks finish in their own chats. They first save meaningful memory and then follow their normal accept/continue/pause lifecycle; the upgrade task never interprets UI archival as consent. After release of every other slot, resume the same upgrade task and repeat exhaustive discovery.
7. On an empty snapshot, advance the barrier to active, bind it to that snapshot, run the selected engine operation, and validate the actual result.

Apply requires actual `APPLIED <transaction>`, validator success, exact target version/path manifest, and matching `last_transaction`. Rollback requires actual `ROLLED_BACK <transaction>`, restored-version validation, exact target-owned metadata, and restored bytes. Preserve raw evidence.

For an explicit apply whose engine returns exact `NOOP already up to date`, current runtime validation plus exact target version/path manifest proves the no-file-change result. Keep this request's claim and active barrier and continue one hub refresh, even when managed files already match target. Do not invent a transaction ID or require a new `last_transaction`; preserve any existing manifest transaction metadata. A completed refresh for the same request reuses its intent, while a separately approved later request can refresh once again. Resume of a successful APPLIED transaction uses original bound evidence, never reruns it to obtain NOOP.

## Project memory

Before archive, successor creation, or a meaningful pause, the task uses helper `read`, prepares the new `PROJECT_STATE.md`, and calls CAS `save` with the returned state hash. The plan remains unchanged unless explicit acceptance authorizes helper `accept`. Preserve the confirmed goal, accepted checkboxes, decisions, results, verification, blockers, unfinished work, next actions, and continuation identity. Historical verification stays historical until rerun.

These schema-13 helper and planning operations apply only while schema 13 is deployed. After rollback to an older contract, reread the restored files and record legitimately missing plan/helper paths; use that contract's state-maintenance and completion rules instead of calling an incompatible helper or recreating removed paths. Do not create a schema-13 planning chat after an older-version rollback.

Upgrade planning does not replace project planning. Existing valid goal and steps survive byte-for-byte where `seed_once` applies. A newly seeded or incomplete plan remains draft with unknown steps unchecked. Only explicit acceptance may check the project step represented by this upgrade; no mapping means no checked step.

If the user naturally asks to archive before final acceptance, save first and ask whether to continue or pause when intent is ambiguous. Continue creates one gated successor for the same request/generation+1 only after capacity is reserved; only the exact predecessor is excluded from path-conflict checks, not other tasks. The successor uses `wait_threads` to wait for the predecessor turn, then separately confirms exact archival before working; timeout retains the same waiting identity. Pause saves then archives without successor and without acceptance. A confirmed completed request saves accepted memory and archives without successor or next step; mixed acceptance/continuation with no clear remaining work is clarified, not guessed. An unmapped request saves state only, never an inferred plan checkbox. Memory-write failure stops before create or archive.

The native UI archive action has no reliable interception hook. Do not promise automatic save when no message or high-confidence signal reaches the task.

## Planning-chat recovery after apply

Release the upgrade barrier after verified transaction and empty final scan, then call helper `read`. Existing registry state is reuse/recovery only: target its bound identity, resolve its exact queued client, or exhaustively locate one raw-key/token match for `creating`; never call `planning-begin` or create again. When the registry is absent, first prove native listing completeness, capacity, no barrier, and exact `list_projects` binding. Only then call `planning-begin`; `action=create` must proceed in the same contiguous sequence to one `create_thread` and immediate real/queued bind. A closed pre-begin gate leaves no registry; an unknown post-begin result leaves one recoverable intent and must not trigger another create.

The planning chat occupies a slot, so it is created only after barrier release. An explicitly archived planning task stays archived when project memory is valid and complete; exact unarchive is limited to authorized recovery of missing/incomplete or user-requested planning discussion. Recovery never starts the next project step.

## Observe and reconcile

Use scan sizes, output settings, recovery limits, deadline, and discovery mode from target `.agents/workflow.json`. A wait is only a wake signal. Before mutation, failure, or barrier release, exhaust metadata again. A nonempty snapshot is never reconciled by the upgrade task.

For apply, release only after verified file transaction, helper refresh stage complete, confirmed exact old retirement, bootstrap owner release, preserved planning-identity rebind and final reconciliation exempting only exact waiting new hub/current upgrade task. Rollback requires verified restored transaction and original empty reconciliation, without refresh. Cancel only before mutation and explicit cancellation. Released/cancelled permits the authoritative hub to dispatch; release is not user acceptance.

Then report `changes`, `verification`, `uncovered`, and `risk` and enter `awaiting_acceptance`. Rejection stays in the same current task. Acceptance saves memory, checks only an explicitly accepted mapped step, and archives the exact task without starting another step. Only a confirmed matching archive result ends the request.

## Resume or stop

At deadline, preserve the barrier and report request, operation, claim, transaction, blockers, unresolved identities, real/queued IDs, memory state, and recovery counters. On resume, re-prove project binding, recover exact identities and manifest, exhaust metadata, reuse valid evidence, and continue only the unresolved stage.

Never repeat a successful file transaction, regenerate identity, infer acceptance from summaries or archival, force-archive a blocker, or release because time elapsed. Ambiguity, content drift, exhausted recovery, or unmanageable state stops fail-closed.
