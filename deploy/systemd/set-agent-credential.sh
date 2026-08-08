#!/usr/bin/env bash
# Store one Buzz agent identity without echoing or logging its private key.
# Run this yourself in a private SSH terminal, never through an assistant tool.
set -euo pipefail

OWNER_PUBKEY="40311b9e4cd014bd0a4e2a6b5e3654b2259d7cd2937f9dc0a61656543a63228c"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KEYTOOL="${REPO_ROOT}/target/release/examples/buzz_keytool"
CONFIG_DIR="${HOME}/.config/buzz-agents"

agent="${1:-}"
case "${agent}" in
  codex)
    agent_command="${HOME}/.local/bin/codex-acp"
    agent_args=""
    ;;
  claude)
    agent_command="${HOME}/.local/bin/claude-agent-acp"
    agent_args=""
    ;;
  cursor)
    agent_command="${HOME}/.local/bin/cursor-agent"
    agent_args="acp"
    ;;
  *)
    echo "usage: $0 <codex|claude|cursor>" >&2
    exit 2
    ;;
esac

[[ -x "${KEYTOOL}" ]] || {
  echo "Missing ${KEYTOOL}; wait for the Buzz release build to finish." >&2
  exit 1
}
[[ -x "${agent_command}" ]] || {
  echo "Missing runtime executable: ${agent_command}" >&2
  exit 1
}

read -r -s -p "Paste the ${agent} nsec/private key (hidden): " private_key
echo
read -r -s -p "Paste the ${agent} NIP-OA auth tag (hidden): " auth_tag
echo

[[ -n "${private_key}" && -n "${auth_tag}" ]] || {
  unset private_key auth_tag
  echo "Both values are required; nothing was written." >&2
  exit 1
}

verification="$(printf '%s\n%s\n' "${private_key}" "${auth_tag}" | "${KEYTOOL}" verify-auth)" || {
  unset private_key auth_tag
  exit 1
}
pubkey="$(printf '%s\n' "${verification}" | sed -n 's/^PUBKEY_HEX=//p')"
owner="$(printf '%s\n' "${verification}" | sed -n 's/^OWNER_PUBKEY_HEX=//p')"
[[ "${owner}" == "${OWNER_PUBKEY}" ]] || {
  unset private_key auth_tag verification
  echo "The attestation belongs to owner ${owner}, not this relay owner; nothing was written." >&2
  exit 1
}

install -d -m 700 "${CONFIG_DIR}"
tmp="$(mktemp "${CONFIG_DIR}/.${agent}.env.XXXXXX")"
trap 'unset private_key auth_tag verification; test ! -e "${tmp:-}" || unlink "${tmp}"' EXIT
chmod 600 "${tmp}"
{
  printf "BUZZ_PRIVATE_KEY='%s'\n" "${private_key}"
  printf "NOSTR_PRIVATE_KEY='%s'\n" "${private_key}"
  printf "BUZZ_AUTH_TAG='%s'\n" "${auth_tag}"
  printf "BUZZ_ACP_AGENT_COMMAND='%s'\n" "${agent_command}"
  printf "BUZZ_ACP_AGENT_ARGS='%s'\n" "${agent_args}"
} > "${tmp}"
unset private_key auth_tag verification
mv "${tmp}" "${CONFIG_DIR}/${agent}.env"
trap - EXIT

echo "Credential installed for ${agent}."
echo "Agent pubkey: ${pubkey}"
echo "The service remains disabled until relay membership is verified."
