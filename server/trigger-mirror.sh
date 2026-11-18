#!/bin/sh
# Starts the mirror workflow through the GitHub API (workflow_dispatch). Meant for the owner's own
# server, from cron, as a second way to start the mirror besides GitHub's thinned-out schedule.
#
# The token is read from TOKEN_FILE (owner root, mode 600), never from arguments or the repo.
# It is a fine-grained personal access token limited to the mirror repository with the repository
# permission "Actions: Read and write". It is handed to curl through stdin, so it does not show
# up in the process list.
#
# Exit status: 0 when GitHub accepted the request (HTTP 204), 1 otherwise.
set -eu

REPO="kpaha/skypin-ephemeris"
WORKFLOW="mirror.yml"
REF="main"
TOKEN_FILE="${TOKEN_FILE:-/etc/ephemeris-mirror/github-token}"

say() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') trigger-mirror: $*"; }

[ -f "$TOKEN_FILE" ] && [ -r "$TOKEN_FILE" ] || { say "cannot read $TOKEN_FILE"; exit 1; }
if [ -n "$(find "$TOKEN_FILE" -prune \( -perm -040 -o -perm -004 \) -print)" ]; then
  say "$TOKEN_FILE is readable by group or others; run: chmod 600 $TOKEN_FILE"
  exit 1
fi
token=$(tr -d ' \t\r\n' < "$TOKEN_FILE")
[ -n "$token" ] || { say "$TOKEN_FILE is empty"; exit 1; }

code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS -o /dev/null -w '%{http_code}' \
  --connect-timeout 15 --max-time 60 -K - \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "{\"ref\":\"$REF\"}" \
  "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW/dispatches") || code="curl failed"

if [ "$code" = 204 ]; then
  say "dispatched $WORKFLOW on $REPO@$REF"
else
  say "GitHub answered $code (401: bad or expired token; 403/404: token lacks Actions write on $REPO or wrong name)"
  exit 1
fi
