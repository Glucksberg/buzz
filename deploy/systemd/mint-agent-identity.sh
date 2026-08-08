#!/usr/bin/env bash
# Mint a new Buzz agent identity directly on this VPS.
# Run this yourself in a private SSH terminal, never through an assistant tool.
set -euo pipefail

OWNER_PUBKEY="40311b9e4cd014bd0a4e2a6b5e3654b2259d7cd2937f9dc0a61656543a63228c"
RELAY_URL="wss://buzz.cloudfarm.ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MINTER="${REPO_ROOT}/target/release/examples/buzz_agent_mint"

agent="${1:-}"
case "${agent}" in
  codex)
    display_name="Codex"
    agent_command="${HOME}/.local/bin/codex-acp"
    agent_args=""
    ;;
  claude)
    display_name="Claude"
    agent_command="${HOME}/.local/bin/claude-agent-acp"
    agent_args=""
    ;;
  cursor)
    display_name="Cursor"
    agent_command="${HOME}/.local/bin/cursor-agent"
    agent_args="acp"
    ;;
  *)
    echo "usage: $0 <codex|claude|cursor>" >&2
    exit 2
    ;;
esac

credential="${HOME}/.config/buzz-agents/${agent}.env"
[[ -x "${MINTER}" ]] || {
  echo "Missing ${MINTER}; build it before minting." >&2
  exit 1
}
[[ -x "${agent_command}" ]] || {
  echo "Runtime is not installed: ${agent_command}" >&2
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
  --name "${display_name}" \
  --relay "${RELAY_URL}" \
  --expected-owner "${OWNER_PUBKEY}" \
  --credential "${credential}" \
  --agent-command "${agent_command}" \
  --agent-args "${agent_args}"

unset owner_key
trap - EXIT
echo "The ${display_name} service is still disabled and stopped."
