# Notchy integrations

Notchy serves your live usage at `http://127.0.0.1:9876/usage` (loopback-only)
whenever the app is running. These tools build on that.

```jsonc
// GET http://127.0.0.1:9876/usage
{
  "updated_at": "2026-06-02T20:54:30Z",
  "providers": {
    "claude":   { "name": "Claude",   "kind": "percent", "label": "61%",        "session": 0.61, "weekly": 0.28 },
    "deepseek": { "name": "DeepSeek", "kind": "balance", "label": "$10.00",     "amount": 10.0 },
    "copilot":  { "name": "GitHub Copilot", "kind": "balance", "label": "$3.21 used", "amount": 3.21 }
  }
}
```

## `notchy` CLI

```bash
cp notchy /usr/local/bin/notchy && chmod +x /usr/local/bin/notchy
notchy            # pretty table
notchy --json     # raw JSON (pipe to jq)
```

## MCP server (Claude Desktop, Cursor, Claude Code)

Lets an agent answer "what's my Claude usage?" or "how much have I spent on AI
this month?" by calling a `get_usage` tool. Zero dependencies (system `python3`).

Add to your MCP client config:

```jsonc
{
  "mcpServers": {
    "notchy": {
      "command": "python3",
      "args": ["/ABSOLUTE/PATH/TO/notchy-mcp.py"]
    }
  }
}
```

Notchy must be running for either tool to return data.
