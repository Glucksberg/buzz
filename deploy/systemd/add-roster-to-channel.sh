#!/usr/bin/env bash
# Add the existing Windows + VPS agent identities to one channel.
# Run this yourself in a private SSH terminal, never through an assistant tool.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ROSTER_TOOL="${REPO_ROOT}/target/release/examples/buzz_channel_roster"
channel="${1:-}"

[[ -n "${channel}" ]] || {
  echo "usage: $0 <channel-uuid>" >&2
  exit 2
}
[[ -x "${ROSTER_TOOL}" ]] || {
  echo "Missing ${ROSTER_TOOL}; build it before updating a channel." >&2
  exit 1
}

read -r -s -p "Paste the channel owner nsec/private key (hidden): " owner_key
echo
[[ -n "${owner_key}" ]] || {
  echo "No key supplied; nothing changed." >&2
  exit 1
}
trap 'unset owner_key' EXIT

printf '%s' "${owner_key}" | "${ROSTER_TOOL}" "${channel}"

unset owner_key
trap - EXIT
