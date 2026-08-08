#!/usr/bin/env bash
# Create a password-encrypted backup of the VPS-managed Buzz agent identities.
# Run this yourself in a private SSH terminal, never through an assistant tool.
set -euo pipefail

CONFIG_DIR="${HOME}/.config/buzz-agents"
AGENTS=(codex claude cursor)

for agent in "${AGENTS[@]}"; do
  credential="${CONFIG_DIR}/${agent}.env"
  [[ -f "${credential}" ]] || {
    echo "Missing credential: ${credential}" >&2
    exit 1
  }
  [[ "$(stat -c '%a' "${credential}")" == "600" ]] || {
    echo "Unsafe permissions on ${credential}; expected 600." >&2
    exit 1
  }
done

read -r -s -p "Backup password (hidden, 12+ characters): " passphrase
echo
read -r -s -p "Repeat backup password: " confirmation
echo
trap 'unset passphrase confirmation' EXIT

[[ "${passphrase}" == "${confirmation}" ]] || {
  echo "Passwords do not match; nothing was written." >&2
  exit 1
}
(( ${#passphrase} >= 12 )) || {
  echo "Password must contain at least 12 characters; nothing was written." >&2
  exit 1
}
unset confirmation

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output="${HOME}/buzz-agent-credentials-${timestamp}.tar.gz.gpg"
tmp="${output}.pending"
trap 'unset passphrase confirmation; test ! -e "${tmp:-}" || unlink "${tmp}"' EXIT
umask 077

tar -C "${CONFIG_DIR}" -czf - codex.env claude.env cursor.env \
  | gpg --batch --yes --quiet --pinentry-mode loopback \
      --passphrase-fd 3 --symmetric --cipher-algo AES256 \
      --s2k-mode 3 --s2k-digest-algo SHA512 \
      --output "${tmp}" 3<<<"${passphrase}"

# Decrypt in memory and check the archive before promoting it to the final name.
contents="$({
  gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
    --decrypt "${tmp}" 3<<<"${passphrase}" \
    | tar -tzf -
})"
expected=$'codex.env\nclaude.env\ncursor.env'
[[ "${contents}" == "${expected}" ]] || {
  echo "Encrypted backup verification failed; nothing was saved." >&2
  exit 1
}

unset passphrase
mv "${tmp}" "${output}"
trap - EXIT
chmod 600 "${output}"

echo "Encrypted backup created and verified:"
echo "${output}"
echo "Contents: codex.env, claude.env, cursor.env"
echo "The password is required for recovery and is not stored in this file."
