
## MCP helper scripts

These drive the in-app MCP server (Settings → AI → MCP must be on, DreaMail
running). **This fork's tracked build has the AI features and the MCP server
switched off** (`DREAMAIL_AI_FEATURES`, see the main README): no server runs,
no `mcp.json` is written, and the scripts exit without sending anything when
`mcp.json` advertises no live server. Unload the daily launchd job while AI is
off (`launchctl unload -w ~/Library/LaunchAgents/io.github.bateman.dreamail-summarize.plist`):
a launchd agent cannot read the app container, so it cannot see that the
server is down, and would keep posting the old token to a port any local
process may have bound. Turning MCP on again later mints a new token; copy it
to `~/.config/dreamail/mcp-token` before reloading the job. They read the port from `mcp.json` in the app container. The bearer
token stays in the Keychain; set `DREAMAIL_MCP_TOKEN` or put it in
`~/.config/dreamail/mcp-token`. Older `mcp.json` files that still include
`token` continue to work.

- `mcp-summarize.py` — backfill thread summaries. Local Ollama by default
  (`--backend ollama --model llama3.2:3b`, nothing leaves the machine) or any
  OpenAI-compatible API (`--backend openai --api-base ... --model ...`, needs
  `OPENAI_API_KEY`). Skips threads that already have a summary unless `--redo`.
- `mcp-export-threads.py` / `mcp-import-summaries.py` — the two-file bridge for
  summarizers that can't reach 127.0.0.1 (Codex Cloud workers, remote batch
  jobs). Export to JSONL, have the remote job emit
  `{"thread_id", "summary"}` lines, import them back.
- `mcp_common.py` — shared MCP JSON-RPC client used by the above. Every
  request (MCP, Ollama, hosted API) must go to `https://`, or to plain
  `http://` on a loopback address (`127.0.0.1`, `::1`) only; a redirect must
  pass the same rule and stay on the same origin. Keys come from the
  environment (`OPENAI_API_KEY`, `DREAMAIL_MCP_TOKEN`), never from arguments.
  Tests: `python3 -m unittest discover -s scripts/tests` (also run by the unit
  suite).

The exported JSONL contains full message bodies; treat it like the mailbox.
