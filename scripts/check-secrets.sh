#!/usr/bin/env bash
# Scan files for things that look like secrets. Run before every commit:
#   scripts/check-secrets.sh            # scans tracked + staged + untracked-not-ignored files
#   scripts/check-secrets.sh --staged   # scans only staged content
# Exit 1 on any finding. Heuristic: it reduces risk, it does not replace review.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

if [ "${1:-}" = "--staged" ]; then
  mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACMR)
else
  mapfile -t FILES < <({ git ls-files; git ls-files --others --exclude-standard; } | sort -u)
fi

FOUND=0
flag() { printf 'SECRET? %s:%s: %s\n' "$1" "$2" "$3"; FOUND=1; }

# Forbidden file names/types (real data, never examples).
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.example) ;;
    .env|*/.env|.env.*|*.env|*.pem|*.key|*.p12|*.pfx|*.sqlite|*.sqlite-*|*.db|*.db-*|*.tar.gz|*.zip|*.pid)
      flag "$f" 0 "forbidden file type (credentials / database / backup)";;
  esac
done

# Content patterns. Placeholders such as <...>, YOUR_..., xxxx, example/test markers are allowed.
PATTERNS=(
  'sk-[A-Za-z0-9_-]{16,}'                         # OpenAI-style / OmniRoute keys
  'freellmapi-[A-Za-z0-9]{16,}'                   # FreeLLMAPI unified key
  'gsk_[A-Za-z0-9]{20,}'                          # Groq
  'AIza[0-9A-Za-z_-]{30,}'                        # Google
  'gh[pousr]_[A-Za-z0-9]{30,}'                    # GitHub tokens
  'github_pat_[A-Za-z0-9_]{30,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'                  # Slack
  'AKIA[0-9A-Z]{16}'                              # AWS access key id
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '(ENCRYPTION_KEY|JWT_SECRET|API_KEY_SECRET|STORAGE_ENCRYPTION_KEY|INITIAL_PASSWORD|PASSWORD|TOKEN|API_KEY|SECRET)[A-Z_]*[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Fa-f0-9]{32,}'
  'Bearer [A-Za-z0-9._-]{24,}'
)
ALLOW='(example|placeholder|your[-_ ]|<[^>]+>|x{6,}|fake|dummy|mock-key|notreal|0{16,}|\$\{?[A-Za-z_(])'

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in scripts/check-secrets.sh|tests/termux/test-check-secrets.sh) continue;; esac
  if [ "${1:-}" = "--staged" ]; then content="$(git show ":$f" 2>/dev/null)"; else content="$(cat "$f" 2>/dev/null)"; fi
  [ -n "$content" ] || continue
  for pat in "${PATTERNS[@]}"; do
    while IFS=: read -r ln line; do
      [ -n "$ln" ] || continue
      if printf '%s' "$line" | grep -qiE "$ALLOW"; then continue; fi
      flag "$f" "$ln" "$(printf '%s' "$line" | cut -c1-80 | sed -E 's/([A-Za-z0-9_-]{6})[A-Za-z0-9_.-]{6,}/\1…[redacted]/g')"
    done < <(printf '%s\n' "$content" | grep -nE -e "$pat" 2>/dev/null)
  done
done

if [ "$FOUND" -eq 0 ]; then echo "check-secrets: no findings in ${#FILES[@]} files"; else echo "check-secrets: FINDINGS above (values are partially redacted)"; fi
exit "$FOUND"
