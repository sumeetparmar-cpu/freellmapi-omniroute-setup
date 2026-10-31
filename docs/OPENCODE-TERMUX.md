# OpenCode on the phone, through the two free-only gateways

**Status, stated plainly.** Prepared and Linux-tested: the config generator + checker (16 checks, mutation-tested), the launcher, and the capability check of the two guarded gateways (`gateways.sh compat`, real requests). **NOT done and NOT claimed: OpenCode is not installed anywhere yet, and nothing here proves it runs on Android.** The install route is unknown until your phone answers `opencode-setup.sh probe`.

## 1. Where Claude/Anthropic inference is still used (audit, 2026-10-31)
| Component | Uses Claude? | Evidence / how to stop |
|---|---|---|
| **The cloud Claude Code session that builds this repo** (the assistant you are talking to) | **YES, every message** | It is a remote session managed by claude.ai (`CLAUDE_CODE_REMOTE_SDK_URL` is set, no `ANTHROPIC_BASE_URL`). It cannot be pointed at your phone (no route to loopback), and a custom-provider setting would need an Anthropic-Messages-format endpoint, which these OpenAI-format gateways are not (a translator would be needed). **The only way to stop that usage is to stop using this session.** |
| Subagents / background tasks started by that session | YES | Same session. |
| FreeLLMAPI, OmniRoute, the guards, the bootstrap and every script in this repo | **No** | `grep` finds no Anthropic call or key anywhere in the repo; both gateways are configured with ONE provider (OVH anonymous) and the guards refuse everything else. |
| OpenCode (once installed) | No, if configured as below | `enabled_providers` lists only our two gateways; `small_model` is ours; `opencode-setup.sh check` fails on any deviation. |
Never claim "zero Claude tokens" while this session is in use: it is not.

## 2. What a coding agent needs, measured (real requests, both guards)
`bash gateways.sh compat` (about 3 minutes, paced for OVH's limit). Measured 2026-10-31 on a cloud replica of your exact stack (same code, same real OVH endpoint; the phone itself was not reachable):

| Capability | FreeLLMAPI guard (`gpt-oss-20b`) | OmniRoute guard (`ovhanon/gpt-oss-120b`) |
|---|---|---|
| Streaming (SSE) | PASS (45 chunks) | PASS (25 chunks) |
| Tool call (function calling) | PASS (`read_file({"path":...})`) | PASS |
| Tool result used in the answer | PASS | PASS |
| Structured output (JSON mode) | PASS | PASS |
| Long context (20,650-token prompt, needle found) | PASS | PASS |
| Answered by | OVH route (`custom/gpt-oss-20b`) | OVH route (custom node, `gpt-oss-120b`) |

So protocol-wise both gateways can carry an agent. Quality of the model is a separate matter: these are open-weight models, not Claude.

## 3. The hard limit you must know about
OVH's anonymous tier allows **2 requests per minute per model per IP**. A coding agent makes many requests per task (read file, edit, run tests, summarise): realistically **10-40 per task**, so one task takes **5-20 minutes** and long sessions will hit the limit. It will not feel like Claude. Real throughput needs your own free-tier keys behind the same guards: Groq (30 requests/min on gpt-oss), Google AI Studio, Mistral free, OpenRouter `:free` models, Cloudflare Workers AI (all already in `config/free-policy.json`, none configured because no keys were supplied). The guards then fail safely with HTTP 429 + `Retry-After` when free capacity is gone: there is no fallback to anything else.

## 4. Pricing note (correction)
OVH's public model list now shows per-token prices (for example gpt-oss-120b $0.00000009 input / $0.00000047 output). Earlier notes said "all priced 0": that no longer matches. Those prices apply to **authenticated** use (OVH docs: authenticated = 400 requests/minute per PCI project). The anonymous tier sends **no key and no account**, so there is nothing to bill, but the gateways cannot report a cost, so "₹0" is inferred from that, not measured. Never create an OVH API key for these gateways.

## 5. Install OpenCode on the phone (YOU run; I do not claim success until I see your output)
Step 1, read-only probe (installs nothing; send me the output):
```
cd ~/freellmapi-omniroute-setup && git pull --ff-only && bash termux/opencode-setup.sh probe
```
Candidate routes, **unverified until the probe answers** (the npm package ships only Linux glibc/musl binaries, and Termux's Node reports its platform as `android`, so a plain `npm i -g opencode-ai` is expected to fail):
* a Termux package, if `pkg search opencode` lists one;
* otherwise OpenCode inside a Linux userland (`proot-distro` with Debian), where the arm64 Linux binary can run and `127.0.0.1` is shared with the phone.
Do not install anything from this list until I have your probe output.

Step 2 (after OpenCode is installed): `bash termux/opencode-setup.sh config && bash termux/opencode-setup.sh check`, then run `~/llm-gateways/bin/opencode-free` instead of `opencode`.
Step 3: `bash termux/opencode-accept.sh` (untested): a real coding task through each gateway (the test result is checked by `node --test`, not by the model), an independent review by the other gateway, and a refused-provider check.

## 6. Usage tracking
`bash termux/gateways.sh usage` shows, per guard, requests allowed/blocked today and counts by provider (read from the guard, not from the model's own claims).
