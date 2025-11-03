#!/usr/bin/env bash
set -euo pipefail
# Run as root (sudo). Installs Flask app, MariaDB, creates user, systemd service.

LAB_ROOT=/opt/maccdc-lab
APP_DIR=${LAB_ROOT}/target_app
SERVICE_USER=maccdclab

echo "Installing Target (web + DB) to ${APP_DIR} ..."

# must be root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 2
fi

apt-get update -y
apt-get install -y python3 python3-venv python3-pip mariadb-server git

# create service user
id -u ${SERVICE_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${SERVICE_USER}

# create app dir and copy app files from repo (assumes script run from repo root)
mkdir -p ${APP_DIR}
cp -r ./target/app/* ${APP_DIR}/
chown -R ${SERVICE_USER}:${SERVICE_USER} ${APP_DIR}

# python venv
python3 -m venv ${APP_DIR}/venv
${APP_DIR}/venv/bin/pip install --upgrade pip
${APP_DIR}/venv/bin/pip install -r ${APP_DIR}/requirements.txt

# DB setup
# Note: on a fresh MariaDB install, root may have no password via unix_socket.
# Create app database and scorebot user that scoreboard will use
mysql -e "CREATE DATABASE IF NOT EXISTS appdb;"
mysql -e "CREATE USER IF NOT EXISTS 'scorebot'@'127.0.0.1' IDENTIFIED BY 'scorepass';"
mysql -e "GRANT ALL PRIVILEGES ON appdb.* TO 'scorebot'@'127.0.0.1'; FLUSH PRIVILEGES;"
mysql appdb -e "CREATE TABLE IF NOT EXISTS flags (id INT PRIMARY KEY, name VARCHAR(64), cnt INT DEFAULT 0); INSERT IGNORE INTO flags (id,name,cnt) VALUES (1,'seed',1);"

# create compromise dir
mkdir -p /var/target
chown ${SERVICE_USER}:${SERVICE_USER} /var/target

# create systemd service
cat > /etc/systemd/system/maccdc-target.service <<'SERVICE'
[Unit]
Description=MACCDC Target App
After=network.target mariadb.service

[Service]
User=maccdclab
Group=maccdclab
WorkingDirectory=/opt/maccdc-lab/target_app
Environment="PATH=/opt/maccdc-lab/target_app/venv/bin"
ExecStart=/opt/maccdc-lab/target_app/venv/bin/gunicorn --bind 0.0.0.0:80 app:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now maccdc-target.service

echo "Target installed and started. Visit http://<host-ip>/ or /health"
