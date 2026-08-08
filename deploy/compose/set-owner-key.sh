#!/usr/bin/env bash
# Set RELAY_OWNER_PUBKEY in deploy/compose/.env from your Nostr identity.
#
# IMPORTANT: run this yourself, directly, in a terminal that nothing else is
# reading — not through an AI assistant's tool calls, not piped, not
# `script`/`tee`'d, not in a session someone else can scroll back through.
# The relay only ever needs your PUBLIC key. If you paste a private key
# below, it is read with terminal echo disabled, used in-memory to derive
# the public key, and then discarded — it is never written to disk, never
# logged, and never printed back to you.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[[ -f .env ]] || { echo "deploy/compose/.env not found — run ./bootstrap-secrets.sh first." >&2; exit 1; }

KEYTOOL="${REPO_ROOT}/target/release/examples/buzz_keytool"
if [[ ! -x "${KEYTOOL}" ]]; then
  echo "Building key helper (offline, no network, no key material involved)..." >&2
  (cd "${REPO_ROOT}" && cargo build --release --example buzz_keytool -p buzz-cli)
fi

set_env() {
  sed -i.bak "s|^RELAY_OWNER_PUBKEY=.*|RELAY_OWNER_PUBKEY=${1}|" .env
  rm -f .env.bak
}

echo "1) I already have a Nostr private key (hex or nsec1...)"
echo "2) Generate a new keypair for this owner identity"
read -r -p "Choice [1/2]: " choice

case "${choice}" in
  1)
    read -r -s -p "Paste your private key (input hidden, will not be echoed): " privkey
    echo
    [[ -n "${privkey}" ]] || { echo "No key entered, aborting." >&2; exit 1; }
    out="$(printf '%s' "${privkey}" | "${KEYTOOL}" derive)"
    unset privkey
    pubhex="$(printf '%s\n' "${out}" | sed -n 's/^PUBKEY_HEX=//p')"
    [[ -n "${pubhex}" ]] || { echo "Could not derive a public key from that input." >&2; exit 1; }
    set_env "${pubhex}"
    echo "Owner pubkey set: ${pubhex}"
    ;;
  2)
    out="$("${KEYTOOL}" generate)"
    pubhex="$(printf '%s\n' "${out}" | sed -n 's/^PUBKEY_HEX=//p')"
    nsec="$(printf '%s\n' "${out}" | sed -n 's/^PRIVKEY_NSEC=//p')"
    set_env "${pubhex}"
    echo
    echo "New owner keypair generated."
    echo "  Public key:  ${pubhex}"
    echo "  Private key: ${nsec}"
    echo
    echo "^ Save the private key in a password manager RIGHT NOW — shown once, never saved by this script."
    ;;
  *)
    echo "Invalid choice, aborting." >&2
    exit 1
    ;;
esac

echo
echo "RELAY_OWNER_PUBKEY is set in deploy/compose/.env. Next, sign in client-side with the matching"
echo "private key (buzz-cli's BUZZ_PRIVATE_KEY env var, or the desktop/mobile app's key import) —"
echo "set that only in your own client session, never in the server's .env."
