#!/usr/bin/env bash
# Start a fresh unit of work in a channel: rotate the ACP sessions of the
# VPS agents (one "!rotate" mentioning all of them) and post a root message
# marking the new work boundary.
#
# Interim stand-in for the "Start new work" UX proposed in block/buzz#5354.
# Run this yourself in a private SSH terminal, never through an assistant tool.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUZZ_CLI="${REPO_ROOT}/target/release/buzz"
RELAY_URL="${BUZZ_RELAY_URL:-https://buzz.cloudfarm.ai}"

# VPS agent identities (stable pubkeys).
AGENTS=(
  "c2374d1adac80ff318caee358383f00019a830923a2427e440efa4c104085a42" # Codex
  "8ddea194fa6b61a0cf32a86e567ce368f5069d41c16668ad0f9b9d1ad934039a" # Claude
  "dbfd5ae7137fbeb7ab453d39fa7b0f0c43a9d55eb7ed9422e3bae3fa948a7541" # Cursor
)

title="${1:-}"
channel="${2:-d5f19242-7f81-4f5f-a63d-77da7c8f06ca}" # default: 1st TEST

[[ -n "${title}" ]] || {
  echo "usage: $0 \"<work title>\" [channel-uuid]" >&2
  exit 2
}
[[ -x "${BUZZ_CLI}" ]] || {
  echo "Missing ${BUZZ_CLI}; build buzz-cli first." >&2
  exit 1
}

read -r -s -p "Paste the owner nsec/private key (hidden): " owner_key
echo
[[ -n "${owner_key}" ]] || {
  echo "No key supplied; nothing changed." >&2
  exit 1
}
trap 'unset owner_key BUZZ_PRIVATE_KEY' EXIT

export BUZZ_PRIVATE_KEY="${owner_key}"

# 1. One "!rotate" mentioning every agent: each harness consumes it and
#    starts the next turn in this channel with a fresh ACP session.
mention_args=()
for pk in "${AGENTS[@]}"; do mention_args+=(--mention "${pk}"); done
"${BUZZ_CLI}" --relay "${RELAY_URL}" messages send \
  --channel "${channel}" --content '!rotate' "${mention_args[@]}" >/dev/null
echo "sessions rotated (${#AGENTS[@]} agents)"

# 2. Root message marking the work boundary (no agent mentions on purpose —
#    kick off the coordinator yourself in a reply).
"${BUZZ_CLI}" --relay "${RELAY_URL}" messages send \
  --channel "${channel}" \
  --content "🆕 Novo trabalho: ${title} — contexto dos agentes zerado. Detalhes e kickoff nesta thread." \
  | sed -E 's/.*"event_id":"([a-f0-9]+)".*/root message: \1/'

unset owner_key BUZZ_PRIVATE_KEY
trap - EXIT
