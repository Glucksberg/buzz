#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

install -m 755 /dev/stdin "${TEST_DIR}/systemctl" <<'SH'
#!/usr/bin/env bash
unit="${*: -1}"
agent="${unit#buzz-agent@}"
agent="${agent%.service}"
[[ " ${FAKE_DOWN:-} " != *" ${agent} "* ]]
SH

install -m 755 /dev/stdin "${TEST_DIR}/buzz" <<'SH'
#!/usr/bin/env bash
message="$(cat)"
printf '%s\n' "${message}" >>"${FAKE_SENT}"
SH

export BUZZ_AGENT_MONITOR_SYSTEMCTL="${TEST_DIR}/systemctl"
export BUZZ_AGENT_MONITOR_CLI="${TEST_DIR}/buzz"
export BUZZ_AGENT_MONITOR_CHANNEL="test-channel"
export BUZZ_AGENT_MONITOR_STATE_DIR="${TEST_DIR}/state"
export FAKE_SENT="${TEST_DIR}/sent"

FAKE_DOWN="" "${SCRIPT_DIR}/monitor-agents.sh"
[[ ! -e "${FAKE_SENT}" ]]

FAKE_DOWN="codex" "${SCRIPT_DIR}/monitor-agents.sh"
[[ "$(wc -l <"${FAKE_SENT}")" -eq 1 ]]
grep -q 'inativo(s): codex' "${FAKE_SENT}"

FAKE_DOWN="codex" "${SCRIPT_DIR}/monitor-agents.sh"
[[ "$(wc -l <"${FAKE_SENT}")" -eq 1 ]]

FAKE_DOWN="" "${SCRIPT_DIR}/monitor-agents.sh"
[[ "$(wc -l <"${FAKE_SENT}")" -eq 2 ]]
grep -q 'agentes recuperados' "${FAKE_SENT}"

echo "agent monitor transition tests passed"
