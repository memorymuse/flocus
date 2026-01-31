# Handoff: vo Phase 1 Implementation Complete

**Date:** 2026-01-22 21:00 PST
**Session:** Full Phase 1 implementation of `vo` — context-aware VS Code file opener
**Status:** Phase 1 complete, working end-to-end

---

## What Was Built

Implemented the complete Phase 1 MVP per [DESIGN.md](../DESIGN.md):

### CLI (`cli/vo`)
- Bash script (~200 lines) that:
  - Resolves relative paths to absolute
  - Detects git root via `git rev-parse --show-toplevel`
  - Reads registry to find matching VS Code window
  - Sends HTTP POST to extension's `/open` endpoint
  - Falls back to `code` command if no match
  - Brings VS Code window to foreground after success
- Flags: `-z` (zen mode), `--raw` (bypass custom editors), `file:line` syntax
- Clean output: `Opened: filename`

### VS Code Extension (`extension/`)
- TypeScript extension that:
  - Registers workspace + port in `~/.config/vo/registry.json`
  - Starts HTTP server on localhost (port 19800-19900)
  - Handles `/health` and `/open` endpoints
  - Opens files, optionally in Mark Sharp for `.md`
- Packaged as `vo-server-0.1.0.vsix`
- Must be installed in WSL mode (extension runs in WSL extension host)

### Tests
- **CLI**: 10 integration tests — real git repos, real HTTP servers, no mocks
- **Extension**: 20 unit tests for registry and server modules
- **Runner**: `tests/run_all.sh` runs both, works from any directory
- Tests are robust: cleanup stale processes, track PIDs, handle Ctrl+C

---

## Key Decisions Made

| Decision | Rationale |
|----------|-----------|
| Window focus via `code $git_root` | No VS Code API exists for bringing window to foreground. This workaround re-invokes `code` which brings existing window forward without reload. |
| Skip focus for `/tmp/*` paths | Prevents tests from opening VS Code windows for temp directories |
| `extensionKind: ["workspace"]` in package.json | Required for extension to run in WSL (not Windows host) |
| CLI output via parsed JSON | Shows friendly `Opened: filename` instead of raw JSON response |

---

## Critical Nuances

### Tab Deduplication
The `findOpenTab()` function in `extension.ts` searches ALL tabs using `vscode.window.tabGroups.all`, which includes:
- Regular text editors (`TabInputText`)
- Custom editors like Mark Sharp (`TabInputCustom`)

This is important because `visibleTextEditors` only includes standard text editors. When a match is found, we use the **existing tab's URI** (not the CLI's resolved path) to open/focus it — this prevents issues when the CLI sends a wrong path (e.g., from a subdirectory).

### WSL + VS Code Architecture
- VS Code window runs on Windows
- Extension host runs in WSL (via Remote-WSL)
- Registry file is in WSL filesystem (`~/.config/vo/`)
- HTTP server binds to WSL localhost — accessible from WSL terminals
- File paths are Linux paths throughout

### Installation
```bash
# Extension must be installed while VS Code is connected to WSL
code --install-extension extension/vo-server-0.1.0.vsix

# CLI needs to be in PATH
ln -s /path/to/vo/cli/vo ~/.local/bin/vo
```

### Window Focus Delay
The `code $git_root` call takes 1-2 seconds to bring window forward. This is acceptable — the `code` CLI has startup overhead.

---

## Files Created

| File | Purpose |
|------|---------|
| [`cli/vo`](../../cli/vo) | Main CLI script |
| [`extension/src/extension.ts`](../../extension/src/extension.ts) | VS Code activation, file opening |
| [`extension/src/registry.ts`](../../extension/src/registry.ts) | Registry CRUD operations |
| [`extension/src/server.ts`](../../extension/src/server.ts) | HTTP server |
| [`extension/vo-server-0.1.0.vsix`](../../extension/vo-server-0.1.0.vsix) | Packaged extension |
| [`tests/test_cli.sh`](../../tests/test_cli.sh) | CLI integration tests |
| [`tests/test_server.py`](../../tests/test_server.py) | Python HTTP server for tests |
| [`tests/run_all.sh`](../../tests/run_all.sh) | Combined test runner |
| [`README.md`](../../README.md) | User documentation |
| [`CLAUDE.md`](../../CLAUDE.md) | Agent documentation |

---

## Remaining Work (Phases 2-4)

### Phase 2: Core Features — COMPLETE
- [x] Reveal in Explorer — R9 (works by default)
- [x] Zen mode in extension — R10
- [x] Line number jump — N3
- [ ] WSL2 comprehensive testing (works, but not exhaustively tested)

### Phase 3: Polish
- [ ] Custom editor mappings via `~/.config/vo/config.json` — R11, R12
- [ ] `--raw` flag handling in extension
- [ ] Registry cleanup (prune stale entries)

### Phase 4: Nice-to-Have
- [ ] Directory support: `vo <folder>` — N1
- [ ] Auto zen mode for orphan files — N2
- [ ] Multiple files: `vo *.md` — N4

### Future: `vc` (VS Code Close)
New companion CLI for closing tabs:
- [ ] `vc` — Close most recently opened tab
- [ ] `vc {filepath}` — Close specific file tab
- [ ] `vc {directory}` — Close all files in directory
- [ ] `vc {date/time}` — Close all files last opened before date/time

### Future: `vo` Profiles
- [ ] `vo {profile_name}` — Open user-defined workspace with pre-defined files, OR restore most recent view of that profile/directory
- [ ] Profile config format TBD (likely `~/.config/vo/profiles.json`)

---

## Additional Features (Added Post-Phase-1)

| Feature | Description |
|---------|-------------|
| **Smart deduplication** | Uses `tabGroups` API to find ALL open tabs (including Mark Sharp). Focuses existing tab instead of duplicating. |
| **Case-insensitive paths** | CLI finds `README.md` when you type `readme.md`. Uses `find -iname` for matching. |
| **Window focus** | Brings VS Code window to foreground via `code $git_root` workaround. Skips for `/tmp/*` paths (tests). |

---

## Required Reading

1. [`CLAUDE.md`](../../CLAUDE.md) — Architecture, dev commands, implementation status
2. [`docs/DESIGN.md`](../DESIGN.md) — Full requirements and technical design

## Suggested Reading

- [`cli/vo`](../../cli/vo) — Well-commented, shows full CLI flow
- [`extension/src/extension.ts`](../../extension/src/extension.ts) — VS Code integration

---

## Pro Tips

1. **Run tests often**: `./tests/run_all.sh` — catches regressions fast
2. **Debug CLI**: `VO_DEBUG=1 vo file.py` — shows path resolution, registry lookup
3. **Rebuild extension**: `cd extension && npm run compile && npm run package`
4. **Reinstall extension**: Must uninstall first, then install new .vsix
5. **Check registry**: `cat ~/.config/vo/registry.json` — verify extension registered
6. **Check extension health**: `curl http://127.0.0.1:<port>/health`
