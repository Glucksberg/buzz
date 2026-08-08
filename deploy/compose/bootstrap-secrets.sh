#!/usr/bin/env bash
# Bootstrap deploy/compose/.env with domain settings and generated secrets.
#
# Safe to run non-interactively (e.g. by an assistant/automation) — this
# script never touches private key material. It intentionally does NOT set
# RELAY_OWNER_PUBKEY; run ./set-owner-key.sh yourself for that, in a
# terminal that nothing else is watching.
#
# Usage: ./bootstrap-secrets.sh [domain]
#   ./bootstrap-secrets.sh buzz.example.com   # public relay with TLS domain
#   ./bootstrap-secrets.sh                    # local-only, no public domain
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

domain="${1:-}"

[[ -f .env ]] || cp .env.example .env

set_env() {
  local key="$1" value="$2"
  sed -i.bak "s|^${key}=.*|${key}=${value}|" .env
  rm -f .env.bak
}

hexsecret() { openssl rand -hex "$1"; }

if [[ -n "${domain}" ]]; then
  set_env "BUZZ_DOMAIN" "${domain}"
  set_env "RELAY_URL" "wss://${domain}"
  set_env "BUZZ_MEDIA_BASE_URL" "https://${domain}/media"
  set_env "BUZZ_MEDIA_SERVER_DOMAIN" "${domain}"
  set_env "BUZZ_CORS_ORIGINS" "https://${domain},http://tauri.localhost,tauri://localhost"
  echo "Domain set: ${domain}"
fi

set_env "BUZZ_RELAY_PRIVATE_KEY" "$(hexsecret 32)"
set_env "BUZZ_GIT_HOOK_HMAC_SECRET" "$(hexsecret 32)"
set_env "POSTGRES_PASSWORD" "$(hexsecret 24)"
set_env "REDIS_PASSWORD" "$(hexsecret 24)"
set_env "BUZZ_S3_ACCESS_KEY" "$(hexsecret 16)"
set_env "BUZZ_S3_SECRET_KEY" "$(hexsecret 24)"

echo "Generated: BUZZ_RELAY_PRIVATE_KEY, BUZZ_GIT_HOOK_HMAC_SECRET, POSTGRES_PASSWORD, REDIS_PASSWORD, BUZZ_S3_ACCESS_KEY, BUZZ_S3_SECRET_KEY"
echo "These are relay/infra secrets, not your personal identity — back up deploy/compose/.env securely (see ./run.sh backup-hint)."
echo
echo "Next: run ./set-owner-key.sh YOURSELF, in your own terminal, to set RELAY_OWNER_PUBKEY."
