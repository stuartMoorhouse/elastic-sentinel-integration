#!/usr/bin/env bash
# Create or update the Elastic Cases templates in config/kibana/case-templates/*.yaml.
# Each template is matched by the YAML `name`: missing -> created, changed -> replaced
# (a new template version), identical -> left alone. Idempotent.
#
# Standalone (no Terraform outputs needed) so Terraform can call it during apply.
# Inputs, all environment variables: KIBANA_URL, KIBANA_USER, KIBANA_PASSWORD.
# Case custom fields are defined inline in each template (Kibana 9.5+ case templates).
set -euo pipefail

: "${KIBANA_URL:?KIBANA_URL is required}"
: "${KIBANA_USER:?KIBANA_USER is required}"
: "${KIBANA_PASSWORD:?KIBANA_PASSWORD is required}"
command -v jq >/dev/null && command -v curl >/dev/null || { echo "jq and curl are required" >&2; exit 1; }

KIBANA_URL="${KIBANA_URL%/}"
OWNER="securitySolution"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config/kibana/case-templates" && pwd)"

# Credentials go in a 0600 curl config, never on the command line.
CURL_CFG="$(mktemp)"
trap 'rm -f "$CURL_CFG"' EXIT
chmod 600 "$CURL_CFG"
u="${KIBANA_USER//\\/\\\\}"; u="${u//\"/\\\"}"
p="${KIBANA_PASSWORD//\\/\\\\}"; p="${p//\"/\\\"}"
printf 'user = "%s:%s"\n' "$u" "$p" > "$CURL_CFG"

# kb METHOD PATH [BODY] -> body on stdout; fails (with the body on stderr) on HTTP >= 400
kb() {
  local out code
  out="$(mktemp)"
  local args=(-sS -K "$CURL_CFG" -o "$out" -w '%{http_code}' --connect-timeout 10 --max-time 60
    -X "$1" -H 'Content-Type: application/json' -H 'kbn-xsrf: true' -H 'elastic-api-version: 2023-10-31')
  [[ -n "${3:-}" ]] && args+=(--data-binary "$3")
  code="$(curl "${args[@]}" "$KIBANA_URL$2")" || { rm -f "$out"; echo "Cannot reach $KIBANA_URL" >&2; return 2; }
  cat "$out"; rm -f "$out"
  if (( code >= 400 )); then echo "$1 $2 returned HTTP $code" >&2; return 1; fi
}

# Wait for the Cases templates API (Kibana can lag behind the deployment becoming healthy).
ready=0
for _ in $(seq 1 30); do
  if kb GET "/api/cases/templates?owner=$OWNER&perPage=100" >/dev/null 2>&1; then ready=1; break; fi
  sleep 10
done
(( ready )) || { echo "Cases templates API not available after 5 minutes" >&2; exit 1; }

existing="$(kb GET "/api/cases/templates?owner=$OWNER&perPage=100")"

shopt -s nullglob
files=("$DIR"/*.yaml)
(( ${#files[@]} > 0 )) || { echo "No template YAML files in $DIR" >&2; exit 1; }

for f in "${files[@]}"; do
  name="$(awk -F': *' '/^name:/ {sub(/^name: */, ""); print; exit}' "$f")"
  [[ -n "$name" ]] || { echo "No top-level name in $f" >&2; exit 1; }
  body="$(jq -n --arg o "$OWNER" --rawfile d "$f" '{owner:$o, definition:$d}')"
  match="$(jq -c --arg n "$name" '[.templates[] | select(.name == $n)][0] // empty' <<<"$existing")"
  if [[ -z "$match" ]]; then
    kb POST /api/cases/templates "$body" >/dev/null
    echo "Created template: $name"
  elif [[ "$(jq -r '.definitionString' <<<"$match")" == "$(cat "$f")" ]]; then
    echo "Unchanged template: $name"
  else
    kb PUT "/api/cases/templates/$(jq -r '.templateId' <<<"$match")" "$body" >/dev/null
    echo "Updated template: $name"
  fi
done
