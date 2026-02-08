/**
 * Registry management for flocus extension.
 *
 * The registry is a JSON file at ~/.config/flocus/registry.json that tracks
 * which VS Code windows are running, their workspace paths, and the ports
 * they're listening on.
 *
 * Format:
 * {
 *   "version": 1,
 *   "windows": [
 *     { "workspace": "/path/to/project", "port": 19801, "pid": 12345, "lastActive": 1737561234567 }
 *   ]
 * }
 */

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

export interface WindowEntry {
    workspace: string;
    port: number;
    pid: number;
    lastActive: number;
}

export interface Registry {
    version: number;
    windows: WindowEntry[];
}

/**
 * Get the path to the registry file.
 * Uses XDG_CONFIG_HOME if set, otherwise ~/.config/flocus/registry.json
 */
export function getRegistryPath(): string {
    const configHome = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
    return path.join(configHome, 'flocus', 'registry.json');
}

/**
 * Read the registry file. Returns empty registry if file doesn't exist.
 */
export function readRegistry(): Registry {
    const registryPath = getRegistryPath();

    try {
        if (!fs.existsSync(registryPath)) {
            return { version: 1, windows: [] };
        }
        const content = fs.readFileSync(registryPath, 'utf-8');
        const registry = JSON.parse(content) as Registry;
        return registry;
    } catch (error) {
        console.error(`[flocus] Failed to read registry: ${error}`);
        return { version: 1, windows: [] };
    }
}

/**
 * Write the registry file atomically (write to temp, then rename).
 */
export function writeRegistry(registry: Registry): void {
    const registryPath = getRegistryPath();
    const registryDir = path.dirname(registryPath);

    // Ensure directory exists
    if (!fs.existsSync(registryDir)) {
        fs.mkdirSync(registryDir, { recursive: true });
    }

    // Write atomically: write to temp file, then rename
    const tempPath = `${registryPath}.tmp.${process.pid}`;
    try {
        fs.writeFileSync(tempPath, JSON.stringify(registry, null, 2), 'utf-8');
        fs.renameSync(tempPath, registryPath);
    } catch (error) {
        // Clean up temp file if rename failed
        try {
            fs.unlinkSync(tempPath);
        } catch {
            // Ignore cleanup errors
        }
        throw error;
    }
}

/**
 * Register a window in the registry.
 * If an entry with the same workspace already exists, update it.
 */
export function registerWindow(entry: WindowEntry): void {
    const registry = readRegistry();

    // Remove any existing entry for this workspace,
    // AND remove stale entries from other workspaces that claim the same port
    // (happens when a previous window crashed without cleaning up)
    registry.windows = registry.windows.filter(
        w => w.workspace !== entry.workspace && w.port !== entry.port
    );

    // Add new entry
    registry.windows.push(entry);

    writeRegistry(registry);
    console.log(`[flocus] Registered: ${entry.workspace} on port ${entry.port}`);
}

/**
 * Unregister a window from the registry.
 * Removes entry matching workspace AND port (to avoid removing a newer entry).
 */
export function unregisterWindow(workspace: string, port: number): void {
    const registry = readRegistry();

    const before = registry.windows.length;
    registry.windows = registry.windows.filter(
        w => !(w.workspace === workspace && w.port === port)
    );
    const after = registry.windows.length;

    if (before !== after) {
        writeRegistry(registry);
        console.log(`[flocus] Unregistered: ${workspace} on port ${port}`);
    }
}

/**
 * Update the lastActive timestamp for a workspace.
 */
export function updateLastActive(workspace: string): void {
    const registry = readRegistry();

    const entry = registry.windows.find(w => w.workspace === workspace);
    if (entry) {
        entry.lastActive = Date.now();
        writeRegistry(registry);
    }
}
