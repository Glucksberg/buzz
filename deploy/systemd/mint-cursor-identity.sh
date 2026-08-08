#!/usr/bin/env bash
# Mint Cursor directly on this VPS without persisting the owner's private key.
# Run this yourself in a private SSH terminal, never through an assistant tool.
set -euo pipefail

OWNER_PUBKEY="40311b9e4cd014bd0a4e2a6b5e3654b2259d7cd2937f9dc0a61656543a63228c"
RELAY_URL="wss://buzz.cloudfarm.ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MINTER="${REPO_ROOT}/target/release/examples/buzz_agent_mint"
CREDENTIAL="${HOME}/.config/buzz-agents/cursor.env"

[[ -x "${MINTER}" ]] || {
  echo "Missing ${MINTER}; build it before minting." >&2
  exit 1
}
[[ -x "${HOME}/.local/bin/cursor-agent" ]] || {
  echo "Cursor CLI is not installed at ${HOME}/.local/bin/cursor-agent." >&2
  exit 1
}

read -r -s -p "Paste the relay owner nsec/private key (hidden): " owner_key
echo
[[ -n "${owner_key}" ]] || {
  echo "No key supplied; nothing changed." >&2
  exit 1
}
trap 'unset owner_key' EXIT

printf '%s' "${owner_key}" | "${MINTER}" \
  --name Cursor \
  --relay "${RELAY_URL}" \
  --expected-owner "${OWNER_PUBKEY}" \
  --credential "${CREDENTIAL}" \
  --agent-command "${HOME}/.local/bin/cursor-agent" \
  --agent-args acp

unset owner_key
trap - EXIT
echo "The Cursor service is still disabled and stopped."
