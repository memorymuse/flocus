# Flocus: Marketplace Publication Design

**Status**: Draft
**Last Updated**: 2026-02-07
**Purpose**: Comprehensive plan for publishing flocus to the VS Code Marketplace

---

## 1. Context

Flocus is a context-aware VS Code file opener. It routes `flocus open <file>` to the correct VS Code window based on git project — something the built-in `code` command cannot do when multiple windows are open.

The tool works and is well-tested (44 integration + unit tests, all real — no mocks). This document covers everything needed to go from "works on my machine" to "installable by anyone from the VS Code Marketplace."

### 1.1 Current Architecture

```
User terminal                     VS Code Window (per workspace)
┌──────────────┐                 ┌─────────────────────────────┐
│  flocus CLI  │─── HTTP ───────▶│  flocus extension           │
│  (bash)      │   localhost     │  ├─ HTTP server (port 198xx)│
│              │                 │  ├─ registry.json manager   │
│              │◀── JSON ────────│  └─ file opener / navigator │
└──────────────┘                 └─────────────────────────────┘
       │
       ▼
~/.config/flocus/registry.json
```

- **Extension**: Runs in each VS Code window, registers workspace+port, handles file open requests
- **CLI**: Bash script, resolves file path, finds matching window via registry, sends HTTP request
- **Registry**: JSON file mapping workspaces to ports, auto-managed by extension

### 1.2 What Works Today

- File opening with correct window targeting (git root matching)
- Path-based fallback (files under any open workspace)
- Orphan workspace config (default window for files outside any project)
- Line number support (`file:42`)
- Zen mode (`-z` flag)
- Duplicate detection (focuses existing tab)
- Case-insensitive paths
- Directory support
- Custom editor mappings (hardcoded to Mark Sharp — needs generalization)
- Server identity verification (workspace mismatch detection, stale entry pruning)
- Comprehensive test suite

---

## 2. Publication Requirements

### 2.1 Marketplace Metadata (package.json)

Current state → required changes:

| Field | Current | Required |
|-------|---------|----------|
| `publisher` | `"local"` | Real publisher account (e.g., `"kysonk"`) |
| `repository` | missing | `{"type": "git", "url": "https://github.com/..."}` |
| `icon` | missing | `"icon.png"` (128x128px minimum) |
| `categories` | `["Other"]` | `["Other", "Developer Tools"]` or similar |
| `keywords` | missing | `["file-opener", "multi-window", "workspace", "focus"]` |
| `contributes` | `{}` | Configuration settings (see Section 3) |
| `homepage` | missing | GitHub repo URL |

**Action**: Register a VS Code Marketplace publisher account at https://marketplace.visualstudio.com/manage. This requires an Azure DevOps organization (free) and a personal access token.

### 2.2 Extension README

The marketplace displays `README.md` from the extension package root. Currently, the extension directory has no README — the project README is at the repo root.

**Action**: Create `extension/README.md` tailored for marketplace consumers:
- One-line value proposition
- GIF/screenshot showing the tool in action (terminal → correct window opens)
- Installation instructions (marketplace install + "Install CLI" command)
- Basic usage examples
- Link to full docs

### 2.3 Changelog

**Action**: Create `extension/CHANGELOG.md` with version history. Can be minimal for v1.0:
```markdown
## 1.0.0
- Initial marketplace release
- Context-aware file opening based on git project
- CLI tool for terminal integration
```

### 2.4 Icon

**Action**: Create `extension/icon.png` — 128x128px minimum, simple geometric design. A focus/crosshair motif would match the "flocus" name (focus + flow).

### 2.5 License

MIT license is already declared in package.json. Ensure a `LICENSE` file exists in the extension directory (vsce warns if missing).

---

## 3. Configuration System

### 3.1 Custom Editor Mappings

**Problem**: The `getCustomEditor()` function at `extension/src/extension.ts:253` hardcodes Mark Sharp (`msharp.customEditor`) as the editor for `.md` files. This is a personal preference, not a general default.

**Design**:

Add a VS Code setting `flocus.customEditors` — an object mapping file extensions to editor IDs:

```jsonc
// User's settings.json
{
    "flocus.customEditors": {
        ".md": "msharp.customEditor",
        ".csv": "janisdd.vscode-edit-csv"
    }
}
```

**package.json `contributes.configuration`**:
```json
{
    "contributes": {
        "configuration": {
            "title": "flocus",
            "properties": {
                "flocus.customEditors": {
                    "type": "object",
                    "default": {},
                    "description": "Map file extensions to custom editor IDs. Example: {\".md\": \"msharp.customEditor\"}",
                    "patternProperties": {
                        "^\\.": {
                            "type": "string",
                            "description": "VS Code editor ID (find in extension details)"
                        }
                    }
                }
            }
        }
    }
}
```

**Implementation change** in `getCustomEditor()`:
```typescript
function getCustomEditor(ext: string): string | undefined {
    const config = vscode.workspace.getConfiguration('flocus');
    const customEditors = config.get<Record<string, string>>('customEditors', {});
    const editorId = customEditors[ext];

    // Verify the editor extension is actually installed
    if (editorId) {
        const installed = vscode.extensions.getExtension(editorId.split('.')[0] + '.' + editorId.split('.')[1]);
        // If we can't verify installation, try it anyway — VS Code will fall back gracefully
        return editorId;
    }

    return undefined;
}
```

**Key decision**: No default mappings. Users opt in to custom editors explicitly. This avoids the Mark Sharp dependency entirely.

**Migration for existing users**: Document in CHANGELOG that `.md` files will now use VS Code's default editor unless `flocus.customEditors` is configured.

### 3.2 Additional Settings (Optional, Lower Priority)

These are nice-to-have, not blocking:

```json
{
    "flocus.enableDebugLogging": {
        "type": "boolean",
        "default": false,
        "description": "Enable debug logging in the output channel"
    },
    "flocus.cliAutoInstall": {
        "type": "boolean",
        "default": true,
        "description": "Automatically maintain CLI symlink on extension activation"
    }
}
```

---

## 4. CLI Installation via Extension

### 4.1 Overview

The CLI (bash script) is bundled inside the VSIX package. The extension provides two mechanisms to make it available:

1. **Automatic**: On every activation, silently maintain a symlink at `~/.local/bin/flocus`
2. **Manual**: A command palette entry "flocus: Install CLI" for first-time setup or troubleshooting

### 4.2 File Structure

```
extension/
├── bin/
│   └── flocus              # The bash CLI script (copied from cli/vo)
├── src/
│   └── extension.ts
├── package.json
├── icon.png
├── README.md
├── CHANGELOG.md
└── .vscodeignore           # Must NOT exclude bin/
```

**Important**: The CLI script lives in TWO places during development:
- `cli/vo` — the development/source copy (what we edit and test against)
- `extension/bin/flocus` — the copy bundled into the VSIX

A build step (or simple `cp cli/vo extension/bin/flocus`) keeps them in sync before packaging. This should be added to the `vscode:prepublish` script.

### 4.3 Symlink Strategy

**Target location**: `~/.local/bin/flocus`

**Rationale**:
- `~/.local/bin` is the XDG standard for user-local binaries
- No sudo/admin privileges required
- Most Linux distributions and modern macOS include `~/.local/bin` in PATH (or it's trivial to add)
- Avoids the `/usr/local/bin` permission dance that VS Code's own `code` command struggles with

**Symlink vs copy**: Use **symlink**. This way, when the extension updates (new version = new extension directory), the symlink is simply re-pointed on next activation. No file content sync needed.

**The version change problem**: The extension path includes the version number:
```
~/.vscode-server/extensions/publisher.flocus-1.0.0/bin/flocus
~/.vscode-server/extensions/publisher.flocus-1.1.0/bin/flocus  ← new version
```

When VS Code updates an extension, the old directory is removed. A symlink pointing to the old path breaks. **Solution**: Re-create the symlink on every activation. Since flocus uses `onStartupFinished`, this happens automatically whenever any VS Code window opens.

### 4.4 Implementation

```typescript
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

const CLI_INSTALL_DIR = path.join(os.homedir(), '.local', 'bin');
const CLI_LINK_NAME = 'flocus';

async function installCli(context: vscode.ExtensionContext, silent: boolean = false): Promise<void> {
    const cliSource = path.join(context.extensionPath, 'bin', 'flocus');
    const cliTarget = path.join(CLI_INSTALL_DIR, CLI_LINK_NAME);

    // Verify the bundled CLI exists
    if (!fs.existsSync(cliSource)) {
        if (!silent) {
            vscode.window.showErrorMessage('flocus: CLI script not found in extension package.');
        }
        console.error('[flocus] CLI script not found at:', cliSource);
        return;
    }

    // Ensure the script is executable
    await fs.promises.chmod(cliSource, 0o755);

    // Ensure target directory exists
    await fs.promises.mkdir(CLI_INSTALL_DIR, { recursive: true });

    // Create/update symlink (idempotent)
    try {
        const existing = await fs.promises.lstat(cliTarget);
        if (existing.isSymbolicLink()) {
            const currentTarget = await fs.promises.readlink(cliTarget);
            if (currentTarget === cliSource) {
                // Already correct, no-op
                return;
            }
        }
        // Remove stale symlink or file
        await fs.promises.unlink(cliTarget);
    } catch (error: any) {
        if (error.code !== 'ENOENT') {
            console.error('[flocus] Error checking existing CLI:', error);
        }
        // ENOENT is fine — means nothing exists at target
    }

    try {
        await fs.promises.symlink(cliSource, cliTarget);
        console.log(`[flocus] CLI installed: ${cliTarget} -> ${cliSource}`);
        if (!silent) {
            vscode.window.showInformationMessage(
                `flocus CLI installed at ${cliTarget}. Ensure ~/.local/bin is in your PATH.`
            );
        }
    } catch (error: any) {
        console.error('[flocus] Failed to install CLI:', error);
        if (!silent) {
            vscode.window.showErrorMessage(
                `flocus: Failed to install CLI at ${cliTarget}: ${error.message}`
            );
        }
    }
}
```

### 4.5 Integration Points

**In `activate()`**:
```typescript
export async function activate(context: vscode.ExtensionContext): Promise<void> {
    // ... existing workspace/server setup ...

    // Auto-maintain CLI symlink (silent — don't bother user on every activation)
    const autoInstall = vscode.workspace.getConfiguration('flocus').get('cliAutoInstall', true);
    if (autoInstall) {
        installCli(context, /* silent */ true);
    }
}
```

**Register manual command** (in `activate()`):
```typescript
context.subscriptions.push(
    vscode.commands.registerCommand('flocus.installCLI', () => {
        installCli(context, /* silent */ false);
    })
);
```

**In package.json**:
```json
{
    "contributes": {
        "commands": [
            {
                "command": "flocus.installCLI",
                "title": "flocus: Install CLI"
            }
        ]
    },
    "activationEvents": [
        "onStartupFinished",
        "onCommand:flocus.installCLI"
    ]
}
```

### 4.6 Build Step: Sync CLI to Extension

Add to `extension/package.json` scripts:
```json
{
    "scripts": {
        "vscode:prepublish": "npm run sync-cli && npm run compile",
        "sync-cli": "mkdir -p bin && cp ../cli/vo bin/flocus && chmod +x bin/flocus"
    }
}
```

This ensures the CLI in the VSIX is always the latest version from `cli/vo`.

### 4.7 PATH Guidance

If `~/.local/bin` is not in the user's PATH, the "Install CLI" command should detect this and provide guidance:

```typescript
// After successful symlink creation
const pathDirs = (process.env.PATH || '').split(':');
if (!pathDirs.includes(CLI_INSTALL_DIR)) {
    const shell = process.env.SHELL || '/bin/bash';
    const rcFile = shell.includes('zsh') ? '~/.zshrc' : '~/.bashrc';
    vscode.window.showWarningMessage(
        `flocus CLI installed, but ~/.local/bin is not in your PATH. Add to ${rcFile}: export PATH="$HOME/.local/bin:$PATH"`,
        'Copy to Clipboard'
    ).then(selection => {
        if (selection === 'Copy to Clipboard') {
            vscode.env.clipboard.writeText('export PATH="$HOME/.local/bin:$PATH"');
        }
    });
}
```

---

## 5. CLI Dependencies

The CLI requires `jq`, `curl`, `git`, and `realpath` (coreutils). These are standard on most Linux/macOS systems but should be documented.

**Action**: Add dependency check guidance to the extension README and to the "Install CLI" command output if any are missing.

The CLI could optionally check for these on first run and print an actionable error:
```bash
for cmd in jq curl git realpath; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: flocus requires '$cmd'. Install it with your package manager." >&2
        exit 1
    fi
done
```

This check already exists in the test runner but not in the CLI itself. Add it to `main()` in the CLI script.

---

## 6. Platform Considerations

### 6.1 Supported Platforms

| Platform | CLI Support | Extension Support | Notes |
|----------|-------------|-------------------|-------|
| Linux | Yes | Yes | Primary target |
| macOS | Yes | Yes | `realpath` available 10.13+ |
| WSL2 | Yes | Yes | Designed for this |
| Windows (native) | No | Yes (extension only) | CLI is bash; would need PowerShell port for native Windows |

**Decision**: Ship as Linux/macOS/WSL2 only for v1.0. Document this clearly. A PowerShell CLI port is a separate future effort and should not block publication.

### 6.2 VS Code Remote Development

Flocus works in VS Code Remote (SSH, WSL, Containers) because:
- The extension runs in the remote extension host (where the files are)
- The HTTP server listens on the remote machine's localhost
- The CLI runs on the remote machine alongside the files
- The registry is on the remote machine's filesystem

This is a natural fit — no special handling needed.

---

## 7. Naming & Branding

### 7.1 CLI Binary Name

The CLI is currently at `cli/vo` (original name) but the project is "flocus." The binary should be `flocus`.

**Action**: The sync-cli build step already handles this (`cp ../cli/vo bin/flocus`). The source file can remain `cli/vo` for backward compatibility, or be renamed to `cli/flocus`. Renaming is cleaner but breaks existing muscle memory.

**Decision**: Rename `cli/vo` to `cli/flocus` for consistency. Update test references.

### 7.2 Extension Display Name

Current: `"displayName": "flocus"`

Options:
- `"flocus"` — clean, minimal
- `"flocus - Context-Aware File Opener"` — more descriptive, better marketplace search
- `"flocus: Focus & Flow for VS Code"` — matches the tagline

**Recommendation**: `"flocus - Smart File Opener"` — concise, searchable, descriptive.

---

## 8. Version Strategy

### 8.1 Initial Version

Publish as **1.0.0**, not 0.1.0. The tool is feature-complete for its core use case, well-tested, and stable. A 0.x version signals "not ready" on the marketplace and discourages adoption.

### 8.2 Versioning Scheme

Follow semver:
- **Major** (2.0.0): Breaking changes to CLI flags, config format, or behavior
- **Minor** (1.1.0): New features (e.g., `flocus close`, profiles)
- **Patch** (1.0.1): Bug fixes

---

## 9. Implementation Checklist

Ordered by dependency — each item builds on the previous.

### Phase A: Marketplace Preparation

1. [ ] Register VS Code Marketplace publisher account
2. [ ] Create `extension/icon.png` (128x128px)
3. [ ] Create `extension/README.md` (marketplace-facing)
4. [ ] Create `extension/CHANGELOG.md`
5. [ ] Add `LICENSE` file to extension directory
6. [ ] Update `extension/package.json`:
   - Set real `publisher`
   - Add `repository`, `homepage`, `icon`, `keywords`
   - Update `categories` to `["Developer Tools"]`
   - Update `displayName`
   - Bump version to `1.0.0`

### Phase B: Configuration System

7. [ ] Add `contributes.configuration` to package.json (custom editor mappings)
8. [ ] Refactor `getCustomEditor()` to read from VS Code settings instead of hardcoded map
9. [ ] Remove Mark Sharp hardcoding entirely (no default mappings)
10. [ ] Add tests for new configuration behavior

### Phase C: CLI Bundling & Installation

11. [ ] Create `extension/bin/` directory
12. [ ] Add `sync-cli` script to package.json
13. [ ] Update `.vscodeignore` to NOT exclude `bin/`
14. [ ] Implement `installCli()` function in extension.ts
15. [ ] Register `flocus.installCLI` command
16. [ ] Add auto-install on activation (silent, behind `cliAutoInstall` setting)
17. [ ] Add PATH detection and guidance
18. [ ] Add dependency check to CLI script (`jq`, `curl`, `git`, `realpath`)
19. [ ] Test CLI installation: fresh install, update, broken symlink recovery
20. [ ] Add `contributes.commands` to package.json

### Phase D: Cleanup & Polish

21. [ ] Rename `cli/vo` to `cli/flocus` (update all test references)
22. [ ] Remove `--allow-missing-repository` from package script
23. [ ] Create demo GIF for README (optional but highly recommended)
24. [ ] Run `vsce ls` to verify package contents
25. [ ] Test on a fresh VS Code profile (no prior flocus state)

### Phase E: Publication

26. [ ] `vsce package` — verify clean build
27. [ ] `vsce publish` — publish to marketplace
28. [ ] Verify listing appears on marketplace
29. [ ] Install from marketplace on a fresh machine, run through full workflow
30. [ ] Create GitHub release with same version tag

---

## 10. Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Symlink breaks on extension update | Medium | Auto-recreate on activation (Section 4.3) |
| `~/.local/bin` not in user's PATH | Medium | Detection + guidance message (Section 4.7) |
| User lacks CLI dependencies (jq, curl) | Low | Actionable error message on first run (Section 5) |
| Mark Sharp users lose custom editor on upgrade | Low | Document migration in CHANGELOG (Section 3.1) |
| Extension activates unnecessarily | Low | `onStartupFinished` is non-blocking; overhead is minimal |
| Marketplace rejection | Low | All requirements are well-documented; no unusual permissions |

---

## 11. Future Considerations (Post-Publication)

These are explicitly out of scope for v1.0 but worth noting:

- **`flocus close` command**: Close tabs by file path (CLI → extension)
- **Profiles**: `flocus profile <name>` to open predefined file sets
- **Multiple file open**: `flocus open *.md` with `--all` flag
- **Windows PowerShell CLI**: Native Windows support without WSL
- **Auto zen mode**: Configurable per-workspace zen mode defaults
- **Registry cleanup command**: `flocus prune` to manually clean stale entries
- **CI/CD pipeline**: GitHub Actions for automated testing and marketplace publishing on release tags

---

## 12. Key Files Reference

| File | Role | Changes Needed |
|------|------|----------------|
| `extension/package.json` | Extension manifest | Metadata, contributes, commands, scripts |
| `extension/src/extension.ts` | Main extension | CLI install, config reading, command registration |
| `extension/.vscodeignore` | Package exclusions | Ensure `bin/` not excluded |
| `cli/vo` (→ `cli/flocus`) | CLI script | Add dependency check, rename |
| `extension/README.md` | Marketplace README | Create from scratch |
| `extension/CHANGELOG.md` | Version history | Create from scratch |
| `extension/icon.png` | Marketplace icon | Create from scratch |
| `extension/bin/flocus` | Bundled CLI copy | Auto-generated by sync-cli |
| `docs/PUBLISH.md` | This document | Reference during implementation |
