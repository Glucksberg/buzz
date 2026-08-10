#!/usr/bin/env bash
# Install the Buzz agent systemd template for the current user.
# This script never reads or writes agent credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HOME}/.config/buzz-agents"
SYSTEMD_DIR="${HOME}/.config/systemd/user"

install -d -m 700 "${CONFIG_DIR}"
install -d -m 755 "${SYSTEMD_DIR}"
install -m 644 "${SCRIPT_DIR}/buzz-agent@.service" "${SYSTEMD_DIR}/buzz-agent@.service"
install -m 644 "${SCRIPT_DIR}/buzz-agent-monitor.service" "${SYSTEMD_DIR}/buzz-agent-monitor.service"
install -m 644 "${SCRIPT_DIR}/buzz-agent-monitor.timer" "${SYSTEMD_DIR}/buzz-agent-monitor.timer"

for agent in codex claude cursor; do
  install -d -m 700 "${HOME}/.buzz/REPOS/${agent}"
done

systemctl --user daemon-reload
echo "Installed Buzz agent and monitor units. Credentials and services are still disabled."
