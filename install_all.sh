#!/usr/bin/env bash
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo: sudo $0"
  exit 2
fi

./target/install_target.sh
./scoreboard/install_scoreboard.sh
./attacker/install_attacker.sh

echo "All components installed. Check systemd services:"
systemctl status maccdc-target maccdc-scoreboard maccdc-attacker --no-pager
