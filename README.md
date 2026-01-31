# vo — Context-Aware VS Code File Opener

Open files in the correct VS Code window based on your project.

## The Problem

When you have multiple VS Code windows open for different projects, the `code` command can't target a specific window:

```bash
code file.py      # Opens in a new window (wrong)
code -r file.py   # Opens in most recently focused (often wrong)
```

## The Solution

```bash
vo src/main.py    # Opens in the VS Code window that has this project open
```

`vo` detects which project a file belongs to (via git root) and opens it in the correct window.

## Features

- **Project-aware**: Automatically finds the VS Code window with your project open
- **Window focus**: Brings the correct VS Code window to the foreground
- **Smart deduplication**: If file is already open, focuses that tab instead of duplicating
- **Line numbers**: `vo file.py:42` jumps to line 42
- **Scroll to top**: New files open at line 1; already-open files preserve scroll position
- **Zen mode**: `vo -z file.py` hides sidebar and panels for focus
- **Case-insensitive**: `vo readme.md` finds `README.md`
- **Custom editors**: `.md` files open in Mark Sharp by default
- **Reveal in Explorer**: Shows the file in the sidebar
- **List open files**: `vo -l` prints all open files in the current project
- **Fallback**: Falls back to `code` if no matching window found

## Installation

### 1. Install the VS Code Extension

```bash
# From the extension directory
code --install-extension extension/vo-server-0.1.0.vsix
```

Or install manually:
1. Open VS Code
2. Press `Cmd+Shift+P` → "Extensions: Install from VSIX..."
3. Select `extension/vo-server-0.1.0.vsix`

### 2. Install the CLI

Add the CLI to your PATH:

```bash
# Option 1: Symlink to a directory in your PATH
ln -s /path/to/vo/cli/vo ~/.local/bin/vo

# Option 2: Add the cli directory to PATH in your shell config
export PATH="/path/to/vo/cli:$PATH"
```

### 3. Dependencies

The CLI requires these commands (likely already installed):
- `jq` — JSON parsing
- `curl` — HTTP requests
- `git` — Project detection

## Usage

```bash
# Open file in correct project window
vo src/main.py

# Jump to specific line
vo src/main.py:142

# Zen mode (hide sidebar and panels)
vo -z README.md

# Use VS Code's default editor (bypass Mark Sharp for .md)
vo --raw notes.md

# List all open files in current project's VS Code window
vo -l
```

## How It Works

1. **VS Code Extension** (`vo-server`):
   - Runs in each VS Code window
   - Registers workspace + port in `~/.config/vo/registry.json`
   - Listens for HTTP requests on localhost

2. **CLI** (`vo`):
   - Resolves file path and detects git root
   - Reads registry to find matching VS Code window
   - Sends HTTP request to open the file

## Configuration

By default, `.md` files open in Mark Sharp editor. Use `--raw` to bypass this and use VS Code's default editor.

Custom editor mappings via `~/.config/vo/config.json` are planned for a future release.

## Troubleshooting

**File opens in wrong window:**
- Ensure the extension is installed and active
- Check registry: `cat ~/.config/vo/registry.json`
- The window must have the project folder open (not just the file)

**Extension not working:**
- Check VS Code output: View → Output → select "vo-server"
- Restart VS Code after installing the extension

**Debug mode:**
```bash
VO_DEBUG=1 vo file.py
```

## Platform Support

- ✅ WSL2 Ubuntu (with VS Code Remote-WSL)
- ✅ macOS
- ✅ Linux

## License

MIT
