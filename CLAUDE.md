# CLAUDE.md — flocus Project

## Project Overview

**flocus** (Focus & Flow) is a context-aware VS Code file opener. It opens files in the correct VS Code window based on git project, solving the problem that `code` command can't target a specific window when multiple are open.

## Architecture

```
flocus/
├── cli/vo                    # Bash CLI script (aliased as flocus)
├── extension/                # VS Code extension (TypeScript)
│   ├── src/
│   │   ├── extension.ts      # VS Code integration, activation/deactivation
│   │   ├── registry.ts       # Registry file read/write (~/.config/flocus/registry.json)
│   │   └── server.ts         # HTTP server (health check, /open, /files endpoints)
│   └── flocus-*.vsix         # Packaged extension
├── tests/
│   ├── test_cli.sh           # CLI integration tests (bash)
│   └── test_server.py        # Test HTTP server helper
└── docs/
    └── DESIGN.md             # Full design document with requirements
```

## How It Works

1. **Extension** runs in each VS Code window:
   - On activation: registers workspace + port in `~/.config/flocus/registry.json`
   - Starts HTTP server on localhost (port 19800-19900)
   - Handles `/open` and `/files` requests

2. **CLI** (`flocus`):
   - Resolves file path, detects git root
   - Reads registry to find matching VS Code window
   - Sends HTTP POST to extension's `/open` endpoint
   - Falls back to `code` command if no match

## Development

### Running Tests

```bash
# Run all tests (works from any directory)
./tests/run_all.sh

# Or individually:
./tests/test_cli.sh                           # CLI integration tests
npm run test:unit --prefix extension          # Extension unit tests
```

Tests are designed to be robust:
- Cleans up stale processes from interrupted runs
- Tracks all server PIDs for proper cleanup
- Handles Ctrl+C gracefully

### Building Extension

```bash
cd extension
npm install
npm run compile        # TypeScript → JavaScript
npm run package        # Creates .vsix file
```

### Key Files

| File | Purpose |
|------|---------|
| `cli/vo` | Main CLI script (bash), aliased as flocus |
| `extension/src/extension.ts` | VS Code activation, file opening logic |
| `extension/src/registry.ts` | Registry CRUD operations |
| `extension/src/server.ts` | HTTP server with /health (returns workspace identity), /open, /files endpoints |
| `docs/DESIGN.md` | Complete design document with all requirements |
| `docs/PUBLISH.md` | Marketplace publication design (CLI bundling, config, checklist) |

## Implementation Status

### Phase 1 (Complete)
- [x] Extension skeleton with HTTP server
- [x] Registry read/write
- [x] CLI with git detection, registry lookup, HTTP request
- [x] Basic file opening
- [x] Integration tests (44 total: 19 CLI + 25 extension)
- [x] Window focus (brings VS Code to foreground)
- [x] Clean CLI output (`Opened: filename`)
- [x] Zen mode (`-z` flag hides sidebar/panels)
- [x] Line number support (`file:42` jumps to line)
- [x] Scroll to top (new files open at line 1; already-open files preserve position)
- [x] List open files (`flocus list` prints all open files in current project)
- [x] Reveal in Explorer (shows file in sidebar)
- [x] Duplicate-detection (focuses existing tab instead of opening twice)
- [x] Case-insensitive file paths
- [x] Directory support (`flocus open <folder>` opens folder in VS Code)
- [x] Path-based fallback (files under any open workspace auto-route)
- [x] Orphan workspace config (default window for orphan files via config.json)
- [x] Agent context (`flocus --agent` for AI agent context)

### Phase 2 (Pending)
- [ ] WSL2 testing

### Phase 3 (In Progress)
- [ ] Custom editor mappings via VS Code settings (design in [PUBLISH.md](docs/PUBLISH.md) Section 3)
- [x] Registry cleanup: stale entry pruning via health identity verification + registration-time port conflict cleanup

### Phase 4 (Nice-to-Have)
- [ ] Auto zen mode for orphan files
- [ ] Multiple files: `flocus open *.md` (`--all` flag)

### Future: `flocus close` Command
Subcommand for closing tabs:
- [ ] `flocus close` — Close most recently opened tab
- [ ] `flocus close {filepath}` — Close specific file tab
- [ ] `flocus close {directory}` — Close all files in directory

### Future: Profiles
- [ ] `flocus profile {name}` — Open workspace with pre-defined files or restore recent view
- [ ] Profile config in `~/.config/flocus/profiles.json`

## Testing Philosophy

**NO MOCK TESTS.** All tests use real:
- Git repositories (created in temp directories)
- HTTP servers (Python test server)
- File operations
- Registry files

The CLI tests use `FLOCUS_DRY_RUN=1` to prevent actually launching VS Code during fallback tests.

## Configuration

- **Registry**: `~/.config/flocus/registry.json` - auto-managed by extension
- **Config**: `~/.config/flocus/config.json` - user settings

## Important Design Decisions

1. **HTTP over IPC**: HTTP on localhost works in WSL2 where IPC is complex
2. **Git root for project detection**: Reliable, standard, no config needed
3. **Registry file**: Simple JSON, atomic writes, no database
4. **Port range 19800-19900**: Unlikely to conflict, easy to debug
5. **Bash CLI**: Fast to prototype, no build step, works everywhere
6. **Subcommand pattern**: `flocus open`, `flocus list` — modern CLI style, no namespace collisions
7. **Window focus via `code $git_root`**: No VS Code API exists to bring window to foreground ([GitHub issue](https://github.com/microsoft/vscode/issues/74945)). Workaround: re-invoke `code` command which brings existing window forward without reloading
8. **Health endpoint returns workspace identity**: `/health` returns `{"status":"ok","workspace":"/path"}` — enables CLI to verify it's talking to the right window, not a stale entry on a reused port

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `FLOCUS_DEBUG=1` | Enable debug output showing path resolution, registry lookup, HTTP requests |
| `FLOCUS_DRY_RUN=1` | Skip actual `code` command in fallback (used by tests) |
| `FLOCUS_NO_FOCUS=1` | Skip window focus behavior (the `code $git_root` call) |

Note: Window focus is automatically skipped for `/tmp/*` paths to prevent tests from opening VS Code windows.

## Common Issues

- **Extension not activating**: Must have a folder open (not just a file)
- **Wrong window**: Check registry has correct workspace path. Stale entries are auto-pruned on detection (workspace mismatch or dead server)
- **Port conflict**: Extension finds next available port automatically. Registration cleans up stale entries from other workspaces on the same port
- **Custom editor scroll issues**: Mark Sharp has an upstream bug where `getLastPosition()` defaults new docs to end-of-file. Upstream issue: [mark-sharp#130](https://github.com/jonathanyeung/mark-sharp/issues/130)
  - **Local patch** (re-apply after Mark Sharp updates): In `~/.vscode-server/extensions/jonathan-yeung.mark-sharp-1.9.1/dist/extension.js`, replace `getLastPosition(e){const t=e.lineCount-1,n=e.lineAt(t).text.length;return new f.Position(t,n)}` with `getLastPosition(e){return new f.Position(0,0)}`
