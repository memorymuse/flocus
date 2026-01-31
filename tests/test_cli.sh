#!/usr/bin/env bash
# Integration tests for vo CLI
# These are REAL tests - no mocks. They create actual files, git repos, and HTTP servers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VO_CLI="$PROJECT_ROOT/cli/vo"

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
    mkdir -p "$XDG_CONFIG_HOME/vo"
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
# Usage: start_test_server <log_file> [files_json]
#-------------------------------------------------------------------------------
start_test_server() {
    local log_file="$1"
    local files_json="${2:-}"
    local port_file="$TEST_TMPDIR/port_$$_$RANDOM"

    # Start server in background, redirect first line (port) to file
    if [[ -n "$files_json" ]]; then
        python3 "$SCRIPT_DIR/test_server.py" "$log_file" 0 "$files_json" > "$port_file" &
    else
        python3 "$SCRIPT_DIR/test_server.py" "$log_file" > "$port_file" &
    fi
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
    [[ -x "$VO_CLI" ]] || return 1
}

test_requires_file_argument() {
    local output
    output=$("$VO_CLI" 2>&1 || true)
    assert_contains "$output" "Usage" "Should show usage when no file given"
}

test_resolves_relative_path() {
    # Create a git repo and file
    local repo="$TEST_TMPDIR/myproject"
    create_git_repo "$repo"
    mkdir -p "$repo/src"
    echo "content" > "$repo/src/module.py"

    # Start test server (gets dynamic port)
    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file")

    # Create registry pointing to our server
    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/vo/registry.json"

    # Run vo from within the repo, using relative path
    (cd "$repo" && "$VO_CLI" src/module.py)

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
    port=$(start_test_server "$log_file")

    # Create registry
    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/vo/registry.json"

    # Run from nested directory
    (cd "$repo/deep/nested" && "$VO_CLI" file.py)

    # Server should have received the request (meaning git root was detected correctly)
    [[ -f "$log_file" ]] || return 1
}

test_sends_correct_json_payload() {
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"
    echo "code" > "$repo/test.py"

    local log_file="$TEST_TMPDIR/request.json"
    local port
    port=$(start_test_server "$log_file")

    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/vo/registry.json"

    "$VO_CLI" "$repo/test.py"

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
    port=$(start_test_server "$log_file")

    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/vo/registry.json"

    "$VO_CLI" -z "$repo/test.py"

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
    port=$(start_test_server "$log_file")

    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/vo/registry.json"

    "$VO_CLI" "$repo/test.py:42"

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
    old_port=$(start_test_server "$old_log")
    local new_port
    new_port=$(start_test_server "$new_log")

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
    }' > "$XDG_CONFIG_HOME/vo/registry.json"

    "$VO_CLI" "$repo/test.py"

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
    rm -f "$XDG_CONFIG_HOME/vo/registry.json"

    # Use dry-run mode to avoid actually launching VS Code
    local output
    output=$(VO_DRY_RUN=1 "$VO_CLI" "$repo/test.py" 2>&1)

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
    }' > "$XDG_CONFIG_HOME/vo/registry.json"

    # Use dry-run mode to avoid actually launching VS Code
    local output
    output=$(VO_DRY_RUN=1 "$VO_CLI" "$repo/test.py" 2>&1)

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
    port=$(start_test_server "$log_file" "$files_json")

    echo '{
        "version": 1,
        "windows": [{
            "workspace": "'"$repo"'",
            "port": '"$port"',
            "pid": 99999,
            "lastActive": 1737561234567
        }]
    }' > "$XDG_CONFIG_HOME/vo/registry.json"

    # Run from within the repo
    local output
    output=$(cd "$repo" && "$VO_CLI" --list)

    # Should output all three files
    assert_contains "$output" "/project/src/main.ts" "Should list main.ts" || return 1
    assert_contains "$output" "/project/README.md" "Should list README.md" || return 1
    assert_contains "$output" "/project/test.py" "Should list test.py" || return 1
}

test_list_requires_git_repo() {
    # Create a directory that's not a git repo
    local dir="$TEST_TMPDIR/not-a-repo"
    mkdir -p "$dir"

    local output
    output=$(cd "$dir" && "$VO_CLI" --list 2>&1 || true)

    assert_contains "$output" "Not in a git repository" "Should error when not in git repo"
}

test_list_requires_vscode_window() {
    local repo="$TEST_TMPDIR/project"
    create_git_repo "$repo"

    # Empty registry (no windows)
    echo '{"version": 1, "windows": []}' > "$XDG_CONFIG_HOME/vo/registry.json"

    local output
    output=$(cd "$repo" && "$VO_CLI" --list 2>&1 || true)

    assert_contains "$output" "No VS Code window found" "Should error when no window found"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main() {
    echo ""
    echo "vo CLI Integration Tests"
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
    if [[ ! -f "$VO_CLI" ]]; then
        echo -e "${YELLOW}SKIP${NC}: CLI not yet implemented at $VO_CLI"
        exit 0
    fi

    run_test "CLI exists and is executable" test_cli_exists_and_executable
    run_test "Shows usage when no file argument" test_requires_file_argument
    run_test "Resolves relative paths to absolute" test_resolves_relative_path
    run_test "Detects git root correctly" test_detects_git_root
    run_test "Sends correct JSON payload" test_sends_correct_json_payload
    run_test "Zen flag sets zen=true" test_zen_flag
    run_test "Parses file:line format" test_line_number_parsing
    run_test "Picks most recently active window" test_picks_most_recent_window
    run_test "Fallback when no registry exists" test_fallback_when_no_registry
    run_test "Fallback when server is dead" test_fallback_when_server_dead
    run_test "List open files" test_list_open_files
    run_test "List requires git repo" test_list_requires_git_repo
    run_test "List requires VS Code window" test_list_requires_vscode_window

    echo ""
    echo "----------------------------------------"
    echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
    echo ""

    [[ $FAILED -eq 0 ]]
}

main "$@"
