#!/usr/bin/env bash
set -euo pipefail
LAB_ROOT=/opt/maccdc-lab
ATT_DIR=${LAB_ROOT}/attacker
SERVICE_USER=maccdclab

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 2
fi

apt-get update -y
apt-get install -y python3 python3-pip
pip3 install requests

mkdir -p ${ATT_DIR}
cp ./attacker/attacker_sim.py ${ATT_DIR}/attacker_sim.py
chown -R ${SERVICE_USER}:${SERVICE_USER} ${ATT_DIR}
chmod +x ${ATT_DIR}/attacker_sim.py

# systemd service for attacker simulator
cat > /etc/systemd/system/maccdc-attacker.service <<'SERVICE'
[Unit]
Description=MACCDC Attacker Simulator
After=network.target

[Service]
User=maccdclab
Group=maccdclab
WorkingDirectory=/opt/maccdc-lab/attacker
Environment=WAIT_SECONDS=1200
ExecStart=/usr/bin/python3 /opt/maccdc-lab/attacker/attacker_sim.py
Restart=no

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now maccdc-attacker.service

echo "Attacker simulator installed. Adjust WAIT_SECONDS env in systemd service file or edit attacker_sim.py for quicker testing."
