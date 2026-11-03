# Phone cheat sheet: OpenCode on your two free gateways (₹0)

Everything runs on your phone (Termux). Nothing goes to Claude, and nothing can bill you: both gateways use OVH's anonymous free tier, behind guards that refuse any model that is not allowlisted. Type commands; never paste into a window that is already running something.

## Daily use
| Do this | Command |
|---|---|
| Start everything (safe to repeat) | `bash ~/freellmapi-omniroute-setup/termux/gateways.sh start` |
| Work on a project | `cd ~/your-project && ~/llm-gateways/bin/opencode-free` |
| One-shot prompt | `~/llm-gateways/bin/opencode-free run "your request"` |
| Choose the model | add `-m omniroute/ovhanon/gpt-oss-120b` (all lowercase) |
| Stop everything | `bash ~/freellmapi-omniroute-setup/termux/gateways.sh stop` |

Keep projects under your home folder. Edits and shell commands ask for your approval in the full-screen mode.

## Which model
- `omniroute/ovhanon/gpt-oss-120b` = coding model (default). Passed both coding tasks on this phone.
- `freellmapi/gpt-oss-20b` = background chores and short answers. NOT reliable for coding.
- Provider names are case-sensitive: `freeLLMapi/...` gives "Unexpected server error".

## Speed (expect it)
OVH allows 2 requests per minute per model. A one-line fix takes minutes, a 4-bug project took about 37 minutes. `local rate limit ... retry in Ns` is not an error and costs nothing: it retries by itself.

## Check and fix
| Question | Command |
|---|---|
| Are all four processes up? | `bash ~/freellmapi-omniroute-setup/termux/gateways.sh status` |
| What did the guards allow/block today? | `bash ~/freellmapi-omniroute-setup/termux/gateways.sh usage` |
| Something is wrong | `bash ~/freellmapi-omniroute-setup/termux/gateways.sh doctor` (prints the fix) |
| One real test request each | `bash ~/freellmapi-omniroute-setup/termux/gateways.sh test` |
| Trace a failed OpenCode request | `bash ~/freellmapi-omniroute-setup/termux/opencode-trace.sh` |
| Update the toolkit | `cd ~/freellmapi-omniroute-setup && git pull` |

## Re-run the self-tests (10-40 minutes each)
- `bash termux/opencode-accept.sh` : last result 8 passed, 2 failed (the 2 are the 20B coding checks).
- `bash termux/opencode-bigtask.sh` : last result 3 passed, 0 failed (120B, 4 bugs, about 37 min).

## Do not
- Do not add provider keys or paid plans. Do not use the raw gateway ports 3001 / 20128 from apps: use only the launcher or the guard ports 3101 / 20228.
- Do not paste into a running OpenCode or test window.
- If Android kills Termux: open it again and run `gateways.sh start` (it holds a wake lock; keep the Termux notification).

## Known limits
One phone, small synthetic projects tested. Large or messy real code is untested. Gemini/Groq/other providers are deliberately not configured.
