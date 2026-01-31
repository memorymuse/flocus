/**
 * Unit tests for server module.
 * These are real tests that start actual HTTP servers.
 */

import * as assert from 'node:assert';
import { describe, it, afterEach } from 'node:test';
import * as http from 'http';

import { findAvailablePort, createServer, OpenRequest, OpenResponse, FilesResponse } from '../../server.js';

// Track servers for cleanup
const servers: http.Server[] = [];

afterEach(() => {
    // Close all servers after each test
    for (const server of servers) {
        server.close();
    }
    servers.length = 0;
});

/**
 * Helper to make HTTP requests
 */
function request(options: {
    port: number;
    method: string;
    path: string;
    body?: string;
}): Promise<{ status: number; body: string }> {
    return new Promise((resolve, reject) => {
        const req = http.request({
            hostname: '127.0.0.1',
            port: options.port,
            method: options.method,
            path: options.path,
            headers: options.body ? { 'Content-Type': 'application/json' } : {}
        }, (res) => {
            let body = '';
            res.on('data', (chunk) => { body += chunk; });
            res.on('end', () => {
                resolve({ status: res.statusCode!, body });
            });
        });

        req.on('error', reject);

        if (options.body) {
            req.write(options.body);
        }
        req.end();
    });
}

describe('server', () => {
    describe('findAvailablePort', () => {
        it('should find an available port in range', async () => {
            const port = await findAvailablePort(30000, 30100);
            assert.ok(port >= 30000 && port <= 30100);
        });

        it('should skip ports that are in use', async () => {
            // Start a server on a port
            const firstPort = await findAvailablePort(30200, 30300);
            const blockingServer = http.createServer();
            await new Promise<void>((resolve) => {
                blockingServer.listen(firstPort, '127.0.0.1', () => resolve());
            });

            try {
                // Now find another port - should skip the one we're using
                const secondPort = await findAvailablePort(30200, 30300);
                assert.notStrictEqual(secondPort, firstPort);
            } finally {
                blockingServer.close();
            }
        });

        it('should throw when no ports available in range', async () => {
            // Bind to all ports in a small range, then try to find one
            const port1 = 31000;
            const port2 = 31001;

            const server1 = http.createServer();
            const server2 = http.createServer();

            await new Promise<void>((resolve) => server1.listen(port1, '127.0.0.1', () => resolve()));
            await new Promise<void>((resolve) => server2.listen(port2, '127.0.0.1', () => resolve()));

            try {
                await assert.rejects(
                    findAvailablePort(port1, port2),
                    /No available port found/
                );
            } finally {
                server1.close();
                server2.close();
            }
        });
    });

    describe('createServer', () => {
        it('should respond to health check', async () => {
            const port = await findAvailablePort(30400, 30500);

            const server = createServer(port, async () => ({ success: true }));
            servers.push(server);

            // Wait for server to start
            await new Promise((resolve) => setTimeout(resolve, 100));

            const res = await request({
                port,
                method: 'GET',
                path: '/health'
            });

            assert.strictEqual(res.status, 200);
            assert.strictEqual(res.body, 'ok');
        });

        it('should return 404 for unknown paths', async () => {
            const port = await findAvailablePort(30400, 30500);

            const server = createServer(port, async () => ({ success: true }));
            servers.push(server);

            await new Promise((resolve) => setTimeout(resolve, 100));

            const res = await request({
                port,
                method: 'GET',
                path: '/unknown'
            });

            assert.strictEqual(res.status, 404);
        });

        it('should call handler for POST /open', async () => {
            const port = await findAvailablePort(30400, 30500);
            let receivedRequest: OpenRequest | undefined;

            const server = createServer(port, async (req) => {
                receivedRequest = req;
                return { success: true, editor: 'test.editor' };
            });
            servers.push(server);

            await new Promise((resolve) => setTimeout(resolve, 100));

            const res = await request({
                port,
                method: 'POST',
                path: '/open',
                body: JSON.stringify({
                    file: '/test/file.txt',
                    line: 42,
                    zen: true
                })
            });

            assert.strictEqual(res.status, 200);

            const body = JSON.parse(res.body) as OpenResponse;
            assert.strictEqual(body.success, true);
            assert.strictEqual(body.editor, 'test.editor');

            assert.ok(receivedRequest);
            assert.strictEqual(receivedRequest.file, '/test/file.txt');
            assert.strictEqual(receivedRequest.line, 42);
            assert.strictEqual(receivedRequest.zen, true);
        });

        it('should return 400 for missing file parameter', async () => {
            const port = await findAvailablePort(30400, 30500);

            const server = createServer(port, async () => ({ success: true }));
            servers.push(server);

            await new Promise((resolve) => setTimeout(resolve, 100));

            const res = await request({
                port,
                method: 'POST',
                path: '/open',
                body: JSON.stringify({ zen: true })  // no file
            });

            assert.strictEqual(res.status, 400);

            const body = JSON.parse(res.body);
            assert.strictEqual(body.success, false);
            assert.ok(body.error.includes('file'));
        });

        it('should return 500 for handler errors', async () => {
            const port = await findAvailablePort(30400, 30500);

            const server = createServer(port, async () => {
                throw new Error('Test error');
            });
            servers.push(server);

            await new Promise((resolve) => setTimeout(resolve, 100));

            const res = await request({
                port,
                method: 'POST',
                path: '/open',
                body: JSON.stringify({ file: '/test.txt' })
            });

            assert.strictEqual(res.status, 500);

            const body = JSON.parse(res.body);
            assert.strictEqual(body.success, false);
            assert.strictEqual(body.error, 'Test error');
        });

        it('should return 501 for /files when handler not provided', async () => {
            const port = await findAvailablePort(30400, 30500);

            // Use single-handler API (no onFiles)
            const server = createServer(port, async () => ({ success: true }));
            servers.push(server);

            await new Promise((resolve) => setTimeout(resolve, 100));

            const res = await request({
                port,
                method: 'GET',
                path: '/files'
            });

            assert.strictEqual(res.status, 501);

            const body = JSON.parse(res.body);
            assert.strictEqual(body.success, false);
            assert.ok(body.error.includes('Not implemented'));
        });

        it('should call onFiles handler for GET /files', async () => {
            const port = await findAvailablePort(30400, 30500);
            const mockFiles = ['/project/src/main.ts', '/project/README.md'];

            const server = createServer(port, {
                onOpen: async () => ({ success: true }),
                onFiles: async () => ({ success: true, files: mockFiles })
            });
            servers.push(server);

            await new Promise((resolve) => setTimeout(resolve, 100));

            const res = await request({
                port,
                method: 'GET',
                path: '/files'
            });

            assert.strictEqual(res.status, 200);

            const body = JSON.parse(res.body) as FilesResponse;
            assert.strictEqual(body.success, true);
            assert.deepStrictEqual(body.files, mockFiles);
        });

        it('should return 500 for /files handler errors', async () => {
            const port = await findAvailablePort(30400, 30500);

            const server = createServer(port, {
                onOpen: async () => ({ success: true }),
                onFiles: async () => { throw new Error('Files error'); }
            });
            servers.push(server);

            await new Promise((resolve) => setTimeout(resolve, 100));

            const res = await request({
                port,
                method: 'GET',
                path: '/files'
            });

            assert.strictEqual(res.status, 500);

            const body = JSON.parse(res.body);
            assert.strictEqual(body.success, false);
            assert.strictEqual(body.error, 'Files error');
        });
    });
});
