/**
 * flocus VS Code Extension
 *
 * This extension enables the flocus CLI to open files in the correct VS Code window.
 *
 * On activation:
 * 1. Registers the workspace in ~/.config/flocus/registry.json
 * 2. Starts an HTTP server on localhost to receive open requests
 * 3. Handles incoming requests to open files, reveal in explorer, etc.
 *
 * On deactivation:
 * 1. Stops the HTTP server
 * 2. Removes the workspace from the registry
 */

import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import * as http from 'http';
import * as os from 'os';

import { registerWindow, unregisterWindow, updateLastActive } from './registry';
import { createServer, findAvailablePort, OpenRequest, OpenResponse, FilesResponse } from './server';

// Port range for HTTP servers (matches CLI expectations)
const PORT_RANGE_START = 19800;
const PORT_RANGE_END = 19900;

// Extension state
let server: http.Server | undefined;
let serverPort: number | undefined;
let workspaceRoot: string | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    // Get workspace root
    const workspaceFolders = vscode.workspace.workspaceFolders;
    if (!workspaceFolders || workspaceFolders.length === 0) {
        console.log('[flocus] No workspace folder open, extension inactive');
        return;
    }

    workspaceRoot = workspaceFolders[0].uri.fsPath;
    console.log(`[flocus] Activating for workspace: ${workspaceRoot}`);

    try {
        // Find available port
        serverPort = await findAvailablePort(PORT_RANGE_START, PORT_RANGE_END);
        console.log(`[flocus] Using port ${serverPort}`);

        // Start HTTP server
        server = createServer(serverPort, {
            onOpen: handleOpenRequest,
            onFiles: handleFilesRequest
        }, workspaceRoot);

        // Register in registry
        registerWindow({
            workspace: workspaceRoot,
            port: serverPort,
            pid: process.pid,
            lastActive: Date.now()
        });

        // Update lastActive when window gains focus
        context.subscriptions.push(
            vscode.window.onDidChangeWindowState((state) => {
                if (state.focused && workspaceRoot) {
                    updateLastActive(workspaceRoot);
                }
            })
        );

        // Log document opens triggered by CLI code-fallback
        registerFallbackOpenLogger(context);

        // Register cleanup on deactivation
        context.subscriptions.push({
            dispose: () => {
                cleanup();
            }
        });

        console.log('[flocus] Extension activated successfully');

    } catch (error) {
        console.error('[flocus] Failed to activate:', error);
        vscode.window.showErrorMessage(`flocus: Failed to start - ${error}`);
    }
}

export function deactivate(): void {
    cleanup();
}

function cleanup(): void {
    if (server) {
        server.close();
        console.log('[flocus] HTTP server stopped');
    }

    if (workspaceRoot && serverPort) {
        unregisterWindow(workspaceRoot, serverPort);
    }

    server = undefined;
    serverPort = undefined;
}

/**
 * Find if a file is already open in any tab (text or custom editor).
 * Returns the tab and its group if found, undefined otherwise.
 */
function findOpenTab(fsPath: string): { tab: vscode.Tab; group: vscode.TabGroup } | undefined {
    for (const group of vscode.window.tabGroups.all) {
        for (const tab of group.tabs) {
            const input = tab.input;
            if (input instanceof vscode.TabInputText || input instanceof vscode.TabInputCustom) {
                if (input.uri.fsPath === fsPath) {
                    return { tab, group };
                }
            }
        }
    }
    return undefined;
}

/**
 * Handle a request to list all open files.
 */
async function handleFilesRequest(): Promise<FilesResponse> {
    console.log('[flocus] Files request');

    try {
        const files: string[] = [];

        for (const group of vscode.window.tabGroups.all) {
            for (const tab of group.tabs) {
                const input = tab.input;
                if (input instanceof vscode.TabInputText || input instanceof vscode.TabInputCustom) {
                    files.push(input.uri.fsPath);
                }
            }
        }

        console.log(`[flocus] Found ${files.length} open files`);
        return { success: true, files };

    } catch (error) {
        const message = error instanceof Error ? error.message : 'Unknown error';
        console.error(`[flocus] Failed to list files: ${message}`);
        return { success: false, error: message };
    }
}

/**
 * Handle an open file request from the CLI.
 */
async function handleOpenRequest(request: OpenRequest): Promise<OpenResponse> {
    console.log(`[flocus] Open request: ${JSON.stringify(request)}`);

    try {
        const uri = vscode.Uri.file(request.file);
        const ext = path.extname(request.file).toLowerCase();

        // Apply zen mode if requested (before opening file)
        if (request.zen) {
            await applyZenMode();
        }

        // Check if file is already open in ANY tab (text editors or custom editors like Mark Sharp)
        const existingTab = findOpenTab(uri.fsPath);
        const isNewlyOpened = !existingTab;

        let editor: vscode.TextEditor | undefined;
        let editorId: string | undefined;

        if (existingTab) {
            // File already open somewhere - focus that tab instead of duplicating
            const { tab, group } = existingTab;
            const tabInput = tab.input as vscode.TabInputText | vscode.TabInputCustom;

            if (tabInput instanceof vscode.TabInputCustom) {
                // Custom editor (Mark Sharp) - focus the group and re-open with same editor
                await vscode.commands.executeCommand('vscode.openWith', tabInput.uri, tabInput.viewType, group.viewColumn);
                editorId = tabInput.viewType;
            } else {
                // Text editor - use showTextDocument to focus
                const document = await vscode.workspace.openTextDocument(tabInput.uri);
                editor = await vscode.window.showTextDocument(document, { viewColumn: group.viewColumn });
            }
        } else {
            // File not open - open it fresh
            if (!request.raw) {
                editorId = getCustomEditor(ext);
            }

            if (editorId) {
                await vscode.commands.executeCommand('vscode.openWith', uri, editorId);
            } else {
                const document = await vscode.workspace.openTextDocument(uri);
                editor = await vscode.window.showTextDocument(document);
            }
        }

        // Position cursor and scroll:
        // - Explicit line specified → jump to that line (centered)
        // - Newly opened file → scroll to top (line 1)
        // - Already open file, no line specified → preserve scroll position
        const explicitLine = request.line && request.line > 0 ? request.line : null;

        if (editor && (explicitLine || isNewlyOpened)) {
            const line = (explicitLine ?? 1) - 1; // VS Code uses 0-based line numbers
            const position = new vscode.Position(line, 0);
            editor.selection = new vscode.Selection(position, position);
            editor.revealRange(
                new vscode.Range(position, position),
                // AtTop for new files (scroll to top), InCenter for explicit lines (show context)
                explicitLine ? vscode.TextEditorRevealType.InCenter : vscode.TextEditorRevealType.AtTop
            );
        }


        // Reveal in explorer (unless zen mode)
        const shouldReveal = request.reveal !== false && !request.zen;
        if (shouldReveal) {
            await vscode.commands.executeCommand('revealInExplorer', uri);
        }

        // Focus the editor
        await vscode.commands.executeCommand('workbench.action.focusActiveEditorGroup');

        console.log(`[flocus] Opened: ${request.file}`);
        return { success: true, editor: editorId };

    } catch (error) {
        const message = error instanceof Error ? error.message : 'Unknown error';
        console.error(`[flocus] Failed to open file: ${message}`);
        return { success: false, error: message };
    }
}

/**
 * Apply zen mode: hide sidebar and panels.
 */
async function applyZenMode(): Promise<void> {
    try {
        await vscode.commands.executeCommand('workbench.action.closeSidebar');
        await vscode.commands.executeCommand('workbench.action.closePanel');
    } catch (error) {
        console.warn('[flocus] Failed to apply zen mode:', error);
    }
}

/**
 * Get custom editor ID for a file extension.
 * Returns undefined to use VS Code's default editor.
 */
function getCustomEditor(ext: string): string | undefined {
    // Default mappings (can be extended via config later)
    const defaultEditors: Record<string, string> = {
        '.md': 'msharp.customEditor'
    };

    // TODO: Read from ~/.config/flocus/config.json for user customization
    return defaultEditors[ext];
}

// ---------------------------------------------------------------------------
// Invocation log — shared with CLI at ~/.config/flocus/flocus.log
// ---------------------------------------------------------------------------

const FLOCUS_CONFIG_DIR = path.join(os.homedir(), '.config', 'flocus');
const LOG_FILE = path.join(FLOCUS_CONFIG_DIR, 'flocus.log');
const PENDING_FILE = path.join(FLOCUS_CONFIG_DIR, '.pending');
const PENDING_MAX_AGE_MS = 5000; // ignore stale .pending older than 5 seconds

/**
 * Append a line to the shared invocation log.
 */
function logToFile(message: string): void {
    try {
        const timestamp = new Date().toISOString().replace('T', ' ').replace(/\.\d+Z$/, '');
        fs.appendFileSync(LOG_FILE, `[${timestamp}] ${message}\n`);
    } catch {
        // Best-effort — don't break the extension if logging fails
    }
}

/**
 * Check if a file path matches the CLI's .pending marker.
 * Returns true and clears the marker if matched.
 */
function matchAndClearPending(openedFilePath: string): boolean {
    try {
        const stat = fs.statSync(PENDING_FILE);
        const ageMs = Date.now() - stat.mtimeMs;
        if (ageMs > PENDING_MAX_AGE_MS) {
            // Stale — clean up and ignore
            fs.unlinkSync(PENDING_FILE);
            return false;
        }
        const pendingPath = fs.readFileSync(PENDING_FILE, 'utf-8').trim();
        if (pendingPath === openedFilePath) {
            fs.unlinkSync(PENDING_FILE);
            return true;
        }
    } catch {
        // .pending doesn't exist or unreadable — normal case
    }
    return false;
}

/**
 * Register a listener that logs document opens triggered by CLI code-fallback.
 * Only fires for files matching the .pending marker left by the CLI.
 */
function registerFallbackOpenLogger(context: vscode.ExtensionContext): void {
    context.subscriptions.push(
        vscode.workspace.onDidOpenTextDocument((document) => {
            if (document.uri.scheme !== 'file') {
                return;
            }
            const filePath = document.uri.fsPath;
            if (matchAndClearPending(filePath)) {
                logToFile(`extension code_fallback_received workspace=${workspaceRoot} file=${filePath}`);
            }
        })
    );
}
