#!/usr/bin/env bash
set -euo pipefail
LAB_ROOT=/opt/maccdc-lab
SCORE_DIR=${LAB_ROOT}/scoreboard
SERVICE_USER=maccdclab

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 2
fi

apt-get update -y
apt-get install -y python3 python3-pip git
pip3 install requests mysql-connector-python

mkdir -p ${SCORE_DIR}
cp ./scoreboard/score_poller.py ${SCORE_DIR}/score_poller.py
chown -R ${SERVICE_USER}:${SERVICE_USER} ${SCORE_DIR}
chmod +x ${SCORE_DIR}/score_poller.py

# logs dir
mkdir -p /var/log/maccdc
chown ${SERVICE_USER}:${SERVICE_USER} /var/log/maccdc

# systemd service
cat > /etc/systemd/system/maccdc-scoreboard.service <<'SERVICE'
[Unit]
Description=MACCDC Scoreboard Poller
After=network.target

[Service]
User=maccdclab
Group=maccdclab
WorkingDirectory=/opt/maccdc-lab/scoreboard
ExecStart=/usr/bin/python3 /opt/maccdc-lab/scoreboard/score_poller.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now maccdc-scoreboard.service

echo "Scoreboard installed and running. Logs: /var/log/maccdc/score_log.csv"
