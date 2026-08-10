#!/usr/bin/env bash
# Report transitions in the health of the VPS-managed Buzz agent services.
#
# The monitor deliberately posts only on a transition (healthy -> down or
# down -> healthy). If delivery fails, the state is not advanced, so the next
# timer run retries the alert instead of silently losing it.
set -euo pipefail

SYSTEMCTL_BIN="${BUZZ_AGENT_MONITOR_SYSTEMCTL:-systemctl}"
BUZZ_CLI="${BUZZ_AGENT_MONITOR_CLI:-${HOME}/buzz/target/release/buzz}"
CHANNEL="${BUZZ_AGENT_MONITOR_CHANNEL:-}"
STATE_DIR="${BUZZ_AGENT_MONITOR_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/buzz-agent-monitor}"
STATE_FILE="${STATE_DIR}/down-agents"
AGENT_NAMES="${BUZZ_AGENT_MONITOR_AGENTS:-codex claude cursor}"

[[ -n "${CHANNEL}" ]] || {
  echo "BUZZ_AGENT_MONITOR_CHANNEL is required" >&2
  exit 2
}
[[ -x "${BUZZ_CLI}" ]] || {
  echo "Buzz CLI is not executable: ${BUZZ_CLI}" >&2
  exit 1
}

install -d -m 700 "${STATE_DIR}"

down=()
for agent in ${AGENT_NAMES}; do
  if ! "${SYSTEMCTL_BIN}" --user is-active --quiet "buzz-agent@${agent}.service"; then
    down+=("${agent}")
  fi
done

current="${down[*]:-}"
previous=""
if [[ -f "${STATE_FILE}" ]]; then
  previous="$(<"${STATE_FILE}")"
fi

if [[ "${current}" == "${previous}" ]]; then
  exit 0
fi

if [[ -n "${current}" ]]; then
  message="🚨 VPS Buzz: agente(s) inativo(s): ${current}. Verifique: systemctl --user status 'buzz-agent@*'"
else
  message="✅ VPS Buzz: agentes recuperados; codex, claude e cursor estão ativos novamente."
fi

printf '%s\n' "${message}" | "${BUZZ_CLI}" messages send \
  --channel "${CHANNEL}" --content - >/dev/null

tmp_state="$(mktemp "${STATE_DIR}/down-agents.XXXXXX")"
trap 'rm -f "${tmp_state}"' EXIT
printf '%s' "${current}" >"${tmp_state}"
chmod 600 "${tmp_state}"
mv -f "${tmp_state}" "${STATE_FILE}"
trap - EXIT

