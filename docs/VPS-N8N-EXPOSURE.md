# n8n on port 5678: exposure risk (separate from the OmniRoute deployment; NOTHING here is changed by this toolkit)

Status of the evidence: the owner reports that n8n port 5678 is publicly reachable. This repo has not seen the VPS's listener list, firewall rules or `vyora-n8n-5678-block.service` content. The only verified fact from the survey screenshot is that a unit named `vyora-n8n-5678-block.service` exists and is `active/exited` (a one-shot unit that ran and finished), plus running `n8n` and `n8n task-runner` processes and Caddy with `/etc/caddy/Caddyfile`. Everything else below is reasoning, not verified.

## Why it matters
* n8n executes workflows: shell/code nodes, HTTP calls and stored credentials for other services (SUPPAR, EARNIX, databases, API keys). An unauthenticated or weakly authenticated n8n reachable from the internet is a remote-code-execution and credential-theft risk, and n8n has had critical vulnerabilities in the past that were exploitable without login.
* Port 5678 serves plain HTTP. If it is reachable directly, logins and webhook payloads cross the internet unencrypted; Caddy (TLS) in front of it is bypassed.
* Docker publishes ports by writing its own firewall rules that are evaluated BEFORE ufw/nft input rules of the host. A "block" unit that inserts a rule once at boot can be bypassed or wiped when Docker restarts or reloads rules. `active/exited` means it ran once, not that a rule is currently enforced.

## What would settle it (read-only; the forensic survey now includes this section)
`bash vps/remote-survey.sh root@HOST --forensic ...` prints, under "N8N / PORT 5678 EXPOSURE": which address 5678 listens on (`127.0.0.1` = private, `0.0.0.0`/`::` = all interfaces), whether a Docker container publishes 5678 and on which address, the installed content of `vyora-n8n-5678-block.service` (unit text only), any firewall rules that mention 5678 or the DOCKER-USER chain. From the phone's own network, a connection test is the only proof of external reachability: `curl -m 5 -s -o /dev/null -w '%{http_code}\n' http://VPS_IP:5678/` (a connect timeout or refusal from a network outside the VPS means blocked; an HTTP code means reachable). Run it from mobile data, not from the VPS.

## Risk rating (provisional until the above is seen)
HIGH if the phone test returns an HTTP code. LOW if it times out/refuses AND the listener is loopback or the block rule is verifiably active. Unknown right now.

## Recommended remediation (needs the owner's separate approval; the OmniRoute deployment does NOT depend on it and does not touch it)
1. Prefer binding n8n to loopback only, published as `127.0.0.1:5678:5678` in its Compose file, with Caddy proxying to it. (Changes n8n's Compose project: not done here.)
2. Or enforce the block where Docker cannot bypass it: a rule in the `DOCKER-USER` chain (or nft `forward` hook) that drops external traffic to port 5678, made persistent.
3. Make sure n8n has owner login enabled and is on a supported version.
This toolkit adds none of these, changes no firewall rule, and binds everything it deploys to 127.0.0.1.
