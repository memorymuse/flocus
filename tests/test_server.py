#!/usr/bin/env python3
"""
Simple HTTP test server for vo CLI integration tests.

Usage: python3 test_server.py <log_file> [port] [files_json]

If port is not specified, an available port is found automatically.
The server writes received POST /open requests to log_file.
If files_json is provided, GET /files returns that JSON array.
Prints the port number to stdout on startup.
"""

import http.server
import json
import socket
import sys


def find_available_port():
    """Find an available port by binding to port 0."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def create_handler(log_file: str, files_list: list | None = None):
    """Create a request handler that logs to the specified file."""

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass  # Suppress HTTP logs

        def do_GET(self):
            if self.path == '/health':
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'ok')
            elif self.path == '/files':
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                response = {'success': True, 'files': files_list or []}
                self.wfile.write(json.dumps(response).encode())
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            if self.path == '/open':
                length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(length).decode('utf-8')
                with open(log_file, 'w') as f:
                    f.write(body)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': True}).encode())
            else:
                self.send_response(404)
                self.end_headers()

    return Handler


def main():
    if len(sys.argv) < 2:
        print("Usage: test_server.py <log_file> [port] [files_json]", file=sys.stderr)
        sys.exit(1)

    log_file = sys.argv[1]
    # Port 0 means auto-assign
    requested_port = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    port = find_available_port() if requested_port == 0 else requested_port
    files_list = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None

    handler = create_handler(log_file, files_list)
    server = http.server.HTTPServer(('127.0.0.1', port), handler)

    # Print port to stdout so caller can capture it
    print(port, flush=True)

    server.serve_forever()


if __name__ == '__main__':
    main()
