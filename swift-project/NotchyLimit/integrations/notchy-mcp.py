#!/usr/bin/env python3
"""
Notchy MCP server — exposes your live AI usage to MCP clients (Claude Desktop,
Cursor, Claude Code, …) as a `get_usage` tool.

It's a thin proxy over Notchy's local HTTP API (http://127.0.0.1:9876/usage), so
Notchy must be running. Zero dependencies — uses only the Python standard
library, and speaks the MCP stdio transport (newline-delimited JSON-RPC).

Wire it up (Claude Desktop / Cursor mcp config):

    {
      "mcpServers": {
        "notchy": { "command": "python3", "args": ["/ABSOLUTE/PATH/notchy-mcp.py"] }
      }
    }

Then ask: "What's my Claude usage?" / "How much have I spent on AI this month?"
"""
import json
import sys
import urllib.request

USAGE_URL = "http://127.0.0.1:9876/usage"
PROTOCOL_VERSION = "2025-06-18"


def fetch_usage() -> str:
    try:
        with urllib.request.urlopen(USAGE_URL, timeout=3) as r:
            return r.read().decode("utf-8")
    except Exception as e:
        return json.dumps({
            "error": "Could not reach Notchy. Is the app running?",
            "detail": str(e),
        })


def send(msg: dict) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def reply(req_id, result) -> None:
    send({"jsonrpc": "2.0", "id": req_id, "result": result})


TOOL = {
    "name": "get_usage",
    "description": "Get the user's current AI provider usage from Notchy: "
                   "per-provider session/weekly percentages, credit balances, "
                   "and dollar spend. Returns live JSON.",
    "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
}


def handle(msg: dict):
    method = msg.get("method")
    req_id = msg.get("id")

    if method == "initialize":
        reply(req_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "notchy", "version": "1.0.0"},
        })
    elif method == "notifications/initialized":
        pass  # notification — no response
    elif method == "tools/list":
        reply(req_id, {"tools": [TOOL]})
    elif method == "tools/call":
        name = (msg.get("params") or {}).get("name")
        if name == "get_usage":
            reply(req_id, {"content": [{"type": "text", "text": fetch_usage()}]})
        else:
            reply(req_id, {
                "content": [{"type": "text", "text": f"Unknown tool: {name}"}],
                "isError": True,
            })
    elif req_id is not None:
        # Unknown method that expects a response.
        send({"jsonrpc": "2.0", "id": req_id,
              "error": {"code": -32601, "message": f"Method not found: {method}"}})


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            handle(json.loads(line))
        except json.JSONDecodeError:
            continue


if __name__ == "__main__":
    main()
