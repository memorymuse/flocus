#!/usr/bin/env bash
# Integration tests for flocus CLI
# These are REAL tests - no mocks. They create actual files, git repos, and HTTP servers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FLOCUS_CLI="$PROJECT_ROOT/cli/vo"  # Still using vo as alias for now

# Test state
TEST_TMPDIR=""
FAILED=0
PASSED=0
SERVER_PIDS=()  # Track all server PIDs for cleanup

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# Cleanup: Kill any stuck test processes from previous runs
#-------------------------------------------------------------------------------
cleanup_stale_processes() {
    # Kill any leftover test servers from previous runs
    pkill -f "test_server.py" 2>/dev/null || true
    # Brief wait for processes to die
    sleep 0.1
}

#-------------------------------------------------------------------------------
# Test Utilities
#-------------------------------------------------------------------------------

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEST_TMPDIR/.config"
    mkdir -p "$XDG_CONFIG_HOME/flocus"
    SERVER_PIDS=()
}

teardown() {
    # Kill all tracked server PIDs
    for pid in "${SERVER_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    # Wait briefly for cleanup
    sleep 0.1
    for pid in "${SERVER_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    SERVER_PIDS=()

    if [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Global cleanup on exit (handles Ctrl+C, errors, etc.)
global_cleanup() {
    teardown
    cleanup_stale_processes
}
trap global_cleanup EXIT INT TERM

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [[ "$expected" != "$actual" ]]; then
        echo -e "${RED}FAIL${NC}: $msg"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        return 1
    fi
    return 0
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "${RED}FAIL${NC}: $msg"
        echo "  Expected to contain: $needle"
        echo "  Actual: $haystack"
        return 1
    fi
    return 0
}

run_test() {
    local test_name="$1"
    local test_fn="$2"

    setup

    echo -n "  $test_name ... "
    # Run test in subshell to isolate failures from set -e
    local result=0
    (set +e; $test_fn) || result=$?

    if [[ $result -eq 0 ]]; then
        echo -e "${GREEN}PASS${NC}"
        ((PASSED++)) || true
    else
        echo -e "${RED}FAIL${NC}"
        ((FAILED++)) || true
    fi

    teardown
}

#-------------------------------------------------------------------------------
# Helper: Create a git repo with files
#-------------------------------------------------------------------------------
create_git_repo() {
    local repo_path="$1"
    mkdir -p "$repo_path"
    git -C "$repo_path" init --quiet
    git -C "$repo_path" config user.email "test@test.com"
    git -C "$repo_path" config user.name "Test"
    echo "test" > "$repo_path/file.txt"
    git -C "$repo_path" add file.txt
    git -C "$repo_path" commit -m "init" --quiet
}

#-------------------------------------------------------------------------------
# Helper: Start test server using standalone Python script
# Returns the port via stdout, adds PID to SERVER_PIDS array
# Usage: start_test_server <log_file> [files_json] [workspace]
#-------------------------------------------------------------------------------
start_test_server() {
    local log_file="$1"
    local files_json="${2:-}"
    local workspace="${3:-}"
    local port_file="$TEST_TMPDIR/port_$$_$RANDOM"

    # Build args list for test_server.py: <log_file> <port> [files_json] [workspace]
    local args=("$SCRIPT_DIR/test_server.py" "$log_file" "0")
    if [[ -n "$files_json" || -n "$workspace" ]]; then
        args+=("${files_json:-null}")
    fi
    if [[ -n "$workspace" ]]; then
        args+=("$workspace")
    fi

    python3 "${args[@]}" > "$port_file" &
    local pid=$!
    SERVER_PIDS+=("$pid")

    # Wait for server to write port (with timeout)
    local attempts=0
    while [[ ! -s "$port_file" && $attempts -lt 20 ]]; do
        sleep 0.1
        ((attempts++))
    done

    if [[ ! -s "$port_file" ]]; then
        echo "ERROR: Server failed to start" >&2
        return 1
    fi

    local port
    port=$(cat "$port_file")
    rm -f "$port_file"

    echo "$port"
}

#-------------------------------------------------------------------------------
# Tests
#-------------------------------------------------------------------------------

test_cli_exists_and_executable() {
    [[ -x "$FLOCUS_CLI" ]] || return 1
}

test_no_args_focuses_project_in_git_repo() {
    # When called with no args inside a git repo, should focus the project window
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"

    local output
    output=$(cd "$repo/src" 2>/dev/null || cd "$repo" && FLOCUS_DRY_RUN=1 "$FLOCUS_CLI" 2>&1)

    # Should try to open the git root directory (not the subdirectory)
    assert_contains "$output" "[dry-run] code $repo" "Should focus project git root"
}

test_no_args_focuses_cwd_outside_git() {
    # When called with no args outside a git repo, should focus cwd
    local dir="$TEST_TMPDIR/standalone"
    mkdir -p "$dir"

    local output
    output=$(cd "$dir" && FLOCUS_DRY_RUN=1 "$FLOCUS_CLI" 2>&1)

    assert_contains "$output" "[dry-run] code $dir" "Should focus cwd when not in git repo"
}

test_no_args_focuses_registered_window() {
    # When called with no args and a server is registered for the project,
    # should focus that window (via code $git_root), not open a new one
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    mkdir -p "$repo/src"

    # Start test server for this workspace
    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    # Register the workspace
    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    local output
    output=$(cd "$repo/src" && FLOCUS_NO_FOCUS=1 "$FLOCUS_CLI" 2>&1)

    assert_contains "$output" "Focused: myproject" "Should report focusing registered project"
}

test_nonexistent_path_errors_early() {
    local output
    output=$("$FLOCUS_CLI" "/tmp/does/not/exist/file.py" 2>&1 || true)

    assert_contains "$output" "does not exist" "Should error on nonexistent path"
}

#-------------------------------------------------------------------------------
# Glob Pattern Tests
#-------------------------------------------------------------------------------

test_glob_single_match_opens_file() {
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    mkdir -p "$repo/docs"
    echo "design" > "$repo/docs/DESIGN.md"
    git -C "$repo" add docs/DESIGN.md
    git -C "$repo" commit -m "add design" --quiet

    # Start test server
    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    echo '{
        "version": 1,
        "windows": [{"workspace": "'"$repo"'", "port": '"$port"', "pid": 99999, "lastActive": 1737561234567}]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    local output
    output=$(cd "$repo" && FLOCUS_NO_FOCUS=1 "$FLOCUS_CLI" '*DESIGN*' 2>&1)

    assert_contains "$output" "Opened: DESIGN.md" "Should open the matched file"
}

test_glob_case_insensitive() {
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    echo "readme" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -m "add readme" --quiet

    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    echo '{
        "version": 1,
        "windows": [{"workspace": "'"$repo"'", "port": '"$port"', "pid": 99999, "lastActive": 1737561234567}]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    local output
    output=$(cd "$repo" && FLOCUS_NO_FOCUS=1 "$FLOCUS_CLI" '*readme*' 2>&1)

    assert_contains "$output" "Opened: README.md" "Should match case-insensitively"
}

test_glob_with_path_pattern() {
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    mkdir -p "$repo/src/app"
    echo "test" > "$repo/src/app/test_main.py"
    git -C "$repo" add src/app/test_main.py
    git -C "$repo" commit -m "add test" --quiet

    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    echo '{
        "version": 1,
        "windows": [{"workspace": "'"$repo"'", "port": '"$port"', "pid": 99999, "lastActive": 1737561234567}]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    local output
    output=$(cd "$repo" && FLOCUS_NO_FOCUS=1 "$FLOCUS_CLI" 'src/*/test_*.py' 2>&1)

    assert_contains "$output" "Opened: test_main.py" "Should match path pattern"
}

test_glob_multiple_matches_lists() {
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    echo "a" > "$repo/alpha.py"
    echo "b" > "$repo/beta.py"
    git -C "$repo" add alpha.py beta.py
    git -C "$repo" commit -m "add py files" --quiet

    local output
    output=$(cd "$repo" && "$FLOCUS_CLI" '*.py' 2>&1 || true)

    assert_contains "$output" "Multiple matches" "Should report multiple matches" || return 1
    assert_contains "$output" "alpha.py" "Should list alpha.py" || return 1
    assert_contains "$output" "beta.py" "Should list beta.py"
}

test_glob_no_matches_errors() {
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    echo "content" > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m "add file" --quiet

    local output
    output=$(cd "$repo" && "$FLOCUS_CLI" '*.xyz' 2>&1 || true)

    assert_contains "$output" "No files matching" "Should error on zero matches"
}

test_glob_with_line_number() {
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    mkdir -p "$repo/docs"
    echo "design" > "$repo/docs/DESIGN.md"
    git -C "$repo" add docs/DESIGN.md
    git -C "$repo" commit -m "add design" --quiet

    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    echo '{
        "version": 1,
        "windows": [{"workspace": "'"$repo"'", "port": '"$port"', "pid": 99999, "lastActive": 1737561234567}]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    local output
    output=$(cd "$repo" && FLOCUS_NO_FOCUS=1 "$FLOCUS_CLI" '*DESIGN*:42' 2>&1)

    assert_contains "$output" "Opened: DESIGN.md" "Should open matched file" || return 1

    # Verify line number was sent in request
    local request
    request=$(cat "$log_file")
    assert_contains "$request" '"line": 42' "Should send line number"
}

test_glob_non_git_fallback() {
    # Non-git directory should use find instead of git ls-files
    local dir="$TEST_TMPDIR/standalone"
    mkdir -p "$dir/sub"
    echo "content" > "$dir/sub/notes.txt"

    local output
    output=$(cd "$dir" && FLOCUS_DRY_RUN=1 "$FLOCUS_CLI" '*.txt' 2>&1)

    assert_contains "$output" "[dry-run] code" "Should find file and fall back to code"
}

test_glob_normal_path_unaffected() {
    # A normal path (no glob chars) should not trigger glob expansion
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    echo "content" > "$repo/main.py"

    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    echo '{
        "version": 1,
        "windows": [{"workspace": "'"$repo"'", "port": '"$port"', "pid": 99999, "lastActive": 1737561234567}]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    local output
    output=$(cd "$repo" && FLOCUS_NO_FOCUS=1 "$FLOCUS_CLI" main.py 2>&1)

    assert_contains "$output" "Opened: main.py" "Normal path should open without glob"
}

#-------------------------------------------------------------------------------
# Path Resolution Tests
#-------------------------------------------------------------------------------

test_resolves_relative_path() {
    # Create a git repo and file
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    mkdir -p "$repo/src"
    echo "content" > "$repo/src/module.py"

    # Start test server (gets dynamic port)
    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    # Create registry pointing to our server
    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    # Run vo from within the repo, using relative path
    (cd "$repo" && "$FLOCUS_CLI" src/module.py)

    # Verify the request contained absolute path
    local request
    request=$(cat "$log_file")
    assert_contains "$request" "$repo/src/module.py" "Request should contain absolute path"
}

test_detects_git_root() {
    # Create nested structure: repo/subdir/file.py
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"
    mkdir -p "$repo/deep/nested"
    echo "code" > "$repo/deep/nested/file.py"

    # Start test server
    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    # Create registry
    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    # Run from nested directory
    (cd "$repo/deep/nested" && "$FLOCUS_CLI" file.py)

    # Server should have received the request (meaning git root was detected correctly)
    [[ -f "$log_file" ]] || return 1
}

test_sends_correct_json_payload() {
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"
    echo "code" > "$repo/test.py"

    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    "$FLOCUS_CLI" "$repo/test.py"

    # Verify JSON structure
    local request
    request=$(cat "$log_file")

    # Should be valid JSON with required fields
    echo "$request" | jq -e '.file' >/dev/null || return 1
    echo "$request" | jq -e '.zen == false' >/dev/null || return 1
    echo "$request" | jq -e '.raw == false' >/dev/null || return 1
}

test_zen_flag() {
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"
    echo "code" > "$repo/test.py"

    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    "$FLOCUS_CLI" -z "$repo/test.py"

    local request
    request=$(cat "$log_file")
    echo "$request" | jq -e '.zen == true' >/dev/null || return 1
}

test_line_number_parsing() {
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"
    echo "code" > "$repo/test.py"

    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo")

    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    "$FLOCUS_CLI" "$repo/test.py:42"

    local request
    request=$(cat "$log_file")
    echo "$request" | jq -e '.line == 42' >/dev/null || return 1
}

test_picks_most_recent_window() {
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"
    echo "code" > "$repo/test.py"

    # Start both servers (get dynamic ports)
    local old_log="$TEST_TMPDIR/old_request.json"
    local new_log="$TEST_TMPDIR/new_request.json"
    local old_port
    old_port=$(start_test_server "$old_log" "" "$repo")
    local new_port
    new_port=$(start_test_server "$new_log" "" "$repo")

    # Two windows for same workspace, different lastActive times
    # The newer one (port $new_port) has higher lastActive
    echo '{
        "version": 1,
        "windows": [
            {
                "workspace": "'"$repo"'",
                "port": '"$old_port"',
                "pid": 99998,
                "lastActive": 1000
            },
            {
                "workspace": "'"$repo"'",
                "port": '"$new_port"',
                "pid": 99999,
                "lastActive": 2000
            }
        ]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    "$FLOCUS_CLI" "$repo/test.py"

    # Only the newer window should have received the request
    [[ ! -f "$old_log" ]] || return 1
    [[ -f "$new_log" ]] || return 1
}

test_fallback_when_no_registry() {
    # No registry file exists
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"
    echo "code" > "$repo/test.py"

    # Remove registry if it exists
    rm -f "$XDG_CONFIG_HOME/flocus/registry.json"

    # Use dry-run mode to avoid actually launching VS Code
    local output
    output=$(FLOCUS_DRY_RUN=1 "$FLOCUS_CLI" "$repo/test.py" 2>&1)

    # Should indicate it would call code command
    assert_contains "$output" "[dry-run] code" "Should fall back to code command"
}

test_fallback_when_server_dead() {
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"
    echo "code" > "$repo/test.py"

    # Registry points to a port with no server
    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": 19899,
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    # Use dry-run mode to avoid actually launching VS Code
    local output
    output=$(FLOCUS_DRY_RUN=1 "$FLOCUS_CLI" "$repo/test.py" 2>&1)

    # Should fall back to code command when server is unreachable
    assert_contains "$output" "[dry-run] code" "Should fall back to code command"
}

test_list_open_files() {
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"

    # Files that our mock server will report as open
    local files_json='["/project/src/main.ts", "/project/README.md", "/project/test.py"]'

    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "$files_json" "$repo")

    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    # Run from within the repo
    local output
    output=$(cd "$repo" && "$FLOCUS_CLI" --list)

    # Should output all three files
    assert_contains "$output" "/project/src/main.ts" "Should list main.ts" || return 1
    assert_contains "$output" "/project/README.md" "Should list README.md" || return 1
    assert_contains "$output" "/project/test.py" "Should list test.py" || return 1
}

test_list_no_matching_window() {
    # Create a directory that's not a git repo and not under any workspace
    local dir="$TEST_TMPDIR/not-a-repo"
    mkdir -p "$dir"

    # Empty registry
    echo '{"version": 1, "windows": []}' > "$XDG_CONFIG_HOME/flocus/registry.json"

    local output
    output=$(cd "$dir" && "$FLOCUS_CLI" --list 2>&1 || true)

    assert_contains "$output" "No VS Code window found" "Should error when no matching window"
}

test_list_requires_vscode_window() {
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"

    # Empty registry (no windows)
    echo '{"version": 1, "windows": []}' > "$XDG_CONFIG_HOME/flocus/registry.json"

    local output
    output=$(cd "$repo" && "$FLOCUS_CLI" --list 2>&1 || true)

    assert_contains "$output" "No VS Code window found" "Should error when no window found"
}

test_open_directory() {
    local dir="$TEST_TMPDIR/myproject"
    mkdir -p "$dir"

    local output
    output=$(FLOCUS_DRY_RUN=1 "$FLOCUS_CLI" "$dir" 2>&1)

    assert_contains "$output" "[dry-run] code $dir" "Should open directory with code command"
}

test_path_based_fallback() {
    # Create a non-git directory with a file
    local workspace="$TEST_TMPDIR/workspace"
    mkdir -p "$workspace/subdir"
    echo "content" > "$workspace/subdir/file.txt"

    # Start test server
    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$workspace")

    # Register the workspace (not a git repo)
    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$workspace"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    # Open a file under the workspace
    "$FLOCUS_CLI" "$workspace/subdir/file.txt"

    # Should have received the request
    [[ -f "$log_file" ]] || return 1
    local request
    request=$(cat "$log_file")
    assert_contains "$request" "$workspace/subdir/file.txt" "Request should contain file path"
}

test_orphan_workspace_config() {
    # Create an orphan file (not in git, not under any workspace)
    local orphan_dir="$TEST_TMPDIR/orphan"
    local orphan_workspace="$TEST_TMPDIR/orphan-ws"
    mkdir -p "$orphan_dir"
    mkdir -p "$orphan_workspace"
    echo "content" > "$orphan_dir/file.txt"

    # Start test server for orphan workspace
    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$orphan_workspace")

    # Register the orphan workspace
    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$orphan_workspace"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    # Configure orphan workspace
    echo '{
        "orphanWorkspace": "'"$orphan_workspace"'"
    }' > "$XDG_CONFIG_HOME/flocus/config.json"

    # Open the orphan file
    "$FLOCUS_CLI" "$orphan_dir/file.txt"

    # Should have been sent to orphan workspace
    [[ -f "$log_file" ]] || return 1
    local request
    request=$(cat "$log_file")
    assert_contains "$request" "$orphan_dir/file.txt" "Request should contain orphan file path"
}

test_workspace_identity_mismatch() {
    # Server runs for workspace A, but registry says it's workspace B
    # CLI should detect the mismatch and fall back
    local repo_a="$TEST_TMPDIR/project-a"
    local repo_b="$TEST_TMPDIR/project-b"
    create_git_repo "$repo_a"
    create_git_repo "$repo_b"
    echo "code" > "$repo_b/test.py"

    # Start server claiming to be workspace A
    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo_a")

    # Registry says this port belongs to workspace B
    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo_b"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    # CLI should detect mismatch and fall back to code command
    local output
    output=$(FLOCUS_DRY_RUN=1 "$FLOCUS_CLI" "$repo_b/test.py" 2>&1)
    assert_contains "$output" "[dry-run] code" "Should fall back when workspace identity mismatches"
}

test_stale_entry_pruned_on_dead_server() {
    # Registry points to a dead port — CLI should prune the stale entry
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"
    echo "code" > "$repo/test.py"

    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": 19899,
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    # Run CLI (will fail to connect, should prune)
    FLOCUS_DRY_RUN=1 "$FLOCUS_CLI" "$repo/test.py" >/dev/null 2>&1 || true

    # Registry should no longer have the stale entry
    local entry_count
    entry_count=$(jq '.windows | length' "$XDG_CONFIG_HOME/flocus/registry.json")
    assert_eq "0" "$entry_count" "Stale entry should be pruned from registry"
}

test_stale_entry_pruned_on_mismatch() {
    # Server runs for workspace A, registry maps workspace B to same port
    # CLI should prune workspace B's stale entry
    local repo_a="$TEST_TMPDIR/project-a"
    local repo_b="$TEST_TMPDIR/project-b"
    create_git_repo "$repo_a"
    create_git_repo "$repo_b"
    echo "code" > "$repo_b/test.py"

    # Start server for workspace A
    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file" "" "$repo_a")

    # Registry has BOTH workspace A (correct) and workspace B (stale, same port)
    echo '{
        "version": 1,
        "windows": [
            {
                "workspace": "'"$repo_a"'",
                "port": '"$port"',
                "pid": 99998,
                "lastActive": 1000
            },
            {
                "workspace": "'"$repo_b"'",
                "port": '"$port"',
                "pid": 99999,
                "lastActive": 2000
            }
        ]
    }' > "$XDG_CONFIG_HOME/flocus/registry.json"

    # Try to open a file in workspace B — should detect mismatch and prune
    FLOCUS_DRY_RUN=1 "$FLOCUS_CLI" "$repo_b/test.py" >/dev/null 2>&1 || true

    # Workspace B's entry should be pruned, workspace A's should remain
    local remaining
    remaining=$(jq -r '.windows[].workspace' "$XDG_CONFIG_HOME/flocus/registry.json")
    assert_eq "$repo_a" "$remaining" "Only workspace A should remain after pruning"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main() {
    echo ""
    echo "flocus CLI Integration Tests"
    echo "========================"
    echo ""

    # Clean up any stale processes from previous interrupted runs
    cleanup_stale_processes

    # Check dependencies
    for cmd in jq curl git python3; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}ERROR${NC}: Required command '$cmd' not found"
            exit 1
        fi
    done

    # Check CLI exists
    if [[ ! -f "$FLOCUS_CLI" ]]; then
        echo -e "${YELLOW}SKIP${NC}: CLI not yet implemented at $FLOCUS_CLI"
        exit 0
    fi

    run_test "CLI exists and is executable" test_cli_exists_and_executable
    run_test "No args focuses project in git repo" test_no_args_focuses_project_in_git_repo
    run_test "No args focuses cwd outside git" test_no_args_focuses_cwd_outside_git
    run_test "No args focuses registered window" test_no_args_focuses_registered_window
    run_test "Nonexistent path errors early" test_nonexistent_path_errors_early
    run_test "Glob single match opens file" test_glob_single_match_opens_file
    run_test "Glob case-insensitive match" test_glob_case_insensitive
    run_test "Glob with path pattern" test_glob_with_path_pattern
    run_test "Glob multiple matches lists files" test_glob_multiple_matches_lists
    run_test "Glob no matches errors" test_glob_no_matches_errors
    run_test "Glob with line number" test_glob_with_line_number
    run_test "Glob non-git fallback" test_glob_non_git_fallback
    run_test "Glob normal path unaffected" test_glob_normal_path_unaffected
    run_test "Resolves relative paths to absolute" test_resolves_relative_path
    run_test "Detects git root correctly" test_detects_git_root
    run_test "Sends correct JSON payload" test_sends_correct_json_payload
    run_test "Zen flag sets zen=true" test_zen_flag
    run_test "Parses file:line format" test_line_number_parsing
    run_test "Picks most recently active window" test_picks_most_recent_window
    run_test "Fallback when no registry exists" test_fallback_when_no_registry
    run_test "Fallback when server is dead" test_fallback_when_server_dead
    run_test "List open files" test_list_open_files
    run_test "List requires matching window" test_list_no_matching_window
    run_test "List requires VS Code window" test_list_requires_vscode_window
    run_test "Open directory" test_open_directory
    run_test "Path-based fallback" test_path_based_fallback
    run_test "Orphan workspace config" test_orphan_workspace_config
    run_test "Workspace identity mismatch falls back" test_workspace_identity_mismatch
    run_test "Stale entry pruned on dead server" test_stale_entry_pruned_on_dead_server
    run_test "Stale entry pruned on workspace mismatch" test_stale_entry_pruned_on_mismatch

    echo ""
    echo "----------------------------------------"
    echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
    echo ""

    [[ $FAILED -eq 0 ]]
}

main "$@"
