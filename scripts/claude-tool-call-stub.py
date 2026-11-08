#!/usr/bin/env python3
"""claude-tool-call-stub.py — a canned Messages API endpoint for
scripts/claude-policy-probe.sh (issue #2799).

Every probe run in that script fails on its placeholder API key before any
model response arrives, so nothing there ever reaches an actual tool call —
which is exactly what the managed `PreToolUse` hook (requirement 4m) needs
in order to be weighed at all. This stands in for the model instead: bound
to 127.0.0.1 and named by `ANTHROPIC_BASE_URL`, it answers the first
`/v1/messages` request of a run with a canned `tool_use` content block for
one named tool, and every later request with a plain `end_turn` text reply,
so a real `claude -p` run attempts exactly one tool call — the one the
caller asked for — and then finishes on its own. No network egress leaves
127.0.0.1 and nothing is billed: the whole exchange is this process
answering its own loopback socket.

Prints "LISTENING <port>" on its own stdout line, flushed, the moment it is
bound and ready to accept the first connection — the caller's cue to stop
waiting and point `claude` at it, and the only way to learn the actual port
when invoked with port 0.

usage: claude-tool-call-stub.py <port> <tool-name> <tool-input-json>
  <port>            0 for an OS-chosen port (reported on stdout as above).
  <tool-name>       the `name` the canned `tool_use` block carries — the
                    `tool_name` a PreToolUse hook then sees, e.g. "Bash",
                    "Agent" or "Workflow".
  <tool-input-json> the block's `input`, verbatim — the hook's own
                    `tool_input`, e.g.
                    '{"command": "...", "run_in_background": true}'.
"""
import http.server
import json
import sys


def _sse(wfile, event, data):
    wfile.write(("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode())


def make_handler(tool_name, tool_input):
    state = {"n": 0}

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "claude-tool-call-stub/1.0"

        def log_message(self, fmt, *args):  # noqa: A003 — matches BaseHTTPRequestHandler's own name
            sys.stderr.write("claude-tool-call-stub: %s\n" % (fmt % args))

        def do_POST(self):  # noqa: N802 — BaseHTTPRequestHandler's own naming convention
            length = int(self.headers.get("Content-Length", 0))
            self.rfile.read(length)  # the request body carries nothing this stub needs to read
            state["n"] += 1
            n = state["n"]

            if n == 1:
                block = {"type": "tool_use", "id": "toolu_stub1", "name": tool_name, "input": {}}
                stop_reason = "tool_use"
                delta = {"type": "input_json_delta", "partial_json": json.dumps(tool_input)}
            else:
                block = {"type": "text", "text": ""}
                stop_reason = "end_turn"
                delta = {"type": "text_delta", "text": "done"}

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            _sse(self.wfile, "message_start", {
                "type": "message_start",
                "message": {"id": "msg_stub%d" % n, "type": "message", "role": "assistant",
                             "model": "claude-tool-call-stub", "content": [],
                             "stop_reason": None, "stop_sequence": None,
                             "usage": {"input_tokens": 1, "output_tokens": 0}},
            })
            _sse(self.wfile, "content_block_start",
                 {"type": "content_block_start", "index": 0, "content_block": block})
            _sse(self.wfile, "content_block_delta",
                 {"type": "content_block_delta", "index": 0, "delta": delta})
            _sse(self.wfile, "content_block_stop", {"type": "content_block_stop", "index": 0})
            _sse(self.wfile, "message_delta", {
                "type": "message_delta",
                "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                "usage": {"output_tokens": 1},
            })
            _sse(self.wfile, "message_stop", {"type": "message_stop"})
            self.wfile.flush()

    return Handler


def main():
    if len(sys.argv) != 4:
        sys.stderr.write(__doc__ or "")
        return 2
    port = int(sys.argv[1])
    tool_name = sys.argv[2]
    tool_input = json.loads(sys.argv[3])

    httpd = http.server.HTTPServer(("127.0.0.1", port), make_handler(tool_name, tool_input))
    sys.stdout.write("LISTENING %d\n" % httpd.server_port)
    sys.stdout.flush()
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
