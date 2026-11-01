# Running now (sandbox session, 2026-10-30)

This is the live state of the *current execution environment* (a temporary cloud container). It is **not** the Hostinger VPS and **not** reachable from a phone.

| What | Address (container loopback only) | Auth |
|---|---|---|
| FreeLLMAPI dashboard | http://127.0.0.1:3001/ | account created at first run |
| FreeLLMAPI API (raw, lists paid names, do not use directly) | http://127.0.0.1:3001/v1 | unified key |
| **FreeLLMAPI via free-guard (use this)** | http://127.0.0.1:3101/v1 | guard client key |
| OmniRoute dashboard | http://127.0.0.1:20128/ (redirects to /login) | admin password |
| OmniRoute API (raw, do not use directly) | http://127.0.0.1:20128/v1 | API key |
| **OmniRoute via free-guard (use this)** | http://127.0.0.1:20228/v1 | guard client key |

Models that work at zero cost today: FreeLLMAPI `gpt-oss-20b` (OVH anonymous tier); OmniRoute `ovhanon/gpt-oss-120b` (custom node, no API key). OVH's anonymous limit is 2 requests/minute/model. Other providers need your own free-tier keys (none configured).

Secrets are in 0600 files under the session scratchpad (`gw/config/*.env`, `fl.*`, `or.*`, `guard/*.ckey`); they are never printed here.

Start / stop (reuses existing data; Node 24.22.2 from the scratchpad):
```
export PATH=<scratchpad>/node24/node_modules/node/bin:$PATH GW_HOME=<scratchpad>/gw
termux/freellmapi.sh start|stop|status ;  termux/omniroute.sh start|stop|status
```

**Know this about FreeLLMAPI:** it serves "unified" names (e.g. `claude-opus-4-5`, `auto`) and answers them from the enabled free pool. A request for `claude-opus-4-5` through the guard was observed to be routed to `custom/gpt-oss-20b` (OVH anonymous, \u20b90) per the response's `_routed_via` field. That is not a paid fallback, but it is also not Claude: pick model names from the free list (`gpt-oss-20b`) if you care which model answers. Verified evidence: 44 enabled models, 0 policy violations (`tools/free-policy.mjs freellmapi audit`), OmniRoute 0 providers outside policy.

## Why your phone cannot reach this
The container has a private address only, no inbound route, and tunnel services (Tailscale, Cloudflare, ngrok) are unreachable from its network allowlist. It is also temporary. Nothing here is exposed publicly, on purpose.

## Safest ways to use it from Android
1. **On the phone itself (recommended).** This toolkit is built for Termux: `termux/freellmapi.sh install && start`, `termux/omniroute.sh install && start`. Then the dashboards are http://127.0.0.1:3001 and http://127.0.0.1:20128 in the phone's own browser, with free-guard in front (docs/FREE-ONLY.md).
2. **From other devices later:** put the gateways on a private VPN (Tailscale) and keep API-key auth on; never port-forward. The VPS route is prepared in docs/VPS-DEPLOYMENT.md but not applied.
