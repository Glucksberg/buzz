#!/usr/bin/env bash
# Create a consistent, restorable backup of the single-node Buzz deployment.
# A short maintenance window is intentional: the relay is stopped before the
# database dump and the MinIO/git/Redis snapshots, then restored by a trap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ "${1:-}" != "--maintenance-window" ]]; then
  echo "usage: $0 --maintenance-window [backup-directory]" >&2
  echo "This briefly stops relay writes so Postgres and volume state agree." >&2
  exit 2
fi

BACKUP_ROOT="${2:-${HOME}/backups/buzz}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FINAL="${BACKUP_ROOT}/buzz-relay-${STAMP}.tar.gz"
COMPOSE=(docker compose --env-file .env -f compose.yml)

[[ -f .env ]] || {
  echo "Missing ${SCRIPT_DIR}/.env" >&2
  exit 1
}

install -d -m 700 "${BACKUP_ROOT}"
exec 9>"${BACKUP_ROOT}/.backup.lock"
flock -n 9 || {
  echo "Another Buzz backup is already running" >&2
  exit 1
}

STAGE="$(mktemp -d "${BACKUP_ROOT}/.backup-${STAMP}.XXXXXX")"
relay_was_running=false
redis_was_running=false
minio_was_running=false

service_is_running() {
  local service="$1" cid
  cid="$("${COMPOSE[@]}" ps -q "${service}")"
  [[ -n "${cid}" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "${cid}")" == "true" ]]
}

volume_for() {
  local service="$1" destination="$2" cid
  cid="$("${COMPOSE[@]}" ps -a -q "${service}")"
  [[ -n "${cid}" ]] || {
    echo "No container exists for service ${service}" >&2
    return 1
  }
  docker inspect --format "{{range .Mounts}}{{if eq .Destination \"${destination}\"}}{{.Name}}{{end}}{{end}}" "${cid}"
}

restore_services() {
  local status=$?
  trap - EXIT INT TERM
  if ${redis_was_running}; then "${COMPOSE[@]}" start redis >/dev/null || true; fi
  if ${minio_was_running}; then "${COMPOSE[@]}" start minio >/dev/null || true; fi
  if ${relay_was_running}; then "${COMPOSE[@]}" up -d --wait relay >/dev/null || true; fi
  rm -rf "${STAGE}"
  exit "${status}"
}
trap restore_services EXIT INT TERM

service_is_running relay && relay_was_running=true
service_is_running redis && redis_was_running=true
service_is_running minio && minio_was_running=true

${relay_was_running} || {
  echo "Relay is not running; refusing to claim a production-consistent backup" >&2
  exit 1
}

echo "Stopping relay writes for the backup window..."
"${COMPOSE[@]}" stop relay >/dev/null

echo "Dumping Postgres..."
"${COMPOSE[@]}" exec -T postgres sh -euc \
  'exec pg_dump --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --format=custom --no-owner --no-privileges' \
  >"${STAGE}/postgres.dump"

if ${redis_was_running}; then
  "${COMPOSE[@]}" exec -T redis sh -euc \
    'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli SAVE >/dev/null'
  "${COMPOSE[@]}" stop redis >/dev/null
fi
if ${minio_was_running}; then
  "${COMPOSE[@]}" stop minio >/dev/null
fi

postgres_volume="$(volume_for postgres /var/lib/postgresql/data)"
redis_volume="$(volume_for redis /data)"
minio_volume="$(volume_for minio /data)"
git_volume="$(volume_for relay /data/git)"

archive_volume() {
  local volume="$1" output="$2"
  docker run --rm --volume "${volume}:/volume:ro" postgres:17-alpine \
    tar -C /volume -czf - . >"${STAGE}/${output}"
}

echo "Archiving MinIO, git, and Redis volumes..."
archive_volume "${minio_volume}" minio-data.tar.gz
archive_volume "${git_volume}" git-data.tar.gz
archive_volume "${redis_volume}" redis-data.tar.gz

install -m 600 .env "${STAGE}/compose.env"
install -m 600 Caddyfile "${STAGE}/Caddyfile"
{
  printf 'created_utc=%s\n' "${STAMP}"
  printf 'source_commit=%s\n' "$(git rev-parse HEAD 2>/dev/null || printf unknown)"
  printf 'postgres_volume=%s\n' "${postgres_volume}"
  printf 'redis_volume=%s\n' "${redis_volume}"
  printf 'minio_volume=%s\n' "${minio_volume}"
  printf 'git_volume=%s\n' "${git_volume}"
  printf 'restore_order=Postgres dump, MinIO/git volumes, Redis volume, compose.env\n'
} >"${STAGE}/MANIFEST.txt"

tar -C "${STAGE}" -czf "${FINAL}.tmp" .
chmod 600 "${FINAL}.tmp"
mv -f "${FINAL}.tmp" "${FINAL}"
sha256sum "${FINAL}" >"${FINAL}.sha256"
chmod 600 "${FINAL}.sha256"

echo "Backup created: ${FINAL}"
echo "Copy this archive and checksum off the VPS; the local copy is not disaster recovery."

