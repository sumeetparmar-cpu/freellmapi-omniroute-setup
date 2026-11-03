# Claude Code on the free-only gateways

`termux/claude-free.sh` starts Claude Code against a local **free-guard** (Anthropic `/v1/messages` route), pinned to a free model.
Everything stays on `127.0.0.1`. Works on Termux and on generic Linux.

```bash
bash termux/bootstrap.sh                              # once: gateways + keyless OVH route + guards + keys (docs/PHONE-TERMUX.md)
bash termux/claude-free.sh --check                    # guard answers and accepts the key (no inference)
bash termux/claude-free.sh                            # interactive Claude Code via FreeLLMAPI, model gpt-oss-20b
bash termux/claude-free.sh -p "explain this repo"     # any claude arguments pass through
bash termux/claude-free.sh --gateway omniroute        # via OmniRoute, model ovhanon/gpt-oss-120b
bash termux/claude-free.sh --model <id>               # another model the free-only policy allows on that gateway
```

Claude Code itself must be installed (`claude` on PATH): https://code.claude.com/docs/en/setup

## What the launcher does

- Base URL = the guard (`127.0.0.1:3101` FreeLLMAPI, `127.0.0.1:20228` OmniRoute); key = the guard **client** key from
  `$GW_HOME/config/guard-<gateway>.clientkey` (must be mode 600), passed only through the environment, never on a command line.
- Every model slot (main, opus/sonnet/haiku aliases, background tasks, subagents) is set to the one free model.
- **Your own Claude Code setup is untouched:** it uses `CLAUDE_CONFIG_DIR=$GW_HOME/claude-code` (login, settings, history and
  `.claude.json` all live there), and it removes `ANTHROPIC_*`, `CLAUDE_CODE_USE_*`, `CLAUDE_CODE_OAUTH_TOKEN` and Bedrock tokens
  from Claude Code's environment, so your real credentials can never be sent to the gateway.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`: no telemetry, error reporting or update checks to Anthropic.
- Preflight `GET /v1/models` on the guard first; a missing guard, a rejected key or a missing `claude` stops it with a clear message.

## What the guard enforces on `/v1/messages`

Same rules as the OpenAI routes (config/free-policy.json), plus:

- the model must pass the free-only policy, checked before anything reaches the gateway (HTTP 403 otherwise). On OmniRoute that
  means explicit free `provider/model` ids only: Claude names, aliases, combos and `auto` are refused. On FreeLLMAPI, ids the gateway
  serves itself (its unified names, `auto`) pass only after the catalog audit left nothing but free models enabled;
- Anthropic server/built-in tools (`web_search_*`, `web_fetch_*`, `code_execution_*`, `bash_*`, `text_editor_*`, `computer_*`, ...),
  `mcp_servers` and `container` are refused. Claude Code's own tools (Read, Edit, Bash, ...) are plain client tools and pass.
  Consequence: Claude Code's **WebSearch** tool does not work here;
- `anthropic-beta` and every other non-allowlisted header is not forwarded; the query string (`?beta=true`) is dropped;
- the client key may come as `Authorization: Bearer` or `x-api-key`; the gateway only ever sees its own key;
- errors use Anthropic's shape (`{"type":"error","error":{...}}`) so Claude Code shows them and retries 429s by itself;
- `/v1/messages/count_tokens` is checked against the policy but not metered (the gateway answers it locally).

## Limits

- OVH's keyless route: **2 requests/minute/model**. Claude Code waits and retries, so a small edit takes about 2 minutes.
- `gpt-oss-20b` / `gpt-oss-120b` are much weaker than Claude models; long multi-step tasks may fail or loop.
- Claude Code's `total_cost_usd` is its own list-price estimate for an unrecognised model; the free route bills nothing.
- Not done: a Windows launcher; the VPS (gateways run as service users there, so the client key needs a deliberate hand-over).

## Test evidence (2026-11-03, sandbox, Linux)

FreeLLMAPI 36826e7 + OmniRoute 3.8.52 via `termux/bootstrap.sh`, Claude Code 2.1.317, real OVH keyless inference, through the guards:

| Gateway | Text prompt | Edit task (Read + Edit tools) |
|---|---|---|
| FreeLLMAPI, `gpt-oss-20b` | exact reply, 1 turn, 2 s | `hello world` -> `hello free`, 4 turns, 121 s |
| OmniRoute, `ovhanon/gpt-oss-120b` | exact reply, 1 turn, 4 s | `hello world` -> `hello free`, 4 turns, 119 s |

Guard logs per gateway: 6 inference requests passed, 2 refused with a local 429 (OVH limit) and retried by Claude Code, nothing else
refused. A decoy `ANTHROPIC_API_KEY` set in the caller's environment appeared in no log; Claude Code wrote nothing outside its
config dir. Automated: `tests/guard/anthropic.test.mjs` (route, models, tools, keys, count_tokens, streaming, cooldown, kill switch)
and `tests/termux/claude-free.test.sh` (launcher environment, isolation, preflight). Not yet run on a phone.
