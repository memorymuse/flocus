# Session Handoff: Logging, Diagnostics & Bug Investigation

**Date**: 2026-02-15 13:20 PST
**Session Focus**: Added always-on invocation logging, investigated multiple user-reported bugs, pinned two unfixed issues

---

## What Was Done

### 1. Always-On Invocation Log (Complete, Tested, Installed)

Added persistent logging to both CLI and extension. Every `vo`/`flocus` invocation now writes to `~/.config/flocus/flocus.log` with the full decision chain.

**CLI side** (`cli/vo`):
- New `log()` function writes timestamped key=value entries
- Logs at every decision point: args, pwd, path resolution, git root, registry lookup, health check, HTTP request/response, `code` exec, exit path
- Before calling `code` in fallback, writes expected file path to `~/.config/flocus/.pending`

**Extension side** (`extension/src/extension.ts`):
- `onDidOpenTextDocument` listener checks if opened file matches `.pending` marker
- Only logs flocus-triggered opens (not manual opens, tab restores, etc.)
- Writes to same `flocus.log`: `extension code_fallback_received workspace=... file=...`
- `.pending` marker auto-expires after 5 seconds (stale cleanup)

**Tests**: All 19 CLI tests pass. Extension compiles clean. Extension rebuilt, packaged, and installed.

### 2. Mark Sharp Auto-Updates Disabled (Complete)

User disabled auto-updates for Mark Sharp in VS Code to preserve the local `getLastPosition()` patch. Note added to CLAUDE.md with reminder to re-enable when upstream fix ships. Issue [#130](https://github.com/jonathanyeung/mark-sharp/issues/130) still open, no maintainer response.

### 3. Bug Investigations (Diagnosed, Pinned)

#### Silent CLI failure (`set -e` + `jq` death) — PINNED, NOT FIXED
- **Symptom**: `vo file.md` produces no output, file doesn't open
- **Root cause**: If HTTP server returns non-JSON (e.g., random service on a reused port), `success=$(echo "$response" | jq -r '.success // false')` fails. With `set -euo pipefail`, jq failure kills the script silently before reaching the `code` fallback.
- **Fix needed**: Protect jq parsing — e.g., `success=$(echo "$response" | jq -r '.success // false' 2>/dev/null || echo "false")`
- **Location**: `cli/vo`, `open_file()` function, around the `send_open_request` response parsing

#### VS Code admin elevation error — PINNED, UNDER INVESTIGATION
- **Symptom**: Windows error "Another instance of Code is already running as administrator" when any `code` command is run, but ONLY when flocus has opened VS Code instances
- **Suspect**: `code "$workspace" >/dev/null 2>&1 &` (backgrounded window focus call, `cli/vo`)
- **Hypothesis**: Backgrounded `code` through WSL2 interop may handle Windows security tokens differently, causing VS Code to launch elevated
- **User testing**: `export FLOCUS_NO_FOCUS=1` in shell rc to skip the background `code` call. Results pending.

#### Panel toggling during flocus open — PUNTED
- **Symptom**: VS Code console/panel randomly opens/closes when flocus opens a file
- **Actual cause**: Claude Code's VS Code extension, not flocus
- **Decision**: No fix needed. Documented in memory file.

---

## Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Always-on logging (not opt-in) | User hit the same silent-failure bug twice with no way to diagnose. Logging cost is negligible (few hundred bytes per invocation). |
| `.pending` marker for extension-side filtering | `onDidOpenTextDocument` fires for ALL document opens. Without filtering, log would be noisy with irrelevant events. Marker file is simple, file-based coordination with no IPC needed. |
| 5-second TTL on `.pending` | Prevents stale markers from matching unrelated opens if `code` fallback fails silently. |
| Pin bugs rather than fix immediately | User wanted to capture the issues and move on. Fixes are straightforward but session was focused on diagnostics. |

---

## Files Modified

| File | Changes |
|------|---------|
| [`CLAUDE.md`](../../CLAUDE.md) | Added Debugging section, Mark Sharp auto-update note, log/pending files in Configuration |
| [`cli/vo`](../../cli/vo) | Added `LOG_FILE`, `log()` function, log calls throughout all code paths, `.pending` marker write in `fallback_to_code` |
| [`extension/src/extension.ts`](../../extension/src/extension.ts) | Added `fs`/`os` imports, `logToFile()`, `matchAndClearPending()`, `registerFallbackOpenLogger()`, registered in `activate()` |

---

## Open Items (Priority Order)

1. **Fix `set -e` + jq silent death** — Straightforward, high impact. Protect jq parsing in `open_file()` and `list_files()`. See pinned bug details above.

2. **Confirm/fix VS Code admin elevation** — Waiting on user test results with `FLOCUS_NO_FOCUS=1`. If confirmed as the backgrounded `code` call, need alternative window focus mechanism or make it opt-in.

3. **Marketplace publication** — Ready to execute per [PUBLISH.md](../PUBLISH.md). Fix pinned bugs first.

4. **Extension update across all workspaces** — The cc-optimizations workspace was running a legacy extension (plain `"ok"` health). After this session's reinstall, the flocus project window has the latest. Other windows need reload to pick up the new extension.

---

## Required Reading

- [`CLAUDE.md`](../../CLAUDE.md) — Updated with debugging section and configuration
- This handoff

## Suggested Reading

- [Previous handoff](260207-1617_registry-fix-and-publish.md) — Registry fix context, Mark Sharp investigation, PUBLISH.md design
- [`docs/PUBLISH.md`](../PUBLISH.md) — If working on marketplace publication

## Key Insight

The invocation log is the single most important diagnostic tool for flocus bugs. **Always check `tail -n 60 ~/.config/flocus/flocus.log` before investigating code.** This is documented in CLAUDE.md's "Debugging — READ THIS FIRST" section.
