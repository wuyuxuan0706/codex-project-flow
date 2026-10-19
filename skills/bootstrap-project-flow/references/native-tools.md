# Native project and chat tools

## Discover before declaring a capability missing

Run this preflight before Bootstrap identity checks, locks, project writes, titles, planning intents, or task creation. Upgrade and recovery use the same preflight before their corresponding actions. Tool discovery is read-only and does not authorize any mutation.

Names such as `list_projects` and `create_thread` in this workflow denote capabilities, not necessarily top-level callable names. Desktop tools can be deferred and namespaced (for example `mcp__codex_app__list_projects`). The initial visible tool list is not a complete inventory when the runtime offers discovery. Windows does not change this rule.

1. Inspect the current runtime's documented discovery surface. When a tool-search facility is exposed, search for native project lookup and chat listing, reading, creation, title, pinning and archival; read the returned schemas. When Code Mode exposes `ALL_TOOLS` and `tools`, inspect relevant metadata in that runtime instead. Do not assume either facility exists in every session.
2. Resolve each required operation to an actually advertised native tool. Read its full description, parameters and result contract before calling it. Prefixes are examples, not names to invent. An advertised mutation is evidence that its interface exists, not that a future mutation will succeed or is authorized.
3. Call the discovered native project-listing tool once as a read-only availability and identity probe. Preserve its actual returned project IDs, paths and host/source information. An error is not an empty successful project list. A call error, denied access, absent tool and identity mismatch are distinct outcomes.
4. Bind the exact invoking saved project as described below, then perform only the listing and targeted reads required by the selected Bootstrap/Upgrade route. Discover mutation schemas without performing test mutations. In particular, never create a test chat or temporarily rename a chat merely to test whether the tools work.
5. Only after available discovery has completed may an absent required capability be reported as missing. If no discovery facility is exposed, state that discovery could not be performed. If a discovered call fails, state that failure rather than claiming the tool is uninstalled. Preserve existing recovery evidence and stop before the affected mutation when capability, identity or results remain uncertain.

When `functions.exec` explicitly exposes `ALL_TOOLS`, this is one metadata-only discovery example:

```javascript
const operations = new Set([
  "list_projects", "list_threads", "list_archived_threads", "read_thread",
  "create_thread", "set_thread_title", "move_thread_to_sidebar_section",
  "set_thread_archived"
]);
for (const entry of ALL_TOOLS) {
  const prefix = "mcp__codex_app__";
  if (entry.name.startsWith(prefix) && operations.has(entry.name.slice(prefix.length))) {
    text(entry); // Name and description; inspect whether a callable schema is included.
  }
}
```

Read that result before the next cell. `ALL_TOOLS` guarantees metadata, not a parameter schema: a description may include one, but if it does not, use the runtime's documented schema-loading mechanism before invoking anything. If no such mechanism is exposed, report the schema as unavailable and do not guess arguments. If the returned description actually advertises `mcp__codex_app__list_projects(args: {})`, the read-only probe is:

```javascript
text(await tools.mcp__codex_app__list_projects({}));
```

Do not run these examples in a shell or another JavaScript runtime, where these runtime-owned bindings do not exist. A tool-search runtime must instead use its own documented discovery and invocation mechanism. Do not scan unrelated tools or account data.

A logical operation can map to a differently named native interface. For example, when the advertised schema provides `move_thread_to_sidebar_section`, its documented `sectionId: "pinned"` implements pinning and `sectionId: null` implements unpinning for an exact real thread ID. Do not declare pinning unavailable just because there is no `set_thread_pinned`. Read and verify the actual result when the authorized workflow reaches that operation; discovery does not authorize a test pin/unpin.

## Bind the invoking project

Use the invoking task's trusted saved-project root and host context. If the context already supplies a project ID, require the native lookup to match that exact ID and canonical root. If it supplies the exact saved root but no ID, a single native project record matching that canonical root and host can establish the ID; retain the returned opaque ID instead of guessing one from a name or path. Zero matches, multiple matches, conflicting host or explicit ID disagreement stop.

On Windows compare resolved canonical paths using Windows path rules, including separator and case normalization; do not compare only display names or path prefixes. This is comparison, not permission to rename paths. A working subdirectory or a similarly named project does not establish a different saved root. If the invoking saved-project root itself cannot be established, report that exact identity gap.

Never use local session databases, authentication files, private app endpoints, a separately launched CLI session or UI clicks to forge the current chat identity or bypass native tools. Do not create project IDs, edit hub/planning registries manually, weaken lock ownership or skip slot/barrier evidence when tools are truly unavailable.

## Report evidence and recovery

Report which discovery surface was used, the actual resolved tool names, the read-only call outcome, and the precise capability or identity still missing. Redact unrelated project entries from user-facing output. Metadata discovery alone is not an end-to-end initialization test; a successful project-list call does not prove title changes, creation or archival succeeded.

Do not recommend reinstalling the plugin, changing configuration, restarting the app or switching operating systems as a proven fix without evidence. Those can be explicitly described as unverified troubleshooting only after actual discovery/call failure. A successful preflight proceeds in the same task through the normal authorized route; a failed one preserves fail-closed behavior. Repeated user requests reuse the same recovery intent and never create duplicate hubs or planning chats.
