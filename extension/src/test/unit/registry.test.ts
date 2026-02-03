/**
 * Unit tests for registry module.
 * These are real tests that create actual files in temp directories.
 */

import * as assert from 'node:assert';
import { describe, it, before, after, beforeEach } from 'node:test';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

// We need to test with a temp directory, so we'll override XDG_CONFIG_HOME
let testDir: string;
let originalXdgConfigHome: string | undefined;

before(() => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'flocus-test-'));
    originalXdgConfigHome = process.env.XDG_CONFIG_HOME;
    process.env.XDG_CONFIG_HOME = testDir;
});

after(() => {
    // Restore original XDG_CONFIG_HOME
    if (originalXdgConfigHome !== undefined) {
        process.env.XDG_CONFIG_HOME = originalXdgConfigHome;
    } else {
        delete process.env.XDG_CONFIG_HOME;
    }

    // Clean up test directory
    fs.rmSync(testDir, { recursive: true, force: true });
});

beforeEach(() => {
    // Clean up registry between tests
    const registryPath = path.join(testDir, 'flocus', 'registry.json');
    if (fs.existsSync(registryPath)) {
        fs.unlinkSync(registryPath);
    }
});

// Import after setting up environment
import {
    getRegistryPath,
    readRegistry,
    writeRegistry,
    registerWindow,
    unregisterWindow,
    updateLastActive
} from '../../registry.js';

describe('registry', () => {
    describe('getRegistryPath', () => {
        it('should return path under XDG_CONFIG_HOME', () => {
            const registryPath = getRegistryPath();
            assert.strictEqual(registryPath, path.join(testDir, 'flocus', 'registry.json'));
        });
    });

    describe('readRegistry', () => {
        it('should return empty registry when file does not exist', () => {
            const registry = readRegistry();
            assert.deepStrictEqual(registry, { version: 1, windows: [] });
        });

        it('should read existing registry', () => {
            const registryPath = getRegistryPath();
            fs.mkdirSync(path.dirname(registryPath), { recursive: true });
            fs.writeFileSync(registryPath, JSON.stringify({
                version: 1,
                windows: [{ workspace: '/test', port: 19800, pid: 123, lastActive: 1000 }]
            }));

            const registry = readRegistry();
            assert.strictEqual(registry.version, 1);
            assert.strictEqual(registry.windows.length, 1);
            assert.strictEqual(registry.windows[0].workspace, '/test');
        });
    });

    describe('writeRegistry', () => {
        it('should create directory and write registry', () => {
            const registry = {
                version: 1,
                windows: [{ workspace: '/test', port: 19800, pid: 123, lastActive: 1000 }]
            };

            writeRegistry(registry);

            const registryPath = getRegistryPath();
            assert.ok(fs.existsSync(registryPath));

            const content = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));
            assert.deepStrictEqual(content, registry);
        });
    });

    describe('registerWindow', () => {
        it('should add new window entry', () => {
            registerWindow({
                workspace: '/project1',
                port: 19801,
                pid: 1000,
                lastActive: Date.now()
            });

            const registry = readRegistry();
            assert.strictEqual(registry.windows.length, 1);
            assert.strictEqual(registry.windows[0].workspace, '/project1');
            assert.strictEqual(registry.windows[0].port, 19801);
        });

        it('should replace existing entry for same workspace', () => {
            registerWindow({
                workspace: '/project1',
                port: 19801,
                pid: 1000,
                lastActive: 1000
            });

            registerWindow({
                workspace: '/project1',
                port: 19802,
                pid: 1001,
                lastActive: 2000
            });

            const registry = readRegistry();
            assert.strictEqual(registry.windows.length, 1);
            assert.strictEqual(registry.windows[0].port, 19802);
            assert.strictEqual(registry.windows[0].lastActive, 2000);
        });

        it('should allow multiple different workspaces', () => {
            registerWindow({
                workspace: '/project1',
                port: 19801,
                pid: 1000,
                lastActive: 1000
            });

            registerWindow({
                workspace: '/project2',
                port: 19802,
                pid: 1001,
                lastActive: 2000
            });

            const registry = readRegistry();
            assert.strictEqual(registry.windows.length, 2);
        });
    });

    describe('unregisterWindow', () => {
        it('should remove matching entry', () => {
            registerWindow({
                workspace: '/project1',
                port: 19801,
                pid: 1000,
                lastActive: 1000
            });

            unregisterWindow('/project1', 19801);

            const registry = readRegistry();
            assert.strictEqual(registry.windows.length, 0);
        });

        it('should not remove entry with different port', () => {
            registerWindow({
                workspace: '/project1',
                port: 19801,
                pid: 1000,
                lastActive: 1000
            });

            // Try to unregister with wrong port
            unregisterWindow('/project1', 19802);

            const registry = readRegistry();
            assert.strictEqual(registry.windows.length, 1);
        });

        it('should handle unregistering non-existent entry gracefully', () => {
            // Should not throw
            unregisterWindow('/nonexistent', 19999);

            const registry = readRegistry();
            assert.strictEqual(registry.windows.length, 0);
        });
    });

    describe('updateLastActive', () => {
        it('should update timestamp for existing entry', () => {
            registerWindow({
                workspace: '/project1',
                port: 19801,
                pid: 1000,
                lastActive: 1000
            });

            updateLastActive('/project1');

            const registry = readRegistry();
            assert.ok(registry.windows[0].lastActive > 1000);
        });

        it('should not create entry for non-existent workspace', () => {
            updateLastActive('/nonexistent');

            const registry = readRegistry();
            assert.strictEqual(registry.windows.length, 0);
        });
    });
});
