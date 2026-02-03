# flocus — Focus & Flow for VS Code

Open files in the correct VS Code window based on your project. Reduce cognitive overhead by letting your tools manage window routing automatically.

## The Problem

When you have multiple VS Code windows open for different projects, the `code` command can't target a specific window:

```bash
code file.py      # Opens in a new window (wrong)
code -r file.py   # Opens in most recently focused (often wrong)
```

## The Solution

```bash
flocus open src/main.py    # Opens in the VS Code window that has this project open
```

`flocus` detects which project a file belongs to (via git root) and opens it in the correct window.

## Features

- **Project-aware**: Automatically finds the VS Code window with your project open
- **Window focus**: Brings the correct VS Code window to the foreground
- **Smart deduplication**: If file is already open, focuses that tab instead of duplicating
- **Line numbers**: `flocus open file.py:42` jumps to line 42
- **Scroll to top**: New files open at line 1; already-open files preserve scroll position
- **Zen mode**: `flocus open -z file.py` hides sidebar and panels for focus
- **Case-insensitive**: `flocus open readme.md` finds `README.md`
- **Custom editors**: `.md` files open in Mark Sharp by default
- **Reveal in Explorer**: Shows the file in the sidebar
- **List open files**: `flocus list` prints all open files in the current project
- **Directory support**: `flocus open ~/projects/myapp` opens folder in VS Code
- **Path-based fallback**: Files under any open workspace auto-route there
- **Orphan workspace**: Configure a default window for files outside any project
- **Agent-friendly**: `flocus --agent` provides context for AI agents
- **Fallback**: Falls back to `code` if no matching window found

## Installation

### 1. Install the VS Code Extension

```bash
# From the extension directory
code --install-extension extension/flocus-0.1.0.vsix
```

Or install manually:
1. Open VS Code
2. Press `Cmd+Shift+P` → "Extensions: Install from VSIX..."
3. Select `extension/flocus-0.1.0.vsix`

### 2. Install the CLI

Add the CLI to your PATH:

```bash
# Option 1: Symlink to a directory in your PATH
ln -s /path/to/flocus/cli/flocus ~/.local/bin/flocus

# Option 2: Add the cli directory to PATH in your shell config
export PATH="/path/to/flocus/cli:$PATH"
```

### 3. Dependencies

The CLI requires these commands (likely already installed):
- `jq` — JSON parsing
- `curl` — HTTP requests
- `git` — Project detection

## Usage

```bash
# Open file in correct project window
flocus open src/main.py

# Jump to specific line
flocus open src/main.py:142

# Open directory (registers for future calls)
flocus open ~/projects/myapp

# Zen mode (hide sidebar and panels)
flocus open -z README.md

# Use VS Code's default editor (bypass Mark Sharp for .md)
flocus open --raw notes.md

# List all open files in current project's VS Code window
flocus list

# Show context for AI agents
flocus --agent
```

## How It Works

1. **VS Code Extension** (`flocus`):
   - Runs in each VS Code window
   - Registers workspace + port in `~/.config/flocus/registry.json`
   - Listens for HTTP requests on localhost

2. **CLI** (`flocus`):
   - Resolves file path and detects git root
   - Reads registry to find matching VS Code window
   - Sends HTTP request to open the file

## Configuration

Config file: `~/.config/flocus/config.json`

```json
{
  "orphanWorkspace": "/home/user/scratch"
}
```

**orphanWorkspace**: Default VS Code window for files not in any git repo or open workspace. Open this folder in VS Code, and orphan files will route there.

### Matching Priority

When you run `flocus open <file>`, it tries to find the right VS Code window in this order:

1. **Git root** — If file is in a git repo, find window with that repo open
2. **Parent workspace** — If file is under any open VS Code folder
3. **Orphan workspace** — If configured in config.json
4. **Fallback** — Opens with `code` command

### Custom Editors

By default, `.md` files open in Mark Sharp editor. Use `--raw` to bypass this.

## Troubleshooting

**File opens in wrong window:**
- Ensure the extension is installed and active
- Check registry: `cat ~/.config/flocus/registry.json`
- The window must have the project folder open (not just the file)

**Extension not working:**
- Check VS Code output: View → Output → select "flocus"
- Restart VS Code after installing the extension

**Debug mode:**
```bash
FLOCUS_DEBUG=1 flocus open file.py
```

## Platform Support

- ✅ WSL2 Ubuntu (with VS Code Remote-WSL)
- ✅ macOS
- ✅ Linux

## License

MIT
