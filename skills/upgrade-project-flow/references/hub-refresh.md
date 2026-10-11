# Upgrade hub refresh

Read this reference for **apply**, or **resume of apply**, after verified APPLIED success or the exact validated same-version NOOP route in coordination.md. The same upgrade task owns refresh. Plan and rollback do not replace the hub. Apply includes one new permanent hub and retirement of only the exact inactive registered predecessor identified in the request's understanding. Never promote the upgrade task into the hub.

## Preconditions and durable intent

Keep the active upgrade barrier. Verify successful transaction, target validation and saved project binding. Call `upgrade-hub-read` before creation. Require complete native discovery, exact old hub accessibility/inactivity, and no other occupying tasks; never force-archive planning or execution blockers. Inspect bootstrap locks; unrelated unresolved locks stop. Resolve a creating planning registry under the old hub before refresh, and authenticate any existing bound/queued planning raw key and continuation lineage.

Preserve engine `hub-read`'s exact old ID and raw registry SHA-256 token. Run the deployed helper:

```text
upgrade-hub-begin --project ROOT --project-id EXACT_PROJECT_ID --request-id REQUEST_UUID --claim-id CLAIM_UUID --upgrade-thread-id EXACT_UPGRADE_TASK_UUID --old-hub-thread-id EXACT_OLD_HUB_UUID --old-registry-token RAW_SHA256 --target-version EXACT_VERSION
```

The helper exclusively writes `.project-flow/upgrade-hub.json` under its OS lock: request/claim/executor, old ID/token, target version, stable owner UUID, one creation token and preserved planning identity. Only a fresh `action=create` permits one create. `recover` or `reuse` means recover the existing attempt. Never hand-edit intent or regenerate IDs on resume.

## One cold-start hub

Immediately after `action=create`, recheck exact `list_projects` binding and create one local visible chat. Omit `model` and `thinking`. Its first raw line is the fully expanded `upgrade.hub_refresh.key`. Prompt it to cold-load the target-version plugin, deployed rules and `upgrade-hub-read`, and report real identity and loaded version/schema. It is a **refresh-only waiting hub**: it must not run normal Bootstrap, install, ensure planning, dispatch, or start project work. It waits for exact registry binding, completed intent and the owning upgrade barrier's released message; unexpected user requests remain queued.

The active barrier has only this one intent-bound hub-creation exception. Other hub, planning, execution and successor creation remain blocked. The verified waiting new hub is not an execution-slot occupant or a refresh-final-scan blocker. Authenticate by exact durable ID and raw key, not title.

Immediately `upgrade-hub-bind --project ROOT --token CREATION_UUID --thread-id REAL_UUID`, or `--client-thread-id CLIENT_UUID`. Explicitly wait and verify target version/schema and raw key. Resolve queued materialization only via `upgrade-hub-resolve --project ROOT --token CREATION_UUID --client-thread-id CLIENT_UUID --thread-id REAL_UUID`; do not use queued IDs in real-ID-only APIs.

Unknown create, timeout or incomplete result retains the same intent and active barrier. Resume exhaustively discovers that exact raw key/token and binds one authenticated result. Zero, multiple or incomplete matches stop. Because intent precedes create, even zero matches cannot prove no creation occurred and does not permit another create.

## Verified handoff and retirement

1. Require a real new ID different from old and upgrade IDs and cold-loaded version evidence. Reread old inactivity and raw registry token. With the intent's stable owner, use existing engine `hub-replacement-prepare` with exact old/token/new, canonical title and inactive confirmation. Record exact replacement key in upgrade raw history. Recover/renew only the same matching owner lock; never prepare another replacement.
2. Renew owner, call `hub-replacement-commit`: atomic registry-token CAS. Before CAS old is authoritative; after CAS only new. CAS failure does not retire old or create another chat. In the CAS gap (registry already new while intent is still bound), use `upgrade-hub-read`, verify exact new registry and matching owner replacement lock, repair title/pin, then advance stage committed; do not retry begin/bind or require the old token still be current. This is not another file transaction.
3. Set and confirm new canonical title and pin. Engine registry read and native targeted read must prove exact new ID/project/title/pin. Only then `upgrade-hub-stage --project ROOT --token CREATION_UUID --stage committed --confirmed-native-evidence`. This flag attests actual caller-verified native results; helper cannot authenticate chat APIs.
4. Retire only exact old ID in order: versioned retired title, unpin, archive. Confirm all three. Checkpoint `--stage retired`. Failure retains new registry, replacement lock, intent and barrier; repair this retirement without reverting registry or creating another hub.
5. Release the exact bootstrap owner with replacement-retired confirmation. Authenticate preserved planning raw identity/lineage and call `planning-rebind` with original root token and exact old/new IDs. The original raw planning key retains its original historical hub ID across repeated refreshes; authenticate unchanged exact project/root token/native identity from original creation history, not a regenerated key using the current or immediately previous hub. Preserve real/queued chat, generation and history; do not reopen archived planning or create another. If planning was absent, keep it absent until post-barrier ensure. Rebind failure retains intent/barrier for same-identity recovery.
6. Record `--stage complete` only after verified retirement, lock release and planning reconciliation. Helper verifies current new registry and preserved planning identity/lineage. Exhaust final native metadata: exempt only exact verified waiting new hub and upgrade task, require old explicitly archived and no other occupants. Release the same barrier only now. New hub rereads both memory files and verifies registry and release evidence before becoming the permanent dispatch-only entry; planning ensure follows normal post-barrier rules.

After release, the upgrade task may send one handoff follow-up to the exact new hub, omitting `model` and `thinking`, to wake its registry/complete/released checks. This is part of the authorized refresh, not permission to forward project requests. Failed or ambiguous activation is reported pending and repaired at the same ID, never another hub.

Resume reads persisted stage and actual engine/native evidence and repairs only missing steps. Plan/state content, existing task IDs and planning root token survive. Completed same request reuses intent; a later separately approved apply can begin a new refresh only from current exact hub after prior intent is complete. Report failures without declaring readiness from intent alone.
