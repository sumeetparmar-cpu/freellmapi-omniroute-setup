# OpenCode on the phone, through the two free-only gateways

**Status, stated plainly.** Prepared and Linux-tested: the config generator + checker (16 checks, mutation-tested), the launcher, and the capability check of the two guarded gateways (`gateways.sh compat`, real requests). **NOT claimed: that OpenCode runs on your phone.** The install method is established (section 5) but only your phone can show which of the two glibc routes works.

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

## 5. Install OpenCode on the phone
**Established (from OpenCode's own published files and your phone's probe):** the official `npm i -g opencode-ai` cannot work on Termux. Its installer maps only `darwin/linux/win32`; Termux's Node reports `android`, so it would look for `opencode-android-arm64`, which does not exist (registry: HTTP 404), and the real binaries are marked Linux-only so npm skips them. The binary itself is an ELF aarch64 glibc executable (interpreter `/lib/ld-linux-aarch64.so.1`, needs only libc/libm/libpthread/libdl, nothing newer than glibc 2.17); Android's own libc cannot run it. Your phone has no Termux `opencode` package, no `proot-distro` and no system glibc.

**So the installer supplies glibc:** it downloads the binary straight from the npm registry and verifies its sha512 against the registry (a tampered file, a wrong-architecture binary or a non-https source is refused: tested), then tries Termux's `glibc-runner`, and if that does not work Debian under `proot-distro`. A method counts only if it really runs `opencode --version`. Which one works on your phone is **not known until you run it**; the Linux tests prove the logic, not Android.

```
cd ~/freellmapi-omniroute-setup && git pull --ff-only && bash termux/opencode-install.sh
```
It never touches the gateways or their data, is safe to re-run, and if neither method works it says so and marks nothing as installed.

Then run OpenCode with `~/llm-gateways/bin/opencode-free` (it reads the guard keys from their mode-600 files; no key is on any command line or in any file it writes). Config: only `freellmapi` and `omniroute` are enabled providers, the background model is ours, sharing and auto-update are off; `bash termux/opencode-setup.sh check` re-verifies that at any time.
End-to-end acceptance (real coding tasks through each gateway, independent review by the other, refused-provider check): `bash termux/opencode-accept.sh` (untested until you run it; budget 10-20 minutes because of OVH's 2 requests/minute).

## 6. Usage tracking
`bash termux/gateways.sh usage` shows, per guard, requests allowed/blocked today and counts by provider (read from the guard, not from the model's own claims).
