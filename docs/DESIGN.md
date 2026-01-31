# `vo` — Context-Aware VS Code File Opener

**Status:** Design Complete, Implementation Pending
**Created:** 2026-01-22
**Author:** Kyle + Claude

---

## 1. Problem Statement

### 1.1 The Pain Point

When working in a terminal, you often discover files you want to open in VS Code:

```bash
~/projects/muse $ grep -l "RetentionPolicy" src/**/*.py
src/core/memory/retention.py

# Now you want to open this file...
```

The native `code` command has a critical limitation: **it cannot target a specific VS Code window based on the project/workspace.**

Available options:
- `code file.py` → Opens in a new window (wrong)
- `code -r file.py` → Opens in most recently focused window (often wrong)
- `code -n file.py` → Opens in new window (definitely wrong)

If you have multiple VS Code windows open for different projects, there's no way to say: *"Open this file in the VS Code window that has THIS project open."*

### 1.2 The Current Workaround

1. Manually find the correct VS Code window
2. Click to focus it
3. Use VS Code's file explorer or Ctrl+P to find the file
4. Open it

This breaks flow, especially for users with ADHD or anyone who wants minimal context-switching.

### 1.3 The Goal

A single command that:
1. Detects which project the file belongs to (via git root)
2. Finds the VS Code window with that project open
3. Focuses that window
4. Opens the file
5. Reveals it in the Explorer sidebar

```bash
~/projects/muse/src/core $ vo memory/retention.py
# Correct VS Code window focuses, file opens, visible in Explorer
```

---

## 2. User Context

### 2.1 Primary User

- Works across **WSL2 Ubuntu** (desktop) and **macOS** (laptop)
- Uses **VS Code Remote-WSL extension** when on Windows/WSL2
- Has **ADHD** — minimizing friction and context-switching is important
- Uses **split editor panes** in VS Code
- Primarily opens **documentation files** (.md) but also code files
- Uses **Mark Sharp** extension for WYSIWYG markdown editing

### 2.2 Typical Workflow

1. Multiple VS Code windows open (different projects)
2. Terminal work in one of those projects
3. Discover a file via grep, find, ls, etc.
4. Want to view/edit it in VS Code immediately
5. Return focus to terminal to continue working

---

## 3. Requirements

### 3.1 Core Requirements (Must Have)

| ID | Requirement | Rationale |
|----|-------------|-----------|
| R1 | `vo <file>` opens file in VS Code window matching current git project | Core functionality |
| R2 | If matching window found → focus window, open file | Expected behavior |
| R3 | If no match → open file in new VS Code window | Graceful fallback |
| R4 | Cross-platform: WSL2 Ubuntu + macOS | User's two environments |
| R5 | Project detection via `git rev-parse --show-toplevel` | Reliable, standard |
| R6 | Duplicate project windows → pick most recently focused | Sensible default |
| R7 | Editor placement: VS Code default (active editor group) | Respect user's split pane setup |
| R8 | CLI command: `vo` | Short, fast to type |
| R9 | Reveal file in Explorer sidebar (expand parents, highlight) | Full context, not just editor |
| R10 | `-z` flag forces zen/distraction-free mode | ADHD support, focus mode |
| R11 | `.md` files open with Mark Sharp editor by default | User's preferred markdown experience |
| R12 | User-configurable editor mappings per file extension | Extensibility |

### 3.2 Nice-to-Have (Prioritized)

| Priority | ID | Feature | Rationale |
|----------|-----|---------|-----------|
| 1 | N1 | Directory support: `vo <folder>` | Complete `code` replacement |
| 2 | N2 | Zen mode for orphan files (auto, not just -z) | Distraction-free for random files |
| 3 | N3 | Line number support: `vo file.py:142` | Jump from grep output |
| 4 | N4 | Multiple files: `vo *.md` | Batch open |

### 3.3 Flags

| Flag | Behavior |
|------|----------|
| `-z` | Zen mode: hide Explorer, hide panels, just the file |
| `--raw` | Bypass custom editor config, use VS Code default |

### 3.4 Out of Scope

- Override default `code` command
- Non-git projects (no detection mechanism)
- Column number support (`:line:col`)
- Remote SSH workspaces (different architecture)

---

## 4. Technical Design

### 4.1 Architecture Overview

The solution has two components:

```
┌─────────────────────────────────────────────────────────────────┐
│                         TERMINAL                                 │
│                                                                  │
│   $ vo src/file.py                                               │
│         │                                                        │
│         ▼                                                        │
│   ┌─────────────┐                                                │
│   │   vo CLI    │  (Shell script or small binary)                │
│   └─────────────┘                                                │
│         │                                                        │
│         │ 1. Resolve file to absolute path                       │
│         │ 2. Detect git root                                     │
│         │ 3. Read registry: which window has this workspace?     │
│         │ 4. Send HTTP request to that window's extension        │
│         │                                                        │
└─────────│────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      VS CODE WINDOW                              │
│                                                                  │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │              vo-server Extension                         │   │
│   │                                                          │   │
│   │  • On activation: register workspace + port in registry  │   │
│   │  • Listen on localhost:<port> for open requests          │   │
│   │  • On request: open file, reveal in explorer, focus      │   │
│   │  • On deactivation: remove from registry                 │   │
│   │                                                          │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 Component 1: VS Code Extension (`vo-server`)

#### 4.2.1 Activation

The extension activates when any folder is opened in VS Code. On activation:

```typescript
// Pseudo-code
async function activate(context: vscode.ExtensionContext) {
  const workspaceRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  if (!workspaceRoot) return;

  // Find available port
  const port = await findAvailablePort(19800, 19900);

  // Start HTTP server
  const server = http.createServer(handleRequest);
  server.listen(port, '127.0.0.1');

  // Register in shared registry
  await registerWindow({
    workspace: workspaceRoot,
    port: port,
    pid: process.pid,
    lastActive: Date.now()
  });

  // Update lastActive on window focus
  vscode.window.onDidChangeWindowState((state) => {
    if (state.focused) {
      updateLastActive(workspaceRoot, Date.now());
    }
  });

  // Cleanup on deactivation
  context.subscriptions.push({
    dispose: () => {
      server.close();
      unregisterWindow(workspaceRoot, port);
    }
  });
}
```

#### 4.2.2 HTTP Server Endpoints

```
POST /open
Content-Type: application/json

{
  "file": "/absolute/path/to/file.py",
  "line": 142,                          // optional
  "zen": false,                         // optional
  "raw": false,                         // optional
  "reveal": true                        // optional, default true
}
```

Response:
```json
{
  "success": true,
  "editor": "msharp.customEditor"       // which editor was used
}
```

#### 4.2.3 Open File Logic

```typescript
async function handleOpenRequest(params: OpenParams) {
  const uri = vscode.Uri.file(params.file);
  const ext = path.extname(params.file);

  // Determine which editor to use
  let editorId: string | undefined;
  if (!params.raw) {
    const config = loadConfig();
    editorId = config.editors?.[ext];  // e.g., ".md" -> "msharp.customEditor"
  }

  // Apply zen mode if requested
  if (params.zen) {
    await vscode.commands.executeCommand('workbench.action.closeSidebar');
    await vscode.commands.executeCommand('workbench.action.closePanel');
  }

  // Open the file
  if (editorId) {
    await vscode.commands.executeCommand('vscode.openWith', uri, editorId);
  } else {
    const doc = await vscode.workspace.openTextDocument(uri);
    const editor = await vscode.window.showTextDocument(doc);

    // Jump to line if specified
    if (params.line) {
      const position = new vscode.Position(params.line - 1, 0);
      editor.selection = new vscode.Selection(position, position);
      editor.revealRange(new vscode.Range(position, position));
    }
  }

  // Reveal in explorer (unless zen mode)
  if (params.reveal && !params.zen) {
    await vscode.commands.executeCommand('revealInExplorer', uri);
  }

  // Focus the window
  await vscode.commands.executeCommand('workbench.action.focusActiveEditorGroup');
}
```

#### 4.2.4 Registry File

Location: `~/.config/vo/registry.json` (Linux/macOS) or platform equivalent

```json
{
  "version": 1,
  "windows": [
    {
      "workspace": "/home/kyle/projects/muse",
      "port": 19801,
      "pid": 12345,
      "lastActive": 1737561234567
    },
    {
      "workspace": "/home/kyle/projects/general-tools",
      "port": 19802,
      "pid": 12346,
      "lastActive": 1737561230000
    }
  ]
}
```

The registry is a simple JSON file. Concurrent access is handled via file locking or atomic writes.

### 4.3 Component 2: CLI Tool (`vo`)

#### 4.3.1 Implementation Options

| Option | Pros | Cons |
|--------|------|------|
| Bash script | Simple, no build step, works everywhere | String handling, less robust |
| Node.js | JS ecosystem, easy HTTP requests | Requires Node runtime |
| Go binary | Fast, single binary, cross-platform | Compile step, more complex |
| Python | Available on most systems | Startup time |

**Recommendation:** Start with **Bash script** for simplicity. Rewrite in Go/Rust later if needed.

#### 4.3.2 CLI Logic (Bash)

```bash
#!/usr/bin/env bash
# vo - Context-aware VS Code file opener

set -euo pipefail

# Parse arguments
ZEN=false
RAW=false
FILE=""
LINE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -z|--zen)
      ZEN=true
      shift
      ;;
    --raw)
      RAW=true
      shift
      ;;
    *)
      # Parse file:line format
      if [[ "$1" =~ ^(.+):([0-9]+)$ ]]; then
        FILE="${BASH_REMATCH[1]}"
        LINE="${BASH_REMATCH[2]}"
      else
        FILE="$1"
      fi
      shift
      ;;
  esac
done

# Resolve to absolute path
FILE=$(realpath "$FILE")

# Detect git root
GIT_ROOT=$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel 2>/dev/null || echo "")

# Read registry
REGISTRY="${XDG_CONFIG_HOME:-$HOME/.config}/vo/registry.json"

if [[ -f "$REGISTRY" && -n "$GIT_ROOT" ]]; then
  # Find matching window(s), sort by lastActive descending
  MATCH=$(jq -r --arg ws "$GIT_ROOT" '
    .windows
    | map(select(.workspace == $ws))
    | sort_by(-.lastActive)
    | .[0]
    | .port // empty
  ' "$REGISTRY")
fi

# Build request payload
PAYLOAD=$(jq -n \
  --arg file "$FILE" \
  --arg line "${LINE:-}" \
  --argjson zen "$ZEN" \
  --argjson raw "$RAW" \
  '{file: $file, zen: $zen, raw: $raw} + (if $line != "" then {line: ($line | tonumber)} else {} end)'
)

if [[ -n "${MATCH:-}" ]]; then
  # Ping to verify window is alive
  if curl -s --max-time 0.5 "http://127.0.0.1:$MATCH/health" >/dev/null 2>&1; then
    # Send open request
    curl -s -X POST "http://127.0.0.1:$MATCH/open" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD"
    exit 0
  fi
fi

# No match or dead window — fall back to opening new window
if [[ "$ZEN" == "true" ]]; then
  # Open file only, no folder context
  code "$FILE"
  # TODO: Could invoke extension command for zen mode after
else
  # Open with project context
  if [[ -n "$GIT_ROOT" ]]; then
    code "$GIT_ROOT" "$FILE"
  else
    code "$FILE"
  fi
fi
```

#### 4.3.3 WSL2 Considerations

When running in WSL2 with VS Code Remote-WSL:

1. **VS Code runs on Windows**, but the extension host runs in WSL
2. The registry file should be in the **WSL filesystem** (`~/.config/vo/`)
3. The HTTP server binds to WSL's localhost, which is accessible from WSL terminals
4. Paths are Linux paths (`/home/kyle/...`), not Windows paths

The Remote-WSL extension handles path translation internally. Our extension running in the WSL extension host will receive Linux paths and operate correctly.

**Key insight:** Because VS Code Remote-WSL runs the extension in WSL's context, the architecture works the same as native Linux. No special path translation needed.

### 4.4 Component 3: User Configuration

#### 4.4.1 Config File Location

`~/.config/vo/config.json`

#### 4.4.2 Schema

```json
{
  "editors": {
    ".md": "msharp.customEditor",
    ".csv": "gc-excelviewer.csvEditor",
    ".pdf": "tomoki1207.pdf"
  }
}
```

If the file doesn't exist, defaults are used:
```json
{
  "editors": {
    ".md": "msharp.customEditor"
  }
}
```

The `--raw` flag bypasses this entirely, using VS Code's default editor.

### 4.5 Edge Cases & Error Handling

| Scenario | Behavior |
|----------|----------|
| File doesn't exist | VS Code creates new unsaved file (default behavior) |
| Git root detection fails | Treat as no match, open in new window |
| Registry file missing | Create empty registry, proceed as no match |
| Extension port unreachable | Prune from registry, proceed as no match |
| Multiple windows same workspace | Use most recent (`lastActive`) |
| Stale registry entry (crashed VS Code) | Health check fails, prune and proceed |
| No VS Code running at all | Falls back to `code` command, launches new |

### 4.6 Security Considerations

- HTTP server binds to `127.0.0.1` only (not accessible from network)
- No authentication needed (localhost-only)
- File paths are validated to exist on disk before opening
- No arbitrary command execution (only file opening)

---

## 5. User Experience Flows

### 5.1 Happy Path: File in Open Project

```
Terminal                          Extension                    VS Code Window
   │                                  │                             │
   │  vo src/file.py                  │                             │
   │────────────────────────────────▶ │                             │
   │  1. Resolve path                 │                             │
   │  2. Get git root: /home/u/muse   │                             │
   │  3. Read registry                │                             │
   │  4. Find port 19801              │                             │
   │                                  │                             │
   │  POST :19801/open {file:...}     │                             │
   │────────────────────────────────▶ │                             │
   │                                  │  openTextDocument()         │
   │                                  │────────────────────────────▶│
   │                                  │  showTextDocument()         │
   │                                  │────────────────────────────▶│
   │                                  │  revealInExplorer()         │
   │                                  │────────────────────────────▶│
   │                                  │  focusWindow()              │
   │                                  │────────────────────────────▶│
   │  {success: true}                 │                             │
   │◀──────────────────────────────── │                             │
   │                                  │                             │
   ▼                                  ▼                             ▼
Terminal ready                   Request done              Window focused,
for next command                                           file open,
                                                           visible in Explorer
```

### 5.2 No Match: Opens New Window

```
Terminal
   │
   │  vo ~/random/notes.md
   │
   │  1. Resolve path
   │  2. Get git root: (none)
   │  3. No match possible
   │
   │  code ~/random/notes.md
   │─────────────────────────────▶ New VS Code window opens
   │
   ▼
Terminal ready
```

### 5.3 Zen Mode

```
Terminal                          Extension                    VS Code Window
   │                                  │                             │
   │  vo -z src/file.py               │                             │
   │────────────────────────────────▶ │                             │
   │                                  │                             │
   │  POST :19801/open {zen:true}     │                             │
   │────────────────────────────────▶ │                             │
   │                                  │  closeSidebar()             │
   │                                  │────────────────────────────▶│
   │                                  │  closePanel()               │
   │                                  │────────────────────────────▶│
   │                                  │  openTextDocument()         │
   │                                  │────────────────────────────▶│
   │                                  │  (no revealInExplorer)      │
   │                                  │                             │
```

---

## 6. Implementation Plan

### Phase 1: Minimal Viable Product

1. **Extension skeleton** — Activation, HTTP server, registry write
2. **Basic open handler** — Open file, focus window
3. **CLI script** — Bash, reads registry, sends request
4. **Manual testing** on macOS

Deliverable: `vo file.py` works on single platform

### Phase 2: Core Features

1. **Reveal in Explorer** — Full navigation context
2. **Zen mode** — `-z` flag support
3. **Line number support** — `file.py:142`
4. **WSL2 testing** — Verify Remote-WSL compatibility

Deliverable: All R1-R10 requirements met

### Phase 3: Polish

1. **Custom editor mappings** — Config file, Mark Sharp default
2. **`--raw` flag** — Bypass custom editors
3. **Registry cleanup** — Prune stale entries on read
4. **Error handling** — Graceful failures, helpful messages

Deliverable: All R11-R12 requirements met

### Phase 4: Nice-to-Haves

1. **Directory support** (N1)
2. **Auto zen mode for orphan files** (N2)
3. **Multiple files** (N4)

---

## 7. Open Questions

| Question | Current Decision | Notes |
|----------|------------------|-------|
| Extension distribution | TBD | Marketplace vs local .vsix |
| Config file format | JSON | Could be YAML, TOML |
| CLI rewrite language | Bash first | Go/Rust if performance matters |
| Should zen mode restore state after? | No | Keep it simple |

---

## 8. Appendix

### 8.1 VS Code Extension API References

- `vscode.workspace.openTextDocument(uri)` — Load document
- `vscode.window.showTextDocument(doc)` — Show in editor
- `vscode.commands.executeCommand('revealInExplorer', uri)` — Show in sidebar
- `vscode.commands.executeCommand('vscode.openWith', uri, editorId)` — Open with specific editor
- `vscode.commands.executeCommand('workbench.action.closeSidebar')` — Hide Explorer
- `vscode.commands.executeCommand('workbench.action.closePanel')` — Hide terminal/output

### 8.2 Mark Sharp Integration

Editor ID: `msharp.customEditor`

To open a markdown file directly in Mark Sharp:
```typescript
await vscode.commands.executeCommand('vscode.openWith', uri, 'msharp.customEditor');
```

### 8.3 Related Tools Evaluated

| Tool | What It Does | Why Not Sufficient |
|------|--------------|-------------------|
| `code` CLI | Opens files/folders | No workspace-aware window targeting |
| [code-connect](https://github.com/chvolkmann/code-connect) | IPC socket discovery | Uses first active socket, not workspace-matched |
| `wmctrl`/`xdotool` | Window management | X11 only, fragile, no editor integration |
| AppleScript | macOS window control | macOS only, no direct editor integration |
