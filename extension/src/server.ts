/**
 * HTTP server for flocus extension.
 *
 * Handles incoming requests from the vo CLI.
 *
 * Endpoints:
 *   GET  /health  - Returns 200 OK if server is running
 *   GET  /files   - Returns list of open file paths
 *   POST /open    - Opens a file in VS Code
 */

import * as http from 'http';
import * as net from 'net';

export interface OpenRequest {
    file: string;
    line?: number;
    zen?: boolean;
    raw?: boolean;
    reveal?: boolean;
}

export interface OpenResponse {
    success: boolean;
    error?: string;
    editor?: string;
}

export interface FilesResponse {
    success: boolean;
    files?: string[];
    error?: string;
}

export type OpenHandler = (request: OpenRequest) => Promise<OpenResponse>;
export type FilesHandler = () => Promise<FilesResponse>;

export interface ServerHandlers {
    onOpen: OpenHandler;
    onFiles?: FilesHandler;
}

/**
 * Find an available port in the given range.
 * Returns the first available port, or throws if none found.
 */
export async function findAvailablePort(start: number, end: number): Promise<number> {
    for (let port = start; port <= end; port++) {
        const available = await isPortAvailable(port);
        if (available) {
            return port;
        }
    }
    throw new Error(`No available port found in range ${start}-${end}`);
}

/**
 * Check if a port is available by attempting to bind to it.
 */
function isPortAvailable(port: number): Promise<boolean> {
    return new Promise((resolve) => {
        const server = net.createServer();

        server.once('error', () => {
            resolve(false);
        });

        server.once('listening', () => {
            server.close(() => {
                resolve(true);
            });
        });

        server.listen(port, '127.0.0.1');
    });
}

/**
 * Create and start the HTTP server.
 * Returns the server instance and the port it's listening on.
 */
export function createServer(
    port: number,
    handlers: OpenHandler | ServerHandlers,
    workspace?: string
): http.Server {
    // Support both old single-handler and new handlers object API
    const { onOpen, onFiles } = typeof handlers === 'function'
        ? { onOpen: handlers, onFiles: undefined }
        : handlers;

    const server = http.createServer(async (req, res) => {
        // Set CORS headers for local development
        res.setHeader('Access-Control-Allow-Origin', '*');
        res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

        // Handle preflight
        if (req.method === 'OPTIONS') {
            res.writeHead(204);
            res.end();
            return;
        }

        // Health check endpoint — returns workspace identity for CLI verification
        if (req.method === 'GET' && req.url === '/health') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ status: 'ok', workspace: workspace || null }));
            return;
        }

        // List open files endpoint
        if (req.method === 'GET' && req.url === '/files') {
            if (!onFiles) {
                res.writeHead(501, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: false, error: 'Not implemented' }));
                return;
            }

            try {
                const response = await onFiles();
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(response));
            } catch (error) {
                console.error('[flocus] Error handling /files:', error);
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({
                    success: false,
                    error: error instanceof Error ? error.message : 'Unknown error'
                }));
            }
            return;
        }

        // Open file endpoint
        if (req.method === 'POST' && req.url === '/open') {
            try {
                const body = await readBody(req);
                const request = JSON.parse(body) as OpenRequest;

                // Validate required fields
                if (!request.file) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ success: false, error: 'Missing file parameter' }));
                    return;
                }

                // Handle the open request
                const response = await onOpen(request);

                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(response));
            } catch (error) {
                console.error('[flocus] Error handling /open:', error);
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({
                    success: false,
                    error: error instanceof Error ? error.message : 'Unknown error'
                }));
            }
            return;
        }

        // Not found
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('Not found');
    });

    server.listen(port, '127.0.0.1', () => {
        console.log(`[flocus] HTTP server listening on http://127.0.0.1:${port}`);
    });

    return server;
}

/**
 * Read the request body as a string.
 */
function readBody(req: http.IncomingMessage): Promise<string> {
    return new Promise((resolve, reject) => {
        const chunks: Buffer[] = [];

        req.on('data', (chunk: Buffer) => {
            chunks.push(chunk);
        });

        req.on('end', () => {
            resolve(Buffer.concat(chunks).toString('utf-8'));
        });

        req.on('error', reject);
    });
}
