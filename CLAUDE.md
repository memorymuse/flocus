# CLAUDE.md — vo Project

## Project Overview

**vo** is a context-aware VS Code file opener. It opens files in the correct VS Code window based on git project, solving the problem that `code` command can't target a specific window when multiple are open.

## Architecture

```
vo/
├── cli/vo                    # Bash CLI script
├── extension/                # VS Code extension (TypeScript)
│   ├── src/
│   │   ├── extension.ts      # VS Code integration, activation/deactivation
│   │   ├── registry.ts       # Registry file read/write (~/.config/vo/registry.json)
│   │   └── server.ts         # HTTP server (health check, /open endpoint)
│   └── vo-server-*.vsix      # Packaged extension
├── tests/
│   ├── test_cli.sh           # CLI integration tests (bash)
│   └── test_server.py        # Test HTTP server helper
└── docs/
    └── DESIGN.md             # Full design document with requirements
```

## How It Works

1. **Extension** runs in each VS Code window:
   - On activation: registers workspace + port in `~/.config/vo/registry.json`
   - Starts HTTP server on localhost (port 19800-19900)
   - Handles `/open` requests to open files

2. **CLI** (`vo`):
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
./tests/test_cli.sh          # CLI integration tests
cd extension && npm run test:unit   # Extension unit tests
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
| `cli/vo` | Main CLI script (bash) |
| `extension/src/extension.ts` | VS Code activation, file opening logic |
| `extension/src/registry.ts` | Registry CRUD operations |
| `extension/src/server.ts` | HTTP server with /health and /open endpoints |
| `docs/DESIGN.md` | Complete design document with all requirements |

## Implementation Status

### Phase 1 (Complete)
- [x] Extension skeleton with HTTP server
- [x] Registry read/write
- [x] CLI with git detection, registry lookup, HTTP request
- [x] Basic file opening
- [x] Integration tests (39 total: 16 CLI + 23 extension)
- [x] Window focus (brings VS Code to foreground)
- [x] Clean CLI output (`Opened: filename`)
- [x] Zen mode (`-z` flag hides sidebar/panels)
- [x] Line number support (`file:42` jumps to line)
- [x] Scroll to top (new files open at line 1; already-open files preserve position)
- [x] List open files (`vo -l` prints all open files in current project)
- [x] Reveal in Explorer (shows file in sidebar)
- [x] Duplicate-detection (focuses existing tab instead of opening twice)
- [x] Case-insensitive file paths
- [x] Directory support (`vo <folder>` opens folder in VS Code)
- [x] Path-based fallback (files under any open workspace auto-route)
- [x] Orphan workspace config (default window for orphan files via config.json)

### Phase 2 (Pending)
- [ ] Reveal in Explorer (R9)
- [ ] Zen mode in extension (R10) - CLI passes flag, extension needs to implement
- [ ] Line number support in extension
- [ ] WSL2 testing

### Phase 3 (Pending)
- [ ] Custom editor mappings via config.json (R11, R12)
- [ ] `--raw` flag handling in extension
- [ ] Registry cleanup (prune stale entries)

### Phase 4 (Nice-to-Have)
- [x] Directory support: `vo <folder>` (moved to Phase 1)
- [ ] Auto zen mode for orphan files
- [ ] Multiple files: `vo *.md`

### Future: `vc` Command (VS Code Close)
Companion CLI for closing tabs:
- [ ] `vc` — Close most recently opened tab
- [ ] `vc {filepath}` — Close specific file tab
- [ ] `vc {directory}` — Close all files in directory
- [ ] `vc {date/time}` — Close files opened before date/time

### Future: `vo` Profiles
- [ ] `vo {profile_name}` — Open workspace with pre-defined files or restore recent view
- [ ] Profile config in `~/.config/vo/profiles.json`

## Testing Philosophy

**NO MOCK TESTS.** All tests use real:
- Git repositories (created in temp directories)
- HTTP servers (Python test server)
- File operations
- Registry files

The CLI tests use `VO_DRY_RUN=1` to prevent actually launching VS Code during fallback tests.

## Configuration

- **Registry**: `~/.config/vo/registry.json` - auto-managed by extension
- **Config**: `~/.config/vo/config.json` - user editor mappings (not yet implemented)

## Important Design Decisions

1. **HTTP over IPC**: HTTP on localhost works in WSL2 where IPC is complex
2. **Git root for project detection**: Reliable, standard, no config needed
3. **Registry file**: Simple JSON, atomic writes, no database
4. **Port range 19800-19900**: Unlikely to conflict, easy to debug
5. **Bash CLI**: Fast to prototype, no build step, works everywhere
6. **Window focus via `code $git_root`**: No VS Code API exists to bring window to foreground ([GitHub issue](https://github.com/microsoft/vscode/issues/74945)). Workaround: re-invoke `code` command which brings existing window forward without reloading ([source](https://www.eliostruyf.com/trick-bring-visual-studio-code-foreground-extension/))

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `VO_DEBUG=1` | Enable debug output showing path resolution, registry lookup, HTTP requests |
| `VO_DRY_RUN=1` | Skip actual `code` command in fallback (used by tests) |
| `VO_NO_FOCUS=1` | Skip window focus behavior (the `code $git_root` call) |

Note: Window focus is automatically skipped for `/tmp/*` paths to prevent tests from opening VS Code windows.

## Common Issues

- **Extension not activating**: Must have a folder open (not just a file)
- **Wrong window**: Check registry has correct workspace path
- **Port conflict**: Extension finds next available port automatically
