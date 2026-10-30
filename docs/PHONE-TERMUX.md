# Both gateways on your Android phone (Termux)

**Status, stated plainly:** everything below is prepared and the scripts are tested on Linux, but it has **not been run on a phone or in Termux** (no access from the build environment). Expect to fix small Android-specific things; the first place to look is `./termux/audit-env.sh`.
Resource warning: OmniRoute measured ~610 MB RAM and ~2.8 GB disk, FreeLLMAPI ~155 MB / 0.6 GB (on Linux). If the phone struggles, run one gateway at a time.

## 1. Termux and packages
Install **Termux from F-Droid** (not the Play Store build). Then:
```bash
pkg update && pkg upgrade -y
pkg install -y git curl openssl nodejs python build-essential gh termux-api   # `nodejs` (current), not nodejs-lts: OmniRoute needs >= 22.22.2
termux-wake-lock                                                                # keep the servers alive with the screen off
```
Also exempt Termux from battery optimisation (Android settings).

## 2. Get the code (the repo is private, so log in first)
```bash
gh auth login            # GitHub.com -> HTTPS -> "Login with a web browser"; the token stays in gh's store, not in git history
gh repo clone sumeetparmar-cpu/freellmapi-omniroute-setup && cd freellmapi-omniroute-setup
git checkout claude/network-access-connectivity-test-82ck5t   # this work is not merged into main yet
```

## 3. Install and start both gateways (reuses nothing from the sandbox; fresh data on the phone)
```bash
./termux/audit-env.sh                      # read-only; fix every BLOCKER first
./termux/freellmapi.sh install && ./termux/freellmapi.sh start
./termux/omniroute.sh  install && ./termux/omniroute.sh  start
./termux/freellmapi.sh health; ./termux/omniroute.sh health
```
Dashboards (open in the phone's browser): **http://127.0.0.1:3001** (FreeLLMAPI: create the first account) and **http://127.0.0.1:20128** (OmniRoute: `./termux/omniroute.sh credentials` prints the admin password; to see the dashboard set `OMNIROUTE_HEADLESS=0` in `~/llm-gateways/config/omniroute.env` and `./termux/omniroute.sh restart`).

## 4. Make them free-only (do this before using them)
1. **FreeLLMAPI** dashboard → copy the unified API key. Add the OVH anonymous endpoint as a *custom endpoint*: base URL `https://oai.endpoints.kepler.ai.cloud.ovh.net/v1`, model `gpt-oss-20b`, **no API key** (see docs/FREE-ONLY.md).
2. **OmniRoute** dashboard → Providers → *Add OpenAI-compatible node*: name `OVH anonymous`, **prefix `ovhanon`**, type `chat`, base URL as above; add a connection **without an API key** and make it active. Then create an API key under *Endpoints*.
3. Prune and audit (disable-only), then start the guards:
```bash
export FREELLMAPI_ADMIN_TOKEN=...          # from the FreeLLMAPI dashboard
export OMNIROUTE_ADMIN_PASSWORD=...        # from `omniroute.sh credentials`
./termux/free-guard.sh audit               # FreeLLMAPI: non-free models disabled; OmniRoute: read-only check
./termux/free-guard.sh setup freellmapi    # asks for the FreeLLMAPI key (hidden), prints YOUR guard key once
./termux/free-guard.sh setup omniroute     # same for OmniRoute
./termux/free-guard.sh start; ./termux/free-guard.sh status
```
**Use the guard ports from your apps:** FreeLLMAPI `http://127.0.0.1:3101/v1` (model `gpt-oss-20b`), OmniRoute `http://127.0.0.1:20228/v1` (model `ovhanon/gpt-oss-120b`), each with its own guard key. Not the raw ports 3001/20128, which list paid model names.

## 5. First real request (₹0: OVH anonymous tier, 2 requests/minute/model)
```bash
curl -s http://127.0.0.1:3101/v1/chat/completions -H "Authorization: Bearer $GUARD_KEY" -H 'content-type: application/json' \
  -d '{"model":"gpt-oss-20b","max_tokens":200,"messages":[{"role":"user","content":"Reply with one word: pong"}]}'
```
(`max_tokens` needs room: these are reasoning models and short budgets can come back with empty text.)

## Reaching it from other devices
Everything binds to `127.0.0.1`, so only apps on the phone can reach it, on purpose. For your laptop or other devices later, use a private VPN (Tailscale) and keep key auth on; never port-forward to the internet.

## Daily use
`./termux/free-guard.sh status|stop|restart|logs <gw>`, `./termux/freellmapi.sh status|stop|restart|backup`, `./termux/omniroute.sh ...`. Backups include the guard's key hashes, not the gateway keys.
