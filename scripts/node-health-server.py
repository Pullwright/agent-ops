#!/usr/bin/env python3
"""node-health-server.py — the HTTP surface over scripts/node-health.sh
(issue #608, Phase 2).

Answers exactly four paths — /livez, /readyz, /healthz, /metrics — 200 when
the underlying CLI call exits 0 and 503 otherwise (/metrics always 200: it
reports data, not a verdict), the CLI's own JSON body either way. Every
other path is 404. Computes on demand, the same read-only CLI a Kubernetes
exec probe or a container healthcheck would call directly; this responder
adds nothing of its own beyond the HTTP framing — no cache, no background
refresh, no state of its own — so it can never itself become a second
answer that disagrees with the CLI's.

usage: node-health-server.py [port] [bind-address]

Binds 127.0.0.1 by default, the same convention scripts/serve-dashboard.sh
documents: a server bound to a container's own loopback is reachable from
nothing, so deploy/docker/compose.yaml's `node-health` service passes
0.0.0.0 here and publishes the port on the host's loopback alone
(127.0.0.1:<port>:<port>) instead. Widening the bind on a bare-metal host is
a different, deliberate choice, and never what this default is for.
"""
import http.server
import json
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(SCRIPT_DIR, "scripts", "node-health.sh")

ROUTES = {
    "/livez": "--live",
    "/readyz": "--ready",
    "/healthz": "--health",
    "/metrics": "--metrics",
}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "node-health-server/1.0"

    def log_message(self, fmt, *args):  # noqa: A003 — matches BaseHTTPRequestHandler's own name
        # One line per request to stderr (Docker/compose captures it), never
        # to stdout: the CLI's own JSON is what an operator greps for, and
        # interleaving access-log lines into it would make that harder, not
        # easier.
        sys.stderr.write("node-health-server: %s\n" % (fmt % args))

    def _answer(self, flag):
        try:
            proc = subprocess.run(
                [CLI, flag], capture_output=True, text=True, timeout=30
            )
            body = proc.stdout.strip() or json.dumps(
                {"error": "node-health.sh produced no output"}
            )
            # /metrics reports data, never a verdict — always 200 once the
            # call itself completed. Every other route's exit code *is* the
            # verdict: 0 -> 200, anything else -> 503, the ordinary
            # health-endpoint convention every orchestrator already expects.
            status = 200 if (flag == "--metrics" or proc.returncode == 0) else 503
        except subprocess.TimeoutExpired:
            status = 503
            body = json.dumps({"error": "node-health.sh timed out"})
        except OSError as exc:
            status = 503
            body = json.dumps({"error": "could not run node-health.sh: %s" % exc})
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):  # noqa: N802 — BaseHTTPRequestHandler's own naming convention
        flag = ROUTES.get(self.path)
        if flag is None:
            body = json.dumps(
                {"error": "not found", "routes": sorted(ROUTES.keys())}
            ).encode("utf-8")
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._answer(flag)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8788
    bind = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    httpd = http.server.ThreadingHTTPServer((bind, port), Handler)
    sys.stderr.write("node-health-server: serving on http://%s:%d\n" % (bind, port))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
